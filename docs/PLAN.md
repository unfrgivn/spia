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
| 3 | Recording/replay transports + `--record` flag | Real transcripts land in `Tests/Fixtures/` | done, including car captures |
| 4 (#4) | `spia capture` (ATMA monitor, candump log, per-ID summary, 2 Mbps UART) | Ghibli traffic captured without reported overflow at 2 Mbps | shipped (PR #9); second-bus traffic also observed with STP 53 |
| 5 (#5) | UDS/ISO-TP client and module discovery, reads first | Complete DTC replies with explicit request/reply IDs and correct flow control | in progress; live ORC/ABS/BCM reads recorded, CLI integration pending |
| 6 (#1) | `spia scan` (stored/pending/permanent DTCs, freeze frame, readiness) + `spia info` (VIN, CAL IDs) | Pure report/decoder tests, original `ghibli-ignition-on-term.txt` replay through production request/decode paths, CLI help/validation; live execution remains unverified | offline milestone implemented; live unverified |
| 7 (#2) | `spia clear` | Codes clear, CEL off, re-scan clean | pending |
| 8 (#3) | `spia live` with CSV logging | RPM/coolant/etc. track reality at idle | pending |
| iOS (#6) | `BLETransport` (CoreBluetooth), SwiftUI shell | Bluetooth FS on iPhone | future |

Reordered 2026-09-26: the fault that started this project is not an emissions code (Mode 03/07/0A are clean), so UDS access to body modules moves ahead of the generic-OBD polish.

## The Ghibli's actual fault (why UDS comes first)

Reported symptoms: every steering-wheel control dead (volume, cluster menu, cruise), horn dead, airbag lamp on, ABS lamp reported on. Column-mounted paddles and wiper stalk work. Washer pump silent despite a full reservoir; whether this is related is unknown.

The combined symptoms make the clock spring and its connections plausible suspects. A warning lamp alone does not identify a circuit or prove an open ribbon. Complete airbag-controller replies below support high-resistance faults in both driver-airbag stages under the SAE interpretation. They do not distinguish a clock spring from connectors, harness wiring, the airbag assembly, or controller faults. Working paddles/wipers do not prove all column electronics are healthy.

Targets are ORC, BCM, steering-column module, and ABS. Generic emissions scans do not cover these faults. Preserve DTCs before repair; no code clearing, output controls, coding, or airbag-circuit probing is part of this investigation. SRS electrical diagnosis requires the vehicle's service procedure and appropriate equipment.

## Hardware notes

Confirmed on the bench (2026-09-26, USB power only, no car):

- USB `0403:6015` (FTDI FT-X), product string `vLinker FS`. Apple's built-in driver enumerates it as `/dev/cu.usbserial-<serial>`; nothing to install.
- `ATZ` → `ELM327 v2.3`. `STI` → `STN1170 v4.3.2`. `STDI` → `vLinker FS r2`. These identify the reported firmware; individual command support still needs verification.
- 115200 baud works. Echo is on after reset. `ATZ` takes ~1.2 s to answer; a failed protocol auto-search takes ~7 s before `UNABLE TO CONNECT`.
- `ATRV` reports `--.-V` without a car; the voltage comes from OBD pin 16.
- Adapter supports up to 3 Mbps (`ATBRD`) and remembers its last protocol across power cycles.
- MS-CAN/HS-CAN switching is relevant here: `STP 53` reported `MS CAN (ISO 15765, 125K/11B)` and exposed a second traffic set on the Ghibli.
- Ghibli M157: expect ISO 15765-4 CAN 11-bit 500k for generic OBD (`ATSP6`). Manufacturer modules are likely UDS over ISO-TP with no public address/DID map. FCA-derived electronics but not identical to Chrysler.
- 2017 predates FCA's Security Gateway (introduced MY2018 on Chrysler/Jeep/RAM). Unverified for Maserati; check on the car.

Confirmed on the car (2017 Ghibli S Q4, 2026-09-26; fixtures in `Tests/Fixtures/ghibli-*.txt`):

- ISO 15765-4 CAN 11-bit 500k. `ATSP0` auto-detects as `A6`.
- Functional `7DF` gets two answers: ECM `7E8` (22 PIDs in 01-20) and TCM `7E9` (6 PIDs). VIN `ZAM57RTS4H1249941`. ECM CAL ID `670106994 G`, TCM `670101187`. ECU names `ECM1-EngineControl1`, `TCM\0-TransmisCtrl`.
- No stored/pending/permanent DTCs, MIL off, all monitors complete. Distance since clear: ECM 1673 km, TCM 1603 km.
- Car must be in RUN, not ACC. In ACC the bus is alive (~40 IDs at 10-20 Hz, e.g. `102`, `10C`, `10D`, `2F9`) but `0100` gets `NO DATA` on `ATSP6`/`7` and `CAN ERROR` on `ATSP8`. ACC to RUN is one more START press without the brake.
- `STP 53` plus `STPBR 125000` exposed about 100 IDs on the second transceiver. The earlier suggestion to use `STP 33` for that bus was incorrect.
- Diagnostic replies were observed on both buses once receive filters covered the actual reply IDs. The request-plus-eight convention is not a general manufacturer-module mapping. Reachability does not establish whether a gateway forwarded a reply.

### Bus observations, ignition on, engine off (2026-09-26, `spia capture`)

- The current parser reported 124 IDs and about 2200 frames/s at 2 Mbps. Frame lengths remain suspect with CAN auto-formatting enabled; do not treat this as a validated raw bus inventory.
- The adapter overflows at 115200 within a second. No overflow was reported in the 2 Mbps runs, but that does not establish lossless capture.
- `102`, `108`, `120`, `2F8` changed during the wheel-movement experiment. Steering-related signals are candidates, not verified decodings or proof of which ECU transmitted them.
- `334` byte 7 did not change during the dedicated volume/horn hold run. This rejects the earlier correlation for that signal, not all possible input paths or faults.
- `328` contained apparent radio metadata. Its segmentation is not established as ISO-TP. `3E0` content needs separate decoding.
- `400`-`423`: eight `FD xx ...` frames at 1.3 Hz, likely network-management/status.
- `214` bytes 1 and 3 drift slowly at idle (sensor value). `10C` byte 4 creeps up over minutes (temperature or voltage).
- Adapter voltage fell from 11.7 V to 11.6 V during ignition-on testing. No universal module-dropout threshold has been established. Later engine-running measurements were 14.0–14.3 V. Use a suitable supply for extended stationary diagnosis; never idle in an enclosed space.

### Complete DTC reads (2026-09-26)

Fixtures: `ghibli-orc-flowcontrol.txt` and `ghibli-abs-bcm-flowcontrol.txt`. Each contains the original TX/RX bytes, including setup acknowledgements. Module names below are working labels based on FCA references, not identification-DID verification.

| Target (request → reply, 500k bus) | Complete response to `19 02 09` | Result |
|---|---|---|
| ORC (`744` → `4C4`) | `59 02 CF 80 01 1B 8F 80 02 1B 8F` | Two raw DTCs: `80011B`, `80021B`, both status `8F` |
| ABS (`747` → `4C7`) | `59 02 7F` | No records matching requested status mask `09` |
| BCM (`620` → `504`) | `59 02 FB 10 09 00 2B` | Raw DTC `100900`, status `2B`; manufacturer meaning unverified |

With SAE-format interpretation, the ORC records map to `B0001-1B` and `B0002-1B`, driver frontal stage 1/2 circuits with resistance above threshold. Exact Maserati descriptions and the ECU's DTC format identifier remain unverified. The decoder therefore preserves raw codes. Status `8F` sets testFailed, testFailedThisOperationCycle, pendingDTC, confirmedDTC, and warningIndicatorRequested. Availability `CF` supports those bits.

`19 02 FF` requests every supported status bit, not every possible DTC definition. `19 02 09` selects records with testFailed or confirmedDTC set. The ABS result does not rule out other-status faults or explain the reported lamp.

The first ORC reply is `7F 19 78` (response pending), followed by a separate multi-frame positive response. `10 0B` is an 11-byte ISO-TP payload length. Automatic flow control worked after setting both data and header before enabling mode 1:

```text
ATCFC 1
ATSH 744
ATCRA 4C4
ATFCSD 30 00 00
ATFCSH 744
ATFCSM 1
190209
```

The earlier `ATFCSM 1` rejection was setup order, not whitespace. See the [OBDLink reference manual](https://www.scantool.net/scantool/downloads/678/obdlink_frpm_e.pdf), CAN-specific commands, and [ELM327 manual](https://elmelectronics.com/wp-content/uploads/2020/05/ELM327DSL.pdf), "Altering Flow Control Messages."

Next: validate and review the bounded offline-replay-backed command `spia uds dtcs --bus hs --tx 744 --rx 4C4` before any live use. It is read-only, standard 11-bit only, explicitly configures the target headers/flow control, sends one `19 02 <mask>` request, accepts pending followed by a final response in one adapter prompt, and reports a pending-only prompt as incomplete. No automatic diagnostic-session transitions, retry, discovery, extended-ID support, or manufacturer label inference are included.

Offline CLI validation runs with `scripts/test-cli-validation.sh .build/debug/spia`; it never invokes a valid auto-port command. `readUDSDTC` assumes its caller exclusively owns the session and has already configured the target headers.
