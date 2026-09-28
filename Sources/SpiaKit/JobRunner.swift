import Foundation
import OBDCore

/// Something only the person at the car can do.
public enum UserAction: String, Codable, Sendable {
    case turnIgnitionOn

    public var title: String {
        switch self {
        case .turnIgnitionOn: return "Turn the ignition on"
        }
    }

    public var instructions: String {
        switch self {
        case .turnIgnitionOn:
            return "The car didn't answer. Put the ignition in RUN so the dash lights up. "
                + "On push-button cars, press START without the brake pedal. The engine can stay off."
        }
    }
}

public struct JobFailure: Error, Sendable, Equatable {
    public let message: String
    /// The adapter must be reconnected before the next check.
    public let reconnectRequired: Bool
    public let cancelled: Bool
    /// Whatever was exchanged before the failure, which is often the most useful evidence.
    public let transcript: TranscriptReference?
}

public enum JobEvent: Sendable, Equatable {
    case started(DiagnosticJob)
    /// Data is being pulled from the car.
    case step(String)
    /// The check is paused until the user confirms `action` (or cancels).
    case needsUser(id: UUID, action: UserAction)
    case userConfirmed(id: UUID)
    case warning(String)
    case completed(JobResult)
    case failed(JobFailure)
}

/// Runs one diagnostic check at a time on a connection and reports what is happening.
public actor JobRunner {
    private let connection: ConnectionManager
    private var task: Task<Void, Never>?
    private var pending: (id: UUID, continuation: CheckedContinuation<Bool, Never>)?
    /// How many times to ask the user before giving up on "the car didn't answer".
    private let maxPrompts = 2

    public init(connection: ConnectionManager) {
        self.connection = connection
    }

    /// Starts `job`. The stream ends after `.completed` or `.failed`. When `transcript` is set,
    /// every byte exchanged is saved there.
    public func run(_ job: DiagnosticJob, transcript: URL? = nil) -> AsyncStream<JobEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: JobEvent.self)
        guard task == nil else {
            continuation.yield(
                .failed(
                    JobFailure(
                        message: ConnectionError.busy.description, reconnectRequired: false,
                        cancelled: false, transcript: nil)))
            continuation.finish()
            return stream
        }
        let task = Task {
            await self.execute(job, transcript: transcript) { continuation.yield($0) }
            continuation.finish()
            self.clearTask()
        }
        self.task = task
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// The user did what `.needsUser(id:)` asked.
    public func confirm(_ id: UUID) {
        guard let pending, pending.id == id else { return }
        self.pending = nil
        pending.continuation.resume(returning: true)
    }

    /// Stops the running check. If it is waiting for the user, nothing is in flight and the
    /// adapter stays usable; if a command is mid-exchange, the connection needs a reconnect.
    public func cancel() {
        task?.cancel()
        resolvePending(false)
    }

    private func clearTask() { task = nil }

    private func resolvePending(_ value: Bool) {
        guard let pending else { return }
        self.pending = nil
        pending.continuation.resume(returning: value)
    }

    private func execute(
        _ job: DiagnosticJob, transcript: URL?, emit: @escaping @Sendable (JobEvent) -> Void
    ) async {
        emit(.started(job))
        do {
            try await connection.prepare(for: job)
            if let transcript { try await connection.beginRecording(to: transcript) }
            let payload = try await perform(job, emit: emit)
            let reference = await finishRecording(emit: emit)
            emit(
                .completed(
                    JobResult(job: job, payload: payload, source: .live, transcript: reference)))
        } catch {
            let reference = await finishRecording(emit: emit)
            let state = await connection.state
            var reconnect = false
            if case .reconnectRequired = state { reconnect = true }
            emit(
                .failed(
                    JobFailure(
                        message: error.readable, reconnectRequired: reconnect,
                        cancelled: error is CancellationError, transcript: reference)))
        }
    }

    private func finishRecording(emit: @Sendable (JobEvent) -> Void) async -> TranscriptReference? {
        do {
            return try await connection.endRecording()
        } catch {
            emit(.warning("The transcript for this check could not be saved: \(error.readable)"))
            return nil
        }
    }

    private func perform(
        _ job: DiagnosticJob, emit: @escaping @Sendable (JobEvent) -> Void
    ) async throws -> JobPayload {
        switch job {
        case .adapterCheck:
            emit(.step("Asking the adapter who it is"))
            let facts = try await connection.withSession { session in
                let firmware = try await session.identifySTN()
                var hardware: String?
                if firmware != nil { hardware = try await session.send("STDI") }
                return (firmware, hardware, try await session.voltage())
            }
            await connection.update(firmware: facts.0, hardware: facts.1, voltage: facts.2)
            guard let status = await connection.state.status else {
                throw ConnectionError.notConnected
            }
            return .adapter(status)

        case .vehicleInfo:
            let reports = try await askingForIgnition(emit: emit) {
                try await self.connection.withSession { session in
                    try await GenericOBDWorkflow.info(on: session) { emit(Self.describe($0)) }
                }
            }
            return .vehicleInfo(reports.map(ECUIdentity.init))

        case .genericScan:
            let reports = try await askingForIgnition(emit: emit) {
                try await self.connection.withSession { session in
                    try await GenericOBDWorkflow.scan(on: session) { emit(Self.describe($0)) }
                }
            }
            return .genericScan(reports.map(ECUScan.init))

        case .moduleDTCs(let target):
            emit(.step(String(format: "Reading trouble codes from module %03X", target.request)))
            let (voltage, response) = try await connection.withSession { session in
                let voltage = try await session.voltage()
                for command in target.setupCommands {
                    let reply = try await session.send(command)
                    guard reply == "OK" else {
                        throw ELM327Error.unexpectedResponse(command: command, response: reply)
                    }
                }
                try await session.configureDiagnosticHeaders(
                    requestHeader: target.request, responseHeader: target.response)
                let response = try await session.readUDSDTC(
                    responseHeader: target.response, statusMask: target.statusMask)
                return (voltage, response)
            }
            await connection.update(voltage: voltage)
            return .moduleDTCs(ModuleDTCs(target: target, response: response))
        }
    }

    /// Runs `read`; when no ECU answers at all, asks the user to switch the ignition on and
    /// tries again. Gives up after `maxPrompts` rather than looping.
    private func askingForIgnition<T: Sendable>(
        emit: @escaping @Sendable (JobEvent) -> Void, _ read: @Sendable () async throws -> T
    ) async throws -> T {
        var prompts = 0
        while true {
            do {
                return try await read()
            } catch GenericOBDWorkflow.Failure.noVehicleResponse where prompts < maxPrompts {
                prompts += 1
                guard await ask(.turnIgnitionOn, emit: emit) else { throw CancellationError() }
            }
        }
    }

    private func ask(_ action: UserAction, emit: @Sendable (JobEvent) -> Void) async -> Bool {
        let id = UUID()
        emit(.needsUser(id: id, action: action))
        let confirmed = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    pending = (id, continuation)
                }
            }
        } onCancel: {
            Task { await self.resolvePending(false) }
        }
        if confirmed { emit(.userConfirmed(id: id)) }
        return confirmed
    }

    private static func describe(_ event: GenericOBDWorkflow.Event) -> JobEvent {
        switch event {
        case .requesting(let request): return .step("Requesting \(request.hex)")
        case .noResponse(let request): return .warning("No answer to \(request.hex)")
        }
    }
}
