import SpiaKit
import SpiaReference
import SpiaStore
import SwiftUI

enum WorkspaceSection: Hashable {
    case overview
    case references
    case photos
    case session(UUID)
}

/// One vehicle, and everything in the window is about it: its overview, references, and sessions.
struct VehicleWorkspace: View {
    @Environment(AppModel.self) private var model
    let vehicle: Vehicle
    let leave: () -> Void
    @State var selection: WorkspaceSection?

    var body: some View {
        let references = model.references(for: vehicle)
        NavigationSplitView {
            WorkspaceSidebar(vehicle: vehicle, references: references, selection: $selection)
                .navigationSplitViewColumnWidth(min: 230, ideal: 270)
                .toolbar {
                    ToolbarItem {
                        Button(action: leave) {
                            Label("Garage", systemImage: "square.grid.2x2")
                        }
                        .help("Back to all vehicles (⇧⌘G)")
                        .keyboardShortcut("g", modifiers: [.command, .shift])
                    }
                }
        } detail: {
            switch selection ?? .overview {
            case .overview:
                VehicleOverview(vehicle: vehicle, references: references, show: show)
            case .references:
                ReferencesView(vehicle: vehicle, references: references)
            case .photos:
                PhotosView(vehicle: vehicle, references: references)
            case .session(let id):
                if let session = vehicle.sessions.first(where: { $0.id == id }) {
                    SessionView(session: session)
                        .id(session.id)
                } else {
                    VehicleOverview(vehicle: vehicle, references: references, show: show)
                }
            }
        }
        .task(id: vehicle.referenceInput) {
            await references.refreshIfNeeded(vehicle.referenceInput)
        }
    }

    private func show(_ section: WorkspaceSection) { selection = section }
}

private struct WorkspaceSidebar: View {
    @Environment(AppModel.self) private var model
    let vehicle: Vehicle
    let references: VehicleReferences
    @Binding var selection: WorkspaceSection?
    @State private var deleting: DiagnosticSession?
    @State private var problem: String?

    var body: some View {
        List(selection: $selection) {
            VehicleBadge(vehicle: vehicle, references: references)
                .selectionDisabled()
                .listRowSeparator(.hidden)
                .padding(.bottom, 6)

            Section("Vehicle") {
                Label("Overview", systemImage: "car")
                    .tag(WorkspaceSection.overview)
                Label("References", systemImage: "books.vertical")
                    .badge(references.safety?.recalls.count ?? 0)
                    .tag(WorkspaceSection.references)
                Label("Photos", systemImage: "photo.on.rectangle")
                    .tag(WorkspaceSection.photos)
            }

            Section("Sessions") {
                ForEach(vehicle.orderedSessions) { session in
                    SessionRow(session: session)
                        .tag(WorkspaceSection.session(session.id))
                        .contextMenu {
                            Button("Delete Session…", role: .destructive) { deleting = session }
                        }
                }
                Button(action: newSession) {
                    Label("New Session", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
        }
        .listStyle(.sidebar)
        .confirmationDialog(
            "Delete “\(deleting?.title ?? "")”?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible, presenting: deleting
        ) { session in
            Button("Delete", role: .destructive) { delete(session) }
        } message: { _ in
            Text(
                "Its notes, check results, transcripts, photos, and assistant conversation are removed from this Mac. This can't be undone."
            )
        }
        .errorAlert($problem)
    }

    private func newSession() {
        do {
            let session = try model.garage.addSession(to: vehicle, title: "New session")
            selection = .session(session.id)
        } catch {
            problem = String(describing: error)
        }
    }

    private func delete(_ session: DiagnosticSession) {
        if selection == .session(session.id) { selection = .overview }
        do { try model.delete(session) } catch { problem = String(describing: error) }
    }
}

/// The current vehicle at the top of the sidebar.
private struct VehicleBadge: View {
    let vehicle: Vehicle
    let references: VehicleReferences

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VehiclePhoto(vehicle: vehicle, references: references)
                .frame(height: 110)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(vehicle.name)
                    .font(.headline)
                    .lineLimit(2)
                if vehicle.isDemo { Chip(text: "Demo") }
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        let detail = vehicle.detail(identity: references.identity)
        return detail.isEmpty ? (vehicle.vin ?? "No VIN yet") : detail
    }
}

private struct SessionRow: View {
    let session: DiagnosticSession

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(session.title)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if session.status == .resolved {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityLabel("Resolved")
                }
            }
            Text(session.updatedAt, format: .relative(presentation: .named))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
