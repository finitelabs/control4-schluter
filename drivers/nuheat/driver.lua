--#ifdef DRIVERCENTRAL
-- TODO: assign a DriverCentral product id (DC_PID) before releasing to DC.
DC_PID = nil
DC_X = nil
DC_FILENAME = "nuheat.c4z"
--#endif

require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")
require("drivers-common-public.global.url")

local log = require("lib.logging")
local bindings = require("lib.bindings")
--#ifndef DRIVERCENTRAL
local githubUpdater = require("lib.github-updater")
--#endif
local JSON = require("JSON")

local NuHeatClient = require("nuheat.client")
local constants = require("constants")

local NS = constants.BINDING_NAMESPACE
local CMD = constants.CMD

local client = NuHeatClient:new()

--- Runtime state (not persisted; rebuilt on login).
local gState = {
  sessionId = nil,
  sequenceNr = 0,
  --- serial number -> latest NuHeat thermostat object
  devices = {},
}

-- ─── Companion handoff ─────────────────────────────────────────────────────

--- Push a thermostat's current object to its bound companion (if any).
--- @param serial string
local function handoff(serial)
  local device = gState.devices[serial]
  local binding = bindings:getDynamicBinding(NS, serial)
  if not device or not binding then
    return
  end
  C4:SendToProxy(binding.bindingId, CMD.UPDATE_THERMOSTAT, { JSON = JSON:encode(device) })
end

--- Resolve the serial number behind a dynamic binding id.
--- @param idBinding integer
--- @return string|nil
local function serialForBinding(idBinding)
  for serial, binding in pairs(bindings:getDynamicBindings(NS)) do
    if binding.bindingId == idBinding then
      return serial
    end
  end
  return nil
end

-- ─── Thermostat discovery ──────────────────────────────────────────────────

--- Store a thermostat object, ensure its provider binding exists, and hand it
--- off to any bound companion.
--- @param device table NuHeat thermostat object
local function ingestThermostat(device)
  local serial = tostring(device.SerialNumber)
  if serial == "nil" or serial == "" then
    return
  end
  gState.devices[serial] = device
  bindings:getOrAddDynamicBinding(
    NS,
    serial,
    "PROXY",
    true,
    device.Room or device.GroupName or ("NuHeat " .. serial),
    constants.THERMOSTAT_CLASS
  )
  handoff(serial)
end

--- Fetch the full thermostat list for the account and ingest each.
local function refreshThermostats()
  if not gState.sessionId then
    return
  end
  client:getThermostats(gState.sessionId):next(function(result)
    local list = result.Thermostats or result
    if type(list) ~= "table" then
      return
    end
    for _, device in ipairs(list) do
      ingestThermostat(device)
    end
  end, function(err)
    log:warn("refreshThermostats failed: %s", err)
  end)
end

-- ─── Real-time notification long-poll ──────────────────────────────────────

local armNotifications -- forward declaration

armNotifications = function()
  if not gState.sessionId then
    return
  end
  client:getNotification(gState.sessionId, gState.sequenceNr):next(function(obj)
    if obj and obj.SequenceNr then
      gState.sequenceNr = tonumber(obj.SequenceNr) + 1
    end
    -- A change was reported; re-read state, then re-arm immediately.
    refreshThermostats()
    armNotifications()
  end, function(err)
    log:trace("notification poll ended (%s); re-arming", err)
    C4:SetTimer(5000, armNotifications)
  end)
end

-- ─── Login ─────────────────────────────────────────────────────────────────

local function login()
  local email = Properties["Email"]
  local password = Properties["Password"]
  if not email or email == "" or not password or password == "" then
    C4:UpdateProperty("Login Status", "Enter email and password")
    return
  end
  C4:UpdateProperty("Login Status", "Logging in...")
  client:authenticate(email, password):next(function(sessionId)
    gState.sessionId = sessionId
    gState.sequenceNr = 0
    C4:UpdateProperty("Login Status", "Logged In")
    refreshThermostats()
    armNotifications()
  end, function(err)
    gState.sessionId = nil
    C4:UpdateProperty("Login Status", err.message or "Login failed")
    log:warn("login failed: %s", err.message)
  end)
end

-- ─── Lifecycle ─────────────────────────────────────────────────────────────

function OnDriverInit()
  --#ifdef DRIVERCENTRAL
  require("cloud-client-byte")
  C4:AllowExecute(false)
  --#else
  C4:AllowExecute(true)
  --#endif
  log:setLogName(C4:GetDeviceData(C4:GetDeviceID(), "name"))
  log:setLogLevel(Properties["Log Level"])
  log:setLogMode(Properties["Log Mode"])
  log:trace("OnDriverInit()")
end

function OnDriverLateInit()
  log:trace("OnDriverLateInit()")
  bindings:restoreBindings()
  C4:UpdateProperty("Driver Version", C4:GetDriverConfigInfo("version"))
  --#ifndef DRIVERCENTRAL
  githubUpdater:init()
  --#endif
  login()
end

function OnPropertyChanged(strProperty)
  log:trace("OnPropertyChanged(%s)", strProperty)
  if strProperty == "Log Level" then
    log:setLogLevel(Properties["Log Level"])
  elseif strProperty == "Log Mode" then
    log:setLogMode(Properties["Log Mode"])
  elseif strProperty == "Email" or strProperty == "Password" then
    login()
  end
end

--- A companion bound/unbound to one of our thermostat provider bindings.
function OnBindingChanged(idBinding, strClass, bIsBound)
  log:trace("OnBindingChanged(%s, %s, %s)", idBinding, strClass, bIsBound)
  local serial = serialForBinding(idBinding)
  if not serial then
    return
  end
  if bIsBound then
    handoff(serial)
  end
end

--- Messages from a companion: it pushes mutated settings to write to NuHeat.
function ReceivedFromProxy(idBinding, strCommand, tParams)
  log:trace("ReceivedFromProxy(%s, %s)", idBinding, strCommand)
  tParams = tParams or {}
  local serial = serialForBinding(idBinding)
  if not serial or not gState.sessionId then
    return
  end
  if strCommand == CMD.SET_THERMOSTAT then
    local ok, settings = pcall(JSON.decode, JSON, tParams.JSON or "")
    if not ok or type(settings) ~= "table" then
      return
    end
    client:setThermostat(gState.sessionId, serial, settings):next(function(updated)
      gState.devices[serial] = updated.Thermostat or updated
      handoff(serial)
    end, function(err)
      log:warn("setThermostat failed for %s: %s", serial, err)
    end)
  end
end

-- ─── Actions ───────────────────────────────────────────────────────────────

function LUA_ACTION.Refresh_Thermostats()
  refreshThermostats()
end

function LUA_ACTION.Reset_Driver(tParams)
  if (tParams or {})["Are You Sure?"] == "Yes" then
    bindings:deleteAllBindings(NS)
    gState.devices = {}
    C4:UpdateProperty("Login Status", "")
    login()
  end
end
