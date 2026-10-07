import SpiaKit
import Testing

@Suite("Code names")
struct CodeNameTests {
    @Test("UDS codes use SAE printing")
    func uds() throws {
        let name = try #require(CodeName("80011B"))
        #expect(name.printed == "B0001-1B")
        #expect(name.system == .body)
        #expect(name.isGeneric)
        #expect(name.failureType == 0x1B)
    }

    @Test("UDS systems and manufacturer ranges are classified")
    func systems() throws {
        let powertrain = try #require(CodeName("100900"))
        #expect(powertrain.printed == "P1009-00")
        #expect(powertrain.system == .powertrain)
        #expect(!powertrain.isGeneric)
        let network = try #require(CodeName("D00800"))
        #expect(network.printed == "U1008-00")
        #expect(network.system == .network)
        #expect(!network.isGeneric)
    }

    @Test("J1979 generic ranges are classified")
    func j1979() throws {
        #expect(try #require(CodeName("P0133")).isGeneric)
        #expect(try #require(CodeName("P0133")).failureType == nil)
        #expect(!(try #require(CodeName("P1234"))).isGeneric)
        #expect(try #require(CodeName("P3400")).isGeneric)
        #expect(!(try #require(CodeName("P3100"))).isGeneric)
        #expect(try #require(CodeName("U3000")).isGeneric)
    }

    @Test("input is case insensitive and malformed codes are rejected")
    func validation() throws {
        let lowercase = try #require(CodeName("80011b"))
        let uppercase = try #require(CodeName("80011B"))
        #expect(lowercase.printed == uppercase.printed)
        #expect(lowercase.base == uppercase.base)
        #expect(lowercase.failureType == uppercase.failureType)
        #expect(CodeName("80011") == nil)
        #expect(CodeName("ZZZZZZ") == nil)
        #expect(CodeName("P01") == nil)
        #expect(CodeName("") == nil)
    }
}
