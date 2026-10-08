import Foundation
import SpiaAssist
import SpiaKit
import SpiaStore
import SwiftData
import Testing

@MainActor
@Suite("Problems")
struct ProblemTests {
    private struct TestStore {
        let container: ModelContainer
        let garage: Garage
    }

    private func makeStore() throws -> TestStore {
        let container = try Garage.inMemoryContainer()
        return TestStore(
            container: container,
            garage: Garage(
                context: container.mainContext,
                files: SpiaFiles(
                    root: FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString))))
    }

    private func makeConfiguration() throws -> AssistantConfiguration {
        let suite = "spia-problem-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return AssistantConfiguration(
            keys: APIKeyStore(service: "com.unfrgivn.spia.tests.\(UUID().uuidString)"),
            defaults: defaults)
    }

    @Test("derives titles from the first sentence or clause")
    func titles() {
        let cases = [
            ("", "New problem"),
            ("  the horn is dead. The airbag light is on", "The horn is dead"),
            ("brakes squeal!", "Brakes squeal"),
            ("Battery is flat?", "Battery is flat"),
            ("Rattle; mostly on cold starts", "Rattle"),
            ("Wheel - controls are dead", "Wheel"),
            (
                "horn, cruise, volume, and cluster buttons on the wheel don't work. Airbag warning light is on.",
                "Horn, cruise, volume, and cluster buttons on…"
            ),
            (
                "the engine makes a very long rattling sound that continues after the car warms up",
                "The engine makes a very long rattling sound…"
            ),
            ("already fine", "Already fine"),
            ("  one   space  ", "One space"),
            ("lights don't work, either", "Lights don't work, either"),
            ("A warning appears. Then it disappears", "A warning appears"),
        ]
        for (input, expected) in cases {
            #expect(ProblemTitle.derive(from: input) == expected)
        }
    }

    @Test("renaming trims and ignores empty titles")
    func rename() throws {
        let store = try makeStore()
        let garage = store.garage
        let vehicle = try garage.addVehicle(name: "Test car")
        let session = try garage.addSession(to: vehicle, title: "Old title")
        try garage.rename(session, to: "  New title  ")
        #expect(session.title == "New title")
        try garage.rename(session, to: " \n ")
        #expect(session.title == "New title")
    }

    @Test("starting a problem without a cloud key keeps it local")
    func startProblemWithoutKey() throws {
        let store = try makeStore()
        let garage = store.garage
        let configuration = try makeConfiguration()
        let vehicle = try garage.addVehicle(name: "Test car")
        var conversation: AssistantConversation?
        let text = "Horn and wheel buttons are dead, airbag light is on"
        let session = try garage.startProblem(
            for: vehicle, saying: text, configuration: configuration,
            conversation: &conversation)

        #expect(session.title == ProblemTitle.derive(from: text))
        #expect(session.problem == text)
        #expect(session.messages.isEmpty)
        #expect(!session.cloudSharingAllowed)
        #expect(conversation == nil)
    }

    @Test("starting a problem with unavailable on-device assistance keeps it local")
    func startProblemOnDeviceWhenUnavailable() throws {
        let store = try makeStore()
        let garage = store.garage
        let configuration = try makeConfiguration()
        configuration.settings.defaultProvider = .onDevice
        let vehicle = try garage.addVehicle(name: "Test car")
        var conversation: AssistantConversation?
        let text = "Horn and wheel buttons are dead, airbag light is on"
        let session = try garage.startProblem(
            for: vehicle, saying: text, configuration: configuration,
            conversation: &conversation)

        #expect(OnDeviceProvider.unavailableReason != nil)
        #expect(session.title == ProblemTitle.derive(from: text))
        #expect(session.problem == text)
        #expect(session.messages.isEmpty)
        #expect(!session.cloudSharingAllowed)
        #expect(conversation == nil)
    }

    @Test(
        "starting a problem sends the first message and receives a reply",
        .enabled(if: ProcessInfo.processInfo.environment["SPIA_ANTHROPIC_API_KEY"] != nil))
    func startProblemLive() async throws {
        let store = try makeStore()
        let garage = store.garage
        let configuration = try makeConfiguration()
        let key = try #require(ProcessInfo.processInfo.environment["SPIA_ANTHROPIC_API_KEY"])
        try configuration.setKey(key, for: .anthropic)
        let vehicle = try garage.addVehicle(name: "Test car")
        var startedConversation: AssistantConversation?
        let text = "The horn is dead and the airbag warning light is on"
        let session = try garage.startProblem(
            for: vehicle, saying: text, configuration: configuration,
            conversation: &startedConversation)
        let conversation = try #require(startedConversation)

        for _ in 0..<300 {
            if !conversation.isResponding { break }
            try await Task.sleep(for: .milliseconds(100))
        }

        #expect(session.cloudSharingAllowed)
        #expect(session.conversation.contains { $0.role == .user && $0.text == text })
        #expect(
            session.conversation.contains {
                $0.role == .assistant
                    && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            })
        #expect(!conversation.isResponding)
    }
}
