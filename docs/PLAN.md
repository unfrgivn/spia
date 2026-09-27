# spia: Plan

spia (Italian for a dashboard warning light, as in "spia motore"). Mac-first OBD-II scan tool for a Vgate vLinker FS (USB), tested against a 2017 Maserati Ghibli S Q4 (M157).
Designed so an iOS app can be added later with a Bluetooth vLinker FS by swapping the transport.

## Decisions (locked)

| Decision | Choice | Why |
|---|---|---|
| Language | Swift 6, Swift Package | Apple-only targets (macOS now, iOS later). CoreBluetooth on both. No FFI. |
| Adapter now | vLinker FS (USB, FTDI) | Fast (3 Mbps), deterministic, shows up as `/dev/cu.usbserial-*`. Best bench tool for CAN capture. |
| Adapter later | vLinker FS Bluetooth (BLE+BT mode) | Only vLinker that works on iOS from a third-party app (BLE). iOS cannot talk to the USB FS at all. |
| Dependencies | `apple/swift-argument-parser` only | Serial I/O is hand-rolled POSIX termios. |
| Testing | Unit tests for pure decoders (J1979 formulas). Session/framing tests replay REAL recorded transcripts. Live e2e against the car. | No mocks. Fixtures come only from real captures. |
| v1 scope | Generic OBD-II + raw terminal + CAN capture | Manufacturer-specific UDS module map is a later reverse-engineering effort. |

## Architecture

Functional core, imperative shell.

```
┌────────────────────────────────────────────────────────────┐
│  spia (CLI, swift-argument-parser)                          │
│  ports · probe · scan · clear · info · live · term · capture│
└───────────────────────────┬────────────────────────────────┘
                            │
┌───────────────────────────▼────────────────────────────────┐
│  ELM327Session (actor, in OBDCore)                          │
│  init sequence, send cmd → read until '>', timeouts,        │
│  adapter error strings (NO DATA, CAN ERROR, BUFFER FULL…)   │
└───────────────┬───────────────────────────┬────────────────┘
                │                           │
┌───────────────▼───────────┐  ┌────────────▼────────────────┐
│  OBDCore (pure, no I/O)   │  │  Transport (protocol)        │
│  PID decoders (J1979)     │  │  SerialTransport (OBDSerial) │
│  DTC parsing (03/07/0A)   │  │  RecordingTransport          │
│  freeze frame, readiness, │  │  ReplayTransport (tests)     │
│  VIN/CALID, ISO-TP        │  │  BLETransport   (later, iOS) │
│  multi-frame reassembly   │  │                              │
└───────────────────────────┘  └─────────────────────────────┘
```

Targets:

- `OBDCore`: pure protocol logic + `Transport` protocol + `ELM327Session`. Must compile for iOS. No Darwin serial code.
- `OBDSerial`: macOS-only `SerialTransport` over POSIX termios.
- `spia`: CLI executable.
- `OBDCoreTests`: Swift Testing. Fixtures under `Tests/Fixtures/` are verbatim recorded transcripts.

## Milestones

| # | Milestone | Verified by | Status |
|---|---|---|---|
| 1 | Package skeleton, `OBDCore` pure decoders + unit tests | `swift build`, `swift test` green | done |
| 2 | `SerialTransport` + `ELM327Session` + `spia ports` / `spia probe` | Hardware day 1: `ATZ`, `ATI`, `ATRV`, `ATDP` answer from the FS | done |
| 3 | Recording/replay transports + `--record` flag | Real transcripts land in `Tests/Fixtures/` | done (USB-only capture; car captures next) |
| 4 (#4) | `spia capture` (ATMA monitor, candump log, per-ID summary, 2 Mbps UART) | 124 IDs captured losslessly on the Ghibli; steering frames identified | done (PR #9); 125k pins 3/11 test still open |
| 5 (#5) | UDS/ISO-TP client: `0x19` ReadDTC, `0x22` ReadDID, `0x14` ClearDTC; module discovery | ORC and BCM answer; codes match the clock-spring diagnosis below | next |
| 6 (#1) | `spia scan` (stored/pending/permanent DTCs, freeze frame, readiness) + `spia info` (VIN, CAL IDs) | Ghibli replay fixtures already recorded; decode matches `term` output | pending |
| 7 (#2) | `spia clear` | Codes clear, CEL off, re-scan clean | pending |
| 8 (#3) | `spia live` with CSV logging | RPM/coolant/etc. track reality at idle | pending |
| iOS (#6) | `BLETransport` (CoreBluetooth), SwiftUI shell | Bluetooth FS on iPhone | future |

Reordered 2026-09-26: the fault that started this project is not an emissions code (Mode 03/07/0A are clean), so UDS access to body modules moves ahead of the generic-OBD polish.

## The Ghibli's actual fault (why UDS comes first)

Symptoms: every steering-wheel control dead (volume, cluster menu, cruise), horn dead, airbag lamp on, ABS lamp on. Column-mounted paddles and wiper stalk work. Washer pump silent (separate fault, probably pump/fuse).

Everything that routes through the clock spring ribbon is dead; everything that bypasses it works. The airbag lamp means the ORC sees the driver squib loop open, which also runs through the ribbon. Working diagnosis: clock spring, with "fuse or unplugged connector at the column base" as the cheap thing to rule out first.

Modules to interrogate over UDS: **ORC** (expect a driver-squib-open B-code), **BCM** (horn/cruise switch faults, washer pump output), **SCCM** (steering column module; hosts the switches and steering angle sensor), **ABS** (probably a lost-comm/steering-angle U- or C-code). None of these answer Mode 01/03.

## Hardware notes

Confirmed on the bench (2026-09-26, USB power only, no car):

- USB `0403:6015` (FTDI FT-X), product string `vLinker FS`. Apple's built-in driver enumerates it as `/dev/cu.usbserial-<serial>`; nothing to install.
- `ATZ` → `ELM327 v2.3`. `STI` → `STN1170 v4.3.2`. `STDI` → `vLinker FS r2`. It is a real STN1170, so the full ST command set is available.
- 115200 baud works. Echo is on after reset. `ATZ` takes ~1.2 s to answer; a failed protocol auto-search takes ~7 s before `UNABLE TO CONNECT`.
- `ATRV` reports `--.-V` without a car; the voltage comes from OBD pin 16.
- Adapter supports up to 3 Mbps (`ATBRD`) and remembers its last protocol across power cycles.
- 8 KB serial buffer, 4128-byte OBD requests. Handles MS-CAN/HS-CAN switching in firmware (Ford-specific, irrelevant for the Ghibli).
- Ghibli M157: expect ISO 15765-4 CAN 11-bit 500k for generic OBD (`ATSP6`). Manufacturer modules are likely UDS over ISO-TP with no public address/DID map. FCA-derived electronics but not identical to Chrysler.
- 2017 predates FCA's Security Gateway (introduced MY2018 on Chrysler/Jeep/RAM). Unverified for Maserati; check on the car.

Confirmed on the car (2017 Ghibli S Q4, 2026-09-26; fixtures in `Tests/Fixtures/ghibli-*.txt`):

- ISO 15765-4 CAN 11-bit 500k. `ATSP0` auto-detects as `A6`.
- Functional `7DF` gets two answers: ECM `7E8` (22 PIDs in 01-20) and TCM `7E9` (6 PIDs). VIN `ZAM57RTS4H1249941`. ECM CAL ID `670106994 G`, TCM `670101187`. ECU names `ECM1-EngineControl1`, `TCM\0-TransmisCtrl`.
- No stored/pending/permanent DTCs, MIL off, all monitors complete. Distance since clear: ECM 1673 km, TCM 1603 km.
- Car must be in RUN, not ACC. In ACC the bus is alive (~40 IDs at 10-20 Hz, e.g. `102`, `10C`, `10D`, `2F9`) but `0100` gets `NO DATA` on `ATSP6`/`7` and `CAN ERROR` on `ATSP8`. ACC to RUN is one more START press without the brake.
- STN commands: `STPRS` works; `STP`, `STPBR`, `STCSWM` returned `?`. Probably called without arguments; retry as `STP 33` / `STPBR 125000` when testing whether CAN-IHS (125k) is on DLC pins 3/11.
- Open: is the SCCM/ORC/BCM traffic on the 500k bus we can see, or on IHS behind the BCM gateway? Decides whether UDS to body modules works from the DLC at all.

### Bus observations, ignition on, engine off (2026-09-26, `spia capture`)

- 124 IDs, ~2200 frames/s. Periodic rates are exact 100/50/20/10/5/2/1/0.5 Hz. Nothing above `44C` except one 29-bit `208262F0`.
- The adapter overflows at 115200 within a second; 2 Mbps captures losslessly. Capture switches rates automatically.
- `102`, `108`, `120`, `2F8` (100/50 Hz) change continuously while the wheel is moved and are static otherwise: steering angle/torque, so the column module is alive on this bus.
- Horn and wheel-button presses (short and 3 s holds) change nothing on the bus. Consistent with an open ribbon on the switch side.
- `328` and `3E0` carry variable-length UTF-16 text: radio now-playing metadata for the cluster.
- `400`-`423`: eight `FD xx ...` frames at 1.3 Hz, likely network-management/status.
- `214` bytes 1 and 3 drift slowly at idle (sensor value). `10C` byte 4 creeps up over minutes (temperature or voltage).
- Battery sagged from 11.7 V to 11.6 V over ~15 minutes of ignition-on captures. Below ~11.5 V modules drop off; start the engine for longer sessions.
