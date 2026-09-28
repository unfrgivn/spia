import Foundation

/// A reply's Markdown as blocks to lay out one under another. `Text` draws inline Markdown
/// (bold, italics, code, links) but shows block syntax, like lists and headings, as run-on lines
/// with their markers.
public enum ReplyBlock: Equatable, Sendable {
    case paragraph(AttributedString)
    case heading(level: Int, AttributedString)
    /// A list item: its marker ("1." or "•", or "" for its later paragraphs), how many lists
    /// deep it is, and its text.
    case item(marker: String, depth: Int, AttributedString)
    case code(String)
    case quote(AttributedString)
    case rule

    /// The blocks of `markdown`, keeping its single line breaks the way a chat reply means them,
    /// and its inline styling on the text.
    public static func parse(_ markdown: String) -> [ReplyBlock] {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: markdown, options: options) else {
            return markdown.isEmpty ? [] : [.paragraph(AttributedString(markdown))]
        }
        // Runs of one block share its presentation intent.
        var groups: [(intent: PresentationIntent?, text: AttributedString)] = []
        for run in parsed.runs {
            let breaks = run.inlinePresentationIntent?.isDisjoint(with: [.softBreak, .lineBreak])
            let piece =
                breaks == false ? AttributedString("\n") : AttributedString(parsed[run.range])
            if let last = groups.indices.last, groups[last].intent == run.presentationIntent {
                groups[last].text.append(piece)
            } else {
                groups.append((run.presentationIntent, piece))
            }
        }
        var lastItem: Int?
        return groups.map { block($0.intent?.components ?? [], $0.text, lastItem: &lastItem) }
    }

    /// The blocks run together as lines, list markers kept, for a preview a few lines long.
    public static func preview(_ markdown: String) -> AttributedString {
        var lines: [AttributedString] = []
        for block in parse(markdown) {
            switch block {
            case .paragraph(let text), .heading(_, let text), .quote(let text):
                lines.append(text)
            case .item(let marker, _, let text):
                lines.append(marker.isEmpty ? text : AttributedString(marker + " ") + text)
            case .code(let code):
                lines.append(AttributedString(code))
            case .rule:
                continue
            }
        }
        var joined = AttributedString()
        for (index, line) in lines.enumerated() {
            if index > 0 { joined.append(AttributedString("\n")) }
            joined.append(line)
        }
        return joined
    }

    /// Components run from the innermost out: a list item's paragraph, the item, its list, and
    /// any lists around that.
    private static func block(
        _ components: [PresentationIntent.IntentType], _ text: AttributedString,
        lastItem: inout Int?
    ) -> ReplyBlock {
        switch components.first?.kind {
        case .header(let level): return .heading(level: level, text)
        case .codeBlock:
            var code = String(text.characters)
            while code.hasSuffix("\n") { code.removeLast() }
            return .code(code)
        case .thematicBreak: return .rule
        default: break
        }
        if let index = components.firstIndex(where: \.isListItem),
            case .listItem(let ordinal) = components[index].kind
        {
            let item = components[index].identity
            defer { lastItem = item }
            let depth = components.filter(\.isList).count
            // A loose item's second paragraph continues it, without a second marker.
            guard lastItem != item else { return .item(marker: "", depth: depth, text) }
            let ordered =
                components.indices.contains(index + 1) && components[index + 1].kind == .orderedList
            let marker = ordered ? "\(ordinal)." : depth > 1 ? "◦" : "•"
            return .item(marker: marker, depth: depth, text)
        }
        if components.contains(where: { $0.kind == .blockQuote }) { return .quote(text) }
        return .paragraph(text)
    }
}

extension PresentationIntent.IntentType {
    fileprivate var isListItem: Bool {
        if case .listItem = kind { true } else { false }
    }

    fileprivate var isList: Bool { kind == .orderedList || kind == .unorderedList }
}
