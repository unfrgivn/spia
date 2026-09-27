import ArgumentParser
import OBDCore

struct Scan: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Read generic DTCs, freeze frame, and readiness.")
    @OptionGroup var global: GlobalOptions

    func run() async throws {
        let options = try genericOptions(global)
        try await Connection.with(options) { connection in
            let reports = try await reportingNoVehicle("vehicle health") {
                try await GenericOBDWorkflow.scan(on: connection.session, onEvent: logNoResponse)
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
        let options = try genericOptions(global)
        try await Connection.with(options) { connection in
            let reports = try await reportingNoVehicle("vehicle identity") {
                try await GenericOBDWorkflow.info(on: connection.session, onEvent: logNoResponse)
            }
            for report in reports { print(report.formatted) }
        }
    }
}

private func genericOptions(_ global: GlobalOptions) throws -> GlobalOptions {
    var options = global
    if options.protocol == .automatic { options.protocol = .can11bit500k }
    try validateGenericProtocol(options.protocol)
    return options
}

@Sendable private func logNoResponse(_ event: GenericOBDWorkflow.Event) {
    if case .noResponse(let request) = event { stderr("\(request.hex): no response") }
}

/// Runs a generic read and turns "nobody answered" into a clear, nonzero exit.
private func reportingNoVehicle<Report>(
    _ subject: String, _ body: () async throws -> [Report]
) async throws -> [Report] {
    do {
        let reports = try await body()
        guard !reports.isEmpty else { throw GenericOBDWorkflow.Failure.noVehicleResponse(.noData) }
        return reports
    } catch let failure as GenericOBDWorkflow.Failure {
        stderr("No ECU responded; \(subject) is unknown. Is the ignition on?")
        throw ValidationError(failure.description)
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
