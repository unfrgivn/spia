import Foundation

/// A decoded positive or negative reply from one ECU.
public enum ServiceResponse: Sendable, Equatable {
    case negative(service: OBDService?, code: NegativeResponseCode)
    case currentData(pid: UInt8, value: PIDValue)
    case freezeFrame(pid: UInt8, frame: UInt8, value: PIDValue)
    /// Freeze frame PID 02: the DTC that caused the frame to be stored. Nil when none.
    case freezeFrameDTC(frame: UInt8, dtc: DTC?)
    case dtcs(service: OBDService, codes: [DTC])
    case cleared
    case vin(String)
    case calibrationIDs([String])
    case calibrationVerificationNumbers([String])
    case ecuName(String)
    case supportedInfoTypes(Set<UInt8>)
    case unrecognized([UInt8])

    public static func decode(_ payload: [UInt8]) -> ServiceResponse {
        guard let first = payload.first else {
            return .unrecognized(payload)
        }
        let body = Array(payload.dropFirst())

        switch first {
        case 0x7F where body.count >= 2:
            return .negative(
                service: OBDService(rawValue: body[0]), code: NegativeResponseCode(byte: body[1]))
        case OBDService.currentData.positiveResponseByte where body.count >= 1:
            return .currentData(
                pid: body[0], value: PIDDecoder.decode(pid: body[0], data: Array(body.dropFirst())))
        case OBDService.freezeFrame.positiveResponseByte where body.count >= 2:
            let data = Array(body.dropFirst(2))
            if body[0] == 0x02 {
                return .freezeFrameDTC(frame: body[1], dtc: DTC(bytes: Array(data.prefix(2))))
            }
            return .freezeFrame(
                pid: body[0], frame: body[1], value: PIDDecoder.decode(pid: body[0], data: data))
        case OBDService.storedDTCs.positiveResponseByte,
            OBDService.pendingDTCs.positiveResponseByte,
            OBDService.permanentDTCs.positiveResponseByte:
            guard let service = OBDService(rawValue: first & ~0x40) else {
                return .unrecognized(payload)
            }
            return .dtcs(service: service, codes: dtcs(afterCount: body))
        case OBDService.clearDTCs.positiveResponseByte:
            return .cleared
        case OBDService.vehicleInfo.positiveResponseByte where body.count >= 1:
            return vehicleInfo(infoType: body[0], body: Array(body.dropFirst()))
        default:
            return .unrecognized(payload)
        }
    }

    /// On CAN the first byte is a DTC count, then two bytes per code, zero-padded.
    private static func dtcs(afterCount body: [UInt8]) -> [DTC] {
        let pairs = body.dropFirst()
        return stride(from: pairs.startIndex, to: pairs.endIndex - 1, by: 2).compactMap { index in
            DTC(bytes: [pairs[index], pairs[index + 1]])
        }
    }

    /// Service 09 payloads all start with a count byte after the info type, then fixed-size
    /// records. VIN is the exception: one record of 17 ASCII bytes.
    private static func vehicleInfo(infoType: UInt8, body: [UInt8]) -> ServiceResponse {
        switch infoType {
        case 0x00 where body.count >= 4:
            return .supportedInfoTypes(
                PIDDecoder.supportedPIDs(base: 0, bitmap: Array(body.prefix(4))))
        case 0x02:
            return .vin(ascii(body.dropFirst()))
        case 0x04:
            return .calibrationIDs(records(body, size: 16).map(ascii))
        case 0x06:
            return .calibrationVerificationNumbers(records(body, size: 4).map(hex))
        case 0x0A:
            return .ecuName(ascii(body.dropFirst()))
        default:
            return .unrecognized([OBDService.vehicleInfo.positiveResponseByte, infoType] + body)
        }
    }

    private static func records(_ body: [UInt8], size: Int) -> [[UInt8]] {
        let data = Array(body.dropFirst())
        return stride(from: 0, to: data.count, by: size).map { start in
            Array(data[start..<min(start + size, data.count)])
        }
    }

    private static func ascii<Bytes: Sequence>(_ bytes: Bytes) -> String
    where Bytes.Element == UInt8 {
        String(decoding: bytes.filter { $0 != 0 }, as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined()
    }
}
