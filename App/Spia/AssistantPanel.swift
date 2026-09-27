import SpiaAssist
import SpiaKit
import SpiaStore
import SwiftUI
import UniformTypeIdentifiers

/// The assistant, beside the session. It reads the session, asks questions, and proposes checks
/// the person approves one at a time.
struct AssistantPanel: View {
    @Environment(AppModel.self) private var model
    #if os(macOS)
        @Environment(\.openSettings) private var openSettings
    #endif
    let conversation: AssistantConversation
    /// Opens the connection assistant, for proposals that need the adapter.
    let connect: () -> Void

    @State private var provider: ProviderID?
    @State private var draft = ""
    @State private var photos: [StoredPart] = []
    @State private var importingPhotos = false
    @State private var consentFor: ProviderID?
    @State private var problem: String?
    @State private var showingSettings = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            messages
            Divider()
            composer
        }
        .sheet(item: $consentFor) { provider in
            CloudConsentSheet(
                provider: provider, shareVIN: model.assistant.settings.shareVIN,
                allow: {
                    conversation.allowCloudSharing()
                    consentFor = nil
                    send()
                }, cancel: { consentFor = nil })
        }
        .fileImporter(
            isPresented: $importingPhotos, allowedContentTypes: [.image],
            allowsMultipleSelection: true
        ) {
            result in
            switch result {
            case .success(let urls): addPhotos(urls)
            case .failure(let error): problem = error.localizedDescription
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            addPhotos(urls)
            return true
        }
        .background(Palette.panel)
        .errorAlert($problem)
        #if os(iOS)
            .sheet(isPresented: $showingSettings) {
                NavigationStack {
                    AssistantSettingsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showingSettings = false }
                        }
                    }
                }
            }
        #endif
    }

    private var chosenProvider: ProviderID { provider ?? model.assistant.settings.defaultProvider }

    // MARK: Header

    private var header: some View {
        HStack {
            Label("Assistant", systemImage: "sparkles")
                .font(.headline)
            Spacer()
            Menu {
                ForEach(ProviderID.allCases) { option in
                    Button {
                        provider = option
                    } label: {
                        let reason = model.assistant.unavailableReason(option)
                        Text(option.displayName) + Text(reason == nil ? "" : " (not set up)")
                    }
                }
                Divider()
                Button("Assistant Settings…", action: showSettings)
            } label: {
                ProviderLabel(provider: chosenProvider)
            }
            .platformBorderlessMenu()
            .fixedSize()
            .help("Which model answers your next message")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: Messages

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if conversation.visibleMessages.isEmpty && !conversation.isResponding {
                        AssistantIntro(ask: { draft = $0 })
                    }
                    ForEach(conversation.visibleMessages) { message in
                        MessageView(message: message, conversation: conversation, connect: connect)
                            .id(message.id)
                    }
                    if let responding = conversation.respondingProvider {
                        StreamingReply(text: conversation.streamingText, provider: responding) {
                            conversation.stop()
                        }
                        .id("streaming")
                    }
                    if let error = conversation.error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                            .card(tint: .orange)
                            .id("error")
                    }
                }
                .padding(14)
            }
            .onChange(of: conversation.visibleMessages.count) { scrollToEnd(proxy) }
            .onChange(of: conversation.streamingText) { scrollToEnd(proxy) }
            .onAppear { scrollToEnd(proxy) }
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        if conversation.isResponding {
            proxy.scrollTo("streaming", anchor: .bottom)
        } else if let last = conversation.visibleMessages.last {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }

    // MARK: Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !photos.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(Array(photos.enumerated()), id: \.offset) { index, part in
                            PhotoThumbnail(part: part, size: 52)
                                .overlay(alignment: .topTrailing) {
                                    Button {
                                        photos.remove(at: index)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .symbolRenderingMode(.palette)
                                            .foregroundStyle(.white, .black.opacity(0.6))
                                    }
                                    .buttonStyle(.plain)
                                    .padding(2)
                                }
                        }
                    }
                }
                if chosenProvider == .onDevice {
                    Text(
                        "The on-device model can't see photos. Choose Claude or OpenAI to include them."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                Button {
                    importingPhotos = true
                } label: {
                    Image(systemName: "photo.badge.plus")
                }
                .buttonStyle(.borderless)
                .help("Attach photos (or drop them here)")

                TextField("Describe what you see, or ask…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .onSubmit(send)

                if conversation.isResponding {
                    Button("Stop", systemImage: "stop.circle.fill") { conversation.stop() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Stop the reply")
                } else {
                    Button("Send", systemImage: "arrow.up.circle.fill", action: send)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .font(.title2)
                        .disabled(!canSend)
                        .keyboardShortcut(.return, modifiers: .command)
                        .help(sendHelp)
                }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(
                    PlatformColor.textBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.quaternary))

            if let reason = model.assistant.unavailableReason(chosenProvider) {
                HStack(alignment: .firstTextBaseline) {
                    Text(reason)
                    if chosenProvider.isCloud {
                        Button("Open Settings", action: showSettings).platformLinkButton()
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else if chosenProvider.isCloud {
                Label("Sent to \(chosenProvider.displayName)", systemImage: "icloud")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Label(PlatformText.staysOnDevice, systemImage: "lock.laptopcomputer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }

    private func showSettings() {
        #if os(macOS)
            openSettings()
        #else
            showingSettings = true
        #endif
    }

    private var hasContent: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !photos.isEmpty
    }

    private var canSend: Bool {
        hasContent && !conversation.isCheckRunning
            && model.assistant.unavailableReason(chosenProvider) == nil
    }

    private var sendHelp: String {
        if conversation.isCheckRunning { return "Wait for the check to finish" }
        return "Send (⌘↩)"
    }

    private func send() {
        guard canSend, !conversation.isResponding else { return }
        if conversation.needsConsent(for: chosenProvider) {
            consentFor = chosenProvider
            return
        }
        // The on-device model can't use photos; they stay attached for a cloud model.
        let attached = chosenProvider == .onDevice ? [] : photos
        conversation.send(draft, photos: attached, using: chosenProvider)
        draft = ""
        if chosenProvider != .onDevice { photos = [] }
    }

    private func addPhotos(_ urls: [URL]) {
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                photos.append(
                    try model.garage.storePhoto(Data(contentsOf: url), in: conversation.session))
            } catch {
                problem = "\(url.lastPathComponent): \(error)"
            }
        }
    }
}

// MARK: - Pieces

private struct ProviderLabel: View {
    let provider: ProviderID

    var body: some View {
        Label(
            provider.displayName, systemImage: provider.isCloud ? "icloud" : "lock.laptopcomputer"
        )
        .font(.callout)
    }
}

private struct AssistantIntro: View {
    let ask: (String) -> Void

    private let starters = [
        "Where should we start?",
        "What do the codes found so far mean?",
        "What should I check by hand before running more scans?",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Work through the problem together.")
                .font(.headline)
            Text(
                "The assistant reads this session's problem, notes, and results. It asks what you're seeing and suggests read-only checks, which run only when you approve them."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            ForEach(starters, id: \.self) { starter in
                Button(starter) { ask(starter) }
                    .platformLinkButton()
                    .font(.callout)
            }
        }
        .card()
    }
}

private struct StreamingReply: View {
    let text: String
    let provider: ProviderID
    let stop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(
                    text.isEmpty
                        ? "\(provider.displayName) is thinking…"
                        : "\(provider.displayName) is replying…")
                Spacer()
                Button("Stop", action: stop).platformLinkButton()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if !text.isEmpty { MarkdownText(text: text) }
        }
    }
}

private struct MessageView: View {
    let message: ChatMessage
    let conversation: AssistantConversation
    let connect: () -> Void

    var body: some View {
        switch message.role {
        case .user: userMessage
        case .assistant: assistantMessage
        }
    }

    private var userMessage: some View {
        VStack(alignment: .trailing, spacing: 6) {
            let images = message.parts.filter { if case .image = $0 { true } else { false } }
            if !images.isEmpty {
                HStack {
                    ForEach(Array(images.enumerated()), id: \.offset) { _, part in
                        PhotoThumbnail(part: part, size: 80)
                    }
                }
            }
            if !message.text.isEmpty {
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var assistantMessage: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !message.text.isEmpty { MarkdownText(text: message.text) }
            ForEach(message.toolCalls, id: \.id) { call in
                ToolCallCard(
                    call: call, resolution: message.resolutions[call.id] ?? .pending,
                    conversation: conversation,
                    connect: connect)
            }
            if let provider = message.provider {
                Text(
                    [provider.displayName, message.model].compactMap { $0 }.joined(separator: " · ")
                )
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
    }
}

/// A proposal or question from the assistant, with what the person decided.
private struct ToolCallCard: View {
    let call: ToolCall
    let resolution: ToolResolution
    let conversation: AssistantConversation
    let connect: () -> Void
    @State private var answer = ""

    var body: some View {
        switch try? AssistantTools.parse(call) {
        case .proposeCheck(let proposal)?: proposalCard(proposal)
        case .askUser(let question)?: questionCard(question)
        case .searchBulletins(let query)?: searchRow(query)
        case nil: status.card()
        }
    }

    /// Searches run by themselves, so they're a quiet line rather than a card.
    private func searchRow(_ query: String) -> some View {
        Label {
            if case .completed(let summary) = resolution {
                Text(summary)
            } else {
                Text("Searching bulletins for “\(query)”")
            }
        } icon: {
            Image(systemName: "doc.text.magnifyingglass")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func proposalCard(_ proposal: CheckProposal) -> some View {
        let job = conversation.proposedJob(call)
        let connected = conversation.workbench?.connection.status != nil
        return VStack(alignment: .leading, spacing: 8) {
            Label("Suggested check", systemImage: "stethoscope")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(title(proposal, job: job)).font(.headline)
            Text(proposal.reason).font(.callout)
            if resolution == .pending {
                HStack {
                    if connected {
                        Button("Run Check") { Task { await conversation.approve(call.id) } }
                            .buttonStyle(.borderedProminent)
                            .disabled(job == nil || conversation.isResponding)
                    } else {
                        Button("Connect to Run…", action: connect)
                            .buttonStyle(.borderedProminent)
                    }
                    Button("Not Now") { conversation.decline(call.id) }
                        .disabled(conversation.isResponding)
                }
                .controlSize(.small)
                if let job { Text(job.summary).font(.caption).foregroundStyle(.secondary) }
            } else {
                status
            }
        }
        .card(tint: resolution == .pending ? .accentColor : nil)
    }

    private func questionCard(_ question: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Question for you", systemImage: "questionmark.bubble")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(question).font(.headline)
            if resolution == .pending {
                HStack {
                    TextField("Your answer", text: $answer, axis: .vertical)
                        .lineLimit(1...4)
                        .onSubmit(submitAnswer)
                    Button("Answer", action: submitAnswer)
                        .disabled(
                            answer.trimmingCharacters(in: .whitespaces).isEmpty
                                || conversation.isResponding)
                }
                .controlSize(.small)
            } else {
                status
            }
        }
        .card(tint: resolution == .pending ? .accentColor : nil)
    }

    private func submitAnswer() {
        conversation.answer(call.id, with: answer)
        answer = ""
    }

    private func title(_ proposal: CheckProposal, job: DiagnosticJob?) -> String {
        switch proposal.check {
        case .moduleCodes: return "Read codes from \(proposal.module ?? "a module")"
        case .genericScan, .vehicleInfo, .adapterCheck: return job?.title ?? proposal.check.rawValue
        }
    }

    @ViewBuilder private var status: some View {
        switch resolution {
        case .pending:
            EmptyView()
        case .running:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Running. Follow any prompts in the session.")
            }
            .font(.callout)
        case .completed(let summary):
            Label(summary, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(
                .callout)
        case .failed(let message):
            Label(message, systemImage: "xmark.circle.fill").foregroundStyle(.red).font(.callout)
        case .declined:
            Label("Not run", systemImage: "minus.circle").foregroundStyle(.secondary).font(.callout)
        case .answered(let text):
            Label(text, systemImage: "arrowshape.turn.up.left").font(.callout)
        case .skipped:
            Label("Skipped", systemImage: "arrow.uturn.forward").foregroundStyle(.secondary).font(
                .callout)
        case .invalid(let reason):
            Label(
                "The assistant's suggestion couldn't be used: \(reason)",
                systemImage: "exclamationmark.triangle"
            )
            .foregroundStyle(.orange).font(.callout)
        }
    }
}

/// Inline Markdown (bold, italics, code, links), keeping the reply's line breaks.
private struct MarkdownText: View {
    let text: String

    var body: some View {
        Group {
            if let attributed = try? AttributedString(
                markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
            {
                Text(attributed)
            } else {
                Text(text)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PhotoThumbnail: View {
    @Environment(AppModel.self) private var model
    let part: StoredPart
    let size: CGFloat

    var body: some View {
        Group {
            if case .image(let path, _) = part {
                LocalImage(url: model.garage.files.url(for: path))
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Asked once per session, before anything goes to a cloud provider.
private struct CloudConsentSheet: View {
    let provider: ProviderID
    let shareVIN: Bool
    let allow: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Share this session with \(provider.displayName)?", systemImage: "icloud")
                .font(.title3.weight(.semibold))
            Text("To answer, \(provider.displayName) receives, with each message:")
            VStack(alignment: .leading, spacing: 4) {
                Text("• The problem description, notes, and your messages and photos")
                Text("• Check results, trouble codes, and the vehicle's module list")
                Text("• The vehicle's name and notes")
                Text(shareVIN ? "• The VIN" : "• Not the VIN (you can change this in Settings)")
            }
            .font(.callout)
            Text(
                "It's sent with your API key and handled under your account's terms with \(provider == .anthropic ? "Anthropic" : "OpenAI"). This applies to this session only; the on-device model never needs this."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Share and Send", action: allow)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .platformSheetFrame(width: 440)
    }
}
