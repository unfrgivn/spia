import Foundation
import Testing

@testable import SpiaReference

private func fixture(_ name: String) throws -> Data {
    try Data(
        contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name))
}

@Suite("VIN")
struct VINTests {
    @Test("the Ghibli's VIN is valid and its check digit calculates")
    func ghibli() throws {
        let vin = try VIN("zam57rts4h1249941")
        #expect(vin.value == "ZAM57RTS4H1249941")
        #expect(vin.checkDigitMatches)
        #expect(!vin.isNorthAmerican)
        #expect(try VIN("1FTFW1ET5DFC10312").isNorthAmerican)
        #expect(VIN.checkDigit(for: "ZAM57RTS4H1249941") == "4")
    }

    @Test("spaces and dashes are ignored; a wrong check digit is reported, not rejected")
    func tolerance() throws {
        let vin = try VIN("ZAM57 RTS5-H1249941")
        #expect(vin.value == "ZAM57RTS5H1249941")
        #expect(!vin.checkDigitMatches)
    }

    @Test("check digit 10 is written X (49 CFR 565.15 example 1M8GDM9A_KP042788 → X)")
    func checkDigitX() {
        #expect(VIN.checkDigit(for: "1M8GDM9AXKP042788") == "X")
    }

    @Test("wrong length and the letters I, O, Q are rejected")
    func invalid() {
        #expect(throws: VIN.Problem.length(16)) { try VIN("ZAM57RTS4H124994") }
        #expect(throws: VIN.Problem.invalidCharacter("O")) { try VIN("ZAM57RTS4H12499O1") }
    }
}

@Suite("NHTSA and Wikimedia replies (recorded 2026-09-27)")
struct ReferenceParsingTests {
    @Test("vPIC decodes the Ghibli into make, model, year, and specification")
    func decode() throws {
        let identity = try VPIC.identity(from: fixture("nhtsa-vpic-ZAM57RTS4H1249941.json"))
        #expect(identity.vin == "ZAM57RTS4H1249941")
        #expect(identity.title == "2017 Maserati Ghibli")
        #expect(identity.detail == "Sport · M157 · 3.0 L V6 (M156B) · AWD")
        #expect(identity.bodyClass == "Sedan/Saloon")
        #expect(identity.transmission == "Automatic")
        #expect(identity.plantCountry == "ITALY")
        #expect(identity.decoderNotes.isEmpty)
        #expect(
            identity.summary
                == "2017 Maserati Ghibli, Sport, M157, Sedan/Saloon, 3.0 L V6 (M156B), Automatic, AWD, Gasoline, built in Italy"
        )
    }

    @Test("a VIN whose check digit fails still decodes, with the decoder's note kept")
    func decodeWithNote() throws {
        let identity = try VPIC.identity(from: fixture("nhtsa-vpic-bad-check-digit.json"))
        #expect(identity.title == "2017 Maserati Ghibli")
        #expect(identity.decoderNotes.first?.contains("Check Digit") == true)
    }

    @Test("makes read in title case, initialisms and hyphens kept")
    func makes() {
        #expect(VPIC.displayMake("MASERATI") == "Maserati")
        #expect(VPIC.displayMake("MERCEDES-BENZ") == "Mercedes-Benz")
        #expect(VPIC.displayMake("LAND ROVER") == "Land Rover")
        #expect(VPIC.displayMake("BMW") == "BMW")
    }

    @Test("byYmmt: variants and re-filings merge into 5 recalls, 21 complaints, 102 bulletins")
    func safety() throws {
        let record = try NHTSA.safety(from: fixture("nhtsa-byymmt-2017-maserati-ghibli.json"))
        #expect(
            record.recalls.map(\.id) == [
                "18V173000", "17V046000", "16V856000", "16V840000", "16V839000",
            ])
        #expect(record.complaints.count == 21)
        #expect(record.bulletins.count == 102)
        let newest = try #require(record.bulletins.first)
        #expect(newest.number == "MAS005184 MTB 26-10")
        #expect(
            newest.title == "Quattroporte / Ghibli / Levante V6 – Thermostat Gasket Availability")
        #expect(newest.detail.hasPrefix("This bulletin provides updated information"))
        #expect(newest.components == ["UNKNOWN OR OTHER", "ENGINE"])
        #expect(newest.documentCount == 1)
        let tires = try #require(record.recalls.first { $0.id == "16V840000" })
        #expect(tires.components == ["TIRES"])
        #expect(
            tires.remedy.hasPrefix(
                "Maserati will notify owners, and dealers will replace the affected tires, free of charge. The recall began"
            ))
        #expect(!record.complaints.contains { $0.description.contains("  ") })
    }

    @Test("capitals read as sentences, with I still a capital; mixed case is left alone")
    func sentenceCase() {
        #expect(NHTSA.sentenceCase("SERVICE BRAKES") == "Service brakes")
        #expect(
            NHTSA.sentenceCase("ON JULY 2017 I WENT IN. I'M TOLD IT'S FINE, AND I, TOO, AGREE")
                == "On july 2017 I went in. I'm told it's fine, and I, too, agree")
        #expect(
            NHTSA.sentenceCase("The contact owns a 2017 Maserati Ghibli.")
                == "The contact owns a 2017 Maserati Ghibli.")
    }

    @Test("a bulletin's documents are the PDFs on static.nhtsa.gov")
    func documents() throws {
        let documents = try NHTSA.bulletinDocuments(from: fixture("nhtsa-bulletin-11034165.json"))
        #expect(
            documents == [
                BulletinDocument(
                    fileName: "MC-11034165-0001.pdf",
                    url: URL(string: "https://static.nhtsa.gov/odi/tsbs/2026/MC-11034165-0001.pdf")!
                )
            ])
    }

    @Test("Commons: photos naming 2017 first, the 1971 Ghibli dropped, credit in plain text")
    func photos() throws {
        let photos = Commons.rank(
            [try Commons.candidates(from: fixture("commons-search-2017-maserati-ghibli.json"))],
            for: PhotoQuery(make: "Maserati", model: "Ghibli", year: 2017))
        #expect(photos.count == 11)
        #expect(photos.first?.caption == "2017 Maserati Ghibli (M157) Automatic 3.0 Front")
        #expect(photos.first?.credit == "Makizox · CC BY-SA 4.0")
        #expect(!photos.contains { $0.id.contains("1971") })
        #expect(photos.allSatisfy { $0.imageURL.host?.hasSuffix(".wikimedia.org") == true })
        #expect(photos.contains { $0.artist == "RL GNZLZ from Chile" })
    }

    @Test("years are found only when they stand alone in a file name")
    func years() {
        #expect(Commons.years(in: "Maserati Ghibli SS (1971).jpg") == [1971])
        #expect(Commons.years(in: "Maserati Ghibli S 2017 (35887002245).jpg") == [2017])
        #expect(Commons.years(in: "Bergrennen2017 Maserati").isEmpty)
    }
}

@Suite("Reference search")
struct ReferenceSearchTests {
    let safety: SafetyRecord

    init() throws {
        safety = try NHTSA.safety(from: fixture("nhtsa-byymmt-2017-maserati-ghibli.json"))
    }

    @Test("“steering wheel” finds the steering-wheel vibration bulletin first")
    func steering() {
        let results = ReferenceSearch.bulletins("steering wheel", in: safety.bulletins)
        #expect(results.first?.number == "MAS003095 MTB 24-21")
        #expect(results.contains { $0.number.hasPrefix("MAS004669") })
    }

    @Test("prefixes match whole words, and a bulletin number finds itself")
    func prefixAndNumber() {
        let bulletins = safety.bulletins
        #expect(ReferenceSearch.bulletins("thermostat", in: bulletins).first?.id == 11_034_165)
        #expect(ReferenceSearch.bulletins("MAS005184", in: bulletins).first?.id == 11_034_165)
        #expect(ReferenceSearch.bulletins("xyzzy", in: bulletins).isEmpty)
    }

    @Test("recalls are found by component, by campaign number, and by what could happen")
    func recalls() {
        #expect(ReferenceSearch.recalls("seat", in: safety.recalls).first?.id == "17V046000")
        #expect(ReferenceSearch.recalls("16V856000", in: safety.recalls).map(\.id) == ["16V856000"])
        #expect(ReferenceSearch.recalls("camera", in: safety.recalls).first?.id == "16V839000")
    }

    @Test("a complaint filed under a component outranks one that only mentions it")
    func complaints() {
        // Three are filed under brakes; three more only mention them, two of those newer.
        let filed = safety.complaints.filter { $0.components.contains("SERVICE BRAKES") }
        let results = ReferenceSearch.complaints("brake", in: safety.complaints)
        #expect(filed.count == 3)
        #expect(results.count == 6)
        #expect(Set(results.prefix(filed.count).map(\.id)) == Set(filed.map(\.id)))
    }

    @Test("a query narrows every kind of record; one with nothing to look for keeps them all")
    func matching() {
        #expect(safety.matching("  ") == safety)
        #expect(safety.matching("the") == safety)
        let seats = safety.matching("seat")
        #expect(seats.recalls.first?.id == "17V046000")
        #expect(seats.recalls.count < safety.recalls.count)
        #expect(seats.bulletins.count < safety.bulletins.count)
    }
}

@Suite("Reference snapshot")
struct ReferenceSnapshotTests {
    @Test("stale after a week or when the VIN changes")
    func staleness() {
        let fetched = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = ReferenceSnapshot(
            vin: "ZAM57RTS4H1249941", identity: nil, safety: nil, photos: [], fetchedAt: fetched,
            problems: [])
        #expect(
            !snapshot.isStale(now: fetched.addingTimeInterval(86_400), vin: "ZAM57RTS4H1249941"))
        #expect(
            snapshot.isStale(now: fetched.addingTimeInterval(8 * 86_400), vin: "ZAM57RTS4H1249941"))
        #expect(snapshot.isStale(now: fetched, vin: nil))
    }
}

@Suite("Requests")
struct RequestTests {
    @Test("request URLs match the ones the fixtures were recorded from")
    func urls() throws {
        #expect(
            try VPIC.decodeURL(vin: "ZAM57RTS4H1249941").absoluteString
                == "https://vpic.nhtsa.dot.gov/api/vehicles/DecodeVinValues/ZAM57RTS4H1249941?format=json"
        )
        #expect(
            try NHTSA.safetyURL(make: "Maserati", model: "Ghibli", year: 2017).absoluteString
                == "https://api.nhtsa.gov/vehicles/byYmmt?data=recalls,complaints,manufacturerCommunications&dataSet=recalls,complaints,manufacturerCommunications&make=MASERATI&max=100&model=GHIBLI&modelYear=2017&productDetail=all"
        )
        #expect(
            try NHTSA.bulletinDocumentsURL(id: 11_034_165).absoluteString
                == "https://api.nhtsa.gov/safetyIssues/byNhtsaId?filter=issueType&filterValue=manufacturerCommunications&nhtsaId=11034165"
        )
        let commons = try Commons.searchURL(query: "2017 Maserati Ghibli").absoluteString
        #expect(commons.contains("gsrsearch=2017%20Maserati%20Ghibli%20filetype:bitmap"))
        #expect(
            NHTSA.recallLookupURL(vin: "ZAM57RTS4H1249941")?.absoluteString
                == "https://www.nhtsa.gov/recalls?vin=ZAM57RTS4H1249941")
    }
}

/// Real requests to NHTSA and Wikimedia. Opt in with `SPIA_LIVE_REFERENCES=1`.
@Suite(
    "Live references", .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["SPIA_LIVE_REFERENCES"] == "1"))
struct LiveReferenceTests {
    let client = ReferenceClient()

    @Test("the Ghibli's VIN decodes, and its recalls, bulletins, and photos load")
    func ghibli() async throws {
        let identity = try await client.identity(for: try VIN("ZAM57RTS4H1249941"))
        #expect(identity.title == "2017 Maserati Ghibli")
        let safety = try await client.safety(for: identity)
        #expect(safety.recalls.count >= 5)
        #expect(safety.bulletins.count >= 90)
        let documents = try await client.documents(forBulletin: 11_034_165)
        #expect(documents.first?.url.pathExtension == "pdf")
        let photos = try await client.photos(
            matching: PhotoQuery(identity: identity, trim: "S Q4", color: .black, colorName: nil))
        #expect(photos.first?.caption.contains("S Q4") == true)
        let image = try await client.get(try #require(photos.first).imageURL)
        #expect(image.count > 10_000)
    }
}

@Suite("Bulletin summaries")
struct BulletinSummaryTests {
    @Test("a heading line becomes the title; hard-wrapped text is unwrapped to its first sentence")
    func titles() throws {
        let bulletins = try NHTSA.safety(from: fixture("nhtsa-byymmt-2017-maserati-ghibli.json"))
            .bulletins
        let exhaust = try #require(bulletins.first { $0.number == "MAS004816_A MTB 26-04" })
        #expect(
            exhaust.title
                == "This bulletin outlines the refinishing procedure for restoring the black coating on exhaust tips affected by peeling or flaking paint."
        )
        let steering = try #require(bulletins.first { $0.number == "MAS003095 MTB 24-21" })
        #expect(steering.title.hasSuffix("possible steering wheel vibration when braking."))
        #expect(steering.detail == "This Bulletin serves as an ADDENDUM to MAS002731")
        let wheels = try #require(bulletins.first { $0.number == "MAS004669 MTB 25-13" })
        #expect(wheels.title == "Wheel Size Vehicle Config Update Info")
        #expect(wheels.detail.hasPrefix("In case of rim replacement, which may involve"))
    }

    @Test("a bulletin filed three times appears once, as its newest filing")
    func refilings() throws {
        let bulletins = try NHTSA.safety(from: fixture("nhtsa-byymmt-2017-maserati-ghibli.json"))
            .bulletins
        let thermostat = bulletins.filter { $0.number == "MAS005184 MTB 26-10" }
        #expect(thermostat.map(\.id) == [11_034_165])
    }
}

@Suite("Photos for the trim and colour")
struct PhotoMatchTests {
    let sq4Blue = PhotoQuery(
        make: "Maserati", model: "Ghibli", year: 2017, series: "M157", trim: "S Q4", color: .blue)

    private func results(_ names: [String]) throws -> [[Commons.Candidate]] {
        try names.map { try Commons.candidates(from: fixture($0)) }
    }

    @Test("searches run from trim and colour down to the model year")
    func plan() {
        #expect(
            sq4Blue.searches == [
                #"Maserati Ghibli "S Q4" blue"#, #"Maserati Ghibli "S Q4""#,
                "2017 Maserati Ghibli blue", "2017 Maserati Ghibli",
            ])
        #expect(sq4Blue.summary == "2017 Maserati Ghibli S Q4 · Blue")
        var named = sq4Blue
        named.colorName = "Blu Emozione"
        #expect(named.searches.first == #"Maserati Ghibli "S Q4" "Blu Emozione""#)
        #expect(named.summary == "2017 Maserati Ghibli S Q4 · Blu Emozione")
        #expect(PhotoQuery(name: "My car").searches == ["My car"])
    }

    @Test("S Q4 photos come first; the blue 1966 Ghibli I and the Ghibli II are left out")
    func blue() throws {
        let photos = Commons.rank(
            try results((1...4).map { "commons-ghibli-sq4-blue-\($0).json" }), for: sq4Blue)
        #expect(photos.count == 12)
        #expect(photos.prefix(8).allSatisfy { $0.caption.contains("S Q4") })
        #expect(!photos.contains { $0.id.contains("Würgau") })
        #expect(!photos.contains { $0.id.contains("Cockpit") || $0.id.contains("1995") })
    }

    @Test("a black S Q4 ranks first when the car is black")
    func black() throws {
        var query = sq4Blue
        query.color = .black
        let photos = Commons.rank(
            try results([
                "commons-ghibli-sq4-black-1.json", "commons-ghibli-sq4-blue-2.json",
                "commons-ghibli-sq4-black-3.json", "commons-ghibli-sq4-blue-4.json",
            ]), for: query)
        #expect(photos.first?.id == "File:Maserati ABA-MG30AA Ghibli S Q4 (23112613075).jpg")
    }

    @Test("a category's model year beats the year the photo was taken")
    func categoryYear() throws {
        let photos = Commons.rank(
            try results(["commons-ghibli-sq4-blue-4.json"]),
            for: PhotoQuery(make: "Maserati", model: "Ghibli", year: 2017), limit: 30)
        #expect(photos.contains { $0.id == "File:Maserati Ghibli (L44 HMS) - 4 July 2026.jpg" })
        #expect(!photos.contains { $0.id == "File:1995 Maserati Ghibli (2).jpg" })
    }

    @Test("phrases match whole words, and S Q4 matches SQ4")
    func text() {
        let text = Commons.Text("Maserati Ghibli SQ4 GranLusso M157 Grigio Maratea")
        #expect(text.contains("S Q4"))
        #expect(text.contains("grigio"))
        #expect(!text.contains("Q4 S"))
        #expect(!Commons.Text("Maserati Ghiblis").contains("Ghibli"))
    }
}
