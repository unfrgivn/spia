import Foundation
import Testing

@testable import SpiaAssist

@Suite("Reply blocks")
struct ReplyBlockTests {
    private let reply = """
        Those are the **airbag** controller's codes.
        Check the horn first.

        ## What to check

        1. Does the horn work with the wheel turned fully left?
        2. Look at the `clock spring` connector.
           - nested *point*

        - a bullet

        > a quote

        ```
        80011B 80021B
        ```
        """

    @Test("paragraphs, headings, numbered and nested lists, quotes, and code, in order")
    func blocks() {
        #expect(
            ReplyBlock.parse(reply).map(\.plain) == [
                "Those are the airbag controller's codes.\nCheck the horn first.",
                "## What to check",
                "1. (1) Does the horn work with the wheel turned fully left?",
                "2. (1) Look at the clock spring connector.",
                "◦ (2) nested point",
                "• (1) a bullet",
                "> a quote",
                "``` 80011B 80021B",
            ])
    }

    @Test("bold, italics, and code stay on the text for Text to draw")
    func inlineStyling() throws {
        guard case .paragraph(let text) = try #require(ReplyBlock.parse(reply).first) else {
            Issue.record("not a paragraph")
            return
        }
        let bold = text.runs.first { $0.inlinePresentationIntent == .stronglyEmphasized }
        #expect(bold.map { String(text[$0.range].characters) } == "airbag")
    }

    @Test("a loose list item's second paragraph continues it without another marker")
    func looseItem() {
        let blocks = ReplyBlock.parse("1. First step.\n\n   More about it.\n\n2. Second step.")
        #expect(
            blocks.map(\.plain) == [
                "1. (1) First step.", " (1) More about it.", "2. (1) Second step.",
            ])
    }

    @Test("a preview runs the blocks together as lines, markers kept")
    func preview() {
        let preview = String(ReplyBlock.preview(reply).characters)
        #expect(
            preview.hasPrefix(
                "Those are the airbag controller's codes.\nCheck the horn first.\nWhat to check\n1. Does the horn"
            ))
        #expect(!preview.contains("**"))
        #expect(ReplyBlock.parse("").isEmpty)
    }
}

extension ReplyBlock {
    /// What a block says, with its kind, for comparing.
    fileprivate var plain: String {
        switch self {
        case .paragraph(let text): String(text.characters)
        case .heading(let level, let text):
            String(repeating: "#", count: level) + " " + String(text.characters)
        case .item(let marker, let depth, let text):
            "\(marker) (\(depth)) \(String(text.characters))"
        case .code(let code): "``` " + code
        case .quote(let text): "> " + String(text.characters)
        case .rule: "---"
        }
    }
}
