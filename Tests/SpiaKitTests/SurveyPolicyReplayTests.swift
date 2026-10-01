import Foundation
import OBDCore
import SpiaKit
import Testing

@Suite("Survey policy replay")
struct SurveyPolicyReplayTests {
    @Test("ATDPN parses automatic and hexadecimal protocol replies")
    func protocolParsing() {
        #expect(ELM327Protocol.parseDetection("A6\r") == .can11bit500k)
        #expect(ELM327Protocol.parseDetection("6") == .can11bit500k)
        #expect(ELM327Protocol.parseDetection("A8") == .can11bit250k)
        #expect(ELM327Protocol.parseDetection("A") == nil)
        #expect(ELM327Protocol.parseDetection("searching") == nil)
    }

    private func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures").appendingPathComponent(name)
    }

    private func plan(make: String, model: String, year: Int) throws -> SurveyPlan {
        try SurveyPlanner.plan(
            catalog: ModuleCatalog.bundled(),
            vehicle: CatalogVehicle(make: make, model: model, year: year),
            reachableBuses: [.highSpeed, .mediumSpeed])
    }

    @Test("new plans expect observed modules and the universal engine target")
    func expectedTargets() throws {
        let ghibli = try plan(make: "Maserati", model: "Ghibli", year: 2017)
        #expect(ghibli.requiresVIN)
        #expect(ghibli.expected.count == 6)
        let cx5 = try plan(make: "Mazda", model: "CX-5", year: 2014)
        #expect(cx5.requiresVIN)
        #expect(cx5.expected.map(\.request) == [0x7E0])
    }

    @Test("the CX-5 survey asks for the VIN before retrying its opening information")
    func cx5VINGate() async throws {
        let plan = try plan(make: "Mazda", model: "CX-5", year: 2014)
        let transport = try ReplayTransport(contentsOf: fixture("cx5-app-ble-survey.txt"))
        let connection = ConnectionManager(
            adapter: AdapterDescriptor(kind: .bluetooth, displayName: "vLinker FS")
        ) { transport }
        try await connection.connect()
        var actions: [UserAction] = []
        var failure: JobFailure?
        let runner = JobRunner(connection: connection)
        for await event in await runner.run(.survey(plan)) {
            switch event {
            case .needsUser(let id, let action):
                actions.append(action)
                await runner.confirm(id)
            case .failed(let value): failure = value
            default: break
            }
        }
        #expect(actions == [.turnIgnitionOnForVIN])
        #expect(failure?.message.contains("0900") == true)
    }

    @Test("the Ghibli protocol detection begins after the recorded opening")
    func ghibliSecondLook() async throws {
        let plan = try plan(make: "Maserati", model: "Ghibli", year: 2017)
        let transport = try ReplayTransport(contentsOf: fixture("ghibli-app-ble-survey.txt"))
        let connection = ConnectionManager(
            adapter: AdapterDescriptor(kind: .bluetooth, displayName: "vLinker FS")
        ) { transport }
        try await connection.connect()
        let runner = JobRunner(connection: connection)
        var failure: JobFailure?
        var steps: [String] = []
        for await event in await runner.run(.survey(plan)) {
            switch event {
            case .needsUser(let id, _): await runner.confirm(id)
            case .step(let step): steps.append(step)
            case .failed(let value): failure = value
            default: break
            }
        }
        #expect(plan.expected.first?.request == 0x744)
        #expect(steps.contains { $0.contains("Requesting") })
        #expect(failure?.message.contains("ATDPN") == true)
    }

    @Test("the Bluetooth Ghibli report names the two expected silent modules")
    func reviewExpectedSilent() throws {
        let saved = try JSONDecoder().decode(
            JobResult.self,
            from: Data(contentsOf: fixture("ghibli-app-ble-survey.result.json")))
        guard case .survey(let oldReport) = saved.payload else { throw ReplayFailure() }
        let currentPlan = try plan(make: "Maserati", model: "Ghibli", year: 2017)
        let report = SurveyReport(
            plan: currentPlan, voltage: oldReport.voltage, vehicleInfo: oldReport.vehicleInfo,
            modules: oldReport.modules, unanswered: oldReport.unanswered,
            notProbed: oldReport.notProbed, stop: oldReport.stop)
        let review = SurveyReview(report: report)
        #expect(
            review.notes.contains {
                $0.contains("Airbag controller (ORC)") && $0.contains("Engine")
            })
        #expect(!review.notes.contains { $0.contains("No computer gave the VIN") })
        #expect(review.canTryAgain)
    }

    private struct ReplayFailure: Error {}
}
