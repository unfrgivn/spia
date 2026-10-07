import Foundation
import OBDCore
import Testing

@Suite("Recorded replay timing")
struct ReplayTimingTests {
    private let clock = ContinuousClock()

    private func fixture(_ name: String) throws -> [TranscriptEvent] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures").appendingPathComponent(name)
        return try Transcript.decodeFile(String(contentsOf: url, encoding: .utf8))
    }

    @Test("recorded RX chunks keep their latency after one command")
    func chunksKeepRecordedLatency() throws {
        let events = try fixture("ghibli-orc-flowcontrol.txt")
        let txIndex = try #require(
            events.firstIndex { $0.direction == .tx && $0.bytes == Array("190209\r".utf8) })
        let tx = events[txIndex]
        let rxEnd =
            events[(txIndex + 1)...].firstIndex(where: {
                $0.direction == .tx
            })
            ?? events.count
        let rxIndices = Array((txIndex + 1)..<rxEnd).filter { events[$0].direction == .rx }
        #expect(rxIndices.count >= 2)

        let write = clock.now
        for index in rxIndices {
            let offset = events[index].milliseconds - tx.milliseconds
            let expected: ReplayReadDecision
            if offset == 0 {
                expected = .deliver
            } else {
                expected = .deliverAfter(.milliseconds(Int64(offset)))
            }
            #expect(
                ReplayTransport.readDecision(
                    events: events, cursor: index,
                    lastWriteRecordedMilliseconds: tx.milliseconds,
                    lastWriteInstant: write, now: write, timeout: .seconds(1)) == expected)
        }
    }

    @Test("a short timeout does not advance before a recorded response")
    func shortTimeoutWaits() throws {
        let events = try fixture("vlinker-fs-usb-only-probe.txt")
        let txIndex = try #require(
            events.firstIndex { $0.direction == .tx && $0.bytes == Array("ATZ\r".utf8) })
        let rxIndex = try #require(
            events[(txIndex + 1)...].firstIndex { $0.direction == .rx })
        let write = clock.now
        let decision = ReplayTransport.readDecision(
            events: events, cursor: rxIndex,
            lastWriteRecordedMilliseconds: events[txIndex].milliseconds,
            lastWriteInstant: write, now: write, timeout: .milliseconds(1))
        #expect(decision == .wait(.milliseconds(1)))
    }

    @Test("a next TX means no response arrives during this read")
    func nextWriteWaits() throws {
        let events = try fixture("ghibli-ignition-on-probe.txt")
        let txIndex = try #require(
            events.firstIndex { $0.direction == .tx && $0.bytes == Array("ATZ\r".utf8) })
        let nextTx = try #require(
            events[(txIndex + 1)...].firstIndex { $0.direction == .tx })
        #expect(
            ReplayTransport.readDecision(
                events: events, cursor: nextTx,
                lastWriteRecordedMilliseconds: events[txIndex].milliseconds,
                lastWriteInstant: clock.now, now: clock.now,
                timeout: .milliseconds(7)) == .wait(.milliseconds(7)))
    }

    @Test("a cancelled paced read throws instead of delivering")
    func cancellationInterruptsRead() async throws {
        let events = try fixture("ghibli-ignition-on-probe.txt")
        let transport = ReplayTransport(events: events, timing: .recorded)
        try await transport.write(Array("ATZ\r".utf8))
        // Cancelled at once, so the outcome doesn't depend on the clock: the read either
        // hasn't started and refuses, or is pacing the 1.2 s gap and is interrupted.
        let read = Task { try await transport.read(timeout: .seconds(3)) }
        read.cancel()
        await #expect(throws: CancellationError.self) { try await read.value }
    }
}
