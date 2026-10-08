import SpiaAssist
import SpiaKit
import SpiaStore
import SwiftUI

struct SessionView: View {
    @Environment(AppModel.self) private var model
    @Bindable var session: DiagnosticSession
    @State private var workbench: Workbench?
    @State private var runner: DiagnosticRunCoordinator?
    @State private var showAssistant = false
    @State private var editingModules = false
    @State private var transcript: TimelineEntry?
    @State private var note = ""
    @State private var error: String?
    @State private var width: CGFloat = 1_000
    /// Rows lit for the bulb check.
    @State private var checking: Set<SessionBoard.Subject> = []
    /// A board row's question, for the assistant to ask.
    @State private var question: String?
    @State private var interpretationDismissed = false
    @State private var renaming = false
    @State private var renameTitle = ""
    #if os(iOS)
        @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    var body: some View {
        sessionScreen
    }

    private var sessionScreen: some View {
        let layout = BoardLayout(width: width)
        let wide = layout == .wide
        return sessionChrome(layout: layout, wide: wide)
            .inspector(isPresented: $showAssistant) {
                AssistantPanel(
                    conversation: model.conversation(for: session),
                    connect: requestConnection,
                    question: $question
                )
                .inspectorColumnWidth(min: 300, ideal: 360, max: 520)
            }
            .sheet(isPresented: connectionPresentation) {
                if let workbench, let vehicle = session.vehicle {
                    ConnectionAssistant(
                        vehicle: vehicle, workbench: workbench,
                        purpose: runner?.isScanPending == true
                            ? "Connect the adapter, and Spia will scan the car." : nil
                    ) { refreshed in
                        self.workbench = refreshed
                        runner?.refresh(refreshed)
                    }
                }
            }
            .sheet(isPresented: $editingModules) {
                if let vehicle = session.vehicle { ModulesEditor(vehicle: vehicle) }
            }
            .sheet(item: $transcript) { entry in
                TranscriptView(entry: entry)
            }
            .surveyReview(runner: runner, vehicle: session.vehicle)
            .readingHistory(
                runner: runner, vehicle: session.vehicle, showTranscript: { transcript = $0 }
            )
            .task(id: session.vehicle?.id) {
                let conversation = model.conversation(for: session)
                if !conversation.visibleMessages.isEmpty || conversation.isResponding {
                    showAssistant = true
                }
                if let vehicle = session.vehicle {
                    workbench = model.workbench(for: vehicle)
                    runner = DiagnosticRunCoordinator(
                        vehicle: vehicle, session: session, model: model)
                    await model.interpreter.refresh(vehicle, adapter: workbench?.liveStatus)
                }
                #if DEBUG
                    if Fixture.screen == .recordings {
                        try? await Task.sleep(for: .milliseconds(500))
                        requestConnection()
                    }
                #endif
            }
            .onChange(of: workbench?.connection) { _, state in
                if case .ready = state { runner?.startPendingScanIfReady() }
            }
            .onChange(of: runner?.connectRequested) { wasRequested, isRequested in
                if wasRequested == true && isRequested == false,
                    workbench?.connection.status == nil
                {
                    runner?.cancelPendingScanIfDisconnected()
                }
            }
            .onChange(of: workbench.map(ObjectIdentifier.init), initial: true) {
                model.conversation(for: session).workbench = workbench
            }
            .errorAlert($error)
            .modifier(
                BulbCheck(link: link, subjects: board.rows.map(\.subject), checking: $checking)
            )
            .focusedSceneValue(\.session, actions)
            .alert("Rename Problem", isPresented: $renaming) {
                TextField("Problem title", text: $renameTitle)
                Button("Cancel", role: .cancel) {}
                Button("Rename") {
                    do { try model.garage.rename(session, to: renameTitle) } catch let renameError {
                        error = renameError.readable
                    }
                }
            }
    }

    private func sessionChrome(layout: BoardLayout, wide: Bool) -> AnyView {
        AnyView(
            baseSessionView(layout: layout, wide: wide)
                .background(Palette.base)
                .navigationTitle($session.title)
                .platformSubtitle(subtitle)
                .platformInlineTitle()
                .toolbar { sessionToolbar })
    }

    private func baseSessionView(layout: BoardLayout, wide: Bool) -> AnyView {
        AnyView(
            ScrollViewReader { scroller in
                sessionScroll(layout: layout, wide: wide, scroller: scroller)
            })
    }

    private func sessionScroll(
        layout: BoardLayout, wide: Bool, scroller: ScrollViewProxy
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                BoardHeader(
                    session: session, board: board, layout: layout,
                    connectionKind: workbench?.adapter.kind)
                if let closedAt = session.closedAt {
                    Text(
                        "As of \(closedAt, format: .dateTime.month().day().year().hour().minute()), when this problem was \(session.status == .archived ? "archived" : "resolved")"
                    )
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.tertiary)
                    .padding(.top, 10)
                }
                if let workbench, let activity = workbench.activity,
                    activity.sessionID == session.id,
                    activity.scan != nil || activity.prompt != nil
                        || SessionBoard.Subject(job: activity.job) == nil
                {
                    ActivityPanel(activity: activity, workbench: workbench).padding(.top, 24)
                }
                if let vehicle = session.vehicle, let interpretations,
                    shouldShowInterpretationConsent
                {
                    InterpretationConsentCard(
                        compact: !wide, board: board, vehicle: vehicle,
                        interpretations: interpretations,
                        allow: {
                            interpretations.allow(model.assistant.settings.defaultProvider)
                            Task {
                                await model.interpreter.refresh(
                                    vehicle, adapter: workbench?.liveStatus)
                            }
                        }, dismiss: { interpretationDismissed = true }
                    )
                    .padding(.top, wide ? 24 : 18)
                }
                if let interpretations,
                    interpretations.review(for: sessionReviewScope) != nil
                        || interpretations.reviewInFlight.contains(sessionReviewScope)
                {
                    ReviewView(
                        review: interpretations.review(for: sessionReviewScope),
                        inFlight: interpretations.reviewInFlight.contains(sessionReviewScope),
                        untaggedQuestions: interpretations.review(for: sessionReviewScope)?
                            .questions
                            .filter {
                                $0.module == nil && $0.codes.isEmpty
                            } ?? [],
                        moduleLabels: moduleLabels,
                        answer: answer,
                        checks: reviewChecks(interpretations.review(for: sessionReviewScope)),
                        run: { runner?.run($0) }
                    )
                    .padding(.top, wide ? 24 : 18)
                }
                SessionBoardView(
                    board: board, layout: layout,
                    read: session.closedAt == nil ? runner?.reader : nil,
                    reading: runner?.reading,
                    checking: checking, unreadable: runner?.unreadable(for: board) ?? [:],
                    notes: notes, interpretations: interpretations,
                    scope: sessionReviewScope,
                    answer: answer,
                    runCheck: { runner?.run($0) },
                    askMore: {
                        question = $0; showAssistant = true
                    },
                    open: { runner?.historySubject = $0.subject },
                    openAssistant: { showAssistant = true }
                )
                .padding(.top, wide ? 32 : 22)
                if let error = interpretations?.lastError, let vehicle = session.vehicle {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(Palette.secondary)
                        Button("Try again") {
                            Task {
                                await model.interpreter.refresh(
                                    vehicle, adapter: workbench?.liveStatus)
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Palette.accent)
                    }
                    .padding(.top, 8)
                }
                CaseFile(
                    session: session, layout: layout, showTranscript: { transcript = $0 },
                    reviewSurvey: {
                        runner?.reviewReport = $0
                    }
                )
                .padding(.top, wide ? 40 : 30)
                .id(Self.timelineID)
                NoteComposer(note: $note, add: addNote).padding(.top, 16)
            }
            .padding(.horizontal, wide ? 56 : 20)
            .padding(.vertical, wide ? 38 : 16)
            .frame(maxWidth: 1_180, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .readingWidth($width)
        #if DEBUG
            .task {
                switch Fixture.screen {
                case .timeline, .replayTimeline:
                    try? await Task.sleep(for: .seconds(3))
                    scroller.scrollTo(Self.timelineID, anchor: .top)
                case .explain:
                    break
                case .history:
                    try? await Task.sleep(for: .seconds(6))
                    runner?.historySubject = .module(DemoGarage.airbag.target)
                case .surveyResults, .surveyResultsMissing, .surveyResultsSearched:
                    try? await Task.sleep(for: .milliseconds(500))
                    if let entry = session.timeline.last,
                        case .survey(let report) = entry.result?.payload
                    {
                        runner?.reviewReport = report
                    }
                default: break
                }
            }
        #endif
    }

    private var sessionReviewScope: ReviewScope {
        if !session.problem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || session.entries.contains(where: { $0.kind == .note })
        {
            return .problem(session.id)
        }
        return .car
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
                        AdapterIndicator(workbench: workbench) { requestConnection() }
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
            AdapterIndicator(workbench: workbench) { requestConnection() }
            runMenu(workbench)
        }
    }

    private func runMenu(_ workbench: Workbench) -> some View {
        ScanMenu(
            vehicle: session.vehicle, workbench: workbench, run: { run($0) },
            scan: { runner?.scan() }, deepScan: { runner?.scan(deep: true) },
            deepScanMessage: runner?.deepScanMessage(),
            connect: requestConnection,
            editModules: { editingModules = true })
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
    private var board: SessionBoard { session.board(live: workbench?.liveStatus) }

    private var interpretations: VehicleInterpretations? {
        session.vehicle.map { model.interpreter.interpretations(for: $0) }
    }

    private var moduleLabels: [ModuleTarget: String] {
        Dictionary(
            uniqueKeysWithValues: (session.vehicle?.orderedModules ?? []).compactMap {
                module in module.target.map { ($0, module.label) }
            })
    }

    private func answer(_ id: UUID, _ text: String) {
        guard let vehicle = session.vehicle else { return }
        Task {
            await model.interpreter.answer(
                vehicle, questionID: id, text: text, adapter: workbench?.liveStatus)
        }
    }

    private func reviewChecks(_ review: StoredReview?) -> [(StoredCheck, Bool)] {
        review?.checks.compactMap { check in
            guard let job = check.job, runner?.workbench?.canRun(job) == true else { return nil }
            let read = board.rows.contains { row in
                switch (check.kind, check.module, row.subject) {
                case (.moduleCodes, let module?, .module(let target)): module == target
                case (.genericScan, _, .engine), (.vehicleInfo, _, .engine),
                    (.adapterCheck, _, .battery):
                    true
                default: false
                }
            }
            return (check, !read)
        } ?? []
    }

    private var shouldShowInterpretationConsent: Bool {
        guard let interpretations else { return false }
        return !interpretationDismissed && !board.rows.allSatisfy { $0.codes.isEmpty }
            && model.assistant.settings.defaultProvider.isCloud && interpretations.consent == nil
    }

    private var subtitle: String {
        guard let vehicle = session.vehicle else { return "" }
        if vehicle.isDemo { return "\(vehicle.name) · Demo" }
        if workbench?.adapter.kind == .replay { return "\(vehicle.name) · Recordings" }
        return vehicle.name
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

    private var link: AdapterLink {
        guard let workbench else { return .unknown }
        return workbench.connection.status == nil ? .disconnected : .connected
    }

    /// The menu bar's session commands, from the state the toolbar shows. Checks run when no
    /// other is running, as the board's Read does, and ask to connect first when there's no
    /// connection.
    private var actions: SessionActions {
        let idle = workbench.map { $0.activity == nil } ?? false
        func check(_ job: DiagnosticJob, _ title: String) -> SessionActions.Check {
            let runs = idle && workbench?.canRun(job) == true
            return .init(job: job, title: title, perform: runs ? { run(job) } : nil)
        }
        return SessionActions(
            connected: workbench?.connection.status != nil,
            assistantShown: showAssistant,
            toggleAssistant: { showAssistant.toggle() }, connect: requestConnection,
            checks: ScanMenu.jobs.map { check($0, $0.menuTitle) },
            scan: runner?.scanAction(), deepScan: runner?.scanAction(deep: true),
            editModules: { editingModules = true },
            rename: {
                renameTitle = session.title
                renaming = true
            },
            moduleChecks: (session.vehicle?.orderedModules ?? []).compactMap { module in
                module.target.map { check(.moduleDTCs($0), module.label) }
            })
    }

    private func run(_ job: DiagnosticJob) {
        runner?.run(job)
    }

    private var connectionPresentation: Binding<Bool> {
        Binding(
            get: { runner?.connectRequested == true },
            set: { isPresented in
                if !isPresented {
                    runner?.connectRequested = false
                    runner?.cancelPendingScanIfDisconnected()
                }
            })
    }

    private func requestConnection() { runner?.connectRequested = true }

    private func addNote() {
        do {
            try model.garage.addNote(note, to: session)
            note = ""
        } catch {
            self.error = error.readable
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
