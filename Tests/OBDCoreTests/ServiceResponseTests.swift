import OBDCore
import Testing

@Suite("Service response decoding")
struct ServiceResponseTests {
    @Test("negative response")
    func negative() {
        #expect(
            ServiceResponse.decode([0x7F, 0x03, 0x11])
                == .negative(service: .storedDTCs, code: .serviceNotSupported))
        #expect(
            ServiceResponse.decode([0x7F, 0x22, 0x31])
                == .negative(service: nil, code: .requestOutOfRange))
    }

    @Test("service 01 current data")
    func currentData() {
        #expect(
            ServiceResponse.decode([0x41, 0x0C, 0x1A, 0xF8])
                == .currentData(pid: 0x0C, value: .rpm(1726)))
    }

    @Test("service 02 freeze frame")
    func freezeFrame() {
        #expect(
            ServiceResponse.decode([0x42, 0x05, 0x00, 0x7B])
                == .freezeFrame(pid: 0x05, frame: 0, value: .celsius(83)))
        #expect(
            ServiceResponse.decode([0x42, 0x02, 0x00, 0x01, 0x33])
                == .freezeFrameDTC(frame: 0, dtc: DTC(code: "P0133")))
        #expect(
            ServiceResponse.decode([0x42, 0x02, 0x00, 0x00, 0x00])
                == .freezeFrameDTC(frame: 0, dtc: nil))
    }

    @Test("service 03/07/0A DTC lists")
    func dtcs() {
        #expect(
            ServiceResponse.decode([0x43, 0x02, 0x01, 0x33, 0x04, 0x20])
                == .dtcs(
                    service: .storedDTCs,
                    codes: [DTC(code: "P0133"), DTC(code: "P0420")].compactMap { $0 }))
        #expect(ServiceResponse.decode([0x43, 0x00]) == .dtcs(service: .storedDTCs, codes: []))
        #expect(
            ServiceResponse.decode([0x47, 0x01, 0x01, 0x71, 0x00, 0x00])
                == .dtcs(service: .pendingDTCs, codes: [DTC(code: "P0171")].compactMap { $0 }))
        #expect(
            ServiceResponse.decode([0x4A, 0x01, 0x04, 0x20])
                == .dtcs(service: .permanentDTCs, codes: [DTC(code: "P0420")].compactMap { $0 }))
    }

    @Test("service 04 clear")
    func cleared() {
        #expect(ServiceResponse.decode([0x44]) == .cleared)
    }

    @Test("service 09 VIN")
    func vin() {
        let vin = Array("ZAM57RTA1H1234567".utf8)
        #expect(ServiceResponse.decode([0x49, 0x02, 0x01] + vin) == .vin("ZAM57RTA1H1234567"))
    }

    @Test("service 09 calibration IDs, 16-byte records with null padding")
    func calibrationIDs() {
        let first = Array("CAL12345".utf8) + Array(repeating: UInt8(0), count: 8)
        let second = Array("0123456789ABCDEF".utf8)
        #expect(
            ServiceResponse.decode([0x49, 0x04, 0x02] + first + second)
                == .calibrationIDs(["CAL12345", "0123456789ABCDEF"]))
    }

    @Test("service 09 CVNs as hex")
    func cvns() {
        #expect(
            ServiceResponse.decode([
                0x49, 0x06, 0x02, 0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x11, 0x22, 0x33,
            ])
                == .calibrationVerificationNumbers(["DEADBEEF", "00112233"]))
    }

    @Test("service 09 ECU name and supported info types")
    func ecuNameAndSupport() {
        #expect(
            ServiceResponse.decode(
                [0x49, 0x0A, 0x01] + Array("ECM".utf8) + Array(repeating: UInt8(0), count: 17))
                == .ecuName("ECM\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0"))
        #expect(
            ServiceResponse.decode([0x49, 0x00, 0x55, 0x40, 0x00, 0x00])
                == .supportedInfoTypes([0x02, 0x04, 0x06, 0x08, 0x0A]))
    }

    @Test("unknown payloads are preserved, not dropped")
    func unrecognized() {
        #expect(ServiceResponse.decode([0x62, 0xF1, 0x90]) == .unrecognized([0x62, 0xF1, 0x90]))
        #expect(ServiceResponse.decode([]) == .unrecognized([]))
    }
}
