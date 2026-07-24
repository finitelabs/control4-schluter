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

- [Features](#features)

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

<div style="page-break-after: always"></div>

# <span style="color:#f78d1f">System Requirements</span>

- Control4 OS 3.3.0 or later
- A Schluter DITRA-HEAT-E-WiFi account with at least one thermostat set up in
  the [Schluter DITRA-HEAT WiFi app](https://ditra-heat-e-wifi.schluter.com)
- Internet access from the Control4 controller

# <span style="color:#f78d1f">Features</span>

- Cloud sign-in with your Schluter DITRA-HEAT WiFi email and password
- Automatic discovery of every thermostat on the account
- One connection per thermostat, each bound to a companion thermostat driver
- Real-time state updates via the cloud's push notifications (no polling delay)
- Setpoint, Heat/Off mode, and hold control
- Full weekly schedule read and edit through the native Control4 thermostat
  scheduling UI
- Temperature values communicated in Celsius — the Control4 proxy handles
  display conversion to the project's configured scale

# <span style="color:#f78d1f">Compatibility</span>

This driver works with Schluter DITRA-HEAT-E-WiFi thermostats (DITRA-HEAT-E-RS1
/ DITRA-HEAT-E-RT1) managed through the Schluter DITRA-HEAT WiFi app. Because
Schluter DITRA-HEAT shares the OJ Electronics cloud platform with sibling
brands, the underlying API is the same one used by those apps.

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

   ![Search Drivers](images/search-drivers.png)

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
variables of its own — all thermostat control and feedback is on the companion.

# <span style="color:#f78d1f">Support</span>

If you have any questions or issues integrating this driver with Control4, you
can file an issue on GitHub:

https://github.com/finitelabs/control4-schluter/issues/new

<a href="https://www.buymeacoffee.com/derek.miller" target="_blank"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me A Coffee" style="height: 60px !important;width: 217px !important;" ></a>

<div style="page-break-after: always"></div>

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
