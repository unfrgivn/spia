import Foundation

/// A completed live check that can be replayed without connecting to the vehicle.
public struct SavedCheck: Sendable, Equatable {
    public let job: DiagnosticJob
    public let recorded: Date
    public let transcript: URL

    public init(job: DiagnosticJob, recorded: Date, transcript: URL) {
        self.job = job
        self.recorded = recorded
        self.transcript = transcript
    }
}
