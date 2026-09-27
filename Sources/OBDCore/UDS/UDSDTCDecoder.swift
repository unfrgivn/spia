public struct UDSDTCRecord: Equatable, Sendable {
    public let code: [UInt8]
    public let status: UInt8

    public init(code: [UInt8], status: UInt8) {
        self.code = code
        self.status = status
    }
}

public enum UDSNegativeResponseCode: Equatable, Sendable {
    case conditionsNotCorrect
    case responsePending
    case other(UInt8)

    public init(byte: UInt8) {
        switch byte {
        case 0x22: self = .conditionsNotCorrect
        case 0x78: self = .responsePending
        default: self = .other(byte)
        }
    }
}

public enum UDSDTCResponse: Equatable, Sendable {
    case positive(availability: UInt8, records: [UDSDTCRecord])
    case negative(service: UInt8, code: UDSNegativeResponseCode)
}

public enum UDSDTCDecodeError: Error, Equatable, Sendable {
    case invalidLength
    case invalidService(UInt8)
    case invalidSubfunction(UInt8)
}

public enum UDSDTCDecoder {
    public static func decode(_ payload: [UInt8]) throws -> UDSDTCResponse {
        guard let service = payload.first else {
            throw UDSDTCDecodeError.invalidLength
        }

        if service == 0x7F {
            guard payload.count == 3 else {
                throw UDSDTCDecodeError.invalidLength
            }
            return .negative(service: payload[1], code: UDSNegativeResponseCode(byte: payload[2]))
        }

        guard service == 0x59 else {
            throw UDSDTCDecodeError.invalidService(service)
        }
        guard payload.count >= 2 else {
            throw UDSDTCDecodeError.invalidLength
        }
        guard payload[1] == 0x02 else {
            throw UDSDTCDecodeError.invalidSubfunction(payload[1])
        }
        guard payload.count >= 3, (payload.count - 3).isMultiple(of: 4) else {
            throw UDSDTCDecodeError.invalidLength
        }

        var records: [UDSDTCRecord] = []
        for index in stride(from: 3, to: payload.count, by: 4) {
            records.append(
                UDSDTCRecord(code: Array(payload[index..<index + 3]), status: payload[index + 3]))
        }
        return .positive(availability: payload[2], records: records)
    }
}
