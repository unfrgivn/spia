import Foundation
import OBDCore
import SpiaKit
import Testing

@Suite("USB bench survey replay")
struct BenchSurveyReplayTests {
    private let adapter = AdapterDescriptor(kind: .usbSerial, displayName: "vLinker FS")

    private func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures").appendingPathComponent(name)
    }

    private func connected(_ name: String) async throws -> (ReplayTransport, ConnectionManager) {
        let transport = try ReplayTransport(contentsOf: fixture(name))
        let connection = ConnectionManager(adapter: adapter) { transport }
        try await connection.connect()
        return (transport, connection)
    }

    private func sent(_ name: String) throws -> [String] {
        try Transcript.decodeFile(String(contentsOf: fixture(name), encoding: .utf8))
            .filter { $0.direction == .tx }
            .map { String(decoding: $0.bytes.dropLast(), as: UTF8.self) }
    }

    private func collect(_ stream: AsyncStream<JobEvent>) async -> [JobEvent] {
        var events: [JobEvent] = []
        for await event in stream { events.append(event) }
        return events
    }

    private func confirmPrompts(
        _ events: AsyncStream<JobEvent>, runner: JobRunner
    ) async -> [JobEvent] {
        var collected: [JobEvent] = []
        for await event in events {
            collected.append(event)
            if case .needsUser(let id, _) = event { await runner.confirm(id) }
        }
        return collected
    }

    @Test("every USB bench transcript starts with adapter reset")
    func transcriptPrefixes() throws {
        for name in [
            "vlinker-fs-usb-only-probe.txt", "vlinker-fs-usb-only-airbag-read.txt",
            "vlinker-fs-usb-only-survey.txt", "vlinker-fs-usb-only-scan-after-module.txt",
        ] {
            #expect(try sent(name).first == "ATZ")
        }
    }

    @Test("the real USB airbag read stops on CAN ERROR without requiring reconnect")
    func airbagRead() async throws {
        let (transport, connection) = try await connected("vlinker-fs-usb-only-airbag-read.txt")
        let events = await collect(
            JobRunner(connection: connection).run(.moduleDTCs(DemoGarage.airbag.target)))
        let failure = try #require(events.compactMap(\.failure).first)
        #expect(failure.message.contains("CAN bus error"))
        #expect(!failure.reconnectRequired)
        #expect(await connection.state.status != nil)
        #expect(await transport.isFinished)

        let planned = DiagnosticJob.moduleDTCs(DemoGarage.airbag.target).plannedCommands
        #expect(try sent("vlinker-fs-usb-only-airbag-read.txt").suffix(planned.count) == planned)
        #expect(
            try Transcript.decodeFile(
                String(contentsOf: fixture("vlinker-fs-usb-only-airbag-read.txt"), encoding: .utf8)
            )
            .first?.bytes == Array("ATZ\r".utf8))
    }

    @Test("the real USB survey continues past silent engine computers and stops at CAN ERROR")
    func survey() async throws {
        let plan = try JSONDecoder().decode(
            SurveyPlan.self,
            from: Data(contentsOf: fixture("vlinker-fs-usb-only-survey.plan.json")))
        #expect(plan.candidates.count == 12)
        #expect(plan.candidates.first?.target == DemoGarage.airbag.target)

        let (transport, connection) = try await connected("vlinker-fs-usb-only-survey.txt")
        let runner = JobRunner(connection: connection)
        let events = await confirmPrompts(runner.run(.survey(plan)), runner: runner)
        let report = try #require(
            events.compactMap { event -> SurveyReport? in
                guard case .completed(let result) = event, case .survey(let report) = result.payload
                else {
                    return nil
                }
                return report
            }.first)
        #expect(report.vehicleInfo.isEmpty)
        #expect(report.modules.isEmpty)
        #expect(report.unanswered.isEmpty)
        #expect(report.stop?.candidate == plan.candidates[0])
        #expect(report.stop?.reason.contains("CAN bus error") == true)
        #expect(report.notProbed.count == 11)
        #expect(events.contains(.warning("The engine computers didn't answer.")))
        #expect(
            ResultText.summary(
                JobResult(
                    job: .survey(plan), payload: .survey(report), source: .live, transcript: nil))
                == "The engine computers didn't answer. No modules answered. Stopped at Airbag controller (ORC) (744): adapter reported: CAN bus error. 11 not asked."
        )
        #expect(await transport.isFinished)

        let commands = plan.commands(for: plan.candidates[0])
        let expected =
            ["ATRV", "0900", "0900", "0900"]
            + commands.setup + commands.headers + [commands.probe]
        #expect(try sent("vlinker-fs-usb-only-survey.txt").suffix(expected.count) == expected)
        #expect(
            try Transcript.decodeFile(
                String(contentsOf: fixture("vlinker-fs-usb-only-survey.txt"), encoding: .utf8)
            )
            .first?.bytes == Array("ATZ\r".utf8))
    }

    @Test("the scan after the survey's module addressing reset still reaches its prompts")
    func scanAfterModuleRead() async throws {
        let (transport, connection) = try await connected(
            "vlinker-fs-usb-only-scan-after-module.txt")
        let runner = JobRunner(connection: connection)
        let events = await confirmPrompts(runner.run(.genericScan), runner: runner)
        let failure = try #require(events.compactMap(\.failure).first)
        #expect(failure.message.contains("no ECU answered"))
        #expect(!failure.reconnectRequired)
        #expect(await transport.isFinished)
        #expect(try sent("vlinker-fs-usb-only-scan-after-module.txt").first == "ATZ")
    }
}
