import Foundation
import SpiaKit
import Testing

/// The module addresses generated from opendbc (`scripts/import-opendbc.py`), checked against
/// what the owner's cars answered and against the survey's limits.
@Suite("Catalog from opendbc")
struct OpenDBCCatalogTests {
    private static func generated() throws -> ModuleCatalog {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/SpiaKit/Catalog/modules-opendbc.json")
        return try ModuleCatalog(data: Data(contentsOf: url))
    }

    private static func target(_ request: UInt32, _ response: UInt32) throws -> ModuleTarget {
        try ModuleTarget(bus: .highSpeed, request: request, response: response)
    }

    @Test("every generated module is a valid, cited reference from openpilot's cars")
    func generatedModules() throws {
        let catalog = try Self.generated()
        #expect(catalog.catalogVersion == "opendbc-f1e707b")
        #expect(catalog.makes.count == 27)
        let platforms = catalog.makes.flatMap(\.platforms)
        #expect(platforms.count == 280)
        let modules = platforms.flatMap(\.modules)
        #expect(modules.count == 1_150)
        for module in modules {
            #expect(module.provenance == .reference)
            #expect(module.source.hasPrefix("opendbc f1e707b: "))
            #expect(module.source.contains("OBD port") || module.source.contains("camera harness"))
            #expect(module.target.bus == .highSpeed)
            #expect(module.target.request != 0x7DF)
            #expect(module.target.response != module.target.request)
        }
    }

    @Test("opendbc's pairs agree with what the Tiguan and the Ghibli answered")
    func agreesWithTheCars() throws {
        let catalog = try ModuleCatalog.bundled()
        let generated = try Self.generated()
        func pairs(_ makes: [String]) -> [UInt32: Set<UInt32>] {
            var pairs: [UInt32: Set<UInt32>] = [:]
            for make in generated.makes where makes.contains(make.make) {
                for module in make.platforms.flatMap(\.modules) {
                    pairs[module.target.request, default: []].insert(module.target.response)
                }
            }
            return pairs
        }
        // VW asks its chassis modules at +0x6A and its engine and transmission at +8; the Tiguan
        // answered every one of opendbc's VW addresses at exactly those replies.
        let tiguan = try #require(
            catalog.match(CatalogVehicle(make: "Volkswagen", model: "Tiguan", year: 2018)))
        let vw = pairs(["Volkswagen", "Audi", "SEAT", "Škoda", "CUPRA", "Porsche", "MAN"])
        #expect(vw.keys.sorted() == [0x712, 0x715, 0x757, 0x7E0, 0x7E1])
        for (request, replies) in vw {
            let observed = try #require(tiguan.modules.first { $0.target.request == request })
            #expect(replies == [observed.target.response])
        }
        // FCA answers its body and chassis modules at request - 0x280, as the Ghibli's airbag
        // controller and ABS did.
        let fca = pairs(["Chrysler", "Jeep", "Ram", "Dodge"])
        #expect(fca[0x744] == [0x4C4])
        #expect(fca[0x747] == [0x4C7])
        #expect(fca[0x7E0] == [0x7E8])
    }

    @Test("a 2019 CX-5 gets opendbc's six modules; a 2014 CX-5, a generation earlier, gets none")
    func mazda() throws {
        let catalog = try ModuleCatalog.bundled()
        let cx5 = try #require(
            catalog.match(CatalogVehicle(make: "MAZDA", model: "CX-5", year: 2019)))
        #expect(cx5.name == "Mazda CX-5 2017-2021 (opendbc MAZDA_CX5)")
        #expect(
            cx5.modules.map(\.target) == [
                try Self.target(0x706, 0x70E), try Self.target(0x730, 0x738),
                try Self.target(0x760, 0x768), try Self.target(0x764, 0x76C),
                try Self.target(0x7E0, 0x7E8), try Self.target(0x7E1, 0x7E9),
            ])
        #expect(
            cx5.modules.map(\.label) == [
                "Front camera", "Power steering", "ABS", "Front radar", "Engine", "Transmission",
            ])
        #expect(catalog.match(CatalogVehicle(make: "MAZDA", model: "CX-5", year: 2014)) == nil)
        // NHTSA calls the Mazda 3 a Mazda3.
        #expect(catalog.match(CatalogVehicle(make: "MAZDA", model: "Mazda3", year: 2018)) != nil)
    }

    @Test("the owner's Tiguan and Ghibli keep exactly what they answered")
    func ownersCars() throws {
        let catalog = try ModuleCatalog.bundled()
        let tiguan = try #require(
            catalog.match(CatalogVehicle(make: "VOLKSWAGEN", model: "Tiguan", year: 2018)))
        #expect(tiguan.name == "MQB (second-generation Tiguan)")
        #expect(tiguan.modules.count == 19)
        #expect(tiguan.modules.allSatisfy { $0.provenance == .observed })
        #expect(tiguan.modules.first { $0.target.request == 0x712 }?.label == "Steering assist")
        let ghibli = try #require(
            catalog.match(CatalogVehicle(make: "MASERATI", model: "Ghibli", year: 2017)))
        #expect(ghibli.name == "M157")
        // The six seen in its first surveys, then the eight its first thorough search found.
        #expect(ghibli.modules.count == 14)
        #expect(ghibli.modules.allSatisfy { $0.provenance == .observed })
    }

    @Test("a 2019 Civic gets Honda's 29-bit modules, each replying with its address bytes swapped")
    func honda() throws {
        let civic = try #require(
            try ModuleCatalog.bundled().match(
                CatalogVehicle(make: "HONDA", model: "Civic", year: 2019)))
        #expect(civic.name == "Honda Civic 2017-2021 (opendbc HONDA_CIVIC_BOSCH)")
        #expect(
            civic.modules.map(\.label) == [
                "Transmission", "Stability control", "Brake booster", "Power steering", "Airbag",
                "Front radar", "Front camera", "Gateway",
            ])
        for module in civic.modules {
            #expect(module.target.isExtended)
            let target = (module.target.request >> 8) & 0xFF
            #expect(module.target.request == 0x18DA_00F1 | target << 8)
            #expect(module.target.response == 0x18DA_F100 | target)
        }
    }

    @Test("a 2021 Sonata gets its gas and hybrid platforms' modules, each once")
    func overlappingPlatforms() throws {
        let sonata = try #require(
            try ModuleCatalog.bundled().match(
                CatalogVehicle(make: "HYUNDAI", model: "Sonata", year: 2021)))
        #expect(sonata.name == "Hyundai Sonata 2020-2023 (opendbc HYUNDAI_SONATA)")
        #expect(
            sonata.modules.map(\.target) == [
                try Self.target(0x7C4, 0x7CC), try Self.target(0x7D0, 0x7D8),
                try Self.target(0x7D1, 0x7D9), try Self.target(0x7D4, 0x7DC),
            ])
    }

    @Test("every car the catalog knows plans within the survey's limit")
    func everyCarPlans() throws {
        let catalog = try ModuleCatalog.bundled()
        var plans = 0
        for make in catalog.makes {
            for platform in make.platforms {
                for model in platform.models {
                    for year in platform.firstYear...platform.lastYear {
                        let plan = try SurveyPlanner.plan(
                            catalog: catalog,
                            vehicle: CatalogVehicle(make: make.make, model: model, year: year),
                            reachableBuses: [.highSpeed, .mediumSpeed])
                        #expect(plan.platform != nil)
                        #expect(plan.candidates.count <= SurveyPlanner.candidateLimit)
                        plans += 1
                    }
                }
            }
        }
        // Every model and year of every platform, Spia's two and opendbc's 280.
        #expect(plans == 944)
    }

    @Test("each make's platforms are pinned, so a regenerated catalog's changes show up here")
    func platformCounts() throws {
        let counts = Dictionary(
            uniqueKeysWithValues: try ModuleCatalog.bundled().makes.map {
                ($0.make, $0.platforms.count)
            })
        #expect(
            counts == [
                "Acura": 9, "Audi": 6, "Chrysler": 4, "CUPRA": 2, "Dodge": 1, "Ford": 12,
                "Genesis": 10, "Honda": 29, "Hyundai": 38, "Jeep": 3, "Kia": 27, "Lexus": 15,
                "Lincoln": 1, "MAN": 2,
                "Maserati": 1, "Mazda": 6, "MG": 1, "Nissan": 3, "Peugeot": 1, "Porsche": 1,
                "Ram": 3, "Rivian": 2, "SEAT": 3, "Subaru": 19, "Tesla": 3, "Toyota": 29,
                "Volkswagen": 42, "Škoda": 9,
            ])
    }
}
