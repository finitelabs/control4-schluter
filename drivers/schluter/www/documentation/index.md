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

The Schluter driver connects Control4 to your Schluter DITRA-HEAT WiFi
floor-heating thermostats through the myschluter.com cloud service. Enter your
Schluter account credentials and each thermostat in your account is exposed as a
connection you bind to a companion **Schluter Thermostat** driver, which appears
in Control4 as a standard thermostat.

# <span style="color:#f78d1f">Index</span>

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

# <span style="color:#f78d1f">System Requirements</span>

- Control4 OS 3.3.0 or later
- A Schluter account at [myschluter.com](https://myschluter.com) with at least
  one thermostat added to a group
- Internet access from the Control4 controller

# <span style="color:#f78d1f">Features</span>

- Cloud login to myschluter.com with your Schluter email and password
- Automatic discovery of every thermostat on the account
- One connection per thermostat, bound to a companion thermostat driver
- Real-time state updates via Schluter's push notifications (no polling delay)
- Reads and controls setpoint, heat/off mode, and hold modes

# <span style="color:#f78d1f">Installer Setup</span>

## Adding the Driver

1. Add the **Schluter** driver to your project.
1. Add a **Schluter Thermostat** driver for each thermostat you want to control.

## Driver Properties

- **Email** — the email address for your Schluter account.
- **Password** — the password for your Schluter account.
- **Login Status** — shows `Logged In` once the credentials are accepted.

## Connecting Thermostats

Once logged in, each thermostat grouped at
[myschluter.com/#groups](https://myschluter.com/#groups) appears as a connection
on the Schluter driver. Bind each one to a **Schluter Thermostat** driver. The
thermostat driver then adapts its capabilities to that device automatically.

# <span style="color:#f78d1f">Support</span>

If you have any questions or issues integrating this driver with Control4, you
can file an issue on GitHub:

https://github.com/finitelabs/control4-schluter/issues/new

# <span style="color:#f78d1f">Changelog</span>
