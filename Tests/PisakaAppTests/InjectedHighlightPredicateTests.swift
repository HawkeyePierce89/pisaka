#if os(macOS)
import AppKit
import Foundation
import Neon
import XCTest
import PisakaCore
@testable import Pisaka

/// Highlight-query **predicates** hold inside injected code: the shipped bash
/// query's `((command (_) @constant) (#match? @constant "^-"))` paints only the
/// `-flag` arguments of a command, whether the shell lines stand alone in a
/// `.sh` file, sit in a Make recipe (`shell_text` → `bash`) or in a Markdown
/// ```` ```sh ```` fence.
///
/// The cause this pins lives in the pinned Neon: `TreeSitterClient`'s
/// `highlightsProvider` resolves predicates on its async path only, and its
/// sync path returns the raw matches. An injected block's sublayer finishes
/// parsing after the first paint and is repainted through the sync path, so
/// every child of `command` — the command name, the quoted string, `exit` —
/// came out `constant`. A standalone `.sh` file hid it until its first edit.
///
/// **Only the app bundle can see this.** `PisakaCore` does not link tree-sitter
/// or Neon, so no `swift test` suite can parse, inject or highlight anything;
/// and executing a query directly (as `ShellSymbolQueryTests` does) would test a
/// reimplementation rather than the path the editor paints through. So the
/// captures here are read back off a real, hidden TextKit 1 `NSTextView` styled
/// by the editor's own highlighter construction, built from
/// `SyntaxLanguageConfiguration.configuration(for:)` and
/// `configuration(forInjectionName:)` exactly as the editor builds it.
///
/// The fixtures are read through `#filePath`: they are source data about the
/// queries, not resources the product ships. `injected-shell.sh` holds the shell
/// lines bare; the `.mk` and `.md` fixtures carry the same lines as a recipe and
/// as a fence.
@MainActor
final class InjectedHighlightPredicateTests: XCTestCase {
    /// The temporary attribute the recording attribute provider writes: the
    /// capture name itself, so the test reads names, not colours.
    private static let captureKey = NSAttributedString.Key("PisakaTestCaptureName")

    private func fixture(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func shellLines() throws -> [String] {
        try fixture("injected-shell.sh").split(separator: "\n").map(String.init)
    }

    // MARK: - Makefile recipe

    func testAMakeRecipeKeepsTheBashPredicate() async throws {
        let text = try fixture("injected-shell.mk")
        let painted = try await paint(text, as: .make)
        try assertPredicateHolds(in: painted, text: text, label: "Make recipe")
    }

    func testAMakeRecipePaintsLikeTheStandaloneScript() async throws {
        let text = try fixture("injected-shell.mk")
        let painted = try await paint(text, as: .make)
        try await assertMatchesStandalone(painted, text: text, label: "Make recipe")
    }

    // MARK: - Markdown fence

    func testAMarkdownShellFenceKeepsTheBashPredicate() async throws {
        let text = try fixture("injected-shell.md")
        let painted = try await paint(text, as: .markdown)
        try assertPredicateHolds(in: painted, text: text, label: "Markdown fence")
    }

    func testAMarkdownShellFencePaintsLikeTheStandaloneScript() async throws {
        let text = try fixture("injected-shell.md")
        let painted = try await paint(text, as: .markdown)
        try await assertMatchesStandalone(painted, text: text, label: "Markdown fence")
    }

    // MARK: - Assertions

    /// The three readings of the bash predicate: the quoted string is a
    /// `string` and never `constant`, the command name is not `constant`, and
    /// the `-v` flag is.
    private func assertPredicateHolds(
        in painted: [String?],
        text: String,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let ns = text as NSString
        let quoted = ns.range(of: "\"swiftlint is not installed\"")
        let command = ns.range(of: "command -v")
        let flag = ns.range(of: "-v ")
        XCTAssertNotEqual(quoted.location, NSNotFound, file: file, line: line)

        let quotedNames = Set((quoted.location..<NSMaxRange(quoted)).map { painted[$0] })
        XCTAssertFalse(quotedNames.contains("constant"),
                       "\(label): the quoted string carries `constant` — the `^-` predicate was skipped",
                       file: file, line: line)
        XCTAssertEqual(quotedNames, ["string"],
                       "\(label): the quoted string must be painted `string`", file: file, line: line)
        XCTAssertNotEqual(painted[command.location], "constant",
                          "\(label): `command` is `constant` — the `^-` predicate was skipped",
                          file: file, line: line)
        XCTAssertEqual(painted[flag.location], "constant",
                       "\(label): `-v` must be `constant`", file: file, line: line)
        XCTAssertEqual(painted[flag.location + 1], "constant",
                       "\(label): `-v` must be `constant`", file: file, line: line)
    }

    /// The injected block paints character for character what the standalone
    /// `.sh` paints, once each shell line is offset to where it sits in the
    /// host (after a recipe's tab and `@`, or at a fence line's start).
    private func assertMatchesStandalone(
        _ painted: [String?],
        text: String,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let script = try fixture("injected-shell.sh")
        let standalone = try await paint(script, as: .shell)
        let scriptNS = script as NSString
        let hostNS = text as NSString

        var injected = Set<Capture>()
        var expected = Set<Capture>()
        for (index, shellLine) in try shellLines().enumerated() {
            let scriptStart = scriptNS.range(of: shellLine).location
            let hostLine = hostNS.range(of: shellLine)
            XCTAssertNotEqual(hostLine.location, NSNotFound,
                              "\(label): the host fixture lost shell line \(index)", file: file, line: line)
            guard hostLine.location != NSNotFound else { continue }
            for column in 0..<(shellLine as NSString).length {
                if let name = standalone[scriptStart + column] {
                    expected.insert(Capture(line: index, column: column, name: name))
                }
                if let name = painted[hostLine.location + column] {
                    injected.insert(Capture(line: index, column: column, name: name))
                }
            }
        }
        XCTAssertFalse(expected.isEmpty, "the standalone script painted nothing", file: file, line: line)
        // `XCTAssertTrue` rather than `XCTAssertEqual`: the two differences name
        // the failure; the two whole sets would bury it.
        XCTAssertTrue(injected == expected,
                      """
                      \(label): the injected shell lines paint differently from the standalone script. \
                      Only injected: \(describe(injected.subtracting(expected))); \
                      only standalone: \(describe(expected.subtracting(injected)))
                      """,
                      file: file, line: line)
    }

    private struct Capture: Hashable {
        let line: Int
        let column: Int
        let name: String
    }

    private func describe(_ captures: Set<Capture>) -> String {
        captures.sorted { ($0.line, $0.column) < ($1.line, $1.column) }
            .map { "\($0.line):\($0.column)=\($0.name)" }
            .joined(separator: " ")
    }

    // MARK: - The editor's highlight path

    /// Paints `text` as `language` through the editor's highlighter on a hidden
    /// text view and returns the capture name at each UTF-16 offset.
    ///
    /// The rendezvous is the quoted string's own `string` capture: it is the
    /// last thing the sublayer paint delivers on a correct path, and its
    /// absence after the deadline is the failure this suite exists to name, so
    /// the wait fails loudly and the assertions then say what was painted
    /// instead.
    private func paint(_ text: String, as language: SyntaxLanguage) async throws -> [String?] {
        let languageConfiguration = try XCTUnwrap(SyntaxLanguageConfiguration.configuration(for: language))

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 900, height: 1200))
        let textView = NSTextView(usingTextLayoutManager: false)
        textView.frame = scrollView.bounds
        scrollView.documentView = textView
        textView.string = text

        let configuration = TextViewHighlighter.Configuration(
            languageConfiguration: languageConfiguration,
            attributeProvider: { token in [Self.captureKey: token.name] },
            languageProvider: { name in
                SyntaxLanguageConfiguration.configuration(forInjectionName: name)
            },
            locationTransformer: { _ in nil }
        )
        let highlighter = try TextViewHighlighter(textView: textView, configuration: configuration)

        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let ns = text as NSString
        let quoted = ns.range(of: "\"swiftlint is not installed\"")
        func captures() -> [String?] {
            (0..<ns.length).map {
                layoutManager.temporaryAttribute(Self.captureKey, atCharacterIndex: $0, effectiveRange: nil) as? String
            }
        }

        let deadline = Date().addingTimeInterval(10)
        var settled = false
        while Date() < deadline {
            let painted = captures()
            if (quoted.location..<NSMaxRange(quoted)).allSatisfy({ painted[$0] == "string" }) {
                settled = true
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        if !settled {
            XCTFail("""
                \(language): the quoted string never received its `string` capture — the last \
                paint over it skipped the bash query's predicates
                """)
        }
        withExtendedLifetime(highlighter) {}
        return captures()
    }
}
#endif
