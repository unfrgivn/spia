import Foundation
import OBDCore
import SpiaKit
import Testing

/// The thorough search, tested against what real cars actually sent. No search has been recorded
/// on a car yet, so the executor's sweep is covered up to the first command a recording lacks, and
/// its parts (listen, window, classifier, sweep list, estimate) on the Ghibli's bus capture and
/// the replies its modules gave.
@Suite("Thorough search")
struct ModuleSearchTests {
    private static let capture = "ghibli-ignition-on-capture-2s.txt"

    private static func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures").appendingPathComponent(name)
    }

    private static func transcript(_ name: String) throws -> [TranscriptEvent] {
        try Transcript.decodeFile(String(contentsOf: fixture(name), encoding: .utf8))
    }

    /// The frame on a recorded RX line that starts with `prefix`, so every frame tested here is
    /// one a car really sent.
    private static func recordedFrame(_ prefix: String, in name: String) throws -> CANFrame {
        let lines = try transcript(name).filter { $0.direction == .rx }
            .flatMap {
                String(decoding: $0.bytes, as: UTF8.self).split(whereSeparator: \.isNewline)
            }
            .map { $0.filter { !$0.isWhitespace } }
        let line = try #require(lines.first { $0.hasPrefix(prefix) })
        return try ELM327ResponseParser.frame(fromHex: line)
    }

    /// The capture's monitor stream as the session's parser reads it: every RX byte after `ATMA`
    /// until the stop.
    private static func captureEvents() throws -> [MonitorEvent] {
        let events = try transcript(capture)
        let start = try #require(
            events.firstIndex { $0.direction == .tx && $0.bytes == Array("ATMA\r".utf8) })
        var parser = MonitorStreamParser()
        var parsed: [MonitorEvent] = []
        for event in events[(start + 1)...] {
            if event.direction == .tx { break }
            parsed += parser.feed(event.bytes)
        }
        return parsed
    }

    private static func captureFrames() throws -> [CANFrame] {
        try captureEvents().compactMap { event in
            if case .frame(let frame) = event { return frame }
            return nil
        }
    }

    /// Through `ATCM 400` / `ATCF 400`: frames from 400 to 7FF.
    private static func inWindow(_ frame: CANFrame) -> Bool { frame.header & 0x400 == 0x400 }

    private static func ghibliPlan(search: ModuleSearch?) throws -> SurveyPlan {
        try SurveyPlanner.plan(
            catalog: ModuleCatalog.bundled(),
            vehicle: CatalogVehicle(make: "Maserati", model: "Ghibli", year: 2017),
            reachableBuses: [.highSpeed], search: search)
    }

    @Test("a module's TesterPresent answer counts, and nothing else on the bus does")
    func classifier() throws {
        // The airbag controller answering the survey's probe: `02 7E 00` from 4C4.
        #expect(
            SearchReplyClassifier.isTesterPresentReply(
                try Self.recordedFrame("4C4027E00", in: "ghibli-app-survey.txt")))
        // The CX-5's transmission refusing a ReadDataByIdentifier: a module, but not an answer to
        // TesterPresent.
        #expect(
            !SearchReplyClassifier.isTesterPresentReply(
                try Self.recordedFrame("7E9037F2231", in: "cx5-app-ble-survey.txt")))
        // The engine answering 09 00.
        #expect(
            !SearchReplyClassifier.isTesterPresentReply(
                try Self.recordedFrame("7E806490055401000", in: "ghibli-app-survey.txt")))
        // Ordinary traffic in the search window on the Ghibli's bus.
        let traffic = try #require(try Self.captureFrames().first { $0.header == 0x44A })
        #expect(!SearchReplyClassifier.isTesterPresentReply(traffic))
    }

    @Test("the reply window carries only network management on the Ghibli's busy bus")
    func window() throws {
        let frames = try Self.captureFrames()
        #expect(frames.count > 4_000)
        #expect(Set(frames.map(\.header)).count == 124)
        // Through the window: FCA's network management at 400 to 44C, about 11 frames a second,
        // and nothing at or above 600, where the sweep sends.
        let window = frames.filter(Self.inWindow)
        #expect(window.count == 23)
        #expect(
            Set(window.map(\.header)) == [
                0x400, 0x401, 0x402, 0x403, 0x407, 0x409, 0x422, 0x423, 0x44A, 0x44C,
            ])
        #expect(!frames.contains { $0.header >= 0x600 })
        let usb = ModuleSearch.standard(over: .usbSerial)
        #expect(window.count <= usb.maxListenFrames)
        #expect(window.count / 2 <= usb.busyLimitPerSecond)
    }

    @Test("listening through the window lets the Ghibli be searched; the whole bus wouldn't")
    func listen() throws {
        let events = try Self.captureEvents()
        // One in three of the Ghibli's frames comes flagged `<DATA ERROR` (not ISO-TP), which is
        // traffic, not trouble.
        #expect(events.contains(.message(.dataError)))
        var windowed = SearchListen(
            maxFrames: ModuleSearch.standard(over: .usbSerial).maxListenFrames)
        for event in events {
            if case .frame(let frame) = event, !Self.inWindow(frame) { continue }
            let listening = windowed.receive(event)
            #expect(listening)
        }
        #expect(windowed.reason == nil)
        #expect(windowed.heard.count == 10)

        var everything = SearchListen(
            maxFrames: ModuleSearch.standard(over: .usbSerial).maxListenFrames)
        var stopped = false
        for event in events {
            if !everything.receive(event) {
                stopped = true
                break
            }
        }
        #expect(stopped)
        #expect(everything.reason?.contains("busy") == true)
    }

    @Test("a probe's reply finds the module among the bus's traffic, and stops only on trouble")
    func reply() throws {
        let answer = "4C4027E00"
        let traffic = "403FD073FFFFFFFFFFF<DATA ERROR"
        _ = try Self.recordedFrame(answer, in: "ghibli-app-survey.txt")
        let rawTraffic = try Self.transcript(Self.capture).filter { $0.direction == .rx }
            .map { String(decoding: $0.bytes, as: UTF8.self) }.joined()
        #expect(rawTraffic.contains(traffic))

        let mixed = SearchReply(traffic + "\r" + answer + "\r")
        #expect(mixed.trouble == nil)
        #expect(mixed.testerPresentReplies == [0x4C4])
        #expect(SearchReply("NO DATA").testerPresentReplies.isEmpty)
        #expect(SearchReply("NO DATA").trouble == nil)
        #expect(SearchReply("CAN ERROR").trouble == .canError)
        #expect(SearchReply("BUFFER FULL").trouble == .bufferFull)
    }

    @Test("the monitor stops at its deadline and replays the Ghibli's capture through the session")
    func monitorDeadline() async throws {
        let transport = try ReplayTransport(contentsOf: Self.fixture(Self.capture))
        let session = ELM327Session(transport: transport)
        _ = try await session.connect(protocol: .can11bit500k)
        try await session.switchBaud(to: 2_000_000)
        let collected = Collected()
        try await session.monitor("ATMA", for: .seconds(2)) { _, event in
            await collected.add(event)
            return true
        }
        let frames = await collected.frames
        #expect(frames.count == (try Self.captureFrames()).count)
        #expect(Set(frames.map(\.header)).count == 124)
        #expect(await collected.messages.allSatisfy { $0 == .dataError })
        // The stop the session sent was the recorded space, and the adapter answered with its
        // prompt, so the session is usable again.
        let sent = try Self.transcript(Self.capture).filter { $0.direction == .tx }
        #expect(sent.contains { $0.bytes == [0x20] })
    }

    private actor Collected {
        var frames: [CANFrame] = []
        var messages: [ELM327AdapterMessage] = []

        func add(_ event: MonitorEvent) {
            switch event {
            case .frame(let frame): frames.append(frame)
            case .message(let message): messages.append(message)
            case .prompt, .unparsable: break
            }
        }
    }

    @Test(
        "the sweep skips the functional and legislated IDs, the plan's modules, and what it heard")
    func sweepList() throws {
        let search = ModuleSearch.standard(over: .usbSerial)
        let plan = try Self.ghibliPlan(search: search)
        let heard = Set(try Self.captureFrames().map(\.header).filter { $0 & 0x400 == 0x400 })
        let requests = search.sweepRequests(candidates: plan.candidates, heardIDs: heard)
        // 600-7FF is 512 IDs, less 7DF, 7E0-7E7, and the Ghibli's 12 other known modules from
        // 600 up: 620, 740, 742, 743, 744, 747, 749, 74B, 762, 763, 764, and 768.
        #expect(requests.count == 491)
        for skipped: UInt32 in [0x7DF, 0x7E0, 0x7E7, 0x744, 0x747, 0x620, 0x763, 0x740, 0x768] {
            #expect(!requests.contains(skipped))
        }
        #expect(requests.first == 0x600)
        #expect(requests.last == 0x7FF)
    }

    @Test("the estimate covers the listen and every address swept")
    func estimate() throws {
        let usb = ModuleSearch.standard(over: .usbSerial)
        let bluetooth = ModuleSearch.standard(over: .bluetooth)
        let candidates = try Self.ghibliPlan(search: usb).candidates
        #expect(usb.estimateMilliseconds(candidates: candidates) == 2_000 + 491 * 80)
        #expect(bluetooth.estimateMilliseconds(candidates: candidates) == 1_000 + 491 * 120)
        #expect(usb.replyTimeoutCommand == "ATST 0C")
        #expect(usb.maxListenFrames == 40)
        #expect(bluetooth.maxListenFrames == 20)
    }

    @Test("a search plan asks only the engine's RPM and TesterPresent beyond the survey")
    func allowlist() throws {
        let plan = try Self.ghibliPlan(search: .standard(over: .bluetooth))
        let survey = Set(try Self.ghibliPlan(search: nil).plannedRequests)
        let added = Set(plan.plannedRequests).subtracting(survey)
        #expect(added == ["010C"])
        #expect(plan.plannedRequests.contains("3E00"))
        let commands = Set(plan.plannedCommands)
        #expect(commands.isSuperset(of: ["ATCRA", "ATCM 400", "ATCF 400", "ATST 0C"]))
        // Nothing outside the read-only services, in any form.
        for request in plan.plannedRequests {
            let service = try #require(UInt8(request.prefix(2), radix: 16))
            #expect([0x01, 0x09, 0x19, 0x22, 0x3E].contains(service))
        }
    }

    @Test("old plans decode without a search")
    func oldPlans() throws {
        for name in ["ghibli-app-survey", "tiguan-app-survey", "cx5-app-ble-survey"] {
            let saved = try JSONDecoder().decode(
                JobResult.self,
                from: Data(contentsOf: Self.fixture("\(name).result.json")))
            guard case .survey(let plan) = saved.job else {
                Issue.record("\(name) isn't a survey")
                continue
            }
            #expect(plan.search == nil)
        }
    }

    @Test("the engine-off check comes right after the opening, before any module is probed")
    func gatePlacement() async throws {
        let plan = try Self.ghibliPlan(search: .standard(over: .usbSerial))
        let transport = try ReplayTransport(contentsOf: Self.fixture("ghibli-app-survey.txt"))
        let connection = ConnectionManager(
            adapter: AdapterDescriptor(kind: .usbSerial, displayName: "vLinker FS")
        ) { transport }
        try await connection.connect()
        let runner = JobRunner(connection: connection)
        var steps: [String] = []
        var failure: JobFailure?
        for await event in await runner.run(.survey(plan)) {
            switch event {
            case .needsUser(let id, _): await runner.confirm(id)
            case .step(let step): steps.append(step)
            case .failed(let value): failure = value
            default: break
            }
        }
        // The recording has the car's opening and the ignition prompt; RPM is the first thing
        // it never heard asked.
        #expect(!steps.contains { $0.hasPrefix("Looking for modules") })
        #expect(failure?.message.contains("010C") == true)
    }
}
