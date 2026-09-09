import XCTest

/// Static verification of the Markdown preview's cross-layer wiring rules.
///
/// A repository-file suite in the `FoldingSourceGatingTests` shape: it reads
/// `Sources/` through `#filePath` with Foundation only and strips comments and
/// string literals with `LSPSourceGatingTests.strippingCommentsAndStringLiterals(_:)`
/// before matching. Load-bearing, not tidy — every file this suite reads states
/// its own rules in prose and quotes the very tokens matched below (the
/// controller's doc comment names `import WebKit` and `autosave.suspend()`, the
/// scheme handler's says it imports no WebKit, the web view's names
/// `load(URLRequest`), so a raw `contains` would stay green on a comment
/// describing a call site that has been deleted — and would *fail* on files
/// that merely say they do not do the thing.
///
/// The feature's files, enumerated explicitly because the rules below are about
/// this set and not about a name prefix:
///
/// * Core — `MarkdownDocument.swift`, `MarkdownPreviewTheme.swift`,
///   `MarkdownHighlightClasses.swift`, `MarkdownRenderer.swift`,
///   `MarkdownPreviewPage.swift`, `MarkdownPreviewAsset.swift`,
///   `MarkdownLinkRule.swift`, `MarkdownScrollRule.swift`,
///   `MarkdownPreviewWidthRule.swift`, `MarkdownPreviewModel.swift`.
/// * App (macOS) — `MarkdownParser.swift`, `MarkdownPreviewSchemeHandler.swift`,
///   `MarkdownPreviewWebView.swift`, `MarkdownPreviewController.swift`,
///   `MarkdownPreviewPane.swift`, `EditorCommandTarget.swift`.
/// * Shared hosts, named as such and *not* part of the feature's file set:
///   `ContentView.swift` (the split, the divider and the width arithmetic's one
///   caller), `PisakaApp.swift` (the menu item and the five caret commands),
///   `CodeEditorView.swift` (the scroll callback), `SyntaxTheme.swift` (the
///   theme derivation) and `FoldCommands.swift` (the sixth caret command).
///   Rules that must hold for the *whole* app layer say so by scanning
///   `Sources/Pisaka` rather than by listing these.
///
/// **Why the compiler cannot see any of this:**
///
/// 1. The compiler cannot keep the parse in one file. `import Markdown` in a
///    second app file compiles and links, and puts a second reading of the AST
///    beside the one whose output every Core test is written against — where a
///    node the tree has no case for could quietly grow a rendering nobody can
///    reach from `swift test`.
/// 2. The compiler cannot keep WebKit out of the rest of the feature. The
///    handler, the controller and the pane are deliberately plain: a
///    `WKWebView` reached from any of them would be a second driver of a page
///    whose whole update ordering is the model's, and it would compile.
/// 3. The compiler cannot see the one-origin rule. `loadHTMLString` is one call,
///    it renders the same page, and it gives that page a **null origin** — under
///    which every bundled file and every project image fetch is cross-origin and
///    fails, and under which the CSP the shell carries is enforced against
///    nothing the handler serves. The failure is a blank-looking preview, not a
///    build error.
/// 4. The compiler cannot keep the app-scheme vocabulary in one place. This is
///    `GitHubCommands`' rule applied to a URL space: the scheme, the host, the
///    shell path and the two path prefixes are Core's, so the forward direction
///    that *composes* a URL and the inverse that *consumes* one are two halves
///    of one function rather than two implementations agreeing by habit. An app
///    file splitting a preview path itself builds, runs, and re-answers the
///    containment question — the feature's whole file-access property — in a
///    file no Core test reads.
/// 5. The compiler cannot see who writes a preference. `markdownPreviewEnabled`
///    is one global switch; a second writer is a second opinion about whether
///    the pane is shown, and it would compile.
/// 6. The compiler cannot count the definitions of "which editor is this
///    keystroke for". Six app-wide chords ask it; the expression they each used
///    to spell answers `nil` while the preview holds focus, which is a beep
///    instead of a comment toggle. A seventh site spelling it again compiles and
///    diverges silently, exactly where nobody looks.
/// 7. The compiler cannot enforce that the preview stays a **reader**. Naming
///    `autosave.suspend()` / `localChanges.beginRevert()` inside it would
///    compile perfectly and turn a debounced render of a buffer nobody is
///    writing to disk into a gate the editor waits behind.
/// 8. The compiler cannot ensure the app-side files are macOS-gated; without
///    `#if os(macOS)` they would break the iOS build, which has no WebKit
///    scheme handler, no `NSApp` and no preview surface at all.
///
/// **The one stated exception.** Every rule below matches comment- *and*
/// literal-stripped text, except the two whose subject **is** a string literal:
/// the HTML tag no app file may compose, and the four spellings of the app
/// scheme's vocabulary. The ordinary scanner deletes exactly the text those two
/// rules are about, and would pass an app file that composed a `<div>` or spelled
/// `pisaka-preview` itself. They read `GitHubSourceGatingTests.strippingComments(_:)`
/// instead — the same scanner with the literals kept — which is that suite's own
/// argument about `gh`'s flags, read here about markup.
final class MarkdownPreviewSourceGatingTests: XCTestCase {

    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // PisakaCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // <root>

    // MARK: - The feature's files

    /// The Core half, enumerated rather than matched by prefix.
    private static let coreFileNames = [
        "MarkdownDocument.swift",
        "MarkdownPreviewTheme.swift",
        "MarkdownHighlightClasses.swift",
        "MarkdownRenderer.swift",
        "MarkdownPreviewPage.swift",
        "MarkdownPreviewAsset.swift",
        "MarkdownLinkRule.swift",
        "MarkdownScrollRule.swift",
        "MarkdownPreviewWidthRule.swift",
        "MarkdownPreviewModel.swift",
    ]

    /// The app half, all macOS-gated.
    private static let appFileNames = [
        "MarkdownParser.swift",
        "MarkdownPreviewSchemeHandler.swift",
        "MarkdownPreviewWebView.swift",
        "MarkdownPreviewController.swift",
        "MarkdownPreviewPane.swift",
        "EditorCommandTarget.swift",
    ]

    /// The markup shapes no app file of the feature may spell, all four of them
    /// impossible in Swift code and so safe to look for in a literal-keeping
    /// scan: a closing tag (`</p`), a declaration or comment opener (`<!`), an
    /// opening tag carrying an attribute (`<img src=`), and an all-lowercase
    /// bare tag (`<br>`) — a generic argument is a type name, so it does not
    /// collide, while `<div>` and `<hr>` are what a renderer written in the
    /// wrong layer reaches for first.
    static let htmlTagShapes = [
        "</[a-zA-Z]",
        "<!",
        "<[a-zA-Z][a-zA-Z0-9-]*\\s+[a-zA-Z-]+=",
        "<[a-z][a-z0-9]*>",
    ]

    /// The files that host the feature without belonging to it. Named here so a
    /// rule that excludes one of them excludes it deliberately.
    private static let sharedHostFileNames = [
        "ContentView.swift",
        "PisakaApp.swift",
        "CodeEditorView.swift",
        "SyntaxTheme.swift",
        "FoldCommands.swift",
    ]

    // MARK: - Reading

    private func swiftFiles(under relativeDirectory: String) throws -> [URL] {
        let directory = Self.repositoryRoot.appendingPathComponent(relativeDirectory)
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            XCTFail("cannot enumerate \(directory.path)")
            return []
        }
        return enumerator
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
    }

    private func source(of url: URL) throws -> String {
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(
            text.isEmpty,
            "\(url.lastPathComponent) is unreadable — the walk is broken, not the code"
        )
        return text
    }

    /// Comment- and literal-stripped, the scanner every rule but the two stated
    /// exceptions reads.
    private func code(of url: URL) throws -> String {
        LSPSourceGatingTests.strippingCommentsAndStringLiterals(try source(of: url))
    }

    private func code(ofFileNamed name: String, under relativeDirectory: String) throws -> String {
        try code(of: Self.repositoryRoot.appendingPathComponent(relativeDirectory + "/" + name))
    }

    /// Comments removed, **string literals kept** — the suite's one stated
    /// exception, read by the markup rule and the scheme-vocabulary rule alone.
    private func literalKeepingCode(of url: URL) throws -> String {
        GitHubSourceGatingTests.strippingComments(try source(of: url))
    }

    private func occurrences(of pattern: String, in code: String) throws -> Int {
        let regex = try NSRegularExpression(pattern: pattern)
        return regex.numberOfMatches(in: code, range: NSRange(code.startIndex..., in: code))
    }

    /// The names of the files under `relativeDirectory` whose stripped code
    /// matches `pattern`.
    private func fileNames(matching pattern: String, under relativeDirectory: String) throws -> Set<String> {
        var names: Set<String> = []
        for url in try swiftFiles(under: relativeDirectory) where try occurrences(of: pattern, in: code(of: url)) > 0 {
            names.insert(url.lastPathComponent)
        }
        return names
    }

    /// The names of the files under `relativeDirectory` whose stripped code
    /// names `identifier` as a whole token.
    private func fileNames(naming identifier: String, under relativeDirectory: String) throws -> Set<String> {
        var names: Set<String> = []
        for url in try swiftFiles(under: relativeDirectory) {
            guard LSPSourceGatingTests.containsToken(identifier, in: try code(of: url)) else { continue }
            names.insert(url.lastPathComponent)
        }
        return names
    }

    /// The names of the files under `relativeDirectory` whose **literal-keeping**
    /// code matches `pattern`.
    private func fileNamesKeepingLiterals(
        matching pattern: String,
        under relativeDirectory: String
    ) throws -> Set<String> {
        var names: Set<String> = []
        for url in try swiftFiles(under: relativeDirectory) {
            guard try occurrences(of: pattern, in: literalKeepingCode(of: url)) > 0 else { continue }
            names.insert(url.lastPathComponent)
        }
        return names
    }

    // MARK: - The file set is what this suite thinks it is

    /// Every file the rules below are written about exists, and the two halves
    /// are where they are said to be.
    ///
    /// Without this the whole suite degrades quietly: a renamed file makes every
    /// set-equality rule about it trivially true, and a moved one makes a
    /// per-file rule read an empty string.
    func testTheFeaturesFilesAreWhereThisSuiteLooks() throws {
        let core = Set(try swiftFiles(under: "Sources/PisakaCore").map(\.lastPathComponent))
        for name in Self.coreFileNames {
            XCTAssertTrue(
                core.contains(name),
                "\(name) is not in Sources/PisakaCore — rename it and update this suite deliberately."
            )
        }

        let app = Set(try swiftFiles(under: "Sources/Pisaka").map(\.lastPathComponent))
        for name in Self.appFileNames + Self.sharedHostFileNames {
            XCTAssertTrue(
                app.contains(name),
                "\(name) is not under Sources/Pisaka — rename it and update this suite deliberately."
            )
        }
    }

    // MARK: - The absence rules can see the thing they forbid

    /// Every rule below that asserts an **absence** is checked here against a
    /// file that does contain what it forbids.
    ///
    /// This is the double-entry the performance bounds keep, read for a text
    /// scan: an absence rule whose pattern is wrong, or whose scanner deletes
    /// the text it looks for, is green forever and dies with the regression it
    /// names. Each control below is a file outside the feature (or the Core half
    /// the rule deliberately exempts) that spells the forbidden thing, so a
    /// broken pattern fails *here* rather than passing silently there.
    func testTheAbsenceRulesArePositivelyControlled() throws {
        XCTAssertTrue(
            LSPSourceGatingTests.containsToken(
                "loadHTMLString",
                in: try code(ofFileNamed: "LeetCodeDescriptionView.swift", under: "Sources/Pisaka")
            ),
            "The statement pane string-loads its document — a different feature under a different rule, and "
                + "the control proving the scanner can still see the call the preview may not make."
        )
        for spelling in ["pathComponents", "URLComponents"] {
            XCTAssertTrue(
                LSPSourceGatingTests.containsToken(
                    spelling,
                    in: try code(ofFileNamed: "MarkdownPreviewAsset.swift", under: "Sources/PisakaCore")
                ),
                "Core's mapping spells \(spelling) — it is the file that composes and consumes a preview "
                    + "URL. If this stops matching, the app-side absence rule is checking nothing."
            )
        }
        XCTAssertTrue(
            LSPSourceGatingTests.containsToken(
                "autosave",
                in: try code(ofFileNamed: "PisakaApp.swift", under: "Sources/Pisaka")
            ),
            "The scene names the writer gate, as the eight gated operations require. The reader rule below "
                + "is meaningful only while this control holds."
        )
        for shape in Self.htmlTagShapes {
            XCTAssertGreaterThan(
                try occurrences(
                    of: shape,
                    in: literalKeepingCode(
                        of: Self.repositoryRoot.appendingPathComponent("Sources/PisakaCore/MarkdownPreviewPage.swift")
                    )
                ),
                0,
                "The page composes markup matching \(shape). That is what the literal-keeping scan exists "
                    + "for: under the ordinary scanner every one of these counts is zero everywhere, and "
                    + "the markup rule passes on an app file emitting a div of its own."
            )
        }
    }

    // MARK: - One parser, one web view

    /// The feature's one `import Markdown`, and its one `import WebKit`.
    func testTheParserAndTheWebViewAreEachOneFile() throws {
        XCTAssertEqual(
            try fileNames(matching: "(?m)^import Markdown$", under: "Sources"),
            ["MarkdownParser.swift"],
            "Exactly one file imports the Markdown parser. Everything downstream of it works on the Core "
                + "tree, which is what makes the whole preview answerable in swift test even though the "
                + "parser itself cannot link there; a second importer is a second reading of the AST."
        )
        XCTAssertEqual(
            try fileNames(matching: "(?m)^import Markdown$", under: "Sources/PisakaCore"),
            [],
            "And Core imports it nowhere: PisakaCore is Foundation-only, so the tree it works on must "
                + "arrive as a value someone else built."
        )

        let webKitImporters = try fileNames(matching: "(?m)^import WebKit$", under: "Sources/Pisaka")
        XCTAssertEqual(
            webKitImporters.intersection(Set(Self.appFileNames)),
            ["MarkdownPreviewWebView.swift"],
            "The preview's one WebKit file. The scheme handler beside it is a plain function of a URL and "
                + "the controller is four forwarding methods; WebKit in either would be a second driver of "
                + "a page whose update ordering is the model's. (LeetCode's own web views are a different "
                + "feature and are outside this set by construction.)"
        )
        XCTAssertEqual(
            try fileNames(matching: "(?m)^import WebKit$", under: "Sources/PisakaCore"),
            [],
            "Core imports WebKit nowhere. The page reaches the model as a one-method seam precisely so the "
                + "ordering can be tested without one."
        )
    }

    // MARK: - One origin

    /// The page is *served*, never string-loaded.
    ///
    /// Three halves of one rule: nothing in the feature spells `loadHTMLString`,
    /// the shell is fetched from exactly one site, and every update after that
    /// arrives as JavaScript into the document already loaded. A string-loaded
    /// document has a null origin, under which the four bundled files and every
    /// project image are cross-origin fetches that fail — and the failure looks
    /// like a stylesheet that did not apply, not like an error.
    func testThePageIsServedAndUpdatedInPlace() throws {
        for name in Self.appFileNames {
            XCTAssertFalse(
                LSPSourceGatingTests.containsToken(
                    "loadHTMLString",
                    in: try code(ofFileNamed: name, under: "Sources/Pisaka")
                ),
                "\(name) must not spell loadHTMLString: a string-loaded document has a null origin, so the "
                    + "bundled files and the project images the handler serves would all be cross-origin."
            )
        }
        XCTAssertEqual(
            try fileNames(matching: "\\bloadHTMLString\\b", under: "Sources/PisakaCore"),
            [],
            "And Core names it nowhere either — it composes the shell as a string for the handler to answer "
                + "with, not for a web view to be handed."
        )

        let webView = try code(ofFileNamed: "MarkdownPreviewWebView.swift", under: "Sources/Pisaka")
        XCTAssertEqual(
            try occurrences(of: "\\.load\\(URLRequest\\(", in: webView),
            1,
            "One load site: the shell, fetched from MarkdownPreviewPage.shellURL so the document and "
                + "everything it reaches share one app-scheme origin. A second load is a second way the page "
                + "can arrive, and only one of them goes through the handler."
        )
        let loaders = try fileNames(matching: "\\.load\\(URLRequest\\(", under: "Sources/Pisaka")
        XCTAssertEqual(
            loaders.intersection(Set(Self.appFileNames)),
            ["MarkdownPreviewWebView.swift"],
            "And that site is the feature's only one."
        )

        let evaluators = try fileNames(naming: "evaluateJavaScript", under: "Sources/Pisaka")
        XCTAssertEqual(
            evaluators.intersection(Set(Self.appFileNames)),
            ["MarkdownPreviewWebView.swift"],
            "Every body and scroll update goes through evaluateJavaScript, in the one file holding the web "
                + "view. What it evaluates is composed by MarkdownPreviewPage; this file only delivers it."
        )
        XCTAssertEqual(
            try fileNames(naming: "evaluateJavaScript", under: "Sources/PisakaCore"),
            [],
            "Core never evaluates anything. It hands the source across the sink seam, which is why the "
                + "ordering is assertable against a scripted sink."
        )
    }

    /// The page's *only* fetch is the one the handler answers.
    ///
    /// The rule above pins how the document arrives; this pins that nothing
    /// else can arrive at all. `WKWebView.allowsLinkPreview` defaults to `true`,
    /// and a link preview loads the URL it is previewing in a web view of
    /// WebKit's own — outside `navigationDelegate`, whose every answer is
    /// `.cancel`, and outside the shell's `default-src 'none'`, which is a
    /// property of the document and not of the process. So a force press on an
    /// `http(s)` link in a rendered document would be the one path by which
    /// this feature reached the network, and the property stated in
    /// `docs/FEATURES.md` and `README.md` — that the page is not allowed to
    /// make a request of any kind — would be false. It is off by a line, and
    /// this is the line.
    func testNoDocumentIsFetchedOutsideTheNavigationDelegate() throws {
        let webView = try code(ofFileNamed: "MarkdownPreviewWebView.swift", under: "Sources/Pisaka")
        XCTAssertEqual(
            try occurrences(of: "\\ballowsLinkPreview\\s*=\\s*false\\b", in: webView),
            1,
            "The preview's web view must turn allowsLinkPreview off: it defaults to true, and a link "
                + "preview fetches its URL outside both the navigation delegate and the page's CSP."
        )
    }

    // MARK: - The app-scheme vocabulary

    /// The scheme, the host, the shell path and the two path prefixes are
    /// spelled in exactly one Core file and in no app file.
    ///
    /// **The first of the suite's two literal-keeping rules**: these are string
    /// literals, so the ordinary scanner deletes precisely the text the rule is
    /// about and would pass an app file that spelled `pisaka-preview://preview`
    /// itself.
    func testTheSchemeVocabularyIsSpelledInOneCoreFile() throws {
        let vocabulary: [(what: String, pattern: String)] = [
            ("the scheme", "\"pisaka-preview\""),
            ("the host", "= \"preview\""),
            ("the shell path", "\"/index\\.html\""),
            ("the bundled-file prefix", "\"/assets/\""),
            ("the project-file prefix", "\"/file/\""),
        ]
        for entry in vocabulary {
            XCTAssertEqual(
                try fileNamesKeepingLiterals(matching: entry.pattern, under: "Sources"),
                ["MarkdownPreviewPage.swift"],
                "\(entry.what) is spelled in exactly one file. The forward direction that composes a preview "
                    + "URL and the inverse that consumes one are two halves of one function; a second "
                    + "spelling is two implementations agreeing by habit, and the containment check they "
                    + "share is the feature's whole file-access property."
            )
        }
    }

    /// No app file of the feature takes a preview URL apart. The inverse
    /// direction is Core's, in the same file that composed the URL.
    func testNoAppFileOfTheFeatureSplitsAPreviewURL() throws {
        for name in Self.appFileNames {
            let code = try self.code(ofFileNamed: name, under: "Sources/Pisaka")
            for spelling in ["pathComponents", "URLComponents"] {
                XCTAssertFalse(
                    LSPSourceGatingTests.containsToken(spelling, in: code),
                    "\(name) must not spell \(spelling): an incoming URL goes straight to "
                        + "MarkdownPreviewAsset.classify(_:context:), which settles the scheme, the host, "
                        + "the prefix and the containment question in one place."
                )
            }
            XCTAssertEqual(
                try occurrences(of: "\\.components\\(separatedBy", in: code),
                0,
                "\(name) must not split a path itself, for the same reason: the handler dispatches over the "
                    + "four cases Core answers with and decides none of them."
            )
        }

        XCTAssertEqual(
            try fileNames(naming: "MarkdownPreviewAsset", under: "Sources/Pisaka"),
            ["MarkdownPreviewSchemeHandler.swift"],
            "One app file asks what a fetch is for, and it dispatches over the four cases Core answers "
                + "with. A second caller would be a second place the containment question is asked — and "
                + "the day the two disagree, one of them serves a file the other refuses."
        )
        XCTAssertEqual(
            try fileNames(naming: "MarkdownLinkRule", under: "Sources/Pisaka"),
            ["MarkdownPreviewWebView.swift"],
            "And one app file asks what a click is for: the navigation delegate. Both rules read the same "
                + "document context — a stored property of the handler, so there is one answer — which is "
                + "what keeps a served file and a followed link from disagreeing about which document the "
                + "page is showing."
        )
    }

    // MARK: - The preference

    /// `markdownPreviewEnabled` is written from exactly one app site.
    func testThePreferenceIsWrittenFromOneSite() throws {
        XCTAssertEqual(
            try fileNames(
                matching: "\\$settings\\.markdownPreviewEnabled|settings\\.markdownPreviewEnabled\\s*=",
                under: "Sources/Pisaka"
            ),
            ["PisakaApp.swift"],
            "One writer: the View menu's toggle. The preference is global — it is not per tab and not per "
                + "window — so a second writer is a second opinion about whether the pane is shown."
        )
        XCTAssertEqual(
            try fileNames(naming: "markdownPreviewEnabled", under: "Sources/Pisaka"),
            ["PisakaApp.swift", "ContentView.swift"],
            "And one reader beside it: the window layout, which asks whether this tab shows a preview. "
                + "ContentView is a named shared host, not a file of the feature."
        )
    }

    // MARK: - The focus helper

    /// One definition of "which editor is this keystroke for", and six callers.
    func testTheFocusHelperHasOneDefinitionAndSixCallSites() throws {
        XCTAssertEqual(
            try fileNames(matching: "\\benum EditorCommandTarget\\b", under: "Sources"),
            ["EditorCommandTarget.swift"],
            "One definition. The fallback past a focused preview is a rule about *which* responder may be "
                + "looked past, and a second copy of it is a second answer on the day one of them is widened."
        )

        XCTAssertEqual(
            try fileNames(matching: "\\bfirstResponder as\\? EditorTextView\\b", under: "Sources"),
            ["EditorCommandTarget.swift"],
            "And the expression the six commands used to spell themselves now lives there alone: written "
                + "again anywhere, it answers nil while the preview holds focus — a beep instead of a "
                + "comment toggle, in exactly the case the helper exists for."
        )

        let app = try code(ofFileNamed: "PisakaApp.swift", under: "Sources/Pisaka")
        XCTAssertEqual(
            try occurrences(of: "EditorCommandTarget\\.focusedEditor\\(", in: app),
            5,
            "Five of the six caret commands are in the scene: Go to Definition, Find Usages, Rename, Toggle "
                + "Comment and Complete. A sixth site here would be a command that never asked."
        )
        let folds = try code(ofFileNamed: "FoldCommands.swift", under: "Sources/Pisaka")
        XCTAssertEqual(
            try occurrences(of: "EditorCommandTarget\\.focusedEditor\\(", in: folds),
            1,
            "And the sixth is the fold items' own focusedEditor(), which asks once for all four of them."
        )
        XCTAssertEqual(
            try fileNames(matching: "EditorCommandTarget\\.focusedEditor\\(", under: "Sources"),
            ["PisakaApp.swift", "FoldCommands.swift"],
            "Two files ask, and they are the two that own app-wide caret chords. A third asker is a command "
                + "surface that grew somewhere no doc comment describes."
        )

        XCTAssertEqual(
            try fileNames(naming: "EditorCommandFocusPassthrough", under: "Sources/Pisaka")
                .subtracting(["EditorCommandTarget.swift"]),
            ["MarkdownPreviewWebView.swift"],
            "One conformer: the preview's web view, which is the file the editor is showing, rendered. "
                + "Anything else claiming the marker would hand a caret command an editor the keystroke was "
                + "never aimed at — the terminal, the project tree and every other responder keep beeping "
                + "byte for byte as they do today."
        )
    }

    // MARK: - No app file composes markup

    /// The HTML is Core's, byte for byte.
    ///
    /// **The second of the suite's two literal-keeping rules**, and the reason
    /// the exception exists: a tag *is* a string literal, so the ordinary
    /// scanner deletes the very thing this rule checks and would pass an app
    /// file emitting a `<div>` of its own.
    ///
    /// The shapes are ``htmlTagShapes``, and every one of them is checked
    /// against Core's own page in `testTheAbsenceRulesArePositivelyControlled()`
    /// — an absence rule whose pattern matches nothing is green forever.
    func testNoAppFileOfTheFeatureComposesHTML() throws {
        for name in Self.appFileNames {
            let code = try literalKeepingCode(
                of: Self.repositoryRoot.appendingPathComponent("Sources/Pisaka/" + name)
            )
            for shape in Self.htmlTagShapes {
                XCTAssertEqual(
                    try occurrences(of: shape, in: code),
                    0,
                    "\(name) must compose no markup (matched \(shape)). Every element the preview shows is "
                        + "emitted by MarkdownRenderer or MarkdownPreviewPage, where the escaping, the "
                        + "class table and the CSP that admits them are all asserted in swift test."
                )
            }
        }
    }

    // MARK: - Platform gating

    func testTheAppSideFilesAreMacOSGated() throws {
        for name in Self.appFileNames {
            let firstLine = try source(of: Self.repositoryRoot.appendingPathComponent("Sources/Pisaka/" + name))
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty }
            XCTAssertEqual(
                firstLine,
                "#if os(macOS)",
                "\(name) must open with #if os(macOS): the preview is macOS-only, and an ungated file would "
                    + "break the iOS build (AppKit, NSApp, WKURLSchemeHandler and the split that hosts the "
                    + "pane exist on neither destination's other half)."
            )
        }
    }

    func testTheIOSLayerNamesNothingUnderTheFeature() throws {
        let names = Self.appFileNames.map { String($0.dropLast(".swift".count)) }
            + [
                "MarkdownPreviewWKWebView",
                "EditorCommandFocusPassthrough",
                "MarkdownPreviewModel",
                "MarkdownPreviewPage",
                "MarkdownPreviewAsset",
                "MarkdownRenderer",
                "MarkdownDocument",
                "MarkdownLinkRule",
                "MarkdownScrollRule",
                "MarkdownPreviewWidthRule",
                "MarkdownPreviewTheme",
                "markdownPreviewEnabled",
                "markdownPreviewFraction",
            ]
        for url in try swiftFiles(under: "Sources/Pisaka/iOS") {
            let code = try self.code(of: url)
            for name in names {
                XCTAssertFalse(
                    LSPSourceGatingTests.containsToken(name, in: code),
                    "\(url.lastPathComponent) must not name \(name): iOS ships no preview surface, and a "
                        + "reference here is a half-built one that compiles."
                )
            }
        }
    }

    // MARK: - A reader

    /// The preview takes no writer gate and is gated by none.
    ///
    /// It writes nothing at all — not the buffer, not the worktree, not the
    /// session — so there is nothing for the gate to order it against. Raising
    /// it around a debounced render would serialize the editor behind a parse of
    /// a buffer nobody is saving; refusing to render while it is up would freeze
    /// the preview for exactly as long as a branch switch takes, for an answer
    /// that costs nothing to recompute.
    func testTheFeatureNamesNoWriterGate() throws {
        for name in Self.appFileNames {
            let code = try self.code(ofFileNamed: name, under: "Sources/Pisaka")
            for gate in ["autosave", "localChanges"] {
                XCTAssertFalse(
                    LSPSourceGatingTests.containsToken(gate, in: code),
                    "\(name) must not name \(gate): the preview is a reader, like the symbol index."
                )
            }
        }
        for name in Self.coreFileNames {
            let code = try self.code(ofFileNamed: name, under: "Sources/PisakaCore")
            for gate in ["autosave", "localChanges"] {
                XCTAssertFalse(
                    LSPSourceGatingTests.containsToken(gate, in: code),
                    "\(name) must not name \(gate) either — the ordering it owns is about a page, not about "
                        + "a disk."
                )
            }
        }
    }
}
