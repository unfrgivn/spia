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
    let survey: (() -> Void)?
    let moduleChecks: [Check]
}

extension DiagnosticJob {
    /// The check's name as a menu item, in the title case menus use.
    var menuTitle: String {
        switch self {
        case .adapterCheck: "Check the Adapter"
        case .vehicleInfo: "Read Vehicle Information"
        case .genericScan: "Scan for Engine and Transmission Codes"
        case .moduleDTCs: "Read Module Trouble Codes"
        case .survey: "Survey This Car"
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
/// and ⌘R for the scan everything starts with.
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
            Button(session?.connected == true ? "Connection…" : "Connect…") { session?.connect() }
                .keyboardShortcut("k")
                .disabled(session == nil)
            Divider()
            ForEach(session?.checks ?? [], id: \.title) { check in
                Button(check.title) { check.perform?() }
                    .keyboardShortcut(check.job == .genericScan ? KeyboardShortcut("r") : nil)
                    .disabled(check.perform == nil)
            }
            Button("Survey This Car") { session?.survey?() }
                .disabled(session?.survey == nil)
            Menu("Read Module Trouble Codes") {
                ForEach(session?.moduleChecks ?? [], id: \.title) { check in
                    Button(check.title) { check.perform?() }
                        .disabled(check.perform == nil)
                }
            }
            .disabled(session?.moduleChecks.isEmpty ?? true)
        }
    }
}
