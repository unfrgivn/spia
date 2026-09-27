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
                    if let workbench, let activity = workbench.activity,
                        activity.sessionID == session.id
                    {
                        ActivityPanel(activity: activity, workbench: workbench)
                            .padding(.top, 24)
                    }
                    SessionBoardView(board: board, layout: layout, read: reader)
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
                .background {
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { width = proxy.size.width }
                            .onChange(of: proxy.size.width) { _, newWidth in width = newWidth }
                    }
                }
            }
            #if DEBUG
                .task {
                    guard Fixture.screen == .timeline else { return }
                    // After the fixture's checks have added their results.
                    try? await Task.sleep(for: .seconds(3))
                    scroller.scrollTo(Self.timelineID, anchor: .top)
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
                conversation: model.conversation(for: session), connect: { showConnection = true }
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

    /// What the session's results say, with the connected adapter's battery reading, which is
    /// newer than any saved one.
    private var board: SessionBoard {
        let modules = (session.vehicle?.orderedModules ?? []).compactMap { preset in
            preset.target.map { SessionBoard.Module(label: preset.label, target: $0) }
        }
        let results = session.timeline.compactMap { entry in
            entry.result.map { SessionBoard.Result(date: entry.date, payload: $0.payload) }
        }
        return SessionBoard(modules: modules, results: results, live: workbench?.connection.status)
    }

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
    private func read(_ subject: SessionBoard.Subject) {
        switch subject {
        case .engine: run(.genericScan)
        case .module(let target): run(.moduleDTCs(target))
        case .battery: run(.adapterCheck)
        }
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
