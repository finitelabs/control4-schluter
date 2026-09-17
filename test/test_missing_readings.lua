-- What the driver does with a handoff that omits a numeric field.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_missing_readings.lua
--
-- Every number this driver reads comes from cloud JSON or from the proxy, so it
-- can be absent, JSON-null or non-numeric: the Schluter cloud answers some POSTs
-- with only {Success, SerialNumber}, a stale-handoff merge copies Temperature
-- across unconditionally, and the oauth backend maps field names that are not
-- verified. `tonumber` also yields infinity for "1e999", which passes every
-- `== nil` test downstream.
--
-- Regression test for DRV-122.

local T = require("testlib")

require("c4_shim")

local Thermostat = require("schluter.thermostat")
local constants = require("constants")

-- Resolved from this file rather than the working directory: make test runs from
-- the driver root, test/run_test.sh does not.
local root = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. ".."
local DRIVER = root .. "/drivers/schluter_thermostat/driver.lua"

local PROXY_BINDING = 5001
local ACCOUNT_BINDING = 5002
local TEMP_OUTPUT_BINDING = 5010

local NAN = 0 / 0
--- Marks a field to delete from the device object, since a nil in an overrides
--- table is indistinguishable from an absent key.
local ABSENT = {}

--- Captured at C4.SendToProxy rather than the global SendToProxy of the same
--- name: the global is a wrapper in lib/utils.lua that forwards through C4Call,
--- so stubbing it would measure the argument the driver passed instead of what
--- came out the far end of the path it actually takes.
local sends = {}
C4.SendToProxy = function(_, idBinding, strCommand, tParams)
  table.insert(sends, { idBinding = idBinding, command = strCommand, params = tParams })
end

dofile(DRIVER)

--- A seven-day schedule of six events each, all readable. `clockBase` shifts
--- every event's time so consecutive handoffs differ: pushSchedule skips a
--- schedule identical to the last one it pushed.
local function schedule(clockBase, badTempFloor)
  local days = {}
  for day = 1, 7 do
    local events = {}
    for entry = 1, 6 do
      events[entry] = {
        Clock = string.format("%02d:00:00", clockBase + entry),
        ScheduleType = entry - 1,
        TempFloor = 2000,
        Active = true,
      }
    end
    days[day] = { WeekDayGrpNo = day, Events = events }
  end
  if badTempFloor ~= nil then
    days[1].Events[1].TempFloor = badTempFloor ~= ABSENT and badTempFloor or nil
  end
  return days
end

--- A Schluter thermostat object as the account driver hands it over. Schluter
--- reports centidegrees, so 2150 is 21.5 °C.
local function device(overrides)
  local d = {
    SerialNumber = "SN-1",
    Online = true,
    Temperature = 2150,
    SetPointTemp = 2200,
    Heating = true,
    RegulationMode = 1,
    MinTemp = 500,
    MaxTemp = 7000,
    Schedules = {},
  }
  for k, v in pairs(overrides or {}) do
    d[k] = v ~= ABSENT and v or nil
  end
  return d
end

--- Hand a device over and return everything the driver sent in response. The
--- handoff is driven through RFP.updateThermostat, not by calling pushState, so
--- what is measured is the path a poll actually takes.
---
--- goOffline first because an optimistic write from an earlier section leaves a
--- pending mode behind, and a handoff arriving under one is merged field by
--- field instead of adopted: the schedule would be the previous device's.
local function handOver(overrides)
  RFP.goOffline(ACCOUNT_BINDING, "goOffline")
  sends = {}
  RFP.updateThermostat(ACCOUNT_BINDING, "updateThermostat", { JSON = JSON:encode(device(overrides)) })
  return sends
end

local function findSend(list, idBinding, command)
  for _, send in ipairs(list) do
    if send.idBinding == idBinding and send.command == command then
      return send
    end
  end
  return nil
end

local function countSends(list, command)
  local n = 0
  for _, send in ipairs(list) do
    if send.command == command then
      n = n + 1
    end
  end
  return n
end

--- Set the display scale the way Navigator does, and clear the capture.
local function useScale(scale)
  RFP.SET_SCALE(PROXY_BINDING, "SET_SCALE", { SCALE = scale })
  sends = {}
end

--------------------------------------------------------------------------------
T.section("a handoff carrying every reading is unaffected")
--------------------------------------------------------------------------------

-- The positive control for everything below: a guard that withheld too much
-- would pass every absence assertion in this file and fail here.
local complete = handOver()

T.eq(
  "TEMPERATURE_CHANGED carries the reading",
  findSend(complete, PROXY_BINDING, "TEMPERATURE_CHANGED").params.TEMPERATURE,
  "21.5"
)
T.eq(
  "HEAT_SETPOINT_CHANGED carries the setpoint",
  findSend(complete, PROXY_BINDING, "HEAT_SETPOINT_CHANGED").params.SETPOINT,
  "22"
)
T.eq(
  "the sensor binding carries CELSIUS",
  findSend(complete, TEMP_OUTPUT_BINDING, "VALUE_CHANGED").params.CELSIUS,
  21.5
)

--------------------------------------------------------------------------------
T.section("a handoff with no temperature withholds the reading")
--------------------------------------------------------------------------------

-- Pushing tostring(nil) put the literal string "nil" on the thermostat proxy and
-- a VALUE_CHANGED with no value at all on the sensor binding.
local noTemperature = handOver({ Temperature = ABSENT })

T.eq("no TEMPERATURE_CHANGED is sent", findSend(noTemperature, PROXY_BINDING, "TEMPERATURE_CHANGED"), nil)
T.eq(
  "no VALUE_CHANGED is sent to the sensor binding",
  findSend(noTemperature, TEMP_OUTPUT_BINDING, "VALUE_CHANGED"),
  nil
)

-- The rest of the push is what makes this a withheld reading rather than an
-- aborted handoff: pushState used to raise here on some inputs, and everything
-- after it went unsent.
T.truthy("ONLINE_CHANGED is still sent", findSend(noTemperature, PROXY_BINDING, "ONLINE_CHANGED"))
T.truthy("HEAT_SETPOINT_CHANGED is still sent", findSend(noTemperature, PROXY_BINDING, "HEAT_SETPOINT_CHANGED"))
T.truthy("HVAC_MODE_CHANGED is still sent", findSend(noTemperature, PROXY_BINDING, "HVAC_MODE_CHANGED"))
T.truthy("HOLD_MODE_CHANGED is still sent", findSend(noTemperature, PROXY_BINDING, "HOLD_MODE_CHANGED"))

-- A JSON null and a non-numeric string reach the driver as the same thing a
-- missing key does, and "1e999" parses to infinity rather than to nil.
T.eq(
  "a non-numeric temperature is withheld too",
  findSend(handOver({ Temperature = "warm" }), PROXY_BINDING, "TEMPERATURE_CHANGED"),
  nil
)
T.eq(
  "an infinite temperature is withheld too",
  findSend(handOver({ Temperature = "1e999" }), PROXY_BINDING, "TEMPERATURE_CHANGED"),
  nil
)

--------------------------------------------------------------------------------
T.section("a handoff with no setpoint withholds the setpoint")
--------------------------------------------------------------------------------

local noSetpoint = handOver({ SetPointTemp = ABSENT })

T.eq("no HEAT_SETPOINT_CHANGED is sent", findSend(noSetpoint, PROXY_BINDING, "HEAT_SETPOINT_CHANGED"), nil)
T.truthy("the temperature is still sent", findSend(noSetpoint, PROXY_BINDING, "TEMPERATURE_CHANGED"))
T.truthy("the sensor binding is still sent", findSend(noSetpoint, TEMP_OUTPUT_BINDING, "VALUE_CHANGED"))

--------------------------------------------------------------------------------
T.section("no payload carries a stringified nil")
--------------------------------------------------------------------------------

-- Asserted over every param of every send rather than over the two known keys,
-- so a new tostring() on a nullable field is caught by this file too.
local function stringifiedNils(list)
  local hits = {}
  for _, send in ipairs(list) do
    for key, value in pairs(send.params or {}) do
      if value == "nil" then
        table.insert(hits, send.command .. "." .. tostring(key))
      end
    end
  end
  return hits
end

T.eq("none with the temperature missing", stringifiedNils(handOver({ Temperature = ABSENT })), {})
T.eq("none with the setpoint missing", stringifiedNils(handOver({ SetPointTemp = ABSENT })), {})
T.eq("none with both missing", stringifiedNils(handOver({ Temperature = ABSENT, SetPointTemp = ABSENT })), {})

--------------------------------------------------------------------------------
T.section("stepping a setpoint the device never reported")
--------------------------------------------------------------------------------

-- INC/DEC_SETPOINT_HEAT is a touchscreen button. Both scales are driven because
-- the Celsius branch does its own arithmetic and the Fahrenheit branch converts.
for _, scale in ipairs({ "C", "F" }) do
  handOver({ SetPointTemp = ABSENT })
  useScale(scale)
  local ok = pcall(RFP.INC_SETPOINT_HEAT, PROXY_BINDING)
  T.truthy("stepping up in " .. scale .. " does not raise", ok)
  T.eq("and writes nothing back to the account", countSends(sends, "SET_THERMOSTAT"), 0)

  sends = {}
  ok = pcall(RFP.DEC_SETPOINT_HEAT, PROXY_BINDING)
  T.truthy("stepping down in " .. scale .. " does not raise", ok)
  T.eq("and writes nothing back to the account either", countSends(sends, "SET_THERMOSTAT"), 0)
end

-- The control: with a setpoint present the button still moves it.
handOver()
useScale("C")
RFP.INC_SETPOINT_HEAT(PROXY_BINDING)
T.eq(
  "a reported setpoint still steps half a degree C",
  findSend(sends, PROXY_BINDING, "HEAT_SETPOINT_CHANGED").params.SETPOINT,
  "22.5"
)

--------------------------------------------------------------------------------
T.section("one unreadable schedule entry no longer voids the whole week")
--------------------------------------------------------------------------------

-- 7 days x 6 events. The bug was not that the one entry was wrong: the push
-- aborted on it, so the C4 schedule editor showed an empty week.
for _, scale in ipairs({ "C", "F" }) do
  useScale(scale)
  local base = scale == "C" and 1 or 2
  local good = handOver({ Schedules = schedule(base) })
  T.eq("all 42 entries reach the proxy in " .. scale, countSends(good, "SCHEDULE_ENTRY_CHANGED"), 42)

  local absent = handOver({ Schedules = schedule(base + 3, ABSENT) })
  T.eq("41 of 42 survive a missing TempFloor in " .. scale, countSends(absent, "SCHEDULE_ENTRY_CHANGED"), 41)

  local unreadable = handOver({ Schedules = schedule(base + 6, "warm") })
  T.eq("41 of 42 survive a non-numeric TempFloor in " .. scale, countSends(unreadable, "SCHEDULE_ENTRY_CHANGED"), 41)
end

-- Skipped, not silently renumbered onto a neighbour's slot.
useScale("C")
local skipped = handOver({ Schedules = schedule(13, ABSENT) })
local slots = {}
for _, send in ipairs(skipped) do
  if send.command == "SCHEDULE_ENTRY_CHANGED" then
    slots[send.params.DayIndex .. ":" .. send.params.EntryIndex] = (send.params.HeatSetpoint or "")
  end
end
T.eq("the unreadable slot is absent", slots["1:0"], nil)
T.eq("its neighbour in the same day is untouched", slots["1:1"], "20")
T.eq("the same slot on another day is untouched", slots["2:0"], "20")

--------------------------------------------------------------------------------
T.section("editing a schedule entry whose stored setpoint is unreadable")
--------------------------------------------------------------------------------

-- The drift guard compares the edit against the stored TempFloor, and that
-- comparison was the raise: it landed after the entry's Clock had already been
-- rewritten, so a user's edit aborted halfway through the device object.
local edited = { Schedules = schedule(14, ABSENT) }
local target = edited.Schedules[1].Events[1]

local ok = pcall(Thermostat.applyScheduleEntry, edited, 1, 0, 400, true, 21.5)
T.truthy("the edit does not raise", ok)
T.eq("the new time is written", target.Clock, "06:40:00")
T.eq("the new setpoint is written", target.TempFloor, 2150)
T.eq("the enabled flag is written", target.Active, true)

-- A readable stored value still gets the drift guard it was built for: re-saving
-- an unchanged entry must not walk TempFloor by the display-scale rounding.
local unchanged = { Schedules = schedule(14) }
local keeper = unchanged.Schedules[1].Events[1]
Thermostat.applyScheduleEntry(unchanged, 1, 0, 400, true, 20.1)
T.eq("a no-op re-save keeps the device's stored value", keeper.TempFloor, 2000)
Thermostat.applyScheduleEntry(unchanged, 1, 0, 400, true, 21.5)
T.eq("a real edit still writes", keeper.TempFloor, 2150)

--------------------------------------------------------------------------------
T.section("a schedule edit the proxy sends as a non-finite temperature")
--------------------------------------------------------------------------------

-- Schedule setpoints arrive in decikelvin. An unreadable one reaching the device
-- would be written as TempFloor = infinity and POSTed to the cloud as a JSON
-- null, because JSON has no infinity literal.
local function editSchedule(heatSetpoint)
  handOver({ Schedules = schedule(16) })
  sends = {}
  RFP.UPDATE_SCHEDULE_ENTRIES(PROXY_BINDING, "UPDATE_SCHEDULE_ENTRIES", {
    DAY_INDEX = "1",
    ENTRY_INDEX = "0",
    ENTRY_TIME = "400",
    ENABLED = "true",
    HEAT_SETPOINT = heatSetpoint,
  })
  return findSend(sends, ACCOUNT_BINDING, constants.CMD.SET_THERMOSTAT)
end

T.eq("an infinite setpoint writes nothing back", editSchedule("1e999"), nil)
T.eq("an unreadable setpoint writes nothing back", editSchedule("warm"), nil)

local written = editSchedule("2946.5")
T.truthy("a readable setpoint is written back", written)
T.contains("and carries the edited temperature", written and written.params.JSON, '"TempFloor":2150')

--------------------------------------------------------------------------------
T.section("a setpoint command that is not a finite number is dropped")
--------------------------------------------------------------------------------

-- An infinite setpoint would reach the device as a JSON null.
local function adoptedSetpoint(tParams)
  handOver()
  sends = {}
  RFP.SET_SETPOINT_HEAT(PROXY_BINDING, "SET_SETPOINT_HEAT", tParams)
  local send = findSend(sends, PROXY_BINDING, "HEAT_SETPOINT_CHANGED")
  return send and send.params.SETPOINT or nil
end

T.eq("an infinite CELSIUS is dropped", adoptedSetpoint({ CELSIUS = "1e999" }), nil)
T.eq("an infinite FAHRENHEIT is dropped", adoptedSetpoint({ FAHRENHEIT = "1e999" }), nil)
T.eq("a finite setpoint is still adopted", adoptedSetpoint({ CELSIUS = "23.5" }), "23.5")

--------------------------------------------------------------------------------
T.section("the conversion helpers answer nil instead of raising")
--------------------------------------------------------------------------------

-- These are the raise sites themselves. The driver guards above are what keeps
-- the nil from travelling, but the helpers are typed number|nil and several
-- callers test the result, so returning nil is the contract.
for _, case in ipairs({
  { "nil", nil },
  { "a non-numeric string", "warm" },
  { "infinity", math.huge },
  { "a NaN", NAN },
  { "an overflowing literal", "1e999" },
}) do
  local label, value = case[1], case[2]
  T.eq("schluterToC(" .. label .. ")", Thermostat.schluterToC(value), nil)
  T.eq("c4ToC(" .. label .. ")", Thermostat.c4ToC(value), nil)
  T.eq("cToF(" .. label .. ")", Thermostat.cToF(value), nil)
  T.eq("fToC(" .. label .. ")", Thermostat.fToC(value), nil)
  T.eq("normalize(" .. label .. ")", Thermostat.normalize(value), nil)
  T.eq(
    "stepSetpointC(" .. label .. ")",
    Thermostat.stepSetpointC({ setpointC = value, minC = 5, maxC = 70 }, 1, "C"),
    nil
  )
end

-- Values chosen to be exact in binary floating point, so this fails on a changed
-- conversion rather than on a rounding difference. The guards must not have
-- turned these helpers into the template's rounding c2f/f2c.
T.eq("cToF still converts", Thermostat.cToF(20), 68)
T.eq("cToF is unrounded", Thermostat.cToF(21.25), 70.25)
T.eq("fToC still converts", Thermostat.fToC(68), 20)
T.eq("schluterToC still scales", Thermostat.schluterToC(2150), 21.5)
T.eq("schluterToC reads a numeric string", Thermostat.schluterToC("2150"), 21.5)
T.eq("c4ToC still converts decikelvin", Thermostat.c4ToC(2946.5), 21.5)
T.eq("normalize still snaps down", Thermostat.normalize(21.25), 21)
T.eq("normalize still snaps up", Thermostat.normalize(21.75), 21.5)
T.eq("stepSetpointC still steps", Thermostat.stepSetpointC({ setpointC = 20, minC = 5, maxC = 70 }, 1, "C"), 20.5)

T.finish()
