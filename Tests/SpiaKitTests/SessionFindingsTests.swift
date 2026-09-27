import Foundation
import Testing

@testable import SpiaKit

@Suite("What a session's results say about the car")
struct SessionFindingsTests {
    /// The demo car's checks, replayed from the recordings made on it.
    private func demoResults(_ jobs: [DiagnosticJob]) async throws -> [JobPayload] {
        let demo = DemoBackend()
        try await demo.connect()
        var results: [JobPayload] = []
        for job in jobs {
            let events = await collect(demo.run(job, transcript: nil))
            results += events.compactMap(\.result?.payload)
        }
        return results
    }

    @Test("nothing read yet is unknown, not healthy")
    func nothingRead() {
        let findings = SessionFindings(results: [])
        #expect(findings == SessionFindings(results: [], airbag: DemoGarage.airbag.target))
        #expect(findings.checkEngine == nil && findings.codes == nil && findings.voltage == nil)
        #expect(findings.checkEngineTone == .neutral)
        #expect(findings.codesTone == .neutral)
        #expect(findings.airbagTone == .neutral)
    }

    @Test("the Ghibli: engine clean, airbag and body computer holding codes, battery low")
    func ghibli() async throws {
        let results = try await demoResults([
            .adapterCheck, .genericScan, .moduleDTCs(DemoGarage.airbag.target),
            .moduleDTCs(DemoGarage.bodyComputer.target),
        ])
        let findings = SessionFindings(results: results, airbag: DemoGarage.airbag.target)

        #expect(findings.checkEngine == false)
        #expect(findings.checkEngineTone == .good)
        #expect(findings.airbagCodes == ["80011B", "80021B"])
        #expect(findings.airbagTone == .bad)
        #expect(findings.codes == ["100900", "80011B", "80021B"])
        #expect(findings.codesTone == .bad)
        #expect(findings.voltage == 11.7)
        #expect(ConnectionSummary.batteryTone(findings.voltage) == .bad)
    }

    @Test("a newer read of a module replaces the older one; a declined read doesn't")
    func newerReadWins() {
        let airbag = DemoGarage.airbag.target
        let faults = JobPayload.moduleDTCs(
            ModuleDTCs(
                target: airbag,
                outcome: .records(
                    availability: 0xFF, [ModuleDTCRecord(code: "80011B", status: 0x2F)]))
        )
        let cleared = JobPayload.moduleDTCs(
            ModuleDTCs(target: airbag, outcome: .records(availability: 0xFF, [])))
        let declined = JobPayload.moduleDTCs(
            ModuleDTCs(target: airbag, outcome: .negative(service: 0x19, code: 0x22)))

        let afterClear = SessionFindings(results: [faults, cleared], airbag: airbag)
        #expect(afterClear.airbagCodes == [])
        #expect(afterClear.codes == [])
        #expect(afterClear.airbagTone == .good)

        let afterDecline = SessionFindings(results: [faults, declined], airbag: airbag)
        #expect(afterDecline.airbagCodes == ["80011B"])
        #expect(afterDecline.codesTone == .bad)
    }

    @Test("a code stored and permanent in one scan counts once")
    func distinctCodes() {
        let readiness = Reading<Readiness>.value(Readiness(milOn: true, dtcCount: 1, monitors: []))
        let scan = ECUScan(
            ecu: 0x7E8, stored: .value(["P0301"]), pending: .value([]),
            permanent: .value(["P0301"]),
            readiness: readiness, freezeFrameDTC: .value(nil), freezeFrame: [])
        let findings = SessionFindings(results: [.genericScan([scan])])
        #expect(findings.codes == ["P0301"])
        #expect(findings.checkEngineTone == .bad)
    }

    @Test("battery reads low under 12 volts, the same line the connection text draws")
    func battery() {
        #expect(ConnectionSummary.batteryTone(nil) == .neutral)
        #expect(ConnectionSummary.batteryTone(11.7) == .bad)
        #expect(ConnectionSummary.batteryTone(12.6) == .good)
        #expect(ConnectionSummary.batteryTone(14.1) == .good)
    }
}
