import Foundation
import OBDCore

/// Something only the person at the car can do.
public enum UserAction: String, Codable, Sendable {
    case turnIgnitionOn
    case turnIgnitionOnForVIN
    case confirmEngineOff

    public var title: String {
        switch self {
        case .turnIgnitionOn: return "Turn the ignition on"
        case .turnIgnitionOnForVIN: return "Turn the ignition fully on"
        case .confirmEngineOff: return "Confirm the engine is off"
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
        case .confirmEngineOff:
            return
                "The engine speed could not be read. Confirm that the engine is off and the ignition stays on."
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

    private struct SearchRun: Sendable {
        let outcome: SearchOutcome
        let modules: [SurveyModule]
    }

    /// Holds the search's listen across the monitor's callbacks.
    private actor SearchListenState {
        var listen: SearchListen

        init(maxFrames: Int) {
            listen = SearchListen(maxFrames: maxFrames)
        }

        func receive(_ event: MonitorEvent) -> Bool {
            listen.receive(event)
        }
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
            let ecus = try await askingForIgnition(emit: emit, incomplete: Self.missingVIN) {
                try await self.connection.withSession { session in
                    try await GenericOBDWorkflow.info(on: session) { emit(Self.describe($0)) }
                }.map(ECUIdentity.init)
            }
            if Self.missingVIN(ecus) != nil { emit(.warning("No computer gave the VIN.")) }
            return .vehicleInfo(ecus)

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

        let vehicleInfo: [ECUIdentity]
        do {
            vehicleInfo = try await askingForIgnition(
                emit: emit, incomplete: { plan.requiresVIN ? Self.missingVIN($0) : nil }
            ) {
                try await self.connection.withSession { session in
                    try await GenericOBDWorkflow.info(on: session) { emit(Self.describe($0)) }
                }.map(ECUIdentity.init)
            }
        } catch GenericOBDWorkflow.Failure.noVehicleResponse {
            emit(.warning("The engine computers didn't answer."))
            vehicleInfo = []
        }
        if plan.requiresVIN, Self.missingVIN(vehicleInfo) != nil {
            emit(.warning("No computer gave the VIN."))
        }

        // The search waits for an engine known to be off. A car whose engine computers didn't
        // answer at all can't say, and has nothing to search on anyway.
        var searchOutcome: SearchOutcome?
        if plan.search != nil {
            let engineOff: Bool?
            if vehicleInfo.isEmpty {
                engineOff = nil
                searchOutcome = Self.skippedSearch(
                    engineRunning: nil,
                    "No engine computer answered, so Spia didn't search.")
            } else {
                engineOff = try await engineIsOff(emit: emit)
            }
            if engineOff == false {
                let reason =
                    "The engine is running. Turn it off, leaving the ignition on, to search."
                searchOutcome = Self.skippedSearch(engineRunning: true, reason)
                emit(.warning(reason))
            } else if engineOff == nil, searchOutcome == nil {
                searchOutcome = Self.skippedSearch(
                    engineRunning: nil,
                    "The search was skipped because the engine wasn't confirmed off.")
            }
        }

        let detectedProtocol: ELM327Protocol?
        if plan.detectsProtocol, !vehicleInfo.isEmpty {
            let response = try await connection.withSession { session in
                try await session.protocolNumber()
            }
            detectedProtocol = ELM327Protocol.parseDetection(response)
        } else {
            detectedProtocol = nil
        }
        if let detectedProtocol, detectedProtocol.surveyUnsupportedNote != nil {
            return SurveyReport(
                plan: plan, voltage: voltage, vehicleInfo: vehicleInfo, modules: [],
                unanswered: [], notProbed: plan.candidates, stop: nil,
                detectedProtocol: detectedProtocol, search: searchOutcome)
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

        if stop == nil, searchOutcome == nil, let search = plan.search,
            Self.searchProtocol(detected: detectedProtocol)
        {
            let run = try await performThoroughSearch(
                search, plan: plan, existingCandidates: plan.candidates, emit: emit)
            searchOutcome = run.outcome
            modules.append(contentsOf: run.modules)
        }

        let order = Dictionary(
            uniqueKeysWithValues: plan.candidates.enumerated().map { ($1.target, $0) })
        modules.sort {
            let left = order[$0.candidate.target] ?? .max
            let right = order[$1.candidate.target] ?? .max
            if left != right { return left < right }
            if $0.candidate.target.request != $1.candidate.target.request {
                return $0.candidate.target.request < $1.candidate.target.request
            }
            return $0.candidate.target.response < $1.candidate.target.response
        }

        return SurveyReport(
            plan: plan, voltage: voltage, vehicleInfo: vehicleInfo, modules: modules,
            unanswered: unanswered, notProbed: notProbed, stop: stop,
            detectedProtocol: detectedProtocol, search: searchOutcome)
    }

    private static func searchProtocol(detected: ELM327Protocol?) -> Bool {
        detected == nil || detected == .can11bit500k
    }

    private static func skippedSearch(engineRunning: Bool?, _ reason: String) -> SearchOutcome {
        SearchOutcome(
            heardIDs: [], sweptCount: 0, confirmed: [], unconfirmed: [],
            engineRunning: engineRunning, stopReason: reason)
    }

    /// Whether the engine is off: RPM reads zero, or, when the engine computer doesn't say (no
    /// answer, or any adapter reply that leaves the line in step), the owner confirms it. Nil
    /// when the owner declines.
    private func engineIsOff(
        emit: @escaping @Sendable (JobEvent) -> Void
    ) async throws -> Bool? {
        let rpm: Double?
        do {
            rpm = try await connection.withSession { session in
                let responses = try await session.request(OBDRequest(raw: [0x01, 0x0C]))
                return responses.compactMap { response -> Double? in
                    guard
                        case .currentData(pid: 0x0C, value: .rpm(let value)) =
                            ServiceResponse.decode(response.payload)
                    else { return nil }
                    return value
                }.first
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if ConnectionManager.desynchronizes(error) { throw error }
            rpm = nil
        }
        guard let rpm else { return await ask(.confirmEngineOff, emit: emit) ? true : nil }
        return rpm <= 0
    }

    private func performThoroughSearch(
        _ search: ModuleSearch, plan: SurveyPlan, existingCandidates: [SurveyCandidate],
        emit: @escaping @Sendable (JobEvent) -> Void
    ) async throws -> SearchRun {
        let result = try await connection.withSession { session in
            try await self.listenAndSweep(
                search, session: session, existingCandidates: existingCandidates, emit: emit)
        }
        var modules: [SurveyModule] = []
        for pair in result.confirmed {
            let candidate = SurveyCandidate(target: pair, origin: .discovered)
            emit(.step(String(format: "Found a module at %03X; asking what it is", pair.request)))
            do {
                let attempt = try await connection.withSession { session in
                    try await self.performSurveyCandidate(
                        candidate, plan: plan, session: session, emit: emit)
                }
                if case .module(let module) = attempt { modules.append(module) }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if ConnectionManager.desynchronizes(error) { throw error }
                emit(
                    .warning(
                        String(
                            format: "The module at %03X answered the search but not ", pair.request)
                            + "the reads that followed: \(error.readable)"))
            }
        }
        return SearchRun(
            outcome: SearchOutcome(
                heardIDs: result.heardIDs.sorted(), sweptCount: result.sweptCount,
                confirmed: result.confirmed, unconfirmed: result.unconfirmed,
                engineRunning: false, stopReason: result.stopReason), modules: modules)
    }

    private struct SearchProbeResult: Sendable {
        let heardIDs: Set<UInt32>
        let sweptCount: Int
        let confirmed: [ModuleTarget]
        let unconfirmed: [ModuleTarget]
        let stopReason: String?
    }

    /// Listens through the plan's reply window, sweeps the request range with TesterPresent, and
    /// asks each answering pair again on its exact reply ID. Adapter and bus trouble ends the
    /// search with a reason; only a desynchronized line or cancellation ends the survey.
    private func listenAndSweep(
        _ search: ModuleSearch, session: ELM327Session, existingCandidates: [SurveyCandidate],
        emit: @escaping @Sendable (JobEvent) -> Void
    ) async throws -> SearchProbeResult {
        var heard = Set<UInt32>()
        var swept = 0
        var pairs: [ModuleTarget] = []
        do {
            // `ATCRA` alone drops the last module's exact filter, so the window below applies.
            try await sendSearchCommand("ATCRA", session: session)
            try await configureSearchWindow(search.replyWindow, session: session)
            let state = SearchListenState(maxFrames: search.maxListenFrames)
            try await session.monitor(for: .milliseconds(Int64(search.listenMilliseconds))) {
                _, event in
                await state.receive(event)
            }
            let listen = await state.listen
            heard = listen.heard
            if let reason = listen.reason {
                return SearchProbeResult(
                    heardIDs: heard, sweptCount: 0, confirmed: [], unconfirmed: [],
                    stopReason: reason)
            }
            let requests = search.sweepRequests(candidates: existingCandidates, heardIDs: heard)
            try await sendSearchCommand(search.replyTimeoutCommand, session: session)
            for request in requests {
                try Task.checkCancellation()
                swept += 1
                emit(.step("Searching: \(swept) of \(requests.count)"))
                try await sendSearchCommand(String(format: "ATSH %03X", request), session: session)
                let reply = SearchReply(try await session.send("3E00"))
                if let trouble = reply.trouble {
                    return SearchProbeResult(
                        heardIDs: heard, sweptCount: swept, confirmed: [], unconfirmed: pairs,
                        stopReason:
                            "The adapter reported \(trouble.description), so the search stopped.")
                }
                for response in reply.testerPresentReplies {
                    let pair = try ModuleTarget(
                        bus: .highSpeed, request: request, response: response)
                    if !pairs.contains(pair) { pairs.append(pair) }
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if ConnectionManager.desynchronizes(error) { throw error }
            return SearchProbeResult(
                heardIDs: heard, sweptCount: swept, confirmed: [], unconfirmed: pairs,
                stopReason: "The search stopped: \(error.readable)")
        }

        var confirmed: [ModuleTarget] = []
        var unconfirmed: [ModuleTarget] = []
        for pair in pairs {
            do {
                try await sendSearchCommand(
                    String(format: "ATCRA %03X", pair.response), session: session)
                try await sendSearchCommand(
                    String(format: "ATSH %03X", pair.request), session: session)
                let answered = SearchReply(try await session.send("3E00")).testerPresentReplies
                    .contains(pair.response)
                if answered { confirmed.append(pair) } else { unconfirmed.append(pair) }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if ConnectionManager.desynchronizes(error) { throw error }
                unconfirmed.append(pair)
            }
        }
        return SearchProbeResult(
            heardIDs: heard, sweptCount: swept, confirmed: confirmed, unconfirmed: unconfirmed,
            stopReason: nil)
    }

    private func configureSearchWindow(_ filter: ReceiveFilter, session: ELM327Session) async throws
    {
        switch filter {
        case .expectedReply:
            try await sendSearchCommand("ATCRA", session: session)
        case .window(let mask, let pattern):
            try await sendSearchCommand(String(format: "ATCM %03X", mask), session: session)
            try await sendSearchCommand(String(format: "ATCF %03X", pattern), session: session)
        }
    }

    private func sendSearchCommand(_ command: String, session: ELM327Session) async throws {
        let response = try await session.send(command)
        guard response.trimmingCharacters(in: .whitespacesAndNewlines) == "OK" else {
            throw ELM327Error.unexpectedResponse(command: command, response: response)
        }
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
        if case .saved(let label, _) = candidate.origin { return label }
        return String(format: "Module %03X", candidate.target.request)
    }

    /// Runs `read`, and when the car isn't fully on asks the user to fix the ignition, then reads
    /// again: `.turnIgnitionOn` when no ECU answers at all, or whatever `incomplete` names for an
    /// answer that shows only part of the car is on. Gives up after `maxPrompts` rather than
    /// looping, returning the last answer, or rethrowing when nothing answered.
    private func askingForIgnition<T: Sendable>(
        emit: @escaping @Sendable (JobEvent) -> Void,
        incomplete: @Sendable (T) -> UserAction? = { _ in nil },
        _ read: @Sendable () async throws -> T
    ) async throws -> T {
        var prompts = 0
        while true {
            let action: UserAction
            do {
                let value = try await read()
                guard let needed = incomplete(value), prompts < maxPrompts else { return value }
                action = needed
            } catch GenericOBDWorkflow.Failure.noVehicleResponse where prompts < maxPrompts {
                action = .turnIgnitionOn
            }
            prompts += 1
            guard await ask(action, emit: emit) else { throw CancellationError() }
        }
    }

    /// Computers answered but none gave the VIN, which every car on CAN must with the ignition
    /// fully on: only part of the car is awake.
    private static func missingVIN(_ ecus: [ECUIdentity]) -> UserAction? {
        !ecus.isEmpty && !ecus.contains { $0.vin.value != nil } ? .turnIgnitionOnForVIN : nil
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
