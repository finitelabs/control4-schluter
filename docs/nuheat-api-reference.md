# NuHeat Signature — API & Driver Design Reference

Reverse-engineered from the defunct `shard7/thermostat_ip_nuheat_signature` (thermostat
companion) and `..._signature_master` (account/controller) drivers on Sourcebot. This is
the implementation blueprint for `control4-nuheat`.

## Architecture (mirrors control4-esphome)

Two drivers, connected by a Control4 proxy binding:

- **Account / controller driver** (`nuheat`) — logs in to `www.mynuheat.com`, holds the
  session, long-polls for real-time updates, and exposes one **connection binding per
  thermostat**. Owns all HTTP.
- **Thermostat companion driver** (`nuheat_thermostat`) — a Control4 `thermostat` proxy
  (proxy id 5001) that binds to the account driver (`ID_CONTROLLER = 1`). Translates C4
  proxy commands ↔ NuHeat JSON. Does no HTTP itself.

Companion → account command channel carries `{JSON = <encoded object>}`:
- `UPDATE_THERMOSTAT` (companion → account): account does `POST /api/thermostat`.
- `GO_OFFLINE` (account → companion) when unbound / logged out.
- Account pushes state to companion via `updateThermostat` `{JSON=...}`.

## REST API — `https://www.mynuheat.com` (port 443)

Headers: `Content-Type: application/json; charset=utf-8`, `Connection: close`.
Session id is passed as the `sessionid` query param on every authenticated call.

| Purpose | Method | Path | Body / Query |
|---|---|---|---|
| Authenticate | POST | `/api/authenticate/user` | body `{Email, Password, Confirm=Password}` |
| List thermostats | GET | `/api/thermostats?sessionid=<sid>` | — |
| Get thermostat | GET | `/api/thermostat?sessionid=<sid>&serialnumber=<sn>` | — |
| Set thermostat | POST | `/api/thermostat?sessionid=<sid>&serialnumber=<sn>` | body = settings object |
| Real-time notify | GET | `/api/notification?sessionid=<sid>&sequencenr=<n>` | long-poll (~300s) |
| Energy usage | GET | (stubbed in old driver, not implemented) | — |

### Auth response
`{ ErrorCode, SessionId }`. `ErrorCode == 0` and non-empty `SessionId` ⇒ logged in.
`ErrorCode == 1 or 2` ⇒ invalid username/password.

### Real-time notifications (native — no third-party driver needed)
After login: `GET /api/notification?sessionid=<sid>&sequencenr=<n>` on a long-lived
connection (~5 min timeout). Response carries `SequenceNr`; on each response, re-request
with `sequencenr = SequenceNr + 1`. On timeout/offline, re-issue the request. This
replaces the old annex4 LiNK dependency — the old thermostat driver only needed annex4 for
its own cloud dashboard, not for thermostat data.

## Thermostat data model (verbatim NuHeat fields)

Response may be `{Thermostat: {...}}` or a bare object. Fields:
```
Assigned, Confirmed, Email, EnergyOverview, ErrorCode, FloorArea, GroupId, GroupName,
HasBeenAssigned, Heating, HoldSetPointDateTime, KwCharge, MaxTemp, MinTemp, Online,
OperatingMode, Room, ScheduleMode, SerialNumber, SetPointTemp, SWVersion, Temperature,
TZOffset, WPerSquareUnit, Schedules[]
```
Consumed: `SerialNumber` (Serial ID), `Online` (connection), `Temperature` (current),
`SetPointTemp` (setpoint), `Heating` (HVAC state), `ScheduleMode`/`OperatingMode` (mode),
`HoldSetPointDateTime` (ISO, e.g. `2020-01-02T13:45:00-05:00`), `TZOffset` (`±HH:MM`),
`MinTemp`/`MaxTemp` (bounds).

### Temperature scaling — API unit is **°C × 100** (hundredths of a degree C)
```
read:  temp_c = (Temperature / 100)               ; temp_f = CToF(Temperature / 100)
write: SetPointTemp = CELSIUS * 100
CToF(t) = t * 9/5 + 32 ;  FToC(t) = (t - 32) * 5/9
```
Snap setpoints to 0.5° (`_normalizeTemp`). Limits: °F 41–158, °C 5–70 (0.5° res).
Away/Off sentinel: `SetPointTemp == 500` (= 5.00 °C) with `ScheduleMode == 3`.

### Modes — `ScheduleMode` enum
```
1 = Auto (follow schedule)
2 = Until (hold until HoldSetPointDateTime)
3 = Permanent / Off-Away
```
HVAC mapping: `Heat` → ScheduleMode 1; `Off` → ScheduleMode 3 + SetPointTemp = MinTemp.
Setpoint change → ScheduleMode 2 (Until) unless already 2/3.
Hold modes: `2 Hours` (Until, now+2h UTC), `Hold Until` (Until, explicit datetime),
`Permanent`, `Off` (resume schedule / Auto).

### Schedule model
`Schedules[]` = day-schedule objects: `{ WeekDayGrpNo, Events[1..4] }`; each event
`{ Clock "HH:MM:SS", Active(bool), TempFloor (°C×100), ScheduleType }`. Days sharing a
`WeekDayGrpNo` share events. Day index maps:
```
NuHeat 1..7 = Mon..Sun ;  C4 0..6 = Sun..Sat
NuheatToControl4 = {1,2,3,4,5,6,0}
Control4ToNuheat = {[0]=7,[1]=1,[2]=2,[3]=3,[4]=4,[5]=5,[6]=6}
```

## Account → companion handoff & dynamic capabilities

Follows esphome's model (`drivers/esphome_climate` + `src/lib/bindings.lua`):

1. **Account** logs in, calls `getThermostats`, and for each thermostat creates a
   dynamic PROXY binding keyed by serial number:
   `Bindings:getOrAddDynamicBinding("nuheat", SerialNumber, "PROXY", true, Room/GroupName, "NUHEAT_THERMOSTAT")`.
   Bindings persist and restore across restarts (bindings lib manages id ranges).
2. When a **companion** binds (`OnBindingChanged`), the account hands it the full
   NuHeat thermostat object as `{JSON=...}` (and on every notification update).
3. **Companion** derives its Control4 thermostat-proxy capabilities from that
   device object and pushes them dynamically — it advertises only what the
   handed device actually supports (don't hard-code):
   - `SendToProxy(PROXY, "ALLOWED_HVAC_MODES_CHANGED", { MODES = "Off,Heat" }, "NOTIFY")`
     — NuHeat is heat-only.
   - `SendToProxy(PROXY, "DYNAMIC_CAPABILITIES_CHANGED", { HAS_SINGLE_SETPOINT=true,
     CAN_HEAT=false, CAN_COOL=false, CAN_AUTO=false }, "NOTIFY")` — per C4 rule the
     `CAN_*` flags must be false when `HAS_SINGLE_SETPOINT` is true.
   - Temperature bounds from `MinTemp`/`MaxTemp`; scale from the C4 UI.
   - Schedule support (NuHeat `Schedules[]`) advertised only if present.
   - Hold/operating mode surfaced via `HAS_EXTRAS` + an `<extras_setup>` section
     ("Operating Mode": Auto / Hold Until / 2 Hours / Permanent), mirroring how
     esphome_climate exposes device-specific extras.
   - Energy (`EnergyOverview`/`KwCharge`/`WPerSquareUnit`) optionally as a
     read-only extras section if the device reports it.

This keeps the companion generic: a future NuHeat model that adds/removes a
feature just changes what the account hands over, and the companion re-advertises.

## Config / properties
Account driver: Email, Password, Login Status ("Logged In" / "Invalid username or
password"). Thermostats must be added to a **group** at `mynuheat.com/#groups` for the
account to enumerate them.

## Open questions to verify on hardware
- Exact notification payload shape (what `SequenceNr`/events carry).
- Whether `/api/thermostats` returns full objects or serial numbers only.
- `OperatingMode` vs `ScheduleMode` distinction.
