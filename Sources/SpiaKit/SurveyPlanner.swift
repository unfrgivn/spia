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

    public init(
        catalogVersion: String, vehicle: CatalogVehicle?, platform: String?,
        candidates: [SurveyCandidate], unreachable: [SurveyCandidate],
        probeTimeoutMilliseconds: UInt64 = 100, readTimeoutMilliseconds: UInt64 = 400,
        identification: [UInt16] = SurveyPlan.defaultIdentification
    ) {
        self.catalogVersion = catalogVersion
        self.vehicle = vehicle
        self.platform = platform
        self.candidates = candidates
        self.unreachable = unreachable
        self.probeTimeoutMilliseconds = probeTimeoutMilliseconds
        self.readTimeoutMilliseconds = readTimeoutMilliseconds
        self.identification = identification
    }

    public static let defaultIdentification: [UInt16] = [
        0xF190, 0xF197, 0xF187, 0xF191, 0xF192, 0xF194, 0xF195, 0xF19E,
    ]

    public var plannedRequests: [String] {
        let info = OBDInfoPlan.standard.requests.map(\.hex)
        let module = candidates.flatMap { candidate in
            ["3E00"]
                + identification.map { String(format: "22%04X", $0) }
                + [candidate.target.readCommand]
        }
        return info + module
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
            unreachable: known.filter { !reachable.contains($0.target.bus) })
    }
}
