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

    /// Runs `plan` against a real recording, confirming each prompt, and returns its steps and
    /// how it ended.
    private func replay(_ plan: SurveyPlan, against recording: String) async throws -> (
        steps: [String], failure: JobFailure?
    ) {
        let transport = try ReplayTransport(contentsOf: fixture(recording))
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
        return (steps, failure)
    }

    @Test("the Ghibli survey asks the protocol right after the recorded opening, before any probe")
    func ghibliProtocolDetection() async throws {
        let plan = try plan(make: "Maserati", model: "Ghibli", year: 2017)
        #expect(plan.detectsProtocol)
        let run = try await replay(plan, against: "ghibli-app-ble-survey.txt")
        #expect(!run.steps.contains { $0.hasPrefix("Looking for modules") })
        #expect(run.failure?.message.contains("ATDPN") == true)
    }

    @Test("the Ghibli second look begins at the first expected silent module")
    func ghibliSecondLook() async throws {
        // The same plan without protocol detection, which the recording predates, so the replay
        // reaches the end of the pass.
        let current = try plan(make: "Maserati", model: "Ghibli", year: 2017)
        let plan = SurveyPlan(
            catalogVersion: current.catalogVersion, vehicle: current.vehicle,
            platform: current.platform, candidates: current.candidates,
            unreachable: current.unreachable, requiresVIN: current.requiresVIN,
            expected: current.expected, detectsProtocol: false)
        #expect(plan.expected.first?.request == 0x744)
        let run = try await replay(plan, against: "ghibli-app-ble-survey.txt")
        // Every recorded probe matched, then the second look began, for the airbag controller and
        // the engine, with the first command the recording doesn't have.
        #expect(run.steps.contains("Looking for modules: 12 of 12"))
        #expect(run.steps.last == "Looking again: 1 of 2")
        #expect(run.failure?.message.contains("ATSP6") == true)
    }

    @Test("only protocols the survey can't probe stop it; an undecided answer probes as before")
    func protocolSupport() {
        #expect(ELM327Protocol.parseDetection("A0") == .automatic)
        #expect(ELM327Protocol.can11bit500k.surveyUnsupportedNote == nil)
        #expect(ELM327Protocol.automatic.surveyUnsupportedNote == nil)
        #expect(ELM327Protocol.iso9141.surveyUnsupportedNote?.contains("ISO 9141-2") == true)
        #expect(ELM327Protocol.j1850VPW.surveyUnsupportedNote?.contains("older protocol") == true)
        #expect(ELM327Protocol.can29bit500k.surveyUnsupportedNote?.contains("29-bit") == true)
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
