#if DEBUG
    import Foundation
    import SpiaAssist
    import SpiaKit
    import SpiaStore
    import SwiftData
    import SwiftUI

    #if os(macOS)
        import AppKit
    #endif

    /// Screenshot fixture, driven by launch arguments (they land in UserDefaults' argument domain):
    /// `-SpiaFixture demo -SpiaScreen session -SpiaAppearance dark`. See scripts/screenshots.sh.
    @MainActor
    enum Fixture {
        enum Screen: String {
            case garage, overview, references, photos, session, settings
            /// The session, scrolled down to its timeline.
            case timeline
        }

        static var enabled: Bool { UserDefaults.standard.string(forKey: "SpiaFixture") != nil }

        static var screen: Screen? {
            UserDefaults.standard.string(forKey: "SpiaScreen").flatMap(Screen.init(rawValue:))
        }

        static var colorScheme: ColorScheme? {
            switch UserDefaults.standard.string(forKey: "SpiaAppearance") {
            case "dark": .dark
            case "light": .light
            default: nil
            }
        }

        /// An in-memory library with the demo car, whose checks then run against the recordings.
        static func makeModel() throws -> AppModel {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("SpiaFixture-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let model = AppModel(
                container: try Garage.inMemoryContainer(), files: SpiaFiles(root: root),
                assistant: assistant())
            let vehicle = try model.garage.addDemoVehicle()
            Task { await runChecks(model: model, vehicle: vehicle) }
            return model
        }

        /// Where the vehicle's workspace opens for `screen`, or nil to stay in the garage.
        static func section(for vehicle: Vehicle) -> WorkspaceSection? {
            switch screen {
            case .overview: .overview
            case .references: .references
            case .photos: .photos
            case .session, .timeline: vehicle.orderedSessions.first.map { .session($0.id) }
            case .garage, .settings, nil: nil
            }
        }

        /// Default settings and no keys: the owner's Keychain items would make an unsigned build
        /// ask for access (and block until someone answers), and their settings would vary shots.
        private static func assistant() -> AssistantConfiguration {
            let suite = "com.unfrgivn.spia.fixture"
            let defaults = UserDefaults(suiteName: suite) ?? .standard
            defaults.removePersistentDomain(forName: suite)
            return AssistantConfiguration(keys: APIKeyStore(service: suite), defaults: defaults)
        }

        #if os(macOS)
            /// Screenshots come out the same size every time.
            static func sizeWindow() {
                NSApp.windows.first(where: \.isVisible)?.setContentSize(
                    NSSize(width: 1440, height: 900))
            }
        #endif

        private static func runChecks(model: AppModel, vehicle: Vehicle) async {
            guard let session = vehicle.orderedSessions.first,
                let workbench = model.workbench(for: vehicle)
            else { return }
            await workbench.connect()
            _ = await workbench.run(.genericScan, in: session)
            _ = await workbench.run(.moduleDTCs(DemoGarage.airbag.target), in: session)
            if let error = workbench.lastError { print("Spia fixture check failed: \(error)") }
        }
    }
#endif
