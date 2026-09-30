import Foundation
import Testing

@testable import SpiaKit

@Suite("A session's results as a board")
struct SessionBoardTests {
    private let modules = DemoGarage.modules.map {
        SessionBoard.Module(label: $0.label, target: $0.target)
    }

    /// The demo car's checks, replayed from the recordings made on it, a second apart.
    private func demoResults(_ jobs: [DiagnosticJob]) async throws -> [SessionBoard.Result] {
        let demo = DemoBackend()
        try await demo.connect()
        var payloads: [JobPayload] = []
        for job in jobs {
            let events = await collect(demo.run(job, transcript: nil))
            payloads += events.compactMap(\.result?.payload)
        }
        return payloads.enumerated().map { index, payload in
            SessionBoard.Result(date: Date(timeIntervalSince1970: Double(index)), payload: payload)
        }
    }

    private func result(_ second: Double, _ payload: JobPayload) -> SessionBoard.Result {
        SessionBoard.Result(date: Date(timeIntervalSince1970: second), payload: payload)
    }

    private func airbag(_ outcome: ModuleDTCOutcome) -> JobPayload {
        .moduleDTCs(ModuleDTCs(target: DemoGarage.airbag.target, outcome: outcome))
    }

    private func scan(milOn: Bool, stored: [String]) -> JobPayload {
        let readiness = Readiness(milOn: milOn, dtcCount: stored.count, monitors: [])
        return .genericScan([
            ECUScan(
                ecu: 0x7E8, stored: .value(stored), pending: .value([]), permanent: .value([]),
                readiness: .value(readiness), freezeFrameDTC: .value(nil), freezeFrame: [])
        ])
    }

    private func survey(_ modules: [SurveyModule]) -> JobPayload {
        let candidates = modules.map(\.candidate)
        let plan = SurveyPlan(
            catalogVersion: "test", vehicle: nil, platform: nil, candidates: candidates,
            unreachable: [])
        return .survey(
            SurveyReport(
                plan: plan, voltage: nil, vehicleInfo: [], modules: modules,
                unanswered: [], notProbed: [], stop: nil))
    }

    @Test("the Ghibli: two airbag faults lead, and the steering column is still to read")
    func ghibli() async throws {
        let results = try await demoResults([
            .adapterCheck, .genericScan, .moduleDTCs(DemoGarage.airbag.target),
            .moduleDTCs(DemoGarage.abs.target), .moduleDTCs(DemoGarage.bodyComputer.target),
        ])
        let board = SessionBoard(modules: modules, results: results)

        #expect(board.rows.map(\.word) == ["Fault", "Code", "Low", "Not read", "Clear", "Clear"])
        #expect(
            board.rows.map(\.name) == [
                "Airbag controller", "Body computer", "Battery", "Steering column",
                "Engine and transmission", "ABS",
            ])
        #expect(board.rows[0].shortName == "ORC")
        #expect(board.rows[0].codes == ["80011B", "80021B"])
        #expect(board.rows[0].detail == "Failing now · Confirmed · Warning lamp requested")
        #expect(board.rows[1].codes == ["100900"])
        #expect(board.rows[1].detail == "Failing now · Confirmed")
        #expect(board.rows[2].value == "11.7 V")
        #expect(board.rows[3].date == nil)
        #expect(board.rows[4].detail == "9 of 9 monitors ready")
        #expect(board.headline == "Two faults in the airbag controller.")
        #expect(
            board.summary
                == "Warning lamp requested. Body computer: 1 code. Battery: 11.7 V, low. Clear: engine and transmission, ABS."
        )
    }

    @Test("a row with something to explain asks the same question every time")
    func questions() async throws {
        let results = try await demoResults([
            .adapterCheck, .genericScan, .moduleDTCs(DemoGarage.airbag.target),
            .moduleDTCs(DemoGarage.bodyComputer.target),
        ])
        let board = SessionBoard(modules: modules, results: results)
        func question(_ name: String) -> String? {
            board.rows.first { $0.name == name }?.question
        }
        #expect(
            question("Airbag controller")
                == "What do 80011B and 80021B from the airbag controller (ORC) mean on this car, and what should I check first?"
        )
        #expect(
            question("Body computer")
                == "What does 100900 from the body computer (BCM) mean on this car, and what should I check first?"
        )
        #expect(
            question("Battery")
                == "The battery reads 11.7 V at the OBD port. Is that a problem, and what should I check?"
        )
        #expect(question("Engine and transmission") == nil)
        #expect(question("Steering column") == nil)
        #expect(
            SessionBoard(modules: modules, results: results).rows.map(\.question)
                == board.rows.map(\.question))
    }

    @Test("nothing read yet: every row says so, and the board says to run a check")
    func nothingRead() {
        let board = SessionBoard(modules: modules, results: [])
        #expect(board.rows.allSatisfy { $0.status == .notRead && $0.date == nil })
        #expect(board.rows.count == modules.count + 2)
        #expect(board.headline == "Nothing read yet.")
        #expect(board.summary == "Run a check to see what the car reports.")
    }

    @Test("a newer read replaces an older one; a declined read doesn't erase codes")
    func newerReadWins() {
        let faults = airbag(
            .records(availability: 0xFF, [ModuleDTCRecord(code: "80011B", status: 0x89)]))
        let cleared = airbag(.records(availability: 0xFF, []))
        let declined = airbag(.negative(service: 0x19, code: 0x22))

        let afterClear = SessionBoard(
            modules: modules, results: [result(2, cleared), result(1, faults)])
        #expect(afterClear.rows.first { $0.name == "Airbag controller" }?.status == .clear)

        let afterDecline = SessionBoard(
            modules: modules, results: [result(1, faults), result(2, declined)])
        let row = afterDecline.rows.first { $0.name == "Airbag controller" }
        #expect(row?.status == .fault)
        #expect(row?.date == Date(timeIntervalSince1970: 1))
        #expect(afterDecline.headline == "One fault in the airbag controller.")

        let onlyDeclined = SessionBoard(modules: modules, results: [result(1, declined)])
        #expect(onlyDeclined.rows.first?.status == .noAnswer)
        #expect(onlyDeclined.headline == "The airbag controller didn't answer.")
    }

    @Test("codes without a warning lamp are codes, not a fault")
    func codesWithoutLamp() {
        let stored = airbag(
            .records(availability: 0xFF, [ModuleDTCRecord(code: "80011B", status: 0x28)]))
        let board = SessionBoard(modules: modules, results: [result(1, stored)])
        #expect(board.rows.first?.status == .codes)
        #expect(board.rows.first?.word == "Code")
        #expect(board.headline == "One code in the airbag controller.")
    }

    @Test("the check-engine light is a fault even before a code is named")
    func checkEngine() {
        let lit = SessionBoard(
            modules: [], results: [result(1, scan(milOn: true, stored: ["P0301"]))])
        #expect(lit.rows.first?.status == .fault)
        #expect(lit.rows.first?.detail == "Check-engine light on · Stored")
        #expect(lit.headline == "The check-engine light is on.")
        #expect(lit.summary == "Engine and transmission: 1 code.")

        let stored = SessionBoard(
            modules: [], results: [result(1, scan(milOn: false, stored: ["P0420"]))])
        #expect(stored.rows.first?.status == .codes)
        #expect(stored.headline == "One code in the engine and transmission.")
    }

    @Test("battery: low under 12 V, high over 15 V, and in range otherwise")
    func battery() {
        func battery(_ volts: Double?) -> SessionBoard.Row? {
            let status = AdapterStatus(identity: "ELM327 v2.3", voltage: volts)
            return SessionBoard(modules: [], results: [result(1, .adapter(status))]).rows
                .first { $0.subject == .battery }
        }
        #expect(battery(11.7)?.status == .low)
        #expect(battery(12.6)?.status == .ok)
        #expect(battery(12.6)?.detail == "In range for a rested battery")
        #expect(battery(14.1)?.detail == "In range for a running engine")
        #expect(battery(15.6)?.status == .high)
        #expect(battery(nil)?.status == .noAnswer)
    }

    @Test("a live reading from the connected adapter replaces a saved one, and has no time")
    func liveBattery() {
        let saved = AdapterStatus(identity: "ELM327 v2.3", voltage: 12.6)
        let live = AdapterStatus(identity: "ELM327 v2.3", voltage: 11.7)
        let board = SessionBoard(modules: [], results: [result(1, .adapter(saved))], live: live)
        let row = board.rows.first { $0.subject == .battery }
        #expect(row?.status == .low)
        #expect(row?.value == "11.7 V")
        #expect(row?.live == true)
        #expect(row?.date == nil)
        #expect(
            SessionBoard(modules: [], results: [result(1, .adapter(saved))]).rows
                .first { $0.subject == .battery }?.live == false)
    }

    @Test("a module read but no longer on the vehicle still gets a row")
    func unknownModule() {
        let target = ModuleTarget(known: .highSpeed, request: 0x7A1, response: 0x7A9)
        let read = JobPayload.moduleDTCs(
            ModuleDTCs(target: target, outcome: .records(availability: 0xFF, [])))
        let board = SessionBoard(modules: [], results: [result(1, read)])
        #expect(board.rows.contains { $0.name == "Module 7A1" && $0.status == .clear })
    }

    @Test("survey code outcomes populate, update, and preserve module rows")
    func surveyOutcomes() throws {
        let unknownTarget = try ModuleTarget(bus: .highSpeed, request: 0x7A1, response: 0x7A9)
        let candidates = [
            SurveyCandidate(target: DemoGarage.airbag.target, origin: .legislated),
            SurveyCandidate(target: DemoGarage.abs.target, origin: .legislated),
            SurveyCandidate(target: DemoGarage.bodyComputer.target, origin: .legislated),
            SurveyCandidate(target: DemoGarage.steeringColumn.target, origin: .legislated),
            SurveyCandidate(target: unknownTarget, origin: .legislated),
            SurveyCandidate(
                target: try ModuleTarget(bus: .highSpeed, request: 0x760, response: 0x768),
                origin: .legislated),
        ]
        let modules = [
            SurveyModule(
                candidate: candidates[0], presence: .present, identification: [],
                codes: .outcome(
                    .records(availability: 0xFF, [ModuleDTCRecord(code: "80011B", status: 0x80)]))),
            SurveyModule(
                candidate: candidates[1], presence: .present, identification: [],
                codes: .outcome(.records(availability: 0xFF, []))),
            SurveyModule(
                candidate: candidates[2], presence: .present, identification: [],
                codes: .outcome(.negative(service: 0x19, code: 0x22))),
            SurveyModule(
                candidate: candidates[3], presence: .present, identification: [], codes: .noAnswer),
            SurveyModule(
                candidate: candidates[4], presence: .present, identification: [],
                codes: .outcome(
                    .records(
                        availability: 0xFF,
                        [ModuleDTCRecord(code: "900001", status: 0x80)]))),
            SurveyModule(
                candidate: candidates[5], presence: .present, identification: [],
                codes: .unreadable("bad response")),
        ]
        let surveyResult = result(1, survey(modules))
        let board = SessionBoard(modules: self.modules, results: [surveyResult])
        #expect(
            board.rows.first { $0.subject == .module(DemoGarage.airbag.target) }?.status == .fault)
        #expect(board.rows.first { $0.subject == .module(DemoGarage.abs.target) }?.status == .clear)
        #expect(
            board.rows.first { $0.subject == .module(DemoGarage.bodyComputer.target) }?.status
                == .noAnswer)
        #expect(
            board.rows.first { $0.subject == .module(DemoGarage.steeringColumn.target) }?.status
                == .notRead)
        #expect(board.rows.first { $0.name == "Module 7A1" }?.status == .fault)
        #expect(!board.rows.contains { $0.name == "Module 760" })

        let laterClear = result(
            2,
            .moduleDTCs(
                ModuleDTCs(
                    target: DemoGarage.airbag.target,
                    outcome: .records(availability: 0xFF, []))))
        #expect(
            SessionBoard(modules: self.modules, results: [surveyResult, laterClear])
                .rows.first { $0.subject == .module(DemoGarage.airbag.target) }?.status == .clear)
        let laterRefusal = result(
            3,
            .moduleDTCs(
                ModuleDTCs(
                    target: DemoGarage.airbag.target,
                    outcome: .negative(service: 0x19, code: 0x22))))
        #expect(
            SessionBoard(modules: self.modules, results: [surveyResult, laterRefusal])
                .rows.first { $0.subject == .module(DemoGarage.airbag.target) }?.status == .fault)
    }

    @Test("each check fills one row, and each row names the check that reads it")
    func subjects() {
        let airbag = DemoGarage.airbag.target
        #expect(SessionBoard.Subject(job: .genericScan) == .engine)
        #expect(SessionBoard.Subject(job: .moduleDTCs(airbag)) == .module(airbag))
        #expect(SessionBoard.Subject(job: .adapterCheck) == .battery)
        #expect(SessionBoard.Subject(job: .vehicleInfo) == nil)
        for subject in [SessionBoard.Subject.engine, .module(airbag), .battery] {
            #expect(SessionBoard.Subject(job: subject.job) == subject)
        }
    }

    @Test("labels split into a name and the short name in parentheses")
    func labels() {
        #expect(SessionBoard.split("Airbag controller (ORC)") == ("Airbag controller", "ORC"))
        #expect(SessionBoard.split("ABS") == ("ABS", nil))
        #expect(SessionBoard.prose("Body computer") == "body computer")
        #expect(SessionBoard.prose("ABS") == "ABS")
    }
}
