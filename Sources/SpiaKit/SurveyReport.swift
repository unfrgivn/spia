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

/// Classifies the complete payload of a TesterPresent response during a broad sweep.
/// Whether one frame heard during the search is a module answering TesterPresent (`3E 00`): a
/// single ISO-TP frame carrying `7E 00`, or a negative answer to `3E` other than "pending".
/// Anything else in the window, including frames that aren't ISO-TP at all, is not.
public enum SearchReplyClassifier {
    public static func isTesterPresentReply(_ frame: CANFrame) -> Bool {
        guard let response = try? ISOTPReassembler.reassemble([frame]).first else { return false }
        return TesterPresentReply(payload: response.payload).isModule
    }

    /// No answer, or a frame the adapter flagged `<DATA ERROR` because its first byte isn't an
    /// ISO-TP length: ordinary traffic, so neither is trouble. The Ghibli's bus flags about one
    /// frame in three.
    static func isBenign(_ message: ELM327AdapterMessage) -> Bool {
        message == .noData || message == .dataError || message == .ok
    }
}

/// What the search makes of the listen before the sweep: every ID heard through the reply
/// window, and why the sweep mustn't run, if it mustn't.
public struct SearchListen: Sendable, Equatable {
    public let maxFrames: Int
    public private(set) var heard: Set<UInt32> = []
    public private(set) var frames = 0
    public private(set) var reason: String?

    public init(maxFrames: Int) {
        self.maxFrames = maxFrames
    }

    /// Takes one monitor event; returns false when listening should stop.
    public mutating func receive(_ event: MonitorEvent) -> Bool {
        switch event {
        case .frame(let frame):
            heard.insert(frame.header)
            frames += 1
            guard frames <= maxFrames else {
                reason = "The bus is busy where module replies would come, so Spia didn't search."
                return false
            }
            return true
        case .unparsable:
            return true
        case .message(let message):
            guard !SearchReplyClassifier.isBenign(message) else { return true }
            reason =
                "The adapter reported \(message.description) while listening, so Spia didn't search."
            return false
        case .prompt:
            reason = "The adapter stopped listening on its own, so Spia didn't search."
            return false
        }
    }
}

/// One probe's reply during the sweep, read line by line the way the monitor reads its stream,
/// since traffic in the window arrives with it.
public struct SearchReply: Sendable, Equatable {
    public let frames: [CANFrame]
    /// An adapter message that means the bus or the adapter is in trouble.
    public let trouble: ELM327AdapterMessage?

    public init(_ text: String) {
        let events = text.split(whereSeparator: \.isNewline).flatMap {
            MonitorStreamParser.events(forLine: String($0))
        }
        frames = events.compactMap { event in
            if case .frame(let frame) = event { return frame }
            return nil
        }
        trouble =
            events.compactMap { event -> ELM327AdapterMessage? in
                guard case .message(let message) = event,
                    !SearchReplyClassifier.isBenign(message)
                else { return nil }
                return message
            }.first
    }

    /// The reply IDs of the modules that answered TesterPresent.
    public var testerPresentReplies: [UInt32] {
        frames.filter(SearchReplyClassifier.isTesterPresentReply).map(\.header)
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
