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
        case 0x7F where body.count == 2:
            return .negative(
                service: OBDService(rawValue: body[0]), code: NegativeResponseCode(byte: body[1]))
        case OBDService.currentData.positiveResponseByte where body.count >= 1:
            return .currentData(
                pid: body[0], value: PIDDecoder.decode(pid: body[0], data: Array(body.dropFirst())))
        case OBDService.freezeFrame.positiveResponseByte where body.count >= 2:
            let data = Array(body.dropFirst(2))
            if body[0] == 0x02 {
                guard data.count >= 2, data.dropFirst(2).allSatisfy({ $0 == 0 }) else {
                    return .unrecognized(payload)
                }
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
            guard let codes = dtcs(afterCount: body) else { return .unrecognized(payload) }
            return .dtcs(service: service, codes: codes)
        case OBDService.clearDTCs.positiveResponseByte:
            return .cleared
        case OBDService.vehicleInfo.positiveResponseByte where body.count >= 1:
            return vehicleInfo(infoType: body[0], body: Array(body.dropFirst()))
        default:
            return .unrecognized(payload)
        }
    }

    /// On CAN the first byte is a DTC count, then two bytes per code, zero-padded.
    private static func dtcs(afterCount body: [UInt8]) -> [DTC]? {
        guard let count = body.first, body.dropFirst().count >= Int(count) * 2,
            body.dropFirst().count.isMultiple(of: 2)
        else { return nil }
        let pairs = body.dropFirst()
        let declaredEnd = pairs.index(pairs.startIndex, offsetBy: Int(count) * 2)
        guard pairs[declaredEnd...].allSatisfy({ $0 == 0 }) else { return nil }
        let codes = stride(from: pairs.startIndex, to: declaredEnd, by: 2).map { index in
            DTC(bytes: [pairs[index], pairs[index + 1]])
        }
        guard codes.allSatisfy({ $0 != nil }) else { return nil }
        return codes.compactMap { $0 }
    }

    /// Service 09 payloads all start with a count byte after the info type, then fixed-size
    /// records. VIN is the exception: one record of 17 ASCII bytes.
    private static func vehicleInfo(infoType: UInt8, body: [UInt8]) -> ServiceResponse {
        switch infoType {
        case 0x00 where body.count >= 4:
            return .supportedInfoTypes(
                PIDDecoder.supportedPIDs(base: 0, bitmap: Array(body.prefix(4))))
        case 0x02 where body.count == 18 && body[0] == 1:
            return .vin(ascii(body.dropFirst()))
        case 0x04:
            guard let records = records(body, size: 16) else {
                return .unrecognized(
                    [OBDService.vehicleInfo.positiveResponseByte, infoType] + body)
            }
            return .calibrationIDs(records.map(paddedASCII))
        case 0x06:
            guard let records = records(body, size: 4) else {
                return .unrecognized(
                    [OBDService.vehicleInfo.positiveResponseByte, infoType] + body)
            }
            return .calibrationVerificationNumbers(records.map(hex))
        case 0x0A where body.count == 21 && body[0] == 1:
            return .ecuName(ascii(body.dropFirst()))
        default:
            return .unrecognized([OBDService.vehicleInfo.positiveResponseByte, infoType] + body)
        }
    }

    private static func records(_ body: [UInt8], size: Int) -> [[UInt8]]? {
        guard let count = body.first else { return nil }
        let data = Array(body.dropFirst())
        guard data.count == Int(count) * size else { return nil }
        return stride(from: 0, to: data.count, by: size).map { start in
            Array(data[start..<start + size])
        }
    }

    private static func ascii<Bytes: Collection>(_ bytes: Bytes) -> String
    where Bytes.Element == UInt8 {
        String(decoding: bytes, as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
    }

    private static func paddedASCII(_ bytes: [UInt8]) -> String {
        ascii(bytes.filter { $0 != 0 })
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined()
    }
}
