import Foundation
import Testing

@testable import SpiaKit

@Suite("Reading history")
struct ReadingHistoryTests {
    private let modules = DemoGarage.modules.map {
        SessionBoard.Module(label: $0.label, target: $0.target)
    }

    private func demoResult(_ job: DiagnosticJob) async throws -> JobPayload {
        let demo = DemoBackend()
        try await demo.connect()
        let events = await collect(demo.run(job, transcript: nil))
        guard let payload = events.compactMap(\.result?.payload).first else {
            throw CocoaError(.coderValueNotFound)
        }
        return payload
    }

    @Test("a module keeps code lifetimes and flags across reads")
    func moduleLifetime() async throws {
        let payload = try await demoResult(.moduleDTCs(DemoGarage.airbag.target))
        let first = SessionBoard.Result(date: Date(timeIntervalSince1970: 10), payload: payload)
        let second = SessionBoard.Result(date: Date(timeIntervalSince1970: 20), payload: payload)
        let history = ReadingHistory(
            subject: .module(DemoGarage.airbag.target), modules: modules,
            results: [(UUID(), first), (UUID(), second)])
        #expect(history.readings.count == 2)
        #expect(
            history.readings.map(\.row.codes) == [["80011B", "80021B"], ["80011B", "80021B"]])
        #expect(history.codes.map(\.code) == ["80011B", "80021B"])
        #expect(history.codes.allSatisfy { $0.readings == 2 && $0.present })
        #expect(history.codes.first?.flags.isEmpty == false)
    }

    @Test("a cleared result makes codes gone, but a negative result does not")
    func goneAndNegative() {
        let target = DemoGarage.airbag.target
        let records = JobPayload.moduleDTCs(
            ModuleDTCs(
                target: target,
                outcome: .records(
                    availability: 0xFF,
                    [ModuleDTCRecord(code: "80011B", status: 0x89)])))
        let clear = JobPayload.moduleDTCs(
            ModuleDTCs(target: target, outcome: .records(availability: 0xFF, [])))
        let negative = JobPayload.moduleDTCs(
            ModuleDTCs(target: target, outcome: .negative(service: 0x19, code: 0x22)))
        let gone = ReadingHistory(
            subject: .module(target), modules: modules,
            results: [
                (
                    UUID(),
                    SessionBoard.Result(date: Date(timeIntervalSince1970: 1), payload: records)
                ),
                (UUID(), SessionBoard.Result(date: Date(timeIntervalSince1970: 2), payload: clear)),
            ])
        let stillPresent = ReadingHistory(
            subject: .module(target), modules: modules,
            results: [
                (
                    UUID(),
                    SessionBoard.Result(date: Date(timeIntervalSince1970: 1), payload: records)
                ),
                (
                    UUID(),
                    SessionBoard.Result(date: Date(timeIntervalSince1970: 2), payload: negative)
                ),
            ])
        #expect(gone.codes.first?.present == false)
        #expect(gone.codes.first?.lastSeen == Date(timeIntervalSince1970: 1))
        #expect(stillPresent.codes.first?.present == true)
    }

    @Test("engine and battery readings use their board rows")
    func engineAndBattery() async throws {
        let scan = try await demoResult(.genericScan)
        let adapter = try await demoResult(.adapterCheck)
        let engine = ReadingHistory(
            subject: .engine, modules: modules,
            results: [(UUID(), SessionBoard.Result(date: .now, payload: scan))])
        let battery = ReadingHistory(
            subject: .battery, modules: modules,
            results: [(UUID(), SessionBoard.Result(date: .now, payload: adapter))])
        #expect(engine.readings.count == 1)
        #expect(engine.codes.isEmpty)
        #expect(battery.readings.first?.row.value != nil)
    }

    @Test("a subject with no results has no history")
    func empty() {
        let history = ReadingHistory(subject: .battery, modules: modules, results: [])
        #expect(history.readings.isEmpty)
        #expect(history.codes.isEmpty)
    }
}
