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
        XCTAssertEqual(document.blocks[3].block, .unorderedList(isTight: true, items: [
            MarkdownListItem(checkbox: nil, blocks: [
                .paragraph([.text("first item")]),
                .unorderedList(isTight: true, items: [
                    MarkdownListItem(checkbox: nil, blocks: [.paragraph([.text("nested item")])])
                ]),
            ]),
            MarkdownListItem(checkbox: .unchecked, blocks: [.paragraph([.text("unchecked task")])]),
            MarkdownListItem(checkbox: .checked, blocks: [.paragraph([.text("checked task")])]),
        ]))
    }

    func testTheOrderedListKeepsItsStart() throws {
        let document = try parsedFixture()
        XCTAssertEqual(document.blocks[4].block, .orderedList(start: 3, isTight: true, items: [
            MarkdownListItem(checkbox: nil, blocks: [.paragraph([.text("third")])]),
            MarkdownListItem(checkbox: nil, blocks: [.paragraph([.text("fourth")])]),
        ]))
    }

    // MARK: - Tight and loose

    /// Every tightness expectation below was taken from cmark's own answer —
    /// `cmark_node_get_list_tight` on the node this same text produces — rather
    /// than from reading the spec and guessing, because the whole point of the
    /// derivation is to agree with the parser that threw the flag away.
    ///
    /// The answers are listed outermost-first, in the order a depth-first walk
    /// meets the lists, so a case with a nested list states both.
    private func tightness(of source: String) -> [Bool] {
        var answers: [Bool] = []
        func walk(_ block: MarkdownBlock) {
            switch block {
            case .unorderedList(let isTight, let items):
                answers.append(isTight)
                items.forEach { $0.blocks.forEach(walk) }
            case .orderedList(_, let isTight, let items):
                answers.append(isTight)
                items.forEach { $0.blocks.forEach(walk) }
            case .blockQuote(let blocks):
                blocks.forEach(walk)
            default:
                break
            }
        }
        MarkdownParser().parse(source).blocks.forEach { walk($0.block) }
        return answers
    }

    /// The two halves of CommonMark's rule, each in the smallest source that
    /// states it, plus the tight control beside it.
    func testABlankLineBetweenItemsOrInsideOneMakesTheListLoose() {
        XCTAssertEqual(tightness(of: "- a\n- b\n"), [true])
        XCTAssertEqual(tightness(of: "- a\n\n- b\n"), [false])
        XCTAssertEqual(tightness(of: "- a\n\n  a2\n- b\n"), [false])
        XCTAssertEqual(tightness(of: "1. a\n2. b\n"), [true])
        XCTAssertEqual(tightness(of: "1. a\n\n2. b\n"), [false])
    }

    /// A multi-line block inside an item is not a gap: the fence's own lines,
    /// the quote's, the table's.
    func testAMultiLineBlockInsideAnItemKeepsTheListTight() {
        XCTAssertEqual(tightness(of: "- a\n  ```\n  x\n  ```\n- b\n"), [true])
        XCTAssertEqual(tightness(of: "- a\n  > q\n- b\n"), [true])
        XCTAssertEqual(tightness(of: "- | a | b |\n  | - | - |\n  | 1 | 2 |\n- c\n"), [true])
    }

    /// A Setext heading is the case a leaf-only reading gets wrong: its
    /// underline is part of the heading and part of no child of it, so an item
    /// holding one would look like it ended a line early and the next item would
    /// read as separated by a blank line.
    func testASetextHeadingsUnderlineBelongsToItsItem() {
        XCTAssertEqual(tightness(of: "- a\n  ---\n- b\n"), [true])
        // …and the same shape with the blank line really there is still loose,
        // so the rule above narrows the case rather than emptying it.
        XCTAssertEqual(tightness(of: "- a\n\n  ---\n- b\n"), [false])
    }

    /// "Directly contain" is load-bearing: a blank line buried in a nested list
    /// makes *that* list loose and leaves the list holding it tight.
    func testLoosenessDoesNotLeakBetweenLevels() {
        XCTAssertEqual(tightness(of: "- outer\n  - inner1\n  - inner2\n- outer2\n"), [true, true])
        XCTAssertEqual(tightness(of: "- outer\n  - inner1\n\n  - inner2\n- outer2\n"), [true, false])
        XCTAssertEqual(tightness(of: "- a\n  - a1\n\n- b\n"), [false, true])
    }

    /// A block quote's "blank" line carries a `>` and is still a line between
    /// the two items, which is what makes the line-number reading work inside
    /// one at all.
    func testABlankLineInsideABlockQuoteCountsTheSameWay() {
        XCTAssertEqual(tightness(of: "> - a\n> - b\n"), [true])
        XCTAssertEqual(tightness(of: "> - a\n>\n> - b\n"), [false])
    }

    /// An item always occupies its marker line, whatever it holds: an empty item
    /// has no blocks to read a line from and reports that line alone, and an
    /// item whose content is written *under* the marker rather than beside it
    /// reports from the marker down. Without either half the neighbours would be
    /// compared across a line carrying a marker, and a tight list would read as
    /// loose.
    func testAnItemAlwaysOccupiesItsMarkerLine() {
        XCTAssertEqual(tightness(of: "- a\n-\n- b\n"), [true])
        XCTAssertEqual(tightness(of: "- a\n\n-\n\n- b\n"), [false])
        XCTAssertEqual(tightness(of: "-\n-\n"), [true])
        XCTAssertEqual(tightness(of: "- a\n-\n  x\n- b\n"), [true])
        // The same one level down, where the item that reports only its marker
        // line is the whole of what the nested list has to report.
        XCTAssertEqual(tightness(of: "- a\n  - x\n  -\n- b\n"), [true, true])
        XCTAssertEqual(tightness(of: "-\n  - x\n- b\n"), [true, true])
    }

    /// A block quote inside an item is the one container read from its own
    /// range: cmark extends a quote only on a line the quote itself matched, so
    /// the range covers every `>` line — including a trailing one, blank inside
    /// the quote and part of the quote from the outside — and a blank line whose
    /// deepest container is a block quote loosens nothing. Its children stop at
    /// the last line carrying content, so reading them alone finds a gap where
    /// the source wrote a `>`.
    func testABlockQuoteInsideAnItemCoversItsOwnLines() {
        XCTAssertEqual(tightness(of: "- a\n  >\n- b\n"), [true])
        XCTAssertEqual(tightness(of: "- a\n  > q\n  >\n- b\n"), [true])
        XCTAssertEqual(tightness(of: "- a\n  > q\n  >\n  >\n- b\n"), [true])
        XCTAssertEqual(tightness(of: "- a\n  >\n  > q\n- b\n"), [true])
        XCTAssertEqual(tightness(of: "- >     code\n  >\n- b\n"), [true])
        // The quote's range stops short of the truly blank line that ended it —
        // the enclosing item's range is the one that swallows that — so every
        // shape that is loose stays loose.
        XCTAssertEqual(tightness(of: "- > q\n\n- b\n"), [false])
        XCTAssertEqual(tightness(of: "- > q\n  >\n\n- b\n"), [false])
        XCTAssertEqual(tightness(of: "- a\n  > q\n\n  r\n- b\n"), [false])
        // A list inside the quote still answers for itself: the quote's lines
        // are one span to the list holding it, and the blank `>` inside it is
        // still the gap between the two items it separates.
        XCTAssertEqual(tightness(of: "- > - x\n  >\n- b\n"), [true, true])
        XCTAssertEqual(tightness(of: "- > - x\n  >\n  > - y\n- b\n"), [true, false])
    }

    /// A trailing blank line closes the list rather than loosening it — the case
    /// an item's own range gets wrong, cmark closing the item *after* it.
    func testTheBlankLineThatEndsAListDoesNotLoosenIt() {
        XCTAssertEqual(tightness(of: "- a\n- b\n\ntext\n"), [true])
        XCTAssertEqual(tightness(of: "- a\n\n"), [true])
    }

    /// The shape neither range can be read straight for: an *indented* code
    /// block's swallows the blank line that ended it — cmark strips trailing
    /// blanks from indented code and closes the node after them — while a fenced
    /// block's legitimately runs to its closing fence, and nothing on
    /// `CodeBlock` tells the two apart. The span is trimmed of trailing blank
    /// source lines instead, capped by the lines the range holds beyond the code
    /// itself, so both forms answer exactly.
    func testAnIndentedCodeBlockEndsAtItsContent() {
        XCTAssertEqual(tightness(of: "-     code\n\n- b\n"), [false])
        XCTAssertEqual(tightness(of: "- ```\n  x\n  ```\n\n- b\n"), [false])
        // …and the tight forms of both, which the trim must not turn loose.
        XCTAssertEqual(tightness(of: "-     code\n- b\n"), [true])
        XCTAssertEqual(tightness(of: "- ```\n  x\n  ```\n- b\n"), [true])
        // A fenced block whose own content ends blank: the ceiling has room to
        // drop two lines and the closing fence still stops the walk at once.
        XCTAssertEqual(tightness(of: "- ```\n  x\n\n  ```\n- b\n"), [true])
        // An indented block whose last content line reads blank — `>` opens a
        // quote outside code, so it counts as blank — is kept by that same
        // ceiling: the range holds no line beyond the code.
        XCTAssertEqual(tightness(of: "-     a\n      >\n- b\n"), [true])
        // Not only the last block: an indented block with a blank line ahead of
        // it has already made the list loose.
        XCTAssertEqual(tightness(of: "- a\n\n      code\n\n- b\n"), [false])
        // And the same inside a block quote, where the blank line is written `>`.
        XCTAssertEqual(tightness(of: "> -     code\n>\n> - b\n"), [false])
        XCTAssertEqual(tightness(of: "> -     code\n> - b\n"), [true])
    }

    /// A **link reference definition** is a line the source wrote as content and
    /// the tree keeps no node for — cmark folds it into the document's link map
    /// and drops the paragraph that carried it — so the blocks around it sit two
    /// lines apart with nothing blank between them. The rule reads which lines
    /// the source wrote blank rather than how far apart two blocks sit, which is
    /// what keeps these lists tight, as cmark's own flag has them.
    func testALinkReferenceDefinitionIsNotABlankLine() {
        XCTAssertEqual(tightness(of: "- heading\n  ---\n  [ref]: /x\n  > quote\n- b\n- c\n"), [true])
        XCTAssertEqual(tightness(of: "- # h\n  [ref]: /x\n  para\n- b\n"), [true])
        XCTAssertEqual(tightness(of: "- ```\n  x\n  ```\n  [ref]: /x\n  para\n- b\n"), [true])
        // The controls: a real blank line in the same place still separates, and
        // a definition written *inside* a paragraph is an ordinary lazy
        // continuation line rather than a hole.
        XCTAssertEqual(tightness(of: "- # h\n\n  para\n- b\n"), [false])
        XCTAssertEqual(tightness(of: "- para\n  [ref]: /x\n  > quote\n- b\n"), [true])
    }

    /// **The two shapes where cmark's own flag departs from the sentence cmark
    /// implements**, and this reading follows the sentence. Both are artifacts of
    /// *how* cmark records "did this block end on a blank line" rather than
    /// readings of the source, and CommonMark's rule — a list is loose if its
    /// items are *separated by blank lines* — is unambiguous about both. They are
    /// pinned here so a future run of the corpus measurement recognises them as
    /// known, not as regressions.
    func testTheShapesWhereCmarksOwnFlagDepartsFromTheRule() {
        // A GFM table with **no body rows**: the delimiter row is the last line
        // the table extension consumes and it consumes the whole of it, which
        // leaves the parser reading the remainder of that line as blank. cmark
        // marks the list loose with no blank line written anywhere — and adding
        // one body row makes cmark itself answer tight again, which is what says
        // the looseness is bookkeeping rather than the source.
        XCTAssertEqual(tightness(of: "- a\n  | h |\n  | - |\n- b\n"), [true])
        XCTAssertEqual(tightness(of: "- | h |\n  | - |\n- b\n"), [true])
        XCTAssertEqual(tightness(of: "- a\n  | h |\n  | - |\n  | v |\n- b\n"), [true])
        // A blank line **following a link reference definition**: the paragraph
        // that carried the definition is removed from the tree once the
        // definition is read, and cmark's record of the blank line goes with it.
        // The source wrote a blank line between two of the item's blocks, so the
        // sentence says loose.
        XCTAssertEqual(tightness(of: "- # h\n  [ref]: /x\n\n  para\n- b\n"), [false])
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

    /// A titled link whose text happens to equal its destination is a **link**,
    /// not an autolink.
    ///
    /// swift-markdown's `isAutolink` asks only whether the one text child equals
    /// the destination, so it answers `true` here — and `.autolink` has no field
    /// for a title, which would silently drop it. The syntax an autolink is
    /// written in has nowhere to put a title, so a title is proof this was an
    /// ordinary link; the two spellings must not collapse into one case.
    func testATitledLinkIsNotMistakenForAnAutolink() {
        let document = MarkdownParser().parse(#"[https://example.com](https://example.com "Docs")"#)
        let link = MarkdownInline.link(
            destination: "https://example.com",
            title: "Docs",
            children: [.text("https://example.com")]
        )
        XCTAssertEqual(document.blocks.map(\.block), [.paragraph([link])])
    }

    /// And the untitled one still is, in both spellings that produce it, so the
    /// rule above narrows the case rather than emptying it.
    func testAnUntitledSelfNamingLinkIsStillAnAutolink() {
        for source in ["<https://example.com>", "[https://example.com](https://example.com)"] {
            XCTAssertEqual(
                MarkdownParser().parse(source).blocks.map(\.block),
                [.paragraph([.autolink(destination: "https://example.com")])],
                "\(source) is an autolink"
            )
        }
    }

    /// The seam, not the concrete type: this is how the preview model will reach
    /// the parser, and the only thing it will know about it.
    func testItConformsToTheCoreParserSeam() {
        let parser: any MarkdownParsing = MarkdownParser()
        XCTAssertEqual(parser.parse("# Title").blocks.map(\.block), [.heading(level: 1, children: [.text("Title")])])
    }
}
#endif
