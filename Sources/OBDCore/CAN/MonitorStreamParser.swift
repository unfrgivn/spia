import Foundation

/// One thing the adapter printed while monitoring the bus (`ATMA` / `STMA`).
public enum MonitorEvent: Equatable, Sendable {
    case frame(CANFrame)
    case message(ELM327AdapterMessage)
    /// The `>` prompt: monitoring has stopped and the adapter is ready for a command.
    case prompt
    /// A line that was neither a frame nor a known status. Garbled by a bus error, usually.
    case unparsable(String)
}

/// Incremental line splitter for the monitor stream. Bytes arrive in arbitrary chunks, so a
/// frame can straddle two reads; this keeps the unfinished tail until the next `\r` lands.
///
/// A stream parser must not die on one bad line, so malformed input becomes `.unparsable`
/// instead of throwing.
public struct MonitorStreamParser: Sendable {
    private static let maximumPendingBytes = 4096
    private var pending: [UInt8] = []
    private var discardingOversizedLine = false

    public init() {}

    public mutating func feed(_ bytes: [UInt8]) -> [MonitorEvent] {
        var events: [MonitorEvent] = []
        for byte in bytes {
            if discardingOversizedLine {
                if byte == 0x0D || byte == 0x0A { discardingOversizedLine = false }
                continue
            }
            if byte == 0x0D || byte == 0x0A {
                let line = String(decoding: pending, as: UTF8.self)
                pending.removeAll(keepingCapacity: true)
                events.append(contentsOf: Self.events(for: line))
            } else {
                pending.append(byte)
                if pending.count > Self.maximumPendingBytes {
                    events.append(.unparsable(String(decoding: pending, as: UTF8.self)))
                    pending.removeAll(keepingCapacity: true)
                    discardingOversizedLine = true
                }
            }
        }
        // The prompt never gets a line ending, so it would otherwise sit in `pending` forever.
        if pending == [UInt8(ascii: ">")] {
            pending.removeAll()
            events.append(.prompt)
        }
        return events
    }

    /// One line becomes a frame and, separately, any `<...>` status the adapter appended to it.
    /// While monitoring, STN firmware prints raw broadcast frames whose first byte is not a valid
    /// ISO-TP PCI as `1028001122334455<DATA ERROR`. The frame is fine, it just is not a
    /// diagnostic message, so it must not be lost.
    private static func events(for rawLine: String) -> [MonitorEvent] {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.isEmpty {
            return []
        }
        if line == ">" {
            return [.prompt]
        }
        if let message = ELM327AdapterMessage(line: line) {
            return [.message(message)]
        }
        var body = Substring(line)
        var trailing: [MonitorEvent] = []
        if let marker = line.firstIndex(of: "<"), marker != line.startIndex {
            body = line[..<marker]
            let suffix = String(line[marker...])
            trailing = [
                ELM327AdapterMessage(line: suffix).map(MonitorEvent.message) ?? .unparsable(suffix)
            ]
        }
        let hex = body.filter { !$0.isWhitespace }
        guard Self.isValidFrameShape(hex) else {
            return [.unparsable(String(body))] + trailing
        }
        guard let frame = try? ELM327ResponseParser.frame(fromHex: hex) else {
            return [.unparsable(String(body))] + trailing
        }
        return [.frame(frame)] + trailing
    }

    private static func isValidFrameShape(_ hex: String) -> Bool {
        let digits = Array(hex)
        guard digits.allSatisfy(\.isHexDigit) else { return false }
        let headerLength = digits.count.isMultiple(of: 2) ? 8 : 3
        guard digits.count >= headerLength + 2,
            digits.count <= headerLength + 16,
            let header = UInt32(String(digits[..<headerLength]), radix: 16)
        else { return false }
        return headerLength == 3 ? header <= 0x7FF : header <= 0x1FFF_FFFF
    }
}
