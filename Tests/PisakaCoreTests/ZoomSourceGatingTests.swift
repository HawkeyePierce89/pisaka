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
    /// itself) and the five `NSHostingController` roots. Sheets inherit it from
    /// whatever presents them and are deliberately absent, and so is
    /// `InterfaceScaleEnvironment.swift`, which *declares* the modifier rather
    /// than using it.
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

    // MARK: - Every zoom surface is declared

    /// Every file that declares a zoom surface, by conformance or by planting the
    /// SwiftUI marker.
    ///
    /// The list reads as the answer to "what can the pointer be over that is not
    /// chrome": the four code text views, the three views that draw *beside* them
    /// (two rulers and the minimap — siblings of a text view, so unreachable
    /// through it), SwiftTerm's terminal view, and the four SwiftUI-drawn code
    /// regions that carry `ZoomSurfaceMarker`.
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
