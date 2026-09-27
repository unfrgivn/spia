import SpiaKit
import SpiaReference
import SpiaStore
import SwiftUI

/// The vehicle's home: what it is, what's known about it, and where to go next.
struct VehicleOverview: View {
    @Environment(AppModel.self) private var model
    let vehicle: Vehicle
    let references: VehicleReferences
    let show: (WorkspaceSection) -> Void

    @State private var workbench: Workbench?
    @State private var editing = false
    @State private var editingModules = false
    @State private var connecting = false
    @State private var uploadingCover = false
    @State private var problem: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                hero
                referenceStatus
                if let recalls = references.safety?.recalls, !recalls.isEmpty {
                    recallCallout(recalls)
                }
                stats
                HStack(alignment: .top, spacing: 20) {
                    details
                    VStack(spacing: 20) {
                        connection
                        modules
                    }
                }
                recentSessions
            }
            .padding(28)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(vehicle.name)
        .navigationSubtitle("Overview")
        .task(id: vehicle.id) { workbench = model.workbench(for: vehicle) }
        .sheet(isPresented: $editing) { VehicleSettings(vehicle: vehicle, references: references) }
        .sheet(isPresented: $editingModules) { ModulesEditor(vehicle: vehicle) }
        .sheet(isPresented: $connecting) {
            if let workbench {
                ConnectionAssistant(vehicle: vehicle, workbench: workbench) { self.workbench = $0 }
            }
        }
        .errorAlert($problem)
    }

    // MARK: - Sections

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            VehiclePhoto(vehicle: vehicle, references: references)
            LinearGradient(
                colors: [.clear, .black.opacity(0.65)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(vehicle.name)
                        .font(.largeTitle.weight(.bold))
                    if vehicle.isDemo { Chip(text: "Demo", color: .white) }
                }
                if !heroDetail.isEmpty {
                    Text(heroDetail).font(.title3)
                }
            }
            .foregroundStyle(.white)
            .padding(20)
        }
        .frame(height: 280)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(alignment: .topTrailing) {
            HStack {
                Button("Change Cover…") { uploadingCover = true }
                    .help("Use a photo of your car instead of the reference photo")
                Button("Edit Vehicle…") { editing = true }
            }
            .buttonStyle(.bordered)
            .padding(14)
        }
        .overlay(alignment: .bottomTrailing) {
            if let photo = references.cover(for: vehicle)?.reference {
                PhotoCredit(photo: photo)
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(10)
            }
        }
        .fileImporter(isPresented: $uploadingCover, allowedContentTypes: [.image]) { result in
            switch result {
            case .success(let url):
                let problems = model.garage.addImages(from: [url], to: vehicle, asCover: true)
                if !problems.isEmpty { problem = problems.joined(separator: "\n") }
            case .failure(let error):
                problem = error.localizedDescription
            }
        }
    }

    private var heroDetail: String { vehicle.detail(identity: references.identity) }

    private var referenceStatus: some View {
        HStack(spacing: 8) {
            if references.isRefreshing {
                ProgressView().controlSize(.small)
                Text("Looking up references…")
            } else if vehicle.vin == nil {
                Image(systemName: "info.circle")
                Text(
                    "Add the VIN, or run “Read vehicle information” in a session, to look up this car's recalls and service bulletins."
                )
            } else if let snapshot = references.snapshot {
                if snapshot.problems.isEmpty {
                    Image(systemName: "checkmark.circle")
                    Text(
                        "References from NHTSA and Wikimedia Commons, updated \(snapshot.fetchedAt, format: .relative(presentation: .named))."
                    )
                } else {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(snapshot.problems.joined(separator: " · "))
                        .lineLimit(2)
                }
            }
            Spacer()
            Button("Refresh") {
                Task { await references.refresh(vehicle.referenceInput) }
            }
            .disabled(references.isRefreshing)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private func recallCallout(_ recalls: [Recall]) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text(
                    "\(recalls.count) safety recall\(recalls.count == 1 ? "" : "s") filed for the \(references.identity?.title ?? "model")"
                )
                .font(.headline)
                Text(
                    "Recalls are filed by model and year. A dealer may already have done these on this car; nhtsa.gov shows which are still open for its VIN."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                HStack {
                    Button("See Recalls") { show(.references) }
                    if let vin = vehicle.vin, let url = NHTSA.recallLookupURL(vin: vin) {
                        Link("Check This VIN on nhtsa.gov", destination: url)
                    }
                }
                .controlSize(.small)
            }
        }
        .card(tint: .orange)
    }

    private var stats: some View {
        let safety = references.safety
        return HStack(spacing: 14) {
            StatTile(
                value: vehicle.sessions.filter { $0.status == .open }.count, label: "Open sessions",
                symbol: "stethoscope"
            ) {
                if let first = vehicle.orderedSessions.first { show(.session(first.id)) }
            }
            StatTile(
                value: safety?.bulletins.count, label: "Service bulletins",
                symbol: "doc.text.magnifyingglass"
            ) { show(.references) }
            StatTile(
                value: safety?.complaints.count, label: "Owner complaints",
                symbol: "person.2.wave.2"
            ) { show(.references) }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Details").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                DetailRow("VIN", vehicle.vin, monospaced: true)
                if let identity = references.identity {
                    DetailRow("Model", identity.title)
                    DetailRow("Trim", vehicle.trim ?? identity.trim)
                    DetailRow("Platform", identity.series)
                    DetailRow("Body", identity.bodyClass)
                    DetailRow("Engine", identity.engine)
                    DetailRow("Transmission", identity.transmission)
                    DetailRow("Drive", identity.driveType)
                    DetailRow("Fuel", identity.fuel)
                    DetailRow("Built in", identity.plantCountry?.capitalized)
                    DetailRow("Color", vehicle.colorName ?? vehicle.color?.displayName)
                    ForEach(identity.decoderNotes, id: \.self) { note in
                        GridRow {
                            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                            Text(note).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .font(.callout)
            if !vehicle.notes.isEmpty {
                Text(vehicle.notes)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .card()
    }

    private var connection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Adapter").font(.headline)
            if let workbench {
                let summary = ConnectionSummary(
                    adapter: workbench.adapter, state: workbench.connection)
                HStack(spacing: 10) {
                    Image(systemName: summary.symbol)
                    Circle().fill(summary.tone.color).frame(width: 8, height: 8)
                    VStack(alignment: .leading) {
                        Text(summary.title).font(.callout.weight(.medium))
                        Text(summary.detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button(workbench.connection.status == nil ? "Connect…" : "Connection…") {
                    connecting = true
                }
                .controlSize(.small)
            } else {
                Text("No adapter set up.").foregroundStyle(.secondary)
            }
        }
        .card()
    }

    private var modules: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Modules").font(.headline)
            if vehicle.orderedModules.isEmpty {
                Text("None yet. Add the modules you want to read codes from.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(vehicle.orderedModules) { module in
                    HStack {
                        Text(module.label).lineLimit(1)
                        Spacer()
                        Text(String(format: "%03X → %03X", module.request, module.response))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }
            Button("Edit Modules…") { editingModules = true }
                .controlSize(.small)
        }
        .card()
    }

    private var recentSessions: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Sessions").font(.headline)
                Spacer()
                Button("New Session", action: newSession)
                    .controlSize(.small)
            }
            if vehicle.sessions.isEmpty {
                Text("Start a session to work on a problem with this car.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(vehicle.orderedSessions.prefix(5)) { session in
                Button {
                    show(.session(session.id))
                } label: {
                    HStack {
                        Image(
                            systemName: session.status == .resolved
                                ? "checkmark.circle.fill" : "circle.dotted"
                        )
                        .foregroundStyle(session.status == .resolved ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.title)
                            if !session.problem.isEmpty {
                                Text(session.problem)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        Text(session.updatedAt, format: .relative(presentation: .named))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .card()
    }

    private func newSession() {
        do {
            let session = try model.garage.addSession(to: vehicle, title: "New session")
            show(.session(session.id))
        } catch {
            problem = String(describing: error)
        }
    }
}

private struct StatTile: View {
    let value: Int?
    let label: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(value.map(String.init) ?? "–")
                        .font(.title2.weight(.semibold).monospacedDigit())
                    Text(label)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .card()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct DetailRow: View {
    let label: String
    let value: String?
    let monospaced: Bool

    init(_ label: String, _ value: String?, monospaced: Bool = false) {
        self.label = label
        self.value = value
        self.monospaced = monospaced
    }

    var body: some View {
        if let value {
            GridRow {
                Text(label).foregroundStyle(.secondary)
                Text(value)
                    .font(monospaced ? .callout.monospaced() : .callout)
                    .textSelection(.enabled)
            }
        }
    }
}
