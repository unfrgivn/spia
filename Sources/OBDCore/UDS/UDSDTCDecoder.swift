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

    public var byte: UInt8 {
        switch self {
        case .conditionsNotCorrect: return 0x22
        case .responsePending: return 0x78
        case .other(let value): return value
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

public enum UDSDTCReadError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidHeader(UInt32)
    case unexpectedECU(UInt32)
    case pendingWithoutFinalResponse
    case noFrames
    case wrongNegativeService(UInt8)
    case duplicateFinalResponse
    case adapterStatus(ELM327AdapterMessage)

    public var description: String {
        switch self {
        case .invalidHeader(let header):
            return String(format: "UDS DTC read requires an 11-bit CAN header: %03X", header)
        case .unexpectedECU(let ecu):
            return String(format: "UDS DTC read received an unexpected ECU: %03X", ecu)
        case .pendingWithoutFinalResponse:
            return "ECU returned response pending, but the adapter stopped before a final response"
        case .noFrames:
            return "adapter prompt contained no CAN response frames"
        case .wrongNegativeService(let service):
            return String(
                format: "negative response referred to unexpected service 0x%02X", service)
        case .duplicateFinalResponse:
            return "ECU returned more than one final UDS DTC response"
        case .adapterStatus(let status):
            return "adapter reported: \(status.description)"
        }
    }
}

/// Selects and validates the final response from one bounded adapter prompt.
public enum UDSDTCResponseSelector {
    public static func select(_ raw: String, expectedECU: UInt32) throws -> UDSDTCResponse {
        let parsed = try ELM327ResponseParser.parse(raw)
        if let status = parsed.messages.first(where: { $0 != .ok }) {
            throw UDSDTCReadError.adapterStatus(status)
        }
        guard !parsed.frames.isEmpty else { throw UDSDTCReadError.noFrames }
        let messages = try UDSMessageAssembler.assemble(parsed.frames)
        var sawPending = false
        var final: UDSDTCResponse?
        for message in messages {
            guard message.ecu == expectedECU else {
                throw UDSDTCReadError.unexpectedECU(message.ecu)
            }
            let response = try UDSDTCDecoder.decode(message.payload)
            switch response {
            case .negative(let service, .responsePending):
                guard service == 0x19 else { throw UDSDTCReadError.wrongNegativeService(service) }
                sawPending = true
            case .negative(let service, _):
                guard service == 0x19 else { throw UDSDTCReadError.wrongNegativeService(service) }
                guard final == nil else { throw UDSDTCReadError.duplicateFinalResponse }
                final = response
            case .positive:
                guard final == nil else { throw UDSDTCReadError.duplicateFinalResponse }
                final = response
            }
        }
        if let final { return final }
        if sawPending { throw UDSDTCReadError.pendingWithoutFinalResponse }
        throw UDSDTCReadError.noFrames
    }
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
