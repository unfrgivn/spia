import SpiaKit
import SpiaReference
import SpiaStore
import SwiftData
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
    /// Opens another vehicle in this window.
    let switchTo: (Vehicle) -> Void
    @State var selection: WorkspaceSection?

    var body: some View {
        let references = model.references(for: vehicle)
        NavigationSplitView {
            WorkspaceSidebar(
                vehicle: vehicle, references: references, selection: $selection,
                switchTo: switchTo, showGarage: leave
            )
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
    let switchTo: (Vehicle) -> Void
    let showGarage: () -> Void
    @State private var deleting: DiagnosticSession?
    @State private var problem: String?

    var body: some View {
        List(selection: $selection) {
            CarSwitcher(
                vehicle: vehicle, references: references, switchTo: switchTo,
                showGarage: showGarage
            )
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
        .scrollContentBackground(.hidden)
        .background(Palette.panel)
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

/// The open vehicle at the top of the sidebar, and the way to another: a menu of the garage's
/// vehicles, and the garage itself.
private struct CarSwitcher: View {
    @Query(sort: \Vehicle.createdAt) private var vehicles: [Vehicle]
    let vehicle: Vehicle
    let references: VehicleReferences
    let switchTo: (Vehicle) -> Void
    let showGarage: () -> Void

    var body: some View {
        Menu {
            ForEach(vehicles) { other in
                Button {
                    if other.id != vehicle.id { switchTo(other) }
                } label: {
                    if other.id == vehicle.id {
                        Label(other.name, systemImage: "checkmark")
                    } else {
                        Text(other.name)
                    }
                }
            }
            Divider()
            Button("Show Garage", action: showGarage)
        } label: {
            HStack(spacing: 10) {
                VehiclePhoto(vehicle: vehicle, references: references)
                    .frame(width: 42, height: 42)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(vehicle.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.primary)
                        .lineLimit(2)
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.tertiary)
            }
            .padding(8)
            .background(
                Palette.hairline, in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help("Switch vehicle")
        .accessibilityLabel("Vehicle: \(vehicle.name)")
    }

    private var detail: String {
        let detail = vehicle.detail(identity: references.identity)
        let parts = (vehicle.isDemo ? ["Demo"] : []) + (detail.isEmpty ? [] : [detail])
        return parts.isEmpty ? (vehicle.vin ?? "No VIN yet") : parts.joined(separator: " · ")
    }
}

private struct SessionRow: View {
    let session: DiagnosticSession

    var body: some View {
        let lamp = session.lamp
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(lamp?.color ?? .clear)
                .frame(width: 7, height: 7)
                .shadow(color: lamp?.color ?? .clear, radius: 3)
                .padding(.top, 5)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(session.title)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if session.status == .resolved {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Palette.pass)
                            .accessibilityLabel("Resolved")
                    }
                }
                Text(session.updatedAt, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
