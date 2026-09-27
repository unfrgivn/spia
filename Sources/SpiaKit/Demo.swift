import CryptoKit
import Foundation
import OBDCore

/// Real recordings from the 2017 Maserati Ghibli S Q4 on 2026-09-26, bundled for demo mode.
public enum DemoRecording: String, CaseIterable, Sendable {
    /// Ignition on: adapter identity, firmware, and voltage, then the generic probe.
    case adapterProbe = "ghibli-ignition-on-probe"
    /// Ignition on, engine off: generic OBD scan and vehicle information.
    case genericReads = "ghibli-ignition-on-term"
    /// Airbag controller trouble codes, recorded with the same commands the app sends.
    case airbagCodes = "ghibli-orc-flowcontrol"
    /// ABS and body computer trouble codes.
    case absAndBodyCodes = "ghibli-abs-bcm-flowcontrol"
    /// The adapter on USB power with no car attached.
    case adapterWithoutCar = "vlinker-fs-usb-only-probe"

    public func url() throws -> URL {
        guard
            let url = Bundle.module.url(
                forResource: rawValue, withExtension: "txt", subdirectory: "Recordings")
        else {
            throw DemoError.missingRecording(rawValue)
        }
        return url
    }

    public func events() throws -> [TranscriptEvent] {
        try Transcript.decodeFile(String(contentsOf: url(), encoding: .utf8))
    }
}

public enum DemoError: Error, Equatable, Sendable, CustomStringConvertible {
    case missingRecording(String)
    case noRecording(DiagnosticJob)
    case recordingHasNoAnswer(String)

    public var description: String {
        switch self {
        case .missingRecording(let name):
            return "the demo recording \(name) is missing from the app"
        case .noRecording(let job):
            return "There is no recording of “\(job.title)” for this module. "
                + "Connect the adapter to the car to run it."
        case .recordingHasNoAnswer(let name):
            return "the recording \(name) contains no answer for this check"
        }
    }
}

/// The demo car, with the modules found on it during the car session.
public enum DemoGarage {
    public static let vehicleName = "2017 Maserati Ghibli S Q4"
    public static let vin = "ZAM57RTS4H1249941"
    public static let adapter = AdapterDescriptor(kind: .demo, displayName: "Ghibli recordings")

    public struct Module: Sendable, Equatable {
        /// Working label from FCA references, not confirmed by identification data.
        public let label: String
        public let target: ModuleTarget
    }

    public static let airbag = Module(
        label: "Airbag controller (ORC)",
        target: ModuleTarget(known: .highSpeed, request: 0x744, response: 0x4C4))
    public static let abs = Module(
        label: "ABS", target: ModuleTarget(known: .highSpeed, request: 0x747, response: 0x4C7))
    public static let bodyComputer = Module(
        label: "Body computer (BCM)",
        target: ModuleTarget(known: .highSpeed, request: 0x620, response: 0x504))
    public static let steeringColumn = Module(
        label: "Steering column (SCCM)",
        target: ModuleTarget(known: .highSpeed, request: 0x763, response: 0x4E3))

    public static let modules = [airbag, abs, bodyComputer, steeringColumn]
}

/// Demo mode. Checks whose recorded command order matches the app's are replayed through the
/// real `ConnectionManager` and `JobRunner`, byte for byte. The rest are decoded from their
/// recording with the production decoders. Either way the result says it came from a recording.
public actor DemoBackend: DiagnosticsBackend {
    public nonisolated let adapter = DemoGarage.adapter
    private var state: ConnectionState = .disconnected {
        didSet { for continuation in observers.values { continuation.yield(state) } }
    }
    private var observers: [UUID: AsyncStream<ConnectionState>.Continuation] = [:]
    private var runner: JobRunner?

    public init() {}

    public func currentState() -> ConnectionState { state }

    public func states() -> AsyncStream<ConnectionState> {
        let (stream, continuation) = AsyncStream.makeStream(of: ConnectionState.self)
        let id = UUID()
        observers[id] = continuation
        continuation.yield(state)
        continuation.onTermination = { _ in Task { await self.removeObserver(id) } }
        return stream
    }

    private func removeObserver(_ id: UUID) { observers[id] = nil }

    /// "Connecting" replays the recorded adapter check, so the status shows the real adapter.
    public func connect() async throws {
        state = .connecting
        do {
            let (_, connection) = try await replay(.adapterProbe)
            for await event in await JobRunner(connection: connection).run(.adapterCheck) {
                if case .failed(let failure) = event { throw failure }
            }
            guard let status = await connection.state.status else {
                throw ConnectionError.notConnected
            }
            state = .ready(status)
        } catch {
            state = .failed(message: String(describing: error))
            throw error
        }
    }

    public func disconnect() { state = .disconnected }

    public func run(_ job: DiagnosticJob, transcript: URL?) async -> AsyncStream<JobEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: JobEvent.self)
        guard case .ready = state else {
            continuation.yield(.started(job))
            continuation.yield(.failed(Self.failure(ConnectionError.notConnected)))
            continuation.finish()
            return stream
        }
        do {
            switch job {
            case .adapterCheck:
                try await forward(
                    job, recording: .adapterProbe, transcript: transcript, to: continuation)
            case .moduleDTCs(let target) where target == DemoGarage.airbag.target:
                try await forward(
                    job, recording: .airbagCodes, transcript: transcript, to: continuation)
            case .moduleDTCs(let target)
            where target == DemoGarage.abs.target || target == DemoGarage.bodyComputer.target:
                try decoded(
                    job, recording: .absAndBodyCodes, transcript: transcript, to: continuation
                ) { report in
                    let answers = report.uds.filter { answer in
                        guard answer.ecu == target.response else { return false }
                        if case .negative(_, .responsePending) = answer.response { return false }
                        return true
                    }
                    guard let answer = answers.last else {
                        throw DemoError.recordingHasNoAnswer(DemoRecording.absAndBodyCodes.rawValue)
                    }
                    return .moduleDTCs(ModuleDTCs(target: target, response: answer.response))
                }
            case .vehicleInfo:
                try decoded(job, recording: .genericReads, transcript: transcript, to: continuation)
                {
                    .vehicleInfo($0.obdInfo.map(ECUIdentity.init))
                }
            case .genericScan:
                try decoded(job, recording: .genericReads, transcript: transcript, to: continuation)
                {
                    .genericScan($0.obdScan.map(ECUScan.init))
                }
            case .moduleDTCs:
                throw DemoError.noRecording(job)
            }
        } catch {
            continuation.yield(.started(job))
            continuation.yield(.failed(Self.failure(error)))
            continuation.finish()
        }
        return stream
    }

    public func confirm(_ id: UUID) async { await runner?.confirm(id) }
    public func cancel() async { await runner?.cancel() }

    /// A fresh connection on a replay of `recording`; each replay can only be played once.
    private func replay(_ recording: DemoRecording) async throws -> (
        ReplayTransport, ConnectionManager
    ) {
        let transport = try ReplayTransport(contentsOf: recording.url())
        let connection = ConnectionManager(adapter: adapter) { transport }
        try await connection.connect()
        return (transport, connection)
    }

    private func forward(
        _ job: DiagnosticJob, recording: DemoRecording, transcript: URL?,
        to continuation: AsyncStream<JobEvent>.Continuation
    ) async throws {
        let (_, connection) = try await replay(recording)
        let runner = JobRunner(connection: connection)
        self.runner = runner
        let events = await runner.run(job, transcript: transcript)
        Task {
            for await event in events {
                if case .completed(let result) = event {
                    continuation.yield(
                        .completed(
                            JobResult(
                                job: result.job, payload: result.payload,
                                source: .recording(recording.rawValue),
                                transcript: result.transcript)))
                } else {
                    continuation.yield(event)
                }
            }
            continuation.finish()
        }
    }

    private func decoded(
        _ job: DiagnosticJob, recording: DemoRecording, transcript: URL?,
        to continuation: AsyncStream<JobEvent>.Continuation,
        _ extract: (TranscriptInspectionReport) throws -> JobPayload
    ) throws {
        let events = try recording.events()
        let report = TranscriptInspection.inspect(events)
        let payload = try extract(report)
        let reference = try transcript.map { try Self.copy(recording, to: $0) }
        continuation.yield(.started(job))
        for exchange in report.exchanges where exchange.kind == "OBD" || exchange.kind == "UDS" {
            continuation.yield(.step("Recorded answer to \(hex(exchange.request))"))
        }
        continuation.yield(
            .completed(
                JobResult(
                    job: job, payload: payload, source: .recording(recording.rawValue),
                    transcript: reference)))
        continuation.finish()
    }

    /// Saves the original recording as the check's transcript, unchanged.
    private static func copy(_ recording: DemoRecording, to url: URL) throws -> TranscriptReference
    {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try Data(contentsOf: recording.url())
        try data.write(to: url)
        return TranscriptReference(
            fileName: url.lastPathComponent, byteCount: data.count,
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }

    private static func failure(_ error: any Error) -> JobFailure {
        JobFailure(
            message: String(describing: error), reconnectRequired: false, cancelled: false,
            transcript: nil)
    }
}
