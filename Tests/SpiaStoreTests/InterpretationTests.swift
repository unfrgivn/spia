import Foundation
import OBDCore
import SpiaAssist
import SpiaKit
import SpiaStore
import SwiftData
import Testing

@MainActor
@Suite("Vehicle interpretations")
struct InterpretationTests {
    let container: ModelContainer
    let garage: Garage
    let root: URL

    init() throws {
        container = try Garage.inMemoryContainer()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("spia-interpretations-\(UUID().uuidString)")
        garage = Garage(context: container.mainContext, files: SpiaFiles(root: root))
    }

    @Test("interpretations round-trip and consent can be withdrawn")
    func roundTrip() throws {
        let vehicle = try garage.addVehicle(name: "Test car")
        let files = SpiaFiles(root: root)
        let cache = VehicleInterpretations(vehicleID: vehicle.id, files: files)
        cache.allow(.anthropic)
        cache.store(
            InterpretationResult(
                codes: [
                    CodeInterpretation(
                        code: "P1009", name: "body computer", meaning: "A body fault.",
                        firstCheck: "Inspect the connector.", confidence: .low)
                ], module: nil),
            target: nil, provider: .anthropic, model: "test")
        let loaded = VehicleInterpretations(vehicleID: vehicle.id, files: files)
        #expect(loaded.consent?.provider == .anthropic)
        #expect(loaded.codes.first?.meaning == "A body fault.")
        cache.recordUsage(
            TokenUsage(input: 100, output: 20), kind: .interpretation, provider: .anthropic,
            model: "test", modules: 2)
        let usageLoaded = VehicleInterpretations(vehicleID: vehicle.id, files: files)
        #expect(usageLoaded.usage.count == 1)
        #expect(usageLoaded.usage.first?.input == 100)
        loaded.withdraw()
        #expect(loaded.consent == nil)
    }

    @Test("old interpretation files decode without a usage key")
    func oldFileDecodes() throws {
        let vehicle = try garage.addVehicle(name: "Old file")
        let url = garage.files.interpretationsURL(vehicle: vehicle.id)
        let data = Data(#"{"codes":[],"modules":[],"reviews":[],"consent":null}"#.utf8)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        #expect(VehicleInterpretations(vehicleID: vehicle.id, files: garage.files).usage.isEmpty)
    }

    @Test("usage summary groups totals by model and recent date")
    func usageSummary() throws {
        let vehicle = try garage.addVehicle(name: "Summary")
        let cache = VehicleInterpretations(vehicleID: vehicle.id, files: garage.files)
        cache.recordUsage(
            TokenUsage(input: 10, output: 4), kind: .interpretation, provider: .anthropic,
            model: "haiku", modules: 1)
        cache.recordUsage(
            TokenUsage(input: 20, output: 8), kind: .review, provider: .anthropic,
            model: "haiku", modules: 0, scope: .car)
        cache.recordUsage(
            TokenUsage(input: 30, output: 12), kind: .interpretation, provider: .openAI,
            model: "gpt", modules: 2)
        let summary = cache.usageSummary
        #expect(summary.total == UsageTotals(requests: 3, input: 60, output: 24))
        #expect(summary.byModel["haiku"] == UsageTotals(requests: 2, input: 30, output: 12))
        #expect(summary.last30Days == summary.total)
    }

    @Test("car briefing includes open problems and interpretations")
    func carBriefing() throws {
        let vehicle = try garage.addDemoVehicle()
        let cache = VehicleInterpretations(vehicleID: vehicle.id, files: garage.files)
        cache.store(
            InterpretationResult(
                codes: [
                    CodeInterpretation(
                        code: "B0001-1B", name: "clock spring", meaning: "Stage 1 circuit.",
                        firstCheck: "Use the SRS procedure.", confidence: .high)
                ], module: nil),
            target: DemoGarage.airbag.target, provider: .anthropic, model: "test")
        let briefing = garage.briefing(for: vehicle, adapter: nil)
        #expect(briefing.problem.contains("Dead steering-wheel controls:"))
        #expect(briefing.problem.contains("Horn, cruise"))
        #expect(briefing.interpretations.contains { $0.contains("clock spring") })
    }

    @Test("a vehicle with no cloud consent does not report an interpretation error")
    func noConsent() async throws {
        let vehicle = try garage.addDemoVehicle()
        let configuration = AssistantConfiguration(
            keys: APIKeyStore(service: "spia-interpretation-test-\(UUID().uuidString)"))
        let interpreter = Interpreter(configuration: configuration, garage: garage)
        await interpreter.catchUp(vehicle, adapter: nil)
        #expect(interpreter.interpretations(for: vehicle).lastError == nil)
    }

    @Test("automatic work pauses without an error, request, or stored result")
    func pausedAutomaticWork() async throws {
        let vehicle = try garage.addDemoVehicle()
        let defaults = UserDefaults(suiteName: "spia-paused-\(UUID().uuidString)")!
        let configuration = AssistantConfiguration(
            keys: APIKeyStore(service: "spia-paused-\(UUID().uuidString)"), defaults: defaults)
        configuration.settings.automaticWorkPaused = true
        let interpreter = Interpreter(configuration: configuration, garage: garage)
        let cache = interpreter.interpretations(for: vehicle)
        cache.allow(.anthropic)
        await interpreter.refresh(vehicle, adapter: nil)
        let result = interpreter.interpretations(for: vehicle)
        #expect(result.lastError == nil)
        #expect(result.inFlight.isEmpty)
        #expect(result.reviewInFlight.isEmpty)
        #expect(result.codes.isEmpty)
        #expect(result.reviews.isEmpty)
    }

    @Test("eleven interpretation modules form sequential batches of eight and three")
    func interpretationBatches() async throws {
        let vehicle = try garage.addVehicle(name: "Batch test car")
        let session = try garage.addSession(to: vehicle, title: "Batch test")
        for index in 0..<11 {
            let target = try ModuleTarget(
                bus: .highSpeed, request: UInt32(0x700 + index), response: UInt32(0x600 + index))
            vehicle.modules.append(
                ModulePreset(
                    label: "Module \(index)", target: target, position: index, confirmed: true))
            try garage.record(
                JobResult(
                    job: .moduleDTCs(target),
                    payload: .moduleDTCs(
                        ModuleDTCs(
                            target: target,
                            outcome: .records(
                                availability: 0xFF,
                                [ModuleDTCRecord(code: "100900", status: 0x08)]))),
                    source: .live, transcript: nil),
                warnings: [], transcriptPath: nil, for: vehicle, in: session)
        }
        let plan = InterpretationPlan.missing(
            board: vehicle.board(), stored: [], modules: vehicle.orderedModules)
        #expect(plan.count == 11)
        let work = plan
        let configuration = AssistantConfiguration(
            keys: APIKeyStore(service: "spia-batch-\(UUID().uuidString)"))
        let interpreter = Interpreter(configuration: configuration, garage: garage)
        interpreter.interpretations(for: vehicle).allow(.anthropic)
        await interpreter.catchUp(vehicle, adapter: nil)
        #expect(interpreter.interpretations(for: vehicle).lastError != nil)
        let batches = InterpretationPlan.batches(work, size: 8)
        #expect(batches.map(\.count) == [8, 3])
        #expect(batches[0].first?.label == plan[0].label)
        #expect(batches[1].first?.label == plan[8].label)
    }

    @Test("the plan finds new airbag and body computer codes")
    func missingPlan() async throws {
        let vehicle = try garage.addDemoVehicle()
        let session = try #require(vehicle.sessions.first)
        let workbench = Workbench(backend: DemoBackend(), garage: garage)
        await workbench.connect()
        _ = await workbench.run(
            .moduleDTCs(DemoGarage.airbag.target), for: vehicle, in: session)
        _ = await workbench.run(
            .moduleDTCs(DemoGarage.bodyComputer.target), for: vehicle, in: session)
        let cache = VehicleInterpretations(vehicleID: vehicle.id, files: garage.files)
        var plan = InterpretationPlan.missing(
            board: vehicle.board(), stored: cache.codes, modules: vehicle.orderedModules)
        #expect(plan.count == 2)
        #expect(plan.first { $0.target == DemoGarage.airbag.target }?.codes.count == 2)
        #expect(plan.first { $0.target == DemoGarage.bodyComputer.target }?.codes.count == 1)
        cache.store(
            InterpretationResult(
                codes: [
                    CodeInterpretation(
                        code: "B0001-1B", name: "clock spring", meaning: "x", firstCheck: "x",
                        confidence: .high),
                    CodeInterpretation(
                        code: "B0002-1B", name: "connector", meaning: "x", firstCheck: "x",
                        confidence: .high),
                ], module: nil),
            target: DemoGarage.airbag.target, provider: .anthropic, model: "test")
        plan = InterpretationPlan.missing(
            board: vehicle.board(), stored: cache.codes, modules: vehicle.orderedModules)
        #expect(plan.count == 1)
        vehicle.modules.first { $0.target == DemoGarage.bodyComputer.target }?.label =
            DemoGarage.bodyComputer.target.fallbackLabel
        plan = InterpretationPlan.missing(
            board: vehicle.board(), stored: cache.codes, modules: vehicle.orderedModules)
        #expect(plan.contains { $0.target == DemoGarage.bodyComputer.target && $0.needsName })
    }

    @Test("consented cloud catch-up reports a missing API key without starting work")
    func missingKeyAfterConsent() async throws {
        let vehicle = try garage.addDemoVehicle()
        let session = try #require(vehicle.sessions.first)
        let workbench = Workbench(backend: DemoBackend(), garage: garage)
        await workbench.connect()
        _ = await workbench.run(
            .moduleDTCs(DemoGarage.airbag.target), for: vehicle, in: session)
        let configuration = AssistantConfiguration(
            keys: APIKeyStore(service: "spia-missing-\(UUID().uuidString)"))
        let interpreter = Interpreter(configuration: configuration, garage: garage)
        interpreter.interpretations(for: vehicle).allow(.anthropic)
        await interpreter.catchUp(vehicle, adapter: nil)
        #expect(
            interpreter.interpretations(for: vehicle).lastError
                == AssistantError.missingAPIKey(.anthropic).description)
        #expect(interpreter.interpretations(for: vehicle).inFlight.isEmpty)
    }
}
