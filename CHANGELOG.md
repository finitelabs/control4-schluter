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

- Fixed the driver reporting "Error retrieving thermostats" when a periodic
  account refresh timed out, even though the thermostat was still connected and
  reporting live. It now keeps the connected status as long as a thermostat is
  known, and only shows the error before any have been discovered.

<!-- #ifndef DRIVERCENTRAL -->

- Fixed an automatic update sometimes leaving companion drivers on the previous
  version until the next update, which could make them stop responding in the
  meantime.

<!-- #endif -->

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
