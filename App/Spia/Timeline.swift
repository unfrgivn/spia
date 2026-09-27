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
                    .foregroundStyle(Palette.secondary)
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
        if entry.kind == .result, let result = entry.result,
            let reading = ResultReading(result.payload, moduleName: moduleName)
        {
            ReadingCard(
                entry: entry, reading: reading, payload: result.payload, modules: modules,
                showTranscript: showTranscript)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Label(entry.title, systemImage: symbol)
                        .font(.headline)
                        .foregroundStyle(entry.kind == .failure ? Palette.fault : Palette.primary)
                    Spacer()
                    EntryStamp(entry: entry)
                }
                switch entry.kind {
                case .note, .failure:
                    Text(entry.body)
                        .textSelection(.enabled)
                case .result:
                    Text(entry.body)
                        .foregroundStyle(Palette.secondary)
                    if let result = entry.result {
                        ResultDetail(payload: result.payload, modules: modules)
                    } else {
                        Text("This result was saved by a newer version of Spia.")
                            .font(.caption)
                            .foregroundStyle(Palette.secondary)
                    }
                }
                EntryFooter(entry: entry, showTranscript: showTranscript)
            }
            .card(tint: entry.kind == .failure ? Palette.fault : nil)
        }
    }

    private var symbol: String {
        switch entry.kind {
        case .note: return "text.bubble"
        case .failure: return "exclamationmark.triangle"
        case .result: return "checkmark.seal"
        }
    }

    private func moduleName(_ target: ModuleTarget) -> String {
        modules.first { $0.target == target }?.label
            ?? String(format: "Module %03X", target.request)
    }
}

/// A check's result led by what it means: a lamp and a headline, the codes it found, and the
/// raw answer behind a disclosure.
private struct ReadingCard: View {
    let entry: TimelineEntry
    let reading: ResultReading
    let payload: JobPayload
    let modules: [ModulePreset]
    let showTranscript: () -> Void
    @State private var showsRaw = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                LampDisc(tone: reading.tone, symbol: symbol)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
                Text(reading.headline)
                    .font(.headline)
                    .foregroundStyle(Palette.primary)
            }
            findings
            DisclosureGroup(isExpanded: $showsRaw) {
                ResultDetail(payload: payload, modules: modules)
                    .padding(.top, 6)
            } label: {
                Text("Raw data")
                    .font(.callout)
                    .foregroundStyle(Palette.secondary)
            }
            EntryFooter(entry: entry, showTranscript: showTranscript, showsStamp: true)
        }
        .card()
    }

    private var symbol: String {
        switch reading.tone {
        case .good: "checkmark"
        case .bad: "exclamationmark.octagon"
        default: "exclamationmark.triangle"
        }
    }

    @ViewBuilder private var findings: some View {
        switch payload {
        case .genericScan(let reports):
            GenericScanReadouts(reports: reports)
        case .moduleDTCs(let module):
            switch module.outcome {
            case .records(let availability, let records):
                ForEach(records, id: \.code) { record in
                    DTCRow(
                        code: record.code,
                        detail: DTCStatus.summary(for: record.status, availability: availability),
                        tone: DTCStatus.tone(for: record.status, availability: availability))
                }
                if !records.isEmpty {
                    Text(
                        "Codes are the module's raw bytes; the maker's names for them aren't known yet."
                    )
                    .font(.caption)
                    .foregroundStyle(Palette.tertiary)
                }
            case .negative(_, let code):
                Text(NegativeResponse.explanation(code))
                    .foregroundStyle(Palette.secondary)
            }
        case .adapter, .vehicleInfo:
            EmptyView()
        }
    }
}

/// A generic scan's counts as readouts on a dash, then each code it found.
private struct GenericScanReadouts: View {
    let reports: [ECUScan]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 32) { readouts }
                Grid(alignment: .leading, horizontalSpacing: 32, verticalSpacing: 12) {
                    GridRow {
                        readout("Stored", count(\.stored))
                        readout("Pending", count(\.pending))
                    }
                    GridRow {
                        readout("Permanent", count(\.permanent))
                        readout("Monitors ready", monitors)
                    }
                }
            }
            ForEach(codes, id: \.code) { found in
                DTCRow(code: found.code, detail: found.lists, tone: .bad)
            }
        }
    }

    @ViewBuilder private var readouts: some View {
        readout("Stored", count(\.stored))
        readout("Pending", count(\.pending))
        readout("Permanent", count(\.permanent))
        readout("Monitors ready", monitors)
    }

    private func readout(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).instrumentCaption()
            Text(value)
                .font(.title3.weight(.semibold))
                .fontDesign(.rounded)
                .monospacedDigit()
                .foregroundStyle(Palette.primary)
        }
        .accessibilityElement(children: .combine)
    }

    /// Distinct codes in one list across the modules, or a dash when none could say.
    private func count(_ list: KeyPath<ECUScan, Reading<[String]>>) -> String {
        let answers = reports.compactMap { $0[keyPath: list].value }
        guard !answers.isEmpty else { return "–" }
        return "\(Set(answers.joined()).count)"
    }

    private var monitors: String {
        let monitors = reports.compactMap(\.readiness.value).flatMap(\.monitors)
        guard !monitors.isEmpty else { return "–" }
        return "\(monitors.filter(\.complete).count) of \(monitors.count)"
    }

    /// Each distinct code, with the lists it's in: "Stored · Permanent".
    private var codes: [(code: String, lists: String)] {
        let lists: [(String, KeyPath<ECUScan, Reading<[String]>>)] = [
            ("Stored", \.stored), ("Pending", \.pending), ("Permanent", \.permanent),
        ]
        let found = Set(
            reports.flatMap { report in lists.compactMap { report[keyPath: $0.1].value }.joined() })
        return found.sorted().map { code in
            let names = lists.filter { _, list in
                reports.contains { $0[keyPath: list].value?.contains(code) == true }
            }
            return (code, names.map(\.0).joined(separator: " · "))
        }
    }
}

/// One trouble code: the code as a badge in its lamp's colour, then what its status says.
private struct DTCRow: View {
    let code: String
    let detail: String
    let tone: Tone

    var body: some View {
        let color = tone == .neutral ? Palette.secondary : tone.color
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(code)
                .font(.callout.monospaced().weight(.semibold))
                .foregroundStyle(color)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .overlay(Capsule().strokeBorder(color.opacity(0.55)))
                .textSelection(.enabled)
            Text(detail)
                .font(.callout)
                .foregroundStyle(Palette.secondary)
        }
    }
}

/// Where a result came from and when.
private struct EntryStamp: View {
    let entry: TimelineEntry

    var body: some View {
        HStack(spacing: 8) {
            if case .recording = entry.result?.source {
                Chip(text: "From recording")
                    .help("Produced from a real recording of the car, not a live connection")
            }
            Text(entry.date, format: .dateTime.hour().minute())
                .font(.caption)
                .foregroundStyle(Palette.tertiary)
        }
    }
}

/// Requests that went unanswered, and the transcript of every byte, when there is one. Reading
/// cards keep their headline's row to themselves, so where and when goes here too.
private struct EntryFooter: View {
    let entry: TimelineEntry
    let showTranscript: () -> Void
    var showsStamp = false

    var body: some View {
        if showsStamp || !entry.warnings.isEmpty || entry.transcriptPath != nil {
            HStack {
                if showsStamp { EntryStamp(entry: entry) }
                if !entry.warnings.isEmpty {
                    Text(entry.warnings.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(Palette.secondary)
                        .lineLimit(2)
                }
                Spacer()
                if entry.transcriptPath != nil {
                    Button("Transcript", action: showTranscript)
                        .platformLinkButton()
                        .font(.caption)
                }
            }
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
                    .foregroundStyle(Palette.pass)
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
                .foregroundStyle(Palette.secondary)
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
            Chip(
                text: flag.label, color: flag.isActive ? Palette.caution : Palette.secondary)
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
                .foregroundStyle(Palette.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .textSelection(.enabled)
        }
    }
}
