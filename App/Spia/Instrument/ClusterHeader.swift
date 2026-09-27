import SpiaKit
import SpiaStore
import SwiftUI

/// The top of a session, laid out like a dash: which car and which session, then the lamps its
/// results light. The adapter lamp is the one place a session shows the connection. It's always
/// drawn dark, like a dash in daylight, so the lamps glow in any appearance.
struct ClusterHeader: View {
    @Bindable var session: DiagnosticSession
    let vehicle: Vehicle
    let references: VehicleReferences
    let workbench: Workbench
    let connect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            identity
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 28) { lamps }
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)],
                    alignment: .leading, spacing: 14
                ) { lamps }
            }
        }
        .panel()
        .environment(\.colorScheme, .dark)
    }

    /// The car and the session. When the row won't fit (an iPhone held upright), the status
    /// moves under the title instead of squeezing it.
    private var identity: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                thumbnail
                titles
                Spacer(minLength: 8)
                status
            }
            HStack(alignment: .top, spacing: 14) {
                thumbnail
                VStack(alignment: .leading, spacing: 8) {
                    titles
                    status
                }
            }
        }
    }

    private var thumbnail: some View {
        VehiclePhoto(vehicle: vehicle, references: references)
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var titles: some View {
        VStack(alignment: .leading, spacing: 3) {
            TextField("Session title", text: $session.title, axis: .vertical)
                .font(.title2.weight(.semibold))
                .textFieldStyle(.plain)
                .lineLimit(1...3)
                .foregroundStyle(Palette.primary)
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(Palette.secondary)
                .lineLimit(2)
        }
    }

    private var status: some View {
        Picker("Status", selection: $session.status) {
            ForEach(SessionStatus.allCases, id: \.self) { status in
                Text(status.rawValue.capitalized).tag(status)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
    }

    private var subtitle: String {
        let started = "Started \(session.startedAt.formatted(date: .abbreviated, time: .shortened))"
        return ([vehicle.name] + (vehicle.isDemo ? ["Demo"] : []) + [started])
            .joined(separator: " · ")
    }

    @ViewBuilder private var lamps: some View {
        let findings = SessionFindings(
            results: session.timeline.compactMap(\.result?.payload), airbag: airbagModule)
        let adapter = ConnectionSummary(adapter: workbench.adapter, state: workbench.connection)
        Button(action: connect) {
            Lamp(
                tone: workbench.activity == nil ? adapter.tone : .working, symbol: adapter.symbol,
                label: "Adapter", value: workbench.activity == nil ? adapter.title : "Reading")
        }
        .buttonStyle(.plain)
        .help("Adapter connection")
        Lamp(
            tone: findings.checkEngineTone, symbol: "engine.combustion", label: "Check engine",
            value: findings.checkEngine.map { $0 ? "On" : "Off" } ?? "Not read")
        Lamp(
            tone: findings.codesTone,
            symbol: findings.codes?.isEmpty == false ? "exclamationmark.octagon" : "checkmark",
            label: "Trouble codes", value: Self.count(findings.codes))
        if let airbagCodes = findings.airbagCodes {
            Lamp(
                tone: findings.airbagTone, symbol: "figure.seated.side.airbag.on", label: "Airbag",
                value: Self.count(airbagCodes))
        }
        battery(volts: workbench.connection.status?.voltage ?? findings.voltage)
    }

    private func battery(volts: Double?) -> some View {
        HStack(spacing: 8) {
            ArcGauge(value: volts, range: 10...16, tone: ConnectionSummary.batteryTone(volts))
            VStack(alignment: .leading, spacing: 1) {
                Text("Battery").instrumentCaption()
                Text(volts.map { String(format: "%.1f V", $0) } ?? "Not read")
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(volts == nil ? Palette.secondary : Palette.primary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Battery")
        .accessibilityValue(volts.map { String(format: "%.1f volts", $0) } ?? "Not read")
    }

    /// The module whose codes get their own lamp. Modules are the owner's own labels, so this
    /// goes by name.
    private var airbagModule: ModuleTarget? {
        vehicle.orderedModules.first { $0.label.localizedCaseInsensitiveContains("airbag") }?.target
    }

    private static func count(_ codes: [String]?) -> String {
        guard let codes else { return "Not read" }
        return codes.isEmpty ? "None" : "\(codes.count)"
    }
}
