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

# <span style="color:#9e2a2f">Overview</span>

<!-- #ifndef DRIVERCENTRAL -->

> DISCLAIMER: This software is neither affiliated with nor endorsed by either
> Control4 or NuHeat.

<!-- #endif -->

The NuHeat driver connects Control4 to your NuHeat Signature WiFi floor-heating
thermostats through the mynuheat.com cloud service. Enter your NuHeat account
credentials and each thermostat in your account is exposed as a connection you
bind to a companion **NuHeat Thermostat** driver, which appears in Control4 as a
standard thermostat.

# <span style="color:#9e2a2f">Index</span>

<div style="font-size: small">

- [System Requirements](#system-requirements)
- [Features](#features)
- [Installer Setup](#installer-setup)
  - [Adding the Driver](#adding-the-driver)
  - [Driver Properties](#driver-properties)
  - [Connecting Thermostats](#connecting-thermostats)
- [Support](#support)
- [Changelog](#changelog)

</div>

# <span style="color:#9e2a2f">System Requirements</span>

- Control4 OS 3.3.0 or later
- A NuHeat account at [mynuheat.com](https://mynuheat.com) with at least one
  thermostat added to a group
- Internet access from the Control4 controller

# <span style="color:#9e2a2f">Features</span>

- Cloud login to mynuheat.com with your NuHeat email and password
- Automatic discovery of every thermostat on the account
- One connection per thermostat, bound to a companion thermostat driver
- Real-time state updates via NuHeat's push notifications (no polling delay)
- Reads and controls setpoint, heat/off mode, and hold modes

# <span style="color:#9e2a2f">Installer Setup</span>

## Adding the Driver

1. Add the **NuHeat** driver to your project.
2. Add a **NuHeat Thermostat** driver for each thermostat you want to control.

## Driver Properties

- **Email** — the email address for your NuHeat account.
- **Password** — the password for your NuHeat account.
- **Login Status** — shows `Logged In` once the credentials are accepted.

## Connecting Thermostats

Once logged in, each thermostat grouped at
[mynuheat.com/#groups](https://mynuheat.com/#groups) appears as a connection on
the NuHeat driver. Bind each one to a **NuHeat Thermostat** driver. The
thermostat driver then adapts its capabilities to that device automatically.

# <span style="color:#9e2a2f">Support</span>

If you have any questions or issues integrating this driver with Control4, you
can file an issue on GitHub:

https://github.com/finitelabs/control4-nuheat/issues/new

# <span style="color:#9e2a2f">Changelog</span>
