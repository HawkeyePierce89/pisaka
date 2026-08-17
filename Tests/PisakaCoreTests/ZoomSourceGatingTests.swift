import XCTest

/// Static verification of the zoom feature's cross-cutting rules — the ones
/// `swift test` cannot otherwise see because they live in the (untested by
/// convention) macOS view layer.
///
/// A repository-file suite in the `LSPSourceGatingTests`/`SparkleSourceGatingTests`
/// mould: it reads `Sources/` through `#filePath` with Foundation only, and it
/// reuses that suite's Swift scanner, so **comments and string literals are
/// stripped before anything is matched**. That is load-bearing here for the usual
/// reason and then some: every file this suite reads documents its own zoom rules
/// at length — `ZoomSurface.swift` names `LineNumberRulerView` and `MinimapView`
/// in prose, `InterfaceScaleEnvironment.swift` explains what multiplying
/// `interfaceScale` inline would do, and `CommitUnifiedDiffView` discusses the
/// interface scale in order to say it does *not* use it. A raw `contains` would
/// pass on all three while the code they describe was deleted.
///
/// What is checked, and why each rule is invisible to the compiler:
///
/// - **The interface scale reaches views only as `InterfaceMetrics`.** CLAUDE.md
///   states it as an invariant. A view writing `settings.interfaceScale * 8`
///   compiles perfectly and looks right at 100%, which is exactly when it would
///   be reviewed.
/// - **Every SwiftUI root injects it.** A new `NSHostingController` root that
///   forgets `.interfaceScaled(settings)` silently draws its whole window at the
///   resting size — no error, no warning, and it looks correct until somebody
///   zooms.
/// - **Every zoom surface is declared.** This is the one that has already gone
///   wrong: a view drawn at the code font but *beside* the text view rather than
///   inside it (a ruler, the minimap) produces no hit-test candidate, so the
///   pointer over it resolves to `.interface` and the gesture resizes the whole
///   application chrome. Nothing about that fails to compile.
/// - **The Preferences terminal stepper reads its grid from `ZoomScaleRule`.**
///   Hard-coding `in: 8...40, step: 2` there compiles and drifts silently from the
///   grid the gestures and ⌘0 use.
final class ZoomSourceGatingTests: XCTestCase {

    // MARK: - The interface scale never reaches a view as a raw number

    /// The only files allowed to name `interfaceScale` as a whole word.
    ///
    /// Three in Core — the rule that bounds it, the metrics built from it, the
    /// store that persists it — and exactly one in the app: the environment
    /// plumbing, which reads it in order to build `InterfaceMetrics` and hand
    /// *that* to views. Note `interfaceScaled` (the modifier) is a different
    /// token and is not matched, which is what lets every root apply it.
    private static let interfaceScaleOwners: Set<String> = [
        "InterfaceMetrics.swift",
        "ZoomScaleRule.swift",
        "SettingsStore.swift",
        "InterfaceScaleEnvironment.swift",
    ]

    func testOnlyThePlumbingNamesTheRawInterfaceScale() throws {
        var offenders: [String] = []
        for url in try Self.swiftSources() {
            let name = url.lastPathComponent
            guard !Self.interfaceScaleOwners.contains(name) else { continue }
            let code = LSPSourceGatingTests.strippingCommentsAndStringLiterals(try Self.read(url))
            if LSPSourceGatingTests.containsToken("interfaceScale", in: code) {
                offenders.append(name)
            }
        }
        XCTAssertEqual(
            offenders, [],
            "the interface scale must reach views as InterfaceMetrics through \\.interfaceMetrics, never as a raw multiplier"
        )

        // The sweep found the owners it was supposed to, so a rename cannot empty
        // the check above into a vacuous pass.
        for owner in Self.interfaceScaleOwners {
            let url = try XCTUnwrap(
                try Self.swiftSources().first { $0.lastPathComponent == owner },
                "\(owner) is gone — update interfaceScaleOwners"
            )
            let code = LSPSourceGatingTests.strippingCommentsAndStringLiterals(try Self.read(url))
            XCTAssertTrue(
                LSPSourceGatingTests.containsToken("interfaceScale", in: code),
                "\(owner) no longer names interfaceScale — it should not be an owner"
            )
        }
    }

    // MARK: - Every root injects the environment

    /// Every file that *applies* `.interfaceScaled(...)`: each SwiftUI root that
    /// receives the shared `SettingsStore` — the main window, the `Settings` scene
    /// (applied by `PisakaApp` at the scene, so it reaches the settings form
    /// itself) and the five `NSHostingController` roots.
    /// `InterfaceScaleEnvironment.swift` is deliberately absent: it *declares*
    /// the modifier rather than using it.
    ///
    /// Most sheets inherit the scale and need no entry of their own — but only
    /// the ones a root presents from *inside* the body that publishes it. The
    /// two that cannot are covered by
    /// `testTheSheetPresentersInjectTheScaleOnTheirContent` below; this test
    /// cannot see them, because it counts files rather than call sites.
    ///
    /// Asserted by **set equality**, in both directions: a new root that forgets
    /// the modifier never appears here, and a root deleted without updating this
    /// list fails rather than quietly shrinking the check.
    private static let interfaceScaledRoots: Set<String> = [
        "ContentView.swift",
        "PisakaApp.swift",
        "DiffWindowContent.swift",
        "SourceViewerContent.swift",
        "ProjectSearchView.swift",
        "MergeView.swift",
        "LeetCodeBrowserView.swift",
    ]

    func testTheInterfaceScaledRootsAreExactlyTheDocumentedSet() throws {
        var found: Set<String> = []
        for url in try Self.swiftSources() {
            let code = LSPSourceGatingTests.strippingCommentsAndStringLiterals(try Self.read(url))
            if code.contains(".interfaceScaled(") { found.insert(url.lastPathComponent) }
        }
        XCTAssertEqual(found, Self.interfaceScaledRoots)
    }

    /// The files that inject the scale **more than once** — at their root *and*
    /// again on the content of a presentation that cannot inherit it.
    ///
    /// A sheet inherits the environment of the view its `.sheet(…)` is attached
    /// to, which is not the same thing as the environment that view's *body*
    /// publishes. Two presentations sit outside the write and had rendered at
    /// 100% over a window at 200%:
    ///
    /// - `PisakaApp` attaches the LeetCode sheets at the scene, around
    ///   `ContentView`, while `ContentView` injects the scale inside its own
    ///   body — below the presentation, so unreachable from it. (The commit
    ///   dialog is the near-miss that makes this look fine: `ContentView`
    ///   presents it from that same body *before* the injection, so there the
    ///   injection really is an ancestor.)
    /// - `LeetCodeBrowserView` attaches its sign-in sheet *after*
    ///   `.interfaceScaled(settings)` in the same chain, and a later modifier
    ///   wraps the environment write rather than descending from it.
    ///
    /// Asserted by set equality, like the roots above, and for the same reason
    /// in both directions: deleting either injection drops that file back to one
    /// call site and fails here, and a new multi-injection file has to be
    /// explained rather than counted.
    private static let interfaceScaledSheetPresenters: Set<String> = [
        "PisakaApp.swift",
        "LeetCodeBrowserView.swift",
    ]

    func testTheSheetPresentersInjectTheScaleOnTheirContent() throws {
        var found: Set<String> = []
        for url in try Self.swiftSources() {
            let code = LSPSourceGatingTests.strippingCommentsAndStringLiterals(try Self.read(url))
            if code.components(separatedBy: ".interfaceScaled(").count - 1 > 1 {
                found.insert(url.lastPathComponent)
            }
        }
        XCTAssertEqual(
            found, Self.interfaceScaledSheetPresenters,
            "a presentation attached outside the environment write must inject the scale on its own content"
        )
    }

    // MARK: - Every zoom surface is declared

    /// Every file that declares a zoom surface, by conformance or by planting the
    /// SwiftUI marker.
    ///
    /// The list reads as the answer to "what can the pointer be over that is not
    /// chrome": the four code text views and the `CodeScrollView` each is the
    /// document of (a content-sized text view answers only for its text, not for
    /// the pane around it), the three views that draw *beside* them (two rulers
    /// and the minimap — siblings of a text view, so unreachable through it),
    /// SwiftTerm's terminal view, and the four SwiftUI-drawn code regions that
    /// carry `ZoomSurfaceMarker`.
    ///
    /// Set equality rather than a subset check, because both directions are the
    /// bug: a code surface that stops declaring itself starts zooming the chrome,
    /// and a *new* surface appearing here without a line in
    /// `docs/architecture/core-zoom.md` is the drift this suite exists to catch.
    private static let zoomSurfaceDeclarers: Set<String> = [
        // The protocol and the marker themselves.
        "ZoomSurface.swift",
        // The four code text views.
        "CodeEditorView.swift",
        "DiffView.swift",
        "MergeView.swift",
        "SourceViewerContent.swift",
        // Drawn beside a text view, so unreachable through it.
        "LineNumberRulerView.swift",
        "MinimapView.swift",
        // The terminal.
        "TerminalSession.swift",
        // SwiftUI-drawn code regions.
        "ProjectSearchView.swift",
        "LeetCodeDescriptionView.swift",
        "CommitUnifiedDiffView.swift",
        "CommitDialogView.swift",
    ]

    func testTheZoomSurfacesAreExactlyTheDocumentedSet() throws {
        var found: Set<String> = []
        for url in try Self.swiftSources() {
            let code = LSPSourceGatingTests.strippingCommentsAndStringLiterals(try Self.read(url))
            if code.contains("ZoomSurfaceProviding") || code.contains("ZoomSurfaceMarker(kind:") {
                found.insert(url.lastPathComponent)
            }
        }
        XCTAssertEqual(found, Self.zoomSurfaceDeclarers)
    }

    /// The four files that build a code pane, each of which must scroll its text
    /// view inside a `CodeScrollView` rather than a plain `NSScrollView`.
    private static let codePaneBuilders: Set<String> = [
        "CodeEditorView.swift",
        "DiffView.swift",
        "MergeView.swift",
        "SourceViewerContent.swift",
    ]

    func testTheCodePanesScrollInsideTheCodeScrollView() throws {
        // The companion to the surface list above, and the rule it cannot state:
        // all four text views are content-sized (`minSize = .zero`, both resizable
        // flags, an unbounded container), so each answers only for the area its
        // text covers. With a plain `NSScrollView` the pointer below the last line
        // or right of the longest one is over no conforming view at all, and the
        // gesture resizes the whole chrome — while every one of these files still
        // appears in `zoomSurfaceDeclarers`, so nothing above notices.
        var offenders: [String] = []
        var found: Set<String> = []
        for url in try Self.swiftSources() {
            let name = url.lastPathComponent
            let code = LSPSourceGatingTests.strippingCommentsAndStringLiterals(try Self.read(url))
            if code.contains("CodeScrollView()") { found.insert(name) }
            // A code pane that constructs the stock scroll view is the regression;
            // `ZoomSurface.swift` declares the subclass and builds no pane.
            if Self.codePaneBuilders.contains(name), code.contains("NSScrollView()") {
                offenders.append(name)
            }
        }
        XCTAssertEqual(offenders, [], "a code pane still builds a plain NSScrollView, so its empty region zooms the chrome")
        XCTAssertEqual(found, Self.codePaneBuilders)
    }

    // MARK: - The hover popover is chrome, not a surface

    /// The hover popover's whole claim to being chrome is one line of AppKit
    /// configuration, and nothing else in the repository can see it.
    ///
    /// `ZoomSurface.swift` states the rule this rests on — **unreachable ≡
    /// chrome** — and the popover is the one view in the app that satisfies it by
    /// *construction* rather than by position: it draws code at the editor's own
    /// font, floats directly over the text view, and would by every other measure
    /// be a code surface. What makes it chrome instead is `ignoresMouseEvents`,
    /// which means the pointer is over the editor even when it looks as though it
    /// is over the popover — so a zoom aimed there is a zoom of the code, which is
    /// what the user means.
    ///
    /// Delete that one line and everything still compiles, still draws identically
    /// and still passes `testTheZoomSurfacesAreExactlyTheDocumentedSet` (the panel
    /// declares no surface either way). What changes is invisible until somebody
    /// zooms over a popover: the panel becomes a hit-test obstacle standing
    /// between the pointer and the code, so the walk finds no conforming view and
    /// the gesture resizes the whole application chrome — and, worse, clicks and
    /// drag-selection stop reaching the text at all. Hence this assertion, over
    /// comment- and literal-stripped source like its siblings, since the file
    /// explains the rule at length in prose a raw `contains` would match.
    func testTheHoverPanelPassesEveryMouseEventThroughToTheCode() throws {
        let url = try XCTUnwrap(
            try Self.swiftSources().first { $0.lastPathComponent == "HoverPanel.swift" },
            "HoverPanel.swift is gone — the hover popover's chrome rule has no home"
        )
        let code = LSPSourceGatingTests.strippingCommentsAndStringLiterals(try Self.read(url))

        XCTAssertTrue(
            code.contains("ignoresMouseEvents = true"),
            "the hover panel must pass mouse events through: it is chrome only because the pointer cannot reach it"
        )
        // And it must not take focus either — a popover that can become key steals
        // the editor's first-responder status mid-typing.
        XCTAssertTrue(
            code.contains("override var canBecomeKey: Bool { false }"),
            "the hover panel must refuse key status"
        )
        // The other half of the same rule, stated where the reason for it lives:
        // an unreachable view declaring a surface would be a candidate the pointer
        // can never actually be over.
        for file in ["HoverPanel.swift", "HoverController.swift"] {
            let url = try XCTUnwrap(
                try Self.swiftSources().first { $0.lastPathComponent == file },
                "\(file) is gone — update this test with the feature"
            )
            let code = LSPSourceGatingTests.strippingCommentsAndStringLiterals(try Self.read(url))
            XCTAssertFalse(
                LSPSourceGatingTests.containsToken("ZoomSurfaceProviding", in: code),
                "\(file) declares a zoom surface the pointer can never reach"
            )
            XCTAssertFalse(
                code.contains("ZoomSurfaceMarker(kind:"),
                "\(file) plants a zoom surface marker the pointer can never reach"
            )
        }
    }

    // MARK: - The Preferences stepper shares the zoom grid

    func testThePreferencesTerminalStepperReadsItsGridFromTheZoomRule() throws {
        // `SettingsStoreTests` can only assert that the *store* accepts the rule's
        // bounds; whether the row presents them is a fact about a view no unit
        // test can reach. Hard-coding `in: 8...40, step: 2` here would compile and
        // drift silently from the grid ⌘0 and the gestures land on.
        let url = try XCTUnwrap(
            try Self.swiftSources().first { $0.lastPathComponent == "SettingsView.swift" }
        )
        let code = LSPSourceGatingTests.strippingCommentsAndStringLiterals(try Self.read(url))
        let stepper = try XCTUnwrap(
            code.range(of: "$settings.terminalFontSize").map { code[$0.lowerBound...] },
            "the terminal font-size Stepper is gone from Preferences"
        )
        // Read only as far as the row's own closing brace region: the next
        // `Stepper(`/`Toggle(` after it starts a different row.
        let row = String(stepper.prefix(400))
        XCTAssertTrue(row.contains("ZoomScaleRule.terminalFont.minimum"), "the lower bound is not the rule's")
        XCTAssertTrue(row.contains("ZoomScaleRule.terminalFont.maximum"), "the upper bound is not the rule's")
        XCTAssertTrue(row.contains("ZoomScaleRule.terminalFont.step"), "the step is not the rule's")
    }

    // MARK: - Reading the sources

    /// Every Swift file under `Sources/`, found relative to this file so the suite
    /// needs no bundle and no Xcode build.
    private static func swiftSources() throws -> [URL] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PisakaCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repository root
            .appendingPathComponent("Sources")
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil),
            "Sources/ is unreadable"
        )
        let urls = enumerator
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.path < $1.path }
        XCTAssertFalse(urls.isEmpty, "found no Swift sources — the walk is broken, not the code")
        return urls
    }

    private static func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }
}
