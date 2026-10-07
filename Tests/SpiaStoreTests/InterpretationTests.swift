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
                        firstCheck: "Inspect the connector.", confidence: "low")
                ], module: nil),
            target: nil, provider: .anthropic, model: "test")
        let loaded = VehicleInterpretations(vehicleID: vehicle.id, files: files)
        #expect(loaded.consent?.provider == .anthropic)
        #expect(loaded.codes.first?.meaning == "A body fault.")
        loaded.withdraw()
        #expect(loaded.consent == nil)
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
                        firstCheck: "Use the SRS procedure.", confidence: "high")
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
                        confidence: "high"),
                    CodeInterpretation(
                        code: "B0002-1B", name: "connector", meaning: "x", firstCheck: "x",
                        confidence: "high"),
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
