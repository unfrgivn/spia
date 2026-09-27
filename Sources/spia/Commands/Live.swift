import ArgumentParser
import Foundation
import OBDCore

struct Live: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Poll selected generic OBD PIDs as CSV.")

    @OptionGroup var global: GlobalOptions
    @Option(name: .long, parsing: .upToNextOption, help: "One-byte PIDs in hex. Default: 0C 05.")
    var pid: [String] = []
    @Option(help: "Seconds between complete polling cycles. Default: 1.") var interval = 1.0
    @Option(help: "Maximum run time in seconds. Default: 30.") var duration = 30.0
    @Option(help: "Write CSV to a new file instead of stdout.") var out: String?

    func run() async throws {
        let pids = try pid.isEmpty ? [0x0C, 0x05] : pid.map { try parsePID($0) }
        let plan = try LivePollingPlan(pids: pids)
        guard interval.isFinite, interval >= 0.1, interval <= 60 else {
            throw LiveValidationError.invalidInterval
        }
        guard duration.isFinite, duration > 0, duration <= 86_400 else {
            throw LiveValidationError.invalidDuration
        }
        let schedule = try LiveSchedule(interval: .seconds(interval), duration: .seconds(duration))
        var options = global
        if options.protocol == .automatic { options.protocol = .can11bit500k }
        guard options.protocol == .can11bit500k || options.protocol == .can29bit500k else {
            throw ValidationError("live requires CAN 11-bit 500k (6) or CAN 29-bit 500k (7)")
        }
        if let out, FileManager.default.fileExists(atPath: out) {
            throw ValidationError("--out must name a new file")
        }
        if let record = options.record, let out,
            try canonicalIdentity(record) == canonicalIdentity(out)
        {
            throw ValidationError("--out and --record must be different files")
        }

        let output = try LiveOutput(path: out)
        try await output.write(LiveRowDecoder.header)
        let work = Task {
            try await Connection.with(options) { connection in
                let clock = ContinuousClock()
                let started = clock.now
                let deadline = started + schedule.duration
                var support = LiveSupportState(plan: plan)
                var knownECUs = Set<UInt32>()
                while let block = support.nextBlock() {
                    try Task.checkCancellation()
                    guard clock.now < deadline else { return }
                    let request = OBDRequest(service: .currentData, pid: block)
                    var responsesForSupport: [(ecu: UInt32, supported: Set<UInt8>)] = []
                    do {
                        let responses = try await connection.session.request(
                            request, timeout: boundedTimeout(clock.now.duration(to: deadline)))
                        for response in responses {
                            knownECUs.insert(response.ecu)
                            guard
                                case .currentData(let pid, .supported(let supported)) =
                                    ServiceResponse.decode(response.payload), pid == block
                            else {
                                continue
                            }
                            responsesForSupport.append((response.ecu, supported))
                        }
                    } catch ELM327Error.adapter(.noData) {
                        responsesForSupport = []
                    }
                    support.update(block: block, responses: responsesForSupport)
                    knownECUs.formUnion(responsesForSupport.map(\.ecu))
                }
                if !knownECUs.isEmpty
                    && plan.pids.allSatisfy({ pid in
                        knownECUs.allSatisfy {
                            support.disposition(pid: pid, ecu: $0) == .unsupported
                        }
                    })
                {
                    throw ValidationError("no requested PID is supported by any responding ECU")
                }

                var nextCycle = clock.now
                var unsupportedEmitted = Set<String>()
                while clock.now < deadline {
                    try Task.checkCancellation()
                    let pollable = plan.pids.filter { pid in
                        knownECUs.isEmpty
                            || knownECUs.contains {
                                support.disposition(pid: pid, ecu: $0) != .unsupported
                            }
                    }
                    for pid in pollable {
                        try Task.checkCancellation()
                        let request = OBDRequest(service: .currentData, pid: pid)
                        guard clock.now < deadline else { return }
                        do {
                            let responses = try await connection.session.request(
                                request, timeout: boundedTimeout(clock.now.duration(to: deadline)))
                            var responded = Set<UInt32>()
                            for response in responses {
                                knownECUs.insert(response.ecu)
                                let elapsed = elapsedSeconds(started, clock.now)
                                switch ServiceResponse.decode(response.payload) {
                                case .currentData(let responsePID, let value)
                                where responsePID == pid:
                                    responded.insert(response.ecu)
                                    for row in LiveRowDecoder.rows(
                                        pid: pid, ecu: response.ecu, value: value,
                                        elapsedSeconds: elapsed)
                                    { try await output.write(row.csvLine) }
                                case .negative(let service, let code)
                                where service == .some(.currentData):
                                    responded.insert(response.ecu)
                                    let status: String =
                                        switch code {
                                        case .serviceNotSupported, .subFunctionNotSupported:
                                            "unsupported"
                                        default: "unavailable"
                                        }
                                    try await output.write(
                                        LiveRowDecoder.unavailable(
                                            pid: pid, ecu: response.ecu, elapsedSeconds: elapsed,
                                            status: status
                                        ).csvLine)
                                default:
                                    responded.insert(response.ecu)
                                    try await output.write(
                                        LiveRowDecoder.unavailable(
                                            pid: pid, ecu: response.ecu, elapsedSeconds: elapsed,
                                            status: "unknown"
                                        ).csvLine)
                                }
                            }
                            let elapsed = elapsedSeconds(started, clock.now)
                            for ecu in knownECUs where !responded.contains(ecu) {
                                let disposition = support.disposition(pid: pid, ecu: ecu)
                                switch disposition {
                                case .unsupported:
                                    let key = "\(ecu)-\(pid)"
                                    if unsupportedEmitted.insert(key).inserted {
                                        try await output.write(
                                            LiveRowDecoder.unavailable(
                                                pid: pid, ecu: ecu, elapsedSeconds: elapsed,
                                                status: "unsupported"
                                            ).csvLine)
                                    }
                                case .supported:
                                    try await output.write(
                                        LiveRowDecoder.unavailable(
                                            pid: pid, ecu: ecu, elapsedSeconds: elapsed,
                                            status: "unavailable"
                                        ).csvLine)
                                case .unknown:
                                    try await output.write(
                                        LiveRowDecoder.unavailable(
                                            pid: pid, ecu: ecu, elapsedSeconds: elapsed,
                                            status: "unknown"
                                        ).csvLine)
                                }
                            }
                        } catch ELM327Error.adapter(.noData) {
                            let elapsed = elapsedSeconds(started, clock.now)
                            let status =
                                knownECUs.contains {
                                    support.disposition(pid: pid, ecu: $0) == .unknown
                                } ? "unknown" : "unavailable"
                            let targets = knownECUs.filter {
                                support.disposition(pid: pid, ecu: $0) == .supported
                            }
                            if targets.isEmpty {
                                try await output.write(
                                    LiveRowDecoder.unavailable(
                                        pid: pid, ecu: nil, elapsedSeconds: elapsed, status: status
                                    ).csvLine)
                            } else {
                                for ecu in targets {
                                    try await output.write(
                                        LiveRowDecoder.unavailable(
                                            pid: pid, ecu: ecu, elapsedSeconds: elapsed,
                                            status: status
                                        ).csvLine)
                                }
                            }
                        }
                    }
                    let now = clock.now
                    let candidate = nextCycle + schedule.interval
                    nextCycle = candidate > now ? candidate : now + schedule.interval
                    let wait = min(now.duration(to: nextCycle), now.duration(to: deadline))
                    if wait > .zero { try await Task.sleep(for: wait) }
                }
            }
        }
        do {
            try await awaitInterrupt(work)
        } catch {
            await output.close()
            throw error
        }
        await output.close()
    }

    private func parsePID(_ text: String) throws -> UInt8 {
        guard let value = UInt8(text, radix: 16) else {
            throw ValidationError("--pid must be one byte of hexadecimal")
        }
        return value
    }

    private func canonicalIdentity(_ path: String) throws -> URL {
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let inode = attributes[.systemFileNumber] as? NSNumber,
            let device = attributes[.systemNumber] as? NSNumber
        else { return url }
        return URL(fileURLWithPath: "file-id:\(device)-\(inode)")
    }

    private func elapsedSeconds(_ start: ContinuousClock.Instant, _ now: ContinuousClock.Instant)
        -> Double
    {
        let components = start.duration(to: now).components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
    private func boundedTimeout(_ duration: Duration) -> Duration { min(duration, .seconds(5)) }

    private func awaitInterrupt(_ work: Task<Void, Error>) async throws {
        let previous = signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        source.setEventHandler { work.cancel() }
        source.resume()
        defer {
            source.cancel()
            signal(SIGINT, previous)
        }
        try await work.value
    }
}

private actor LiveOutput {
    private let handle: FileHandle?
    private let stdout: Bool

    init(path: String?) throws {
        stdout = path == nil
        if let path {
            let url = URL(fileURLWithPath: path)
            try Data().write(to: url, options: .withoutOverwriting)
            handle = try FileHandle(forWritingTo: url)
        } else {
            handle = nil
        }
    }

    func write(_ line: String) throws {
        let data = Data((line + "\n").utf8)
        if stdout {
            try FileHandle.standardOutput.write(contentsOf: data)
        } else {
            try handle?.write(contentsOf: data)
        }
    }

    func close() { try? handle?.close() }
}
