import Foundation

/// Results retain the difference between a positive empty answer and no usable answer.
public enum OBDReadResult<Value: Sendable & Equatable>: Sendable, Equatable {
    case positive(Value)
    case unsupported(NegativeResponseCode)
    case unavailable(String)
    case malformed([UInt8])
    case unknown([UInt8])
}

public enum OBDRequestOutcome: Sendable, Equatable {
    case response(ServiceResponse)
    case adapter(ELM327AdapterMessage)
    case malformed([UInt8])
}

public struct OBDObservation: Sendable, Equatable {
    public let request: OBDRequest
    public let ecu: UInt32?
    public let outcome: OBDRequestOutcome

    public init(request: OBDRequest, ecu: UInt32?, outcome: OBDRequestOutcome) {
        self.request = request
        self.ecu = ecu
        self.outcome = outcome
    }
}

public struct ECUReport: Sendable, Equatable {
    public let ecu: UInt32
    public var stored: OBDReadResult<[DTC]> = .unavailable("not requested")
    public var pending: OBDReadResult<[DTC]> = .unavailable("not requested")
    public var permanent: OBDReadResult<[DTC]> = .unavailable("not requested")
    public var readiness: OBDReadResult<MonitorStatus> = .unavailable("not requested")
    public var freezeFrameDTC: OBDReadResult<DTC?> = .unavailable("not requested")
    public var freezeFrameValues: [UInt8: OBDReadResult<PIDValue>] = [:]

    public init(ecu: UInt32) { self.ecu = ecu }
}

public struct OBDScanPlan: Sendable, Equatable {
    public let requests: [OBDRequest]
    public static let standard = OBDScanPlan(requests: [
        OBDRequest(service: .currentData, pid: 0x00),
        OBDRequest(service: .currentData, pid: 0x01),
        OBDRequest(service: .storedDTCs),
        OBDRequest(service: .pendingDTCs),
        OBDRequest(service: .permanentDTCs),
    ])
    public static let freezeFrameDTC = OBDRequest(service: .freezeFrame, pid: 0x02, frame: 0x00)
    public static let freezeFrameSupport = OBDRequest(service: .freezeFrame, pid: 0x00, frame: 0x00)
    public init(requests: [OBDRequest]) { self.requests = requests }

    public static func freezeFrameFollowUpRequests(
        observations: [OBDObservation]
    ) -> [OBDRequest] {
        let eligible = Set(
            observations.compactMap { observation -> UInt32? in
                guard observation.request == freezeFrameDTC,
                    case .response(.freezeFrameDTC(frame: 0, dtc: let dtc)) = observation.outcome,
                    dtc != nil
                else { return nil }
                return observation.ecu
            })
        let supported = observations.reduce(into: Set<UInt8>()) { result, observation in
            guard let ecu = observation.ecu, eligible.contains(ecu),
                observation.request == freezeFrameSupport,
                case .response(.freezeFrame(_, 0, .supported(let pids))) = observation.outcome
            else { return }
            result.formUnion(pids.intersection(Set([0x05, 0x0C, 0x0D, 0x0F, 0x11])))
        }
        return supported.sorted().map { OBDRequest(service: .freezeFrame, pid: $0, frame: 0) }
    }
}

public struct OBDInfoPlan: Sendable, Equatable {
    public let requests: [OBDRequest]
    public static let standard = OBDInfoPlan(requests: [
        OBDRequest(service: .vehicleInfo, pid: 0x00),
        OBDRequest(service: .vehicleInfo, pid: 0x02),
        OBDRequest(service: .vehicleInfo, pid: 0x04),
        OBDRequest(service: .vehicleInfo, pid: 0x06),
        OBDRequest(service: .vehicleInfo, pid: 0x0A),
    ])
    public init(requests: [OBDRequest]) { self.requests = requests }
}

public struct ECUInfoReport: Sendable, Equatable {
    public let ecu: UInt32
    public var vin: OBDReadResult<String> = .unavailable("not requested")
    public var calibrationIDs: OBDReadResult<[String]> = .unavailable("not requested")
    public var cvns: OBDReadResult<[String]> = .unavailable("not requested")
    public var name: OBDReadResult<String> = .unavailable("not requested")
    public init(ecu: UInt32) { self.ecu = ecu }

    public var formatted: String {
        "ECU \(String(ecu, radix: 16, uppercase: true))\n  VIN: \(stringValue(vin))\n  CAL IDs: \(stringListValue(calibrationIDs))\n  CVNs: \(stringListValue(cvns))\n  name: \(stringValue(name))"
    }

    private func stringValue(_ result: OBDReadResult<String>) -> String {
        switch result {
        case .positive(let value): return value.replacingOccurrences(of: "\0", with: "")
        case .unsupported(let code): return "unsupported (\(code))"
        case .unavailable(let reason): return "unavailable (\(reason))"
        case .malformed: return "malformed"
        case .unknown: return "unknown"
        }
    }

    private func stringListValue(_ result: OBDReadResult<[String]>) -> String {
        switch result {
        case .positive(let values):
            return values.isEmpty ? "positive empty" : values.joined(separator: ", ")
        case .unsupported(let code): return "unsupported (\(code))"
        case .unavailable(let reason): return "unavailable (\(reason))"
        case .malformed: return "malformed"
        case .unknown: return "unknown"
        }
    }
}

public enum OBDReportBuilder {
    public static func finalizeObservations(
        _ observations: [OBDObservation], requests: [OBDRequest], ecus: Set<UInt32>
    ) -> [OBDObservation] {
        var result = observations
        for ecu in ecus {
            for request in requests
            where !result.contains(where: { $0.ecu == ecu && $0.request == request }) {
                result.append(
                    OBDObservation(request: request, ecu: ecu, outcome: .adapter(.noData)))
            }
        }
        return result
    }

    public static func scan(observations: [OBDObservation]) -> [ECUReport] {
        var reports: [UInt32: ECUReport] = [:]
        for observation in observations {
            guard let ecu = observation.ecu else { continue }
            var report = reports[ecu] ?? ECUReport(ecu: ecu)
            switch observation.outcome {
            case .adapter(.noData): markUnavailable(&report, request: observation.request)
            case .adapter: break
            case .malformed(let bytes):
                markUnknown(&report, request: observation.request, bytes: bytes)
            case .response(let response):
                apply(&report, request: observation.request, response: response)
            }
            reports[ecu] = report
        }
        return reports.values.sorted { $0.ecu < $1.ecu }
    }

    public static func info(observations: [OBDObservation]) -> [ECUInfoReport] {
        var reports: [UInt32: ECUInfoReport] = [:]
        for observation in observations {
            guard let ecu = observation.ecu else { continue }
            var report = reports[ecu] ?? ECUInfoReport(ecu: ecu)
            switch observation.outcome {
            case .adapter(.noData): markUnavailable(&report, request: observation.request)
            case .adapter: break
            case .malformed(let bytes):
                markUnknown(&report, request: observation.request, bytes: bytes)
            case .response(let response):
                apply(&report, request: observation.request, response: response)
            }
            reports[ecu] = report
        }
        return reports.values.sorted { $0.ecu < $1.ecu }
    }

    private static func apply(
        _ report: inout ECUReport, request: OBDRequest, response: ServiceResponse
    ) {
        switch response {
        case .dtcs(let service, let codes):
            guard request.bytes == [service.rawValue] else {
                markUnknown(&report, request: request, bytes: [service.positiveResponseByte])
                return
            }
            assign(&report, service: service, result: .positive(codes))
        case .currentData(_, .monitorStatus(let status)) where request.bytes == [0x01, 0x01]:
            report.readiness = .positive(status)
        case .currentData where request.bytes == [0x01, 0x01]:
            markUnknown(&report, request: request, bytes: [0x41])
        case .freezeFrameDTC(_, let dtc) where request.bytes == [0x02, 0x02, 0x00]:
            report.freezeFrameDTC = .positive(dtc)
        case .freezeFrameDTC where request.bytes == [0x02, 0x02, 0x00]:
            markUnknown(&report, request: request, bytes: [0x42])
        case .freezeFrame(let pid, 0, let value) where request.bytes == [0x02, pid, 0]:
            report.freezeFrameValues[pid] = .positive(value)
        case .freezeFrame where request.bytes.count == 3 && request.bytes.first == 0x02:
            markUnknown(&report, request: request, bytes: [0x42])
        case .negative(let service, let code):
            guard request.bytes.first == service?.rawValue else {
                markUnknown(&report, request: request, bytes: [0x7F])
                return
            }
            switch service {
            case .some(.storedDTCs): report.stored = dtcNegative(code)
            case .some(.pendingDTCs): report.pending = dtcNegative(code)
            case .some(.permanentDTCs): report.permanent = dtcNegative(code)
            default: break
            }
        case .unrecognized(let bytes): markUnknown(&report, request: request, bytes: bytes)
        default: break
        }
    }

    private static func apply(
        _ report: inout ECUInfoReport, request: OBDRequest, response: ServiceResponse
    ) {
        switch response {
        case .vin(let value) where request.bytes == [0x09, 0x02]: report.vin = .positive(value)
        case .calibrationIDs(let value) where request.bytes == [0x09, 0x04]:
            report.calibrationIDs = .positive(value)
        case .calibrationVerificationNumbers(let value) where request.bytes == [0x09, 0x06]:
            report.cvns = .positive(value)
        case .ecuName(let value) where request.bytes == [0x09, 0x0A]: report.name = .positive(value)
        case .negative(let service, let code) where service == .some(.vehicleInfo):
            guard request.bytes.first == 0x09 else {
                markUnknown(&report, request: request, bytes: [0x7F])
                return
            }
            markUnsupported(&report, request: request, code: code)
        case .unrecognized(let bytes): markUnknown(&report, request: request, bytes: bytes)
        default: break
        }
    }

    private static func assign(
        _ report: inout ECUReport, service: OBDService, result: OBDReadResult<[DTC]>
    ) {
        switch service {
        case .storedDTCs: report.stored = result
        case .pendingDTCs: report.pending = result
        case .permanentDTCs: report.permanent = result
        default: break
        }
    }

    private static func markUnavailable(_ report: inout ECUReport, request: OBDRequest) {
        if request.bytes == [0x02, 0x02, 0] {
            report.freezeFrameDTC = .unavailable("no response")
            return
        }
        if request.bytes.count == 3, request.bytes[0] == 0x02, request.bytes[2] == 0 {
            report.freezeFrameValues[request.bytes[1]] = .unavailable("no response")
            return
        }
        switch request.bytes {
        case [0x03]: report.stored = .unavailable("no response")
        case [0x07]: report.pending = .unavailable("no response")
        case [0x0A]: report.permanent = .unavailable("no response")
        case [0x01, 0x01]: report.readiness = .unavailable("no response")
        default: break
        }
    }

    private static func markUnavailable(_ report: inout ECUInfoReport, request: OBDRequest) {
        switch request.bytes {
        case [0x09, 0x02]: report.vin = .unavailable("no response")
        case [0x09, 0x04]: report.calibrationIDs = .unavailable("no response")
        case [0x09, 0x06]: report.cvns = .unavailable("no response")
        case [0x09, 0x0A]: report.name = .unavailable("no response")
        default: break
        }
    }

    private static func markUnsupported(
        _ report: inout ECUInfoReport, request: OBDRequest, code: NegativeResponseCode
    ) {
        switch request.bytes {
        case [0x09, 0x02]: report.vin = infoNegative(code)
        case [0x09, 0x04]: report.calibrationIDs = infoNegative(code)
        case [0x09, 0x06]: report.cvns = infoNegative(code)
        case [0x09, 0x0A]: report.name = infoNegative(code)
        default: break
        }
    }

    private static func infoNegative<Value>(_ code: NegativeResponseCode) -> OBDReadResult<Value> {
        switch code {
        case .serviceNotSupported, .subFunctionNotSupported: return .unsupported(code)
        default: return .unavailable("negative response: \(code)")
        }
    }

    private static func dtcNegative(_ code: NegativeResponseCode) -> OBDReadResult<[DTC]> {
        switch code {
        case .serviceNotSupported, .subFunctionNotSupported: return .unsupported(code)
        default: return .unavailable("negative response: \(code)")
        }
    }

    private static func markUnknown(_ report: inout ECUReport, request: OBDRequest, bytes: [UInt8])
    {
        if request.bytes.count == 3, request.bytes[0] == 0x02, request.bytes[2] == 0 {
            report.freezeFrameValues[request.bytes[1]] = .unknown(bytes)
            return
        }
        switch request.bytes {
        case [0x03]: report.stored = .unknown(bytes)
        case [0x07]: report.pending = .unknown(bytes)
        case [0x0A]: report.permanent = .unknown(bytes)
        case [0x01, 0x01]: report.readiness = .unknown(bytes)
        case [0x02, 0x02, 0]: report.freezeFrameDTC = .unknown(bytes)
        default: break
        }
    }

    private static func markUnknown(
        _ report: inout ECUInfoReport, request: OBDRequest, bytes: [UInt8]
    ) {
        switch request.bytes {
        case [0x09, 0x02]: report.vin = .unknown(bytes)
        case [0x09, 0x04]: report.calibrationIDs = .unknown(bytes)
        case [0x09, 0x06]: report.cvns = .unknown(bytes)
        case [0x09, 0x0A]: report.name = .unknown(bytes)
        default: break
        }
    }
}
