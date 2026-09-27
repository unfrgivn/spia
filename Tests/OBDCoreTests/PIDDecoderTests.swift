import OBDCore
import Testing

@Suite("PID decoder (SAE J1979)")
struct PIDDecoderTests {
    @Test("PID 00 support bitmap")
    func supportBitmap() {
        // BE 3E A8 13 = 1011 1110  0011 1110  1010 1000  0001 0011
        let expected: Set<UInt8> = [
            0x01, 0x03, 0x04, 0x05, 0x06, 0x07,
            0x0B, 0x0C, 0x0D, 0x0E, 0x0F,
            0x11, 0x13, 0x15,
            0x1C, 0x1F, 0x20,
        ]
        #expect(
            PIDDecoder.decode(pid: 0x00, data: [0xBE, 0x3E, 0xA8, 0x13]) == .supported(expected))
    }

    @Test("PID 20 bitmap offsets from 0x20")
    func supportBitmapOffset() {
        #expect(
            PIDDecoder.decode(pid: 0x20, data: [0x80, 0x00, 0x00, 0x01])
                == .supported([0x21, 0x40]))
    }

    @Test("PID 01 monitor status, spark ignition")
    func monitorStatusSpark() {
        let value = PIDDecoder.decode(pid: 0x01, data: [0x81, 0x07, 0x65, 0x04])
        let expected = MonitorStatus(
            milOn: true, dtcCount: 1, ignition: .spark,
            complete: [
                .misfire: true, .fuelSystem: true, .components: true,
                .catalyst: true, .evaporativeSystem: false,
                .oxygenSensor: true, .oxygenSensorHeater: true,
            ])
        #expect(value == .monitorStatus(expected))
    }

    @Test("PID 01 monitor status, compression ignition")
    func monitorStatusCompression() {
        let value = PIDDecoder.decode(pid: 0x01, data: [0x00, 0x0F, 0x41, 0x01])
        let expected = MonitorStatus(
            milOn: false, dtcCount: 0, ignition: .compression,
            complete: [
                .misfire: true, .fuelSystem: true, .components: true,
                .nmhcCatalyst: false, .pmFilter: true,
            ])
        #expect(value == .monitorStatus(expected))
    }

    @Test(
        "single-byte formulas",
        arguments: [
            (UInt8(0x04), [UInt8(0xFF)], PIDValue.percent(100)),
            (0x05, [0x7B], .celsius(83)),
            (0x06, [0x80], .percent(0)),
            (0x07, [0x00], .percent(-100)),
            (0x0B, [0x65], .kilopascals(101)),
            (0x0D, [0x3C], .kilometersPerHour(60)),
            (0x0E, [0x80], .degrees(0)),
            (0x0E, [0x00], .degrees(-64)),
            (0x0F, [0x28], .celsius(0)),
            (0x11, [0x00], .percent(0)),
            (0x1C, [0x06], .obdStandard(.eobd)),
            (0x1C, [0x63], .obdStandard(.other(0x63))),
            (0x2F, [0xFF], .percent(100)),
            (0x33, [0x64], .kilopascals(100)),
            (0x46, [0x54], .celsius(44)),
            (0x5C, [0x8C], .celsius(100)),
        ])
    func singleByte(pid: UInt8, data: [UInt8], expected: PIDValue) {
        #expect(PIDDecoder.decode(pid: pid, data: data) == expected)
    }

    @Test(
        "two-byte formulas",
        arguments: [
            (UInt8(0x0C), [UInt8(0x1A), 0xF8], PIDValue.rpm(1726)),
            (0x10, [0x01, 0xF4], .gramsPerSecond(5)),
            (0x1F, [0x0E, 0x10], .seconds(3600)),
            (0x21, [0x00, 0x2A], .kilometers(42)),
            (0x42, [0x36, 0xB0], .volts(14)),
            (0x5E, [0x00, 0xC8], .litersPerHour(10)),
        ])
    func twoByte(pid: UInt8, data: [UInt8], expected: PIDValue) {
        #expect(PIDDecoder.decode(pid: pid, data: data) == expected)
    }

    @Test("short payloads fall back to raw rather than inventing a value")
    func shortPayload() {
        #expect(PIDDecoder.decode(pid: 0x0C, data: [0x1A]) == .raw([0x1A]))
        #expect(PIDDecoder.decode(pid: 0x00, data: [0xBE, 0x3E]) == .raw([0xBE, 0x3E]))
        #expect(PIDDecoder.decode(pid: 0x01, data: []) == .raw([]))
    }

    @Test("unknown PIDs are raw")
    func unknown() {
        #expect(PIDDecoder.decode(pid: 0xFE, data: [0x01, 0x02]) == .raw([0x01, 0x02]))
    }

    @Test("every decoded PID has a descriptor")
    func descriptors() {
        let decoded: [UInt8] = [
            0x00, 0x01, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10,
            0x11, 0x1C, 0x1F, 0x20, 0x21, 0x2F, 0x33, 0x40, 0x42, 0x46, 0x5C, 0x5E, 0x60, 0x80,
            0xA0, 0xC0,
        ]
        for pid in decoded {
            #expect(PIDDescriptor.table[pid] != nil, "missing descriptor for \(pid)")
        }
    }
}
