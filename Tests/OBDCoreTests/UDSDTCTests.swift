import Foundation
import OBDCore
import Testing

@Suite("UDS DTC decoder")
struct UDSDTCTests {
    @Test("rejects diagnostic headers wider than 29 bits before writing")
    func rejectsInvalidDiagnosticHeadersBeforeIO() async {
        let transport = ReplayTransport(events: [])
        let session = ELM327Session(transport: transport)

        await #expect(throws: ELM327Error.invalidCANHeader(0x2000_0000)) {
            try await session.configureDiagnosticHeaders(
                requestHeader: 0x2000_0000, responseHeader: 0x4C4)
        }
    }

    @Test("decodes availability and raw three-byte DTC records")
    func decodesPositiveResponse() throws {
        let response = try UDSDTCDecoder.decode(
            [0x59, 0x02, 0xCF, 0x80, 0x01, 0x1B, 0x8F, 0x80, 0x02, 0x1B, 0x8F])

        #expect(
            response
                == .positive(
                    availability: 0xCF,
                    records: [
                        UDSDTCRecord(code: [0x80, 0x01, 0x1B], status: 0x8F),
                        UDSDTCRecord(code: [0x80, 0x02, 0x1B], status: 0x8F),
                    ]))
    }

    @Test("recognizes conditions-not-correct and response-pending negative replies")
    func decodesNegativeResponses() throws {
        #expect(
            try UDSDTCDecoder.decode([0x7F, 0x19, 0x22])
                == .negative(service: 0x19, code: .conditionsNotCorrect))
        #expect(
            try UDSDTCDecoder.decode([0x7F, 0x19, 0x78])
                == .negative(service: 0x19, code: .responsePending))
    }

    @Test("selects a terminal negative response after pending")
    func selectsTerminalNegativeResponse() throws {
        let raw = "4C4037F1978\r4C4037F1922\r"
        #expect(
            try UDSDTCResponseSelector.select(raw, expectedECU: 0x4C4)
                == .negative(service: 0x19, code: .conditionsNotCorrect))
    }

    @Test("rejects pending for an unrelated negative-response service")
    func rejectsWrongNegativeService() {
        #expect(throws: UDSReadError.wrongNegativeService(0x22)) {
            try UDSDTCResponseSelector.select("4C4037F2278\r", expectedECU: 0x4C4)
        }
    }

    @Test("rejects pending-only prompt")
    func rejectsPendingOnly() {
        #expect(throws: UDSReadError.pendingWithoutFinalResponse) {
            try UDSDTCResponseSelector.select("4C4037F1978\r", expectedECU: 0x4C4)
        }
    }

    @Test("rejects a prompt with no frames")
    func rejectsNoFrames() {
        #expect(throws: UDSReadError.noFrames) {
            try UDSDTCResponseSelector.select("\r", expectedECU: 0x4C4)
        }
    }

    @Test("rejects adapter error statuses instead of returning a DTC result")
    func rejectsAdapterStatus() {
        #expect(throws: UDSReadError.adapterStatus(.noData)) {
            try UDSDTCResponseSelector.select("NO DATA\r", expectedECU: 0x4C4)
        }
        #expect(throws: UDSReadError.adapterStatus(.canError)) {
            try UDSDTCResponseSelector.select("CAN ERROR\r4C403590200\r", expectedECU: 0x4C4)
        }
    }

    @Test("rejects an unexpected ECU")
    func rejectsUnexpectedECU() {
        #expect(throws: UDSReadError.unexpectedECU(0x4C5)) {
            try UDSDTCResponseSelector.select("4C5037F1978\r", expectedECU: 0x4C4)
        }
    }

    @Test("rejects duplicate final responses")
    func rejectsDuplicateFinal() {
        #expect(throws: UDSReadError.duplicateFinalResponse) {
            try UDSDTCResponseSelector.select("4C403590200\r4C403590200\r", expectedECU: 0x4C4)
        }
    }

    @Test("rejects invalid service, subfunction, and record lengths")
    func rejectsInvalidPayloads() {
        #expect(throws: UDSDTCDecodeError.invalidService(0x58)) {
            try UDSDTCDecoder.decode([0x58, 0x02, 0x00])
        }
        #expect(throws: UDSDTCDecodeError.invalidSubfunction(0x01)) {
            try UDSDTCDecoder.decode([0x59, 0x01, 0x00])
        }
        #expect(throws: UDSDTCDecodeError.invalidLength) {
            try UDSDTCDecoder.decode([0x59, 0x02, 0x00, 0x80])
        }
        #expect(throws: UDSDTCDecodeError.invalidLength) {
            try UDSDTCDecoder.decode([0x7F, 0x19])
        }
    }

    @Test("validates timeout and cancellation before any adapter write")
    func validatesBeforeIO() async {
        let transport = ReplayTransport(events: [])
        let session = ELM327Session(transport: transport)
        await #expect(throws: ELM327Error.invalidTimeout) {
            try await session.readUDSDTC(
                responseHeader: 0x4C4, timeout: .zero)
        }
        let task = Task {
            try await session.readUDSDTC(responseHeader: 0x4C4)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await transport.isFinished)
    }

    @Test("replays ORC pending and final payloads without splicing messages")
    func replaysORC() async throws {
        let url = fixtureURL("ghibli-orc-flowcontrol.txt")
        let transport = try ReplayTransport(contentsOf: url)
        let session = ELM327Session(transport: transport)

        _ = try await session.connect()
        _ = try await session.send("ATRV")
        _ = try await session.send("ATSP6")
        _ = try await session.send("ATST 64")
        _ = try await session.send("ATCFC 1")
        try await session.configureDiagnosticHeaders(requestHeader: 0x744, responseHeader: 0x4C4)
        let decoded = [
            try await session.readUDSDTC(responseHeader: 0x4C4)
        ]

        #expect(
            decoded == [
                .positive(
                    availability: 0xCF,
                    records: [
                        UDSDTCRecord(code: [0x80, 0x01, 0x1B], status: 0x8F),
                        UDSDTCRecord(code: [0x80, 0x02, 0x1B], status: 0x8F),
                    ])
            ])
        #expect(await transport.isFinished)
    }

    @Test("replays ABS and BCM availability with their distinct payloads")
    func replaysABSandBCM() async throws {
        let url = fixtureURL("ghibli-abs-bcm-flowcontrol.txt")
        let transport = try ReplayTransport(contentsOf: url)
        let session = ELM327Session(transport: transport)

        _ = try await session.connect()
        _ = try await session.send("ATSP6")
        _ = try await session.send("ATST 64")
        _ = try await session.send("ATCFC 1")
        _ = try await session.send("ATFCSD 30 00 00")
        _ = try await session.send("ATSH 747")
        _ = try await session.send("ATCRA 4C7")
        _ = try await session.send("ATFCSH 747")
        _ = try await session.send("ATFCSM 1")
        let absResponse = try await session.readUDSDTC(responseHeader: 0x4C7)
        _ = try await session.send("ATSH 620")
        _ = try await session.send("ATCRA 504")
        _ = try await session.send("ATFCSH 620")
        _ = try await session.send("ATFCSM 1")
        let bcmResponse = try await session.readUDSDTC(responseHeader: 0x504)
        let decoded = [absResponse, bcmResponse]

        #expect(
            decoded == [
                .positive(availability: 0x7F, records: []),
                .positive(
                    availability: 0xFB,
                    records: [
                        UDSDTCRecord(code: [0x10, 0x09, 0x00], status: 0x2B)
                    ]),
            ])
        #expect(await transport.isFinished)
    }

    private func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
    }

}
