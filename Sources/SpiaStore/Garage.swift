import CryptoKit
import Foundation
import OBDCore
import SpiaKit
import SwiftData

/// Where the app keeps files that don't belong in the database: per vehicle transcripts and
/// per-problem attachments.
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

    public func transcriptPath(vehicle: UUID, entry: UUID) -> String {
        "Transcripts/\(vehicle.uuidString)/\(entry.uuidString).txt"
    }

    /// The database of vehicles, sessions, and conversations.
    public var storeURL: URL { root.appendingPathComponent("Library.store") }

    public func url(for relativePath: String) -> URL {
        root.appendingPathComponent(relativePath)
    }

    public func attachmentPath(session: UUID, name: String) -> String {
        "Attachments/\(session.uuidString)/\(name)"
    }

    /// The owner's photos of a vehicle. Their data, unlike `References`.
    public func vehicleFolder(_ vehicle: UUID) -> URL {
        root.appendingPathComponent("Vehicles/\(vehicle.uuidString)", isDirectory: true)
    }

    public func vehicleImagePath(vehicle: UUID, name: String) -> String {
        "Vehicles/\(vehicle.uuidString)/Photos/\(name)"
    }

    /// Every folder holding files that belong to the session alone. Transcripts are the car's
    /// and are not here.
    public func folders(for session: UUID) -> [URL] {
        [root.appendingPathComponent("Attachments/\(session.uuidString)", isDirectory: true)]
    }

    public func transcriptFolder(for vehicle: UUID) -> URL {
        root.appendingPathComponent("Transcripts/\(vehicle.uuidString)", isDirectory: true)
    }

    /// Where schema v1 kept a session's transcripts. Entries still point into these folders
    /// by path; the folder goes when the vehicle does.
    public func legacyTranscriptFolder(for session: UUID) -> URL {
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

    private static let schema = Schema(versionedSchema: SpiaSchemaV2.self)

    private static func container(_ configuration: ModelConfiguration) throws -> ModelContainer {
        try ModelContainer(
            for: schema, migrationPlan: SpiaMigrationPlan.self, configurations: configuration)
    }

    @discardableResult
    public func addVehicle(name: String, vin: String? = nil, adapterKind: AdapterKind = .usbSerial)
        throws -> Vehicle
    {
        let vehicle = Vehicle(name: name, vin: vin)
        context.insert(vehicle)
        vehicle.adapters.append(
            AdapterProfile(
                kind: adapterKind,
                name: AdapterProfile.defaultName(for: adapterKind)))
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
        vehicle.trim = "S Q4"
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
        let entry = TimelineEntry(kind: .note, title: "Note", body: trimmed)
        entry.vehicle = session.vehicle
        append(entry, to: session)
        try context.save()
    }

    /// Reserves the transcript file for a check that is about to run.
    public func newTranscript(for vehicle: Vehicle) -> (path: String, url: URL) {
        let path = files.transcriptPath(vehicle: vehicle.id, entry: UUID())
        return (path, files.url(for: path))
    }

    /// Finds the newest valid live transcript for each exact job on the vehicle.
    public func savedChecks(for vehicle: Vehicle) -> [SavedCheck] {
        var newest: [DiagnosticJob: SavedCheck] = [:]
        for entry in vehicle.entries where entry.kind == .result {
            guard let result = entry.result, result.source == .live,
                let reference = result.transcript, let path = entry.transcriptPath,
                let data = try? Data(contentsOf: files.url(for: path)),
                data.count == reference.byteCount,
                Self.sha256(data) == reference.sha256,
                Self.isStandaloneTranscript(data)
            else { continue }
            let check = SavedCheck(
                job: result.job, recorded: entry.date, transcript: files.url(for: path))
            if newest[result.job]?.recorded ?? .distantPast < check.recorded {
                newest[result.job] = check
            }
        }
        return newest.values.sorted { $0.recorded < $1.recorded }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isStandaloneTranscript(_ data: Data) -> Bool {
        guard let events = try? Transcript.decodeFile(String(decoding: data, as: UTF8.self)),
            let first = events.first
        else { return false }
        return first.direction == .tx && first.bytes == Array("ATZ\r".utf8)
    }

    public func record(
        _ result: JobResult, warnings: [String], transcriptPath: String?,
        for vehicle: Vehicle, in session: DiagnosticSession? = nil
    ) throws {
        let entry = TimelineEntry(
            kind: .result, title: result.job.title, body: ResultText.summary(result))
        entry.resultData = try JSONEncoder().encode(result)
        entry.warnings = warnings
        entry.transcriptPath = result.transcript == nil ? nil : transcriptPath
        entry.vehicle = vehicle
        if let session { append(entry, to: session) }
        if vehicle.vin == nil, let vin = Self.reportedVIN(result) {
            vehicle.vin = vin
        }
        try context.save()
    }

    public func apply(_ choices: [ModuleChoice], to vehicle: Vehicle) throws {
        var nextPosition = (vehicle.modules.map(\.position).max() ?? -1) + 1
        for choice in choices {
            if let existing = vehicle.modules.first(where: { $0.target == choice.target }) {
                existing.label = choice.label
                existing.confirmed = choice.confirmed
            } else {
                vehicle.modules.append(
                    ModulePreset(
                        label: choice.label, target: choice.target, position: nextPosition,
                        confirmed: choice.confirmed))
                nextPosition += 1
            }
        }
        try context.save()
    }

    /// The VIN a live vehicle-information check or survey read, if the car reported one.
    /// Recordings are never copied into a vehicle.
    public static func reportedVIN(_ result: JobResult) -> String? {
        guard result.source == .live else { return nil }
        let ecus: [ECUIdentity]
        switch result.payload {
        case .vehicleInfo(let reports): ecus = reports
        case .survey(let report): ecus = report.vehicleInfo
        default: return nil
        }
        return ecus.lazy.compactMap { ecu in
            ecu.vin.value?.trimmingCharacters(
                in: .whitespacesAndNewlines.union(.controlCharacters))
        }.first { $0.count == 17 }
    }

    public func recordFailure(
        of job: DiagnosticJob, _ failure: JobFailure, warnings: [String], transcriptPath: String?,
        for vehicle: Vehicle, in session: DiagnosticSession? = nil
    ) throws {
        let entry = TimelineEntry(kind: .failure, title: job.title, body: failure.message)
        entry.warnings = warnings
        entry.transcriptPath = failure.transcript == nil ? nil : transcriptPath
        entry.vehicle = vehicle
        if let session { append(entry, to: session) }
        try context.save()
    }

    /// Deletes the vehicle, its sessions and history, their files, its photos, and its
    /// references.
    public func delete(_ vehicle: Vehicle) throws {
        let folders =
            [files.transcriptFolder(for: vehicle.id)]
            + vehicle.sessions.flatMap { files.folders(for: $0.id) }
            + vehicle.sessions.map { files.legacyTranscriptFolder(for: $0.id) }
            + [files.referencesFolder(vehicle: vehicle.id), files.vehicleFolder(vehicle.id)]
        context.delete(vehicle)
        try context.save()
        try removeFolders(folders)
    }

    /// Deletes the session, its notes, its conversation, and its attachments. Readings taken
    /// during it are the car's and stay, no longer linked to any session.
    public func delete(_ session: DiagnosticSession) throws {
        let folders = files.folders(for: session.id)
        for entry in session.entries where entry.kind == .note {
            context.delete(entry)
        }
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
