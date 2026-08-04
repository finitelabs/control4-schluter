-- Schluter DITRA-HEAT thermostat companion driver.
--
-- Presents one Schluter (OJ Microline) floor-heating thermostat as a C4
-- thermostatV2 proxy. It owns no cloud session: the account driver polls the
-- Schluter cloud and hands the raw thermostat object down over the account
-- binding (RFP.updateThermostat / RFP.goOffline); writes go back up as
-- SET_THERMOSTAT commands for the account to POST.
--
-- Writes are optimistic: proxy commands mutate the handed-over object, push the
-- new state to the proxy immediately, and arm a confirm/retry loop that re-POSTs
-- until the slow (and occasionally lossy) Schluter cloud reflects the change or
-- a timeout accepts reality.

--#ifdef DRIVERCENTRAL
DC_PID = 0 -- TODO: Assign DriverCentral product ID
DC_X = nil
DC_FILENAME = "schluter_thermostat.c4z"
--#endif

require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")
require("drivers-common-public.global.url")

JSON = require("JSON")

local log = require("lib.logging")
local Thermostat = require("schluter.thermostat")
local constants = require("constants")

--- thermostatV2 proxy (this driver's primary proxy).
local PROXY_BINDING = 5001
--- Consumer connection bound up to the Schluter account driver.
local ACCOUNT_BINDING = 5002
--- Temperature value output connection.
local TEMP_OUTPUT_BINDING = 5010

--- Set true at the end of OnDriverLateInit, after the boot-time property replay;
--- OPC.Driver_Status re-pins "Initializing" until then.
local gInitialized = false
--- Raw Schluter thermostat object handed over by the account (mutated in place to
--- build the settings we POST back). `nil` until the first handoff.
local gDevice = nil
--- Normalized state derived from gDevice (see schluter.thermostat).
local gState = nil
--- The project's display scale ("C"/"F"), reported by the proxy's SET_SCALE.
--- Schedule setpoints are pushed as integer values in this scale (like the
--- NuHeat Signature driver), matching the editor's grid so they don't drift.
local gScale = "F"

--- Pending optimistic write. Schluter's cloud is slow to reflect changes —
--- especially *leaving* a hold (seconds to tens of seconds) — and occasionally
--- drops a write entirely. After we POST a mode change we remember the intended
--- regulation mode so that (1) handoffs still showing the old mode don't snap the
--- UI back, and (2) a retry loop re-POSTs until the cloud confirms or we give up.
--- @type { mode: integer, ts: integer }|nil
local gPending = nil
--- Stop trusting the optimistic state after this long (cloud won: accept reality).
local CONFIRM_TIMEOUT_S = 60
--- Re-POST an unconfirmed write on this cadence to survive dropped writes.
local RETRY_INTERVAL_S = 12

--- @return boolean
local function isCelsius()
  return tostring(gScale):sub(1, 1):upper() == "C"
end

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
    return Thermostat.fToC(fahrenheit)
  end
  local value = tonumber(tParams.VALUE)
  if value ~= nil then
    local scale = tParams.SCALE or "F"
    if scale == "C" or scale == "c" or scale == "CELSIUS" then
      return value
    end
    return Thermostat.fToC(value)
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
  local caps = Thermostat.capabilities(gState)
  SendToProxy(PROXY_BINDING, "ALLOWED_HVAC_MODES_CHANGED", { MODES = caps.allowedHvacModes }, "NOTIFY")
  -- Populate the hold-modes list; without this the proxy only accepts "Off" and
  -- silently drops "Until Next"/"Permanent" (the static hold_modes cap alone
  -- leaves HOLD_MODES_LIST empty).
  SendToProxy(PROXY_BINDING, "ALLOWED_HOLD_MODES_CHANGED", { MODES = Thermostat.HOLD_MODES }, "NOTIFY")
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
    SETPOINT_HEAT_MIN_F = Thermostat.round(Thermostat.cToF(caps.minSetpointC)),
    SETPOINT_HEAT_MAX_F = Thermostat.round(Thermostat.cToF(caps.maxSetpointC)),
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
  SendToProxy(PROXY_BINDING, "HVAC_MODE_CHANGED", { MODE = Thermostat.hvacMode(gState) }, "NOTIFY")
  SendToProxy(PROXY_BINDING, "HVAC_STATE_CHANGED", { STATE = Thermostat.hvacState(gState) }, "NOTIFY")
  SendToProxy(PROXY_BINDING, "HOLD_MODE_CHANGED", { MODE = Thermostat.holdMode(gState) }, "NOTIFY")
  SendToProxy(TEMP_OUTPUT_BINDING, "VALUE_CHANGED", {
    CELSIUS = tostring(gState.temperatureC),
    FAHRENHEIT = tostring(Thermostat.cToF(gState.temperatureC)),
  })
end

--- Send the mutated Schluter settings object back to the account to write.
local function pushToAccount()
  if gDevice then
    SendToProxy(ACCOUNT_BINDING, constants.CMD.SET_THERMOSTAT, { JSON = JSON:encode(gDevice) })
  end
end

--- Re-POST the intended settings on a timer until the cloud confirms the pending
--- mode change (handled in updateThermostat) or we time out. This is what makes a
--- change actually stick when Schluter drops or is slow to apply the first write.
local function scheduleConfirm()
  SetTimer("SchluterConfirm", RETRY_INTERVAL_S * ONE_SECOND, function()
    if not gPending then
      return
    end
    if (os.time() - gPending.ts) >= CONFIRM_TIMEOUT_S then
      gPending = nil
      return
    end
    pushToAccount()
    scheduleConfirm()
  end)
end

--- Mark the regulation mode we just wrote as pending and arm the confirm/retry
--- loop. Called right after a command POSTs, so the optimistic state survives
--- stale handoffs and dropped writes.
local function markPending()
  if not gDevice then
    return
  end
  gPending = { mode = Thermostat.currentMode(gDevice), ts = os.time() }
  scheduleConfirm()
end

-- ─── Schedule (thermostatV2 schedule proxy ⇄ Schluter Schedules[]) ────────────

--- Heat-only placeholder for the cool column (°C). Schluter never cools, but the
--- proxy's schedule editor still renders a cool setpoint per entry; a 0 there is
--- read as an unset sentinel (0 K ≈ -460 °F). A high value shows sanely and never
--- triggers cooling. 35 °C = 95 °F, the convention other heat-only floor drivers use.
local COOL_PLACEHOLDER_C = 35

--- Notify the proxy of one schedule entry. Following the NuHeat Signature driver
--- (same OJ platform), the setpoint is sent as an integer in the project's
--- display scale with a matching Units field — integer °F + "F", or integer °C +
--- "C" — so it lands on the editor's grid without drifting.
--- @param row table { c4Day, entryIndex, minutes, active, tempC }
local function pushScheduleEntry(row)
  local heat, cool, units
  if isCelsius() then
    heat = Thermostat.round(Thermostat.normalize(row.tempC))
    cool = Thermostat.round(COOL_PLACEHOLDER_C)
    units = "C"
  else
    heat = Thermostat.round(Thermostat.cToF(row.tempC))
    cool = Thermostat.round(Thermostat.cToF(COOL_PLACEHOLDER_C))
    units = "F"
  end
  SendToProxy(PROXY_BINDING, "SCHEDULE_ENTRY_CHANGED", {
    DayIndex = tostring(row.c4Day),
    EntryIndex = tostring(row.entryIndex),
    TimeMinutes = tostring(row.minutes),
    EnabledFlag = row.active and "true" or "false",
    HeatSetpoint = tostring(heat),
    CoolSetpoint = tostring(cool),
    Units = units,
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
  for _, row in ipairs(Thermostat.scheduleEntries(gDevice)) do
    pushScheduleEntry(row)
  end
end

--- Parse an UPDATE_SCHEDULE_ENTRIES command into edit rows. The thermostatV2
--- proxy sends an ENTRIES XML blob of <ScheduleEntryUpdate .../> elements (and,
--- on some versions, flat params). Setpoints arrive in Control4's canonical unit
--- (decikelvin), so convert with Thermostat.c4ToC.
--- @param tParams table
--- @return table[] edits Each `{ day, entry, minutes, enabled, tempC }`.
local function parseScheduleEntries(tParams)
  tParams = tParams or {}
  local edits = {}
  local entriesXml = tParams.ENTRIES
  if type(entriesXml) == "string" and entriesXml ~= "" then
    -- The blob is a bare sequence of elements, so wrap it in a synthetic root.
    local tree = ParseXml("<Entries>" .. entriesXml .. "</Entries>")
    local updates = Select(tree, "Entries", "ScheduleEntryUpdate") or {}
    if updates._attr ~= nil then
      -- xml2lua returns a lone element bare rather than as a one-element list.
      updates = { updates }
    end
    for _, update in ipairs(updates) do
      local a = update._attr or {}
      edits[#edits + 1] = {
        day = tonumber(a.DayOfWeek),
        entry = tonumber(a.EntryIndex),
        minutes = tonumber(a.EntryTime),
        enabled = toboolean(a.IsEnabled),
        tempC = Thermostat.c4ToC(a.HeatSetpoint),
      }
    end
  elseif tParams.DAY_INDEX ~= nil then
    edits[#edits + 1] = {
      day = tonumber(tParams.DAY_INDEX),
      entry = tonumber(tParams.ENTRY_INDEX),
      minutes = tonumber(tParams.ENTRY_TIME),
      enabled = toboolean(tParams.ENABLED),
      tempC = Thermostat.c4ToC(tParams.HEAT_SETPOINT),
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
  -- Reflect the change on the proxy immediately (optimistic). Schluter can take
  -- tens of seconds to apply a change and there may be no handoff until it does,
  -- so without this the UI would sit on the old state (and look like it "didn't
  -- stick"). markPending + the confirm loop keep it from reverting and re-POST.
  gState = Thermostat.fromDevice(gDevice)
  pushToAccount()
  markPending()
  pushState()
end

--- The Schluter datetime for the next scheduled change, used as a temporary
--- (Comfort) hold's end time so a manual override lasts "until next event".
--- @return string|nil
local function nextComfortEndTime()
  if not gDevice then
    return nil
  end
  return Thermostat.nextEventEndTime(gDevice, os.time(), Thermostat.tzOffsetSeconds(gDevice.TZOffset))
end

--- @param idBinding integer
--- @param tParams table
local function handleSetpoint(idBinding, tParams)
  local celsius = getCelsiusFromParams(tParams)
  if celsius == nil then
    return
  end
  applyAndSend(idBinding, function()
    Thermostat.applySetpoint(gDevice, celsius, nextComfortEndTime())
  end)
end

function RFP.SET_SINGLE_SETPOINT(idBinding, _strCommand, tParams)
  log:trace("RFP.SET_SINGLE_SETPOINT(%s)", idBinding)
  handleSetpoint(idBinding, tParams)
end

function RFP.SET_SETPOINT_HEAT(idBinding, _strCommand, tParams)
  log:trace("RFP.SET_SETPOINT_HEAT(%s)", idBinding)
  handleSetpoint(idBinding, tParams)
end

--- Nudge the heat setpoint by one resolution step in the project's display scale
--- (0.5 °C / 1 °F, matching driver.xml), clamped to the device's bounds.
--- @param idBinding integer
--- @param delta integer +1 or -1
local function adjustSetpoint(idBinding, delta)
  if not gState then
    return
  end
  local celsius
  if isCelsius() then
    celsius = gState.setpointC + delta * 0.5
  else
    celsius = Thermostat.fToC(Thermostat.round(Thermostat.cToF(gState.setpointC)) + delta)
  end
  celsius = math.max(gState.minC, math.min(gState.maxC, celsius))
  applyAndSend(idBinding, function()
    Thermostat.applySetpoint(gDevice, celsius, nextComfortEndTime())
  end)
end

function RFP.INC_SETPOINT_HEAT(idBinding)
  log:trace("RFP.INC_SETPOINT_HEAT(%s)", idBinding)
  adjustSetpoint(idBinding, 1)
end

function RFP.DEC_SETPOINT_HEAT(idBinding)
  log:trace("RFP.DEC_SETPOINT_HEAT(%s)", idBinding)
  adjustSetpoint(idBinding, -1)
end

function RFP.SET_MODE_HEAT(idBinding)
  log:trace("RFP.SET_MODE_HEAT(%s)", idBinding)
  applyAndSend(idBinding, function()
    Thermostat.applyHvacMode(gDevice, "Heat", gDevice.MinTemp)
  end)
end

function RFP.SET_MODE_OFF(idBinding)
  log:trace("RFP.SET_MODE_OFF(%s)", idBinding)
  applyAndSend(idBinding, function()
    Thermostat.applyHvacMode(gDevice, "Off", gDevice.MinTemp)
  end)
end

function RFP.SET_MODE_HOLD(idBinding, _strCommand, tParams)
  log:trace("RFP.SET_MODE_HOLD(%s)", tostring((tParams or {}).MODE))
  applyAndSend(idBinding, function()
    Thermostat.applyHold(gDevice, (tParams or {}).MODE, nextComfortEndTime())
  end)
end

--- The proxy reports the project's display scale ("C"/"F"). Track it and re-push
--- the schedule so its setpoints are in that scale (matching the editor grid).
function RFP.SET_SCALE(idBinding, _strCommand, tParams)
  if idBinding ~= PROXY_BINDING then
    return
  end
  local scale = (tParams or {}).SCALE
  if not IsEmpty(scale) then
    gScale = scale
  end
  log:trace("RFP.SET_SCALE(%s)", tostring(gScale))
  gScheduleJson = nil
  pushSchedule()
end

--- Edit one or more schedule entries. Applies each to the device (propagating
--- across the Schluter day-group), notifies the proxy of every affected day, and
--- writes the mutated schedule back through the account. The thermostatV2 proxy
--- sends this as UPDATE_SCHEDULE_ENTRIES (with an ENTRIES XML blob of
--- <ScheduleEntryUpdate .../> elements).
function RFP.UPDATE_SCHEDULE_ENTRIES(idBinding, _strCommand, tParams)
  log:trace("RFP.UPDATE_SCHEDULE_ENTRIES(%s)", idBinding)
  if idBinding ~= PROXY_BINDING or not gDevice then
    return
  end
  local affectedDays = {}
  for _, e in ipairs(parseScheduleEntries(tParams)) do
    if e.day ~= nil and e.entry ~= nil and e.tempC ~= nil then
      local affected = Thermostat.applyScheduleEntry(gDevice, e.day, e.entry, e.minutes or 0, e.enabled, e.tempC)
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
  Thermostat.normalizeSchedule(gDevice)
  gScheduleJson = nil
  for _, row in ipairs(Thermostat.scheduleEntries(gDevice)) do
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
function RFP.updateThermostat(idBinding, _strCommand, tParams)
  log:trace("RFP.updateThermostat(%s)", idBinding)
  local ok, device = pcall(JSON.decode, JSON, (tParams or {}).JSON or "")
  if not ok or type(device) ~= "table" then
    return
  end
  device = device.Thermostat or device
  if gPending and (os.time() - gPending.ts) < CONFIRM_TIMEOUT_S then
    if Thermostat.currentMode(device) == gPending.mode then
      -- Cloud caught up to our write; trust reality from here on.
      gPending = nil
      gDevice = device
    elseif gDevice then
      -- Stale handoff (cloud hasn't applied the write yet, or dropped it). Keep
      -- our intended state so the UI doesn't snap back; only refresh the live
      -- sensor fields. The confirm loop keeps re-POSTing until it takes.
      gDevice.Temperature = device.Temperature
      gDevice.Heating = device.Heating
      gDevice.Online = device.Online
    else
      gDevice = device
    end
  else
    gPending = nil
    gDevice = device
  end
  gState = Thermostat.fromDevice(gDevice)
  C4:UpdateProperty("Serial ID", gState.serialNumber)
  pushCapabilities()
  pushState()
  pushSchedule()
end

--- The thermostat is gone / account logged out.
function RFP.goOffline(idBinding, _strCommand)
  log:trace("RFP.goOffline(%s)", idBinding)
  SendToProxy(PROXY_BINDING, "ONLINE_CHANGED", { STATE = false }, "NOTIFY")
  C4:UpdateProperty("Serial ID", "")
  C4:UpdateProperty("Driver Status", "Offline")
  gDevice, gState, gScheduleJson, gPending = nil, nil, nil, nil
end

-- ─── Property + lifecycle ──────────────────────────────────────────────────

function OPC.Log_Level(propertyValue)
  log:setLogLevel(propertyValue)
  local ultra = log:getLogLevel() >= 6 and log:isPrintEnabled()
  DEBUGPRINT, DEBUG_TIMER, DEBUG_RFN, DEBUG_URL, DEBUG_WEBSOCKET = ultra, ultra, ultra, ultra, ultra
end

function OPC.Log_Mode(propertyValue)
  log:setLogMode(propertyValue)
  CancelTimer("LogMode")
  if not log:isEnabled() then
    return
  end
  SetTimer("LogMode", 3 * ONE_HOUR, function()
    UpdateProperty("Log Mode", "Off", true)
  end)
end

function OPC.Driver_Status(_v)
  if not gInitialized then
    UpdateProperty("Driver Status", "Initializing", false)
  end
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
  gInitialized = false
  log:setLogName(C4:GetDeviceData(C4:GetDeviceID(), "name"))
  log:setLogLevel(Properties["Log Level"])
  log:setLogMode(Properties["Log Mode"])
  log:trace("OnDriverInit()")
end

function OnDriverLateInit()
  log:trace("OnDriverLateInit()")
  if not CheckMinimumVersion("Driver Status") then
    return
  end
  for p, _ in pairs(Properties) do
    local status, err = pcall(OnPropertyChanged, p)
    if not status and err then
      log:error("Error in OnPropertyChanged for property '%s': %s", p, err)
    end
  end
  gInitialized = true
  -- Settle Driver Status now that init is done; the replay above left it at
  -- "Initializing" via the OPC.Driver_Status guard.
  C4:UpdateProperty("Driver Status", "Waiting for thermostat")
  SendToProxy(PROXY_BINDING, "ONLINE_CHANGED", { STATE = false }, "NOTIFY")
end
