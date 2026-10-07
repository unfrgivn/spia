import Foundation

public enum IdentificationReading: Equatable, Sendable {
    case value([UInt8])
    case refused(UDSNegativeResponseCode)

    public var rawValue: [UInt8]? {
        if case .value(let bytes) = self { return bytes }
        return nil
    }

    public var text: String? {
        guard let rawValue else { return nil }
        var trimmed = rawValue
        while let first = trimmed.first, first == 0 || first == 0xFF || first == 0x20 {
            trimmed.removeFirst()
        }
        while let last = trimmed.last, last == 0 || last == 0xFF || last == 0x20 {
            trimmed.removeLast()
        }
        guard !trimmed.isEmpty, trimmed.allSatisfy({ (0x20...0x7E).contains($0) }) else {
            return nil
        }
        return String(decoding: trimmed, as: UTF8.self)
    }
}

public enum IdentificationDecodeError: Error, Equatable, Sendable {
    case tooShort
    case wrongDID(expected: UInt16, actual: UInt16)
    case invalidService(UInt8)
    case wrongNegativeService(UInt8)
}

public enum IdentificationDecoder {
    public static func decode(did: UInt16, payload: [UInt8]) throws -> IdentificationReading {
        guard payload.count >= 3 else { throw IdentificationDecodeError.tooShort }
        switch payload[0] {
        case 0x62:
            let actual = UInt16(payload[1]) << 8 | UInt16(payload[2])
            guard actual == did else {
                throw IdentificationDecodeError.wrongDID(expected: did, actual: actual)
            }
            return .value(Array(payload.dropFirst(3)))
        case 0x7F:
            guard payload[1] == 0x22 else {
                throw IdentificationDecodeError.wrongNegativeService(payload[1])
            }
            return .refused(UDSNegativeResponseCode(byte: payload[2]))
        default:
            throw IdentificationDecodeError.invalidService(payload[0])
        }
    }
}
