import Foundation
import OBDCore
import SpiaAssist
import SpiaKit
import SpiaReference
import SwiftData

public enum SpiaSchemaV2: VersionedSchema {
    public static let versionIdentifier = Schema.Version(2, 0, 0)
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
        /// Everything read from or noted about the car, whichever problem it was for.
        @Relationship(deleteRule: .cascade, inverse: \TimelineEntry.vehicle)
        public var entries: [TimelineEntry] = []
        @Relationship(deleteRule: .cascade, inverse: \VehicleImage.vehicle)
        public var images: [VehicleImage] = []

        public var orderedModules: [ModulePreset] { modules.sorted { $0.position < $1.position } }
        public var orderedEntries: [TimelineEntry] { entries.sorted { $0.date < $1.date } }
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

    /// How this vehicle's adapter is reached.
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

        public static func defaultName(for kind: AdapterKind) -> String {
            switch kind {
            case .usbSerial: return "USB adapter"
            case .bluetooth: return "Bluetooth adapter"
            case .demo: return DemoGarage.adapter.displayName
            }
        }

        public func use(_ kind: AdapterKind) {
            kindRaw = kind.rawValue
            name = Self.defaultName(for: kind)
            devicePath = nil
        }

        public var descriptor: AdapterDescriptor {
            let connectionKind: ConnectionKind
            switch kind {
            case .usbSerial: connectionKind = .usbSerial
            case .bluetooth: connectionKind = .bluetooth
            case .demo: connectionKind = .demo
            }
            return AdapterDescriptor(
                kind: connectionKind, displayName: name, devicePath: devicePath)
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

    /// One problem being worked on: what the user reported, the notes and readings taken for
    /// it, and the conversation about it. The car's state is the vehicle's; this is a view of
    /// it as of the problem.
    @Model public final class DiagnosticSession {
        @Attribute(.unique) public var id: UUID
        public var title: String
        public var problem: String
        public var statusRaw: String
        public var startedAt: Date
        public var updatedAt: Date
        public var closedAt: Date?
        public var resolution: String?
        /// The user agreed that this session's data may be sent to cloud AI providers.
        public var cloudSharingAllowed: Bool = false
        public var vehicle: Vehicle?
        /// Notes and the readings taken for this problem. Deleting the problem unlinks its
        /// readings rather than deleting them; `Garage.delete` removes the notes itself.
        @Relationship(deleteRule: .nullify, inverse: \TimelineEntry.session)
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

        /// Closing records the first close time. Reopening clears it, so the board follows the
        /// current car while a problem is open and the historical car after it is closed.
        public var status: SessionStatus {
            get { SessionStatus(rawValue: statusRaw) ?? .open }
            set {
                statusRaw = newValue.rawValue
                if newValue == .open {
                    closedAt = nil
                } else if closedAt == nil {
                    closedAt = .now
                }
            }
        }

        public var timeline: [TimelineEntry] { entries.sorted { $0.date < $1.date } }
        public var conversation: [ChatMessage] { messages.sorted { $0.sequence < $1.sequence } }
    }

    /// Something learned about the car: a note, a check result, or a failed check. It belongs
    /// to the vehicle, and to the problem it was taken for when there was one.
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
        /// The problem this was taken for, if any. Nil once that problem is deleted.
        public var session: DiagnosticSession?
        public var vehicle: Vehicle?

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

extension SpiaSchemaV2 {
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
