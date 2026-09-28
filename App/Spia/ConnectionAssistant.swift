import SpiaKit
import SpiaStore
import SwiftUI

struct ConnectionAssistant: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let vehicle: Vehicle
    let workbench: Workbench
    /// Called with a new workbench when the chosen port changes.
    let replaced: (Workbench) -> Void

    @State private var ports: [String] = []
    @State private var chosenPort: String?

    private var profile: AdapterProfile? { vehicle.adapters.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Connect to your car")
                .font(.title2.weight(.semibold))

            if workbench.adapter.kind == .demo {
                Text(
                    "This vehicle uses real recordings from a 2017 Maserati Ghibli, made with a vLinker FS on 2026-09-26. Connecting replays the recorded adapter check; every result is labeled as coming from a recording."
                )
                .fixedSize(horizontal: false, vertical: true)
            } else {
                #if os(macOS)
                    Picker(
                        "Adapter",
                        selection: Binding(
                            get: { profile?.kind ?? .usbSerial },
                            set: { switchAdapter(to: $0) })
                    ) {
                        Text("USB cable").tag(AdapterKind.usbSerial)
                        Text("Bluetooth").tag(AdapterKind.bluetooth)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .disabled(workbench.isBusy)
                    if workbench.adapter.kind == .bluetooth {
                        bluetoothSteps
                    } else {
                        steps
                    }
                #else
                    if workbench.adapter.kind == .bluetooth {
                        bluetoothSteps
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(AdapterSetupError.needsMac.description)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Use Bluetooth instead") { switchAdapter(to: .bluetooth) }
                        }
                    }
                #endif
            }

            status

            HStack {
                if workbench.connection.status != nil {
                    Button("Disconnect") { Task { await workbench.disconnect() } }
                }
                Spacer()
                Button("Done") { dismiss() }
                Button(connectTitle) { Task { await workbench.connect() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        workbench.isBusy
                            || (workbench.adapter.kind == .usbSerial && profile?.devicePath == nil))
            }
        }
        .padding(24)
        .platformSheetFrame(width: 540)
        .onAppear {
            #if os(macOS)
                refreshPorts()
            #endif
            chosenPort = profile?.devicePath
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 16) {
            Step(number: 1, title: "Plug the adapter into the car") {
                Text(
                    "The OBD-II port is under the dashboard, usually left of the steering column. Use a USB adapter such as the Vgate vLinker FS (USB)."
                )
            }
            Step(number: 2, title: "Connect it to this Mac") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Picker("Port", selection: $chosenPort) {
                            Text("Choose…").tag(String?.none)
                            ForEach(ports, id: \.self) { port in
                                Text(portLabel(port)).tag(String?.some(port))
                            }
                        }
                        .labelsHidden()
                        Button {
                            refreshPorts()
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .labelStyle(.iconOnly)
                        .help("Look for adapters again")
                    }
                    .onChange(of: chosenPort) { _, port in choose(port) }
                    if ports.isEmpty {
                        Text(
                            "No USB adapter found. Check the cable; a vLinker FS shows up as “usbserial-…”."
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                }
            }
            Step(number: 3, title: "Turn the ignition on") {
                Text(
                    "The dash should light up; the engine can stay off. The adapter check works without it, but reading the car doesn't. For long sessions, run the engine or use a charger so the battery doesn't drain."
                )
            }
        }
    }

    private var bluetoothSteps: some View {
        VStack(alignment: .leading, spacing: 16) {
            Step(number: 1, title: "Plug in the adapter") {
                Text(
                    "Plug the vLinker FS into the OBD-II port. Switch it once from MFi to BLE+BT with Vgate's VgateFwUpdater iOS app, then unplug and replug it."
                )
            }
            Step(number: 2, title: "Turn the ignition on") {
                Text(
                    "The dash should light up; the engine can stay off. Spia finds the adapter on its own; no pairing needed. Allow Bluetooth when asked."
                )
            }
            Step(number: 3, title: "When you're done") {
                Text(
                    "Unplug the adapter. In BLE+BT mode anyone nearby can connect to it while it's awake."
                )
            }
        }
    }

    private var status: some View {
        let summary = ConnectionSummary(adapter: workbench.adapter, state: workbench.connection)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: summary.symbol)
                    .font(.title2)
                Circle().fill(summary.tone.color).frame(width: 10, height: 10)
                VStack(alignment: .leading) {
                    Text(summary.title).font(.headline)
                    Text(summary.detail).font(.callout).foregroundStyle(.secondary)
                }
                if workbench.connection == .connecting {
                    Spacer()
                    ProgressView().controlSize(.small)
                }
            }
            if let adapterStatus = workbench.connection.status {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    GridRow {
                        Text("Adapter").foregroundStyle(.secondary)
                        Text(adapterStatus.hardware ?? "unknown")
                    }
                    GridRow {
                        Text("Firmware").foregroundStyle(.secondary)
                        Text(adapterStatus.firmware ?? adapterStatus.identity)
                    }
                }
                .font(.callout)
            }
            if let error = workbench.lastError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .card(tint: summary.tone == .neutral ? nil : summary.tone.color)
    }

    private var connectTitle: String {
        switch workbench.connection {
        case .ready: return "Reconnect"
        case .reconnectRequired: return "Reconnect"
        default: return "Connect"
        }
    }

    private func portLabel(_ port: String) -> String {
        let name = port.replacingOccurrences(of: "/dev/cu.", with: "")
        return name.contains("usbserial") ? "\(name) (USB adapter)" : name
    }

    private func refreshPorts(selectFirst: Bool = true) {
        ports = AppModel.serialPorts()
        if selectFirst, chosenPort == nil,
            let first = ports.first(where: { $0.contains("usbserial") })
        {
            chosenPort = first
        }
    }

    private func choose(_ port: String?) {
        guard let profile, profile.devicePath != port else { return }
        profile.devicePath = port
        Task {
            await model.resetConnection(for: profile)
            if let fresh = model.workbench(for: vehicle) { replaced(fresh) }
        }
    }

    private func switchAdapter(to kind: AdapterKind) {
        guard let profile else { return }
        guard profile.kind != kind else { return }
        profile.use(kind)
        #if os(macOS)
            if kind == .usbSerial {
                chosenPort = nil
                refreshPorts(selectFirst: false)
            }
        #endif
        Task {
            await model.resetConnection(for: profile)
            if let fresh = model.workbench(for: vehicle) { replaced(fresh) }
        }
    }
}

private struct Step<Content: View>: View {
    let number: Int
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.callout.weight(.bold))
                .frame(width: 24, height: 24)
                .background(.tint.opacity(0.15), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                content
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
