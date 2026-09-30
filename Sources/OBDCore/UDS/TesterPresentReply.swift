import Foundation

public enum TesterPresentReply: Equatable, Sendable {
    case present
    case refused(UDSNegativeResponseCode)
    case pending
    case unrelated

    public init(payload: [UInt8]) {
        if payload.count >= 2, payload[0] == 0x7E, payload[1] == 0x00 {
            self = .present
        } else if payload.count >= 3, payload[0] == 0x7F, payload[1] == 0x3E {
            let code = UDSNegativeResponseCode(byte: payload[2])
            self = code == .responsePending ? .pending : .refused(code)
        } else {
            self = .unrelated
        }
    }

    public var isModule: Bool {
        switch self {
        case .present, .refused: true
        case .pending, .unrelated: false
        }
    }
}
