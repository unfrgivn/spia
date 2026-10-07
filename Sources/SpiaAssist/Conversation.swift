import Foundation

/// Which model answers. Chosen per message.
public enum ProviderID: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Apple's on-device model (macOS 26 on Apple silicon with Apple Intelligence). Nothing leaves the Mac.
    case onDevice
    case anthropic
    case openAI

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        #if os(macOS)
            case .onDevice: return "On this Mac"
        #else
            case .onDevice: return "On this device"
        #endif
        case .anthropic: return "Claude"
        case .openAI: return "OpenAI"
        }
    }

    /// Whether messages and session data are sent to a company's servers.
    public var isCloud: Bool { self != .onDevice }
}

public struct ImageInput: Codable, Sendable, Equatable {
    /// `image/jpeg`, `image/png`, `image/gif`, or `image/webp`.
    public let mediaType: String
    public let data: Data

    public init(mediaType: String, data: Data) {
        self.mediaType = mediaType
        self.data = data
    }
}

/// The model asked to use a tool. `arguments` is the JSON text it produced.
public struct ToolCall: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let arguments: String

    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

/// What the app tells the model after acting on a tool call.
public struct ToolResult: Codable, Sendable, Equatable {
    public let callID: String
    public let content: String
    public let isError: Bool

    public init(callID: String, content: String, isError: Bool = false) {
        self.callID = callID
        self.content = content
        self.isError = isError
    }
}

/// Token counts reported by a provider for one completed request.
public struct TokenUsage: Sendable, Equatable {
    public let input: Int
    public let output: Int

    public init(input: Int, output: Int) {
        self.input = input
        self.output = output
    }
}

public enum MessagePart: Codable, Sendable, Equatable {
    case text(String)
    case image(ImageInput)
    case toolCall(ToolCall)
    case toolResult(ToolResult)
}

public enum ConversationRole: String, Codable, Sendable {
    case user, assistant
}

public struct ConversationMessage: Codable, Sendable, Equatable {
    public let role: ConversationRole
    public let parts: [MessagePart]

    public init(role: ConversationRole, parts: [MessagePart]) {
        self.role = role
        self.parts = parts
    }
}

/// Everything a provider needs for one reply.
public struct AssistantRequest: Sendable, Equatable {
    public enum ToolChoice: Sendable, Equatable { case auto, tool(String) }
    public let instructions: String
    public let messages: [ConversationMessage]
    public let tools: [ToolDefinition]
    public let maxOutputTokens: Int
    public let toolChoice: ToolChoice

    public init(
        instructions: String, messages: [ConversationMessage], tools: [ToolDefinition],
        maxOutputTokens: Int = 2048, toolChoice: ToolChoice = .auto
    ) {
        self.instructions = instructions
        self.messages = messages
        self.tools = tools
        self.maxOutputTokens = maxOutputTokens
        self.toolChoice = toolChoice
    }
}

public enum StopReason: Sendable, Equatable {
    case endTurn
    case toolUse
    case maxTokens
    case other(String)
}

public enum AssistantEvent: Sendable, Equatable {
    case text(String)
    case toolCall(ToolCall)
    case usage(TokenUsage)
    case finished(StopReason)
}

public enum AssistantError: Error, Sendable, Equatable, CustomStringConvertible {
    case missingAPIKey(ProviderID)
    case http(status: Int, message: String)
    case provider(kind: String, message: String)
    case unavailable(String)
    case malformedStream(String)

    public var description: String {
        switch self {
        case .missingAPIKey(let provider):
            return "Add your \(provider.displayName) API key in Settings to use it."
        case .http(let status, let message):
            switch status {
            case 401, 403:
                return "The API key was rejected (\(status)). Check it in Settings. \(message)"
            case 429:
                return
                    "The provider is rate limiting requests. Wait a moment and try again. \(message)"
            case 500...:
                return "The provider had a problem (\(status)). Try again shortly. \(message)"
            default: return "The request failed (\(status)): \(message)"
            }
        case .provider(let kind, let message): return "\(kind): \(message)"
        case .unavailable(let reason): return reason
        case .malformedStream(let detail): return "The reply couldn't be read: \(detail)"
        }
    }
}

public protocol AssistantProvider: Sendable {
    var id: ProviderID { get }
    /// Streams one reply. The stream ends after `.finished` or throws.
    func respond(to request: AssistantRequest) -> AsyncThrowingStream<AssistantEvent, any Error>
}
