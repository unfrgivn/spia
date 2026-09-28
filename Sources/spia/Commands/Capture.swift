import ArgumentParser
import Dispatch
import Foundation
import OBDCore

struct Capture: AsyncParsableCommand {
    private static let maximumDuration = 86_400.0
    private static let maximumBaud = 10_000_000
    static let configuration = CommandConfiguration(
        abstract: "Sniff the CAN bus. Frames go to stdout in candump format; Ctrl-C or "
            + "--duration stops and prints a per-ID summary on stderr.")

    @OptionGroup var global: GlobalOptions

    @Option(name: .long, help: "Stop after this many seconds. Default: run until Ctrl-C.")
    var duration: Double?

    @Option(
        name: .long, parsing: .upToNextOption,
        help: "Only keep these arbitration IDs (hex, e.g. 102 7E8). Default: everything.")
    var id: [String] = []

    @Option(name: .long, help: "Also append the candump log to this file.")
    var out: String?

    @Flag(name: .long, help: "Do not print frames, only the summary.")
    var quiet = false

    @Option(name: .long, help: "Monitor command. ATMA on any ELM327; STMA on STN firmware.")
    var command = "ATMA"

    @Option(
        name: .long,
        help: ArgumentHelp(
            "STN protocol number (STP) to select after connecting, overriding --protocol.",
            discussion:
                "53 is ISO 15765 11-bit on the second CAN transceiver (DLC pins 3/11, 125k), which "
                + "is where FCA-derived cars put the interior bus. See the STN11xx reference."))
    var stp: Int?

    @Option(name: .long, help: "CAN bit rate for --stp (STPBR), e.g. 125000.")
    var stpBaud: Int?

    @Option(
        name: .long,
        help: ArgumentHelp(
            "Switch the adapter UART to this rate before monitoring (default 2000000 for serial; Bluetooth keeps its adapter rate, so only 0 is valid there).",
            discussion:
                "A busy 500k bus overflows the adapter at 115200. 0 keeps the connection rate."
        ))
    var uartBaud: Int?

    func run() async throws {
        try validateOptions()
        var options = global
        if options.protocol == .automatic {
            options.protocol = .can11bit500k
            stderr(
                "Monitor mode needs a fixed protocol; using 6 (CAN 11-bit 500k). Pass --protocol to change."
            )
        }
        stderr(
            "Warning: monitor output is adapter-formatted; it is not guaranteed raw/lossless CAN.")
        let filter = try Set(id.map(parseID))
        if let out, let record = options.record,
            try canonicalFileURL(out) == canonicalFileURL(record)
        {
            throw ValidationError("--out and --record must be different files")
        }
        let file = try out.map(openForAppend)
        defer { try? file?.close() }

        try await Connection.with(options) { connection in
            let recorder = CaptureRecorder(filter: filter, echo: !quiet, file: file)
            stderr("Connected to \(connection.adapterIdentity).")
            let requestedBaud = uartBaud ?? (options.ble || options.bleID != nil ? 0 : 2_000_000)
            if requestedBaud > 0, requestedBaud != options.baud {
                try await connection.session.switchBaud(to: requestedBaud)
                stderr("UART switched to \(requestedBaud) baud.")
            }
            if let stp {
                var setup = ["STP \(stp)"]
                if let stpBaud {
                    setup.append("STPBR \(stpBaud)")
                }
                for line in setup {
                    let reply = try await connection.session.send(line)
                    guard reply.trimmingCharacters(in: .whitespacesAndNewlines) == "OK" else {
                        throw ELM327Error.unexpectedResponse(command: line, response: reply)
                    }
                }
                stderr("STN protocol \(stp): \(try await connection.session.send("STPRS"))")
            }
            stderr("Monitoring with \(command); Ctrl-C to stop.")

            let work = Task {
                try await connection.session.monitor(command) { elapsed, event in
                    await recorder.handle(elapsed, event)
                }
            }
            let interrupt = installInterruptHandler { work.cancel() }
            defer { interrupt.cancel() }
            var timer: Task<Void, Never>?
            if let duration {
                timer = Task {
                    try? await Task.sleep(for: .seconds(duration))
                    if !Task.isCancelled { work.cancel() }
                }
            }
            defer { timer?.cancel() }
            try await work.value

            if let failure = await recorder.failure() { throw failure }

            let report = await recorder.report()
            stderr(report)
        }
    }

    private func validateOptions() throws {
        if let duration, !duration.isFinite || duration <= 0 || duration > Self.maximumDuration {
            throw ValidationError("--duration must be finite, positive, and at most 86400 seconds")
        }
        guard command == "ATMA" || command == "STMA" else {
            throw ValidationError("--command must be ATMA or STMA")
        }
        let requestedBaud = uartBaud ?? 0
        guard requestedBaud >= 0, requestedBaud <= Self.maximumBaud else {
            throw ValidationError("--uart-baud must be zero or positive and at most 10000000")
        }
        if (global.ble || global.bleID != nil), requestedBaud != 0 {
            throw ValidationError(
                "--uart-baud must be 0 for Bluetooth; Bluetooth has no UART rate to switch")
        }
        if let stp, stp != 53 && stp != 54 {
            throw ValidationError("--stp must be 53 or 54")
        }
        if let stpBaud {
            guard stp != nil else { throw ValidationError("--stp-baud requires --stp") }
            guard stpBaud == 125_000 else {
                throw ValidationError("--stp-baud currently supports only 125000")
            }
        }
        switch global.protocol {
        case .automatic, .can11bit500k, .can29bit500k, .can11bit250k, .can29bit250k:
            break
        default:
            throw ValidationError("capture requires CAN protocol 6, 7, 8, 9, or automatic")
        }
    }

    private func parseID(_ text: String) throws -> UInt32 {
        guard let value = UInt64(text, radix: 16) else {
            throw ValidationError("'\(text)' is not a hex CAN ID")
        }
        guard value <= 0x1FFF_FFFF else {
            throw ValidationError("'\(text)' exceeds the 29-bit CAN ID limit")
        }
        return UInt32(value)
    }

    private func openForAppend(_ path: String) throws -> FileHandle {
        if !FileManager.default.fileExists(atPath: path) {
            try Data().write(to: URL(fileURLWithPath: path))
        }
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.seekToEnd()
        return handle
    }

    private func canonicalFileURL(_ path: String) throws -> URL {
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let identifier = attributes[.systemFileNumber] as? NSNumber
        else { return url }
        return URL(fileURLWithPath: "file-number:\(identifier)")
    }

    /// Ctrl-C cancels the capture instead of killing the process, so the adapter is taken out of
    /// monitor mode and the summary still prints.
    private func installInterruptHandler(_ action: @escaping @Sendable () -> Void)
        -> DispatchSourceSignal
    {
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        source.setEventHandler(handler: action)
        source.resume()
        return source
    }
}

/// Owns the mutable capture state so the monitor callback stays `Sendable`.
actor CaptureRecorder {
    private let filter: Set<UInt32>
    private let echo: Bool
    private let file: FileHandle?
    private var summary = CaptureSummary()
    private var messages: [ELM327AdapterMessage] = []
    private var unparsable = 0
    private var dropped = 0
    private var writeFailure: Error?

    init(filter: Set<UInt32>, echo: Bool, file: FileHandle?) {
        self.filter = filter
        self.echo = echo
        self.file = file
    }

    func handle(_ elapsed: Duration, _ event: MonitorEvent) -> Bool {
        switch event {
        case .frame(let frame):
            guard filter.isEmpty || filter.contains(frame.header) else {
                dropped += 1
                return true
            }
            summary.record(frame, at: elapsed)
            let line = CandumpFormat.line(elapsed: elapsed, frame: frame)
            if echo {
                print(line)
            }
            do {
                try file?.write(contentsOf: Data((line + "\n").utf8))
            } catch {
                writeFailure = error
                return false
            }
        case .message(let message):
            messages.append(message)
        case .unparsable:
            unparsable += 1
        case .prompt:
            break
        }
        return true
    }

    func failure() -> Error? { writeFailure }

    func report() -> String {
        var lines: [String] = []
        let rows = summary.rows
        lines.append("")
        lines.append(
            "\(summary.frameCount) frames from \(rows.count) IDs"
                + (dropped > 0 ? ", \(dropped) filtered out" : "")
                + (unparsable > 0 ? ", \(unparsable) unparsable lines" : ""))
        if !messages.isEmpty {
            let counted = Dictionary(grouping: messages, by: \.description)
                .map { "\($0.key) x\($0.value.count)" }.sorted()
            lines.append("Adapter messages: \(counted.joined(separator: ", "))")
        }
        if rows.isEmpty {
            return lines.joined(separator: "\n")
        }
        lines.append("")
        lines.append(
            pad("ID", 9) + pad("count", 7) + pad("Hz", 7) + pad("len", 5) + pad("changing", 18)
                + "last")
        for row in rows {
            let hz = row.hertz.map { String(format: "%.1f", $0) } ?? "-"
            let changing =
                row.changingBytes.isEmpty
                ? "-" : row.changingBytes.map(String.init).joined(separator: ",")
            let length = row.lengths.map(String.init).joined(separator: "/")
            lines.append(
                pad(CandumpFormat.id(row.id), 9) + pad(String(row.count), 7) + pad(hz, 7)
                    + pad(length, 5) + pad(changing, 18)
                    + row.last.map { String(format: "%02X", $0) }.joined(separator: " "))
        }
        return lines.joined(separator: "\n")
    }

    private func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text + " " : text + String(repeating: " ", count: width - text.count)
    }
}

/// The SocketCAN `candump -l` log format, so captures open in SavvyCAN, can-utils, cantools.
enum CandumpFormat {
    static func line(elapsed: Duration, frame: CANFrame) -> String {
        let seconds = elapsed / .seconds(1)
        let data = frame.data.map { String(format: "%02X", $0) }.joined()
        return String(format: "(%.6f) can0 ", seconds) + id(frame.header) + "#" + data
    }

    /// 3 hex digits for 11-bit IDs, 8 for 29-bit, matching candump.
    static func id(_ header: UInt32) -> String {
        String(format: header > 0x7FF ? "%08X" : "%03X", header)
    }
}
