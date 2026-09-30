public enum UDSNegativeResponseCode: Equatable, Sendable {
    case conditionsNotCorrect
    case serviceNotSupported
    case subFunctionNotSupported
    case incorrectMessageLengthOrInvalidFormat
    case requestOutOfRange
    case securityAccessDenied
    case responsePending
    case subFunctionNotSupportedInActiveSession
    case serviceNotSupportedInActiveSession
    case other(UInt8)

    public init(byte: UInt8) {
        switch byte {
        case 0x11: self = .serviceNotSupported
        case 0x12: self = .subFunctionNotSupported
        case 0x13: self = .incorrectMessageLengthOrInvalidFormat
        case 0x22: self = .conditionsNotCorrect
        case 0x31: self = .requestOutOfRange
        case 0x33: self = .securityAccessDenied
        case 0x78: self = .responsePending
        case 0x7E: self = .subFunctionNotSupportedInActiveSession
        case 0x7F: self = .serviceNotSupportedInActiveSession
        default: self = .other(byte)
        }
    }

    public var byte: UInt8 {
        switch self {
        case .conditionsNotCorrect: return 0x22
        case .serviceNotSupported: return 0x11
        case .subFunctionNotSupported: return 0x12
        case .incorrectMessageLengthOrInvalidFormat: return 0x13
        case .requestOutOfRange: return 0x31
        case .securityAccessDenied: return 0x33
        case .responsePending: return 0x78
        case .subFunctionNotSupportedInActiveSession: return 0x7E
        case .serviceNotSupportedInActiveSession: return 0x7F
        case .other(let value): return value
        }
    }
}
