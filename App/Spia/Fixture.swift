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
            case garage, overview, startProblem = "start-problem", references, photos, session,
                settings, replay
            case replayTimeline = "replay-timeline"
            case recordings
            case onboarding
            case scanning
            case surveyResults = "survey-results"
            case surveyResultsMissing = "survey-results-missing"
            case surveyResultsSearched = "survey-results-searched"
            /// References, on the bulletins or the complaints.
            case bulletins, complaints
            /// The garage before any vehicle is added.
            case welcome
            /// The session, scrolled down to its timeline.
            case timeline
            /// The session with the interpretation rows visible.
            case explain
            /// The problem with its review questions visible.
            case questions
            /// The session, with a module's reading history open.
            case history
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
                assistant: assistant(), replayTiming: screen == .scanning ? .recorded : .immediate,
                savedChecksProvider: checks.map { saved in { saved } })
            if screen == .onboarding {
                _ = try model.garage.addVehicle(
                    name: "2017 Maserati Ghibli S Q4", vin: DemoGarage.vin)
            } else if screen == .surveyResults || screen == .surveyResultsMissing
                || screen == .surveyResultsSearched
            {
                let vehicle = try model.garage.addVehicle(
                    name: DemoGarage.vehicleName, vin: DemoGarage.vin)
                let report: SurveyReport
                switch screen {
                case .surveyResults: report = try surveyReport()
                case .surveyResultsMissing: report = try surveyReportMissing()
                case .surveyResultsSearched: report = try surveyReportSearched()
                default: throw CocoaError(.coderInvalidValue)
                }
                try model.garage.record(
                    JobResult(
                        job: .survey(report.plan), payload: .survey(report), source: .live,
                        transcript: nil),
                    warnings: [], transcriptPath: nil, for: vehicle, in: nil)
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
                    seedInterpretations(model: model, vehicle: vehicle)
                    Task {
                        if screen == .scanning {
                            await runScan(model: model, vehicle: vehicle)
                        } else {
                            await runChecks(model: model, vehicle: vehicle)
                        }
                    }
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
            case .session, .timeline, .explain, .questions, .history, .replay, .replayTimeline,
                .recordings:
                vehicle.orderedSessions.first.map { .session($0.id) }
            case .garage, .settings, .welcome, nil: nil
            case .onboarding, .scanning, .startProblem: .overview
            case .surveyResults, .surveyResultsMissing, .surveyResultsSearched: .overview
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
            _ = await workbench.run(.adapterCheck, for: vehicle, in: session)
            // Checks after the bulb check, the way someone connects and then runs one.
            try? await Task.sleep(for: .seconds(1.5))
            _ = await workbench.run(.genericScan, for: vehicle, in: session)
            _ = await workbench.run(
                .moduleDTCs(DemoGarage.airbag.target), for: vehicle, in: session)
            _ = await workbench.run(.moduleDTCs(DemoGarage.abs.target), for: vehicle, in: session)
            _ = await workbench.run(
                .moduleDTCs(DemoGarage.bodyComputer.target), for: vehicle, in: session)
            if let error = workbench.lastError { print("Spia fixture check failed: \(error)") }
        }

        private static func runScan(model: AppModel, vehicle: Vehicle) async {
            guard let workbench = model.workbench(for: vehicle) else { return }
            try? await Task.sleep(for: .seconds(1))
            await workbench.connect()
            let survey = try? model.surveyPlan(for: vehicle, workbench: workbench)
            let plan = ScanPlan.make(
                for: vehicle, canRun: { workbench.canRun($0) }, survey: survey)
            _ = await workbench.scan(plan, for: vehicle, in: vehicle.orderedSessions.first)
        }

        private static func seedInterpretations(model: AppModel, vehicle: Vehicle) {
            let cache = model.interpreter.interpretations(for: vehicle)
            cache.allow(.anthropic)
            cache.store(
                InterpretationResult(
                    codes: [
                        CodeInterpretation(
                            code: "B0001-1B", name: "Driver airbag clock spring",
                            meaning:
                                "The driver frontal stage 1 deployment circuit has an open or high-resistance path. On this car, the dead horn and steering-wheel controls make the clock spring the leading suspect.",
                            firstCheck:
                                "Follow Maserati's SRS procedure and inspect the clock-spring and connector area without probing airbag circuits.",
                            confidence: "high"),
                        CodeInterpretation(
                            code: "B0002-1B", name: "Driver airbag connector",
                            meaning:
                                "The driver frontal stage 2 deployment circuit reports the same failure type, which points to an interruption rather than a deployment command.",
                            firstCheck:
                                "Have a qualified technician inspect the SRS connector and clock spring using the manufacturer's procedure.",
                            confidence: "high"),
                    ], module: nil),
                target: DemoGarage.airbag.target, provider: .anthropic,
                model: AnthropicProvider.fastModel)
            cache.store(
                InterpretationResult(
                    codes: [
                        CodeInterpretation(
                            code: "P1009-00", name: "Body computer communication fault",
                            meaning:
                                "This manufacturer-specific code is not verified by the public catalog. It may reflect a body-computer communication or supply issue, but that meaning is only a low-confidence guess.",
                            firstCheck:
                                "Check battery voltage and body-computer power and ground according to the service manual.",
                            confidence: "low")
                    ], module: nil),
                target: DemoGarage.bodyComputer.target, provider: .anthropic,
                model: AnthropicProvider.fastModel)
            cache.storeReview(
                ReviewResult(
                    reading:
                        "The airbag controller's two driver-circuit faults fit the dead horn and wheel controls. The clock spring is the leading suspect, but its safety circuit should be handled only by the manufacturer's procedure.",
                    questions: [
                        ReviewQuestion(
                            question:
                                "Does the horn work with the wheel turned fully left or right?",
                            module: DemoGarage.airbag.label, codes: ["B0001-1B", "B0002-1B"]),
                        ReviewQuestion(
                            question: "Has the steering wheel or airbag been removed or serviced?",
                            module: nil, codes: []),
                    ],
                    checks: [
                        CheckProposal(
                            check: .moduleCodes, module: DemoGarage.steeringColumn.label,
                            reason: "Its codes would say whether the wheel's switches reach it")
                    ]),
                scope: .problem(vehicle.orderedSessions[0].id), inputs: "fixture-problem",
                provider: .anthropic, model: AnthropicProvider.fastModel,
                modules: vehicle.assistantModules)
            cache.storeReview(
                ReviewResult(
                    reading:
                        "The car's readings point to a steering-wheel control fault around the clock spring, with no engine or transmission codes to widen the search.",
                    questions: [], checks: []),
                scope: .car, inputs: "fixture-car", provider: .anthropic,
                model: AnthropicProvider.fastModel, modules: vehicle.assistantModules)
        }

        private static func runReplayChecks(
            model: AppModel, vehicle: Vehicle, session: DiagnosticSession
        ) async {
            try? await Task.sleep(for: .seconds(2))
            guard let workbench = model.workbench(for: vehicle) else { return }
            await Task.yield()
            await workbench.connect()
            _ = await workbench.run(.adapterCheck, for: vehicle, in: session)
            _ = await workbench.run(
                .moduleDTCs(DemoGarage.airbag.target), for: vehicle, in: session)
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
            let steering = try candidate(0x763)
            let engine = try candidate(0x7E0)
            let transmission = try candidate(0x7E1)
            // What the Ghibli answered on the car over USB: the six of its first surveys
            // (2026-09-30), the eight its first thorough search found (2026-10-04), and the names
            // and VIN its engine and transmission computers gave to 09.
            var ecm = ECUInfoReport(ecu: 0x7E8)
            ecm.name = .positive("ECM1-EngineControl1")
            ecm.vin = .positive("ZAM57RTS4H1249941")
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
                    candidate: steering, presence: .present, identification: [],
                    codes: .outcome(
                        .records(
                            availability: 0x39,
                            [
                                ModuleDTCRecord(code: "059300", status: 0x29),
                                ModuleDTCRecord(code: "058100", status: 0x29),
                                ModuleDTCRecord(code: "D00800", status: 0x28),
                            ]))),
                SurveyModule(
                    candidate: engine, presence: .present, identification: [], codes: noCodes),
                SurveyModule(
                    candidate: transmission, presence: .present, identification: [],
                    codes: noCodes),
            ]
            let codesFound: [UInt32: [ModuleDTCRecord]] = [
                0x740: [
                    ModuleDTCRecord(code: "A59B00", status: 0x4B),
                    ModuleDTCRecord(code: "A59B01", status: 0x48),
                    ModuleDTCRecord(code: "9A1100", status: 0x49),
                ],
                0x742: [ModuleDTCRecord(code: "C00100", status: 0x28)],
                0x743: [ModuleDTCRecord(code: "407700", status: 0x08)],
            ]
            let found = try [0x740, 0x742, 0x743, 0x749, 0x74B, 0x762, 0x764, 0x768].map {
                (request: UInt32) in
                SurveyModule(
                    candidate: try candidate(request), presence: .present, identification: [],
                    codes: .outcome(.records(availability: 0xFF, codesFound[request] ?? [])))
            }
            let answered = Set((modules + found).map(\.candidate.target))
            return SurveyReport(
                plan: plan, voltage: 14.3, vehicleInfo: [ECUIdentity(ecm), ECUIdentity(tcm)],
                modules: modules + found,
                unanswered: plan.candidates.filter { !answered.contains($0.target) },
                notProbed: [], stop: nil)
        }

        /// The same Ghibli on the phone, surveyed as its ignition came on: only the engine answered
        /// the opening requests, then it and the airbag controller stayed silent at their probes.
        private static func surveyReportMissing() throws -> SurveyReport {
            let report = try surveyReport()
            let silent: Set<UInt32> = [0x744, 0x7E0]
            return SurveyReport(
                plan: report.plan, voltage: 11.8,
                vehicleInfo: report.vehicleInfo.filter { $0.ecu == 0x7E8 },
                modules: report.modules.filter { !silent.contains($0.candidate.target.request) },
                unanswered: report.plan.candidates.filter { candidate in
                    silent.contains(candidate.target.request)
                        || report.unanswered.contains { $0.target == candidate.target }
                },
                notProbed: [], stop: nil)
        }

        private static func surveyReportSearched() throws -> SurveyReport {
            let base = try surveyReport()
            let search = ModuleSearch.standard(over: .demo)
            let plan = try SurveyPlanner.plan(
                catalog: try ModuleCatalog.bundled(),
                vehicle: CatalogVehicle(make: "Maserati", model: "Ghibli", year: 2017),
                reachableBuses: [.highSpeed, .mediumSpeed], search: search)
            // No search has run on a car yet, so the found module is made up, but it behaves as the
            // Ghibli's modules do: it gives the VIN and refuses F197, and its reply follows FCA's
            // request - 280 (744 -> 4C4). The listen heard the network management the Ghibli's
            // capture shows in the window.
            let target = try ModuleTarget(bus: .highSpeed, request: 0x75A, response: 0x4DA)
            let discovered = SurveyModule(
                candidate: SurveyCandidate(target: target, origin: .discovered),
                presence: .present,
                identification: [
                    SurveyIdentification(
                        did: 0xF190, result: .value(Array("ZAM57RTS4H1249941".utf8))),
                    SurveyIdentification(did: 0xF197, result: .refused(0x31)),
                ], codes: .outcome(.records(availability: 0xFF, [])))
            let heard: Set<UInt32> = [
                0x400, 0x401, 0x402, 0x403, 0x407, 0x409, 0x422, 0x423, 0x44A, 0x44C,
            ]
            return SurveyReport(
                plan: plan, voltage: base.voltage, vehicleInfo: base.vehicleInfo,
                modules: base.modules + [discovered], unanswered: base.unanswered,
                notProbed: base.notProbed, stop: nil, detectedProtocol: .can11bit500k,
                search: SearchOutcome(
                    heardIDs: heard.sorted(),
                    sweptCount: search.sweepRequests(
                        candidates: plan.candidates, heardIDs: heard
                    ).count,
                    confirmed: [target], unconfirmed: [], engineRunning: false,
                    stopReason: nil))
        }

    }
#endif
