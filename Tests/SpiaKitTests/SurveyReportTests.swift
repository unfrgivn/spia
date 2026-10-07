import Foundation
import OBDCore
import SpiaKit
import Testing

@Suite("Survey reports")
struct SurveyReportTests {
    private func candidate() throws -> SurveyCandidate {
        SurveyCandidate(
            target: try ModuleTarget(bus: .highSpeed, request: 0x7E0, response: 0x7E8),
            origin: .legislated)
    }

    @Test("a legislated probe has one complete, deterministic command sequence")
    func plannedCommands() throws {
        let plan = SurveyPlan(
            catalogVersion: "test", vehicle: nil, platform: nil, candidates: [try candidate()],
            unreachable: [], identification: [0xF190, 0xF197])
        #expect(
            plan.plannedCommands == [
                "ATRV", "0900", "0902", "0904", "0906", "090A",
                "ATSP6", "ATST 19", "ATCFC 1", "ATSH 7E0", "ATCRA 7E8",
                "ATFCSD 30 00 00", "ATFCSH 7E0", "ATFCSM 1", "3E00", "ATST 64",
                "22F190", "22F197", "190209",
            ])
    }

    @Test("survey reports round-trip through Codable")
    func coding() throws {
        let plan = SurveyPlan(
            catalogVersion: "test", vehicle: nil, platform: nil, candidates: [try candidate()],
            unreachable: [])
        let report = SurveyReport(
            plan: plan, voltage: 12.4, vehicleInfo: [],
            modules: [
                SurveyModule(
                    candidate: try candidate(), presence: .refused(0x11),
                    identification: [
                        SurveyIdentification(did: 0xF197, result: .value([0x45, 0x43, 0x4D]))
                    ],
                    codes: .outcome(.negative(service: 0x19, code: 0x22)))
            ],
            unanswered: [], notProbed: [], stop: nil)
        #expect(
            try JSONDecoder().decode(SurveyReport.self, from: JSONEncoder().encode(report))
                == report)
    }

    @Test("module naming uses module, OBD, catalog, then no name")
    func namingPrecedence() throws {
        var obdReport = ECUInfoReport(ecu: 0x7E8)
        obdReport.name = .positive("Engine")
        let obd = ECUIdentity(obdReport)
        let catalog = SurveyCandidate(
            target: try candidate().target,
            origin: .catalog(label: "Engine controller", provenance: .reference, source: "test"))
        let plan = SurveyPlan(
            catalogVersion: "test", vehicle: nil, platform: nil, candidates: [catalog],
            unreachable: [])
        func report(_ module: SurveyModule, vehicleInfo: [ECUIdentity] = [obd]) -> SurveyReport {
            SurveyReport(
                plan: plan, voltage: nil, vehicleInfo: vehicleInfo, modules: [module],
                unanswered: [], notProbed: [], stop: nil)
        }
        let module = SurveyModule(
            candidate: catalog, presence: .present,
            identification: [SurveyIdentification(did: 0xF197, result: .value(Array("ECM".utf8)))],
            codes: .noAnswer)
        #expect(report(module).ownName(of: module) == SurveyName(text: "ECM", source: .module))
        #expect(
            report(module).name(of: module)
                == SurveyName(text: "Engine controller", source: .catalog))

        let withoutModuleName = SurveyModule(
            candidate: catalog, presence: .present, identification: [], codes: .noAnswer)
        #expect(
            report(withoutModuleName).ownName(of: withoutModuleName)
                == SurveyName(text: "Engine", source: .obd))
        #expect(
            report(withoutModuleName, vehicleInfo: []).name(of: withoutModuleName)
                == SurveyName(text: "Engine controller", source: .catalog))
        let unknown = SurveyModule(
            candidate: try candidate(), presence: .present, identification: [], codes: .noAnswer)
        #expect(report(unknown, vehicleInfo: []).name(of: unknown) == nil)
    }

    @Test("proposed modules preserve plan order and confirmation sources")
    func proposedModules() throws {
        let targets = try [
            ModuleTarget(bus: .highSpeed, request: 0x700, response: 0x708),
            ModuleTarget(bus: .highSpeed, request: 0x701, response: 0x709),
            ModuleTarget(bus: .highSpeed, request: 0x702, response: 0x70A),
            ModuleTarget(bus: .highSpeed, request: 0x703, response: 0x70B),
            ModuleTarget(bus: .highSpeed, request: 0x704, response: 0x70C),
            ModuleTarget(bus: .highSpeed, request: 0x705, response: 0x70D),
        ]
        let candidates = [
            SurveyCandidate(
                target: targets[0],
                origin: .catalog(label: "First reference", provenance: .reference, source: "test")),
            SurveyCandidate(
                target: targets[1],
                origin: .catalog(label: "Second reference", provenance: .reference, source: "test")),
            SurveyCandidate(
                target: targets[2],
                origin: .catalog(label: "Third reference", provenance: .reference, source: "test")),
            SurveyCandidate(target: targets[3], origin: .legislated),
            SurveyCandidate(target: targets[4], origin: .legislated),
            SurveyCandidate(target: targets[5], origin: .legislated),
        ]
        var engine = ECUInfoReport(ecu: targets[1].response)
        engine.name = .positive("OBD engine")
        var other = ECUInfoReport(ecu: targets[5].response)
        other.name = .positive("OBD other")
        let modules = [
            SurveyModule(
                candidate: candidates[0], presence: .present,
                identification: [
                    SurveyIdentification(did: 0xF197, result: .value(Array("Own module".utf8)))
                ], codes: .noAnswer),
            SurveyModule(
                candidate: candidates[1], presence: .present, identification: [], codes: .noAnswer),
            SurveyModule(
                candidate: candidates[2], presence: .present, identification: [], codes: .noAnswer),
            SurveyModule(
                candidate: candidates[3], presence: .present, identification: [], codes: .noAnswer),
            SurveyModule(
                candidate: candidates[4], presence: .present,
                identification: [
                    SurveyIdentification(did: 0xF197, result: .value(Array("Own module".utf8)))
                ], codes: .noAnswer),
            SurveyModule(
                candidate: candidates[5], presence: .present, identification: [], codes: .noAnswer),
        ]
        let plan = SurveyPlan(
            catalogVersion: "test", vehicle: nil, platform: nil, candidates: candidates,
            unreachable: [])
        let report = SurveyReport(
            plan: plan, voltage: nil, vehicleInfo: [ECUIdentity(engine), ECUIdentity(other)],
            modules: modules,
            unanswered: [], notProbed: [], stop: nil)
        #expect(
            report.proposedModules()
                == [
                    ModuleChoice(target: targets[0], label: "First reference", confirmed: true),
                    ModuleChoice(target: targets[1], label: "Second reference", confirmed: true),
                    ModuleChoice(target: targets[2], label: "Third reference", confirmed: false),
                    ModuleChoice(target: targets[3], label: "Module 703", confirmed: false),
                    ModuleChoice(target: targets[4], label: "Own module", confirmed: true),
                    ModuleChoice(target: targets[5], label: "OBD other", confirmed: true),
                ])
    }

    @Test("survey result text reports modules, codes, unanswered, and stops")
    func resultText() throws {
        let plan = SurveyPlan(
            catalogVersion: "test", vehicle: nil, platform: nil, candidates: [try candidate()],
            unreachable: [])
        let module = SurveyModule(
            candidate: try candidate(), presence: .present, identification: [],
            codes: .outcome(.negative(service: 0x19, code: 0x22)))
        let report = SurveyReport(
            plan: plan, voltage: nil, vehicleInfo: [], modules: [module],
            unanswered: [try candidate()],
            notProbed: [], stop: SurveyStop(candidate: try candidate(), reason: "CAN ERROR"))
        let result = JobResult(
            job: .survey(plan), payload: .survey(report), source: .live, transcript: nil)
        #expect(
            ResultText.summary(result)
                == "The engine computers didn't answer. Found 1 module, 1 with codes. 1 didn't answer. Stopped at Module 7E0 (7E0): CAN ERROR."
        )
    }

    @Test("survey result text says plainly when the thorough search did not run")
    func skippedSearchResultText() throws {
        let plan = SurveyPlan(
            catalogVersion: "test", vehicle: nil, platform: nil, candidates: [try candidate()],
            unreachable: [])
        let search = SearchOutcome(
            heardIDs: [], sweptCount: 0, confirmed: [], unconfirmed: [], engineRunning: false,
            stopReason: "The bus is busy where module replies would come, so Spia didn't search.")
        let report = SurveyReport(
            plan: plan, voltage: nil, vehicleInfo: [], modules: [], unanswered: [], notProbed: [],
            stop: nil, search: search)
        let result = JobResult(
            job: .survey(plan), payload: .survey(report), source: .live, transcript: nil)
        #expect(
            ResultText.summary(result)
                == "The engine computers didn't answer. No modules answered. The search didn't run: The bus is busy where module replies would come, so Spia didn't search.")
    }

    @Test("a TesterPresent answer, a refusal, or a busy reply is a module; anything else isn't")
    func presenceFromReply() {
        #expect(SurveyPresence(TesterPresentReply(payload: [0x7E, 0x00])) == .present)
        #expect(SurveyPresence(TesterPresentReply(payload: [0x7F, 0x3E, 0x11])) == .refused(0x11))
        #expect(SurveyPresence(TesterPresentReply(payload: [0x7F, 0x3E, 0x78])) == .pending)
        #expect(SurveyPresence(TesterPresentReply(payload: [0x7E, 0x80])) == nil)
        #expect(SurveyPresence(TesterPresentReply(payload: [0x7F, 0x22, 0x11])) == nil)
    }
}
