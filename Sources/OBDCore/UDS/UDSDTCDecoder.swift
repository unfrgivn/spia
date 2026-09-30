public struct UDSDTCRecord: Equatable, Sendable {
    public let code: [UInt8]
    public let status: UInt8

    public init(code: [UInt8], status: UInt8) {
        self.code = code
        self.status = status
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

public enum UDSReadError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidHeader(UInt32)
    case invalidLength
    case unexpectedECU(UInt32)
    case pendingWithoutFinalResponse
    case noFrames
    case wrongNegativeService(UInt8)
    case duplicateFinalResponse
    case adapterStatus(ELM327AdapterMessage)
    case invalidPositiveService(UInt8)

    public var description: String {
        switch self {
        case .invalidHeader(let header):
            return String(format: "UDS read requires an 11-bit CAN header: %03X", header)
        case .invalidLength:
            return "UDS response had an invalid length"
        case .unexpectedECU(let ecu):
            return String(format: "UDS read received an unexpected ECU: %03X", ecu)
        case .pendingWithoutFinalResponse:
            return "ECU returned response pending, but the adapter stopped before a final response"
        case .noFrames:
            return "adapter prompt contained no CAN response frames"
        case .wrongNegativeService(let service):
            return String(
                format: "negative response referred to unexpected service 0x%02X", service)
        case .duplicateFinalResponse:
            return "ECU returned more than one final UDS response"
        case .adapterStatus(let status):
            return "adapter reported: \(status.description)"
        case .invalidPositiveService(let service):
            return String(format: "positive response used unexpected service 0x%02X", service)
        }
    }
}

/// Selects and validates the final response from one bounded adapter prompt.
public enum UDSResponseSelector {
    public static func finalPayload(
        _ raw: String, expectedECU: UInt32, service: UInt8
    ) throws -> [UInt8] {
        let parsed = try ELM327ResponseParser.parse(raw)
        if let status = parsed.messages.first(where: { $0 != .ok }) {
            throw UDSReadError.adapterStatus(status)
        }
        guard !parsed.frames.isEmpty else { throw UDSReadError.noFrames }
        let messages = try UDSMessageAssembler.assemble(parsed.frames)
        var sawPending = false
        var final: [UInt8]?
        for message in messages {
            guard message.ecu == expectedECU else {
                throw UDSReadError.unexpectedECU(message.ecu)
            }
            let payload = message.payload
            if payload.first == 0x7F {
                guard payload.count == 3 else { throw UDSReadError.invalidLength }
                guard payload[1] == service else {
                    throw UDSReadError.wrongNegativeService(payload[1])
                }
                if payload[2] == 0x78 {
                    sawPending = true
                } else {
                    guard final == nil else { throw UDSReadError.duplicateFinalResponse }
                    final = payload
                }
            } else {
                guard payload.first == service &+ 0x40 else {
                    throw UDSReadError.invalidPositiveService(payload.first ?? 0)
                }
                guard final == nil else { throw UDSReadError.duplicateFinalResponse }
                final = payload
            }
        }
        if let final { return final }
        if sawPending { throw UDSReadError.pendingWithoutFinalResponse }
        throw UDSReadError.noFrames
    }
}

public enum UDSDTCResponseSelector {
    public static func select(_ raw: String, expectedECU: UInt32) throws -> UDSDTCResponse {
        try UDSDTCDecoder.decode(
            UDSResponseSelector.finalPayload(raw, expectedECU: expectedECU, service: 0x19))
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
