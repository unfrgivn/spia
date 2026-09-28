import Foundation

public enum ReplayError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The code under test sent something other than what the recorded session sent.
    case unexpectedWrite(expected: [UInt8]?, got: [UInt8])
    /// The code under test read when the recording says it should have written next.
    case unexpectedRead(pendingWrite: [UInt8])
    case exhausted

    public var description: String {
        switch self {
        case .unexpectedWrite(let expected, let got):
            let want = expected.map { String(decoding: $0, as: UTF8.self) } ?? "<end of transcript>"
            return
                "replay: expected write \"\(want)\", got \"\(String(decoding: got, as: UTF8.self))\""
        case .unexpectedRead(let pending):
            return "replay: read before writing \"\(String(decoding: pending, as: UTF8.self))\""
        case .exhausted:
            return "replay: transcript exhausted"
        }
    }
}

public enum ReplayTiming: Equatable, Sendable {
    case immediate
    case recorded
}

public enum ReplayReadDecision: Equatable, Sendable {
    case deliver
    case deliverAfter(Duration)
    case wait(Duration)
    case exhausted
}

/// Plays back a recorded transcript. Writes must match the recording byte for byte; reads
/// return the recorded RX chunks in order. Nothing here is invented: if the adapter never said
/// it, this transport never says it either.
public actor ReplayTransport: Transport {
    private let events: [TranscriptEvent]
    private var timing: ReplayTiming
    private var cursor = 0
    private var lastWrite: (recordedMilliseconds: UInt64, instant: ContinuousClock.Instant)?
    private let clock = ContinuousClock()

    public init(events: [TranscriptEvent], timing: ReplayTiming = .immediate) {
        self.events = events
        self.timing = timing
    }

    public init(contentsOf url: URL, timing: ReplayTiming = .immediate) throws {
        events = try Transcript.decodeFile(String(contentsOf: url, encoding: .utf8))
        self.timing = timing
    }

    public func open() async throws {}

    public func close() async {}

    /// Recorded sessions have no line; the rate is whatever it was when recorded.
    public func setBaud(_ baud: Int) async throws {}

    public func setTiming(_ timing: ReplayTiming) {
        self.timing = timing
        lastWrite = nil
    }

    public func write(_ bytes: [UInt8]) async throws {
        guard cursor < events.count else {
            throw ReplayError.unexpectedWrite(expected: nil, got: bytes)
        }
        let event = events[cursor]
        guard event.direction == .tx, event.bytes == bytes else {
            throw ReplayError.unexpectedWrite(
                expected: event.direction == .tx ? event.bytes : nil, got: bytes)
        }
        cursor += 1
        if timing == .recorded {
            lastWrite = (event.milliseconds, clock.now)
        }
    }

    public func read(timeout: Duration) async throws -> [UInt8] {
        guard timing == .recorded else { return try readImmediately() }
        let decision = Self.readDecision(
            events: events, cursor: cursor,
            lastWriteRecordedMilliseconds: lastWrite?.recordedMilliseconds,
            lastWriteInstant: lastWrite?.instant, now: clock.now, timeout: timeout)
        switch decision {
        case .deliver:
            let bytes = events[cursor].bytes
            cursor += 1
            return bytes
        case .deliverAfter(let duration):
            let index = cursor
            try await Task.sleep(for: duration)
            guard cursor == index, index < events.count, events[index].direction == .rx else {
                return []
            }
            cursor += 1
            return events[index].bytes
        case .wait(let duration):
            try await Task.sleep(for: duration)
            return []
        case .exhausted:
            throw ReplayError.exhausted
        }
    }

    private func readImmediately() throws -> [UInt8] {
        guard cursor < events.count else {
            throw ReplayError.exhausted
        }
        let event = events[cursor]
        guard event.direction == .rx else {
            throw ReplayError.unexpectedRead(pendingWrite: event.bytes)
        }
        cursor += 1
        return event.bytes
    }

    /// Decides whether a paced read can deliver its next event without performing any I/O or
    /// sleeping. The transport applies the decision and owns cursor advancement.
    public static func readDecision(
        events: [TranscriptEvent], cursor: Int, lastWriteRecordedMilliseconds: UInt64?,
        lastWriteInstant: ContinuousClock.Instant?, now: ContinuousClock.Instant,
        timeout: Duration
    ) -> ReplayReadDecision {
        guard cursor < events.count else { return .exhausted }
        let event = events[cursor]
        guard event.direction == .rx else { return .wait(timeout) }
        guard let lastWriteRecordedMilliseconds, let lastWriteInstant else {
            return .deliver
        }
        let latency: UInt64
        if event.milliseconds >= lastWriteRecordedMilliseconds {
            latency = event.milliseconds - lastWriteRecordedMilliseconds
        } else {
            latency = 0
        }
        let clampedLatency = min(latency, UInt64(Int64.max))
        let due = lastWriteInstant + .milliseconds(Int64(clampedLatency))
        let remaining = now.duration(to: due)
        if remaining <= .zero { return .deliver }
        return remaining <= timeout ? .deliverAfter(remaining) : .wait(timeout)
    }

    /// True once every recorded event has been consumed.
    public var isFinished: Bool {
        cursor == events.count
    }
}
