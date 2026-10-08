import Foundation
import Observation
import SpiaAssist
import SpiaKit

/// Explains newly observed codes once for each vehicle and module.
@MainActor @Observable
public final class Interpreter {
    private let configuration: AssistantConfiguration
    private let garage: Garage
    private var caches: [UUID: VehicleInterpretations] = [:]

    public init(configuration: AssistantConfiguration, garage: Garage) {
        self.configuration = configuration
        self.garage = garage
    }

    public func interpretations(for vehicle: Vehicle) -> VehicleInterpretations {
        if let existing = caches[vehicle.id] {
            return existing
        }
        let cache = VehicleInterpretations(vehicleID: vehicle.id, files: garage.files)
        caches[vehicle.id] = cache
        return cache
    }

    public func catchUp(_ vehicle: Vehicle, adapter: AdapterStatus?) async {
        let interpretations = interpretations(for: vehicle)
        let plan = InterpretationPlan.missing(
            board: vehicle.board(), stored: interpretations.codes, modules: vehicle.orderedModules)
        let work = plan.filter { !interpretations.inFlight.contains($0.target) }
        guard !work.isEmpty else { return }
        guard !configuration.settings.automaticWorkPaused else { return }
        let providerID = configuration.settings.defaultProvider
        if providerID.isCloud && interpretations.consent == nil {
            return
        }
        if let reason = configuration.unavailableReason(providerID) {
            interpretations.lastError = reason
            return
        }
        let briefing = garage.briefing(for: vehicle, adapter: adapter)
        for batch in InterpretationPlan.batches(work, size: 8) {
            for item in batch { interpretations.begin(item.target) }
            defer { batch.forEach { interpretations.end($0.target) } }
            do {
                let provider = try configuration.settings.backgroundProvider(
                    providerID, keys: configuration.keys)
                let model = configuration.settings.backgroundModel(for: providerID)
                var usage: TokenUsage?
                defer {
                    if let usage {
                        interpretations.recordUsage(
                            usage, kind: .interpretation, provider: providerID, model: model,
                            modules: batch.count)
                    }
                }
                let request = InterpretationRequest.make(
                    briefing: briefing,
                    modules: batch.map {
                        InterpretationModuleInput(
                            module: moduleFacts(for: $0, vehicle: vehicle),
                            codes: codeInputs(for: $0),
                            nameModule: $0.needsName)
                    },
                    provider: providerID,
                    sharing: SharingPolicy(includeVIN: configuration.settings.shareVIN))
                var call: ToolCall?
                for try await event in provider.respond(to: request) {
                    switch event {
                    case .usage(let value): usage = value
                    case .toolCall(let toolCall) where toolCall.name == InterpretationTool.name:
                        call = toolCall
                    default: break
                    }
                }
                guard let call else {
                    throw InterpreterError.noStructuredAnswer
                }
                let labels = batch.map(\.label)
                let result = try InterpretationTool.parse(call, modules: labels)
                for item in batch {
                    let codes = result.codes.filter {
                        $0.module?.caseInsensitiveCompare(item.label) == .orderedSame
                            || ($0.module == nil && item.target == nil)
                    }
                    let module = item.needsName && batch.count == 1 ? result.module : nil
                    interpretations.store(
                        InterpretationResult(codes: codes, module: module), target: item.target,
                        provider: providerID,
                        model: model,
                        module: item.needsName ? module : nil)
                }
                interpretations.lastError = nil
            } catch {
                interpretations.lastError = "Code explanation failed: \(error.readable)."
            }
        }
    }

    public func refresh(_ vehicle: Vehicle, adapter: AdapterStatus?) async {
        await catchUp(vehicle, adapter: adapter)
        await review(vehicle, adapter: adapter)
    }

    public func review(_ vehicle: Vehicle, adapter: AdapterStatus?) async {
        let interpretations = interpretations(for: vehicle)
        guard !configuration.settings.automaticWorkPaused else { return }
        let carBriefing = garage.briefing(for: vehicle, adapter: adapter)
        let scopes: [(ReviewScope, DiagnosticSession?)] =
            [(.car, nil)]
            + vehicle.sessions.filter { $0.status == .open && Self.hasSymptoms($0) }.map {
                (.problem($0.id), $0)
            }
        let providerID = configuration.settings.defaultProvider
        if providerID.isCloud && interpretations.consent == nil { return }
        if let reason = configuration.unavailableReason(providerID) {
            interpretations.lastError = reason
            return
        }
        for (scope, session) in scopes {
            guard !interpretations.reviewInFlight.contains(scope) else { continue }
            let existing = interpretations.review(for: scope)
            let answered =
                existing?.questions.compactMap { question in
                    question.answer.map { (question: question.text, answer: $0) }
                } ?? []
            let notes = session?.notes.map(\.body) ?? []
            let findings =
                session?.findings.map {
                    (title: $0.title, text: $0.body, evidence: garage.evidenceKey($0))
                } ?? []
            let problem = session?.problem ?? carBriefing.problem
            let inputs = ReviewInputs.hash(
                board: vehicle.board(), problem: problem, answers: answered, notes: notes,
                findings: findings)
            let unchanged =
                session == nil
                ? existing?.inputs == inputs
                : existing?.kind == .diagnosis && existing?.inputs == inputs
            guard !unchanged else { continue }
            interpretations.beginReview(scope)
            defer { interpretations.endReview(scope) }
            do {
                let provider = try configuration.settings.backgroundProvider(
                    providerID, keys: configuration.keys)
                let model = configuration.settings.backgroundModel(for: providerID)
                var usage: TokenUsage?
                defer {
                    if let usage {
                        interpretations.recordUsage(
                            usage, kind: session == nil ? .review : .diagnosis,
                            provider: providerID, model: model, modules: 0,
                            scope: scope)
                    }
                }
                let request: AssistantRequest
                let toolName: String
                if let session {
                    request = DiagnosisRequest.make(
                        briefing: garage.briefing(for: session, adapter: adapter),
                        title: session.title,
                        text: session.problem, notes: notes, answered: answered,
                        findings: session.findings.map { garage.finding($0) },
                        codes: reviewCodes(for: vehicle.board()),
                        unread: unreadParts(for: vehicle.board()),
                        provider: providerID,
                        sharing: SharingPolicy(includeVIN: configuration.settings.shareVIN))
                    toolName = DiagnosisTool.name
                } else {
                    request = ReviewRequest.make(
                        briefing: carBriefing, scope: .car, answered: answered,
                        codes: reviewCodes(for: vehicle.board()),
                        unread: unreadParts(for: vehicle.board()),
                        provider: providerID,
                        sharing: SharingPolicy(includeVIN: configuration.settings.shareVIN))
                    toolName = ReviewTool.name
                }
                let response = try await respond(request, provider: provider)
                usage = response.usage
                let call = response.call
                guard let call else { throw InterpreterError.noStructuredAnswer }
                guard call.name == toolName else { throw InterpreterError.noStructuredAnswer }
                if session != nil {
                    let result = try DiagnosisTool.parse(
                        call, modules: carBriefing.modules.map(\.label))
                    interpretations.storeDiagnosis(
                        result, scope: scope, inputs: inputs, provider: providerID, model: model,
                        modules: vehicle.assistantModules)
                } else {
                    let result = try ReviewTool.parse(
                        call, modules: carBriefing.modules.map(\.label))
                    interpretations.storeReview(
                        result, scope: scope, inputs: inputs, provider: providerID, model: model,
                        modules: vehicle.assistantModules)
                }
                interpretations.lastError = nil
            } catch {
                interpretations.lastError =
                    "\(session == nil ? "Review" : "Diagnosis") failed: \(error.readable)."
            }
        }
    }

    public static func reviewScopes(for vehicle: Vehicle) -> [ReviewScope] {
        [.car]
            + vehicle.sessions.filter { $0.status == .open && hasSymptoms($0) }.map {
                .problem($0.id)
            }
    }

    private static func hasSymptoms(_ session: DiagnosticSession) -> Bool {
        !session.problem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !session.notes.isEmpty
    }

    private func reviewCodes(for board: SessionBoard) -> [(
        printed: String, name: String?, failureType: String?
    )] {
        board.rows.flatMap { row in
            row.printedCodes.enumerated().map { index, code in
                let codeName = row.names[index]
                let name = catalogName(for: code)
                return (
                    printed: code,
                    name: name,
                    failureType: Self.failureTypeLabel(for: codeName)
                )
            }
        }
    }

    private func catalogName(for printed: String) -> String? {
        let base = printed.split(separator: "-", maxSplits: 1).first.map(String.init) ?? printed
        guard let code = CodeName(base) else { return nil }
        return CodeCatalog.bundledCatalog?.entry(for: code)?.title
    }

    private static func failureTypeLabel(for name: CodeName?) -> String? {
        guard let name, let byte = name.failureType else { return nil }
        if let label = name.failureTypeLabel, name.failureTypeMeaning != nil {
            return label
        }
        return "\(String(format: "%02X", byte)), not described by Spia"
    }

    private func unreadParts(for board: SessionBoard) -> [String] {
        board.rows.filter { $0.status == .notRead }.map { row in
            switch row.subject {
            case .engine: return "Engine and transmission"
            case .module: return row.name
            case .battery: return "Battery"
            }
        }
    }

    public func answer(
        _ vehicle: Vehicle, questionID: UUID, text: String, adapter: AdapterStatus?
    ) async {
        interpretations(for: vehicle).answer(questionID: questionID, text: text)
        await review(vehicle, adapter: adapter)
    }

    public func forget(problem id: UUID, in vehicle: Vehicle) {
        interpretations(for: vehicle).removeReview(for: .problem(id))
    }

    /// Drops the vehicle's cache once the vehicle is gone; its file goes with the vehicle's folder.
    public func forget(vehicle id: UUID) {
        caches.removeValue(forKey: id)
    }

    private func respond(_ request: AssistantRequest, provider: any AssistantProvider) async throws
        -> (call: ToolCall?, usage: TokenUsage?)
    {
        var call: ToolCall?
        var usage: TokenUsage?
        for try await event in provider.respond(to: request) {
            switch event {
            case .usage(let value): usage = value
            case .toolCall(let value): call = value
            default: break
            }
        }
        return (call, usage)
    }

    private func moduleFacts(
        for work: InterpretationPlan.Work, vehicle: Vehicle
    ) -> SessionBriefing.ModuleFacts? {
        guard let target = work.target else { return nil }
        guard let preset = vehicle.orderedModules.first(where: { $0.target == target }) else {
            return nil
        }
        return .init(
            label: preset.label, bus: target.bus.rawValue,
            request: String(format: "%03X", target.request),
            reply: String(format: "%03X", target.response), labelConfirmed: preset.confirmed)
    }

    private func codeInputs(for work: InterpretationPlan.Work) -> [InterpretationCodeInput] {
        return work.codes.map { raw in
            let name = CodeName(raw).flatMap { CodeCatalog.bundledCatalog?.entry(for: $0)?.title }
            let printed = CodeName(raw)?.printed ?? raw
            let failureType: String?
            if let name = CodeName(raw), let byte = name.failureType {
                failureType =
                    Self.failureTypeLabel(for: name)
                    ?? "\(String(format: "%02X", byte)), not described by Spia"
            } else {
                failureType = nil
            }
            return InterpretationCodeInput(
                code: printed, catalogName: name, failureType: failureType)
        }
    }
}

private enum InterpreterError: Error, CustomStringConvertible {
    case noStructuredAnswer
    var description: String { "the provider returned no structured interpretation" }
}
