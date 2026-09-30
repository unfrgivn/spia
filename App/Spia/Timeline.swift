import SpiaKit
import SpiaStore
import SwiftUI

/// Everything learned in a session, oldest first, one line each: when, what it was about, and
/// what it found, in the board's words. A line opens to show the raw answer and the transcript.
struct CaseFile: View {
    let session: DiagnosticSession
    let layout: BoardLayout
    let showTranscript: (TimelineEntry) -> Void
    let reviewSurvey: (SurveyReport) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeading("Case file", note: session.entries.isEmpty ? nil : count)
                .padding(.bottom, 10)
            if session.entries.isEmpty {
                Hairline()
                Text("Results and notes will appear here, oldest first.")
                    .font(.callout)
                    .foregroundStyle(Palette.secondary)
                    .padding(.vertical, 12)
            }
            ForEach(session.timeline) { entry in
                LedgerRow(
                    entry: entry, modules: modules, layout: layout,
                    showTranscript: { showTranscript(entry) }, reviewSurvey: reviewSurvey)
            }
            if !session.entries.isEmpty { Hairline() }
        }
    }

    private var modules: [ModulePreset] { session.vehicle?.orderedModules ?? [] }

    private var count: String {
        session.entries.count == 1 ? "1 entry" : "\(session.entries.count) entries, oldest first"
    }
}

private struct LedgerRow: View {
    let entry: TimelineEntry
    let modules: [ModulePreset]
    let layout: BoardLayout
    let showTranscript: () -> Void
    let reviewSurvey: (SurveyReport) -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Hairline()
            Button {
                withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
            } label: {
                line(LedgerSummary(entry: entry, modules: modules))
            }
            .buttonStyle(.plain)
            .accessibilityHint(expanded ? "Hides the details" : "Shows the details")
            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    details
                    EntryFooter(entry: entry, showTranscript: showTranscript, showsStamp: true)
                }
                .padding(.leading, layout == .wide ? 84 : 0)
                .padding(.bottom, 14)
            }
        }
    }

    @ViewBuilder private func line(_ summary: LedgerSummary) -> some View {
        let title = Text(summary.title)
            .fontWeight(.semibold)
            .foregroundStyle(summary.failed ? Palette.fault : Palette.primary)
        let text = Text(summary.text).foregroundStyle(Palette.secondary)
        Group {
            switch layout {
            case .wide:
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    time.frame(width: 84, alignment: .leading)
                    VStack(alignment: .leading, spacing: 3) {
                        title
                        if let recorded = entry.result?.source.replayDate {
                            ReplayChip(recorded: recorded)
                        }
                    }
                    .frame(width: 250, alignment: .leading)
                    text.lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                    chevron
                }
                .font(.system(size: 14))
            case .compact:
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    time
                    VStack(alignment: .leading, spacing: 3) {
                        title.font(.system(size: 15))
                        if let recorded = entry.result?.source.replayDate {
                            ReplayChip(recorded: recorded)
                        }
                        text.font(.system(size: 13.5)).lineLimit(3)
                    }
                    Spacer(minLength: 0)
                    chevron
                }
            }
        }
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }

    private var time: some View {
        Text(entry.date, format: .dateTime.hour().minute())
            .font(.system(size: 12.5, weight: .medium, design: .monospaced))
            .foregroundStyle(Palette.tertiary)
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Palette.tertiary)
            .rotationEffect(.degrees(expanded ? 90 : 0))
    }

    @ViewBuilder private var details: some View {
        switch entry.kind {
        case .note, .failure:
            Text(entry.body)
                .textSelection(.enabled)
                .foregroundStyle(Palette.secondary)
        case .result:
            if let result = entry.result {
                ResultDetail(
                    payload: result.payload, modules: modules, reviewSurvey: reviewSurvey)
            } else {
                Text("This result was saved by a newer version of Spia.")
                    .font(.caption)
                    .foregroundStyle(Palette.secondary)
            }
        }
    }
}

/// An entry in the board's words: "Airbag controller", "80011B 80021B · Failing now · …".
private struct LedgerSummary {
    let title: String
    let text: String
    let failed: Bool

    init(entry: TimelineEntry, modules: [ModulePreset]) {
        failed = entry.kind == .failure
        guard entry.kind == .result else {
            title = entry.kind == .note ? "Note" : entry.title
            text = entry.body
            return
        }
        guard let payload = entry.result?.payload else {
            title = entry.title
            text = "Saved by a newer version of Spia"
            return
        }
        switch payload {
        case .adapter(let status):
            title = "Adapter check"
            text = [
                status.hardware ?? status.identity,
                status.voltage.map { String(format: "Battery at %.1f V", $0) },
            ].compactMap { $0 }.joined(separator: " · ")
        case .vehicleInfo(let ecus):
            title = "Vehicle information"
            text =
                ecus.compactMap(\.vin.value).first.map { "VIN \($0)" }
                ?? (ecus.count == 1 ? "1 computer answered" : "\(ecus.count) computers answered")
        case .genericScan, .moduleDTCs:
            let board = SessionBoard(
                modules: modules.boardModules,
                results: entry.boardResult.map { [$0] } ?? [])
            let row = board.rows.first { $0.date != nil }
            title = row?.name ?? entry.title
            text =
                row.map { row in
                    ([row.codes.joined(separator: " ")].filter { !$0.isEmpty } + [row.detail])
                        .joined(separator: " · ")
                } ?? entry.body
        case .survey(let report):
            title = "Survey"
            text = ResultText.summary(
                JobResult(
                    job: .survey(report.plan), payload: .survey(report), source: .live,
                    transcript: nil))
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
            if let recorded = entry.result?.source.replayDate {
                ReplayChip(recorded: recorded)
            }
            Text(entry.date, format: .dateTime.hour().minute())
                .font(.caption)
                .foregroundStyle(Palette.tertiary)
        }
    }
}

/// Marks a result replayed from a saved recording, with when the car said it, so it can't pass
/// for a new reading.
private struct ReplayChip: View {
    let recorded: Date

    var body: some View {
        let stamp = recorded.formatted(date: .abbreviated, time: .shortened)
        Chip(text: "Replay of \(stamp)")
            .help("Replayed from a recording of this car made on \(stamp), not a new reading")
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
    let reviewSurvey: (SurveyReport) -> Void

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
        case .survey(let report):
            VStack(alignment: .leading, spacing: 10) {
                Text(
                    ResultText.summary(
                        JobResult(
                            job: .survey(report.plan), payload: .survey(report), source: .live,
                            transcript: nil))
                )
                .font(.callout)
                Button("Review Modules") { reviewSurvey(report) }
                    .buttonStyle(.borderedProminent)
            }
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
