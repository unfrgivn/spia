import OBDCore
import Testing

@Suite("DTC")
struct DTCTests {
    @Test(
        "two-byte encoding",
        arguments: [
            ([0x01, 0x33], "P0133"),
            ([0x04, 0x20], "P0420"),
            ([0x41, 0x20], "C0120"),
            ([0x81, 0x12], "B0112"),
            ([0xC1, 0x05], "U0105"),
            ([0x0A, 0x10], "P0A10"),
            ([0x2A, 0xBC], "P2ABC"),
        ])
    func decodes(bytes: [UInt8], code: String) {
        #expect(DTC(bytes: bytes)?.description == code)
    }

    @Test("padding and wrong lengths are rejected")
    func rejects() {
        #expect(DTC(bytes: [0x00, 0x00]) == nil)
        #expect(DTC(bytes: [0x01]) == nil)
        #expect(DTC(bytes: [0x01, 0x33, 0x00]) == nil)
    }

    @Test(
        "round trips through the human form",
        arguments: ["P0133", "C0120", "B0112", "U0105", "P0A10"])
    func roundTrip(code: String) {
        let parsed = DTC(code: code)
        #expect(parsed?.description == code)
        #expect(parsed.flatMap { DTC(bytes: $0.bytes) } == parsed)
    }

    @Test("invalid human forms")
    func invalidCodes() {
        #expect(DTC(code: "X0133") == nil)
        #expect(DTC(code: "P4133") == nil)
        #expect(DTC(code: "P013") == nil)
        #expect(DTC(code: "P01G3") == nil)
    }

    @Test("case insensitive")
    func lowercase() {
        #expect(DTC(code: "p0a10")?.description == "P0A10")
    }
}
