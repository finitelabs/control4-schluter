--- Driver-wide constants for control4-schluter.
local M = {}

--- Which backend the account driver uses (see schluter.client). "legacy" is the
--- ditra-heat-e-wifi.schluter.com app API, fully working today. "oauth" is the
--- OJ Electronics OpenAPI, enabled once a ClientID is issued.
M.API_MODE = "legacy"

--- Legacy backend host + OJ Electronics `Application` id. Schluter DITRA-HEAT is
--- one brand on the shared OJ cloud; the client is generic (host + application),
--- so sibling brands (e.g. NuHeat) can be added later by changing these.
M.LEGACY_HOST = "https://ditra-heat-e-wifi.schluter.com"
M.LEGACY_APPLICATION = 7

--- C4:SetPropertyAttribs values used by lib.values / lib.utils for runtime
--- property visibility.
M.SHOW_PROPERTY = 0
M.HIDE_PROPERTY = 1

--- Dynamic-binding namespace for thermostat provider bindings on the account
--- driver (see lib.bindings). Keyed by thermostat serial number.
M.BINDING_NAMESPACE = "schluter"

--- Proprietary connection class shared by the account (provider) and the
--- schluter_thermostat companion (consumer). Must match the companion driver.xml.
M.THERMOSTAT_CLASS = "SCHLUTER_THERMOSTAT"

--- `Action` values on a /api/notification response, alongside `SequenceNr` and
--- the embedded `Thermostat`. Taken from the official app's notification handler
--- (com.ojelectronics.microline.DataHelper): 1 and 2 both mean the thermostat was
--- added or updated, 3 means it was removed from the account.
M.NOTIFY_ACTION = {
  ADDED = 1,
  UPDATED = 2,
  REMOVED = 3,
}

--- Proxy commands exchanged across the account ↔ companion binding.
M.CMD = {
  --- account → companion: full thermostat object as {JSON=...}
  UPDATE_THERMOSTAT = "updateThermostat",
  --- account → companion: thermostat is gone / logged out
  GO_OFFLINE = "goOffline",
  --- companion → account: push mutated settings object as {JSON=...}
  SET_THERMOSTAT = "setThermostat",
}

return M
