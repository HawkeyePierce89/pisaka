import XCTest
@testable import PisakaCore

/// The renderer: a document tree in, an HTML body out.
///
/// This is the suite that decides what the preview *shows*, and it can decide
/// it because the renderer is a pure function — no web view, no parser, no
/// files. Three of its properties are the interesting ones and each is asserted
/// on its own rather than through a whole-document golden string:
///
/// * **Escaping happens once, everywhere.** Text position and attribute value
///   alike, for every author-supplied string. A golden-file assertion would
///   cover this only for the strings the fixture happened to contain.
/// * **`data-line` is on top-level blocks and nowhere else.** The one property
///   scroll sync depends on, and one a nested-block regression would break
///   silently — the preview would still render, and would still scroll, just to
///   the wrong place.
/// * **A file target is either an app-scheme URL or the source's own
///   spelling.** Which is the forward half of the round trip the navigation rule
///   closes: what is asserted here is the exact string the delegate will later be
///   handed.
final class MarkdownRendererTests: XCTestCase {

    // MARK: - Fixtures

    /// A document with no file and no project — the context under which every
    /// relative target is unresolvable, used by every test that is not about
    /// asset resolution.
    private let noContext = MarkdownDocumentContext.none

    /// A project at `/p/root` with a document two levels down, so `..` has
    /// somewhere to climb to and somewhere to climb *past*.
    private let projectContext = MarkdownDocumentContext(
        documentURL: URL(fileURLWithPath: "/p/root/docs/guide.md"),
        projectRoot: URL(fileURLWithPath: "/p/root")
    )

    private func body(_ blocks: [MarkdownTopLevelBlock], _ context: MarkdownDocumentContext? = nil) -> String {
        MarkdownRenderer.body(for: MarkdownDocument(blocks: blocks), context: context ?? noContext)
    }

    private func body(_ block: MarkdownBlock, line: Int? = nil, _ context: MarkdownDocumentContext? = nil) -> String {
        body([MarkdownTopLevelBlock(block: block, sourceLine: line)], context)
    }

    // MARK: - Escaping

    /// The five characters, in text position.
    func testTextIsEscaped() {
        let rendered = body(.paragraph([.text("a < b & c > d \"q\" 'q'")]))
        XCTAssertEqual(rendered, "<p>a &lt; b &amp; c &gt; d &quot;q&quot; &#39;q&#39;</p>")
    }

    /// `&` is folded first, so the ampersands the other four introduce are not
    /// escaped a second time. The classic double-escape regression: `<` becoming
    /// `&amp;lt;` and rendering as visible source.
    func testAmpersandIsNotDoubleEscaped() {
        XCTAssertEqual(body(.paragraph([.text("&amp; <")])), "<p>&amp;amp; &lt;</p>")
    }

    /// The same escape in every attribute value. A title carrying a quote is the
    /// injection this closes: unescaped, `" onmouseover="…` is an attribute the
    /// document author wrote.
    func testAttributeValuesAreEscaped() {
        let rendered = body(.paragraph([
            .link(destination: "https://e.com/?a=1&b=2", title: "a \" b < c", children: [.text("x")]),
        ]))
        XCTAssertEqual(
            rendered,
            "<p><a href=\"https://e.com/?a=1&amp;b=2\" title=\"a &quot; b &lt; c\">x</a></p>"
        )
    }

    /// An image's `alt` is flattened inline content, escaped like any other
    /// attribute — and a nested emphasis contributes its words, not its markup.
    func testImageAltIsFlattenedAndEscaped() {
        let rendered = body(.paragraph([
            .image(source: nil, title: nil, children: [.text("a \"b\" "), .emphasis([.text("c")]), .code("<d>")]),
        ]))
        XCTAssertEqual(rendered, "<p><img alt=\"a &quot;b&quot; c&lt;d&gt;\"></p>")
    }

    /// Code content is escaped too — a `<script>` inside a fence is text.
    func testCodeContentIsEscaped() {
        XCTAssertEqual(
            body(.codeBlock(language: nil, code: "<script>alert('x')</script>")),
            "<pre><code>&lt;script&gt;alert(&#39;x&#39;)&lt;/script&gt;</code></pre>"
        )
        XCTAssertEqual(body(.paragraph([.code("a<b")])), "<p><code>a&lt;b</code></p>")
    }

    // MARK: - data-line

    /// Every top-level block kind carries the attribute, on its outermost
    /// element.
    func testTopLevelBlocksCarryTheirSourceLine() {
        let cases: [MarkdownBlock] = [
            .paragraph([.text("p")]),
            .heading(level: 2, children: [.text("h")]),
            .codeBlock(language: nil, code: "c"),
            .codeBlock(language: "swift", code: "c"),
            .codeBlock(language: "mermaid", code: "c"),
            .blockQuote([.paragraph([.text("q")])]),
            .unorderedList(isTight: true, items: [MarkdownListItem(blocks: [.paragraph([.text("i")])])]),
            .orderedList(start: 1, isTight: true, items: [MarkdownListItem(blocks: [.paragraph([.text("i")])])]),
            .table(alignments: [.none], header: MarkdownTableRow(cells: [[.text("h")]]), body: []),
            .thematicBreak,
        ]
        for block in cases {
            XCTAssertTrue(body(block, line: 7).contains(" data-line=\"7\""), "\(block)")
        }
    }

    /// A block whose parser gave no source range carries no attribute at all —
    /// not an empty one and not a zero.
    func testBlockWithoutSourceLineCarriesNoAttribute() {
        XCTAssertEqual(body(.paragraph([.text("x")])), "<p>x</p>")
    }

    /// The lines are the blocks' own, in order.
    func testEachTopLevelBlockCarriesItsOwnLine() {
        let rendered = body([
            MarkdownTopLevelBlock(block: .paragraph([.text("a")]), sourceLine: 1),
            MarkdownTopLevelBlock(block: .thematicBreak, sourceLine: 3),
            MarkdownTopLevelBlock(block: .paragraph([.text("b")]), sourceLine: 5),
        ])
        XCTAssertEqual(rendered, "<p data-line=\"1\">a</p>\n<hr data-line=\"3\">\n<p data-line=\"5\">b</p>")
    }

    /// **Nested blocks carry none.** A blockquote's paragraph, a list item's
    /// paragraph and a nested list are all rendered from the same block renderer
    /// as their top-level counterparts, so nothing but the call site keeps the
    /// attribute off them — which is exactly what this asserts.
    func testNestedBlocksCarryNoSourceLine() {
        let nested = MarkdownBlock.blockQuote([
            .paragraph([.text("q")]),
            .unorderedList(isTight: true, items: [MarkdownListItem(blocks: [.paragraph([.text("i")]), .thematicBreak])]),
        ])
        let rendered = body(nested, line: 4)
        // Exactly one occurrence, and it is the blockquote's own.
        XCTAssertEqual(rendered.components(separatedBy: "data-line").count - 1, 1)
        XCTAssertTrue(rendered.hasPrefix("<blockquote data-line=\"4\">"), rendered)
    }

    // MARK: - Code blocks

    /// The three fence shapes, and no fourth.
    func testTheThreeFenceShapes() {
        XCTAssertEqual(
            body(.codeBlock(language: nil, code: "let x = 1\n")),
            "<pre><code>let x = 1\n</code></pre>"
        )
        XCTAssertEqual(
            body(.codeBlock(language: "swift", code: "let x = 1\n")),
            "<pre><code class=\"language-swift\">let x = 1\n</code></pre>"
        )
        XCTAssertEqual(
            body(.codeBlock(language: "mermaid", code: "graph TD;\n")),
            "<pre class=\"mermaid\">graph TD;\n</pre>"
        )
    }

    /// A fence with no language gets **no** highlight class: nothing is
    /// auto-detected, so the markup carries nothing for highlight.js to find.
    func testUnlabelledFenceCarriesNoLanguageClass() {
        XCTAssertFalse(body(.codeBlock(language: nil, code: "x")).contains("language-"))
        XCTAssertFalse(body(.codeBlock(language: nil, code: "x")).contains("class="))
    }

    /// An info string is reduced to its first word, and folded to lower case:
    /// `class="language-swift"`, never `language-Swift title=Example.swift`.
    func testInfoStringIsReducedToItsFirstWordLowercased() {
        XCTAssertEqual(
            body(.codeBlock(language: "Swift title=Example.swift", code: "x")),
            "<pre><code class=\"language-swift\">x</code></pre>"
        )
        XCTAssertEqual(
            body(.codeBlock(language: "MERMAID", code: "x")),
            "<pre class=\"mermaid\">x</pre>"
        )
    }

    /// A language name is escaped where it lands, like every other attribute
    /// value: an info string is author-supplied text, not a vetted identifier.
    func testLanguageNameIsEscaped() {
        XCTAssertEqual(
            body(.codeBlock(language: "\"><script>", code: "x")),
            "<pre><code class=\"language-&quot;&gt;&lt;script&gt;\">x</code></pre>"
        )
    }

    // MARK: - Lists

    /// A task item draws a disabled checkbox; an ordinary item draws none at
    /// all, which is what distinguishes it from an unchecked one.
    func testTaskItemsAndOrdinaryItems() {
        let rendered = body(.unorderedList(isTight: true, items: [
            MarkdownListItem(checkbox: nil, blocks: [.paragraph([.text("plain")])]),
            MarkdownListItem(checkbox: .unchecked, blocks: [.paragraph([.text("todo")])]),
            MarkdownListItem(checkbox: .checked, blocks: [.paragraph([.text("done")])]),
        ]))
        XCTAssertEqual(rendered, """
            <ul><li><p>plain</p></li>
            <li class="task-list-item"><input type="checkbox" disabled><p>todo</p></li>
            <li class="task-list-item"><input type="checkbox" disabled checked><p>done</p></li></ul>
            """)
    }

    /// Every checkbox is disabled: the preview is read-only and writes nothing.
    func testEveryCheckboxIsDisabled() {
        let rendered = body(.unorderedList(isTight: true, items: [
            MarkdownListItem(checkbox: .unchecked, blocks: [.paragraph([.text("a")])]),
            MarkdownListItem(checkbox: .checked, blocks: [.paragraph([.text("b")])]),
        ]))
        let inputs = rendered.components(separatedBy: "<input").count - 1
        let disabled = rendered.components(separatedBy: "disabled").count - 1
        XCTAssertEqual(inputs, 2)
        XCTAssertEqual(disabled, 2)
    }

    /// An ordered list states its start, always — including `1`.
    func testOrderedListStatesItsStart() {
        let item = MarkdownListItem(blocks: [.paragraph([.text("a")])])
        XCTAssertTrue(body(.orderedList(start: 3, isTight: true, items: [item])).hasPrefix("<ol start=\"3\">"))
        XCTAssertTrue(body(.orderedList(start: 1, isTight: true, items: [item])).hasPrefix("<ol start=\"1\">"))
    }

    /// A loose list says so on the element; a tight one says nothing at all, so
    /// the ordinary list renders exactly as it did before the distinction
    /// existed.
    func testOnlyALooseListCarriesTheClass() {
        let item = MarkdownListItem(blocks: [.paragraph([.text("a")])])
        XCTAssertEqual(body(.unorderedList(isTight: true, items: [item])), "<ul><li><p>a</p></li></ul>")
        XCTAssertEqual(body(.unorderedList(isTight: false, items: [item])),
                       "<ul class=\"loose\"><li><p>a</p></li></ul>")
        XCTAssertEqual(body(.orderedList(start: 1, isTight: true, items: [item])),
                       "<ol start=\"1\"><li><p>a</p></li></ol>")
        XCTAssertEqual(body(.orderedList(start: 2, isTight: false, items: [item])),
                       "<ol start=\"2\" class=\"loose\"><li><p>a</p></li></ol>")
    }

    /// The class and `data-line` are both attributes of the same element and
    /// neither displaces the other — the regression a naive interpolation makes
    /// is one swallowing the other's quote.
    func testALooseListKeepsItsSourceLine() {
        let item = MarkdownListItem(blocks: [.paragraph([.text("a")])])
        XCTAssertEqual(body(.unorderedList(isTight: false, items: [item]), line: 4),
                       "<ul class=\"loose\" data-line=\"4\"><li><p>a</p></li></ul>")
    }

    /// Looseness is a fact about the list, so it reaches a nested list only if
    /// that list carries it: the outer one being loose says nothing about the
    /// inner one, which is exactly what CommonMark decides separately.
    func testANestedListsLoosenessIsItsOwn() {
        let inner = MarkdownBlock.unorderedList(
            isTight: true,
            items: [MarkdownListItem(blocks: [.paragraph([.text("i")])])]
        )
        let rendered = body(.unorderedList(
            isTight: false,
            items: [MarkdownListItem(blocks: [.paragraph([.text("o")]), inner])]
        ))
        XCTAssertEqual(rendered.components(separatedBy: "class=\"loose\"").count - 1, 1)
        XCTAssertTrue(rendered.hasPrefix("<ul class=\"loose\">"), rendered)
        XCTAssertTrue(rendered.contains("<ul><li><p>i</p></li></ul>"), rendered)
    }

    /// A nested list is a block inside its item, rendered by the same code — and
    /// its checkboxes survive the nesting.
    func testNestedListWithCheckboxes() {
        let rendered = body(.unorderedList(isTight: true, items: [
            MarkdownListItem(checkbox: .checked, blocks: [
                .paragraph([.text("outer")]),
                .unorderedList(isTight: true, items: [MarkdownListItem(checkbox: .unchecked, blocks: [.paragraph([.text("inner")])])]),
            ]),
        ]))
        XCTAssertTrue(rendered.contains("<input type=\"checkbox\" disabled checked><p>outer</p>"), rendered)
        XCTAssertTrue(rendered.contains("<ul><li class=\"task-list-item\"><input type=\"checkbox\" disabled><p>inner</p>"), rendered)
    }

    // MARK: - Tables

    /// Per-column alignment, in column order; an unaligned column emits nothing.
    func testTableAlignmentAttributes() {
        let rendered = body(.table(
            alignments: [.none, .left, .center, .right],
            header: MarkdownTableRow(cells: [[.text("a")], [.text("b")], [.text("c")], [.text("d")]]),
            body: [MarkdownTableRow(cells: [[.text("1")], [.text("2")], [.text("3")], [.text("4")]])]
        ))
        XCTAssertEqual(rendered, """
            <table><thead><tr><th>a</th><th style="text-align: left">b</th>\
            <th style="text-align: center">c</th><th style="text-align: right">d</th></tr></thead>\
            <tbody><tr><td>1</td><td style="text-align: left">2</td>\
            <td style="text-align: center">3</td><td style="text-align: right">4</td></tr></tbody></table>
            """)
    }

    /// A row shorter or longer than the alignment list is emitted as it is:
    /// nothing pads and nothing truncates, and a cell past the last stated
    /// alignment is unaligned rather than a crash.
    func testTableRowsAreNeitherPaddedNorTruncated() {
        let rendered = body(.table(
            alignments: [.right],
            header: MarkdownTableRow(cells: [[.text("h")]]),
            body: [
                MarkdownTableRow(cells: []),
                MarkdownTableRow(cells: [[.text("1")], [.text("2")]]),
            ]
        ))
        XCTAssertTrue(rendered.contains("<tbody><tr></tr>"), rendered)
        XCTAssertTrue(rendered.contains("<tr><td style=\"text-align: right\">1</td><td>2</td></tr>"), rendered)
    }

    // MARK: - The remaining blocks and inlines

    func testBlockQuoteAndThematicBreak() {
        XCTAssertEqual(
            body(.blockQuote([.paragraph([.text("a")]), .paragraph([.text("b")])])),
            "<blockquote><p>a</p>\n<p>b</p></blockquote>"
        )
        XCTAssertEqual(body(.thematicBreak), "<hr>")
    }

    /// Heading levels 1…6 pass through; anything outside is clamped, because
    /// HTML has no seventh heading.
    func testHeadingLevelsAreClamped() {
        for level in 1...6 {
            XCTAssertEqual(
                body(.heading(level: level, children: [.text("t")])),
                "<h\(level) id=\"t\">t</h\(level)>"
            )
        }
        XCTAssertEqual(body(.heading(level: 9, children: [.text("t")])), "<h6 id=\"t\">t</h6>")
        XCTAssertEqual(body(.heading(level: 0, children: [.text("t")])), "<h1 id=\"t\">t</h1>")
    }

    // MARK: - Heading anchors

    /// Every level carries its `id`, ahead of the `data-line` a top-level block
    /// also gets. The rule itself is `MarkdownHeadingSlugTests`; what is
    /// asserted here is that the renderer asks it and where the answer lands.
    func testHeadingsCarryTheirAnchor() {
        for level in 1...6 {
            XCTAssertEqual(
                body(.heading(level: level, children: [.text("A Heading!")]), line: 3),
                "<h\(level) id=\"a-heading\" data-line=\"3\">A Heading!</h\(level)>"
            )
        }
    }

    /// The anchor is named after the heading's *words*, the same flattening an
    /// image's `alt` gets: markup inside a heading is how it is drawn, never
    /// part of what a link to it spells.
    func testAnAnchorIsNamedAfterTheFlattenedText() {
        XCTAssertEqual(
            body(.heading(level: 2, children: [.text("The "), .strong([.text("one")]), .code("rule")])),
            "<h2 id=\"the-onerule\">The <strong>one</strong><code>rule</code></h2>"
        )
    }

    /// A heading whose only child is an image slugs that image's alt text —
    /// `plainText(_:)` reaching through the image the same way it reaches
    /// through an emphasis.
    func testAHeadingOfAnImageAloneSlugsItsAltText() {
        let rendered = body(.heading(level: 1, children: [
            .image(source: nil, title: nil, children: [.text("The Logo")]),
        ]))
        XCTAssertEqual(rendered, "<h1 id=\"the-logo\"><img alt=\"The Logo\"></h1>")
    }

    /// A heading the slug rule leaves unnamed carries no `id` at all — not
    /// `id=""`, which is a target a reader would take for one.
    func testAHeadingWithNothingNameableCarriesNoAnchor() {
        XCTAssertEqual(body(.heading(level: 2, children: [.text("!?")])), "<h2>!?</h2>")
        XCTAssertEqual(body(.heading(level: 2, children: []), line: 4), "<h2 data-line=\"4\"></h2>")
    }

    /// Repeats are numbered in the order the *walk* reaches them, which is
    /// document order.
    func testRepeatedHeadingsAreNumberedInDocumentOrder() {
        let rendered = body([
            MarkdownTopLevelBlock(block: .heading(level: 1, children: [.text("Notes")]), sourceLine: nil),
            MarkdownTopLevelBlock(block: .heading(level: 2, children: [.text("notes")]), sourceLine: nil),
            MarkdownTopLevelBlock(block: .heading(level: 3, children: [.text("NOTES")]), sourceLine: nil),
        ])
        XCTAssertEqual(rendered, """
            <h1 id="notes">Notes</h1>
            <h2 id="notes-1">notes</h2>
            <h3 id="notes-2">NOTES</h3>
            """)
    }

    /// A heading nested in a blockquote or a list item is a heading: it gets an
    /// `id` on the same terms, numbered where it sits rather than after every
    /// top-level one. The allocator travels the whole walk, which is the only
    /// way the second `Notes` here can be `notes-1` and the third `notes-2`.
    func testNestedHeadingsCarryAnchorsInWalkOrder() {
        let rendered = body([
            MarkdownTopLevelBlock(block: .heading(level: 1, children: [.text("Notes")]), sourceLine: nil),
            MarkdownTopLevelBlock(
                block: .blockQuote([.heading(level: 2, children: [.text("Notes")])]),
                sourceLine: nil
            ),
            MarkdownTopLevelBlock(
                block: .unorderedList(isTight: true, items: [
                    MarkdownListItem(blocks: [.heading(level: 3, children: [.text("Notes")])]),
                ]),
                sourceLine: nil
            ),
        ])
        XCTAssertEqual(rendered, """
            <h1 id="notes">Notes</h1>
            <blockquote><h2 id="notes-1">Notes</h2></blockquote>
            <ul><li><h3 id="notes-2">Notes</h3></li></ul>
            """)
    }

    /// The same tree rendered twice is the same markup: the allocator is a value
    /// created per render, not state that survives one.
    func testRenderingTheSameDocumentTwiceProducesTheSameAnchors() {
        let blocks = [
            MarkdownTopLevelBlock(block: .heading(level: 1, children: [.text("Notes")]), sourceLine: nil),
            MarkdownTopLevelBlock(block: .heading(level: 1, children: [.text("Notes")]), sourceLine: nil),
        ]
        XCTAssertEqual(body(blocks), body(blocks))
    }

    /// Nothing but a heading gains an `id`.
    func testNoOtherBlockGainsAnAnchor() {
        let cases: [MarkdownBlock] = [
            .paragraph([.text("p")]),
            .codeBlock(language: "swift", code: "c"),
            .blockQuote([.paragraph([.text("q")])]),
            .unorderedList(isTight: true, items: [MarkdownListItem(blocks: [.paragraph([.text("i")])])]),
            .orderedList(start: 1, isTight: true, items: [MarkdownListItem(blocks: [.paragraph([.text("i")])])]),
            .table(alignments: [.none], header: MarkdownTableRow(cells: [[.text("h")]]), body: []),
            .thematicBreak,
        ]
        for block in cases {
            XCTAssertFalse(body(block, line: 7).contains(" id=\""), "\(block)")
        }
    }

    func testInlineKinds() {
        let rendered = body(.paragraph([
            .emphasis([.text("e")]),
            .strong([.text("s")]),
            .strikethrough([.text("d")]),
            .autolink(destination: "https://e.com/a&b"),
            .lineBreak,
            .text("x"),
            .softBreak,
            .text("y"),
        ]))
        XCTAssertEqual(rendered, """
            <p><em>e</em><strong>s</strong><del>d</del>\
            <a href="https://e.com/a&amp;b">https://e.com/a&amp;b</a><br>x\ny</p>
            """)
    }

    /// A link the source left without a destination is an `<a>` with no `href`
    /// — not `href=""`, which would reload the shell when clicked.
    func testLinkWithoutDestinationEmitsNoHref() {
        XCTAssertEqual(body(.paragraph([.link(destination: nil, title: nil, children: [.text("x")])])), "<p><a>x</a></p>")
        XCTAssertEqual(body(.paragraph([.image(source: nil, title: nil, children: [])])), "<p><img alt=\"\"></p>")
    }

    // MARK: - Raw HTML

    /// A document whose source carried raw HTML renders **nothing** for it.
    ///
    /// There is no case to assert against directly, which is the point: the tree
    /// has nowhere to put an HTML block or an inline span, so the parser drops
    /// them by having no target and the renderer cannot interpolate what it was
    /// never handed. What this test pins is the consequence — the two paragraphs
    /// that surrounded a `<div>` in the source render as themselves, with no
    /// element between them and no escaped remnant of one.
    func testRawHtmlFromTheSourceProducesNothing() {
        // `# A` / `<div onclick="x">boom</div>` / `B <b>c</b>` as the parser maps
        // it: the heading, then a paragraph whose only inline is the text
        // outside the span.
        let rendered = body([
            MarkdownTopLevelBlock(block: .heading(level: 1, children: [.text("A")]), sourceLine: 1),
            MarkdownTopLevelBlock(block: .paragraph([.text("B ")]), sourceLine: 5),
        ])
        XCTAssertEqual(rendered, "<h1 id=\"a\" data-line=\"1\">A</h1>\n<p data-line=\"5\">B </p>")
        XCTAssertFalse(rendered.contains("div"))
        XCTAssertFalse(rendered.contains("onclick"))
        XCTAssertFalse(rendered.contains("<b>"))
    }

    // MARK: - Asset targets

    /// A relative image inside the project root is emitted as an app-scheme URL
    /// carrying the file's project-relative path.
    func testRelativeImageInsideTheRootBecomesAnAppSchemeURL() {
        let rendered = body(.paragraph([.image(source: "img/a.png", title: nil, children: [.text("alt")])]), projectContext)
        XCTAssertEqual(
            rendered,
            "<p><img src=\"pisaka-preview://preview/file/docs/img/a.png\" alt=\"alt\"></p>"
        )
    }

    /// A relative link that climbs *within* the root resolves too — resolution
    /// is about reach, not about spelling.
    func testRelativeLinkClimbingInsideTheRootResolves() {
        let rendered = body(.paragraph([
            .link(destination: "../README.md", title: nil, children: [.text("readme")]),
        ]), projectContext)
        XCTAssertEqual(
            rendered,
            "<p><a href=\"pisaka-preview://preview/file/README.md\">readme</a></p>"
        )
    }

    /// A target outside the root is emitted **unresolved** — which renders as a
    /// broken image with its alt text and, for a link, as a target the
    /// navigation rule refuses.
    ///
    /// A target carrying a scheme keeps its own spelling; a scheme-less one is
    /// carried under the reserved prefix, since the page would otherwise resolve
    /// it against the shell's URL (see the round trip below).
    func testTargetOutsideTheRootIsEmittedUnresolved() {
        for target in ["../../etc/passwd", "/etc/passwd"] {
            let rendered = body(.paragraph([.image(source: target, title: nil, children: [.text("alt")])]), projectContext)
            XCTAssertEqual(
                rendered,
                "<p><img src=\"\(MarkdownRenderer.escaped(MarkdownPreviewAsset.unresolvedTarget(target)))\" alt=\"alt\"></p>",
                target
            )
            XCTAssertTrue(rendered.contains(MarkdownPreviewPage.unresolvedPathPrefix), target)
        }
        let rendered = body(
            .paragraph([.image(source: "file:///etc/passwd", title: nil, children: [.text("alt")])]),
            projectContext
        )
        XCTAssertEqual(rendered, "<p><img src=\"file:///etc/passwd\" alt=\"alt\"></p>")
    }

    /// The refusal survives the page's base URL, which is the whole reason the
    /// reserved prefix exists.
    ///
    /// A refused *scheme-less* spelling left verbatim would be re-resolved by
    /// the web view against ``MarkdownPreviewPage/shellURL``; any spelling
    /// normalizing under the project-file prefix would then name a **different**
    /// in-project file — a wrong image, and a wrong file opened in the editor.
    /// Containment never broke; the answer was simply not the one the forward
    /// direction gave. So the emitted attribute is resolved the way the page
    /// would resolve it, and the inverse must still refuse it.
    func testARefusedRelativeTargetCannotReEnterTheServedNamespace() throws {
        let context = MarkdownDocumentContext(
            documentURL: URL(fileURLWithPath: "/p/root/a.md"),
            projectRoot: URL(fileURLWithPath: "/p/root")
        )
        let escapes = [
            "../file/logo.png",       // would have named /p/root/logo.png
            "../assets/preview.css",  // would have named a bundled file
            "../index.html",          // would have named the shell itself
            "../file/../file/x.png",
        ]
        for target in escapes {
            XCTAssertNil(
                MarkdownPreviewAsset.assetURL(forTarget: target, context: context),
                "\(target) is refused by the forward direction"
            )
            let emitted = MarkdownPreviewAsset.unresolvedTarget(target)
            let url = try XCTUnwrap(
                URL(string: emitted, relativeTo: MarkdownPreviewPage.shellURL)?.absoluteURL,
                target
            )
            XCTAssertEqual(
                MarkdownPreviewAsset.classify(url, context: context),
                .refused,
                "\(target) must stay refused after the page resolves it"
            )
            XCTAssertEqual(
                MarkdownLinkRule.decision(for: url, context: context),
                .refused,
                "\(target) must open nothing"
            )
        }
    }

    /// An `http`/`https`/`mailto` target is left exactly as the source spelled
    /// it, and never rewritten into the app scheme.
    func testNetworkTargetsAreLeftAlone() {
        for target in ["https://e.com/a", "http://e.com/a", "mailto:a@e.com"] {
            let rendered = body(.paragraph([.link(destination: target, title: nil, children: [.text("t")])]), projectContext)
            XCTAssertEqual(rendered, "<p><a href=\"\(target)\">t</a></p>", target)
            XCTAssertFalse(rendered.contains(MarkdownPreviewPage.scheme), target)
        }
    }

    /// A fragment addresses this page, not a file: emitted as spelled, for the
    /// navigation rule to read as an anchor.
    func testFragmentTargetIsLeftAlone() {
        XCTAssertEqual(
            body(.paragraph([.link(destination: "#section", title: nil, children: [.text("t")])]), projectContext),
            "<p><a href=\"#section\">t</a></p>"
        )
    }

    /// With no document URL there is no base to resolve against, so a relative
    /// target is unresolved — an unsaved buffer's images are broken, honestly.
    ///
    /// Under the reserved prefix rather than verbatim, because *every* relative
    /// target is refused in this context: `file/x.png` left as spelled would be
    /// resolved by the page into the served project-file namespace, which is the
    /// one shape where "broken, honestly" would have been false.
    func testRelativeTargetWithoutADocumentURLIsUnresolved() {
        let context = MarkdownDocumentContext(documentURL: nil, projectRoot: URL(fileURLWithPath: "/p/root"))
        XCTAssertEqual(
            body(.paragraph([.image(source: "img/a.png", title: nil, children: [])]), context),
            "<p><img src=\"\(MarkdownPreviewAsset.unresolvedTarget("img/a.png"))\" alt=\"\"></p>"
        )
        let served = body(.paragraph([.image(source: "file/x.png", title: nil, children: [])]), context)
        XCTAssertFalse(served.contains(MarkdownPreviewPage.filePathPrefix + "x.png"))
    }

    /// With no project root there is nothing to be inside of.
    func testRelativeTargetWithoutAProjectRootIsUnresolved() {
        let context = MarkdownDocumentContext(
            documentURL: URL(fileURLWithPath: "/p/root/docs/guide.md"),
            projectRoot: nil
        )
        XCTAssertEqual(
            body(.paragraph([.image(source: "img/a.png", title: nil, children: [])]), context),
            "<p><img src=\"\(MarkdownPreviewAsset.unresolvedTarget("img/a.png"))\" alt=\"\"></p>"
        )
    }

    /// A percent-encoded target and a literal-space one name the same file and
    /// resolve to the same, once-encoded, app-scheme URL.
    func testPercentEncodingRoundTripsOnce() {
        for target in ["img/a%20b.png", "img/a b.png"] {
            let rendered = body(.paragraph([.image(source: target, title: nil, children: [])]), projectContext)
            XCTAssertEqual(
                rendered,
                "<p><img src=\"pisaka-preview://preview/file/docs/img/a%20b.png\" alt=\"\"></p>",
                target
            )
        }
    }
}
