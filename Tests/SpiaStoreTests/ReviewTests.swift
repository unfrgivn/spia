import Foundation
import OBDCore
import SpiaAssist
import SpiaKit
import SpiaStore
import SwiftData
import Testing

@MainActor
@Suite("Stored reviews")
struct ReviewTests {
    let container: ModelContainer
    let garage: Garage
    let root: URL

    init() throws {
        container = try Garage.inMemoryContainer()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("spia-reviews-\(UUID().uuidString)")
        garage = Garage(context: container.mainContext, files: SpiaFiles(root: root))
    }

    private func result() -> ReviewResult {
        ReviewResult(
            reading: "The airbag controller's stored fault is consistent with the owner's report.",
            questions: [
                .init(
                    question: "Does the lamp stay on?", module: "Airbag controller (ORC)",
                    code: "80011B"),
                .init(question: "Was work done recently?", module: nil, code: nil),
            ],
            checks: [
                .init(
                    check: .moduleCodes, module: "Airbag controller (ORC)", reason: "Read it again."
                )
            ])
    }

    private func store(_ cache: VehicleInterpretations, scope: ReviewScope = .car) {
        cache.storeReview(
            result(), scope: scope, inputs: "inputs", provider: .anthropic, model: "test",
            modules: [("Airbag controller (ORC)", DemoGarage.airbag.target)])
    }

    @Test("a review and its answered question round-trip through the vehicle file")
    func roundTrip() throws {
        let vehicle = try garage.addVehicle(name: "Test car")
        let cache = VehicleInterpretations(vehicleID: vehicle.id, files: garage.files)
        store(cache)
        let questionID = try #require(cache.review(for: .car)?.questions.first?.id)
        cache.answer(questionID: questionID, text: "Yes, it does.")
        let loaded = VehicleInterpretations(vehicleID: vehicle.id, files: garage.files)
        let review = try #require(loaded.review(for: .car))
        #expect(review.reading.contains("airbag"))
        #expect(review.questions.first?.answer == "Yes, it does.")
        #expect(review.questions.last?.answer == nil)
    }

    @Test("review input hashes change only when board, problem, or answers change")
    func inputHash() throws {
        let target = DemoGarage.airbag.target
        func board(_ code: String) -> SessionBoard {
            let outcome = ModuleDTCOutcome.records(
                availability: 1, [ModuleDTCRecord(code: code, status: 1)])
            let module = ModuleDTCs(target: target, outcome: outcome)
            return SessionBoard(
                modules: [.init(label: "Airbag controller (ORC)", target: target)],
                results: [.init(date: .now, payload: .moduleDTCs(module))])
        }
        let answers: [(question: String, answer: String)] = []
        let first = ReviewInputs.hash(board: board("80011B"), problem: "horn", answers: answers)
        #expect(
            first == ReviewInputs.hash(board: board("80011B"), problem: "horn", answers: answers))
        #expect(
            first != ReviewInputs.hash(board: board("80021B"), problem: "horn", answers: answers))
        #expect(
            first
                != ReviewInputs.hash(
                    board: board("80011B"), problem: "horn stopped", answers: answers))
        #expect(
            first
                != ReviewInputs.hash(
                    board: board("80011B"), problem: "horn", answers: [("Does it work?", "No")]))
    }

    @Test("openQuestions finds a tagged question by subject and raw code")
    func findsTaggedQuestion() throws {
        let vehicle = try garage.addVehicle(name: "Test car")
        let cache = VehicleInterpretations(vehicleID: vehicle.id, files: garage.files)
        store(cache)
        let found = cache.openQuestions(about: .module(DemoGarage.airbag.target), code: "80011B")
        #expect(found.count == 1)
        #expect(found.first?.code == "80011B")
        #expect(cache.openQuestions(about: .engine, code: "80011B").isEmpty)
        #expect(
            cache.openQuestions(about: .module(DemoGarage.airbag.target), code: "80021B").isEmpty)
    }

    @Test("review respects cloud consent and reports a missing key after consent")
    func reviewGating() async throws {
        let vehicle = try garage.addDemoVehicle()
        let configuration = AssistantConfiguration(
            keys: APIKeyStore(service: "spia-review-gating-\(UUID().uuidString)"))
        let interpreter = Interpreter(configuration: configuration, garage: garage)
        await interpreter.review(vehicle, adapter: nil)
        #expect(interpreter.interpretations(for: vehicle).lastError == nil)
        interpreter.interpretations(for: vehicle).allow(.anthropic)
        await interpreter.review(vehicle, adapter: nil)
        #expect(
            interpreter.interpretations(for: vehicle).lastError
                == AssistantError.missingAPIKey(.anthropic).description)
        #expect(interpreter.interpretations(for: vehicle).reviewInFlight.isEmpty)
        #expect(interpreter.interpretations(for: vehicle).reviews.isEmpty)
    }

    @Test("answer persists before a no-key re-review and the briefing carries it")
    func answerAndBriefing() async throws {
        let vehicle = try garage.addDemoVehicle()
        let cache = interpreterCache(vehicle)
        store(cache)
        let questionID = try #require(cache.review(for: .car)?.questions.first?.id)
        let configuration = AssistantConfiguration(
            keys: APIKeyStore(service: "spia-review-answer-\(UUID().uuidString)"))
        let interpreter = Interpreter(configuration: configuration, garage: garage)
        await interpreter.answer(
            vehicle, questionID: questionID, text: "Only when turning.", adapter: nil)
        let loaded = interpreter.interpretations(for: vehicle)
        #expect(loaded.review(for: .car)?.questions.first?.answer == "Only when turning.")
        let briefing = garage.briefing(for: vehicle, adapter: nil)
        #expect(briefing.reviews.contains { $0.contains("The airbag controller") })
        #expect(briefing.reviews.contains { $0.contains("Only when turning.") })
    }

    private func interpreterCache(_ vehicle: Vehicle) -> VehicleInterpretations {
        VehicleInterpretations(vehicleID: vehicle.id, files: garage.files)
    }
}
