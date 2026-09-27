import Foundation

/// One line of a recorded session: milliseconds since open, direction, raw bytes as hex.
public struct TranscriptEvent: Equatable, Sendable {
    public enum Direction: String, Sendable {
        case tx = "TX"
        case rx = "RX"
    }

    public let milliseconds: UInt64
    public let direction: Direction
    public let bytes: [UInt8]

    public init(milliseconds: UInt64, direction: Direction, bytes: [UInt8]) {
        self.milliseconds = milliseconds
        self.direction = direction
        self.bytes = bytes
    }
}

public enum TranscriptError: Error, Equatable, Sendable, CustomStringConvertible {
    case malformedLine(String)

    public var description: String {
        switch self {
        case .malformedLine(let line):
            return "malformed transcript line: \"\(line)\""
        }
    }
}

/// The transcript file format. One event per line: `<ms> TX|RX <hex>`.
public enum Transcript {
    public static func encode(_ event: TranscriptEvent) -> String {
        let hex = event.bytes.map { String(format: "%02X", $0) }.joined()
        return "\(event.milliseconds) \(event.direction.rawValue) \(hex)"
    }

    public static func decode(_ line: String) throws -> TranscriptEvent {
        let parts = line.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, let milliseconds = UInt64(parts[0]),
            let direction = TranscriptEvent.Direction(rawValue: String(parts[1]))
        else {
            throw TranscriptError.malformedLine(line)
        }
        let digits = Array(parts[2])
        guard digits.count.isMultiple(of: 2) else {
            throw TranscriptError.malformedLine(line)
        }
        var bytes: [UInt8] = []
        for index in stride(from: 0, to: digits.count, by: 2) {
            guard let byte = UInt8(String(digits[index...index + 1]), radix: 16) else {
                throw TranscriptError.malformedLine(line)
            }
            bytes.append(byte)
        }
        return TranscriptEvent(milliseconds: milliseconds, direction: direction, bytes: bytes)
    }

    public static func decodeFile(_ text: String) throws -> [TranscriptEvent] {
        try text.split(whereSeparator: \.isNewline).map { try decode(String($0)) }
    }
}
