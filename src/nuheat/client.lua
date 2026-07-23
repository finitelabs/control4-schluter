--- NuHeat Signature cloud API client for Control4.
--- Talks to the mynuheat.com REST API used by the NuHeat mobile app / web
--- dashboard. All methods return a Deferred that resolves with the decoded
--- JSON body (or rejects with an error). Session handling (login, re-auth on
--- expiry) is owned by the account driver; this client is stateless apart from
--- caching the credentials passed to authenticate().
---
--- API surface (see docs/nuheat-api-reference.md):
---   POST /api/authenticate/user            -> { ErrorCode, SessionId }
---   GET  /api/thermostats?sessionid=        -> thermostat list
---   GET  /api/thermostat?sessionid=&serialnumber=
---   POST /api/thermostat?sessionid=&serialnumber=
---   GET  /api/notification?sessionid=&sequencenr=   (long-poll, ~5 min)

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

--- @class NuHeatClient
local NuHeatClient = {}
NuHeatClient.__index = NuHeatClient

--- @return NuHeatClient
function NuHeatClient:new()
  local instance = setmetatable({}, self)
  return instance
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

--- Decode a JSON response body, rejecting the deferred on malformed JSON.
--- @param body string
--- @return table|nil decoded, string|nil error
local function _decode(body)
  local ok, decoded = pcall(JSON.decode, JSON, body)
  if not ok or type(decoded) ~= "table" then
    return nil, "malformed JSON response"
  end
  return decoded, nil
end

--- Authenticate against mynuheat.com. Resolves with the session id string.
--- @param email string
--- @param password string
--- @return Deferred<string, NuHeatAuthError>
function NuHeatClient:authenticate(email, password)
  log:trace("NuHeatClient:authenticate(%s)", email)
  local d = deferred.new()
  local body = JSON:encode({ Email = email, Password = password, Confirm = password })

  http:post(BASE_URL .. "/api/authenticate/user", body, HEADERS):next(function(response)
    local object, err = _decode(response.body)
    if not object then
      return d:reject({ errorCode = -1, message = err })
    end
    if object.ErrorCode == 0 and object.SessionId and object.SessionId ~= "" then
      return d:resolve(object.SessionId)
    end
    -- ErrorCode 1/2 = invalid username/password; anything else = other failure.
    d:reject({
      errorCode = object.ErrorCode,
      message = (object.ErrorCode == 1 or object.ErrorCode == 2) and "Invalid username or password"
        or ("Authentication failed (ErrorCode " .. tostring(object.ErrorCode) .. ")"),
    })
  end, function(errorResponse)
    d:reject({ errorCode = -1, message = "authenticate request failed" })
  end)

  return d
end

--- List the thermostats visible to this account (grouped at mynuheat.com/#groups).
--- @param sessionId string
--- @return Deferred<table, any>
function NuHeatClient:getThermostats(sessionId)
  log:trace("NuHeatClient:getThermostats()")
  return self:_getJson("/api/thermostats" .. _query({ sessionid = sessionId }))
end

--- Get a single thermostat's current state by serial number.
--- @param sessionId string
--- @param serialNumber string
--- @return Deferred<table, any>
function NuHeatClient:getThermostat(sessionId, serialNumber)
  log:trace("NuHeatClient:getThermostat(%s)", serialNumber)
  return self:_getJson("/api/thermostat" .. _query({ sessionid = sessionId, serialnumber = serialNumber }))
end

--- Push settings to a thermostat (setpoint, mode, hold, schedule).
--- @param sessionId string
--- @param serialNumber string
--- @param settings table The mutated NuHeat thermostat settings object.
--- @return Deferred<table, any>
function NuHeatClient:setThermostat(sessionId, serialNumber, settings)
  log:trace("NuHeatClient:setThermostat(%s)", serialNumber)
  local d = deferred.new()
  local url = BASE_URL .. "/api/thermostat" .. _query({ sessionid = sessionId, serialnumber = serialNumber })

  http:post(url, JSON:encode(settings), HEADERS):next(function(response)
    local object, err = _decode(response.body)
    if not object then
      return d:reject(err)
    end
    d:resolve(object)
  end, function()
    d:reject("setThermostat request failed")
  end)

  return d
end

--- Long-poll for the next account notification. Resolves when the server
--- returns (a change occurred) or the request completes; the caller inspects
--- `SequenceNr` and re-requests with the next sequence number.
--- @param sessionId string
--- @param sequenceNr number
--- @return Deferred<table, any>
function NuHeatClient:getNotification(sessionId, sequenceNr)
  log:trace("NuHeatClient:getNotification(seq=%s)", sequenceNr)
  return self:_getJson(
    "/api/notification" .. _query({ sessionid = sessionId, sequencenr = sequenceNr }),
    { timeout = NOTIFY_TIMEOUT_S }
  )
end

--- Shared GET → decode-JSON helper.
--- @param path string Path beginning with `/api/...` (query string included).
--- @param options table|nil Optional http request options (e.g. timeout).
--- @return Deferred<table, any>
function NuHeatClient:_getJson(path, options)
  local d = deferred.new()
  http:get(BASE_URL .. path, HEADERS, options):next(function(response)
    local object, err = _decode(response.body)
    if not object then
      return d:reject(err)
    end
    d:resolve(object)
  end, function()
    d:reject("GET " .. path .. " failed")
  end)
  return d
end

return NuHeatClient
