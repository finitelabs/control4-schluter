-- What the companion writes for the HVAC mode and setpoint commands the
-- thermostatV2 proxy sends, and how its optimistic write holds against the
-- handoffs the account sends after it.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_companion_write.lua
--
-- Regression test for DRV-212.

local T = require("testlib")

require("c4_shim")
require("drivers-common-public.global.timer")

local constants = require("constants")

local root = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. ".."
local DRIVER = root .. "/drivers/schluter_thermostat/driver.lua"

local PROXY_BINDING = 5001
local ACCOUNT_BINDING = 5002

local sends = {}
C4.SendToProxy = function(_, idBinding, command, tParams)
  table.insert(sends, { idBinding = idBinding, command = command, params = tParams })
end

local timers = {}
SetTimer = function(name, delay, callback, repeating)
  timers[name] = { delay = delay, callback = callback, repeating = repeating }
end
CancelTimer = function(name)
  timers[name] = nil
end

dofile(DRIVER)

local function device(overrides)
  local d = {
    SerialNumber = "1",
    Online = true,
    Temperature = 2150,
    SetPointTemp = 2200,
    Heating = false,
    RegulationMode = 1,
    MinTemp = 500,
    MaxTemp = 4000,
  }
  for k, v in pairs(overrides or {}) do
    d[k] = v
  end
  return d
end

local function handOver(d)
  RFP.updateThermostat(ACCOUNT_BINDING, "updateThermostat", { JSON = JSON:encode(d) })
end

local function lastWrite()
  local written
  for _, send in ipairs(sends) do
    if send.idBinding == ACCOUNT_BINDING and send.command == constants.CMD.SET_THERMOSTAT then
      written = JSON:decode(send.params.JSON)
    end
  end
  return written
end

local function lastSetpoint()
  for i = #sends, 1, -1 do
    if sends[i].command == "HEAT_SETPOINT_CHANGED" then
      return tonumber(sends[i].params.SETPOINT)
    end
  end
end

local function writesToAccount()
  local n = 0
  for _, send in ipairs(sends) do
    if send.idBinding == ACCOUNT_BINDING and send.command == constants.CMD.SET_THERMOSTAT then
      n = n + 1
    end
  end
  return n
end

T.section("a Fahrenheit project's setpoint is read in Fahrenheit")
-- Captured from the thermostatV2 proxy on a 4.3 controller in a Fahrenheit
-- project, setting 24.5 C: CELSIUS arrives rounded to a whole degree.
handOver(device())
RFP.SET_SCALE(PROXY_BINDING, "SET_SCALE", { SCALE = "FAHRENHEIT" })
sends = {}
RFP.SET_SETPOINT_HEAT(
  PROXY_BINDING,
  "SET_SETPOINT_HEAT",
  { CELSIUS = "25", FAHRENHEIT = "76", KELVIN = "2976", SETPOINT = "76" }
)
T.eq("76 F is written as 24.5 C, not 25", lastWrite() and lastWrite().SetPointTemp, 2450)
RFP.SET_SCALE(PROXY_BINDING, "SET_SCALE", { SCALE = "CELSIUS" })
sends = {}
RFP.SET_SETPOINT_HEAT(PROXY_BINDING, "SET_SETPOINT_HEAT", { CELSIUS = "24.5", FAHRENHEIT = "76" })
T.eq("a Celsius project reads CELSIUS", lastWrite() and lastWrite().SetPointTemp, 2450)

T.section("Heat/Off arrives as SET_MODE_HVAC")
RFP.goOffline(ACCOUNT_BINDING, "goOffline")
handOver(device())
sends = {}
RFP.SET_MODE_HVAC(PROXY_BINDING, "SET_MODE_HVAC", { MODE = "Off" })
T.eq("Off is Manual", lastWrite() and lastWrite().RegulationMode, 3)
T.eq("at the device minimum", lastWrite() and lastWrite().ManualTemperature, 500)
sends = {}
RFP.SET_MODE_HVAC(PROXY_BINDING, "SET_MODE_HVAC", { MODE = "Heat" })
T.eq("Heat resumes the schedule", lastWrite() and lastWrite().RegulationMode, 1)
sends = {}
RFP.SET_MODE_HVAC(PROXY_BINDING, "SET_MODE_HVAC", { MODE = "Cool" })
T.eq("a mode it does not have writes nothing", lastWrite(), nil)

T.section("a setpoint change within a hold waits for the new setpoint")
RFP.goOffline(ACCOUNT_BINDING, "goOffline")
handOver(device({ RegulationMode = 2, SetPointTemp = 2200 }))
RFP.SET_SCALE(PROXY_BINDING, "SET_SCALE", { SCALE = "CELSIUS" })
sends = {}
RFP.SET_SETPOINT_HEAT(PROXY_BINDING, "SET_SETPOINT_HEAT", { CELSIUS = "25" })
T.eq("shows 25 C at once", lastSetpoint(), 25)
handOver(device({ RegulationMode = 2, SetPointTemp = 2200 }))
T.eq("a read still in Comfort at 22 C does not put it back", lastSetpoint(), 25)
sends = {}
timers.SchluterConfirm.callback()
T.eq("the write is sent again", writesToAccount(), 1)
handOver(device({ RegulationMode = 2, SetPointTemp = 2500 }))
sends = {}
timers.SchluterConfirm.callback()
T.eq("the read at 25 C ends the wait", writesToAccount(), 0)

T.finish()
