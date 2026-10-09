import Foundation
import SpiaKit
import SpiaStore
import SpiaTestSupport
import SwiftData
import Testing

@MainActor
@Suite("One scan")
struct ScanTests {
    private let container: ModelContainer
    private let garage: Garage
    private let root: URL

    init() throws {
        container = try Garage.inMemoryContainer()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("spia-scan-tests-\(UUID().uuidString)")
        garage = Garage(context: container.mainContext, files: SpiaFiles(root: root))
    }

    @Test("demo scan plan runs the recorded checks in phase order")
    func demoPlan() throws {
        let vehicle = try garage.addDemoVehicle()
        let plan = ScanPlan.make(for: vehicle, backend: DemoBackend(), survey: nil)
        #expect(
            plan.jobs == [
                .adapterCheck,
                .vehicleInfo,
                .moduleDTCs(DemoGarage.airbag.target),
                .moduleDTCs(DemoGarage.abs.target),
                .moduleDTCs(DemoGarage.bodyComputer.target),
                .genericScan,
            ])
        #expect(plan.phases == [.adapter, .car, .codes, .codes, .codes, .codes])
        #expect(!plan.jobs.contains(.moduleDTCs(DemoGarage.steeringColumn.target)))
        #expect(
            !plan.jobs.contains {
                if case .survey = $0 { return true }; return false
            })
    }

    @Test("saved survey replay plan keeps the survey job")
    func replayPlan() throws {
        let vehicle = try garage.addVehicle(name: "Replay car")
        let survey = try Self.saved("ghibli-app-survey")
        let checks = [
            Self.check(.adapterCheck, "ghibli-app-vehicle-info-after-survey"),
            Self.check(survey.job, "ghibli-app-survey"),
            Self.check(.genericScan, "ghibli-app-scan"),
        ]
        let backend = ReplayBackend(displayName: "Ghibli", checks: checks, timing: .immediate)
        let plan = ScanPlan.make(for: vehicle, backend: backend, survey: survey.surveyPlan)
        #expect(plan.jobs.count == 3)
        #expect(plan.jobs[0] == .adapterCheck)
        #expect(plan.jobs[1] == survey.job)
        #expect(plan.jobs[2] == .genericScan)
        #expect(plan.phases == [.adapter, .modules, .codes])
    }

    @Test("deep plan adds a search to the survey")
    func deepPlan() throws {
        let vehicle = try garage.addVehicle(name: "Deep car")
        let report = try Self.saved("ghibli-app-survey")
        let plan = ScanPlan.make(
            for: vehicle,
            canRun: { _ in true },
            survey: report.surveyPlan,
            deep: true)
        guard case .survey(let survey) = plan.jobs[1] else {
            Issue.record("deep scan did not plan a survey")
            return
        }
        #expect(survey.search != nil)
    }

    @Test("demo workbench records one result per scan job and advances phases")
    func runsDemoScan() async throws {
        let vehicle = try garage.addDemoVehicle()
        let session = try #require(vehicle.sessions.first)
        let workbench = Workbench(backend: DemoBackend(), garage: garage)
        await workbench.connect()
        let plan = ScanPlan.make(for: vehicle, backend: DemoBackend(), survey: nil)
        let phases = Task { @MainActor in
            var values: [ScanPhase] = []
            while workbench.activity != nil || values.isEmpty {
                if let phase = workbench.activity?.scan?.current, values.last != phase {
                    values.append(phase)
                }
                try? await Task.sleep(for: .milliseconds(1))
            }
            return values
        }
        let outcome = await workbench.scan(plan, for: vehicle, in: session)
        let observed = await phases.value
        #expect(observed.contains(.adapter))
        #expect(observed.contains(.car))
        #expect(observed.contains(.codes))
        #expect(outcome.outcomes.count == plan.jobs.count)
        #expect(
            vehicle.entries.filter { $0.kind == .result || $0.kind == .failure }.count
                == plan.jobs.count)
        let recordedJobs = vehicle.entries
            .sorted { $0.date < $1.date }
            .compactMap(\.result?.job)
        #expect(recordedJobs == plan.jobs)
        #expect(workbench.activity == nil)
    }

    @Test("cancelling the second job leaves later jobs unrun")
    func cancelsScan() async throws {
        let vehicle = try garage.addDemoVehicle()
        let session = try #require(vehicle.sessions.first)
        let clock = ManualClock()
        let backend = DemoBackend(timing: .recorded, clock: clock)
        let workbench = Workbench(backend: backend, garage: garage)
        await workbench.connect()
        let plan = ScanPlan.make(for: vehicle, backend: DemoBackend(), survey: nil)
        // Every recorded pause now suspends on the clock. Step the first job through its pauses
        // until it completes, then cancel while the second job is suspended on one of its own.
        clock.hold()
        let scan = Task { await workbench.scan(plan, for: vehicle, in: session) }
        while workbench.activity?.scan?.completed != 1 {
            await clock.waitUntilSleeping()
            clock.advance()
        }
        await clock.waitUntilSleeping()
        await workbench.cancel()
        let outcome = await scan.value
        #expect(outcome.outcomes.count == 2)
        #expect(outcome.outcomes.last == .cancelled)
        #expect(vehicle.entries.filter { $0.kind == .result || $0.kind == .failure }.count == 1)
        #expect(workbench.activity == nil)
    }

    @Test("survey decisions keep modules and report a busy search")
    func decisions() throws {
        let empty = try garage.addVehicle(name: "Empty")
        let ghibli = try Self.saved("ghibli-app-survey").surveyReport
        #expect(ScanDecision.needed(report: ghibli, vehicle: empty, outcomes: []) != nil)
        try garage.apply(ghibli.proposedModules(), to: empty)
        #expect(ScanDecision.needed(report: ghibli, vehicle: empty, outcomes: []) == nil)
        let busy = try Self.saved("tiguan-app-search-busy")
        guard
            case .cutShort(let reason)? = ScanDecision.needed(
                report: busy.surveyReport, vehicle: empty, outcomes: [])
        else {
            Issue.record("busy search was not cut short")
            return
        }
        #expect(reason.contains("busy"))
        #expect(
            ScanDecision.needed(
                report: nil, vehicle: empty, outcomes: [.failed(message: "adapter failed")])
                == .cutShort(reason: "The scan could not finish."))
    }

    @Test("deep scan is suggested only once after a survey")
    func deepSuggestion() throws {
        let vehicle = try garage.addVehicle(name: "Suggestion car")
        #expect(!ScanSuggestion.shouldSuggestDeepScan(for: vehicle))
        let normal = Self.emptyReport(search: nil)
        try Self.append(normal, to: vehicle)
        #expect(ScanSuggestion.shouldSuggestDeepScan(for: vehicle))
        let deep = Self.emptyReport(search: ModuleSearch.standard(over: .usbSerial))
        try Self.append(deep, to: vehicle)
        #expect(!ScanSuggestion.shouldSuggestDeepScan(for: vehicle))
    }

    @Test("diagnostic job titles use the scan wording")
    func titles() {
        let plan = SurveyPlan(
            catalogVersion: "test", vehicle: nil, platform: nil, candidates: [], unreachable: [])
        #expect(DiagnosticJob.adapterCheck.title == "Adapter and battery")
        #expect(DiagnosticJob.vehicleInfo.title == "Vehicle information")
        #expect(DiagnosticJob.genericScan.title == "Engine and transmission codes")
        #expect(DiagnosticJob.moduleDTCs(DemoGarage.airbag.target).title == "Module codes")
        #expect(DiagnosticJob.survey(plan).title == "Modules and their codes")
    }

    private static func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures").appendingPathComponent(name)
    }

    private static func saved(_ name: String) throws -> JobResult {
        try JSONDecoder().decode(
            JobResult.self, from: Data(contentsOf: fixture("\(name).result.json")))
    }

    private static func check(_ job: DiagnosticJob, _ name: String) -> SavedCheck {
        SavedCheck(job: job, recorded: .now, transcript: fixture("\(name).txt"))
    }

    private static func append(_ report: SurveyReport, to vehicle: Vehicle) throws {
        let entry = TimelineEntry(kind: .result, title: report.plan.catalogVersion, body: "Survey")
        entry.vehicle = vehicle
        entry.resultData = try JSONEncoder().encode(
            JobResult(
                job: .survey(report.plan), payload: .survey(report), source: .live, transcript: nil)
        )
        vehicle.entries.append(entry)
    }

    private static func emptyReport(search: ModuleSearch?) -> SurveyReport {
        let plan = SurveyPlan(
            catalogVersion: "test", vehicle: nil, platform: nil, candidates: [], unreachable: [],
            search: search)
        return SurveyReport(
            plan: plan, voltage: nil, vehicleInfo: [], modules: [], unanswered: [], notProbed: [],
            stop: nil)
    }
}

private extension JobResult {
    var surveyReport: SurveyReport {
        if case .survey(let report) = payload { return report }
        fatalError("fixture is not a survey result")
    }

    var surveyPlan: SurveyPlan {
        surveyReport.plan
    }
}
