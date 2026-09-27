import OBDCore
import Testing

@Suite("ELM327 response parser")
struct ResponseParserTests {
    @Test("11-bit frame with headers on")
    func elevenBitFrame() throws {
        let parsed = try ELM327ResponseParser.parse("7E8064100BE3EA813\r\r")
        #expect(
            parsed.frames == [
                CANFrame(header: 0x7E8, data: [0x06, 0x41, 0x00, 0xBE, 0x3E, 0xA8, 0x13])
            ])
        #expect(parsed.messages.isEmpty)
    }

    @Test("29-bit frame with headers on")
    func twentyNineBitFrame() throws {
        let parsed = try ELM327ResponseParser.parse("18DAF110064100BE3EA813")
        #expect(
            parsed.frames == [
                CANFrame(header: 0x18DA_F110, data: [0x06, 0x41, 0x00, 0xBE, 0x3E, 0xA8, 0x13])
            ])
    }

    @Test("spaces and SEARCHING banner are tolerated")
    func tolerant() throws {
        let parsed = try ELM327ResponseParser.parse("SEARCHING...\r7E8 06 41 00 BE 3E A8 13\r")
        #expect(parsed.frames.count == 1)
        #expect(parsed.frames.first?.header == 0x7E8)
    }

    @Test("two ECUs answer the same request")
    func twoECUs() throws {
        let parsed = try ELM327ResponseParser.parse("7E804410C1AF8\r7E904410C1AF8\r")
        #expect(parsed.frames.map(\.header) == [0x7E8, 0x7E9])
    }

    @Test("status lines become typed messages, not frames")
    func statusLines() throws {
        let parsed = try ELM327ResponseParser.parse("SEARCHING...\rUNABLE TO CONNECT\r")
        #expect(parsed.frames.isEmpty)
        #expect(parsed.messages == [.unableToConnect])
    }

    @Test(
        "adapter message strings",
        arguments: [
            ("OK", ELM327AdapterMessage.ok),
            ("?", .unknownCommand),
            ("NO DATA", .noData),
            ("CAN ERROR", .canError),
            ("BUS INIT: ...ERROR", .busInitError),
            ("BUFFER FULL", .bufferFull),
            ("<DATA ERROR", .dataError),
            ("STOPPED", .stopped),
            ("LV RESET", .lowVoltageReset),
        ])
    func messages(line: String, expected: ELM327AdapterMessage) {
        #expect(ELM327AdapterMessage(line: line) == expected)
    }

    @Test("garbage is an error, not a silent skip")
    func garbage() {
        #expect(throws: ELM327ParseError.malformedLine("7E8G6")) {
            try ELM327ResponseParser.parse("7E8G6")
        }
    }
}
