import Foundation

#if canImport(FoundationModels)
    import FoundationModels
#endif

/// Apple's on-device model. Private and free, but smaller than the cloud models, it cannot see
/// images, and it needs macOS 26 on Apple silicon with Apple Intelligence turned on. It cannot
/// force a requested tool, so forced-tool requests may produce text instead.
public struct OnDeviceProvider: AssistantProvider {
    public let id = ProviderID.onDevice

    public init() {}

    /// Nil when available; otherwise why not, in words the user can act on.
    public static var unavailableReason: String? {
        #if canImport(FoundationModels)
            if #available(macOS 26.0, iOS 26.0, *) {
                switch SystemLanguageModel.default.availability {
                case .available: return nil
                case .unavailable(.deviceNotEligible):
                    #if os(macOS)
                        return
                            "This Mac can't run Apple's on-device model (it needs Apple silicon)."
                    #else
                        return "This device can't run Apple's on-device model."
                    #endif
                case .unavailable(.appleIntelligenceNotEnabled):
                    #if os(macOS)
                        return
                            "Turn on Apple Intelligence in System Settings to use the on-device model."
                    #else
                        return "Turn on Apple Intelligence in Settings to use the on-device model."
                    #endif
                case .unavailable(.modelNotReady):
                    return "Apple's on-device model is still downloading. Try again later."
                case .unavailable:
                    return "Apple's on-device model isn't available right now."
                }
            }
        #endif
        #if os(macOS)
            return "The on-device model needs macOS 26 or later."
        #else
            return "The on-device model needs iOS 26 or later."
        #endif
    }

    public func respond(to request: AssistantRequest) -> AsyncThrowingStream<
        AssistantEvent, any Error
    > {
        #if canImport(FoundationModels)
            if #available(macOS 26.0, iOS 26.0, *), Self.unavailableReason == nil {
                return OnDeviceSession.respond(to: request)
            }
        #endif
        return AsyncThrowingStream { continuation in
            continuation.finish(
                throwing: AssistantError.unavailable(Self.unavailableReason ?? "unavailable"))
        }
    }

    /// The conversation as one prompt. Tool calls and results become bracketed lines, and images
    /// are noted, since the text-only session can't see them.
    static func transcript(_ messages: [ConversationMessage]) -> String {
        var lines: [String] = []
        for message in messages {
            let speaker = message.role == .user ? "Person" : "Assistant"
            for part in message.parts {
                switch part {
                case .text(let text): lines.append("\(speaker): \(text)")
                case .image:
                    lines.append("[\(speaker) attached a photo the on-device model can't see]")
                case .toolCall(let call):
                    lines.append("[Assistant used \(call.name): \(call.arguments)]")
                case .toolResult(let result): lines.append("[Result: \(result.content)]")
                }
            }
        }
        lines.append("\nReply to the person's latest message.")
        return lines.joined(separator: "\n")
    }
}

#if canImport(FoundationModels)
    @available(macOS 26.0, iOS 26.0, *)
    enum OnDeviceSession {
        static func respond(to request: AssistantRequest) -> AsyncThrowingStream<
            AssistantEvent, any Error
        > {
            AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        let calls = CallLog()
                        let tools: [any Tool] =
                            request.tools.contains { $0.name == AssistantTools.proposeCheckName }
                            ? [ProposeCheckTool(log: calls), AskUserTool(log: calls)] : []
                        let session = LanguageModelSession(
                            tools: tools, instructions: request.instructions.joined)
                        var sent = ""
                        for try await snapshot in session.streamResponse(
                            to: OnDeviceProvider.transcript(request.messages))
                        {
                            let text = snapshot.content
                            if text.hasPrefix(sent) {
                                continuation.yield(.text(String(text.dropFirst(sent.count))))
                            }
                            sent = text
                        }
                        let made = await calls.calls
                        for call in made { continuation.yield(.toolCall(call)) }
                        continuation.yield(.finished(made.isEmpty ? .endTurn : .toolUse))
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }

    /// Tool calls the on-device model made, replayed afterwards as ordinary `ToolCall`s so the
    /// app handles every provider the same way.
    @available(macOS 26.0, iOS 26.0, *)
    actor CallLog {
        private(set) var calls: [ToolCall] = []

        func record(_ name: String, _ arguments: JSONValue) {
            let text = (try? arguments.serialized()) ?? "{}"
            calls.append(
                ToolCall(id: "on-device-\(UUID().uuidString)", name: name, arguments: text))
        }
    }

    private let waitMessage =
        "Shown to the person. Stop here and wait for their decision; don't call another tool in this reply."

    @available(macOS 26.0, iOS 26.0, *)
    struct ProposeCheckTool: Tool {
        let log: CallLog
        let name = AssistantTools.proposeCheckName
        let description =
            "Propose one read-only check for the person to approve: generic_scan, vehicle_info, adapter_check, or module_codes."

        @Generable
        struct Arguments {
            @Guide(description: "One of: generic_scan, vehicle_info, adapter_check, module_codes")
            var check: String
            @Guide(description: "For module_codes, the module label exactly as in the session data")
            var module: String?
            @Guide(description: "One or two sentences on what this check will tell us")
            var reason: String
        }

        func call(arguments: Arguments) async throws -> String {
            await log.record(
                name,
                [
                    "check": .string(arguments.check),
                    "module": arguments.module.map { .string($0) } ?? .null,
                    "reason": .string(arguments.reason),
                ])
            return waitMessage
        }
    }

    @available(macOS 26.0, iOS 26.0, *)
    struct AskUserTool: Tool {
        let log: CallLog
        let name = AssistantTools.askUserName
        let description = "Ask the person at the car one focused question."

        @Generable
        struct Arguments {
            @Guide(description: "The question")
            var question: String
        }

        func call(arguments: Arguments) async throws -> String {
            await log.record(name, ["question": .string(arguments.question)])
            return waitMessage
        }
    }
#endif
