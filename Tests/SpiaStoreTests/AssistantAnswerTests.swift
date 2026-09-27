import Foundation
import SpiaAssist
import SwiftData
import Testing

@testable import SpiaStore

@MainActor
@Suite("Answers to the board's questions")
struct AssistantAnswerTests {
    let container: ModelContainer
    let garage: Garage

    init() throws {
        container = try Garage.inMemoryContainer()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "spia-answers-\(UUID().uuidString)")
        garage = Garage(context: container.mainContext, files: SpiaFiles(root: root))
    }

    private let question =
        "What do 80011B and 80021B from the airbag controller (ORC) mean on this car, and what should I check first?"

    private func say(_ session: DiagnosticSession, _ role: ConversationRole, _ parts: [StoredPart])
    {
        let sequence = (session.messages.map(\.sequence).max() ?? -1) + 1
        session.messages.append(
            ChatMessage(
                sequence: sequence, role: role, parts: parts,
                provider: role == .assistant ? .anthropic : nil))
    }

    @Test("the answer is the first reply with words after the question was last asked")
    func latestAnswer() throws {
        let session = try #require(try garage.addDemoVehicle().sessions.first)
        #expect(session.answer(to: question) == nil)

        say(session, .user, [.text(question)])
        say(session, .assistant, [.text("First answer.")])
        say(session, .user, [.text("And the horn?")])
        say(session, .assistant, [.text("About the horn.")])
        #expect(session.answer(to: question)?.text == "First answer.")

        // Asked again: the old answer no longer counts until there's a new one. A check's result
        // coming back in between doesn't end the wait.
        say(session, .user, [.text(question)])
        #expect(session.answer(to: question) == nil)
        say(session, .assistant, [.text("")])
        say(
            session, .user,
            [.toolResult(ToolResult(callID: "call-1", content: "Done", isError: false))])
        say(session, .assistant, [.text("Second answer.")])
        #expect(session.answer(to: question)?.text == "Second answer.")
        #expect(session.answer(to: question)?.provider == .anthropic)
    }

    @Test("a question left for another before any reply has no answer")
    func movedOn() throws {
        let session = try #require(try garage.addDemoVehicle().sessions.first)
        say(session, .user, [.text(question)])
        say(session, .user, [.text("Never mind. What about the battery?")])
        say(session, .assistant, [.text("About the battery.")])
        #expect(session.answer(to: question) == nil)
    }
}
