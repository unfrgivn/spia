import OBDCore

/// A diagnostic module addressed with either standard 11-bit IDs or normal-fixed 29-bit IDs.
/// Reply IDs are not always request + 8 on manufacturer modules, so both are stored explicitly.
public struct ModuleTarget: Codable, Sendable, Hashable {
    public let bus: CANBus
    public let request: UInt32
    public let response: UInt32
    public var isExtended: Bool { request > 0x7FF }
    /// UDS status mask for ReadDTCInformation 19 02. `09` = failing now or confirmed.
    public let statusMask: UInt8

    public enum Invalid: Error, Equatable, Sendable, CustomStringConvertible {
        case invalidCANID(UInt32)
        case mixedAddressWidth(request: UInt32, response: UInt32)
        case extendedOnMediumSpeed
        case functionalBroadcast
        case extendedFunctionalBroadcast
        case sameRequestAndResponse

        public var description: String {
            switch self {
            case .invalidCANID(let id): return String(format: "%X is not a valid CAN ID", id)
            case .mixedAddressWidth(let request, let response):
                return String(
                    format: "request %X and reply %X must use the same CAN ID width", request,
                    response)
            case .extendedOnMediumSpeed:
                return "29-bit module addresses are only supported on the 500k bus"
            case .functionalBroadcast: return "7DF is the broadcast ID, not a module"
            case .extendedFunctionalBroadcast:
                return "18DB33F1 is the functional broadcast ID, not a module"
            case .sameRequestAndResponse: return "request and reply IDs must differ"
            }
        }
    }

    public init(bus: CANBus, request: UInt32, response: UInt32, statusMask: UInt8 = 0x09) throws {
        guard request != response else { throw Invalid.sameRequestAndResponse }
        for id in [request, response] where id > 0x1FFF_FFFF { throw Invalid.invalidCANID(id) }
        let requestIsExtended = request > 0x7FF
        guard requestIsExtended == (response > 0x7FF) else {
            throw Invalid.mixedAddressWidth(request: request, response: response)
        }
        guard request != 0x7DF, response != 0x7DF else { throw Invalid.functionalBroadcast }
        guard request != 0x18DB_33F1, response != 0x18DB_33F1 else {
            throw Invalid.extendedFunctionalBroadcast
        }
        guard !requestIsExtended || bus == .highSpeed else {
            throw Invalid.extendedOnMediumSpeed
        }
        self.bus = bus
        self.request = request
        self.response = response
        self.statusMask = statusMask
    }

    private enum CodingKeys: String, CodingKey { case bus, request, response, statusMask }

    /// For targets known valid at compile time, such as the demo car's modules.
    init(known bus: CANBus, request: UInt32, response: UInt32) {
        self.bus = bus
        self.request = request
        self.response = response
        self.statusMask = 0x09
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            bus: values.decode(CANBus.self, forKey: .bus),
            request: values.decode(UInt32.self, forKey: .request),
            response: values.decode(UInt32.self, forKey: .response),
            statusMask: values.decode(UInt8.self, forKey: .statusMask))
    }

    /// Adapter setup that precedes the flow-control configuration. Sent exactly as listed and
    /// each must answer `OK`. This is the order proven on the car.
    public var setupCommands: [String] {
        [bus.protocolCommand(extended: isExtended), "ATST 64", "ATCFC 1"]
    }

    /// What `ELM327Session.configureDiagnosticHeaders` sends for this target.
    public var headerCommands: [String] {
        [
            String(format: "ATSH %0\(isExtended ? 8 : 3)X", request),
            String(format: "ATCRA %0\(isExtended ? 8 : 3)X", response),
            "ATFCSD 30 00 00",
            String(format: "ATFCSH %0\(isExtended ? 8 : 3)X", request), "ATFCSM 1",
        ]
    }

    public var readCommand: String { String(format: "1902%02X", statusMask) }
}

/// What the car has to be doing for a check to work.
public enum VehicleRequirement: String, Codable, Sendable {
    case none
    /// Ignition in RUN (the dash lit); the engine may be off.
    case ignitionOn
}

/// The complete list of things the app may do to a car. Every case is read-only: nothing here
/// clears codes, changes a module's session, unlocks security access, or moves an actuator.
public enum DiagnosticJob: Codable, Sendable, Hashable {
    case adapterCheck
    case vehicleInfo
    case genericScan
    case moduleDTCs(ModuleTarget)
    case survey(SurveyPlan)

    public var id: String {
        switch self {
        case .adapterCheck: return "adapter-check"
        case .vehicleInfo: return "vehicle-info"
        case .genericScan: return "generic-scan"
        case .moduleDTCs(let target):
            return String(
                format: "module-dtcs-%@-%03X-%03X", target.bus.rawValue, target.request,
                target.response)
        case .survey: return "survey"
        }
    }

    public var title: String {
        switch self {
        case .adapterCheck: return "Check the adapter"
        case .vehicleInfo: return "Read vehicle information"
        case .genericScan: return "Scan for engine and transmission codes"
        case .moduleDTCs: return "Read module trouble codes"
        case .survey: return "Survey the car"
        }
    }

    public var summary: String {
        switch self {
        case .adapterCheck:
            return "Identifies the adapter and reads the battery voltage it sees."
        case .vehicleInfo:
            return
                "Reads the VIN, software calibration IDs, and module names every car must report."
        case .genericScan:
            return "Reads the standard emissions codes, readiness monitors, and freeze frame."
        case .moduleDTCs:
            return "Asks one module, such as the airbag controller, for its trouble codes."
        case .survey:
            return "Finds the car's diagnostic modules, asks what they are, and reads their codes."
        }
    }

    public var requirement: VehicleRequirement {
        switch self {
        case .adapterCheck: return .none
        case .vehicleInfo, .genericScan, .moduleDTCs, .survey: return .ignitionOn
        }
    }

    /// Commands this check sends, for the "what will be sent" view and the allowlist test.
    /// Generic scans add freeze-frame follow-ups only when an ECU reports a freeze frame.
    public var plannedCommands: [String] {
        switch self {
        case .adapterCheck:
            return ["STI", "STDI", "ATRV"]
        case .vehicleInfo:
            return OBDInfoPlan.standard.requests.map(\.hex)
        case .genericScan:
            return
                (OBDScanPlan.standard.requests + [
                    OBDScanPlan.freezeFrameDTC, OBDScanPlan.freezeFrameSupport,
                ]).map(\.hex)
        case .moduleDTCs(let target):
            return ["ATRV"] + target.setupCommands + target.headerCommands + [target.readCommand]
        case .survey(let plan): return plan.plannedCommands
        }
    }
}
