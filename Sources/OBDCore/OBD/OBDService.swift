/// SAE J1979 diagnostic services (modes). A positive reply echoes the service with bit 6 set.
public enum OBDService: UInt8, CaseIterable, Sendable {
    case currentData = 0x01
    case freezeFrame = 0x02
    case storedDTCs = 0x03
    case clearDTCs = 0x04
    case pendingDTCs = 0x07
    case vehicleInfo = 0x09
    case permanentDTCs = 0x0A

    public var positiveResponseByte: UInt8 {
        rawValue | 0x40
    }
}

/// UDS / J1979 negative response codes, the third byte of a `7F` reply.
public enum NegativeResponseCode: Equatable, Sendable, CustomStringConvertible {
    case generalReject
    case serviceNotSupported
    case subFunctionNotSupported
    case incorrectMessageLength
    case busyRepeatRequest
    case conditionsNotCorrect
    case requestOutOfRange
    case securityAccessDenied
    case responsePending
    case unknown(UInt8)

    public init(byte: UInt8) {
        switch byte {
        case 0x10: self = .generalReject
        case 0x11: self = .serviceNotSupported
        case 0x12: self = .subFunctionNotSupported
        case 0x13: self = .incorrectMessageLength
        case 0x21: self = .busyRepeatRequest
        case 0x22: self = .conditionsNotCorrect
        case 0x31: self = .requestOutOfRange
        case 0x33: self = .securityAccessDenied
        case 0x78: self = .responsePending
        default: self = .unknown(byte)
        }
    }

    public var description: String {
        switch self {
        case .generalReject: return "general reject"
        case .serviceNotSupported: return "service not supported"
        case .subFunctionNotSupported: return "sub-function not supported"
        case .incorrectMessageLength: return "incorrect message length"
        case .busyRepeatRequest: return "busy, repeat request"
        case .conditionsNotCorrect: return "conditions not correct"
        case .requestOutOfRange: return "request out of range"
        case .securityAccessDenied: return "security access denied"
        case .responsePending: return "response pending"
        case .unknown(let byte):
            return "negative response 0x\(String(byte, radix: 16, uppercase: true))"
        }
    }
}
