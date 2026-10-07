import Foundation

/// OpenAI Responses API (https://platform.openai.com/docs/api-reference/responses). Sent with
/// `store: false`; the app keeps the conversation and resends it, so nothing is chained server-side.
public struct OpenAIProvider: AssistantProvider {
    public static let defaultModel = "gpt-5.5"
    public static let fastModel = "gpt-5.4-mini"
    static let endpoint = URL(string: "https://api.openai.com/v1/responses")

    public let id = ProviderID.openAI
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
                    http.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization")
                    http.httpBody = Data(
                        try Self.body(for: request, model: model).serialized().utf8)
                    var decoder = OpenAIStreamDecoder()
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

    public static func body(for request: AssistantRequest, model: String) throws -> JSONValue {
        var input: [JSONValue] = []
        for message in request.messages {
            var content: [JSONValue] = []
            func flushContent() {
                guard !content.isEmpty else { return }
                input.append(["role": .string(message.role.rawValue), "content": .array(content)])
                content = []
            }
            for part in message.parts {
                switch part {
                case .text(let text):
                    content.append([
                        "type": message.role == .user ? "input_text" : "output_text",
                        "text": .string(text),
                    ])
                case .image(let image):
                    content.append([
                        "type": "input_image",
                        "image_url": .string(
                            "data:\(image.mediaType);base64,\(image.data.base64EncodedString())"),
                        "detail": "auto",
                    ])
                case .toolCall(let call):
                    flushContent()
                    input.append([
                        "type": "function_call", "call_id": .string(call.id),
                        "name": .string(call.name),
                        "arguments": .string(call.arguments),
                    ])
                case .toolResult(let result):
                    flushContent()
                    input.append([
                        "type": "function_call_output", "call_id": .string(result.callID),
                        "output": .string(
                            result.isError ? "Error: \(result.content)" : result.content),
                    ])
                }
            }
            flushContent()
        }
        let choice: JSONValue = {
            switch request.toolChoice {
            case .auto: return .string("auto")
            case .tool(let name): return ["type": "function", "name": .string(name)]
            }
        }()
        return [
            "model": .string(model),
            "instructions": .string(request.instructions),
            "input": .array(input),
            "max_output_tokens": .number(Double(request.maxOutputTokens)),
            "store": false,
            "stream": true,
            "tools": .array(
                request.tools.map { tool in
                    [
                        "type": "function", "name": .string(tool.name),
                        "description": .string(tool.description),
                        "parameters": tool.parameters, "strict": true,
                    ]
                }),
            "tool_choice": choice,
        ]
    }
}

/// Turns Responses API stream events into `AssistantEvent`s.
public struct OpenAIStreamDecoder: Sendable {
    private var sawToolCall = false

    public init() {}

    public mutating func consume(_ event: SSEEvent) throws -> [AssistantEvent] {
        let payload: JSONValue
        do {
            payload = try JSONValue.parse(event.data)
        } catch {
            throw AssistantError.malformedStream(event.data)
        }
        switch payload["type"]?.string ?? event.event {
        case "response.output_text.delta":
            return payload["delta"]?.string.map { [.text($0)] } ?? []
        case "response.output_item.done":
            guard let item = payload["item"], item["type"]?.string == "function_call",
                let id = item["call_id"]?.string, let name = item["name"]?.string
            else { return [] }
            sawToolCall = true
            return [
                .toolCall(
                    ToolCall(id: id, name: name, arguments: item["arguments"]?.string ?? "{}"))
            ]
        // OpenAI's response.completed event carries response.usage.input_tokens and
        // response.usage.output_tokens. The other usage detail fields are ignored.
        case "response.completed":
            let usage = payload["response"]?["usage"]
            let events: [AssistantEvent] =
                usage.flatMap { usage in
                    guard let input = usage["input_tokens"].flatMap(Self.integer),
                        let output = usage["output_tokens"].flatMap(Self.integer)
                    else { return nil }
                    return .usage(TokenUsage(input: input, output: output))
                }.map { [$0, .finished(sawToolCall ? .toolUse : .endTurn)] }
                ?? [.finished(sawToolCall ? .toolUse : .endTurn)]
            return events
        case "response.incomplete":
            let reason = payload["response"]?["incomplete_details"]?["reason"]?.string
            return [
                .finished(
                    reason == "max_output_tokens" ? .maxTokens : .other(reason ?? "incomplete"))
            ]
        case "response.failed":
            let error = payload["response"]?["error"]
            throw AssistantError.provider(
                kind: error?["code"]?.string ?? "failed",
                message: error?["message"]?.string ?? event.data)
        case "error":
            throw AssistantError.provider(
                kind: payload["code"]?.string ?? "error",
                message: payload["message"]?.string ?? event.data)
        default:
            return []
        }
    }

    private static func integer(_ value: JSONValue) -> Int? {
        if case .number(let number) = value { return Int(exactly: number) }
        return nil
    }
}
