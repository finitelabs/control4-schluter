--- Legacy Schluter backend — the undocumented myschluter.com app API.
---
--- This is the same REST surface the Schluter mobile app / web dashboard and the
--- original (now unmaintained) Control4 driver used. The client owns its own
--- session: authenticate() stores the SessionId and every other call uses it.
--- All methods return a Deferred that resolves with the decoded JSON body (or
--- rejects). See docs/schluter-api-reference.md.
---
--- API surface:
---   POST /api/authenticate/user            -> { ErrorCode, SessionId }
---   GET  /api/thermostats?sessionid=        -> thermostat list
---   GET  /api/thermostat?sessionid=&serialnumber=
---   POST /api/thermostat?sessionid=&serialnumber=   (setpoint/mode/hold + Schedules[])
---   GET  /api/notification?sessionid=&sequencenr=   (long-poll, ~5 min)
---
--- Schedules are not a separate endpoint here: the thermostat object carries a
--- Schedules[] array, so getSchedule/setSchedule read-modify-write that object.

local deferred = require("deferred")
local http = require("lib.http")
local log = require("lib.logging")
local JSON = require("JSON")

--- Default host (Schluter). Schluter DITRA-HEAT uses the same API on a different
--- host + Application id; both are configured via new({ host, applicationId }).
local DEFAULT_HOST = "https://www.myschluter.com"
local HEADERS = { ["Content-Type"] = "application/json; charset=utf-8" }
-- The notification endpoint long-polls: the server holds the request open (~5 min)
-- until a change occurs or its own timeout elapses. Stay comfortably *under* the
-- server's hold — lib.http clamps request timeouts to 300s, so asking for more
-- silently lands on 300 and races the server's reply, tearing down the connection
-- at the exact moment it answers. Nothing is lost by expiring early: the cursor
-- (sequencenr) means the next poll re-delivers anything that happened meanwhile.
local NOTIFY_TIMEOUT_S = 240
-- Writes need far longer than lib.http's 30s default. A POST issued while the
-- controller is holding the notification connection can take tens of seconds
-- (measured: 17s, 30s, 10s) even though the same request from a workstation
-- completes in 0.3s. At 30s we were aborting writes that were about to succeed
-- and reporting them as failures.
local WRITE_TIMEOUT_S = 120

--- @class SchluterAuthError
--- @field errorCode number Schluter ErrorCode (1/2 = invalid credentials)
--- @field message string Human-readable message

--- @class SchluterLegacyClient
local Client = {}
Client.__index = Client

--- @param config table|nil { host?: string, applicationId?: number } — brand host
--- and OJ Application id (Schluter=7; Schluter omits it).
--- @return SchluterLegacyClient
function Client:new(config)
  config = config or {}
  local instance = setmetatable({}, self)
  instance._sessionId = nil
  instance._host = config.host or DEFAULT_HOST
  instance._applicationId = config.applicationId
  --- Transfer handle for the in-flight notification long-poll, so it can be
  --- aborted when a write needs the connection (see cancelNotification).
  instance._notifyTransfer = nil
  return instance
end

--- Coerce a response body to a decoded table. lib.http (via drivers-common-public
--- url) already parses JSON responses into a table, so accept that directly and
--- only decode when the body is still a raw string.
--- @param body string|table
--- @return table|nil decoded, string|nil error
local function _decode(body)
  if type(body) == "table" then
    return body, nil
  end
  local ok, decoded = pcall(JSON.decode, JSON, body)
  if not ok or type(decoded) ~= "table" then
    return nil, "malformed JSON response"
  end
  return decoded, nil
end

-- ─── Auth / session ────────────────────────────────────────────────────────

--- Authenticate against myschluter.com and hold the resulting session id.
--- @param email string
--- @param password string
--- @return Deferred<boolean, SchluterAuthError>
function Client:authenticate(email, password)
  log:trace("legacy:authenticate(%s)", email)
  local d = deferred.new()
  -- Confirm is used by Schluter; Application scopes the OJ tenant (Schluter=7).
  local payload = { Email = email, Password = password, Confirm = password }
  if self._applicationId ~= nil then
    payload.Application = self._applicationId
  end
  local body = JSON:encode(payload)

  http:post(self._host .. "/api/authenticate/user", body, HEADERS):next(function(response)
    local object, err = _decode(response.body)
    if not object then
      return d:reject({ errorCode = -1, message = err })
    end
    if object.ErrorCode == 0 and not IsEmpty(object.SessionId) then
      self._sessionId = object.SessionId
      return d:resolve(true)
    end
    -- ErrorCode 1/2 = invalid username/password; anything else = other failure.
    d:reject({
      errorCode = object.ErrorCode,
      message = (object.ErrorCode == 1 or object.ErrorCode == 2) and "Invalid username or password"
        or ("Authentication failed (ErrorCode " .. tostring(object.ErrorCode) .. ")"),
    })
  end, function(errorResponse)
    -- Surface the underlying transport error (timeout, DNS, TLS) rather than a
    -- generic message so failures are diagnosable.
    local detail = type(errorResponse) == "table" and errorResponse.error or errorResponse
    d:reject({ errorCode = -1, message = "authenticate request failed: " .. tostring(detail) })
  end)

  return d
end

--- @return boolean
function Client:isAuthenticated()
  return self._sessionId ~= nil
end

--- Drop the held session.
function Client:logout()
  self._sessionId = nil
end

-- ─── Thermostats ───────────────────────────────────────────────────────────

--- List the thermostats visible to this account (grouped at myschluter.com/#groups).
--- @return Deferred<table[], any>
function Client:getThermostats()
  log:trace("legacy:getThermostats()")
  local url = MakeURL(self._host .. "/api/thermostats", { sessionid = self._sessionId })
  return self:_getJson(url):next(function(result)
    -- Normalize to a bare array of thermostat objects. Schluter returns
    -- `Thermostats`; Schluter wraps them in `Groups[].Thermostats`.
    if type(result.Groups) == "table" then
      local list = {}
      for _, group in ipairs(result.Groups) do
        for _, t in ipairs(group.Thermostats or {}) do
          list[#list + 1] = t
        end
      end
      return list
    end
    return result.Thermostats or result
  end)
end

--- Get a single thermostat's current state by serial number.
--- @param serialNumber string
--- @return Deferred<table, any>
function Client:getThermostat(serialNumber)
  log:trace("legacy:getThermostat(%s)", serialNumber)
  local url = MakeURL(self._host .. "/api/thermostat", { sessionid = self._sessionId, serialnumber = serialNumber })
  return self:_getJson(url):next(function(result)
    return result.Thermostat or result
  end)
end

--- The only fields the server accepts on a write. Taken from the official app,
--- which serializes its POST body against `json.shared.ThermostatPost` and so
--- sends exactly these (see docs/schluter-api-reference.md). Everything else on
--- the thermostat object is read-only and echoing it back is meaningless —
--- notably `SetPointTemp`, which the server derives from ManualTemperature /
--- ComfortTemperature / the active schedule. Writing it does nothing, which is
--- why a bare SetPointTemp write never took effect in Manual mode.
local WRITABLE_FIELDS = {
  "RegulationMode",
  "ManualTemperature",
  "ComfortTemperature",
  "ComfortEndTime",
  "Schedules",
  "VacationEnabled",
  "VacationBeginDay",
  "VacationEndDay",
  "VacationTemperature",
  "LastPrimaryModeIsAuto",
}

--- Reduce a full thermostat object to the writable subset.
--- @param settings table
--- @return table
local function _writable(settings)
  local body = {}
  for _, field in ipairs(WRITABLE_FIELDS) do
    if settings[field] ~= nil then
      body[field] = settings[field]
    end
  end
  return body
end

--- Push a mutated settings object to a thermostat (setpoint / mode / hold and/or
--- Schedules[]). Accepts the canonical Schluter thermostat shape and sends only
--- the fields the server actually writes.
--- @param serialNumber string
--- @param settings table
--- @return Deferred<table, any>
function Client:setThermostat(serialNumber, settings)
  log:trace("legacy:setThermostat(%s)", serialNumber)
  local d = deferred.new()
  local url = MakeURL(self._host .. "/api/thermostat", { sessionid = self._sessionId, serialnumber = serialNumber })

  http:post(url, JSON:encode(_writable(settings)), HEADERS, { timeout = WRITE_TIMEOUT_S }):next(function(response)
    local object, err = _decode(response.body)
    if not object then
      return d:reject(err)
    end
    if object.Success == false then
      return d:reject("setThermostat rejected by server")
    end
    -- Schluter's POST replies with just `{"Success":true}` — not the device. If a
    -- device object came back (some backends do), use it. Otherwise resolve with
    -- the settings we just wrote rather than issuing a readback: the object we
    -- sent already carries the post-write state on every field the caller reads
    -- (setHeldTemp writes SetPointTemp alongside Manual/ComfortTemperature), and
    -- the account reconciles against the cloud on its next refresh anyway. The
    -- readback used to be a per-write GET on /api/thermostat, which piled a
    -- fourth concurrent request onto a host already holding a long-poll and
    -- routinely timed out — reporting a *write* failure for a read that failed
    -- after the write had already succeeded.
    if type(object.Thermostat) == "table" or object.SerialNumber ~= nil then
      d:resolve(object.Thermostat or object)
    else
      d:resolve(settings)
    end
  end, function(errorResponse)
    -- Mirrors _getJson: a write is the other place a rejected session surfaces,
    -- and suspendNotifications() has just cancelled the long poll, so without
    -- this the 401 goes unnoticed until some unrelated GET happens to hit it.
    if type(errorResponse) == "table" and errorResponse.code == 401 then
      log:info("Session rejected (401) on write; clearing it so the driver re-authenticates")
      self:logout()
    end
    local detail = type(errorResponse) == "table" and errorResponse.error or errorResponse
    d:reject("setThermostat request failed: " .. tostring(detail))
  end)

  return d
end

-- ─── Schedules ─────────────────────────────────────────────────────────────
-- Legacy has no dedicated schedule endpoint; schedules live inside the
-- thermostat object, so these read-modify-write that object.

--- Read the current weekly schedule as a canonical Schedules[] array.
--- @param serialNumber string
--- @return Deferred<table[], any>
function Client:getSchedule(serialNumber)
  log:trace("legacy:getSchedule(%s)", serialNumber)
  return self:getThermostat(serialNumber):next(function(thermostat)
    return thermostat.Schedules or {}
  end)
end

--- Write a canonical Schedules[] array back to the thermostat, preserving the
--- rest of the current object.
--- @param serialNumber string
--- @param schedules table[]
--- @return Deferred<table, any>
function Client:setSchedule(serialNumber, schedules)
  log:trace("legacy:setSchedule(%s)", serialNumber)
  return self:getThermostat(serialNumber):next(function(thermostat)
    thermostat.Schedules = schedules
    return self:setThermostat(serialNumber, thermostat)
  end)
end

-- ─── Real-time notifications ───────────────────────────────────────────────

--- Long-poll for the next account notification. Resolves when the server
--- returns (a change occurred) or the request completes; the caller inspects
--- `SequenceNr` and re-requests with the next sequence number. The response also
--- embeds the changed `Thermostat` and an `Action` (see constants.NOTIFY_ACTION).
---
--- This one request is issued through `urlDo` rather than lib.http so we can keep
--- the transfer handle and abort it later (see cancelNotification): the
--- controller starves POSTs while this long-poll is open, so a write has to be
--- able to take the connection back.
--- @param sequenceNr number
--- @return Deferred<table, any>
function Client:getNotification(sequenceNr)
  log:trace("legacy:getNotification(seq=%s)", sequenceNr)
  local d = deferred.new()
  local url = MakeURL(self._host .. "/api/notification", { sessionid = self._sessionId, sequencenr = sequenceNr })

  local transfer = urlDo("GET", url, nil, HEADERS, function(strError, responseCode, _headers, responseBody)
    self._notifyTransfer = nil
    if strError or IsEmpty(responseCode) or responseCode < 200 or responseCode >= 300 then
      if responseCode == 401 then
        log:info("Session rejected (401) on notification; clearing it")
        self:logout()
      end
      return d:reject(
        string.format(
          "GET %s failed%s%s",
          url,
          not IsEmpty(responseCode) and (" with status code " .. responseCode) or "",
          not IsEmpty(strError) and ("; " .. strError) or ""
        )
      )
    end
    local object, err = _decode(responseBody)
    if not object then
      return d:reject(err)
    end
    d:resolve(object)
  end, nil, { timeout = NOTIFY_TIMEOUT_S })

  -- urlDo only hands back a transfer object on the newer url stack; without one
  -- we simply cannot abort, and the caller falls back to ignoring the response.
  self._notifyTransfer = transfer
  return d
end

--- Abort the in-flight notification long-poll, freeing the connection it holds.
--- The pending request rejects with a cancellation error, which the caller
--- ignores (its loop generation has already been retired).
--- @return boolean cancelled True if a transfer was actually aborted.
function Client:cancelNotification()
  local transfer = self._notifyTransfer
  self._notifyTransfer = nil
  if not transfer or type(transfer.Cancel) ~= "function" then
    return false
  end
  local ok = pcall(function()
    transfer:Cancel()
  end)
  log:trace("legacy:cancelNotification() -> %s", ok)
  return ok
end

-- ─── Internals ─────────────────────────────────────────────────────────────

--- Shared GET → decode-JSON helper.
--- @param url string Full request URL (query string included).
--- @param options table|nil Optional http request options (e.g. timeout).
--- @return Deferred<table, any>
function Client:_getJson(url, options)
  local d = deferred.new()
  http:get(url, HEADERS, options):next(function(response)
    local object, err = _decode(response.body)
    if not object then
      return d:reject(err)
    end
    d:resolve(object)
  end, function(errorResponse)
    -- Sessions expire server-side after a short idle period. Drop the dead one
    -- so isAuthenticated() goes false and the caller can log in again; without
    -- this the driver would retry forever against a session the server has
    -- already forgotten.
    if type(errorResponse) == "table" and errorResponse.code == 401 then
      log:info("Session rejected (401); clearing it so the driver re-authenticates")
      self:logout()
    end
    local detail = type(errorResponse) == "table" and errorResponse.error or errorResponse
    d:reject("GET " .. url .. " failed: " .. tostring(detail))
  end)
  return d
end

return Client
