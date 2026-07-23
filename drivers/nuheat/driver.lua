--#ifdef DRIVERCENTRAL
-- TODO: assign a DriverCentral product id (DC_PID) before releasing to DC.
DC_PID = nil
DC_X = nil
DC_FILENAME = "nuheat.c4z"
--#endif

--#ifndef DRIVERCENTRAL
DRIVER_GITHUB_REPO = "finitelabs/control4-nuheat"
DRIVER_FILENAMES = {
  "nuheat.c4z",
  "nuheat_thermostat.c4z",
}
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
  --- @type string|nil
  sessionId = nil,
  --- @type number
  sequenceNr = 0,
  --- @type table<string, table> serial number -> latest NuHeat thermostat object
  devices = {},
}

--- Set true once OnDriverLateInit finishes; guards the property-sync handlers
--- from firing while Composer loads the initial property values.
local gInitialized = false

--- All nuheat account instances on this controller, sorted by device id. Used
--- for leader election (lowest id is the leader that runs updates).
--- @return integer[]
local function getAccountDriverIds()
  local drivers = C4:GetDevicesByC4iName(C4:GetDriverFileName()) or {}
  local ids = {}
  for id in pairs(drivers) do
    ids[#ids + 1] = tonumber(id)
  end
  table.sort(ids)
  return ids
end

--#ifndef DRIVERCENTRAL
--- Mirror an updater property to the other account instances so they stay
--- consistent (only the leader instance actually performs updates).
--- @param propertyName string
--- @param propertyValue string
local function syncPropertyToOtherInstances(propertyName, propertyValue)
  local myId = C4:GetDeviceID()
  for _, deviceId in ipairs(getAccountDriverIds()) do
    if deviceId ~= myId then
      SetDeviceProperties(deviceId, { [propertyName] = propertyValue }, true)
    end
  end
end
--#endif

-- ─── Companion handoff ─────────────────────────────────────────────────────

--- Push a thermostat's current object to its bound companion (if any).
--- @param serial string
local function handoff(serial)
  local device = gState.devices[serial]
  local binding = bindings:getDynamicBinding(NS, serial)
  if not device or not binding then
    return
  end
  SendToProxy(binding.bindingId, CMD.UPDATE_THERMOSTAT, { JSON = JSON:encode(device) })
end

--- Resolve the serial number behind a dynamic binding id.
--- @param idBinding integer
--- @return string|nil serial
local function serialForBinding(idBinding)
  for serial, binding in pairs(bindings:getDynamicBindings(NS)) do
    if binding.bindingId == idBinding then
      return serial
    end
  end
  return nil
end

-- ─── Thermostat discovery ──────────────────────────────────────────────────

--- Store a thermostat object, ensure its provider binding exists, register a
--- bind handler that (re)hands the device off when a companion connects, and
--- push the current state to any companion already bound.
--- @param device table NuHeat thermostat object
local function ingestThermostat(device)
  local serial = tostring(device.SerialNumber)
  if serial == "nil" or serial == "" then
    return
  end
  gState.devices[serial] = device
  local binding = bindings:getOrAddDynamicBinding(
    NS,
    serial,
    "PROXY",
    true,
    device.Room or device.GroupName or ("NuHeat " .. serial),
    constants.THERMOSTAT_CLASS
  )
  if binding then
    -- OnBindingChanged is dispatched per binding id (see OBC in handlers.lua):
    -- hand off the current device whenever a companion binds.
    OBC[binding.bindingId] = function(_idBinding, _strClass, bIsBound)
      if bIsBound then
        handoff(serial)
      end
    end
  end
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

--- @type fun(): void
local armNotifications

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
    SetTimer("NuHeatNotify", 5 * ONE_SECOND, armNotifications)
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

--#ifndef DRIVERCENTRAL
--- Update the driver(s) from the GitHub repository.
--- @param forceUpdate? boolean Force the update even if already up to date.
local function updateDrivers(forceUpdate)
  log:trace("updateDrivers(%s)", forceUpdate)
  githubUpdater
    :updateAll(DRIVER_GITHUB_REPO, DRIVER_FILENAMES, Properties["Update Channel"] == "Prerelease", forceUpdate)
    :next(function(updatedDrivers)
      if updatedDrivers and #updatedDrivers > 0 then
        log:info("Updated driver(s): %s", table.concat(updatedDrivers, ","))
      end
    end, function(err)
      log:warn("driver update failed: %s", err)
    end)
end
--#endif

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
  login()
  --#ifndef DRIVERCENTRAL
  -- Auto-update: only the leader account instance checks, at most every 30 min,
  -- and only when Automatic Updates is On. The DriverCentral build lets
  -- cloud-client-byte own updates instead.
  SetTimer("AutoUpdate", 30 * ONE_MINUTE, function()
    local isLeader = Select(getAccountDriverIds(), 1) == C4:GetDeviceID()
    if isLeader and toboolean(Properties["Automatic Updates"]) then
      log:info("Checking for driver update (leader instance)")
      updateDrivers()
    end
  end, true)
  --#endif
  gInitialized = true
end

-- ─── Property handlers (OPC dispatch) ──────────────────────────────────────

function OPC.Log_Level(propertyValue)
  log:setLogLevel(propertyValue)
end

function OPC.Log_Mode(propertyValue)
  log:setLogMode(propertyValue)
end

function OPC.Email()
  login()
end

function OPC.Password()
  login()
end

function OPC.Automatic_Updates(propertyValue)
  --#ifndef DRIVERCENTRAL
  if not gInitialized then
    return
  end
  syncPropertyToOtherInstances("Automatic Updates", propertyValue)
  --#endif
end

--#ifndef DRIVERCENTRAL
function OPC.Update_Channel(propertyValue)
  if not gInitialized then
    return
  end
  syncPropertyToOtherInstances("Update Channel", propertyValue)
end
--#endif

-- ─── Messages from a companion (RFP dispatch) ──────────────────────────────

--- A companion pushes mutated settings for us to write to NuHeat.
--- @param idBinding integer
--- @param strCommand string
--- @param tParams table
function RFP.setThermostat(idBinding, strCommand, tParams)
  log:trace("RFP.setThermostat(%s)", idBinding)
  local serial = serialForBinding(idBinding)
  if not serial or not gState.sessionId then
    return
  end
  local ok, settings = pcall(JSON.decode, JSON, (tParams or {}).JSON or "")
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

-- ─── Actions (EC dispatch) ─────────────────────────────────────────────────

function EC.Refresh_Thermostats()
  log:trace("EC.Refresh_Thermostats()")
  refreshThermostats()
end

function EC.Reset_Driver(tParams)
  log:trace("EC.Reset_Driver()")
  if (tParams or {})["Are You Sure?"] == "Yes" then
    bindings:deleteAllBindings(NS)
    gState.devices = {}
    C4:UpdateProperty("Login Status", "")
    login()
  end
end

--#ifndef DRIVERCENTRAL
function EC.Update_Drivers()
  log:trace("EC.Update_Drivers()")
  updateDrivers(true)
end
--#endif
