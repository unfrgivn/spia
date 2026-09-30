import Foundation
import OBDCore
import SpiaKit
import Testing

@Suite("Survey planner")
struct SurveyPlannerTests {
    private func catalog() throws -> ModuleCatalog { try ModuleCatalog.bundled() }

    private func ghibli() throws -> CatalogVehicle {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/nhtsa-vpic-ZAM57RTS4H1249941.json")
        struct Reply: Decodable {
            struct Result: Decodable {
                let make: String
                let model: String
                let year: String
                enum CodingKeys: String, CodingKey {
                    case make = "Make", model = "Model", year = "ModelYear"
                }
            }
            let results: [Result]
            enum CodingKeys: String, CodingKey { case results = "Results" }
        }
        let reply = try JSONDecoder().decode(Reply.self, from: Data(contentsOf: url))
        let result = try #require(reply.results.first)
        return CatalogVehicle(
            make: result.make, model: result.model, year: try #require(Int(result.year)))
    }

    @Test("Ghibli and Tiguan plans put catalog modules before legislated candidates")
    func knownPlans() throws {
        let catalog = try catalog()
        let ghibliPlan = try SurveyPlanner.plan(
            catalog: catalog, vehicle: try ghibli(), reachableBuses: [.highSpeed])
        #expect(ghibliPlan.candidates.count == 12)
        #expect(ghibliPlan.unreachable.isEmpty)
        #expect(ghibliPlan.platform == "M157")
        #expect(
            ghibliPlan.candidates.prefix(6).map(\.target) == [
                DemoGarage.airbag.target, DemoGarage.abs.target, DemoGarage.bodyComputer.target,
                DemoGarage.steeringColumn.target,
                try ModuleTarget(bus: .highSpeed, request: 0x7E0, response: 0x7E8),
                try ModuleTarget(bus: .highSpeed, request: 0x7E1, response: 0x7E9),
            ])
        #expect(
            ghibliPlan.candidates.dropFirst(6).map { $0.target.request } == [
                0x7E2, 0x7E3, 0x7E4, 0x7E5, 0x7E6, 0x7E7,
            ])

        let tiguan = try SurveyPlanner.plan(
            catalog: catalog,
            vehicle: CatalogVehicle(make: "Volkswagen", model: "Tiguan", year: 2018),
            reachableBuses: [])
        #expect(tiguan.candidates.count == 30)
        #expect(tiguan.platform == "MQB (second-generation Tiguan)")
    }

    @Test("nil and unmatched vehicles get only the legislated range")
    func legislatedOnly() throws {
        let catalog = try catalog()
        for vehicle in [
            nil,
            CatalogVehicle(make: "Maserati", model: "Ghibli", year: 2025),
        ] as [CatalogVehicle?] {
            let plan = try SurveyPlanner.plan(
                catalog: catalog, vehicle: vehicle, reachableBuses: [])
            #expect(plan.platform == nil)
            #expect(plan.candidates.count == 8)
            #expect(
                plan.candidates.allSatisfy {
                    if case .legislated = $0.origin { true } else { false }
                })
        }
    }

    @Test("unreachable buses stay in the plan's explanation")
    func unreachableBus() throws {
        let data = Self.literal(modules: [
            [
                "label": "Interior module", "bus": "ms", "request": "620", "reply": "504",
                "provenance": "reference", "source": "reference",
            ]
        ])
        let plan = try SurveyPlanner.plan(
            catalog: ModuleCatalog(data: data),
            vehicle: CatalogVehicle(make: "Test", model: "Car", year: 2020),
            reachableBuses: [.highSpeed])
        #expect(plan.candidates.count == 8)
        #expect(plan.unreachable.count == 1)
        #expect(
            try SurveyPlanner.plan(
                catalog: ModuleCatalog(data: data),
                vehicle: CatalogVehicle(make: "Test", model: "Car", year: 2020),
                reachableBuses: [.highSpeed, .mediumSpeed]
            ).unreachable.isEmpty)
    }

    @Test("a catalog module with a legislated ID on another bus doesn't drop the 500k probe")
    func legislatedDedupeComparesWholeTargets() throws {
        let data = Self.literal(modules: [
            [
                "label": "Interior module", "bus": "ms", "request": "7E3", "reply": "7EB",
                "provenance": "reference", "source": "reference",
            ]
        ])
        let plan = try SurveyPlanner.plan(
            catalog: ModuleCatalog(data: data),
            vehicle: CatalogVehicle(make: "Test", model: "Car", year: 2020),
            reachableBuses: [.highSpeed])
        #expect(plan.candidates.filter { $0.origin == .legislated }.count == 8)
        #expect(
            plan.candidates.contains {
                $0.target.bus == .highSpeed && $0.target.request == 0x7E3
            })
        #expect(plan.unreachable.map(\.target.bus) == [.mediumSpeed])
    }

    @Test("plans are deterministic and Codable")
    func deterministicCoding() throws {
        let catalog = try catalog()
        let vehicle = try ghibli()
        let first = try SurveyPlanner.plan(catalog: catalog, vehicle: vehicle, reachableBuses: [])
        let second = try SurveyPlanner.plan(
            catalog: catalog, vehicle: vehicle, reachableBuses: [.highSpeed])
        #expect(first == second)
        #expect(
            try JSONDecoder().decode(SurveyPlan.self, from: JSONEncoder().encode(first)) == first)
    }

    @Test("the candidate cap prevents an oversized survey")
    func candidateCap() throws {
        let modules = (0..<65).map { index in
            [
                "label": "Module \(index)", "bus": "hs",
                "request": String(format: "%03X", 0x500 + index),
                "reply": String(format: "%03X", 0x600 + index),
                "provenance": "reference", "source": "source",
            ]
        }
        #expect(throws: SurveyPlannerError.tooManyCandidates(73)) {
            try SurveyPlanner.plan(
                catalog: ModuleCatalog(data: Self.literal(modules: modules)),
                vehicle: CatalogVehicle(make: "Test", model: "Car", year: 2020),
                reachableBuses: [.highSpeed])
        }
    }

    @Test("planned requests stay on the read-only allowlist")
    func commandSafety() throws {
        let plans =
            try catalog().makes.flatMap { make in
                try make.platforms.map { platform in
                    try SurveyPlanner.plan(
                        catalog: catalog(),
                        vehicle: CatalogVehicle(
                            make: make.make, model: platform.models[0], year: platform.firstYear),
                        reachableBuses: [.highSpeed, .mediumSpeed])
                }
            } + [
                try SurveyPlanner.plan(catalog: catalog(), vehicle: nil, reachableBuses: [])
            ]
        let allowed: Set<UInt8> = [0x09, 0x22, 0x19, 0x3E]
        let forbidden: Set<UInt8> = [
            0x04, 0x10, 0x11, 0x14, 0x27, 0x28, 0x2E, 0x2F, 0x31, 0x3B, 0x85,
        ]
        for plan in plans {
            for request in plan.plannedRequests {
                let service = try #require(UInt8(request.prefix(2), radix: 16))
                #expect(allowed.contains(service))
                #expect(!forbidden.contains(service))
                if service == 0x3E { #expect(request == "3E00") }
                if service == 0x22 {
                    let did = try #require(UInt16(request.dropFirst(2), radix: 16))
                    #expect((0xF180...0xF19F).contains(did))
                }
                if service == 0x19 { #expect(request.count == 6 && request.hasPrefix("1902")) }
            }
        }
    }

    private static func literal(modules: [[String: String]]) -> Data {
        let object: [String: Any] = [
            "schemaVersion": 1, "catalogVersion": "test",
            "makes": [
                [
                    "make": "Test", "aliases": [],
                    "platforms": [
                        [
                            "name": "Test platform", "models": ["Car"],
                            "years": ["first": 2020, "last": 2024], "modules": modules,
                        ]
                    ],
                ]
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }
}
