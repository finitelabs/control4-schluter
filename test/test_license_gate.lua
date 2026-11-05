-- The Schluter account's license gate in the DriverCentral build, driven by the real cloud client against a fake
-- Cloud driver and a scripted Schluter client. Licensed, the account logs in, reads, long-polls and writes; five
-- minutes without a license log it out, stop every request and take the thermostats offline; a license logs it in
-- again at once. With no product id yet the account is stopped from its load.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_license_gate.lua

require("c4_shim")
local T = require("testlib")
local cloud = require("dc_cloud")

local DRIVER = (debug.getinfo(1, "S").source:match("@(.*[/\\])") or "./") .. "../drivers/schluter/driver.lua"

local deferred = require("deferred")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

local function resolved(value)
  local d = deferred.new()
  d:resolve(value)
  return d
end

-- The Schluter cloud, counted: each call is a request that left the controller.
local calls = { logins = 0, reads = 0, writes = 0, polls = 0 }
local authed = false
local fake = {}
function fake.isAuthenticated()
  return authed
end
function fake.authenticate()
  calls.logins = calls.logins + 1
  authed = true
  return resolved(true)
end
function fake.logout()
  authed = false
end
function fake.getThermostats()
  calls.reads = calls.reads + 1
  return resolved({
    {
      SerialNumber = 1182342,
      Room = "Bath",
      RegulationMode = 1,
      SetPointTemp = 3111,
      Temperature = 3130,
      Online = true,
    },
  })
end
function fake.setThermostat(_, _serial, settings)
  calls.writes = calls.writes + 1
  return resolved(settings)
end
function fake.getNotification()
  calls.polls = calls.polls + 1
  return deferred.new()
end
function fake.cancelNotification() end
package.loaded["schluter.client"] = {
  create = function()
    return fake
  end,
}
local function total()
  return calls.logins + calls.reads + calls.writes + calls.polls
end

-- drivers-common-public's named timers, kept so a test fires them by hand.
local timers = {}
SetTimer = function(name, delay, callback, repeating)
  timers[name] = { delay = delay, callback = callback, repeating = repeating }
end
CancelTimer = function(name)
  timers[name] = nil
end
local function fire(name)
  local t = timers[name]
  if not t then
    return
  end
  if not t.repeating then
    timers[name] = nil
  end
  t.callback()
end
local function armed()
  local n = 0
  for name in pairs(timers) do
    if name:find("^Schluter") then
      n = n + 1
    end
  end
  return n
end

local sends = {}
C4.SendToProxy = function(_, idBinding, command, tParams)
  sends[#sends + 1] = { idBinding = idBinding, command = command, params = tParams }
end
local function sent(command)
  local n = 0
  for _, s in ipairs(sends) do
    if s.command == command then
      n = n + 1
    end
  end
  return n
end
C4.UpdateProperty = function(_, name, value)
  Properties[name] = value
end
C4.GetDriverConfigInfo = function(_, key)
  return ({ minimum_os_version = "3.3.0", version = "20261104", model = "Schluter" })[key]
end
C4.GetVersionInfo = function()
  return { version = "4.3.0" }
end
C4.FireEventByID = function() end

--- Runs `path` as the DriverCentral build compiles it: a line its directives leave out is blanked.
local function dofileDriverCentral(path)
  local f = assert(io.open(path))
  local lines, stack, including = {}, {}, true
  for line in f:lines() do
    local ifdef, name = line:match("^%s*%-%-%s*#(ifn?def)%s+([%w_]+)%s*$")
    if ifdef then
      stack[#stack + 1] = including
      including = including and (name == "DRIVERCENTRAL") == (ifdef == "ifdef")
    elseif line:match("^%s*%-%-%s*#else%s*$") then
      including = stack[#stack] and not including
    elseif line:match("^%s*%-%-%s*#endif%s*$") then
      including = table.remove(stack)
    end
    lines[#lines + 1] = including and line or ""
  end
  f:close()
  assert(load(table.concat(lines, "\n"), "@" .. path))()
end

local gate

--- A load of the account driver with a fresh client and gate, then its login.
--- @param answer? table What the Cloud driver answers each ping with; nil answers nothing.
--- @param pid? integer The product id (999).
local function load(answer, pid)
  if gate and gate._timer then
    gate._timer:Cancel()
  end
  package.loaded["cloud-client-byte"] = nil
  package.loaded["lib.drivercentral"] = nil
  cloud.ping, cloud.answer, cloud.silent, cloud.present = nil, answer, answer == nil, true
  for k in pairs(timers) do
    timers[k] = nil
  end
  authed = false
  Properties = {
    ["Email"] = "owner@example.com",
    ["Password"] = "x",
    ["Log Level"] = "3 - Info",
    ["Log Mode"] = "Off",
    ["Cloud Status"] = "",
    ["Automatic Updates"] = "Off",
    ["Cloud Monitoring"] = "Disabled",
  }
  DC_OnDriverStatus = nil
  dofileDriverCentral(DRIVER)
  gate = require("lib.drivercentral")
  gate.PRODUCT_ID = pid or 999
  OnDriverInit()
  OnDriverLateInit("DIT_STARTUP")
  fire("SchluterLogin")
end

--- `n` rounds of 10 s: one ping, then one read by the gate.
local function tick(n)
  for _ = 1, n or 1 do
    if cloud.ping then
      cloud.poll(1)
    end
    gate:_check()
  end
end

--- A companion's write of the thermostat it was handed last.
local function write()
  for i = #sends, 1, -1 do
    if sends[i].command == "updateThermostat" then
      local device = JSON:decode(sends[i].params.JSON)
      device.SetPointTemp = 2950
      ReceivedFromProxy(sends[i].idBinding, "setThermostat", { JSON = JSON:encode(device) })
      fire("SchluterWrite_1182342")
      return
    end
  end
end

T.section("A licensed account logs in, reads, long-polls and writes")
do
  load({ AC = 1, AS = "License Activated" })
  T.eq("logged in", calls.logins > 0, true)
  T.eq("the long-poll runs", calls.polls > 0, true)
  T.eq("the reconcile poll is armed", timers.SchluterReconcile ~= nil, true)
  tick(40)
  local writes = calls.writes
  write()
  T.eq("a companion's write reaches Schluter after 400 s", calls.writes, writes + 1)
end

T.section("Without a license the account logs out five minutes after its load, and nothing reaches Schluter")
do
  load({ AC = 0, AS = "Invalid License" })
  tick(29)
  T.eq("29 reads of 0: logged in", authed, true)
  local offline = sent("goOffline")
  tick()
  T.eq("the 30th read logs it out", authed, false)
  T.eq("and leaves no Schluter timer armed", armed(), 0)
  T.eq("the thermostat goes offline", sent("goOffline") > offline, true)
  T.eq("Driver Status says why", Properties["Driver Status"], "No active license")
  T.eq("and Login Status", Properties["Login Status"], "No active license")
  local before = total()
  EC.Refresh_Thermostats()
  EC.Reconnect()
  OnPropertyChanged("Password")
  fire("SchluterLogin")
  write()
  T.eq("Refresh, Reconnect, a credential edit and a write send nothing", total(), before)
  T.eq("and arm nothing", armed(), 0)
end

T.section("A write already waiting when the account stops is dropped")
do
  load({ AC = 1, AS = "License Activated" })
  for i = #sends, 1, -1 do
    if sends[i].command == "updateThermostat" then
      local device = JSON:decode(sends[i].params.JSON)
      ReceivedFromProxy(sends[i].idBinding, "setThermostat", { JSON = JSON:encode(device) })
      break
    end
  end
  cloud.answer = { AC = 0, AS = "Trial Expired" }
  local writes = calls.writes
  tick(30)
  fire("SchluterWrite_1182342")
  T.eq("the waiting write never goes out", calls.writes, writes)
end

T.section("A license back logs the account in again at once")
do
  load({ AC = -1, AS = "Trial Running, 1 Hours Remaining" })
  cloud.answer = { AC = 0, AS = "Trial Expired" }
  tick(30)
  T.eq("stopped", authed, false)
  local logins = calls.logins
  cloud.answer = { AC = 1, AS = "License Activated" }
  cloud.say(cloud.answer)
  fire("SchluterLogin")
  T.eq("logged in again", calls.logins, logins + 1)
  T.eq("the long-poll and the reconcile poll run again", timers.SchluterReconcile ~= nil, true)
end

T.section("A Cloud driver update leaves a licensed account logged in")
do
  load({ AC = 1, AS = "License Activated" })
  tick(3)
  cloud.say({ AC = 0, AS = "Cloud driver removed, please install cloud driver." })
  cloud.silent = true
  tick(3)
  cloud.silent = false
  tick(40)
  T.eq("logged in", authed, true)
end

T.section("With no product id yet the account is stopped from its load")
do
  for k in pairs(calls) do
    calls[k] = 0
  end
  load({ AC = 1, AS = "License Activated" }, 0)
  T.eq("the client is not loaded", package.loaded["cloud-client-byte"], nil)
  T.eq("Driver Status", Properties["Driver Status"], "No active license")
  tick(40)
  T.eq("nothing reaches Schluter", total(), 0)
end

if gate and gate._timer then
  gate._timer:Cancel()
end
T.finish()
