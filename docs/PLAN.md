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
| 4 | `spia scan` (stored/pending/permanent DTCs, freeze frame, readiness) + `spia info` (VIN, CAL IDs) | Reads the Ghibli's active codes; cross-check against dash / known scanner | pending |
| 5 | `spia clear` | Codes clear, CEL off, re-scan clean | pending |
| 6 | `spia live` with CSV logging | RPM/coolant/etc. track reality at idle | pending |
| 7 | `spia term` (raw AT/ST/hex) + `spia capture` (ATMA monitor to file) | We see Maserati CAN traffic | pending |
| 8+ | UDS/ISO-TP client, Maserati module discovery | Non-powertrain ECUs answer | future |
| iOS | `BLETransport` (CoreBluetooth), SwiftUI shell | Bluetooth FS on iPhone | future |

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

## Open questions (answer on the car)

- Exact `ATI` / `STI` strings and firmware version of the FS.
- Which ECUs respond to functional request `7DF` (expect at least `7E8` engine, maybe `7E9` transmission).
- Whether `ATMA` on the OBD port sees body-bus traffic or only the diagnostic CAN.
