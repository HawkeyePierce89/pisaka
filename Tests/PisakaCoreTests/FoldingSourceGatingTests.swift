import XCTest

/// Static verification of code folding's cross-layer wiring rules.
///
/// A repository-file suite in the `DatabaseViewerSourceGatingTests` shape: it
/// reads `Sources/` through `#filePath` with Foundation only and strips comments
/// and string literals with `LSPSourceGatingTests`'s Swift scanner before
/// matching. Load-bearing, not tidy — every file this suite reads states its own
/// rules in prose, and most of them quote the very tokens matched below (the
/// controller's own doc comment names `FoldShift`, the ruler's names
/// `FoldRegionScanner`, the layout manager's names `GlyphProperty.null`), so a
/// raw `contains` would stay green on a comment describing a call site that has
/// been deleted.
///
/// **Why the compiler cannot see any of this:**
///
/// 1. Hiding is two halves of one mechanism that must agree. The glyph pass
///    stores `GlyphProperty.null` for every hidden character; the typesetter
///    subclass suppresses the line break of a hidden separator, because in
///    TextKit 1 a `.null` glyph on a separator still ends its line and would
///    leave a fold as a column of blank rows. Either half in a second file is a
///    second opinion about what is hidden, and both compile perfectly on their
///    own — the failure is a drawing artefact nobody's test can see.
/// 2. The compiler cannot keep the reveal funnel a funnel. Every jump into a
///    buffer must unfold what it lands in *before* it scrolls, or the caret ends
///    up parked inside hidden text with the view showing a placeholder. A new
///    `scrollRangeToVisible` beside a `setSelectedRange` compiles, runs, and
///    scrolls to a line that is not drawn — so the set of files allowed to
///    scroll a text view is pinned by equality, with the three named exclusions
///    (a read-only viewer, the merge result pane, iOS) carrying their reasons
///    here rather than in a hand-kept allowance nobody re-reads.
/// 3. The compiler cannot keep the caret out of hidden text either.
///    `FoldCaretRule` is a pure function whose *absence* is invisible: arrowing
///    into a folded block simply stops drawing a caret. It belongs in the one
///    coordinator that holds fold state, and the three other text views in the
///    app hold none — a fourth that started holding some would have to say so
///    here.
/// 4. The compiler cannot stop a view from deciding what `FoldState` decides.
///    Every rule about what is folded — the two-line minimum, the merge between
///    a bracket candidate and an indentation one, the shift's three-way test —
///    lives in Core and is unit-tested there. A view re-deriving any of them
///    compiles and produces a second, subtly different answer that no Core test
///    can reach.
/// 5. The compiler cannot ensure the app-side fold files are macOS-gated;
///    without `#if os(macOS)` they would break the iOS build, which has no
///    gutter chevron, no layout-manager subclass and no menu surface.
/// 6. The compiler cannot enforce that folding stays a **reader**. Naming
///    `autosave.suspend()` / `localChanges.beginRevert()` inside the feature
///    would compile perfectly and turn a debounced background question about
///    where the blocks are into a gate the editor waits behind — the same rule
///    the symbol index lives under, and for the same reason.
final class FoldingSourceGatingTests: XCTestCase {

    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // PisakaCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // <root>

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

    private func code(of url: URL) throws -> String {
        LSPSourceGatingTests.strippingCommentsAndStringLiterals(
            try String(contentsOf: url, encoding: .utf8)
        )
    }

    private func code(ofFileNamed name: String, under relativeDirectory: String) throws -> String {
        try code(of: Self.repositoryRoot.appendingPathComponent(relativeDirectory + "/" + name))
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

    // MARK: - Hiding lives in one file, both halves

    /// The glyph half and the typesetter half are one mechanism, and they live
    /// together.
    ///
    /// Both were planned as both from the start: a `.null` glyph is not drawn and
    /// advances nothing, but in TextKit 1 the separator it sits on still *ends
    /// its line*, so hiding without the typesetter draws a folded block as a run
    /// of empty rows rather than as nothing at all. Splitting the two across
    /// files is how they come to disagree about which characters are hidden —
    /// and neither half's failure is visible to any assertion the test target can
    /// make, because both are drawing.
    func testHidingLivesInOneFileAndBothHalvesAreThere() throws {
        let manager = try code(ofFileNamed: "BracketOverlayLayoutManager.swift", under: "Sources/Pisaka")

        XCTAssertGreaterThan(
            try occurrences(of: "GlyphProperty\\.null", in: manager),
            0,
            "The glyph half must be here: hidden characters are stored with a null glyph property, which is "
                + "what keeps every UTF-16 offset meaning the same thing folded and unfolded."
        )
        XCTAssertGreaterThan(
            try occurrences(of: "override func setGlyphs\\b", in: manager),
            0,
            "And it must be the glyph-generation override that does it — the one pass that sees a character "
                + "index beside every glyph."
        )
        XCTAssertGreaterThan(
            try occurrences(of: "NSATSTypesetter\\b", in: manager),
            0,
            "The typesetter half must be here too: without it a folded block is a column of blank rows."
        )
        XCTAssertGreaterThan(
            try occurrences(of: "actionForControlCharacter\\b", in: manager),
            0,
            "And it must be the control-character action that suppresses the hidden separator's line break."
        )

        XCTAssertEqual(
            try fileNames(matching: "GlyphProperty\\.null|override func setGlyphs\\b", under: "Sources"),
            ["BracketOverlayLayoutManager.swift"],
            "Exactly one file may hide text. A second glyph-generation override is a second answer to what is "
                + "hidden, and the two would disagree silently — nothing crashes, the text is simply drawn wrong."
        )
        XCTAssertEqual(
            try fileNames(matching: "NSATSTypesetter\\b|actionForControlCharacter\\b", under: "Sources"),
            ["BracketOverlayLayoutManager.swift"],
            "And exactly one file may suppress a line break. The typesetter half is meaningless apart from the "
                + "glyph half that decides what is hidden; the two belong in the same file for the same reason "
                + "they belong in the same commit."
        )
    }

    // MARK: - The menu surface

    /// The whole menu surface of folding is one file, and the scene names it once.
    func testTheFoldCommandsLiveInOneFileAndTheSceneNamesThemOnce() throws {
        XCTAssertEqual(
            try fileNames(matching: "\\.(leftArrow|rightArrow), modifiers: \\[\\.command, \\.option\\]", under: "Sources"),
            ["FoldCommands.swift"],
            "⌘⌥← and ⌘⌥→ are spelled in exactly one file. An app-wide key equivalent fires wherever the "
                + "keystroke lands, so a second declaration of either is two menu items racing for one chord."
        )

        let app = try code(ofFileNamed: "PisakaApp.swift", under: "Sources/Pisaka")
        XCTAssertEqual(
            try occurrences(of: "\\bFoldCommands\\b", in: app),
            1,
            "The scene names the commands exactly once — the one line that adds them. Nothing else about "
                + "folding appears in the scene file, and a second mention would be the beginning of it."
        )

        XCTAssertEqual(
            try fileNames(matching: "\\b(foldAtCaret|unfoldAtCaret)\\b", under: "Sources"),
            ["FoldCommands.swift", "CodeEditorView.swift"],
            "The two command entry points are declared by the text view and called by the commands, and by "
                + "nobody else: a third caller would be a fold gesture that never asked the first responder "
                + "which editor it meant."
        )
    }

    /// Fold All / Unfold All — the two new chords, their entry points and the
    /// unchanged three-mutation count.
    func testFoldAllChordsAndEntryPoints() throws {
        XCTAssertEqual(
            try fileNames(matching: "\\.leftArrow, modifiers: \\[\\.command, \\.option, \\.shift\\]", under: "Sources"),
            ["FoldCommands.swift"],
            "⌘⌥⇧← is spelled in exactly one file. An app-wide key equivalent fires wherever the keystroke "
                + "lands, so a second declaration is two menu items racing for one chord."
        )
        XCTAssertEqual(
            try fileNames(matching: "\\.rightArrow, modifiers: \\[\\.command, \\.option, \\.shift\\]", under: "Sources"),
            ["FoldCommands.swift"],
            "⌘⌥⇧→ is spelled in exactly one file, for the same reason."
        )
        XCTAssertEqual(
            try fileNames(matching: "\\b(foldAll|unfoldAll)\\b", under: "Sources"),
            ["CodeEditorView.swift", "FoldCommands.swift", "FoldController.swift"],
            "The two new entry points are declared by the text view (CodeEditorView) and called by the "
                + "commands (FoldCommands); the controller also exposes same-named whole-value operations "
                + "that hand a value through apply(_:), so three files name them. A fourth caller would be "
                + "a fold gesture that never asked the first responder which editor it meant."
        )
        XCTAssertEqual(
            try fileNames(matching: "\\bonFoldAll\\b", under: "Sources"),
            ["CodeEditorView.swift"],
            "The Fold All closure is declared by the text view alone."
        )
        XCTAssertEqual(
            try fileNames(matching: "\\bonUnfoldAll\\b", under: "Sources"),
            ["CodeEditorView.swift"],
            "The Unfold All closure is declared by the text view alone."
        )
        XCTAssertEqual(
            try occurrences(
                of: "\\b\\w+\\.(fold|unfold|toggle)\\(region\\)",
                in: try code(ofFileNamed: "FoldController.swift", under: "Sources/Pisaka")
            ),
            3,
            "Three mutations, one per gesture: toggle (the chevron), fold (⌘⌥←) and unfold (⌘⌥→ and the "
                + "placeholder click). Fold All and Unfold All hand a whole value through apply(_:), which "
                + "is what keeps the layout manager, the gutter and the memory from ever disagreeing."
        )
    }

    // MARK: - The reveal funnel

    /// Every jump into a buffer unfolds what it lands in before it scrolls.
    ///
    /// Four sets, each by equality:
    ///
    /// 1. The coordinator's `revealRange(_:)` is called from the coordinator
    ///    itself (the app's reveal request lands there through `applyReveal`) and
    ///    from the find bar, whose one jump was routed through it. `UsageResult
    ///    .revealRange(naming:in:)` is a different function on a different type
    ///    and is excluded by its first argument label.
    /// 2. `FoldReveal` is named in the coordinator alone: the rule that decides
    ///    *which* blocks a range opens is Core's, and one caller is what makes
    ///    the funnel a funnel.
    /// 3. Scrolling a text view is the act that must never happen without the
    ///    unfold in front of it. The three named exclusions hold no fold state at
    ///    all — `SourceViewerContent` is the read-only out-of-project viewer,
    ///    `MergeView`'s is the merge result pane, and the iOS coordinator is on
    ///    the platform folding does not ship to. `CodeEditorView` is pinned to
    ///    exactly two: the funnel's own scroll and the Tab plan's caret scroll,
    ///    the one in-file site that is not a reveal (it follows an edit the user
    ///    just made, at a caret that is by construction on a visible line).
    ///    `EditorSearchController` must have none left.
    /// 4. `EditorRevealState.reveal(fileID:range:)` is driven from the scene (both
    ///    of whose sites land in the editor's funnel through `applyReveal`) and
    ///    from the source-viewer window controller, which drives that window's own
    ///    reveal state and is excluded by name.
    func testTheRevealFunnelIsAFunnel() throws {
        XCTAssertEqual(
            try fileNames(matching: "(?<!func )\\brevealRange\\??\\((?!naming)", under: "Sources"),
            ["CodeEditorView.swift", "EditorSearchController.swift"],
            "Exactly two files call the coordinator's reveal. Anything else jumping into a buffer would be a "
                + "jump that does not unfold first — a caret parked inside hidden text, with the view showing "
                + "a placeholder where it thinks it is."
        )

        XCTAssertEqual(
            try fileNames(naming: "FoldReveal", under: "Sources/Pisaka"),
            ["CodeEditorView.swift"],
            "The reveal rule is named in one app file. Which blocks a range opens is Core's decision; a second "
                + "caller is a second place that decision could be taken differently."
        )

        XCTAssertEqual(
            try fileNames(matching: "\\bscrollRangeToVisible\\b", under: "Sources/Pisaka"),
            [
                "CodeEditorView.swift",
                "SourceViewerContent.swift",
                "MergeView.swift",
                "CodeEditorCoordinator_iOS.swift",
            ],
            "Four files scroll a text view, and three of them are named exclusions holding no fold state: the "
                + "read-only out-of-project viewer, the merge result pane and iOS. A fifth is a jump that "
                + "skipped the funnel."
        )
        XCTAssertEqual(
            try occurrences(
                of: "\\bscrollRangeToVisible\\b",
                in: try code(ofFileNamed: "CodeEditorView.swift", under: "Sources/Pisaka")
            ),
            2,
            "Two scrolls in the editor: the funnel's own, and the Tab plan's caret scroll — the one in-file "
                + "site that is not a reveal, following an edit the user just made at a caret that is on a "
                + "visible line by construction. A third would need its own reason, here."
        )
        XCTAssertEqual(
            try occurrences(
                of: "\\bscrollRangeToVisible\\b",
                in: try code(ofFileNamed: "EditorSearchController.swift", under: "Sources/Pisaka")
            ),
            0,
            "The find bar's one jump was routed through the funnel and must not keep a scroll of its own: a "
                + "match inside a folded block is exactly the case the routing exists for."
        )

        XCTAssertEqual(
            try fileNames(matching: "\\breveal\\.reveal\\(", under: "Sources/Pisaka"),
            ["PisakaApp.swift", "SourceViewerWindowController.swift"],
            "Two files post a reveal request: the scene, whose requests land in the editor's funnel through "
                + "applyReveal, and the source-viewer window controller, which drives that window's own "
                + "EditorRevealState and is excluded by name."
        )
    }

    // MARK: - The caret rule

    /// The caret never lands inside hidden text, and one file says so.
    func testTheCaretRuleIsNamedInOneFile() throws {
        XCTAssertEqual(
            try fileNames(naming: "FoldCaretRule", under: "Sources/Pisaka"),
            ["CodeEditorView.swift"],
            "One coordinator holds fold state, so one coordinator applies the caret rule."
        )

        for name in ["MergeView.swift", "SourceViewerContent.swift"] {
            XCTAssertFalse(
                LSPSourceGatingTests.containsToken(
                    "FoldCaretRule",
                    in: try code(ofFileNamed: name, under: "Sources/Pisaka")
                ),
                "\(name) is a named non-caller: its text view holds no fold state, so there is no hidden text "
                    + "for a caret to land in."
            )
        }
        XCTAssertFalse(
            LSPSourceGatingTests.containsToken(
                "FoldCaretRule",
                in: try code(ofFileNamed: "CodeEditorCoordinator_iOS.swift", under: "Sources/Pisaka/iOS")
            ),
            "And iOS is the third: folding is macOS-only in part 1, so its editor hides nothing."
        )
    }

    // MARK: - No view decides what the state decides

    /// Every rule about what is folded lives in Core.
    ///
    /// `FoldState` is a value type, so mutating it means holding a `var` — which
    /// is why the rule can be stated as *who names the type at all*. Two files
    /// do: the controller, which owns the one mutable copy, and the ruler, which
    /// is **told** a value and only ever asks it questions (`folded(containing:)`
    /// when it measures the placeholder, `isFolded` when it picks a chevron
    /// direction). The three mutating members are spelled in the controller and
    /// exactly three times, once per gesture — toggle, fold, unfold — with every
    /// other writer handing over a whole value through `apply(_:)`.
    ///
    /// The fallback scanner is named by no app file at all: the app asks the
    /// intelligence seam, which routes to a server or to the scanner, and an app
    /// file calling the scanner directly would quietly bypass whichever server
    /// serves the file.
    func testNoViewFileDecidesWhatTheStateDecides() throws {
        XCTAssertEqual(
            try fileNames(naming: "FoldState", under: "Sources/Pisaka"),
            ["FoldController.swift", "LineNumberRulerView.swift"],
            "Two app files hold a folded state: the controller, which owns it, and the gutter, which is told "
                + "it. A third holder is a third answer to what is hidden — and the layout manager is "
                + "deliberately not one of them: it takes the plain ranges, so it cannot ask a fold question "
                + "it might answer differently."
        )
        XCTAssertEqual(
            try occurrences(
                of: "\\bfoldedState\\.(fold|unfold|toggle)\\(",
                in: try code(ofFileNamed: "LineNumberRulerView.swift", under: "Sources/Pisaka")
            ),
            0,
            "The gutter never mutates what it was told. It draws the answer; it does not take a second one."
        )
        XCTAssertEqual(
            try occurrences(
                of: "\\b\\w+\\.(fold|unfold|toggle)\\(region\\)",
                in: try code(ofFileNamed: "FoldController.swift", under: "Sources/Pisaka")
            ),
            3,
            "Three mutations, one per gesture: toggle (the chevron), fold (⌘⌥←) and unfold (⌘⌥→ and the "
                + "placeholder click). Every other writer hands over a whole value through apply(_:), which is "
                + "what keeps the layout manager, the gutter and the memory from ever disagreeing."
        )

        XCTAssertEqual(
            try fileNames(naming: "FoldRegionScanner", under: "Sources/Pisaka"),
            [],
            "No app file names the fallback scanner. The app asks the intelligence seam; calling the scanner "
                + "directly would answer brackets and indentation for a file a language server serves."
        )
        XCTAssertEqual(
            try fileNames(naming: "FoldShift", under: "Sources/Pisaka"),
            ["FoldController.swift"],
            "One file shifts folds across an edit, and it is the one that holds both line-start tables at that "
                + "moment."
        )
        XCTAssertEqual(
            try fileNames(naming: "FoldStateMemory", under: "Sources/Pisaka"),
            ["FoldController.swift"],
            "And one file remembers them across a tab switch — beside the viewport memory, on the same signals."
        )
        XCTAssertEqual(
            try fileNames(naming: "FoldCommandRule", under: "Sources/Pisaka"),
            ["CodeEditorView.swift"],
            "Which block a command acts on is Core's decision, asked in the one file that knows where the "
                + "caret is."
        )
        XCTAssertEqual(
            try fileNames(naming: "FoldSeverityRule", under: "Sources/Pisaka"),
            ["LineNumberRulerView.swift"],
            "The folded-header severity rule is named by exactly one app file: the gutter, which is the one "
                + "place holding both inputs and is already allowed to be told a FoldState. A second caller is "
                + "a second place that decision could be taken differently."
        )
        XCTAssertEqual(
            try occurrences(
                of: "\\bfoldedState\\.(fold|unfold|toggle)\\(",
                in: try code(ofFileNamed: "LineNumberRulerView.swift", under: "Sources/Pisaka")
            ),
            0,
            "The gutter still never mutates what it was told, even after gaining the severity rule. It draws "
                + "the answer; it does not take a second one."
        )

        for url in try swiftFiles(under: "Sources/Pisaka") {
            let code = try self.code(of: url)
            XCTAssertEqual(
                try occurrences(of: "\\bFoldRegion\\(", in: code),
                0,
                "\(url.lastPathComponent) must not construct a FoldRegion: the two-line minimum is the "
                    + "refusing initializer's rule, and a region the app assembled would be one nothing "
                    + "offered a chevron for."
            )
            for spelling in ["oldEnd", "isBracket"] {
                XCTAssertFalse(
                    LSPSourceGatingTests.containsToken(spelling, in: code),
                    "\(url.lastPathComponent) must not spell `\(spelling)`: that is the shift's three-way "
                        + "test and the scanner's merge rule respectively, both decided and tested in Core."
                )
            }
        }
    }

    // MARK: - Platform gating

    func testTheAppSideFoldFilesAreMacOSGated() throws {
        let foldFiles = try swiftFiles(under: "Sources/Pisaka")
            .filter { $0.lastPathComponent.hasPrefix("Fold") }
        XCTAssertEqual(
            Set(foldFiles.map(\.lastPathComponent)),
            ["FoldController.swift", "FoldCommands.swift"],
            "The app half of folding is these two files; if it moved, this suite is looking in the wrong place."
        )
        for url in foldFiles {
            let firstLine = try code(of: url)
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty }
            XCTAssertEqual(
                firstLine,
                "#if os(macOS)",
                "\(url.lastPathComponent) must open with #if os(macOS): folding is macOS-only in part 1, and "
                    + "an ungated file would break the iOS build (AppKit, NSApp and the layout-manager "
                    + "subclass exist on neither destination's other half)."
            )
        }
    }

    func testTheIOSLayerNamesNothingUnderTheFoldFeature() throws {
        for url in try swiftFiles(under: "Sources/Pisaka/iOS") {
            let code = try self.code(of: url)
            for name in [
                "FoldController", "FoldCommands", "FoldState", "FoldRegion",
                "FoldReveal", "FoldCaretRule", "FoldCommandRule", "FoldShift",
                "FoldRegionScanner", "FoldStateMemory", "FoldingTypesetter",
            ] {
                XCTAssertFalse(
                    LSPSourceGatingTests.containsToken(name, in: code),
                    "\(url.lastPathComponent) must not name \(name): iOS ships no fold surface, and a "
                        + "reference here is a half-built one that compiles."
                )
            }
        }
    }

    // MARK: - A reader, like the index

    /// Folding takes no writer gate and is gated by none.
    ///
    /// The candidate list is a debounced background question about a buffer
    /// nobody is writing to disk. Raising the gate around it would serialize the
    /// editor behind it; refusing to ask while the gate is up would leave the
    /// chevrons stale for exactly as long as a branch switch takes, for an answer
    /// that costs nothing to recompute.
    func testTheFoldLayerNamesNoWriterGate() throws {
        for name in ["FoldController.swift", "FoldCommands.swift"] {
            let code = try self.code(ofFileNamed: name, under: "Sources/Pisaka")
            for gate in ["autosave", "localChanges"] {
                XCTAssertFalse(
                    LSPSourceGatingTests.containsToken(gate, in: code),
                    "\(name) must not name \(gate): folding is a reader, like the symbol index. It writes "
                        + "nothing — not the buffer, not the session, not the disk — so there is nothing for a "
                        + "writer gate to order it against."
                )
            }
        }
    }
}
