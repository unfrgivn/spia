import Foundation
import OBDCore
import Testing

@Suite("Generic OBD workflow")
struct GenericOBDWorkflowTests {
    private func fixture(_ name: String) throws -> ReplayTransport {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
        return try ReplayTransport(contentsOf: url)
    }

    @Test("no car on the adapter is 'nobody answered', not a clean empty scan")
    func noVehicle() async throws {
        let transport = try fixture("vlinker-fs-usb-only-probe.txt")
        let session = ELM327Session(transport: transport)
        _ = try await session.connect()
        _ = try await session.identifySTN()
        _ = try await session.send("STDI")
        _ = try await session.voltage()

        let recorder = EventLog()
        await #expect(throws: GenericOBDWorkflow.Failure.noVehicleResponse(.unableToConnect)) {
            _ = try await GenericOBDWorkflow.scan(on: session) { recorder.append($0) }
        }
        let events = recorder.events
        #expect(events == [.requesting(OBDRequest(service: .currentData, pid: 0x00))])
        #expect(await transport.isFinished)
    }
}

/// Collects workflow events from a `@Sendable` callback in a test.
private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [GenericOBDWorkflow.Event] = []

    func append(_ event: GenericOBDWorkflow.Event) {
        lock.withLock { stored.append(event) }
    }

    var events: [GenericOBDWorkflow.Event] { lock.withLock { stored } }
}
