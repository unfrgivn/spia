import SpiaKit
import SpiaStore
import SwiftUI

struct SessionView: View {
    @Environment(AppModel.self) private var model
    @Bindable var session: DiagnosticSession
    @State private var workbench: Workbench?
    @State private var showAssistant = true
    @State private var showConnection = false
    @State private var editingModules = false
    @State private var transcript: TimelineEntry?
    @State private var note = ""
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                ProblemCard(problem: $session.problem)
                if let workbench {
                    if let activity = workbench.activity, activity.sessionID == session.id {
                        ActivityPanel(activity: activity, workbench: workbench)
                    }
                    ChecksSection(
                        vehicle: session.vehicle, workbench: workbench, session: session,
                        connect: { showConnection = true }, editModules: { editingModules = true })
                }
                TimelineSection(session: session, showTranscript: { transcript = $0 })
                NoteComposer(note: $note, add: addNote)
            }
            .padding(28)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(session.title)
        .navigationSubtitle(session.vehicle?.name ?? "")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if let workbench {
                    ConnectionPill(workbench: workbench) { showConnection = true }
                }
                Menu {
                    Button("Edit Modules…") { editingModules = true }
                        .disabled(session.vehicle == nil)
                } label: {
                    Label("Advanced", systemImage: "slider.horizontal.3")
                }
                Button {
                    showAssistant.toggle()
                } label: {
                    Label("Assistant", systemImage: "sidebar.right")
                }
                .help("Show or hide the assistant")
            }
        }
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

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Session title", text: $session.title)
                .font(.largeTitle.weight(.semibold))
                .textFieldStyle(.plain)
            HStack(spacing: 12) {
                Text("Started \(session.startedAt.formatted(date: .abbreviated, time: .shortened))")
                    .foregroundStyle(.secondary)
                Picker("Status", selection: $session.status) {
                    ForEach(SessionStatus.allCases, id: \.self) { status in
                        Text(status.rawValue.capitalized).tag(status)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .labelsHidden()
            }
            .font(.callout)
        }
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

private struct ProblemCard: View {
    @Binding var problem: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("What's going on?", systemImage: "person.fill.questionmark")
                .font(.headline)
            TextField(
                "Describe the problem in your own words: what happens, when, and what you've noticed.",
                text: $problem, axis: .vertical
            )
            .textFieldStyle(.plain)
            .lineLimit(2...8)
        }
        .card()
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
            .textFieldStyle(.roundedBorder)
            .lineLimit(1...5)
            .onSubmit(add)
            Button("Add Note", action: add)
                .disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}
