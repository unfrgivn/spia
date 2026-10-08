import Foundation
import ImageIO
import SpiaStore
import SpiaKit
import SwiftData
import Testing

@MainActor
@Suite("Finding evidence for the model")
struct EvidenceTests {
    @Test("finding loads photos, sounds, and clip frames")
    func loadsEvidence() async throws {
        let (container, garage, _, entry) = try Self.makeFinding()
        _ = container
        _ = try garage.attachPhoto(try imageData(), to: entry)
        _ = try await garage.attachSound(at: makeSound(seconds: 1), to: entry)
        let first = garage.finding(entry)
        #expect(first.photos.count == 1)
        #expect(first.photos[0].mediaType == "image/jpeg")
        #expect(CGImageSourceCreateWithData(first.photos[0].data as CFData, nil) != nil)
        #expect(first.sounds.count == 1)
        #expect((0.8...1.3).contains(first.sounds[0]))
        #expect(first.clips.isEmpty)

        _ = try await garage.attachClip(at: makeClip(), to: entry)
        let complete = garage.finding(entry)
        #expect(complete.clips.count == 1)
        #expect(complete.clips[0].frames.count == 3)
        #expect((0.8...1.2).contains(complete.clips[0].duration))
    }

    @Test("evidence identity is ordered and affects review inputs")
    func evidenceIdentity() throws {
        let (container, garage, vehicle, entry) = try Self.makeFinding()
        _ = container
        #expect(garage.evidenceKey(entry).isEmpty)
        let board = SessionBoard(modules: [], results: [])
        let base = ReviewInputs.hash(
            board: board, problem: "p", answers: [],
            findings: [(title: entry.title, text: entry.body, evidence: "")])
        let attachment = try garage.attachPhoto(try imageData(), to: entry)
        let second = try garage.attachPhoto(try imageData(), to: entry)
        attachment.addedAt = Date(timeIntervalSince1970: 1)
        second.addedAt = Date(timeIntervalSince1970: 2)
        let later = ReviewInputs.hash(
            board: board, problem: "p", answers: [],
            findings: [(title: entry.title, text: entry.body, evidence: garage.evidenceKey(entry))])
        #expect(garage.evidenceKey(entry) == "\(attachment.id.uuidString),\(second.id.uuidString)")
        #expect(base != later)
        #expect(
            base
                == ReviewInputs.hash(
                    board: board, problem: "p", answers: [],
                    findings: [(title: entry.title, text: entry.body, evidence: "")]))
        #expect(vehicle.entries.contains { $0.id == entry.id })
    }

    @Test("missing evidence files are omitted")
    func missingFileIsIgnored() throws {
        let (container, garage, _, entry) = try Self.makeFinding()
        _ = container
        let attachment = try garage.attachPhoto(try imageData(), to: entry)
        try FileManager.default.removeItem(at: garage.files.url(for: attachment.path))

        #expect(garage.finding(entry).photos.isEmpty)
    }

    private static func makeFinding() throws -> (ModelContainer, Garage, Vehicle, TimelineEntry) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let container = try Garage.inMemoryContainer()
        let garage = Garage(context: container.mainContext, files: SpiaFiles(root: root))
        let vehicle = try garage.addVehicle(name: "Car")
        let entry = TimelineEntry(kind: .finding, title: "Finding", body: "Observed")
        entry.vehicle = vehicle
        vehicle.entries.append(entry)
        try garage.context.save()
        return (container, garage, vehicle, entry)
    }
}
