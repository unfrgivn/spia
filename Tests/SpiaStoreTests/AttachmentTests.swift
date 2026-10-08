import Foundation
import AVFoundation
import ImageIO
import SpiaStore
import SwiftData
import Testing

@MainActor
@Suite("Finding attachments")
struct AttachmentTests {
    @Test("finding evidence is stored beside the vehicle's photos")
    func findingPathIsUnderVehicle() {
        let vehicle = UUID()
        let path = SpiaFiles(root: URL(fileURLWithPath: "/tmp")).findingPath(
            vehicle: vehicle, name: "photo.jpg")

        #expect(path == "Vehicles/\(vehicle.uuidString)/Findings/photo.jpg")
    }

    @Test("a photo is prepared as a JPEG and attached to its finding")
    func attachPhoto() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let container = try Garage.inMemoryContainer()
        let garage = Garage(context: container.mainContext, files: SpiaFiles(root: root))
        let vehicle = try garage.addVehicle(name: "Car")
        let session = try garage.addSession(to: vehicle, title: "Problem")
        let entry = TimelineEntry(kind: .finding, title: "Connector", body: "Loose")
        entry.vehicle = vehicle
        session.entries.append(entry)

        let attachment = try garage.attachPhoto(try imageData(), to: entry)

        #expect(attachment.kind == .photo)
        #expect(attachment.mediaType == "image/jpeg")
        let data = try Data(contentsOf: garage.files.url(for: attachment.path))
        #expect(CGImageSourceCreateWithData(data as CFData, nil) != nil)
    }

    @Test("a finding without a vehicle cannot receive evidence")
    func attachmentNeedsVehicle() throws {
        let container = try Garage.inMemoryContainer()
        let garage = Garage(
            context: container.mainContext, files: SpiaFiles(root: .temporaryDirectory))
        let entry = TimelineEntry(kind: .finding, title: "Finding")

        #expect(throws: MediaError.noVehicle) {
            try garage.attachPhoto(Data(), to: entry)
        }
    }

    @Test("deleting an attachment removes its row and file")
    func deleteAttachment() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let container = try Garage.inMemoryContainer()
        let garage = Garage(context: container.mainContext, files: SpiaFiles(root: root))
        let vehicle = try garage.addVehicle(name: "Car")
        let entry = TimelineEntry(kind: .finding, title: "Finding")
        entry.vehicle = vehicle
        vehicle.entries.append(entry)
        let attachment = try garage.attachPhoto(try imageData(), to: entry)
        let url = garage.files.url(for: attachment.path)

        try garage.delete(attachment)

        #expect(entry.attachments.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("a clip keeps its recording and three prepared frames")
    func attachClip() async throws {
        let clip = try await makeClip()
        let (container, garage, _, entry) = try Self.makeFinding()
        _ = container

        let attachment = try await garage.attachClip(at: clip, to: entry)

        #expect(attachment.kind == .clip)
        #expect(attachment.mediaType == "video/quicktime")
        #expect(attachment.duration.map { (0.8...1.2).contains($0) } == true)
        #expect(attachment.framePaths.count == 3)
        #expect(FileManager.default.fileExists(atPath: garage.files.url(for: attachment.path).path))
        for path in attachment.framePaths {
            let data = try Data(contentsOf: garage.files.url(for: path))
            let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            #expect(
                (image.width == 320 && image.height == 240)
                    || (image.width == 240 && image.height == 320))
        }
    }

    @Test("a sound keeps its AAC recording without frames")
    func attachSound() async throws {
        let sound = try makeSound(seconds: 1)
        let (container, garage, _, entry) = try Self.makeFinding()
        _ = container

        let attachment = try await garage.attachSound(at: sound, to: entry)

        #expect(attachment.kind == .sound)
        #expect(attachment.mediaType == "audio/mp4")
        #expect(attachment.duration.map { (0.8...1.3).contains($0) } == true)
        #expect(attachment.framePaths.isEmpty)
        #expect(FileManager.default.fileExists(atPath: garage.files.url(for: attachment.path).path))
    }

    @Test("a sound over the duration cap is rejected before storing")
    func rejectsLongSound() async throws {
        let sound = try makeSound(seconds: 61, sampleRate: 8_000)
        let (container, garage, vehicle, entry) = try Self.makeFinding()
        _ = container
        let findings = garage.files.vehicleFolder(vehicle.id).appendingPathComponent("Findings")

        await #expect(throws: MediaError.tooLong(seconds: 61, limit: 60)) {
            try await Self.attachSound(at: sound, garage: garage, entry: entry)
        }

        #expect(!FileManager.default.fileExists(atPath: findings.path))
    }

    @Test("deleting a clip removes its recording, frames, and row")
    func deleteClip() async throws {
        let clip = try await makeClip()
        let (container, garage, _, entry) = try Self.makeFinding()
        _ = container
        let attachment = try await garage.attachClip(at: clip, to: entry)
        let paths = [attachment.path] + attachment.framePaths

        try garage.delete(attachment)

        #expect(entry.attachments.isEmpty)
        #expect(
            paths.allSatisfy {
                !FileManager.default.fileExists(atPath: garage.files.url(for: $0).path)
            })
    }

    @Test("problem deletion keeps finding evidence, vehicle deletion removes it")
    func deletionRules() async throws {
        let clip = try await makeClip()
        let (container, garage, vehicle, entry) = try Self.makeFinding()
        _ = container
        let session = try garage.addSession(to: vehicle, title: "Problem")
        session.entries.append(entry)
        let attachment = try await garage.attachClip(at: clip, to: entry)
        let paths = [attachment.path] + attachment.framePaths
        let vehicleFolder = garage.files.vehicleFolder(vehicle.id)

        try garage.delete(session)

        #expect(vehicle.entries.contains { $0.id == entry.id })
        #expect(entry.attachments.contains { $0.id == attachment.id })
        #expect(
            paths.allSatisfy {
                FileManager.default.fileExists(atPath: garage.files.url(for: $0).path)
            })

        try garage.delete(vehicle)

        #expect(
            !FileManager.default.fileExists(atPath: vehicleFolder.path))
    }

    @Test("v2 findings migrate with empty evidence")
    func migrationFromV2() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("Library.store")
        let schema = Schema(versionedSchema: SpiaSchemaV2.self)
        let oldContainer = try ModelContainer(
            for: schema, configurations: ModelConfiguration(schema: schema, url: url))
        let oldContext = ModelContext(oldContainer)
        let oldVehicle = SpiaSchemaV2.Vehicle(name: "Old car")
        let oldSession = SpiaSchemaV2.DiagnosticSession(title: "Problem")
        let oldEntry = SpiaSchemaV2.TimelineEntry(kind: .finding, title: "Finding")
        oldVehicle.sessions = [oldSession]
        oldSession.entries = [oldEntry]
        oldEntry.vehicle = oldVehicle
        oldContext.insert(oldVehicle)
        try oldContext.save()

        let files = SpiaFiles(root: root)
        let container = try Garage.container(at: files)
        let garage = Garage(context: container.mainContext, files: files)
        let entries = try garage.context.fetch(FetchDescriptor<TimelineEntry>())

        #expect(entries.count == 1)
        #expect(entries.first?.attachments.isEmpty == true)
        #expect(entries.first?.vehicle?.name == "Old car")
        #expect(entries.first?.session?.title == "Problem")
    }

    private static func makeFinding() throws -> (ModelContainer, Garage, Vehicle, TimelineEntry) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let container = try Garage.inMemoryContainer()
        let garage = Garage(context: container.mainContext, files: SpiaFiles(root: root))
        let vehicle = try garage.addVehicle(name: "Car")
        let entry = TimelineEntry(kind: .finding, title: "Finding")
        entry.vehicle = vehicle
        vehicle.entries.append(entry)
        try garage.context.save()
        return (container, garage, vehicle, entry)
    }

    private static func attachSound(at url: URL, garage: Garage, entry: TimelineEntry) async throws
    {
        _ = try await garage.attachSound(at: url, to: entry)
    }

}
