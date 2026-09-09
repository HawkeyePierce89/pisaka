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
/// **What is matched, and what is deliberately not.** Only the *character*
/// form — `.keyboardShortcut("p", modifiers: […])` — which is the form a menu
/// command uses. The semantic forms (`.cancelAction`, `.defaultAction`) and the
/// `KeyEquivalent` constants (`.return`, `.leftArrow`) are excluded by the
/// pattern rather than by an exception list: the first two are Esc and Return
/// bound *per sheet*, where sharing them across sheets is the whole point, and
/// the arrow constants are a distinguishable spelling this rule has never had a
/// collision in. `FoldCommands`' four arrow chords therefore sit outside the
/// set, which is stated here rather than left to be inferred.
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
            pattern: #"\.keyboardShortcut\("(.)",\s*modifiers:\s*(\[[^\]]*\]|\.[a-zA-Z]+)\)"#
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
                    key: String(code[key]),
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
}
