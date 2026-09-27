import OBDCore
import Testing

@Suite("Requests and transcript format")
struct RequestAndTranscriptTests {
    @Test(
        "request hex",
        arguments: [
            (OBDRequest(service: .currentData, pid: 0x0C), "010C"),
            (OBDRequest(service: .storedDTCs), "03"),
            (OBDRequest(service: .vehicleInfo, pid: 0x02), "0902"),
            (OBDRequest(service: .freezeFrame, pid: 0x02, frame: 0x00), "020200"),
            (OBDRequest(raw: [0x22, 0xF1, 0x90]), "22F190"),
        ])
    func requestHex(request: OBDRequest, hex: String) {
        #expect(request.hex == hex)
    }

    @Test("transcript line round trip")
    func transcriptRoundTrip() throws {
        let event = TranscriptEvent(
            milliseconds: 1234, direction: .rx, bytes: Array("OK\r\r>".utf8))
        let line = Transcript.encode(event)
        #expect(line == "1234 RX 4F4B0D0D3E")
        #expect(try Transcript.decode(line) == event)
    }

    @Test("empty payload encodes and decodes")
    func emptyPayload() throws {
        let event = TranscriptEvent(milliseconds: 0, direction: .tx, bytes: [])
        #expect(try Transcript.decode(Transcript.encode(event)) == event)
    }

    @Test(
        "malformed lines are rejected",
        arguments: ["", "abc TX 00", "1 XX 00", "1 TX 0", "1 TX ZZ", "1 TX"])
    func malformed(line: String) {
        #expect(throws: TranscriptError.malformedLine(line)) {
            try Transcript.decode(line)
        }
    }

    @Test("protocol digits")
    func protocolDigits() {
        #expect(ELM327Protocol(commandDigit: "6") == .can11bit500k)
        #expect(ELM327Protocol(commandDigit: "a") == .j1939)
        #expect(ELM327Protocol(commandDigit: "D") == nil)
        #expect(ELM327Protocol.can29bit250k.commandDigit == "9")
    }
}
