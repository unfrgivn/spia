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
    @State private var reviewReport: SurveyReport?
    @State private var reviewVehicle: Vehicle?
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
        sessionScreen
    }

    private var sessionScreen: some View {
        let layout = BoardLayout(width: width)
        let wide = layout == .wide
        return sessionChrome(layout: layout, wide: wide)
            .inspector(isPresented: $showAssistant) {
                AssistantPanel(
                    conversation: model.conversation(for: session),
                    connect: { showConnection = true },
                    question: $question
                )
                .inspectorColumnWidth(min: 300, ideal: 360, max: 520)
            }
            .sheet(isPresented: $showConnection) {
                if let workbench, let vehicle = session.vehicle {
                    ConnectionAssistant(
                        vehicle: vehicle, workbench: workbench,
                        purpose: model.hasSurveyRequest(for: session)
                            ? "Connect the adapter, and Spia will find this car's modules." : nil
                    ) { refreshed in
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
            .sheet(
                isPresented: Binding(
                    get: { reviewReport != nil }, set: { if !$0 { reviewReport = nil } })
            ) {
                if let report = reviewReport, let vehicle = reviewVehicle {
                    SurveyResultsView(
                        report: report, vehicle: vehicle,
                        searchMessage: thoroughSearchMessage(for: report),
                        tryAgain: {
                            reviewReport = nil
                            requestSurveyInSession()
                        },
                        searchMoreThoroughly: {
                            reviewReport = nil
                            requestSurveyInSession(search: true)
                        })
                }
            }
            .task(id: session.vehicle?.id) {
                if let vehicle = session.vehicle { workbench = model.workbench(for: vehicle) }
                startPendingSurveyIfReady()
                if let workbench, workbench.connection.status == nil,
                    model.hasSurveyRequest(for: session)
                {
                    showConnection = true
                }
                #if DEBUG
                    if Fixture.screen == .recordings {
                        try? await Task.sleep(for: .milliseconds(500))
                        showConnection = true
                    }
                #endif
            }
            .onChange(of: workbench?.connection) { _, state in
                if case .ready = state { startPendingSurveyIfReady() }
            }
            .onChange(of: showConnection) { wasShown, isShown in
                if wasShown && !isShown && workbench?.connection.status == nil {
                    model.cancelSurveyRequest(for: session)
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
                if showModuleDiscoveryCard { moduleDiscoveryCard(compact: !wide).padding(.top, 18) }
                if let workbench, let activity = workbench.activity,
                    activity.sessionID == session.id,
                    activity.prompt != nil || SessionBoard.Subject(job: activity.job) == nil
                {
                    ActivityPanel(activity: activity, workbench: workbench).padding(.top, 24)
                }
                SessionBoardView(
                    board: board, layout: layout, read: reader, reading: reading,
                    checking: checking, unreadable: unreadable(board), notes: notes,
                    explain: { explain($0) }, openAssistant: { showAssistant = true }
                )
                .padding(.top, wide ? 32 : 22)
                CaseFile(
                    session: session, layout: layout, showTranscript: { transcript = $0 },
                    reviewSurvey: {
                        reviewReport = $0
                        reviewVehicle = session.vehicle
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
                    try? await Task.sleep(for: .seconds(6))
                    let notes = notes
                    if let row = board.rows.first(where: {
                        $0.question != nil && notes[$0.subject] == nil
                    }) {
                        explain(row)
                    }
                case .surveyResults, .surveyResultsMissing, .surveyResultsSearched:
                    try? await Task.sleep(for: .milliseconds(500))
                    if let entry = session.timeline.last,
                        case .survey(let report) = entry.result?.payload,
                        let vehicle = session.vehicle
                    {
                        reviewReport = report
                        reviewVehicle = vehicle
                    }
                default: break
                }
            }
        #endif
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
            survey: surveyAction(workbench), connect: { showConnection = true },
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

    private var subtitle: String {
        guard let vehicle = session.vehicle else { return "" }
        if vehicle.isDemo { return "\(vehicle.name) · Demo" }
        if workbench?.adapter.kind == .replay { return "\(vehicle.name) · Recordings" }
        return vehicle.name
    }

    private var showModuleDiscoveryCard: Bool {
        guard let vehicle = session.vehicle else { return false }
        return !vehicle.isDemo && vehicle.modules.isEmpty
    }

    @ViewBuilder private func moduleDiscoveryCard(compact: Bool) -> some View {
        FindModulesCard(
            compact: compact, disabled: workbench?.activity != nil,
            action: { requestSurveyInSession() })
    }

    /// Reads a board row's missing reading; nil while a check runs.
    private var reader: ((SessionBoard.Subject) -> Void)? {
        guard workbench?.activity == nil else { return nil }
        return { read($0) }
    }

    /// Unread rows this adapter can't read, and why. Only the demo car says no, for the modules
    /// nobody recorded.
    private func unreadable(_ board: SessionBoard) -> [SessionBoard.Subject: String] {
        guard let workbench else { return [:] }
        var reasons: [SessionBoard.Subject: String] = [:]
        for row in board.rows where row.status == .notRead && !workbench.canRun(row.subject.job) {
            reasons[row.subject] =
                switch workbench.adapter.kind {
                case .demo: "Not in the demo"
                case .replay: "Not recorded yet"
                default: "Can't be read here"
                }
        }
        return reasons
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
            toggleAssistant: { showAssistant.toggle() }, connect: { showConnection = true },
            checks: RunMenu.jobs.map { check($0, $0.menuTitle) },
            survey: surveyAction(workbench),
            moduleChecks: (session.vehicle?.orderedModules ?? []).compactMap { module in
                module.target.map { check(.moduleDTCs($0), module.label) }
            })
    }

    private func surveyAction(_ workbench: Workbench?) -> (() -> Void)? {
        guard let workbench, let vehicle = session.vehicle else { return nil }
        // The plan a click would run decides, so saved recordings offer only a survey they hold.
        // When no plan can be made, the item stays on and the click says why.
        if let plan = try? model.surveyPlan(for: vehicle, workbench: workbench),
            !workbench.canRun(.survey(plan))
        {
            return nil
        }
        return { runSurvey(workbench) }
    }

    private func runSurvey(_ workbench: Workbench, search: Bool = false) {
        guard let vehicle = session.vehicle else { return }
        do {
            let plan = try model.surveyPlan(for: vehicle, workbench: workbench, search: search)
            run(.survey(plan))
        } catch {
            workbench.lastError = error.readable
        }
    }

    private func requestSurveyInSession(search: Bool = false) {
        guard let workbench, session.vehicle != nil else { return }
        model.requestSurvey(for: session, search: search)
        if workbench.connection.status == nil {
            showConnection = true
        } else {
            startPendingSurveyIfReady()
        }
    }

    private func startPendingSurveyIfReady() {
        guard let workbench, workbench.connection.status != nil,
            model.consumeSurveyRequest(for: session)
        else { return }
        showConnection = false
        runSurvey(workbench, search: model.consumeThoroughSurveyRequest(for: session))
    }

    private func thoroughSearchMessage(for report: SurveyReport) -> String? {
        guard report.plan.search == nil, let vehicle = session.vehicle, !vehicle.isDemo,
            let workbench, workbench.connection.status != nil,
            report.detectedProtocol == nil || report.detectedProtocol == .can11bit500k
        else { return nil }
        let search = ModuleSearch.standard(over: workbench.adapter.kind)
        return search.confirmationMessage(
            connection: workbench.adapter.kind, candidates: report.plan.candidates)
    }

    private func run(_ job: DiagnosticJob) {
        guard let workbench else { return }
        guard workbench.connection.status != nil else {
            showConnection = true
            return
        }
        Task {
            let outcome = await workbench.run(job, in: session)
            if case .completed(let result) = outcome,
                case .survey(let report) = result.payload
            {
                reviewReport = report
                reviewVehicle = session.vehicle
            }
        }
    }

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
