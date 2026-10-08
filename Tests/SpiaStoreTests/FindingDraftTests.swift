import Foundation
import SpiaKit
import SpiaStore
import SwiftData
import Testing

@MainActor
@Suite("Finding drafts")
struct FindingDraftTests {
    let container: ModelContainer
    let garage: Garage
    let vehicle: Vehicle
    let session: DiagnosticSession

    init() throws {
        container = try Garage.inMemoryContainer()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("spia-drafts-\(UUID().uuidString)")
        garage = Garage(context: container.mainContext, files: SpiaFiles(root: root))
        vehicle = try garage.addVehicle(name: "Ghibli")
        session = try garage.addSession(to: vehicle, title: "Horn", problem: "Horn is dead.")
    }

    @Test("a draft with words, a photo, and a sound becomes one finding with both attached")
    func wordsAndEvidence() async throws {
        let entry = try await garage.addFinding(
            FindingDraft(
                title: "Press the horn", text: "  Nothing, not even a click.  ",
                photos: [try imageData()], sounds: [try makeSound(seconds: 1)]),
            to: session)
        #expect(entry.kind == .finding)
        #expect(entry.title == "Press the horn")
        #expect(entry.body == "Nothing, not even a click.")
        #expect(entry.vehicle?.id == vehicle.id)
        #expect(entry.session?.id == session.id)
        let kinds = entry.attachments.sorted { $0.addedAt < $1.addedAt }.map(\.kind)
        #expect(kinds == [.photo, .sound])
        #expect(session.findings.count == 1)
    }

    @Test("a photo alone is a finding with an empty body")
    func photoAlone() async throws {
        let entry = try await garage.addFinding(
            FindingDraft(title: "", photos: [try imageData()]), to: session)
        #expect(entry.body.isEmpty)
        #expect(entry.title == "Finding")
        #expect(entry.attachments.count == 1)
    }

    @Test("words alone are saved")
    func wordsAlone() async throws {
        try await garage.addFinding(FindingDraft(title: "Fuses", text: "F23 intact."), to: session)
        let fetched = try garage.context.fetch(FetchDescriptor<TimelineEntry>())
        #expect(fetched.contains { $0.kind == .finding && $0.body == "F23 intact." })
    }

    @Test("an empty draft is refused and leaves nothing behind")
    func emptyDraft() async throws {
        await #expect(throws: FindingError.empty) {
            _ = try await garage.addFinding(FindingDraft(title: "Nothing", text: "  "), to: session)
        }
        #expect(session.findings.isEmpty)
    }

    @Test("a clip that can't be read rolls the whole finding back")
    func badClipRollsBack() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).mov")
        await #expect(throws: MediaError.unreadable) {
            _ = try await garage.addFinding(
                FindingDraft(
                    title: "Relay", text: "Clicked twice.", photos: [try imageData()],
                    clips: [missing]),
                to: session)
        }
        #expect(session.findings.isEmpty)
        #expect(vehicle.entries.filter { $0.kind == .finding }.isEmpty)
        let folder = garage.files.url(for: garage.files.findingPath(vehicle: vehicle.id, name: ""))
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        #expect(files.isEmpty)
    }
}
