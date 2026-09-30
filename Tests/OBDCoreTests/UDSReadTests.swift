import OBDCore
import Testing

@Suite("Generic UDS read selector")
struct UDSReadTests {
    @Test("generic selector retains the DTC payloads")
    func dtcPayloads() throws {
        #expect(
            try UDSResponseSelector.finalPayload(
                "4C403590200\r", expectedECU: 0x4C4, service: 0x19)
                == [0x59, 0x02, 0x00])
        #expect(
            try UDSResponseSelector.finalPayload(
                "4C402597F\r", expectedECU: 0x4C4, service: 0x19)
                == [0x59, 0x7F])
    }

    @Test("generic selector handles pending and final replies for 22 and 3E")
    func pendingAndFinal() throws {
        #expect(
            try UDSResponseSelector.finalPayload(
                "4C4037F3E78\r4C4027E00\r", expectedECU: 0x4C4, service: 0x3E)
                == [0x7E, 0x00])
        #expect(
            try UDSResponseSelector.finalPayload(
                "4C40562F1904142\r", expectedECU: 0x4C4, service: 0x22)
                == [0x62, 0xF1, 0x90, 0x41, 0x42])
        #expect(
            try UDSResponseSelector.finalPayload(
                "4C4037F2231\r", expectedECU: 0x4C4, service: 0x22)
                == [0x7F, 0x22, 0x31])
    }

    @Test("generic selector reassembles a multi-frame VIN response")
    func multiFrameIdentification() throws {
        let raw = "4C4101462F1905A414D\r4C42135375254533448\r4C42231323439393431\r"
        let payload = try UDSResponseSelector.finalPayload(
            raw, expectedECU: 0x4C4, service: 0x22)
        #expect(
            try IdentificationDecoder.decode(did: 0xF190, payload: payload).text
                == "ZAM57RTS4H1249941")
    }

    @Test("generic selector rejects wrong ECU, service, duplicates, pending-only, and no data")
    func rejectionCases() {
        #expect(throws: UDSReadError.unexpectedECU(0x4C5)) {
            try UDSResponseSelector.finalPayload(
                "4C5027E00\r", expectedECU: 0x4C4, service: 0x3E)
        }
        #expect(throws: UDSReadError.wrongNegativeService(0x22)) {
            try UDSResponseSelector.finalPayload(
                "4C4037F2278\r", expectedECU: 0x4C4, service: 0x3E)
        }
        #expect(throws: UDSReadError.duplicateFinalResponse) {
            try UDSResponseSelector.finalPayload(
                "4C4027E00\r4C4027E00\r", expectedECU: 0x4C4, service: 0x3E)
        }
        #expect(throws: UDSReadError.pendingWithoutFinalResponse) {
            try UDSResponseSelector.finalPayload(
                "4C4037F3E78\r", expectedECU: 0x4C4, service: 0x3E)
        }
        #expect(throws: UDSReadError.adapterStatus(.noData)) {
            try UDSResponseSelector.finalPayload(
                "NO DATA\r", expectedECU: 0x4C4, service: 0x3E)
        }
        #expect(throws: UDSReadError.invalidPositiveService(0x62)) {
            try UDSResponseSelector.finalPayload(
                "4C40562F1904142\r", expectedECU: 0x4C4, service: 0x3E)
        }
    }
}
