--- NuHeat client factory + backend contract.
---
--- The account/companion drivers talk to NuHeat only through a `NuHeatClient`,
--- never to a concrete backend. Two interchangeable backends implement the same
--- contract so either can be dropped in:
---
---   * `nuheat.client.legacy` — the undocumented mynuheat.com app API
---     (email/password session, thermostat + schedule ride in one object).
---     Fully functional today; used to verify all features.
---   * `nuheat.client.oauth`  — the documented OpenAPI at api.mynuheat.com
---     (OAuth2/OpenID, dedicated Thermostat/Schedule endpoints). Drop-in
---     replacement, enabled once a ClientID is issued by NuHeat.
---
--- Both backends own their own auth/session state and speak the same canonical
--- thermostat object shape (the legacy mynuheat.com shape — see
--- docs/nuheat-api-reference.md and nuheat.thermostat), so the drivers are
--- backend-agnostic. The oauth backend translates the OpenAPI models to/from
--- that canonical shape internally.
---
--- Contract (every method returns a Deferred unless noted):
---   authenticate(email, password) -> resolves true once a session/token is held
---   isAuthenticated()             -> boolean (NOT deferred)
---   logout()                      -> void (NOT deferred)
---   getThermostats()              -> canonical thermostat object[]
---   getThermostat(serial)         -> canonical thermostat object
---   setThermostat(serial, settings) -> writes a mutated object (setpoint / mode /
---                                       hold, and/or Schedules[]); resolves the
---                                       updated object
---   getSchedule(serial)           -> canonical Schedules[] array
---   setSchedule(serial, schedules) -> writes Schedules[]; resolves updated object
---   getNotification(sequenceNr)   -> resolves { SequenceNr = n } when a change is
---                                     seen (legacy long-poll; oauth polls)

local M = {}

--- Backend identifiers.
M.LEGACY = "legacy"
M.OAUTH = "oauth"

--- Construct a client backend.
--- @param kind string|nil One of M.LEGACY (default) or M.OAUTH.
--- @param config table|nil Backend config (oauth: clientId/clientSecret/scopes).
--- @return table client A NuHeatClient implementing the contract above.
function M.create(kind, config)
  kind = kind or M.LEGACY
  -- Lazy require so a build only bundles the backend it actually uses (the
  -- squishy generator discovers modules via the require graph).
  if kind == M.OAUTH then
    return require("nuheat.client.oauth"):new(config)
  end
  return require("nuheat.client.legacy"):new(config)
end

return M
