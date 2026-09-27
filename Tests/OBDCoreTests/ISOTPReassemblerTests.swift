import OBDCore
import Testing

@Suite("ISO-TP reassembly")
struct ISOTPReassemblerTests {
    private func frame(_ header: UInt32, _ data: [UInt8]) -> CANFrame {
        CANFrame(header: header, data: data)
    }

    @Test("single frame")
    func single() throws {
        let result = try ISOTPReassembler.reassemble([
            frame(0x7E8, [0x04, 0x41, 0x0C, 0x1A, 0xF8, 0x00, 0x00, 0x00])
        ])
        #expect(result == [ECUResponse(ecu: 0x7E8, payload: [0x41, 0x0C, 0x1A, 0xF8])])
    }

    @Test("multi-frame VIN reply, trimmed to declared length")
    func vin() throws {
        let result = try ISOTPReassembler.reassemble([
            frame(0x7E8, [0x10, 0x14, 0x49, 0x02, 0x01, 0x57, 0x50, 0x30]),
            frame(0x7E8, [0x21, 0x5A, 0x5A, 0x5A, 0x39, 0x39, 0x39, 0x5A]),
            frame(0x7E8, [0x22, 0x54, 0x53, 0x33, 0x39, 0x32, 0x31, 0x32]),
        ])
        let vin = Array("WP0ZZZ999ZTS392124".utf8).prefix(17)
        #expect(result.count == 1)
        #expect(result.first?.payload.count == 20)
        #expect(result.first?.payload == [0x49, 0x02, 0x01] + vin)
    }

    @Test("two ECUs, order of first appearance preserved")
    func twoECUs() throws {
        let result = try ISOTPReassembler.reassemble([
            frame(0x7E9, [0x04, 0x41, 0x0C, 0x00, 0x00]),
            frame(0x7E8, [0x04, 0x41, 0x0C, 0x1A, 0xF8]),
        ])
        #expect(result.map(\.ecu) == [0x7E9, 0x7E8])
    }

    @Test("sequence number wraps from F to 0")
    func sequenceWrap() throws {
        // 6 bytes in the first frame + 17 consecutive frames * 7 = 125 bytes declared.
        var frames = [frame(0x7E8, [0x10, 0x7D] + Array(repeating: 0xAA, count: 6))]
        for sequence in 1...17 {
            let pci = 0x20 | UInt8(sequence & 0x0F)
            frames.append(frame(0x7E8, [pci] + Array(repeating: UInt8(sequence), count: 7)))
        }
        let result = try ISOTPReassembler.reassemble(frames)
        #expect(result.first?.payload.count == 125)
        #expect(result.first?.payload.last == 17)
    }

    @Test("sequence gap is an error")
    func gap() {
        #expect(throws: ISOTPError.sequenceGap(ecu: 0x7E8, expected: 1, got: 2)) {
            try ISOTPReassembler.reassemble([
                frame(0x7E8, [0x10, 0x14, 0x49, 0x02, 0x01, 0x57, 0x50, 0x30]),
                frame(0x7E8, [0x22, 0x54, 0x53, 0x33, 0x39, 0x32, 0x31, 0x32]),
            ])
        }
    }

    @Test("consecutive frame without a first frame is an error")
    func missingFirst() {
        #expect(throws: ISOTPError.missingFirstFrame(ecu: 0x7E8)) {
            try ISOTPReassembler.reassemble([frame(0x7E8, [0x21, 0x01, 0x02])])
        }
    }

    @Test("fewer bytes than declared is an error")
    func truncated() {
        #expect(throws: ISOTPError.truncated(ecu: 0x7E8)) {
            try ISOTPReassembler.reassemble([
                frame(0x7E8, [0x10, 0x14, 0x49, 0x02, 0x01, 0x57, 0x50, 0x30])
            ])
        }
        #expect(throws: ISOTPError.truncated(ecu: 0x7E8)) {
            try ISOTPReassembler.reassemble([frame(0x7E8, [0x05, 0x41, 0x0C])])
        }
    }
}
