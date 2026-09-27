import Foundation
import OBDCore
import SpiaKit
import SwiftData

/// Version 1 of the on-disk store. Future versions add a new schema and a migration stage;
/// existing users' garages must always open.
public enum SpiaSchemaV1: VersionedSchema {
    public static let versionIdentifier = Schema.Version(1, 0, 0)
    public static var models: [any PersistentModel.Type] {
        [
            Vehicle.self, AdapterProfile.self, ModulePreset.self, DiagnosticSession.self,
            TimelineEntry.self,
        ]
    }

    /// A car the user works on. Each has its own adapters, modules, and history.
    @Model public final class Vehicle {
        @Attribute(.unique) public var id: UUID
        public var name: String
        public var vin: String?
        public var notes: String
        public var createdAt: Date
        /// The bundled 2017 Ghibli whose checks come from real recordings.
        public var isDemo: Bool
        @Relationship(deleteRule: .cascade, inverse: \AdapterProfile.vehicle)
        public var adapters: [AdapterProfile] = []
        @Relationship(deleteRule: .cascade, inverse: \ModulePreset.vehicle)
        public var modules: [ModulePreset] = []
        @Relationship(deleteRule: .cascade, inverse: \DiagnosticSession.vehicle)
        public var sessions: [DiagnosticSession] = []

        public var orderedModules: [ModulePreset] { modules.sorted { $0.position < $1.position } }
        public var orderedSessions: [DiagnosticSession] {
            sessions.sorted { $0.updatedAt > $1.updatedAt }
        }

        public init(name: String, vin: String? = nil, notes: String = "", isDemo: Bool = false) {
            id = UUID()
            self.name = name
            self.vin = vin
            self.notes = notes
            createdAt = .now
            self.isDemo = isDemo
        }
    }

    /// How this vehicle's adapter is reached. A vehicle may have several (USB now, Bluetooth later).
    @Model public final class AdapterProfile {
        @Attribute(.unique) public var id: UUID
        public var kindRaw: String
        public var name: String
        public var devicePath: String?
        public var baud: Int
        public var firmware: String?
        public var hardware: String?
        public var lastConnectedAt: Date?
        public var vehicle: Vehicle?

        public init(kind: AdapterKind, name: String, devicePath: String? = nil, baud: Int = 115_200)
        {
            id = UUID()
            kindRaw = kind.rawValue
            self.name = name
            self.devicePath = devicePath
            self.baud = baud
        }

        public var kind: AdapterKind { AdapterKind(rawValue: kindRaw) ?? .usbSerial }

        public var descriptor: AdapterDescriptor {
            AdapterDescriptor(kind: kind, displayName: name, devicePath: devicePath)
        }
    }

    /// A diagnostic module on this vehicle, addressed by its request and reply IDs.
    @Model public final class ModulePreset {
        @Attribute(.unique) public var id: UUID
        /// Display order within the vehicle; relationships are unordered.
        public var position: Int
        /// The user's name for it. Unconfirmed labels come from references, not from the module.
        public var label: String
        public var busRaw: String
        public var request: Int
        public var response: Int
        public var confirmed: Bool
        public var notes: String
        public var vehicle: Vehicle?

        public init(
            label: String, target: ModuleTarget, position: Int = 0, confirmed: Bool = false,
            notes: String = ""
        ) {
            id = UUID()
            self.position = position
            self.label = label
            busRaw = target.bus.rawValue
            request = Int(target.request)
            response = Int(target.response)
            self.confirmed = confirmed
            self.notes = notes
        }

        /// Nil if the stored IDs were edited into something that is not a single module.
        public var target: ModuleTarget? {
            guard let bus = CANBus(rawValue: busRaw), request >= 0, response >= 0 else {
                return nil
            }
            return try? ModuleTarget(bus: bus, request: UInt32(request), response: UInt32(response))
        }
    }

    /// One problem being worked on: what the user reported, and everything learned since.
    @Model public final class DiagnosticSession {
        @Attribute(.unique) public var id: UUID
        public var title: String
        public var problem: String
        public var statusRaw: String
        public var startedAt: Date
        public var updatedAt: Date
        public var resolution: String?
        public var vehicle: Vehicle?
        @Relationship(deleteRule: .cascade, inverse: \TimelineEntry.session)
        public var entries: [TimelineEntry] = []

        public init(title: String, problem: String = "") {
            id = UUID()
            self.title = title
            self.problem = problem
            statusRaw = SessionStatus.open.rawValue
            startedAt = .now
            updatedAt = .now
        }

        public var status: SessionStatus {
            get { SessionStatus(rawValue: statusRaw) ?? .open }
            set { statusRaw = newValue.rawValue }
        }

        public var timeline: [TimelineEntry] { entries.sorted { $0.date < $1.date } }
    }

    /// Something that happened in a session: a note, a check result, or a failed check.
    @Model public final class TimelineEntry {
        @Attribute(.unique) public var id: UUID
        public var date: Date
        public var kindRaw: String
        public var title: String
        public var body: String
        /// `JobResult` as JSON, for results.
        @Attribute(.externalStorage) public var resultData: Data?
        /// Warnings raised while the check ran, e.g. "No answer to 0A".
        public var warnings: [String]
        /// Transcript path relative to the app's storage folder.
        public var transcriptPath: String?
        public var session: DiagnosticSession?

        public init(kind: EntryKind, title: String, body: String = "", date: Date = .now) {
            id = UUID()
            self.date = date
            kindRaw = kind.rawValue
            self.title = title
            self.body = body
            warnings = []
        }

        public var kind: EntryKind { EntryKind(rawValue: kindRaw) ?? .note }

        /// Nil for notes, and for results written by a future app version this one can't read.
        public var result: JobResult? {
            resultData.flatMap { try? JSONDecoder().decode(JobResult.self, from: $0) }
        }
    }
}

public enum SessionStatus: String, Codable, Sendable, CaseIterable {
    case open, resolved, archived
}

public enum EntryKind: String, Codable, Sendable {
    case note, result, failure
}

public typealias Vehicle = SpiaSchemaV1.Vehicle
public typealias AdapterProfile = SpiaSchemaV1.AdapterProfile
public typealias ModulePreset = SpiaSchemaV1.ModulePreset
public typealias DiagnosticSession = SpiaSchemaV1.DiagnosticSession
public typealias TimelineEntry = SpiaSchemaV1.TimelineEntry

public enum SpiaMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] { [SpiaSchemaV1.self] }
    public static var stages: [MigrationStage] { [] }
}
