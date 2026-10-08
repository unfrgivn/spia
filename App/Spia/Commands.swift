import SpiaKit
import SpiaStore
import SwiftUI

/// What the menu bar can do in the key window's garage.
struct GarageActions {
    let addVehicle: () -> Void
}

/// What the menu bar can do in the key window's vehicle.
struct WorkspaceActions {
    let show: (WorkspaceSection) -> Void
    let newSession: () -> Void
    let showGarage: () -> Void
}

/// What the menu bar can do in the key window's session, worked out when the session is drawn
/// so the menus follow the adapter without watching it themselves.
struct SessionActions {
    /// A check that can run now, or nil for one that can't: not connected, busy, or not in the
    /// demo's recordings.
    struct Check {
        let job: DiagnosticJob
        let title: String
        let perform: (() -> Void)?
    }

    let connected: Bool
    let assistantShown: Bool
    let toggleAssistant: () -> Void
    let connect: () -> Void
    let checks: [Check]
    let scan: (() -> Void)?
    let deepScan: (() -> Void)?
    let editModules: (() -> Void)?
    let rename: () -> Void
    let resolve: (() -> Void)?
    let reopen: (() -> Void)?
    let moduleChecks: [Check]
}

extension DiagnosticJob {
    /// The check's name as a menu item, in the title case menus use.
    var menuTitle: String {
        switch self {
        case .adapterCheck: "Adapter and battery"
        case .vehicleInfo: "Vehicle information"
        case .genericScan: "Engine and transmission codes"
        case .moduleDTCs: "Module codes"
        case .survey: "Modules and their codes"
        }
    }
}

extension FocusedValues {
    @Entry var garage: GarageActions?
    @Entry var workspace: WorkspaceActions?
    @Entry var session: SessionActions?
}

/// The menu bar's way to everything the toolbar and board do, with keys: ⌘N for a session and
/// ⇧⌘N for a vehicle, ⌘1 to ⌘3 for a vehicle's pages, ⌥⌘I for the assistant, ⌘K to connect,
/// and ⌘R for Scan Car.
struct SpiaCommands: Commands {
    @FocusedValue(\.garage) private var garage
    @FocusedValue(\.workspace) private var workspace
    @FocusedValue(\.session) private var session
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        SidebarCommands()
        CommandGroup(replacing: .newItem) {
            Button("New Problem") { workspace?.newSession() }
                .keyboardShortcut("n")
                .disabled(workspace == nil)
            Button("New Vehicle…") { garage?.addVehicle() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(garage == nil)
            Divider()
            Button("New Window") { openWindow(id: SpiaApp.mainWindow) }
                .keyboardShortcut("n", modifiers: [.command, .option])
        }
        CommandGroup(after: .sidebar) {
            Button(session?.assistantShown == true ? "Hide Assistant" : "Show Assistant") {
                session?.toggleAssistant()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(session == nil)
            Divider()
            Button("Overview") { workspace?.show(.overview) }
                .keyboardShortcut("1")
                .disabled(workspace == nil)
            Button("References") { workspace?.show(.references) }
                .keyboardShortcut("2")
                .disabled(workspace == nil)
            Button("Photos") { workspace?.show(.photos) }
                .keyboardShortcut("3")
                .disabled(workspace == nil)
            Button("Garage") { workspace?.showGarage() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(workspace == nil)
            Divider()
        }
        CommandMenu("Problem") {
            Button("Rename Problem…") { session?.rename() }
                .disabled(session == nil)
            Button("Resolve Problem…") { session?.resolve?() }
                .disabled(session?.resolve == nil)
            Button("Reopen Problem") { session?.reopen?() }
                .disabled(session?.reopen == nil)
            Divider()
            Button(session?.connected == true ? "Connection…" : "Connect…") { session?.connect() }
                .keyboardShortcut("k")
                .disabled(session == nil)
            Divider()
            Button("Scan Car") { session?.scan?() }
                .keyboardShortcut("r")
                .disabled(session?.scan == nil)
            Button("Deep Scan…") { session?.deepScan?() }
                .disabled(session?.deepScan == nil)
            Divider()
            Menu("Advanced") {
                ForEach(session?.checks ?? [], id: \.title) { check in
                    Button(check.title) { check.perform?() }
                        .disabled(check.perform == nil)
                }
                Divider()
                Menu("Modules") {
                    ForEach(session?.moduleChecks ?? [], id: \.title) { check in
                        Button(check.title) { check.perform?() }
                            .disabled(check.perform == nil)
                    }
                }
                .disabled(session?.moduleChecks.isEmpty ?? true)
                Button("Edit Modules…") { session?.editModules?() }
                    .disabled(session?.editModules == nil)
            }
        }
    }
}
