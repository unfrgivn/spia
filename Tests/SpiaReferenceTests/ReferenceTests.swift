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

    @Test("byYmmt: AWD and RWD variants merge into 5 recalls, 21 complaints, 110 bulletins")
    func safety() throws {
        let record = try NHTSA.safety(from: fixture("nhtsa-byymmt-2017-maserati-ghibli.json"))
        #expect(
            record.recalls.map(\.id) == [
                "18V173000", "17V046000", "16V856000", "16V840000", "16V839000",
            ])
        #expect(record.complaints.count == 21)
        #expect(record.bulletins.count == 110)
        let newest = try #require(record.bulletins.first)
        #expect(newest.number == "MAS005184 MTB 26-10")
        #expect(
            newest.title == "Quattroporte / Ghibli / Levante V6 – Thermostat Gasket Availability")
        #expect(newest.detail.hasPrefix("This bulletin provides updated information"))
        #expect(newest.components == ["UNKNOWN OR OTHER", "ENGINE"])
        #expect(newest.documentCount == 1)
        let tires = try #require(record.recalls.first { $0.id == "16V840000" })
        #expect(tires.components == ["TIRES"])
        #expect(!tires.remedy.isEmpty)
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
        let photos = try Commons.photos(
            from: fixture("commons-search-2017-maserati-ghibli.json"), modelYear: 2017)
        #expect(photos.count == 8)
        #expect(photos.first?.caption == "2017 Maserati Ghibli (M157) Automatic 3.0 Front")
        #expect(photos.first?.credit == "Makizox · CC BY-SA 4.0")
        #expect(photos.last?.id == "File:Würgau Bergrennen2017 Maserati Ghibli 0155-PSD-2.jpg")
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

@Suite("Bulletin search")
struct BulletinSearchTests {
    let bulletins: [Bulletin]

    init() throws {
        bulletins = try NHTSA.safety(from: fixture("nhtsa-byymmt-2017-maserati-ghibli.json"))
            .bulletins
    }

    @Test("“steering wheel” finds the steering-wheel vibration bulletin first")
    func steering() throws {
        let results = BulletinSearch.search("steering wheel", in: bulletins)
        #expect(results.first?.number == "MAS003095 MTB 24-21")
        #expect(results.contains { $0.number.hasPrefix("MAS004669") })
    }

    @Test("prefixes match whole words, and a bulletin number finds itself")
    func prefixAndNumber() {
        #expect(BulletinSearch.search("thermostat", in: bulletins).first?.id == 11_034_165)
        #expect(BulletinSearch.search("MAS005184", in: bulletins).first?.id == 11_034_165)
        #expect(BulletinSearch.search("xyzzy", in: bulletins).isEmpty)
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
        #expect(safety.bulletins.count >= 100)
        let documents = try await client.documents(forBulletin: 11_034_165)
        #expect(documents.first?.url.pathExtension == "pdf")
        let photos = try await client.photos(for: identity)
        #expect(!photos.isEmpty)
        let image = try await client.get(try #require(photos.first).imageURL)
        #expect(image.count > 10_000)
    }
}
