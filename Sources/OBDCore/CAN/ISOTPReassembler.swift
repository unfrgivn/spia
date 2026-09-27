public enum ISOTPError: Error, Equatable, Sendable, CustomStringConvertible {
    case truncated(ecu: UInt32)
    case sequenceGap(ecu: UInt32, expected: UInt8, got: UInt8)
    case missingFirstFrame(ecu: UInt32)
    case malformedFrame(ecu: UInt32)

    public var description: String {
        switch self {
        case .truncated(let ecu):
            return "ECU \(hex(ecu)): response shorter than its declared length"
        case .sequenceGap(let ecu, let expected, let got):
            return "ECU \(hex(ecu)): expected consecutive frame \(expected), got \(got)"
        case .missingFirstFrame(let ecu):
            return "ECU \(hex(ecu)): consecutive frame without a first frame"
        case .malformedFrame(let ecu):
            return "ECU \(hex(ecu)): ISO-TP frame is not a classical 8-byte CAN frame"
        }
    }

    private func hex(_ value: UInt32) -> String {
        String(value, radix: 16, uppercase: true)
    }
}

/// Reassembles ISO 15765-2 (ISO-TP) frames into one payload per responding ECU.
///
/// Frame layout, PCI = first data byte:
///
/// ```
/// Single      0L dd dd dd dd dd dd dd     L = length (1..7)
/// First       1L LL dd dd dd dd dd dd     LLL = 12-bit total length
/// Consecutive 2S dd dd dd dd dd dd dd     S = sequence 1,2,..,F,0,1,..
/// ```
public enum ISOTPReassembler {
    public static func reassemble(_ frames: [CANFrame]) throws -> [ECUResponse] {
        var order: [UInt32] = []
        var groups: [UInt32: [CANFrame]] = [:]
        for frame in frames {
            guard frame.data.count <= 8 else {
                throw ISOTPError.malformedFrame(ecu: frame.header)
            }
            if groups[frame.header] == nil {
                order.append(frame.header)
            }
            groups[frame.header, default: []].append(frame)
        }
        return try order.map { ecu in
            try reassemble(ecu: ecu, frames: groups[ecu] ?? [])
        }
    }

    private static func reassemble(ecu: UInt32, frames: [CANFrame]) throws -> ECUResponse {
        guard let first = frames.first, let pci = first.data.first else {
            throw ISOTPError.truncated(ecu: ecu)
        }
        switch pci >> 4 {
        case 0:
            let length = Int(pci & 0x0F)
            guard (1...7).contains(length), first.data.count > length else {
                throw ISOTPError.truncated(ecu: ecu)
            }
            return ECUResponse(ecu: ecu, payload: Array(first.data[1...length]))
        case 1:
            guard first.data.count >= 2 else {
                throw ISOTPError.truncated(ecu: ecu)
            }
            let length = (Int(pci & 0x0F) << 8) | Int(first.data[1])
            guard length >= 8 else {
                throw ISOTPError.truncated(ecu: ecu)
            }
            var payload = Array(first.data.dropFirst(2))
            var expected: UInt8 = 1
            for frame in frames.dropFirst() {
                guard let framePCI = frame.data.first, framePCI >> 4 == 2 else {
                    continue
                }
                let sequence = framePCI & 0x0F
                guard frame.data.count >= 2 else {
                    throw ISOTPError.truncated(ecu: ecu)
                }
                guard sequence == expected else {
                    throw ISOTPError.sequenceGap(ecu: ecu, expected: expected, got: sequence)
                }
                payload.append(contentsOf: frame.data.dropFirst())
                expected = (expected + 1) & 0x0F
            }
            guard payload.count >= length else {
                throw ISOTPError.truncated(ecu: ecu)
            }
            return ECUResponse(ecu: ecu, payload: Array(payload.prefix(length)))
        case 2:
            throw ISOTPError.missingFirstFrame(ecu: ecu)
        default:
            throw ISOTPError.truncated(ecu: ecu)
        }
    }
}
