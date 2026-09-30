import OBDCore
import SpiaKit
import Testing

/// The review sheet's wording and the modules it saves, on reports shaped the way a survey
/// builds them.
@Suite("Survey review")
struct SurveyReviewTests {
    private static let ghibli = CatalogVehicle(make: "Maserati", model: "Ghibli", year: 2017)

    private static func target(_ request: UInt32, _ reply: UInt32) throws -> ModuleTarget {
        try ModuleTarget(bus: .highSpeed, request: request, response: reply)
    }

    private static func known(_ label: String, _ target: ModuleTarget) -> SurveyCandidate {
        SurveyCandidate(
            target: target, origin: .catalog(label: label, provenance: .observed, source: "test"))
    }

    private static func module(
        _ candidate: SurveyCandidate,
        codes: SurveyCodes = .outcome(.records(availability: 0xFF, [])),
        identification: [SurveyIdentification] = []
    ) -> SurveyModule {
        SurveyModule(
            candidate: candidate, presence: .present, identification: identification, codes: codes)
    }

    private static func report(
        vehicle: CatalogVehicle? = ghibli, platform: String? = "M157",
        vehicleInfo: [ECUIdentity] = [], modules: [SurveyModule] = [],
        unanswered: [SurveyCandidate] = [], notProbed: [SurveyCandidate] = [],
        stop: SurveyStop? = nil, unreachable: [SurveyCandidate] = []
    ) -> SurveyReport {
        let candidates =
            modules.map(\.candidate) + unanswered + (stop.map { [$0.candidate] } ?? []) + notProbed
        return SurveyReport(
            plan: SurveyPlan(
                catalogVersion: "test", vehicle: vehicle, platform: platform,
                candidates: candidates, unreachable: unreachable),
            voltage: nil, vehicleInfo: vehicleInfo, modules: modules, unanswered: unanswered,
            notProbed: notProbed, stop: stop)
    }

    private static func ecu(_ id: UInt32, named name: String) -> ECUIdentity {
        var report = ECUInfoReport(ecu: id)
        report.name = .positive(name)
        return ECUIdentity(report)
    }

    @Test("the headline counts what answered")
    func headline() throws {
        let airbag = Self.known("Airbag controller (ORC)", try Self.target(0x744, 0x4C4))
        let abs = Self.known("ABS", try Self.target(0x747, 0x4C7))
        #expect(SurveyReview(report: Self.report()).headline == "No modules answered")
        #expect(
            SurveyReview(report: Self.report(modules: [Self.module(airbag)])).headline
                == "Found 1 module")
        #expect(
            SurveyReview(report: Self.report(modules: [Self.module(airbag), Self.module(abs)]))
                .headline == "Found 2 modules")
    }

    @Test("notes say what limited the survey, and only when it did")
    func notes() throws {
        let engine = Self.ecu(0x7E8, named: "ECM1-EngineControl1")
        #expect(SurveyReview(report: Self.report(vehicleInfo: [engine])).notes.isEmpty)
        #expect(
            SurveyReview(report: Self.report()).notes == ["The engine computers didn't answer."])
        #expect(
            SurveyReview(report: Self.report(vehicle: nil, platform: nil, vehicleInfo: [engine]))
                .notes == [
                    "Spia doesn't know this car's make yet. Add its VIN, then survey again to include the modules known for it."
                ])
        #expect(
            SurveyReview(
                report: Self.report(
                    vehicle: CatalogVehicle(make: "Volkswagen", model: "Passat", year: 2016),
                    platform: nil, vehicleInfo: [engine])
            ).notes == [
                "Spia has no module list for a 2016 Volkswagen Passat yet, so it asked the standard engine addresses only."
            ])

        let airbag = Self.known("Airbag controller (ORC)", try Self.target(0x744, 0x4C4))
        let later = [
            SurveyCandidate(target: try Self.target(0x7E2, 0x7EA), origin: .legislated),
            SurveyCandidate(target: try Self.target(0x7E3, 0x7EB), origin: .legislated),
        ]
        #expect(
            SurveyReview(
                report: Self.report(
                    vehicleInfo: [engine], notProbed: later,
                    stop: SurveyStop(candidate: airbag, reason: "adapter reported: CAN bus error"))
            ).notes == [
                "Stopped at Airbag controller (ORC) (744): adapter reported: CAN bus error. 2 not asked."
            ])

        let interior = SurveyCandidate(
            target: try ModuleTarget(bus: .mediumSpeed, request: 0x620, response: 0x504),
            origin: .catalog(label: "Interior", provenance: .reference, source: "test"))
        #expect(
            SurveyReview(report: Self.report(vehicleInfo: [engine], unreachable: [interior])).notes
                == ["1 known module is on the 125k bus, which this adapter can't reach."])
        #expect(
            SurveyReview(
                report: Self.report(vehicleInfo: [engine], unreachable: [interior, interior])
            ).notes == ["2 known modules are on the 125k bus, which this adapter can't reach."])
    }

    @Test("each row says where its name came from and what the module reported")
    func rows() throws {
        let named = Self.module(
            Self.known("Airbag controller (ORC)", try Self.target(0x744, 0x4C4)),
            codes: .outcome(
                .records(
                    availability: 0xCF,
                    [
                        ModuleDTCRecord(code: "80011B", status: 0x8F),
                        ModuleDTCRecord(code: "80021B", status: 0x8F),
                    ])),
            identification: [
                SurveyIdentification(did: 0xF197, result: .value(Array("SRS ORC".utf8)))
            ])
        let transmission = Self.module(
            Self.known("Transmission", try Self.target(0x7E1, 0x7E9)),
            codes: .outcome(
                .records(availability: 0xFF, [ModuleDTCRecord(code: "070000", status: 0x08)])))
        let abs = Self.module(Self.known("ABS", try Self.target(0x747, 0x4C7)))
        let unnamed = Self.module(
            SurveyCandidate(target: try Self.target(0x7E2, 0x7EA), origin: .legislated),
            codes: .outcome(.negative(service: 0x19, code: 0x22)))
        let silent = Self.module(
            Self.known("Body computer (BCM)", try Self.target(0x620, 0x504)), codes: .noAnswer)
        let garbled = Self.module(
            Self.known("Steering column (SCCM)", try Self.target(0x763, 0x4E3)),
            codes: .unreadable("bad response"))
        let review = SurveyReview(
            report: Self.report(
                vehicleInfo: [Self.ecu(0x7E9, named: "TCM\0-TransmisCtrl")],
                modules: [named, transmission, abs, unnamed, silent, garbled]))

        #expect(
            review.rows.map(\.proposedName) == [
                "SRS ORC", "TCM-TransmisCtrl", "ABS", "Module 7E2", "Body computer (BCM)",
                "Steering column (SCCM)",
            ])
        #expect(
            review.rows.map(\.nameSource.caption) == [
                "Named itself", "Named itself", "From references, unconfirmed", "No name found",
                "From references, unconfirmed", "From references, unconfirmed",
            ])
        #expect(review.rows.map(\.confirmed) == [true, true, false, false, false, false])
        #expect(
            review.rows.map(\.codesSummary) == [
                "2 codes", "1 code", "No codes", "Didn't give its codes",
                "Didn't answer the code request", "Couldn't read its codes",
            ])
    }

    @Test("modules that didn't answer are listed by their names or addresses")
    func unanswered() throws {
        let review = SurveyReview(
            report: Self.report(unanswered: [
                Self.known("Steering column (SCCM)", try Self.target(0x763, 0x4E3)),
                SurveyCandidate(target: try Self.target(0x7E3, 0x7EB), origin: .legislated),
            ]))
        #expect(review.unansweredLabels == ["Steering column (SCCM)", "Module 7E3"])
    }

    @Test("saving keeps the checked rows; a name the owner changed is confirmed as theirs")
    func choices() throws {
        let airbag = try Self.target(0x744, 0x4C4)
        let abs = try Self.target(0x747, 0x4C7)
        let engine = try Self.target(0x7E0, 0x7E8)
        let unnamed = try Self.target(0x7E2, 0x7EA)
        let review = SurveyReview(
            report: Self.report(
                vehicleInfo: [Self.ecu(0x7E8, named: "ECM1-EngineControl1")],
                modules: [
                    Self.module(Self.known("Airbag controller (ORC)", airbag)),
                    Self.module(Self.known("ABS", abs)),
                    Self.module(Self.known("Engine", engine)),
                    Self.module(SurveyCandidate(target: unnamed, origin: .legislated)),
                ]))
        let all: Set = [airbag, abs, engine, unnamed]

        // Untouched: the proposals, with their own confirmation.
        #expect(
            review.choices(names: [:], kept: all) == [
                ModuleChoice(target: airbag, label: "Airbag controller (ORC)", confirmed: false),
                ModuleChoice(target: abs, label: "ABS", confirmed: false),
                ModuleChoice(target: engine, label: "ECM1-EngineControl1", confirmed: true),
                ModuleChoice(target: unnamed, label: "Module 7E2", confirmed: false),
            ])
        // Edited, trimmed; blank and space-only edits fall back; typing the proposal back keeps
        // its confirmation; unchecked rows aren't saved.
        #expect(
            review.choices(
                names: [
                    airbag: "  Driver airbag module ", abs: "   ", engine: "",
                    unnamed: "Module 7E2",
                ],
                kept: [airbag, abs, engine, unnamed]
            ) == [
                ModuleChoice(target: airbag, label: "Driver airbag module", confirmed: true),
                ModuleChoice(target: abs, label: "ABS", confirmed: false),
                ModuleChoice(target: engine, label: "ECM1-EngineControl1", confirmed: true),
                ModuleChoice(target: unnamed, label: "Module 7E2", confirmed: false),
            ])
        #expect(
            review.choices(names: [:], kept: [abs]) == [
                ModuleChoice(target: abs, label: "ABS", confirmed: false)
            ])
        #expect(review.choices(names: [:], kept: []).isEmpty)
    }
}
