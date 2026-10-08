import SpiaKit
import SpiaStore
import SwiftUI

extension View {
    func surveyReview(
        runner: DiagnosticRunCoordinator?, vehicle: Vehicle?
    ) -> some View {
        sheet(
            isPresented: Binding(
                get: { runner?.reviewReport != nil },
                set: { if !$0 { runner?.reviewReport = nil } })
        ) {
            if let report = runner?.reviewReport, let runner, let vehicle {
                SurveyResultsView(
                    report: report, vehicle: vehicle,
                    searchMessage: runner.thoroughSearchMessage(for: report),
                    tryAgain: {
                        runner.reviewReport = nil
                        runner.scan()
                    },
                    searchMoreThoroughly: {
                        runner.reviewReport = nil
                        runner.scan(deep: true)
                    })
            }
        }
        .sheet(
            isPresented: Binding(
                get: { runner?.scanCutShortReason != nil },
                set: { if !$0 { runner?.scanCutShortReason = nil } })
        ) {
            if let reason = runner?.scanCutShortReason {
                ScanCutShortView(reason: reason) {
                    runner?.scanCutShortReason = nil
                    runner?.scan()
                }
            }
        }
    }
}

private struct ScanCutShortView: View {
    let reason: String
    let tryAgain: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("The scan was cut short")
                .font(.headline)
            Text(reason)
                .foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Not Now") { dismiss() }
                    .buttonStyle(.bordered)
                Button("Try Again") {
                    dismiss()
                    tryAgain()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .platformSheetFrame(width: 420, minHeight: 180)
    }
}
