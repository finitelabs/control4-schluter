--#ifdef DRIVERCENTRAL
-- TODO: assign a DriverCentral product id (DC_PID) before releasing to DC.
DC_PID = nil
DC_X = nil
DC_FILENAME = "nuheat_thermostat.c4z"
--#endif

require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")
require("drivers-common-public.global.url")

local log = require("lib.logging")
local JSON = require("JSON")

local model = require("nuheat.thermostat")
local constants = require("constants")

--- thermostatV2 proxy (this driver's primary proxy).
local PROXY_BINDING = 5001
--- Consumer connection bound up to the NuHeat account driver.
local ACCOUNT_BINDING = 5002
--- Temperature value output connection.
local TEMP_OUTPUT_BINDING = 5010

--- Raw NuHeat thermostat object handed over by the account (mutated in place to
--- build the settings we POST back). `nil` until the first handoff.
local gDevice = nil
--- Normalized state derived from gDevice (see nuheat.thermostat).
local gState = nil

-- ─── Command param parsing ─────────────────────────────────────────────────

--- Extract a Celsius value from a proxy setpoint command's params.
--- @param tParams table
--- @return number|nil celsius
local function getCelsiusFromParams(tParams)
  tParams = tParams or {}
  local celsius = tonumber(tParams.CELSIUS)
  if celsius ~= nil then
    return celsius
  end
  local fahrenheit = tonumber(tParams.FAHRENHEIT)
  if fahrenheit ~= nil then
    return model.fToC(fahrenheit)
  end
  local value = tonumber(tParams.VALUE)
  if value ~= nil then
    local scale = tParams.SCALE or "F"
    if scale == "C" or scale == "c" or scale == "CELSIUS" then
      return value
    end
    return model.fToC(value)
  end
  return nil
end

-- ─── Push state / capabilities to the thermostat proxy ─────────────────────

--- Advertise the capabilities of the handed device (heat-only single setpoint,
--- per-device bounds). Only what the device supports is advertised.
local function pushCapabilities()
  if not gState then
    return
  end
  local caps = model.capabilities(gState)
  SendToProxy(PROXY_BINDING, "ALLOWED_HVAC_MODES_CHANGED", { MODES = caps.allowedHvacModes }, "NOTIFY")
  SendToProxy(PROXY_BINDING, "DYNAMIC_CAPABILITIES_CHANGED", {
    HAS_SINGLE_SETPOINT = caps.hasSingleSetpoint,
    CAN_HEAT = caps.canHeat,
    CAN_COOL = caps.canCool,
    CAN_AUTO = caps.canAuto,
  }, "NOTIFY")
  SendToProxy(PROXY_BINDING, "DYNAMIC_CAPABILITIES_CHANGED", {
    SETPOINT_SINGLE_MIN_C = caps.minSetpointC,
    SETPOINT_SINGLE_MAX_C = caps.maxSetpointC,
    SETPOINT_SINGLE_MIN_F = model.round(model.cToF(caps.minSetpointC)),
    SETPOINT_SINGLE_MAX_F = model.round(model.cToF(caps.maxSetpointC)),
  }, "NOTIFY")
end

--- Push current temperature / setpoint / mode / state to the proxy (values in
--- Celsius; the proxy converts for the user's display scale).
local function pushState()
  if not gState then
    return
  end
  SendToProxy(PROXY_BINDING, "ONLINE_CHANGED", { STATE = gState.online }, "NOTIFY")
  SendToProxy(PROXY_BINDING, "TEMPERATURE_CHANGED", {
    TEMPERATURE = tostring(gState.temperatureC),
    SCALE = "C",
  }, "NOTIFY")
  SendToProxy(PROXY_BINDING, "SINGLE_SETPOINT_CHANGED", {
    SETPOINT = tostring(gState.setpointC),
    SCALE = "C",
  }, "NOTIFY")
  SendToProxy(PROXY_BINDING, "HVAC_MODE_CHANGED", { MODE = model.hvacMode(gState) }, "NOTIFY")
  SendToProxy(PROXY_BINDING, "HVAC_STATE_CHANGED", { STATE = model.hvacState(gState) }, "NOTIFY")
  SendToProxy(TEMP_OUTPUT_BINDING, "VALUE_CHANGED", {
    CELSIUS = tostring(gState.temperatureC),
    FAHRENHEIT = tostring(model.cToF(gState.temperatureC)),
  })
end

--- Send the mutated NuHeat settings object back to the account to write.
local function pushToAccount()
  if gDevice then
    SendToProxy(ACCOUNT_BINDING, constants.CMD.SET_THERMOSTAT, { JSON = JSON:encode(gDevice) })
  end
end

-- ─── Proxy command handlers (thermostatV2 → NuHeat) ────────────────────────

local function applyAndSend(idBinding, mutate)
  if idBinding ~= PROXY_BINDING or not gDevice then
    return
  end
  mutate()
  pushToAccount()
end

--- @param idBinding integer
--- @param tParams table
local function handleSetpoint(idBinding, tParams)
  local celsius = getCelsiusFromParams(tParams)
  if celsius == nil then
    return
  end
  applyAndSend(idBinding, function()
    model.applySetpoint(gDevice, celsius)
  end)
end

function RFP.SET_SINGLE_SETPOINT(idBinding, strCommand, tParams)
  log:trace("RFP.SET_SINGLE_SETPOINT(%s)", idBinding)
  handleSetpoint(idBinding, tParams)
end

function RFP.SET_SETPOINT_HEAT(idBinding, strCommand, tParams)
  log:trace("RFP.SET_SETPOINT_HEAT(%s)", idBinding)
  handleSetpoint(idBinding, tParams)
end

function RFP.SET_MODE_HEAT(idBinding)
  log:trace("RFP.SET_MODE_HEAT(%s)", idBinding)
  applyAndSend(idBinding, function()
    model.applyHvacMode(gDevice, "Heat", gDevice.MinTemp)
  end)
end

function RFP.SET_MODE_OFF(idBinding)
  log:trace("RFP.SET_MODE_OFF(%s)", idBinding)
  applyAndSend(idBinding, function()
    model.applyHvacMode(gDevice, "Off", gDevice.MinTemp)
  end)
end

-- ─── Account handoff handlers (account → this companion) ────────────────────

--- The account hands over the current NuHeat thermostat object.
function RFP.updateThermostat(idBinding, strCommand, tParams)
  log:trace("RFP.updateThermostat(%s)", idBinding)
  local ok, device = pcall(JSON.decode, JSON, (tParams or {}).JSON or "")
  if not ok or type(device) ~= "table" then
    return
  end
  gDevice = device.Thermostat or device
  gState = model.fromDevice(gDevice)
  C4:UpdateProperty("Serial ID", gState.serialNumber)
  pushCapabilities()
  pushState()
end

--- The thermostat is gone / account logged out.
function RFP.goOffline(idBinding, strCommand)
  log:trace("RFP.goOffline(%s)", idBinding)
  SendToProxy(PROXY_BINDING, "ONLINE_CHANGED", { STATE = false }, "NOTIFY")
  C4:UpdateProperty("Serial ID", "")
  gDevice, gState = nil, nil
end

-- ─── Property + lifecycle ──────────────────────────────────────────────────

function OPC.Log_Level(propertyValue)
  log:setLogLevel(propertyValue)
end

function OPC.Log_Mode(propertyValue)
  log:setLogMode(propertyValue)
end

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
  C4:UpdateProperty("Driver Version", C4:GetDriverConfigInfo("version"))
  SendToProxy(PROXY_BINDING, "ONLINE_CHANGED", { STATE = false }, "NOTIFY")
end
