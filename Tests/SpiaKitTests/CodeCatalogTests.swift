import SpiaKit
import Testing

@Suite("Generic code catalog")
struct CodeCatalogTests {
    @Test("bundled OBDex data is present")
    func catalog() throws {
        let catalog = try CodeCatalog.bundled()
        let b0001Name = try #require(CodeName("B0001"))
        let b0001 = try #require(catalog.entry(for: b0001Name))
        #expect(b0001.title == "Driver Frontal Stage 1 Deployment Control")
        #expect(b0001.causes.count == 3)
        #expect(b0001.causes[0].localizedCaseInsensitiveContains("clock spring"))
        let p0133Name = try #require(CodeName("P0133"))
        let p0133 = try #require(catalog.entry(for: p0133Name))
        #expect(p0133.title.hasPrefix("O2 Sensor Slow Response"))
        let p1009Name = try #require(CodeName("P1009"))
        #expect(catalog.entry(for: p1009Name) == nil)
        #expect(catalog.count == 9533)
        #expect(catalog.source.commit.hasPrefix("bc58b0e"))
    }
}
