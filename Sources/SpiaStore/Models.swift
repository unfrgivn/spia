import Foundation
import OBDCore
import SpiaAssist
import SpiaKit
import SpiaReference
import SwiftData

/// Version 1 of the on-disk store. Future versions add a new schema and a migration stage;
/// existing users' garages must always open.
public enum SpiaSchemaV1: VersionedSchema {
    public static let versionIdentifier = Schema.Version(1, 0, 0)
    public static var models: [any PersistentModel.Type] {
        [
            Vehicle.self, AdapterProfile.self, ModulePreset.self, DiagnosticSession.self,
            TimelineEntry.self, ChatMessage.self, VehicleImage.self,
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
        /// The trim as the owner knows it (e.g. `S Q4`); the decoder's is often a package name.
        public var trim: String?
        /// A `PaintColor`. VINs don't encode colour, so only the owner can say.
        public var colorRaw: String?
        /// The maker's paint name, e.g. `Blu Emozione`.
        public var colorName: String?
        /// Which of the owner's photos is the cover; without one, their first photo is.
        public var coverImageID: UUID?
        @Relationship(deleteRule: .cascade, inverse: \AdapterProfile.vehicle)
        public var adapters: [AdapterProfile] = []
        @Relationship(deleteRule: .cascade, inverse: \ModulePreset.vehicle)
        public var modules: [ModulePreset] = []
        @Relationship(deleteRule: .cascade, inverse: \DiagnosticSession.vehicle)
        public var sessions: [DiagnosticSession] = []
        @Relationship(deleteRule: .cascade, inverse: \VehicleImage.vehicle)
        public var images: [VehicleImage] = []

        public var orderedModules: [ModulePreset] { modules.sorted { $0.position < $1.position } }
        public var orderedSessions: [DiagnosticSession] {
            sessions.sorted { $0.updatedAt > $1.updatedAt }
        }
        public var orderedImages: [VehicleImage] { images.sorted { $0.addedAt < $1.addedAt } }

        public var color: PaintColor? {
            get { colorRaw.flatMap(PaintColor.init(rawValue:)) }
            set { colorRaw = newValue?.rawValue }
        }

        /// The owner's photo standing for the vehicle: the one they picked, else their first.
        /// Nil until they add one, when the best reference photo stands in.
        public var coverImage: VehicleImage? {
            images.first { $0.id == coverImageID } ?? orderedImages.first
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
        /// The user agreed that this session's data may be sent to cloud AI providers.
        public var cloudSharingAllowed: Bool = false
        public var vehicle: Vehicle?
        @Relationship(deleteRule: .cascade, inverse: \TimelineEntry.session)
        public var entries: [TimelineEntry] = []
        @Relationship(deleteRule: .cascade, inverse: \ChatMessage.session)
        public var messages: [ChatMessage] = []

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
        public var conversation: [ChatMessage] { messages.sorted { $0.sequence < $1.sequence } }
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

extension SpiaSchemaV1 {
    /// A photo the owner added of their own car. The file is a JPEG under the app's storage
    /// folder, resized and without location metadata.
    @Model public final class VehicleImage {
        @Attribute(.unique) public var id: UUID
        /// Relative to the app's storage folder.
        public var path: String
        public var addedAt: Date
        public var vehicle: Vehicle?

        public init(path: String) {
            id = UUID()
            self.path = path
            addedAt = .now
        }
    }

    /// One turn of the assistant conversation. Tool results are stored as user messages, as the
    /// providers require, and hidden in the UI behind the proposal they answer.
    @Model public final class ChatMessage {
        @Attribute(.unique) public var id: UUID
        /// Position in the conversation; dates can tie.
        public var sequence: Int
        public var date: Date
        public var roleRaw: String
        public var providerRaw: String?
        public var model: String?
        /// `[StoredPart]` as JSON. Images are stored as files and referenced here.
        public var partsData: Data
        /// `[callID: ToolResolution]` as JSON, for assistant messages with tool calls.
        public var resolutionsData: Data?
        public var session: DiagnosticSession?

        public init(
            sequence: Int, role: ConversationRole, parts: [StoredPart], provider: ProviderID? = nil,
            model: String? = nil
        ) {
            id = UUID()
            self.sequence = sequence
            date = .now
            roleRaw = role.rawValue
            providerRaw = provider?.rawValue
            self.model = model
            partsData = (try? JSONEncoder().encode(parts)) ?? Data("[]".utf8)
        }

        public var role: ConversationRole { ConversationRole(rawValue: roleRaw) ?? .user }
        public var provider: ProviderID? { providerRaw.flatMap(ProviderID.init(rawValue:)) }

        public var parts: [StoredPart] {
            (try? JSONDecoder().decode([StoredPart].self, from: partsData)) ?? []
        }

        public var text: String {
            parts.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined(
                separator: "\n\n")
        }

        public var toolCalls: [ToolCall] {
            parts.compactMap { if case .toolCall(let call) = $0 { call } else { nil } }
        }

        public var isToolResultsOnly: Bool {
            !parts.isEmpty && parts.allSatisfy { if case .toolResult = $0 { true } else { false } }
        }

        public var resolutions: [String: ToolResolution] {
            get {
                resolutionsData.flatMap {
                    try? JSONDecoder().decode([String: ToolResolution].self, from: $0)
                } ?? [:]
            }
            set { resolutionsData = try? JSONEncoder().encode(newValue) }
        }
    }
}

/// A message part as stored: images live in files under the app's storage folder.
public enum StoredPart: Codable, Sendable, Equatable {
    case text(String)
    case image(path: String, mediaType: String)
    case toolCall(ToolCall)
    case toolResult(ToolResult)
}

/// What became of a tool call.
public enum ToolResolution: Codable, Sendable, Equatable {
    case pending
    case running
    case completed(summary: String)
    case failed(message: String)
    case declined
    case answered(String)
    /// The user moved on without responding.
    case skipped
    /// The model's call couldn't be used (unknown module, bad arguments).
    case invalid(String)

    public var isOpen: Bool { self == .pending || self == .running }
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
public typealias ChatMessage = SpiaSchemaV1.ChatMessage
public typealias VehicleImage = SpiaSchemaV1.VehicleImage

public enum SpiaMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] { [SpiaSchemaV1.self] }
    public static var stages: [MigrationStage] { [] }
}
