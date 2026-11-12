-- The schluter account driver against a Schluter that grants a session and then refuses it at once, every read
-- answering 401, as it did on 2026-11-11: the driver signs in again on a growing wait, not every few seconds. A
-- session that has worked and then expires is signed in again at once.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_session_refused.lua

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

local function rejected(value)
  local d = deferred.new()
  d:reject(value)
  return d
end

-- ─── Scripted Schluter client ──────────────────────────────────────────────

local refusing = true
local authed, signIns = false, 0
local poll
local fake = {}
function fake.isAuthenticated()
  return authed
end
function fake.authenticate()
  signIns = signIns + 1
  authed = true
  return resolved(true)
end
function fake.logout()
  authed = false
end
function fake.getThermostats()
  if refusing then
    authed = false
    return rejected("HTTP 401")
  end
  return resolved({})
end
function fake.getNotification()
  if refusing then
    authed = false
    return rejected("HTTP 401")
  end
  poll = deferred.new()
  return poll
end
function fake.cancelNotification() end
package.loaded["schluter.client"] = {
  create = function()
    return fake
  end,
}

local timers = {}
SetTimer = function(name, delay, callback)
  timers[name] = { delay = delay, callback = callback }
end
CancelTimer = function(name)
  timers[name] = nil
end
local function fire(name)
  local timer = timers[name]
  timers[name] = nil
  timer.callback()
  return timer.delay
end

C4.UpdateProperty = function(_, name, value)
  Properties[name] = value
end
C4.GetDriverConfigInfo = function(_, key)
  return ({ minimum_os_version = "3.3.0", version = "20261111", model = "Schluter" })[key]
end
C4.GetVersionInfo = function()
  return { version = "4.3.0" }
end
C4.FireEventByID = function() end
C4.SendToProxy = function() end

--- Runs `path` as the open-source build compiles it: a line its directives leave out is blanked.
local function dofileOss(path)
  local f = assert(io.open(path))
  local lines, stack, including = {}, {}, true
  for line in f:lines() do
    local ifdef, name = line:match("^%s*%-%-%s*#(ifn?def)%s+([%w_]+)%s*$")
    if ifdef then
      stack[#stack + 1] = including
      including = including and (name == "DRIVERCENTRAL") == (ifdef == "ifndef")
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

Properties = {
  ["Email"] = "owner@example.com",
  ["Password"] = "x",
  ["Log Level"] = "3 - Info",
  ["Log Mode"] = "Off",
  ["Automatic Updates"] = "Off",
}
dofileOss(DRIVER)
OnDriverInit()
OnDriverLateInit("DIT_STARTUP")

T.section("a session refused at once is signed in again on a growing wait")
-- Each sign-in's wait, in seconds, until ten minutes have gone by.
local waits, statuses, elapsed = {}, {}, 0
while elapsed < 600 do
  if timers.SchluterLogin then
    elapsed = elapsed + fire("SchluterLogin") / 1000
  elseif timers.SchluterLoginRetry then
    statuses[#statuses + 1] = Properties["Driver Status"]
    local wait = fire("SchluterLoginRetry") / 1000
    waits[#waits + 1] = wait
    elapsed = elapsed + wait
  elseif timers.SchluterNotify then
    elapsed = elapsed + fire("SchluterNotify") / 1000
  else
    break
  end
end
T.eq("seven sign-ins in ten minutes", signIns, 7)
T.eq("each after a longer wait, up to five minutes", waits, { 5, 10, 20, 40, 80, 160, 300 })
T.eq("Driver Status says when, first", statuses[1], "Not connected; retrying in 5s")
T.eq("and last", statuses[#statuses], "Not connected; retrying in 300s")

T.section("once a session works, an expired one is signed in again at once")
refusing = false
fire("SchluterLogin")
T.eq("signed in", Properties["Login Status"], "Logged In")
T.eq("and the long-poll is open", poll ~= nil, true)
-- Schluter expires the session: the long-poll fails fast and the client drops it.
authed = false
signIns = 0
poll:reject("HTTP 401")
fire("SchluterNotify")
T.eq("signed in again with no wait", timers.SchluterLoginRetry, nil)
T.eq("the sign-in is on its way", timers.SchluterLogin ~= nil, true)
fire("SchluterLogin")
T.eq("one sign-in", signIns, 1)

T.finish()
