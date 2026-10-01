import Foundation

/// Where a diagnostic request goes on CAN, and where the answer comes back from.
///
/// Legislated OBD uses 11-bit IDs: request on `7E0`-`7E7`, reply on request + 8. Some
/// manufacturer modules use ISO 15765-2 normal fixed addressing with 29-bit IDs: request
/// `18DA <target> <tester>`, reply `18DA <tester> <target>`, tester `F1`. On the recorded Ghibli
/// bus, the observed 11-bit request/reply pair is `744` -> `4C4`; no broader mapping is inferred.
public enum DiagnosticAddress: Equatable, Hashable, Sendable, CustomStringConvertible {
    case standard(request: UInt16)
    case extended(target: UInt8, tester: UInt8 = 0xF1)

    public var requestHeader: UInt32 {
        switch self {
        case .standard(let request): return UInt32(request)
        case .extended(let target, let tester):
            return 0x18DA_0000 | UInt32(target) << 8 | UInt32(tester)
        }
    }

    public var responseHeader: UInt32 {
        switch self {
        case .standard(let request): return UInt32(request) + 8
        case .extended(let target, let tester):
            return 0x18DA_0000 | UInt32(tester) << 8 | UInt32(target)
        }
    }

    /// The commands that aim the adapter at this address: protocol, header, and a receive
    /// filter. Without a filter the adapter would hand back every broadcast frame on the bus.
    public func setupCommands(on bus: CANBus, receive: ReceiveFilter = .expectedReply) -> [String] {
        switch self {
        case .standard(let request):
            return [
                bus.protocolCommand(extended: false),
                String(format: "ATSH%03X", request),
            ] + receive.commands(expected: responseHeader, extended: false)
        case .extended(let target, let tester):
            return [
                bus.protocolCommand(extended: true),
                "ATCP18",
                String(format: "ATSH%02X%02X%02X", 0xDA, target, tester),
            ] + receive.commands(expected: responseHeader, extended: true)
        }
    }

    public var description: String {
        switch self {
        case .standard(let request): return String(format: "%03X", request)
        case .extended: return String(format: "%08X", requestHeader)
        }
    }
}

/// Which CAN transceiver in the adapter, hence which DLC pins.
public enum CANBus: String, CaseIterable, Codable, Sendable {
    /// DLC pins 6/14, ISO 15765-4 at 500k. Legislated OBD, powertrain. Plain ELM327 `ATSP`.
    case highSpeed = "hs"
    /// DLC pins 3/11 at 125k. Ford calls it MS-CAN, FCA calls it CAN-IHS (interior). Only on
    /// adapters with a second transceiver such as the vLinker FS; STN protocols 53 and 54.
    case mediumSpeed = "ms"

    public func protocolCommand(extended: Bool) -> String {
        switch self {
        case .highSpeed:
            return "ATSP" + (extended ? ELM327Protocol.can29bit500k : .can11bit500k).commandDigit
        case .mediumSpeed:
            return extended ? "STP 54" : "STP 53"
        }
    }
}

/// Which incoming frames the adapter passes back after a request.
public enum ReceiveFilter: Codable, Equatable, Hashable, Sendable {
    /// Only the conventional reply ID (request + 8, or `18DA <tester> <target>`).
    case expectedReply
    /// Any ID in an aligned range, for cars whose reply IDs do not follow the convention.
    /// `mask` selects the bits that must equal `pattern`; `ATCM 600` / `ATCF 600` accepts
    /// `600`-`7FF`.
    case window(mask: UInt32, pattern: UInt32)

    /// The smallest aligned window covering `lowest`...`highest`.
    public static func window(covering lowest: UInt32, _ highest: UInt32) throws -> ReceiveFilter {
        guard lowest <= highest, highest <= 0x7FF else {
            throw DiagnosticAddressError.invalidReceiveWindow(lowest: lowest, highest: highest)
        }
        var span: UInt32 = 1
        while lowest & ~(span - 1) != highest & ~(span - 1) {
            span <<= 1
        }
        return .window(mask: 0x7FF & ~(span - 1), pattern: lowest & ~(span - 1))
    }

    func commands(expected: UInt32, extended: Bool) -> [String] {
        let width = extended ? 8 : 3
        switch self {
        case .expectedReply:
            return [String(format: "ATCRA%0\(width)X", expected)]
        case .window(let mask, let pattern):
            return [
                String(format: "ATCM%0\(width)X", mask), String(format: "ATCF%0\(width)X", pattern),
            ]
        }
    }
}

public enum DiagnosticAddressError: Error, Equatable, Sendable {
    case invalidReceiveWindow(lowest: UInt32, highest: UInt32)
}
