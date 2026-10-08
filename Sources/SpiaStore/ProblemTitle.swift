import Foundation

/// Turns the owner's first description into a short problem title.
public enum ProblemTitle {
    public static func derive(from text: String) -> String {
        let cleaned =
            text
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "New problem" }

        let delimiters = [".", "!", "?", ";", " - "]
        let firstDelimiter = delimiters.compactMap { delimiter in
            cleaned.range(of: delimiter).map { ($0.lowerBound, delimiter) }
        }.min { $0.0 < $1.0 }
        var title = firstDelimiter.map { String(cleaned[..<$0.0]) } ?? cleaned
        if firstDelimiter == nil, title.count > 60, let comma = title.firstIndex(of: ",") {
            title = String(title[..<comma])
        }
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return "New problem" }
        guard let first = title.first else { return "New problem" }
        title.replaceSubrange(
            title.startIndex...title.startIndex, with: String(first).uppercased())
        return shortened(title)
    }

    private static func shortened(_ title: String) -> String {
        guard title.count > 48 else { return title }
        let limit = 47
        let prefix = String(title.prefix(limit))
        let boundary = prefix.lastIndex(where: { $0.isWhitespace }) ?? prefix.endIndex
        let shortened = String(prefix[..<boundary]).trimmingCharacters(in: .whitespacesAndNewlines)
        return shortened.isEmpty ? String(title.prefix(limit)) + "…" : shortened + "…"
    }
}
