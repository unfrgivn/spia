import Foundation

/// Wraps a live transport and writes every byte in both directions to a transcript file.
/// The result is a verbatim capture that `ReplayTransport` can play back in tests.
public actor RecordingTransport: Transport {
    private let base: Transport
    private let url: URL
    private let clock = ContinuousClock()
    private var opened: ContinuousClock.Instant?
    private var handle: FileHandle?

    public init(_ base: Transport, writingTo url: URL) {
        self.base = base
        self.url = url
    }

    public func open() async throws {
        try await base.open()
        try Data().write(to: url)
        handle = try FileHandle(forWritingTo: url)
        opened = clock.now
    }

    public func close() async {
        await base.close()
        try? handle?.close()
        handle = nil
    }

    public func write(_ bytes: [UInt8]) async throws {
        try await base.write(bytes)
        try record(.tx, bytes)
    }

    public func read(timeout: Duration) async throws -> [UInt8] {
        let bytes = try await base.read(timeout: timeout)
        if !bytes.isEmpty {
            try record(.rx, bytes)
        }
        return bytes
    }

    private func record(_ direction: TranscriptEvent.Direction, _ bytes: [UInt8]) throws {
        guard let handle, let opened else {
            return
        }
        let elapsed = opened.duration(to: clock.now) / .milliseconds(1)
        let event = TranscriptEvent(
            milliseconds: UInt64(max(0, elapsed)), direction: direction, bytes: bytes)
        try handle.write(contentsOf: Data((Transcript.encode(event) + "\n").utf8))
    }
}
