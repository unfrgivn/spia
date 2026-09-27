/// SAE J1979 service 01/02 PID formulas.
public enum PIDDecoder {
    /// The PIDs that answer with a 4-byte "next 32 PIDs supported" bitmap.
    public static let supportBitmapPIDs: Set<UInt8> = [0x00, 0x20, 0x40, 0x60, 0x80, 0xA0, 0xC0]

    public static func decode(pid: UInt8, data: [UInt8]) -> PIDValue {
        if supportBitmapPIDs.contains(pid) {
            guard data.count >= 4 else {
                return .raw(data)
            }
            return .supported(supportedPIDs(base: pid, bitmap: Array(data.prefix(4))))
        }
        if pid == 0x01 {
            guard data.count >= 4 else {
                return .raw(data)
            }
            return .monitorStatus(monitorStatus(data))
        }

        guard let a = data.first else {
            return .raw(data)
        }
        let ab: Int? = data.count >= 2 ? (Int(a) << 8) | Int(data[1]) : nil

        switch pid {
        case 0x04, 0x11, 0x2F:
            return .percent(Double(a) * 100 / 255)
        case 0x05, 0x0F, 0x46, 0x5C:
            return .celsius(Double(a) - 40)
        case 0x06...0x09:
            return .percent((Double(a) - 128) * 100 / 128)
        case 0x0B, 0x33:
            return .kilopascals(Double(a))
        case 0x0D:
            return .kilometersPerHour(Double(a))
        case 0x0E:
            return .degrees(Double(a) / 2 - 64)
        case 0x1C:
            return .obdStandard(OBDStandard(byte: a))
        default:
            break
        }

        guard let ab else {
            return .raw(data)
        }
        switch pid {
        case 0x0C: return .rpm(Double(ab) / 4)
        case 0x10: return .gramsPerSecond(Double(ab) / 100)
        case 0x1F: return .seconds(UInt32(ab))
        case 0x21: return .kilometers(UInt32(ab))
        case 0x42: return .volts(Double(ab) / 1000)
        case 0x5E: return .litersPerHour(Double(ab) / 20)
        default: return .raw(data)
        }
    }

    /// Bit 7 of byte A is `base + 1`, bit 0 of byte D is `base + 32`.
    static func supportedPIDs(base: UInt8, bitmap: [UInt8]) -> Set<UInt8> {
        var result = Set<UInt8>()
        for (byteIndex, byte) in bitmap.enumerated() {
            for bit in 0..<8 where byte & (0x80 >> bit) != 0 {
                result.insert(base + UInt8(byteIndex * 8 + bit + 1))
            }
        }
        return result
    }

    /// PID 01 layout:
    ///
    /// ```
    /// A: bit 7 MIL, bits 0-6 DTC count
    /// B: bits 0-2 misfire/fuel/components available, bit 3 = compression ignition,
    ///    bits 4-6 same three monitors INCOMPLETE
    /// C: ignition-specific monitors available (bit n)
    /// D: same monitors INCOMPLETE (bit n)
    /// ```
    static func monitorStatus(_ data: [UInt8]) -> MonitorStatus {
        let (a, b, c, d) = (data[0], data[1], data[2], data[3])
        let ignition: IgnitionType = b & 0x08 == 0 ? .spark : .compression
        var complete: [Monitor: Bool] = [:]

        let common: [Monitor] = [.misfire, .fuelSystem, .components]
        for (bit, monitor) in common.enumerated() where b & (1 << bit) != 0 {
            complete[monitor] = b & (1 << (bit + 4)) == 0
        }

        let specific: [Monitor?] =
            ignition == .spark
            ? [
                .catalyst, .heatedCatalyst, .evaporativeSystem, .secondaryAirSystem,
                .acRefrigerant, .oxygenSensor, .oxygenSensorHeater, .egrOrVVT,
            ]
            : [
                .nmhcCatalyst, .noxScrMonitor, nil, .boostPressure,
                nil, .exhaustGasSensor, .pmFilter, .egrOrVVT,
            ]
        for (bit, monitor) in specific.enumerated() {
            guard let monitor, c & (1 << bit) != 0 else {
                continue
            }
            complete[monitor] = d & (1 << bit) == 0
        }

        return MonitorStatus(
            milOn: a & 0x80 != 0, dtcCount: a & 0x7F, ignition: ignition, complete: complete)
    }
}
