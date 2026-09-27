import SpiaKit
import SpiaStore
import SwiftUI

struct TimelineSection: View {
    let session: DiagnosticSession
    let showTranscript: (TimelineEntry) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Timeline")
                .font(.title2.weight(.semibold))
            if session.entries.isEmpty {
                Text("Results and notes will appear here, newest first.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(session.timeline.reversed()) { entry in
                EntryView(entry: entry, modules: session.vehicle?.orderedModules ?? []) {
                    showTranscript(entry)
                }
            }
        }
    }
}

private struct EntryView: View {
    let entry: TimelineEntry
    let modules: [ModulePreset]
    let showTranscript: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label(entry.title, systemImage: symbol)
                    .font(.headline)
                    .foregroundStyle(entry.kind == .failure ? Color.red : Color.primary)
                Spacer()
                if case .recording = entry.result?.source {
                    Chip(text: "From recording")
                        .help("Produced from a real recording of the car, not a live connection")
                }
                Text(entry.date, format: .dateTime.hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            switch entry.kind {
            case .note:
                Text(entry.body)
                    .textSelection(.enabled)
            case .failure:
                Text(entry.body)
                    .textSelection(.enabled)
            case .result:
                Text(entry.body)
                    .foregroundStyle(.secondary)
                if let result = entry.result {
                    ResultDetail(payload: result.payload, modules: modules)
                } else {
                    Text("This result was saved by a newer version of Spia.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if !entry.warnings.isEmpty || entry.transcriptPath != nil {
                HStack {
                    if !entry.warnings.isEmpty {
                        Text(entry.warnings.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                    if entry.transcriptPath != nil {
                        Button("Transcript", action: showTranscript)
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
            }
        }
        .card(tint: entry.kind == .failure ? .red : nil)
    }

    private var symbol: String {
        switch entry.kind {
        case .note: return "text.bubble"
        case .failure: return "exclamationmark.triangle"
        case .result: return "checkmark.seal"
        }
    }
}

private struct ResultDetail: View {
    let payload: JobPayload
    let modules: [ModulePreset]

    var body: some View {
        switch payload {
        case .moduleDTCs(let result):
            ModuleCodesView(result: result, label: label(for: result.target))
        case .genericScan(let ecus):
            ForEach(ecus, id: \.ecu) { GenericScanRow(scan: $0) }
        case .vehicleInfo(let ecus):
            ForEach(ecus, id: \.ecu) { IdentityRow(identity: $0) }
        case .adapter(let status):
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                FactRow("Adapter", status.hardware ?? status.identity)
                if let firmware = status.firmware { FactRow("Firmware", firmware) }
                FactRow("Protocol chip", status.identity)
                FactRow(
                    "Car battery",
                    status.voltage.map { String(format: "%.1f V", $0) } ?? "no power detected")
            }
            .font(.callout)
        }
    }

    private func label(for target: ModuleTarget) -> String {
        let name = modules.first { $0.target == target }?.label
        let ids = String(format: "%03X → %03X", target.request, target.response)
        return name.map { "\($0) · \(ids)" } ?? "Module \(ids)"
    }
}

private struct ModuleCodesView: View {
    let result: ModuleDTCs
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.subheadline.weight(.medium))
            switch result.outcome {
            case .records(_, let records) where records.isEmpty:
                Label("No trouble codes stored", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            case .records(let availability, let records):
                ForEach(records, id: \.code) { record in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(record.code)
                            .font(.body.monospaced().weight(.semibold))
                            .textSelection(.enabled)
                        FlowChips(
                            flags: DTCStatus.flags(for: record.status, availability: availability))
                    }
                }
                Text(
                    "Codes are the module's raw bytes. Manufacturer descriptions aren't verified yet."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            case .negative(_, let code):
                Text(NegativeResponse.explanation(code))
            }
        }
    }
}

private struct FlowChips: View {
    let flags: [DTCStatus.Flag]

    var body: some View {
        ViewThatFits {
            HStack(spacing: 6) { chips }
            VStack(alignment: .leading, spacing: 4) { chips }
        }
    }

    @ViewBuilder private var chips: some View {
        ForEach(flags, id: \.bit) { flag in
            Chip(text: flag.label, color: flag.isActive ? .orange : .secondary)
        }
    }
}

private struct GenericScanRow: View {
    let scan: ECUScan

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(format: "ECU %03X", scan.ecu))
                .font(.subheadline.weight(.medium))
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                FactRow("Stored codes", codes(scan.stored))
                FactRow("Pending codes", codes(scan.pending))
                FactRow("Permanent codes", codes(scan.permanent))
                FactRow("Readiness", readiness)
                FactRow("Freeze frame", freezeFrame)
            }
            .font(.callout)
        }
    }

    private func codes(_ reading: Reading<[String]>) -> String {
        switch reading {
        case .value(let codes): return codes.isEmpty ? "none" : codes.joined(separator: ", ")
        case .unsupported(let why): return "not supported (\(why))"
        case .unavailable(let why): return "unknown (\(why))"
        case .malformed(let bytes), .unknown(let bytes): return "unreadable answer \(bytes)"
        }
    }

    private var readiness: String {
        guard let readiness = scan.readiness.value else { return "unknown" }
        let complete = readiness.monitors.filter(\.complete).count
        return
            "Check-engine light \(readiness.milOn ? "ON" : "off") · \(complete) of \(readiness.monitors.count) monitors complete"
    }

    private var freezeFrame: String {
        switch scan.freezeFrameDTC {
        case .value(let dtc): return dtc.map { "stored for \($0)" } ?? "none stored"
        default: return "unknown"
        }
    }
}

private struct IdentityRow: View {
    let identity: ECUIdentity

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(
                identity.displayName.map { "\($0) · " + String(format: "%03X", identity.ecu) }
                    ?? String(format: "ECU %03X", identity.ecu)
            )
            .font(.subheadline.weight(.medium))
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                if let vin = identity.vin.value { FactRow("VIN", vin) }
                if let ids = identity.calibrationIDs.value {
                    FactRow("Software", ids.joined(separator: ", "))
                }
                if let cvns = identity.cvns.value {
                    FactRow("Checksum", cvns.joined(separator: ", "))
                }
            }
            .font(.callout)
        }
    }
}

private struct FactRow: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .textSelection(.enabled)
        }
    }
}
