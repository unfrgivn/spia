import Foundation
import OBDCore
import Testing

@Suite("Live monitoring core")
struct LiveMonitoringTests {
    @Test("plan deduplicates PIDs and selects support blocks")
    func plan() throws {
        let plan = try LivePollingPlan(pids: [0x0C, 0x05, 0x0C, 0x21])
        #expect(plan.pids == [0x05, 0x0C, 0x21])
        var support = LiveSupportState(plan: plan)
        #expect(support.nextBlock() == 0)
        support.update(
            block: 0,
            responses: [
                (0x7E8, Set([0x20, 0x05, 0x0C])), (0x7E9, Set([0x05, 0x0C])),
            ])
        #expect(support.nextBlock() == 0x20)
        support.update(block: 0x20, responses: [(0x7E8, Set([0x21]))])
        #expect(support.disposition(pid: 0x21, ecu: 0x7E8) == .supported)
        #expect(support.disposition(pid: 0x21, ecu: 0x7E9) == .unsupported)
        #expect(support.disposition(pid: 0x05, ecu: 0x7E9) == .supported)
        var pid42 = LiveSupportState(plan: try LivePollingPlan(pids: [0x42]))
        #expect(pid42.nextBlock() == 0)
        pid42.update(block: 0, responses: [(0x7E8, Set([0x20, 0x40]))])
        #expect(pid42.nextBlock() == 0x20)
        pid42.update(block: 0x20, responses: [(0x7E8, Set([0x40]))])
        #expect(pid42.nextBlock() == 0x40)
        let chainedPlan = try LivePollingPlan(pids: [0x21, 0x41])
        var chained = LiveSupportState(plan: chainedPlan)
        #expect(chained.nextBlock() == 0)
        chained.update(
            block: 0, responses: [(0x7E8, Set([0x20, 0x40])), (0x7E9, Set([0x20, 0x40]))])
        #expect(chained.nextBlock() == 0x20)
        chained.update(block: 0x20, responses: [(0x7E8, Set([0x21, 0x40]))])
        #expect(chained.nextBlock() == 0x40)
        chained.update(block: 0x40, responses: [(0x7E8, Set([0x41]))])
        #expect(chained.disposition(pid: 0x41, ecu: 0x7E9) == .unknown)
        #expect(throws: LiveValidationError.invalidPID) { try LivePollingPlan(pids: [0x00]) }
        #expect(throws: LiveValidationError.tooManyPIDs) {
            try LivePollingPlan(pids: Array(UInt8(1)...UInt8(17)))
        }
        let schedule = try LiveSchedule(interval: .seconds(60), duration: .seconds(1))
        #expect(schedule.nextDue(after: .zero, now: .seconds(2)) == .seconds(60))
        #expect(
            schedule.boundedWait(now: .seconds(0.9), nextDue: .seconds(60), deadline: .seconds(1))
                == .seconds(0.1))
    }

    @Test("recorded idle responses become numeric rows with units")
    func recordedRows() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ghibli-idle-term.txt")
        let events = try Transcript.decodeFile(String(contentsOf: url, encoding: .utf8))
        let txIndex = try #require(
            events.firstIndex {
                $0.direction == .tx && String(decoding: $0.bytes, as: UTF8.self) == "010C\r"
            })
        var raw = [UInt8]()
        for event in events[(txIndex + 1)...] where event.direction == .rx {
            raw.append(contentsOf: event.bytes)
            if event.bytes.contains(UInt8(ascii: ">")) { break }
        }
        let parsed = try ELM327ResponseParser.parse(
            String(decoding: raw.prefix(while: { $0 != UInt8(ascii: ">") }), as: UTF8.self))
        let responses = try ISOTPReassembler.reassemble(parsed.frames)
        let response = try #require(responses.first)
        let decoded = ServiceResponse.decode(response.payload)
        guard case .currentData(0x0C, let value) = decoded else {
            Issue.record("expected RPM response"); return
        }
        let row = try #require(
            LiveRowDecoder.rows(pid: 0x0C, ecu: response.ecu, value: value, elapsedSeconds: 1).first
        )
        #expect(row.value == "1179.500")
        #expect(row.unit == "rpm")
        #expect(row.status == "value")
    }

    @Test("CSV quotes commas, quotes, and newlines")
    func csv() {
        let row = LiveCSVRow(
            elapsedSeconds: 1.25, ecu: nil, pid: 0x05, name: "coolant,\"temp\"", value: "36.000",
            unit: "°C", status: "value\nconfirmed")
        #expect(
            row.csvLine
                == "\"1.250\",\"\",\"05\",\"coolant,\"\"temp\"\"\",\"36.000\",\"°C\",\"value\nconfirmed\""
        )
    }
}
