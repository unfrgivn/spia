import Foundation

public enum ELM327Error: Error, Equatable, Sendable, CustomStringConvertible {
    /// No `>` prompt arrived before the deadline. `partial` is whatever did arrive.
    case timeout(command: String, partial: String)
    /// A setup command did not answer `OK`.
    case unexpectedResponse(command: String, response: String)
    /// A CAN identifier is out of range or incompatible with the paired identifier's width.
    case invalidCANHeader(UInt32)
    /// The adapter answered an OBD request with a status message and no frames.
    case adapter(ELM327AdapterMessage)
    /// The adapter produced more response data than the bounded command allows.
    case responseTooLarge(command: String, limit: Int)
    case invalidTimeout
    case operationInProgress
    case transportUnsynchronized

    public var description: String {
        switch self {
        case .timeout(let command, let partial):
            let suffix = partial.isEmpty ? "" : " (received: \"\(printable(partial))\")"
            return "timed out waiting for a reply to \(command)\(suffix)"
        case .unexpectedResponse(let command, let response):
            return "\(command) answered \"\(printable(response))\""
        case .invalidCANHeader(let header):
            return
                "invalid CAN header \(String(format: "%08X", header)): out of range or mismatched identifier width"
        case .adapter(let message):
            return message.description
        case .responseTooLarge(let command, let limit):
            return "response to \(command) exceeded the \(limit)-byte safety limit"
        case .invalidTimeout:
            return "timeout must be positive"
        case .operationInProgress:
            return "another adapter operation is already in progress"
        case .transportUnsynchronized:
            return "adapter exchange was interrupted; reconnect before sending another command"
        }
    }

    private func printable(_ text: String) -> String {
        text.replacingOccurrences(of: "\r", with: "⏎")
    }
}
