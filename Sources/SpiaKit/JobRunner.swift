import Foundation
import OBDCore

/// Something only the person at the car can do.
public enum UserAction: String, Codable, Sendable {
    case turnIgnitionOn
    case turnIgnitionOnForVIN

    public var title: String {
        switch self {
        case .turnIgnitionOn: return "Turn the ignition on"
        case .turnIgnitionOnForVIN: return "Turn the ignition fully on"
        }
    }

    public var instructions: String {
        switch self {
        case .turnIgnitionOn:
            return "The car didn't answer. Put the ignition in RUN so the dash lights up. "
                + "On push-button cars, press START without the brake pedal. The engine can stay off."
        case .turnIgnitionOnForVIN:
            return
                "Only part of the car answered and nothing gave the VIN. Switch the ignition fully on "
                + "with the engine off, so every dash warning light comes on. On a push-button car, "
                + "press START without the brake until they do."
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
    private enum SurveyAttempt: Sendable {
        case module(SurveyModule)
        case unanswered
    }

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
            let infoRead: @Sendable () async throws -> [ECUInfoReport] = {
                try await self.connection.withSession { session in
                    try await GenericOBDWorkflow.info(on: session) { emit(Self.describe($0)) }
                }
            }
            let first = try await askingForIgnition(action: .turnIgnitionOn, emit: emit) {
                try await infoRead()
            }
            let reports: [ECUInfoReport]
            if !first.isEmpty,
                !first.contains(where: {
                    if case .positive = $0.vin { return true }
                    return false
                })
            {
                reports = try await askingForIgnition(
                    initial: first, action: .turnIgnitionOnForVIN, emit: emit,
                    shouldRetry: { reports in
                        !reports.contains {
                            if case .positive = $0.vin { return true }
                            return false
                        }
                    }, read: infoRead)
                if !reports.contains(where: {
                    if case .positive = $0.vin { return true }
                    return false
                }) {
                    emit(.warning("No computer gave the VIN."))
                }
            } else {
                reports = first
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

        case .survey(let plan):
            return .survey(try await performSurvey(plan, emit: emit))
        }
    }

    private func performSurvey(
        _ plan: SurveyPlan, emit: @escaping @Sendable (JobEvent) -> Void
    ) async throws -> SurveyReport {
        emit(.step("Reading the car's voltage"))
        let voltage = try await connection.withSession { session in try await session.voltage() }
        await connection.update(voltage: voltage)

        let infoRead: @Sendable () async throws -> [ECUIdentity] = {
            try await self.connection.withSession { session in
                try await GenericOBDWorkflow.info(on: session) { emit(Self.describe($0)) }
            }.map(ECUIdentity.init)
        }
        let firstInfo: [ECUIdentity]
        do {
            firstInfo = try await askingForIgnition(action: .turnIgnitionOn, emit: emit) {
                try await infoRead()
            }
        } catch GenericOBDWorkflow.Failure.noVehicleResponse {
            emit(.warning("The engine computers didn't answer."))
            firstInfo = []
        }
        let vehicleInfo: [ECUIdentity]
        if plan.requiresVIN, !firstInfo.isEmpty, !firstInfo.contains(where: { $0.vin.value != nil })
        {
            vehicleInfo = try await askingForIgnition(
                initial: firstInfo, action: .turnIgnitionOnForVIN, emit: emit,
                shouldRetry: { !$0.contains(where: { $0.vin.value != nil }) }, read: infoRead)
            if !vehicleInfo.contains(where: { $0.vin.value != nil }) {
                emit(.warning("No computer gave the VIN."))
            }
        } else {
            vehicleInfo = firstInfo
        }

        var modules: [SurveyModule] = []
        var unanswered: [SurveyCandidate] = []
        var notProbed: [SurveyCandidate] = []
        var stop: SurveyStop?

        for (index, candidate) in plan.candidates.enumerated() {
            emit(.step("Looking for modules: \(index + 1) of \(plan.candidates.count)"))
            do {
                let attempt = try await connection.withSession { session in
                    try await self.performSurveyCandidate(
                        candidate, plan: plan, session: session, emit: emit)
                }
                switch attempt {
                case .unanswered:
                    unanswered.append(candidate)
                case .module(let module):
                    modules.append(module)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if ConnectionManager.desynchronizes(error) { throw error }
                stop = SurveyStop(candidate: candidate, reason: error.readable)
                notProbed = Array(plan.candidates.dropFirst(index + 1))
                break
            }
        }

        if stop == nil {
            let silentTargets = Set(unanswered.map(\.target))
            let secondLook = plan.expected.filter { silentTargets.contains($0) }
            for (index, target) in secondLook.enumerated() {
                guard let candidate = plan.candidates.first(where: { $0.target == target }) else {
                    continue
                }
                emit(.step("Looking again: \(index + 1) of \(secondLook.count)"))
                do {
                    let attempt = try await connection.withSession { session in
                        try await self.performSurveyCandidate(
                            candidate, plan: plan, session: session, emit: emit)
                    }
                    switch attempt {
                    case .unanswered:
                        break
                    case .module(let module):
                        modules.append(module)
                        unanswered.removeAll { $0.target == target }
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    if ConnectionManager.desynchronizes(error) { throw error }
                    stop = SurveyStop(candidate: candidate, reason: error.readable)
                    break
                }
            }
        }

        let order = Dictionary(
            uniqueKeysWithValues: plan.candidates.enumerated().map { ($1.target, $0) })
        modules.sort { (order[$0.candidate.target] ?? .max) < (order[$1.candidate.target] ?? .max) }

        return SurveyReport(
            plan: plan, voltage: voltage, vehicleInfo: vehicleInfo, modules: modules,
            unanswered: unanswered, notProbed: notProbed, stop: stop)
    }

    private func performSurveyCandidate(
        _ candidate: SurveyCandidate, plan: SurveyPlan, session: ELM327Session,
        emit: @escaping @Sendable (JobEvent) -> Void
    ) async throws -> SurveyAttempt {
        let commands = plan.commands(for: candidate)
        for command in commands.setup {
            try await sendSurveyCommand(command, session: session)
        }
        try await session.configureDiagnosticHeaders(
            requestHeader: candidate.target.request, responseHeader: candidate.target.response)

        guard
            let reply = try await session.testerPresent(responseHeader: candidate.target.response),
            let presence = SurveyPresence(reply)
        else {
            return .unanswered
        }

        let label = candidateLabel(candidate)
        emit(.step("\(label) answered; asking what it is"))
        try await sendSurveyCommand(commands.readTimeout, session: session)
        // The reads keep the session's own deadlines for the adapter's prompt; the plan's read
        // timeout is the adapter's per-reply wait (`ATST`), already set above.
        var identification: [SurveyIdentification] = []
        identify: for did in plan.identification {
            do {
                let reading = try await session.readDataByIdentifier(
                    did, responseHeader: candidate.target.response)
                switch reading {
                case .value(let bytes):
                    identification.append(SurveyIdentification(did: did, result: .value(bytes)))
                case .refused(let code):
                    identification.append(
                        SurveyIdentification(did: did, result: .refused(code.byte)))
                    // Unsupported service, or not in this session: every other DID would be
                    // refused the same way.
                    if [0x11, 0x7E, 0x7F].contains(code.byte) { break identify }
                }
            } catch UDSReadError.adapterStatus(.noData) {
                identification.append(SurveyIdentification(did: did, result: .noAnswer))
            } catch let error as IdentificationDecodeError {
                identification.append(
                    SurveyIdentification(did: did, result: .unreadable(error.readable)))
            } catch UDSReadError.pendingWithoutFinalResponse {
                identification.append(
                    SurveyIdentification(
                        did: did,
                        result: .unreadable(UDSReadError.pendingWithoutFinalResponse.readable)))
            }
        }

        let codes: SurveyCodes
        do {
            let response = try await session.readUDSDTC(
                responseHeader: candidate.target.response, statusMask: candidate.target.statusMask)
            codes = .outcome(ModuleDTCs(target: candidate.target, response: response).outcome)
        } catch UDSReadError.adapterStatus(.noData) {
            codes = .noAnswer
        } catch let error as UDSDTCDecodeError {
            codes = .unreadable(error.readable)
        } catch UDSReadError.pendingWithoutFinalResponse {
            codes = .unreadable(UDSReadError.pendingWithoutFinalResponse.readable)
        }
        return .module(
            SurveyModule(
                candidate: candidate, presence: presence, identification: identification,
                codes: codes))
    }

    private func sendSurveyCommand(_ command: String, session: ELM327Session) async throws {
        let reply = try await session.send(command)
        guard reply.trimmingCharacters(in: .whitespacesAndNewlines) == "OK" else {
            throw ELM327Error.unexpectedResponse(command: command, response: reply)
        }
    }

    private func candidateLabel(_ candidate: SurveyCandidate) -> String {
        if case .catalog(let label, _, _) = candidate.origin { return label }
        return String(format: "Module %03X", candidate.target.request)
    }

    /// Runs `read`; when no ECU answers at all, asks the user to switch the ignition on and
    /// tries again. Gives up after `maxPrompts` rather than looping.
    private func askingForIgnition<T: Sendable>(
        action: UserAction = .turnIgnitionOn,
        emit: @escaping @Sendable (JobEvent) -> Void,
        shouldRetry: @escaping @Sendable (T) -> Bool = { _ in false },
        _ read: @Sendable () async throws -> T
    ) async throws -> T {
        var prompts = 0
        while true {
            do {
                let value = try await read()
                guard shouldRetry(value), prompts < maxPrompts else { return value }
                prompts += 1
                guard await ask(action, emit: emit) else { throw CancellationError() }
            } catch GenericOBDWorkflow.Failure.noVehicleResponse where prompts < maxPrompts {
                prompts += 1
                guard await ask(action, emit: emit) else { throw CancellationError() }
            }
        }
    }

    private func askingForIgnition<T: Sendable>(
        initial: T, action: UserAction, emit: @escaping @Sendable (JobEvent) -> Void,
        shouldRetry: @escaping @Sendable (T) -> Bool,
        read: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        var value = initial
        var prompts = 0
        while shouldRetry(value), prompts < maxPrompts {
            prompts += 1
            guard await ask(action, emit: emit) else { throw CancellationError() }
            value = try await read()
        }
        return value
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
