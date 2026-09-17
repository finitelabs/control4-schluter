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

- Fixed the thermostat always using Fahrenheit. It never read the temperature
  scale from Control4, so a Celsius project got Fahrenheit setpoint steps and a
  schedule shown in the wrong unit. The driver now follows the scale the
  thermostat is set to, falling back to the project's setting, and picks up a
  change made in Navigator straight away.

- Fixed the thermostat telling Control4 its scale could not be changed while
  still acting on the change, so the Celsius and Fahrenheit choice is now
  offered.

- Fixed the thermostat showing a temperature or setpoint of "nil" when the cloud
  sent an update that did not include one. The last known reading is kept until
  a real one arrives.

- Fixed the whole weekly schedule disappearing from the Control4 schedule editor
  when the thermostat reported one entry without a usable temperature. The other
  entries are now shown, and editing an entry whose stored temperature cannot be
  read no longer fails partway through.

- Fixed the setpoint up and down buttons doing nothing but logging an error
  after an update that carried no setpoint.

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
