import Foundation

public protocol SessionClock: Sendable {
    var now: Duration { get }
    func sleep(for duration: Duration) async throws
}

public struct WallClock: SessionClock, Sendable {
    private let origin: ContinuousClock.Instant
    private let clock: ContinuousClock

    public init() { clock = ContinuousClock(); origin = clock.now }
    public var now: Duration { origin.duration(to: clock.now) }
    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}
