# spia: Plan

spia (Italian for a dashboard warning light, as in "spia motore"). Mac-first OBD-II scan tool for a Vgate vLinker FS (USB), tested against a 2017 Maserati Ghibli S Q4 (M157).
The app also runs on iPhone and iPad, where it reaches Bluetooth LE adapters (the vLinker FS in BLE+BT mode) through `BLETransport`.

## Decisions (locked)

| Decision | Choice | Why |
|---|---|---|
| Language | Swift 6, Swift Package | Apple-only targets (macOS now, iOS later). CoreBluetooth on both. No FFI. |
| Adapter now | vLinker FS (USB, FTDI) | Fast (3 Mbps), deterministic, shows up as `/dev/cu.usbserial-*`. Best bench tool for CAN capture. |
| Adapter later | vLinker FS Bluetooth, switched to BLE+BT mode | It ships in MFi mode. There CoreBluetooth can't reach it, and the Mac's serial connection failed after the first session (see Hardware notes). The VgateFwUpdater iOS app switches the mode, reversibly per Vgate support. iOS cannot talk to the USB FS at all. |
| Dependencies | `apple/swift-argument-parser` only | Serial I/O is hand-rolled POSIX termios. |
| Testing | Unit tests for pure decoders (J1979 formulas). Session/framing tests replay REAL recorded transcripts. Live e2e against the car. | No mocks. Fixtures come only from real captures. |
| v1 scope | Generic OBD-II + raw terminal + CAN capture | Manufacturer-specific UDS module map is a later reverse-engineering effort. |
| Module survey scope | By default the make's known modules plus the legislated range; a wider search only when the owner asks for it, behind a plain warning | Probing arbitrary IDs on a live car is the risky part. Owner's decision, 2026-09-28. |
| Make knowledge | A bundled, versioned JSON catalog | Adding a make is a data change, not a code change. A hosted catalog may come later. Owner's decision, 2026-09-28. |

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
│  VIN/CALID, ISO-TP        │  │  BLETransport (OBDBluetooth) │
│  multi-frame reassembly   │  │                              │
└───────────────────────────┘  └─────────────────────────────┘
```

Targets:

- `OBDCore`: pure protocol logic + `Transport` protocol + `ELM327Session`. Must compile for iOS. No Darwin serial code.
- `OBDBluetooth`: CoreBluetooth `BLETransport`, compiling for iOS.
- `OBDBluetoothTests`: pure Bluetooth transport logic tests without CoreBluetooth fakes.
- `OBDSerial`: macOS-only `SerialTransport` over POSIX termios.
- `spia`: CLI executable.
- `OBDCoreTests`: Swift Testing. Fixtures under `Tests/Fixtures/` are verbatim recorded transcripts.

## Desktop app (macOS 14+, universal)

The CLI and the app share one engine. Layers, bottom up:

- `OBDCore`: protocol, decoders, `GenericOBDWorkflow` (the one generic scan/info sequence).
- `SpiaKit`: `ConnectionManager` (sole owner of an adapter session), `JobRunner` (one read-only check at a time, progress, "needs you" prompts), typed `JobResult` snapshots, per-check transcripts, and `DemoBackend`. iOS-compatible.
- `OBDBluetooth`: CoreBluetooth transport for the vLinker FS 18F0 service, plus adapter discovery and pure chunking/sighting logic.
- `SpiaAssist`: the assistant's provider layer. Claude (Messages API) and OpenAI (Responses API, `store: false`) over URLSession with a byte-level SSE parser; Apple's on-device model (FoundationModels, macOS 26 + Apple Intelligence, availability-gated); API keys in the Keychain; the session briefing and safety rules. iOS-compatible.
- `SpiaReference`: public references for a vehicle, Foundation only. VIN validation (49 CFR 565 check digit, required only for North American VINs), NHTSA vPIC decoding, recalls, owner complaints, and manufacturer service bulletins from NHTSA's `vehicles/byYmmt` in one request (bulletin PDFs fetched on demand), photos from Wikimedia Commons with author and license, and keyword search over bulletins. No keys. iOS-compatible. Photo search runs from trim and colour down to the model year and ranks the merged results on title, description, and categories: a photo must mention the model, files filed only under another generation's category (the model's categories on photos that clearly fit are trusted) are dropped, and a category's model year beats a title's photo date.
- `SpiaStore`: SwiftData schema v1 (vehicles, adapter profiles, modules, sessions, timeline, chat messages) at `Application Support/Spia/Library.store`, transcript and photo files, the `Workbench` model the screens bind to, `AssistantConversation`, and `VehicleReferences`, a per-vehicle cache under `References/<vehicle>` (refreshed weekly or when the VIN changes, deleted with the vehicle). iOS-compatible.
- `App/SpiaApp.xcodeproj`: SwiftUI screens only, one target for macOS, iPhone, and iPad. `OBDBluetooth` is linked on all platforms; `OBDSerial` is linked on macOS only; there, the sandbox allows serial, Bluetooth, network client, and user-selected files.
- App icon: `design/icon/app-icon.svg` (the gauge: a dial reading into the warning zone, with a pulse line) is the source; `scripts/render-app-icon.sh` renders macOS sizes and the iOS icon into `AppIcon.appiconset` (needs `rsvg-convert`). The other `option-*.svg` files are the alternatives considered.

Run it: open `App/SpiaApp.xcodeproj` and run the `Spia` scheme, or `xcodebuild -project App/SpiaApp.xcodeproj -scheme Spia build`. Choose "Explore the demo" to use the Ghibli recordings without a car. `scripts/screenshots.sh` captures `-SpiaFixture demo -SpiaScreen <screen> -SpiaAppearance <light|dark>` fixture screens.

The app opens on the garage: every vehicle as a card with its photo, decoded model, open sessions, and recalls. Opening one scopes the window to it (kept per window across launches; ⇧⌘G returns to the garage): Overview (decoded details, recalls callout, adapter, modules, sessions), References (service bulletins with search and an in-app PDF viewer, recalls, complaints), Photos (the owner's photos and reference photos; the cover is the best reference match until the owner adds a photo, then theirs, and they can pick which of theirs), and its sessions. VINs don't encode paint, so the owner picks a colour (and optionally the maker's paint name), and may give the trim as they know it (the demo is `S Q4`; vPIC says `Sport`); both steer the photo search. The owner's photos are resized JPEGs without location data under `Vehicles/<vehicle>/Photos`, deleted with the vehicle. Typing a VIN in the vehicle editor decodes it with NHTSA straight away; the VIN is sent to NHTSA automatically (the user's choice), other lookups send only make, model, and year. A live "Read vehicle information" check fills in a missing VIN. Owner's manuals aren't fetched: makers publish them only through their own portals, with no public API.

Each vehicle has one adapter profile. The Mac connect sheet switches it between the USB cable, the default for new Mac vehicles, and Bluetooth LE, while iPhone and iPad use Bluetooth LE.

Demo mode replays recordings through the same code as a live adapter where the recorded command order matches (adapter check, airbag module), and decodes the rest from their recordings with the production decoders (generic scan, vehicle info, ABS, body computer). Results are labelled "From recording". The steering-column module has no recording and says so.

Verified: engine and store behaviour by `swift test` against the real recordings; app builds universal with warnings as errors; app launches. Not verified: the app against the live car, sandboxed serial access to the vLinker FS, the iOS app over Bluetooth on a device, the Mac app over Bluetooth, and the screens by eye.

App phases: 1 foundation (done), 2 assistant (built, see below), 3 media (camera, video, audio capture), 4 guided workflow from symptoms to tests to a solution.

### Assistant

- The model is chosen per message: on this Mac, Claude, or OpenAI. Model IDs are editable in Settings (defaults `claude-opus-5-5`, `gpt-5.5`; presets for `claude-haiku-4-5`, `gpt-5.4-mini`).
- Its tools: `propose_check` (one of `generic_scan`, `vehicle_info`, `adapter_check`, `module_codes`, with the module restricted to the vehicle's own module labels), `ask_user`, and, when the vehicle's bulletins are loaded, `search_bulletins`, which the app answers at once because nothing on the car is involved. It cannot run anything on the car. A proposal becomes a `DiagnosticJob` only when the person approves it, and the check's result goes back to the model as the tool result. Declines, answers, and "moved on without answering" are reported the same way.
- Every request carries fresh session data (vehicle, problem, modules, timeline with payloads, and the vehicle's references: decoded model, recalls, complaint counts by component, bulletin count) inside a `<session_data>` block the model is told is data, never instructions. The on-device model gets summaries only, within a smaller budget.
- Cloud providers need a once-per-session consent that lists what is sent. The VIN is withheld from cloud providers unless allowed in Settings.
- Safety rules in every briefing: no probing or unplugging SRS/airbag/clock-spring circuits, manufacturer-code mappings labelled as interpretations, warnings for fuel, high voltage, lifting, and running engines indoors.
- Photos (attach or drop) are resized to 2000 px JPEG, which also strips location metadata, and stored under `Attachments/<session>`. The on-device model can't see them.
- Verified: stream decoding and request shapes against the documented examples, tool validation, briefing and redaction, Keychain round trip, and approval running a real demo check through the Workbench. Live provider tests run when `SPIA_ANTHROPIC_API_KEY` / `SPIA_OPENAI_API_KEY` are set; not yet run. The on-device path compiles but is untested (this Mac runs macOS 15).

## Vehicle onboarding: the survey

Any owner, using only the app, adds a car, connects, and ends with its modules found, named, and read: no CAN IDs, no code changes. The owner's Ghibli and Tiguan are development cars only. Today modules come only from Advanced → Edit Modules (raw bus and IDs) or the demo's `DemoGarage`, and discovery exists only in `spia discover`.

Flow: add the car (VIN, decoded by vPIC to make, model, and year), connect (the adapter check reports STN firmware), Survey This Car, review the results, save the modules. The vehicle overview offers "Find this car's modules" until the car has some, and the Run menu keeps "Survey This Car". Edit Modules stays under Advanced. The assistant can't propose a survey; it's the owner's action.

### What one survey does

A survey is one read-only `DiagnosticJob.survey(SurveyPlan)` with one `JobPayload.survey(SurveyReport)`, recorded and replayable like any check. A pure planner resolves the plan before it runs, from the catalog, the car's identity, the scope, and the adapter's capabilities: buses, exact request and reply IDs, timeouts, identification DIDs, the DTC status mask, and the catalog version. Because the plan is stored in the job, a saved survey replays exactly after the catalog changes. The survey starts from the post-connect adapter state (the in-place reset runs first after a module read) and ends module-addressed.

1. Buses. 500k (pins 6/14) always. 125k (pins 3/11) only on STN adapters that accept `STP 53`, and then only for the make's known modules unless the thorough search includes that bus. STN firmware (`STI`) is evidence, not proof: each bus reports whether it was reached.
2. Generic OBD. The emissions ECUs that answer `7DF`, named by `09 0A`, become modules named by themselves (engine `7E0` → `7E8`, transmission `7E1` → `7E9`).
3. Probe. Each candidate gets TesterPresent (`3E 00`) with a short fixed timeout and a filter on its exact reply ID. A positive reply, or any negative reply other than `78`, counts as a module; `78` is waited out. DiagnosticSessionControl (`10 01`), which other tools use for discovery, stays forbidden by the read-only rule; identification confirms each responder instead.
4. Identify. ReadDataByIdentifier, one DID at a time: `F190` VIN, `F197` system name, `F187`, `F191`, `F192`, `F194`, `F195`, `F19E`. Raw bytes are kept, and text is decoded only when it's printable. `31` means that DID isn't supported and the module still counts; `7E` or `7F` means found but not identifiable in the default session. The survey never changes session, never requests security access, and never works around a gateway (FCA's Secure Gateway, MY2018 on).
5. Codes. Each responder's DTCs with `19 02 09`.
6. Thorough only, and built in step 9: listen, then sweep. A monitor filtered to the sweep range (an aligned window) records which IDs the car already uses, and the sweep skips them. `BUFFER FULL`, or a listen cut short any other way, means the sweep doesn't run. Replies are accepted within an aligned window, and each pair is confirmed with a second probe on its exact reply ID, because reply IDs follow no formula: VW `713` → `77D` but `7E0` → `7E8`; FCA `744` → `4C4` but `620` → `504`.
7. Stop on bus errors, repeated `78`, adapter overflow, malformed ISO-TP, or replies from unexpected IDs. Only read-only services go out (`3E`, `22`, `19`, and the OBD modes), and the allowlist test covers the survey's planned commands.

Silence is never proof a module is absent: a gateway, a sleeping module, and a session-gated module all look alike. Unanswered candidates stay in the report and never become modules.

### Results and storage

For each module the report keeps its target, how it answered, its identification, its codes, and its provenance (identified, catalog observed, catalog reference, user entered). The results sheet shows the module's own name when it gave one (`F197` or `09 0A`), else the catalog's label marked unconfirmed, else "Module 7xx". The owner keeps, renames, and saves; `Garage.apply(report, choices, to:)` merges by bus, request, and reply. `ModulePreset` stays as it is, with `confirmed` meaning the module named itself. Full provenance lives in the session's survey result; a stored `source` field (a SpiaSchemaV2 migration) waits until the app needs it after a session is deleted. `SessionBoard` reads a survey's per-module codes the way it reads module reads.

### The catalog

Make knowledge ships as bundled, versioned JSON in SpiaKit: makes, then platforms (models and year ranges), then modules with label, bus, exact request and reply, and provenance with its source. Matching normalizes the vPIC make and model (case, punctuation, aliases) within bounded year ranges and never guesses a neighbouring generation. With no match, the survey covers the legislated range only and says make-specific coverage isn't available. Adding a make is a data change. The demo keeps the modules its recordings were made with, and a test keeps those modules in agreement with the catalog.

Seeds:

- Maserati M157, observed on the Ghibli: airbag `744` → `4C4`, ABS `747` → `4C7`, body computer `620` → `504`. Steering column `763` → `4E3` is from references and unverified.
- VW MQB, 24 modules, reference only, from a public list extracted from ODIS ([vag-uds-ids](https://github.com/ConnorHowell/vag-uds-ids)): gateway `710` → `77A`, central electronics `70E` → `778`, steering assist `712` → `77C`, brakes `713` → `77D`, airbag `715` → `77F`.

### Testing

Pure tests cover the catalog, the matcher, the planner (deterministic; a catalog change leaves an existing plan alone), filter construction, probe classification, identification decoding, merge rules, and board mapping. Until car captures exist, identification decoding may be tested against the worked examples in ISO 14229-1, labelled as normative vectors and never put into transcript files. Replay tests use only real captures: a bench capture (USB adapter, no car) runs the whole survey through its no-answer path, and the first car visit supplies responders, multi-frame identification, and codes. That visit follows the owner's path end to end: add by VIN, connect, survey, review, save, then replay the saved survey at the desk.

### Steps

1. The catalog: the JSON, decoder, and matcher. Survey types arrive with their first user: the plan in step 2, the report in step 4.
2. The planner for the standard survey, with its command-safety tests: an explicit allowlist of services (`09`, `3E`, `22`, `19`), the exact probe, the DID range, and a cap of 64 candidates.
3. The answers: TesterPresent classification shared by the CLI and the survey, identification decoding, and named negative response codes.
4. The survey in JobRunner: phases, cancellation, the ignition prompt, recording, addressing.
5. Replay and the demo, then the real bench capture through the executor.
6. Store and board: `Garage.apply`, the board mapping.
7. Onboarding UI: the overview card, the thorough-search warning, the results sheet, the Run menu entry.
8. The first car visit, on the owner's path.
9. The thorough search: per-platform sweep ranges as catalog data, listen first, sweep, and confirm each pair (item 6 above). It handles `BUFFER FULL` in `monitor` and waits until the standard survey works end to end.

Sources for these rules: Caring Caribou's [UDS discovery](https://github.com/CaringCaribou/caringcaribou/blob/master/documentation/uds.md) (listen first, blacklist, verify each pair), the [OBDLink family reference](https://www.scantool.net/scantool/downloads/678/obdlink_frpm_e.pdf) (filters, flow control, `STP 53`; filters must be set again after `STP`), and the Linux [can327 notes](https://kernel.org/doc/html/next/networking/device_drivers/can/can327.html) (ELM327 monitoring ends in `BUFFER FULL` and drops frames).

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
| iOS (#6) | `BLETransport` (CoreBluetooth), SwiftUI shell | Bluetooth FS on iPhone | `BLETransport` and `spia --ble` verified on the Ghibli; iOS app wiring builds, not yet run on an iPhone |
| Survey | In-app onboarding: find, identify, name, and read a car's modules | Bench capture replays through the survey; first car visit on the owner's path | designed 2026-09-28 |

Reordered 2026-09-26: the fault that started this project is not an emissions code (Mode 03/07/0A are clean), so UDS access to body modules moves ahead of the generic-OBD polish.

### Adapter state and check recordings

A module read leaves the adapter addressed to that module. The invariant is that every check starts
from the state established by `connect`: generic scan and vehicle information reinitialize the
adapter first when a module read ran earlier on the same connection. Adapter checks do not need
that reset, and a module read claims the module-addressed state before it sends its first command.

Saved check transcripts are standalone files in the unchanged `<ms> TX|RX <hex>` format. They
include the latest adapter initialization exchange followed by the check, with timestamps measured
from initialization and the real gap preserved. A fresh connection can therefore replay any saved
check in any order.

Demo mode can replay forward checks and decoded check steps at the timestamps in the car recording.
The app uses that recorded speed so the reading rows, progress text, cancellation, and prompts can
be exercised. Tests and screenshot fixtures use immediate replay and remain instant.

Completed live checks are standalone recordings tied to the vehicle. At the desk, only the newest
valid live recording for an exact check can be replayed through the production connection and job
runner. Its result is marked with the date the car was recorded, and replay results are never valid
inputs for another replay.

The connection sheet can choose Recordings when a vehicle has saved checks. The demo adapter still
uses bundled recordings, but its battery row is now produced by running the adapter check rather
than treating connection status as a current reading. The DEBUG fixture adds `replay`,
`replay-timeline`, and `recordings` (the connect sheet on Recordings) screens for a non-demo Ghibli
with the real adapter and airbag recordings, so the board, case file, and connect sheet show a
saved-check session without contacting a car.

The in-place reset is not verified against a real adapter yet. A bench capture still needs the USB
vLinker FS on USB power with no car: connect, read the airbag module, then run the scan. The scan
transcript should start with `ATZ` through `ATSP0` and end with `UNABLE TO CONNECT`. USB and BLE
reset behaviour remain unverified.

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

vLinker FS Bluetooth on the car (2017 Ghibli, 2026-09-27; macOS 15.7, Classic Bluetooth then BLE; fixtures `ghibli-bt-*.txt` are Classic):

- Car-powered only (7–30 V). Pairing needs its Connect button. It pairs as `vLinker FS 17879` (serial-number suffix); macOS creates `/dev/cu.vLinkerFS17879`.
- SDP: `JXSL-SPP` on RFCOMM channel 1, `JXSL-iAP` (MFi) on channel 2. The unit shipped in MFi mode.
- `ATZ` → `ELM327 v2.3`, `STI` → `STN2120 v5.8.1` (the USB unit is `STN1170 v4.3.2`), `STDI` → `vLinker FS r2`. `SerialTransport` works unchanged; the driver accepts `IOSSIOSPEED`.
- The scripted session decodes the same as the USB unit's: VIN, CAL IDs, CVNs, ECU names, DTC state. Simple commands took 9–46 ms (USB: 16 ms); bus-bound requests match. The first `ATZ` after opening the port can go unanswered for over 3 s while the link comes up.
- Only 2 of 12 connections carried data, each the first after a fresh pairing; a third pairing's first connection failed. Otherwise the port opens, nothing comes back, and closing it blocks about 10 s. Opening RFCOMM channel 1 directly with IOBluetooth failed with `0xE00002BC` three times, while channel 2 opened and ignored `ATZ`. Not spia (a raw termios test behaves the same), not the paired phone (its Bluetooth was off), not low voltage (engine running), not a sleeping adapter (button pressed).
- VgateFwUpdater (iOS) switched it to BLE+BT in its lower extension section: the bar fills and shows a check, and nothing changes until the adapter is unplugged and plugged back in. It then advertises over BLE as `vLinker FS-IOS` with service `18F0`.
- GATT: service `18F0` has `2AF0` (notify, indicate) and `2AF1` (write, write without response). Service `E7810A71-73AE-499D-8C15-FAA9AEF0C3F2` has one characteristic, `BEF8D6C9-9C21-4C9E-B632-BD58C1009F9F` (read, write, write without response, notify, indicate). Device Information is present. macOS reported 20-byte writes without response at connect and 182 once the MTU was negotiated.
- Over `18F0` from macOS CoreBluetooth: `ATZ` echoed, then `ELM327 v2.3` after 1.28 s. `ATE0`, `ATI`, `STI` (`STN2120 v5.8.1`), `STDI`, `ATRV` (14.4 V, engine running) each answered in about 30 ms, each reply in one notification. Classic Bluetooth in this mode is untested.
- Through `spia --ble` on macOS (ignition on; fixtures `ghibli-ble-ignition-on-*.txt`): `ports --ble` found it at -39 dBm. `probe` matched the USB unit (`STN2120 v5.8.1`, 12.0 V, `A6`, ECM `7E8` with 22 PIDs, TCM `7E9` with 6). The scripted session decodes identically to `ghibli-ignition-on-term.txt`. Simple commands took about 30 ms (USB: 16 ms); bus-bound requests were 15–45 ms slower; the scripted session took 4.2 s (USB: 3.3 s). Four connections in a row all worked. `capture` overflowed the adapter's buffer after 136 frames (about 0.25 s), so bus sniffing stays on USB.

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
