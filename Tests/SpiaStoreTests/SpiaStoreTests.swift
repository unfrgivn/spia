import CryptoKit
import Foundation
import OBDCore
import SpiaKit
import SpiaStore
import SwiftData
import Testing

@MainActor
@Suite("Garage and workbench")
struct SpiaStoreTests {
    let container: ModelContainer
    let garage: Garage
    let root: URL

    init() throws {
        container = try Garage.inMemoryContainer()
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "spia-store-\(UUID().uuidString)")
        garage = Garage(context: container.mainContext, files: SpiaFiles(root: root))
    }

    private func demoWorkbench() async throws -> (Workbench, DiagnosticSession) {
        let vehicle = try garage.addDemoVehicle()
        let session = try #require(vehicle.sessions.first)
        let workbench = Workbench(backend: DemoBackend(), garage: garage)
        await workbench.connect()
        return (workbench, session)
    }

    private func recordLive(
        _ job: DiagnosticJob, recording: DemoRecording, in session: DiagnosticSession
    ) async throws -> JobResult {
        let transport = try ReplayTransport(contentsOf: recording.url())
        let connection = ConnectionManager(adapter: DemoGarage.adapter) { transport }
        try await connection.connect()
        let vehicle = try #require(session.vehicle)
        let transcript = garage.newTranscript(for: vehicle)
        var result: JobResult?
        for await event in await JobRunner(connection: connection).run(
            job, transcript: transcript.url)
        {
            if case .completed(let completed) = event { result = completed }
        }
        let completed = try #require(result)
        try garage.record(
            completed, warnings: [], transcriptPath: transcript.path, for: vehicle, in: session)
        return completed
    }

    @Test("demo and replay workbenches do not expose a physical live status")
    func nonPhysicalLiveStatus() async throws {
        let (demo, _) = try await demoWorkbench()
        #expect(demo.liveStatus == nil)
        let replay = ReplayBackend(
            displayName: "Saved recordings",
            checks: [
                SavedCheck(
                    job: .moduleDTCs(DemoGarage.airbag.target), recorded: .now,
                    transcript: try DemoRecording.airbagCodes.url())
            ], timing: .immediate)
        let workbench = Workbench(backend: replay, garage: garage)
        await workbench.connect()
        #expect(workbench.liveStatus == nil)
    }

    @Test("the demo vehicle comes with its adapter, unconfirmed modules, and a first session")
    func demoVehicle() throws {
        let vehicle = try garage.addDemoVehicle()
        #expect(vehicle.isDemo)
        #expect(vehicle.vin == DemoGarage.vin)
        #expect(vehicle.adapters.map(\.kind) == [.demo])
        #expect(vehicle.orderedModules.compactMap(\.target) == DemoGarage.modules.map(\.target))
        #expect(vehicle.modules.allSatisfy { !$0.confirmed })
        #expect(vehicle.sessions.map(\.title) == ["Dead steering-wheel controls"])
    }

    @Test("extended module presets survive a store round trip")
    func extendedModulePresetRoundTrip() throws {
        let target = try ModuleTarget(
            bus: .highSpeed, request: 0x18DA30F1, response: 0x18DAF130)
        let preset = ModulePreset(label: "EPS", target: target)
        container.mainContext.insert(preset)
        try container.mainContext.save()
        let saved = try #require(
            try container.mainContext.fetch(FetchDescriptor<ModulePreset>()).first)
        #expect(saved.target == target)
    }

    @Test("a vehicle can start with a Bluetooth adapter profile")
    func bluetoothAdapterProfile() throws {
        let vehicle = try garage.addVehicle(name: "Bluetooth car", adapterKind: .bluetooth)
        let adapter = try #require(vehicle.adapters.first)
        #expect(adapter.kind == .bluetooth)
        #expect(adapter.name == "Bluetooth adapter")
        #expect(adapter.devicePath == nil)
    }

    @Test("an adapter profile switches between USB and Bluetooth")
    func switchesAdapterKind() throws {
        let vehicle = try garage.addVehicle(name: "Switchable car")
        let adapter = try #require(vehicle.adapters.first)
        adapter.use(.bluetooth)
        #expect(adapter.kind == .bluetooth)
        #expect(adapter.name == "Bluetooth adapter")
        #expect(adapter.devicePath == nil)
        adapter.devicePath = "peripheral-id"
        adapter.use(.usbSerial)
        #expect(adapter.kind == .usbSerial)
        #expect(adapter.name == "USB adapter")
        #expect(adapter.devicePath == nil)
    }

    @Test("a check's result is saved to the session with its transcript")
    func recordsResult() async throws {
        let (workbench, session) = try await demoWorkbench()
        #expect(workbench.connection.status?.hardware == "vLinker FS r2")

        await workbench.run(
            .moduleDTCs(DemoGarage.airbag.target), for: session.vehicle!, in: session)

        #expect(workbench.activity == nil)
        let entry = try #require(session.timeline.last)
        #expect(entry.kind == .result)
        #expect(entry.body == "2 codes: B0001-1B, B0002-1B · 2 failing now")
        let result = try #require(entry.result)
        #expect(result.source == .recording("ghibli-orc-flowcontrol"))

        // The saved transcript is the one the check wrote, intact.
        let path = try #require(entry.transcriptPath)
        let data = try Data(contentsOf: garage.files.url(for: path))
        #expect(
            result.transcript?.sha256
                == SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        #expect(
            try Transcript.decodeFile(String(decoding: data, as: UTF8.self)).contains {
                $0.direction == .tx
            })
    }

    @Test("saved live checks replay through the production path")
    func savedChecksReplay() async throws {
        let vehicle = try garage.addVehicle(name: "Recorded car")
        let session = try garage.addSession(to: vehicle, title: "Saved checks")
        _ = try await recordLive(
            .moduleDTCs(DemoGarage.airbag.target), recording: .airbagCodes, in: session)
        _ = try await recordLive(.adapterCheck, recording: .adapterProbe, in: session)

        let checks = garage.savedChecks(for: vehicle)
        #expect(checks.map(\.job).contains(.adapterCheck))
        #expect(checks.map(\.job).contains(.moduleDTCs(DemoGarage.airbag.target)))
        let savedAirbag = try #require(
            checks.first { $0.job == .moduleDTCs(DemoGarage.airbag.target) })
        let savedEntry = try #require(
            session.timeline.first {
                $0.result?.job == savedAirbag.job && $0.result?.source == .live
            })
        let savedPayload = try #require(savedEntry.result?.payload)
        let savedData = try Data(contentsOf: savedAirbag.transcript)

        let replayBackend = ReplayBackend(
            displayName: "Saved recordings", checks: checks, timing: .immediate)
        let replayWorkbench = Workbench(backend: replayBackend, garage: garage)
        await replayWorkbench.connect()
        #expect(replayWorkbench.liveStatus == nil)
        let replayOutcome = await replayWorkbench.run(
            savedAirbag.job, for: session.vehicle!, in: session)
        guard case .completed(let replayResult) = replayOutcome else {
            Issue.record("saved airbag check did not replay")
            return
        }
        #expect(replayResult.payload == savedPayload)
        #expect(replayResult.source == .replay(recorded: savedAirbag.recorded))
        let replayEntry = try #require(
            session.timeline.last { $0.result?.source == .replay(recorded: savedAirbag.recorded) })
        let replayPath = try #require(replayEntry.transcriptPath)
        #expect(try Data(contentsOf: garage.files.url(for: replayPath)) == savedData)
    }

    @Test("invalid and non-live saved results are excluded")
    func savedCheckValidation() async throws {
        let vehicle = try garage.addVehicle(name: "Validation car")
        let session = try garage.addSession(to: vehicle, title: "Validation")
        _ = try await recordLive(
            .moduleDTCs(DemoGarage.airbag.target), recording: .airbagCodes, in: session)
        let liveEntry = try #require(session.timeline.last)
        let originalPath = try #require(liveEntry.transcriptPath)
        let otherPath = "wrong-recording.txt"
        try FileManager.default.copyItem(
            at: DemoRecording.adapterProbe.url(), to: garage.files.url(for: otherPath))
        liveEntry.transcriptPath = otherPath
        #expect(garage.savedChecks(for: vehicle).isEmpty)
        liveEntry.transcriptPath = originalPath
        try FileManager.default.removeItem(at: garage.files.url(for: originalPath))
        #expect(garage.savedChecks(for: vehicle).isEmpty)

        let replayEntry = TimelineEntry(kind: .result, title: "Replay", body: "Replay")
        replayEntry.resultData = try JSONEncoder().encode(
            JobResult(
                job: .moduleDTCs(DemoGarage.airbag.target),
                payload: .moduleDTCs(
                    ModuleDTCs(
                        target: DemoGarage.airbag.target,
                        outcome: .records(availability: 0, []))),
                source: .replay(recorded: .now), transcript: nil))
        session.entries.append(replayEntry)
        #expect(garage.savedChecks(for: vehicle).isEmpty)
    }

    @Test("replay board results use the car date and lose to newer live results")
    func replayBoardDating() throws {
        let recorded = Date(timeIntervalSince1970: 100)
        let liveDate = Date(timeIntervalSince1970: 200)
        let payload = JobPayload.genericScan([])
        let replayEntry = TimelineEntry(kind: .result, title: "Replay", date: liveDate)
        replayEntry.resultData = try JSONEncoder().encode(
            JobResult(
                job: .genericScan, payload: payload, source: .replay(recorded: recorded),
                transcript: nil))
        let liveEntry = TimelineEntry(kind: .result, title: "Live", date: liveDate)
        liveEntry.resultData = try JSONEncoder().encode(
            JobResult(job: .genericScan, payload: payload, source: .live, transcript: nil))
        let board = SessionBoard(
            modules: [],
            results: [replayEntry.boardResult, liveEntry.boardResult].compactMap { $0 })
        #expect(board.rows.first(where: { $0.subject == .engine })?.date == liveDate)

        let replayOnly = SessionBoard(
            modules: [], results: [replayEntry.boardResult].compactMap { $0 })
        #expect(replayOnly.rows.first(where: { $0.subject == .engine })?.date == recorded)
    }

    @Test("briefing marks replay results as recordings and keeps the date in prose")
    func replayBriefing() throws {
        let vehicle = try garage.addVehicle(name: "Briefing car")
        let session = try garage.addSession(to: vehicle, title: "Replay")
        let recorded = Date(timeIntervalSince1970: 100)
        let entry = TimelineEntry(kind: .result, title: "Scan", date: .now)
        entry.resultData = try JSONEncoder().encode(
            JobResult(
                job: .genericScan, payload: .genericScan([]), source: .replay(recorded: recorded),
                transcript: nil))
        session.entries.append(entry)
        let briefing = garage.briefing(for: session, adapter: nil)
        #expect(briefing.events.last?.fromRecording == true)
        #expect(briefing.events.last?.summary.contains("Replayed from a recording") == true)
    }

    @Test("briefings include the car reading and only their problem's notes")
    func problemBriefingUsesCarHistory() async throws {
        let (workbench, originalSession) = try await demoWorkbench()
        let vehicle = try #require(originalSession.vehicle)
        await workbench.run(.adapterCheck, for: vehicle)
        let reading = try #require(vehicle.entries.first { $0.kind == .result })

        let firstProblem = try garage.addSession(to: vehicle, title: "First problem")
        try garage.addNote("first problem note", to: firstProblem)
        let secondProblem = try garage.addSession(to: vehicle, title: "Second problem")
        try garage.addNote("second problem note", to: secondProblem)

        let firstBriefing = garage.briefing(for: firstProblem, adapter: nil)
        #expect(
            firstBriefing.events.contains {
                $0.kind == "note" && $0.summary == "first problem note"
            })
        #expect(firstBriefing.events.contains { $0.kind == "result" && $0.title == reading.title })
        #expect(!firstBriefing.events.contains { $0.summary == "second problem note" })

        let secondBriefing = garage.briefing(for: secondProblem, adapter: nil)
        #expect(
            secondBriefing.events.contains {
                $0.kind == "note" && $0.summary == "second problem note"
            })
        #expect(secondBriefing.events.contains { $0.kind == "result" && $0.title == reading.title })
        #expect(!secondBriefing.events.contains { $0.summary == "first problem note" })

        let oldProblem = try garage.addSession(to: vehicle, title: "Earlier problem")
        oldProblem.status = .resolved
        oldProblem.closedAt = reading.date.addingTimeInterval(-1)
        let oldBriefing = garage.briefing(for: oldProblem, adapter: nil)
        #expect(!oldBriefing.events.contains { $0.kind == "result" && $0.title == reading.title })
    }

    @Test("the demo workbench offers only the checks the recordings answer")
    func demoChecks() async throws {
        let (workbench, _) = try await demoWorkbench()
        #expect(workbench.canRun(.moduleDTCs(DemoGarage.airbag.target)))
        #expect(workbench.canRun(.genericScan))
        #expect(!workbench.canRun(.moduleDTCs(DemoGarage.steeringColumn.target)))
    }

    @Test("a check that can't run is saved as a failure, not as an empty result")
    func recordsFailure() async throws {
        let (workbench, session) = try await demoWorkbench()
        await workbench.run(
            .moduleDTCs(DemoGarage.steeringColumn.target), for: session.vehicle!, in: session)
        let entry = try #require(session.timeline.last)
        #expect(entry.kind == .failure)
        #expect(entry.result == nil)
        #expect(entry.body.contains("no recording"))
    }

    @Test("generic scan and vehicle info summaries read plainly")
    func summaries() async throws {
        let (workbench, session) = try await demoWorkbench()
        await workbench.run(.vehicleInfo, for: session.vehicle!, in: session)
        await workbench.run(.genericScan, for: session.vehicle!, in: session)
        #expect(
            session.timeline.suffix(2).map(\.body) == [
                "VIN ZAM57RTS4H1249941 · 2 modules answered (ECM1-EngineControl1, TCM-TransmisCtrl)",
                "No engine or transmission codes · check-engine light off",
            ])
    }

    @Test("the ignition prompt pauses the check; cancelling records nothing and clears the prompt")
    func promptThenCancel() async throws {
        let vehicle = try garage.addVehicle(name: "Bench")
        let session = try garage.addSession(to: vehicle, title: "Adapter only")
        let transport = try ReplayTransport(contentsOf: DemoRecording.adapterWithoutCar.url())
        let backend = LiveBackend(
            adapter: AdapterDescriptor(kind: .usbSerial, displayName: "vLinker FS")
        ) {
            transport
        }
        let workbench = Workbench(backend: backend, garage: garage)
        await workbench.connect()
        let status = try #require(workbench.connection.status, "adapter should be ready")
        #expect(status.hardware == "vLinker FS r2")
        #expect(status.voltage == nil)

        let running = Task { await workbench.run(.genericScan, for: session.vehicle!, in: session) }
        var waited = 0
        while workbench.activity?.prompt == nil, waited < 1000 {
            await Task.yield()
            waited += 1
        }
        #expect(workbench.activity?.prompt?.action == .turnIgnitionOn)

        await workbench.cancel()
        _ = await running.value
        #expect(workbench.activity == nil)
        #expect(session.entries.isEmpty)
        #expect(workbench.connection.status != nil)
    }

    @Test("the library is written to Spia's own folder and reopens with its data")
    func onDisk() throws {
        let files = SpiaFiles(root: root.appendingPathComponent("disk", isDirectory: true))
        do {
            let container = try Garage.container(at: files)
            try Garage(context: container.mainContext, files: files).addVehicle(name: "Ghibli")
        }
        #expect(FileManager.default.fileExists(atPath: files.storeURL.path))
        #expect(files.storeURL.deletingLastPathComponent() == files.root)

        let reopened = try Garage.container(at: files)
        #expect(
            try reopened.mainContext.fetch(FetchDescriptor<Vehicle>()).map(\.name) == ["Ghibli"])
    }

    @Test("notes are trimmed and empty notes are ignored")
    func notes() throws {
        let vehicle = try garage.addVehicle(name: "Test car")
        let session = try garage.addSession(to: vehicle, title: "Rattle")
        try garage.addNote("  only over bumps  ", to: session)
        try garage.addNote("   ", to: session)
        #expect(session.timeline.map(\.body) == ["only over bumps"])
    }

    @Test("deleting a vehicle removes its sessions, history, and vehicle transcripts")
    func deleteVehicle() async throws {
        let (workbench, session) = try await demoWorkbench()
        await workbench.run(
            .moduleDTCs(DemoGarage.airbag.target), for: session.vehicle!, in: session)
        let folder = garage.files.transcriptFolder(for: session.vehicle!.id)
        #expect(FileManager.default.fileExists(atPath: folder.path))
        let vehicle = try #require(session.vehicle)

        try garage.delete(vehicle)

        #expect(try container.mainContext.fetchCount(FetchDescriptor<Vehicle>()) == 0)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<DiagnosticSession>()) == 0)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<TimelineEntry>()) == 0)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<ModulePreset>()) == 0)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }
}
