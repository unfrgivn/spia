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
        let providerID = configuration.settings.defaultProvider
        if providerID.isCloud && interpretations.consent == nil {
            return
        }
        if let reason = configuration.unavailableReason(providerID) {
            interpretations.lastError = reason
            return
        }
        let briefing = garage.briefing(for: vehicle, adapter: adapter)
        for item in work {
            guard !interpretations.inFlight.contains(item.target) else { continue }
            interpretations.begin(item.target)
            defer { interpretations.end(item.target) }
            do {
                let provider = try configuration.settings.provider(
                    providerID, keys: configuration.keys)
                let request = InterpretationRequest.make(
                    briefing: briefing,
                    module: moduleFacts(for: item, vehicle: vehicle),
                    codes: codeInputs(for: item),
                    nameModule: item.needsName,
                    provider: providerID,
                    sharing: SharingPolicy(includeVIN: configuration.settings.shareVIN))
                var call: ToolCall?
                for try await event in provider.respond(to: request) {
                    if case .toolCall(let toolCall) = event,
                        toolCall.name == InterpretationTool.name
                    {
                        call = toolCall
                    }
                }
                guard let call else {
                    throw InterpreterError.noStructuredAnswer
                }
                let result = try InterpretationTool.parse(call)
                interpretations.store(
                    result, target: item.target, provider: providerID,
                    model: configuration.settings.model(for: providerID),
                    module: item.needsName ? result.module : nil)
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
        let carBriefing = garage.briefing(for: vehicle, adapter: adapter)
        let scopes: [(ReviewScope, ReviewRequest.Scope, String)] =
            [
                (.car, .car, carBriefing.problem)
            ]
            + vehicle.sessions.filter { $0.status == .open }.map { session in
                (
                    .problem(session.id), .problem(title: session.title, text: session.problem),
                    session.problem
                )
            }
        let providerID = configuration.settings.defaultProvider
        if providerID.isCloud && interpretations.consent == nil { return }
        if let reason = configuration.unavailableReason(providerID) {
            interpretations.lastError = reason
            return
        }
        for (scope, requestScope, problem) in scopes {
            guard !interpretations.reviewInFlight.contains(scope) else { continue }
            let existing = interpretations.review(for: scope)
            let answered =
                existing?.questions.compactMap { question in
                    question.answer.map { (question: question.text, answer: $0) }
                } ?? []
            let inputs = ReviewInputs.hash(
                board: vehicle.board(), problem: problem, answers: answered)
            guard existing?.inputs != inputs else { continue }
            interpretations.beginReview(scope)
            defer { interpretations.endReview(scope) }
            do {
                let provider = try configuration.settings.provider(
                    providerID, keys: configuration.keys)
                let request = ReviewRequest.make(
                    briefing: carBriefing, scope: requestScope, answered: answered,
                    codes: reviewCodes(for: vehicle.board()),
                    unread: unreadParts(for: vehicle.board()),
                    provider: providerID,
                    sharing: SharingPolicy(includeVIN: configuration.settings.shareVIN))
                var call: ToolCall?
                for try await event in provider.respond(to: request) {
                    if case .toolCall(let toolCall) = event, toolCall.name == ReviewTool.name {
                        call = toolCall
                    }
                }
                guard let call else { throw InterpreterError.noStructuredAnswer }
                let result = try ReviewTool.parse(call, modules: carBriefing.modules.map(\.label))
                interpretations.storeReview(
                    result, scope: scope, inputs: inputs, provider: providerID,
                    model: configuration.settings.model(for: providerID),
                    modules: vehicle.assistantModules)
                interpretations.lastError = nil
            } catch {
                interpretations.lastError = "Review failed: \(error.readable)."
            }
        }
    }

    private func reviewCodes(for board: SessionBoard) -> [(printed: String, name: String?)] {
        board.rows.flatMap { row in
            row.printedCodes.map { code in
                let name = catalogName(for: code)
                return (printed: code, name: name)
            }
        }
    }

    private func catalogName(for printed: String) -> String? {
        let base = printed.split(separator: "-", maxSplits: 1).first.map(String.init) ?? printed
        guard let code = CodeName(base) else { return nil }
        return CodeCatalog.bundledCatalog?.entry(for: code)?.title
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
            return InterpretationCodeInput(code: printed, catalogName: name)
        }
    }
}

private enum InterpreterError: Error, CustomStringConvertible {
    case noStructuredAnswer
    var description: String { "the provider returned no structured interpretation" }
}
