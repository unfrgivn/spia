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

        // The transcript holds exactly what the check sent, which is exactly what was sent on the car.
        let recorded = try Transcript.decodeFile(String(contentsOf: url, encoding: .utf8))
        let sent = recorded.filter { $0.direction == .tx }.map {
            String(decoding: $0.bytes.dropLast(), as: UTF8.self)
        }
        #expect(sent == DiagnosticJob.moduleDTCs(Self.airbag).plannedCommands)
        let onCar = try DemoRecording.airbagCodes.events().filter { $0.direction == .tx }
            .map { String(decoding: $0.bytes.dropLast(), as: UTF8.self) }
        #expect(Array(onCar.suffix(sent.count)) == sent)

        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(
            result.transcript
                == TranscriptReference(
                    fileName: "transcript.txt", byteCount: data.count, sha256: digest))
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
        jobs.append(
            .moduleDTCs(
                try ModuleTarget(
                    bus: .mediumSpeed, request: 0x7BF, response: 0x53F, statusMask: 0xFF)))
        for job in jobs {
            for command in job.plannedCommands
            where !command.hasPrefix("AT") && !command.hasPrefix("ST") {
                let service = try #require(
                    UInt8(command.prefix(2), radix: 16), "\(command) is not hex")
                #expect(!forbidden.contains(service), "\(job.id) would send \(command)")
            }
        }
    }

    @Test("module targets reject IDs that are not a single 11-bit module")
    func moduleTargetValidation() {
        #expect(throws: ModuleTarget.Invalid.notElevenBit(0x800)) {
            try ModuleTarget(bus: .highSpeed, request: 0x800, response: 0x4C4)
        }
        #expect(throws: ModuleTarget.Invalid.functionalBroadcast) {
            try ModuleTarget(bus: .highSpeed, request: 0x7DF, response: 0x7E8)
        }
        #expect(throws: ModuleTarget.Invalid.sameRequestAndResponse) {
            try ModuleTarget(bus: .highSpeed, request: 0x744, response: 0x744)
        }
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

    @Test("voltage explains whether the adapter is really in a car")
    func voltageWording() {
        #expect(ConnectionSummary.voltageText(nil).hasPrefix("No power from the car"))
        #expect(ConnectionSummary.voltageText(11.7) == "11.7 V, battery low")
        #expect(ConnectionSummary.voltageText(14.3).contains("charging"))
        #expect(ConnectionSummary.voltageText(12.6) == "12.6 V")
    }
}

@Suite("Demo car")
struct DemoBackendTests {
    private func run(_ job: DiagnosticJob, on demo: DemoBackend) async -> [JobEvent] {
        await collect(demo.run(job, transcript: nil))
    }

    @Test("connecting replays the recorded adapter check")
    func connect() async throws {
        let demo = DemoBackend()
        try await demo.connect()
        let state = await prefix(demo.states(), 1).first
        #expect(state?.status?.firmware == "STN1170 v4.3.2")
        #expect(state?.status?.voltage == 11.7)
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
