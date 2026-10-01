import Foundation
import OBDCore
import SpiaKit
import Testing

@Suite("Survey planner")
struct SurveyPlannerTests {
    @Test("thorough search warning calculates its address count and rounded duration")
    func thoroughSearchWarning() throws {
        let target = try ModuleTarget(bus: .highSpeed, request: 0x744, response: 0x4C4)
        let candidate = SurveyCandidate(target: target, origin: .legislated)
        let search = ModuleSearch(
            requestRange: 0x600...0x603, listenMilliseconds: 1_001, perAddressMilliseconds: 80)
        #expect(
            search.confirmationMessage(
                connection: .bluetooth, candidates: [candidate])
                == "Spia will send a 'tester present' message, which changes nothing, to about 4 addresses this car doesn't use, to find modules no list knows about.\nIt takes about 2 seconds over Bluetooth.\nLeave the ignition on with the engine off, and don't drive."
        )
    }

    @Test("adapter firmware determines whether the medium-speed bus is reachable")
    func reachableBuses() {
        #expect(SurveyPlanner.reachableBuses(for: nil) == [.highSpeed])
        #expect(
            SurveyPlanner.reachableBuses(
                for: AdapterStatus(identity: "ELM327", firmware: nil)) == [.highSpeed])
        #expect(
            SurveyPlanner.reachableBuses(
                for: AdapterStatus(identity: "ELM327", firmware: "STN1170"))
                == [.highSpeed, .mediumSpeed])
    }

    @Test("saved modules replace known targets, append unknown targets, and keep bus reachability")
    func savedModules() throws {
        let abs = try ModuleTarget(bus: .highSpeed, request: 0x747, response: 0x4C7)
        let savedUnknown = try ModuleTarget(bus: .highSpeed, request: 0x799, response: 0x7A1)
        let savedMedium = try ModuleTarget(bus: .mediumSpeed, request: 0x620, response: 0x504)
        let saved = [
            ModuleChoice(target: abs, label: "Saved ABS", confirmed: false),
            ModuleChoice(target: savedUnknown, label: "Saved extra", confirmed: true),
            ModuleChoice(target: savedMedium, label: "Saved interior", confirmed: true),
        ]
        let plan = try SurveyPlanner.plan(
            catalog: catalog(), vehicle: try ghibli(), reachableBuses: [.highSpeed],
            savedModules: saved)
        #expect(
            plan.candidates.contains {
                $0.target == abs && $0.origin == .saved(label: "Saved ABS", confirmed: false)
            })
        let unknownIndex = try #require(plan.candidates.firstIndex { $0.target == savedUnknown })
        let engineIndex = try #require(plan.candidates.firstIndex { $0.target.request == 0x7E0 })
        #expect(unknownIndex > engineIndex)
        #expect(plan.unreachable.contains { $0.target == savedMedium })
        #expect(plan.expected.contains(abs))
        #expect(plan.expected.contains(savedUnknown))
        // The 125k bus is out of this adapter's reach, so it's never probed or missed.
        #expect(!plan.expected.contains(savedMedium))
    }

    @Test("a module saved twice is probed once")
    func duplicateSavedModules() throws {
        let tcm = try ModuleTarget(bus: .highSpeed, request: 0x7E1, response: 0x7E9)
        let plan = try SurveyPlanner.plan(
            catalog: catalog(), vehicle: CatalogVehicle(make: "Mazda", model: "CX-5", year: 2014),
            reachableBuses: [.highSpeed],
            savedModules: [
                ModuleChoice(target: tcm, label: "TCM-TransmisCtrl", confirmed: true),
                ModuleChoice(target: tcm, label: "Transmission", confirmed: false),
            ])
        #expect(plan.candidates.filter { $0.target == tcm }.count == 1)
        #expect(plan.expected.filter { $0 == tcm }.count == 1)
        #expect(
            plan.candidates.first { $0.target == tcm }?.origin
                == .saved(label: "TCM-TransmisCtrl", confirmed: true))
    }

    @Test("the owner's real saved modules: the phone's Ghibli and the CX-5")
    func realSavedModules() throws {
        func target(_ request: UInt32, _ response: UInt32) throws -> ModuleTarget {
            try ModuleTarget(bus: .highSpeed, request: request, response: response)
        }
        // The phone's Ghibli saved four modules, unconfirmed, from its survey with the car partly
        // on. They keep their catalog places; the airbag controller and engine stay catalog.
        let ghibliPlan = try SurveyPlanner.plan(
            catalog: catalog(), vehicle: try ghibli(), reachableBuses: [.highSpeed],
            savedModules: [
                ModuleChoice(target: try target(0x747, 0x4C7), label: "ABS", confirmed: false),
                ModuleChoice(
                    target: try target(0x620, 0x504), label: "Body computer (BCM)", confirmed: false
                ),
                ModuleChoice(
                    target: try target(0x763, 0x4E3), label: "Steering column (SCCM)",
                    confirmed: false),
                ModuleChoice(
                    target: try target(0x7E1, 0x7E9), label: "Transmission", confirmed: false),
            ])
        #expect(
            ghibliPlan.candidates.prefix(6).map(\.target.request) == [
                0x744, 0x747, 0x620, 0x763, 0x7E0, 0x7E1,
            ])
        #expect(
            ghibliPlan.candidates.prefix(6).map { candidate -> Bool in
                if case .saved = candidate.origin { return true }
                return false
            } == [false, true, true, true, false, true])
        #expect(ghibliPlan.expected.map(\.request) == [0x744, 0x747, 0x620, 0x763, 0x7E0, 0x7E1])

        // The CX-5 saved its transmission, which named itself; no catalog knows the car, so it
        // comes before the legislated addresses, and the engine computer is expected too.
        let cx5Plan = try SurveyPlanner.plan(
            catalog: catalog(), vehicle: CatalogVehicle(make: "Mazda", model: "CX-5", year: 2014),
            reachableBuses: [.highSpeed],
            savedModules: [
                ModuleChoice(
                    target: try target(0x7E1, 0x7E9), label: "TCM-TransmisCtrl", confirmed: true)
            ])
        #expect(
            cx5Plan.candidates.map(\.target.request) == [
                0x7E1, 0x7E0, 0x7E2, 0x7E3, 0x7E4, 0x7E5, 0x7E6, 0x7E7,
            ])
        #expect(cx5Plan.expected.map(\.request) == [0x7E1, 0x7E0])
    }
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

    @Test("survey plans carry VIN and second-look expectations, with old-plan defaults")
    func surveyPolicyRoundTrip() throws {
        let catalog = try catalog()
        let ghibliPlan = try SurveyPlanner.plan(
            catalog: catalog, vehicle: ghibli(), reachableBuses: [.highSpeed, .mediumSpeed])
        #expect(ghibliPlan.requiresVIN)
        #expect(ghibliPlan.expected.count == 6)
        #expect(ghibliPlan.expected.contains { $0.request == 0x7E0 && $0.response == 0x7E8 })

        let tiguan = CatalogVehicle(make: "Volkswagen", model: "Tiguan", year: 2018)
        let tiguanPlan = try SurveyPlanner.plan(
            catalog: catalog, vehicle: tiguan, reachableBuses: [.highSpeed, .mediumSpeed])
        #expect(tiguanPlan.expected.count == 19)

        let cx5 = CatalogVehicle(make: "Mazda", model: "CX-5", year: 2014)
        let cx5Plan = try SurveyPlanner.plan(
            catalog: catalog, vehicle: cx5, reachableBuses: [.highSpeed])
        #expect(cx5Plan.expected.map(\.request) == [0x7E0])

        var oldJSON =
            try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(ghibliPlan)) as! [String: Any]
        oldJSON.removeValue(forKey: "requiresVIN")
        oldJSON.removeValue(forKey: "expected")
        let oldPlan = try JSONDecoder().decode(
            SurveyPlan.self, from: JSONSerialization.data(withJSONObject: oldJSON))
        #expect(!oldPlan.requiresVIN)
        #expect(oldPlan.expected.isEmpty)
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
        // The 19 modules that answered on a 2018 Tiguan, then 7E2-7E7 (7E0 and 7E1 are among them).
        #expect(tiguan.candidates.count == 25)
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
