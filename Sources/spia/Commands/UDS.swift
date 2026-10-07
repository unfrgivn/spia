import ArgumentParser
import Foundation
import OBDCore

struct UDS: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Read manufacturer-module UDS data.", subcommands: [UDSDTCs.self])
}

struct UDSDTCs: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dtcs", abstract: "Read DTCs with UDS service 19.")

    @OptionGroup var global: GlobalOptions
    @Option var bus: CANBus = .highSpeed
    @Option(help: "11-bit or 29-bit request CAN ID, hexadecimal.") var tx: String
    @Option(help: "11-bit or 29-bit response CAN ID, hexadecimal.") var rx: String
    @Option(help: "One-byte UDS status mask, hexadecimal (default: 09).") var statusMask = "09"
    @Option(help: "Finite transaction timeout in seconds (default: 10, maximum: 120).")
    var timeout = 10.0

    func run() async throws {
        let requestHeader = try parseHeader(tx, name: "--tx")
        let responseHeader = try parseHeader(rx, name: "--rx")
        let extended = requestHeader > 0x7FF
        guard extended == (responseHeader > 0x7FF) else {
            throw ValidationError(
                "--tx and --rx must use the same width: each must be an 11-bit hexadecimal CAN ID or both 29-bit"
            )
        }
        guard !extended || bus == .highSpeed else {
            throw ValidationError("29-bit module addresses are only supported on the 500k bus")
        }
        guard requestHeader != responseHeader else {
            throw ValidationError("--tx and --rx must differ")
        }
        guard requestHeader != 0x7DF, responseHeader != 0x7DF,
            requestHeader != 0x18DB_33F1, responseHeader != 0x18DB_33F1
        else {
            throw ValidationError("functional broadcast IDs cannot be module addresses")
        }
        let mask = try parseByte(statusMask, name: "--status-mask")
        guard timeout.isFinite, timeout > 0, timeout <= 120 else {
            throw ValidationError("--timeout must be finite, positive, and at most 120 seconds")
        }

        try await Connection.with(global) { connection in
            let session = connection.session
            let protocolCommand = bus.protocolCommand(extended: extended)
            let protocolResponse = try await session.send(protocolCommand)
            guard protocolResponse.contains("OK") else {
                throw ELM327Error.unexpectedResponse(
                    command: protocolCommand, response: protocolResponse)
            }
            for command in ["ATST 64", "ATCFC 1"] {
                let response = try await session.send(command)
                guard response.trimmingCharacters(in: .whitespacesAndNewlines) == "OK" else {
                    throw ELM327Error.unexpectedResponse(command: command, response: response)
                }
            }
            try await session.configureDiagnosticHeaders(
                requestHeader: requestHeader, responseHeader: responseHeader)
            let response = try await session.readUDSDTC(
                responseHeader: responseHeader, statusMask: mask, timeout: .seconds(timeout))
            print(response.formatted)
            if case .negative = response { throw ExitCode.failure }
        }
    }

    private func parseHeader(_ value: String, name: String) throws -> UInt32 {
        guard let parsed = UInt32(value, radix: 16), parsed <= 0x1FFF_FFFF else {
            throw ValidationError("\(name) must be an 11-bit or 29-bit hexadecimal CAN ID")
        }
        return parsed
    }

    private func parseByte(_ value: String, name: String) throws -> UInt8 {
        guard let parsed = UInt8(value, radix: 16) else {
            throw ValidationError("\(name) must be one byte of hexadecimal")
        }
        return parsed
    }
}

private extension UDSDTCResponse {
    var formatted: String {
        switch self {
        case .positive(let availability, let records):
            let availabilityText = statusNames(availability)
            guard !records.isEmpty else {
                return
                    "No DTC records (positive response; availability 0x\(String(format: "%02X", availability)): \(availabilityText))"
            }
            return records.map { record in
                let code = record.code.map { String(format: "%02X", $0) }.joined()
                return
                    "\(code) status 0x\(String(format: "%02X", record.status)): \(statusNames(record.status))"
            }.joined(separator: "\n")
                + "\nAvailability 0x\(String(format: "%02X", availability)): \(availabilityText)"
        case .negative(let service, let code):
            return String(
                format: "Negative response: service 0x%02X, NRC %@", service,
                String(describing: code))
        }
    }

    func statusNames(_ value: UInt8) -> String {
        let names = [
            (0x01, "testFailed"), (0x02, "testFailedThisOperationCycle"),
            (0x04, "pendingDTC"), (0x08, "confirmedDTC"),
            (0x10, "testNotCompletedSinceLastClear"), (0x20, "testFailedSinceLastClear"),
            (0x40, "testNotCompletedThisOperationCycle"), (0x80, "warningIndicatorRequested"),
        ].compactMap { value & UInt8($0.0) != 0 ? $0.1 : nil }
        return names.isEmpty ? "none" : names.joined(separator: ", ")
    }
}
