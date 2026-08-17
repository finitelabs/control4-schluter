-- Schluter account coordinator.
--
-- Owns the single cloud session for the whole Schluter (DITRA-HEAT) account,
-- discovers the account's thermostats, and exposes a dynamic PROXY binding per
-- thermostat that the schluter_thermostat companion drivers bind to. Companions
-- receive the full thermostat object over the binding (UPDATE_THERMOSTAT) and
-- push mutated settings back (setThermostat); the coordinator runs the
-- notification long-poll and serializes/coalesces companion writes because the
-- cloud host will not run a POST alongside the long-poll it holds open.

--#ifdef DRIVERCENTRAL
DC_PID = 0 -- TODO: Assign DriverCentral product ID
DC_X = nil
DC_FILENAME = "schluter.c4z"
--#else
DRIVER_GITHUB_REPO = "finitelabs/control4-schluter"
DRIVER_FILENAMES = {
  "schluter.c4z",
  "schluter_thermostat.c4z",
}
--#endif

require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

JSON = require("JSON")

local log = require("lib.logging")
local bindings = require("lib.bindings")
--#ifndef DRIVERCENTRAL
local githubUpdater = require("lib.github-updater")
--#endif

local clientFactory = require("schluter.client")
local constants = require("constants")

local NS = constants.BINDING_NAMESPACE
local CMD = constants.CMD
local ACTION = constants.NOTIFY_ACTION

-- The backend (legacy Schluter app API or official OAuth) owns its own session;
-- the driver is backend-agnostic and only speaks the client contract.
local client = clientFactory.create(constants.API_MODE, {
  host = constants.LEGACY_HOST,
  applicationId = constants.LEGACY_APPLICATION,
})

--- Runtime state (not persisted; rebuilt on login).
local gState = {
  --- @type number Notification cursor (legacy long-poll; ignored by oauth).
  sequenceNr = 0,
  --- @type table<string, table> serial number -> latest Schluter thermostat object
  devices = {},
}

--- Incremented on every login so a long-poll loop started by an earlier login
--- retires itself instead of running forever alongside the new one. Without this,
--- each re-login (credential edit, Reset Driver) leaves its loop in flight; they
--- accumulate, and their overlapping refreshes can deliver an *older* snapshot
--- after a newer one and stomp good state.
--- @type integer
local gNotifyGeneration = 0

--- Monotonic ids for thermostat refreshes, so a slow response that started before
--- a newer one can't overwrite the newer result.
--- @type integer
local gRefreshIssued = 0
--- @type integer
local gRefreshAccepted = 0

--- Set true once OnDriverLateInit finishes; guards the property-sync handlers
--- from firing while Composer loads the initial property values.
local gInitialized = false

--- True from the moment a login is armed until its authenticate settles. The
--- write path checks this before resuming the long-poll: reopening it while a
--- login is waiting out its grace period (or is mid-POST) hands authenticate
--- the connection contention the grace period exists to avoid.
local gLoginPending = false

--- All schluter account instances on this controller, sorted by device id. Used
--- for leader election (lowest id is the leader that runs updates).
--- @return integer[]
local function getAccountDriverIds()
  local drivers = C4:GetDevicesByC4iName(C4:GetDriverFileName()) or {}
  local ids = {}
  for id in pairs(drivers) do
    ids[#ids + 1] = tonumber(id)
  end
  table.sort(ids)
  return ids
end

--#ifndef DRIVERCENTRAL
--- Mirror an updater property to the other account instances so they stay
--- consistent (only the leader instance actually performs updates).
--- @param propertyName string
--- @param propertyValue string
local function syncPropertyToOtherInstances(propertyName, propertyValue)
  local myId = C4:GetDeviceID()
  for _, deviceId in ipairs(getAccountDriverIds()) do
    if deviceId ~= myId then
      SetDeviceProperties(deviceId, { [propertyName] = propertyValue }, true)
    end
  end
end
--#endif

-- ─── Companion handoff ─────────────────────────────────────────────────────

--- Push a thermostat's current object to its bound companion (if any).
--- @param serial string
local function handoff(serial)
  local device = gState.devices[serial]
  local binding = bindings:getDynamicBinding(NS, serial)
  if not device or not binding then
    return
  end
  SendToProxy(binding.bindingId, CMD.UPDATE_THERMOSTAT, { JSON = JSON:encode(device) })
end

--- Resolve the serial number behind a dynamic binding id.
--- @param idBinding integer
--- @return string|nil serial
local function serialForBinding(idBinding)
  for serial, binding in pairs(bindings:getDynamicBindings(NS)) do
    if binding.bindingId == idBinding then
      return serial
    end
  end
  return nil
end

-- ─── Thermostat discovery ──────────────────────────────────────────────────

--- Store a thermostat object, ensure its provider binding exists, register a
--- bind handler that (re)hands the device off when a companion connects, and
--- push the current state to any companion already bound.
--- @param device table Schluter thermostat object
local function ingestThermostat(device)
  local serial = tostring(device.SerialNumber)
  if serial == "nil" or serial == "" then
    return
  end
  gState.devices[serial] = device
  local binding = bindings:getOrAddDynamicBinding(
    NS,
    serial,
    "PROXY",
    true,
    device.Room or device.GroupName or ("Schluter " .. serial),
    constants.THERMOSTAT_CLASS
  )
  if binding then
    -- OnBindingChanged is dispatched per binding id (see OBC in handlers.lua):
    -- hand off the current device whenever a companion binds.
    OBC[binding.bindingId] = function(_idBinding, _strClass, bIsBound)
      if bIsBound then
        handoff(serial)
      end
    end
  end
  handoff(serial)
end

--- The connected status line for a given thermostat count.
local function connectedStatus(count)
  return string.format("Connected (%d thermostat%s)", count, count == 1 and "" or "s")
end

--- How many thermostats we currently hold.
local function thermostatCount()
  local count = 0
  for _ in pairs(gState.devices) do
    count = count + 1
  end
  return count
end

--- Fetch the full thermostat list for the account and ingest each. Responses are
--- accepted in issue order only: with several refreshes in flight (a notification
--- and the safety-net poll can overlap) a slow earlier response would otherwise
--- land last and hand a stale device to the companion.
local function refreshThermostats()
  if not client:isAuthenticated() then
    return
  end
  gRefreshIssued = gRefreshIssued + 1
  local refreshId = gRefreshIssued
  client:getThermostats():next(function(list)
    if type(list) ~= "table" then
      return
    end
    if refreshId < gRefreshAccepted then
      log:trace("discarding stale thermostat refresh %d (accepted %d)", refreshId, gRefreshAccepted)
      return
    end
    gRefreshAccepted = refreshId
    for _, device in ipairs(list) do
      ingestThermostat(device)
    end
    C4:UpdateProperty("Driver Status", connectedStatus(#list))
  end, function(err)
    log:warn("refreshThermostats failed: %s", err)
    -- The notification long-poll keeps known thermostats current and drives this
    -- list read even for heartbeats that carry no device, so a transient failure
    -- here (e.g. an API timeout) must not mask a healthy connection. Keep
    -- reporting the thermostats we hold; only surface the error before discovery.
    local count = thermostatCount()
    if count == 0 then
      C4:UpdateProperty("Driver Status", "Error retrieving thermostats")
    else
      C4:UpdateProperty("Driver Status", connectedStatus(count))
    end
  end)
end

-- ─── Real-time notification long-poll ──────────────────────────────────────

--- Floor between polls. The server normally holds the request open for minutes,
--- but it answers immediately when it has a backlog — or when something is wrong
--- (expired session, error body returned with HTTP 200). Without a floor those
--- immediate returns re-arm in a tight loop that hammers the API.
local NOTIFY_MIN_INTERVAL_S = 2
--- Backoff after a failed poll, and the ceiling it grows to.
local NOTIFY_RETRY_S = 5
local NOTIFY_RETRY_MAX_S = 60
--- A poll that survived at least this long before failing was a healthy
--- long-poll that simply expired, not a broken connection worth backing off from.
local NOTIFY_HEALTHY_RUN_S = 30
--- Safety net: the long-poll is the only thing that refreshes state, so if the
--- notification stream silently stops (dropped connection, session expiry) the
--- driver would sit on a stale device forever. Reconcile on this cadence too.
local RECONCILE_INTERVAL_S = 5 * 60

--- @type fun(generation: integer, backoffS: number): void
local armNotifications
--- Forward declaration: the notification loop re-authenticates when the server
--- expires our session out from under us.
--- @type fun(): void
local login

armNotifications = function(generation, backoffS)
  if generation ~= gNotifyGeneration then
    -- Retired by a newer login. Let this loop die.
    return
  end
  if not client:isAuthenticated() then
    -- The session expired (a 401 clears it in the client). Log in again; a
    -- successful login restarts the loop on a fresh generation.
    log:info("No valid session; re-authenticating")
    login()
    return
  end
  local startedAt = os.time()
  client:getNotification(gState.sequenceNr):next(function(obj)
    if generation ~= gNotifyGeneration then
      return
    end
    if obj and obj.SequenceNr then
      gState.sequenceNr = tonumber(obj.SequenceNr) + 1
    end
    -- The notification body embeds the changed thermostat in full (same 34-field
    -- object /api/thermostats returns, Schedules included), so consume it
    -- directly instead of re-reading the whole account on every poll. That is
    -- what the official app does, and it removes a request per cycle from a host
    -- that is already holding this long-poll open. Only fall back to a full read
    -- when the payload carries no usable device, or the serial is one we have
    -- not seen (a thermostat added or moved between groups).
    local device = obj and obj.Thermostat
    local serial = type(device) == "table" and tostring(device.SerialNumber) or nil
    if obj and tonumber(obj.Action) == ACTION.REMOVED and serial then
      gState.devices[serial] = nil
      local binding = bindings:getDynamicBinding(NS, serial)
      if binding then
        SendToProxy(binding.bindingId, CMD.GO_OFFLINE, {})
      end
    elseif serial and serial ~= "nil" and serial ~= "" and gState.devices[serial] then
      -- Claim a refresh slot so an /api/thermostats read already in flight can't
      -- land afterwards and overwrite this newer state.
      gRefreshIssued = gRefreshIssued + 1
      gRefreshAccepted = gRefreshIssued
      ingestThermostat(device)
    else
      refreshThermostats()
    end
    local elapsed = os.time() - startedAt
    local delay = math.max(NOTIFY_MIN_INTERVAL_S - elapsed, 0)
    if delay > 0 then
      SetTimer("SchluterNotify", delay * ONE_SECOND, function()
        armNotifications(generation, NOTIFY_RETRY_S)
      end)
    else
      armNotifications(generation, NOTIFY_RETRY_S)
    end
  end, function(err)
    if generation ~= gNotifyGeneration then
      return
    end
    -- A poll that ran a long time before failing is just the long-poll expiring
    -- with nothing to report — normal, so re-arm promptly at the base delay.
    -- Only a *fast* failure (auth, DNS, refused) earns a growing backoff.
    local expired = (os.time() - startedAt) >= NOTIFY_HEALTHY_RUN_S
    local delay = expired and NOTIFY_RETRY_S or (backoffS or NOTIFY_RETRY_S)
    log:trace("notification poll ended after %ds (%s); re-arming in %ds", os.time() - startedAt, err, delay)
    SetTimer("SchluterNotify", delay * ONE_SECOND, function()
      armNotifications(generation, expired and NOTIFY_RETRY_S or math.min(delay * 2, NOTIFY_RETRY_MAX_S))
    end)
  end)
end

--- Retire any in-flight notification loop and start a fresh one.
local function restartNotifications()
  gNotifyGeneration = gNotifyGeneration + 1
  CancelTimer("SchluterNotify")
  armNotifications(gNotifyGeneration, NOTIFY_RETRY_S)
end

--- Retire the notification loop *and* abort the long-poll it is holding open.
---
--- Measured on the controller: with the long-poll in flight, 4 of 7 writes died
--- at a 30s timeout and the survivors took 17-30s; with it stopped, 8 of 8
--- completed in under a second. The controller will not run a POST alongside the
--- held connection, so a write has to take that connection back first. Retiring
--- the generation alone is not enough — that only makes us ignore the response
--- while the socket stays open — hence the explicit cancel.
local function suspendNotifications()
  gNotifyGeneration = gNotifyGeneration + 1
  CancelTimer("SchluterNotify")
  if type(client.cancelNotification) == "function" then
    client:cancelNotification()
  end
end

--- Grace period between aborting the long-poll and issuing the write. Cancelling
--- a transfer may not release its connection synchronously.
local WRITE_DELAY_MS = 600
--- A write slower than this is worth surfacing: it means the POST was queued
--- behind the notification connection rather than going out cleanly.
local SLOW_WRITE_S = 5

--- Backoff after a login that failed for a retryable reason, and the ceiling it
--- grows to. Deliberately slower than the notification ladder: a login is a
--- credentialed POST, not a poll, so there is no reason to hammer it.
local LOGIN_RETRY_S = 5
local LOGIN_RETRY_MAX_S = 300

-- ─── Login ─────────────────────────────────────────────────────────────────

--- @param retryBackoffS number|nil Delay before the next attempt if this one
--- fails retryably, doubling up to LOGIN_RETRY_MAX_S. Omitted by every
--- user-initiated login (init, a credential edit, Reconnect), which starts the
--- ladder over; only the retry timer below passes it.
login = function(retryBackoffS)
  -- Stop first, before the checks below can short-circuit, so no earlier
  -- generation keeps polling behind an "Awaiting credentials" or failed login.
  -- suspendNotifications (not a bare generation bump) because authenticate()
  -- POSTs, and a POST will not run alongside the held long-poll: the same
  -- contention the write path measured. Also drop any login already armed
  -- below, and any pending retry, so the newest call wins.
  suspendNotifications()
  CancelTimer("SchluterReconcile")
  CancelTimer("SchluterLogin")
  CancelTimer("SchluterLoginRetry")
  gLoginPending = false
  local email = Properties["Email"]
  local password = Properties["Password"]
  if IsEmpty(email) or IsEmpty(password) then
    client:logout()
    C4:UpdateProperty("Login Status", "Enter email and password")
    C4:UpdateProperty("Driver Status", "Awaiting credentials")
    return
  end
  C4:UpdateProperty("Login Status", "Logging in...")
  C4:UpdateProperty("Driver Status", "Connecting")
  -- Same grace period the write path uses: aborting the long-poll does not
  -- necessarily release its connection inline. Status is already updated, so
  -- the UI does not wait on this.
  gLoginPending = true
  SetTimer("SchluterLogin", WRITE_DELAY_MS, function()
    client:authenticate(email, password):next(function()
      gLoginPending = false
      gState.sequenceNr = 0
      C4:UpdateProperty("Login Status", "Logged In")
      refreshThermostats()
      restartNotifications()
      -- Reconcile regardless of the notification stream (see RECONCILE_INTERVAL_S).
      SetTimer("SchluterReconcile", RECONCILE_INTERVAL_S * ONE_SECOND, refreshThermostats, true)
    end, function(err)
      gLoginPending = false
      client:logout()
      C4:UpdateProperty("Login Status", err.message or "Login failed")
      log:warn("Login failed: %s", err.message)
      -- ErrorCode 1/2 is the server rejecting the credentials themselves (see
      -- Client:authenticate). Retrying replays a known-bad password and risks
      -- the account being locked, and editing Email or Password re-fires login
      -- on its own, so stop here. Everything else is a transport or server-side
      -- failure, where stopping leaves the driver at "Not connected" for the
      -- rest of the controller's uptime with every companion offline. The case
      -- that motivates this is a controller rebooting after a power cut and
      -- reaching OnDriverLateInit before the WAN is up.
      if err.errorCode == 1 or err.errorCode == 2 then
        C4:UpdateProperty("Driver Status", "Not connected")
        return
      end
      local delay = retryBackoffS or LOGIN_RETRY_S
      C4:UpdateProperty("Driver Status", string.format("Not connected; retrying in %ds", delay))
      SetTimer("SchluterLoginRetry", delay * ONE_SECOND, function()
        login(math.min(delay * 2, LOGIN_RETRY_MAX_S))
      end)
    end)
  end)
end

--#ifndef DRIVERCENTRAL
--- Update the driver(s) from the GitHub repository.
--- @param forceUpdate? boolean Force the update even if already up to date.
function UpdateDrivers(forceUpdate)
  log:trace("UpdateDrivers(%s)", forceUpdate)
  githubUpdater
    :updateAll(DRIVER_GITHUB_REPO, DRIVER_FILENAMES, Properties["Update Channel"] == "Prerelease", forceUpdate)
    :next(function(updatedDrivers)
      if updatedDrivers and #updatedDrivers > 0 then
        log:info("Updated driver(s): %s", table.concat(updatedDrivers, ","))
      end
    end, function(err)
      log:warn("Driver update failed: %s", err)
    end)
end
--#endif

-- ─── Lifecycle ─────────────────────────────────────────────────────────────

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

  -- Re-add persisted dynamic bindings. This must happen here, not in
  -- OnDriverLateInit: Director resolves stored connections before LateInit
  -- (see src/lib/bindings.lua).
  bindings:restoreBindings()
end

function OnDriverLateInit()
  log:trace("OnDriverLateInit()")
  if not CheckMinimumVersion("Driver Status") then
    return
  end

  for p, _ in pairs(Properties) do
    local ok, err = pcall(OnPropertyChanged, p)
    if not ok then
      log:error("OnPropertyChanged('%s') failed: %s", p, tostring(err))
    end
  end

  --#ifndef DRIVERCENTRAL
  -- Auto-update: only the leader account instance checks, at most every 30 min,
  -- and only when Automatic Updates is On. The DriverCentral build lets
  -- cloud-client-byte own updates instead.
  SetTimer("UpdateCheck", 30 * ONE_MINUTE, function()
    local isLeader = Select(getAccountDriverIds(), 1) == C4:GetDeviceID()
    if isLeader and toboolean(Properties["Automatic Updates"]) then
      log:info("Checking for driver update (leader instance)")
      UpdateDrivers()
    end
  end, true)
  --#endif

  gInitialized = true
  login()
end

function OnDriverDestroyed()
  gNotifyGeneration = gNotifyGeneration + 1
  CancelTimer("SchluterNotify")
  CancelTimer("SchluterReconcile")
  CancelTimer("SchluterLogin")
  CancelTimer("SchluterLoginRetry")
  CancelTimer("UpdateCheck")
  gLoginPending = false
  if type(client.cancelNotification) == "function" then
    client:cancelNotification()
  end
end

-- ─── Property handlers (OPC dispatch) ──────────────────────────────────────

function OPC.Driver_Status(_v)
  if not gInitialized then
    UpdateProperty("Driver Status", "Initializing", false)
  end
end

function OPC.Driver_Version(_v)
  C4:UpdateProperty("Driver Version", C4:GetDriverConfigInfo("version"))
end

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

function OPC.Email()
  if not gInitialized then
    return
  end
  login()
end

function OPC.Password()
  if not gInitialized then
    return
  end
  login()
end

function OPC.Automatic_Updates(propertyValue)
  --#ifndef DRIVERCENTRAL
  if not gInitialized then
    return
  end
  syncPropertyToOtherInstances("Automatic Updates", propertyValue)
  --#endif
end

--#ifndef DRIVERCENTRAL
function OPC.Update_Channel(propertyValue)
  if not gInitialized then
    return
  end
  syncPropertyToOtherInstances("Update Channel", propertyValue)
end
--#endif

-- ─── Messages from a companion (RFP dispatch) ──────────────────────────────

--- Serial numbers with a POST in flight, and the most recent settings that
--- arrived while it was. The companion re-POSTs its intended state every 12s
--- until the cloud confirms, so without coalescing a single user action stacks
--- several concurrent writes against a host that is already holding a long-poll
--- open — which is how requests started timing out.
--- @type table<string, boolean>
local gWriteInFlight = {}
--- @type table<string, table>
local gQueuedWrite = {}

--- @type fun(serial: string, settings: table): void
local writeThermostat

writeThermostat = function(serial, settings)
  gWriteInFlight[serial] = true
  -- Take the connection back from the long-poll before POSTing (see
  -- suspendNotifications), otherwise this write is likely to time out.
  suspendNotifications()
  --- Release the in-flight slot and send whatever arrived while we were busy,
  --- resuming the notification stream once nothing is left to write.
  local function done()
    gWriteInFlight[serial] = nil
    local queued = gQueuedWrite[serial]
    if queued then
      gQueuedWrite[serial] = nil
      -- Re-check the session. RFP.setThermostat gated on it before the POST
      -- this is completing, and a write held open is exactly the window where
      -- the session gets rejected, so the replay must not inherit that stale
      -- decision. Dropping the settings is safe: every push carries the full
      -- object, so the companion re-sends on its next retry once login() has
      -- re-established the session.
      if client:isAuthenticated() then
        writeThermostat(serial, queued)
        return
      end
      log:warn("Dropped a queued write for %s: session was lost while a write was in flight", serial)
    end
    -- Not while a login is armed or in flight: resuming the poll here would
    -- hand authenticate() the held connection back, which is exactly what
    -- login()'s grace period is trying to keep clear. The login's own success
    -- handler restarts the stream.
    if next(gWriteInFlight) == nil and not gLoginPending then
      restartNotifications()
    end
  end
  -- Give the cancelled long-poll a moment to actually release its connection
  -- before we POST; aborting a transfer does not necessarily free it inline.
  SetTimer("SchluterWrite_" .. serial, WRITE_DELAY_MS, function()
    local t0 = os.time()
    client:setThermostat(serial, settings):next(function(updated)
      -- Take the next slot in the refresh sequence so any /api/thermostats read
      -- that was already in flight when this write landed is discarded instead of
      -- handing the companion the pre-write state.
      gRefreshIssued = gRefreshIssued + 1
      gRefreshAccepted = gRefreshIssued
      gState.devices[serial] = updated
      handoff(serial)
      local elapsed = os.time() - t0
      if elapsed >= SLOW_WRITE_S then
        log:warn("Write to %s took %ds (long-poll connection contention)", serial, elapsed)
      end
      done()
    end, function(err)
      log:warn("setThermostat failed for %s after %ds: %s", serial, os.time() - t0, err)
      done()
    end)
  end)
end

--- A companion pushes mutated settings for us to write to Schluter.
--- @param idBinding integer
--- @param _strCommand string
--- @param tParams table
function RFP.setThermostat(idBinding, _strCommand, tParams)
  log:trace("RFP.setThermostat(%s)", idBinding)
  local serial = serialForBinding(idBinding)
  if not serial or not client:isAuthenticated() then
    return
  end
  local ok, settings = pcall(JSON.decode, JSON, (tParams or {}).JSON or "")
  if not ok or type(settings) ~= "table" then
    return
  end
  if gWriteInFlight[serial] then
    -- Coalesce: keep only the newest intent and send it when the current POST
    -- finishes. Nothing is lost, because each push carries the full object.
    log:trace("write already in flight for %s; coalescing", serial)
    gQueuedWrite[serial] = settings
    return
  end
  writeThermostat(serial, settings)
end

-- ─── Actions (EC dispatch) ─────────────────────────────────────────────────

function EC.Refresh_Thermostats()
  log:trace("EC.Refresh_Thermostats()")
  refreshThermostats()
end

--- Drop the current session and log in again. Unlike Reset Driver, this leaves
--- the dynamic companion bindings (and cached devices) untouched.
function EC.Reconnect()
  log:trace("EC.Reconnect()")
  client:logout()
  login()
end

function EC.Reset_Driver(tParams)
  log:trace("EC.Reset_Driver()")
  if (tParams or {})["Are You Sure?"] == "Yes" then
    bindings:reset()
    gState.devices = {}
    client:logout()
    C4:UpdateProperty("Login Status", "")
    login()
  end
end

--#ifndef DRIVERCENTRAL
function EC.Update_Drivers()
  log:trace("EC.Update_Drivers()")
  UpdateDrivers(true)
end
--#endif
