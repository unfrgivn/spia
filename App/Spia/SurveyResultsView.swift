import SpiaKit
import SpiaStore
import SwiftUI

struct SurveyResultsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let report: SurveyReport
    let vehicle: Vehicle
    let searchMessage: String?
    let tryAgain: () -> Void
    let searchMoreThoroughly: () -> Void
    @State private var names: [ModuleTarget: String]
    @State private var kept: Set<ModuleTarget>
    @State private var error: String?
    @State private var showSearchConfirmation = false

    private let review: SurveyReview

    init(
        report: SurveyReport, vehicle: Vehicle, searchMessage: String? = nil,
        tryAgain: @escaping () -> Void = {}, searchMoreThoroughly: @escaping () -> Void = {}
    ) {
        self.report = report
        self.vehicle = vehicle
        self.searchMessage = searchMessage
        self.tryAgain = tryAgain
        self.searchMoreThoroughly = searchMoreThoroughly
        let review = SurveyReview(report: report)
        self.review = review
        _names = State(
            initialValue: Dictionary(
                review.rows.map { ($0.target, $0.proposedName) },
                uniquingKeysWith: { first, _ in first }))
        _kept = State(initialValue: Set(review.rows.map(\.target)))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let reason = report.search?.stopReason {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Spia didn't search")
                            .font(.headline)
                        Text(reason)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Try Again", action: searchMoreThoroughly)
                            .buttonStyle(.borderedProminent)
                    }
                    .foregroundStyle(Palette.primary)
                    .card(tint: Palette.caution)
                }
                Text(review.headline)
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(Palette.primary)
                if !review.notes.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(review.notes, id: \.self) { note in
                            Label(note, systemImage: "info.circle")
                                .foregroundStyle(Palette.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .card(tint: Palette.caution)
                    if review.canTryAgain {
                        Button("Try Again", action: tryAgain)
                            .buttonStyle(.borderedProminent)
                    }
                }
                if searchMessage != nil {
                    Button("Search More Thoroughly") { showSearchConfirmation = true }
                        .buttonStyle(.borderedProminent)
                }
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(review.rows.enumerated()), id: \.element.id) { index, row in
                        moduleRow(row)
                        if index < review.rows.count - 1 { Hairline() }
                    }
                }
                .card(tint: Palette.accent)
                if !review.unansweredLabels.isEmpty {
                    DisclosureGroup("Didn't answer (\(review.unansweredLabels.count))") {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(review.unansweredLabels, id: \.self) { label in
                                Text(label).foregroundStyle(Palette.secondary)
                            }
                        }
                        .padding(.top, 8)
                    }
                    .padding(.horizontal, 4)
                }
                HStack {
                    Button("Not Now") { dismiss() }
                        .buttonStyle(.bordered)
                    Spacer()
                    Button("Save Modules") { save() }
                        .buttonStyle(.borderedProminent)
                        .disabled(kept.isEmpty)
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Palette.base)
        .platformSheetFrame(width: 760, idealWidth: 820, minHeight: 620, idealHeight: 760)
        .errorAlert($error)
        .confirmationDialog(
            "Search More Thoroughly?", isPresented: $showSearchConfirmation,
            titleVisibility: .visible
        ) {
            Button("Search") { searchMoreThoroughly() }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let searchMessage { Text(searchMessage) }
        }
    }

    private func moduleRow(_ row: SurveyReview.Row) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle(
                "Keep \(row.proposedName)",
                isOn: Binding(
                    get: { kept.contains(row.target) },
                    set: { if $0 { kept.insert(row.target) } else { kept.remove(row.target) } })
            )
            .labelsHidden()
            .platformCheckboxToggle()
            .padding(.top, 2)
            VStack(alignment: .leading, spacing: 5) {
                TextField("Module name", text: nameBinding(for: row))
                    .textFieldStyle(.roundedBorder)
                Text(row.caption)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(
                        !row.confirmed && [.catalog, .saved].contains(row.nameSource)
                            ? Palette.caution : Palette.secondary)
                Text(row.codesSummary)
                    .font(.callout)
                    .foregroundStyle(Palette.primary)
            }
        }
        .padding(.vertical, 12)
    }

    private func nameBinding(for row: SurveyReview.Row) -> Binding<String> {
        Binding(
            get: { names[row.target, default: row.proposedName] },
            set: { names[row.target] = $0 })
    }

    private func save() {
        do {
            try model.garage.apply(review.choices(names: names, kept: kept), to: vehicle)
            dismiss()
        } catch {
            self.error = error.readable
        }
    }

}
