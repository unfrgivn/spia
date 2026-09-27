import SpiaKit
import SpiaStore
import SwiftData
import SwiftUI

@main
struct SpiaApp: App {
    @State private var model: AppModel?
    @State private var startupError: String?

    var body: some Scene {
        WindowGroup {
            Group {
                if let model {
                    ContentView()
                        .environment(model)
                        .modelContainer(model.container)
                } else if let startupError {
                    ContentUnavailableView(
                        "Spia couldn't open its library",
                        systemImage: "externaldrive.badge.exclamationmark",
                        description: Text(startupError))
                } else {
                    ProgressView()
                }
            }
            .frame(minWidth: 900, minHeight: 600)
            .task {
                guard model == nil, startupError == nil else { return }
                do {
                    model = try AppModel.live()
                } catch {
                    startupError = String(describing: error)
                }
            }
        }
        .windowToolbarStyle(.unified)

        Settings {
            if let model {
                AssistantSettingsView()
                    .environment(model)
            }
        }
    }
}

/// The garage until a vehicle is opened; then that vehicle's workspace.
struct ContentView: View {
    @Query(sort: \Vehicle.createdAt) private var vehicles: [Vehicle]
    /// The open vehicle, kept per window across launches.
    @SceneStorage("openVehicle") private var openVehicleID = ""
    @State private var initialSection: WorkspaceSection?

    var body: some View {
        if let vehicle = vehicles.first(where: { $0.id.uuidString == openVehicleID }) {
            VehicleWorkspace(
                vehicle: vehicle, leave: { openVehicleID = "" }, selection: initialSection
            )
            .id(vehicle.id)
        } else {
            NavigationStack {
                GarageView { vehicle, session in
                    initialSection = session.map { .session($0.id) } ?? .overview
                    openVehicleID = vehicle.id.uuidString
                }
            }
        }
    }
}
