import CryptoKit
import Foundation
import OBDCore

public enum ConnectionError: Error, Equatable, Sendable, CustomStringConvertible {
    case notConnected
    case reconnectRequired(String)
    case busy

    public var description: String {
        switch self {
        case .notConnected: return "not connected to an adapter"
        case .reconnectRequired(let reason): return "reconnect required: \(reason)"
        case .busy: return "another check is using the adapter"
        }
    }
}

/// Sole owner of one adapter session. Everything that talks to the adapter goes through
/// `withSession`, which admits one caller at a time, so multi-command checks cannot interleave.
public actor ConnectionManager {
    public typealias TransportFactory = @Sendable () throws -> any Transport

    public nonisolated let adapter: AdapterDescriptor
    private let baud: Int
    private let makeTransport: TransportFactory
    private var session: ELM327Session?
    private var selectedProtocol = ELM327Protocol.automatic
    private var addressing = AdapterAddressing.postConnect
    private var recorder: TranscriptRecorder?
    private var inUse = false
    public private(set) var state: ConnectionState = .disconnected {
        didSet { for continuation in observers.values { continuation.yield(state) } }
    }
    private var observers: [UUID: AsyncStream<ConnectionState>.Continuation] = [:]

    public init(
        adapter: AdapterDescriptor, baud: Int = 115_200, transport: @escaping TransportFactory
    ) {
        self.adapter = adapter
        self.baud = baud
        self.makeTransport = transport
    }

    /// The current state, then every change. Any number of observers may subscribe.
    public func states() -> AsyncStream<ConnectionState> {
        let (stream, continuation) = AsyncStream.makeStream(of: ConnectionState.self)
        let id = UUID()
        observers[id] = continuation
        continuation.yield(state)
        continuation.onTermination = { _ in Task { await self.removeObserver(id) } }
        return stream
    }

    private func removeObserver(_ id: UUID) { observers[id] = nil }

    public func connect(protocol selected: ELM327Protocol = .automatic) async throws {
        guard !inUse else { throw ConnectionError.busy }
        if session != nil { await disconnect() }
        state = .connecting
        do {
            let recorder = TranscriptRecorder(try makeTransport())
            let session = ELM327Session(transport: recorder, baud: baud)
            let identity = try await session.connect(protocol: selected)
            selectedProtocol = selected
            addressing = .postConnect
            self.recorder = recorder
            self.session = session
            state = .ready(AdapterStatus(identity: identity))
        } catch {
            state = .failed(message: error.readable)
            throw error
        }
    }

    public func disconnect() async {
        await session?.disconnect()
        session = nil
        recorder = nil
        addressing = .postConnect
        state = .disconnected
    }

    /// Makes the adapter state safe for `job`, reinitialising in place when a previous module
    /// read left it addressed to that module. Module reads claim that state before any command.
    public func prepare(for job: DiagnosticJob) async throws {
        switch state {
        case .ready: break
        case .reconnectRequired(let reason): throw ConnectionError.reconnectRequired(reason)
        default: throw ConnectionError.notConnected
        }
        guard let session, !inUse else { throw ConnectionError.busy }
        inUse = true
        defer { inUse = false }
        if addressing.needsReinitialization(for: job) {
            do {
                try await session.reinitialize(protocol: selectedProtocol)
            } catch {
                addressing = .reconnectRequired(reason: error.readable)
                state = .reconnectRequired(reason: error.readable)
                throw error
            }
        }
        addressing = addressing.state(after: job)
    }

    /// Runs `body` with exclusive use of the session. An error that may have left the adapter
    /// mid-exchange moves the connection to `reconnectRequired`.
    public func withSession<T: Sendable>(
        _ body: @Sendable (ELM327Session) async throws -> T
    ) async throws -> T {
        switch state {
        case .ready: break
        case .reconnectRequired(let reason): throw ConnectionError.reconnectRequired(reason)
        default: throw ConnectionError.notConnected
        }
        guard let session, !inUse else { throw ConnectionError.busy }
        inUse = true
        defer { inUse = false }
        do {
            return try await body(session)
        } catch {
            if Self.desynchronizes(error) {
                state = .reconnectRequired(reason: error.readable)
            }
            throw error
        }
    }

    /// Merges newly learned adapter facts into the ready state.
    public func update(firmware: String?? = nil, hardware: String?? = nil, voltage: Double?? = nil)
    {
        guard case .ready(var status) = state else { return }
        if let firmware { status.firmware = firmware }
        if let hardware { status.hardware = hardware }
        if let voltage { status.voltage = voltage }
        state = .ready(status)
    }

    public func beginRecording(to url: URL) async throws {
        guard let recorder else { throw ConnectionError.notConnected }
        try await recorder.start(url)
    }

    /// Stops recording and describes the file. Throws if any byte could not be written.
    public func endRecording() async throws -> TranscriptReference? {
        try await recorder?.stop()
    }

    /// Errors after which the adapter may still be sending, or may be waiting for more input.
    /// Adapter status lines (`NO DATA`) and decode errors arrive after the prompt and are safe.
    static func desynchronizes(_ error: any Error) -> Bool {
        switch error {
        case is CancellationError: return true
        case let error as ELM327Error:
            switch error {
            case .timeout, .transportUnsynchronized, .responseTooLarge: return true
            case .adapter, .unexpectedResponse, .invalidCANHeader, .invalidTimeout,
                .operationInProgress:
                return false
            }
        case is GenericOBDWorkflow.Failure, is UDSDTCReadError, is UDSDTCDecodeError,
            is UDSMessageAssemblyError, is ELM327ParseError, is ISOTPError:
            return false
        default:
            // Transport I/O failures: the serial line itself broke.
            return true
        }
    }
}

public enum TranscriptError: Error, Equatable, Sendable {
    case writeFailed(String)
}

/// Passes bytes through and, while a check is running, writes them to a transcript file in the
/// same format as `spia --record`, so saved checks can be replayed and inspected later.
actor TranscriptRecorder: Transport {
    private let base: any Transport
    private let clock = ContinuousClock()
    private var file: (url: URL, handle: FileHandle, started: ContinuousClock.Instant)?
    private var failure: String?

    init(_ base: any Transport) { self.base = base }

    func start(_ url: URL) throws {
        try? file?.handle.close()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
        file = (url, try FileHandle(forWritingTo: url), clock.now)
        failure = nil
    }

    func stop() throws -> TranscriptReference? {
        guard let file else { return nil }
        self.file = nil
        try file.handle.close()
        if let failure { throw TranscriptError.writeFailed(failure) }
        let data = try Data(contentsOf: file.url)
        return TranscriptReference(
            fileName: file.url.lastPathComponent, byteCount: data.count,
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }

    func open() async throws { try await base.open() }
    func close() async { await base.close() }
    func setBaud(_ baud: Int) async throws { try await base.setBaud(baud) }

    func write(_ bytes: [UInt8]) async throws {
        try await base.write(bytes)
        record(.tx, bytes)
    }

    func read(timeout: Duration) async throws -> [UInt8] {
        let bytes = try await base.read(timeout: timeout)
        if !bytes.isEmpty { record(.rx, bytes) }
        return bytes
    }

    /// A failed write must not break the diagnosis in progress; it is reported by `stop()`.
    private func record(_ direction: TranscriptEvent.Direction, _ bytes: [UInt8]) {
        guard let file, failure == nil else { return }
        let elapsed = file.started.duration(to: clock.now) / .milliseconds(1)
        let event = TranscriptEvent(
            milliseconds: UInt64(max(0, elapsed)), direction: direction, bytes: bytes)
        do {
            try file.handle.write(contentsOf: Data((Transcript.encode(event) + "\n").utf8))
        } catch {
            failure = error.readable
        }
    }
}
