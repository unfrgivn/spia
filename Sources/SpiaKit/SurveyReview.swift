import Foundation

public struct SurveyReview: Sendable, Equatable {
    public enum NameSource: String, Sendable, Equatable {
        case module
        case obd
        case catalog
        case fallback

        public var caption: String {
            switch self {
            case .module, .obd: return "Named itself"
            case .catalog: return "From references, unconfirmed"
            case .fallback: return "No name found"
            }
        }
    }

    public struct Row: Sendable, Equatable, Identifiable {
        public let target: ModuleTarget
        public let proposedName: String
        public let nameSource: NameSource
        public let ownName: String?
        public let confirmed: Bool
        public let codesSummary: String

        public var id: ModuleTarget { target }

        public var caption: String {
            if nameSource == .catalog, let ownName {
                return "Calls itself \(ownName)"
            }
            return nameSource.caption
        }
    }

    public let headline: String
    public let notes: [String]
    public let rows: [Row]
    public let unansweredLabels: [String]

    public init(report: SurveyReport) {
        let choices = report.proposedModules()
        rows = report.modules.enumerated().map { index, module in
            let choice = choices[index]
            let source: NameSource
            switch report.name(of: module)?.source {
            case .module?: source = .module
            case .obd?: source = .obd
            case .catalog?: source = .catalog
            case nil: source = .fallback
            }
            return Row(
                target: choice.target, proposedName: choice.label, nameSource: source,
                ownName: report.ownName(of: module)?.text, confirmed: choice.confirmed,
                codesSummary: Self.codesSummary(module.codes))
        }
        headline =
            report.modules.isEmpty
            ? "No modules answered"
            : "Found \(report.modules.count) module\(report.modules.count == 1 ? "" : "s")"
        var notes: [String] = []
        if report.vehicleInfo.isEmpty { notes.append("The engine computers didn't answer.") }
        if let vehicle = report.plan.vehicle {
            if report.plan.platform == nil {
                notes.append(
                    "Spia has no module list for a \(vehicle.year) \(vehicle.make) \(vehicle.model) yet, so it asked the standard engine addresses only."
                )
            }
        } else {
            notes.append(
                "Spia doesn't know this car's make yet. Add its VIN, then survey again to include the modules known for it."
            )
        }
        if let stop = report.stop {
            let label = Self.label(for: stop.candidate)
            var text =
                "Stopped at \(label) (\(String(format: "%03X", stop.candidate.target.request))): \(stop.reason)."
            if !report.notProbed.isEmpty { text += " \(report.notProbed.count) not asked." }
            notes.append(text)
        }
        if !report.plan.unreachable.isEmpty {
            notes.append(
                "\(report.plan.unreachable.count) known module\(report.plan.unreachable.count == 1 ? " is" : "s are") on the 125k bus, which this adapter can't reach."
            )
        }
        self.notes = notes
        unansweredLabels = report.unanswered.map(Self.label(for:))
    }

    /// The modules to save: the kept rows, named as the owner left them. A name the owner changed
    /// is theirs, so it's confirmed; an untouched one keeps the proposal's. A blank name falls
    /// back to the proposal.
    public func choices(names: [ModuleTarget: String], kept: Set<ModuleTarget>) -> [ModuleChoice] {
        rows.compactMap { row in
            guard kept.contains(row.target) else { return nil }
            let typed = (names[row.target] ?? row.proposedName)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let name = typed.isEmpty ? row.proposedName : typed
            return ModuleChoice(
                target: row.target, label: name,
                confirmed: name == row.proposedName ? row.confirmed : true)
        }
    }

    public static func label(for candidate: SurveyCandidate) -> String {
        if case .catalog(let label, _, _) = candidate.origin { return label }
        return String(format: "Module %03X", candidate.target.request)
    }

    private static func codesSummary(_ codes: SurveyCodes) -> String {
        switch codes {
        case .outcome(.records(_, let records)):
            if records.isEmpty { return "No codes" }
            return "\(records.count) code\(records.count == 1 ? "" : "s")"
        case .outcome(.negative): return "Didn't give its codes"
        case .noAnswer: return "Didn't answer the code request"
        case .unreadable: return "Couldn't read its codes"
        }
    }
}
