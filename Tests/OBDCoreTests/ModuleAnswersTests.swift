import OBDCore
import Testing

@Suite("Module answer decoding")
struct ModuleAnswersTests {
    @Test("named negative response codes preserve every byte")
    func negativeCodesRoundTrip() {
        let bytes: [UInt8] = [0x11, 0x12, 0x13, 0x22, 0x31, 0x33, 0x78, 0x7E, 0x7F, 0x55]
        for byte in bytes { #expect(UDSNegativeResponseCode(byte: byte).byte == byte) }
        #expect(UDSNegativeResponseCode(byte: 0x22) == .conditionsNotCorrect)
        #expect(UDSNegativeResponseCode(byte: 0x78) == .responsePending)
    }

    @Test("TesterPresent distinguishes present, refusal, pending, and unrelated replies")
    func testerPresentReplies() {
        #expect(TesterPresentReply(payload: [0x7E, 0x00]) == .present)
        #expect(
            TesterPresentReply(payload: [0x7F, 0x3E, 0x11])
                == .refused(.serviceNotSupported))
        #expect(
            TesterPresentReply(payload: [0x7F, 0x3E, 0x7F])
                == .refused(.serviceNotSupportedInActiveSession))
        #expect(TesterPresentReply(payload: [0x7F, 0x3E, 0x78]) == .pending)
        let unrelated: [[UInt8]] = [
            [0x7F, 0x22, 0x11], [0x7E], [0x7E, 0x01], [0x62, 0xF1, 0x90],
        ]
        for payload in unrelated {
            #expect(TesterPresentReply(payload: payload) == .unrelated)
        }
        #expect(TesterPresentReply(payload: [0x7F, 0x3E, 0x11]).isModule)
        #expect(!TesterPresentReply(payload: [0x7F, 0x3E, 0x78]).isModule)
    }

    @Test("identification decodes values, text padding, and negative responses")
    func identificationValues() throws {
        let vin = Array("ZAM57RTS4H1249941".utf8)
        let reading = try IdentificationDecoder.decode(
            did: 0xF190, payload: [0x62, 0xF1, 0x90] + vin)
        #expect(reading.rawValue == vin)
        #expect(reading.text == "ZAM57RTS4H1249941")
        #expect(
            try IdentificationDecoder.decode(
                did: 0xF197, payload: [0x62, 0xF1, 0x97, 0x00, 0xFF, 0x45, 0x43, 0x4D, 0x00]
            )
            .text == "ECM")
        #expect(
            try IdentificationDecoder.decode(
                did: 0xF190, payload: [0x62, 0xF1, 0x90, 0, 0xFF, 0x20]
            ).text == nil)
        #expect(
            try IdentificationDecoder.decode(did: 0xF190, payload: [0x62, 0xF1, 0x90, 0x01, 0x7F])
                .text == nil)
        #expect(
            try IdentificationDecoder.decode(did: 0xF190, payload: [0x62, 0xF1, 0x90]).text == nil)
        #expect(
            try IdentificationDecoder.decode(did: 0xF190, payload: [0x7F, 0x22, 0x31])
                == .refused(.requestOutOfRange))
        #expect(
            try IdentificationDecoder.decode(did: 0xF190, payload: [0x7F, 0x22, 0x7F])
                == .refused(.serviceNotSupportedInActiveSession))
        #expect(
            try IdentificationDecoder.decode(did: 0xF190, payload: [0x7F, 0x22, 0x78])
                == .refused(.responsePending))
    }

    @Test("identification rejects malformed replies with typed errors")
    func identificationErrors() {
        #expect(throws: IdentificationDecodeError.tooShort) {
            try IdentificationDecoder.decode(did: 0xF190, payload: [0x62, 0xF1])
        }
        #expect(throws: IdentificationDecodeError.wrongDID(expected: 0xF190, actual: 0xF197)) {
            try IdentificationDecoder.decode(did: 0xF190, payload: [0x62, 0xF1, 0x97])
        }
        #expect(throws: IdentificationDecodeError.invalidService(0x59)) {
            try IdentificationDecoder.decode(did: 0xF190, payload: [0x59, 0x02, 0x00])
        }
        #expect(throws: IdentificationDecodeError.wrongNegativeService(0x19)) {
            try IdentificationDecoder.decode(did: 0xF190, payload: [0x7F, 0x19, 0x22])
        }
    }
}
