import CryptoKit
import Foundation
import OBDCore
import SpiaKit
import Testing

/// The app's own recordings from the 2017 Ghibli S Q4 on 2026-09-30, made by onboarding the car
/// in the Mac app over the USB vLinker FS with the ignition on: the survey, then vehicle
/// information (which reset the adapter in place, because the survey had left it on a module),
/// then the scan. Each replays through today's code to the result the app saved at the car.
@Suite("Ghibli app recordings")
struct CarSurveyReplayTests {
    private static let vin = "ZAM57RTS4H1249941"
    private let adapter = AdapterDescriptor(kind: .usbSerial, displayName: "vLinker FS")

    private func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures").appendingPathComponent(name)
    }

    private func saved(_ name: String) throws -> JobResult {
        try JSONDecoder().decode(JobResult.self, from: Data(contentsOf: fixture(name)))
    }

    /// Runs `job` over a fresh connection to the recording, confirming any ignition prompt.
    private func replay(
        _ job: DiagnosticJob, from recording: String
    ) async throws -> (result: JobResult?, finished: Bool) {
        let transport = try ReplayTransport(contentsOf: fixture(recording))
        let connection = ConnectionManager(adapter: adapter) { transport }
        try await connection.connect()
        let runner = JobRunner(connection: connection)
        var result: JobResult?
        for await event in await runner.run(job) {
            switch event {
            case .needsUser(let id, _): await runner.confirm(id)
            case .completed(let completed): result = completed
            default: break
            }
        }
        return (result, await transport.isFinished)
    }

    @Test("each saved result names its recording by size and SHA-256")
    func recordingsMatchResults() throws {
        for name in [
            "ghibli-app-survey", "ghibli-app-vehicle-info-after-survey", "ghibli-app-scan",
        ] {
            let result = try saved("\(name).result.json")
            let data = try Data(contentsOf: fixture("\(name).txt"))
            #expect(result.source == .live)
            #expect(result.transcript?.byteCount == data.count)
            #expect(
                result.transcript?.sha256
                    == SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        }
    }

    @Test("the survey replays to the report the app saved at the car")
    func survey() async throws {
        let saved = try saved("ghibli-app-survey.result.json")
        guard case .survey(let plan) = saved.job, case .survey(let report) = saved.payload else {
            Issue.record("the saved result isn't a survey")
            return
        }
        let replayed = try await replay(.survey(plan), from: "ghibli-app-survey.txt")
        #expect(replayed.result?.payload == saved.payload)
        #expect(replayed.finished)

        // Every module the catalog knows for M157 answered, and none of the other legislated IDs.
        #expect(
            report.modules.map(\.candidate.target.request) == [
                0x744, 0x747, 0x620, 0x763, 0x7E0, 0x7E1,
            ])
        #expect(report.unanswered.map(\.target.request) == Array(0x7E2...0x7E7))
        #expect(report.stop == nil)
        // Each module gave the car's VIN, so it belongs to this car, but none named itself.
        for module in report.modules {
            let identification = Dictionary(
                module.identification.map { ($0.did, $0.result) },
                uniquingKeysWith: { first, _ in first })
            #expect(identification[0xF190] == .value(Array(Self.vin.utf8)))
            #expect(identification[0xF197] == .refused(0x31))
        }
        // The steering column, read here for the first time: two codes failing now, one confirmed.
        let steering = try #require(report.modules.first { $0.candidate.target.request == 0x763 })
        #expect(
            steering.codes
                == .outcome(
                    .records(
                        availability: 0x39,
                        [
                            ModuleDTCRecord(code: "059300", status: 0x29),
                            ModuleDTCRecord(code: "058100", status: 0x29),
                            ModuleDTCRecord(code: "D00800", status: 0x28),
                        ])))
        let airbag = try #require(report.modules.first { $0.candidate.target.request == 0x744 })
        #expect(
            airbag.codes
                == .outcome(
                    .records(
                        availability: 0xCF,
                        [
                            ModuleDTCRecord(code: "80011B", status: 0x8F),
                            ModuleDTCRecord(code: "80021B", status: 0x8F),
                        ])))
        #expect(
            airbag.identification.first { $0.did == 0xF187 }?.result
                == .value(Array("670101610  ".utf8)))
    }

    @Test("vehicle information right after the survey reset the adapter in place and read the VIN")
    func vehicleInfoAfterSurvey() async throws {
        let saved = try saved("ghibli-app-vehicle-info-after-survey.result.json")
        let replayed = try await replay(
            .vehicleInfo, from: "ghibli-app-vehicle-info-after-survey.txt")
        #expect(replayed.result?.payload == saved.payload)
        #expect(replayed.finished)
        guard case .vehicleInfo(let ecus) = saved.payload else {
            Issue.record("the saved result isn't vehicle information")
            return
        }
        #expect(ecus.map(\.ecu) == [0x7E8, 0x7E9])
        #expect(ecus.compactMap(\.vin.value).contains(Self.vin))

        // The reset happened on a connection already set up: the adapter didn't echo `ATZ`
        // because echo was still off, whereas the survey's connect, on an adapter fresh from
        // power-up, echoed it.
        let reset = try Transcript.decodeFile(
            String(contentsOf: fixture("ghibli-app-vehicle-info-after-survey.txt"), encoding: .utf8)
        )
        let connect = try Transcript.decodeFile(
            String(contentsOf: fixture("ghibli-app-survey.txt"), encoding: .utf8))
        #expect(reset.first?.bytes == Array("ATZ\r".utf8))
        #expect(!String(decoding: reset[1].bytes, as: UTF8.self).contains("ATZ"))
        #expect(connect.first?.bytes == Array("ATZ\r".utf8))
        #expect(
            String(decoding: connect[1].bytes + connect[2].bytes, as: UTF8.self).hasPrefix("ATZ"))
    }

    @Test("the scan after it replays to the result the app saved")
    func scan() async throws {
        let saved = try saved("ghibli-app-scan.result.json")
        let replayed = try await replay(.genericScan, from: "ghibli-app-scan.txt")
        #expect(replayed.result?.payload == saved.payload)
        #expect(replayed.finished)
    }
}
