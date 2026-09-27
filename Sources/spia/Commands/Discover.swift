import ArgumentParser
import Foundation
import OBDCore

struct Discover: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Find diagnostic modules: send TesterPresent to every plausible address and "
            + "list who answers.")

    @OptionGroup var global: GlobalOptions

    @Flag(name: .long, help: "Skip the 11-bit 700-7F7 sweep.")
    var skipStandard = false

    @Flag(name: .long, help: "Skip the 29-bit 18DAxxF1 sweep.")
    var skipExtended = false

    @Option(name: .long, help: "Per-address wait for a reply, in milliseconds.")
    var wait = 100

    @Option(
        name: .long,
        help: "Request to send at each address, hex. 3E00 = TesterPresent, 1001 = default session.")
    var request = "3E00"

    @Option(
        name: .long,
        help:
            "hs = DLC pins 6/14 at 500k (powertrain); ms = pins 3/11 at 125k (interior, vLinker FS only)."
    )
    var bus: CANBus = .highSpeed

    func run() async throws {
        try await Connection.with(global) { connection in
            let session = connection.session
            stderr("Connected to \(connection.adapterIdentity).")
            // Fixed, short reply timeout: an unanswered address costs `wait` ms, nothing more.
            for command in ["ATAT0", String(format: "ATST%02X", max(1, min(255, wait / 4)))] {
                let response = try await session.send(command)
                guard response.contains("OK") else {
                    throw ELM327Error.unexpectedResponse(command: command, response: response)
                }
            }

            var found: [(DiagnosticAddress, ECUResponse)] = []
            if !skipStandard {
                stderr("Sweeping 11-bit 700-7F7...")
                for request in UInt16(0x700)...0x7F7
                where request != 0x7DF && !(0x7E8...0x7EF).contains(request) {
                    found += try await probe(.standard(request: request), on: session)
                }
            }
            if !skipExtended {
                stderr("Sweeping 29-bit 18DAxxF1...")
                for target in UInt8(0x00)...0xFF where target != 0xF1 {
                    found += try await probe(.extended(target: target), on: session)
                }
            }

            print()
            print(
                "\(found.count) module\(found.count == 1 ? "" : "s") answered \(request) on \(bus.rawValue):"
            )
            for (address, response) in found {
                print(
                    "  \(address) -> \(String(format: "%X", response.ecu)): \(PIDValue.raw(response.payload).formatted)"
                )
            }
        }
    }

    private func requestBytes() throws -> [UInt8] {
        let digits = Array(request.filter { !$0.isWhitespace })
        guard !digits.isEmpty, digits.count.isMultiple(of: 2) else {
            throw ValidationError("--request must be an even number of hex digits")
        }
        return try stride(from: 0, to: digits.count, by: 2).map { index in
            guard let byte = UInt8(String(digits[index...index + 1]), radix: 16) else {
                throw ValidationError("'\(request)' is not hex")
            }
            return byte
        }
    }

    private func probe(_ address: DiagnosticAddress, on session: ELM327Session) async throws
        -> [(DiagnosticAddress, ECUResponse)]
    {
        try await session.address(address, on: bus)
        let responses: [ECUResponse]
        do {
            responses = try await session.request(
                OBDRequest(raw: try requestBytes()), timeout: .seconds(2))
        } catch ELM327Error.adapter(.noData) {
            return []
        } catch ELM327Error.adapter(let message) {
            stderr("  \(address): \(message)")
            return []
        }
        for response in responses {
            print("  \(address) answered: \(PIDValue.raw(response.payload).formatted)")
        }
        return responses.map { (address, $0) }
    }
}
