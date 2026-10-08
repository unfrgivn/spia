import Foundation
import SpiaAssist
import SpiaKit
import SpiaStore
import SpiaKit
import SwiftData
import Testing

@MainActor
@Suite("Stored diagnoses")
struct DiagnosisTests {
    let container: ModelContainer
    let garage: Garage

    init() throws {
        container = try Garage.inMemoryContainer()
        garage = Garage(
            context: container.mainContext,
            files: SpiaFiles(
                root: FileManager.default.temporaryDirectory
                    .appendingPathComponent("spia-diagnosis-\(UUID().uuidString)")))
    }

    private func diagnosis(
        question: ReviewQuestion? = nil, reading: String = "A likely wiring fault."
    ) -> DiagnosisResult {
        DiagnosisResult(
            reading: reading, symptoms: ["Horn silent"],
            suspects: [
                DiagnosisSuspect(
                    name: "Wire", why: "Evidence", confidence: .high, symptoms: [0])
            ],
            checks: [
                DiagnosisCheck(
                    proposal: CheckProposal(
                        check: .moduleCodes, module: "Airbag controller (ORC)", reason: "Read"),
                    suspects: [0])
            ],
            inspections: [
                DiagnosisInspection(
                    title: "Inspect", steps: "Look", lookFor: "Damage", safety: nil, suspects: [0],
                    tellsApart: "Evidence")
            ],
            questions: question.map { [$0] } ?? [],
            conclusion: DiagnosisConclusion(cause: "Wire", fix: "Repair", confidence: .high))
    }

    private func store(
        _ cache: VehicleInterpretations, _ result: DiagnosisResult, scope: ReviewScope
    ) {
        cache.storeDiagnosis(
            result, scope: scope, inputs: "inputs", provider: .anthropic, model: "test",
            modules: [(label: "Airbag controller (ORC)", target: DemoGarage.airbag.target)])
    }

    @Test("a diagnosis stores its structured investigation")
    func storesDiagnosis() throws {
        let vehicle = try garage.addVehicle(name: "Test car")
        let cache = VehicleInterpretations(vehicleID: vehicle.id, files: garage.files)
        store(cache, diagnosis(), scope: .problem(UUID()))
        let loaded = VehicleInterpretations(vehicleID: vehicle.id, files: garage.files)
        let review = try #require(loaded.reviews.first)
        #expect(review.kind == .diagnosis)
        #expect(review.symptoms == ["Horn silent"])
        #expect(review.suspects.first?.confidence == .high)
        #expect(review.checks.first?.suspects == [0])
        #expect(review.inspections.count == 1)
        #expect(review.conclusion?.cause == "Wire")
    }

    @Test("an old interpretation file decodes with review defaults")
    func decodesOldInterpretations() throws {
        let vehicle = try garage.addVehicle(name: "Old car")
        let id = UUID()
        let date = "2026-10-08T00:00:00Z"
        let scopeData = try JSONEncoder().encode(ReviewScope.problem(id))
        let scope = String(decoding: scopeData, as: UTF8.self)
        let json = """
            {"consent":null,"codes":[],"modules":[],"reviews":[{"scope":\(scope),"reading":"Old reading","questions":[],"checks":[{"kind":"module_codes","module":null,"reason":"Read it"}],"inputs":"old","provider":"anthropic","model":"test","date":"\(date)"}]}
            """
        try FileManager.default.createDirectory(
            at: garage.files.interpretationsURL(vehicle: vehicle.id).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data(json.utf8).write(to: garage.files.interpretationsURL(vehicle: vehicle.id))

        let loaded = VehicleInterpretations(vehicleID: vehicle.id, files: garage.files)
        let review = try #require(loaded.review(for: .problem(id)))
        #expect(review.kind == .review)
        #expect(review.symptoms.isEmpty)
        #expect(review.suspects.isEmpty)
        #expect(review.inspections.isEmpty)
        #expect(review.conclusion == nil)
        #expect(review.checks.first?.suspects == [])
    }

    @Test("diagnosis carries answers over and removing a scope leaves others")
    func carriesAnswersAndRemovesScope() throws {
        let vehicle = try garage.addVehicle(name: "Test car")
        let cache = VehicleInterpretations(vehicleID: vehicle.id, files: garage.files)
        let scope = ReviewScope.problem(UUID())
        let question = ReviewQuestion(question: "Does it stay on?", module: nil, codes: [])
        store(cache, diagnosis(question: question), scope: scope)
        let questionID = try #require(cache.review(for: scope)?.questions.first?.id)
        cache.answer(questionID: questionID, text: "Only when turning")
        store(cache, diagnosis(question: question), scope: scope)
        #expect(cache.review(for: scope)?.questions.first?.answer == "Only when turning")

        cache.storeReview(
            ReviewResult(reading: "Car", questions: [], checks: []), scope: .car, inputs: "car",
            provider: .anthropic, model: "test", modules: [])
        cache.removeReview(for: scope)
        #expect(cache.review(for: scope) == nil)
        #expect(cache.review(for: .car)?.reading == "Car")
    }

    @Test("diagnosis input hashes include only supplied notes and findings")
    func inputHash() throws {
        let board = SessionBoard(modules: [], results: [])
        let answers: [(question: String, answer: String)] = []
        let base = ReviewInputs.hash(board: board, problem: "horn", answers: answers)
        #expect(base == ReviewInputs.hash(board: board, problem: "horn", answers: answers))
        #expect(
            base
                == ReviewInputs.hash(
                    board: board, problem: "horn", answers: answers, notes: [], findings: []))
        #expect(
            base
                != ReviewInputs.hash(
                    board: board, problem: "horn", answers: answers, notes: ["Only cold"]))
        #expect(
            base
                != ReviewInputs.hash(
                    board: board, problem: "horn", answers: answers,
                    findings: [(title: "Inspect", text: "Fuse intact", evidence: "")]))
    }

    @Test("findings belong to the car and survive problem deletion")
    func findingsAndDeletion() throws {
        let vehicle = try garage.addVehicle(name: "Test car")
        let session = try garage.addSession(to: vehicle, title: "Problem")
        try garage.addFinding("Fuse intact", title: "Fuse", to: session)
        try garage.addFinding("Relay clicks", title: "  ", to: session)
        try garage.addFinding("   ", title: "Ignored", to: session)
        try garage.addNote("Owner note", to: session)
        #expect(session.findings.count == 2)
        #expect(session.notes.count == 1)
        #expect(session.findings.first?.kind == .finding)
        #expect(session.findings.first?.vehicle?.id == vehicle.id)
        #expect(session.findings.map(\.title) == ["Fuse", "Finding"])
        #expect(session.findings.allSatisfy { $0.session === session })

        try garage.delete(session)
        #expect(vehicle.entries.contains { $0.kind == .finding && $0.session == nil })
        #expect(vehicle.entries.contains { $0.kind == .note } == false)
    }

    @Test("resolve and reopen manage resolution and reopened notes")
    func resolvesAndReopens() throws {
        let vehicle = try garage.addVehicle(name: "Test car")
        let resolved = try garage.addSession(to: vehicle, title: "Resolved")
        try garage.resolve(resolved, fix: "  Replace the clock spring  ")
        #expect(resolved.status == .resolved)
        #expect(resolved.closedAt != nil)
        #expect(resolved.resolution == "Replace the clock spring")
        try garage.reopen(resolved)
        #expect(resolved.status == .open)
        #expect(resolved.closedAt == nil)
        #expect(resolved.resolution == nil)
        #expect(resolved.notes.count == 1)
        #expect(resolved.notes.first?.body.hasPrefix("Reopened.") == true)

        let blank = try garage.addSession(to: vehicle, title: "Blank")
        try garage.resolve(blank, fix: "   ")
        #expect(blank.resolution == nil)
        try garage.reopen(blank)
        #expect(blank.notes.isEmpty)
    }

    @Test("review scopes include open problems with text or notes only")
    func reviewScopes() throws {
        let vehicle = try garage.addVehicle(name: "Test car")
        let text = try garage.addSession(to: vehicle, title: "Text", problem: "A noise")
        let noted = try garage.addSession(to: vehicle, title: "Note")
        try garage.addNote("It happens cold", to: noted)
        let empty = try garage.addSession(to: vehicle, title: "Empty")
        let resolved = try garage.addSession(to: vehicle, title: "Resolved", problem: "Old noise")
        try garage.resolve(resolved, fix: nil)
        let scopes = Interpreter.reviewScopes(for: vehicle)
        #expect(Set(scopes) == Set([.car, .problem(text.id), .problem(noted.id)]))
        #expect(!scopes.contains(.problem(empty.id)))
        #expect(!scopes.contains(.problem(resolved.id)))
    }
}
