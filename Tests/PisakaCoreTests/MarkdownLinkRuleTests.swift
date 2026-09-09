import XCTest
@testable import PisakaCore

/// What a click in the preview does.
///
/// The rule is asked about the URL the *web view* resolved, not about the string
/// the Markdown source carried, so the suite's central case is the round trip:
/// render a real link through `MarkdownRenderer`, take the `href` that landed in
/// the page, and assert the rule turns it back into the file the source named.
/// Anything asserted against a hand-written app-scheme URL is asserting the
/// rule; that one case asserts that the renderer and the rule are two halves of
/// the same mapping.
final class MarkdownLinkRuleTests: XCTestCase {

    // MARK: - Fixtures

    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private let context = MarkdownDocumentContext(
        documentURL: URL(fileURLWithPath: "/p/root/docs/guide.md"),
        projectRoot: URL(fileURLWithPath: "/p/root")
    )

    private func decision(_ string: String, _ context: MarkdownDocumentContext) throws
        -> MarkdownLinkDecision {
        MarkdownLinkRule.decision(for: try XCTUnwrap(URL(string: string)), context: context)
    }

    /// The same, under the fixed project context above.
    private func decision(_ string: String) throws -> MarkdownLinkDecision {
        try decision(string, context)
    }

    /// The one `href` in `html`, unescaped enough for a URL (the renderer
    /// escapes `&`, which no app-scheme URL it composes contains).
    private func href(in html: String) throws -> String {
        let pattern = try NSRegularExpression(pattern: "href=\"([^\"]*)\"")
        let range = NSRange(html.startIndex..., in: html)
        let match = try XCTUnwrap(pattern.firstMatch(in: html, range: range))
        let captured = try XCTUnwrap(Range(match.range(at: 1), in: html))
        return String(html[captured])
    }

    // MARK: - The round trip

    func testARenderedLinkToAProjectFileOpensThatFile() throws {
        let dir = try makeTempDirectory()
        let root = dir.appendingPathComponent("root")
        let target = root.appendingPathComponent("docs/notes.md")
        try write("# Notes", to: target)
        try write("# Guide", to: root.appendingPathComponent("docs/guide.md"))

        let context = MarkdownDocumentContext(
            documentURL: root.appendingPathComponent("docs/guide.md"),
            projectRoot: root
        )
        let document = MarkdownDocument(blocks: [
            MarkdownTopLevelBlock(
                block: .paragraph([
                    .link(destination: "notes.md", title: nil, children: [.text("Notes")]),
                ]),
                sourceLine: 1
            ),
        ])

        let emitted = try href(in: MarkdownRenderer.body(for: document, context: context))
        let navigation = try XCTUnwrap(URL(string: emitted))

        guard case .openInEditor(let fileURL) = MarkdownLinkRule.decision(for: navigation, context: context)
        else { return XCTFail("expected the rendered link to open the file it named") }
        XCTAssertEqual(CanonicalPath.canonical(fileURL), CanonicalPath.canonical(target))
    }

    func testARenderedLinkWithASpaceInItsNameRoundTrips() throws {
        let dir = try makeTempDirectory()
        let root = dir.appendingPathComponent("root")
        let target = root.appendingPathComponent("my notes.md")
        try write("# Notes", to: target)
        try write("# Guide", to: root.appendingPathComponent("guide.md"))

        let context = MarkdownDocumentContext(
            documentURL: root.appendingPathComponent("guide.md"),
            projectRoot: root
        )
        let document = MarkdownDocument(blocks: [
            MarkdownTopLevelBlock(
                block: .paragraph([
                    .link(destination: "my%20notes.md", title: nil, children: [.text("Notes")]),
                ]),
                sourceLine: 1
            ),
        ])

        let emitted = try href(in: MarkdownRenderer.body(for: document, context: context))
        let navigation = try XCTUnwrap(URL(string: emitted))

        guard case .openInEditor(let fileURL) = MarkdownLinkRule.decision(for: navigation, context: context)
        else { return XCTFail("expected a percent-encoded name to round-trip") }
        XCTAssertEqual(CanonicalPath.canonical(fileURL), CanonicalPath.canonical(target))
    }

    /// A link to another document *and a place inside it* opens that document.
    ///
    /// The whole round trip, because this is where the two halves could disagree
    /// without either looking wrong on its own: the renderer must drop the
    /// anchor when it composes the URL, and the rule must then read that URL as
    /// a file rather than as an anchor on this page.
    func testARenderedLinkCarryingAnAnchorOpensTheFileItNames() throws {
        let dir = try makeTempDirectory()
        let root = dir.appendingPathComponent("root")
        let target = root.appendingPathComponent("docs/notes.md")
        try write("# Notes", to: target)
        try write("# Guide", to: root.appendingPathComponent("docs/guide.md"))

        let context = MarkdownDocumentContext(
            documentURL: root.appendingPathComponent("docs/guide.md"),
            projectRoot: root
        )
        let document = MarkdownDocument(blocks: [
            MarkdownTopLevelBlock(
                block: .paragraph([
                    .link(destination: "notes.md#the-rule", title: nil, children: [.text("Notes")]),
                ]),
                sourceLine: 1
            ),
        ])

        let emitted = try href(in: MarkdownRenderer.body(for: document, context: context))
        let navigation = try XCTUnwrap(URL(string: emitted))

        guard case .openInEditor(let fileURL) = MarkdownLinkRule.decision(for: navigation, context: context)
        else { return XCTFail("expected a link with an anchor to open the file it named") }
        XCTAssertEqual(CanonicalPath.canonical(fileURL), CanonicalPath.canonical(target))
    }

    // MARK: - The round trip: a heading and a link to it

    /// Every `href` in `html`, in document order.
    private func hrefs(in html: String) throws -> [String] {
        try values(of: "href", in: html)
    }

    /// Every `id` in `html`, in document order.
    private func ids(in html: String) throws -> [String] {
        try values(of: "id", in: html)
    }

    private func values(of name: String, in html: String) throws -> [String] {
        let pattern = try NSRegularExpression(pattern: "\\b\(name)=\"([^\"]*)\"")
        let range = NSRange(html.startIndex..., in: html)
        return try pattern.matches(in: html, range: range).map { match in
            let captured = try XCTUnwrap(Range(match.range(at: 1), in: html))
            return String(html[captured])
        }
    }

    /// What the *web view* does with an `href`: resolve it against the one URL
    /// the page was ever loaded from.
    private func navigationURL(for href: String) throws -> URL {
        try XCTUnwrap(URL(string: href, relativeTo: MarkdownPreviewPage.shellURL)).absoluteURL
    }

    /// A document whose body is `## <heading>` followed by `[x](#<link>)`, for
    /// each pair given, rendered in that order.
    private func document(headingsAndLinks pairs: [(String, String)]) -> MarkdownDocument {
        MarkdownDocument(blocks: pairs.flatMap { heading, link in
            [
                MarkdownTopLevelBlock(block: .heading(level: 2, children: [.text(heading)]), sourceLine: nil),
                MarkdownTopLevelBlock(
                    block: .paragraph([.link(destination: "#\(link)", title: nil, children: [.text("x")])]),
                    sourceLine: nil
                ),
            ]
        })
    }

    /// A link an author spelled by hand reaches the heading it names.
    ///
    /// The whole round trip in one assertion, and the only place the two halves
    /// meet: `MarkdownHeadingSlug` decides what the `id` is, the renderer emits
    /// both it and the `href`, the web view resolves the fragment-only spelling
    /// against the shell, and `MarkdownLinkRule` reads it back. Either half
    /// changing its idea of what a slug is fails here — nothing else in the
    /// pipeline compares the two.
    func testAFragmentLinkReachesTheHeadingItNames() throws {
        let rendered = MarkdownRenderer.body(
            for: document(headingsAndLinks: [("A Heading", "a-heading"), ("What’s new?", "whats-new")]),
            context: context
        )

        let ids = try ids(in: rendered)
        XCTAssertEqual(ids, ["a-heading", "whats-new"])

        for (index, href) in try hrefs(in: rendered).enumerated() {
            let decision = MarkdownLinkRule.decision(for: try navigationURL(for: href), context: context)
            XCTAssertEqual(decision, .anchor(ids[index]), href)
        }
    }

    /// The duplicate case: two headings that slug alike, and the second link
    /// reaching the second heading rather than the first.
    ///
    /// This is what the allocator is *for*, and it is invisible from either side
    /// alone — the ids are distinct in the markup and the fragments are distinct
    /// in the URLs, and only pairing them says the second link lands on the
    /// second heading.
    func testTheSecondOfTwoIdenticalHeadingsIsReachedByItsOwnLink() throws {
        let rendered = MarkdownRenderer.body(
            for: document(headingsAndLinks: [("Notes", "notes"), ("Notes", "notes-1")]),
            context: context
        )

        let ids = try ids(in: rendered)
        XCTAssertEqual(ids, ["notes", "notes-1"])

        let hrefs = try hrefs(in: rendered)
        XCTAssertEqual(hrefs, ["#notes", "#notes-1"])
        XCTAssertEqual(
            MarkdownLinkRule.decision(for: try navigationURL(for: hrefs[1]), context: context),
            .anchor("notes-1")
        )
    }

    /// A non-English heading, which is the case the encoding decides.
    ///
    /// The `id` in the markup is the slug's own characters; the URL the web view
    /// resolves the `href` to carries them percent-encoded. Reading the fragment
    /// as the URL spells it would hand the page `%D0%BF…`, `getElementById`
    /// would find nothing, and every anchor in a Russian, Greek or German
    /// document would be silently dead. An ASCII slug encodes to itself, so the
    /// two cases above cannot see this at all.
    func testANonASCIIHeadingIsReachedByItsOwnLink() throws {
        let rendered = MarkdownRenderer.body(
            for: document(headingsAndLinks: [("Привет мир", "привет-мир"), ("Größe", "größe")]),
            context: context
        )

        let ids = try ids(in: rendered)
        XCTAssertEqual(ids, ["привет-мир", "größe"])

        for (index, href) in try hrefs(in: rendered).enumerated() {
            let url = try navigationURL(for: href)
            XCTAssertNotEqual(url.absoluteString, href, "the web view is expected to encode \(href)")
            XCTAssertEqual(MarkdownLinkRule.decision(for: url, context: context), .anchor(ids[index]), href)
        }
    }

    /// An underscored heading, which is the case the character class decides:
    /// GFM keeps `_`, so an anchor an author copied from a rendered README has
    /// to land here too.
    func testAnUnderscoredHeadingIsReachedByItsOwnLink() throws {
        let rendered = MarkdownRenderer.body(
            for: document(headingsAndLinks: [("snake_case", "snake_case")]),
            context: context
        )

        XCTAssertEqual(try ids(in: rendered), ["snake_case"])
        let href = try XCTUnwrap(try hrefs(in: rendered).first)
        XCTAssertEqual(
            MarkdownLinkRule.decision(for: try navigationURL(for: href), context: context),
            .anchor("snake_case")
        )
    }

    /// A heading named after the shell's own container does not take its id.
    ///
    /// `getElementById` answers the *first* element in document order, and the
    /// container is the heading's ancestor: sharing the id would scroll the page
    /// to the top of the container rather than to the heading, which is the same
    /// silent wrong-target the suffixing exists to prevent.
    func testAHeadingNamedAfterTheContainerDoesNotTakeItsID() throws {
        let rendered = MarkdownRenderer.body(
            for: document(headingsAndLinks: [(MarkdownPreviewPage.containerElementID, "content-1")]),
            context: context
        )

        XCTAssertEqual(try ids(in: rendered), ["content-1"])
        let href = try XCTUnwrap(try hrefs(in: rendered).first)
        XCTAssertEqual(
            MarkdownLinkRule.decision(for: try navigationURL(for: href), context: context),
            .anchor("content-1")
        )
    }

    /// A fragment naming a heading the document does not have still resolves to
    /// an anchor — the page's own lookup is what finds nothing, and the rule has
    /// no business knowing which ids exist.
    func testAFragmentNamingNoHeadingIsStillAnAnchor() throws {
        let rendered = MarkdownRenderer.body(
            for: document(headingsAndLinks: [("A Heading", "not-here")]),
            context: context
        )
        let href = try XCTUnwrap(try hrefs(in: rendered).first)
        XCTAssertEqual(
            MarkdownLinkRule.decision(for: try navigationURL(for: href), context: context),
            .anchor("not-here")
        )
    }

    // MARK: - External

    func testTheThreeExternalSchemesLeaveTheApp() throws {
        for string in [
            "https://example.com/page",
            "http://example.com/page",
            "mailto:someone@example.com",
        ] {
            XCTAssertEqual(
                try decision(string),
                .external(try XCTUnwrap(URL(string: string))),
                "\(string) must open externally"
            )
        }
    }

    func testASchemeIsMatchedRegardlessOfCase() throws {
        XCTAssertEqual(
            try decision("HTTPS://example.com/page"),
            .external(try XCTUnwrap(URL(string: "HTTPS://example.com/page")))
        )
    }

    // MARK: - Anchors

    func testAFragmentOnTheShellIsAnAnchor() throws {
        XCTAssertEqual(try decision("pisaka-preview://preview/index.html#a-heading"), .anchor("a-heading"))
    }

    func testTheShellWithoutAFragmentIsRefused() throws {
        // A navigation to the page itself is a reload, and the page is installed
        // once: nothing may reload it out from under the body it is holding.
        XCTAssertEqual(try decision("pisaka-preview://preview/index.html"), .refused)
    }

    // MARK: - Refused

    func testActiveAndInliningSchemesAreRefused() throws {
        for string in [
            "javascript:alert(1)",
            "data:text/html;base64,AAAA",
            "file:///etc/passwd",
            "file:///p/root/docs/notes.md",
            "about:blank",
            "ftp://example.com/f",
        ] {
            XCTAssertEqual(try decision(string), .refused, "\(string) must be refused")
        }
    }

    func testAnAppSchemeURLTheInverseRejectsIsRefused() throws {
        for string in [
            "pisaka-preview://preview/file/../../etc/passwd",
            "pisaka-preview://elsewhere/file/notes.md",
            "pisaka-preview://preview/assets/preview.js",
            "pisaka-preview://preview/file/",
        ] {
            XCTAssertEqual(try decision(string), .refused, "\(string) must be refused")
        }
    }

    func testAProjectFileIsRefusedWithNoProjectRoot() throws {
        XCTAssertEqual(
            try decision("pisaka-preview://preview/file/docs/notes.md", MarkdownDocumentContext.none),
            .refused
        )
    }

    func testASymlinkOutOfTheRootIsRefusedRatherThanOpened() throws {
        let dir = try makeTempDirectory()
        let root = dir.appendingPathComponent("root")
        let outside = dir.appendingPathComponent("outside")
        try write("secret", to: outside.appendingPathComponent("secret.md"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("escape"),
            withDestinationURL: outside
        )

        let context = MarkdownDocumentContext(documentURL: nil, projectRoot: root)
        XCTAssertEqual(
            try decision("pisaka-preview://preview/file/escape/secret.md", context),
            .refused
        )
    }

    func testAFileReachedThroughASymlinkedAncestorIsOpened() throws {
        let dir = try makeTempDirectory()
        let root = dir.appendingPathComponent("root")
        let target = root.appendingPathComponent("real/notes.md")
        try write("# Notes", to: target)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link"),
            withDestinationURL: root.appendingPathComponent("real")
        )

        let context = MarkdownDocumentContext(documentURL: nil, projectRoot: root)
        guard case .openInEditor(let fileURL) = try decision(
            "pisaka-preview://preview/file/link/notes.md",
            context
        ) else { return XCTFail("a file inside the root must open, however it is reached") }
        XCTAssertEqual(CanonicalPath.canonical(fileURL), CanonicalPath.canonical(target))
    }
}
