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
///   `problemsPanel`, one hop from the branch it serves) are read too — each
///   hosted view **whole**, `struct` brace to matching brace, not by its `var
///   body` alone: three of the four bodies are pure delegation, so a minimum
///   written on the `content` property they compose reaches the slot exactly as
///   one on `body` would, and `body`-only scanning would miss the likeliest
///   place to reintroduce this. The private row and detail structs later in
///   those same files are outside the declaration and stay unmatched, which is
///   how `CommitRow`'s legitimate per-row `minHeight` is excluded without an
///   exemption list: a minimum inside a row of a scrolling list is a different
///   thing and is deliberately not matched. The per-panel table is pinned to
///   the `case .…:` labels of `panelContent(_:)` **by set equality**, so the
///   inventory cannot fall behind the enum: the compiler already forces that
///   switch to cover every `BottomPanel` case, and without the tie a fifth
///   panel would put a fifth view in the slot with no minimum check at all
///   while this suite stayed green.
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
        var panelContentBody = ""

        for name in ["panelContent", "problemsPanel"] {
            let body = try XCTUnwrap(
                Self.declarationBody(after: name, in: contentView),
                "\(name) not found in ContentView.swift — rename it and update this suite deliberately"
            )
            if name == "panelContent" { panelContentBody = body }
            slotFacingBodies.append(("ContentView.\(name)", body))
        }

        // The views `panelContent(_:)` puts in the slot, **one per
        // `BottomPanel` case**. Each is read **whole**, not by its `var body`
        // alone: three of the four bodies are pure delegation
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
        ]

        // The tie that makes this table complete rather than merely long. A
        // fifth `BottomPanel` case forces a fifth branch in `panelContent(_:)`
        // — the compiler makes that switch exhaustive, which is the one half of
        // this rule `swift test` gets for free — and that branch would put a
        // fifth view in the fixed-height slot with no minimum check at all
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
