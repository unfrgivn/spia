import SpiaKit
import Testing

@Suite("Scan phases")
struct ScanPhaseTests {
    @Test("every JobRunner step belongs to a phase")
    func runnerStepsHavePhases() {
        // Keep this list beside JobRunner.perform, whose comment points back here.
        let surveyPlan = SurveyPlan(
            catalogVersion: "test", vehicle: nil, platform: nil, candidates: [], unreachable: [])
        let steps: [(DiagnosticJob, String, ScanPhase)] = [
            (.adapterCheck, "Asking the adapter who it is", .adapter),
            (.vehicleInfo, "Requesting 010C", .car),
            (.survey(surveyPlan), "Asking the adapter who it is", .car),
            (.survey(surveyPlan), "Reading the car's voltage", .car),
            (.survey(surveyPlan), "Looking for modules: 1 of 1", .modules),
            (.survey(surveyPlan), "Looking again: 1 of 1", .modules),
            (.survey(surveyPlan), "Searching: 1 of 1", .modules),
            (.survey(surveyPlan), "Found a module at 744; asking what it is", .modules),
            (.survey(surveyPlan), "Airbag answered; asking what it is", .modules),
            (.survey(surveyPlan), "Reading trouble codes from module 744", .codes),
            (.genericScan, "Requesting 010C", .codes),
            (
                .moduleDTCs(DemoGarage.airbag.target), "Reading trouble codes from module 744",
                .codes
            ),
        ]
        for (job, step, expected) in steps {
            #expect(ScanPhase.current(for: job, step: step) == expected)
        }
    }
}
