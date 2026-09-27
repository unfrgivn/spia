import Foundation
import OBDSerial
import Observation
import SpiaKit
import SpiaStore
import SwiftData

/// App-wide state: the garage, and one workbench per adapter so a connection survives
/// switching between sessions of the same vehicle.
@MainActor
@Observable
final class AppModel {
    let container: ModelContainer
    let garage: Garage
    private var workbenches: [UUID: Workbench] = [:]

    init(container: ModelContainer, files: SpiaFiles) {
        self.container = container
        garage = Garage(context: container.mainContext, files: files)
    }

    static func live() throws -> AppModel {
        try AppModel(container: Garage.container(), files: SpiaFiles.standard())
    }

    /// The workbench for the vehicle's primary adapter, created on first use.
    func workbench(for vehicle: Vehicle) -> Workbench? {
        guard let profile = vehicle.adapters.first else { return nil }
        if let existing = workbenches[profile.id] { return existing }
        let workbench = Workbench(backend: Self.backend(for: profile), garage: garage)
        workbenches[profile.id] = workbench
        return workbench
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
            let path = profile.devicePath ?? ""
            let baud = profile.baud
            return LiveBackend(adapter: profile.descriptor, baud: baud) {
                guard !path.isEmpty else { throw AdapterSetupError.noPortChosen }
                return SerialTransport(path: path, baud: baud)
            }
        }
    }

    /// USB serial devices that look like OBD adapters come first.
    static func serialPorts() -> [String] {
        SerialTransport.availablePorts().sorted { lhs, rhs in
            let lhsUSB = lhs.contains("usbserial") || lhs.contains("usbmodem")
            let rhsUSB = rhs.contains("usbserial") || rhs.contains("usbmodem")
            return lhsUSB == rhsUSB ? lhs < rhs : lhsUSB
        }
    }
}

enum AdapterSetupError: Error, CustomStringConvertible {
    case noPortChosen

    var description: String {
        switch self {
        case .noPortChosen: return "Choose the adapter's USB port first."
        }
    }
}
