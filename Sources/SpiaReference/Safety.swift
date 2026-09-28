import Foundation

/// A safety recall filed with NHTSA for the car's make, model, and year. Whether this car
/// was repaired can only be checked by VIN on nhtsa.gov.
public struct Recall: Codable, Sendable, Equatable, Identifiable {
    /// NHTSA campaign number, e.g. `16V840000`.
    public let id: String
    public let manufacturerCampaign: String?
    public let reportDate: Date?
    public let components: [String]
    public let summary: String
    public let consequence: String
    public let remedy: String
    /// NHTSA advises not driving the car until it's repaired.
    public let parkIt: Bool
    /// NHTSA advises parking outside because of fire risk.
    public let parkOutside: Bool
}

/// An owner's report to NHTSA about a car of this make, model, and year.
public struct Complaint: Codable, Sendable, Equatable, Identifiable {
    public let id: Int
    public let dateFiled: Date?
    public let incidentDate: Date?
    public let components: [String]
    public let description: String
    public let crash: Bool
    public let fire: Bool
    public let injuries: Int
}

/// A manufacturer communication (service bulletin, diagnostic sheet, campaign) that the maker
/// filed with NHTSA for this make, model, and year. Filings are often broad: a bulletin may
/// cover other models or conditions this car doesn't have.
public struct Bulletin: Codable, Sendable, Equatable, Identifiable {
    /// NHTSA ID of the newest filing, used to fetch the documents.
    public let id: Int
    /// The maker's number, e.g. `MAS005184 MTB 26-10`.
    public let number: String
    public let date: Date?
    /// The summary's heading, or its first sentence.
    public let title: String
    /// The rest of the summary, often empty.
    public let detail: String
    public let components: [String]
    public let documentCount: Int
}

/// One file attached to a bulletin, usually the bulletin itself as a PDF.
public struct BulletinDocument: Codable, Sendable, Equatable {
    public let fileName: String
    public let url: URL
}

public struct SafetyRecord: Codable, Sendable, Equatable {
    public var recalls: [Recall]
    public var complaints: [Complaint]
    public var bulletins: [Bulletin]

    public init(recalls: [Recall], complaints: [Complaint], bulletins: [Bulletin]) {
        self.recalls = recalls
        self.complaints = complaints
        self.bulletins = bulletins
    }

    /// Complaint counts by component, largest first, for a quick picture of common faults.
    public var complaintsByComponent: [(component: String, count: Int)] {
        var counts: [String: Int] = [:]
        for complaint in complaints {
            for component in complaint.components { counts[component, default: 0] += 1 }
        }
        return counts.map { ($0.key, $0.value) }.sorted {
            $0.count == $1.count ? $0.component < $1.component : $0.count > $1.count
        }
    }
}

/// NHTSA's public safety API. No key.
public enum NHTSA {
    /// Recalls, complaints, and manufacturer communications for a make, model, and year, in one
    /// request. The same endpoint backs the vehicle pages on nhtsa.gov.
    public static func safetyURL(make: String, model: String, year: Int) throws -> URL {
        let sets = "recalls,complaints,manufacturerCommunications"
        return try https(
            "api.nhtsa.gov", "/vehicles/byYmmt",
            [
                ("data", sets), ("dataSet", sets), ("make", make.uppercased()), ("max", "100"),
                ("model", model.uppercased()), ("modelYear", String(year)),
                ("productDetail", "all"),
            ])
    }

    public static func bulletinDocumentsURL(id: Int) throws -> URL {
        try https(
            "api.nhtsa.gov", "/safetyIssues/byNhtsaId",
            [
                ("filter", "issueType"), ("filterValue", "manufacturerCommunications"),
                ("nhtsaId", String(id)),
            ])
    }

    /// The nhtsa.gov page that shows open recalls for one car.
    public static func recallLookupURL(vin: String) -> URL? {
        try? https("www.nhtsa.gov", "/recalls", [("vin", vin)])
    }

    /// Reads a `byYmmt` reply. NHTSA lists each variant (e.g. AWD and RWD) separately with
    /// mostly the same records, so records are merged by ID; a bulletin filed more than once
    /// under the same number keeps only its newest filing.
    public static func safety(from data: Data) throws -> SafetyRecord {
        guard let reply = try? JSONDecoder().decode(YMMTReply.self, from: data) else {
            throw ReferenceError.malformed("NHTSA")
        }
        var recalls: [String: Recall] = [:]
        var complaints: [Int: Complaint] = [:]
        var bulletins: [Int: Bulletin] = [:]
        for variant in reply.results {
            for raw in variant.safetyIssues.recalls ?? [] {
                let recall = raw.recall
                recalls[recall.id] = recalls[recall.id] ?? recall
            }
            for raw in variant.safetyIssues.complaints ?? [] {
                let complaint = raw.complaint
                complaints[complaint.id] = complaints[complaint.id] ?? complaint
            }
            for raw in variant.safetyIssues.manufacturerCommunications ?? [] {
                let bulletin = raw.bulletin
                bulletins[bulletin.id] = bulletins[bulletin.id] ?? bulletin
            }
        }
        var newestByNumber: [String: Bulletin] = [:]
        for bulletin in bulletins.values {
            if let kept = newestByNumber[bulletin.number],
                newestFirst(\Bulletin.date, \Bulletin.id)(kept, bulletin)
            {
                continue
            }
            newestByNumber[bulletin.number] = bulletin
        }
        return SafetyRecord(
            recalls: recalls.values.sorted(by: newestFirst(\.reportDate, \.id)),
            complaints: complaints.values.sorted(by: newestFirst(\.dateFiled, \.id)),
            bulletins: newestByNumber.values.sorted(by: newestFirst(\.date, \.id)))
    }

    public static func bulletinDocuments(from data: Data) throws -> [BulletinDocument] {
        struct Reply: Decodable {
            struct Result: Decodable { let manufacturerCommunications: [Communication]? }
            struct Communication: Decodable { let associatedDocuments: Documents? }
            let results: [Result]
        }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else {
            throw ReferenceError.malformed("NHTSA")
        }
        return reply.results.flatMap { $0.manufacturerCommunications ?? [] }.flatMap {
            $0.associatedDocuments?.documents ?? []
        }.compactMap { document in
            guard let url = URL(string: document.url), url.scheme == "https" else { return nil }
            return BulletinDocument(fileName: document.fileName, url: url)
        }
    }

    private static func newestFirst<Record, ID: Comparable>(
        _ date: KeyPath<Record, Date?>, _ id: KeyPath<Record, ID>
    ) -> (Record, Record) -> Bool {
        { lhs, rhs in
            let left = lhs[keyPath: date] ?? .distantPast
            let right = rhs[keyPath: date] ?? .distantPast
            return left == right ? lhs[keyPath: id] < rhs[keyPath: id] : left > right
        }
    }

    static func date(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        return try? Date(raw, strategy: .iso8601)
    }

    /// NHTSA writes components, and some complaints, in capitals, which read more easily in
    /// sentence case. Names can't be told from other words, but "I" can. Text that isn't all
    /// capitals is left as it is.
    public static func sentenceCase(_ text: String) -> String {
        guard text == text.uppercased() else { return text }
        var result = ""
        var startOfSentence = true
        for character in text.lowercased() {
            if startOfSentence, character.isLetter {
                result.append(contentsOf: character.uppercased())
                startOfSentence = false
            } else {
                result.append(character)
            }
            if ".!?".contains(character) { startOfSentence = true }
        }
        return result.split(separator: " ", omittingEmptySubsequences: false).map { word in
            // "i", "i," and "i'm", but not "it".
            word.first == "i" && !(word.dropFirst().first?.isLetter ?? false)
                ? "I" + word.dropFirst() : String(word)
        }.joined(separator: " ")
    }

    /// NHTSA's prose has two spaces after a full stop, and sometimes more; one reads better.
    static func prose(_ raw: String?) -> String {
        (raw ?? "").split(separator: " ").joined(separator: " ")
    }
}

// MARK: - Reply shapes

private struct YMMTReply: Decodable {
    struct Variant: Decodable { let safetyIssues: Issues }
    struct Issues: Decodable {
        let recalls: [RawRecall]?
        let complaints: [RawComplaint]?
        let manufacturerCommunications: [RawCommunication]?
    }
    let results: [Variant]
}

private struct RawComponent: Decodable { let name: String }

private struct RawRecall: Decodable {
    let nhtsaCampaignNumber: String
    let mfrCampaignNumber: String?
    let reportReceivedDate: String?
    let components: [RawComponent]?
    let summary: String?
    let consequence: String?
    let correctiveAction: String?
    let parkIt: Bool?
    let parkOutSide: Bool?

    var recall: Recall {
        Recall(
            id: nhtsaCampaignNumber, manufacturerCampaign: mfrCampaignNumber,
            reportDate: NHTSA.date(reportReceivedDate), components: components?.map(\.name) ?? [],
            summary: NHTSA.prose(summary), consequence: NHTSA.prose(consequence),
            remedy: NHTSA.prose(correctiveAction),
            parkIt: parkIt ?? false, parkOutside: parkOutSide ?? false)
    }
}

private struct RawComplaint: Decodable {
    let nhtsaIdNumber: Int
    let dateFiled: String?
    let dateOfIncident: String?
    let components: [RawComponent]?
    let description: String?
    let crash: Bool?
    let fire: Bool?
    let numberOfInjuries: Int?

    var complaint: Complaint {
        Complaint(
            id: nhtsaIdNumber, dateFiled: NHTSA.date(dateFiled),
            incidentDate: NHTSA.date(dateOfIncident), components: components?.map(\.name) ?? [],
            description: NHTSA.prose(description), crash: crash ?? false, fire: fire ?? false,
            injuries: numberOfInjuries ?? 0)
    }
}

private struct RawCommunication: Decodable {
    let nhtsaIdNumber: Int
    let manufacturerCommunicationNumber: String?
    let summary: String?
    let communicationDate: String?
    let components: [RawComponent]?
    let associatedDocumentsCount: Int?

    var bulletin: Bulletin {
        let number = manufacturerCommunicationNumber ?? "NHTSA \(nhtsaIdNumber)"
        let (title, detail) = Self.split(summary ?? "")
        return Bulletin(
            id: nhtsaIdNumber, number: number, date: NHTSA.date(communicationDate),
            title: title.isEmpty ? number : title, detail: detail,
            components: components?.map(\.name) ?? [], documentCount: associatedDocumentsCount ?? 0
        )
    }

    /// Summaries are hard-wrapped near 95 characters. A short first line without a full stop,
    /// followed by a capitalised line, is a heading; otherwise the unwrapped text's first
    /// sentence is. List items stay on their own lines.
    static func split(_ summary: String) -> (title: String, detail: String) {
        let lines = summary.split(whereSeparator: \.isNewline).map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        guard let first = lines.first else { return ("", "") }
        if lines.count > 1, first.count <= 80, !first.hasSuffix("."),
            lines[1].first?.isUppercase == true
        {
            return (first, unwrap(lines.dropFirst()))
        }
        let text = unwrap(lines[...])
        guard let stop = text.range(of: ". ") else { return (text, "") }
        return (
            String(text[..<stop.lowerBound]) + ".",
            String(text[stop.upperBound...]).trimmingCharacters(in: .whitespaces)
        )
    }

    private static func unwrap(_ lines: ArraySlice<String>) -> String {
        var text = ""
        for line in lines {
            if !text.isEmpty {
                text += "•-*".contains(line.prefix(1)) ? "\n" : " "
            }
            text += line
        }
        return text
    }
}

/// In `byYmmt` replies this is a link to the documents; in `byNhtsaId` replies, the documents.
private enum Documents: Decodable {
    struct Document: Decodable {
        let fileName: String
        let url: String
    }
    case link
    case list([Document])

    var documents: [Document] {
        if case .list(let documents) = self { return documents }
        return []
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let list = try? container.decode([Document].self) {
            self = .list(list)
        } else {
            _ = try container.decode(String.self)
            self = .link
        }
    }
}
