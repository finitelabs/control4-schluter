<!-- Copyright 2026 Finite Labs, LLC. All rights reserved. -->

<img alt="Schluter" src="./images/header.png" width="275"/>

______________________________________________________________________

# <span style="color:#f78d1f">Overview</span>

> DISCLAIMER: This software is neither affiliated with nor endorsed by either
> Control4 or Schluter-Systems.

Integrate [Schluter DITRA-HEAT-E-WiFi](https://www.schluter.com) floor-heating
thermostats into Control4. This account driver signs in to your Schluter
DITRA-HEAT WiFi account, discovers every thermostat on it, and exposes each one
as a connection you bind to a companion **Schluter Thermostat** driver, which
appears in Control4 as a native thermostat with setpoint, mode, and schedule
control.

Schluter DITRA-HEAT is built on the OJ Electronics cloud platform, so this
driver talks to the same REST API the Schluter DITRA-HEAT WiFi app uses.

# <span style="color:#f78d1f">Index</span>

<div style="font-size: small">

- [System Requirements](#system-requirements)

- [Included Drivers](#included-drivers)

  - [Schluter](#schluter)
  - [Schluter Thermostat](#schluter-thermostat)

- [Compatibility](#compatibility)

- [Installer Setup](#installer-setup)

  - [Driver Installation](#driver-installation)
  - [Driver Setup](#driver-setup)
    - [Driver Properties](#driver-properties)
      - [Cloud Settings](#cloud-settings)
      - [Account Settings](#account-settings)
      - [Driver Settings](#driver-settings)
    - [Driver Actions](#driver-actions)
  - [Programming Reference](#programming-reference)

- [Support](#support)

- [Changelog](#changelog)

</div>

# <span style="color:#f78d1f">System Requirements</span>

- Control4 OS 3.3.0 or later
- A Schluter DITRA-HEAT-E-WiFi account with at least one thermostat set up in
  the [Schluter DITRA-HEAT WiFi app](https://ditra-heat-e-wifi.schluter.com)
- Internet access from the Control4 controller

# <span style="color:#f78d1f">Included Drivers</span>

## Schluter

The account driver, and the driver to add first. Enter your Schluter DITRA-HEAT
WiFi account email and password and it signs in to the cloud, discovers every
thermostat on the account, and creates a connection for each one. The **Schluter
Thermostat** drivers bind to those connections, so the account driver is the
only place credentials are entered and the only cloud connection that is opened.

**Key features:**

- Cloud sign-in with your Schluter DITRA-HEAT WiFi email and password
- Automatic discovery of every thermostat on the account
- One connection per thermostat, each bound to a companion thermostat driver
- Real-time state updates via the cloud's push notifications (no polling delay)

## Schluter Thermostat

The companion driver. Add one per physical thermostat and bind it to a
thermostat connection on the account driver. Each one appears in Control4 as a
native thermostat with setpoint, mode, and schedule control.

**Key features:**

- Setpoint, Heat/Off mode, and hold control
- Full weekly schedule read and edit through the native Control4 thermostat
  scheduling UI
- Temperature values communicated in Celsius, with the Control4 proxy handling
  display conversion to the project's configured scale

# <span style="color:#f78d1f">Compatibility</span>

This driver works with Schluter DITRA-HEAT-E-WiFi thermostats (DITRA-HEAT-E-RS1
/ DITRA-HEAT-E-RT1) managed through the Schluter DITRA-HEAT WiFi app. Because
Schluter DITRA-HEAT shares the OJ Electronics cloud platform with sibling
brands, the underlying API is the same one used by those apps.

If you have a model that works and is not listed, please
[open an issue](https://github.com/finitelabs/control4-schluter/issues/new) so
it can be added.

# <span style="color:#f78d1f">Installer Setup</span>

> ⚠️ Only a **_single_** Schluter account driver instance is required per
> Schluter account. Add one **Schluter Thermostat** driver per physical
> thermostat.

## Driver Installation

Driver installation and setup are similar to most other ip-based drivers. Below
is an outline of the basic steps for your convenience.

1. Download the latest `control4-schluter.zip` from
   [Github](https://github.com/finitelabs/control4-schluter/releases/latest).

1. Extract and
   [install](https://www.control4.com/help/c4/software/cpro/dealer-composer-help/content/composerpro_userguide/adding_drivers_manually.htm)
   all `.c4z` files.

1. Use the "Search" tab to find the "Schluter" driver and add it to your
   project.
   <br><img alt="Search Drivers" src="./images/search-drivers.png" width="250"/>

1. Configure the [Account Settings](#account-settings) with your Schluter email
   and password.

1. After a few moments the [`Driver Status`](#driver-status-read-only) will
   display `Connected` with the number of thermostats found. If it fails, set
   the [`Log Mode`](#log-mode--off--print--log--print-and-log-) property to
   `Print` and re-enter the credentials, then check the Lua output window for
   details.

1. For each thermostat you want to control, use the "Search" tab to add a
   "Schluter Thermostat" driver. In the "Connections" tab, select the "Schluter"
   driver and bind each discovered thermostat to a "Schluter Thermostat" driver.

Each companion driver includes its own documentation accessible from within
Composer Pro. Refer to the **Schluter Thermostat** driver documentation for its
property, connection, and programming reference.

## Driver Setup

### Driver Properties

#### Cloud Settings

##### Automatic Updates \[ Off | **_On_** \]

Enables or disables automatic driver updates from GitHub releases.

##### Update Channel \[ **_Production_** | Prerelease \]

Sets the update channel considered during automatic updates from GitHub
releases.

#### Account Settings

##### Email

The email address for your Schluter DITRA-HEAT WiFi account.

##### Password

The password for your Schluter DITRA-HEAT WiFi account.

##### Login Status (read-only)

Displays the account sign-in state (e.g. `Logging in...`, `Logged In`, or an
error message such as `Invalid username or password`).

#### Driver Settings

##### Driver Status (read-only)

Displays the current status of the driver (e.g. `Connected (2 thermostats)`).

##### Driver Version (read-only)

Displays the current version of the driver.

##### Log Level \[ 0 - Fatal | 1 - Error | 2 - Warning | **_3 - Info_** | 4 - Debug | 5 - Trace | 6 - Ultra \]

Sets the logging level. Default is `3 - Info`.

##### Log Mode \[ **_Off_** | Print | Log | Print and Log \]

Sets the logging mode. Default is `Off`.

### Driver Actions

#### Update Drivers

Trigger the driver to update from the latest release on GitHub, regardless of
the current version.

#### Refresh Thermostats

Re-reads the account and refreshes the discovered thermostats and their
connection bindings.

#### Reconnect

Signs out and logs back in to the Schluter cloud without touching connection
bindings or cached thermostats. Use this to recover from a stuck session without
losing programming.

#### Reset Driver

> ⚠️ This will reset all connection bindings and delete any programming
> associated with them.

Signs out, removes all dynamically created thermostat connections, and signs
back in to rediscover from scratch. Useful if thermostats were added, removed,
or renamed on the account.

**Parameters:**

- **Are You Sure?** \[ **_No_** | Yes \] - Confirmation to reset the driver.

## Programming Reference

Once signed in, the driver creates one **provider** connection per thermostat on
the account (binding class `SCHLUTER_THERMOSTAT`), named after the thermostat's
room. Bind each to a **Schluter Thermostat** companion driver; that companion
exposes the standard Control4 thermostat proxy for programming (setpoint, mode,
schedule, temperature). This account driver has no directly programmable
variables of its own. All thermostat control and feedback is on the companion.

# <span style="color:#f78d1f">Support</span>

If you have any questions or issues integrating this driver with Control4, you
can file an issue on GitHub:

https://github.com/finitelabs/control4-schluter/issues/new

<a href="https://www.buymeacoffee.com/derek.miller" target="_blank"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me A Coffee" style="height: 60px !important;width: 217px !important;" ></a>

# <span style="color:#f78d1f">Changelog</span>

<!--
Template for a new release entry (copy below the heading, fill in, uncomment):

## v[Version] - YYYY-MM-DD

### Added
- Added

### Fixed
- Fixed

### Changed
- Changed

### Removed
- Removed
-->

## Unreleased

### Fixed

- Fixed an automatic update sometimes leaving companion drivers on the previous
  version until the next update, which could make them stop responding in the
  meantime.

## v20260816 - 2026-08-16

### Added

- Initial release.
- Control for Schluter DITRA-HEAT WiFi floor-heating thermostats. An account
  driver connects to your Schluter account and adds a thermostat companion
  driver for each thermostat it finds.
- Native Control4 thermostat integration (ThermostatV2): floor temperature, heat
  setpoint, and Heat/Off mode.
- The full weekly heating schedule, read and edited from the standard Control4
  scheduling interface.
- Hold options (Until Next, Permanent).
- Floor temperature exposed as a temperature-value connection for other drivers.
- Automatic driver updates via GitHub or DriverCentral.
