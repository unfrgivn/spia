import Foundation
import SpiaAssist
import SpiaKit
import Testing

private func reviewText(_ request: AssistantRequest) -> String {
    request.messages.flatMap(\.parts).compactMap { part in
        if case .text(let text) = part { return text }
        return nil
    }.joined(separator: "\n")
}

private func assertStrict(_ value: JSONValue) {
    guard case .object(let object) = value else { return }
    let isObjectSchema = object["type"]?.string == "object"
    guard isObjectSchema else { return }
    #expect(object["additionalProperties"] == .bool(false))
    guard case .object(let properties)? = object["properties"],
        case .array(let required)? = object["required"]
    else { return }
    #expect(Set(required.compactMap(\.string)) == Set(properties.keys))
    for property in properties.values { assertStrict(property) }
    if let items = object["items"] { assertStrict(items) }
}

@Suite("Review assistant")
struct ReviewTests {
    private let modules = ["Airbag controller (ORC)"]

    @Test("record_review is strict at every object level")
    func strictDefinition() {
        let parameters = ReviewTool.definition(modules: modules).parameters
        assertStrict(parameters)
    }

    @Test("record_review parses tagged and untagged questions and a module check")
    func parsesRealisticCall() throws {
        let call = ToolCall(
            id: "review-1", name: ReviewTool.name,
            arguments:
                #"{"reading":"The airbag controller has two stored faults and the body computer is clear.","questions":[{"question":"Does the airbag lamp stay on after start?","module":"Airbag controller (ORC)","code":"B0001-1B"},{"question":"Did this begin after any work?","module":null,"code":null}],"checks":[{"check":"module_codes","module":"Airbag controller (ORC)","reason":"Read the controller again to see whether the faults remain."}]}"#
        )
        let result = try ReviewTool.parse(call, modules: modules)
        #expect(result.reading.contains("airbag"))
        #expect(result.questions.count == 2)
        #expect(result.questions[0].module == modules[0])
        #expect(result.questions[0].code == "B0001-1B")
        #expect(result.questions[1].module == nil && result.questions[1].code == nil)
        #expect(result.checks.count == 1)
        #expect(result.checks[0].check == .moduleCodes)
    }

    @Test("review rejects unknown modules and deliberately rejects a fourth question")
    func rejectsUnknownModuleAndTooManyQuestions() {
        let unknown = ToolCall(
            id: "1", name: ReviewTool.name,
            arguments:
                #"{"reading":"x","questions":[{"question":"x","module":"Engine","code":null}],"checks":[]}"#
        )
        #expect(throws: Error.self) { try ReviewTool.parse(unknown, modules: modules) }
        let tooMany = ToolCall(
            id: "1", name: ReviewTool.name,
            arguments:
                #"{"reading":"x","questions":[{"question":"1","module":null,"code":null},{"question":"2","module":null,"code":null},{"question":"3","module":null,"code":null},{"question":"4","module":null,"code":null}],"checks":[]}"#
        )
        #expect(throws: Error.self) { try ReviewTool.parse(tooMany, modules: modules) }
    }

    @Test("problem review quotes answers and withholds VIN")
    func problemRequest() {
        let briefing = SessionBriefing(
            vehicle: .init(name: "Ghibli", vin: "SECRET", notes: ""),
            problem: "Horn dead",
            modules: modules.map {
                .init(label: $0, bus: "hs", request: "744", reply: "4C4", labelConfirmed: true)
            }, adapter: nil,
            events: [
                .init(
                    date: .now, kind: "read", title: "Airbag", summary: "fault", result: nil,
                    codes: ["B0001-1B (Driver Frontal Stage 1 Deployment Control)"],
                    fromRecording: false, warnings: [])
            ])
        let request = ReviewRequest.make(
            briefing: briefing,
            scope: .problem(title: "Horn controls", text: "The horn stopped after rain."),
            answered: [(question: "Was the battery disconnected?", answer: "Yes, yesterday.")],
            provider: .anthropic, sharing: .init(includeVIN: false))
        let text = reviewText(request) + request.instructions
        #expect(text.contains("The horn stopped after rain."))
        #expect(text.contains("Was the battery disconnected?"))
        #expect(text.contains("Yes, yesterday."))
        #expect(text.contains("B0001-1B"))
        #expect(text.contains("Driver Frontal Stage 1 Deployment Control"))
        #expect(!text.contains("SECRET"))
        #expect(request.toolChoice == .tool(ReviewTool.name))
    }

    @Test(
        "Anthropic reviews a realistic demo board",
        .enabled(if: ProcessInfo.processInfo.environment["SPIA_ANTHROPIC_API_KEY"] != nil))
    func anthropicReview() async throws {
        try await liveReview(
            AnthropicProvider(
                apiKey: ProcessInfo.processInfo.environment["SPIA_ANTHROPIC_API_KEY"] ?? "",
                model: AnthropicProvider.fastModel))
    }

    @Test(
        "OpenAI reviews a realistic demo board",
        .enabled(if: ProcessInfo.processInfo.environment["SPIA_OPENAI_API_KEY"] != nil))
    func openAIReview() async throws {
        try await liveReview(
            OpenAIProvider(
                apiKey: ProcessInfo.processInfo.environment["SPIA_OPENAI_API_KEY"] ?? "",
                model: OpenAIProvider.fastModel))
    }

    private func liveReview(_ provider: any AssistantProvider) async throws {
        let briefing = SessionBriefing(
            vehicle: .init(name: "2017 Maserati Ghibli S Q4", vin: nil, notes: ""),
            problem: "Horn and steering-wheel controls are dead.",
            modules: modules.map {
                .init(label: $0, bus: "hs", request: "744", reply: "4C4", labelConfirmed: true)
            }, adapter: nil,
            events: [
                .init(
                    date: .now, kind: "read", title: "Airbag", summary: "Two stored faults",
                    result: nil, codes: ["B0001-1B", "B0002-1B"], fromRecording: true, warnings: [])
            ])
        let request = ReviewRequest.make(
            briefing: briefing, scope: .car, answered: [], provider: provider.id,
            sharing: .init(includeVIN: false))
        var call: ToolCall?
        for try await event in provider.respond(to: request) {
            if case .toolCall(let value) = event { call = value }
        }
        let result = try ReviewTool.parse(try #require(call), modules: modules)
        #expect(!result.reading.isEmpty)
        #expect(result.questions.count <= 3)
    }
}
