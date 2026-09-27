import Foundation
import OBDCore

/// What the app talks to: a real adapter or the demo car. Both run checks through the same
/// `JobRunner` and report the same events, so screens never special-case demo mode.
public protocol DiagnosticsBackend: Sendable {
    var adapter: AdapterDescriptor { get }
    func states() async -> AsyncStream<ConnectionState>
    func connect() async throws
    func disconnect() async
    func run(_ job: DiagnosticJob, transcript: URL?) async -> AsyncStream<JobEvent>
    func confirm(_ id: UUID) async
    func cancel() async
}

/// A physical adapter.
public actor LiveBackend: DiagnosticsBackend {
    public nonisolated let adapter: AdapterDescriptor
    private let connection: ConnectionManager
    private let runner: JobRunner

    public init(
        adapter: AdapterDescriptor, baud: Int = 115_200,
        transport: @escaping ConnectionManager.TransportFactory
    ) {
        self.adapter = adapter
        connection = ConnectionManager(adapter: adapter, baud: baud, transport: transport)
        runner = JobRunner(connection: connection)
    }

    public func states() async -> AsyncStream<ConnectionState> { await connection.states() }

    /// Connects and identifies the adapter, so the status shows firmware and voltage at once.
    public func connect() async throws {
        try await connection.connect()
        for await event in await runner.run(.adapterCheck) {
            if case .failed(let failure) = event { throw failure }
        }
    }

    public func disconnect() async { await connection.disconnect() }

    public func run(_ job: DiagnosticJob, transcript: URL?) async -> AsyncStream<JobEvent> {
        await runner.run(job, transcript: transcript)
    }

    public func confirm(_ id: UUID) async { await runner.confirm(id) }
    public func cancel() async { await runner.cancel() }
}
