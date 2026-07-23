--- Driver-wide constants for control4-nuheat.
local M = {}

--- Which NuHeat backend the account driver uses (see nuheat.client). "legacy"
--- is the mynuheat.com app API, fully working today. "oauth" is the official
--- api.mynuheat.com OpenAPI, enabled once a ClientID is issued. Kept a constant
--- for now; promote to a Composer property when the oauth backend goes live.
M.API_MODE = "legacy"

--- C4:SetPropertyAttribs values used by lib.values / lib.utils for runtime
--- property visibility.
M.SHOW_PROPERTY = 0
M.HIDE_PROPERTY = 1

--- Dynamic-binding namespace for thermostat provider bindings on the account
--- driver (see lib.bindings). Keyed by thermostat serial number.
M.BINDING_NAMESPACE = "nuheat"

--- Proprietary connection class shared by the account (provider) and the
--- nuheat_thermostat companion (consumer). Must match the companion driver.xml.
M.THERMOSTAT_CLASS = "NUHEAT_THERMOSTAT"

--- Proxy commands exchanged across the account ↔ companion binding.
M.CMD = {
  --- account → companion: full NuHeat thermostat object as {JSON=...}
  UPDATE_THERMOSTAT = "updateThermostat",
  --- account → companion: thermostat is gone / logged out
  GO_OFFLINE = "goOffline",
  --- companion → account: push mutated settings object as {JSON=...}
  SET_THERMOSTAT = "setThermostat",
}

return M
