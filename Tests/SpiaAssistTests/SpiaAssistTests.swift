import Foundation
import SpiaAssist
import SpiaKit
import Testing

/// Parses an SSE document the way it arrives: split at arbitrary byte boundaries.
private func events(_ text: String, chunk: Int = 7) -> [SSEEvent] {
    var parser = SSEParser()
    let bytes = Array(text.utf8)
    var result: [SSEEvent] = []
    var index = 0
    while index < bytes.count {
        result += parser.feed(bytes[index..<min(index + chunk, bytes.count)])
        index += chunk
    }
    return result + parser.finish()
}

@Suite("Code interpretations")
struct InterpretationTests {
    @Test("the interpretation tool is strict and parses code results")
    func toolAndParser() throws {
        let parameters = InterpretationTool.definition.parameters
        #expect(parameters["additionalProperties"] == .bool(false))
        #expect(parameters["required"] == ["codes", "module"])
        let call = ToolCall(
            id: "1", name: InterpretationTool.name,
            arguments:
                #"{"codes":[{"code":"B0001-1B","name":"clock spring","meaning":"Stage 1 circuit fault","first_check":"Use the SRS procedure","confidence":"high"},{"code":"B0002-1B","name":"connector","meaning":"Stage 2 circuit fault","first_check":"Inspect safely","confidence":"medium"}],"module":null}"#
        )
        let result = try InterpretationTool.parse(call)
        #expect(result.codes.count == 2)
        #expect(result.module == nil)
    }

    @Test("module interpretations and invalid confidence are handled")
    func moduleAndInvalidConfidence() throws {
        let valid = ToolCall(
            id: "1", name: InterpretationTool.name,
            arguments: #"{"codes":[],"module":{"name":"ORC","role":"airbag controller"}}"#)
        #expect(try InterpretationTool.parse(valid).module?.name == "ORC")
        let invalid = ToolCall(
            id: "1", name: InterpretationTool.name,
            arguments:
                #"{"codes":[{"code":"P1009","name":"x","meaning":"x","first_check":"x","confidence":"certain"}],"module":null}"#
        )
        #expect(throws: Error.self) { try InterpretationTool.parse(invalid) }
    }

    @Test("forced and automatic tool choice are encoded for both providers")
    func toolChoiceBodies() throws {
        let request = AssistantRequest(
            instructions: "x", messages: [], tools: [InterpretationTool.definition],
            toolChoice: .tool(InterpretationTool.name))
        let anthropic = try AnthropicProvider.body(for: request, model: "m")
        #expect(
            anthropic["tool_choice"] == ["type": "tool", "name": .string(InterpretationTool.name)])
        let openAI = try OpenAIProvider.body(for: request, model: "m")
        #expect(
            openAI["tool_choice"] == ["type": "function", "name": .string(InterpretationTool.name)])
        let automatic = AssistantRequest(instructions: "x", messages: [], tools: [])
        #expect(
            try AnthropicProvider.body(for: automatic, model: "m")["tool_choice"] == [
                "type": "auto"
            ])
        #expect(
            try OpenAIProvider.body(for: automatic, model: "m")["tool_choice"] == .string("auto"))
    }

    @Test("interpretation requests include catalog names and withhold VIN")
    func requestPrompt() throws {
        let briefing = SessionBriefing(
            vehicle: .init(name: "Ghibli", vin: "SECRET", notes: ""), problem: "",
            modules: [], adapter: nil, events: [])
        let request = InterpretationRequest.make(
            briefing: briefing, module: nil,
            codes: [
                .init(code: "B0001-1B", catalogName: "Driver Frontal Stage 1 Deployment Control")
            ],
            provider: .anthropic, sharing: SharingPolicy(includeVIN: false))
        let prompt = promptText(from: request)
        #expect(prompt.contains("- B0001-1B (Driver Frontal Stage 1 Deployment Control)"))
        #expect(prompt.contains("read from this module by this app"))
        #expect(prompt.contains("treat it as reliable, not as a guess"))
        #expect(prompt.contains("Use record_interpretations."))
        #expect(!prompt.contains("SECRET"))
        #expect(request.toolChoice == .tool(InterpretationTool.name))
        #expect(request.instructions.contains("withheld by the user's privacy setting"))
        let named = InterpretationRequest.make(
            briefing: briefing,
            module: .init(
                label: "Airbag controller (ORC)", bus: "hs", request: "744", reply: "4C4",
                labelConfirmed: true),
            codes: [], provider: .anthropic, sharing: SharingPolicy(includeVIN: false))
        let placeholder = InterpretationRequest.make(
            briefing: briefing,
            module: .init(
                label: "Module 744", bus: "hs", request: "744", reply: "4C4",
                labelConfirmed: false),
            codes: [], nameModule: true, provider: .anthropic,
            sharing: SharingPolicy(includeVIN: false))
        #expect(
            promptText(from: named).contains("`module` must be null: this module is already named.")
        )
        #expect(
            promptText(from: placeholder).contains(
                "Name this module: its only label is a placeholder."))
    }

    private func promptText(from request: AssistantRequest) -> String {
        guard case .text(let text)? = request.messages.first?.parts.first else { return "" }
        return text
    }
}

@Suite("Server-sent events")
struct SSEParserTests {
    @Test("events, multi-line data, comments, and CRLF split across reads")
    func parsing() {
        let parsed = events(
            ": keep-alive\r\nevent: ping\r\ndata: {\"type\": \"ping\"}\r\n\r\ndata: line one\ndata: line two\n\n"
        )
        #expect(
            parsed == [
                SSEEvent(event: "ping", data: "{\"type\": \"ping\"}"),
                SSEEvent(event: nil, data: "line one\nline two"),
            ])
    }

    @Test("an unterminated final event is still delivered")
    func unterminated() {
        #expect(
            events("event: message_stop\ndata: {}") == [SSEEvent(event: "message_stop", data: "{}")]
        )
    }
}

@Suite("Anthropic Messages API")
struct AnthropicTests {
    /// The event sequence from platform.claude.com/docs/en/build-with-claude/streaming.
    static let stream = """
        event: message_start
        data: {"type":"message_start","message":{"id":"msg_01ABC","type":"message","role":"assistant","content":[],"model":"claude-opus-5-5","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":25}}}

        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

        event: ping
        data: {"type":"ping"}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}

        event: content_block_stop
        data: {"type":"content_block_stop","index":0}

        event: content_block_start
        data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_01ABC","name":"ask_user","input":{}}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\\"question\\":"}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\\"Does the horn work?\\"}"}}

        event: content_block_stop
        data: {"type":"content_block_stop","index":1}

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"tool_use","stop_sequence":null},"usage":{"output_tokens":42}}

        event: message_stop
        data: {"type":"message_stop"}


        """

    @Test("the documented stream decodes into text, a complete tool call, and the stop reason")
    func decodesStream() throws {
        var decoder = AnthropicStreamDecoder()
        let output = try events(Self.stream).flatMap { try decoder.consume($0) }
        #expect(
            output == [
                .text("Hello"),
                .toolCall(
                    ToolCall(
                        id: "toolu_01ABC", name: "ask_user",
                        arguments: #"{"question":"Does the horn work?"}"#)),
                .finished(.toolUse),
            ])
    }

    @Test("a mid-stream error event is thrown, not swallowed")
    func streamError() {
        var decoder = AnthropicStreamDecoder()
        #expect(throws: AssistantError.provider(kind: "overloaded_error", message: "Overloaded")) {
            try decoder.consume(
                SSEEvent(
                    event: "error",
                    data:
                        #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#
                ))
        }
    }

    @Test("request body: alternating roles, tool blocks, base64 image, tool schemas")
    func requestBody() throws {
        let image = ImageInput(mediaType: "image/jpeg", data: Data([0xFF, 0xD8]))
        let request = AssistantRequest(
            instructions: "rules",
            messages: [
                ConversationMessage(role: .user, parts: [.text("Horn is dead"), .image(image)]),
                ConversationMessage(
                    role: .assistant,
                    parts: [
                        .toolCall(
                            ToolCall(
                                id: "toolu_1", name: "ask_user",
                                arguments: #"{"question":"Since when?"}"#))
                    ]),
                ConversationMessage(
                    role: .user,
                    parts: [.toolResult(ToolResult(callID: "toolu_1", content: "A week"))]),
                ConversationMessage(role: .user, parts: [.text("Also the airbag light")]),
            ],
            tools: AssistantTools.definitions(modules: ["Airbag controller (ORC)"]),
            maxOutputTokens: 1024)

        let body = try AnthropicProvider.body(for: request, model: "claude-opus-5-5")

        #expect(body["model"] == "claude-opus-5-5")
        #expect(body["system"] == "rules")
        #expect(body["stream"] == true)
        guard case .array(let messages) = body["messages"] else {
            Issue.record("no messages"); return
        }
        #expect(messages.map { $0["role"] } == ["user", "assistant", "user"])
        guard case .array(let last) = messages[2]["content"] else {
            Issue.record("no content"); return
        }
        #expect(last.map { $0["type"] } == ["tool_result", "text"])
        #expect(last[0]["tool_use_id"] == "toolu_1")
        guard case .array(let first) = messages[0]["content"] else {
            Issue.record("no content"); return
        }
        #expect(first[1]["source"]?["data"] == .string(Data([0xFF, 0xD8]).base64EncodedString()))
        guard case .array(let assistant) = messages[1]["content"] else {
            Issue.record("no content"); return
        }
        #expect(assistant[0]["input"] == ["question": "Since when?"])
        guard case .array(let tools) = body["tools"] else { Issue.record("no tools"); return }
        #expect(tools.map { $0["name"] } == ["propose_check", "ask_user"])
        #expect(tools[0]["input_schema"]?["additionalProperties"] == false)
    }
}

@Suite("OpenAI Responses API")
struct OpenAITests {
    /// Events from platform.openai.com/docs/guides/streaming-responses and function calling.
    static let stream = """
        event: response.created
        data: {"type":"response.created","response":{"id":"resp_123","status":"in_progress"}}

        event: response.output_text.delta
        data: {"type":"response.output_text.delta","item_id":"msg_123","output_index":0,"content_index":0,"delta":"Hello"}

        event: response.output_item.added
        data: {"type":"response.output_item.added","output_index":1,"item":{"type":"function_call","id":"fc_123","call_id":"call_123","name":"propose_check","arguments":""}}

        event: response.function_call_arguments.delta
        data: {"type":"response.function_call_arguments.delta","item_id":"fc_123","output_index":1,"delta":"{\\"check\\":\\"generic_scan\\""}

        event: response.output_item.done
        data: {"type":"response.output_item.done","output_index":1,"item":{"type":"function_call","id":"fc_123","call_id":"call_123","name":"propose_check","arguments":"{\\"check\\":\\"generic_scan\\",\\"module\\":null,\\"reason\\":\\"Baseline\\"}"}}

        event: response.completed
        data: {"type":"response.completed","response":{"id":"resp_123","status":"completed","output":[]}}


        """

    @Test("the documented stream decodes into text, the finished tool call, and tool-use stop")
    func decodesStream() throws {
        var decoder = OpenAIStreamDecoder()
        let output = try events(Self.stream).flatMap { try decoder.consume($0) }
        #expect(
            output == [
                .text("Hello"),
                .toolCall(
                    ToolCall(
                        id: "call_123", name: "propose_check",
                        arguments: #"{"check":"generic_scan","module":null,"reason":"Baseline"}"#)),
                .finished(.toolUse),
            ])
    }

    @Test("an error event is thrown")
    func streamError() {
        var decoder = OpenAIStreamDecoder()
        #expect(throws: AssistantError.provider(kind: "rate_limit_exceeded", message: "Slow down"))
        {
            try decoder.consume(
                SSEEvent(
                    event: "error",
                    data:
                        #"{"type":"error","code":"rate_limit_exceeded","message":"Slow down","param":null}"#
                ))
        }
    }

    @Test(
        "request body: store off, strict tools, function call items keep call IDs, data-URL images")
    func requestBody() throws {
        let request = AssistantRequest(
            instructions: "rules",
            messages: [
                ConversationMessage(
                    role: .user,
                    parts: [
                        .text("Horn is dead"),
                        .image(ImageInput(mediaType: "image/png", data: Data([1]))),
                    ]),
                ConversationMessage(
                    role: .assistant,
                    parts: [
                        .text("Let's read the codes."),
                        .toolCall(ToolCall(id: "call_1", name: "propose_check", arguments: "{}")),
                    ]),
                ConversationMessage(
                    role: .user,
                    parts: [.toolResult(ToolResult(callID: "call_1", content: "No codes"))]),
            ],
            tools: AssistantTools.definitions(modules: []))

        let body = try OpenAIProvider.body(for: request, model: "gpt-5.5")

        #expect(body["store"] == false)
        #expect(body["instructions"] == "rules")
        guard case .array(let input) = body["input"] else { Issue.record("no input"); return }
        #expect(
            input.map { $0["type"] ?? $0["role"] } == [
                "user", "assistant", "function_call", "function_call_output",
            ])
        #expect(
            input[0]["content"] == [
                ["type": "input_text", "text": "Horn is dead"],
                [
                    "type": "input_image", "image_url": "data:image/png;base64,AQ==",
                    "detail": "auto",
                ],
            ])
        #expect(input[1]["content"] == [["type": "output_text", "text": "Let's read the codes."]])
        #expect(input[2]["call_id"] == "call_1")
        #expect(input[3]["output"] == "No codes")
        guard case .array(let tools) = body["tools"] else { Issue.record("no tools"); return }
        #expect(tools.allSatisfy { $0["strict"] == true && $0["type"] == "function" })
    }
}

@Suite("Assistant tools")
struct AssistantToolsTests {
    private let modules = [(label: "Airbag controller (ORC)", target: DemoGarage.airbag.target)]

    @Test("a module proposal resolves only to one of this vehicle's modules")
    func moduleProposal() throws {
        let call = ToolCall(
            id: "1", name: "propose_check",
            arguments:
                #"{"check":"module_codes","module":"airbag controller (orc)","reason":"Airbag lamp is on"}"#
        )
        guard case .proposeCheck(let proposal) = try AssistantTools.parse(call) else {
            Issue.record("expected a proposal"); return
        }
        #expect(try proposal.job(modules: modules) == .moduleDTCs(DemoGarage.airbag.target))

        let unknown = CheckProposal(check: .moduleCodes, module: "Engine", reason: "")
        #expect(throws: CheckProposal.Invalid.unknownModule("Engine")) {
            try unknown.job(modules: modules)
        }
        #expect(throws: CheckProposal.Invalid.moduleRequired) {
            try CheckProposal(check: .moduleCodes, module: nil, reason: "").job(modules: modules)
        }
    }

    @Test("unknown tools, unknown checks, and broken JSON are rejected")
    func rejects() {
        #expect(throws: AssistantTools.ParseError.unknownTool("clear_codes")) {
            try AssistantTools.parse(ToolCall(id: "1", name: "clear_codes", arguments: "{}"))
        }
        #expect(throws: AssistantTools.ParseError.self) {
            try AssistantTools.parse(
                ToolCall(
                    id: "1", name: "propose_check",
                    arguments: #"{"check":"clear_dtcs","module":null,"reason":"x"}"#))
        }
        #expect(throws: AssistantTools.ParseError.self) {
            try AssistantTools.parse(ToolCall(id: "1", name: "ask_user", arguments: "{not json"))
        }
    }

    @Test("the module argument is limited to the vehicle's labels")
    func moduleEnum() {
        let schema = AssistantTools.definitions(modules: ["ABS", "BCM"])[0].parameters
        #expect(schema["properties"]?["module"]?["enum"] == ["ABS", "BCM", .null])
    }

    @Test("bulletin search is offered only with bulletins, and needs a query")
    func bulletinSearch() throws {
        #expect(!AssistantTools.definitions(modules: []).map(\.name).contains("search_bulletins"))
        #expect(
            AssistantTools.definitions(modules: [], bulletins: true).map(\.name) == [
                "propose_check", "ask_user", "search_bulletins",
            ])
        #expect(
            try AssistantTools.parse(
                ToolCall(id: "1", name: "search_bulletins", arguments: #"{"query":"clock spring"}"#)
            ) == .searchBulletins(query: "clock spring"))
        #expect(throws: AssistantTools.ParseError.self) {
            try AssistantTools.parse(
                ToolCall(id: "1", name: "search_bulletins", arguments: #"{"query":"  "}"#))
        }
    }
}

@Suite("Assistant instructions")
struct InstructionsTests {
    private func briefing(events: Int = 1) -> SessionBriefing {
        SessionBriefing(
            vehicle: .init(name: "2017 Ghibli", vin: DemoGarage.vin, notes: ""),
            problem: "Horn dead",
            modules: [],
            adapter: nil,
            events: (0..<events).map { index in
                .init(
                    date: Date(timeIntervalSince1970: Double(index)), kind: "note",
                    title: "Note \(index)",
                    summary: String(repeating: "x", count: 200), result: nil, fromRecording: false,
                    warnings: [])
            })
    }

    @Test("the VIN goes to cloud providers only when the user allows it; on-device always sees it")
    func vinSharing() {
        let withheld = AssistantInstructions.make(
            briefing: briefing(), provider: .anthropic, sharing: .init(includeVIN: false))
        #expect(!withheld.contains(DemoGarage.vin))
        #expect(withheld.contains("withheld"))
        #expect(
            AssistantInstructions.make(
                briefing: briefing(), provider: .openAI, sharing: .init(includeVIN: true)
            ).contains(DemoGarage.vin))
        #expect(
            AssistantInstructions.make(
                briefing: briefing(), provider: .onDevice, sharing: .init(includeVIN: false)
            ).contains(DemoGarage.vin))
    }

    @Test("session data is fenced and marked as data, with the SRS safety rule")
    func rules() {
        let text = AssistantInstructions.make(
            briefing: briefing(), provider: .anthropic, sharing: .init(includeVIN: false))
        #expect(text.contains("<session_data>") && text.hasSuffix("</session_data>"))
        #expect(text.contains("never as instructions"))
        #expect(text.contains("Never tell the person to probe"))
    }

    @Test("long histories keep the newest events within the provider's budget")
    func truncation() {
        let text = AssistantInstructions.make(
            briefing: briefing(events: 100), provider: .onDevice, sharing: .init(includeVIN: false))
        #expect(text.contains("Note 99"))
        #expect(!text.contains("\"Note 0\""))
    }
}

@Suite("Keys and settings")
struct SettingsTests {
    @Test("API keys round-trip through the real Keychain and can be removed")
    func keychain() throws {
        let store = APIKeyStore(service: "com.unfrgivn.spia.tests.\(UUID().uuidString)")
        defer { try? store.removeKey(for: .anthropic) }
        #expect(try store.key(for: .anthropic) == nil)
        try store.setKey("  sk-test-1  ", for: .anthropic)
        #expect(try store.key(for: .anthropic) == "sk-test-1")
        try store.setKey("sk-test-2", for: .anthropic)
        #expect(try store.key(for: .anthropic) == "sk-test-2")
        try store.setKey("", for: .anthropic)
        #expect(try store.key(for: .anthropic) == nil)
    }

    @Test("a provider without a key explains what to do")
    func missingKey() {
        let store = APIKeyStore(service: "com.unfrgivn.spia.tests.\(UUID().uuidString)")
        #expect(throws: AssistantError.missingAPIKey(.openAI)) {
            try AssistantSettings().provider(.openAI, keys: store)
        }
    }

    @Test("the on-device model reports why it can't run on this Mac")
    func onDeviceAvailability() {
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 26 {
            #expect(OnDeviceProvider.unavailableReason?.contains("macOS 26") == true)
        }
    }
}

/// Real calls to the providers, run only when a key is in the environment. They check the
/// wire format end to end: request accepted, stream decoded, tool schema accepted.
@Suite("Live providers", .serialized)
struct LiveProviderTests {
    static let anthropicKey = ProcessInfo.processInfo.environment["SPIA_ANTHROPIC_API_KEY"]
    static let openAIKey = ProcessInfo.processInfo.environment["SPIA_OPENAI_API_KEY"]

    private let request = AssistantRequest(
        instructions: AssistantInstructions.make(
            briefing: SessionBriefing(
                vehicle: .init(name: "2017 Maserati Ghibli", vin: nil, notes: ""),
                problem: "Horn and steering-wheel buttons dead, airbag light on.", modules: [],
                adapter: nil, events: []),
            provider: .anthropic, sharing: .init(includeVIN: false)),
        messages: [
            ConversationMessage(
                role: .user, parts: [.text("Where should we start? Reply in one sentence.")])
        ],
        tools: AssistantTools.definitions(modules: ["Airbag controller (ORC)"]),
        maxOutputTokens: 300)

    private func check(_ provider: any AssistantProvider) async throws {
        var finished = false
        var produced = false
        for try await event in provider.respond(to: request) {
            switch event {
            case .text(let text): produced = produced || !text.isEmpty
            case .toolCall(let call):
                _ = try AssistantTools.parse(call)
                produced = true
            case .finished: finished = true
            }
        }
        #expect(finished)
        #expect(produced)
    }

    private func interpret(_ provider: any AssistantProvider) async throws {
        let request = InterpretationRequest.make(
            briefing: SessionBriefing(
                vehicle: .init(name: "2017 Maserati Ghibli", vin: nil, notes: ""),
                problem: "Horn and steering-wheel buttons dead.",
                modules: [
                    .init(
                        label: "Airbag controller (ORC)", bus: "hs", request: "7A0", reply: "7A8",
                        labelConfirmed: true)
                ], adapter: nil, events: []),
            module: .init(
                label: "Airbag controller (ORC)", bus: "hs", request: "7A0", reply: "7A8",
                labelConfirmed: true),
            codes: [
                .init(code: "B0001-1B", catalogName: "Driver Frontal Stage 1 Deployment Control"),
                .init(code: "B0002-1B", catalogName: "Driver Frontal Stage 2 Deployment Control"),
            ], provider: provider.id, sharing: .init(includeVIN: false))
        var call: ToolCall?
        for try await event in provider.respond(to: request) {
            if case .toolCall(let value) = event { call = value }
        }
        let result = try InterpretationTool.parse(try #require(call))
        #expect(result.codes.count == 2)
        #expect(
            result.codes.allSatisfy {
                !$0.name.isEmpty && !$0.meaning.isEmpty && !$0.firstCheck.isEmpty
                    && ["high", "medium", "low"].contains($0.confidence)
            })
    }

    @Test("Claude answers with text or a valid tool call", .enabled(if: anthropicKey != nil))
    func claude() async throws {
        try await check(
            AnthropicProvider(apiKey: Self.anthropicKey ?? "", model: AnthropicProvider.fastModel))
    }

    @Test("OpenAI answers with text or a valid tool call", .enabled(if: openAIKey != nil))
    func openAI() async throws {
        try await check(
            OpenAIProvider(apiKey: Self.openAIKey ?? "", model: OpenAIProvider.fastModel))
    }

    @Test("Claude interprets the Ghibli airbag codes", .enabled(if: anthropicKey != nil))
    func claudeInterpretations() async throws {
        try await interpret(
            AnthropicProvider(apiKey: Self.anthropicKey ?? "", model: AnthropicProvider.fastModel))
    }

    @Test("OpenAI interprets the Ghibli airbag codes", .enabled(if: openAIKey != nil))
    func openAIInterpretations() async throws {
        try await interpret(
            OpenAIProvider(apiKey: Self.openAIKey ?? "", model: OpenAIProvider.fastModel))
    }
}
