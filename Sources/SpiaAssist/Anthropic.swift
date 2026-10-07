import Foundation

/// Anthropic Messages API (https://platform.claude.com/docs/en/api/messages).
public struct AnthropicProvider: AssistantProvider {
    public static let defaultModel = "claude-opus-5-5"
    public static let fastModel = "claude-haiku-4-5"
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")

    public let id = ProviderID.anthropic
    let apiKey: String
    let model: String
    let session: URLSession

    public init(apiKey: String, model: String = defaultModel, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.model = model
        self.session = session
    }

    public func respond(to request: AssistantRequest) -> AsyncThrowingStream<
        AssistantEvent, any Error
    > {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let endpoint = Self.endpoint else {
                        throw AssistantError.unavailable("bad endpoint")
                    }
                    var http = URLRequest(url: endpoint)
                    http.httpMethod = "POST"
                    http.setValue("application/json", forHTTPHeaderField: "content-type")
                    http.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                    http.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                    http.httpBody = Data(
                        try Self.body(for: request, model: model).serialized().utf8)
                    var decoder = AnthropicStreamDecoder()
                    let events = EventStreamClient(session: session).events(
                        http, errorMessage: Self.errorMessage)
                    for try await event in events {
                        for output in try decoder.consume(event) { continuation.yield(output) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func errorMessage(_ body: Data) -> String? {
        (try? JSONDecoder().decode(JSONValue.self, from: body))?["error"]?["message"]?.string
    }

    /// The request body. Adjacent messages with the same role are merged, since the API expects
    /// strictly alternating turns.
    public static func body(for request: AssistantRequest, model: String) throws -> JSONValue {
        var messages: [(role: ConversationRole, content: [JSONValue])] = []
        for message in request.messages {
            let content = try message.parts.map(block)
            if let last = messages.last, last.role == message.role {
                messages[messages.count - 1].content += content
            } else {
                messages.append((message.role, content))
            }
        }
        return [
            "model": .string(model),
            "max_tokens": .number(Double(request.maxOutputTokens)),
            "system": .string(request.instructions),
            "stream": true,
            "tool_choice": toolChoice(for: request.toolChoice),
            "tools": .array(
                request.tools.map { tool in
                    [
                        "name": .string(tool.name), "description": .string(tool.description),
                        "input_schema": tool.parameters,
                    ]
                }),
            "messages": .array(
                messages.map { ["role": .string($0.role.rawValue), "content": .array($0.content)] }),
        ]
    }

    private static func toolChoice(for choice: AssistantRequest.ToolChoice) -> JSONValue {
        switch choice {
        case .auto: return ["type": "auto"]
        case .tool(let name): return ["type": "tool", "name": .string(name)]
        }
    }

    private static func block(_ part: MessagePart) throws -> JSONValue {
        switch part {
        case .text(let text):
            return ["type": "text", "text": .string(text)]
        case .image(let image):
            return [
                "type": "image",
                "source": [
                    "type": "base64", "media_type": .string(image.mediaType),
                    "data": .string(image.data.base64EncodedString()),
                ],
            ]
        case .toolCall(let call):
            let input = (try? JSONValue.parse(call.arguments)) ?? [:]
            return [
                "type": "tool_use", "id": .string(call.id), "name": .string(call.name),
                "input": input,
            ]
        case .toolResult(let result):
            return [
                "type": "tool_result", "tool_use_id": .string(result.callID),
                "content": .string(result.content), "is_error": .bool(result.isError),
            ]
        }
    }
}

/// Turns Anthropic stream events into `AssistantEvent`s. Tool arguments arrive as JSON
/// fragments and are only emitted once their block is complete.
public struct AnthropicStreamDecoder: Sendable {
    private var tools: [Int: (id: String, name: String, json: String)] = [:]
    private var stopReason: StopReason = .endTurn
    private var inputTokens: Int?

    public init() {}

    public mutating func consume(_ event: SSEEvent) throws -> [AssistantEvent] {
        let payload: JSONValue
        do {
            payload = try JSONValue.parse(event.data)
        } catch {
            throw AssistantError.malformedStream(event.data)
        }
        let index = payload["index"].flatMap(Self.integer)
        switch payload["type"]?.string ?? event.event {
        // Anthropic's message_start carries message.usage.input_tokens. Its message_delta
        // carries cumulative usage.output_tokens. Cache fields are intentionally ignored.
        case "message_start":
            inputTokens = payload["message"]?["usage"]?["input_tokens"].flatMap(Self.integer)
            return []
        case "content_block_start":
            if let block = payload["content_block"], block["type"]?.string == "tool_use", let index,
                let id = block["id"]?.string, let name = block["name"]?.string
            {
                tools[index] = (id, name, "")
            }
            return []
        case "content_block_delta":
            guard let delta = payload["delta"] else { return [] }
            switch delta["type"]?.string {
            case "text_delta":
                return delta["text"]?.string.map { [.text($0)] } ?? []
            case "input_json_delta":
                if let index, let fragment = delta["partial_json"]?.string {
                    tools[index]?.json += fragment
                }
                return []
            default:
                return []
            }
        case "content_block_stop":
            guard let index, let tool = tools.removeValue(forKey: index) else { return [] }
            return [
                .toolCall(
                    ToolCall(
                        id: tool.id, name: tool.name,
                        arguments: tool.json.isEmpty ? "{}" : tool.json))
            ]
        case "message_delta":
            switch payload["delta"]?["stop_reason"]?.string {
            case "end_turn", "stop_sequence": stopReason = .endTurn
            case "tool_use": stopReason = .toolUse
            case "max_tokens": stopReason = .maxTokens
            case let other?: stopReason = .other(other)
            case nil: break
            }
            guard let inputTokens,
                let outputTokens = payload["usage"]?["output_tokens"].flatMap(Self.integer)
            else { return [] }
            return [.usage(TokenUsage(input: inputTokens, output: outputTokens))]
        case "message_stop":
            return [.finished(stopReason)]
        case "error":
            throw AssistantError.provider(
                kind: payload["error"]?["type"]?.string ?? "error",
                message: payload["error"]?["message"]?.string ?? event.data)
        default:
            return []
        }
    }

    static func integer(_ value: JSONValue) -> Int? {
        if case .number(let number) = value { return Int(exactly: number) }
        return nil
    }
}
