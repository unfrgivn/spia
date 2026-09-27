import Foundation
import SpiaAssist
import SpiaKit
import SpiaReference
import SwiftData
import Testing

@testable import SpiaStore

private func fixture(_ name: String) throws -> Data {
    try Data(
        contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name))
}

@MainActor
@Suite("Vehicle references in the store and the assistant")
struct ReferenceStoreTests {
    let container: ModelContainer
    let garage: Garage

    init() throws {
        container = try Garage.inMemoryContainer()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "spia-references-\(UUID().uuidString)")
        garage = Garage(context: container.mainContext, files: SpiaFiles(root: root))
    }

    /// References as a lookup would leave them, parsed from the recorded NHTSA and Commons replies.
    private func cacheRecordedReferences(for vehicle: Vehicle) throws -> ReferenceSnapshot {
        let snapshot = ReferenceSnapshot(
            vin: vehicle.vin,
            identity: try VPIC.identity(from: fixture("nhtsa-vpic-ZAM57RTS4H1249941.json")),
            safety: try NHTSA.safety(from: fixture("nhtsa-byymmt-2017-maserati-ghibli.json")),
            photos: try Commons.photos(
                from: fixture("commons-search-2017-maserati-ghibli.json"), modelYear: 2017),
            // Whole seconds: the cache stores dates as ISO 8601.
            fetchedAt: Date(timeIntervalSince1970: 1_790_000_000), problems: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let url = garage.files.snapshotURL(vehicle: vehicle.id)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(snapshot).write(to: url)
        return snapshot
    }

    @Test("cached references load for the vehicle, including after a restart")
    func cache() throws {
        let vehicle = try garage.addDemoVehicle()
        let snapshot = try cacheRecordedReferences(for: vehicle)

        let loaded = try #require(garage.references(for: vehicle))
        #expect(loaded.identity == snapshot.identity && loaded.photos == snapshot.photos)
        #expect(loaded.safety?.bulletins.map(\.id) == snapshot.safety?.bulletins.map(\.id))
        #expect(loaded.fetchedAt == snapshot.fetchedAt)
        let references = VehicleReferences(vehicleID: vehicle.id, files: garage.files)
        #expect(references.identity?.title == "2017 Maserati Ghibli")
        #expect(references.safety?.bulletins.count == 110)
        // Nothing is downloaded yet, so no photos are shown.
        #expect(references.photos.isEmpty)
    }

    @Test("the briefing carries the decoded car, recalls, complaints, and the bulletin count")
    func briefing() throws {
        let vehicle = try garage.addDemoVehicle()
        _ = try cacheRecordedReferences(for: vehicle)
        let session = try #require(vehicle.sessions.first)

        let references = try #require(garage.briefing(for: session, adapter: nil).references)

        #expect(references.decodedVehicle?.hasPrefix("2017 Maserati Ghibli, Sport, M157") == true)
        #expect(references.recalls.map(\.campaign).first == "18V173000")
        #expect(references.recalls.first?.date == "2018-03-14")
        #expect(references.bulletinCount == 110)
        #expect(references.complaintsByComponent.prefix(2) == ["ENGINE: 7", "POWER TRAIN: 7"])
        let instructions = AssistantInstructions.make(
            briefing: garage.briefing(for: session, adapter: nil), provider: .anthropic,
            sharing: SharingPolicy(includeVIN: false))
        #expect(instructions.contains("search_bulletins"))
        #expect(!instructions.contains("ZAM57RTS4H1249941"))
    }

    @Test("a bulletin search answers the model at once with the matching bulletins")
    func search() throws {
        let bulletins = try NHTSA.safety(from: fixture("nhtsa-byymmt-2017-maserati-ghibli.json"))
            .bulletins

        let (summary, result) = AssistantConversation.bulletinSearch(
            "steering wheel", in: bulletins, callID: "toolu_9")

        #expect(summary.hasPrefix("Searched bulletins for “steering wheel”: "))
        #expect(result.callID == "toolu_9")
        #expect(!result.isError)
        #expect(result.content.contains(#""number":"MAS003095 MTB 24-21""#))
        #expect(result.content.contains("may not apply to this car"))

        let (none, empty) = AssistantConversation.bulletinSearch(
            "horn", in: [], callID: "toolu_10")
        #expect(none == "Searched bulletins for “horn”: none found")
        #expect(empty.content.hasPrefix("No service bulletins are loaded"))
    }

    @Test("a live vehicle-information check fills in a missing VIN; a recording never does")
    func vinFromCar() async throws {
        let demo = try garage.addDemoVehicle()
        let workbench = Workbench(backend: DemoBackend(), garage: garage)
        await workbench.connect()
        guard
            case .completed(let recorded) = await workbench.run(
                .vehicleInfo, in: try #require(demo.sessions.first))
        else {
            Issue.record("the vehicle-information recording should replay")
            return
        }
        let car = try garage.addVehicle(name: "My car")
        let session = try garage.addSession(to: car, title: "Check")

        try garage.record(recorded, warnings: [], transcriptPath: nil, in: session)
        #expect(car.vin == nil)

        let live = JobResult(
            job: recorded.job, payload: recorded.payload, source: .live, transcript: nil)
        try garage.record(live, warnings: [], transcriptPath: nil, in: session)
        #expect(car.vin == "ZAM57RTS4H1249941")
    }

    @Test("deleting the vehicle deletes its references")
    func deletion() throws {
        let vehicle = try garage.addDemoVehicle()
        _ = try cacheRecordedReferences(for: vehicle)
        let folder = garage.files.referencesFolder(vehicle: vehicle.id)
        #expect(FileManager.default.fileExists(atPath: folder.path))

        try garage.delete(vehicle)

        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }
}
