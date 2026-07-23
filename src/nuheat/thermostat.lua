--- NuHeat thermostat state model + Control4 translation helpers.
---
--- Pure logic (no C4/HTTP side effects) so it is unit-testable: temperature
--- scaling between NuHeat's wire format and Celsius/Fahrenheit, ScheduleMode ↔
--- HVAC/hold mapping, capability derivation from a device object, and building
--- the `settings` object POSTed back to mynuheat.com. Used by the companion
--- (nuheat_thermostat) driver. See docs/nuheat-api-reference.md.

local M = {}

--- NuHeat wire temperatures are Celsius × 100 (hundredths of a degree C).
local NUHEAT_SCALE = 100
--- ScheduleMode enum used by the NuHeat API.
M.MODE = { AUTO = 1, UNTIL = 2, PERMANENT = 3 }
--- Away/Off is encoded as Permanent hold at the 5.00 °C minimum (== 500).
M.OFF_SENTINEL = 500
--- Setpoint bounds (NuHeat Signature): 5–70 °C / 41–158 °F.
M.MIN_C, M.MAX_C = 5, 70

-- ─── Temperature conversion ────────────────────────────────────────────────

--- @param n number NuHeat wire value (°C × 100)
--- @return number celsius
function M.nuheatToC(n)
  return tonumber(n) / NUHEAT_SCALE
end

--- @param c number Celsius
--- @return number nuheat wire value (°C × 100, rounded)
function M.cToNuheat(c)
  return M.round(tonumber(c) * NUHEAT_SCALE)
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

--- Snap a temperature to the nearest 0.5° (NuHeat setpoint resolution).
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

--- @class NuHeatState
--- @field serialNumber string
--- @field online boolean
--- @field room string
--- @field temperatureC number Current floor temperature, °C
--- @field setpointC number Active setpoint, °C
--- @field heating boolean HVAC actively heating
--- @field scheduleMode integer NuHeat ScheduleMode (1/2/3)
--- @field minC number
--- @field maxC number
--- @field hasSchedule boolean
--- @field isOff boolean Away/Off (permanent hold at minimum)

--- Normalize a raw NuHeat thermostat object (bare or `{Thermostat=...}`).
--- @param object table
--- @return NuHeatState
function M.fromDevice(object)
  local v = object.Thermostat or object
  local scheduleMode = tonumber(v.ScheduleMode)
  local setpoint = tonumber(v.SetPointTemp)
  return {
    serialNumber = tostring(v.SerialNumber),
    online = v.Online == true,
    room = v.Room or v.GroupName or "",
    temperatureC = M.nuheatToC(v.Temperature),
    setpointC = M.nuheatToC(setpoint),
    heating = v.Heating == true,
    scheduleMode = scheduleMode,
    minC = v.MinTemp and M.nuheatToC(v.MinTemp) or M.MIN_C,
    maxC = v.MaxTemp and M.nuheatToC(v.MaxTemp) or M.MAX_C,
    hasSchedule = type(v.Schedules) == "table" and #v.Schedules > 0,
    isOff = scheduleMode == M.MODE.PERMANENT and setpoint == M.OFF_SENTINEL,
  }
end

-- ─── Capability derivation (for the thermostat proxy) ───────────────────────

--- Derive the Control4 thermostat-proxy capabilities from device state. NuHeat
--- is heat-only with a single setpoint, so CAN_* are false per the C4 rule that
--- they must be false when HAS_SINGLE_SETPOINT is true. Only advertises what the
--- handed device actually reports (e.g. schedule).
--- @param state NuHeatState
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
--- @param state NuHeatState
--- @return string
function M.hvacState(state)
  return state.heating and "Heat" or "Off"
end

--- HVAC mode for the C4 proxy: "Off" when in Away/Off, otherwise "Heat".
--- @param state NuHeatState
--- @return string
function M.hvacMode(state)
  return state.isOff and "Off" or "Heat"
end

-- ─── Settings builders (Control4 → NuHeat POST body) ───────────────────────

--- Set the heat setpoint (°C). Puts the thermostat into a temporary "Until"
--- hold unless it is already in an Until/Permanent hold.
--- @param settings table Current NuHeat settings object (mutated + returned).
--- @param celsius number
--- @return table settings
function M.applySetpoint(settings, celsius)
  settings.SetPointTemp = M.cToNuheat(M.normalize(celsius))
  if settings.ScheduleMode ~= M.MODE.UNTIL and settings.ScheduleMode ~= M.MODE.PERMANENT then
    settings.ScheduleMode = M.MODE.UNTIL
  end
  return settings
end

--- Set HVAC mode. "Heat" resumes the schedule (Auto); "Off" is a permanent hold
--- at the device minimum (Away).
--- @param settings table
--- @param mode string "Heat" | "Off"
--- @param minTempNuheat number Device MinTemp in NuHeat units (°C×100).
--- @return table settings
function M.applyHvacMode(settings, mode, minTempNuheat)
  if mode == "Off" then
    settings.ScheduleMode = M.MODE.PERMANENT
    settings.SetPointTemp = minTempNuheat or M.OFF_SENTINEL
  else
    settings.ScheduleMode = M.MODE.AUTO
  end
  return settings
end

return M
