import SpiaKit
import SpiaStore
import SwiftData
import SwiftUI

@main
struct SpiaApp: App {
    @State private var model: AppModel?
    @State private var startupError: String?

    static let mainWindow = "main"

    var body: some Scene {
        WindowGroup(id: Self.mainWindow) {
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
            .platformWindowFrame()
            .tint(Palette.accent)
            .followsAppearanceSetting()
            .task {
                guard model == nil, startupError == nil else { return }
                do {
                    model = try makeModel()
                } catch {
                    startupError = error.readable
                }
            }
        }
        .commands { SpiaCommands() }
        #if os(macOS)
            .windowToolbarStyle(.unified)
        #endif

        #if os(macOS)
            Settings {
                if let model {
                    SettingsView()
                        .environment(model)
                        .followsAppearanceSetting()
                }
            }
        #endif
    }

    private func makeModel() throws -> AppModel {
        #if DEBUG
            if Fixture.enabled { return try Fixture.makeModel() }
        #endif
        return try AppModel.live()
    }
}

/// The garage until a vehicle is opened; then that vehicle's workspace.
struct ContentView: View {
    @Query(sort: \Vehicle.createdAt) private var vehicles: [Vehicle]
    /// The open vehicle, kept per window across launches.
    @SceneStorage("openVehicle") private var openVehicleID = ""
    @State private var initialSection: WorkspaceSection?

    var body: some View {
        #if DEBUG
            Group {
                if Fixture.enabled, Fixture.screen == .settings {
                    NavigationStack { SettingsView() }
                } else {
                    content
                }
            }
            .task { openFixtureScreen() }
        #else
            content
        #endif
    }

    @ViewBuilder private var content: some View {
        if let vehicle = vehicles.first(where: { $0.id.uuidString == openVehicleID }) {
            VehicleWorkspace(
                vehicle: vehicle, leave: { openVehicleID = "" }, switchTo: open,
                selection: initialSection
            )
            .id(vehicle.id)
        } else {
            NavigationStack {
                GarageView { vehicle, session in open(vehicle, at: session) }
            }
        }
    }

    /// Opens `vehicle` in this window, at `session` if given.
    private func open(_ vehicle: Vehicle, at session: DiagnosticSession?) {
        initialSection = session.map { .session($0.id) } ?? .overview
        openVehicleID = vehicle.id.uuidString
    }

    /// Switching to another vehicle picks up its open session, the way Continue does.
    private func open(_ vehicle: Vehicle) {
        open(vehicle, at: vehicle.orderedSessions.first { $0.status == .open })
    }

    #if DEBUG
        private func openFixtureScreen() {
            guard Fixture.enabled else { return }
            #if os(macOS)
                Fixture.sizeWindow()
            #endif
            guard openVehicleID.isEmpty, let vehicle = vehicles.first,
                let section = Fixture.section(for: vehicle)
            else { return }
            initialSection = section
            openVehicleID = vehicle.id.uuidString
        }
    #endif
}
