--#ifdef DRIVERCENTRAL
-- TODO: assign a DriverCentral product id (DC_PID) before releasing to DC.
DC_PID = nil
DC_X = nil
DC_FILENAME = "schluter.c4z"
--#endif

--#ifndef DRIVERCENTRAL
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
require("drivers-common-public.global.url")

local log = require("lib.logging")
local bindings = require("lib.bindings")
--#ifndef DRIVERCENTRAL
local githubUpdater = require("lib.github-updater")
--#endif
local JSON = require("JSON")

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
    C4:UpdateProperty("Driver Status", string.format("Connected (%d thermostat%s)", #list, #list == 1 and "" or "s"))
  end, function(err)
    log:warn("refreshThermostats failed: %s", err)
    C4:UpdateProperty("Driver Status", "Error retrieving thermostats")
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
    log:info("no valid session; re-authenticating")
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

-- ─── Login ─────────────────────────────────────────────────────────────────

login = function()
  local email = Properties["Email"]
  local password = Properties["Password"]
  if not email or email == "" or not password or password == "" then
    C4:UpdateProperty("Login Status", "Enter email and password")
    C4:UpdateProperty("Driver Status", "Awaiting credentials")
    return
  end
  C4:UpdateProperty("Login Status", "Logging in...")
  C4:UpdateProperty("Driver Status", "Connecting")
  client:authenticate(email, password):next(function()
    gState.sequenceNr = 0
    C4:UpdateProperty("Login Status", "Logged In")
    refreshThermostats()
    restartNotifications()
    -- Reconcile regardless of the notification stream (see RECONCILE_INTERVAL_S).
    SetTimer("SchluterReconcile", RECONCILE_INTERVAL_S * ONE_SECOND, refreshThermostats, true)
  end, function(err)
    client:logout()
    gNotifyGeneration = gNotifyGeneration + 1
    CancelTimer("SchluterNotify")
    CancelTimer("SchluterReconcile")
    C4:UpdateProperty("Login Status", err.message or "Login failed")
    C4:UpdateProperty("Driver Status", "Not connected")
    log:warn("login failed: %s", err.message)
  end)
end

--#ifndef DRIVERCENTRAL
--- Update the driver(s) from the GitHub repository.
--- @param forceUpdate? boolean Force the update even if already up to date.
local function updateDrivers(forceUpdate)
  log:trace("updateDrivers(%s)", forceUpdate)
  githubUpdater
    :updateAll(DRIVER_GITHUB_REPO, DRIVER_FILENAMES, Properties["Update Channel"] == "Prerelease", forceUpdate)
    :next(function(updatedDrivers)
      if updatedDrivers and #updatedDrivers > 0 then
        log:info("Updated driver(s): %s", table.concat(updatedDrivers, ","))
      end
    end, function(err)
      log:warn("driver update failed: %s", err)
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
  log:setLogName(C4:GetDeviceData(C4:GetDeviceID(), "name"))
  log:setLogLevel(Properties["Log Level"])
  log:setLogMode(Properties["Log Mode"])
  log:trace("OnDriverInit()")
end

function OnDriverLateInit()
  log:trace("OnDriverLateInit()")
  bindings:restoreBindings()
  C4:UpdateProperty("Driver Version", C4:GetDriverConfigInfo("version"))
  C4:UpdateProperty("Driver Status", "Initializing")
  login()
  --#ifndef DRIVERCENTRAL
  -- Auto-update: only the leader account instance checks, at most every 30 min,
  -- and only when Automatic Updates is On. The DriverCentral build lets
  -- cloud-client-byte own updates instead.
  SetTimer("AutoUpdate", 30 * ONE_MINUTE, function()
    local isLeader = Select(getAccountDriverIds(), 1) == C4:GetDeviceID()
    if isLeader and toboolean(Properties["Automatic Updates"]) then
      log:info("Checking for driver update (leader instance)")
      updateDrivers()
    end
  end, true)
  --#endif
  gInitialized = true
end

-- ─── Property handlers (OPC dispatch) ──────────────────────────────────────

function OPC.Log_Level(propertyValue)
  log:setLogLevel(propertyValue)
end

function OPC.Log_Mode(propertyValue)
  log:setLogMode(propertyValue)
end

function OPC.Email()
  login()
end

function OPC.Password()
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
  --- Release the in-flight slot and send whatever arrived while we were busy.
  local function done()
    gWriteInFlight[serial] = nil
    local queued = gQueuedWrite[serial]
    if queued then
      gQueuedWrite[serial] = nil
      writeThermostat(serial, queued)
    end
  end
  client:setThermostat(serial, settings):next(function(updated)
    -- Take the next slot in the refresh sequence so any /api/thermostats read
    -- that was already in flight when this write landed is discarded instead of
    -- handing the companion the pre-write state.
    gRefreshIssued = gRefreshIssued + 1
    gRefreshAccepted = gRefreshIssued
    gState.devices[serial] = updated
    handoff(serial)
    done()
  end, function(err)
    log:warn("setThermostat failed for %s: %s", serial, err)
    done()
  end)
end

--- A companion pushes mutated settings for us to write to Schluter.
--- @param idBinding integer
--- @param strCommand string
--- @param tParams table
function RFP.setThermostat(idBinding, strCommand, tParams)
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

function EC.Reset_Driver(tParams)
  log:trace("EC.Reset_Driver()")
  if (tParams or {})["Are You Sure?"] == "Yes" then
    bindings:deleteAllBindings(NS)
    gState.devices = {}
    client:logout()
    C4:UpdateProperty("Login Status", "")
    login()
  end
end

--#ifndef DRIVERCENTRAL
function EC.Update_Drivers()
  log:trace("EC.Update_Drivers()")
  updateDrivers(true)
end
--#endif
