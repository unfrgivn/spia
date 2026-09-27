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
                            Button {
                                open(vehicle, nil)
                            } label: {
                                VehicleCard(
                                    vehicle: vehicle, references: model.references(for: vehicle))
                            }
                            .buttonStyle(.plain)
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

/// A vehicle in the garage: its photo, what it is, and what's going on with it.
private struct VehicleCard: View {
    let vehicle: Vehicle
    let references: VehicleReferences

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VehiclePhoto(vehicle: vehicle, references: references)
                .frame(height: 170)
                .clipped()
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(vehicle.name)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if vehicle.isDemo { Chip(text: "Demo") }
                }
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Chip(text: sessionsText, color: openSessions > 0 ? .accentColor : .secondary)
                    if let recalls = references.safety?.recalls.count, recalls > 0 {
                        Chip(text: "\(recalls) recall\(recalls == 1 ? "" : "s")", color: .orange)
                    }
                    if references.isRefreshing {
                        ProgressView().controlSize(.mini)
                    }
                }
                .padding(.top, 4)
            }
            .padding(14)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1))
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .task(id: vehicle.referenceInput) {
            await references.refreshIfNeeded(vehicle.referenceInput)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the vehicle")
    }

    private var openSessions: Int { vehicle.sessions.filter { $0.status == .open }.count }

    private var sessionsText: String {
        let count = vehicle.sessions.count
        guard count > 0 else { return "No sessions" }
        return openSessions > 0
            ? "\(openSessions) open session\(openSessions == 1 ? "" : "s")"
            : "\(count) session\(count == 1 ? "" : "s")"
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
                Text(title).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(20)
            .frame(maxWidth: .infinity, minHeight: 260)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        Color.primary.opacity(0.18), style: StrokeStyle(lineWidth: 1.5, dash: [6]))
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
                Image(systemName: "stethoscope.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.tint)
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
