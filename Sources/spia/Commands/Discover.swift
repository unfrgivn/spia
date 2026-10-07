import ArgumentParser
import Foundation
import OBDCore

struct Discover: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Find diagnostic modules: send TesterPresent to every plausible address and "
            + "list who answers.")

    @OptionGroup var global: GlobalOptions

    @Flag(name: .long, help: "Skip the 11-bit sweep.")
    var skipStandard = false

    @Option(name: .long, help: "11-bit request IDs to sweep, hex, inclusive.")
    var range = "7E0-7E7"

    @Option(
        name: .long,
        help: ArgumentHelp(
            "Accept replies from an explicitly aligned experimental ID range instead of request+8, e.g. 600-7FF.",
            discussion:
                "Vehicle-specific experimental mode; do not assume this range is safe on another bus."
        ))
    var responseWindow: String?

    @Flag(name: .long, help: "Skip the 29-bit 18DAxxF1 sweep.")
    var skipExtended = false

    @Option(name: .long, help: "Per-address wait for a reply, in milliseconds.")
    var wait = 100

    @Option(
        name: .long,
        help: "Request to send at each address, hex. 3E00 = TesterPresent, 1001 = default session.")
    var request = "3E00"

    @Flag(name: .long, help: "Allow non-legislated ranges and the 29-bit sweep.")
    var experimental = false

    @Option(
        name: .long,
        help:
            "hs = DLC pins 6/14 at 500k (powertrain); ms = pins 3/11 at 125k (interior, vLinker FS only)."
    )
    var bus: CANBus = .highSpeed

    func run() async throws {
        let standardRange = try parseRange(range)
        let payload = try requestBytes()
        guard payload == [0x3E, 0x00] else {
            throw ValidationError("--request is restricted to 3E00")
        }
        guard (4...1020).contains(wait), wait.isMultiple(of: 4) else {
            throw ValidationError("--wait must be a multiple of 4 milliseconds from 4 through 1020")
        }
        if !experimental && (standardRange.0 < 0x7E0 || standardRange.1 > 0x7E7) {
            throw ValidationError("non-standard discovery requires --experimental")
        }
        if let responseWindow {
            let window = try parseRange(responseWindow)
            guard experimental else {
                throw ValidationError("--response-window requires --experimental")
            }
            try validateResponseWindow(window)
        }
        if responseWindow == nil && standardRange.1 > 0x7F7 {
            throw ValidationError("request IDs must leave room for request+8")
        }
        guard !(skipStandard && (!experimental || skipExtended)) else {
            throw ValidationError("discovery has no sweep enabled")
        }
        try await Connection.with(global) { connection in
            let session = connection.session
            stderr("Connected to \(connection.adapterIdentity).")
            // Fixed, short reply timeout: an unanswered address costs `wait` ms, nothing more.
            for command in ["ATAT0", String(format: "ATST%02X", max(1, min(255, wait / 4)))] {
                let response = try await session.send(command)
                guard response.trimmingCharacters(in: .whitespacesAndNewlines) == "OK" else {
                    throw ELM327Error.unexpectedResponse(command: command, response: response)
                }
            }

            var found: [(DiagnosticAddress, ECUResponse)] = []
            if !skipStandard {
                let (low, high) = standardRange
                var receive = ReceiveFilter.expectedReply
                if let responseWindow {
                    let (windowLow, windowHigh) = try parseRange(responseWindow)
                    receive = try .window(covering: UInt32(windowLow), UInt32(windowHigh))
                }
                stderr("Sweeping 11-bit \(range)...")
                for request in low...high
                where request != 0x7DF && !(0x7E8...0x7EF).contains(request) {
                    found += try await probe(
                        .standard(request: request), on: session, receive: receive)
                }
            }
            if experimental && !skipExtended {
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

    private func parseRange(_ text: String) throws -> (UInt16, UInt16) {
        let parts = text.split(separator: "-")
        guard parts.count == 2, let low = UInt16(parts[0], radix: 16),
            let high = UInt16(parts[1], radix: 16), low <= high, high <= 0x7FF
        else {
            throw ValidationError("'\(text)' is not a hex range like 700-7F7")
        }
        return (low, high)
    }

    private func validateResponseWindow(_ range: (UInt16, UInt16)) throws {
        let filter = try ReceiveFilter.window(covering: UInt32(range.0), UInt32(range.1))
        guard case .window(let mask, let pattern) = filter else { return }
        let expandedLow = pattern & 0x7FF
        let expandedHigh = expandedLow | (~mask & 0x7FF)
        guard UInt16(expandedLow) == range.0, UInt16(expandedHigh) == range.1 else {
            throw ValidationError("--response-window must be an exact aligned mask range")
        }
        guard range.0 >= 0x480 else {
            throw ValidationError(
                "--response-window must start at or above 480 (experimental broadcast safety bound)"
            )
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

    private func probe(
        _ address: DiagnosticAddress, on session: ELM327Session,
        receive: ReceiveFilter = .expectedReply
    ) async throws -> [(DiagnosticAddress, ECUResponse)] {
        try await session.address(address, on: bus, receive: receive)
        let responses: [ECUResponse]
        do {
            responses = try await session.request(
                OBDRequest(raw: try requestBytes()), timeout: .seconds(2))
        } catch ELM327Error.adapter(.noData) {
            return []
        }
        for response in responses
        where TesterPresentReply(payload: response.payload) == .pending {
            stderr("  \(address): response pending (provisional, not counted)")
        }
        let valid = responses.filter { TesterPresentReply(payload: $0.payload).isModule }
        for response in valid {
            print("  \(address) answered: \(PIDValue.raw(response.payload).formatted)")
        }
        return valid.map { (address, $0) }
    }
}
