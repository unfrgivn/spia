import Foundation
import OBDCore

public enum ReplayBackendError: Error, Equatable, Sendable, CustomStringConvertible {
    case noSavedChecks
    case noSavedCheck(DiagnosticJob)

    public var description: String {
        switch self {
        case .noSavedChecks:
            return
                "There are no saved recordings for this vehicle yet. Run a check on the car to record one."
        case .noSavedCheck(let job):
            return
                "There’s no saved recording of “\(job.title)” for this vehicle yet. Run it on the car to record one."
        }
    }
}

/// Replays this vehicle's own completed checks through the production connection and job runner.
public actor ReplayBackend: DiagnosticsBackend {
    public nonisolated let adapter: AdapterDescriptor
    private let checks: [SavedCheck]
    private let timing: ReplayTiming
    private var state: ConnectionState = .disconnected {
        didSet { for continuation in observers.values { continuation.yield(state) } }
    }
    private var observers: [UUID: AsyncStream<ConnectionState>.Continuation] = [:]
    private var runner: JobRunner?

    public init(
        displayName: String, checks: [SavedCheck], timing: ReplayTiming = .recorded
    ) {
        adapter = AdapterDescriptor(kind: .replay, displayName: displayName)
        self.checks = checks
        self.timing = timing
    }

    public func currentState() async -> ConnectionState { state }

    public func states() async -> AsyncStream<ConnectionState> {
        let (stream, continuation) = AsyncStream.makeStream(of: ConnectionState.self)
        let id = UUID()
        observers[id] = continuation
        continuation.yield(state)
        continuation.onTermination = { _ in Task { await self.removeObserver(id) } }
        return stream
    }

    private func removeObserver(_ id: UUID) { observers[id] = nil }

    public func connect() async throws {
        guard let newest = newestCheck(for: .adapterCheck) ?? newestCheck else {
            state = .failed(message: ReplayBackendError.noSavedChecks.description)
            throw ReplayBackendError.noSavedChecks
        }
        state = .connecting
        do {
            let (_, connection) = try ReplaySupport.connection(
                adapter: adapter, transcript: newest.transcript, timing: timing)
            try await connection.connect()
            if newest.job == .adapterCheck {
                let checkRunner = JobRunner(connection: connection)
                for await event in await checkRunner.run(.adapterCheck) {
                    if case .failed(let failure) = event { throw failure }
                }
            }
            guard let status = await connection.state.status else {
                throw ConnectionError.notConnected
            }
            state = .ready(status)
        } catch {
            state = .failed(message: error.readable)
            throw error
        }
    }

    public func disconnect() { state = .disconnected }

    public func run(_ job: DiagnosticJob, transcript: URL?) async -> AsyncStream<JobEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: JobEvent.self)
        guard case .ready = state else {
            continuation.yield(.started(job))
            continuation.yield(.failed(ReplaySupport.failure(ConnectionError.notConnected)))
            continuation.finish()
            return stream
        }
        guard let saved = newestCheck(for: job) else {
            continuation.yield(.started(job))
            continuation.yield(.failed(ReplaySupport.failure(ReplayBackendError.noSavedCheck(job))))
            continuation.finish()
            return stream
        }
        do {
            let (transport, connection) = try ReplaySupport.connection(
                adapter: adapter, transcript: saved.transcript, timing: .immediate)
            try await connection.connect()
            await transport.setTiming(timing)
            let checkRunner = JobRunner(connection: connection)
            runner = checkRunner
            let events = await checkRunner.run(job)
            Task {
                for await event in events {
                    if case .completed(let result) = event {
                        do {
                            let reference = try transcript.map {
                                try ReplaySupport.copy(saved.transcript, to: $0)
                            }
                            continuation.yield(
                                .completed(
                                    JobResult(
                                        job: result.job, payload: result.payload,
                                        source: .replay(recorded: saved.recorded),
                                        transcript: reference)))
                        } catch {
                            continuation.yield(.failed(ReplaySupport.failure(error)))
                        }
                    } else {
                        continuation.yield(event)
                    }
                }
                continuation.finish()
            }
        } catch {
            continuation.yield(.started(job))
            continuation.yield(.failed(ReplaySupport.failure(error)))
            continuation.finish()
        }
        return stream
    }

    public nonisolated func canRun(_ job: DiagnosticJob) -> Bool {
        checks.contains { $0.job == job }
    }

    public func confirm(_ id: UUID) async { await runner?.confirm(id) }
    public func cancel() async { await runner?.cancel() }

    private var newestCheck: SavedCheck? {
        checks.max { $0.recorded < $1.recorded }
    }

    private func newestCheck(for job: DiagnosticJob) -> SavedCheck? {
        checks.filter { $0.job == job }.max { $0.recorded < $1.recorded }
    }

}
