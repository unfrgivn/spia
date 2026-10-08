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
                #"{"reading":"The airbag controller has two stored faults and the body computer is clear.","questions":[{"question":"Does the airbag lamp stay on after start?","module":"Airbag controller (ORC)","codes":["B0001-1B","B0002-1B"]},{"question":"Did this begin after any work?","module":null,"codes":[]}],"checks":[{"check":"module_codes","module":"Airbag controller (ORC)","reason":"Read the controller again to see whether the faults remain."}]}"#
        )
        let result = try ReviewTool.parse(call, modules: modules)
        #expect(result.reading.contains("airbag"))
        #expect(result.questions.count == 2)
        #expect(result.questions[0].module == modules[0])
        #expect(result.questions[0].codes == ["B0001-1B", "B0002-1B"])
        #expect(result.questions[1].module == nil && result.questions[1].codes.isEmpty)
        #expect(result.checks.count == 1)
        #expect(result.checks[0].check == .moduleCodes)
    }

    @Test("review rejects unknown modules and deliberately rejects a fourth question")
    func rejectsUnknownModuleAndTooManyQuestions() {
        let unknown = ToolCall(
            id: "1", name: ReviewTool.name,
            arguments:
                #"{"reading":"x","questions":[{"question":"x","module":"Engine","codes":[]}],"checks":[]}"#
        )
        #expect(throws: Error.self) { try ReviewTool.parse(unknown, modules: modules) }
        let tooMany = ToolCall(
            id: "1", name: ReviewTool.name,
            arguments:
                #"{"reading":"x","questions":[{"question":"1","module":null,"codes":[]},{"question":"2","module":null,"codes":[]},{"question":"3","module":null,"codes":[]},{"question":"4","module":null,"codes":[]}],"checks":[]}"#
        )
        #expect(throws: Error.self) { try ReviewTool.parse(tooMany, modules: modules) }
    }

    @Test("record_review rejects and quotes a bad code element")
    func rejectsBadCodeElement() {
        let call = ToolCall(
            id: "1", name: ReviewTool.name,
            arguments:
                #"{"reading":"x","questions":[{"question":"x","module":null,"codes":["B0001-1B","not-a-code"]}],"checks":[]}"#
        )
        do {
            _ = try ReviewTool.parse(call, modules: modules)
            Issue.record("bad code was accepted")
        } catch let error as AssistantError {
            #expect(error == .malformedStream("invalid review code \"not-a-code\""))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
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
            codes: [
                (
                    printed: "B0001-1B", name: "Driver Frontal Stage 1 Deployment Control",
                    failureType:
                        "1B: resistance in the circuit is too high"
                )
            ],
            unread: ["Steering column"],
            provider: .anthropic, sharing: .init(includeVIN: false))
        let text = reviewText(request) + request.instructions.joined
        #expect(text.contains("The horn stopped after rain."))
        #expect(text.contains("Was the battery disconnected?"))
        #expect(text.contains("Yes, yesterday."))
        #expect(text.contains("B0001-1B"))
        #expect(text.contains("Driver Frontal Stage 1 Deployment Control"))
        #expect(text.contains("failure type 1B: resistance"))
        #expect(text.contains("use it as given"))
        #expect(text.contains("Not read yet:\n- Steering column"))
        #expect(text.contains("at most three sentences of plain prose, with no lists or headings"))
        #expect(!text.contains("SECRET"))
        #expect(request.toolChoice == .tool(ReviewTool.name))
        #expect(request.maxOutputTokens == 900)
    }

    @Test("review prompts identify an unknown failure type")
    func unknownFailureTypePrompt() {
        let briefing = SessionBriefing(
            vehicle: .init(name: "Ghibli", vin: nil, notes: ""), problem: "", modules: [],
            adapter: nil, events: [])
        let request = ReviewRequest.make(
            briefing: briefing, scope: .car, answered: [],
            codes: [(printed: "B0001-E7", name: nil, failureType: "E7, not described by Spia")],
            unread: [], provider: .anthropic, sharing: .init(includeVIN: false))
        #expect(reviewText(request).contains("failure type E7, not described by Spia"))
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
            briefing: briefing, scope: .car, answered: [],
            codes: [] as [(printed: String, name: String?, failureType: String?)], unread: [],
            provider: provider.id,
            sharing: .init(includeVIN: false))
        var call: ToolCall?
        var usage: TokenUsage?
        for try await event in provider.respond(to: request) {
            switch event {
            case .toolCall(let value): call = value
            case .usage(let value): usage = value
            default: break
            }
        }
        // A real stream must report what it cost; the ledger depends on it.
        let cost = try #require(usage)
        #expect(cost.input > 0 && cost.output > 0)
        let result = try ReviewTool.parse(try #require(call), modules: modules)
        #expect(!result.reading.isEmpty)
        #expect(result.questions.count <= 3)
    }
}
