import CoreGraphics
import Foundation
import ImageIO
import SpiaAssist
import SpiaKit
import SpiaStore
import SwiftData
import Testing
import UniformTypeIdentifiers

@MainActor
@Suite("Assistant conversation")
struct AssistantConversationTests {
    let container: ModelContainer
    let garage: Garage
    let configuration: AssistantConfiguration

    init() throws {
        container = try Garage.inMemoryContainer()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "spia-assist-\(UUID().uuidString)")
        garage = Garage(context: container.mainContext, files: SpiaFiles(root: root))
        // An empty Keychain service: cloud providers have no key, as on a fresh install.
        let suite = "spia-tests-\(UUID().uuidString)"
        configuration = AssistantConfiguration(
            keys: APIKeyStore(service: "com.unfrgivn.spia.tests.\(UUID().uuidString)"),
            defaults: try #require(UserDefaults(suiteName: suite)))
    }

    private func demo() async throws -> (AssistantConversation, DiagnosticSession, Workbench) {
        let vehicle = try garage.addDemoVehicle()
        let session = try #require(vehicle.sessions.first)
        let workbench = Workbench(backend: DemoBackend(), garage: garage)
        await workbench.connect()
        let conversation = AssistantConversation(
            session: session, garage: garage, configuration: configuration)
        conversation.workbench = workbench
        return (conversation, session, workbench)
    }

    /// A reply as a provider would leave it: text and a tool call, awaiting the person.
    @discardableResult
    private func reply(_ call: ToolCall, in session: DiagnosticSession) throws -> ChatMessage {
        let message = ChatMessage(
            sequence: session.messages.count, role: .assistant,
            parts: [.text("Let's look."), .toolCall(call)],
            provider: .anthropic, model: AnthropicProvider.defaultModel)
        message.resolutions = [call.id: .pending]
        session.messages.append(message)
        try garage.context.save()
        return message
    }

    private func proposal(_ id: String, module: String) -> ToolCall {
        ToolCall(
            id: id, name: AssistantTools.proposeCheckName,
            arguments:
                #"{"check":"module_codes","module":"\#(module)","reason":"Airbag lamp is on"}"#)
    }

    @Test("the briefing carries the modules and each result, marked as from a recording")
    func briefing() async throws {
        let (_, session, workbench) = try await demo()
        await workbench.run(
            .moduleDTCs(DemoGarage.airbag.target), for: session.vehicle!, in: session)

        let briefing = garage.briefing(for: session, adapter: workbench.connection.status)

        #expect(briefing.vehicle.vin == DemoGarage.vin)
        #expect(briefing.problem.contains("Horn"))
        let airbag = try #require(briefing.modules.first { $0.request == "744" })
        #expect(airbag.reply == "4C4")
        #expect(airbag.bus == "hs")
        #expect(!airbag.labelConfirmed)
        let event = try #require(briefing.events.last)
        #expect(event.summary == "2 codes: B0001-1B, B0002-1B · 2 failing now")
        #expect(
            event.codes.contains(
                "B0001-1B (Driver Frontal Stage 1 Deployment Control; 1B: resistance in the circuit is too high, which usually means a corroded, loose, or partly broken connection)"
            ))
        #expect(event.fromRecording)
        guard case .moduleDTCs(let dtcs) = event.result else {
            Issue.record("expected module codes")
            return
        }
        #expect(dtcs.target == DemoGarage.airbag.target)
        #expect(briefing.adapter?.hardware == "vLinker FS r2")
    }

    @Test("an approved proposal runs the real check and the model receives its result")
    func approve() async throws {
        let (conversation, session, _) = try await demo()
        let label = try #require(
            session.vehicle?.orderedModules.first { $0.target == DemoGarage.airbag.target }?.label)
        let message = try reply(proposal("toolu_1", module: label), in: session)

        await conversation.approve("toolu_1")

        #expect(
            message.resolutions["toolu_1"]
                == .completed(summary: "2 codes: B0001-1B, B0002-1B · 2 failing now"))
        #expect(session.timeline.last?.body == "2 codes: B0001-1B, B0002-1B · 2 failing now")
        let result = try #require(session.conversation.last)
        #expect(result.role == .user && result.isToolResultsOnly)
        guard case .toolResult(let toolResult) = result.parts.first else {
            Issue.record("expected a tool result")
            return
        }
        #expect(toolResult.callID == "toolu_1")
        #expect(
            toolResult.content.hasPrefix(
                "From the demo recording \"ghibli-orc-flowcontrol\", not a live car."))
        #expect(toolResult.content.contains(#""code":"80011B""#))
        // The conversation then asks Claude for the next reply, which needs a key here.
        #expect(conversation.error == AssistantError.missingAPIKey(.anthropic).description)
        #expect(!conversation.visibleMessages.contains { $0.isToolResultsOnly })
    }

    @Test("a proposal for a module the vehicle doesn't have is refused without running anything")
    func unknownModule() async throws {
        let (conversation, session, _) = try await demo()
        let message = try reply(proposal("toolu_2", module: "Sunroof"), in: session)

        await conversation.approve("toolu_2")

        #expect(
            message.resolutions["toolu_2"]
                == .invalid(#""Sunroof" is not one of this vehicle's modules"#))
        #expect(session.entries.isEmpty)
        guard case .toolResult(let toolResult) = session.conversation.last?.parts.first else {
            Issue.record("expected a tool result")
            return
        }
        #expect(toolResult.isError)
    }

    @Test("cloud providers get nothing until the person allows sharing for the session")
    func consent() async throws {
        let (conversation, session, _) = try await demo()
        #expect(conversation.needsConsent(for: .anthropic))
        #expect(!conversation.needsConsent(for: .onDevice))

        conversation.send("The horn is dead", using: .openAI)
        #expect(session.messages.isEmpty)
        #expect(conversation.error?.contains("Allow this problem's data") == true)

        conversation.allowCloudSharing()
        #expect(session.cloudSharingAllowed)
        conversation.send("The horn is dead", using: .openAI)
        #expect(session.conversation.map(\.text) == ["The horn is dead"])
        #expect(conversation.error == AssistantError.missingAPIKey(.openAI).description)
    }

    @Test(
        "writing instead of answering closes the open question, with its result ahead of the text")
    func skip() async throws {
        let (conversation, session, _) = try await demo()
        conversation.allowCloudSharing()
        let question = ToolCall(
            id: "toolu_3", name: AssistantTools.askUserName,
            arguments: #"{"question":"Does the horn work?"}"#)
        let message = try reply(question, in: session)

        conversation.send("Actually, the airbag light came on first", using: .anthropic)

        #expect(message.resolutions["toolu_3"] == .skipped)
        let sent = try #require(session.conversation.last)
        guard case .toolResult(let skipped) = sent.parts.first,
            case .text(let text) = sent.parts.last
        else {
            Issue.record("expected the tool result, then the text")
            return
        }
        #expect(skipped.callID == "toolu_3")
        #expect(text == "Actually, the airbag light came on first")
    }

    @Test("photos are resized to 2000 px JPEG, stored with the session, and deleted with it")
    func photos() throws {
        let vehicle = try garage.addVehicle(name: "Test car")
        let session = try garage.addSession(to: vehicle, title: "Rattle")
        let png = try Self.png(width: 3000, height: 1500)

        guard case .image(let path, let mediaType) = try garage.storePhoto(png, in: session) else {
            Issue.record("expected an image part")
            return
        }

        #expect(mediaType == "image/jpeg")
        let url = garage.files.url(for: path)
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.jpeg.identifier)
        let stored = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect((stored.width, stored.height) == (2000, 1000))

        try garage.delete(session)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(throws: PhotoError.unreadable) {
            try PhotoPreparation.jpeg(from: Data("not an image".utf8))
        }
    }

    private static func png(width: Int, height: Int) throws -> Data {
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0.8, green: 0.1, blue: 0.1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(
                data as CFMutableData, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
