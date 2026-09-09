import XCTest
@testable import PisakaCore

/// The preview's shell document: its policy, its four bundled files, its theme
/// as CSS, and the two JavaScript entry points everything after page load goes
/// through.
///
/// Four properties are worth asserting on their own, and each of them is silent
/// when it breaks — which is why they are asserted here rather than left to a
/// golden document:
///
/// * **The page names no network origin.** Not in the policy, not in a tag, not
///   in a stylesheet. A regression would produce a page that still renders
///   perfectly while quietly fetching something, so the assertion reads the whole
///   document for `http://` and `https://` rather than reading the CSP alone.
/// * **The policy is exact.** It is asserted verbatim, because every term in it
///   is load-bearing and a *weaker* policy is invisible at run time: nothing
///   fails, more merely becomes possible.
/// * **The bootstrap's hash matches the bootstrap.** Both are derived from one
///   constant, and this suite recomputes the digest independently so a hand-edit
///   of either cannot pass. A mismatch is a page whose script is silently
///   refused, which looks exactly like a rendering bug.
/// * **A body crosses as a value.** The update source is decoded back and
///   compared to the body it was composed from, for a body containing every
///   character that could end the call early.
final class MarkdownPreviewPageTests: XCTestCase {

    private let fontSize: Double = 13

    private func lightPage() -> String {
        MarkdownPreviewPage.html(theme: .light, fontSize: fontSize)
    }

    // MARK: - The vocabulary

    func testTheShellURLIsComposedFromTheSchemeHostAndPath() {
        XCTAssertEqual(MarkdownPreviewPage.shellURL.scheme, MarkdownPreviewPage.scheme)
        XCTAssertEqual(MarkdownPreviewPage.shellURL.host, MarkdownPreviewPage.host)
        XCTAssertEqual(MarkdownPreviewPage.shellURL.path, MarkdownPreviewPage.shellPath)
    }

    func testTheBundledFileListIsTheFourFilesInLoadOrder() {
        XCTAssertEqual(
            MarkdownPreviewPage.bundledFileNames,
            ["preview.css", "highlight.min.js", "mermaid.min.js", "preview.js"]
        )
    }

    func testABundledPathCarriesTheOneBundledPrefix() {
        XCTAssertEqual(
            MarkdownPreviewPage.bundledPath(forFileName: "preview.js"),
            MarkdownPreviewPage.bundledPathPrefix + "preview.js"
        )
        // The two prefixes are distinct, which is what keeps a project file out
        // of the namespace the shell's own script tags spell.
        XCTAssertNotEqual(MarkdownPreviewPage.bundledPathPrefix, MarkdownPreviewPage.filePathPrefix)
    }

    // MARK: - The policy

    func testTheContentSecurityPolicyIsExact() {
        XCTAssertEqual(
            MarkdownPreviewPage.contentSecurityPolicy,
            "default-src 'none'; "
                + "script-src pisaka-preview: '\(MarkdownPreviewPage.bootstrapScriptHash)'; "
                + "style-src pisaka-preview: 'unsafe-inline'; "
                + "img-src pisaka-preview: data:; "
                + "connect-src 'none'; "
                + "base-uri 'none'; "
                + "form-action 'none'"
        )
    }

    func testTheScriptPolicyIsNeverUnsafeInline() {
        let policy = MarkdownPreviewPage.contentSecurityPolicy
        // `'unsafe-inline'` appears once, and it is the style clause's.
        let occurrences = policy.components(separatedBy: "'unsafe-inline'").count - 1
        XCTAssertEqual(occurrences, 1)
        let styleClause = policy
            .components(separatedBy: "; ")
            .first { $0.hasPrefix("style-src") }
        XCTAssertEqual(styleClause, "style-src pisaka-preview: 'unsafe-inline'")
    }

    func testThePolicyNamesNoNetworkOrigin() {
        let policy = MarkdownPreviewPage.contentSecurityPolicy
        for forbidden in ["http://", "https://", "http:", "https:", "*", "'unsafe-eval'"] {
            XCTAssertFalse(policy.contains(forbidden), "the policy names \(forbidden)")
        }
    }

    func testTheBootstrapHashIsTheDigestOfTheBootstrapSource() {
        let digest = SHA256.digest(of: Data(MarkdownPreviewPage.bootstrapSource.utf8))
        XCTAssertEqual(MarkdownPreviewPage.bootstrapScriptHash, "sha256-" + digest.base64EncodedString())
        XCTAssertTrue(MarkdownPreviewPage.contentSecurityPolicy.contains("'\(MarkdownPreviewPage.bootstrapScriptHash)'"))
    }

    func testTheBootstrapScriptElementCarriesExactlyTheHashedBytes() {
        // What CSP hashes is the element's text content, so the document must
        // contain the constant with no whitespace of its own around it.
        XCTAssertTrue(lightPage().contains("<script>\(MarkdownPreviewPage.bootstrapSource)</script>"))
    }

    // MARK: - The document

    func testTheShellNamesNoNetworkURL() {
        let page = lightPage()
        // `http` alone would match the CSP's own `http-equiv` attribute, which is
        // how a meta-tag policy is spelled; a *URL* is what must be absent.
        XCTAssertFalse(page.contains("http://"))
        XCTAssertFalse(page.contains("https://"))
        XCTAssertFalse(page.contains("//cdn"))
    }

    func testEveryTagTheShellLoadsNamesABundledFileUnderTheBundledPrefix() {
        let page = lightPage()
        XCTAssertTrue(page.contains("<link rel=\"stylesheet\" href=\"/assets/preview.css\">"))
        for name in ["highlight.min.js", "mermaid.min.js", "preview.js"] {
            XCTAssertTrue(page.contains("<script src=\"/assets/\(name)\"></script>"), "missing \(name)")
        }
    }

    func testTheScriptTagsAreInLoadOrderAndTheBootstrapIsLast() {
        let page = lightPage()
        let positions = ["highlight.min.js", "mermaid.min.js", "preview.js"].map { name in
            page.range(of: "<script src=\"/assets/\(name)\">")?.lowerBound
        }
        let found = positions.compactMap { $0 }
        XCTAssertEqual(found.count, 3)
        XCTAssertEqual(found, found.sorted())
        let bootstrap = page.range(of: "<script>\(MarkdownPreviewPage.bootstrapSource)</script>")?.lowerBound
        XCTAssertNotNil(bootstrap)
        XCTAssertTrue(found.allSatisfy { $0 < bootstrap! })
    }

    func testTheThemeStyleFollowsTheStylesheetLinkSoItWins() {
        let page = lightPage()
        let link = page.range(of: "<link rel=\"stylesheet\"")?.lowerBound
        let style = page.range(of: "<style>")?.lowerBound
        XCTAssertNotNil(link)
        XCTAssertNotNil(style)
        XCTAssertTrue(link! < style!)
    }

    func testTheBodyContainerIsEmpty() {
        XCTAssertTrue(lightPage().contains("<div id=\"\(MarkdownPreviewPage.containerElementID)\"></div>"))
    }

    // MARK: - The theme as CSS

    func testEveryTokenKindReachesTheCSSAsItsOwnCustomProperty() {
        let page = lightPage()
        for kind in SyntaxTokenKind.allCases {
            let name = MarkdownPreviewTheme.cssVariableName(for: kind)
            XCTAssertTrue(
                page.contains("  \(name): \(MarkdownPreviewTheme.light.color(for: kind));"),
                "missing custom property for \(kind)"
            )
        }
    }

    func testEveryChromeColourReachesTheCSS() {
        let page = lightPage()
        let theme = MarkdownPreviewTheme.light
        let expected = [
            "color-scheme: light;",
            "--background: \(theme.background);",
            "--text: \(theme.text);",
            "--secondary-text: \(theme.secondaryText);",
            "--link: \(theme.link);",
            "--code-background: \(theme.codeBackground);",
            "--border: \(theme.border);",
            "--table-border: \(theme.tableBorder);",
        ]
        for declaration in expected {
            XCTAssertTrue(page.contains(declaration), "missing \(declaration)")
        }
    }

    func testEveryHighlightScopeGetsOneRuleReadingItsKindsProperty() {
        let page = lightPage()
        for scope in MarkdownHighlightClasses.standardScopes {
            guard
                let selector = MarkdownHighlightClasses.cssSelector(forScope: scope),
                let kind = MarkdownHighlightClasses.kind(forScope: scope)
            else { return XCTFail("scope \(scope) has no selector or no kind") }
            let name = MarkdownPreviewTheme.cssVariableName(for: kind)
            XCTAssertTrue(
                page.contains("\(selector) { color: var(\(name)); }"),
                "missing rule for \(scope)"
            )
        }
    }

    func testTheCodeFontSizeReachesTheCSS() {
        let page = MarkdownPreviewPage.html(theme: .light, fontSize: 17)
        XCTAssertTrue(page.contains("--font-size: 17px;"))
        XCTAssertTrue(page.contains("--code-font-size: 16px;"))
    }

    func testAnAbsurdFontSizeIsClampedRatherThanEmitted() {
        let page = MarkdownPreviewPage.html(theme: .light, fontSize: .nan)
        XCTAssertFalse(page.contains("nan"))
        XCTAssertTrue(page.contains("--font-size: \(Int(SettingsStore.clampFontSize(.nan)))px;"))
    }

    func testLightAndDarkShellsDiffer() {
        let light = MarkdownPreviewPage.html(theme: .light, fontSize: fontSize)
        let dark = MarkdownPreviewPage.html(theme: .dark, fontSize: fontSize)
        XCTAssertNotEqual(light, dark)
        XCTAssertTrue(light.contains("color-scheme: light;"))
        XCTAssertTrue(dark.contains("color-scheme: dark;"))
        XCTAssertTrue(light.contains("data-color-scheme=\"light\""))
        XCTAssertTrue(dark.contains("data-color-scheme=\"dark\""))
    }

    // MARK: - The two entry points

    /// The argument of a one-argument call, or `nil` when the source is not that
    /// shape. Deliberately parsed rather than pattern-matched, so the assertion
    /// fails when the call's *shape* changes and not only its content.
    private func argument(of source: String, call: String) -> String? {
        let prefix = "window.\(MarkdownPreviewPage.namespace).\(call)("
        guard source.hasPrefix(prefix), source.hasSuffix(");") else { return nil }
        return String(source.dropFirst(prefix.count).dropLast(2))
    }

    func testABodyRoundTripsThroughTheUpdateSource() throws {
        let body = """
            <p>a "quoted" &amp; \\backslashed\\ line</p>
            <p>with </script> in it and a tab\there</p>
            """
        let source = MarkdownPreviewPage.bodyUpdateSource(body: body)
        let literal = try XCTUnwrap(argument(of: source, call: "render"))

        // The literal is valid JSON as well as valid JavaScript, which is what
        // lets the decoding be Foundation's rather than a second escaper written
        // here to agree with the first.
        let decoded = try JSONSerialization.jsonObject(
            with: Data(literal.utf8),
            options: [.fragmentsAllowed]
        ) as? String
        XCTAssertEqual(decoded, body)
    }

    func testTheUpdateSourceCannotBeEndedByItsArgument() throws {
        // Every character that could close the literal, close the call or open a
        // tag, in one body — including a `");` that would end the call if the
        // quote in front of it survived unescaped.
        let body = "</script><script>alert(1)</script>\");"
        let source = MarkdownPreviewPage.bodyUpdateSource(body: body)
        let literal = try XCTUnwrap(argument(of: source, call: "render"))

        // No tag can form anywhere in the source, so the literal survives being
        // read inside a `<script>` element as well as through `evaluateJavaScript`.
        XCTAssertFalse(source.contains("<"))
        XCTAssertFalse(source.contains(">"))

        // The `);` the body carries stays inside the literal: it decodes back to
        // the body, which is the statement that nothing escaped — a `);` in the
        // source is not by itself the end of the call, an unescaped quote before
        // it would be.
        let decoded = try JSONSerialization.jsonObject(
            with: Data(literal.utf8),
            options: [.fragmentsAllowed]
        ) as? String
        XCTAssertEqual(decoded, body)
    }

    func testAnEmptyBodyIsAnEmptyLiteralRatherThanNoCall() {
        XCTAssertEqual(
            MarkdownPreviewPage.bodyUpdateSource(body: ""),
            "window.PisakaPreview.render(\"\");"
        )
    }

    func testControlCharactersAndLineSeparatorsAreEscaped() throws {
        let body = "a\u{0}b\u{2028}c\u{2029}d\u{1f}e"
        let source = MarkdownPreviewPage.bodyUpdateSource(body: body)
        let literal = try XCTUnwrap(argument(of: source, call: "render"))
        XCTAssertTrue(literal.contains("\\u0000"))
        XCTAssertTrue(literal.contains("\\u2028"))
        XCTAssertTrue(literal.contains("\\u2029"))
        XCTAssertTrue(literal.contains("\\u001f"))
        let decoded = try JSONSerialization.jsonObject(
            with: Data(literal.utf8),
            options: [.fragmentsAllowed]
        ) as? String
        XCTAssertEqual(decoded, body)
    }

    func testTheScrollSourceCarriesTheLineAsANumber() {
        XCTAssertEqual(
            MarkdownPreviewPage.scrollToLineSource(line: 42),
            "window.PisakaPreview.scrollToLine(42);"
        )
        XCTAssertEqual(
            MarkdownPreviewPage.scrollToLineSource(line: 1),
            "window.PisakaPreview.scrollToLine(1);"
        )
    }

    func testBothEntryPointsCallThroughTheOneNamespace() {
        XCTAssertTrue(MarkdownPreviewPage.bodyUpdateSource(body: "x").hasPrefix("window.PisakaPreview."))
        XCTAssertTrue(MarkdownPreviewPage.scrollToLineSource(line: 1).hasPrefix("window.PisakaPreview."))
        XCTAssertTrue(MarkdownPreviewPage.bootstrapSource.hasPrefix("window.PisakaPreview."))
    }
}
