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
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \Vehicle.createdAt) private var vehicles: [Vehicle]
    @State private var selection: UUID?
    @State private var editingVehicle = false
    @State private var problem: String?

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection, addVehicle: { editingVehicle = true })
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            if let session = selectedSession {
                SessionView(session: session)
                    .id(session.id)
            } else if vehicles.isEmpty {
                WelcomeView(addVehicle: { editingVehicle = true }, addDemo: addDemo)
            } else {
                ContentUnavailableView(
                    "Choose a session", systemImage: "stethoscope",
                    description: Text(
                        "Pick a session in the sidebar, or start a new one for a vehicle."))
            }
        }
        .sheet(isPresented: $editingVehicle) {
            VehicleEditor { vehicle in
                selection = vehicle.orderedSessions.first?.id
            }
        }
        .errorAlert($problem)
    }

    private var selectedSession: DiagnosticSession? {
        guard let selection else { return nil }
        return vehicles.lazy.flatMap(\.sessions).first { $0.id == selection }
    }

    private func addDemo() {
        do {
            selection = try model.garage.addDemoVehicle().orderedSessions.first?.id
        } catch {
            problem = String(describing: error)
        }
    }
}
