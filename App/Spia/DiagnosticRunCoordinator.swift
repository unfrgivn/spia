import Observation
import SpiaKit
import SpiaStore

/// The connection, check, and survey state shared by the vehicle dashboard and a problem.
@MainActor
@Observable
final class DiagnosticRunCoordinator {
    let vehicle: Vehicle
    let session: DiagnosticSession?
    let model: AppModel
    var workbench: Workbench?
    var connectRequested = false
    var reviewReport: SurveyReport?
    var historySubject: SessionBoard.Subject?
    private var pendingSurvey = false
    private var pendingThoroughSearch = false

    var isSurveyPending: Bool { pendingSurvey }

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
        }
    }

    func requestSurvey(search: Bool = false) {
        guard let workbench else { return }
        pendingSurvey = true
        pendingThoroughSearch = search
        if workbench.connection.status == nil {
            connectRequested = true
        } else {
            startPendingSurveyIfReady()
        }
    }

    func startPendingSurveyIfReady() {
        guard pendingSurvey, let workbench, workbench.connection.status != nil else { return }
        pendingSurvey = false
        let search = pendingThoroughSearch
        pendingThoroughSearch = false
        connectRequested = false
        runSurvey(search: search)
    }

    func cancelPendingSurveyIfDisconnected() {
        if workbench?.connection.status == nil {
            pendingSurvey = false
            pendingThoroughSearch = false
        }
    }

    func surveyAction() -> (() -> Void)? {
        guard let workbench else { return nil }
        if let plan = try? model.surveyPlan(for: vehicle, workbench: workbench),
            !workbench.canRun(.survey(plan))
        {
            return nil
        }
        return { [weak self] in self?.runSurvey() }
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

    private func runSurvey(search: Bool = false) {
        do {
            guard let workbench else { return }
            let plan = try model.surveyPlan(for: vehicle, workbench: workbench, search: search)
            run(.survey(plan))
        } catch { workbench?.lastError = error.readable }
    }
}
