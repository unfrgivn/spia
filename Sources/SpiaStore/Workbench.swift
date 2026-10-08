import Foundation
import Observation
import SpiaKit

private extension DiagnosticJob {
    var stopsScan: Bool {
        switch self {
        case .vehicleInfo, .survey: return true
        case .adapterCheck, .genericScan, .moduleDTCs: return false
        }
    }
}

/// What a running check is doing right now, for the activity panel.
public struct CheckActivity: Equatable, Sendable {
    public let job: DiagnosticJob
    public let vehicleID: UUID
    public let sessionID: UUID?
    public internal(set) var steps: [String] = []
    public internal(set) var warnings: [String] = []
    /// Set while the check is paused for the person at the car.
    public internal(set) var prompt: Prompt?
    public internal(set) var scan: ScanProgress? = nil

    public struct Prompt: Equatable, Sendable {
        public let id: UUID
        public let action: UserAction
    }

    public var currentStep: String? { steps.last }
}

public struct ScanProgress: Equatable, Sendable {
    public let phases: [ScanPhase]
    public internal(set) var current: ScanPhase
    public internal(set) var completed: Int
    public let total: Int
}

/// How a check ended, for callers that act on it (the assistant feeds it back to the model).
public enum CheckOutcome: Sendable, Equatable {
    case completed(JobResult)
    case failed(message: String)
    case cancelled
    /// Another check was already running.
    case notStarted
}

/// Connects the screens to one adapter (or the demo car) and records what checks find.
@MainActor
@Observable
public final class Workbench {
    public let adapter: AdapterDescriptor
    public private(set) var connection: ConnectionState = .disconnected
    public private(set) var liveStatus: AdapterStatus?
    public private(set) var activity: CheckActivity?
    /// The most recent problem to show the user, cleared when they act.
    public var lastError: String?

    private let backend: any DiagnosticsBackend
    private let garage: Garage
    private var observerReady = false
    private var observerWaiters: [CheckedContinuation<Void, Never>] = []

    public init(backend: any DiagnosticsBackend, garage: Garage) {
        self.backend = backend
        self.garage = garage
        adapter = backend.adapter
        Task { [weak self, backend] in
            for await state in await backend.states() {
                guard let self else { return }
                self.connection = state
                self.liveStatus = self.isPhysical ? state.status : nil
                if !self.observerReady {
                    self.observerReady = true
                    let waiters = self.observerWaiters
                    self.observerWaiters.removeAll()
                    for waiter in waiters { waiter.resume() }
                }
            }
        }
    }

    public var isBusy: Bool { activity != nil || connection == .connecting }

    /// Whether `job` can get an answer from this adapter, or from the demo car's recordings.
    public func canRun(_ job: DiagnosticJob) -> Bool { backend.canRun(job) }

    public func connect() async {
        lastError = nil
        await waitForObserver()
        do {
            try await backend.connect()
        } catch {
            lastError = error.readable
        }
        connection = await backend.currentState()
        liveStatus = isPhysical ? connection.status : nil
    }

    public func disconnect() async {
        await backend.disconnect()
        connection = await backend.currentState()
        liveStatus = isPhysical ? connection.status : nil
    }

    /// Runs `job` on `vehicle`, keeping `activity` current, and saves the outcome to the car's
    /// history, linked to `session` when the check was taken for a problem. A check the user
    /// cancels is not recorded.
    @discardableResult
    public func run(
        _ job: DiagnosticJob, for vehicle: Vehicle, in session: DiagnosticSession? = nil
    ) async -> CheckOutcome {
        guard activity == nil else { return .notStarted }
        return await runJob(job, for: vehicle, in: session, scan: nil, ownsActivity: true)
    }

    /// Runs all jobs in a scan as one activity and records each result independently.
    @discardableResult
    public func scan(
        _ plan: ScanPlan, for vehicle: Vehicle, in session: DiagnosticSession? = nil
    ) async -> ScanOutcome {
        guard activity == nil else { return ScanOutcome(outcomes: [.notStarted]) }
        guard let first = plan.jobs.first else { return ScanOutcome(outcomes: []) }
        lastError = nil
        let phases = plan.phases
        activity = CheckActivity(
            job: first, vehicleID: vehicle.id, sessionID: session?.id,
            scan: ScanProgress(
                phases: phases, current: phases[0], completed: 0, total: plan.jobs.count))
        defer { activity = nil }
        var outcomes: [CheckOutcome] = []
        var report: SurveyReport?
        for (index, job) in plan.jobs.enumerated() {
            let phase = plan.phase(for: index)
            activity?.scan?.current = phase
            let outcome = await runJob(
                job, for: vehicle, in: session, scan: phase, ownsActivity: false)
            outcomes.append(outcome)
            if case .completed(let result) = outcome, case .survey(let value) = result.payload {
                report = value
            }
            activity?.scan?.completed = index + 1
            if case .cancelled = outcome { break }
            if case .failed = outcome, job.stopsScan { break }
        }
        return ScanOutcome(outcomes: outcomes, surveyReport: report)
    }

    private func runJob(
        _ job: DiagnosticJob, for vehicle: Vehicle, in session: DiagnosticSession?,
        scan phase: ScanPhase?, ownsActivity: Bool
    ) async -> CheckOutcome {
        var outcome = CheckOutcome.cancelled
        let transcript = garage.newTranscript(for: vehicle)
        if ownsActivity {
            activity = CheckActivity(job: job, vehicleID: vehicle.id, sessionID: session?.id)
        }
        defer { if ownsActivity { activity = nil } }
        if let phase { activity?.scan?.current = phase }
        activity?.steps.removeAll()
        activity?.warnings.removeAll()
        activity?.prompt = nil

        for await event in await backend.run(job, transcript: transcript.url) {
            switch event {
            case .started:
                break
            case .step(let text):
                activity?.steps.append(text)
                if activity?.scan != nil {
                    activity?.scan?.current = ScanPhase.current(for: job, step: text)
                }
            case .warning(let text):
                activity?.warnings.append(text)
            case .needsUser(let id, let action):
                activity?.prompt = CheckActivity.Prompt(id: id, action: action)
            case .userConfirmed:
                activity?.prompt = nil
            case .completed(let result):
                outcome = .completed(result)
                save {
                    try garage.record(
                        result, warnings: activity?.warnings ?? [], transcriptPath: transcript.path,
                        for: vehicle, in: session)
                }
            case .failed(let failure):
                guard !failure.cancelled else { break }
                outcome = .failed(message: failure.message)
                save {
                    try garage.recordFailure(
                        of: job, failure, warnings: activity?.warnings ?? [],
                        transcriptPath: transcript.path,
                        for: vehicle, in: session)
                }
            }
        }
        connection = await backend.currentState()
        return outcome
    }

    /// The user did what the prompt asked.
    public func confirmPrompt() async {
        guard let prompt = activity?.prompt else { return }
        activity?.prompt = nil
        await backend.confirm(prompt.id)
    }

    public func cancel() async {
        await backend.cancel()
    }

    private func save(_ write: () throws -> Void) {
        do {
            try write()
        } catch {
            lastError = "Couldn't save the result: \(error.readable)"
        }
    }

    private func waitForObserver() async {
        guard !observerReady else { return }
        await withCheckedContinuation { continuation in
            observerWaiters.append(continuation)
        }
    }

    private var isPhysical: Bool {
        adapter.kind == .usbSerial || adapter.kind == .bluetooth
    }
}
