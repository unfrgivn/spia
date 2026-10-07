import CryptoKit
import Foundation
import OBDCore
import SpiaKit
import Testing

/// Every test here runs real recordings from the car or the bench. Nothing is simulated.
@Suite("SpiaKit engine")
struct SpiaKitTests {
    private static let airbag = DemoGarage.airbag.target

    private func connected(_ recording: DemoRecording) async throws -> (
        ReplayTransport, ConnectionManager
    ) {
        let transport = try ReplayTransport(contentsOf: recording.url())
        let connection = ConnectionManager(adapter: DemoGarage.adapter) { transport }
        try await connection.connect()
        return (transport, connection)
    }

    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("spia-tests-\(UUID().uuidString)")
            .appendingPathComponent("transcript.txt")
    }

    private func sameWireEvents(_ first: [TranscriptEvent], _ second: [TranscriptEvent]) -> Bool {
        first.count == second.count
            && zip(first, second).allSatisfy {
                $0.0.direction == $0.1.direction && $0.0.bytes == $0.1.bytes
            }
    }

    @Test("adapter addressing decisions cover every job from both states")
    func adapterAddressing() {
        let survey = DiagnosticJob.survey(
            SurveyPlan(
                catalogVersion: "test", vehicle: nil, platform: nil, candidates: [],
                unreachable: []))
        let cases: [(job: DiagnosticJob, needsPostConnect: Bool, leavesModule: Bool)] = [
            (.adapterCheck, false, false),
            (.vehicleInfo, true, false),
            (.genericScan, true, false),
            (survey, true, true),
            (.moduleDTCs(Self.airbag), false, true),
        ]
        for (job, needsPostConnect, leavesModule) in cases {
            #expect(!AdapterAddressing.postConnect.needsReinitialization(for: job))
            #expect(
                AdapterAddressing.moduleAddressed.needsReinitialization(for: job)
                    == needsPostConnect)
            #expect(
                AdapterAddressing.postConnect.state(after: job)
                    == (leavesModule ? .moduleAddressed : .postConnect))
            // An adapter check leaves the addressing as it found it.
            #expect(
                AdapterAddressing.moduleAddressed.state(after: job)
                    == (leavesModule || job == .adapterCheck ? .moduleAddressed : .postConnect))
        }
    }

    @Test("bundled demo recordings are byte-identical to the test fixtures")
    func recordingsMatchFixtures() throws {
        let fixtures = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(
                "Fixtures")
        for recording in DemoRecording.allCases {
            let bundled = try Data(contentsOf: recording.url())
            let original = try Data(
                contentsOf: fixtures.appendingPathComponent("\(recording.rawValue).txt"))
            #expect(bundled == original, "\(recording.rawValue) differs from Tests/Fixtures")
        }
    }

    @Test("airbag module read replays the car session byte for byte and saves a transcript")
    func airbagModuleRead() async throws {
        let (transport, connection) = try await connected(.airbagCodes)
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let events = await collect(
            JobRunner(connection: connection).run(.moduleDTCs(Self.airbag), transcript: url))

        #expect(events.first == .started(.moduleDTCs(Self.airbag)))
        let result = try #require(events.compactMap(\.result).first)
        #expect(
            result.payload
                == .moduleDTCs(
                    ModuleDTCs(
                        target: Self.airbag,
                        outcome: .records(
                            availability: 0xCF,
                            [
                                ModuleDTCRecord(code: "80011B", status: 0x8F),
                                ModuleDTCRecord(code: "80021B", status: 0x8F),
                            ]))))
        #expect(await transport.isFinished)
        #expect(await connection.state.status?.voltage == 14.3)

        // The transcript holds initialization followed by the check, exactly as sent on the car.
        let recorded = try Transcript.decodeFile(String(contentsOf: url, encoding: .utf8))
        let sent = recorded.filter { $0.direction == .tx }.map {
            String(decoding: $0.bytes.dropLast(), as: UTF8.self)
        }
        let planned = DiagnosticJob.moduleDTCs(Self.airbag).plannedCommands
        #expect(Array(sent.suffix(planned.count)) == planned)
        let onCar = try DemoRecording.airbagCodes.events().filter { $0.direction == .tx }
            .map { String(decoding: $0.bytes.dropLast(), as: UTF8.self) }
        #expect(sent == onCar)

        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(
            result.transcript
                == TranscriptReference(
                    fileName: "transcript.txt", byteCount: data.count, sha256: digest))
    }

    @Test("airbag transcript includes initialization and replays standalone")
    func airbagTranscriptRoundTrip() async throws {
        let (_, connection) = try await connected(.airbagCodes)
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let events = await collect(
            JobRunner(connection: connection).run(.moduleDTCs(Self.airbag), transcript: url))
        #expect(events.compactMap(\.result).first?.payload != nil)
        let saved = try Transcript.decodeFile(String(contentsOf: url, encoding: .utf8))
        let original = try DemoRecording.airbagCodes.events()
        #expect(sameWireEvents(saved, original))
        #expect(saved.first?.direction == .tx)
        #expect(saved.first?.bytes == Array("ATZ\r".utf8))
        #expect(
            zip(saved, saved.dropFirst()).allSatisfy {
                $0.0.milliseconds <= $0.1.milliseconds
            })

        let replay = try ReplayTransport(contentsOf: url)
        let fresh = ConnectionManager(adapter: DemoGarage.adapter) { replay }
        try await fresh.connect()
        let replayEvents = await collect(
            JobRunner(connection: fresh).run(.moduleDTCs(Self.airbag)))
        #expect(
            replayEvents.compactMap(\.result).first?.payload
                == events.compactMap(\.result).first?.payload)
        #expect(await replay.isFinished)
    }

    @Test("adapter check transcript stops before the trailing generic probe")
    func adapterCheckTranscriptRoundTrip() async throws {
        let (_, connection) = try await connected(.adapterProbe)
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        _ = await collect(JobRunner(connection: connection).run(.adapterCheck, transcript: url))
        let saved = try Transcript.decodeFile(String(contentsOf: url, encoding: .utf8))
        let original = try DemoRecording.adapterProbe.events()
        let trailing = try #require(
            original.firstIndex {
                $0.direction == .tx && String(decoding: $0.bytes, as: UTF8.self) == "0100\r"
            })
        #expect(sameWireEvents(saved, Array(original[..<trailing])))
        #expect(saved.first?.direction == .tx)
        #expect(saved.first?.bytes == Array("ATZ\r".utf8))
        #expect(
            zip(saved, saved.dropFirst()).allSatisfy {
                $0.0.milliseconds <= $0.1.milliseconds
            })

        let replay = try ReplayTransport(contentsOf: url)
        let fresh = ConnectionManager(adapter: DemoGarage.adapter) { replay }
        try await fresh.connect()
        let replayEvents = await collect(JobRunner(connection: fresh).run(.adapterCheck))
        #expect(replayEvents.compactMap(\.result).first?.payload != nil)
        #expect(await replay.isFinished)
    }

    @Test("adapter check reads firmware, hardware, and the car's voltage into the connection state")
    func adapterCheck() async throws {
        let (_, connection) = try await connected(.adapterProbe)
        let events = await collect(JobRunner(connection: connection).run(.adapterCheck))
        let expected = AdapterStatus(
            identity: "ELM327 v2.3", firmware: "STN1170 v4.3.2", hardware: "vLinker FS r2",
            voltage: 11.7)
        #expect(events.compactMap(\.result).first?.payload == .adapter(expected))
        #expect(await connection.state == .ready(expected))
    }

    @Test("no car answering pauses for the user; cancelling there leaves the adapter usable")
    func cancelAtIgnitionPrompt() async throws {
        let (_, connection) = try await connected(.adapterWithoutCar)
        _ = await collect(JobRunner(connection: connection).run(.adapterCheck))
        let runner = JobRunner(connection: connection)

        var events: [JobEvent] = []
        for await event in await runner.run(.genericScan) {
            events.append(event)
            if case .needsUser(_, .turnIgnitionOn) = event { await runner.cancel() }
        }

        #expect(
            events.contains { if case .needsUser(_, .turnIgnitionOn) = $0 { true } else { false } })
        let failure = try #require(events.compactMap(\.failure).first)
        #expect(failure.cancelled)
        #expect(!failure.reconnectRequired)
        #expect(await connection.state.status != nil)
    }

    @Test("confirming the prompt retries; running past the recording requires a reconnect")
    func confirmAtIgnitionPrompt() async throws {
        let (_, connection) = try await connected(.adapterWithoutCar)
        _ = await collect(JobRunner(connection: connection).run(.adapterCheck))
        let runner = JobRunner(connection: connection)

        var events: [JobEvent] = []
        for await event in await runner.run(.genericScan) {
            events.append(event)
            if case .needsUser(let id, _) = event { await runner.confirm(id) }
        }

        #expect(events.contains { if case .userConfirmed = $0 { true } else { false } })
        let failure = try #require(events.compactMap(\.failure).first)
        #expect(failure.reconnectRequired)
        #expect(!failure.cancelled)
        if case .reconnectRequired = await connection.state {
        } else {
            Issue.record("connection should require a reconnect")
        }
    }

    @Test("a second check is refused while one is running")
    func oneCheckAtATime() async throws {
        let (_, connection) = try await connected(.adapterWithoutCar)
        _ = await collect(JobRunner(connection: connection).run(.adapterCheck))
        let runner = JobRunner(connection: connection)
        let first = await runner.run(.genericScan)
        var iterator = first.makeAsyncIterator()
        while let event = await iterator.next() {
            if case .needsUser = event { break }
        }

        let second = await collect(runner.run(.vehicleInfo))
        #expect(second.compactMap(\.failure).first?.message == ConnectionError.busy.description)

        await runner.cancel()
        while await iterator.next() != nil {}
    }

    @Test("results round-trip through JSON and a future schema is refused")
    func resultCoding() throws {
        let result = JobResult(
            job: .moduleDTCs(Self.airbag),
            payload: .moduleDTCs(
                ModuleDTCs(target: Self.airbag, outcome: .negative(service: 0x19, code: 0x22))),
            source: .recording("ghibli-orc-flowcontrol"), transcript: nil)
        let data = try JSONEncoder().encode(result)
        #expect(try JSONDecoder().decode(JobResult.self, from: data) == result)

        let future = try #require(String(data: data, encoding: .utf8))
            .replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":2")
        #expect(throws: JobResult.DecodingFailure.unsupportedSchemaVersion(2)) {
            try JSONDecoder().decode(JobResult.self, from: Data(future.utf8))
        }
        let liveJSON =
            #"{"schemaVersion":1,"job":{"genericScan":{}},"payload":{"genericScan":{"_0":[]}},"source":{"live":{}}}"#
        let decodedLive = try JSONDecoder().decode(JobResult.self, from: Data(liveJSON.utf8))
        #expect(decodedLive.source == .live)
        let replay = JobResult(
            job: .genericScan, payload: .genericScan([]),
            source: .replay(recorded: Date(timeIntervalSince1970: 1_700_000_000)), transcript: nil)
        #expect(
            try JSONDecoder().decode(JobResult.self, from: JSONEncoder().encode(replay)) == replay)
    }

    @Test("no check can send a service that changes the car")
    func readOnlyAllowlist() throws {
        // Clear DTCs, session control, reset, security access, write, routine, I/O control,
        // communication control, DTC setting, tester-present-driven session keeping aside.
        let forbidden: Set<UInt8> = [
            0x04, 0x10, 0x11, 0x14, 0x27, 0x28, 0x2E, 0x2F, 0x31, 0x3B, 0x85,
        ]
        var jobs: [DiagnosticJob] = [.adapterCheck, .vehicleInfo, .genericScan]
        jobs += DemoGarage.modules.map { .moduleDTCs($0.target) }
        let bundled = try ModuleCatalog.bundled()
        jobs += try bundled.makes.flatMap { make in
            try make.platforms.map { platform in
                .survey(
                    try SurveyPlanner.plan(
                        catalog: bundled,
                        vehicle: CatalogVehicle(
                            make: make.make, model: platform.models[0], year: platform.firstYear),
                        reachableBuses: [.highSpeed, .mediumSpeed]))
            }
        }
        jobs.append(
            .moduleDTCs(
                try ModuleTarget(
                    bus: .mediumSpeed, request: 0x7BF, response: 0x53F, statusMask: 0xFF)))
        for job in jobs {
            for command in job.plannedCommands
            where command != "ATRV" && !command.hasPrefix("AT") && !command.hasPrefix("ST") {
                let service = try #require(
                    UInt8(command.prefix(2), radix: 16), "\(command) is not hex")
                #expect(!forbidden.contains(service), "\(job.id) would send \(command)")
            }
        }
    }

    @Test("module targets validate standard and extended CAN addresses")
    func moduleTargetValidation() throws {
        #expect(throws: ModuleTarget.Invalid.mixedAddressWidth(request: 0x800, response: 0x4C4)) {
            try ModuleTarget(bus: .highSpeed, request: 0x800, response: 0x4C4)
        }
        #expect(throws: ModuleTarget.Invalid.functionalBroadcast) {
            try ModuleTarget(bus: .highSpeed, request: 0x7DF, response: 0x7E8)
        }
        #expect(throws: ModuleTarget.Invalid.sameRequestAndResponse) {
            try ModuleTarget(bus: .highSpeed, request: 0x744, response: 0x744)
        }
        let extended = try ModuleTarget(
            bus: .highSpeed, request: 0x18DA30F1, response: 0x18DAF130)
        #expect(extended.isExtended)
        #expect(throws: ModuleTarget.Invalid.extendedOnMediumSpeed) {
            try ModuleTarget(bus: .mediumSpeed, request: 0x18DA30F1, response: 0x18DAF130)
        }
        #expect(throws: ModuleTarget.Invalid.extendedFunctionalBroadcast) {
            try ModuleTarget(bus: .highSpeed, request: 0x18DB33F1, response: 0x18DAF133)
        }
        #expect(throws: ModuleTarget.Invalid.invalidCANID(0x20000000)) {
            try ModuleTarget(bus: .highSpeed, request: 0x20000000, response: 0x18DAF130)
        }
    }

    @Test("29-bit module commands select protocol 7 and eight-digit headers")
    func extendedModuleCommands() throws {
        let target = try ModuleTarget(
            bus: .highSpeed, request: 0x18DA30F1, response: 0x18DAF130)
        #expect(target.setupCommands == ["ATSP7", "ATST 64", "ATCFC 1"])
        #expect(
            target.headerCommands == [
                "ATSH 18DA30F1", "ATCRA 18DAF130", "ATFCSD 30 00 00", "ATFCSH 18DA30F1",
                "ATFCSM 1",
            ])
        let plan = SurveyPlan(
            catalogVersion: "test", vehicle: nil, platform: nil,
            candidates: [SurveyCandidate(target: target, origin: .discovered)], unreachable: [])
        #expect(plan.commands(for: plan.candidates[0]).setup.first == "ATSP7")
        #expect(plan.plannedCommands.contains("ATSH 18DA30F1"))
    }

    @Test("connection state is delivered to every observer")
    func stateObservers() async throws {
        let transport = try ReplayTransport(contentsOf: DemoRecording.adapterWithoutCar.url())
        let connection = ConnectionManager(adapter: DemoGarage.adapter) { transport }
        let first = await connection.states()
        let second = await connection.states()
        try await connection.connect()
        await connection.disconnect()
        let expected: [ConnectionState] = [
            .disconnected, .connecting, .ready(AdapterStatus(identity: "ELM327 v2.3")),
            .disconnected,
        ]
        #expect(await prefix(first, expected.count) == expected)
        #expect(await prefix(second, expected.count) == expected)
    }

    @Test("status bits read as plain English, limited to what the module supports")
    func statusFlags() {
        let labels = DTCStatus.flags(for: 0x8F, availability: 0xCF).map(\.label)
        #expect(
            labels == [
                "Failing now", "Failed this drive cycle", "Pending", "Confirmed",
                "Warning lamp requested",
            ])
        #expect(
            DTCStatus.flags(for: 0x2B, availability: 0x0B).map(\.label) == [
                "Failing now", "Failed this drive cycle", "Confirmed",
            ])
    }

    @Test("errors read plainly: Spia's by their description, the system's by their localized one")
    func readableErrors() {
        #expect(
            DemoError.missingRecording("x").readable
                == "the demo recording x is missing from the app")
        let missing = CocoaError(.fileReadNoSuchFile)
        #expect(missing.readable == missing.localizedDescription)
        #expect(!missing.readable.contains("Domain="))
        struct Shape: Decodable { let volts: Double }
        let decoding = #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Shape.self, from: Data(#"{"volts":"high"}"#.utf8))
        }
        #expect(decoding?.readable == decoding?.localizedDescription)
        #expect(decoding?.readable.contains("typeMismatch") == false)
        #expect(CancellationError().readable == "Cancelled")
    }

    @Test("voltage explains whether the adapter is really in a car")
    func voltageWording() {
        #expect(ConnectionSummary.voltageText(nil).hasPrefix("No power from the car"))
        #expect(ConnectionSummary.voltageText(11.7) == "11.7 V, battery low")
        #expect(ConnectionSummary.voltageText(14.3).contains("charging"))
        #expect(ConnectionSummary.voltageText(12.6) == "12.6 V")
    }

    @Test("demo and replay connection summaries do not present saved voltage as current")
    func recordedConnectionWording() {
        let status = AdapterStatus(
            identity: "ELM327 v2.3", firmware: "STN1170 v4.3.2", hardware: "vLinker FS r2",
            voltage: 14.3)
        for kind in [ConnectionKind.demo, .replay] {
            let summary = ConnectionSummary(
                adapter: AdapterDescriptor(kind: kind, displayName: "recording"),
                state: .ready(status))
            #expect(summary.detail.contains("not a live car reading"))
            #expect(!summary.detail.contains("14.3 V"))
            #expect(!summary.detail.contains("No power from the car"))
        }
    }
}

@Suite("Demo car")
struct DemoBackendTests {
    private func run(_ job: DiagnosticJob, on demo: DemoBackend) async -> [JobEvent] {
        await collect(demo.run(job, transcript: nil))
    }

    @Test("demo refuses a survey because it has no survey recording")
    func surveyUnavailable() async {
        let demo = DemoBackend()
        try? await demo.connect()
        let plan = SurveyPlan(
            catalogVersion: "test", vehicle: nil, platform: nil, candidates: [], unreachable: [])
        #expect(!demo.canRun(.survey(plan)))
        let events = await run(.survey(plan), on: demo)
        #expect(events.compactMap(\.failure).first?.message.contains("car survey") == true)
    }

    @Test("connecting replays the recorded adapter check")
    func connect() async throws {
        let demo = DemoBackend()
        try await demo.connect()
        let state = await prefix(demo.states(), 1).first
        #expect(state?.status?.firmware == "STN1170 v4.3.2")
        #expect(state?.status?.voltage == 11.7)
    }

    @Test("recorded connection waits for the adapter's real response latency")
    func recordedConnectionTiming() async throws {
        let events = try DemoRecording.adapterProbe.events()
        let immediateTransport = ReplayTransport(events: events)
        let immediate = ConnectionManager(adapter: DemoGarage.adapter) { immediateTransport }
        try await immediate.connect()

        let recordedTransport = ReplayTransport(events: events, timing: .recorded)
        let recorded = ConnectionManager(adapter: DemoGarage.adapter) { recordedTransport }
        let clock = ContinuousClock()
        let start = clock.now
        try await recorded.connect()
        #expect(start.duration(to: clock.now) >= .milliseconds(1_000))
        let recordedStatus = await recorded.state.status
        let immediateStatus = await immediate.state.status
        #expect(recordedStatus == immediateStatus)
    }

    @Test("a replay backend rejects checks without saved recordings readably")
    func replayBackendCoverage() async throws {
        let saved = SavedCheck(
            job: .moduleDTCs(DemoGarage.airbag.target), recorded: .now,
            transcript: try DemoRecording.airbagCodes.url())
        let backend = ReplayBackend(
            displayName: "Saved recordings", checks: [saved], timing: .immediate)
        #expect(!backend.canRun(.genericScan))
        try await backend.connect()
        let events = await collect(await backend.run(.genericScan, transcript: nil))
        #expect(
            events.compactMap(\.failure).first?.message.contains("saved recording")
                == true)
    }

    @Test("replay connection prefers an adapter check and otherwise uses check identity")
    func replayConnectionStatusSources() async throws {
        let adapter = SavedCheck(
            job: .adapterCheck, recorded: Date(timeIntervalSince1970: 100),
            transcript: try DemoRecording.adapterProbe.url())
        let module = SavedCheck(
            job: .moduleDTCs(DemoGarage.airbag.target), recorded: Date(timeIntervalSince1970: 200),
            transcript: try DemoRecording.airbagCodes.url())
        let withAdapter = ReplayBackend(
            displayName: "Saved", checks: [adapter, module], timing: .immediate)
        try await withAdapter.connect()
        #expect((await withAdapter.currentState()).status?.firmware == "STN1170 v4.3.2")

        let withoutAdapter = ReplayBackend(
            displayName: "Saved", checks: [module], timing: .immediate)
        try await withoutAdapter.connect()
        #expect((await withoutAdapter.currentState()).status?.firmware == nil)
    }

    @Test("a paced decoded check can be cancelled")
    func cancelPacedDecodedCheck() async throws {
        let demo = DemoBackend(timing: .recorded)
        try await demo.connect()
        let stream = await demo.run(.genericScan, transcript: nil)
        let collecting = Task { await collect(stream) }
        try await Task.sleep(for: .milliseconds(20))
        await demo.cancel()
        let events = await collecting.value
        #expect(events.compactMap(\.failure).first?.cancelled == true)
    }

    @Test("a paced module check does not replay connection initialization")
    func pacedModuleCheckUsesCheckDuration() async throws {
        let demo = DemoBackend(timing: .recorded)
        try await demo.connect()
        let events = try DemoRecording.airbagCodes.events()
        let checkStart = try #require(
            events.firstIndex {
                $0.direction == .tx && $0.bytes == Array("ATRV\r".utf8)
            })
        let lastTimestamp = try #require(events.last?.milliseconds)
        let recordedDuration = lastTimestamp - events[checkStart].milliseconds
        let clock = ContinuousClock()
        let start = clock.now
        _ = await run(.moduleDTCs(DemoGarage.airbag.target), on: demo)
        let elapsed = start.duration(to: clock.now)
        let lowerBound: Duration = .milliseconds(Int64(recordedDuration / 2))
        let upperBound: Duration = .milliseconds(
            Int64(min(recordedDuration + 1_000, UInt64(Int64.max))))
        #expect(elapsed >= lowerBound)
        #expect(elapsed < upperBound)
    }

    @Test("vehicle information and generic scan come from the ignition-on recording")
    func genericReads() async throws {
        let demo = DemoBackend()
        try await demo.connect()

        let info = try #require(await run(.vehicleInfo, on: demo).compactMap(\.result).first)
        #expect(info.source == .recording("ghibli-ignition-on-term"))
        guard case .vehicleInfo(let ecus) = info.payload else {
            Issue.record("wrong payload"); return
        }
        #expect(ecus.map(\.ecu) == [0x7E8, 0x7E9])
        #expect(ecus.first?.vin == .value(DemoGarage.vin))
        #expect(ecus.last?.displayName == "TCM-TransmisCtrl")

        let scan = try #require(await run(.genericScan, on: demo).compactMap(\.result).first)
        guard case .genericScan(let reports) = scan.payload else {
            Issue.record("wrong payload"); return
        }
        #expect(reports.count == 2)
        #expect(
            reports.allSatisfy {
                $0.stored == .value([]) && $0.pending == .value([]) && $0.permanent == .value([])
            })
        #expect(reports.first?.readiness.value?.milOn == false)
    }

    @Test(
        "module reads: airbag replayed live-path, ABS and body computer decoded, steering column unrecorded"
    )
    func moduleReads() async throws {
        let demo = DemoBackend()
        try await demo.connect()

        let airbag = try #require(
            await run(.moduleDTCs(DemoGarage.airbag.target), on: demo).compactMap(\.result).first)
        #expect(airbag.source == .recording("ghibli-orc-flowcontrol"))
        guard case .moduleDTCs(let codes) = airbag.payload,
            case .records(_, let records) = codes.outcome
        else {
            Issue.record("wrong airbag payload"); return
        }
        #expect(records.map(\.code) == ["80011B", "80021B"])

        let abs = try #require(
            await run(.moduleDTCs(DemoGarage.abs.target), on: demo).compactMap(\.result).first)
        #expect(
            abs.payload
                == .moduleDTCs(
                    ModuleDTCs(
                        target: DemoGarage.abs.target, outcome: .records(availability: 0x7F, []))))

        let body = try #require(
            await run(.moduleDTCs(DemoGarage.bodyComputer.target), on: demo).compactMap(\.result)
                .first)
        #expect(
            body.payload
                == .moduleDTCs(
                    ModuleDTCs(
                        target: DemoGarage.bodyComputer.target,
                        outcome: .records(
                            availability: 0xFB, [ModuleDTCRecord(code: "100900", status: 0x2B)]))))

        let steering = await run(.moduleDTCs(DemoGarage.steeringColumn.target), on: demo)
        #expect(
            steering.compactMap(\.failure).first?.message
                == DemoError.noRecording(.moduleDTCs(DemoGarage.steeringColumn.target)).description)
    }

    @Test("the demo knows which checks its recordings answer: exactly the ones that run")
    func coverage() async throws {
        let demo = DemoBackend()
        try await demo.connect()
        let jobs: [DiagnosticJob] =
            [.adapterCheck, .vehicleInfo, .genericScan]
            + DemoGarage.modules.map { .moduleDTCs($0.target) }
        for job in jobs {
            let answered = await run(job, on: demo).contains { $0.result != nil }
            #expect(demo.canRun(job) == answered, "\(job.title)")
        }
        #expect(!demo.canRun(.moduleDTCs(DemoGarage.steeringColumn.target)))
    }

    @Test("checks refuse to run before connecting")
    func requiresConnection() async {
        let events = await run(.genericScan, on: DemoBackend())
        #expect(
            events.compactMap(\.failure).first?.message == ConnectionError.notConnected.description)
    }
}

extension JobEvent {
    var result: JobResult? { if case .completed(let result) = self { result } else { nil } }
    var failure: JobFailure? { if case .failed(let failure) = self { failure } else { nil } }
}

func collect(_ stream: AsyncStream<JobEvent>) async -> [JobEvent] {
    var events: [JobEvent] = []
    for await event in stream { events.append(event) }
    return events
}

func prefix<Element: Sendable>(_ stream: AsyncStream<Element>, _ count: Int) async -> [Element] {
    var values: [Element] = []
    for await value in stream {
        values.append(value)
        if values.count == count { break }
    }
    return values
}
