import Foundation
import Observation
import SpiaAssist
import SpiaKit

extension Garage {
    /// What the assistant is told about `session`: the vehicle, the problem, its modules, and
    /// every note and check result so far.
    public func briefing(for session: DiagnosticSession, adapter: AdapterStatus?) -> SessionBriefing
    {
        let vehicle = session.vehicle
        return SessionBriefing(
            vehicle: .init(
                name: vehicle?.name ?? "Unnamed vehicle", vin: vehicle?.vin,
                notes: vehicle?.notes ?? ""),
            problem: session.problem,
            modules: (vehicle?.orderedModules ?? []).compactMap { preset in
                guard let target = preset.target else { return nil }
                return .init(
                    label: preset.label, bus: target.bus.rawValue,
                    request: String(format: "%03X", target.request),
                    reply: String(format: "%03X", target.response), labelConfirmed: preset.confirmed
                )
            },
            adapter: adapter,
            events: session.timeline.map { entry in
                let result = entry.result
                let fromRecording: Bool
                if case .recording = result?.source {
                    fromRecording = true
                } else {
                    fromRecording = false
                }
                return .init(
                    date: entry.date, kind: entry.kindRaw, title: entry.title, summary: entry.body,
                    result: result?.payload, fromRecording: fromRecording, warnings: entry.warnings)
            })
    }
}

extension Vehicle {
    /// Modules the assistant may name in a proposal: labelled, with valid addresses.
    public var assistantModules: [(label: String, target: ModuleTarget)] {
        var seen = Set<String>()
        return orderedModules.compactMap { preset in
            guard let target = preset.target, seen.insert(preset.label.lowercased()).inserted else {
                return nil
            }
            return (preset.label, target)
        }
    }
}

/// Assistant preferences and keys, shared by every session's conversation.
@MainActor
@Observable
public final class AssistantConfiguration {
    public var settings: AssistantSettings {
        didSet { settings.save(to: defaults) }
    }
    /// Providers with a key in the Keychain.
    public private(set) var configuredKeys: Set<ProviderID> = []
    public let keys: APIKeyStore
    private let defaults: UserDefaults

    public init(keys: APIKeyStore = APIKeyStore(), defaults: UserDefaults = .standard) {
        self.keys = keys
        self.defaults = defaults
        settings = AssistantSettings.load(from: defaults)
        configuredKeys = Set(ProviderID.allCases.filter { (try? keys.key(for: $0)) != nil })
    }

    public func setKey(_ key: String, for provider: ProviderID) throws {
        try keys.setKey(key, for: provider)
        if try keys.key(for: provider) != nil {
            configuredKeys.insert(provider)
        } else {
            configuredKeys.remove(provider)
        }
    }

    /// Nil when `provider` can answer; otherwise what the user needs to do.
    public func unavailableReason(_ provider: ProviderID) -> String? {
        switch provider {
        case .onDevice: return OnDeviceProvider.unavailableReason
        case .anthropic, .openAI:
            return configuredKeys.contains(provider)
                ? nil : AssistantError.missingAPIKey(provider).description
        }
    }
}

/// One session's conversation with the assistant.
///
///     person ──send──▶ provider streams a reply ──▶ saved assistant message
///                                                    │ tool calls? each starts pending
///            approve ─▶ Workbench runs the check ─┐  │
///            decline / answer ────────────────────┴──▶ tool result saved
///                                                    │ all calls resolved?
///                                                    └──▶ provider replies again
///
/// The model never runs anything: a proposal only becomes a check when the person approves it,
/// and then only one of the read-only jobs, on one of this vehicle's modules.
@MainActor
@Observable
public final class AssistantConversation {
    public let session: DiagnosticSession
    /// The adapter this session's checks run on. Set by the screen that owns the connection.
    public var workbench: Workbench?
    /// The reply arriving right now.
    public private(set) var streamingText = ""
    public private(set) var respondingProvider: ProviderID?
    public var error: String?

    private let garage: Garage
    private let configuration: AssistantConfiguration
    private var task: Task<Void, Never>?
    /// Replies the model made in a row to fix its own unusable tool calls, to stop loops.
    private var retries = 0
    private static let maxRetries = 2

    public init(session: DiagnosticSession, garage: Garage, configuration: AssistantConfiguration) {
        self.session = session
        self.garage = garage
        self.configuration = configuration
    }

    public var isResponding: Bool { respondingProvider != nil }

    /// Messages to show. Tool results appear on the proposal they answer instead.
    public var visibleMessages: [ChatMessage] {
        session.conversation.filter { !$0.isToolResultsOnly }
    }

    public var isCheckRunning: Bool {
        session.messages.contains { $0.resolutions.values.contains(.running) }
    }

    public func needsConsent(for provider: ProviderID) -> Bool {
        provider.isCloud && !session.cloudSharingAllowed
    }

    public func allowCloudSharing() {
        session.cloudSharingAllowed = true
        save()
    }

    /// Sends the person's message. Questions and proposals they didn't respond to are closed,
    /// and the model is told they moved on.
    public func send(_ text: String, photos: [StoredPart] = [], using provider: ProviderID) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isResponding, !isCheckRunning, !trimmed.isEmpty || !photos.isEmpty else { return }
        guard !needsConsent(for: provider) else {
            error = "Allow this session's data to be shared with \(provider.displayName) first."
            return
        }
        // Tool results first: providers require them to follow the calls they answer.
        var parts = closeOpenCalls()
        if !trimmed.isEmpty { parts.append(.text(trimmed)) }
        parts += photos
        append(.user, parts)
        retries = 0
        respond(using: provider)
    }

    /// Runs an approved proposal and gives the model its result.
    public func approve(_ callID: String) async {
        guard case let (message, call)? = openCall(callID), message.resolutions[callID] == .pending
        else { return }
        guard let workbench, workbench.connection.status != nil else {
            error = "Connect the adapter first, then approve the check."
            return
        }
        let job: DiagnosticJob
        do {
            job = try Self.job(for: call, modules: session.vehicle?.assistantModules ?? [])
        } catch {
            resolve(
                callID, in: message, .invalid(String(describing: error)),
                error: String(describing: error))
            continueConversation()
            return
        }
        message.resolutions[callID] = .running
        save()
        let outcome = await workbench.run(job, in: session)
        guard let (resolution, result) = Self.feedback(for: outcome, callID: callID) else {
            message.resolutions[callID] = .pending
            error = "Another check is running. Approve this one when it finishes."
            save()
            return
        }
        message.resolutions[callID] = resolution
        append(.user, [.toolResult(result)])
        continueConversation()
    }

    public func decline(_ callID: String) {
        guard case let (message, _)? = openCall(callID), message.resolutions[callID] == .pending
        else { return }
        message.resolutions[callID] = .declined
        append(
            .user,
            [
                .toolResult(
                    ToolResult(callID: callID, content: "The person declined to run this check."))
            ])
        continueConversation()
    }

    public func answer(_ callID: String, with text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, case let (message, _)? = openCall(callID),
            message.resolutions[callID] == .pending
        else { return }
        message.resolutions[callID] = .answered(trimmed)
        append(.user, [.toolResult(ToolResult(callID: callID, content: trimmed))])
        continueConversation()
    }

    /// Stops the reply in progress, keeping what arrived.
    public func stop() {
        task?.cancel()
    }

    // MARK: - Replies

    private func respond(using id: ProviderID) {
        let provider: any AssistantProvider
        do {
            provider = try configuration.settings.provider(id, keys: configuration.keys)
        } catch {
            self.error = String(describing: error)
            return
        }
        let modules = session.vehicle?.assistantModules ?? []
        let request = AssistantRequest(
            instructions: AssistantInstructions.make(
                briefing: garage.briefing(for: session, adapter: workbench?.connection.status),
                provider: id, sharing: SharingPolicy(includeVIN: configuration.settings.shareVIN)),
            messages: history(),
            tools: AssistantTools.definitions(modules: modules.map(\.label)))
        error = nil
        streamingText = ""
        respondingProvider = id
        task = Task { [weak self] in
            await self?.receive(provider.respond(to: request), from: id)
        }
    }

    private func receive(
        _ events: AsyncThrowingStream<AssistantEvent, any Error>, from id: ProviderID
    ) async {
        var calls: [ToolCall] = []
        var failure: String?
        do {
            for try await event in events {
                switch event {
                case .text(let delta): streamingText += delta
                case .toolCall(let call): calls.append(call)
                case .finished(.maxTokens): failure = "The reply was cut off at its length limit."
                case .finished: break
                }
            }
        } catch {
            if !Task.isCancelled { failure = String(describing: error) }
        }
        // A stopped reply keeps its text, but half-considered proposals are dropped.
        if Task.isCancelled { calls = [] }
        let text = streamingText.trimmingCharacters(in: .whitespacesAndNewlines)
        streamingText = ""
        respondingProvider = nil
        task = nil
        if !text.isEmpty || !calls.isEmpty {
            saveReply(text: text, calls: calls, from: id)
        }
        error = failure
        if !calls.isEmpty, retries < Self.maxRetries, continueConversation() {
            retries += 1
        }
    }

    /// Saves the reply. Tool calls that can't be used are answered with the reason straight
    /// away, so the model can correct itself.
    private func saveReply(text: String, calls: [ToolCall], from id: ProviderID) {
        var parts: [StoredPart] = text.isEmpty ? [] : [.text(text)]
        parts += calls.map { .toolCall($0) }
        let message = append(
            .assistant, parts, provider: id, model: configuration.settings.model(for: id))
        let modules = session.vehicle?.assistantModules ?? []
        var resolutions: [String: ToolResolution] = [:]
        var rejected: [StoredPart] = []
        for call in calls {
            do {
                if case .proposeCheck = try AssistantTools.parse(call) {
                    _ = try Self.job(for: call, modules: modules)
                }
                resolutions[call.id] = .pending
            } catch {
                resolutions[call.id] = .invalid(String(describing: error))
                rejected.append(
                    .toolResult(
                        ToolResult(
                            callID: call.id, content: String(describing: error), isError: true)))
            }
        }
        message.resolutions = resolutions
        if !rejected.isEmpty { append(.user, rejected) }
        save()
    }

    /// Asks for the next reply once every call in the latest reply is resolved and the model has
    /// something new to read. Returns whether it did.
    @discardableResult
    private func continueConversation() -> Bool {
        let conversation = session.conversation
        guard !isResponding, let last = conversation.last, last.role == .user,
            let reply = conversation.last(where: { $0.role == .assistant }),
            !reply.toolCalls.isEmpty, !reply.resolutions.values.contains(where: \.isOpen)
        else { return false }
        respond(using: reply.provider ?? configuration.settings.defaultProvider)
        return true
    }

    // MARK: - Stored conversation

    /// The conversation as the providers see it. Photos are read back from their files.
    private func history() -> [ConversationMessage] {
        session.conversation.compactMap { message in
            let parts = message.parts.map { part -> MessagePart in
                switch part {
                case .text(let text):
                    return .text(text)
                case .image(let path, let mediaType):
                    guard let data = try? Data(contentsOf: garage.files.url(for: path)) else {
                        return .text("[A photo that is no longer available]")
                    }
                    return .image(ImageInput(mediaType: mediaType, data: data))
                case .toolCall(let call):
                    return .toolCall(call)
                case .toolResult(let result):
                    return .toolResult(result)
                }
            }
            return parts.isEmpty ? nil : ConversationMessage(role: message.role, parts: parts)
        }
    }

    private func openCall(_ callID: String) -> (ChatMessage, ToolCall)? {
        for message in session.messages where message.role == .assistant {
            if let call = message.toolCalls.first(where: { $0.id == callID }) {
                return (message, call)
            }
        }
        return nil
    }

    /// Marks every pending call skipped, returning the results that tell the model so.
    private func closeOpenCalls() -> [StoredPart] {
        var results: [StoredPart] = []
        for message in session.conversation where message.role == .assistant {
            var resolutions = message.resolutions
            for call in message.toolCalls where resolutions[call.id] == .pending {
                resolutions[call.id] = .skipped
                results.append(
                    .toolResult(
                        ToolResult(
                            callID: call.id,
                            content:
                                "The person didn't respond to this and wrote a new message instead."
                        )))
            }
            if resolutions != message.resolutions { message.resolutions = resolutions }
        }
        return results
    }

    private func resolve(
        _ callID: String, in message: ChatMessage, _ resolution: ToolResolution, error: String
    ) {
        message.resolutions[callID] = resolution
        append(.user, [.toolResult(ToolResult(callID: callID, content: error, isError: true))])
    }

    @discardableResult
    private func append(
        _ role: ConversationRole, _ parts: [StoredPart], provider: ProviderID? = nil,
        model: String? = nil
    ) -> ChatMessage {
        let sequence = (session.messages.map(\.sequence).max() ?? -1) + 1
        let message = ChatMessage(
            sequence: sequence, role: role, parts: parts, provider: provider, model: model)
        session.messages.append(message)
        session.updatedAt = message.date
        save()
        return message
    }

    private func save() {
        do {
            try garage.context.save()
        } catch {
            self.error = "Couldn't save the conversation: \(error)"
        }
    }

    // MARK: - Functional core

    static func job(for call: ToolCall, modules: [(label: String, target: ModuleTarget)]) throws
        -> DiagnosticJob
    {
        guard case .proposeCheck(let proposal) = try AssistantTools.parse(call) else {
            throw AssistantTools.ParseError.badArguments("not a check proposal")
        }
        return try proposal.job(modules: modules)
    }

    /// What the person sees on the proposal, and what the model is told. Nil when the check
    /// never started.
    static func feedback(for outcome: CheckOutcome, callID: String) -> (ToolResolution, ToolResult)?
    {
        switch outcome {
        case .completed(let result):
            let summary = ResultText.summary(result)
            var content = summary
            if case .recording(let name) = result.source {
                content = "From the demo recording \"\(name)\", not a live car. " + content
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            if let data = try? encoder.encode(result.payload), data.count <= 20_000 {
                content += "\n\nFull result: " + String(decoding: data, as: UTF8.self)
            }
            return (.completed(summary: summary), ToolResult(callID: callID, content: content))
        case .failed(let message):
            return (
                .failed(message: message),
                ToolResult(callID: callID, content: "The check failed: \(message)", isError: true)
            )
        case .cancelled:
            return (
                .failed(message: "Cancelled"),
                ToolResult(
                    callID: callID, content: "The person cancelled the check before it finished.")
            )
        case .notStarted:
            return nil
        }
    }
}
