import XCTest

/// Static verification of the bottom dock panel's layout rules — the ones
/// `swift test` cannot otherwise see because they live in the (untested by
/// convention) macOS view layer, in `ContentView.swift` and the dock container
/// it delegates to, `BottomDockColumn.swift`.
///
/// A repository-file suite in the `ZoomSourceGatingTests` mould: it reads
/// `Sources/Pisaka/ContentView.swift` and `Sources/Pisaka/BottomDockColumn.swift`
/// through `#filePath` with Foundation only
/// and reuses `LSPSourceGatingTests`'s Swift scanner, so **comments and string
/// literals are stripped before anything is matched**. That is load-bearing
/// here for the usual reason and then some: the file documents every one of
/// these rules at length, naming the deleted `frame(minHeight:)` modifiers, the
/// `.local` coordinate space it no longer uses and the 10pt jump the default
/// `minimumDistance` caused. A raw `contains` would stay green on all three
/// while the code they describe was reverted.
///
/// What is checked, and why each rule is invisible to the compiler:
///
/// - **Panel content states no minimum height.** This is the *precondition*
///   behind "the panel never paints over the bottom bar"
///   (`BottomPanelHeightRule`'s doc comment, `app-window.md`): the panel is
///   rendered into a slot of exactly the rule's height, and a minimum stated
///   inside a fixed-height slot can never be satisfied — the child cannot make
///   the slot grow, so its only outcome is to overflow. Re-adding
///   `.frame(minHeight: metrics.scaled(160))` to the Log branch compiles, looks
///   entirely reasonable in review, and restores the exact bleed this feature
///   was written to fix. The branch bodies in `panelContent(_:)` are only half
///   of it: what lands in the slot is a *view*, and a minimum on that view's own
///   `body` root reaches the slot exactly as one written at the call site would
///   — `TerminalPanelView` carried one, in its own file, for the whole life of
///   this rule. So the six hosted panel roots (and `ContentView`'s
///   `problemsPanel` and `usagesPanel`, each one hop from the branch it serves)
///   are read too — each
///   hosted view **whole**, `struct` brace to matching brace, not by its `var
///   body` alone: most of those bodies are pure delegation, so a minimum
///   written on the `content` property they compose reaches the slot exactly as
///   one on `body` would, and `body`-only scanning would miss the likeliest
///   place to reintroduce this. The private row and detail structs later in
///   those same files are outside the declaration and stay unmatched, which is
///   how `CommitRow`'s legitimate per-row `minHeight` is excluded without an
///   exemption list: a minimum inside a row of a scrolling list is a different
///   thing and is deliberately not matched. The per-panel table is pinned to
///   the `case .…:` labels of `panelContent(_:)` **by set equality**, so the
///   inventory cannot fall behind the enum: the compiler already forces that
///   switch to cover every `BottomPanel` case, and without the tie a new
///   panel would put another view in the slot with no minimum check at all
///   while this suite stayed green.
/// - **The drag is measured in the column's named coordinate space, with
///   `minimumDistance: 0`.** `DragGesture()` — the default — compiles and
///   type-checks identically while measuring against an origin the drag itself
///   moves, which oscillates instead of tracking. Nothing but a human dragging
///   the divider can tell the two apart at runtime. The drag is built in
///   `ContentView`, the space is published by `BottomDockColumn`, and the name
///   crosses the seam as the column's `coordinateSpaceName`, so all three
///   halves are read.
/// - **The column is pinned to the area, top-leading, and carries no clip; the
///   bottom bar is drawn above it instead.** A clip of any spelling —
///   `clipped`, `clipShape`, `mask`, `cornerRadius`, called with an argument
///   list or a trailing closure alike — anywhere in
///   `BottomDockColumn.swift`, or in `ContentView`'s `body`, `mainArea` or
///   `editorSplit`, sits above the editor's `HSplitView`, and a clip above that split makes its
///   panes drop the window's top safe-area inset: the whole top row slides under
///   the transparent title bar with the dock open and sits correctly with it
///   closed. It compiles, it is invisible in every gate but a hosted window
///   (`BottomDockLayoutTests` measures it and records the bisection), and it is
///   the most natural thing to add back to a column whose overflow must not
///   reach the bottom bar. That guarantee is the root's instead: `bottomBar`
///   carries `.zIndex(1)` in `ContentView.body`, on its own opaque `bgPanel`
///   ground — both halves read — so anything spilling off `mainArea`'s bottom
///   edge lands under it. The pin
///   stays because the coordinate space is published on it and because its
///   top-leading alignment is what sends the surplus down and to the trailing
///   edge rather than up or over the project tree's leading edge.
/// - **The slot itself is top-aligned.** The same argument one level in, and the
///   other half of the same guarantee: `.frame(height:)` defaults to `.center`,
///   which splits an overflowing child's surplus evenly and sends half of it
///   *upwards*, over the divider and into the editor — inside `mainArea`,
///   where the bar's cover cannot reach it. Deleting `alignment: .top` compiles, reads
///   as a harmless simplification, and leaves the guarantee covering the bottom
///   bar alone. The slot is built in `ContentView`'s `panel:` builder, so the
///   rule reads the modifiers between `panelContent(panel)` and that builder's
///   closing brace.
final class BottomPanelSourceGatingTests: XCTestCase {

    /// `ContentView.swift`, comment- and literal-stripped.
    private func contentViewCode() throws -> String {
        try appSource(named: "ContentView.swift")
    }

    /// `BottomDockColumn.swift`, comment- and literal-stripped.
    private func dockColumnCode() throws -> String {
        try appSource(named: "BottomDockColumn.swift")
    }

    /// One file under `Sources/Pisaka/`, comment- and literal-stripped.
    private func appSource(named name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PisakaCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repository root
            .appendingPathComponent("Sources/Pisaka/\(name)")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(source.isEmpty, "\(name) is unreadable — the walk is broken, not the code")
        return LSPSourceGatingTests.strippingCommentsAndStringLiterals(source)
    }

    /// The same code with **every** whitespace character removed, so a match is
    /// insensitive to how the call it looks for is wrapped across lines. Without
    /// this an ordinary reformat — the argument list of the pin below is already
    /// three lines long — fails the suite while the rule it guards is intact.
    private static func whitespaceFree(_ code: String) -> String {
        code.filter { !$0.isWhitespace }
    }

    // MARK: - Nothing in the fixed-height slot states a minimum

    func testPanelContentStatesNoMinimumHeight() throws {
        let contentView = try contentViewCode()
        var slotFacingBodies: [(what: String, code: String)] = []
        var panelContentBody = ""

        for name in ["panelContent", "problemsPanel", "usagesPanel"] {
            let body = try XCTUnwrap(
                Self.declarationBody(after: name, in: contentView),
                "\(name) not found in ContentView.swift — rename it and update this suite deliberately"
            )
            if name == "panelContent" { panelContentBody = body }
            slotFacingBodies.append(("ContentView.\(name)", body))
        }

        // The views `panelContent(_:)` puts in the slot, **one per
        // `BottomPanel` case**. Each is read **whole**, not by its `var body`
        // alone: most of those bodies are pure delegation
        // (`VStack { header; Divider(); content }`), and a minimum written on
        // `content` — where the list actually lives, and so the likeliest place
        // to reintroduce this — raises the `VStack`'s minimum and reaches the
        // slot exactly as one on `body` would. The private row/detail structs
        // later in the same files are *not* part of the declaration and stay
        // excluded, which is what keeps `CommitRow`'s legitimate
        // `minHeight: rowHeight` out of this: a minimum inside a row of a
        // scrolling list is a different thing, and deliberately not matched.
        let hostedRoots: [String: (file: String, type: String)] = [
            "terminal": ("TerminalPanelView.swift", "TerminalPanelView"),
            "log": ("CommitLogView.swift", "CommitLogView"),
            "changes": ("LocalChangesView.swift", "LocalChangesView"),
            "problems": ("ProblemsPanelView.swift", "ProblemsPanelView"),
            "usages": ("UsagesPanelView.swift", "UsagesPanelView"),
            "pullRequests": ("PullRequestsPanelView.swift", "PullRequestsPanelView"),
        ]

        // The tie that makes this table complete rather than merely long. A
        // new `BottomPanel` case forces another branch in `panelContent(_:)`
        // — the compiler makes that switch exhaustive, which is the one half of
        // this rule `swift test` gets for free — and that branch would put a
        // further view in the fixed-height slot with no minimum check at all
        // while this suite stayed green, the exact miss `TerminalPanelView`
        // already demonstrated for the whole life of the rule. Matching the
        // branch labels against the table by set equality is what turns adding
        // a panel into a deliberate edit here.
        let branchLabels = Self.switchCaseLabels(in: panelContentBody)
        XCTAssertEqual(
            branchLabels, Set(hostedRoots.keys),
            """
            panelContent(_:) and this suite's hosted-root table disagree about which panels exist. \
            Every BottomPanel case puts a view in the fixed-height slot, so every one of them needs \
            its root read here — add the new panel's view to the table, or drop the removed one.
            """
        )

        for (panel, root) in hostedRoots.sorted(by: { $0.key < $1.key }) {
            let code = try appSource(named: root.file)
            slotFacingBodies.append((
                "\(root.type) (BottomPanel.\(panel))",
                try XCTUnwrap(
                    Self.typeBody(root.type, in: code),
                    "\(root.type) is not declared in \(root.file) — rename it and update this suite deliberately"
                )
            ))
        }

        // The dock's tab row, which `panelContent(_:)` stacks above every
        // panel: it sits inside the same fixed-height slot, so a minimum stated
        // on it reaches the slot exactly as one on a panel would.
        slotFacingBodies.append((
            "DockTabRow",
            try XCTUnwrap(
                Self.typeBody("DockTabRow", in: try appSource(named: "DockTabRow.swift")),
                "DockTabRow is not declared in DockTabRow.swift — rename it and update this suite deliberately"
            )
        ))

        for (what, body) in slotFacingBodies {
            XCTAssertFalse(
                body.contains("minHeight"),
                """
                \(what) states a minimum height. The panel is rendered into a slot of exactly \
                `BottomPanelHeightRule`'s height, which the rule shrinks below its own floor when \
                the space cannot hold it — a child that demands more cannot make the slot grow, so \
                it can only overflow, over the divider above and the bottom bar below.
                """
            )
        }
    }

    // MARK: - The drag is measured where the divider does not move

    func testTheDividerDragUsesTheColumnsCoordinateSpace() throws {
        let code = Self.whitespaceFree(try contentViewCode())
        let gesture = Self.whitespaceFree(
            "DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.panelColumnSpace))"
        )
        XCTAssertTrue(
            code.contains(gesture),
            """
            The divider drag no longer names `panelColumnSpace`. `DragGesture`'s default `.local` \
            space is the divider's own, and the divider is what the drag moves: the translation \
            collapses to ~0 every frame and the panel oscillates instead of tracking the pointer. \
            `minimumDistance: 0` is the second half — the default makes the first `onChanged` \
            arrive with a >=10pt translation already accumulated.
            """
        )
        XCTAssertTrue(
            code.contains(Self.whitespaceFree("BottomDockColumn(coordinateSpaceName: Self.panelColumnSpace)")),
            "the dock column is no longer handed the space the divider drag is measured in"
        )
        XCTAssertTrue(
            Self.whitespaceFree(try dockColumnCode())
                .contains(Self.whitespaceFree("coordinateSpace(name: coordinateSpaceName)")),
            "the panel column no longer publishes the space its drag is measured in"
        )
    }

    // MARK: - The column is pinned and unclipped; the bar covers its overflow

    /// Every clipping modifier, in both call syntaxes: whitespace removal turns
    /// `.mask { Rectangle() }` into `mask{`, which an argument-list-only match
    /// would let through.
    private static let clipSpellings = ["clipped", "clipShape", "mask", "cornerRadius"]
        .flatMap { [$0 + "(", $0 + "{"] }

    func testThePanelColumnIsPinnedUnclippedAndCoveredByTheBottomBar() throws {
        let column = Self.whitespaceFree(try dockColumnCode())
        let pin = Self.whitespaceFree(
            "frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)"
        )
        XCTAssertTrue(column.contains(pin), """
            The panel column is not pinned to the `GeometryReader`'s size, top-*leading*. Without \
            the pin an oversized column reports its overflow and the divider's coordinate space \
            grows with it; `.top` alone centers horizontally, so a column wider than the area (the \
            split's panes state minimum widths the `GeometryReader` erases) would push half the \
            surplus off the project tree's leading edge.
            """)
        for clip in Self.clipSpellings {
            XCTAssertFalse(column.contains(clip), """
                `BottomDockColumn` contains `\(clip)`. A clip above the editor's `HSplitView` makes \
                the split's panes drop the window's top safe-area inset, so with the dock open the \
                whole top row slides under the title bar (`BottomDockLayoutTests`). The overflow \
                guarantee is the bottom bar's `.zIndex(1)` in `ContentView.body`, not a clip here.
                """)
        }
        // The column is one ancestor of the split; `ContentView` holds the
        // others — `body` wraps `mainArea`, `mainArea` wraps the column, and
        // `editorSplit` is the split's own modifier chain — and a clip at any of
        // them restores the bug just as one in the column would. A clip a pane
        // needs belongs in that pane's own declaration, below the split, as the
        // markdown split's does.
        let contentView = try contentViewCode()
        for name in ["body", "mainArea", "editorSplit"] {
            let declaration = Self.whitespaceFree(try XCTUnwrap(
                Self.declarationBody(after: name, in: contentView),
                "ContentView no longer declares `\(name)` — update this suite deliberately"
            ))
            for clip in Self.clipSpellings {
                XCTAssertFalse(declaration.contains(clip), """
                    `ContentView.\(name)` contains `\(clip)`. It is an ancestor of the editor's \
                    `HSplitView`, and a clip there drops the panes' top safe-area inset exactly as \
                    one in `BottomDockColumn` would (`BottomDockLayoutTests`).
                    """)
            }
        }
        XCTAssertTrue(
            Self.whitespaceFree(contentView).contains("bottomBar.zIndex(1)"),
            """
            The bottom bar is no longer drawn above `mainArea` by an explicit `.zIndex(1)`. That \
            order — on the bar's own opaque ground — is the whole of "the panel never paints over \
            the bottom bar" now that the dock column carries no clip.
            """
        )
        let bar = Self.whitespaceFree(try XCTUnwrap(
            Self.declarationBody(after: "bottomBar", in: contentView),
            "ContentView no longer declares `bottomBar` — update this suite deliberately"
        ))
        XCTAssertTrue(
            bar.contains(Self.whitespaceFree("background(chromeColor(.bgPanel))")),
            """
            The bottom bar no longer paints its own opaque `bgPanel` ground. The `.zIndex(1)` \
            above only orders the bar over `mainArea`; without the ground, whatever overflows the \
            dock column shows through the bar.
            """
        )
    }

    // MARK: - The slot sends its surplus where the bar covers it

    func testThePanelSlotIsTopAligned() throws {
        let code = Self.whitespaceFree(try contentViewCode())
        let column = try XCTUnwrap(
            code.range(of: "BottomDockColumn("),
            "ContentView no longer builds the dock through BottomDockColumn — update this suite deliberately"
        )
        let slot = try XCTUnwrap(
            code.range(of: "panelContent(panel)", range: column.upperBound..<code.endIndex),
            "panelContent(_:) is no longer called with the selected panel — update this suite deliberately"
        )
        // The `panel:` builder's closing brace. The slot's modifiers carry no
        // brace of their own, so everything up to it is the fixed-height slot's
        // modifiers and nothing else.
        let builderEnd = try XCTUnwrap(
            code.range(of: "}", range: slot.upperBound..<code.endIndex),
            "the panel slot's builder is not closed — the scan is broken, not the code"
        )
        XCTAssertTrue(
            code[slot.upperBound..<builderEnd.lowerBound].contains("alignment:.top"),
            """
            The fixed-height panel slot is no longer top-aligned. `.frame(height:)` defaults to \
            `.center`, so a child that refuses the proposal overflows *symmetrically*: the downward \
            half lands on the column's bottom edge, under the bottom bar, and the upward half \
            paints over the divider and into the editor — inside `mainArea`, where the bar's cover \
            cannot reach it. Without this the overdraw guarantee covers the bottom bar and \
            nothing else, which is half of what the bug report names.
            """
        )
    }

    /// The `case .<label>:` labels of a switch in an already-stripped
    /// declaration body, so a label merely *named* in a comment cannot count.
    /// Used to pin this suite's per-panel table against the branches the
    /// compiler forces `panelContent(_:)` to have.
    private static func switchCaseLabels(in body: String) -> Set<String> {
        var labels: Set<String> = []
        var searchStart = body.startIndex
        while let keyword = body.range(of: "case .", range: searchStart..<body.endIndex) {
            searchStart = keyword.upperBound
            var end = keyword.upperBound
            while end < body.endIndex, isIdentifierCharacter(body[end]) { end = body.index(after: end) }
            guard end > keyword.upperBound, end < body.endIndex, body[end] == ":" else { continue }
            labels.insert(String(body[keyword.upperBound..<end]))
        }
        return labels
    }

    // MARK: - Reading one function out of the file

    /// The whole `struct <type> { … }` declaration — every member, so a
    /// delegated `content`/`header` property counts as part of the root that
    /// faces the slot. A private helper struct declared later in the same file
    /// is outside the matching brace and so is not read. `nil` if the type is
    /// not declared here.
    private static func typeBody(_ type: String, in code: String) -> String? {
        declarationBody(after: "struct", name: type, in: code)
    }

    /// The body of the first `func <name>` or `var <name>` — from its opening
    /// brace to the matching close, counted on already-stripped source so no
    /// brace inside a comment or a string literal can be counted. `nil` if the
    /// declaration is not there.
    private static func declarationBody(after name: String, in code: String) -> String? {
        declarationBody(after: "func", name: name, in: code)
            ?? declarationBody(after: "var", name: name, in: code)
    }

    /// The brace-matched body of `<keyword> <name>`, where `<name>` must end at
    /// a character that cannot continue a Swift identifier.
    ///
    /// The boundary check is the point: a bare substring search matches the
    /// longer name that merely *starts* with the one asked for — a future
    /// `func panelContentBackground` or `struct LocalChangesViewRow` declared
    /// ahead of the real one would silently hand back a different body, and the
    /// assertion below would go on passing while guarding nothing.
    private static func declarationBody(after keyword: String, name: String, in code: String) -> String? {
        let needle = "\(keyword) \(name)"
        var searchStart = code.startIndex
        while let declaration = code.range(of: needle, range: searchStart..<code.endIndex) {
            searchStart = declaration.lowerBound < code.endIndex
                ? code.index(after: declaration.lowerBound)
                : code.endIndex
            let next = declaration.upperBound
            if next < code.endIndex, isIdentifierCharacter(code[next]) { continue }
            return bracedBody(from: next, in: code)
        }
        return nil
    }

    /// From `start`, the first `{` and everything up to its matching `}`.
    private static func bracedBody(from start: String.Index, in code: String) -> String? {
        let characters = Array(code[start...])
        guard let open = characters.firstIndex(of: "{") else { return nil }
        var depth = 0
        for index in open..<characters.count {
            if characters[index] == "{" { depth += 1 }
            if characters[index] == "}" {
                depth -= 1
                if depth == 0 { return String(characters[open...index]) }
            }
        }
        return nil
    }

    private static func isIdentifierCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }
}
