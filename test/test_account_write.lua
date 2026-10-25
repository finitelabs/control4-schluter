-- The schluter account driver's write path against a scripted client: a
-- companion's write is sent but not echoed back to it (Schluter's POST answers
-- only {"Success":true}, so an echo would confirm the companion's pending write
-- before the cloud has), and a read a few seconds later hands over what the
-- cloud actually stored.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_account_write.lua

local T = require("testlib")

require("c4_shim")

local root = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. ".."
local DRIVER = root .. "/drivers/schluter/driver.lua"

local deferred = require("deferred")
-- Loaded before the stubs below, which would otherwise be redefined when the
-- driver's requires first run these modules.
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

local function resolved(value)
  local d = deferred.new()
  d:resolve(value)
  return d
end

local function copy(t)
  return JSON:decode(JSON:encode(t))
end

-- ─── Scripted Schluter client ──────────────────────────────────────────────

local cloud = {
  SerialNumber = 1182342,
  Room = "Master Bathroom",
  RegulationMode = 1,
  SetPointTemp = 3111,
  ComfortTemperature = 2600,
  ManualTemperature = 2600,
  Temperature = 3130,
  Online = true,
}
local writes, reads = {}, 0
local fake = {}
function fake.isAuthenticated()
  return true
end
function fake.getThermostats()
  reads = reads + 1
  return resolved({ copy(cloud) })
end
function fake.setThermostat(_, serial, settings)
  writes[#writes + 1] = { serial = serial, settings = settings }
  return resolved(settings)
end
function fake.getNotification()
  return deferred.new()
end
function fake.cancelNotification() end
package.loaded["schluter.client"] = {
  create = function()
    return fake
  end,
}

local timers = {}
SetTimer = function(name, delay, callback, repeating)
  timers[name] = { delay = delay, callback = callback, repeating = repeating }
end
CancelTimer = function(name)
  timers[name] = nil
end
local function fire(name)
  local timer = timers[name]
  timers[name] = nil
  timer.callback()
end

local sends = {}
C4.SendToProxy = function(_, idBinding, command, tParams)
  sends[#sends + 1] = { idBinding = idBinding, command = command, params = tParams }
end
local function handoffs()
  local list = {}
  for _, send in ipairs(sends) do
    if send.command == "updateThermostat" then
      list[#list + 1] = JSON:decode(send.params.JSON)
    end
  end
  return list
end

dofile(DRIVER)

T.section("discovery hands the thermostat to its companion")
EC.Refresh_Thermostats()
local first = handoffs()[1]
T.truthy("handed off", first)
T.eq("as the cloud reports it", first and first.SetPointTemp, 3111)
local bindingId
for _, send in ipairs(sends) do
  if send.command == "updateThermostat" then
    bindingId = send.idBinding
  end
end

T.section("a companion's write is sent but not echoed")
sends = {}
local held = copy(cloud)
held.RegulationMode = 2
held.SetPointTemp = 2950
held.ComfortTemperature = 2950
RFP.setThermostat(bindingId, "setThermostat", { JSON = JSON:encode(held) })
fire("SchluterWrite_1182342")
T.eq("one write", #writes, 1)
T.eq("with the companion's setpoint", writes[1] and writes[1].settings.SetPointTemp, 2950)
T.eq("nothing is handed back", #handoffs(), 0)
T.truthy("a read-back is scheduled", timers.SchluterReadback)
T.eq("five seconds later", timers.SchluterReadback and timers.SchluterReadback.delay, 5 * 1000)

T.section("the read-back hands over what the cloud stored")
-- Schluter has not applied it yet: the companion must see the old state, so its
-- pending write stays pending and its retry re-sends.
reads = 0
fire("SchluterReadback")
T.eq("the cloud is read", reads, 1)
local stale = handoffs()[1]
T.eq("a cloud still on the old setpoint is handed over as is", stale and stale.SetPointTemp, 3111)

sends = {}
cloud.RegulationMode, cloud.SetPointTemp, cloud.ComfortTemperature = 2, 2950, 2950
EC.Refresh_Thermostats()
local applied = handoffs()[1]
T.eq("once applied, the new setpoint", applied and applied.SetPointTemp, 2950)
T.eq("and hold", applied and applied.RegulationMode, 2)

T.section("a read issued before the write is discarded")
local pendingRead = deferred.new()
fake.getThermostats = function()
  return pendingRead
end
EC.Refresh_Thermostats()
fake.getThermostats = function()
  return resolved({ copy(cloud) })
end
RFP.setThermostat(bindingId, "setThermostat", { JSON = JSON:encode(held) })
fire("SchluterWrite_1182342")
sends = {}
local before = copy(cloud)
before.SetPointTemp = 2000
pendingRead:resolve({ before })
T.eq("its pre-write state never reaches the companion", #handoffs(), 0)

T.finish()
