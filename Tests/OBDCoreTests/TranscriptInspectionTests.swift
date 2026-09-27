import Foundation
import OBDCore
import Testing

@Suite("Offline transcript inspection")
struct TranscriptInspectionTests {
    private func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
    }

    @Test("real generic transcript uses production OBD decoding and reports")
    func genericFixture() throws {
        let events = try Transcript.decodeFile(
            String(contentsOf: fixtureURL("ghibli-ignition-on-term.txt"), encoding: .utf8))
        let report = TranscriptInspection.inspect(events)
        #expect(report.obdInfo.count == 2)
        #expect(report.obdInfo.contains { $0.vin == .positive("ZAM57RTS4H1249941") })
        #expect(report.obdInfo.contains { $0.calibrationIDs == .positive(["670106994 G"]) })
        #expect(report.obdInfo.contains { $0.name == .positive("ECM1-EngineControl1\0") })
        #expect(report.obdScan.count == 2)
        #expect(report.rendered.contains("ZAM57RTS4H1249941"))
    }

    @Test("real UDS transcript shows pending and raw final records without names")
    func udsFixture() throws {
        let events = try Transcript.decodeFile(
            String(contentsOf: fixtureURL("ghibli-orc-flowcontrol.txt"), encoding: .utf8))
        let report = TranscriptInspection.inspect(events)
        let results = report.uds.filter { $0.ecu == 0x4C4 }
        #expect(results.count == 2)
        #expect(
            results.contains {
                if case .negative(service: 0x19, code: .responsePending) = $0.response {
                    return true
                }
                return false
            })
        #expect(
            results.contains {
                if case .positive(_, let records) = $0.response {
                    return records.map(\.code) == [[0x80, 0x01, 0x1B], [0x80, 0x02, 0x1B]]
                }
                return false
            })
        #expect(report.rendered.contains("raw 80011B status 8F"))
    }

    @Test("real ABS and BCM UDS captures retain their distinct raw results")
    func otherUDSFixtures() throws {
        let absEvents = try Transcript.decodeFile(
            String(contentsOf: fixtureURL("ghibli-abs-bcm-flowcontrol.txt"), encoding: .utf8))
        let report = TranscriptInspection.inspect(absEvents)
        #expect(
            report.uds.contains {
                $0.ecu == 0x4C7 && $0.response == .positive(availability: 0x7F, records: [])
            })
        #expect(
            report.uds.contains {
                guard $0.ecu == 0x504 else { return false }
                if case .positive(_, let records) = $0.response {
                    return records.count == 1 && records[0].code == [0x10, 0x09, 0x00]
                        && records[0].status == 0x2B
                }
                return false
            })
    }

    @Test("split commands, incomplete prompts, and monitor stop are classified safely")
    func boundedInput() {
        let split = [
            TranscriptEvent(milliseconds: 0, direction: .tx, bytes: Array("01".utf8)),
            TranscriptEvent(milliseconds: 1, direction: .tx, bytes: Array("00\r".utf8)),
            TranscriptEvent(
                milliseconds: 2, direction: .rx, bytes: Array("7E8064100BE3EA813\r>".utf8)),
        ]
        let splitReport = TranscriptInspection.inspect(split)
        #expect(splitReport.exchanges.first?.request == [0x01, 0x00])
        #expect(splitReport.exchanges.first?.complete == true)

        let incomplete = TranscriptInspection.inspect([
            TranscriptEvent(milliseconds: 0, direction: .tx, bytes: Array("0100\r".utf8)),
            TranscriptEvent(milliseconds: 1, direction: .rx, bytes: Array("7E8064100".utf8)),
        ])
        #expect(incomplete.exchanges.first?.complete == false)
        #expect(incomplete.warnings.contains { $0.contains("ended before the prompt") })

        let monitor = TranscriptInspection.inspect([
            TranscriptEvent(milliseconds: 0, direction: .tx, bytes: Array("ATMA\r".utf8)),
            TranscriptEvent(milliseconds: 10, direction: .rx, bytes: Array("10203040\r".utf8)),
            TranscriptEvent(milliseconds: 20, direction: .tx, bytes: [0x20]),
            TranscriptEvent(milliseconds: 21, direction: .rx, bytes: Array("STOPPED\r>".utf8)),
        ])
        #expect(monitor.monitors.count == 1)
        #expect(monitor.monitors[0].complete)
        #expect(monitor.uds.isEmpty)
        #expect(monitor.rendered.contains("not interpreted as diagnostics"))

        let decreasing = TranscriptInspection.inspect([
            TranscriptEvent(milliseconds: 10, direction: .tx, bytes: Array("ATMA\r".utf8)),
            TranscriptEvent(milliseconds: 5, direction: .rx, bytes: Array("STOPPED\r>".utf8)),
        ])
        #expect(decreasing.rendered.contains("Time: 5–10 ms (5 ms)"))
        #expect(decreasing.warnings.contains { $0.contains("timestamps decrease") })

        let pending = TranscriptInspection.inspect([
            TranscriptEvent(milliseconds: 0, direction: .tx, bytes: Array("190209\r".utf8)),
            TranscriptEvent(milliseconds: 1, direction: .rx, bytes: Array("7E8037F1978\r>".utf8)),
        ])
        #expect(pending.warnings.contains { $0.contains("pending without a final") })

        let noData = TranscriptInspection.inspect([
            TranscriptEvent(milliseconds: 0, direction: .tx, bytes: Array("0100\r".utf8)),
            TranscriptEvent(milliseconds: 1, direction: .rx, bytes: Array("NO DATA\r>".utf8)),
        ])
        #expect(noData.warnings.contains { $0.contains("no response from the vehicle") })

        let trailing = TranscriptInspection.inspect([
            TranscriptEvent(milliseconds: 0, direction: .tx, bytes: Array("0400\rJUNK".utf8)),
            TranscriptEvent(milliseconds: 1, direction: .rx, bytes: Array("OK\r>TAIL".utf8)),
            TranscriptEvent(milliseconds: 2, direction: .tx, bytes: Array("0100".utf8)),
        ])
        #expect(trailing.warnings.contains { $0.contains("TX bytes after CR") })
        #expect(trailing.warnings.contains { $0.contains("RX bytes after prompt") })
        #expect(trailing.warnings.contains { $0.contains("without CR") })
        #expect(trailing.exchanges.contains { $0.kind == "uninterpreted diagnostic" })
    }

    @Test("recorded monitor capture remains a complete monitor exchange")
    func recordedMonitor() throws {
        let events = try Transcript.decodeFile(
            String(contentsOf: fixtureURL("ghibli-ignition-on-capture-2s.txt"), encoding: .utf8))
        let report = TranscriptInspection.inspect(events)
        #expect(report.monitors.count == 1)
        #expect(report.monitors[0].complete)
        #expect(report.uds.isEmpty)
        #expect(report.warnings.contains { $0.contains("monitor adapter") })
        #expect(report.rendered.contains("not interpreted as diagnostics"))
    }

    @Test("malformed transcript is rejected without replaying writes")
    func malformed() {
        #expect(throws: TranscriptError.malformedLine("bad")) {
            try Transcript.decode("bad")
        }
    }
}
