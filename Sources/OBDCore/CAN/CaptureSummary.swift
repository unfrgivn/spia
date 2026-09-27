/// Per-arbitration-ID statistics over a capture. Pure; the CLI feeds it and prints it.
public struct CaptureSummary: Sendable {
    public struct Row: Equatable, Sendable {
        public let id: UInt32
        public let count: Int
        /// Frames per second between the first and last sighting. Nil for a single frame.
        public let hertz: Double?
        /// Distinct payload lengths seen. Almost always one.
        public let lengths: [Int]
        public let last: [UInt8]
        /// Byte positions whose value ever differed from the first frame's. Counters and
        /// sensor values light up here; static IDs stay empty.
        public let changingBytes: [Int]
    }

    private struct Entry {
        var count = 1
        var firstSeen: Duration
        var lastSeen: Duration
        var lengths: Set<Int>
        var first: [UInt8]
        var last: [UInt8]
        var changing: Set<Int> = []
    }

    private var entries: [UInt32: Entry] = [:]
    public private(set) var frameCount = 0

    public init() {}

    public mutating func record(_ frame: CANFrame, at elapsed: Duration) {
        frameCount += 1
        guard var entry = entries[frame.header] else {
            entries[frame.header] = Entry(
                firstSeen: elapsed, lastSeen: elapsed, lengths: [frame.data.count],
                first: frame.data, last: frame.data)
            return
        }
        entry.count += 1
        entry.lastSeen = elapsed
        entry.lengths.insert(frame.data.count)
        for (index, byte) in frame.data.enumerated()
        where index >= entry.first.count || entry.first[index] != byte {
            entry.changing.insert(index)
        }
        entry.last = frame.data
        entries[frame.header] = entry
    }

    public var rows: [Row] {
        entries.sorted { $0.key < $1.key }.map { id, entry in
            let span = entry.lastSeen - entry.firstSeen
            let hertz: Double? =
                entry.count > 1 && span > .zero
                ? Double(entry.count - 1) / (span / .seconds(1)) : nil
            return Row(
                id: id, count: entry.count, hertz: hertz, lengths: entry.lengths.sorted(),
                last: entry.last, changingBytes: entry.changing.sorted())
        }
    }
}
