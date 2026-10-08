import Observation
import SpiaKit
import SpiaStore

/// The connection and diagnostic state shared by the vehicle dashboard and a problem.
@MainActor
@Observable
final class DiagnosticRunCoordinator {
    let vehicle: Vehicle
    let session: DiagnosticSession?
    let model: AppModel
    var workbench: Workbench?
    var connectRequested = false
    var reviewReport: SurveyReport?
    var scanCutShortReason: String?
    var historySubject: SessionBoard.Subject?
    private var pendingScan = false
    private var pendingDeepScan = false

    var isScanPending: Bool { pendingScan }

    var reader: ((SessionBoard.Subject) -> Void)? {
        guard workbench?.activity == nil else { return nil }
        return { [weak self] subject in self?.run(subject.job) }
    }

    var reading: (subject: SessionBoard.Subject, step: String?, cancel: () -> Void)? {
        guard let workbench, let activity = workbench.activity,
            activity.vehicleID == vehicle.id, activity.prompt == nil,
            let subject = SessionBoard.Subject(job: activity.job)
        else { return nil }
        return (subject, activity.currentStep, { Task { await workbench.cancel() } })
    }

    func unreadable(for board: SessionBoard) -> [SessionBoard.Subject: String] {
        guard let workbench else { return [:] }
        var reasons: [SessionBoard.Subject: String] = [:]
        for row in board.rows where row.status == .notRead && !workbench.canRun(row.subject.job) {
            reasons[row.subject] =
                switch workbench.adapter.kind {
                case .demo: "Not in the demo"
                case .replay: "Not recorded yet"
                default: "Can't be read here"
                }
        }
        return reasons
    }

    init(vehicle: Vehicle, session: DiagnosticSession?, model: AppModel) {
        self.vehicle = vehicle
        self.session = session
        self.model = model
        workbench = model.workbench(for: vehicle)
    }

    func refresh(_ workbench: Workbench) {
        self.workbench = workbench
    }

    func run(_ job: DiagnosticJob) {
        guard let workbench else { return }
        guard workbench.connection.status != nil else {
            connectRequested = true
            return
        }
        Task {
            let outcome = await workbench.run(job, for: vehicle, in: session)
            if case .completed(let result) = outcome, case .survey(let report) = result.payload {
                reviewReport = report
            }
            await model.interpreter.refresh(vehicle, adapter: workbench.connection.status)
        }
    }

    func run(_ check: StoredCheck) {
        guard let job = check.job else { return }
        run(job)
    }

    func scan(deep: Bool = false) {
        guard let workbench else { return }
        pendingScan = true
        pendingDeepScan = deep
        if workbench.connection.status == nil {
            connectRequested = true
        } else {
            startPendingScanIfReady()
        }
    }

    func startPendingScanIfReady() {
        guard pendingScan, let workbench, workbench.connection.status != nil else { return }
        pendingScan = false
        let deep = pendingDeepScan
        pendingDeepScan = false
        connectRequested = false
        startScan(deep: deep)
    }

    func cancelPendingScanIfDisconnected() {
        if workbench?.connection.status == nil {
            pendingScan = false
            pendingDeepScan = false
        }
    }

    func scanAction(deep: Bool = false) -> (() -> Void)? {
        guard let workbench else { return nil }
        guard workbench.activity == nil else { return nil }
        return { [weak self] in self?.scan(deep: deep) }
    }

    func deepScanMessage() -> String? {
        guard let workbench, workbench.connection.status != nil,
            let plan = try? model.surveyPlan(for: vehicle, workbench: workbench, search: true),
            let search = plan.search
        else { return nil }
        return search.confirmationMessage(
            connection: workbench.adapter.kind, candidates: plan.candidates)
    }

    func thoroughSearchMessage(for report: SurveyReport) -> String? {
        guard report.plan.search == nil, report.detectedProtocol?.surveyUnsupportedNote == nil,
            !vehicle.isDemo, let workbench, workbench.connection.status != nil,
            let plan = try? model.surveyPlan(for: vehicle, workbench: workbench, search: true),
            workbench.canRun(.survey(plan)), let search = plan.search
        else { return nil }
        return search.confirmationMessage(
            connection: workbench.adapter.kind, candidates: plan.candidates)
    }

    private func startScan(deep: Bool) {
        do {
            guard let workbench else { return }
            let survey = try model.surveyPlan(for: vehicle, workbench: workbench)
            let plan = ScanPlan.make(
                for: vehicle, canRun: { workbench.canRun($0) }, survey: survey, deep: deep)
            Task {
                let outcome = await workbench.scan(plan, for: vehicle, in: session)
                switch ScanDecision.needed(
                    report: outcome.surveyReport, vehicle: vehicle, outcomes: outcome.outcomes)
                {
                case .keepModules(let report): reviewReport = report
                case .cutShort(let reason): scanCutShortReason = reason
                case nil: break
                }
                await model.interpreter.refresh(vehicle, adapter: workbench.connection.status)
            }
        } catch { workbench?.lastError = error.readable }
    }
}

extension StoredCheck {
    var job: DiagnosticJob? {
        switch kind {
        case .adapterCheck: .adapterCheck
        case .vehicleInfo: .vehicleInfo
        case .genericScan: .genericScan
        case .moduleCodes: module.map(DiagnosticJob.moduleDTCs)
        }
    }
}
