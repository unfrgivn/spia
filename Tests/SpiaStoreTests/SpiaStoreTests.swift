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
        container = try Garage.container(inMemory: true)
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

    @Test("a check's result is saved to the session with its transcript")
    func recordsResult() async throws {
        let (workbench, session) = try await demoWorkbench()
        #expect(workbench.connection.status?.hardware == "vLinker FS r2")

        await workbench.run(.moduleDTCs(DemoGarage.airbag.target), in: session)

        #expect(workbench.activity == nil)
        let entry = try #require(session.timeline.last)
        #expect(entry.kind == .result)
        #expect(entry.body == "2 codes: 80011B, 80021B · 2 failing now")
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

    @Test("a check that can't run is saved as a failure, not as an empty result")
    func recordsFailure() async throws {
        let (workbench, session) = try await demoWorkbench()
        await workbench.run(.moduleDTCs(DemoGarage.steeringColumn.target), in: session)
        let entry = try #require(session.timeline.last)
        #expect(entry.kind == .failure)
        #expect(entry.result == nil)
        #expect(entry.body.contains("no recording"))
    }

    @Test("generic scan and vehicle info summaries read plainly")
    func summaries() async throws {
        let (workbench, session) = try await demoWorkbench()
        await workbench.run(.vehicleInfo, in: session)
        await workbench.run(.genericScan, in: session)
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

        let running = Task { await workbench.run(.genericScan, in: session) }
        var waited = 0
        while workbench.activity?.prompt == nil, waited < 1000 {
            await Task.yield()
            waited += 1
        }
        #expect(workbench.activity?.prompt?.action == .turnIgnitionOn)

        await workbench.cancel()
        await running.value
        #expect(workbench.activity == nil)
        #expect(session.entries.isEmpty)
        #expect(workbench.connection.status != nil)
    }

    @Test("notes are trimmed and empty notes are ignored")
    func notes() throws {
        let vehicle = try garage.addVehicle(name: "Test car")
        let session = try garage.addSession(to: vehicle, title: "Rattle")
        try garage.addNote("  only over bumps  ", to: session)
        try garage.addNote("   ", to: session)
        #expect(session.timeline.map(\.body) == ["only over bumps"])
    }

    @Test("deleting a vehicle removes its sessions, history, and transcript files")
    func deleteVehicle() async throws {
        let (workbench, session) = try await demoWorkbench()
        await workbench.run(.moduleDTCs(DemoGarage.airbag.target), in: session)
        let folder = garage.files.sessionFolder(session.id)
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
