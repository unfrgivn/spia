import OBDCore
import SpiaKit
import SpiaReference
import SpiaStore
import Testing

@Suite("Garage survey VIN")
@MainActor
struct GarageSurveyTests {
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
