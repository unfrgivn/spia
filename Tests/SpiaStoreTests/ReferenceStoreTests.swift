import CoreGraphics
import Foundation
import ImageIO
import SpiaAssist
import SpiaKit
import SpiaReference
import SwiftData
import Testing
import UniformTypeIdentifiers

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
            photos: Commons.rank(
                [try Commons.candidates(from: fixture("commons-search-2017-maserati-ghibli.json"))],
                for: PhotoQuery(make: "Maserati", model: "Ghibli", year: 2017)),
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
        #expect(references.safety?.bulletins.count == 102)
        // Nothing is downloaded yet, so no photos are shown.
        #expect(references.photos.isEmpty)
    }

    @Test("a refresh that's cut short keeps the cached references and downloaded photos")
    func cancelledRefresh() async throws {
        let vehicle = try garage.addDemoVehicle()
        let cached = try cacheRecordedReferences(for: vehicle)
        let photo = try #require(cached.photos.first)
        let downloaded = garage.files.photoURL(vehicle: vehicle.id, photo: photo)
        try FileManager.default.createDirectory(
            at: downloaded.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0xFF, 0xD8, 0xFF]).write(to: downloaded)
        let references = VehicleReferences(vehicleID: vehicle.id, files: garage.files)

        // Cancelled before it runs, as when the screen goes away mid-refresh.
        let refresh = Task { await references.refresh(vehicle.referenceInput) }
        refresh.cancel()
        await refresh.value

        #expect(references.snapshot == cached)
        #expect(garage.references(for: vehicle) == cached)
        #expect(FileManager.default.fileExists(atPath: downloaded.path))
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
        #expect(references.bulletinCount == 102)
        #expect(references.complaintsByComponent.prefix(2) == ["ENGINE: 7", "POWER TRAIN: 7"])
        let instructions = AssistantInstructions.make(
            briefing: garage.briefing(for: session, adapter: nil), provider: .anthropic,
            sharing: SharingPolicy(includeVIN: false))
        #expect(instructions.joined.contains("search_bulletins"))
        #expect(!instructions.joined.contains("ZAM57RTS4H1249941"))
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
                .vehicleInfo, for: demo, in: try #require(demo.sessions.first))
        else {
            Issue.record("the vehicle-information recording should replay")
            return
        }
        let car = try garage.addVehicle(name: "My car")
        let session = try garage.addSession(to: car, title: "Check")

        try garage.record(recorded, warnings: [], transcriptPath: nil, for: car, in: session)
        #expect(car.vin == nil)

        let live = JobResult(
            job: recorded.job, payload: recorded.payload, source: .live, transcript: nil)
        try garage.record(live, warnings: [], transcriptPath: nil, for: car, in: session)
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

    @Test("the owner's photos replace the reference photo as the cover, and go with the vehicle")
    func ownPhotos() throws {
        let vehicle = try garage.addDemoVehicle()
        _ = try cacheRecordedReferences(for: vehicle)
        let references = VehicleReferences(vehicleID: vehicle.id, files: garage.files)
        // Photos from the cache count only once downloaded; put one reference photo on disk.
        let reference = try #require(references.snapshot?.photos.first)
        let referenceFile = garage.files.photoURL(vehicle: vehicle.id, photo: reference)
        try FileManager.default.createDirectory(
            at: referenceFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PhotoPreparation.jpeg(from: try Self.png()).write(to: referenceFile)
        #expect(
            references.cover(for: vehicle) == CoverImage(file: referenceFile, reference: reference))

        let first = try garage.addImage(try Self.png(), to: vehicle)
        let firstFile = garage.files.url(for: first.path)
        #expect(references.cover(for: vehicle) == CoverImage(file: firstFile, reference: nil))
        let source = try #require(CGImageSourceCreateWithURL(firstFile as CFURL, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.jpeg.identifier)

        let second = try garage.addImage(try Self.png(), to: vehicle)
        #expect(vehicle.coverImage == first)
        try garage.setCover(second)
        #expect(vehicle.coverImage == second)
        try garage.delete(second)
        #expect(vehicle.coverImage == first)
        try garage.delete(first)
        #expect(!FileManager.default.fileExists(atPath: firstFile.path))
        #expect(references.cover(for: vehicle)?.reference == reference)

        try garage.addImage(try Self.png(), to: vehicle, asCover: true)
        let folder = garage.files.vehicleFolder(vehicle.id)
        #expect(FileManager.default.fileExists(atPath: folder.path))
        try garage.delete(vehicle)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test("the photo search uses the owner's trim and colour over the decoder's trim")
    func photoQuery() throws {
        let identity = try VPIC.identity(from: fixture("nhtsa-vpic-ZAM57RTS4H1249941.json"))
        let vehicle = try garage.addDemoVehicle()
        vehicle.color = .blue
        let query = vehicle.referenceInput.photoQuery(identity: identity)
        #expect(query.trim == "S Q4")
        #expect(query.searches.first == #"Maserati Ghibli "S Q4" blue"#)
        vehicle.trim = nil
        #expect(vehicle.referenceInput.photoQuery(identity: identity).trim == "Sport")
    }

    private static func png() throws -> Data {
        let context = try #require(
            CGContext(
                data: nil, width: 1200, height: 800, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0.1, green: 0.2, blue: 0.6, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 1200, height: 800))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
