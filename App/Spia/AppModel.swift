import Foundation
import OBDCore
import Observation
import SpiaAssist
import SpiaKit
import SpiaStore
import SwiftData
import OBDBluetooth

#if os(macOS)
    import OBDSerial
#endif

/// App-wide state: the garage, one workbench per adapter so a connection survives switching
/// between sessions of the same vehicle, one assistant conversation per session so a reply
/// keeps arriving while the user looks elsewhere, and one set of references per vehicle.
@MainActor
@Observable
final class AppModel {
    let container: ModelContainer
    let garage: Garage
    let assistant: AssistantConfiguration
    let replayTiming: ReplayTiming
    private var workbenches: [UUID: Workbench] = [:]
    private var recordingWorkbenches: [UUID: Workbench] = [:]
    private var recordingsActive: Set<UUID> = []
    private var conversations: [UUID: AssistantConversation] = [:]
    private var referenceSets: [UUID: VehicleReferences] = [:]
    /// Loaded on first use. Not observed: building a plan while a menu is drawn fills it in, and
    /// that must not count as a change to redraw for.
    @ObservationIgnored private var surveyCatalog: ModuleCatalog?
    @ObservationIgnored private var surveyCatalogError: String?
    private var pendingSurveySessions: Set<UUID> = []
    private let savedChecksProvider: (() -> [SavedCheck])?

    init(
        container: ModelContainer, files: SpiaFiles,
        assistant: AssistantConfiguration = AssistantConfiguration(),
        replayTiming: ReplayTiming = .recorded,
        savedChecksProvider: (() -> [SavedCheck])? = nil
    ) {
        self.container = container
        self.assistant = assistant
        self.replayTiming = replayTiming
        self.savedChecksProvider = savedChecksProvider
        garage = Garage(context: container.mainContext, files: files)
    }

    static func live() throws -> AppModel {
        let files = try SpiaFiles.standard()
        return try AppModel(container: Garage.container(at: files), files: files)
    }

    /// The workbench for the vehicle's primary adapter, created on first use.
    func workbench(for vehicle: Vehicle) -> Workbench? {
        guard let profile = vehicle.adapters.first else { return nil }
        if recordingsActive.contains(vehicle.id) {
            return recordingWorkbenches[vehicle.id]
        }
        if let existing = workbenches[profile.id] { return existing }
        let workbench = Workbench(
            backend: Self.backend(for: profile, replayTiming: replayTiming), garage: garage)
        workbenches[profile.id] = workbench
        return workbench
    }

    func savedChecks(for vehicle: Vehicle) -> [SavedCheck] {
        #if DEBUG
            savedChecksProvider?() ?? garage.savedChecks(for: vehicle)
        #else
            garage.savedChecks(for: vehicle)
        #endif
    }

    func useRecordings(for vehicle: Vehicle) async -> Workbench? {
        guard let profile = vehicle.adapters.first else { return nil }
        let checks = savedChecks(for: vehicle)
        guard !checks.isEmpty else { return nil }
        if let existing = recordingWorkbenches[vehicle.id] {
            recordingsActive.insert(vehicle.id)
            return existing
        }
        if let existing = workbenches.removeValue(forKey: profile.id) {
            await existing.disconnect()
        }
        return prepareRecordings(for: vehicle, checks: checks)
    }

    func prepareRecordings(for vehicle: Vehicle) -> Workbench? {
        let checks = savedChecks(for: vehicle)
        guard !checks.isEmpty else { return nil }
        return prepareRecordings(for: vehicle, checks: checks)
    }

    private func prepareRecordings(for vehicle: Vehicle, checks: [SavedCheck]) -> Workbench {
        let workbench = Workbench(
            backend: ReplayBackend(
                displayName: "Saved recordings", checks: checks, timing: replayTiming),
            garage: garage)
        recordingWorkbenches[vehicle.id] = workbench
        recordingsActive.insert(vehicle.id)
        return workbench
    }

    func useProfile(for vehicle: Vehicle) async -> Workbench? {
        guard vehicle.adapters.first != nil else { return nil }
        recordingsActive.remove(vehicle.id)
        if let existing = recordingWorkbenches.removeValue(forKey: vehicle.id) {
            await existing.disconnect()
        }
        return workbench(for: vehicle)
    }

    func conversation(for session: DiagnosticSession) -> AssistantConversation {
        if let existing = conversations[session.id] { return existing }
        let conversation = AssistantConversation(
            session: session, garage: garage, configuration: assistant)
        conversations[session.id] = conversation
        return conversation
    }

    func references(for vehicle: Vehicle) -> VehicleReferences {
        if let existing = referenceSets[vehicle.id] { return existing }
        let references = VehicleReferences(vehicleID: vehicle.id, files: garage.files)
        referenceSets[vehicle.id] = references
        return references
    }

    func surveyPlan(for vehicle: Vehicle, workbench: Workbench) throws -> SurveyPlan {
        let catalog: ModuleCatalog
        if let surveyCatalog {
            catalog = surveyCatalog
        } else if let surveyCatalogError {
            throw SurveySetupError(surveyCatalogError)
        } else {
            do {
                catalog = try ModuleCatalog.bundled()
                surveyCatalog = catalog
            } catch {
                let message = "The vehicle survey catalog couldn't be loaded: \(error.readable)"
                surveyCatalogError = message
                throw SurveySetupError(message)
            }
        }
        let identity = references(for: vehicle).identity
        return try SurveyPlanner.plan(
            catalog: catalog,
            vehicle: identity.map(CatalogVehicle.init),
            reachableBuses: SurveyPlanner.reachableBuses(for: workbench.connection.status),
            savedModules: vehicle.orderedModules.compactMap { module in
                module.target.map {
                    ModuleChoice(target: $0, label: module.label, confirmed: module.confirmed)
                }
            })
    }

    func requestSurvey(for session: DiagnosticSession) {
        pendingSurveySessions.insert(session.id)
    }

    func consumeSurveyRequest(for session: DiagnosticSession) -> Bool {
        pendingSurveySessions.remove(session.id) != nil
    }

    func hasSurveyRequest(for session: DiagnosticSession) -> Bool {
        pendingSurveySessions.contains(session.id)
    }

    func cancelSurveyRequest(for session: DiagnosticSession) {
        pendingSurveySessions.remove(session.id)
    }

    func delete(_ session: DiagnosticSession) throws {
        conversations.removeValue(forKey: session.id)?.stop()
        try garage.delete(session)
    }

    func delete(_ vehicle: Vehicle) throws {
        for session in vehicle.sessions { conversations.removeValue(forKey: session.id)?.stop() }
        recordingsActive.remove(vehicle.id)
        recordingWorkbenches.removeValue(forKey: vehicle.id)
        referenceSets.removeValue(forKey: vehicle.id)
        try garage.delete(vehicle)
    }

    /// Call after changing a profile's port or baud so the next connection uses them.
    func resetConnection(for profile: AdapterProfile) async {
        if let existing = workbenches.removeValue(forKey: profile.id) {
            await existing.disconnect()
        }
    }

    private static func backend(
        for profile: AdapterProfile, replayTiming: ReplayTiming
    ) -> any DiagnosticsBackend {
        switch profile.kind {
        case .demo:
            return DemoBackend(timing: replayTiming)
        case .usbSerial:
            #if os(iOS)
                return LiveBackend(adapter: profile.descriptor, baud: profile.baud) {
                    throw AdapterSetupError.needsMac
                }
            #else
                let path = profile.devicePath ?? ""
                let baud = profile.baud
                return LiveBackend(adapter: profile.descriptor, baud: baud) {
                    guard !path.isEmpty else { throw AdapterSetupError.noPortChosen }
                    return SerialTransport(path: path, baud: baud)
                }
            #endif
        case .bluetooth:
            let identifier = profile.devicePath.flatMap(UUID.init(uuidString:))
            return LiveBackend(adapter: profile.descriptor, baud: profile.baud) {
                BLETransport(identifier: identifier)
            }
        }
    }

    /// USB serial devices that look like OBD adapters come first.
    static func serialPorts() -> [String] {
        #if os(iOS)
            return []
        #else
            SerialTransport.availablePorts().sorted { lhs, rhs in
                let lhsUSB = lhs.contains("usbserial") || lhs.contains("usbmodem")
                let rhsUSB = rhs.contains("usbserial") || rhs.contains("usbmodem")
                return lhsUSB == rhsUSB ? lhs < rhs : lhsUSB
            }
        #endif
    }
}

enum AdapterSetupError: Error, CustomStringConvertible {
    case noPortChosen
    case needsMac

    var description: String {
        switch self {
        case .noPortChosen: return "Choose the adapter's USB port first."
        case .needsMac:
            return
                "USB adapters work with Spia on a Mac. iPhone and iPad need a Bluetooth LE adapter such as the vLinker FS in BLE+BT mode."
        }
    }
}

private struct SurveySetupError: Error, CustomStringConvertible {
    let message: String

    init(_ message: String) { self.message = message }

    var description: String { message }
}
