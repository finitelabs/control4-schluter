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

<!-- #ifdef DRIVERCENTRAL -->

## Unreleased

### Added

- Added a Support Code property to the Schluter and Schluter Thermostat drivers,
  which lets Finite Labs support open the driver's Lua tab and its Trace and
  Ultra log levels for an hour
- Added Cloud Monitoring, Enabled by default, which sends Finite Labs each
  driver's memory use every hour and each error it hits, and a Diagnostics
  Snapshot action
- Added one Automatic Updates setting for the Schluter driver and its thermostat
  drivers, so the drivers update together

<!-- #endif -->

## v20261025 - 2026-10-25

### Fixed

- Fixed the driver reporting "Error retrieving thermostats" when a periodic
  account refresh timed out, even though the thermostat was still connected and
  reporting live.
- Fixed the thermostat always using Fahrenheit. It now follows the scale the
  thermostat is set to, or the project's, and picks up a change made in
  Navigator at once.
- Fixed the thermostat telling Control4 its scale could not be changed while
  still acting on the change, so the Celsius and Fahrenheit choice is now
  offered.
- Fixed the thermostat showing a temperature or setpoint of "nil" when the cloud
  sent an update that did not include one. The last known reading is kept until
  a real one arrives.
- Fixed the whole weekly schedule disappearing from the Control4 schedule
  editor, or an edit failing partway through, when one entry had no usable
  temperature.
- Fixed the setpoint up and down buttons doing nothing but logging an error
  after an update that carried no setpoint.
- Fixed turning the thermostat off or back to heat from the Control4 app doing
  nothing.
- Fixed a setpoint chosen in a Fahrenheit project being rounded to a whole
  degree Celsius, so 85 °F was set as 84 °F.
- Fixed a setpoint changed during a temporary or permanent hold jumping back to
  the old value in the Control4 app, and not being sent again when Schluter
  missed it.

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
- Native Control4 thermostat control of floor temperature, heat setpoint and
  Heat or Off mode.
- The full weekly heating schedule, read and edited from the standard Control4
  scheduling interface.
- Until Next and Permanent hold options.
- Floor temperature exposed as a temperature-value connection for other drivers.
- Automatic driver updates via GitHub or DriverCentral.
