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

<img alt="Schluter Thermostat" src="./images/header.png" width="500"/>

______________________________________________________________________

# <span style="color:#f78d1f">Overview</span>

<!-- #ifndef DRIVERCENTRAL -->

> DISCLAIMER: This software is neither affiliated with nor endorsed by either
> Control4 or Schluter-Systems.

<!-- #endif -->

This driver represents a single Schluter DITRA-HEAT floor-heating thermostat as
a native Control4 thermostat, through the Control4 ThermostatV2 proxy. It does
not talk to the cloud itself — it binds to the **Schluter** account driver,
which hands it the device and its live state. The driver adapts its capabilities
(heat-only, single setpoint, temperature range, schedule) to the device it is
given.

# <span style="color:#f78d1f">Index</span>

<div style="font-size: small">

- [System Requirements](#system-requirements)
- [Features](#features)
- [Compatibility](#compatibility)
- [Installer Setup](#installer-setup)
  - [Adding the Driver](#adding-the-driver)
  - [Driver Properties](#driver-properties)
    <!-- #ifdef DRIVERCENTRAL -->
    - [Cloud Settings](#cloud-settings)
    <!-- #endif -->
    - [Driver Settings](#driver-settings)
  - [Connections](#connections)
- [Scheduling](#scheduling)

<!-- #ifdef DRIVERCENTRAL -->

- [Developer Information](#developer-information)

<!-- #endif -->

- [Support](#support)
- [Changelog](#changelog)

</div>

<div style="page-break-after: always"></div>

# <span style="color:#f78d1f">System Requirements</span>

- Control4 OS 3.3.0 or later
- A configured **Schluter** account driver in the same project, signed in and
  reporting at least one thermostat

# <span style="color:#f78d1f">Features</span>

- Native Control4 ThermostatV2 proxy integration
- Current floor temperature, single setpoint, and Heat/Off mode
- Hold options (2 Hours, Hold Until, Permanent)
- Full weekly schedule read and edit via the native Control4 scheduling UI
- Capabilities (setpoint range, schedule) adapt automatically to the bound
  device
- Floor temperature exposed as a temperature-value connection for other drivers
- Temperature values communicated in Celsius — the Control4 proxy handles
  display conversion to the project's configured scale

# <span style="color:#f78d1f">Compatibility</span>

Works with any Schluter DITRA-HEAT-E-WiFi thermostat discovered by the
**Schluter** account driver. Schluter DITRA-HEAT is heat-only with a single
setpoint, so cooling and dual-setpoint capabilities are not advertised.

# <span style="color:#f78d1f">Installer Setup</span>

Refer to the main **Schluter** account driver documentation for account sign-in.
Once the account driver is signed in and reporting thermostats, bind this driver
to one of them.

## Adding the Driver

1. In Composer Pro, add the **Schluter Thermostat** driver to your project.
1. In the "Connections" tab, bind this driver's **Schluter Thermostat**
   connection to the thermostat exposed by the **Schluter** account driver.
1. The driver automatically synchronizes its state, capabilities, and schedule
   once bound. The **Serial ID** property shows which thermostat it is bound to.

## Driver Properties

<!-- #ifdef DRIVERCENTRAL -->

### Cloud Settings

#### Cloud Status (read-only)

Displays the DriverCentral cloud license status.

#### Automatic Updates \[ Off | **_On_** \]

Enables or disables automatic driver updates via DriverCentral.

<!-- #endif -->

### Driver Settings

#### Driver Status (read-only)

Displays the current status (e.g. `Online`, `Offline`, or
`Waiting for thermostat`).

#### Driver Version (read-only)

Displays the current version of the driver.

#### Serial ID (read-only)

The serial number of the Schluter thermostat this driver is bound to.

#### Log Level \[ 0 - Fatal | 1 - Error | 2 - Warning | **_3 - Info_** | 4 - Debug | 5 - Trace | 6 - Ultra \]

Sets the logging level. Default is `3 - Info`.

#### Log Mode \[ **_Off_** | Print | Log | Print and Log \]

Sets the logging mode. Default is `Off`.

## Connections

### Thermostat (provider)

The Control4 ThermostatV2 proxy connection, automatically managed by the driver.
Program against this like any Control4 thermostat.

### Schluter Thermostat (consumer)

Bind this to a thermostat exposed by the **Schluter** account driver. This is
how the driver receives its device and live state.

### Temperature (provider)

Outputs the thermostat's current floor temperature to other Control4 drivers via
a `TEMPERATURE_VALUE` connection (both Celsius and Fahrenheit).

# <span style="color:#f78d1f">Scheduling</span>

The thermostat's weekly schedule is read from Schluter and shown in the native
Control4 thermostat scheduling UI, with four events per day (Wake, Leave,
Return, Sleep). Editing an event in Control4 writes it back to the thermostat.

Schluter groups days that share the same program (for example all weekdays):
editing any day in a group updates the whole group, matching the thermostat's
own behavior. To control a day independently, separate it from its group in the
Schluter DITRA-HEAT WiFi app first.

<!-- #ifdef DRIVERCENTRAL -->

# <span style="color:#f78d1f">Developer Information</span>

<p align="center">
<img alt="Finite Labs" src="./images/finite-labs-logo.png" width="400"/>
</p>

Copyright © 2026 Finite Labs LLC

All information contained herein is, and remains the property of Finite Labs LLC
and its suppliers, if any. The intellectual and technical concepts contained
herein are proprietary to Finite Labs LLC and its suppliers and may be covered
by U.S. and Foreign Patents, patents in process, and are protected by trade
secret or copyright law. Dissemination of this information or reproduction of
this material is strictly forbidden unless prior written permission is obtained
from Finite Labs LLC. For the latest information, please visit
https://drivercentral.io/platforms/control4-drivers/utility/schluter

<!-- #endif -->

# <span style="color:#f78d1f">Support</span>

<!-- #ifdef DRIVERCENTRAL -->

If you have any questions or issues integrating this driver with Control4, you
can contact us at
[driver-support@finitelabs.com](mailto:driver-support@finitelabs.com) or
call/text us at [+1 (949) 371-5805](tel:+19493715805).

<!-- #else -->

If you have any questions or issues integrating this driver with Control4, you
can file an issue on GitHub:

https://github.com/finitelabs/control4-schluter/issues/new

<a href="https://www.buymeacoffee.com/derek.miller" target="_blank"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me A Coffee" style="height: 60px !important;width: 217px !important;" ></a>

<!-- #endif -->

<div style="page-break-after: always"></div>

<!-- #embed-changelog -->
