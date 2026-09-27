import SpiaAssist
import SpiaKit
import SpiaStore
import SwiftUI

struct SessionView: View {
    @Environment(AppModel.self) private var model
    @Bindable var session: DiagnosticSession
    @State private var workbench: Workbench?
    @State private var showAssistant = false
    @State private var showConnection = false
    @State private var editingModules = false
    @State private var transcript: TimelineEntry?
    @State private var note = ""
    @State private var error: String?
    @State private var width: CGFloat = 1_000
    /// Rows lit for the bulb check.
    @State private var checking: Set<SessionBoard.Subject> = []
    /// A board row's question, for the assistant to ask.
    @State private var question: String?
    #if os(iOS)
        @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    var body: some View {
        let layout = BoardLayout(width: width)
        let wide = layout == .wide
        ScrollViewReader { scroller in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    BoardHeader(session: session, board: board, layout: layout)
                    // A check waiting for the owner, or one with no row, gets the panel; the rest
                    // show on their row.
                    if let workbench, let activity = workbench.activity,
                        activity.sessionID == session.id,
                        activity.prompt != nil || SessionBoard.Subject(job: activity.job) == nil
                    {
                        ActivityPanel(activity: activity, workbench: workbench)
                            .padding(.top, 24)
                    }
                    SessionBoardView(
                        board: board, layout: layout, read: reader, reading: reading,
                        checking: checking, notes: notes, explain: { explain($0) },
                        openAssistant: { showAssistant = true }
                    )
                    .padding(.top, wide ? 32 : 22)
                    CaseFile(session: session, layout: layout) { transcript = $0 }
                        .padding(.top, wide ? 40 : 30)
                        .id(Self.timelineID)
                    NoteComposer(note: $note, add: addNote)
                        .padding(.top, 16)
                }
                .padding(.horizontal, wide ? 56 : 20)
                .padding(.vertical, wide ? 38 : 16)
                .frame(maxWidth: 1_180, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // The scroll view's width, not the content's, which depends on the layout this picks.
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { width = proxy.size.width }
                        .onChange(of: proxy.size.width) { _, newWidth in width = newWidth }
                }
            }
            #if DEBUG
                .task {
                    switch Fixture.screen {
                    case .timeline:
                        // After the fixture's checks have added their results.
                        try? await Task.sleep(for: .seconds(3))
                        scroller.scrollTo(Self.timelineID, anchor: .top)
                    case .explain:
                        // After the checks and the fixture's answered question.
                        try? await Task.sleep(for: .seconds(6))
                        let notes = notes
                        if let row = board.rows.first(where: {
                            $0.question != nil && notes[$0.subject] == nil
                        }) {
                            explain(row)
                        }
                    default:
                        break
                    }
                }
            #endif
        }
        .background(Palette.base)
        .navigationTitle($session.title)
        .platformSubtitle(subtitle)
        .platformInlineTitle()
        .toolbar { sessionToolbar }
        .inspector(isPresented: $showAssistant) {
            AssistantPanel(
                conversation: model.conversation(for: session), connect: { showConnection = true },
                question: $question
            )
            .inspectorColumnWidth(min: 300, ideal: 360, max: 520)
        }
        .sheet(isPresented: $showConnection) {
            if let workbench, let vehicle = session.vehicle {
                ConnectionAssistant(vehicle: vehicle, workbench: workbench) { refreshed in
                    self.workbench = refreshed
                }
            }
        }
        .sheet(isPresented: $editingModules) {
            if let vehicle = session.vehicle { ModulesEditor(vehicle: vehicle) }
        }
        .sheet(item: $transcript) { entry in
            TranscriptView(entry: entry)
        }
        .task(id: session.vehicle?.id) {
            if let vehicle = session.vehicle { workbench = model.workbench(for: vehicle) }
        }
        .onChange(of: workbench.map(ObjectIdentifier.init), initial: true) {
            model.conversation(for: session).workbench = workbench
        }
        .errorAlert($error)
        .modifier(BulbCheck(link: link, subjects: board.rows.map(\.subject), checking: $checking))
    }

    private static let timelineID = "timeline"

    /// The adapter's lamp and Run share the toolbar on a Mac and an iPad. On an iPhone the top
    /// bar goes to the title, so they sit in a bar at the bottom, under the thumb.
    @ToolbarContentBuilder private var sessionToolbar: some ToolbarContent {
        #if os(macOS)
            ToolbarItemGroup(placement: .primaryAction) { adapterAndRun }
            ToolbarItem(placement: .primaryAction) { assistantToggle }
        #else
            if sizeClass == .compact {
                ToolbarItemGroup(placement: .bottomBar) {
                    if let workbench {
                        AdapterIndicator(workbench: workbench) { showConnection = true }
                        Spacer()
                        runMenu(workbench)
                    }
                }
            } else {
                ToolbarItemGroup(placement: .primaryAction) { adapterAndRun }
            }
            ToolbarItem(placement: .secondaryAction) { assistantToggle }
        #endif
    }

    @ViewBuilder private var adapterAndRun: some View {
        if let workbench {
            AdapterIndicator(workbench: workbench) { showConnection = true }
            runMenu(workbench)
        }
    }

    private func runMenu(_ workbench: Workbench) -> some View {
        RunMenu(
            vehicle: session.vehicle, workbench: workbench, run: { run($0) },
            connect: { showConnection = true }, editModules: { editingModules = true })
    }

    private var assistantToggle: some View {
        Button {
            showAssistant.toggle()
        } label: {
            Label("Assistant", systemImage: "sidebar.right")
        }
        .help("Show or hide the assistant")
    }

    /// With the connected adapter's battery reading, which is newer than any saved one.
    private var board: SessionBoard { session.board(live: workbench?.connection.status) }

    private var subtitle: String {
        guard let vehicle = session.vehicle else { return "" }
        return vehicle.isDemo ? "\(vehicle.name) · Demo" : vehicle.name
    }

    /// Reads a board row's missing reading; nil while a check runs.
    private var reader: ((SessionBoard.Subject) -> Void)? {
        guard workbench?.activity == nil else { return nil }
        return { read($0) }
    }

    /// A board row's missing reading. Without an adapter, the connection assistant comes first.
    private func read(_ subject: SessionBoard.Subject) { run(subject.job) }

    /// Opens the assistant on a row's question; it asks at once when it can, or waits in the
    /// composer while it needs setting up or the owner's consent.
    private func explain(_ row: SessionBoard.Row) {
        question = row.question
        showAssistant = true
    }

    /// Answers about the board's rows, found in the conversation, or being written now.
    private var notes: [SessionBoard.Subject: BoardNote] {
        let conversation = model.conversation(for: session)
        var notes: [SessionBoard.Subject: BoardNote] = [:]
        for row in board.rows {
            guard let question = row.question else { continue }
            if conversation.isAnswering(question) {
                notes[row.subject] = BoardNote(
                    text: conversation.streamingText,
                    by: conversation.respondingProvider?.displayName, pending: true)
            } else if let answer = session.answer(to: question) {
                notes[row.subject] = BoardNote(
                    text: answer.text, by: answer.provider?.displayName, pending: false)
            }
        }
        return notes
    }

    /// The row the running check is filling in, unless it's waiting for the owner.
    private var reading: (subject: SessionBoard.Subject, step: String?, cancel: () -> Void)? {
        guard let workbench, let activity = workbench.activity, activity.sessionID == session.id,
            activity.prompt == nil, let subject = SessionBoard.Subject(job: activity.job)
        else { return nil }
        return (subject, activity.currentStep, { Task { await workbench.cancel() } })
    }

    private var link: AdapterLink {
        guard let workbench else { return .unknown }
        return workbench.connection.status == nil ? .disconnected : .connected
    }

    private func run(_ job: DiagnosticJob) {
        guard let workbench else { return }
        guard workbench.connection.status != nil else {
            showConnection = true
            return
        }
        Task { await workbench.run(job, in: session) }
    }

    private func addNote() {
        do {
            try model.garage.addNote(note, to: session)
            note = ""
        } catch {
            self.error = String(describing: error)
        }
    }
}

/// Whether the screen knows of an adapter connection yet. Opening a session while connected
/// goes from unknown to connected, which isn't a new connection.
private enum AdapterLink: Equatable {
    case unknown, disconnected, connected
}

/// The bulb check a car does at key-on: when the adapter connects, every row lights, then flips
/// back to what it says, top to bottom, with a light tick for each where there's haptics. It says
/// the board is live without a word. Skipped with Reduce Motion.
private struct BulbCheck: ViewModifier {
    let link: AdapterLink
    let subjects: [SessionBoard.Subject]
    @Binding var checking: Set<SessionBoard.Subject>
    @State private var run = 0
    @State private var flips = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .onChange(of: link) { old, new in
                if old == .disconnected, new == .connected { run += 1 }
            }
            .task(id: run) {
                guard run > 0, !reduceMotion else { return }
                defer { checking = [] }
                withAnimation(.snappy(duration: 0.3)) { checking = Set(subjects) }
                flips += 1
                try? await Task.sleep(for: .milliseconds(650))
                for subject in subjects {
                    guard !Task.isCancelled else { return }
                    withAnimation(.snappy(duration: 0.3)) { _ = checking.remove(subject) }
                    flips += 1
                    try? await Task.sleep(for: .milliseconds(80))
                }
            }
            .sensoryFeedback(.selection, trigger: flips)
    }
}

private struct NoteComposer: View {
    @Binding var note: String
    let add: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(
                "Add a note: something you tried, heard, or saw", text: $note, axis: .vertical
            )
            .textFieldStyle(.plain)
            .lineLimit(1...5)
            .onSubmit(add)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(
                    Palette.hairline))
            Button("Add Note", action: add)
                .disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}
