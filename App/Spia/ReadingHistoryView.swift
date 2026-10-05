import SpiaKit
import SpiaStore
import SwiftUI

extension View {
    func readingHistory(
        runner: DiagnosticRunCoordinator?, vehicle: Vehicle?,
        explain: ((SessionBoard.Row) -> Void)? = nil,
        showTranscript: @escaping (TimelineEntry) -> Void = { _ in }
    ) -> some View {
        sheet(
            item: Binding(
                get: { runner?.historySubject },
                set: { runner?.historySubject = $0 })
        ) { subject in
            if let runner, let vehicle {
                ReadingHistoryView(
                    vehicle: vehicle, subject: subject, session: runner.session,
                    explain: explain.map { callback in
                        { row in
                            runner.historySubject = nil
                            callback(row)
                        }
                    }, showTranscript: showTranscript)
            }
        }
    }
}

struct ReadingHistoryView: View {
    let vehicle: Vehicle
    let subject: SessionBoard.Subject
    let session: DiagnosticSession?
    let explain: ((SessionBoard.Row) -> Void)?
    let showTranscript: (TimelineEntry) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var expanded: Set<UUID> = []

    private var asOf: Date? { session?.closedAt }
    private var history: ReadingHistory { vehicle.history(for: subject, asOf: asOf) }
    private var row: SessionBoard.Row {
        vehicle.board(asOf: asOf).rows.first { $0.subject == subject }
            ?? history.readings.first?.row
            ?? SessionBoard.Row(
                subject: subject, name: "Reading", shortName: nil, status: .notRead, codes: [],
                value: nil, detail: "Not read yet", date: nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !history.codes.isEmpty { codesSection }
                    SectionHeading("Readings", note: history.readings.count.description)
                        .padding(.top, 24)
                    ForEach(history.readings) { reading in
                        readingRow(reading)
                    }
                    if history.readings.isEmpty {
                        Text("Nothing has been read for this part of the car yet.")
                            .font(.callout)
                            .foregroundStyle(Palette.secondary)
                            .padding(.vertical, 14)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(20)
        }
        .frame(minWidth: 560, idealWidth: 720, minHeight: 460)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.name).font(.title2.weight(.bold))
                    if let shortName = row.shortName {
                        Text(shortName).font(.caption.monospaced()).foregroundStyle(
                            Palette.tertiary)
                    }
                }
                Spacer()
                if let explain, row.question != nil {
                    Button("Explain") { explain(row) }
                        .buttonStyle(.bordered)
                }
            }
            HStack(spacing: 12) {
                StatusWord(row: row, size: 20)
                readingText(row)
            }
            Text(row.detail).font(.callout).foregroundStyle(Palette.secondary)
            if let closedAt = session?.closedAt {
                Text(
                    "As of \(closedAt, format: .dateTime.month().day().year().hour().minute()), when this problem was \(session?.status == .archived ? "archived" : "resolved")"
                )
                .font(.caption)
                .foregroundStyle(Palette.tertiary)
            }
        }
        .padding(24)
        .background(Palette.base)
    }

    private var codesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading("Codes")
            ForEach(history.codes) { code in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(code.code).font(.body.monospaced().weight(.semibold))
                        if !code.present {
                            Text("Gone").foregroundStyle(Palette.pass).font(
                                .caption.weight(.semibold))
                        }
                    }
                    // On their own line: five flags beside the code don't fit the sheet.
                    FlowChips(flags: code.flags)
                    HStack(spacing: 8) {
                        Text("First seen \(code.firstSeen, format: .dateTime.month().day().year())")
                        if code.lastSeen != code.firstSeen {
                            Text(
                                "Last seen \(code.lastSeen, format: .dateTime.month().day().year())"
                            )
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(Palette.secondary)
                }
            }
        }
    }

    private func readingRow(_ reading: ReadingHistory.Reading) -> some View {
        let entry = vehicle.entry(for: reading)
        return VStack(alignment: .leading, spacing: 8) {
            Hairline()
            Button {
                if expanded.contains(reading.id) {
                    expanded.remove(reading.id)
                } else {
                    expanded.insert(reading.id)
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(reading.date, format: .dateTime.month().day().hour().minute())
                        .font(.caption.monospaced()).foregroundStyle(Palette.tertiary)
                    StatusWord(row: reading.row, size: 13)
                    readingText(reading.row)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.tertiary)
                        .rotationEffect(.degrees(expanded.contains(reading.id) ? 90 : 0))
                }
            }
            .buttonStyle(.plain)
            Text(reading.row.detail).font(.callout).foregroundStyle(Palette.secondary)
            if let entry, let problem = entry.session?.title {
                Chip(text: "For \(problem)")
            }
            if expanded.contains(reading.id), let entry, let result = entry.result {
                ResultDetail(
                    payload: result.payload, modules: vehicle.orderedModules,
                    reviewSurvey: { _ in })
            }
            if let entry {
                EntryFooter(
                    entry: entry,
                    showTranscript: {
                        dismiss()
                        showTranscript(entry)
                    },
                    showsStamp: true)
            }
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder private func readingText(_ row: SessionBoard.Row) -> some View {
        if !row.codes.isEmpty {
            Text(row.codes.joined(separator: " "))
                .font(.body.monospaced().weight(.semibold))
        } else if let value = row.value {
            Text(value).font(.body.monospaced().weight(.semibold))
        } else {
            Text("No codes").font(.callout).foregroundStyle(Palette.tertiary)
        }
    }
}
