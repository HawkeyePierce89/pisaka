import XCTest

/// Static verification of the bottom dock panel's layout rules — the ones
/// `swift test` cannot otherwise see because they live in the (untested by
/// convention) macOS view layer, in `ContentView.swift`.
///
/// A repository-file suite in the `ZoomSourceGatingTests` mould: it reads
/// `Sources/Pisaka/ContentView.swift` through `#filePath` with Foundation only
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
///   this rule. So the four hosted panel roots (and `ContentView`'s
///   `problemsPanel`, one hop from the branch it serves) are read too, each by
///   its own `body`, which is the root that faces the slot; a minimum deeper
///   inside a scroll view is a different thing and is deliberately not matched.
/// - **The drag is measured in the column's named coordinate space, with
///   `minimumDistance: 0`.** `DragGesture()` — the default — compiles and
///   type-checks identically while measuring against an origin the drag itself
///   moves, which oscillates instead of tracking. Nothing but a human dragging
///   the divider can tell the two apart at runtime.
/// - **The column is pinned to the area and then clipped.** `.clipped()` clips a
///   view to the frame it *reported*, not the one it was proposed, so dropping
///   the `.frame(width:height:alignment:)` in front of it silently turns the
///   guarantee into a no-op in precisely the overflow case it exists for.
final class BottomPanelSourceGatingTests: XCTestCase {

    /// `ContentView.swift`, comment- and literal-stripped.
    private func contentViewCode() throws -> String {
        try appSource(named: "ContentView.swift")
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

        for name in ["panelContent", "problemsPanel"] {
            slotFacingBodies.append((
                "ContentView.\(name)",
                try XCTUnwrap(
                    Self.declarationBody(after: name, in: contentView),
                    "\(name) not found in ContentView.swift — rename it and update this suite deliberately"
                )
            ))
        }

        // The four views `panelContent(_:)` puts in the slot. Each is read by its
        // own `body`, the root that faces the slot: a minimum there reaches the
        // fixed-height frame exactly as one written at the call site would.
        for (file, type) in [
            ("TerminalPanelView.swift", "TerminalPanelView"),
            ("CommitLogView.swift", "CommitLogView"),
            ("LocalChangesView.swift", "LocalChangesView"),
            ("ProblemsPanelView.swift", "ProblemsPanelView"),
        ] {
            let code = try appSource(named: file)
            slotFacingBodies.append((
                "\(type).body",
                try XCTUnwrap(
                    Self.bodyOfType(type, in: code),
                    "\(type) has no `var body` in \(file) — rename it and update this suite deliberately"
                )
            ))
        }

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
            code.contains(Self.whitespaceFree("coordinateSpace(name: Self.panelColumnSpace)")),
            "the panel column no longer publishes the space its drag is measured in"
        )
    }

    // MARK: - The clip is pinned to the area it must clip to

    func testThePanelColumnIsPinnedToTheAreaBeforeItIsClipped() throws {
        let code = Self.whitespaceFree(try contentViewCode())
        let pin = Self.whitespaceFree(
            "frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)"
        )
        let pinned = try XCTUnwrap(code.range(of: pin), """
            The panel column is not pinned to the `GeometryReader`'s size, top-*leading*. \
            `.clipped()` clips to the frame a view *reported*, not the one it was proposed, so an \
            oversized column would be clipped to its own overflow — a no-op in exactly the case \
            the clip exists for. The leading half matters just as much: `.top` centers \
            horizontally, so a column wider than the area (the split's panes state minimum widths \
            the `GeometryReader` erases) would have the clip take half the surplus off each side, \
            cutting the project tree's leading edge.
            """)
        let clip = try XCTUnwrap(code.range(of: "clipped()"), "the panel column is no longer clipped")
        XCTAssertLessThan(
            pinned.lowerBound, clip.lowerBound,
            "the pin must come before the clip, or the clip rect is still the column's own size"
        )
    }

    // MARK: - Reading one function out of the file

    /// The `body` of `struct <type>` — the first `var body` after the type's own
    /// declaration, so a nested helper view later in the same file is not read
    /// in its place. `nil` if either is missing.
    private static func bodyOfType(_ type: String, in code: String) -> String? {
        guard let declaration = code.range(of: "struct \(type)") else { return nil }
        return declarationBody(after: "body", in: String(code[declaration.upperBound...]))
    }

    /// The body of the first `func <name>` or `var <name>` — from its opening
    /// brace to the matching close, counted on already-stripped source so no
    /// brace inside a comment or a string literal can be counted. `nil` if the
    /// declaration is not there.
    private static func declarationBody(after name: String, in code: String) -> String? {
        let declaration = code.range(of: "func \(name)") ?? code.range(of: "var \(name)")
        guard let declaration else { return nil }
        let characters = Array(code[declaration.upperBound...])
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
}
