--- Legacy NuHeat backend — the undocumented mynuheat.com app API.
---
--- This is the same REST surface the NuHeat mobile app / web dashboard and the
--- original (now unmaintained) Control4 driver used. The client owns its own
--- session: authenticate() stores the SessionId and every other call uses it.
--- All methods return a Deferred that resolves with the decoded JSON body (or
--- rejects). See docs/nuheat-api-reference.md.
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

local BASE_URL = "https://www.mynuheat.com"
local HEADERS = { ["Content-Type"] = "application/json; charset=utf-8" }
-- The notification endpoint long-polls: the server holds the request open until
-- a change occurs or the timeout elapses. Give it well over the ~5 min the old
-- driver used so we don't tear the connection down early.
local NOTIFY_TIMEOUT_S = 330

--- @class NuHeatAuthError
--- @field errorCode number NuHeat ErrorCode (1/2 = invalid credentials)
--- @field message string Human-readable message

--- @class NuHeatLegacyClient
local Client = {}
Client.__index = Client

--- @param _config table|nil Unused for the legacy backend.
--- @return NuHeatLegacyClient
function Client:new(_config)
  return setmetatable({ _sessionId = nil }, self)
end

--- Build a `?a=b&c=d` query string from a table (values URL-encoded).
--- @param params table<string, string|number>
--- @return string
local function _query(params)
  local parts = {}
  for k, v in pairs(params) do
    parts[#parts + 1] = tostring(k) .. "=" .. C4:URLEncode(tostring(v))
  end
  return "?" .. table.concat(parts, "&")
end

--- Decode a JSON response body, returning nil + error on malformed JSON.
--- @param body string
--- @return table|nil decoded, string|nil error
local function _decode(body)
  local ok, decoded = pcall(JSON.decode, JSON, body)
  if not ok or type(decoded) ~= "table" then
    return nil, "malformed JSON response"
  end
  return decoded, nil
end

-- ─── Auth / session ────────────────────────────────────────────────────────

--- Authenticate against mynuheat.com and hold the resulting session id.
--- @param email string
--- @param password string
--- @return Deferred<boolean, NuHeatAuthError>
function Client:authenticate(email, password)
  log:trace("legacy:authenticate(%s)", email)
  local d = deferred.new()
  local body = JSON:encode({ Email = email, Password = password, Confirm = password })

  http:post(BASE_URL .. "/api/authenticate/user", body, HEADERS):next(function(response)
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

--- List the thermostats visible to this account (grouped at mynuheat.com/#groups).
--- @return Deferred<table[], any>
function Client:getThermostats()
  log:trace("legacy:getThermostats()")
  return self:_getJson("/api/thermostats" .. _query({ sessionid = self._sessionId })):next(function(result)
    -- Normalize to a bare array of thermostat objects.
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
--- Schedules[]). The object is the canonical NuHeat thermostat shape.
--- @param serialNumber string
--- @param settings table
--- @return Deferred<table, any>
function Client:setThermostat(serialNumber, settings)
  log:trace("legacy:setThermostat(%s)", serialNumber)
  local d = deferred.new()
  local url = BASE_URL .. "/api/thermostat" .. _query({ sessionid = self._sessionId, serialnumber = serialNumber })

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
  http:get(BASE_URL .. path, HEADERS, options):next(function(response)
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
