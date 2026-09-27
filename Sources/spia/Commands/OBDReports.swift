import ArgumentParser
import OBDCore

struct Scan: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Read generic DTCs, freeze frame, and readiness.")
    @OptionGroup var global: GlobalOptions

    func run() async throws {
        var options = global
        if options.protocol == .automatic { options.protocol = .can11bit500k }
        try validateGenericProtocol(options.protocol)
        try await Connection.with(options) { connection in
            var observations: [OBDObservation] = []
            var ecus = Set<UInt32>()
            var requested: [OBDRequest] = []
            for request in OBDScanPlan.standard.requests {
                requested.append(request)
                do {
                    let values = try await connection.session.request(request)
                    for value in values {
                        ecus.insert(value.ecu)
                        let response = ServiceResponse.decode(value.payload)
                        observations.append(
                            OBDObservation(
                                request: request, ecu: value.ecu,
                                outcome: .response(response)))
                    }
                } catch ELM327Error.adapter(.noData) {
                    stderr("\(request.hex): no response")
                }
            }
            let freezeFrame = OBDScanPlan.freezeFrameDTC
            requested.append(freezeFrame)
            do {
                let values = try await connection.session.request(freezeFrame)
                for value in values {
                    ecus.insert(value.ecu)
                    observations.append(
                        OBDObservation(
                            request: freezeFrame, ecu: value.ecu,
                            outcome: .response(ServiceResponse.decode(value.payload))))
                }
            } catch ELM327Error.adapter(.noData) {
                stderr("\(freezeFrame.hex): no response")
            }
            let hasFreezeFrameDTC = observations.contains {
                guard $0.request == OBDScanPlan.freezeFrameDTC,
                    case .response(.freezeFrameDTC(frame: 0, dtc: let dtc)) = $0.outcome
                else { return false }
                return dtc != nil
            }
            if hasFreezeFrameDTC {
                let support = OBDScanPlan.freezeFrameSupport
                requested.append(support)
                do {
                    let values = try await connection.session.request(support)
                    for value in values {
                        ecus.insert(value.ecu)
                        let response = ServiceResponse.decode(value.payload)
                        observations.append(
                            OBDObservation(
                                request: support, ecu: value.ecu, outcome: .response(response)))
                    }
                } catch ELM327Error.adapter(.noData) {
                    stderr("\(support.hex): freeze-frame PID support unavailable")
                }
                for useful in OBDScanPlan.freezeFrameFollowUpRequests(observations: observations) {
                    do {
                        requested.append(useful)
                        let values = try await connection.session.request(useful)
                        observations += values.map { value in
                            ecus.insert(value.ecu)
                            return OBDObservation(
                                request: useful, ecu: value.ecu,
                                outcome: .response(ServiceResponse.decode(value.payload)))
                        }
                    } catch ELM327Error.adapter(.noData) {
                        stderr("\(useful.hex): freeze-frame value unavailable")
                    }
                }
            }
            let finalized = OBDReportBuilder.finalizeObservations(
                observations, requests: requested, ecus: ecus)
            let reports = OBDReportBuilder.scan(observations: finalized)
            if reports.isEmpty {
                stderr("No ECU responded; vehicle health is unknown.")
                throw ValidationError("no ECU responded")
            }
            for report in reports { print(report.formatted) }
        }
    }
}

struct Info: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Read generic VIN, calibration IDs, CVNs, and ECU names.")
    @OptionGroup var global: GlobalOptions

    func run() async throws {
        var options = global
        if options.protocol == .automatic { options.protocol = .can11bit500k }
        try validateGenericProtocol(options.protocol)
        try await Connection.with(options) { connection in
            var observations: [OBDObservation] = []
            var ecus = Set<UInt32>()
            var requested: [OBDRequest] = []
            for request in OBDInfoPlan.standard.requests {
                requested.append(request)
                do {
                    let values = try await connection.session.request(request)
                    for value in values {
                        ecus.insert(value.ecu)
                        observations.append(
                            OBDObservation(
                                request: request, ecu: value.ecu,
                                outcome: .response(ServiceResponse.decode(value.payload))))
                    }
                } catch ELM327Error.adapter(.noData) {
                    stderr("\(request.hex): optional data unavailable")
                }
            }
            let finalized = OBDReportBuilder.finalizeObservations(
                observations, requests: requested, ecus: ecus)
            let reports = OBDReportBuilder.info(observations: finalized)
            if reports.isEmpty {
                stderr("No ECU responded; vehicle identity is unknown.")
                throw ValidationError("no ECU responded")
            }
            for report in reports { print(report.formatted) }
        }
    }
}

private func validateGenericProtocol(_ value: ELM327Protocol) throws {
    guard value == .can11bit500k || value == .can29bit500k else {
        throw ValidationError("scan and info require CAN 11-bit 500k (6) or CAN 29-bit 500k (7)")
    }
}

private extension ECUReport {
    var formatted: String {
        let readinessText: String
        switch readiness {
        case .positive(let status):
            let monitors = status.complete.keys.sorted { $0.rawValue < $1.rawValue }.map {
                monitor in
                "\(monitor.rawValue):\(status.complete[monitor] == true ? "complete" : "incomplete")"
            }.joined(separator: ", ")
            readinessText =
                "MIL \(status.milOn ? "on" : "off"), DTC count \(status.dtcCount), \(monitors)"
        default: readinessText = readiness.text
        }
        return
            "ECU \(String(format: "%03X", ecu))\n  stored: \(stored.text)\n  pending: \(pending.text)\n  permanent: \(permanent.text)\n  readiness: \(readinessText)\n  freeze-frame DTC: \(freezeFrameDTC.text)\n  freeze-frame values: \(freezeFrameValuesText)"
    }

    var freezeFrameValuesText: String {
        guard !freezeFrameValues.isEmpty else { return "none" }
        return freezeFrameValues.sorted { $0.key < $1.key }.map { pid, value in
            "PID \(String(format: "%02X", pid)): \(value.text)"
        }.joined(separator: ", ")
    }
}

private extension OBDReadResult where Value == [DTC] {
    var text: String {
        switch self {
        case .positive(let value):
            return value.isEmpty
                ? "positive empty" : value.map(\.description).joined(separator: ", ")
        case .unsupported(let code): return "unsupported (\(code))"
        case .unavailable(let reason): return "unavailable (\(reason))"
        case .malformed: return "malformed"
        case .unknown: return "unknown"
        }
    }
}

private extension OBDReadResult {
    var text: String {
        switch self {
        case .positive: return "available"
        case .unsupported(let code): return "unsupported (\(code))"
        case .unavailable(let reason): return "unavailable (\(reason))"
        case .malformed: return "malformed"
        case .unknown: return "unknown"
        }
    }
}

private extension OBDReadResult where Value == DTC? {
    var text: String {
        switch self {
        case .positive(let dtc): return dtc?.description ?? "positive empty"
        case .unsupported(let code): return "unsupported (\(code))"
        case .unavailable(let reason): return "unavailable (\(reason))"
        case .malformed: return "malformed"
        case .unknown: return "unknown"
        }
    }
}

private extension OBDReadResult where Value == PIDValue {
    var text: String {
        switch self {
        case .positive(let value): return value.formatted
        case .unsupported(let code): return "unsupported (\(code))"
        case .unavailable(let reason): return "unavailable (\(reason))"
        case .malformed: return "malformed"
        case .unknown: return "unknown"
        }
    }
}
