-- Tests the temperature value output connection by driving the driver's own
-- handoff handler and reading the payload that reaches C4.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_sensor_binding_params.lua
--
-- The helpers' own behaviour is covered by test_sensor_params.lua. What is
-- checked here is the call site: C4-THERM reads a bound temperature from
-- tParams["CELSIUS"] and never looks at VALUE or SCALE, and it reads
-- tParams["TIMESTAMP"] into a Dbg:Trace concatenation before testing it, so a
-- payload without one crashes the thermostat at its driver.lua:2982 before the
-- reading is ever considered.
--
-- Regression test for DRV-121.

local T = require("testlib")

require("c4_shim")

-- Resolved from this file rather than the working directory: make test runs from
-- the driver root, test/run_test.sh does not.
local root = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. ".."
local DRIVER = root .. "/drivers/schluter_thermostat/driver.lua"

local PROXY_BINDING = 5001
local ACCOUNT_BINDING = 5002
local TEMP_OUTPUT_BINDING = 5010

--- Everything the driver sent since the last reset.
---
--- Captured at C4.SendToProxy rather than the global SendToProxy of the same
--- name: the global is a wrapper in lib/utils.lua that forwards through C4Call,
--- so stubbing it would measure the argument the driver passed instead of what
--- came out the far end of the path it actually takes.
local sends = {}
C4.SendToProxy = function(_, idBinding, strCommand, tParams)
  table.insert(sends, { idBinding = idBinding, command = strCommand, params = tParams })
end

dofile(DRIVER)

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
    d[k] = v
  end
  return d
end

--- Hand a device over to the driver and return everything it sent in response.
local function handOver(overrides)
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

--------------------------------------------------------------------------------
T.section("the temperature output carries every key convention")
--------------------------------------------------------------------------------

local emitted = findSend(handOver(), TEMP_OUTPUT_BINDING, "VALUE_CHANGED")

T.check("the handoff emits a VALUE_CHANGED on the output binding", emitted ~= nil, "no send")
T.eq("VALUE is the measured temperature", emitted.params.VALUE, 21.5)
T.eq("SCALE names the measured scale", emitted.params.SCALE, "CELSIUS")
T.eq("CELSIUS is what C4-THERM reads", emitted.params.CELSIUS, 21.5)
T.eq("FAHRENHEIT is converted alongside", emitted.params.FAHRENHEIT, 70.7)

--------------------------------------------------------------------------------
T.section("TIMESTAMP is present and fresh")
--------------------------------------------------------------------------------

-- C4-THERM crashes on a payload with no stamp and discards one stamped older
-- than 900 seconds, so both properties are asserted rather than presence alone.
local now = os.time()
local stamp = emitted.params.TIMESTAMP

T.check("TIMESTAMP is a number", type(stamp) == "number", type(stamp))
T.check(
  "TIMESTAMP is epoch seconds inside C4-THERM's 900s gate",
  type(stamp) == "number" and stamp > now - 900 and stamp <= now,
  stamp
)

--------------------------------------------------------------------------------
T.section("the payload tracks the reported temperature")
--------------------------------------------------------------------------------

-- A payload built once and cached would pass every assertion above.
local colder = findSend(handOver({ Temperature = 1800 }), TEMP_OUTPUT_BINDING, "VALUE_CHANGED")

T.eq("VALUE follows the device", colder.params.VALUE, 18)
T.eq("CELSIUS follows the device", colder.params.CELSIUS, 18)
T.eq("FAHRENHEIT follows the device", colder.params.FAHRENHEIT, 64.4)

--------------------------------------------------------------------------------
T.section("the thermostat proxy's own notifications are unchanged")
--------------------------------------------------------------------------------

-- The output binding is one of several sends in pushState. This change is meant
-- to be confined to it, and these run over the same captured batch.
local batch = handOver()
local temperatureChanged = findSend(batch, PROXY_BINDING, "TEMPERATURE_CHANGED")
local setpointChanged = findSend(batch, PROXY_BINDING, "HEAT_SETPOINT_CHANGED")

T.check("TEMPERATURE_CHANGED still goes to the proxy", temperatureChanged ~= nil, "missing")
T.eq("still a string in C", temperatureChanged.params.TEMPERATURE, "21.5")
T.eq("still scaled C", temperatureChanged.params.SCALE, "C")
T.check("HEAT_SETPOINT_CHANGED still goes to the proxy", setpointChanged ~= nil, "missing")
T.eq("still the reported setpoint", setpointChanged.params.SETPOINT, "22")

--------------------------------------------------------------------------------
T.section("a setpoint command is read through the shared tolerant parse")
--------------------------------------------------------------------------------

-- The driver's local parser was folded onto CelsiusFromParams. It is read back
-- through the setpoint the driver actually adopts, rather than by calling the
-- parser: the setpoint is what a wrong conversion would damage, and it is the
-- only observable a local function has.
--
-- applySetpoint snaps to the nearest 0.5 °C (Schluter's resolution), so the
-- shared helper rounding a conversion to 1 decimal where the local one did not
-- is absorbed before it reaches the device.
local function adoptedSetpoint(tParams)
  handOver()
  sends = {}
  RFP.SET_SETPOINT_HEAT(PROXY_BINDING, "SET_SETPOINT_HEAT", tParams)
  local send = findSend(sends, PROXY_BINDING, "HEAT_SETPOINT_CHANGED")
  return send and send.params.SETPOINT or nil
end

T.eq("CELSIUS is taken directly", adoptedSetpoint({ CELSIUS = "23.5" }), "23.5")
T.eq("FAHRENHEIT is converted", adoptedSetpoint({ FAHRENHEIT = "72" }), "22")
T.eq("a bare VALUE is Fahrenheit, as the proxy sends it", adoptedSetpoint({ VALUE = "72" }), "22")
T.eq("VALUE with SCALE=C is Celsius", adoptedSetpoint({ VALUE = "23.5", SCALE = "C" }), "23.5")
T.eq("CELSIUS wins over FAHRENHEIT", adoptedSetpoint({ CELSIUS = "23.5", FAHRENHEIT = "100" }), "23.5")
T.eq("nothing usable is ignored", adoptedSetpoint({ MODE = "Heat" }), nil)

-- The local parser fell through to Fahrenheit for any scale it did not spell
-- out, so a Kelvin setpoint became (K - 32) * 5/9: 296.65 K is 23.5 °C and was
-- adopted as 147 °C. The shared helper knows the scale.
T.eq("KELVIN is converted, not read as Fahrenheit", adoptedSetpoint({ VALUE = "296.65", SCALE = "KELVIN" }), "23.5")

-- A scale that names no temperature now yields nil rather than being assumed
-- Fahrenheit, so an unreadable command is dropped instead of moving the floor
-- heating to an invented setpoint.
T.eq("an unrecognized scale is dropped", adoptedSetpoint({ VALUE = "72", SCALE = "BANANAS" }), nil)

--------------------------------------------------------------------------------
T.section("the setpoint handlers are spelled the way the proxy dispatches them")
--------------------------------------------------------------------------------

-- ReceivedFromProxy resolves a handler by exact command name and accepts it only
-- if it is a function (handlers.lua:866-868, Select(RFP, strCommand)); this
-- driver defines no numeric idBinding fallback, so a misspelled handler is never
-- reached and the miss is logged only behind DEBUGPRINT. SET_SINGLE_SETPOINT was
-- one: the thermostatV2 command is SET_SETPOINT_SINGLE, and this driver does not
-- advertise that model anyway (hasSingleSetpoint false, driver.xml
-- has_single_setpoint False), so the correctly spelled handler would be dead too.
--
-- The present-checks are not decoration: they are what stops the absent-check
-- from passing vacuously against an RFP that was never populated.
T.eq("SET_SINGLE_SETPOINT is not dispatchable", type(RFP.SET_SINGLE_SETPOINT), "nil")
T.eq("SET_SETPOINT_HEAT is dispatchable", type(RFP.SET_SETPOINT_HEAT), "function")
T.eq("INC_SETPOINT_HEAT is dispatchable", type(RFP.INC_SETPOINT_HEAT), "function")
T.eq("DEC_SETPOINT_HEAT is dispatchable", type(RFP.DEC_SETPOINT_HEAT), "function")

T.finish()
