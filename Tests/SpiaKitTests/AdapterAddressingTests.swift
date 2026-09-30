import SpiaKit
import Testing

@Suite("Adapter addressing")
struct AdapterAddressingTests {
    private static let module = DiagnosticJob.moduleDTCs(DemoGarage.airbag.target)

    @Test("an adapter check preserves addressing")
    func adapterCheckPreservesAddressing() {
        #expect(
            AdapterAddressing.moduleAddressed.state(after: .adapterCheck)
                == .moduleAddressed)
    }

    @Test("job sequences decide resets from the accumulated state")
    func sequences() {
        func fold(_ jobs: [DiagnosticJob]) -> [Bool] {
            var addressing = AdapterAddressing.postConnect
            return jobs.map { job in
                let reset = addressing.needsReinitialization(for: job)
                addressing = addressing.state(after: job)
                return reset
            }
        }

        #expect(fold([Self.module, .adapterCheck, .genericScan]) == [false, false, true])
        #expect(fold([Self.module, .genericScan, .vehicleInfo]) == [false, true, false])
        #expect(fold([.genericScan, Self.module, Self.module]) == [false, false, false])
    }

    @Test("a survey starts from the post-connect state and leaves the adapter on a module")
    func surveySequences() throws {
        let survey = DiagnosticJob.survey(
            try SurveyPlanner.plan(
                catalog: ModuleCatalog.bundled(), vehicle: nil, reachableBuses: [.highSpeed]))
        func fold(_ jobs: [DiagnosticJob]) -> [Bool] {
            var addressing = AdapterAddressing.postConnect
            return jobs.map { job in
                let reset = addressing.needsReinitialization(for: job)
                addressing = addressing.state(after: job)
                return reset
            }
        }

        #expect(fold([Self.module, survey]) == [false, true])
        #expect(fold([survey, .genericScan]) == [false, true])
        #expect(fold([survey, survey]) == [false, true])
        #expect(fold([survey, .adapterCheck, .vehicleInfo]) == [false, false, true])
        #expect(fold([survey, Self.module]) == [false, false])
    }
}
