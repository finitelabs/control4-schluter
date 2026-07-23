--- Driver-wide constants for control4-nuheat.
local M = {}

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
