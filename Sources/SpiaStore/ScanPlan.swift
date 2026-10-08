import SpiaKit

/// The ordered, runnable work for one scan.
public struct ScanPlan: Sendable, Equatable {
    public let jobs: [DiagnosticJob]
    public let phases: [ScanPhase]

    public init(jobs: [DiagnosticJob], phases: [ScanPhase]) {
        self.jobs = jobs
        self.phases = phases
    }

    public func phase(for index: Int) -> ScanPhase { phases[index] }

    /// Builds a plan without touching the adapter or the store.
    public static func make(
        for vehicle: Vehicle,
        backend: any DiagnosticsBackend,
        survey: SurveyPlan?,
        deep: Bool = false
    ) -> ScanPlan {
        make(for: vehicle, canRun: backend.canRun, survey: survey, deep: deep)
    }

    /// Builds a plan from capabilities without contacting an adapter.
    public static func make(
        for vehicle: Vehicle,
        canRun: (DiagnosticJob) -> Bool,
        survey: SurveyPlan?,
        deep: Bool = false
    ) -> ScanPlan {
        var jobs: [DiagnosticJob] = []
        var phases: [ScanPhase] = []
        append(
            .adapterCheck, phase: .adapter, if: canRun(.adapterCheck), to: &jobs,
            phases: &phases)
        let plannedSurvey = deep ? survey?.deepened() : survey
        if let plannedSurvey, canRun(.survey(plannedSurvey)) {
            jobs.append(.survey(plannedSurvey))
            phases.append(.modules)
        } else {
            append(
                .vehicleInfo, phase: .car, if: canRun(.vehicleInfo), to: &jobs,
                phases: &phases)
            for module in vehicle.orderedModules {
                guard let target = module.target else { continue }
                let job = DiagnosticJob.moduleDTCs(target)
                append(job, phase: .codes, if: canRun(job), to: &jobs, phases: &phases)
            }
        }
        append(
            .genericScan, phase: .codes, if: canRun(.genericScan), to: &jobs,
            phases: &phases)
        return ScanPlan(jobs: jobs, phases: phases)
    }

    private static func append(
        _ job: DiagnosticJob, phase: ScanPhase, if runnable: Bool, to jobs: inout [DiagnosticJob],
        phases: inout [ScanPhase]
    ) {
        guard runnable else { return }
        jobs.append(job)
        phases.append(phase)
    }
}

/// The result of running all or part of a scan.
public struct ScanOutcome: Sendable, Equatable {
    public let outcomes: [CheckOutcome]
    public let surveyReport: SurveyReport?

    public init(outcomes: [CheckOutcome], surveyReport: SurveyReport? = nil) {
        self.outcomes = outcomes
        self.surveyReport = surveyReport
    }
}

/// A decision the caller may need to present after a scan.
public enum ScanDecision: Sendable, Equatable {
    case keepModules(SurveyReport)
    case cutShort(reason: String)

    public static func needed(
        report: SurveyReport?, vehicle: Vehicle, outcomes: [CheckOutcome]
    ) -> ScanDecision? {
        if let report {
            if let reason = report.search?.stopReason ?? report.stop?.reason {
                return .cutShort(reason: reason)
            }
            let saved = vehicle.modules.reduce(into: [ModuleTarget: String]()) { labels, module in
                if let target = module.target { labels[target] = module.label }
            }
            let proposed = report.proposedModules()
            if proposed.contains(where: { saved[$0.target] != $0.label }) {
                return .keepModules(report)
            }
        }
        if outcomes.contains(where: { outcome in
            if case .failed = outcome { return true }
            return false
        }) {
            return .cutShort(reason: "The scan could not finish.")
        }
        return nil
    }
}

/// Rules for showing the one-time deep-scan suggestion.
public enum ScanSuggestion {
    public static func shouldSuggestDeepScan(for vehicle: Vehicle) -> Bool {
        let results = vehicle.entries.filter { $0.kind == .result }
        let hasScan = results.contains { entry in
            guard let result = entry.result else { return false }
            return result.job == .genericScan || result.job.isSurvey
        }
        guard hasScan else { return false }
        let hasDeepScan = results.contains { entry in
            guard let result = entry.result else { return false }
            guard case .survey(let report) = result.payload else { return false }
            return report.plan.search != nil
        }
        guard !hasDeepScan else { return false }
        return results.contains { entry in
            guard let result = entry.result, case .survey(let report) = result.payload else {
                return false
            }
            return !report.plan.catalogContributedMakeSpecificCandidates
        }
    }
}

private extension DiagnosticJob {
    var isSurvey: Bool {
        if case .survey = self { return true }
        return false
    }
}
