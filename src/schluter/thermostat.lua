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

-- ─── Temperature conversion ────────────────────────────────────────────────

--- @param n number Schluter wire value (°C × 100)
--- @return number celsius
function M.schluterToC(n)
  return tonumber(n) / SCHLUTER_SCALE
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
    hasSingleSetpoint = true,
    canHeat = false,
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

-- ─── Settings builders (Control4 → Schluter POST body) ───────────────────────

--- Set the heat setpoint (°C). Puts the thermostat into a temporary "Until"
--- hold unless it is already in an Until/Permanent hold.
--- @param settings table Current Schluter settings object (mutated + returned).
--- @param celsius number
--- @return table settings
function M.applySetpoint(settings, celsius)
  settings.SetPointTemp = M.cToSchluter(M.normalize(celsius))
  if settings.ScheduleMode ~= M.MODE.UNTIL and settings.ScheduleMode ~= M.MODE.PERMANENT then
    settings.ScheduleMode = M.MODE.UNTIL
  end
  return settings
end

--- Set HVAC mode. "Heat" resumes the schedule (Auto); "Off" is a permanent hold
--- at the device minimum (Away).
--- @param settings table
--- @param mode string "Heat" | "Off"
--- @param minTempSchluter number Device MinTemp in Schluter units (°C×100).
--- @return table settings
function M.applyHvacMode(settings, mode, minTempSchluter)
  if mode == "Off" then
    settings.ScheduleMode = M.MODE.PERMANENT
    settings.SetPointTemp = minTempSchluter or M.OFF_SENTINEL
  else
    settings.ScheduleMode = M.MODE.AUTO
  end
  return settings
end

-- ─── Schedule model (Control4 thermostatV2 ⇄ Schluter Schedules[]) ────────────
--
-- Schluter `device.Schedules` is a 7-element array indexed by Schluter day
-- (1=Mon .. 7=Sun). Each entry = `{ WeekDayGrpNo, Events[1..4] }`, each event =
-- `{ Clock "HH:MM:SS", ScheduleType, TempFloor (°C×100), Active }`. Days sharing
-- a `WeekDayGrpNo` share one program, so editing one propagates to the whole
-- group — matching the Schluter thermostat's own grouping behavior (and the old
-- driver). Control4's thermostatV2 schedule is per-day (DayIndex 0=Sun .. 6=Sat)
-- with EntryIndex 0..3 (Wake/Leave/Return/Sleep). Heat-only, so cool is unused.

--- Schluter schedule array index (1=Mon..7=Sun) -> C4 DayIndex (0=Sun..6=Sat).
M.SCHLUTER_TO_C4_DAY = { 1, 2, 3, 4, 5, 6, 0 }
--- C4 DayIndex (0=Sun..6=Sat) -> Schluter schedule array index (1=Mon..7=Sun).
M.C4_TO_SCHLUTER_DAY = { [0] = 7, [1] = 1, [2] = 2, [3] = 3, [4] = 4, [5] = 5, [6] = 6 }
--- Events per day in the Schluter DITRA-HEAT schedule.
M.SCHEDULE_ENTRIES_PER_DAY = 4

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
      local event = schedule.Events[entryIndex + 1]
      if event then
        event.Clock = clock
        event.TempFloor = tempFloor
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

return M
