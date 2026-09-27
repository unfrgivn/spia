import Foundation

public struct ParsedResponse: Equatable, Sendable {
    public let frames: [CANFrame]
    public let messages: [ELM327AdapterMessage]

    public init(frames: [CANFrame], messages: [ELM327AdapterMessage]) {
        self.frames = frames
        self.messages = messages
    }
}

public enum ELM327ParseError: Error, Equatable, Sendable, CustomStringConvertible {
    case malformedLine(String)

    public var description: String {
        switch self {
        case .malformedLine(let line):
            return "could not parse adapter output: \"\(line)\""
        }
    }
}

/// Splits the adapter's reply to an OBD request into CAN frames and status messages.
///
/// Assumes `ATL0 ATS0 ATH1` (no linefeeds, no spaces, headers on) but tolerates the opposite.
/// With headers on, an 11-bit frame prints as 3 header hex digits followed by data bytes
/// (`7E8064100BE3EA813`) and a 29-bit frame as 8 (`18DAF110064100BE3EA813`). The two are
/// distinguished by parity: 3 + 2n is odd, 8 + 2n is even.
public enum ELM327ResponseParser {
    public static func parse(_ text: String) throws -> ParsedResponse {
        var frames: [CANFrame] = []
        var messages: [ELM327AdapterMessage] = []

        for rawLine in text.split(whereSeparator: { $0 == "\r" || $0 == "\n" }) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line == "SEARCHING..." {
                continue
            }
            if let message = ELM327AdapterMessage(line: line) {
                messages.append(message)
                continue
            }
            frames.append(try frame(fromHex: line.filter { !$0.isWhitespace }))
        }
        return ParsedResponse(frames: frames, messages: messages)
    }

    /// Parses one frame line with headers on and whitespace already removed.
    public static func frame(fromHex hex: String) throws -> CANFrame {
        let digits = Array(hex)
        guard digits.allSatisfy(\.isHexDigit) else {
            throw ELM327ParseError.malformedLine(hex)
        }
        let headerLength = digits.count.isMultiple(of: 2) ? 8 : 3
        guard digits.count >= headerLength + 2 else {
            throw ELM327ParseError.malformedLine(hex)
        }
        guard let header = UInt32(String(digits[..<headerLength]), radix: 16) else {
            throw ELM327ParseError.malformedLine(hex)
        }
        var data: [UInt8] = []
        for index in stride(from: headerLength, to: digits.count, by: 2) {
            guard let byte = UInt8(String(digits[index...index + 1]), radix: 16) else {
                throw ELM327ParseError.malformedLine(hex)
            }
            data.append(byte)
        }
        return CANFrame(header: header, data: data)
    }
}
