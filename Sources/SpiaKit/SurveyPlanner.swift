import Foundation
import OBDCore

public struct SurveyCandidate: Codable, Sendable, Equatable, Hashable {
    public enum Origin: Codable, Sendable, Equatable, Hashable {
        case catalog(label: String, provenance: ModuleProvenance, source: String)
        case legislated
    }

    public let target: ModuleTarget
    public let origin: Origin

    public init(target: ModuleTarget, origin: Origin) {
        self.target = target
        self.origin = origin
    }
}

public struct SurveyPlan: Codable, Sendable, Equatable, Hashable {
    public let catalogVersion: String
    public let vehicle: CatalogVehicle?
    public let platform: String?
    public let candidates: [SurveyCandidate]
    public let unreachable: [SurveyCandidate]
    public let probeTimeoutMilliseconds: UInt64
    public let readTimeoutMilliseconds: UInt64
    public let identification: [UInt16]
    public let requiresVIN: Bool
    public let expected: [ModuleTarget]

    public init(
        catalogVersion: String, vehicle: CatalogVehicle?, platform: String?,
        candidates: [SurveyCandidate], unreachable: [SurveyCandidate],
        probeTimeoutMilliseconds: UInt64 = 100, readTimeoutMilliseconds: UInt64 = 400,
        identification: [UInt16] = SurveyPlan.defaultIdentification,
        requiresVIN: Bool = false, expected: [ModuleTarget] = []
    ) {
        self.catalogVersion = catalogVersion
        self.vehicle = vehicle
        self.platform = platform
        self.candidates = candidates
        self.unreachable = unreachable
        self.probeTimeoutMilliseconds = probeTimeoutMilliseconds
        self.readTimeoutMilliseconds = readTimeoutMilliseconds
        self.identification = identification
        self.requiresVIN = requiresVIN
        self.expected = expected
    }

    private enum CodingKeys: String, CodingKey {
        case catalogVersion, vehicle, platform, candidates, unreachable
        case probeTimeoutMilliseconds, readTimeoutMilliseconds, identification
        case requiresVIN, expected
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        catalogVersion = try values.decode(String.self, forKey: .catalogVersion)
        vehicle = try values.decodeIfPresent(CatalogVehicle.self, forKey: .vehicle)
        platform = try values.decodeIfPresent(String.self, forKey: .platform)
        candidates = try values.decode([SurveyCandidate].self, forKey: .candidates)
        unreachable = try values.decode([SurveyCandidate].self, forKey: .unreachable)
        probeTimeoutMilliseconds = try values.decode(UInt64.self, forKey: .probeTimeoutMilliseconds)
        readTimeoutMilliseconds = try values.decode(UInt64.self, forKey: .readTimeoutMilliseconds)
        identification = try values.decode([UInt16].self, forKey: .identification)
        requiresVIN = try values.decodeIfPresent(Bool.self, forKey: .requiresVIN) ?? false
        expected = try values.decodeIfPresent([ModuleTarget].self, forKey: .expected) ?? []
    }

    public static let defaultIdentification: [UInt16] = [
        0xF190, 0xF197, 0xF187, 0xF191, 0xF192, 0xF194, 0xF195, 0xF19E,
    ]

    public var plannedRequests: [String] {
        let info = OBDInfoPlan.standard.requests.map(\.hex)
        return info
            + candidates.flatMap { candidate in
                let commands = commands(for: candidate)
                return [commands.probe] + commands.identification + [commands.codes]
            }
    }

    public var plannedCommands: [String] {
        ["ATRV"] + OBDInfoPlan.standard.requests.map(\.hex)
            + candidates.flatMap { commands(for: $0).all }
    }

    /// What one candidate costs, by part, so the executor never counts positions.
    public struct CandidateCommands: Sendable, Equatable {
        /// The bus protocol, the short probe timeout, and automatic flow control. Each answers OK.
        public let setup: [String]
        /// What `ELM327Session.configureDiagnosticHeaders` sends for the target.
        public let headers: [String]
        public let probe: String
        /// Sent only when the module answered the probe, before identification and codes.
        public let readTimeout: String
        public let identification: [String]
        public let codes: String

        /// Everything, in the order it's sent when the module answers.
        public var all: [String] {
            setup + headers + [probe, readTimeout] + identification + [codes]
        }
    }

    public func commands(for candidate: SurveyCandidate) -> CandidateCommands {
        CandidateCommands(
            setup: [
                candidate.target.bus.protocolCommand(extended: false), probeTimeoutCommand,
                "ATCFC 1",
            ],
            headers: candidate.target.headerCommands,
            probe: "3E00",
            readTimeout: readTimeoutCommand,
            identification: identification.map { String(format: "22%04X", $0) },
            codes: candidate.target.readCommand)
    }

    /// The adapter's per-reply timeout (`ATST`) while probing: short, because most candidates
    /// don't answer. Not how long the app waits for the adapter's prompt.
    public var probeTimeoutCommand: String {
        timeoutCommand(milliseconds: probeTimeoutMilliseconds)
    }

    /// The adapter's per-reply timeout (`ATST`) for identification and codes.
    public var readTimeoutCommand: String {
        timeoutCommand(milliseconds: readTimeoutMilliseconds)
    }

    private func timeoutCommand(milliseconds: UInt64) -> String {
        let value = min(max(milliseconds / 4, 1), 255)
        return String(format: "ATST %02X", value)
    }
}

public enum SurveyPlannerError: Error, Equatable, Sendable, CustomStringConvertible {
    case tooManyCandidates(Int)

    public var description: String {
        switch self {
        case .tooManyCandidates(let count):
            return
                "the survey has \(count) candidates, exceeding the limit of \(SurveyPlanner.candidateLimit)"
        }
    }
}

public enum SurveyPlanner {
    /// A bad catalog edit must not turn a survey into a flood of probes.
    public static let candidateLimit = 64

    public static func reachableBuses(for status: AdapterStatus?) -> Set<CANBus> {
        status?.firmware == nil ? [.highSpeed] : [.highSpeed, .mediumSpeed]
    }

    public static func plan(
        catalog: ModuleCatalog, vehicle: CatalogVehicle?, reachableBuses: Set<CANBus>
    ) throws -> SurveyPlan {
        var reachable = reachableBuses
        reachable.insert(.highSpeed)
        let match = vehicle.flatMap(catalog.match)
        let known = (match?.modules ?? []).map {
            SurveyCandidate(
                target: $0.target,
                origin: .catalog(label: $0.label, provenance: $0.provenance, source: $0.source))
        }
        // Whole targets, bus and reply included: the same request ID on another bus is another
        // module, and it mustn't drop the legislated probe on the 500k bus.
        let knownTargets = Set(known.map(\.target))
        let legislated = (UInt32(0x7E0)...0x7E7).compactMap { request -> SurveyCandidate? in
            guard
                let target = try? ModuleTarget(
                    bus: .highSpeed, request: request, response: request + 8),
                !knownTargets.contains(target)
            else { return nil }
            return SurveyCandidate(target: target, origin: .legislated)
        }
        let candidates = known.filter { reachable.contains($0.target.bus) } + legislated
        guard candidates.count <= candidateLimit else {
            throw SurveyPlannerError.tooManyCandidates(candidates.count)
        }
        return SurveyPlan(
            catalogVersion: catalog.catalogVersion, vehicle: vehicle,
            platform: match?.name, candidates: candidates,
            unreachable: known.filter { !reachable.contains($0.target.bus) },
            requiresVIN: vehicle != nil, expected: expectedTargets(from: candidates))
    }

    private static func expectedTargets(from candidates: [SurveyCandidate]) -> [ModuleTarget] {
        var targets = candidates.compactMap { candidate -> ModuleTarget? in
            if case .catalog(_, .observed, _) = candidate.origin { return candidate.target }
            return nil
        }
        let engine =
            candidates.first { $0.target.request == 0x7E0 && $0.target.response == 0x7E8 }?.target
            ?? (try? ModuleTarget(bus: .highSpeed, request: 0x7E0, response: 0x7E8))
        if let engine, !targets.contains(engine) { targets.append(engine) }
        return targets
    }
}
