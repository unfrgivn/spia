import SpiaKit
import Testing

@Suite("Failure types")
struct FailureTypeTests {
    @Test("common failure types are described in Spia's words")
    func meanings() throws {
        #expect(FailureType.meaning(of: 0x1B)?.contains("resistance") == true)
        #expect(FailureType.meaning(of: 0x1B)?.contains("too high") == true)
        #expect(FailureType.meaning(of: 0x11)?.contains("ground") == true)
        #expect(FailureType.meaning(of: 0x13)?.contains("open") == true)
        #expect(FailureType.meaning(of: 0x00) != nil)
        #expect(FailureType.meaning(of: 0xE7) == nil)
        #expect(FailureType.label(for: 0xE7) == "E7")
    }

    @Test("code names expose their failure type label only for UDS codes")
    func codeLabels() throws {
        #expect(try #require(CodeName("80011B")).failureTypeLabel?.hasPrefix("1B: ") == true)
        #expect(try #require(CodeName("P0133")).failureTypeLabel == nil)
    }
}
