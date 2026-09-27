import Foundation
import Testing

@testable import SpiaKit

@Suite("Results read as what they mean for the car")
struct ResultReadingTests {
    private func demoResult(_ job: DiagnosticJob) async throws -> JobPayload {
        let demo = DemoBackend()
        try await demo.connect()
        let events = await collect(demo.run(job, transcript: nil))
        return try #require(events.compactMap(\.result?.payload).first)
    }

    private func name(_ target: ModuleTarget) -> String {
        DemoGarage.modules.first { $0.target == target }?.label ?? "Module"
    }

    @Test("the Ghibli's scans: engine clean, airbag with two codes, ABS clean")
    func ghibli() async throws {
        let engine = try #require(
            ResultReading(try await demoResult(.genericScan), moduleName: name))
        #expect(engine == ResultReading(.good, "Engine and transmission: no trouble codes"))

        let airbag = try #require(
            ResultReading(
                try await demoResult(.moduleDTCs(DemoGarage.airbag.target)), moduleName: name))
        #expect(airbag == ResultReading(.bad, "Airbag controller (ORC): 2 trouble codes"))

        let abs = try #require(
            ResultReading(
                try await demoResult(.moduleDTCs(DemoGarage.abs.target)), moduleName: name))
        #expect(abs == ResultReading(.good, "ABS: no trouble codes"))
    }

    @Test("a declined read and a lit lamp without codes are named, not called healthy")
    func unhealthyWithoutCodes() {
        let declined = JobPayload.moduleDTCs(
            ModuleDTCs(target: DemoGarage.abs.target, outcome: .negative(service: 0x19, code: 0x22))
        )
        #expect(
            ResultReading(declined, moduleName: name)
                == ResultReading(.attention, "ABS didn't give its codes"))

        let readiness = Reading<Readiness>.value(Readiness(milOn: true, dtcCount: 0, monitors: []))
        let lamp = ECUScan(
            ecu: 0x7E8, stored: .value([]), pending: .value([]), permanent: .value([]),
            readiness: readiness, freezeFrameDTC: .value(nil), freezeFrame: [])
        #expect(
            ResultReading(.genericScan([lamp]), moduleName: name)
                == ResultReading(.bad, "Engine and transmission: check-engine light on"))
    }

    @Test("the adapter check isn't a reading about the car")
    func notAboutTheCar() async throws {
        #expect(ResultReading(try await demoResult(.adapterCheck), moduleName: name) == nil)
    }

    @Test("status bytes read as one line, and as a lamp")
    func status() {
        // The body computer's code on the Ghibli: 0x2B, with 0xFB supported.
        #expect(DTCStatus.summary(for: 0x2B, availability: 0xFB) == "Failing now · Confirmed")
        #expect(DTCStatus.summary(for: 0x06) == "Failed this drive cycle · Pending")
        #expect(DTCStatus.tone(for: 0x2B, availability: 0xFB) == .bad)
        #expect(DTCStatus.tone(for: 0x04) == .attention)
        #expect(DTCStatus.summary(for: 0x50) == "Not active now")
        #expect(DTCStatus.tone(for: 0x50) == .neutral)
    }
}
