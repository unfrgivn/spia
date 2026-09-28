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

    @Test("vLinker FS over Bluetooth LE, ignition on: identity, voltage, and both ECUs")
    func bluetoothProbe() async throws {
        let transport = try fixture("ghibli-ble-ignition-on-probe.txt")
        let session = ELM327Session(transport: transport)

        #expect(try await session.connect() == "ELM327 v2.3")
        #expect(try await session.identifySTN() == "STN2120 v5.8.1")
        #expect(try await session.send("STDI") == "vLinker FS r2")
        #expect(try await session.voltage() == 12.0)
        let responses = try await session.request(OBDRequest(service: .currentData, pid: 0x00))
        var supported: [UInt32: Int] = [:]
        for response in responses {
            if case .currentData(_, .supported(let pids)) = ServiceResponse.decode(response.payload)
            {
                supported[response.ecu] = pids.count
            }
        }
        #expect(supported == [0x7E8: 22, 0x7E9: 6])
        #expect(try await session.describeProtocol() == "AUTO, ISO 15765-4 (CAN 11/500)")
        #expect(try await session.protocolNumber() == "A6")
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

    @Test(
        "replays the generic OBD sequence into production reports, over USB and BLE",
        arguments: ["ghibli-ignition-on-term.txt", "ghibli-ble-ignition-on-term.txt"])
    func ghibliGenericReports(recording: String) async throws {
        let url = fixtureURL(recording)
        let events = try Transcript.decodeFile(String(contentsOf: url, encoding: .utf8))
        let transport = try ReplayTransport(contentsOf: url)
        let session = ELM327Session(transport: transport)
        _ = try await session.connect(protocol: .automatic)

        guard
            let start = events.firstIndex(where: {
                $0.direction == .tx && $0.bytes == Array("ATSP0\r".utf8)
            }),
            let end = events[start...].firstIndex(where: {
                $0.direction == .tx && $0.bytes == Array("ATDP\r".utf8)
            })
        else { throw ReplayError.exhausted }

        var observations: [OBDObservation] = []
        for event in events[(start + 1)..<end] where event.direction == .tx {
            let text = String(decoding: event.bytes.dropLast(), as: UTF8.self)
            guard text.count.isMultiple(of: 2), let bytes = hexBytes(text) else { continue }
            let request = OBDRequest(raw: bytes)
            do {
                let responses = try await session.request(request)
                observations += responses.map {
                    OBDObservation(
                        request: request, ecu: $0.ecu,
                        outcome: .response(ServiceResponse.decode($0.payload)))
                }
            } catch ELM327Error.adapter(.noData) {
                // The fixture has no ECU identity to attach to NO DATA. Positive responses below
                // still prove the production parser/report path for both responding ECUs.
            }
        }

        let reports = OBDReportBuilder.info(observations: observations)
        #expect(reports.count == 2)
        #expect(reports.contains { $0.vin == .positive("ZAM57RTS4H1249941") })
        #expect(reports.contains { $0.vin == .unavailable("not requested") })
        #expect(reports.contains { $0.calibrationIDs == .positive(["670106994 G"]) })
        #expect(reports.contains { $0.calibrationIDs == .positive(["670101187"]) })
        #expect(reports.contains { $0.cvns == .positive(["5E4C9C84"]) })
        #expect(reports.contains { $0.cvns == .positive(["FD5A5568"]) })
        #expect(reports.contains { $0.name == .positive("ECM1-EngineControl1\0") })
        #expect(reports.contains { $0.name == .positive("TCM\0-TransmisCtrl\0\0\0") })

        let scans = OBDReportBuilder.scan(observations: observations)
        #expect(scans.count == 2)
        #expect(
            scans.allSatisfy {
                $0.stored == .positive([]) && $0.pending == .positive([])
                    && $0.permanent == .positive([])
            })
        #expect(scans.allSatisfy { $0.freezeFrameDTC == .positive(nil) })
        #expect(
            scans.allSatisfy {
                if case .positive(let status) = $0.readiness {
                    return !status.milOn && status.dtcCount == 0
                        && status.complete.values.allSatisfy { $0 }
                }
                return false
            })
    }

    private func hexBytes(_ text: String) -> [UInt8]? {
        stride(from: 0, to: text.count, by: 2).map { index in
            let start = text.index(text.startIndex, offsetBy: index)
            let end = text.index(start, offsetBy: 2)
            return UInt8(text[start..<end], radix: 16)
        }.reduce(into: [UInt8]()) { result, byte in
            guard let byte else { result.removeAll(); return }
            result.append(byte)
        }.nilIfEmpty
    }
}

private extension Array where Element == UInt8 {
    var nilIfEmpty: [UInt8]? { isEmpty ? nil : self }
}
