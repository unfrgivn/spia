import Foundation
import Observation
import SpiaKit

/// What a running check is doing right now, for the activity panel.
public struct CheckActivity: Equatable, Sendable {
    public let job: DiagnosticJob
    public let sessionID: UUID
    public internal(set) var steps: [String] = []
    public internal(set) var warnings: [String] = []
    /// Set while the check is paused for the person at the car.
    public internal(set) var prompt: Prompt?

    public struct Prompt: Equatable, Sendable {
        public let id: UUID
        public let action: UserAction
    }

    public var currentStep: String? { steps.last }
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
    public private(set) var activity: CheckActivity?
    /// The most recent problem to show the user, cleared when they act.
    public var lastError: String?

    private let backend: any DiagnosticsBackend
    private let garage: Garage

    public init(backend: any DiagnosticsBackend, garage: Garage) {
        self.backend = backend
        self.garage = garage
        adapter = backend.adapter
        Task { [weak self, backend] in
            for await state in await backend.states() {
                guard let self else { return }
                self.connection = state
            }
        }
    }

    public var isBusy: Bool { activity != nil || connection == .connecting }

    public func connect() async {
        lastError = nil
        do {
            try await backend.connect()
        } catch {
            lastError = String(describing: error)
        }
        connection = await backend.currentState()
    }

    public func disconnect() async {
        await backend.disconnect()
        connection = await backend.currentState()
    }

    /// Runs `job` for `session`, keeping `activity` current, and saves the outcome to the
    /// session's timeline. A check the user cancels is not recorded.
    @discardableResult
    public func run(_ job: DiagnosticJob, in session: DiagnosticSession) async -> CheckOutcome {
        guard activity == nil else { return .notStarted }
        var outcome = CheckOutcome.cancelled
        lastError = nil
        let transcript = garage.newTranscript(for: session)
        activity = CheckActivity(job: job, sessionID: session.id)
        defer { activity = nil }

        for await event in await backend.run(job, transcript: transcript.url) {
            switch event {
            case .started:
                break
            case .step(let text):
                activity?.steps.append(text)
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
                        in: session)
                }
            case .failed(let failure):
                guard !failure.cancelled else { break }
                outcome = .failed(message: failure.message)
                save {
                    try garage.recordFailure(
                        of: job, failure, warnings: activity?.warnings ?? [],
                        transcriptPath: transcript.path,
                        in: session)
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
            lastError = "Couldn't save the result: \(error)"
        }
    }
}
