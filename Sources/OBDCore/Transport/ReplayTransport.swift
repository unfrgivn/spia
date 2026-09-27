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

/// Plays back a recorded transcript. Writes must match the recording byte for byte; reads
/// return the recorded RX chunks in order. Nothing here is invented: if the adapter never said
/// it, this transport never says it either.
public actor ReplayTransport: Transport {
    private let events: [TranscriptEvent]
    private var cursor = 0

    public init(events: [TranscriptEvent]) {
        self.events = events
    }

    public init(contentsOf url: URL) throws {
        events = try Transcript.decodeFile(String(contentsOf: url, encoding: .utf8))
    }

    public func open() async throws {}

    public func close() async {}

    /// Recorded sessions have no line; the rate is whatever it was when recorded.
    public func setBaud(_ baud: Int) async throws {}

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
    }

    public func read(timeout: Duration) async throws -> [UInt8] {
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

    /// True once every recorded event has been consumed.
    public var isFinished: Bool {
        cursor == events.count
    }
}
