--- Schluter thermostat state model + Control4 translation helpers.
---
--- Pure logic (no C4/HTTP side effects) so it is unit-testable: temperature
--- scaling between Schluter's wire format and Celsius/Fahrenheit, ScheduleMode ↔
--- HVAC/hold mapping, capability derivation from a device object, and building
--- the `settings` object POSTed back to myschluter.com. Used by the companion
--- (schluter_thermostat) driver. See docs/schluter-api-reference.md.

local M = {}

--- Schluter wire temperatures are Celsius × 100 (hundredths of a degree C).
local SCHLUTER_SCALE = 100
--- ScheduleMode enum used by the Schluter API.
M.MODE = { AUTO = 1, UNTIL = 2, PERMANENT = 3 }
--- Away/Off is encoded as Permanent hold at the 5.00 °C minimum (== 500).
M.OFF_SENTINEL = 500
--- Setpoint bounds (Schluter DITRA-HEAT): 5–70 °C / 41–158 °F.
M.MIN_C, M.MAX_C = 5, 70
--- Setpoints that differ by less than this (°C) are treated as unchanged when
--- writing a schedule entry back, so °F↔°C display rounding can't drift the
--- device's stored value. Below a 1 °F (≈0.56 °C) and a 0.5 °C step.
M.SETPOINT_EPSILON_C = 0.28

-- ─── Temperature conversion ────────────────────────────────────────────────

--- @param n number Schluter wire value (°C × 100)
--- @return number|nil celsius
function M.schluterToC(n)
  local v = tonumber(n)
  if v == nil then
    return nil
  end
  return v / SCHLUTER_SCALE
end

--- @param c number Celsius
--- @return number schluter wire value (°C × 100, rounded)
function M.cToSchluter(c)
  return M.round(tonumber(c) * SCHLUTER_SCALE)
end

--- @param c number Celsius
--- @return number fahrenheit
function M.cToF(c)
  return c * 9 / 5 + 32
end

--- @param f number Fahrenheit
--- @return number celsius
function M.fToC(f)
  return (f - 32) * 5 / 9
end

--- Control4's canonical temperature unit is decikelvin: (°C + 273.15) × 10.
--- The thermostatV2 proxy sends schedule-entry setpoints in this unit.
M.KELVIN_OFFSET = 273.15

--- Convert a Control4 canonical temperature (decikelvin) to Celsius.
--- @param value number
--- @return number|nil celsius
function M.c4ToC(value)
  local n = tonumber(value)
  if n == nil then
    return nil
  end
  return n / 10 - M.KELVIN_OFFSET
end

--- Convert Celsius to Control4 canonical temperature (decikelvin).
--- @param c number
--- @return number decikelvin
function M.cToC4(c)
  return M.round((tonumber(c) + M.KELVIN_OFFSET) * 10)
end

--- Round half-up to `idp` decimal places (default 0).
--- @param num number
--- @param idp integer|nil
--- @return number
function M.round(num, idp)
  local mult = 10 ^ (idp or 0)
  return math.floor(tonumber(num) * mult + 0.5) / mult
end

--- Snap a temperature to the nearest 0.5° (Schluter setpoint resolution).
--- @param temp number
--- @return number
function M.normalize(temp)
  local t = tonumber(temp)
  local r = t % 0.5
  if r > 0.25 then
    return t + (0.5 - r)
  end
  return t - r
end

-- ─── Device object → normalized state ──────────────────────────────────────

--- @class SchluterState
--- @field serialNumber string
--- @field online boolean
--- @field room string
--- @field temperatureC number Current floor temperature, °C
--- @field setpointC number Active setpoint, °C
--- @field heating boolean HVAC actively heating
--- @field scheduleMode integer Schluter ScheduleMode (1/2/3)
--- @field minC number
--- @field maxC number
--- @field hasSchedule boolean
--- @field isOff boolean Away/Off (permanent hold at minimum)

--- Normalize a raw Schluter thermostat object (bare or `{Thermostat=...}`).
--- @param object table
--- @return SchluterState
function M.fromDevice(object)
  local v = object.Thermostat or object
  -- Schluter uses RegulationMode; Schluter uses ScheduleMode (same 1/2/3 enum).
  local scheduleMode = tonumber(v.RegulationMode or v.ScheduleMode)
  local setpoint = tonumber(v.SetPointTemp)
  return {
    serialNumber = tostring(v.SerialNumber),
    online = v.Online == true,
    room = v.Room or v.GroupName or "",
    temperatureC = M.schluterToC(v.Temperature),
    setpointC = M.schluterToC(setpoint),
    heating = v.Heating == true,
    scheduleMode = scheduleMode,
    minC = v.MinTemp and M.schluterToC(v.MinTemp) or M.MIN_C,
    maxC = v.MaxTemp and M.schluterToC(v.MaxTemp) or M.MAX_C,
    hasSchedule = type(v.Schedules) == "table" and #v.Schedules > 0,
    isOff = scheduleMode == M.MODE.PERMANENT and setpoint == M.OFF_SENTINEL,
  }
end

-- ─── Capability derivation (for the thermostat proxy) ───────────────────────

--- Derive the Control4 thermostat-proxy capabilities from device state. Schluter
--- is heat-only with a single setpoint, so CAN_* are false per the C4 rule that
--- they must be false when HAS_SINGLE_SETPOINT is true. Only advertises what the
--- handed device actually reports (e.g. schedule).
--- @param state SchluterState
--- @return table capabilities
function M.capabilities(state)
  return {
    allowedHvacModes = "Off,Heat",
    -- Heat-setpoint model (like the original NuHeat driver): a single Heat
    -- setpoint, not the single_setpoint model. The C4 schedule editor only lets
    -- you pick a temperature in the heat-setpoint model.
    hasSingleSetpoint = false,
    canHeat = true,
    canCool = false,
    canAuto = false,
    minSetpointC = state.minC,
    maxSetpointC = state.maxC,
    hasSchedule = state.hasSchedule,
  }
end

--- HVAC state string for the C4 proxy: "Heat" while heating, else "Off".
--- @param state SchluterState
--- @return string
function M.hvacState(state)
  return state.heating and "Heat" or "Off"
end

--- HVAC mode for the C4 proxy: "Off" when in Away/Off, otherwise "Heat".
--- @param state SchluterState
--- @return string
function M.hvacMode(state)
  return state.isOff and "Off" or "Heat"
end

--- The C4 hold modes this driver advertises, mapped to Schluter's RegulationMode.
--- Schluter's Comfort (2) is a temporary hold until the next scheduled change
--- ("Until Next"); Manual (3) is a permanent hold; Auto (1)/Away is no hold.
M.HOLD_MODES = "Off,Until Next,Permanent"

--- C4 hold mode from device state.
--- @param state SchluterState
--- @return string
function M.holdMode(state)
  if state.scheduleMode == M.MODE.UNTIL then
    return "Until Next"
  elseif state.scheduleMode == M.MODE.PERMANENT and not state.isOff then
    return "Permanent"
  end
  return "Off"
end

-- ─── Settings builders (Control4 → Schluter POST body) ───────────────────────

--- The device's current regulation mode. Schluter uses `RegulationMode`; NuHeat
--- uses `ScheduleMode` (same 1/2/3 enum). Read whichever is present.
--- @param settings table
--- @return integer|nil
function M.currentMode(settings)
  return tonumber(settings.RegulationMode or settings.ScheduleMode)
end

--- Set the regulation mode on both fields so either backend honors it. Schluter
--- reads `RegulationMode` (setting only `ScheduleMode` is silently ignored, so
--- the device keeps following its schedule and the setpoint never holds).
--- @param settings table
--- @param mode integer
local function setMode(settings, mode)
  settings.RegulationMode = mode
  settings.ScheduleMode = mode
end

--- Write the held setpoint onto the field the given mode actually reads: Manual
--- (permanent) regulates to ManualTemperature, Comfort (temporary) regulates to
--- ComfortTemperature. SetPointTemp is set too (it mirrors the active setpoint).
--- @param settings table
--- @param schluter number setpoint in Schluter units (°C×100)
--- @param mode integer
local function setHeldTemp(settings, schluter, mode)
  settings.SetPointTemp = schluter
  if mode == M.MODE.PERMANENT then
    settings.ManualTemperature = schluter
  elseif mode == M.MODE.UNTIL then
    settings.ComfortTemperature = schluter
  end
end

--- Set the heat setpoint (°C). Enters a temporary Comfort hold until the next
--- scheduled change, unless the thermostat is already in a permanent (Manual)
--- hold — in which case the permanent hold is kept at the new temperature.
--- @param settings table Current Schluter settings object (mutated + returned).
--- @param celsius number
--- @param comfortEndTime string|nil Schluter datetime for the Comfort hold end.
--- @return table settings
function M.applySetpoint(settings, celsius, comfortEndTime)
  local schluter = M.cToSchluter(M.normalize(celsius))
  local mode = M.currentMode(settings) == M.MODE.PERMANENT and M.MODE.PERMANENT or M.MODE.UNTIL
  setHeldTemp(settings, schluter, mode)
  if mode == M.MODE.UNTIL and comfortEndTime then
    settings.ComfortEndTime = comfortEndTime
  end
  setMode(settings, mode)
  return settings
end

--- C4 hold-mode string -> regulation mode. "Off" resumes the schedule (Auto);
--- "Until Next" is a temporary Comfort hold; "Permanent" is a Manual hold.
M.HOLD_TO_MODE = {
  ["Off"] = M.MODE.AUTO,
  ["Until Next"] = M.MODE.UNTIL,
  ["Permanent"] = M.MODE.PERMANENT,
}

--- Apply a C4 hold-mode change to the device, holding the current setpoint on
--- the field the target mode reads.
--- @param settings table
--- @param c4HoldMode string
--- @param comfortEndTime string|nil Schluter datetime for a Comfort hold end.
--- @return table settings
function M.applyHold(settings, c4HoldMode, comfortEndTime)
  local mode = M.HOLD_TO_MODE[c4HoldMode]
  if mode then
    if mode ~= M.MODE.AUTO then
      setHeldTemp(settings, tonumber(settings.SetPointTemp), mode)
      if mode == M.MODE.UNTIL and comfortEndTime then
        settings.ComfortEndTime = comfortEndTime
      end
    end
    setMode(settings, mode)
  end
  return settings
end

--- Parse a Schluter TZ offset ("±HH:MM") into seconds east of UTC.
--- @param tz string|nil
--- @return integer
function M.tzOffsetSeconds(tz)
  local sign, h, m = tostring(tz):match("([%+%-])(%d+):(%d+)")
  if not sign then
    return 0
  end
  local secs = tonumber(h) * 3600 + tonumber(m) * 60
  return sign == "-" and -secs or secs
end

--- Next enabled schedule event as a Schluter UTC datetime string
--- ("dd/MM/yyyy HH:MM:SS +00:00"), for a Comfort hold's ComfortEndTime ("until
--- the next scheduled change"). Returns nil if there is no schedule.
--- @param device table
--- @param nowUtc integer current UTC epoch (os.time())
--- @param tzOffsetSec integer device offset east of UTC, seconds
--- @return string|nil
function M.nextEventEndTime(device, nowUtc, tzOffsetSec)
  local schedules = (device or {}).Schedules
  if type(schedules) ~= "table" then
    return nil
  end
  -- Read (nowUtc + offset) as if UTC to get the device's local wall clock.
  local localEpoch = nowUtc + tzOffsetSec
  local lt = os.date("!*t", localEpoch)
  local nowMin = lt.hour * 60 + lt.min
  local midnightLocal = localEpoch - nowMin * 60 - lt.sec
  -- Lua wday 1=Sun..7=Sat -> Schluter schedule index 1=Mon..7=Sun.
  local luaToSchluter = { [1] = 7, [2] = 1, [3] = 2, [4] = 3, [5] = 4, [6] = 5, [7] = 6 }
  for dayAhead = 0, 7 do
    local wday = ((lt.wday - 1 + dayAhead) % 7) + 1
    local sched = schedules[luaToSchluter[wday]]
    if sched and type(sched.Events) == "table" then
      for _, event in ipairs(sched.Events) do
        local em = M.clockToMinutes(event.Clock)
        if event.Active == true and (dayAhead > 0 or em > nowMin) then
          local eventUtc = midnightLocal + dayAhead * 86400 + em * 60 - tzOffsetSec
          return os.date("!%d/%m/%Y %H:%M:%S +00:00", eventUtc)
        end
      end
    end
  end
  return nil
end

--- Set HVAC mode. "Heat" resumes the schedule (Auto); "Off" is a permanent hold
--- at the device minimum (Away).
--- @param settings table
--- @param mode string "Heat" | "Off"
--- @param minTempSchluter number Device MinTemp in Schluter units (°C×100).
--- @return table settings
function M.applyHvacMode(settings, mode, minTempSchluter)
  if mode == "Off" then
    -- Away/Off is a permanent (Manual) hold at the device minimum. Schluter's
    -- Manual mode regulates to ManualTemperature and recomputes SetPointTemp from
    -- it, so both must be written or the setpoint springs back and Off is lost.
    setHeldTemp(settings, minTempSchluter or M.OFF_SENTINEL, M.MODE.PERMANENT)
    setMode(settings, M.MODE.PERMANENT)
  else
    setMode(settings, M.MODE.AUTO)
  end
  return settings
end

-- ─── Schedule model (Control4 thermostatV2 ⇄ Schluter Schedules[]) ────────────
--
-- Schluter `device.Schedules` is a 7-element array indexed by Schluter day
-- (1=Mon .. 7=Sun). Each entry = `{ WeekDayGrpNo, Events[1..6] }`, each event =
-- `{ Clock "HH:MM:SS", ScheduleType, TempFloor (°C×100), Active }`. Days sharing
-- a `WeekDayGrpNo` share one program, so editing one propagates to the whole
-- group — matching the Schluter thermostat's own grouping behavior (and the old
-- driver). Control4's thermostatV2 schedule is per-day (DayIndex 0=Sun .. 6=Sat)
-- with EntryIndex 0..5, mapped 1:1 to the device's 6 events. Heat-only.

--- Schluter schedule array index (1=Mon..7=Sun) -> C4 DayIndex (0=Sun..6=Sat).
M.SCHLUTER_TO_C4_DAY = { 1, 2, 3, 4, 5, 6, 0 }
--- C4 DayIndex (0=Sun..6=Sat) -> Schluter schedule array index (1=Mon..7=Sun).
M.C4_TO_SCHLUTER_DAY = { [0] = 7, [1] = 1, [2] = 2, [3] = 3, [4] = 4, [5] = 5, [6] = 6 }
--- Events per day in the Schluter DITRA-HEAT schedule; the proxy exposes the same
--- number of schedule slots (declared in driver.xml schedule_default).
M.SCHEDULE_ENTRIES_PER_DAY = 6

--- Parse "HH:MM:SS" (or "HH:MM") into minutes since midnight.
--- @param clock string
--- @return integer minutes
function M.clockToMinutes(clock)
  local h, m = tostring(clock):match("(%d+):(%d+)")
  if not h then
    return 0
  end
  return tonumber(h) * 60 + tonumber(m)
end

--- Format minutes since midnight as "HH:MM:SS".
--- @param minutes number
--- @return string
function M.minutesToClock(minutes)
  local mins = math.floor(tonumber(minutes) or 0)
  local h = math.floor(mins / 60) % 24
  return string.format("%02d:%02d:00", h, mins % 60)
end

--- Flatten a device's Schedules[] into per-(day, entry) rows for the C4 proxy.
--- @param device table Schluter thermostat object
--- @return table[] rows Each `{ c4Day, entryIndex, minutes, active, tempC }`.
function M.scheduleEntries(device)
  local rows = {}
  local schedules = (device or {}).Schedules
  if type(schedules) ~= "table" then
    return rows
  end
  for schluterDay, schedule in ipairs(schedules) do
    local c4Day = M.SCHLUTER_TO_C4_DAY[schluterDay]
    if c4Day ~= nil and type(schedule.Events) == "table" then
      -- Schluter has 6 events/day, mapped 1:1 to the proxy's 6 schedule slots.
      for entryIndex, event in ipairs(schedule.Events) do
        rows[#rows + 1] = {
          c4Day = c4Day,
          entryIndex = entryIndex - 1,
          minutes = M.clockToMinutes(event.Clock),
          active = event.Active == true,
          tempC = M.schluterToC(event.TempFloor),
        }
      end
    end
  end
  return rows
end

--- Apply one Control4 schedule-entry edit to the device, propagating to every day
--- sharing the edited day's WeekDayGrpNo. Mutates `device.Schedules` in place and
--- preserves each event's existing ScheduleType.
--- @param device table
--- @param c4Day integer 0=Sun..6=Sat
--- @param entryIndex integer 0..3
--- @param minutes number time since midnight
--- @param active boolean
--- @param tempC number heat setpoint, °C
--- @return integer[] affectedC4Days C4 day indices that changed (for notifications)
function M.applyScheduleEntry(device, c4Day, entryIndex, minutes, active, tempC)
  local affected = {}
  local schedules = (device or {}).Schedules
  local schluterDay = M.C4_TO_SCHLUTER_DAY[c4Day]
  if type(schedules) ~= "table" or not schluterDay or not schedules[schluterDay] then
    return affected
  end
  local group = schedules[schluterDay].WeekDayGrpNo
  local clock = M.minutesToClock(minutes)
  local tempFloor = M.cToSchluter(tempC)
  for day, schedule in ipairs(schedules) do
    if schedule.WeekDayGrpNo == group and type(schedule.Events) == "table" then
      -- C4 slot index maps 1:1 to the device event.
      local event = schedule.Events[entryIndex + 1]
      if event then
        event.Clock = clock
        -- Only rewrite the setpoint when it actually changed in the display
        -- scale. The proxy reports setpoints as integer °F (or 0.5 °C), which do
        -- not line up with the device's exact stored °C, so re-saving an
        -- unchanged entry would otherwise drift TempFloor by the rounding error
        -- (e.g. 31.05 → 31.15 °C) and no longer match the Schluter app. The
        -- epsilon is below both a 1 °F and a 0.5 °C step, so genuine edits still
        -- pass through while no-op re-saves preserve the device's value.
        if math.abs(tempC - M.schluterToC(event.TempFloor)) >= M.SETPOINT_EPSILON_C then
          event.TempFloor = tempFloor
        end
        event.Active = active == true
        local mapped = M.SCHLUTER_TO_C4_DAY[day]
        if mapped ~= nil then
          affected[#affected + 1] = mapped
        end
      end
    end
  end
  return affected
end

--- Re-sort every day's events by clock (ascending) and renumber each event's
--- ScheduleType to its new position (0-based). The Schluter device stores the six
--- daily events in time order with ScheduleType == index; after a Control4 edit
--- changes an event's time, this restores that invariant so events always map
--- back to the device by time. Mutates `device.Schedules` in place.
--- @param device table
function M.normalizeSchedule(device)
  local schedules = (device or {}).Schedules
  if type(schedules) ~= "table" then
    return
  end
  for _, schedule in ipairs(schedules) do
    if type(schedule.Events) == "table" then
      table.sort(schedule.Events, function(a, b)
        return M.clockToMinutes(a.Clock) < M.clockToMinutes(b.Clock)
      end)
      for i, event in ipairs(schedule.Events) do
        event.ScheduleType = i - 1
      end
    end
  end
end

return M
