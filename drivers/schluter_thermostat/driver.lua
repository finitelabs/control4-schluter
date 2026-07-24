--#ifdef DRIVERCENTRAL
-- TODO: assign a DriverCentral product id (DC_PID) before releasing to DC.
DC_PID = nil
DC_X = nil
DC_FILENAME = "schluter_thermostat.c4z"
--#endif

require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")
require("drivers-common-public.global.url")

local log = require("lib.logging")
local JSON = require("JSON")

local model = require("schluter.thermostat")
local constants = require("constants")

--- thermostatV2 proxy (this driver's primary proxy).
local PROXY_BINDING = 5001
--- Consumer connection bound up to the Schluter account driver.
local ACCOUNT_BINDING = 5002
--- Temperature value output connection.
local TEMP_OUTPUT_BINDING = 5010

--- Raw Schluter thermostat object handed over by the account (mutated in place to
--- build the settings we POST back). `nil` until the first handoff.
local gDevice = nil
--- Normalized state derived from gDevice (see schluter.thermostat).
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
  -- Heat setpoint bounds (heat-setpoint model). Static bounds also come from
  -- driver.xml; send the device's actual range so it tracks the thermostat.
  SendToProxy(PROXY_BINDING, "DYNAMIC_CAPABILITIES_CHANGED", {
    SETPOINT_HEAT_MIN_C = caps.minSetpointC,
    SETPOINT_HEAT_MAX_C = caps.maxSetpointC,
    SETPOINT_HEAT_MIN_F = model.round(model.cToF(caps.minSetpointC)),
    SETPOINT_HEAT_MAX_F = model.round(model.cToF(caps.maxSetpointC)),
  }, "NOTIFY")
end

--- Push current temperature / setpoint / mode / state to the proxy (values in
--- Celsius; the proxy converts for the user's display scale).
local function pushState()
  if not gState then
    return
  end
  C4:UpdateProperty("Driver Status", gState.online and "Online" or "Offline")
  SendToProxy(PROXY_BINDING, "ONLINE_CHANGED", { STATE = gState.online }, "NOTIFY")
  SendToProxy(PROXY_BINDING, "TEMPERATURE_CHANGED", {
    TEMPERATURE = tostring(gState.temperatureC),
    SCALE = "C",
  }, "NOTIFY")
  SendToProxy(PROXY_BINDING, "HEAT_SETPOINT_CHANGED", {
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

--- Send the mutated Schluter settings object back to the account to write.
local function pushToAccount()
  if gDevice then
    SendToProxy(ACCOUNT_BINDING, constants.CMD.SET_THERMOSTAT, { JSON = JSON:encode(gDevice) })
  end
end

-- ─── Schedule (thermostatV2 schedule proxy ⇄ Schluter Schedules[]) ────────────

--- Heat-only placeholder for the cool column (°C). Schluter never cools, but the
--- proxy's schedule editor still renders a cool setpoint per entry; a 0 there is
--- read as an unset sentinel (0 K ≈ -460 °F). A high value shows sanely and never
--- triggers cooling. 35 °C = 95 °F, the convention other heat-only floor drivers use.
local COOL_PLACEHOLDER_C = 35

--- Notify the proxy of one schedule entry. The thermostatV2 schedule channel
--- takes setpoints as °C×10 (deci-Celsius) with no Units field — the same unit
--- the schedule_default template uses (278 → 27.8 °C → 82 °F). Verified against
--- the proxy's SCHEDULE variable: other forms are mis-read — a plain °C value
--- with Units="C" is integer-truncated (27.78 → 27), and a bare value with no
--- Units is read as °C×10, so decikelvin (3009) clamps to the 158 °F max.
--- @param row table { c4Day, entryIndex, minutes, active, tempC }
local function pushScheduleEntry(row)
  SendToProxy(PROXY_BINDING, "SCHEDULE_ENTRY_CHANGED", {
    DayIndex = tostring(row.c4Day),
    EntryIndex = tostring(row.entryIndex),
    TimeMinutes = tostring(row.minutes),
    EnabledFlag = row.active and "true" or "false",
    HeatSetpoint = tostring(model.round(row.tempC * 10)),
    CoolSetpoint = tostring(model.round(COOL_PLACEHOLDER_C * 10)),
  }, "NOTIFY")
end

--- Serialization of the last schedule pushed to the proxy, so unchanged handoffs
--- (which arrive on every notification poll) don't re-emit all 28 entries.
local gScheduleJson = nil

--- Push the whole schedule to the proxy (on handoff / state update), but only
--- when it differs from the last one pushed.
local function pushSchedule()
  if not gDevice or type(gDevice.Schedules) ~= "table" then
    return
  end
  local json = JSON:encode(gDevice.Schedules)
  if json == gScheduleJson then
    return
  end
  gScheduleJson = json
  for _, row in ipairs(model.scheduleEntries(gDevice)) do
    pushScheduleEntry(row)
  end
end

--- Parse an UPDATE_SCHEDULE_ENTRIES command into edit rows. The thermostatV2
--- proxy sends an ENTRIES XML blob of <ScheduleEntryUpdate .../> elements (and,
--- on some versions, flat params). Setpoints arrive in Control4's canonical unit
--- (decikelvin), so convert with model.c4ToC.
--- @param tParams table
--- @return table[] edits Each `{ day, entry, minutes, enabled, tempC }`.
local function parseScheduleEntries(tParams)
  tParams = tParams or {}
  local edits = {}
  local entriesXml = tParams.ENTRIES
  if type(entriesXml) == "string" and entriesXml ~= "" then
    for attrs in entriesXml:gmatch("<ScheduleEntryUpdate(.-)/?>") do
      local function attr(name)
        return attrs:match(name .. '%s*=%s*"([^"]*)"')
      end
      edits[#edits + 1] = {
        day = tonumber(attr("DayOfWeek")),
        entry = tonumber(attr("EntryIndex")),
        minutes = tonumber(attr("EntryTime")),
        enabled = tostring(attr("IsEnabled")):lower() == "true",
        tempC = model.c4ToC(attr("HeatSetpoint")),
      }
    end
  elseif tParams.DAY_INDEX ~= nil then
    edits[#edits + 1] = {
      day = tonumber(tParams.DAY_INDEX),
      entry = tonumber(tParams.ENTRY_INDEX),
      minutes = tonumber(tParams.ENTRY_TIME),
      enabled = toboolean(tParams.ENABLED),
      tempC = model.c4ToC(tParams.HEAT_SETPOINT),
    }
  end
  return edits
end

-- ─── Proxy command handlers (thermostatV2 → Schluter) ────────────────────────

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

--- The proxy reports the project's display scale ("C"/"F"). Setpoints are pushed
--- as scale-absolute decikelvin, so no conversion is needed; just re-push the
--- schedule so it repaints promptly when the display scale changes.
function RFP.SET_SCALE(idBinding, strCommand, tParams)
  log:trace("RFP.SET_SCALE(%s)", tostring((tParams or {}).SCALE))
  gScheduleJson = nil
  pushSchedule()
end

--- Edit one or more schedule entries. Applies each to the device (propagating
--- across the Schluter day-group), notifies the proxy of every affected day, and
--- writes the mutated schedule back through the account. The thermostatV2 proxy
--- sends this as UPDATE_SCHEDULE_ENTRIES (with an ENTRIES XML blob of
--- <ScheduleEntryUpdate .../> elements).
function RFP.UPDATE_SCHEDULE_ENTRIES(idBinding, strCommand, tParams)
  log:trace("RFP.UPDATE_SCHEDULE_ENTRIES(%s)", idBinding)
  if idBinding ~= PROXY_BINDING or not gDevice then
    return
  end
  local affectedDays = {}
  for _, e in ipairs(parseScheduleEntries(tParams)) do
    if e.day ~= nil and e.entry ~= nil and e.tempC ~= nil then
      local affected = model.applyScheduleEntry(gDevice, e.day, e.entry, e.minutes or 0, e.enabled, e.tempC)
      for _, c4Day in ipairs(affected) do
        affectedDays[c4Day] = true
      end
    end
  end
  if next(affectedDays) == nil then
    return
  end
  -- Keep each day's six events ordered by time (renumbering ScheduleType) so an
  -- edit always maps back to the correct Schluter event, then re-push every
  -- affected day in full so the C4 editor reflects the sorted order.
  model.normalizeSchedule(gDevice)
  gScheduleJson = nil
  for _, row in ipairs(model.scheduleEntries(gDevice)) do
    if affectedDays[row.c4Day] then
      pushScheduleEntry(row)
    end
  end
  pushToAccount()
end

--- Alias: some proxy/OS versions send the singular command name.
RFP.SCHEDULE_ENTRY = RFP.UPDATE_SCHEDULE_ENTRIES

-- ─── Account handoff handlers (account → this companion) ────────────────────

--- The account hands over the current Schluter thermostat object.
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
  pushSchedule()
end

--- The thermostat is gone / account logged out.
function RFP.goOffline(idBinding, strCommand)
  log:trace("RFP.goOffline(%s)", idBinding)
  SendToProxy(PROXY_BINDING, "ONLINE_CHANGED", { STATE = false }, "NOTIFY")
  C4:UpdateProperty("Serial ID", "")
  C4:UpdateProperty("Driver Status", "Offline")
  gDevice, gState, gScheduleJson = nil, nil, nil
end

-- ─── Property + lifecycle ──────────────────────────────────────────────────

function OPC.Log_Level(propertyValue)
  log:setLogLevel(propertyValue)
end

function OPC.Log_Mode(propertyValue)
  log:setLogMode(propertyValue)
end

function OPC.Driver_Version()
  C4:UpdateProperty("Driver Version", C4:GetDriverConfigInfo("version"))
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
  C4:UpdateProperty("Driver Status", "Waiting for thermostat")
  SendToProxy(PROXY_BINDING, "ONLINE_CHANGED", { STATE = false }, "NOTIFY")
end
