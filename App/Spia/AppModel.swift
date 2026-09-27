import Foundation
import Observation
import SpiaAssist
import SpiaKit
import SpiaStore
import SwiftData

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
    private var workbenches: [UUID: Workbench] = [:]
    private var conversations: [UUID: AssistantConversation] = [:]
    private var referenceSets: [UUID: VehicleReferences] = [:]

    init(
        container: ModelContainer, files: SpiaFiles,
        assistant: AssistantConfiguration = AssistantConfiguration()
    ) {
        self.container = container
        self.assistant = assistant
        garage = Garage(context: container.mainContext, files: files)
    }

    static func live() throws -> AppModel {
        let files = try SpiaFiles.standard()
        return try AppModel(container: Garage.container(at: files), files: files)
    }

    /// The workbench for the vehicle's primary adapter, created on first use.
    func workbench(for vehicle: Vehicle) -> Workbench? {
        guard let profile = vehicle.adapters.first else { return nil }
        if let existing = workbenches[profile.id] { return existing }
        let workbench = Workbench(backend: Self.backend(for: profile), garage: garage)
        workbenches[profile.id] = workbench
        return workbench
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

    func delete(_ session: DiagnosticSession) throws {
        conversations.removeValue(forKey: session.id)?.stop()
        try garage.delete(session)
    }

    func delete(_ vehicle: Vehicle) throws {
        for session in vehicle.sessions { conversations.removeValue(forKey: session.id)?.stop() }
        referenceSets.removeValue(forKey: vehicle.id)
        try garage.delete(vehicle)
    }

    /// Call after changing a profile's port or baud so the next connection uses them.
    func resetConnection(for profile: AdapterProfile) async {
        if let existing = workbenches.removeValue(forKey: profile.id) {
            await existing.disconnect()
        }
    }

    private static func backend(for profile: AdapterProfile) -> any DiagnosticsBackend {
        switch profile.kind {
        case .demo:
            return DemoBackend()
        case .usbSerial, .bluetooth:
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
                "This adapter works with Spia on a Mac. iPhone support for Bluetooth adapters is planned."
        }
    }
}
