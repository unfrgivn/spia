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
                        runner.requestSurvey()
                    },
                    searchMoreThoroughly: {
                        runner.reviewReport = nil
                        runner.requestSurvey(search: true)
                    })
            }
        }
    }
}
