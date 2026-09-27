import Foundation
import OBDCore
import Testing

/// Drives `ELM327Session` against transcripts recorded from the real vLinker FS.
/// Nothing in these fixtures is hand-written; see `spia --record`.
@Suite("ELM327 session (replayed recordings)")
struct ELM327SessionReplayTests {
    private func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
    }

    private func fixture(_ name: String) throws -> ReplayTransport {
        try ReplayTransport(contentsOf: fixtureURL(name))
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

    @Test("2017 Ghibli, ignition on: STBR to 2 Mbps, 2 s of ATMA, stop, switch back")
    func ghibliCapture() async throws {
        let url = fixtureURL("ghibli-ignition-on-capture-2s.txt")
        let transport = try ReplayTransport(contentsOf: url)
        let session = ELM327Session(transport: transport)

        _ = try await session.connect(protocol: .can11bit500k)
        try await session.switchBaud(to: 2_000_000)

        // The live run was cancelled between two reads. Stop on the last event of the last
        // recorded chunk so the replay takes the same path.
        let total = try monitorEventCount(in: url)
        var summary = CaptureSummary()
        var seen = 0
        var tags = 0
        let recorder = Recorder()
        try await session.monitor { elapsed, event in
            await recorder.record(elapsed, event)
            return await recorder.count < total
        }
        (summary, seen, tags) = await recorder.snapshot()

        #expect(seen == total)
        #expect(summary.frameCount == 4296)
        #expect(summary.rows.count == 124)
        #expect(tags == 1258, "frames tagged <DATA ERROR are kept and counted")
        let engineish = summary.rows.first { $0.id == 0x102 }
        #expect(engineish?.count == 204, "100 Hz for the 2.04 s the monitor actually ran")
        #expect(
            engineish?.changingBytes == [6, 7], "rolling counter and CRC only, wheel untouched")

        await session.disconnect()
        #expect(await transport.isFinished, "disconnect put the UART back to 115200")
    }

    private actor Recorder {
        private var summary = CaptureSummary()
        private(set) var count = 0
        private var tags = 0

        func record(_ elapsed: Duration, _ event: MonitorEvent) {
            count += 1
            switch event {
            case .frame(let frame): summary.record(frame, at: elapsed)
            case .message(.dataError): tags += 1
            default: break
            }
        }

        func snapshot() -> (CaptureSummary, Int, Int) {
            (summary, count, tags)
        }
    }

    /// Events the parser produces from everything the adapter sent between `ATMA` and the stop
    /// byte, straight from the transcript.
    private func monitorEventCount(in url: URL) throws -> Int {
        let events = try Transcript.decodeFile(String(contentsOf: url, encoding: .utf8))
        guard
            let start = events.firstIndex(where: {
                $0.direction == .tx && $0.bytes == Array("ATMA\r".utf8)
            }),
            let stop = events[start...].firstIndex(where: {
                $0.direction == .tx && $0.bytes == [0x20]
            })
        else {
            throw ReplayError.exhausted
        }
        var parser = MonitorStreamParser()
        return events[(start + 1)..<stop].reduce(0) { $0 + parser.feed($1.bytes).count }
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
