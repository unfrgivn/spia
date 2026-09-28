import SpiaKit
import SpiaReference
import SpiaStore
import SwiftData
import SwiftUI

/// The first screen: every vehicle in its own bay, like cars in a showroom, each with what its
/// open session says about it. Opening one scopes the whole window to it.
struct GarageView: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \Vehicle.createdAt) private var vehicles: [Vehicle]
    let open: (Vehicle, DiagnosticSession?) -> Void
    @State private var addingVehicle = false
    @State private var deleting: Vehicle?
    @State private var problem: String?
    @State private var width: CGFloat = 1_000

    var body: some View {
        let compact = width < 760
        ScrollView {
            VStack(alignment: .leading, spacing: compact ? 16 : 24) {
                if vehicles.isEmpty {
                    Welcome(addVehicle: { addingVehicle = true }, addDemo: addDemo)
                } else {
                    ForEach(vehicles) { vehicle in
                        ShowroomBay(
                            vehicle: vehicle, references: model.references(for: vehicle),
                            compact: compact, featured: vehicles.count == 1,
                            open: { open(vehicle, $0) },
                            startSession: { startSession(on: vehicle) }
                        )
                        .contextMenu {
                            Button("Open") { open(vehicle, nil) }
                            Divider()
                            Button("Delete Vehicle and History…", role: .destructive) {
                                deleting = vehicle
                            }
                        }
                    }
                    AddRow(
                        symbol: "plus.circle", title: "Add a vehicle",
                        detail: "Enter the VIN and Spia looks up the rest."
                    ) { addingVehicle = true }
                    if !vehicles.contains(where: \.isDemo) {
                        AddRow(
                            symbol: "car.side", title: "Add the demo car",
                            detail: "A 2017 Maserati Ghibli, replayed from real recordings.",
                            action: addDemo)
                    }
                }
            }
            .padding(compact ? 16 : 36)
            .frame(maxWidth: 1_240, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .readingWidth($width)
        .background(Palette.base)
        .navigationTitle("Garage")
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

    private func startSession(on vehicle: Vehicle) {
        do {
            open(vehicle, try model.garage.addSession(to: vehicle, title: "New session"))
        } catch {
            problem = String(describing: error)
        }
    }

    private func delete(_ vehicle: Vehicle) {
        do { try model.delete(vehicle) } catch { problem = String(describing: error) }
    }
}

/// A vehicle in its bay: the photo coming out of the dark, what the car is, and what its open
/// session says, with the lines of its board that matter most. Always drawn dark, like a
/// showroom, so the photo and the lamps carry the colour by day too. Tapping the bay opens the
/// vehicle; Continue opens its session.
private struct ShowroomBay: View {
    let vehicle: Vehicle
    let references: VehicleReferences
    let compact: Bool
    /// The garage's only car, which gets the room to itself.
    let featured: Bool
    /// Opens the vehicle, or one of its sessions.
    let open: (DiagnosticSession?) -> Void
    let startSession: () -> Void
    @State private var hovering = false

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 22, style: .continuous) }
    private var session: DiagnosticSession? {
        vehicle.orderedSessions.first { $0.status == .open }
    }

    var body: some View {
        Group {
            if compact { stacked } else { wide }
        }
        .background(Palette.base)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Palette.hairline))
        .contentShape(shape)
        .onTapGesture { open(nil) }
        .onHover { hovering = $0 }
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Open \(vehicle.name)") { open(nil) }
        .task(id: vehicle.referenceInput) {
            await references.refreshIfNeeded(vehicle.referenceInput)
        }
    }

    /// The photo is a background, so its width never decides the bay's; the bay clips it.
    private var wide: some View {
        details
            .frame(width: 540, alignment: .leading)
            .padding(featured ? 48 : 40)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: featured ? 540 : 440)
            .background(alignment: .trailing) {
                ShowroomPhoto(vehicle: vehicle, references: references, raised: hovering)
                    .frame(width: featured ? 860 : 780)
            }
    }

    private var stacked: some View {
        VStack(alignment: .leading, spacing: 0) {
            ShowroomPhoto(vehicle: vehicle, references: references, fadesIn: false)
                .frame(height: 210)
                .overlay(alignment: .bottom) {
                    LinearGradient(
                        colors: [.clear, Palette.base], startPoint: .top, endPoint: .bottom
                    )
                    .frame(height: 70)
                }
            details
                .padding(.horizontal, 18)
                .padding(.bottom, 20)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(vehicle.name)
                .font(.system(size: compact ? 26 : 40, weight: .bold))
                .tracking(compact ? -0.4 : -0.8)
                .foregroundStyle(Palette.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text(detail)
                .font(.system(size: compact ? 13 : 14))
                .foregroundStyle(Palette.secondary)
                .lineLimit(2)
                .padding(.top, compact ? 4 : 6)
            badges
                .padding(.top, 10)
            if !compact { Spacer(minLength: 24) }
            sessionSummary
                .padding(.top, compact ? 18 : 0)
        }
        .frame(maxHeight: compact ? nil : .infinity, alignment: .topLeading)
    }

    @ViewBuilder private var badges: some View {
        let recalls = references.safety?.recalls.count
        if vehicle.isDemo || recalls != nil {
            HStack(spacing: 10) {
                if vehicle.isDemo { Chip(text: "Demo") }
                if let recalls {
                    Text(
                        recalls == 1
                            ? "1 recall" : recalls == 0 ? "No recalls" : "\(recalls) recalls"
                    )
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(recalls > 0 ? Palette.caution : Palette.tertiary)
                }
            }
        }
    }

    @ViewBuilder private var sessionSummary: some View {
        if let session {
            let board = session.board()
            VStack(alignment: .leading, spacing: 0) {
                let opened = Text("· Opened \(BoardHeader.opened(session.startedAt))")
                    .foregroundStyle(Palette.tertiary)
                Text("\(Text(session.title).foregroundStyle(Palette.primary)) \(opened)")
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(compact ? 2 : 1)
                Text(board.headline)
                    .font(.system(size: compact ? 19 : 24, weight: .semibold))
                    .tracking(-0.3)
                    .foregroundStyle(Palette.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
                MiniBoard(
                    rows: board.rows.filter { $0.status != .notRead }.prefix(3),
                    size: compact ? 17 : 20
                )
                .padding(.top, 12)
                Button {
                    open(session)
                } label: {
                    PrimaryPill(title: "Continue")
                }
                .buttonStyle(.plain)
                .help("Continue “\(session.title)”")
                .padding(.top, 16)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text(vehicle.sessions.isEmpty ? "No sessions yet" : "No open sessions")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.primary)
                Text("Start one when something's wrong: what you notice, and what the car reports.")
                    .font(.system(size: 13.5))
                    .foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: startSession) { PrimaryPill(title: "Start a Session") }
                    .buttonStyle(.plain)
                    .padding(.top, 10)
            }
        }
    }

    private var detail: String {
        let detail = vehicle.detail(identity: references.identity)
        if !detail.isEmpty { return detail }
        return vehicle.vin.map { "VIN \($0)" } ?? "No VIN yet"
    }
}

/// The lines of a board that matter most, small: the status word and the part it's about.
private struct MiniBoard: View {
    let rows: ArraySlice<SessionBoard.Row>
    let size: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(rows) { row in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    StatusWord(row: row, size: size)
                        .frame(width: size * 3.7, alignment: .leading)
                    Text(row.name)
                        .font(.system(size: size * 0.72, weight: .medium))
                        .foregroundStyle(Palette.primary)
                    if let reading = reading(row) {
                        Text(reading)
                            .font(
                                .system(size: size * 0.66, weight: .semibold, design: .monospaced)
                            )
                            .foregroundStyle(row.status.tone.color)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func reading(_ row: SessionBoard.Row) -> String? {
        row.codes.isEmpty ? row.value : row.codes.joined(separator: " ")
    }
}

/// A slim row for adding a vehicle, after the bays.
private struct AddRow: View {
    let symbol: String
    let title: String
    let detail: String
    let action: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 20))
                    .foregroundStyle(Palette.accent)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.primary)
                    Text(detail)
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.tertiary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .background(
                shape.strokeBorder(
                    Palette.tertiary.opacity(0.45), style: StrokeStyle(lineWidth: 1.2, dash: [5]))
            )
            .contentShape(shape)
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
                    symbol: "plus.circle", title: "Set up my vehicle",
                    detail:
                        "Enter the VIN: Spia looks up the model, its recalls and service bulletins, and photos.",
                    action: addVehicle)
                StartOption(
                    symbol: "car.side", title: "Explore the demo",
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
