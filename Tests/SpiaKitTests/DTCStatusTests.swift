import Testing

@testable import SpiaKit

@Suite("DTC status bytes in plain English")
struct DTCStatusTests {
    @Test("status bytes read as one line of what's wrong now")
    func summary() {
        // The body computer's code on the Ghibli: 0x2B, with 0xFB supported.
        #expect(DTCStatus.summary(for: 0x2B, availability: 0xFB) == "Failing now · Confirmed")
        #expect(DTCStatus.summary(for: 0x06) == "Failed this drive cycle · Pending")
        #expect(
            DTCStatus.summary(for: 0x89) == "Failing now · Confirmed · Warning lamp requested")
        #expect(DTCStatus.summary(for: 0x50) == "Not active now")
    }

    @Test("only the flags a module supports count")
    func availability() {
        #expect(DTCStatus.flags(for: 0x89, availability: 0x09).map(\.bit) == [0x01, 0x08])
        #expect(DTCStatus.summary(for: 0x80, availability: 0x7F) == "Not active now")
    }
}
