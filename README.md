# spia

spia (Italian for a dashboard warning light, as in *spia motore*) reads a car through an OBD-II adapter. It is a Swift package with a command-line tool and a SwiftUI app for macOS, iPhone, and iPad, built around a Vgate vLinker FS (USB on the Mac, Bluetooth LE on iOS) and developed against a 2017 Maserati Ghibli.

The app adds a car by VIN, connects, and scans it: adapter and battery, the engine computers, every module the car answers at, and the codes from each. Codes are named from bundled CC0 data, explained by a model the owner chooses (Claude, OpenAI, or Apple's on-device model), and kept as the car's history. A problem gets a diagnosis: suspects ranked, the tests that tell them apart, what the owner found (with photos, clips, and sounds), then a cause and a fix. Everything the engine does to the car is read-only.

The plan, the decisions behind it, and the hardware notes live in [`docs/PLAN.md`](docs/PLAN.md). Read that before changing anything.

## Build and test

Swift 6, macOS 14 or later. The only dependency is `swift-argument-parser`.

```sh
swift build -Xswiftc -warnings-as-errors
swift test
swift format lint --strict --recursive Sources Tests Package.swift App
```

Tests replay real recorded adapter transcripts from `Tests/Fixtures/`; there are no mocks. CI runs the same three commands plus the app builds (`.github/workflows/ci.yml`).

## The app

Open `App/SpiaApp.xcodeproj` and run the `Spia` scheme, or:

```sh
xcodebuild -project App/SpiaApp.xcodeproj -scheme Spia build
```

Choose "Explore the demo" to use the Ghibli's recordings without a car or an adapter.

## The command line

```sh
swift run spia ports          # list serial ports, or BLE adapters with --ble
swift run spia probe          # identify the adapter and the car
swift run spia scan           # generic DTCs, freeze frame, readiness
swift run spia info           # VIN, calibration IDs, ECU names
swift run spia live           # poll PIDs as CSV
swift run spia capture        # sniff the CAN bus in candump format
swift run spia discover       # find modules with TesterPresent
swift run spia uds dtcs --tx 744 --rx 4C4   # one module's codes with UDS 19
swift run spia term           # raw AT/ST/OBD terminal
swift run spia inspect FILE   # read a saved transcript offline
```

Add `--record FILE` to save a transcript; recordings from the car become test fixtures.

## Layout

| Target | What it is |
|---|---|
| `OBDCore` | Protocol logic with no I/O: ELM327 session, J1979 decoders, ISO-TP, UDS |
| `OBDSerial` | macOS serial transport over POSIX termios |
| `OBDBluetooth` | CoreBluetooth transport for the vLinker FS |
| `SpiaKit` | Connection and job runner, the module survey, the bundled catalog, replay |
| `SpiaAssist` | Claude, OpenAI, and on-device model providers, the briefing, the review tools |
| `SpiaReference` | NHTSA decoding, recalls, bulletins, complaints, Wikimedia photos |
| `SpiaStore` | SwiftData schema, the garage, the workbench the screens bind to |
| `spia` | The command-line tool |
| `App/` | The SwiftUI app, screens only |

Third-party data attributions are in [`NOTICE`](NOTICE).
