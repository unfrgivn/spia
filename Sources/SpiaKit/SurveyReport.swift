import Foundation
import OBDCore

public enum SurveyPresence: Codable, Sendable, Equatable {
    case present
    case refused(UInt8)
    case pending

    /// Nil for a reply that isn't an answer to TesterPresent, which counts as no answer.
    public init?(_ reply: TesterPresentReply) {
        switch reply {
        case .present: self = .present
        case .refused(let code): self = .refused(code.byte)
        case .pending: self = .pending
        case .unrelated: return nil
        }
    }
}

public enum SurveyIdentificationResult: Codable, Sendable, Equatable {
    case value([UInt8])
    case refused(UInt8)
    case noAnswer
    case unreadable(String)
}

public struct SurveyIdentification: Codable, Sendable, Equatable {
    public let did: UInt16
    public let result: SurveyIdentificationResult

    public init(did: UInt16, result: SurveyIdentificationResult) {
        self.did = did
        self.result = result
    }
}

public enum SurveyCodes: Codable, Sendable, Equatable {
    case outcome(ModuleDTCOutcome)
    case noAnswer
    case unreadable(String)
}

public struct SurveyModule: Codable, Sendable, Equatable {
    public let candidate: SurveyCandidate
    public let presence: SurveyPresence
    public let identification: [SurveyIdentification]
    public let codes: SurveyCodes

    public init(
        candidate: SurveyCandidate, presence: SurveyPresence,
        identification: [SurveyIdentification], codes: SurveyCodes
    ) {
        self.candidate = candidate
        self.presence = presence
        self.identification = identification
        self.codes = codes
    }
}

public struct SurveyStop: Codable, Sendable, Equatable {
    public let candidate: SurveyCandidate
    public let reason: String

    public init(candidate: SurveyCandidate, reason: String) {
        self.candidate = candidate
        self.reason = reason
    }
}

public struct SearchOutcome: Codable, Sendable, Equatable {
    public let heardIDs: [UInt32]
    public let sweptCount: Int
    public let confirmed: [ModuleTarget]
    public let unconfirmed: [ModuleTarget]
    public let engineRunning: Bool?
    public let stopReason: String?

    public init(
        heardIDs: [UInt32], sweptCount: Int, confirmed: [ModuleTarget],
        unconfirmed: [ModuleTarget], engineRunning: Bool?, stopReason: String?
    ) {
        self.heardIDs = heardIDs
        self.sweptCount = sweptCount
        self.confirmed = confirmed
        self.unconfirmed = unconfirmed
        self.engineRunning = engineRunning
        self.stopReason = stopReason
    }
}

public struct SurveyName: Codable, Sendable, Equatable {
    public enum Source: String, Codable, Sendable {
        case module
        case obd
        case catalog
        case saved
    }

    public let text: String
    public let source: Source

    public init(text: String, source: Source) {
        self.text = text
        self.source = source
    }
}

public struct ModuleChoice: Codable, Sendable, Equatable, Hashable {
    public let target: ModuleTarget
    public let label: String
    public let confirmed: Bool

    public init(target: ModuleTarget, label: String, confirmed: Bool = false) {
        self.target = target
        self.label = label
        self.confirmed = confirmed
    }
}

public struct SurveyReport: Codable, Sendable, Equatable {
    public let plan: SurveyPlan
    public let voltage: Double?
    public let vehicleInfo: [ECUIdentity]
    public let modules: [SurveyModule]
    public let unanswered: [SurveyCandidate]
    public let notProbed: [SurveyCandidate]
    public let stop: SurveyStop?
    public let detectedProtocol: ELM327Protocol?
    public let search: SearchOutcome?

    public init(
        plan: SurveyPlan, voltage: Double?, vehicleInfo: [ECUIdentity], modules: [SurveyModule],
        unanswered: [SurveyCandidate], notProbed: [SurveyCandidate], stop: SurveyStop?,
        detectedProtocol: ELM327Protocol? = nil, search: SearchOutcome? = nil
    ) {
        self.plan = plan
        self.voltage = voltage
        self.vehicleInfo = vehicleInfo
        self.modules = modules
        self.unanswered = unanswered
        self.notProbed = notProbed
        self.stop = stop
        self.detectedProtocol = detectedProtocol
        self.search = search
    }

    public func ownName(of module: SurveyModule) -> SurveyName? {
        if let identification = module.identification.first(where: { $0.did == 0xF197 }),
            case .value(let bytes) = identification.result,
            let text = IdentificationReading.value(bytes).text
        {
            return SurveyName(text: text, source: .module)
        }
        if let name = vehicleInfo.first(where: { $0.ecu == module.candidate.target.response })?
            .displayName,
            !name.isEmpty
        {
            return SurveyName(text: name, source: .obd)
        }
        return nil
    }

    public func name(of module: SurveyModule) -> SurveyName? {
        if case .saved(let label, _) = module.candidate.origin {
            return SurveyName(text: label, source: .saved)
        }
        if case .discovered = module.candidate.origin { return ownName(of: module) }
        if case .catalog(let label, _, _) = module.candidate.origin {
            return SurveyName(text: label, source: .catalog)
        }
        return ownName(of: module)
    }

    public func proposedModules() -> [ModuleChoice] {
        modules.map { module in
            if case .saved(let label, let confirmed) = module.candidate.origin {
                return ModuleChoice(
                    target: module.candidate.target, label: label,
                    confirmed: confirmed || ownName(of: module) != nil)
            }
            if case .discovered = module.candidate.origin, let name = ownName(of: module) {
                return ModuleChoice(
                    target: module.candidate.target, label: name.text, confirmed: true)
            }
            if case .catalog(let label, _, _) = module.candidate.origin {
                return ModuleChoice(
                    target: module.candidate.target, label: label,
                    confirmed: ownName(of: module) != nil)
            }
            if let name = ownName(of: module) {
                return ModuleChoice(
                    target: module.candidate.target, label: name.text, confirmed: true)
            }
            return ModuleChoice(
                target: module.candidate.target,
                label: String(format: "Module %03X", module.candidate.target.request),
                confirmed: false)
        }
    }
}
