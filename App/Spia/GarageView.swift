import SpiaKit
import SpiaReference
import SpiaStore
import SwiftData
import SwiftUI

/// The first screen: every vehicle as a card. Opening one scopes the whole window to it.
struct GarageView: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \Vehicle.createdAt) private var vehicles: [Vehicle]
    let open: (Vehicle, DiagnosticSession?) -> Void
    @State private var addingVehicle = false
    @State private var deleting: Vehicle?
    @State private var problem: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if vehicles.isEmpty {
                    Welcome(addVehicle: { addingVehicle = true }, addDemo: addDemo)
                } else {
                    Text("Garage")
                        .font(.largeTitle.weight(.semibold))
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 280, maximum: 420), spacing: 20)],
                        alignment: .leading, spacing: 20
                    ) {
                        ForEach(vehicles) { vehicle in
                            ShowroomCard(
                                vehicle: vehicle, references: model.references(for: vehicle),
                                open: { open(vehicle, $0) }
                            )
                            .contextMenu {
                                Button("Open") { open(vehicle, nil) }
                                Divider()
                                Button("Delete Vehicle and History…", role: .destructive) {
                                    deleting = vehicle
                                }
                            }
                        }
                        AddCard(
                            symbol: "car.badge.plus", title: "Add a vehicle",
                            detail: "Enter the VIN and Spia looks up the rest."
                        ) { addingVehicle = true }
                        if !vehicles.contains(where: \.isDemo) {
                            AddCard(
                                symbol: "play.rectangle", title: "Add the demo car",
                                detail: "A 2017 Maserati Ghibli, replayed from real recordings.",
                                action: addDemo)
                        }
                    }
                }
            }
            .padding(36)
            .frame(maxWidth: 1200, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Palette.base)
        .navigationTitle("Spia")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    addingVehicle = true
                } label: {
                    Label("Add Vehicle", systemImage: "plus")
                }
                .help("Add a vehicle")
            }
        }
        .sheet(isPresented: $addingVehicle) {
            VehicleEditor { vehicle in open(vehicle, vehicle.orderedSessions.first) }
        }
        .confirmationDialog(
            "Delete \(deleting?.name ?? "this vehicle") and all its sessions?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible, presenting: deleting
        ) { vehicle in
            Button("Delete", role: .destructive) { delete(vehicle) }
        } message: { vehicle in
            Text(Self.deletionMessage(sessions: vehicle.sessions.count))
        }
        .errorAlert($problem)
    }

    static func deletionMessage(sessions count: Int) -> String {
        let sessions =
            count == 1
            ? "Its session, with its results, transcripts, photos, and conversation, is"
            : "All \(count) sessions, with their results, transcripts, photos, and conversations, are"
        return "\(sessions) removed from this Mac, along with its references. This can't be undone."
    }

    private func addDemo() {
        do {
            let vehicle = try model.garage.addDemoVehicle()
            open(vehicle, vehicle.orderedSessions.first)
        } catch {
            problem = String(describing: error)
        }
    }

    private func delete(_ vehicle: Vehicle) {
        do { try model.delete(vehicle) } catch { problem = String(describing: error) }
    }
}

/// A vehicle in the garage, shown like a car in a showroom: the photo edge to edge, what it
/// is over a navy fade, and lamps for its open sessions and recalls.
private struct ShowroomCard: View {
    let vehicle: Vehicle
    let references: VehicleReferences
    /// Opens the vehicle, or one of its sessions.
    let open: (DiagnosticSession?) -> Void
    @State private var hovering = false

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 14, style: .continuous) }

    var body: some View {
        // Continue sits beside the card's button, not in it, so each can be pressed.
        ZStack(alignment: .bottomTrailing) {
            Button {
                open(nil)
            } label: {
                showroom
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the vehicle")
            if let session = openSession {
                Button("Continue") { open(session) }
                    .buttonStyle(.borderedProminent)
                    .help("Continue “\(session.title)”")
                    .padding(14)
            }
        }
        .scaleEffect(hovering ? 1.015 : 1)
        .shadow(color: .black.opacity(hovering ? 0.25 : 0), radius: 14, y: 6)
        .animation(.easeOut(duration: 0.15), value: hovering)
        .onHover { hovering = $0 }
        .task(id: vehicle.referenceInput) {
            await references.refreshIfNeeded(vehicle.referenceInput)
        }
    }

    private var showroom: some View {
        VehiclePhoto(vehicle: vehicle, references: references)
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.35),
                        .init(color: Palette.scrim, location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom)
            }
            .overlay(alignment: .topTrailing) {
                if vehicle.isDemo { Chip(text: "Demo").padding(12) }
            }
            .overlay(alignment: .bottomLeading) { caption }
            .clipShape(shape)
            .overlay(shape.strokeBorder(Palette.hairline))
            .contentShape(shape)
    }

    /// Over the photo, always in night colours so it reads on the fade.
    private var caption: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(vehicle.name)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Palette.primary)
                    .lineLimit(2)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(Palette.secondary)
                    .lineLimit(1)
            }
            HStack(spacing: 22) {
                Lamp(
                    tone: openSessions > 0 ? .working : .neutral, symbol: "stethoscope",
                    label: "Sessions", value: sessionsText)
                recalls
            }
            // Clear of the Continue button, which sits level with the lamps.
            .padding(.trailing, openSession == nil ? 0 : 96)
        }
        .padding(16)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private var recalls: some View {
        if let count = references.safety?.recalls.count {
            Lamp(
                tone: count > 0 ? .attention : .good,
                symbol: count > 0 ? "exclamationmark.triangle" : "checkmark", label: "Recalls",
                value: count > 0 ? "\(count)" : "None")
        } else {
            Lamp(
                tone: .neutral, symbol: "exclamationmark.triangle", label: "Recalls",
                value: references.isRefreshing ? "Looking up" : "Unknown")
        }
    }

    private var openSession: DiagnosticSession? {
        vehicle.orderedSessions.first { $0.status == .open }
    }

    private var openSessions: Int { vehicle.sessions.filter { $0.status == .open }.count }

    private var sessionsText: String {
        let count = vehicle.sessions.count
        guard count > 0 else { return "None" }
        return openSessions > 0 ? "\(openSessions) open" : "\(count)"
    }

    private var subtitle: String {
        let detail = vehicle.detail(identity: references.identity)
        if !detail.isEmpty { return detail }
        return vehicle.vin.map { "VIN \($0)" } ?? "No VIN yet"
    }
}

private struct AddCard: View {
    let symbol: String
    let title: String
    let detail: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 30))
                    .foregroundStyle(.tint)
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Palette.primary)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(Palette.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .aspectRatio(16 / 9, contentMode: .fit)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        Palette.tertiary.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [6])
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// Shown until the first vehicle is added.
private struct Welcome: View {
    let addVehicle: () -> Void
    let addDemo: () -> Void

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 12) {
                PlatformIcon(size: 112)
                    .accessibilityHidden(true)
                Text("Spia")
                    .font(.largeTitle.weight(.semibold))
                Text(
                    "Work out what's wrong with your car from two sides: what you notice, and what the car reports."
                )
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
            }
            HStack(spacing: 16) {
                StartOption(
                    symbol: "car.badge.plus", title: "Set up my vehicle",
                    detail:
                        "Enter the VIN: Spia looks up the model, its recalls and service bulletins, and photos.",
                    action: addVehicle)
                StartOption(
                    symbol: "play.rectangle", title: "Explore the demo",
                    detail:
                        "A 2017 Maserati Ghibli with dead wheel controls, from real recordings.",
                    action: addDemo)
            }
            .frame(maxWidth: 620)
            VStack(alignment: .leading, spacing: 10) {
                Label("What you need", systemImage: "cable.connector")
                    .font(.headline)
                Text(
                    "An OBD-II adapter with USB, such as the **Vgate vLinker FS (USB)**. It plugs into the diagnostic port under the dashboard, usually left of the steering column, and into your Mac with its USB cable."
                )
                Text("Bluetooth adapters will come with the iPhone app.")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .card()
            .frame(maxWidth: 620)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 20)
    }
}

private struct StartOption: View {
    let symbol: String
    let title: String
    let detail: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: symbol)
                    .font(.title)
                    .foregroundStyle(.tint)
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
            .card()
        }
        .buttonStyle(.plain)
    }
}
