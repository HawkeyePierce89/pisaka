import XCTest
@testable import PisakaCore

/// The preview's document tree: construction and equality, case by case.
///
/// A value type with no behaviour still carries two properties worth pinning.
/// The first is that every shape the renderer will be asked to draw can actually
/// be *built* — a case whose payload cannot express a nested checkbox list or a
/// mixed-alignment table is a gap that would otherwise surface as a rendering
/// bug two tasks later. The second is that equality is structural all the way
/// down: the preview model publishes a new tree only when it differs from the
/// one on screen, so `==` deciding "same" for two trees that differ in a nested
/// list item, a table alignment or a top-level source line would silently stop
/// the page from updating.
final class MarkdownDocumentTests: XCTestCase {

    // MARK: - Inline cases

    func testInlineCasesCarryTheirPayloadAndCompareStructurally() {
        XCTAssertEqual(MarkdownInline.text("hi"), .text("hi"))
        XCTAssertNotEqual(MarkdownInline.text("hi"), .text("ho"))
        XCTAssertNotEqual(MarkdownInline.text("hi"), .code("hi"))

        XCTAssertEqual(MarkdownInline.emphasis([.text("a")]), .emphasis([.text("a")]))
        XCTAssertNotEqual(MarkdownInline.emphasis([.text("a")]), .strong([.text("a")]))
        XCTAssertNotEqual(MarkdownInline.strikethrough([.text("a")]), .emphasis([.text("a")]))

        XCTAssertEqual(MarkdownInline.lineBreak, .lineBreak)
        XCTAssertNotEqual(MarkdownInline.lineBreak, .softBreak)
    }

    func testInlineNestingComparesAtEveryDepth() {
        let deep = MarkdownInline.strong([.emphasis([.strikethrough([.text("x")])])])
        XCTAssertEqual(deep, .strong([.emphasis([.strikethrough([.text("x")])])]))
        XCTAssertNotEqual(deep, .strong([.emphasis([.strikethrough([.text("y")])])]))
    }

    func testLinkAndImageCarryDestinationAndTitleSeparately() {
        let link = MarkdownInline.link(destination: "./a.md", title: "T", children: [.text("a")])
        XCTAssertEqual(link, .link(destination: "./a.md", title: "T", children: [.text("a")]))
        XCTAssertNotEqual(link, .link(destination: "./b.md", title: "T", children: [.text("a")]))
        XCTAssertNotEqual(link, .link(destination: "./a.md", title: nil, children: [.text("a")]))
        XCTAssertNotEqual(link, .link(destination: "./a.md", title: "T", children: [.text("b")]))

        // A destination the source omitted is `nil`, not an empty string: the
        // asset rule is asked about a spelling, and "" is a spelling.
        XCTAssertNotEqual(
            MarkdownInline.link(destination: nil, title: nil, children: []),
            .link(destination: "", title: nil, children: [])
        )

        let image = MarkdownInline.image(source: "img/a.png", title: nil, children: [.text("alt")])
        XCTAssertEqual(image, .image(source: "img/a.png", title: nil, children: [.text("alt")]))
        XCTAssertNotEqual(image, .image(source: "img/a.png", title: nil, children: [.text("other")]))
        // An image is not a link, even with the same payload shape.
        XCTAssertNotEqual(image, .link(destination: "img/a.png", title: nil, children: [.text("alt")]))
    }

    func testAutolinkIsItsOwnCaseRatherThanALinkThatMatchesItsText() {
        let autolink = MarkdownInline.autolink(destination: "https://example.com")
        XCTAssertEqual(autolink, .autolink(destination: "https://example.com"))
        XCTAssertNotEqual(
            autolink,
            .link(destination: "https://example.com", title: nil, children: [.text("https://example.com")])
        )
    }

    // MARK: - Block cases

    func testBlockCasesCarryTheirPayloadAndCompareStructurally() {
        XCTAssertEqual(MarkdownBlock.paragraph([.text("p")]), .paragraph([.text("p")]))
        XCTAssertNotEqual(MarkdownBlock.paragraph([.text("p")]), .paragraph([.text("q")]))

        XCTAssertEqual(MarkdownBlock.heading(level: 2, children: [.text("h")]), .heading(level: 2, children: [.text("h")]))
        XCTAssertNotEqual(MarkdownBlock.heading(level: 2, children: [.text("h")]), .heading(level: 3, children: [.text("h")]))

        XCTAssertEqual(MarkdownBlock.thematicBreak, .thematicBreak)
        XCTAssertNotEqual(MarkdownBlock.thematicBreak, .paragraph([]))
    }

    func testCodeBlockDistinguishesNoLanguageFromAnEmptyOne() {
        let bare = MarkdownBlock.codeBlock(language: nil, code: "let a = 1\n")
        XCTAssertEqual(bare, .codeBlock(language: nil, code: "let a = 1\n"))
        XCTAssertNotEqual(bare, .codeBlock(language: "", code: "let a = 1\n"))
        XCTAssertNotEqual(bare, .codeBlock(language: "swift", code: "let a = 1\n"))
        // The code is verbatim, trailing newline included.
        XCTAssertNotEqual(bare, .codeBlock(language: nil, code: "let a = 1"))
    }

    func testBlockQuoteNestsBlocks() {
        let quote = MarkdownBlock.blockQuote([.paragraph([.text("a")]), .blockQuote([.paragraph([.text("b")])])])
        XCTAssertEqual(quote, .blockQuote([.paragraph([.text("a")]), .blockQuote([.paragraph([.text("b")])])]))
        XCTAssertNotEqual(quote, .blockQuote([.paragraph([.text("a")]), .blockQuote([.paragraph([.text("c")])])]))
    }

    func testOrderedListCarriesItsStart() {
        let item = MarkdownListItem(blocks: [.paragraph([.text("one")])])
        XCTAssertEqual(MarkdownBlock.orderedList(start: 3, items: [item]), .orderedList(start: 3, items: [item]))
        XCTAssertNotEqual(MarkdownBlock.orderedList(start: 3, items: [item]), .orderedList(start: 1, items: [item]))
        XCTAssertNotEqual(MarkdownBlock.orderedList(start: 1, items: [item]), .unorderedList([item]))
    }

    // MARK: - The two shapes the renderer is hardest on

    func testNestedListWithCheckboxes() {
        let nested = MarkdownBlock.unorderedList([
            MarkdownListItem(checkbox: .checked, blocks: [.paragraph([.text("done")])]),
            MarkdownListItem(checkbox: .unchecked, blocks: [
                .paragraph([.text("todo")]),
                .unorderedList([
                    MarkdownListItem(checkbox: .unchecked, blocks: [.paragraph([.text("sub")])]),
                    MarkdownListItem(blocks: [.paragraph([.text("plain")])]),
                ]),
            ]),
        ])

        guard case let .unorderedList(items) = nested else { return XCTFail("expected an unordered list") }
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].checkbox, .checked)
        XCTAssertEqual(items[1].checkbox, .unchecked)

        guard case let .unorderedList(sub) = items[1].blocks[1] else { return XCTFail("expected a nested list") }
        XCTAssertEqual(sub[0].checkbox, .unchecked)
        // An item with no checkbox is distinct from an unchecked one: one draws
        // a bullet, the other an empty box.
        XCTAssertNil(sub[1].checkbox)
        XCTAssertNotEqual(sub[0], sub[1])
    }

    func testNestedListEqualityReachesTheDeepestItem() {
        func list(_ deepest: String) -> MarkdownBlock {
            .unorderedList([
                MarkdownListItem(blocks: [
                    .paragraph([.text("outer")]),
                    .orderedList(start: 1, items: [
                        MarkdownListItem(checkbox: .checked, blocks: [.paragraph([.text(deepest)])])
                    ]),
                ]),
            ])
        }
        XCTAssertEqual(list("x"), list("x"))
        XCTAssertNotEqual(list("x"), list("y"))
    }

    func testTableWithMixedAlignment() {
        let table = MarkdownBlock.table(
            alignments: [.left, .center, .right, .none],
            header: MarkdownTableRow(cells: [[.text("a")], [.text("b")], [.text("c")], [.text("d")]]),
            body: [
                MarkdownTableRow(cells: [[.text("1")], [.strong([.text("2")])], [.text("3")], [.text("4")]]),
                // GFM permits a short row; nothing pads it here.
                MarkdownTableRow(cells: [[.text("5")]]),
            ]
        )

        guard case let .table(alignments, header, body) = table else { return XCTFail("expected a table") }
        XCTAssertEqual(alignments, [.left, .center, .right, .none])
        XCTAssertEqual(header.cells.count, 4)
        XCTAssertEqual(body.count, 2)
        XCTAssertEqual(body[1].cells.count, 1)
        XCTAssertEqual(body[0].cells[1], [.strong([.text("2")])])
    }

    func testTableAlignmentIsPartOfEquality() {
        let header = MarkdownTableRow(cells: [[.text("a")]])
        XCTAssertNotEqual(
            MarkdownBlock.table(alignments: [.left], header: header, body: []),
            MarkdownBlock.table(alignments: [.none], header: header, body: [])
        )
        XCTAssertNotEqual(
            MarkdownBlock.table(alignments: [.center], header: header, body: []),
            MarkdownBlock.table(alignments: [.right], header: header, body: [])
        )
        XCTAssertEqual(
            MarkdownBlock.table(alignments: [.left], header: header, body: []),
            MarkdownBlock.table(alignments: [.left], header: header, body: [])
        )
    }

    // MARK: - The document and its source lines

    func testTopLevelBlockCarriesTheSourceLineAndTheDocumentKeepsOrder() {
        let document = MarkdownDocument(blocks: [
            MarkdownTopLevelBlock(block: .heading(level: 1, children: [.text("Title")]), sourceLine: 1),
            MarkdownTopLevelBlock(block: .paragraph([.text("body")]), sourceLine: 3),
            MarkdownTopLevelBlock(block: .thematicBreak, sourceLine: 5),
        ])

        XCTAssertEqual(document.blocks.map(\.sourceLine), [1, 3, 5])
        XCTAssertEqual(document.blocks.first?.block, .heading(level: 1, children: [.text("Title")]))
    }

    func testASourceLineIsOptionalAndPartOfEquality() {
        let block = MarkdownBlock.paragraph([.text("p")])
        XCTAssertNil(MarkdownTopLevelBlock(block: block).sourceLine)
        XCTAssertNotEqual(
            MarkdownTopLevelBlock(block: block, sourceLine: 2),
            MarkdownTopLevelBlock(block: block, sourceLine: 3)
        )
        XCTAssertNotEqual(
            MarkdownTopLevelBlock(block: block, sourceLine: nil),
            MarkdownTopLevelBlock(block: block, sourceLine: 1)
        )
    }

    func testDocumentOrderIsPartOfEquality() {
        let first = MarkdownTopLevelBlock(block: .paragraph([.text("a")]), sourceLine: 1)
        let second = MarkdownTopLevelBlock(block: .paragraph([.text("b")]), sourceLine: 2)
        XCTAssertEqual(MarkdownDocument(blocks: [first, second]), MarkdownDocument(blocks: [first, second]))
        XCTAssertNotEqual(MarkdownDocument(blocks: [first, second]), MarkdownDocument(blocks: [second, first]))
    }

    func testTheEmptyDocumentHasNoBlocks() {
        XCTAssertEqual(MarkdownDocument.empty.blocks, [])
        XCTAssertEqual(MarkdownDocument.empty, MarkdownDocument(blocks: []))
        XCTAssertNotEqual(
            MarkdownDocument.empty,
            MarkdownDocument(blocks: [MarkdownTopLevelBlock(block: .paragraph([]))])
        )
    }
}
