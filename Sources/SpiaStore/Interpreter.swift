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
                    model: configuration.settings.model(for: providerID))
                interpretations.lastError = nil
            } catch {
                interpretations.lastError = "Code explanation failed: \(error.readable)."
            }
        }
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
