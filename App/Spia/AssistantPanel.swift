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
    /// A question from the board, asked as soon as it arrives.
    @Binding var question: String?

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
            Hairline()
            messages
            Hairline()
            composer
        }
        // Asked like anything typed: at once when it can be, else it waits in the composer for
        // the owner's consent, a key, or a check to finish.
        .onChange(of: question, initial: true) { _, asked in
            guard let asked else { return }
            question = nil
            draft = asked
            send()
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
            Label {
                Text("Assistant").foregroundStyle(Palette.primary)
            } icon: {
                Image(systemName: "sparkles").foregroundStyle(Palette.accent)
            }
            .font(.system(size: 15, weight: .semibold))
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
                    .foregroundStyle(Palette.accent)
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
                LazyVStack(alignment: .leading, spacing: 18) {
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
                        Label {
                            Text(error).foregroundStyle(Palette.primary)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(Palette.caution)
                        }
                        .font(.system(size: 13.5))
                        .textSelection(.enabled)
                        .card()
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
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.tertiary)
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                Button {
                    importingPhotos = true
                } label: {
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 15))
                        .foregroundStyle(Palette.accent)
                }
                .buttonStyle(.plain)
                .help("Attach photos (or drop them here)")

                TextField("Describe what you see, or ask…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.primary)
                    .lineLimit(1...6)
                    .onSubmit(send)

                if conversation.isResponding {
                    Button("Stop", systemImage: "stop.circle.fill") { conversation.stop() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .font(.title2)
                        .foregroundStyle(Palette.accent)
                        .help("Stop the reply")
                } else {
                    Button("Send", systemImage: "arrow.up.circle.fill", action: send)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .font(.title2)
                        .foregroundStyle(canSend ? Palette.accent : Palette.tertiary)
                        .disabled(!canSend)
                        .keyboardShortcut(.return, modifiers: .command)
                        .help(sendHelp)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(
                    Palette.hairline))

            Group {
                if let reason = model.assistant.unavailableReason(chosenProvider) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(reason)
                        if chosenProvider.isCloud {
                            Button("Open Settings", action: showSettings)
                                .buttonStyle(.plain)
                                .fontWeight(.semibold)
                                .foregroundStyle(Palette.accent)
                        }
                    }
                } else if chosenProvider.isCloud {
                    Label("Sent to \(chosenProvider.displayName)", systemImage: "icloud")
                } else {
                    Label(PlatformText.staysOnDevice, systemImage: "lock.laptopcomputer")
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(Palette.tertiary)
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
                problem = "\(url.lastPathComponent): \(error.readable)"
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
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Palette.primary)
            Text(
                "The assistant reads this session's problem, notes, and results. It asks what you're seeing and suggests read-only checks, which run only when you approve them."
            )
            .font(.system(size: 14))
            .foregroundStyle(Palette.secondary)
            .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(starters, id: \.self) { starter in
                    Hairline()
                    Button {
                        ask(starter)
                    } label: {
                        HStack {
                            Text(starter)
                            Spacer(minLength: 8)
                            Image(systemName: "arrow.up.left")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Palette.accent)
                    .help("Put this in the message box")
                }
                Hairline()
            }
            .padding(.top, 6)
        }
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
                Button("Stop", action: stop)
                    .buttonStyle(.plain)
                    .fontWeight(.semibold)
                    .foregroundStyle(Palette.accent)
            }
            .font(.system(size: 12))
            .foregroundStyle(Palette.tertiary)
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
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.primary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        Palette.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Palette.hairline))
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
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.tertiary)
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
        .font(.system(size: 12.5))
        .foregroundStyle(Palette.tertiary)
    }

    private func proposalCard(_ proposal: CheckProposal) -> some View {
        let job = conversation.proposedJob(call)
        let connected = conversation.workbench?.connection.status != nil
        return VStack(alignment: .leading, spacing: 8) {
            Label("Suggested check", systemImage: "stethoscope")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.tertiary)
            Text(title(proposal, job: job))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.primary)
            Text(proposal.reason)
                .font(.system(size: 14))
                .foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if resolution == .pending {
                HStack(spacing: 10) {
                    if connected {
                        Button {
                            Task { await conversation.approve(call.id) }
                        } label: {
                            PrimaryPill(title: "Run Check")
                        }
                        .disabled(job == nil || conversation.isResponding)
                    } else {
                        Button(action: connect) { PrimaryPill(title: "Connect to Run…") }
                    }
                    Button("Not Now") { conversation.decline(call.id) }
                        .buttonStyle(OutlineButtonStyle())
                        .disabled(conversation.isResponding)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
                if let job {
                    Text(job.summary)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.tertiary)
                }
            } else {
                status
            }
        }
        .card(tint: resolution == .pending ? Palette.accent : nil)
    }

    private func questionCard(_ question: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Question for you", systemImage: "questionmark.bubble")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.tertiary)
            Text(question)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.primary)
                .fixedSize(horizontal: false, vertical: true)
            if resolution == .pending {
                HStack {
                    TextField("Your answer", text: $answer, axis: .vertical)
                        .lineLimit(1...4)
                        .onSubmit(submitAnswer)
                    Button("Answer", action: submitAnswer)
                        .buttonStyle(OutlineButtonStyle())
                        .disabled(
                            answer.trimmingCharacters(in: .whitespaces).isEmpty
                                || conversation.isResponding)
                }
            } else {
                status
            }
        }
        .card(tint: resolution == .pending ? Palette.accent : nil)
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

    /// How the proposal or question ended. These describe Spia's work, not the car, so they stay
    /// out of the car's colours: a check that completed may well have found faults.
    @ViewBuilder private var status: some View {
        Group {
            switch resolution {
            case .pending:
                EmptyView()
            case .running:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Running. Follow any prompts in the session.")
                }
            case .completed(let summary):
                outcome(summary, symbol: "checkmark", tint: Palette.tertiary)
            case .failed(let message):
                outcome(message, symbol: "exclamationmark.triangle", tint: Palette.caution)
            case .declined:
                outcome("Not run", symbol: "minus", tint: Palette.tertiary)
            case .answered(let text):
                outcome(text, symbol: "arrowshape.turn.up.left", tint: Palette.tertiary)
            case .skipped:
                outcome("Skipped", symbol: "arrow.uturn.forward", tint: Palette.tertiary)
            case .invalid(let reason):
                outcome(
                    "The assistant's suggestion couldn't be used: \(reason)",
                    symbol: "exclamationmark.triangle", tint: Palette.caution)
            }
        }
        .font(.system(size: 13.5))
        .foregroundStyle(Palette.secondary)
    }

    private func outcome(_ text: String, symbol: String, tint: Color) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
    }
}

/// A reply's Markdown, block by block: paragraphs, headings, numbered and bulleted lists, quotes,
/// and code, each with its inline bold, italics, code, and links.
private struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(ReplyBlock.parse(text).enumerated()), id: \.offset) { _, block in
                view(block)
            }
        }
        .font(.system(size: 14.5))
        .lineSpacing(2)
        .foregroundStyle(Palette.primary)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func view(_ block: ReplyBlock) -> some View {
        switch block {
        case .paragraph(let text):
            Text(text).fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let text):
            Text(text)
                .font(.system(size: level <= 2 ? 15.5 : 14.5, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        case .item(let marker, let depth, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker)
                    .monospacedDigit()
                    .foregroundStyle(Palette.tertiary)
                    .frame(minWidth: 16, alignment: .trailing)
                Text(text).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(max(depth - 1, 0)) * 18)
        case .code(let code):
            Text(code)
                .font(.system(size: 12.5, design: .monospaced))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        case .quote(let text):
            HStack(spacing: 10) {
                Rectangle().fill(Palette.tertiary).frame(width: 2)
                Text(text)
                    .foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .rule:
            Hairline()
        }
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
                Image(systemName: "photo").foregroundStyle(Palette.tertiary)
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
