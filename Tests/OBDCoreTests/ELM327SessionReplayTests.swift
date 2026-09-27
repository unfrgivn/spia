import Foundation
import OBDCore
import Testing

/// Drives `ELM327Session` against transcripts recorded from the real vLinker FS.
/// Nothing in these fixtures is hand-written; see `spia --record`.
@Suite("ELM327 session (replayed recordings)")
struct ELM327SessionReplayTests {
    private func fixture(_ name: String) throws -> ReplayTransport {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
        return try ReplayTransport(contentsOf: url)
    }

    @Test("USB-powered adapter with no vehicle: full probe flow")
    func usbOnlyProbe() async throws {
        let transport = try fixture("vlinker-fs-usb-only-probe.txt")
        let session = ELM327Session(transport: transport)

        let identity = try await session.connect()
        #expect(identity == "ELM327 v2.3")
        #expect(try await session.identifySTN() == "STN1170 v4.3.2")
        #expect(try await session.send("STDI") == "vLinker FS r2")
        #expect(try await session.voltage() == nil)

        await #expect(throws: ELM327Error.adapter(.unableToConnect)) {
            try await session.request(OBDRequest(service: .currentData, pid: 0x00))
        }
        #expect(await transport.isFinished)
    }

    @Test("a deviation from the recording is caught, not papered over")
    func deviationDetected() async throws {
        let transport = try fixture("vlinker-fs-usb-only-probe.txt")
        let session = ELM327Session(transport: transport)
        _ = try await session.connect()

        await #expect(throws: ReplayError.self) {
            try await session.send("ATI")
        }
    }
}
