import Foundation

/// What the recording said should happen next, when the code under test did something else.
public enum ReplayExpectation: Equatable, Sendable {
    case write([UInt8])
    case read([UInt8])
    case end
}

public enum ReplayError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The code under test sent something other than what the recorded session sent.
    case unexpectedWrite(expected: ReplayExpectation, got: [UInt8])
    /// The code under test read when the recording says it should have written next.
    case unexpectedRead(pendingWrite: [UInt8])
    case exhausted

    public var description: String {
        switch self {
        case .unexpectedWrite(let expected, let got):
            let sent = String(decoding: got, as: UTF8.self)
            switch expected {
            case .write(let bytes):
                return
                    "replay: expected write \"\(String(decoding: bytes, as: UTF8.self))\", got \"\(sent)\""
            case .read(let bytes):
                return
                    "replay: expected to read \"\(String(decoding: bytes, as: UTF8.self))\" next, got write \"\(sent)\""
            case .end:
                return "replay: expected the transcript to end, got write \"\(sent)\""
            }
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
    private var lastWrite: (recordedMilliseconds: UInt64, instant: Duration)?
    private let clock: any SessionClock

    public init(
        events: [TranscriptEvent], timing: ReplayTiming = .immediate,
        clock: any SessionClock = WallClock()
    ) {
        self.events = events
        self.timing = timing
        self.clock = clock
    }

    public init(
        contentsOf url: URL, timing: ReplayTiming = .immediate,
        clock: any SessionClock = WallClock()
    ) throws {
        events = try Transcript.decodeFile(String(contentsOf: url, encoding: .utf8))
        self.timing = timing
        self.clock = clock
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
            throw ReplayError.unexpectedWrite(expected: .end, got: bytes)
        }
        let event = events[cursor]
        guard event.direction == .tx, event.bytes == bytes else {
            throw ReplayError.unexpectedWrite(
                expected: event.direction == .tx ? .write(event.bytes) : .read(event.bytes),
                got: bytes)
        }
        cursor += 1
        if timing == .recorded {
            lastWrite = (event.milliseconds, clock.now)
        }
    }

    public func read(timeout: Duration) async throws -> [UInt8] {
        // A read cancelled before it got to run must not hand back data, even when the
        // recording says the reply is already due.
        try Task.checkCancellation()
        guard timing == .recorded else { return try await readImmediately(timeout: timeout) }
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
            try await clock.sleep(for: duration)
            guard cursor == index, index < events.count, events[index].direction == .rx else {
                return []
            }
            cursor += 1
            return events[index].bytes
        case .wait(let duration):
            try await clock.sleep(for: duration)
            return []
        case .exhausted:
            throw ReplayError.exhausted
        }
    }

    /// The recording's next byte, at once. When the recording says we write next, there is
    /// nothing to read yet: like a live adapter with no data, the read waits out its timeout and
    /// returns empty, so a monitor running to a deadline idles instead of spinning.
    private func readImmediately(timeout: Duration) async throws -> [UInt8] {
        guard cursor < events.count else {
            throw ReplayError.exhausted
        }
        let event = events[cursor]
        guard event.direction == .rx else {
            try await clock.sleep(for: timeout)
            return []
        }
        cursor += 1
        return event.bytes
    }

    /// Decides whether a paced read can deliver its next event without performing any I/O or
    /// sleeping. The transport applies the decision and owns cursor advancement.
    public static func readDecision(
        events: [TranscriptEvent], cursor: Int, lastWriteRecordedMilliseconds: UInt64?,
        lastWriteInstant: Duration?, now: Duration,
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
        let remaining = due - now
        if remaining <= .zero { return .deliver }
        return remaining <= timeout ? .deliverAfter(remaining) : .wait(timeout)
    }

    /// True once every recorded event has been consumed.
    public var isFinished: Bool {
        cursor == events.count
    }
}
