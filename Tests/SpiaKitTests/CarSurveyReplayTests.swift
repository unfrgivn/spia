import CryptoKit
import Foundation
import OBDCore
import SpiaKit
import Testing

/// The app's own recordings from the cars on 2026-09-30, copied verbatim from its libraries with
/// the results it saved when it made them:
///
/// - `ghibli-app-*`: the 2017 Ghibli S Q4 onboarded in the Mac app over the USB vLinker FS. The
///   survey (after an ignition prompt), vehicle information, and the scan.
/// - `ghibli-app-ble-*`: the same car minutes later, onboarded on an iPhone over the Bluetooth
///   vLinker FS while its ignition had only just come on. The survey, vehicle information (after
///   an ignition prompt, because by then the car had gone quiet), the scan, and a body computer
///   read.
/// - `tiguan-app-*`: the 2018 Tiguan onboarded in the Mac app over USB. The survey, then vehicle
///   information.
/// - `cx5-app-ble-*`: a 2014 Mazda CX-5 onboarded on the iPhone over Bluetooth with only part of
///   the car on: the transmission answered, the engine computer didn't. The survey, vehicle
///   information, then, after the owner switched the ignition fully on, the scan and vehicle
///   information again.
/// - `*-app-search*` and `*-vehicle-info-after-search`: the thorough search's first runs on the
///   cars, 2026-10-04, in the Mac app over USB, each followed by vehicle information.
@Suite("App recordings from the cars")
struct CarSurveyReplayTests {
    struct Recording: Sendable, CustomTestStringConvertible {
        let name: String
        let adapter: ConnectionKind
        /// What the app asked the owner during the check, in order.
        let prompts: [UserAction]

        var testDescription: String { name }
    }

    static let recordings = [
        Recording(name: "ghibli-app-survey", adapter: .usbSerial, prompts: [.turnIgnitionOn]),
        Recording(name: "ghibli-app-vehicle-info-after-survey", adapter: .usbSerial, prompts: []),
        Recording(name: "ghibli-app-scan", adapter: .usbSerial, prompts: []),
        Recording(name: "ghibli-app-ble-survey", adapter: .bluetooth, prompts: []),
        Recording(
            name: "ghibli-app-ble-vehicle-info-after-survey", adapter: .bluetooth,
            prompts: [.turnIgnitionOn]),
        Recording(name: "ghibli-app-ble-scan", adapter: .bluetooth, prompts: []),
        Recording(name: "ghibli-app-ble-bcm-read", adapter: .bluetooth, prompts: []),
        Recording(name: "tiguan-app-survey", adapter: .usbSerial, prompts: []),
        Recording(name: "tiguan-app-vehicle-info-after-survey", adapter: .usbSerial, prompts: []),
        Recording(name: "cx5-app-ble-survey", adapter: .bluetooth, prompts: []),
        Recording(name: "cx5-app-ble-scan", adapter: .bluetooth, prompts: []),
        Recording(
            name: "cx5-app-ble-vehicle-info-after-ignition", adapter: .bluetooth, prompts: []),
        Recording(name: "ghibli-app-search", adapter: .usbSerial, prompts: []),
        Recording(name: "ghibli-app-vehicle-info-after-search", adapter: .usbSerial, prompts: []),
        Recording(name: "tiguan-app-search-busy", adapter: .usbSerial, prompts: []),
        Recording(name: "tiguan-app-vehicle-info-after-search", adapter: .usbSerial, prompts: []),
    ]

    private static let ghibliVIN = "ZAM57RTS4H1249941"
    private static let tiguanVIN = "3VV4B7AX3JM197049"
    private static let cx5VIN = "JM3KE4DY6E0322030"

    private static func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures").appendingPathComponent(name)
    }

    private static func saved(_ name: String) throws -> JobResult {
        try JSONDecoder().decode(
            JobResult.self, from: Data(contentsOf: fixture("\(name).result.json")))
    }

    private static func transcript(_ name: String) throws -> [TranscriptEvent] {
        try Transcript.decodeFile(String(contentsOf: fixture("\(name).txt"), encoding: .utf8))
    }

    private static func sent(_ name: String) throws -> [String] {
        try transcript(name).filter { $0.direction == .tx }
            .map { String(decoding: $0.bytes.dropLast(), as: UTF8.self) }
    }

    private static func survey(_ name: String) throws -> SurveyReport {
        guard case .survey(let report) = try saved(name).payload else {
            throw ReplayFailure("\(name) isn't a survey")
        }
        return report
    }

    private static func vehicleInfo(_ name: String) throws -> [ECUIdentity] {
        guard case .vehicleInfo(let ecus) = try saved(name).payload else {
            throw ReplayFailure("\(name) isn't vehicle information")
        }
        return ecus
    }

    private static func module(_ request: UInt32, in report: SurveyReport) throws -> SurveyModule {
        try #require(report.modules.first { $0.candidate.target.request == request })
    }

    private static func records(_ module: SurveyModule) -> [ModuleDTCRecord] {
        if case .outcome(.records(_, let records)) = module.codes { return records }
        return []
    }

    private struct ReplayFailure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    @Test("each saved result names its recording by size and SHA-256", arguments: recordings)
    func recordingMatchesResult(_ recording: Recording) throws {
        let result = try Self.saved(recording.name)
        let data = try Data(contentsOf: Self.fixture("\(recording.name).txt"))
        #expect(result.source == .live)
        #expect(result.transcript?.byteCount == data.count)
        #expect(
            result.transcript?.sha256
                == SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }

    @Test(
        "each recording replays to the result the app saved, asking what it asked",
        arguments: recordings)
    func replays(_ recording: Recording) async throws {
        let saved = try Self.saved(recording.name)
        let transport = try ReplayTransport(contentsOf: Self.fixture("\(recording.name).txt"))
        let adapter = AdapterDescriptor(kind: recording.adapter, displayName: "vLinker FS")
        let connection = ConnectionManager(adapter: adapter) { transport }
        try await connection.connect()
        let runner = JobRunner(connection: connection)
        var result: JobResult?
        var prompts: [UserAction] = []
        for await event in await runner.run(saved.job) {
            switch event {
            case .needsUser(let id, let action):
                prompts.append(action)
                await runner.confirm(id)
            case .completed(let completed): result = completed
            default: break
            }
        }
        #expect(result?.payload == saved.payload)
        #expect(prompts == recording.prompts)
        #expect(await transport.isFinished)
    }

    @Test(
        "the Ghibli over USB: six modules, each giving the VIN, and only the engine computers named"
    )
    func ghibliSurvey() throws {
        let report = try Self.survey("ghibli-app-survey")
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
            #expect(identification[0xF190] == .value(Array(Self.ghibliVIN.utf8)))
            #expect(identification[0xF197] == .refused(0x31))
        }
        // The steering column, read here for the first time: two codes failing now, one confirmed.
        #expect(
            try Self.module(0x763, in: report).codes
                == .outcome(
                    .records(
                        availability: 0x39,
                        [
                            ModuleDTCRecord(code: "059300", status: 0x29),
                            ModuleDTCRecord(code: "058100", status: 0x29),
                            ModuleDTCRecord(code: "D00800", status: 0x28),
                        ])))
        let airbag = try Self.module(0x744, in: report)
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

        // The FCA modules keep their reference labels, unconfirmed; the engine and transmission
        // keep theirs too, confirmed by the names they gave over OBD.
        let proposed = report.proposedModules()
        #expect(
            proposed.map(\.label) == [
                "Airbag controller (ORC)", "ABS", "Body computer (BCM)", "Steering column (SCCM)",
                "Engine", "Transmission",
            ])
        #expect(proposed.map(\.confirmed) == [false, false, false, false, true, true])
        #expect(
            SurveyReview(report: report).rows.map(\.caption) == [
                "From references, unconfirmed", "From references, unconfirmed",
                "From references, unconfirmed", "From references, unconfirmed",
                "Calls itself ECM1-EngineControl1", "Calls itself TCM-TransmisCtrl",
            ])
    }

    @Test("vehicle information right after the Ghibli's USB survey reset the adapter in place")
    func ghibliVehicleInfoAfterSurvey() throws {
        let ecus = try Self.vehicleInfo("ghibli-app-vehicle-info-after-survey")
        #expect(ecus.map(\.ecu) == [0x7E8, 0x7E9])
        #expect(ecus.compactMap(\.vin.value).contains(Self.ghibliVIN))

        // The reset happened on a connection already set up: the adapter didn't echo `ATZ`
        // because echo was still off, whereas the survey's connect, on an adapter fresh from
        // power-up, echoed it.
        let reset = try Self.transcript("ghibli-app-vehicle-info-after-survey")
        let connect = try Self.transcript("ghibli-app-survey")
        #expect(reset.first?.bytes == Array("ATZ\r".utf8))
        #expect(!String(decoding: reset[1].bytes, as: UTF8.self).contains("ATZ"))
        #expect(connect.first?.bytes == Array("ATZ\r".utf8))
        #expect(
            String(decoding: connect[1].bytes + connect[2].bytes, as: UTF8.self).hasPrefix("ATZ"))
    }

    @Test("the Ghibli over Bluetooth, surveyed as its ignition came on: four modules answered")
    func ghibliBluetoothSurvey() throws {
        let report = try Self.survey("ghibli-app-ble-survey")
        // The airbag controller and the engine, which answered over USB minutes earlier, stayed
        // silent: the car's power was changing during this survey, not the adapter dropping
        // replies, as the next three checks show.
        #expect(report.modules.map(\.candidate.target.request) == [0x747, 0x620, 0x763, 0x7E1])
        #expect(
            report.unanswered.map(\.target.request) == [0x744, 0x7E0] + Array(0x7E2...0x7E7))
        // Only the engine answered the opening requests. The transmission was still starting up,
        // and answered its own address seven seconds later.
        #expect(report.vehicleInfo.map(\.ecu) == [0x7E8])
        // The body computer's code says its operation cycle had only just begun: test not
        // completed this cycle (0x40), and not yet failed this cycle (0x02). Over USB, and again
        // over Bluetooth a minute later, the same code reads 0x2B.
        #expect(
            try Self.module(0x620, in: report).codes
                == .outcome(
                    .records(availability: 0xFB, [ModuleDTCRecord(code: "100900", status: 0x69)])))
        #expect(
            Self.records(try Self.module(0x763, in: report)) == [
                ModuleDTCRecord(code: "059300", status: 0x29),
                ModuleDTCRecord(code: "058100", status: 0x29),
                ModuleDTCRecord(code: "D00800", status: 0x28),
            ])
    }

    @Test("over Bluetooth, the reset after the survey worked and the car had gone quiet")
    func ghibliBluetoothAfterSurvey() throws {
        // The survey left the adapter listening for `7EF` only, the last address it asked. The
        // next check reset it first, so the engine computers' replies on `7E8` and `7E9` got
        // through: but only after an ignition prompt, because nothing answered at first.
        #expect(
            try Self.sent("ghibli-app-ble-survey").last { $0.hasPrefix("ATCRA") } == "ATCRA 7EF")
        let sent = try Self.sent("ghibli-app-ble-vehicle-info-after-survey")
        #expect(sent.first == "ATZ")
        #expect(sent.filter { $0 == "0900" }.count == 2)
        let ecus = try Self.vehicleInfo("ghibli-app-ble-vehicle-info-after-survey")
        #expect(ecus.map(\.ecu) == [0x7E8, 0x7E9])
        #expect(ecus.compactMap(\.vin.value).contains(Self.ghibliVIN))

        // A minute after the survey, the body computer's code had failed this cycle.
        guard case .moduleDTCs(let read) = try Self.saved("ghibli-app-ble-bcm-read").payload else {
            Issue.record("the saved result isn't a module read")
            return
        }
        #expect(read.target.request == 0x620)
        #expect(
            read.outcome
                == .records(availability: 0xFB, [ModuleDTCRecord(code: "100900", status: 0x2B)]))
    }

    @Test("the Tiguan: 19 modules answered, and every one named itself")
    func tiguanSurvey() throws {
        let report = try Self.survey("tiguan-app-survey")
        #expect(
            report.modules.map(\.candidate.target.request) == [
                0x7E0, 0x7E1, 0x710, 0x70E, 0x713, 0x715, 0x712, 0x70C, 0x714, 0x746, 0x70F, 0x757,
                0x74A, 0x74B, 0x70A, 0x773, 0x732, 0x769, 0x74F,
            ])
        // The immobilizer, parking brake, second all-wheel-drive address, tire pressure, and
        // headlight range are only references, and this car didn't answer at them.
        #expect(
            report.unanswered.map(\.target.request)
                == [0x711, 0x752, 0x71D, 0x70B, 0x754] + Array(0x7E2...0x7E7))
        #expect(report.stop == nil)
        #expect(
            report.vehicleInfo.first { $0.ecu == 0x7E8 }.flatMap(\.vin.value) == Self.tiguanVIN)

        // Readable labels first, each confirmed by the name the module gave, which arrives padded
        // with spaces or NULs.
        let ownNames = [
            "R4 2.0l TFSI", "AISIN AQ8", "GW MQB High", "BCM PQ37BOSCH", "ESC", "AirbagVW21",
            "MQB_PP_APA", "Lenks. Modul", "KOMBI", "AC Automat", "Haldex4Motion", "ACCCONTIMQB",
            "TSG FS", "TSG BFS", "PDC 8 Kanal", "MU-S-NS-US", "VWKESSYMQB", "Areaview 2",
            "MQB_B_MFK",
        ]
        #expect(report.modules.map { report.ownName(of: $0)?.text } == ownNames)
        let selfNamed = report.modules.filter { report.ownName(of: $0)?.source == .module }
        #expect(selfNamed.count == report.modules.count)
        let proposed = report.proposedModules()
        #expect(
            proposed.map(\.label) == [
                "Engine", "Transmission", "Gateway", "Central electronics (BCM)", "Brakes (ABS)",
                "Airbag", "Steering assist", "Steering column electronics", "Instrument cluster",
                "Climate control", "All-wheel drive", "Adaptive cruise control", "Driver door",
                "Passenger door", "Parking assist", "Information electronics",
                "Access and start (Kessy)", "Rear-view camera", "Front driver-assistance sensors",
            ])
        #expect(proposed.filter(\.confirmed).count == proposed.count)
        #expect(
            SurveyReview(report: report).rows.map(\.caption)
                == ownNames.map { "Calls itself \($0)" })

        let coded = report.modules.filter { !Self.records($0).isEmpty }
        #expect(coded.map(\.candidate.target.request) == [0x70E, 0x746, 0x757, 0x74A, 0x773])
        #expect(
            coded.map(Self.records) == [
                [ModuleDTCRecord(code: "086614", status: 0x09)],
                [ModuleDTCRecord(code: "040501", status: 0x08)],
                [ModuleDTCRecord(code: "0004D4", status: 0x08)],
                [ModuleDTCRecord(code: "010003", status: 0x09)],
                [ModuleDTCRecord(code: "000014", status: 0x09)],
            ])
    }

    @Test("vehicle information right after the Tiguan's survey reset the adapter and read the VIN")
    func tiguanVehicleInfoAfterSurvey() throws {
        #expect(try Self.sent("tiguan-app-survey").last { $0.hasPrefix("ATCRA") } == "ATCRA 7EF")
        #expect(try Self.sent("tiguan-app-vehicle-info-after-survey").first == "ATZ")
        let ecus = try Self.vehicleInfo("tiguan-app-vehicle-info-after-survey")
        #expect(ecus.map(\.ecu) == [0x7E8, 0x7E9])
        #expect(ecus.first { $0.ecu == 0x7E8 }?.vin.value == Self.tiguanVIN)
    }

    @Test("the CX-5 with only part of the car on: the transmission answered, the engine didn't")
    func cx5PartlyOn() throws {
        let report = try Self.survey("cx5-app-ble-survey")
        // Spia knows no Mazda modules, so the survey asked the eight legislated addresses only.
        #expect(report.plan.platform == nil)
        #expect(report.plan.candidates.map(\.target.request) == Array(0x7E0...0x7E7))
        #expect(report.modules.map(\.candidate.target.request) == [0x7E1])
        #expect(report.unanswered.map(\.target.request) == [0x7E0] + Array(0x7E2...0x7E7))
        // Only the transmission answered the opening requests, and nothing gave a VIN: the
        // engine computer, which every car has, wasn't on.
        #expect(report.vehicleInfo.map(\.ecu) == [0x7E9])
        #expect(report.vehicleInfo.compactMap(\.vin.value).isEmpty)
        let transmission = try Self.module(0x7E1, in: report)
        let refusals = transmission.identification.filter { $0.result == .refused(0x31) }
        #expect(refusals.count == SurveyPlan.defaultIdentification.count)
        #expect(transmission.codes == .outcome(.records(availability: 0xFF, [])))

        let before = try Self.vehicleInfo("cx5-app-ble-vehicle-info-before-ignition")
        #expect(before.map(\.ecu) == [0x7E9])
        #expect(before.compactMap(\.vin.value).isEmpty)

        // With the ignition fully on, both answered: no codes, the check-engine light off, and
        // every readiness monitor complete.
        guard case .genericScan(let scans) = try Self.saved("cx5-app-ble-scan").payload else {
            Issue.record("the saved result isn't a scan")
            return
        }
        #expect(scans.map(\.ecu) == [0x7E8, 0x7E9])
        for scan in scans {
            #expect(scan.stored == .value([]))
            #expect(scan.pending == .value([]))
            #expect(scan.permanent == .value([]))
            #expect(scan.readiness.value?.milOn == false)
            let incomplete = scan.readiness.value?.monitors.filter { !$0.complete }
            #expect(incomplete == [])
        }
        #expect(scans.first?.readiness.value?.monitors.count == 8)
        let after = try Self.vehicleInfo("cx5-app-ble-vehicle-info-after-ignition")
        #expect(after.map(\.ecu) == [0x7E8, 0x7E9])
        #expect(after.first { $0.ecu == 0x7E8 }?.vin.value == Self.cx5VIN)
    }

    @Test("the CX-5 vehicle information asks for full ignition after a partial answer")
    func cx5VehicleInfoBeforeIgnition() async throws {
        let name = "cx5-app-ble-vehicle-info-before-ignition"
        let transport = try ReplayTransport(contentsOf: Self.fixture("\(name).txt"))
        let connection = ConnectionManager(
            adapter: AdapterDescriptor(kind: .bluetooth, displayName: "vLinker FS")
        ) { transport }
        try await connection.connect()
        let runner = JobRunner(connection: connection)
        var prompts: [UserAction] = []
        var failure: JobFailure?
        for await event in await runner.run(.vehicleInfo) {
            switch event {
            case .needsUser(let id, let action):
                prompts.append(action)
                await runner.confirm(id)
            case .failed(let value): failure = value
            default: break
            }
        }
        #expect(prompts == [.turnIgnitionOnForVIN])
        #expect(
            failure?.message == "replay: expected write \"<end of transcript>\", got \"0900\r\"")
        #expect(try Self.sent(name).last == "090A")
        #expect(await transport.isFinished)
    }

    @Test("the Ghibli's first search heard FCA's network management and found eight modules")
    func ghibliSearch() throws {
        let report = try Self.survey("ghibli-app-search")
        #expect(report.detectedProtocol == .can11bit500k)
        let search = try #require(report.search)
        // The listen heard the network management the ignition-on capture shows in the window,
        // few enough to sweep.
        #expect(
            search.heardIDs == [
                0x400, 0x401, 0x402, 0x403, 0x407, 0x409, 0x422, 0x423, 0x44A, 0x44C,
            ])
        #expect(search.engineRunning == false)
        #expect(search.stopReason == nil)
        #expect(search.sweptCount == 499)
        // Eight modules no list knew, every one replying at request - 0x280 as FCA's do, and every
        // one confirmed on its exact reply.
        #expect(
            search.confirmed.map(\.request) == [
                0x740, 0x742, 0x743, 0x749, 0x74B, 0x762, 0x764, 0x768,
            ])
        for target in search.confirmed { #expect(target.response == target.request - 0x280) }
        #expect(search.unconfirmed.isEmpty)

        let found = report.modules.filter {
            if case .discovered = $0.candidate.origin { return true }
            return false
        }
        #expect(found.map(\.candidate.target) == search.confirmed)
        #expect(report.modules.count == 14)
        // Each gave the car's VIN, so each is this car's.
        for module in found {
            let vin = module.identification.first { $0.did == 0xF190 }?.result
            #expect(vin == .value(Array(Self.ghibliVIN.utf8)))
        }
        func records(_ request: UInt32) throws -> [ModuleDTCRecord] {
            Self.records(try Self.module(request, in: report))
        }
        #expect(
            try records(0x740) == [
                ModuleDTCRecord(code: "A59B00", status: 0x4B),
                ModuleDTCRecord(code: "A59B01", status: 0x48),
                ModuleDTCRecord(code: "9A1100", status: 0x49),
            ])
        // The instrument cluster's U0001 and the tire pressure module's C0077.
        #expect(try records(0x742) == [ModuleDTCRecord(code: "C00100", status: 0x28)])
        #expect(try records(0x743) == [ModuleDTCRecord(code: "407700", status: 0x08)])
    }

    @Test("the Tiguan's search stopped at VW's 29-bit traffic in the reply window")
    func tiguanSearchBusy() throws {
        let report = try Self.survey("tiguan-app-search-busy")
        #expect(report.detectedProtocol == .can11bit500k)
        #expect(report.modules.count == 19)
        let search = try #require(report.search)
        #expect(
            search.stopReason
                == "The bus is busy where module replies would come, so Spia didn't search.")
        #expect(search.sweptCount == 0)
        // 29-bit frames from 17F00010: the 11-bit window let them through, so they count.
        #expect(search.heardIDs == [0x17F0_0010])
    }

    @Test("vehicle information after each search reset the adapter in place and read the VIN")
    func vehicleInfoAfterSearch() throws {
        for (name, vin) in [
            ("ghibli-app-vehicle-info-after-search", Self.ghibliVIN),
            ("tiguan-app-vehicle-info-after-search", Self.tiguanVIN),
        ] {
            #expect(try Self.sent(name).first == "ATZ")
            #expect(try Self.vehicleInfo(name).compactMap(\.vin.value).contains(vin))
        }
    }
}
