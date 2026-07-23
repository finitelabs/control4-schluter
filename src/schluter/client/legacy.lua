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
-- The notification endpoint long-polls: the server holds the request open until
-- a change occurs or the timeout elapses. Give it well over the ~5 min the old
-- driver used so we don't tear the connection down early.
local NOTIFY_TIMEOUT_S = 330

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
  return setmetatable({
    _sessionId = nil,
    _host = config.host or DEFAULT_HOST,
    _applicationId = config.applicationId,
  }, self)
end

--- Percent-encode a string (RFC 3986 unreserved set). Self-contained because
--- C4:URLEncode is not present on all controller OS versions.
--- @param s string|number
--- @return string
local function _urlEncode(s)
  return (tostring(s):gsub("[^%w%-_%.~]", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end

--- Build a `?a=b&c=d` query string from a table (values URL-encoded).
--- @param params table<string, string|number>
--- @return string
local function _query(params)
  local parts = {}
  for k, v in pairs(params) do
    parts[#parts + 1] = tostring(k) .. "=" .. _urlEncode(v)
  end
  return "?" .. table.concat(parts, "&")
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
    if object.ErrorCode == 0 and object.SessionId and object.SessionId ~= "" then
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
  return self:_getJson("/api/thermostats" .. _query({ sessionid = self._sessionId })):next(function(result)
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
  return self
    :_getJson("/api/thermostat" .. _query({ sessionid = self._sessionId, serialnumber = serialNumber }))
    :next(function(result)
      return result.Thermostat or result
    end)
end

--- Push a mutated settings object to a thermostat (setpoint / mode / hold and/or
--- Schedules[]). The object is the canonical Schluter thermostat shape.
--- @param serialNumber string
--- @param settings table
--- @return Deferred<table, any>
function Client:setThermostat(serialNumber, settings)
  log:trace("legacy:setThermostat(%s)", serialNumber)
  local d = deferred.new()
  local url = self._host .. "/api/thermostat" .. _query({ sessionid = self._sessionId, serialnumber = serialNumber })

  http:post(url, JSON:encode(settings), HEADERS):next(function(response)
    local object, err = _decode(response.body)
    if not object then
      return d:reject(err)
    end
    d:resolve(object.Thermostat or object)
  end, function(errorResponse)
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
--- `SequenceNr` and re-requests with the next sequence number.
--- @param sequenceNr number
--- @return Deferred<table, any>
function Client:getNotification(sequenceNr)
  log:trace("legacy:getNotification(seq=%s)", sequenceNr)
  return self:_getJson(
    "/api/notification" .. _query({ sessionid = self._sessionId, sequencenr = sequenceNr }),
    { timeout = NOTIFY_TIMEOUT_S }
  )
end

-- ─── Internals ─────────────────────────────────────────────────────────────

--- Shared GET → decode-JSON helper.
--- @param path string Path beginning with `/api/...` (query string included).
--- @param options table|nil Optional http request options (e.g. timeout).
--- @return Deferred<table, any>
function Client:_getJson(path, options)
  local d = deferred.new()
  http:get(self._host .. path, HEADERS, options):next(function(response)
    local object, err = _decode(response.body)
    if not object then
      return d:reject(err)
    end
    d:resolve(object)
  end, function(errorResponse)
    local detail = type(errorResponse) == "table" and errorResponse.error or errorResponse
    d:reject("GET " .. path .. " failed: " .. tostring(detail))
  end)
  return d
end

return Client
