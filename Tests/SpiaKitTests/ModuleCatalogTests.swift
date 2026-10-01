import Foundation
import SpiaKit
import Testing

@Suite("Module catalog")
struct ModuleCatalogTests {
    private struct VPIC: Decodable {
        struct Result: Decodable {
            let make: String
            let model: String
            let modelYear: String

            enum CodingKeys: String, CodingKey {
                case make = "Make", model = "Model", modelYear = "ModelYear"
            }
        }
        let results: [Result]

        enum CodingKeys: String, CodingKey { case results = "Results" }
    }

    private func catalog() throws -> ModuleCatalog { try ModuleCatalog.bundled() }

    private func vPICVehicle() throws -> CatalogVehicle {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/nhtsa-vpic-ZAM57RTS4H1249941.json")
        let value = try #require(
            JSONDecoder().decode(VPIC.self, from: Data(contentsOf: url)).results.first)
        return CatalogVehicle(
            make: value.make, model: value.model, year: try #require(Int(value.modelYear)))
    }

    @Test("the bundled catalog validates every real module")
    func bundledCatalog() throws {
        let catalog = try catalog()
        #expect(catalog.schemaVersion == 1)
        #expect(catalog.catalogVersion == "2026.10.01+opendbc-f1e707b")
        // Spia's Maserati and Volkswagen, then opendbc's 27 makes, Volkswagen among them.
        #expect(catalog.makes.count == 28)
        #expect(catalog.makes.prefix(2).map(\.make) == ["Maserati", "Volkswagen"])
        #expect(catalog.makes.first { $0.make == "Volkswagen" }?.platforms[0].modules.count == 19)
        for make in catalog.makes {
            for platform in make.platforms {
                #expect(platform.modules.allSatisfy { $0.target.request != 0x7DF })
                #expect(Set(platform.modules.map(\.target)).count == platform.modules.count)
            }
        }
    }

    @Test("real vehicle spellings match only their bounded platforms")
    func matching() throws {
        let catalog = try catalog()
        let vPIC = try vPICVehicle()
        #expect(catalog.match(vPIC)?.name == "M157")
        #expect(
            catalog.match(CatalogVehicle(make: "Maserati", model: "Ghibli", year: 2017))?.name
                == "M157")
        #expect(
            catalog.match(CatalogVehicle(make: "Volkswagen", model: "Tiguan", year: 2018))?.name
                == "MQB (second-generation Tiguan)")
        #expect(
            catalog.match(CatalogVehicle(make: "VW", model: "TIGUAN", year: 2019))?.name
                == "MQB (second-generation Tiguan)")
        #expect(
            catalog.match(CatalogVehicle(make: "Volkswagen", model: "Tiguan Limited", year: 2018))
                == nil)
        #expect(catalog.match(CatalogVehicle(make: "Maserati", model: "Ghibli", year: 2013)) == nil)
        #expect(catalog.match(CatalogVehicle(make: "Maserati", model: "Ghibli", year: 2025)) == nil)
        #expect(catalog.match(CatalogVehicle(make: "Unknown", model: "Tiguan", year: 2019)) == nil)
    }

    @Test("the demo modules remain in agreement with M157")
    func demoAgreement() throws {
        let platform = try #require(
            catalog().match(CatalogVehicle(make: "Maserati", model: "Ghibli", year: 2017)))
        for demo in DemoGarage.modules {
            #expect(
                platform.modules.contains {
                    $0.label == demo.label && $0.target == demo.target
                })
        }
    }

    @Test("malformed catalogs throw readable validation errors")
    func malformedCatalogs() {
        #expect(throws: ModuleCatalogError.unsupportedSchemaVersion(2)) {
            try ModuleCatalog(
                data: Data(#"{"schemaVersion":2,"catalogVersion":"x","makes":[]}"#.utf8))
        }
        #expect(throws: ModuleCatalogError.unknownBus("bad")) {
            try ModuleCatalog(data: Self.moduleJSON(bus: "bad"))
        }
        #expect(throws: ModuleCatalogError.unknownProvenance("bad")) {
            try ModuleCatalog(data: Self.moduleJSON(provenance: "bad"))
        }
        #expect(throws: ModuleCatalogError.self) {
            try ModuleCatalog(data: Self.moduleJSON(request: "7DF"))
        }
        #expect(throws: ModuleCatalogError.duplicateTarget("744 -> 4C4")) {
            try ModuleCatalog(data: Self.moduleJSON(duplicate: true))
        }
        #expect(throws: ModuleCatalogError.invalidYearRange) {
            try ModuleCatalog(data: Self.moduleJSON(first: 2025, last: 2024))
        }
        #expect(throws: ModuleCatalogError.emptyField("module label")) {
            try ModuleCatalog(data: Self.moduleJSON(label: ""))
        }
    }

    @Test("a make listed twice is refused, not shadowed; platforms that overlap merge")
    func shadowedEntries() throws {
        let platform = Self.platformJSON(first: 2018, last: 2024)
        #expect(throws: ModuleCatalogError.duplicateMake("x")) {
            try ModuleCatalog(
                data: Self.catalogJSON(
                    Self.makeJSON("X", platforms: platform) + ","
                        + Self.makeJSON("x", platforms: platform)))
        }
        #expect(throws: ModuleCatalogError.duplicateMake("Volkswagen")) {
            try ModuleCatalog(
                data: Self.catalogJSON(
                    Self.makeJSON("Volkswagen", platforms: platform) + ","
                        + Self.makeJSON(
                            "VW Group", aliases: #"["Volkswagen"]"#, platforms: platform)))
        }
        // Two platforms claim the model in 2020-2022: a car of those years gets both, in order,
        // each target once.
        let overlapping = try ModuleCatalog(
            data: Self.catalogJSON(
                Self.makeJSON(
                    "X",
                    platforms: Self.platformJSON(first: 2018, last: 2022) + ","
                        + Self.platformJSON(first: 2020, last: 2024, request: "745", reply: "4C5")
                        + "," + Self.platformJSON(first: 2020, last: 2024, label: "Again"))))
        let merged = try #require(
            overlapping.match(CatalogVehicle(make: "X", model: "M", year: 2021)))
        #expect(merged.modules.map(\.label) == ["Module", "Module"])
        #expect(merged.modules.map(\.target.request) == [0x744, 0x745])
        #expect(
            overlapping.match(CatalogVehicle(make: "X", model: "M", year: 2019))?.modules.map(
                \.target.request) == [0x744])
        #expect(
            overlapping.match(CatalogVehicle(make: "X", model: "M", year: 2024))?.modules.map(
                \.target.request) == [0x745, 0x744])
        #expect(throws: ModuleCatalogError.emptyField("make")) {
            try ModuleCatalog(data: Self.catalogJSON(Self.makeJSON("--", platforms: platform)))
        }

        let generations = try ModuleCatalog(
            data: Self.catalogJSON(
                Self.makeJSON(
                    "X",
                    platforms: Self.platformJSON(first: 2014, last: 2017) + ","
                        + Self.platformJSON(first: 2018, last: 2024))))
        #expect(generations.makes.first?.platforms.count == 2)
    }

    private static func catalogJSON(_ makes: String) -> Data {
        Data(#"{"schemaVersion":1,"catalogVersion":"x","makes":[\#(makes)]}"#.utf8)
    }

    private static func makeJSON(
        _ make: String, aliases: String = "[]", platforms: String
    ) -> String {
        #"{"make":"\#(make)","aliases":\#(aliases),"platforms":[\#(platforms)]}"#
    }

    private static func platformJSON(
        first: Int, last: Int, request: String = "744", reply: String = "4C4",
        label: String = "Module"
    ) -> String {
        #"{"name":"P","models":["M"],"years":{"first":\#(first),"last":\#(last)},"modules":["#
            + #"{"label":"\#(label)","bus":"hs","request":"\#(request)","reply":"\#(reply)","#
            + #""provenance":"observed","source":"x"}]}"#
    }

    private static func moduleJSON(
        bus: String = "hs", provenance: String = "observed", request: String = "744",
        label: String = "Module", first: Int = 2020, last: Int = 2024, duplicate: Bool = false
    ) -> Data {
        let second =
            duplicate
            ? "{\"label\":\"Other\",\"bus\":\"hs\",\"request\":\"744\",\"reply\":\"4C4\",\"provenance\":\"observed\",\"source\":\"x\"},"
            : ""
        return Data(
            "{\"schemaVersion\":1,\"catalogVersion\":\"x\",\"makes\":[{\"make\":\"X\",\"aliases\":[],\"platforms\":[{\"name\":\"P\",\"models\":[\"M\"],\"years\":{\"first\":\(first),\"last\":\(last)},\"modules\":[{\"label\":\"\(label)\",\"bus\":\"\(bus)\",\"request\":\"\(request)\",\"reply\":\"4C4\",\"provenance\":\"\(provenance)\",\"source\":\"x\"},\(second){\"label\":\"Other\",\"bus\":\"hs\",\"request\":\"745\",\"reply\":\"4C5\",\"provenance\":\"observed\",\"source\":\"x\"}]}]}]}"
                .utf8)
    }
}
