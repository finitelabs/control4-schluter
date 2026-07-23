<!-- Copyright 2026 Finite Labs, LLC. All rights reserved. -->

<style>
@media print {
   .noprint {
      visibility: hidden;
      display: none;
   }
   * {
        -webkit-print-color-adjust: exact;
        print-color-adjust: exact;
    }
}
</style>

# <span style="color:#f78d1f">Overview</span>

<!-- #ifndef DRIVERCENTRAL -->

> DISCLAIMER: This software is neither affiliated with nor endorsed by either
> Control4 or Schluter.

<!-- #endif -->

The Schluter Thermostat driver represents a single Schluter DITRA-HEAT
floor-heating thermostat as a standard Control4 thermostat. It does not talk to
the cloud itself — it binds to the **Schluter** account driver, which hands it
the device and its live state. The thermostat driver adapts its capabilities
(heat-only, single setpoint, temperature range) to the device it is given.

# <span style="color:#f78d1f">Index</span>

<div style="font-size: small">

- [System Requirements](#system-requirements)
- [Features](#features)
- [Installer Setup](#installer-setup)
- [Support](#support)
- [Changelog](#changelog)

</div>

# <span style="color:#f78d1f">System Requirements</span>

- Control4 OS 3.3.0 or later
- A configured **Schluter** account driver in the same project

# <span style="color:#f78d1f">Features</span>

- Standard Control4 thermostat control (current temperature, setpoint, mode)
- Heat and Off modes with hold options (2 Hours, Hold Until, Permanent)
- Capabilities adapt automatically to the bound thermostat
- Floor temperature exposed as a temperature-value connection

# <span style="color:#f78d1f">Installer Setup</span>

1. Add and log in to the **Schluter** account driver first.
1. Add a **Schluter Thermostat** driver for each thermostat.
1. Bind each thermostat driver's **Schluter Thermostat** connection to the
   matching connection on the Schluter account driver.

The **Serial ID** property shows which Schluter thermostat a driver is bound to.

# <span style="color:#f78d1f">Support</span>

If you have any questions or issues integrating this driver with Control4, you
can file an issue on GitHub:

https://github.com/finitelabs/control4-schluter/issues/new

# <span style="color:#f78d1f">Changelog</span>
