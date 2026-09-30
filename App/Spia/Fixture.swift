#if DEBUG
    import Foundation
    import OBDCore
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
            case garage, overview, references, photos, session, settings, replay
            case replayTimeline = "replay-timeline"
            case recordings
            case onboarding
            case surveyResults = "survey-results"
            /// References, on the bulletins or the complaints.
            case bulletins, complaints
            /// The garage before any vehicle is added.
            case welcome
            /// The session, scrolled down to its timeline.
            case timeline
            /// The session, with Explain pressed on the first row that has no answer yet.
            case explain
        }

        static var enabled: Bool { UserDefaults.standard.string(forKey: "SpiaFixture") != nil }

        static var screen: Screen? {
            UserDefaults.standard.string(forKey: "SpiaScreen").flatMap(Screen.init(rawValue:))
        }

        /// A References search and a complaints component to start with: `-SpiaQuery brake
        /// -SpiaComponent STEERING`.
        static var query: String? { UserDefaults.standard.string(forKey: "SpiaQuery") }
        static var component: String? { UserDefaults.standard.string(forKey: "SpiaComponent") }

        static var appearance: Appearance? {
            UserDefaults.standard.string(forKey: "SpiaAppearance").flatMap(
                Appearance.init(rawValue:))
        }

        /// An in-memory library with the demo car, whose checks then run against the recordings;
        /// empty for the welcome.
        static func makeModel() throws -> AppModel {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("SpiaFixture-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let checks =
                try screen == .replay || screen == .replayTimeline || screen == .recordings
                ? savedChecks() : nil
            let model = AppModel(
                container: try Garage.inMemoryContainer(), files: SpiaFiles(root: root),
                assistant: assistant(), replayTiming: .immediate,
                savedChecksProvider: checks.map { saved in { saved } })
            if screen == .onboarding {
                _ = try model.garage.addVehicle(
                    name: "2017 Maserati Ghibli S Q4", vin: DemoGarage.vin)
            } else if screen == .surveyResults {
                let vehicle = try model.garage.addVehicle(
                    name: DemoGarage.vehicleName, vin: DemoGarage.vin)
                let session = try model.garage.addSession(
                    to: vehicle, title: "Finding this car's modules")
                let report = try surveyReport()
                try model.garage.record(
                    JobResult(
                        job: .survey(report.plan), payload: .survey(report), source: .live,
                        transcript: nil),
                    warnings: [], transcriptPath: nil, in: session)
            } else if screen != .welcome {
                if screen == .replay || screen == .replayTimeline || screen == .recordings {
                    let vehicle = try model.garage.addVehicle(
                        name: DemoGarage.vehicleName, vin: DemoGarage.vin)
                    for (position, module) in DemoGarage.modules.enumerated() {
                        vehicle.modules.append(
                            ModulePreset(
                                label: module.label, target: module.target, position: position))
                    }
                    let session = try model.garage.addSession(to: vehicle, title: "Saved checks")
                    _ = model.prepareRecordings(for: vehicle)
                    if screen == .replay || screen == .replayTimeline {
                        Task {
                            await runReplayChecks(model: model, vehicle: vehicle, session: session)
                        }
                    }
                } else {
                    let vehicle = try model.garage.addDemoVehicle()
                    Task { await runChecks(model: model, vehicle: vehicle) }
                }
            }
            return model
        }

        private static func savedChecks() throws -> [SavedCheck] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
            guard
                let date = calendar.date(
                    from: DateComponents(year: 2026, month: 9, day: 26, hour: 12))
            else { throw CocoaError(.coderInvalidValue) }
            return [
                SavedCheck(
                    job: .adapterCheck, recorded: date,
                    transcript: try DemoRecording.adapterProbe.url()),
                SavedCheck(
                    job: .moduleDTCs(DemoGarage.airbag.target), recorded: date,
                    transcript: try DemoRecording.airbagCodes.url()),
            ]
        }

        /// Where the vehicle's workspace opens for `screen`, or nil to stay in the garage.
        static func section(for vehicle: Vehicle) -> WorkspaceSection? {
            switch screen {
            case .overview: .overview
            case .references, .bulletins, .complaints: .references
            case .photos: .photos
            case .session, .timeline, .explain, .replay, .replayTimeline, .recordings:
                vehicle.orderedSessions.first.map { .session($0.id) }
            case .garage, .settings, .welcome, nil: nil
            case .onboarding: .overview
            case .surveyResults:
                vehicle.orderedSessions.first.map { .session($0.id) }
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
            // Connect once the screen is up, so shots can show what a new connection looks like.
            try? await Task.sleep(for: .seconds(2))
            await workbench.connect()
            _ = await workbench.run(.adapterCheck, in: session)
            // Checks after the bulb check, the way someone connects and then runs one.
            try? await Task.sleep(for: .seconds(1.5))
            _ = await workbench.run(.genericScan, in: session)
            _ = await workbench.run(.moduleDTCs(DemoGarage.airbag.target), in: session)
            _ = await workbench.run(.moduleDTCs(DemoGarage.abs.target), in: session)
            _ = await workbench.run(.moduleDTCs(DemoGarage.bodyComputer.target), in: session)
            if let error = workbench.lastError { print("Spia fixture check failed: \(error)") }
            answerAirbagQuestion(in: session, garage: model.garage)
        }

        private static func runReplayChecks(
            model: AppModel, vehicle: Vehicle, session: DiagnosticSession
        ) async {
            try? await Task.sleep(for: .seconds(2))
            guard let workbench = model.workbench(for: vehicle) else { return }
            await Task.yield()
            await workbench.connect()
            _ = await workbench.run(.adapterCheck, in: session)
            _ = await workbench.run(.moduleDTCs(DemoGarage.airbag.target), in: session)
        }

        private static func surveyReport() throws -> SurveyReport {
            let catalog = try ModuleCatalog.bundled()
            let identity = CatalogVehicle(make: "Maserati", model: "Ghibli", year: 2017)
            let plan = try SurveyPlanner.plan(
                catalog: catalog, vehicle: identity, reachableBuses: [.highSpeed, .mediumSpeed])
            func candidate(_ request: UInt32) throws -> SurveyCandidate {
                guard let candidate = plan.candidates.first(where: { $0.target.request == request })
                else { throw CocoaError(.coderValueNotFound) }
                return candidate
            }
            let airbag = try candidate(0x744)
            let abs = try candidate(0x747)
            let bcm = try candidate(0x620)
            let engine = try candidate(0x7E0)
            let transmission = try candidate(0x7E1)
            // The names the Ghibli's engine and transmission computers gave to 09 0A on the car.
            var ecm = ECUInfoReport(ecu: 0x7E8)
            ecm.name = .positive("ECM1-EngineControl1")
            var tcm = ECUInfoReport(ecu: 0x7E9)
            tcm.name = .positive("TCM\0-TransmisCtrl")
            let noCodes = SurveyCodes.outcome(.records(availability: 0xFF, []))
            let modules = [
                SurveyModule(
                    candidate: airbag, presence: .present, identification: [],
                    codes: .outcome(
                        .records(
                            availability: 0xCF,
                            [
                                ModuleDTCRecord(code: "80011B", status: 0x8F),
                                ModuleDTCRecord(code: "80021B", status: 0x8F),
                            ]))),
                SurveyModule(
                    candidate: abs, presence: .present, identification: [], codes: noCodes),
                SurveyModule(
                    candidate: bcm, presence: .present, identification: [],
                    codes: .outcome(
                        .records(
                            availability: 0xFB,
                            [ModuleDTCRecord(code: "100900", status: 0x2B)]))),
                SurveyModule(
                    candidate: engine, presence: .present, identification: [], codes: noCodes),
                SurveyModule(
                    candidate: transmission, presence: .present, identification: [],
                    codes: noCodes),
            ]
            let answered = Set(modules.map(\.candidate.target))
            return SurveyReport(
                plan: plan, voltage: 14.3, vehicleInfo: [ECUIdentity(ecm), ECUIdentity(tcm)],
                modules: modules,
                unanswered: plan.candidates.filter { !answered.contains($0.target) },
                notProbed: [], stop: nil)
        }

        /// A question about the airbag row and an answer, as if the owner had tapped Explain,
        /// so shots show a note. The fixture has no keys, so nothing is really asked.
        private static func answerAirbagQuestion(in session: DiagnosticSession, garage: Garage) {
            guard
                let question = session.board().rows
                    .first(where: { $0.subject == .module(DemoGarage.airbag.target) })?.question
            else { return }
            let next = (session.messages.map(\.sequence).max() ?? -1) + 1
            session.messages.append(
                ChatMessage(sequence: next, role: .user, parts: [.text(question)]))
            session.messages.append(
                ChatMessage(
                    sequence: next + 1, role: .assistant, parts: [.text(airbagAnswer)],
                    provider: .anthropic))
            try? garage.context.save()
        }

        private static let airbagAnswer = """
            Those are the airbag controller's own codes, so their exact meanings are in Maserati's \
            service data rather than the public OBD list. With a dead horn and dead wheel buttons \
            as well, the usual cause is a failing **clock spring**: the coiled cable behind the \
            steering wheel that carries the horn, the wheel buttons, and the driver's airbag.

            Check first:

            1. Does the horn work with the wheel turned fully left or right?
            2. Is the airbag lamp on all the time, or only at some wheel angles?
            """
    }
#endif
