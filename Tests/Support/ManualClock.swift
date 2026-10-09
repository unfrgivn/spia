import Foundation
import OBDCore

/// A clock the test turns by hand, for replaying recordings at their recorded pace in no real
/// time. Sleeping advances the clock by the requested duration and returns at once, so a paced
/// replay's elapsed time is exact and the test never waits on the wall. After `hold()`, a sleep
/// suspends instead until the test calls `advance()` or cancels the sleeper: that is how a test
/// stops a check between two recorded exchanges. One sleeper at a time; a connection is one
/// chain of awaits, which is all these tests drive.
public final class ManualClock: SessionClock, @unchecked Sendable {
    private let lock = NSLock()
    private var elapsed: Duration = .zero
    private var held = false
    private var sleeper: (duration: Duration, continuation: CheckedContinuation<Void, Error>)?
    private var observers: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public var now: Duration { withLock { elapsed } }

    /// From now on, sleeps suspend until `advance()` or cancellation.
    public func hold() {
        withLock { held = true }
    }

    /// Returns once a sleeper is suspended on the held clock.
    public func waitUntilSleeping() async {
        await withCheckedContinuation { continuation in
            let sleeping = withLock { () -> Bool in
                if sleeper != nil { return true }
                observers.append(continuation)
                return false
            }
            if sleeping { continuation.resume() }
        }
    }

    /// Lets the suspended sleeper through, moving the clock by what it asked for.
    public func advance() {
        let released = withLock { () -> CheckedContinuation<Void, Error>? in
            guard let sleeper else { return nil }
            elapsed += sleeper.duration
            self.sleeper = nil
            return sleeper.continuation
        }
        released?.resume()
    }

    public func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        let suspends = withLock { () -> Bool in
            if !held { elapsed += duration }
            return held
        }
        guard suspends else { return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                // Cancellation that arrived before the continuation was installed would find no
                // sleeper to resume, so check for it under the same lock.
                let (waiting, cancelled) = withLock {
                    () -> ([CheckedContinuation<Void, Never>], Bool) in
                    if Task.isCancelled { return ([], true) }
                    sleeper = (duration, continuation)
                    defer { observers = [] }
                    return (observers, false)
                }
                if cancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                for observer in waiting { observer.resume() }
            }
        } onCancel: {
            let continuation = withLock { () -> CheckedContinuation<Void, Error>? in
                defer { sleeper = nil }
                return sleeper?.continuation
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

extension ManualClock {
    /// What a paced replay of these events takes on the clock: for each command, the time from
    /// its write to the last chunk of its reply. The tester's own pauses between a reply and the
    /// next command are not replayed, so they don't count.
    public static func pacedDuration<Events: Collection>(of events: Events) -> Duration
    where Events.Element == TranscriptEvent {
        var position: UInt64?
        var total: UInt64 = 0
        for event in events {
            switch event.direction {
            case .tx:
                position = event.milliseconds
            case .rx:
                if let at = position, event.milliseconds > at {
                    total += event.milliseconds - at
                }
                position = event.milliseconds
            }
        }
        return .milliseconds(Int64(min(total, UInt64(Int64.max))))
    }
}
