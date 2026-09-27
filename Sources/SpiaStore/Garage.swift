import Foundation
import SpiaKit
import SwiftData

/// Where the app keeps files that don't belong in the database: per session, the raw
/// transcripts (so every result can be replayed or inspected later) and attached photos.
public struct SpiaFiles: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    /// `~/Library/Application Support/Spia` (inside the sandbox container when sandboxed).
    public static func standard() throws -> SpiaFiles {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil,
            create: true)
        return SpiaFiles(root: support.appendingPathComponent("Spia", isDirectory: true))
    }

    public func transcriptPath(session: UUID, entry: UUID) -> String {
        "Transcripts/\(session.uuidString)/\(entry.uuidString).txt"
    }

    /// The database of vehicles, sessions, and conversations.
    public var storeURL: URL { root.appendingPathComponent("Library.store") }

    public func url(for relativePath: String) -> URL {
        root.appendingPathComponent(relativePath)
    }

    public func attachmentPath(session: UUID, name: String) -> String {
        "Attachments/\(session.uuidString)/\(name)"
    }

    /// Every folder holding a session's files.
    public func folders(for session: UUID) -> [URL] {
        ["Transcripts", "Attachments"].map {
            root.appendingPathComponent("\($0)/\(session.uuidString)", isDirectory: true)
        }
    }
}

/// All reads and writes of the user's vehicles and sessions.
@MainActor
public final class Garage {
    public let context: ModelContext
    public let files: SpiaFiles

    public init(context: ModelContext, files: SpiaFiles) {
        self.context = context
        self.files = files
    }

    /// The library stored in `files`. Always an explicit path: SwiftData's default is a
    /// `default.store` shared by every unsandboxed app, and opening another app's store migrates
    /// it to this schema, deleting that app's data.
    public static func container(at files: SpiaFiles) throws -> ModelContainer {
        try FileManager.default.createDirectory(at: files.root, withIntermediateDirectories: true)
        return try container(ModelConfiguration(schema: schema, url: files.storeURL))
    }

    /// A library that lives only as long as the process, for tests.
    public static func inMemoryContainer() throws -> ModelContainer {
        try container(ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
    }

    private static let schema = Schema(versionedSchema: SpiaSchemaV1.self)

    private static func container(_ configuration: ModelConfiguration) throws -> ModelContainer {
        try ModelContainer(
            for: schema, migrationPlan: SpiaMigrationPlan.self, configurations: configuration)
    }

    @discardableResult
    public func addVehicle(name: String, vin: String? = nil) throws -> Vehicle {
        let vehicle = Vehicle(name: name, vin: vin)
        context.insert(vehicle)
        vehicle.adapters.append(AdapterProfile(kind: .usbSerial, name: "USB adapter"))
        try context.save()
        return vehicle
    }

    /// The 2017 Ghibli, with the modules found on it. Checks replay the car's recordings.
    @discardableResult
    public func addDemoVehicle() throws -> Vehicle {
        let vehicle = Vehicle(
            name: DemoGarage.vehicleName, vin: DemoGarage.vin,
            notes:
                "Recorded on the car on 2026-09-26. Wheel controls and horn dead, airbag lamp on.",
            isDemo: true)
        context.insert(vehicle)
        vehicle.adapters.append(AdapterProfile(kind: .demo, name: DemoGarage.adapter.displayName))
        for (position, module) in DemoGarage.modules.enumerated() {
            vehicle.modules.append(
                ModulePreset(label: module.label, target: module.target, position: position))
        }
        let session = DiagnosticSession(
            title: "Dead steering-wheel controls",
            problem:
                "Horn, cruise, volume, and cluster buttons on the wheel don't work. Airbag warning light is on. Paddles and wipers work."
        )
        vehicle.sessions.append(session)
        try context.save()
        return vehicle
    }

    @discardableResult
    public func addSession(to vehicle: Vehicle, title: String, problem: String = "") throws
        -> DiagnosticSession
    {
        let session = DiagnosticSession(title: title, problem: problem)
        vehicle.sessions.append(session)
        try context.save()
        return session
    }

    public func addNote(_ text: String, to session: DiagnosticSession) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        append(TimelineEntry(kind: .note, title: "Note", body: trimmed), to: session)
        try context.save()
    }

    /// Reserves the transcript file for a check that is about to run.
    public func newTranscript(for session: DiagnosticSession) -> (path: String, url: URL) {
        let path = files.transcriptPath(session: session.id, entry: UUID())
        return (path, files.url(for: path))
    }

    public func record(
        _ result: JobResult, warnings: [String], transcriptPath: String?,
        in session: DiagnosticSession
    ) throws {
        let entry = TimelineEntry(
            kind: .result, title: result.job.title, body: ResultText.summary(result))
        entry.resultData = try JSONEncoder().encode(result)
        entry.warnings = warnings
        entry.transcriptPath = result.transcript == nil ? nil : transcriptPath
        append(entry, to: session)
        try context.save()
    }

    public func recordFailure(
        of job: DiagnosticJob, _ failure: JobFailure, warnings: [String], transcriptPath: String?,
        in session: DiagnosticSession
    ) throws {
        let entry = TimelineEntry(kind: .failure, title: job.title, body: failure.message)
        entry.warnings = warnings
        entry.transcriptPath = failure.transcript == nil ? nil : transcriptPath
        append(entry, to: session)
        try context.save()
    }

    /// Deletes the vehicle, its sessions and history, and their files.
    public func delete(_ vehicle: Vehicle) throws {
        let folders = vehicle.sessions.flatMap { files.folders(for: $0.id) }
        context.delete(vehicle)
        try context.save()
        try removeFolders(folders)
    }

    /// Deletes the session, its history and conversation, and its transcript and photo files.
    public func delete(_ session: DiagnosticSession) throws {
        let folders = files.folders(for: session.id)
        context.delete(session)
        try context.save()
        try removeFolders(folders)
    }

    private func removeFolders(_ folders: [URL]) throws {
        for folder in folders where FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder)
        }
    }

    private func append(_ entry: TimelineEntry, to session: DiagnosticSession) {
        session.entries.append(entry)
        session.updatedAt = entry.date
    }
}
