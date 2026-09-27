import OBDCore
import Testing

@Suite("UDS ISO-TP message assembler")
struct UDSMessageAssemblerTests {
    @Test("keeps pending and final messages from one ECU in wire order")
    func keepsMessagesInOrder() throws {
        let frames = [
            CANFrame(header: 0x4C4, data: [0x03, 0x7F, 0x19, 0x78]),
            CANFrame(header: 0x4C4, data: [0x10, 0x0B, 0x59, 0x02, 0xCF, 0x80, 0x01, 0x1B]),
            CANFrame(header: 0x4C4, data: [0x21, 0x8F, 0x80, 0x02, 0x1B, 0x8F]),
        ]

        let messages = try UDSMessageAssembler.assemble(frames)

        #expect(
            messages == [
                ECUResponse(ecu: 0x4C4, payload: [0x7F, 0x19, 0x78]),
                ECUResponse(
                    ecu: 0x4C4,
                    payload: [0x59, 0x02, 0xCF, 0x80, 0x01, 0x1B, 0x8F, 0x80, 0x02, 0x1B, 0x8F]),
            ])
    }

    @Test("rejects gaps, truncation, and consecutive frames without a first frame")
    func rejectsMalformedStreams() {
        #expect(throws: UDSMessageAssemblyError.sequenceGap(ecu: 0x4C4, expected: 1, got: 2)) {
            try UDSMessageAssembler.assemble([
                CANFrame(header: 0x4C4, data: [0x10, 0x08, 0x59, 0x02, 0x00, 0x80, 0x01, 0x1B]),
                CANFrame(header: 0x4C4, data: [0x22, 0, 0, 0, 0, 0, 0, 0]),
            ])
        }
        #expect(throws: UDSMessageAssemblyError.truncated(ecu: 0x4C4)) {
            try UDSMessageAssembler.assemble([
                CANFrame(header: 0x4C4, data: [0x10, 0x08, 0x59, 0x02, 0x00, 0x80, 0x01, 0x1B])
            ])
        }
        #expect(throws: UDSMessageAssemblyError.unexpectedConsecutiveFrame(ecu: 0x4C4)) {
            try UDSMessageAssembler.assemble([
                CANFrame(header: 0x4C4, data: [0x21, 0, 0, 0, 0, 0, 0, 0])
            ])
        }
    }

    @Test("rejects oversized CAN frames, short first frames, and empty consecutive frames")
    func rejectsInvalidClassicalFrames() {
        #expect(throws: UDSMessageAssemblyError.malformedFrame(ecu: 0x4C4)) {
            try UDSMessageAssembler.assemble([
                CANFrame(header: 0x4C4, data: Array(repeating: 0, count: 9))
            ])
        }
        #expect(throws: UDSMessageAssemblyError.malformedFrame(ecu: 0x4C4)) {
            try UDSMessageAssembler.assemble([
                CANFrame(header: 0x4C4, data: [0x10])
            ])
        }
        #expect(throws: UDSMessageAssemblyError.malformedFrame(ecu: 0x4C4)) {
            try UDSMessageAssembler.assemble([
                CANFrame(header: 0x4C4, data: [0x10, 0x07, 1, 2, 3, 4, 5, 6]),
                CANFrame(header: 0x4C4, data: [0x21, 7, 8, 9, 10, 11, 12, 13]),
            ])
        }
        #expect(throws: UDSMessageAssemblyError.malformedFrame(ecu: 0x4C4)) {
            try UDSMessageAssembler.assemble([
                CANFrame(header: 0x4C4, data: [0x10, 0x08, 1, 2, 3, 4, 5, 6]),
                CANFrame(header: 0x4C4, data: [0x21]),
            ])
        }
    }

    @Test("supports interleaved ECU messages and sequence wrap")
    func supportsInterleavingAndWrap() throws {
        var frames = [CANFrame(header: 0x4C4, data: [0x10, 0x80, 0x59, 2, 0, 1, 2, 3])]
        frames.append(CANFrame(header: 0x4C5, data: [0x03, 0x7F, 0x19, 0x78]))
        let sequences = Array(UInt8(1)...UInt8(15)) + [0, 1, 2]
        for sequence in sequences {
            frames.append(
                CANFrame(
                    header: 0x4C4, data: [0x20 | sequence] + Array(repeating: sequence, count: 7)))
        }
        let messages = try UDSMessageAssembler.assemble(frames)
        #expect(messages.count == 2)
        #expect(messages[0].ecu == 0x4C5)
        #expect(messages[1].ecu == 0x4C4)
    }
}
