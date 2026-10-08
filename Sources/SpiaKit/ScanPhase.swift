import Foundation

/// The four parts of a complete scan.
public enum ScanPhase: String, Codable, Sendable, Equatable, CaseIterable {
    case adapter
    case car
    case modules
    case codes

    public var title: String {
        switch self {
        case .adapter: return "Adapter and battery"
        case .car: return "The car"
        case .modules: return "Modules"
        case .codes: return "Codes"
        }
    }

    public static func current(for job: DiagnosticJob, step: String?) -> ScanPhase {
        switch job {
        case .adapterCheck: return .adapter
        case .vehicleInfo: return .car
        case .genericScan, .moduleDTCs: return .codes
        case .survey:
            guard let step else { return .car }
            if step.hasPrefix("Looking for modules") || step.hasPrefix("Looking again")
                || step.hasPrefix("Searching") || step.hasPrefix("Found a module")
                || step.contains("answered; asking what it is")
            {
                return .modules
            }
            if step.hasPrefix("Reading trouble codes") { return .codes }
            if step.hasPrefix("Asking the adapter") || step.hasPrefix("Reading the car's voltage") {
                return .car
            }
            return .car
        }
    }
}
