import OBDCore
import Testing

@Suite("Monitor stream parser")
struct MonitorStreamParserTests {
    @Test("unterminated input is bounded and malformed CAN shapes stay unparsable")
    func rejectsUnboundedMalformedInput() {
        var parser = MonitorStreamParser()
        let events = parser.feed(Array(String(repeating: "F", count: 10_000).utf8))

        #expect(events.count == 1)
        #expect(
            events.first.map { event in
                if case .unparsable = event { true } else { false }
            } == true)
        #expect(parser.feed(Array("\r".utf8)).isEmpty)
        #expect(
            parser.feed(Array("123456789012345678901\r".utf8))
                == [.unparsable("123456789012345678901")])
    }

    @Test("a frame split across two reads is reassembled")
    func straddlingReads() {
        var parser = MonitorStreamParser()
        #expect(parser.feed(Array("10280011223".utf8)).isEmpty)
        #expect(
            parser.feed(Array("34455667\r10C".utf8)) == [
                .frame(
                    CANFrame(header: 0x102, data: [0x80, 0x01, 0x12, 0x23, 0x34, 0x45, 0x56, 0x67]))
            ])
        #expect(
            parser.feed(Array("0000\r".utf8)) == [.frame(CANFrame(header: 0x10C, data: [0, 0]))])
    }

    @Test("status lines, garbage, and the prompt are typed separately")
    func mixedLines() {
        var parser = MonitorStreamParser()
        let events = parser.feed(Array("BUFFER FULL\r<RX ERROR\r7E80\rSTOPPED\r\r>".utf8))
        #expect(
            events == [
                .message(.bufferFull), .message(.receiveError), .unparsable("7E80"),
                .message(.stopped), .prompt,
            ])
    }

    @Test("a raw broadcast frame tagged <DATA ERROR keeps the frame and reports the tag")
    func dataErrorSuffix() {
        var parser = MonitorStreamParser()
        #expect(
            parser.feed(Array("14C8000809079<DATA ERROR\r".utf8)) == [
                .frame(CANFrame(header: 0x14C, data: [0x80, 0x00, 0x80, 0x90, 0x79])),
                .message(.dataError),
            ])
    }

    @Test("29-bit frames are recognised by even digit count")
    func extendedFrame() {
        var parser = MonitorStreamParser()
        #expect(
            parser.feed(Array("18DAF110064100BE3EA813\r".utf8)) == [
                .frame(
                    CANFrame(header: 0x18DA_F110, data: [0x06, 0x41, 0x00, 0xBE, 0x3E, 0xA8, 0x13]))
            ])
    }

    @Test("empty reads and bare line endings produce nothing")
    func noise() {
        var parser = MonitorStreamParser()
        #expect(parser.feed([]).isEmpty)
        #expect(parser.feed(Array("\r\n\r".utf8)).isEmpty)
    }
}

@Suite("Capture summary")
struct CaptureSummaryTests {
    @Test("rate, length and changing bytes per ID")
    func perID() {
        var summary = CaptureSummary()
        summary.record(CANFrame(header: 0x102, data: [0x00, 0x10, 0xFF]), at: .zero)
        summary.record(CANFrame(header: 0x2F9, data: [0xAA]), at: .milliseconds(30))
        summary.record(CANFrame(header: 0x102, data: [0x01, 0x10, 0xFF]), at: .milliseconds(100))
        summary.record(CANFrame(header: 0x102, data: [0x02, 0x10, 0xFE]), at: .milliseconds(200))

        #expect(summary.frameCount == 4)
        let rows = summary.rows
        #expect(rows.map(\.id) == [0x102, 0x2F9])
        #expect(rows[0].count == 3)
        #expect(rows[0].hertz.map { abs($0 - 10) < 0.001 } == true)
        #expect(rows[0].lengths == [3])
        #expect(rows[0].changingBytes == [0, 2])
        #expect(rows[0].last == [0x02, 0x10, 0xFE])
        #expect(rows[1].hertz == nil)
        #expect(rows[1].changingBytes.isEmpty)
    }

    @Test("a payload that grows marks the new bytes as changing")
    func variableLength() {
        var summary = CaptureSummary()
        summary.record(CANFrame(header: 0x10, data: [0x01]), at: .zero)
        summary.record(CANFrame(header: 0x10, data: [0x01, 0x02]), at: .seconds(1))
        let row = summary.rows[0]
        #expect(row.lengths == [1, 2])
        #expect(row.changingBytes == [1])
    }
}

@Suite("Diagnostic receive filters")
struct DiagnosticReceiveFilterTests {
    @Test("window rejects reversed, overflowing, and overflow-prone bounds")
    func validatesWindowBounds() {
        #expect(throws: DiagnosticAddressError.self) {
            try ReceiveFilter.window(covering: 0x7E8, 0x7E0)
        }
        #expect(throws: DiagnosticAddressError.self) {
            try ReceiveFilter.window(covering: 0x7E8, 0x800)
        }
        #expect(
            (try? ReceiveFilter.window(covering: 0x7E8, 0x7EF))
                == .window(mask: 0x7F8, pattern: 0x7E8))
    }
}
