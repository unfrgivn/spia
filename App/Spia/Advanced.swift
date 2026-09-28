import OBDCore
import SpiaKit
import SpiaStore
import SwiftUI

/// Edit the diagnostic modules known on a vehicle. IDs are hexadecimal CAN identifiers.
struct ModulesEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let vehicle: Vehicle
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Modules on \(vehicle.name)")
                .font(.title2.weight(.semibold))
            Text(
                "Each module answers on its own reply ID. Labels marked unconfirmed come from references, not from the module itself."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            List {
                ForEach(vehicle.orderedModules) { module in
                    ModuleRow(module: module)
                }
                .onDelete { offsets in
                    for index in offsets {
                        model.garage.context.delete(vehicle.orderedModules[index])
                    }
                    save()
                }
            }
            .frame(minHeight: 220)
            HStack {
                Button {
                    addModule()
                } label: {
                    Label("Add Module", systemImage: "plus")
                }
                Spacer()
                Button("Done") {
                    save()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .platformSheetFrame(width: 620, height: 460)
        .errorAlert($error)
    }

    private func addModule() {
        guard let target = try? ModuleTarget(bus: .highSpeed, request: 0x7E0, response: 0x7E8)
        else { return }
        let position = (vehicle.modules.map(\.position).max() ?? -1) + 1
        vehicle.modules.append(
            ModulePreset(label: "New module", target: target, position: position))
        save()
    }

    private func save() {
        do { try model.garage.context.save() } catch { self.error = error.readable }
    }
}

private struct ModuleRow: View {
    @Bindable var module: ModulePreset

    var body: some View {
        HStack(spacing: 10) {
            TextField("Label", text: $module.label)
                .frame(minWidth: 160)
            Picker("Bus", selection: $module.busRaw) {
                Text("500k (pins 6/14)").tag(CANBus.highSpeed.rawValue)
                Text("125k (pins 3/11)").tag(CANBus.mediumSpeed.rawValue)
            }
            .labelsHidden()
            .fixedSize()
            HexField(label: "Request", value: $module.request)
            Image(systemName: "arrow.right").foregroundStyle(.secondary)
            HexField(label: "Reply", value: $module.response)
            Toggle("Confirmed", isOn: $module.confirmed)
                .platformCheckboxToggle()
            if module.target == nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(
                        "Not a valid module address: 11-bit IDs up to 7FF, not 7DF, request and reply different."
                    )
            }
        }
    }
}

private struct HexField: View {
    let label: String
    @Binding var value: Int
    @State private var text = ""

    var body: some View {
        TextField(label, text: $text)
            .font(.body.monospaced())
            .frame(width: 56)
            .onAppear { text = String(format: "%03X", value) }
            .onChange(of: text) { _, new in
                if let parsed = Int(new, radix: 16), parsed <= 0x7FF { value = parsed }
            }
            .accessibilityLabel("\(label) ID, hexadecimal")
    }
}

/// Every byte exchanged during a check, for when the summary isn't enough.
struct TranscriptView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let entry: TimelineEntry

    @State private var lines: [Line] = []
    @State private var error: String?

    struct Line: Identifiable {
        let id: Int
        let milliseconds: UInt64
        let sent: Bool
        let text: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Transcript · \(entry.title)")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            Text(
                "→ sent to the adapter · ← received from the car. Times are milliseconds from the start of the check."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            if let error {
                Text(error).foregroundStyle(.red)
            }
            List(lines) { line in
                HStack(alignment: .top, spacing: 10) {
                    Text("\(line.milliseconds)")
                        .foregroundStyle(.secondary)
                        .frame(width: 56, alignment: .trailing)
                    Text(line.sent ? "→" : "←")
                        .foregroundStyle(line.sent ? Color.accentColor : Color.green)
                    Text(line.text)
                        .textSelection(.enabled)
                }
                .font(.callout.monospaced())
            }
        }
        .padding(20)
        .platformSheetFrame(width: 640, height: 520)
        .task { load() }
    }

    private func load() {
        guard let path = entry.transcriptPath else { return }
        do {
            let text = try String(contentsOf: model.garage.files.url(for: path), encoding: .utf8)
            lines = try Transcript.decodeFile(text).enumerated().map { index, event in
                Line(
                    id: index, milliseconds: event.milliseconds, sent: event.direction == .tx,
                    text: String(decoding: event.bytes, as: UTF8.self)
                        .replacingOccurrences(of: "\r", with: "⏎ ")
                        .trimmingCharacters(in: .whitespaces))
            }
        } catch {
            self.error = "Couldn't read the transcript: \(error.readable)"
        }
    }
}
