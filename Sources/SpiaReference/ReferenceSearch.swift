import Foundation

/// Keyword search over the public records, for the References screen and the assistant.
///
/// A record matches any word of the query, and a word matches the words that start with it, so
/// `steer` finds "steering". Neighbouring words count joined up too, so `airbag` finds "air
/// bags". Each kind of record has tiers of fields, best first; a word found in a better tier
/// counts more, records matching more words rank higher, and newer ones break ties. A query
/// with no words to look for matches everything, in the order given.
public enum ReferenceSearch {
    /// Title and number, then components, then the rest of the summary.
    public static func bulletins(_ query: String, in bulletins: [Bulletin], limit: Int = .max)
        -> [Bulletin]
    {
        rank(query, bulletins, limit: limit, date: \.date) { bulletin in
            [
                bulletin.title + " " + bulletin.number, bulletin.components.joined(separator: " "),
                bulletin.detail,
            ]
        }
    }

    /// Components and campaign numbers, then what could happen, then the rest.
    public static func recalls(_ query: String, in recalls: [Recall], limit: Int = .max)
        -> [Recall]
    {
        rank(query, recalls, limit: limit, date: \.reportDate) { recall in
            [
                ([recall.id, recall.manufacturerCampaign ?? ""] + recall.components)
                    .joined(separator: " "),
                recall.consequence, recall.summary + " " + recall.remedy,
            ]
        }
    }

    /// Components, then the owner's account.
    public static func complaints(_ query: String, in complaints: [Complaint], limit: Int = .max)
        -> [Complaint]
    {
        rank(query, complaints, limit: limit, date: \.dateFiled) { complaint in
            [complaint.components.joined(separator: " "), complaint.description]
        }
    }

    private static func rank<Record>(
        _ query: String, _ records: [Record], limit: Int, date: (Record) -> Date?,
        tiers: (Record) -> [String]
    ) -> [Record] {
        let terms = words(in: query).filter { !stopWords.contains($0) }
        guard !terms.isEmpty else { return Array(records.prefix(limit)) }
        let scored = records.compactMap { record -> (Record, Int)? in
            let fields = tiers(record).map(vocabulary)
            let score = terms.reduce(0) { score, term in
                // The best tier the word is in: the first of three counts 3, the last 1.
                score + (fields.firstIndex { matches(term, $0) }.map { fields.count - $0 } ?? 0)
            }
            return score > 0 ? (record, score) : nil
        }
        return scored.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return (date(lhs.0) ?? .distantPast) > (date(rhs.0) ?? .distantPast)
        }.prefix(limit).map(\.0)
    }

    static func words(in text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// A field's words, and each pair of neighbours joined ("seat belt" as "seatbelt"), leaving
    /// out pairs with a stop word, which would make "the rear" into "therear".
    private static func vocabulary(_ text: String) -> Set<String> {
        let all = words(in: text)
        let pairs = zip(all, all.dropFirst()).compactMap { first, second in
            stopWords.contains(first) || stopWords.contains(second) ? nil : first + second
        }
        return Set(all).union(pairs)
    }

    private static func matches(_ term: String, _ words: Set<String>) -> Bool {
        if words.contains(term) { return true }
        guard term.count >= 3 else { return false }
        return words.contains { $0.hasPrefix(term) }
    }

    private static let stopWords: Set<String> = [
        "a", "an", "and", "are", "for", "in", "is", "of", "on", "or", "the", "to", "with",
    ]
}

extension SafetyRecord {
    /// The records mentioning any word of `query`, best first; for a blank query, all of them.
    public func matching(_ query: String) -> SafetyRecord {
        SafetyRecord(
            recalls: ReferenceSearch.recalls(query, in: recalls),
            complaints: ReferenceSearch.complaints(query, in: complaints),
            bulletins: ReferenceSearch.bulletins(query, in: bulletins))
    }
}
