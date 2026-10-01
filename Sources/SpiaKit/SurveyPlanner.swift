import Foundation
import OBDCore

public struct SurveyCandidate: Codable, Sendable, Equatable, Hashable {
    public enum Origin: Codable, Sendable, Equatable, Hashable {
        case catalog(label: String, provenance: ModuleProvenance, source: String)
        case saved(label: String, confirmed: Bool)
        case discovered
        case legislated
    }

    public let target: ModuleTarget
    public let origin: Origin

    public init(target: ModuleTarget, origin: Origin) {
        self.target = target
        self.origin = origin
    }
}

public struct ModuleSearch: Codable, Sendable, Equatable, Hashable {
    public let requestRange: ClosedRange<UInt32>
    public let replyWindow: ReceiveFilter
    public let listenMilliseconds: UInt64
    public let replyTimeoutMilliseconds: UInt64
    public let busyLimitPerSecond: Int
    public let perAddressMilliseconds: UInt64

    public init(
        requestRange: ClosedRange<UInt32> = 0x600...0x7FF,
        replyWindow: ReceiveFilter = .window(mask: 0x400, pattern: 0x400),
        listenMilliseconds: UInt64,
        replyTimeoutMilliseconds: UInt64 = 48,
        busyLimitPerSecond: Int = 20,
        perAddressMilliseconds: UInt64 = 80
    ) {
        self.requestRange = requestRange
        self.replyWindow = replyWindow
        self.listenMilliseconds = listenMilliseconds
        self.replyTimeoutMilliseconds = replyTimeoutMilliseconds
        self.busyLimitPerSecond = busyLimitPerSecond
        self.perAddressMilliseconds = perAddressMilliseconds
    }

    public static func standard(over connection: ConnectionKind) -> ModuleSearch {
        switch connection {
        case .bluetooth:
            return ModuleSearch(listenMilliseconds: 1_000, perAddressMilliseconds: 120)
        case .usbSerial, .demo, .replay:
            return ModuleSearch(listenMilliseconds: 2_000, perAddressMilliseconds: 80)
        }
    }

    public func estimateMilliseconds(
        candidates: [SurveyCandidate] = [], heardIDs: Set<UInt32> = []
    ) -> UInt64 {
        let count = sweepRequests(candidates: candidates, heardIDs: heardIDs).count
        return listenMilliseconds + UInt64(count) * perAddressMilliseconds
    }

    /// The most frames the listen may hear through the window before the bus counts as too busy
    /// to search: the per-second limit over the whole listen.
    public var maxListenFrames: Int {
        max(1, busyLimitPerSecond * Int(listenMilliseconds) / 1_000)
    }

    /// The adapter's own wait for each answer during the sweep (`ATST`, in 4 ms units). Modules
    /// answer TesterPresent within a few milliseconds, so it stays short.
    public var replyTimeoutCommand: String {
        let value = min(max(replyTimeoutMilliseconds / 4, 1), 255)
        return String(format: "ATST %02X", value)
    }

    public func sweepRequests(
        candidates: [SurveyCandidate], heardIDs: Set<UInt32>
    ) -> [UInt32] {
        let excluded = Set([0x7DF] + Array(0x7E0...0x7E7))
            .union(candidates.map { $0.target.request }).union(heardIDs)
        return requestRange.filter { !excluded.contains($0) }
    }

    /// The plain-language warning shown before the owner starts a thorough search.
    public func confirmationMessage(
        connection: ConnectionKind, candidates: [SurveyCandidate], heardIDs: Set<UInt32> = []
    ) -> String {
        let addresses = sweepRequests(candidates: candidates, heardIDs: heardIDs).count
        let milliseconds = estimateMilliseconds(candidates: candidates, heardIDs: heardIDs)
        let seconds = (milliseconds + 999) / 1_000
        let connectionName = connection == .bluetooth ? "Bluetooth" : "USB"
        return
            "Spia will send a 'tester present' message, which changes nothing, to about \(addresses) addresses this car doesn't use, to find modules no list knows about.\nIt takes about \(seconds) seconds over \(connectionName).\nLeave the ignition on with the engine off, and don't drive."
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
    public let detectsProtocol: Bool
    public let search: ModuleSearch?

    public init(
        catalogVersion: String, vehicle: CatalogVehicle?, platform: String?,
        candidates: [SurveyCandidate], unreachable: [SurveyCandidate],
        probeTimeoutMilliseconds: UInt64 = 100, readTimeoutMilliseconds: UInt64 = 400,
        identification: [UInt16] = SurveyPlan.defaultIdentification,
        requiresVIN: Bool = false, expected: [ModuleTarget] = [], detectsProtocol: Bool = false,
        search: ModuleSearch? = nil
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
        self.detectsProtocol = detectsProtocol
        self.search = search
    }

    private enum CodingKeys: String, CodingKey {
        case catalogVersion, vehicle, platform, candidates, unreachable
        case probeTimeoutMilliseconds, readTimeoutMilliseconds, identification
        case requiresVIN, expected, detectsProtocol, search
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
        detectsProtocol = try values.decodeIfPresent(Bool.self, forKey: .detectsProtocol) ?? false
        search = try values.decodeIfPresent(ModuleSearch.self, forKey: .search)
    }

    public static let defaultIdentification: [UInt16] = [
        0xF190, 0xF197, 0xF187, 0xF191, 0xF192, 0xF194, 0xF195, 0xF19E,
    ]

    public var plannedRequests: [String] {
        let info = OBDInfoPlan.standard.requests.map(\.hex)
        // The search asks the engine's RPM, then sends only TesterPresent.
        let searchRequests = search == nil ? [] : ["010C", "3E00"]
        return info
            + candidates.flatMap { candidate in
                let commands = commands(for: candidate)
                return [commands.probe] + commands.identification + [commands.codes]
            } + searchRequests
    }

    public var plannedCommands: [String] {
        let searchCommands: [String] =
            search.map { value in
                let window: [String]
                switch value.replyWindow {
                case .expectedReply:
                    window = []
                case .window(let mask, let pattern):
                    window = [
                        String(format: "ATCM %03X", mask), String(format: "ATCF %03X", pattern),
                    ]
                }
                return ["ATCRA"] + window + [value.replyTimeoutCommand, "3E00"]
                    + value.requestRange.map { String(format: "ATSH %03X", $0) }
            } ?? []
        return ["ATRV"] + OBDInfoPlan.standard.requests.map(\.hex)
            + (detectsProtocol ? ["ATDPN"] : [])
            + candidates.flatMap { commands(for: $0).all } + searchCommands
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
                candidate.target.bus.protocolCommand(extended: candidate.target.isExtended),
                probeTimeoutCommand,
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
        catalog: ModuleCatalog, vehicle: CatalogVehicle?, reachableBuses: Set<CANBus>,
        savedModules: [ModuleChoice] = [], search: ModuleSearch? = nil
    ) throws -> SurveyPlan {
        var reachable = reachableBuses
        reachable.insert(.highSpeed)
        let match = vehicle.flatMap(catalog.match)
        let catalogCandidates = (match?.modules ?? []).map {
            SurveyCandidate(
                target: $0.target,
                origin: .catalog(label: $0.label, provenance: $0.provenance, source: $0.source))
        }
        // A module saved twice (the modules editor allows it) is still one module.
        var seen = Set<ModuleTarget>()
        let saved = savedModules.filter { seen.insert($0.target).inserted }
        let savedByTarget = Dictionary(uniqueKeysWithValues: saved.map { ($0.target, $0) })
        var known = catalogCandidates.map { candidate in
            guard let saved = savedByTarget[candidate.target] else { return candidate }
            return SurveyCandidate(
                target: candidate.target,
                origin: .saved(label: saved.label, confirmed: saved.confirmed))
        }
        let catalogTargets = Set(catalogCandidates.map(\.target))
        known += saved.filter { !catalogTargets.contains($0.target) }.map {
            SurveyCandidate(
                target: $0.target, origin: .saved(label: $0.label, confirmed: $0.confirmed))
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
            requiresVIN: true,
            expected: expectedTargets(from: candidates),
            detectsProtocol: true, search: search)
    }

    /// The candidates the survey should hear from, in probe order: the car's saved modules,
    /// catalog modules seen answering on this platform, and the engine computer every car has at
    /// `7E0`. Unreachable modules are never probed, so they can't be missed either.
    private static func expectedTargets(from candidates: [SurveyCandidate]) -> [ModuleTarget] {
        candidates.compactMap { candidate in
            let target = candidate.target
            switch candidate.origin {
            case .saved, .catalog(_, .observed, _):
                return target
            case .catalog, .legislated, .discovered:
                let engine =
                    target.bus == .highSpeed && target.request == 0x7E0 && target.response == 0x7E8
                return engine ? target : nil
            }
        }
    }
}
