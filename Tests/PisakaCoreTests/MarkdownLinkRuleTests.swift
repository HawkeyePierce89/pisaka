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
