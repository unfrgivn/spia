import Foundation

public enum IgnitionType: Sendable, Equatable {
    case spark
    case compression
}

/// An emissions readiness monitor reported by PID 01.
public enum Monitor: String, Hashable, Sendable, CaseIterable {
    case misfire
    case fuelSystem
    case components
    case catalyst
    case heatedCatalyst
    case evaporativeSystem
    case secondaryAirSystem
    case acRefrigerant
    case oxygenSensor
    case oxygenSensorHeater
    case egrOrVVT
    case nmhcCatalyst
    case noxScrMonitor
    case boostPressure
    case exhaustGasSensor
    case pmFilter
}

public struct MonitorStatus: Sendable, Equatable {
    public let milOn: Bool
    public let dtcCount: UInt8
    public let ignition: IgnitionType
    /// Only monitors the ECU reports as available. `true` means the test has completed.
    public let complete: [Monitor: Bool]

    public init(milOn: Bool, dtcCount: UInt8, ignition: IgnitionType, complete: [Monitor: Bool]) {
        self.milOn = milOn
        self.dtcCount = dtcCount
        self.ignition = ignition
        self.complete = complete
    }
}

/// PID 1C: which OBD standard the ECU claims to follow.
public enum OBDStandard: Sendable, Equatable {
    case obdII
    case obdEPA
    case obdAndObdII
    case obdI
    case notOBD
    case eobd
    case eobdAndObdII
    case eobdAndObd
    case eobdObdAndObdII
    case jobd
    case jobdAndObdII
    case jobdAndEobd
    case jobdEobdAndObdII
    case other(UInt8)

    public init(byte: UInt8) {
        let known: [OBDStandard] = [
            .obdII, .obdEPA, .obdAndObdII, .obdI, .notOBD, .eobd, .eobdAndObdII, .eobdAndObd,
            .eobdObdAndObdII, .jobd, .jobdAndObdII, .jobdAndEobd, .jobdEobdAndObdII,
        ]
        let index = Int(byte) - 1
        self = known.indices.contains(index) ? known[index] : .other(byte)
    }
}

/// A decoded PID value with its unit baked into the case.
public enum PIDValue: Sendable, Equatable {
    case supported(Set<UInt8>)
    case monitorStatus(MonitorStatus)
    case rpm(Double)
    case celsius(Double)
    case percent(Double)
    case kilometersPerHour(Double)
    case kilopascals(Double)
    case gramsPerSecond(Double)
    case volts(Double)
    case seconds(UInt32)
    case kilometers(UInt32)
    case degrees(Double)
    case litersPerHour(Double)
    case obdStandard(OBDStandard)
    /// The PID is unknown or the ECU sent fewer bytes than the formula needs.
    case raw([UInt8])

    public var formatted: String {
        switch self {
        case .supported(let pids):
            return pids.sorted().map { String(format: "%02X", $0) }.joined(separator: " ")
        case .monitorStatus(let status):
            let mil = status.milOn ? "MIL on" : "MIL off"
            return "\(mil), \(status.dtcCount) DTC(s), \(status.complete.count) monitors"
        case .rpm(let value): return "\(Int(value.rounded())) rpm"
        case .celsius(let value): return "\(Int(value.rounded())) °C"
        case .percent(let value): return String(format: "%.1f %%", value)
        case .kilometersPerHour(let value): return "\(Int(value.rounded())) km/h"
        case .kilopascals(let value): return "\(Int(value.rounded())) kPa"
        case .gramsPerSecond(let value): return String(format: "%.2f g/s", value)
        case .volts(let value): return String(format: "%.2f V", value)
        case .seconds(let value): return "\(value) s"
        case .kilometers(let value): return "\(value) km"
        case .degrees(let value): return String(format: "%.1f°", value)
        case .litersPerHour(let value): return String(format: "%.2f L/h", value)
        case .obdStandard(let standard): return "\(standard)"
        case .raw(let bytes): return bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        }
    }
}
