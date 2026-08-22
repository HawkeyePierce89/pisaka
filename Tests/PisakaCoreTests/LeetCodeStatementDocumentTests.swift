import XCTest
@testable import PisakaCore

/// The panel renders whatever this type composes, and the panel itself is a web
/// view with no tests — so everything that could go wrong with the document has
/// to be asserted here.
///
/// Three things are actually at stake. The fragment must survive **verbatim**
/// (LeetCode's markup is the statement; a wrapper that mangled it would show a
/// broken problem). The pieces that make a fragment render *as a page* must be
/// present — charset, viewport, and the `<base href>` without which every image
/// in every statement is a broken icon. And the theme must genuinely reach the
/// CSS, which is asserted by requiring light and dark to differ rather than by
/// pinning colour values nobody should have to update to restyle the panel.
///
/// The cache half is the offline story: a fragment stored today is what a person
/// on a plane reads tomorrow, and every way the file can be missing, unreadable
/// or blank has to read as "not cached" rather than as an empty statement.
final class LeetCodeStatementDocumentTests: XCTestCase {

    // MARK: - Harness

    /// A fragment with the things a real statement has: markup, an entity, a
    /// relative image, a `<pre>` block and non-ASCII text.
    private let fragment = """
        <p>Given an array <code>nums</code> &amp; a target, return indices.</p>
        <img src="/uploads/2021/01/example.png" />
        <pre>Input: nums = [2,7,11,15]
        Output: [0,1]</pre>
        <p>Пример — 例</p>
        """

    private let treeRoot = URL(fileURLWithPath: "/leetcode-statement-tests")
    private var cacheBase: URL { treeRoot.appendingPathComponent("cache") }
    private let statementPath = "cache/Statements/two-sum.html"

    private func makeCache(_ tree: StubFileTree) -> LeetCodeStatementCache {
        LeetCodeStatementCache(
            layout: LeetCodeCacheLayout(base: cacheBase),
            fileService: tree
        )
    }

    private func document(
        theme: LeetCodeStatementDocument.Theme = .light,
        fontSize: Double = 13,
        title: String = "Two Sum"
    ) -> String {
        LeetCodeStatementDocument.html(
            fragment: fragment,
            title: title,
            theme: theme,
            fontSize: fontSize
        )
    }

    // MARK: - The document

    func testWrapperCarriesTheFragmentVerbatim() {
        XCTAssertTrue(
            document().contains(fragment),
            "the statement is LeetCode's markup; the wrapper may surround it but never rewrite it"
        )
    }

    func testDocumentHasTheStructuralPiecesAFragmentLacks() {
        let html = document()
        XCTAssertTrue(html.hasPrefix("<!DOCTYPE html>"))
        XCTAssertTrue(html.contains("<meta charset=\"utf-8\">"))
        XCTAssertTrue(html.contains("<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"))
        XCTAssertTrue(html.contains("<style>"))
        XCTAssertTrue(html.hasSuffix("</html>"))
    }

    /// Without this, every `<img src="/uploads/…">` in every statement — and
    /// LeetCode puts them in a great many — resolves against the web view's own
    /// (absent) base and renders as a broken image.
    func testBaseHrefIsTheSiteRoot() {
        XCTAssertTrue(document().contains("<base href=\"https://leetcode.com/\">"))
        XCTAssertEqual(LeetCodeAPI.siteURL.absoluteString, "https://leetcode.com/")
    }

    func testTitleIsEscaped() {
        let html = document(title: "A <b>\"tricky\" & odd</b> title")
        XCTAssertTrue(html.contains("<title>A &lt;b&gt;&quot;tricky&quot; &amp; odd&lt;/b&gt; title</title>"))
        // The escaping introduces ampersands of its own; escaping them again
        // would print `&amp;lt;` in the window title.
        XCTAssertFalse(html.contains("&amp;lt;"))
    }

    func testLightAndDarkProduceDifferentDocuments() {
        let light = document(theme: .light)
        let dark = document(theme: .dark)
        XCTAssertNotEqual(light, dark)
        XCTAssertTrue(light.contains("color-scheme: light;"))
        XCTAssertTrue(dark.contains("color-scheme: dark;"))
        XCTAssertTrue(light.contains(LeetCodeStatementDocument.Theme.light.background))
        XCTAssertTrue(dark.contains(LeetCodeStatementDocument.Theme.dark.background))
        XCTAssertFalse(dark.contains(LeetCodeStatementDocument.Theme.light.background))
    }

    /// Every colour on the theme has to actually reach the stylesheet — a field
    /// that is declared and never interpolated is a restyle that silently does
    /// nothing.
    func testEveryThemeColourReachesTheStylesheet() {
        let theme = LeetCodeStatementDocument.Theme(
            background: "#010203",
            text: "#040506",
            secondaryText: "#070809",
            link: "#0a0b0c",
            codeBackground: "#0d0e0f",
            border: "#101112",
            colorScheme: "dark"
        )
        let html = document(theme: theme)
        for colour in [
            theme.background, theme.text, theme.secondaryText,
            theme.link, theme.codeBackground, theme.border,
        ] {
            XCTAssertTrue(html.contains(colour), "\(colour) never reaches the CSS")
        }
    }

    func testThemeResolutionFollowsThePreference() {
        XCTAssertEqual(
            LeetCodeStatementDocument.Theme.resolved(.light, systemPrefersDark: true),
            .light
        )
        XCTAssertEqual(
            LeetCodeStatementDocument.Theme.resolved(.dark, systemPrefersDark: false),
            .dark
        )
        XCTAssertEqual(
            LeetCodeStatementDocument.Theme.resolved(.system, systemPrefersDark: true),
            .dark
        )
        XCTAssertEqual(
            LeetCodeStatementDocument.Theme.resolved(.system, systemPrefersDark: false),
            .light
        )
    }

    func testFontSizeIsTheEditorsAndIsEmittedWithoutATrailingZero() {
        let html = document(fontSize: 18)
        XCTAssertTrue(html.contains("font-size: 18px;"))
        XCTAssertFalse(html.contains("18.0px"))
    }

    func testFontSizeSurvivesAbsurdValues() {
        // An unparsable `font-size` drops the whole declaration, so a NaN or an
        // out-of-range value must be clamped before it reaches the CSS rather
        // than after somebody notices the panel rendering at the default size.
        for value in [Double.nan, -40, 400, .infinity] {
            let html = document(fontSize: value)
            XCTAssertFalse(html.contains("nan"), "NaN reached the stylesheet")
            XCTAssertFalse(html.contains("inf"), "an infinity reached the stylesheet")
            let clamped = SettingsStore.clampFontSize(value)
            XCTAssertTrue(html.contains("font-size: \(Int(clamped))px;"))
        }
    }

    /// The one property the whole type exists for: given the same inputs it is
    /// the same document, so the panel can re-render on every theme change
    /// without the web view flickering through a different page.
    func testCompositionIsPure() {
        XCTAssertEqual(document(), document())
    }

    // MARK: - The cache

    func testFragmentRoundTripsThroughTheCache() {
        let tree = StubFileTree(root: treeRoot, files: [:])
        let cache = makeCache(tree)

        XCTAssertTrue(cache.store(fragment, forSlug: "two-sum"))
        XCTAssertEqual(tree.writtenPaths, [statementPath])
        XCTAssertEqual(cache.fragment(forSlug: "two-sum"), fragment)
        XCTAssertTrue(cache.hasFragment(forSlug: "two-sum"))
    }

    func testStoringCreatesTheStatementsDirectory() {
        let tree = StubFileTree(root: treeRoot, files: [:])
        XCTAssertTrue(makeCache(tree).store(fragment, forSlug: "two-sum"))
        XCTAssertTrue(tree.hasDirectory("cache/Statements"))
    }

    func testAMissingFileIsSimplyNotCached() {
        let cache = makeCache(StubFileTree(root: treeRoot, files: [:]))
        XCTAssertNil(cache.fragment(forSlug: "two-sum"))
        XCTAssertFalse(cache.hasFragment(forSlug: "two-sum"))
    }

    func testAnUnreadableFileIsNotCached() {
        let tree = StubFileTree(root: treeRoot, files: [statementPath: fragment])
        tree.unreadableFiles = [statementPath]
        XCTAssertNil(makeCache(tree).fragment(forSlug: "two-sum"))
    }

    /// A truncated or half-written cache file is how an empty one appears in
    /// practice; serving it would render a blank panel *and* suppress the fetch
    /// that would have repaired it.
    func testABlankFileIsNotCached() {
        let tree = StubFileTree(root: treeRoot, files: [statementPath: "   \n "])
        XCTAssertNil(makeCache(tree).fragment(forSlug: "two-sum"))
    }

    func testAnEmptyFragmentIsNeverStored() {
        let tree = StubFileTree(root: treeRoot, files: [:])
        XCTAssertFalse(makeCache(tree).store("  \n", forSlug: "two-sum"))
        XCTAssertEqual(tree.writtenPaths, [])
    }

    /// The write is an optimisation. A read-only cache directory costs one fetch
    /// next time and must not be reported as a failure to the caller who asked
    /// to see a problem.
    func testAFailedWriteIsSurvivable() {
        let tree = StubFileTree(root: treeRoot, files: [:])
        tree.writeFailures = [statementPath]
        XCTAssertFalse(makeCache(tree).store(fragment, forSlug: "two-sum"))
        XCTAssertNil(makeCache(tree).fragment(forSlug: "two-sum"))
    }

    /// A slug is a file-name component only after the input parser's rule says
    /// so — the same rule "Open Problem…" applies — so a traversal can neither be
    /// written nor looked up.
    func testAHostileSlugIsRefusedRatherThanEscapingTheCacheDirectory() {
        let tree = StubFileTree(root: treeRoot, files: [:])
        let cache = makeCache(tree)
        for slug in ["../../etc/passwd", "/absolute", "two sum", ""] {
            XCTAssertNil(cache.file(forSlug: slug), "\(slug) became a path")
            XCTAssertFalse(cache.store(fragment, forSlug: slug), "\(slug) was written")
            XCTAssertNil(cache.fragment(forSlug: slug))
        }
        XCTAssertEqual(tree.writtenPaths, [])
    }

    func testTheCacheFileIsInsideTheCacheRoot() throws {
        let layout = LeetCodeCacheLayout(base: cacheBase)
        let cache = LeetCodeStatementCache(
            layout: layout,
            fileService: StubFileTree(root: treeRoot, files: [:])
        )
        let url = try XCTUnwrap(cache.file(forSlug: "two-sum"))
        XCTAssertEqual(url.lastPathComponent, "two-sum.html")
        XCTAssertTrue(layout.contains(url))
    }
}
