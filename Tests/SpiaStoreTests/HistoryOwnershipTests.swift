import Foundation
import SpiaKit
import SpiaStore
import SwiftData
import Testing

@MainActor
@Suite("Vehicle history ownership")
struct HistoryOwnershipTests {
    private func result(date: Date, voltage: Double) -> TimelineEntry {
        let entry = TimelineEntry(kind: .result, title: "Adapter", date: date)
        entry.resultData = try? JSONEncoder().encode(
            JobResult(
                job: .adapterCheck,
                payload: .adapter(AdapterStatus(identity: "adapter", voltage: voltage)),
                source: .live,
                transcript: nil))
        return entry
    }

    @Test("migration backfills vehicle ownership and resolved close times")
    func migrationBackfillsOwnership() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("Library.store")
        try Self.writeV1Library(at: url)

        // The container must outlive the context: a context whose container has been released
        // traps the moment it faults a relationship.
        let files = SpiaFiles(root: root)
        let container = try Garage.container(at: files)
        let garage = Garage(context: container.mainContext, files: files)
        let entries = try garage.context.fetch(FetchDescriptor<TimelineEntry>())
        let sessions = try garage.context.fetch(FetchDescriptor<DiagnosticSession>())
        #expect(entries.count == 2)
        let vehicles = try garage.context.fetch(FetchDescriptor<Vehicle>())
        #expect(vehicles.count == 1)
        #expect(vehicles.first?.entries.count == 2)
        #expect(
            entries.allSatisfy { $0.vehicle != nil && $0.vehicle?.id == $0.session?.vehicle?.id }
                == true)
        #expect(
            sessions.first(where: { $0.title == "Resolved" })?.closedAt
                == Date(timeIntervalSince1970: 42))
        #expect(sessions.first(where: { $0.title == "Open" })?.closedAt == nil)
        #expect(sessions.allSatisfy { $0.timeline.count == 1 } == true)
    }

    /// Writes a schema v1 library the way the shipped app did, and closes it before returning.
    private static func writeV1Library(at url: URL) throws {
        let schema = Schema(versionedSchema: SpiaSchemaV1.self)
        let container = try ModelContainer(
            for: schema, configurations: ModelConfiguration(schema: schema, url: url))
        let context = ModelContext(container)
        let vehicle = SpiaSchemaV1.Vehicle(name: "Old car")
        let open = SpiaSchemaV1.DiagnosticSession(title: "Open")
        let resolved = SpiaSchemaV1.DiagnosticSession(title: "Resolved")
        resolved.status = .resolved
        resolved.updatedAt = Date(timeIntervalSince1970: 42)
        let note = SpiaSchemaV1.TimelineEntry(kind: .note, title: "Note")
        let reading = SpiaSchemaV1.TimelineEntry(kind: .result, title: "Reading")
        context.insert(vehicle)
        vehicle.sessions = [open, resolved]
        open.entries = [note]
        resolved.entries = [reading]
        try context.save()
    }

    @Test("a vehicle board folds readings as of a historical date")
    func boardAsOf() throws {
        let container = try Garage.inMemoryContainer()
        let garage = Garage(
            context: container.mainContext, files: SpiaFiles(root: .temporaryDirectory))
        let vehicle = try garage.addVehicle(name: "Car")
        let firstDate = Date(timeIntervalSince1970: 10)
        let secondDate = Date(timeIntervalSince1970: 20)
        let first = result(date: firstDate, voltage: 11)
        let second = result(date: secondDate, voltage: 16)
        first.vehicle = vehicle
        second.vehicle = vehicle
        vehicle.entries = [first, second]
        try garage.context.save()
        #expect(vehicle.board(asOf: Date(timeIntervalSince1970: 15)).rows.first?.status == .low)
        #expect(vehicle.board().rows.first?.status == .high)
        let session = try garage.addSession(to: vehicle, title: "Closed")
        session.status = .resolved
        session.closedAt = Date(timeIntervalSince1970: 15)
        #expect(session.board(live: AdapterStatus(identity: "live")).rows.first?.status == .low)
    }

    @Test("vehicle history keeps entry ownership and supports historical dates")
    func historyOwnershipAndAsOf() throws {
        let container = try Garage.inMemoryContainer()
        let garage = Garage(
            context: container.mainContext, files: SpiaFiles(root: .temporaryDirectory))
        let vehicle = try garage.addVehicle(name: "Car")
        let problem = try garage.addSession(to: vehicle, title: "Battery concern")
        let firstDate = Date(timeIntervalSince1970: 10)
        let secondDate = Date(timeIntervalSince1970: 20)
        let firstResult = JobResult(
            job: .adapterCheck,
            payload: .adapter(AdapterStatus(identity: "adapter", voltage: 12.4)),
            source: .live,
            transcript: nil)
        let secondResult = JobResult(
            job: .adapterCheck,
            payload: .adapter(AdapterStatus(identity: "adapter", voltage: 12.7)),
            source: .live,
            transcript: nil)

        try garage.record(firstResult, warnings: [], transcriptPath: nil, for: vehicle, in: problem)
        let firstEntry = try #require(vehicle.entries.last)
        firstEntry.date = firstDate
        try garage.record(secondResult, warnings: [], transcriptPath: nil, for: vehicle, in: nil)
        let secondEntry = try #require(vehicle.entries.first { $0.id != firstEntry.id })
        secondEntry.date = secondDate
        try garage.context.save()

        let history = vehicle.history(for: .battery)
        #expect(history.readings.count == 2)
        #expect(history.readings.map(\.date) == [secondDate, firstDate])
        let entries = try history.readings.map { try #require(vehicle.entry(for: $0)) }
        #expect(entries.map(\.id) == [secondEntry.id, firstEntry.id])
        #expect(entries.filter { $0.session?.title == problem.title }.count == 1)

        let historical = vehicle.history(for: .battery, asOf: Date(timeIntervalSince1970: 15))
        #expect(historical.readings.count == 1)
        #expect(historical.readings.first?.id == firstEntry.id)
    }

    @Test("deleting a problem keeps readings and removes notes and attachments")
    func deletingProblemKeepsReadings() throws {
        let container = try Garage.inMemoryContainer()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let garage = Garage(context: container.mainContext, files: SpiaFiles(root: root))
        let vehicle = try garage.addVehicle(name: "Car")
        let session = try garage.addSession(to: vehicle, title: "Problem")
        try garage.record(
            JobResult(
                job: .adapterCheck, payload: .adapter(AdapterStatus(identity: "a")), source: .live,
                transcript: nil),
            warnings: [], transcriptPath: "Transcripts/\(vehicle.id.uuidString)/reading.txt",
            for: vehicle, in: session)
        try garage.addNote("keep the log useful", to: session)
        let attachment = garage.files.url(
            for: garage.files.attachmentPath(session: session.id, name: "photo.jpg"))
        try FileManager.default.createDirectory(
            at: attachment.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("photo".utf8).write(to: attachment)
        try garage.delete(session)
        #expect(vehicle.entries.count == 1)
        #expect(vehicle.entries.first?.session == nil)
        #expect(vehicle.entries.first?.kind == .result)
        #expect(
            !FileManager.default.fileExists(atPath: attachment.deletingLastPathComponent().path))
    }

    @Test("deleting a vehicle removes current and legacy transcript folders")
    func deletingVehicleRemovesLegacyTranscripts() throws {
        let container = try Garage.inMemoryContainer()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let garage = Garage(context: container.mainContext, files: SpiaFiles(root: root))
        let vehicle = try garage.addVehicle(name: "Car")
        let session = try garage.addSession(to: vehicle, title: "Problem")
        let current = garage.files.transcriptFolder(for: vehicle.id)
        let legacy = root.appendingPathComponent("Transcripts/\(session.id.uuidString)")
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try garage.delete(vehicle)
        #expect(!FileManager.default.fileExists(atPath: current.path))
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
    }
}
