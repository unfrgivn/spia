import Foundation
import SpiaKit
import SwiftData

/// Where the app keeps files that don't belong in the database: one folder per session of
/// raw transcripts, so every result can be replayed or inspected later.
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

    public func url(for relativePath: String) -> URL {
        root.appendingPathComponent(relativePath)
    }

    public func sessionFolder(_ session: UUID) -> URL {
        root.appendingPathComponent("Transcripts/\(session.uuidString)", isDirectory: true)
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

    public static func container(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema(versionedSchema: SpiaSchemaV1.self)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
        return try ModelContainer(
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
            name: "\(DemoGarage.vehicleName) (demo)", vin: DemoGarage.vin,
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

    /// Deletes the vehicle, its sessions and history, and their transcript files.
    public func delete(_ vehicle: Vehicle) throws {
        let folders = vehicle.sessions.map { files.sessionFolder($0.id) }
        context.delete(vehicle)
        try context.save()
        for folder in folders where FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder)
        }
    }

    public func delete(_ session: DiagnosticSession) throws {
        let folder = files.sessionFolder(session.id)
        context.delete(session)
        try context.save()
        if FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder)
        }
    }

    private func append(_ entry: TimelineEntry, to session: DiagnosticSession) {
        session.entries.append(entry)
        session.updatedAt = entry.date
    }
}
