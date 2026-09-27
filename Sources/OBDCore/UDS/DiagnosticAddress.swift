import Foundation

/// Where a diagnostic request goes on CAN, and where the answer comes back from.
///
/// Legislated OBD uses 11-bit IDs: request on `7E0`-`7E7`, reply on request + 8. Most
/// manufacturer modules on FCA-derived cars use ISO 15765-2 normal fixed addressing with 29-bit
/// IDs: request `18DA <target> <tester>`, reply `18DA <tester> <target>`, tester `F1`.
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
    /// filter for exactly the expected reply. Without the filter the adapter would hand back
    /// every broadcast frame on the bus.
    public func setupCommands(on bus: CANBus) -> [String] {
        switch self {
        case .standard(let request):
            return [
                bus.protocolCommand(extended: false),
                String(format: "ATSH%03X", request),
                String(format: "ATCRA%03X", responseHeader),
            ]
        case .extended(let target, let tester):
            return [
                bus.protocolCommand(extended: true),
                "ATCP18",
                String(format: "ATSH%02X%02X%02X", 0xDA, target, tester),
                String(format: "ATCRA%08X", responseHeader),
            ]
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
public enum CANBus: String, CaseIterable, Sendable {
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
