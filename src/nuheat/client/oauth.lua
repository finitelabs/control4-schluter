--- OAuth2 NuHeat backend — the documented OpenAPI at api.mynuheat.com.
---
--- Drop-in replacement for nuheat.client.legacy that speaks the official,
--- supported API (OAuth2/OpenID via identity.mynuheat.com, dedicated
--- Thermostat / Schedule / Group / EnergyLog endpoints). It translates the
--- OpenAPI models to/from the canonical NuHeat thermostat shape the drivers
--- already consume, so the account/companion code is unchanged.
---
--- STATUS: skeleton. The endpoint mapping and model translation are written
--- against the published OpenAPI spec (api.mynuheat.com/swagger/v1/swagger.json),
--- but two things must be confirmed against a live account before this is
--- production-ready, both marked `-- TODO(oauth)` below:
---   1. The OAuth2 grant type NuHeat enables for integrators (and thus the exact
---      token request) — pending a ClientID from NuHeat support.
---   2. The ThermostatModel field names + temperature units (the spec lists the
---      schema shape but not units; legacy is °C×100).
--- Everything is centralized so those are one-line fixes once verified.

local deferred = require("deferred")
local http = require("lib.http")
local log = require("lib.logging")
local JSON = require("JSON")

-- Regional host: api.mynuheat.com (global) or api.nam.mynuheat.com (N. America).
local API_BASE = "https://api.mynuheat.com"
local IDENTITY_BASE = "https://identity.mynuheat.com"
local TOKEN_URL = IDENTITY_BASE .. "/connect/token"
local SCOPES = "openid openapi offline_access"
-- Poll interval for change detection (the official API has no long-poll).
local POLL_INTERVAL_MS = 60 * 1000
-- Refresh the access token this many seconds before it actually expires.
local TOKEN_SKEW_S = 60

--- @class NuHeatOAuthClient
local Client = {}
Client.__index = Client

--- @param config table|nil { clientId, clientSecret, scopes?, apiBase?, region? }
--- @return NuHeatOAuthClient
function Client:new(config)
  config = config or {}
  return setmetatable({
    _clientId = config.clientId,
    _clientSecret = config.clientSecret,
    _scopes = config.scopes or SCOPES,
    _apiBase = config.apiBase or API_BASE,
    _email = nil,
    _password = nil,
    _accessToken = nil,
    _refreshToken = nil,
    _expiresAt = 0,
  }, self)
end

-- ─── Auth / token ──────────────────────────────────────────────────────────

--- Store credentials and acquire an initial access token.
--- @param email string
--- @param password string
--- @return Deferred<boolean, NuHeatAuthError>
function Client:authenticate(email, password)
  log:trace("oauth:authenticate(%s)", email)
  self._email = email
  self._password = password
  return self:_ensureToken():next(function()
    return true
  end)
end

--- @return boolean
function Client:isAuthenticated()
  return self._accessToken ~= nil and os.time() < self._expiresAt
end

function Client:logout()
  self._accessToken, self._refreshToken, self._expiresAt = nil, nil, 0
end

--- Ensure a live access token, acquiring or refreshing as needed.
--- @return Deferred<string, NuHeatAuthError> resolves with the access token
function Client:_ensureToken()
  if self:isAuthenticated() then
    return deferred.new():resolve(self._accessToken)
  end
  if not self._clientId then
    return deferred.new():reject({
      errorCode = -1,
      message = "OAuth ClientID not configured (request one from NuHeat support)",
    })
  end

  -- Prefer a refresh_token exchange when we have one; otherwise a fresh grant.
  local form
  if self._refreshToken then
    form = {
      grant_type = "refresh_token",
      refresh_token = self._refreshToken,
      client_id = self._clientId,
      client_secret = self._clientSecret,
    }
  else
    -- TODO(oauth): confirm the grant type NuHeat enables for integrators. This
    -- assumes Resource Owner Password Credentials; may instead be authorization
    -- code (needs a browser redirect) or device code. Kept isolated here.
    form = {
      grant_type = "password",
      username = self._email,
      password = self._password,
      client_id = self._clientId,
      client_secret = self._clientSecret,
      scope = self._scopes,
    }
  end

  local d = deferred.new()
  local headers = { ["Content-Type"] = "application/x-www-form-urlencoded" }
  http:post(TOKEN_URL, self:_encodeForm(form), headers):next(function(response)
    local ok, token = pcall(JSON.decode, JSON, response.body)
    if not ok or type(token) ~= "table" or not token.access_token then
      return d:reject({ errorCode = -1, message = "token request returned no access_token" })
    end
    self._accessToken = token.access_token
    self._refreshToken = token.refresh_token or self._refreshToken
    self._expiresAt = os.time() + (tonumber(token.expires_in) or 3600) - TOKEN_SKEW_S
    d:resolve(self._accessToken)
  end, function(errorResponse)
    local detail = type(errorResponse) == "table" and errorResponse.error or errorResponse
    self._accessToken, self._expiresAt = nil, 0
    d:reject({ errorCode = -1, message = "token request failed: " .. tostring(detail) })
  end)
  return d
end

-- ─── Thermostats ───────────────────────────────────────────────────────────

--- @return Deferred<table[], any>
function Client:getThermostats()
  log:trace("oauth:getThermostats()")
  return self:_request("GET", "/api/v1/Thermostat"):next(function(list)
    local out = {}
    for _, model in ipairs(type(list) == "table" and list or {}) do
      out[#out + 1] = self:_thermostatToCanonical(model)
    end
    return out
  end)
end

--- @param serialNumber string
--- @return Deferred<table, any>
function Client:getThermostat(serialNumber)
  log:trace("oauth:getThermostat(%s)", serialNumber)
  return self:_request("GET", "/api/v1/Thermostat/" .. serialNumber):next(function(model)
    return self:_thermostatToCanonical(model)
  end)
end

--- Write a mutated canonical settings object. Routes to the Schedule endpoint
--- when Schedules[] are present, otherwise the Thermostat (hold) endpoint.
--- @param serialNumber string
--- @param settings table
--- @return Deferred<table, any>
function Client:setThermostat(serialNumber, settings)
  log:trace("oauth:setThermostat(%s)", serialNumber)
  if type(settings.Schedules) == "table" then
    return self:setSchedule(serialNumber, settings.Schedules)
  end
  -- PUT /api/v1/Thermostat sets hold/mode. Map canonical ScheduleMode/SetPointTemp.
  local body = {
    serialNumber = serialNumber,
    scheduleMode = settings.ScheduleMode,
    setPointTemp = settings.SetPointTemp, -- TODO(oauth): confirm field name + units
  }
  return self:_request("PUT", "/api/v1/Thermostat", body):next(function()
    return self:getThermostat(serialNumber)
  end)
end

-- ─── Schedules ─────────────────────────────────────────────────────────────

--- @param serialNumber string
--- @return Deferred<table[], any> canonical Schedules[]
function Client:getSchedule(serialNumber)
  log:trace("oauth:getSchedule(%s)", serialNumber)
  return self:_request("GET", "/api/v1/Schedule/" .. serialNumber):next(function(model)
    return self:_scheduleToCanonical(model)
  end)
end

--- @param serialNumber string
--- @param schedules table[] canonical Schedules[]
--- @return Deferred<table, any>
function Client:setSchedule(serialNumber, schedules)
  log:trace("oauth:setSchedule(%s)", serialNumber)
  local body = self:_scheduleFromCanonical(serialNumber, schedules)
  return self:_request("PUT", "/api/v1/Schedule", body):next(function()
    return self:getThermostat(serialNumber)
  end)
end

-- ─── Change detection (polling shim for the missing long-poll) ──────────────

--- The OpenAPI has no long-poll. Emulate the legacy notification contract by
--- resolving after a fixed interval so the account re-reads state periodically.
--- @param sequenceNr number
--- @return Deferred<table, any> resolves { SequenceNr = sequenceNr + 1 }
function Client:getNotification(sequenceNr)
  log:trace("oauth:getNotification(seq=%s)", sequenceNr)
  local d = deferred.new()
  C4:SetTimer(POLL_INTERVAL_MS, function()
    d:resolve({ SequenceNr = (tonumber(sequenceNr) or 0) + 1 })
  end)
  return d
end

-- ─── Model translation (OpenAPI ⇄ canonical NuHeat shape) ──────────────────

--- ThermostatModel → canonical thermostat object.
--- TODO(oauth): confirm OpenAPI field names + temperature units against a live
--- response; centralized here so it is a one-line fix.
--- @param m table
--- @return table
function Client:_thermostatToCanonical(m)
  m = m or {}
  return {
    SerialNumber = m.serialNumber,
    Room = m.room or m.groupName or "",
    GroupName = m.groupName,
    Online = m.online == true,
    Heating = m.heating == true,
    Temperature = m.temperature,
    SetPointTemp = m.setPointTemp,
    ScheduleMode = m.scheduleMode,
    MinTemp = m.minTemp,
    MaxTemp = m.maxTemp,
    Schedules = m.schedules and self:_scheduleToCanonical({ days = m.schedules }) or nil,
  }
end

--- ScheduleModel (days[] of ScheduleDayModel) → canonical Schedules[].
--- @param model table { days = ScheduleDayModel[] }
--- @return table[]
function Client:_scheduleToCanonical(model)
  local days = (model or {}).days or {}
  local out = {}
  for _, day in ipairs(days) do
    local events = {}
    for _, e in ipairs(day.events or {}) do
      events[#events + 1] = {
        Clock = e.clock,
        ScheduleType = e.scheduleType,
        TempFloor = e.temperature,
        Active = e.active == true,
      }
    end
    out[#out + 1] = { WeekDayGrpNo = day.weekDayGroupNumber, WeekDay = day.weekDay, Events = events }
  end
  return out
end

--- Canonical Schedules[] → ScheduleModel body for PUT /api/v1/Schedule.
--- @param serialNumber string
--- @param schedules table[]
--- @return table
function Client:_scheduleFromCanonical(serialNumber, schedules)
  local days = {}
  for _, day in ipairs(schedules or {}) do
    local events = {}
    for _, e in ipairs(day.Events or {}) do
      events[#events + 1] = {
        clock = e.Clock,
        scheduleType = e.ScheduleType,
        temperature = e.TempFloor,
        active = e.Active == true,
      }
    end
    days[#days + 1] = { weekDay = day.WeekDay, weekDayGroupNumber = day.WeekDayGrpNo, events = events }
  end
  return { serialNumber = serialNumber, days = days }
end

-- ─── Internals ─────────────────────────────────────────────────────────────

--- URL-encode a flat table as application/x-www-form-urlencoded.
--- @param form table<string, string>
--- @return string
function Client:_encodeForm(form)
  local parts = {}
  for k, v in pairs(form) do
    if v ~= nil then
      parts[#parts + 1] = tostring(k) .. "=" .. C4:URLEncode(tostring(v))
    end
  end
  return table.concat(parts, "&")
end

--- Authenticated JSON request: ensure token, attach bearer, decode response.
--- @param method string "GET" | "PUT" | "POST"
--- @param path string e.g. "/api/v1/Thermostat"
--- @param body table|nil JSON body for PUT/POST
--- @return Deferred<table, any>
function Client:_request(method, path, body)
  return self:_ensureToken():next(function(token)
    local d = deferred.new()
    local url = self._apiBase .. path
    local headers = {
      ["Authorization"] = "Bearer " .. token,
      ["Content-Type"] = "application/json",
      ["Accept"] = "application/json",
    }
    local onOk = function(response)
      if response.body == nil or response.body == "" then
        return d:resolve({})
      end
      local ok, decoded = pcall(JSON.decode, JSON, response.body)
      if not ok then
        return d:reject("malformed JSON from " .. path)
      end
      d:resolve(decoded)
    end
    local onErr = function(errorResponse)
      local detail = type(errorResponse) == "table" and errorResponse.error or errorResponse
      d:reject(method .. " " .. path .. " failed: " .. tostring(detail))
    end

    if method == "GET" then
      http:get(url, headers):next(onOk, onErr)
    elseif method == "PUT" then
      http:put(url, JSON:encode(body or {}), headers):next(onOk, onErr)
    else
      http:post(url, JSON:encode(body or {}), headers):next(onOk, onErr)
    end
    return d
  end)
end

return Client
