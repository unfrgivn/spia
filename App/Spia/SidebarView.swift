import SpiaKit
import SpiaStore
import SwiftData
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \Vehicle.createdAt) private var vehicles: [Vehicle]
    @Binding var selection: UUID?
    let addVehicle: () -> Void
    @State private var problem: String?
    @State private var pendingDeletion: PendingDeletion?

    var body: some View {
        List(selection: $selection) {
            ForEach(vehicles) { vehicle in
                Section {
                    ForEach(vehicle.orderedSessions) { session in
                        SessionRow(session: session)
                            .tag(session.id)
                            .contextMenu {
                                Button("Delete Session…", role: .destructive) {
                                    pendingDeletion = .session(session)
                                }
                            }
                    }
                    Button {
                        newSession(for: vehicle)
                    } label: {
                        Label("New Session", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                } header: {
                    VehicleHeader(vehicle: vehicle)
                        .contextMenu {
                            Button("Delete Vehicle and History…", role: .destructive) {
                                pendingDeletion = .vehicle(vehicle)
                            }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItem {
                Menu {
                    Button("New Vehicle…", action: addVehicle)
                    Button("Add Demo Ghibli") { perform { try model.garage.addDemoVehicle() } }
                } label: {
                    Label("Add Vehicle", systemImage: "car.badge.plus")
                }
            }
        }
        .errorAlert($problem)
        .confirmationDialog(
            pendingDeletion?.title ?? "", isPresented: isConfirmingDeletion,
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { deletion in
            Button("Delete", role: .destructive) {
                switch deletion {
                case .session(let session): delete(session)
                case .vehicle(let vehicle): delete(vehicle)
                }
            }
        } message: { deletion in
            Text(deletion.message)
        }
    }

    private var isConfirmingDeletion: Binding<Bool> {
        Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })
    }

    private func newSession(for vehicle: Vehicle) {
        perform {
            let session = try model.garage.addSession(to: vehicle, title: "New session")
            selection = session.id
        }
    }

    private func delete(_ session: DiagnosticSession) {
        if selection == session.id { selection = nil }
        perform { try model.delete(session) }
    }

    private func delete(_ vehicle: Vehicle) {
        if vehicle.sessions.contains(where: { $0.id == selection }) { selection = nil }
        perform { try model.delete(vehicle) }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { problem = String(describing: error) }
    }
}

private enum PendingDeletion {
    case session(DiagnosticSession)
    case vehicle(Vehicle)

    var title: String {
        switch self {
        case .session(let session): "Delete “\(session.title)”?"
        case .vehicle(let vehicle): "Delete \(vehicle.name) and all its sessions?"
        }
    }

    var message: String {
        switch self {
        case .session:
            return
                "Its notes, check results, transcripts, photos, and assistant conversation are removed from this Mac. This can't be undone."
        case .vehicle(let vehicle):
            let count = vehicle.sessions.count
            let sessions =
                count == 1
                ? "Its session, with its results, transcripts, photos, and conversation, is"
                : "All \(count) sessions, with their results, transcripts, photos, and conversations, are"
            return "\(sessions) removed from this Mac. This can't be undone."
        }
    }
}

private struct VehicleHeader: View {
    let vehicle: Vehicle

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: vehicle.isDemo ? "play.rectangle" : "car")
            Text(vehicle.name)
                .lineLimit(1)
            if vehicle.isDemo {
                Text("DEMO")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }
        }
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
