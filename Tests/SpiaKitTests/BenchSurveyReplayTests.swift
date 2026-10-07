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
            "vlinker-fs-usb-only-search-skipped.txt", "vlinker-fs-usb-only-29bit-module-read.txt",
            "vlinker-fs-usb-only-monitor.txt",
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

    @Test("with no car, a survey that would search skips the search instead of failing")
    func searchSkippedWithoutACar() async throws {
        let saved = try JSONDecoder().decode(
            JobResult.self,
            from: Data(contentsOf: fixture("vlinker-fs-usb-only-search-skipped.result.json")))
        guard case .survey(let plan) = saved.job, case .survey(let report) = saved.payload else {
            Issue.record("the saved result isn't a survey")
            return
        }
        #expect(plan.search == .standard(over: .usbSerial))

        let (transport, connection) = try await connected("vlinker-fs-usb-only-search-skipped.txt")
        let runner = JobRunner(connection: connection)
        let events = await confirmPrompts(runner.run(.survey(plan)), runner: runner)
        let replayed = events.compactMap { event -> JobResult? in
            if case .completed(let result) = event { return result }
            return nil
        }
        #expect(replayed.first?.payload == saved.payload)
        #expect(await transport.isFinished)
        let prompts = events.compactMap { event -> UserAction? in
            if case .needsUser(_, let action) = event { return action }
            return nil
        }
        #expect(prompts == [.turnIgnitionOn, .turnIgnitionOn])

        // Nothing answered the opening, so the search neither asked the engine's RPM nor
        // listened, and the standard survey ran on to its first module.
        #expect(report.search?.stopReason == "No engine computer answered, so Spia didn't search.")
        #expect(report.search?.sweptCount == 0)
        let sent = try sent("vlinker-fs-usb-only-search-skipped.txt")
        #expect(!sent.contains("010C"))
        #expect(!sent.contains("ATMA"))
        #expect(report.stop?.candidate == plan.candidates[0])
        #expect(report.stop?.reason.contains("CAN bus error") == true)
    }

    @Test("the real STN1170 accepts every 29-bit command a module read sends")
    func extendedModuleRead() async throws {
        let target = try ModuleTarget(bus: .highSpeed, request: 0x18DA_30F1, response: 0x18DA_F130)
        let (transport, connection) = try await connected(
            "vlinker-fs-usb-only-29bit-module-read.txt")
        let events = await collect(JobRunner(connection: connection).run(.moduleDTCs(target)))
        // The job checks each setup command for the adapter's OK, so failing only at the read
        // means the adapter accepted the 29-bit protocol, header, filter, and flow control.
        let failure = try #require(events.compactMap(\.failure).first)
        #expect(failure.message.contains("CAN bus error"))
        #expect(!failure.reconnectRequired)
        #expect(await transport.isFinished)
        let planned = DiagnosticJob.moduleDTCs(target).plannedCommands
        #expect(
            try sent("vlinker-fs-usb-only-29bit-module-read.txt").suffix(planned.count) == planned)
        #expect(
            planned.suffix(9) == [
                "ATSP7", "ATST 64", "ATCFC 1", "ATSH 18DA30F1", "ATCRA 18DAF130", "ATFCSD 30 00 00",
                "ATFCSH 18DA30F1", "ATFCSM 1", "190209",
            ])
    }

    @Test("the real adapter's monitor stops on its deadline on a silent bus")
    func monitorOnASilentBus() async throws {
        let transport = try ReplayTransport(contentsOf: fixture("vlinker-fs-usb-only-monitor.txt"))
        let session = ELM327Session(transport: transport)
        _ = try await session.connect(protocol: .can11bit500k)
        let heard = Heard()
        try await session.monitor("ATMA", for: .milliseconds(300)) { _, event in
            await heard.add(event)
            return true
        }
        #expect(await heard.events.isEmpty)
        // The stop byte went out, and the adapter's STOPPED and prompt came back.
        #expect(await transport.isFinished)
        let recorded = try Transcript.decodeFile(
            String(contentsOf: fixture("vlinker-fs-usb-only-monitor.txt"), encoding: .utf8))
        #expect(recorded.last { $0.direction == .tx }?.bytes == [0x20])
        let lastReply = String(decoding: recorded.last?.bytes ?? [], as: UTF8.self)
        #expect(lastReply.hasPrefix("STOPPED"))
    }

    private actor Heard {
        var events: [MonitorEvent] = []
        func add(_ event: MonitorEvent) { events.append(event) }
    }
}
