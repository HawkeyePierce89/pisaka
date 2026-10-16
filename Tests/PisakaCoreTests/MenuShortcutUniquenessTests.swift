import XCTest

/// Every menu command's key equivalent is distinct.
///
/// A repository-file suite in the `GitHubSourceGatingTests` shape: it reads
/// `Sources/Pisaka` through `#filePath` with Foundation only, so it runs in
/// `swift test` without an Xcode build.
///
/// **Why nothing else can see this.** Two `Commands` bodies declaring the same
/// `.keyboardShortcut` compile, link and launch. AppKit then gives the chord to
/// exactly one of the two items and the other becomes unreachable from the
/// keyboard — silently, and only on the tabs where the winner is enabled. That
/// is not a hypothetical: ⌘⇧P named both View → *Markdown Preview* and
/// LeetCode → *Open Problem…* through a whole release, and the second was
/// unreachable on precisely the tabs the preview cared about. The fix moved one
/// of them; this suite is what keeps the next command from re-creating it.
///
/// **What is matched, and what is deliberately not.** The *character* form —
/// `.keyboardShortcut("p", modifiers: […])` — which is the form most menu
/// commands use, and the `KeyEquivalent` *constant* form —
/// `.keyboardShortcut(.tab, modifiers: .control)` — which is how the Window
/// menu's ⌃Tab / ⌃⇧Tab tab commands and `FoldCommands`' four arrow chords are
/// spelled; a constant is recorded under its dotted name (`.tab`), which no
/// single character can equal. Two spellings stay outside the set, excluded by
/// the pattern rather than by an exception list: the semantic forms
/// (`.cancelAction`, `.defaultAction`), which carry no `modifiers:`, and the
/// `.return` constant. All three are Esc and Return bound *per sheet or per
/// pane* — ⌘Return commits in the commit dialog, the merge window and the SQL
/// console alike — where sharing them across surfaces is the whole point.
///
/// **One chord source no scan can see.** AppKit's native window tabbing adds
/// its own Window-menu "Show Next Tab / Show Previous Tab" items bound to
/// ⌃Tab / ⌃⇧Tab, which would take those chords from the editor-tab commands
/// without any declaration in `Sources/Pisaka`. `AppDelegate` turns it off in
/// `applicationWillFinishLaunching(_:)`, and
/// `testAutomaticWindowTabbingIsTurnedOff` pins that assignment over
/// comment-stripped text, so the comment explaining it cannot keep it green.
///
/// The scan strips **comments only, keeping string literals** — the same stated
/// exception `GitHubSourceGatingTests` makes for the `gh` vocabulary, and for
/// its reason: the token this rule is about *is* a string literal, so the
/// ordinary scanner would delete the very thing being matched. Prose naming a
/// chord (`⌘⇧P`, and the comment above the moved item explaining why) is not a
/// declaration and must not be read as one, which is what dropping comments buys.
final class MenuShortcutUniquenessTests: XCTestCase {

    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // PisakaCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // <root>

    /// One declaration: the key, the modifiers as written, and where.
    private struct Shortcut {
        let key: String
        let modifiers: String
        let location: String

        /// What two declarations must not share. The modifier list is sorted so
        /// `[.command, .shift]` and `[.shift, .command]` are one chord.
        var chord: String {
            let parts = modifiers
                .split(whereSeparator: { " []".contains($0) })
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ",")) }
                .filter { !$0.isEmpty }
                .sorted()
            return "\(key) + \(parts.joined(separator: " "))"
        }
    }

    private func declaredShortcuts() throws -> [Shortcut] {
        let directory = Self.repositoryRoot.appendingPathComponent("Sources/Pisaka")
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            XCTFail("cannot enumerate \(directory.path)")
            return []
        }

        let pattern = try NSRegularExpression(
            pattern: #"\.keyboardShortcut\(("."|\.(?!return\b)[a-zA-Z]+),\s*modifiers:\s*(\[[^\]]*\]|\.[a-zA-Z]+)\)"#
        )

        var found: [Shortcut] = []
        for url in enumerator.compactMap({ $0 as? URL }) where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(source.isEmpty, "\(url.lastPathComponent) is unreadable — the walk is broken")
            let code = GitHubSourceGatingTests.strippingComments(source)
            let range = NSRange(code.startIndex..., in: code)
            for match in pattern.matches(in: code, range: range) {
                let key = try XCTUnwrap(Range(match.range(at: 1), in: code))
                let modifiers = try XCTUnwrap(Range(match.range(at: 2), in: code))
                found.append(Shortcut(
                    // A character keeps its quotes off; a constant keeps its dot.
                    key: String(code[key]).trimmingCharacters(in: CharacterSet(charactersIn: "\"")),
                    modifiers: String(code[modifiers]),
                    location: url.lastPathComponent
                ))
            }
        }
        return found
    }

    /// The rule. A duplicate chord names the two files it was declared in,
    /// because that is what the reader has to go look at.
    func testNoTwoMenuCommandsDeclareTheSameChord() throws {
        let shortcuts = try declaredShortcuts()

        // Named, so a regex that silently matched nothing cannot pass this test
        // by having no duplicates in an empty set.
        XCTAssertGreaterThan(shortcuts.count, 20, """
            fewer character key equivalents were found than the app is known to \
            declare — the scan is broken, not the code
            """)

        let byChord = Dictionary(grouping: shortcuts, by: \.chord)
        for (chord, declarations) in byChord.sorted(by: { $0.key < $1.key }) where declarations.count > 1 {
            XCTFail("""
                \(chord) is declared \(declarations.count) times, in \
                \(declarations.map(\.location).sorted().joined(separator: ", ")). AppKit gives the \
                chord to one of them and the others are unreachable from the keyboard, on exactly \
                the tabs where the winner is enabled — which is how ⌘⇧P shipped naming both \
                View > Markdown Preview and LeetCode > Open Problem….
                """)
        }
    }

    /// The two chords this branch's move produced, pinned by name so the fix
    /// itself cannot be silently undone by a later edit that keeps the set
    /// distinct some other way.
    func testThePreviewAndTheProblemSheetHoldTheirOwnChords() throws {
        let byChord = Dictionary(grouping: try declaredShortcuts(), by: \.chord)

        let preview = try XCTUnwrap(byChord["p + .command .shift"], "⌘⇧P is declared by nothing")
        XCTAssertEqual(preview.map(\.location), ["PisakaApp.swift"], "⌘⇧P is View > Markdown Preview")

        let openProblem = try XCTUnwrap(byChord["p + .command .option"], "⌘⌥P is declared by nothing")
        XCTAssertEqual(openProblem.map(\.location), ["LeetCodeOpenProblemSheet.swift"],
                       "⌘⌥P is LeetCode > Open Problem…")
    }

    /// The tab-navigation chords, each held by `PisakaApp.swift` alone: the two
    /// adjacent moves in both spellings and the nine Select Tab items. The
    /// constant form is what makes ⌃Tab / ⌃⇧Tab visible here at all.
    func testTheTabNavigationChordsAreDeclaredOnceEach() throws {
        let byChord = Dictionary(grouping: try declaredShortcuts(), by: \.chord)
        var chords = [
            "] + .command .shift", "[ + .command .shift",
            ".tab + .control", ".tab + .control .shift",
        ]
        chords += (1...9).map { "\($0) + .command" }
        for chord in chords {
            let declarations = try XCTUnwrap(byChord[chord], "\(chord) is declared by nothing")
            XCTAssertEqual(declarations.map(\.location), ["PisakaApp.swift"], chord)
        }
    }

    /// AppKit's native window tabbing would bind its own ⌃Tab / ⌃⇧Tab items,
    /// invisible to the scan above; `AppDelegate` must turn it off. Read over
    /// comment-stripped text, so the doc comment naming the setting cannot keep
    /// this green after the assignment is deleted.
    func testAutomaticWindowTabbingIsTurnedOff() throws {
        let url = Self.repositoryRoot.appendingPathComponent("Sources/Pisaka/AppDelegate.swift")
        let code = LSPSourceGatingTests.strippingCommentsAndStringLiterals(try String(contentsOf: url, encoding: .utf8))
        XCTAssertTrue(code.contains("func applicationWillFinishLaunching("),
                      "the assignment must run before any window exists")
        XCTAssertNotNil(code.range(
            of: #"NSWindow\.allowsAutomaticWindowTabbing\s*=\s*false"#, options: .regularExpression
        ), "AppDelegate no longer turns native window tabbing off — AppKit's ⌃Tab items would return")
    }
}
