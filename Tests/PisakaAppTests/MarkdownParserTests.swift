#if os(macOS)
import Foundation
import XCTest
import PisakaCore
@testable import Pisaka

/// `MarkdownParser` against a fixture holding every element the preview renders.
///
/// **This is the only place in the pipeline where the parser executes.** It is
/// the app's one `import Markdown`, and `PisakaCore` deliberately does not link
/// swift-markdown, so `swift test` cannot reach it; the app-layer bundle can,
/// and does so headlessly — no window, no web view, no WebKit.
///
/// The fixture is read through `#filePath` rather than from the test bundle, the
/// way the repository-file suites in `PisakaCoreTests` read theirs: it is source
/// data about the parser, not a resource the product ships, and reading it from
/// disk keeps the assertion honest if the bundle's resource wiring ever changes.
///
/// What is asserted is the *whole* tree, case by case, plus every top-level
/// `sourceLine`. Both halves matter and for different reasons: the shape is what
/// the renderer will be handed, and the lines are what `data-line` and scroll
/// sync are built on, so a source-position regression that left the shape intact
/// would otherwise surface only as a preview that scrolls to the wrong place.
final class MarkdownParserTests: XCTestCase {
    private func fixtureText() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/every-element.md")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func parsedFixture() throws -> MarkdownDocument {
        MarkdownParser().parse(try fixtureText())
    }

    // MARK: - Top-level shape and source lines

    /// Every top-level block, in order, with the 1-based line it started on.
    ///
    /// The two dropped nodes are visible here by their absence: the raw HTML
    /// block on line 38 produces no entry at all, so line 40's paragraph follows
    /// line 36's indented code directly.
    func testTheTopLevelBlocksAndTheirSourceLines() throws {
        let document = try parsedFixture()
        let lines = document.blocks.map { $0.sourceLine }
        XCTAssertEqual(lines, [1, 3, 8, 10, 15, 18, 20, 24, 28, 32, 36, 40, 42])
        XCTAssertEqual(document.blocks.count, 13)
    }

    func testTheHeadingsCarryTheirLevels() throws {
        let document = try parsedFixture()
        XCTAssertEqual(document.blocks[0].block, .heading(level: 1, children: [.text("Heading one")]))
        XCTAssertEqual(document.blocks[2].block, .heading(level: 2, children: [.text("Heading two")]))
    }

    // MARK: - Inline content

    func testTheFirstParagraphsInlineContent() throws {
        let document = try parsedFixture()
        XCTAssertEqual(document.blocks[1].block, .paragraph([
            .text("A paragraph with "),
            .emphasis([.text("emphasis")]),
            .text(", "),
            .strong([.text("strong")]),
            .text(", "),
            .strikethrough([.text("struck")]),
            .text(", "),
            .code("code"),
            .text(","),
            .softBreak,
            .text("a "),
            .link(destination: "./notes/other.md", title: "the title", children: [.text("relative link")]),
            .text(", an "),
            .image(source: "./img/logo.png", title: nil, children: [.text("image")]),
            .text(","),
            .softBreak,
            .text("an autolink "),
            .autolink(destination: "https://example.com/"),
            .text(" and a hard break here"),
            .lineBreak,
            .text("on the next line."),
        ]))
    }

    /// The inline raw HTML spans are gone and the text around them is not: the
    /// drop is structural (there is no case to map onto), never a filter that
    /// could take a neighbour with it.
    func testTheInlineRawHTMLIsDroppedAndItsNeighboursAreNot() throws {
        let document = try parsedFixture()
        XCTAssertEqual(document.blocks[11].block, .paragraph([
            .text("A paragraph with an inline "),
            .text("span"),
            .text(" that is dropped."),
        ]))
    }

    // MARK: - Lists

    func testTheUnorderedListWithItsNestedListAndTaskItems() throws {
        let document = try parsedFixture()
        XCTAssertEqual(document.blocks[3].block, .unorderedList([
            MarkdownListItem(checkbox: nil, blocks: [
                .paragraph([.text("first item")]),
                .unorderedList([
                    MarkdownListItem(checkbox: nil, blocks: [.paragraph([.text("nested item")])])
                ]),
            ]),
            MarkdownListItem(checkbox: .unchecked, blocks: [.paragraph([.text("unchecked task")])]),
            MarkdownListItem(checkbox: .checked, blocks: [.paragraph([.text("checked task")])]),
        ]))
    }

    func testTheOrderedListKeepsItsStart() throws {
        let document = try parsedFixture()
        XCTAssertEqual(document.blocks[4].block, .orderedList(start: 3, items: [
            MarkdownListItem(checkbox: nil, blocks: [.paragraph([.text("third")])]),
            MarkdownListItem(checkbox: nil, blocks: [.paragraph([.text("fourth")])]),
        ]))
    }

    func testTheBlockQuoteHoldsItsOwnBlocks() throws {
        let document = try parsedFixture()
        XCTAssertEqual(document.blocks[5].block, .blockQuote([.paragraph([.text("A quoted paragraph.")])]))
    }

    // MARK: - Table

    func testTheTablesAlignmentsHeaderAndBody() throws {
        let document = try parsedFixture()
        XCTAssertEqual(document.blocks[6].block, .table(
            alignments: [.left, .center, .right, .none],
            header: MarkdownTableRow(cells: [
                [.text("Left")], [.text("Center")], [.text("Right")], [.text("Plain")]
            ]),
            body: [
                MarkdownTableRow(cells: [[.text("a")], [.text("b")], [.text("c")], [.text("d")]])
            ]
        ))
    }

    // MARK: - Code blocks

    /// The three fence forms plus the indented one. A bare fence and an indented
    /// block both answer `nil` for the language, which is what tells the
    /// renderer not to emit a highlight class; nothing here guesses one.
    func testTheCodeBlocksKeepTheirLanguagesAndTheirText() throws {
        let document = try parsedFixture()
        XCTAssertEqual(document.blocks[7].block, .codeBlock(language: "swift", code: "let x = 1\n"))
        XCTAssertEqual(document.blocks[8].block, .codeBlock(language: "mermaid", code: "graph TD; A-->B;\n"))
        XCTAssertEqual(document.blocks[9].block, .codeBlock(language: nil, code: "bare fence\n"))
        XCTAssertEqual(document.blocks[10].block, .codeBlock(language: nil, code: "indented code\n"))
    }

    func testTheThematicBreak() throws {
        let document = try parsedFixture()
        XCTAssertEqual(document.blocks[12].block, .thematicBreak)
    }

    // MARK: - The parser's refusals

    /// Smart punctuation is off, so the text is exactly what the source spelled:
    /// straight quotes stay straight and `--` stays two hyphens. Rewriting them
    /// would be a normalisation, which is the one thing this file may not do.
    func testTextIsNotNormalised() {
        let document = MarkdownParser().parse(#"He said "no" -- twice."#)
        XCTAssertEqual(document.blocks.map(\.block), [.paragraph([.text(#"He said "no" -- twice."#)])])
    }

    /// An empty document is the empty tree, not a document holding an empty
    /// paragraph.
    func testAnEmptyTextParsesToTheEmptyDocument() {
        XCTAssertEqual(MarkdownParser().parse(""), MarkdownDocument.empty)
    }

    /// A document that is nothing but raw HTML has nowhere for any of it to go.
    func testADocumentOfRawHTMLAloneIsEmpty() {
        XCTAssertEqual(MarkdownParser().parse("<div>\n<p>only markup</p>\n</div>\n"), MarkdownDocument.empty)
    }

    /// The seam, not the concrete type: this is how the preview model will reach
    /// the parser, and the only thing it will know about it.
    func testItConformsToTheCoreParserSeam() {
        let parser: any MarkdownParsing = MarkdownParser()
        XCTAssertEqual(parser.parse("# Title").blocks.map(\.block), [.heading(level: 1, children: [.text("Title")])])
    }
}
#endif
