import Foundation

/// Keyword search over bulletins, for the References screen and the assistant.
public enum BulletinSearch {
    /// Bulletins matching any word of `query`, best first. A word matches words that start with
    /// it, so `steer` finds "steering". Title and number matches count most, then components,
    /// then the rest of the summary; bulletins matching more words rank higher.
    public static func search(_ query: String, in bulletins: [Bulletin], limit: Int = 20)
        -> [Bulletin]
    {
        let terms = words(in: query).filter { !stopWords.contains($0) }
        guard !terms.isEmpty else { return Array(bulletins.prefix(limit)) }
        let scored = bulletins.compactMap { bulletin -> (Bulletin, Int)? in
            let title = Set(words(in: bulletin.title + " " + bulletin.number))
            let components = Set(words(in: bulletin.components.joined(separator: " ")))
            let detail = Set(words(in: bulletin.detail))
            var score = 0
            for term in terms {
                if matches(term, title) {
                    score += 3
                } else if matches(term, components) {
                    score += 2
                } else if matches(term, detail) {
                    score += 1
                }
            }
            return score > 0 ? (bulletin, score) : nil
        }
        return scored.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return (lhs.0.date ?? .distantPast) > (rhs.0.date ?? .distantPast)
        }.prefix(limit).map(\.0)
    }

    static func words(in text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
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
