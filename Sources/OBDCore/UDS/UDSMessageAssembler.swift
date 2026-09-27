public enum UDSMessageAssemblyError: Error, Equatable, Sendable {
    case malformedFrame(ecu: UInt32)
    case truncated(ecu: UInt32)
    case sequenceGap(ecu: UInt32, expected: UInt8, got: UInt8)
    case unexpectedConsecutiveFrame(ecu: UInt32)
}

/// Reassembles an ordered stream of ISO-TP response frames into complete messages.
/// A new single or first frame closes the preceding message only when that message is complete.
public enum UDSMessageAssembler {
    public static func assemble(_ frames: [CANFrame]) throws -> [ECUResponse] {
        var active: [UInt32: PartialMessage] = [:]
        var messages: [ECUResponse] = []

        for frame in frames {
            guard let pci = frame.data.first else {
                throw UDSMessageAssemblyError.malformedFrame(ecu: frame.header)
            }
            guard frame.data.count <= 8 else {
                throw UDSMessageAssemblyError.malformedFrame(ecu: frame.header)
            }
            switch pci >> 4 {
            case 0:
                let length = Int(pci & 0x0F)
                guard (1...7).contains(length), frame.data.count >= length + 1 else {
                    throw UDSMessageAssemblyError.truncated(ecu: frame.header)
                }
                guard active[frame.header] == nil else {
                    throw UDSMessageAssemblyError.truncated(ecu: frame.header)
                }
                messages.append(
                    ECUResponse(ecu: frame.header, payload: Array(frame.data[1...length])))
            case 1:
                guard frame.data.count >= 2 else {
                    throw UDSMessageAssemblyError.malformedFrame(ecu: frame.header)
                }
                guard active[frame.header] == nil else {
                    throw UDSMessageAssemblyError.truncated(ecu: frame.header)
                }
                let length = (Int(pci & 0x0F) << 8) | Int(frame.data[1])
                guard length >= 8 else {
                    throw UDSMessageAssemblyError.malformedFrame(ecu: frame.header)
                }
                active[frame.header] = PartialMessage(
                    length: length, payload: Array(frame.data.dropFirst(2)), expectedSequence: 1)
                finishIfComplete(ecu: frame.header, active: &active, messages: &messages)
            case 2:
                guard var message = active[frame.header] else {
                    throw UDSMessageAssemblyError.unexpectedConsecutiveFrame(ecu: frame.header)
                }
                let sequence = pci & 0x0F
                guard sequence == message.expectedSequence else {
                    throw UDSMessageAssemblyError.sequenceGap(
                        ecu: frame.header, expected: message.expectedSequence, got: sequence)
                }
                guard frame.data.count >= 2 else {
                    throw UDSMessageAssemblyError.malformedFrame(ecu: frame.header)
                }
                let remaining = message.length - message.payload.count
                guard frame.data.count - 1 >= min(7, remaining) else {
                    throw UDSMessageAssemblyError.truncated(ecu: frame.header)
                }
                message.payload.append(contentsOf: frame.data.dropFirst())
                message.expectedSequence = (sequence + 1) & 0x0F
                active[frame.header] = message
                finishIfComplete(ecu: frame.header, active: &active, messages: &messages)
            default:
                throw UDSMessageAssemblyError.malformedFrame(ecu: frame.header)
            }
        }

        if let (ecu, _) = active.first {
            throw UDSMessageAssemblyError.truncated(ecu: ecu)
        }
        return messages
    }

    private struct PartialMessage {
        let length: Int
        var payload: [UInt8]
        var expectedSequence: UInt8
    }

    private static func finishIfComplete(
        ecu: UInt32, active: inout [UInt32: PartialMessage], messages: inout [ECUResponse]
    ) {
        guard let message = active[ecu], message.payload.count >= message.length else { return }
        messages.append(
            ECUResponse(ecu: ecu, payload: Array(message.payload.prefix(message.length))))
        active.removeValue(forKey: ecu)
    }
}
