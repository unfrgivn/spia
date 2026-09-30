import Foundation
import OBDCore
import SpiaKit
import SpiaReference
import SpiaStore
import Testing

@Suite("Garage survey VIN")
@MainActor
struct GarageSurveyTests {
    @Test("applying survey choices appends, updates, preserves, and is idempotent")
    func applyChoices() throws {
        let container = try Garage.inMemoryContainer()
        let garage = Garage(
            context: container.mainContext,
            files: SpiaFiles(root: FileManager.default.temporaryDirectory))
        let vehicle = SpiaSchemaV1.Vehicle(name: "Test car")
        container.mainContext.insert(vehicle)
        let existingTarget = try ModuleTarget(bus: .highSpeed, request: 0x744, response: 0x4C4)
        let otherBusTarget = try ModuleTarget(bus: .mediumSpeed, request: 0x744, response: 0x53C)
        let untouchedTarget = try ModuleTarget(bus: .highSpeed, request: 0x747, response: 0x4C7)
        vehicle.modules = [
            ModulePreset(label: "Old", target: existingTarget, position: 2),
            ModulePreset(label: "Other bus", target: otherBusTarget, position: 4),
            ModulePreset(label: "Untouched", target: untouchedTarget, position: 7),
        ]
        try container.mainContext.save()
        let choices = [
            ModuleChoice(target: existingTarget, label: "Airbag", confirmed: true),
            ModuleChoice(
                target: try ModuleTarget(bus: .highSpeed, request: 0x620, response: 0x504),
                label: "Body", confirmed: false),
        ]
        try garage.apply(choices, to: vehicle)
        #expect(vehicle.modules.count == 4)
        #expect(vehicle.modules.first { $0.target == existingTarget }?.label == "Airbag")
        #expect(vehicle.modules.first { $0.target == existingTarget }?.confirmed == true)
        #expect(vehicle.modules.first { $0.target == otherBusTarget }?.label == "Other bus")
        #expect(vehicle.modules.first { $0.target == untouchedTarget }?.label == "Untouched")
        #expect(vehicle.modules.first { $0.label == "Body" }?.position == 8)
        try garage.apply(choices, to: vehicle)
        #expect(vehicle.modules.count == 4)
        #expect(vehicle.modules.filter { $0.label == "Body" }.count == 1)
    }

    @Test("a decoded vehicle identity becomes a catalog vehicle")
    func catalogVehicle() {
        let identity = VehicleIdentity(
            vin: "ZAM57RTS4H1249941", make: "Maserati", model: "Ghibli", modelYear: 2017)
        #expect(
            CatalogVehicle(identity)
                == CatalogVehicle(make: "Maserati", model: "Ghibli", year: 2017))
    }

    @Test("reportedVIN accepts the VIN from a live survey")
    func surveyVIN() throws {
        var info = ECUInfoReport(ecu: 0x7E8)
        info.vin = .positive("ZAM57RTS4H1249941")
        let identity = ECUIdentity(info)
        let plan = SurveyPlan(
            catalogVersion: "test", vehicle: nil, platform: nil, candidates: [], unreachable: [])
        let report = SurveyReport(
            plan: plan, voltage: 12.4, vehicleInfo: [identity], modules: [], unanswered: [],
            notProbed: [], stop: nil)
        let result = JobResult(
            job: .survey(plan), payload: .survey(report), source: .live, transcript: nil)
        #expect(Garage.reportedVIN(result) == "ZAM57RTS4H1249941")
    }
}
