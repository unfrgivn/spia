import Foundation
import SpiaKit
import SpiaStore
import SwiftData
import Testing

@MainActor
@Suite("Problems")
struct ProblemTests {
    @Test("derives titles from the first sentence or clause")
    func titles() {
        let cases = [
            ("", "New problem"),
            ("  the horn is dead. The airbag light is on", "The horn is dead"),
            ("brakes squeal!", "Brakes squeal"),
            ("Battery is flat?", "Battery is flat"),
            ("Rattle; mostly on cold starts", "Rattle"),
            ("Wheel - controls are dead", "Wheel"),
            (
                "horn, cruise, volume, and cluster buttons on the wheel don't work. Airbag warning light is on.",
                "Horn, cruise, volume, and cluster buttons on…"
            ),
            (
                "the engine makes a very long rattling sound that continues after the car warms up",
                "The engine makes a very long rattling sound…"
            ),
            ("already fine", "Already fine"),
            ("  one   space  ", "One space"),
            ("lights don't work, either", "Lights don't work, either"),
            ("A warning appears. Then it disappears", "A warning appears"),
        ]
        for (input, expected) in cases {
            #expect(ProblemTitle.derive(from: input) == expected)
        }
    }

    @Test("renaming trims and ignores empty titles")
    func rename() throws {
        let container = try Garage.inMemoryContainer()
        let garage = Garage(
            context: container.mainContext,
            files: SpiaFiles(
                root: FileManager.default.temporaryDirectory.appendingPathComponent(
                    UUID().uuidString)))
        let vehicle = try garage.addVehicle(name: "Test car")
        let session = try garage.addSession(to: vehicle, title: "Old title")
        try garage.rename(session, to: "  New title  ")
        #expect(session.title == "New title")
        try garage.rename(session, to: " \n ")
        #expect(session.title == "New title")
    }
}
