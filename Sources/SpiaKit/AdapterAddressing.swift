import Foundation

/// The adapter's addressing state as established by the checks run on this connection.
public enum AdapterAddressing: Equatable, Sendable {
    /// The state left by connection initialization.
    case postConnect
    /// The adapter has been configured for a module read.
    case moduleAddressed

    public func needsReinitialization(for job: DiagnosticJob) -> Bool {
        self == .moduleAddressed && job.requiresPostConnectAddressing
    }

    public func state(after job: DiagnosticJob) -> AdapterAddressing {
        switch job {
        case .moduleDTCs:
            return .moduleAddressed
        case .adapterCheck:
            return self
        case .vehicleInfo, .genericScan:
            return .postConnect
        }
    }
}

extension DiagnosticJob {
    fileprivate var requiresPostConnectAddressing: Bool {
        switch self {
        case .genericScan, .vehicleInfo: true
        case .adapterCheck, .moduleDTCs: false
        }
    }
}
