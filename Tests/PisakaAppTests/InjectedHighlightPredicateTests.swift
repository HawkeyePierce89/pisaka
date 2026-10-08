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
/// The fix is `PredicateResolvingHighlighter`, whose synchronous half always
/// declines, so every paint resolves predicates; every attaching site uses it,
/// which `testNoViewAttachesNeonsUnresolvingHighlighter` pins.
///
/// Bash is not the only injected target with predicates.
/// `testEveryPredicateCarryingInjectedTargetKeepsItsPredicates` probes every
/// other one the enumeration in `app-editor-overlays.md` finds: HTML →
/// JavaScript and CSS, a JavaScript `css` tagged template, a Rust macro, and a
/// Markdown fence for each predicate-carrying language.
///
/// **Only the app bundle can see this.** `PisakaCore` does not link tree-sitter
/// or Neon, so no `swift test` suite can parse, inject or highlight anything;
/// and executing a query directly (as `ShellSymbolQueryTests` does) would test a
/// reimplementation rather than the path the editor paints through. So the
/// captures here are read back off a real, hidden TextKit 1 `NSTextView` styled
/// by the editor's own `PredicateResolvingHighlighter`, built from
/// `SyntaxLanguageConfiguration.configuration(for:)` (the injections resolve
/// through `configuration(forInjectionName:)` inside it) exactly as the editor
/// builds it.
///
/// The fixtures are read through `#filePath`: they are source data about the
/// queries, not resources the product ships. `injected-shell.sh` holds the shell
/// lines bare; the `.mk` and `.md` fixtures carry the same lines as a recipe and
/// as a fence, and `injected-shell-two-fences.md` splits them across two fences
/// with prose between. A recipe and two fences each paint exactly what the
/// standalone script paints: the injected ranges include every line's newline,
/// so bash never reads the end of one line and the start of the next as one
/// word.
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

    /// Two `sh` fences splitting the same three lines, prose between them. Both
    /// land in one combined bash layer, so the first fence's last word would
    /// join the second fence's first word were the ranges to stop short of
    /// their newlines; `code_fence_content` includes its line endings, so
    /// every first word keeps its standalone capture.
    func testTwoAdjacentShellFencesPaintLikeTheStandaloneScript() async throws {
        let text = try fixture("injected-shell-two-fences.md")
        let painted = try await paint(text, as: .markdown)
        try await assertMatchesStandalone(painted, text: text, label: "two Markdown fences")
    }

    // MARK: - Standalone script

    /// The regression side of the fix: a standalone `.sh` file's first paint
    /// was already right before it, and must stay exactly what it was — every
    /// captured run, named.
    func testAStandaloneScriptPaintsWhatItPaintedBeforeTheFix() async throws {
        let text = try fixture("injected-shell.sh")
        let painted = try await paint(text, as: .shell)
        XCTAssertEqual(runs(of: painted, in: text), Self.standaloneRuns)
    }

    /// An edit repaints the edited range, which Neon's synchronous path did
    /// without predicates: `swiftlint` and `lint` turned `constant`. The
    /// rendezvous is the inserted flag's own `constant` capture, which every
    /// path delivers.
    func testAStandaloneScriptKeepsThePredicateAfterAnEdit() async throws {
        try await assertPredicateHoldsAfterAnEdit(in: "injected-shell.sh", as: .shell)
    }

    /// The same edit inside a Markdown fence, where the restyle also waits on
    /// the injected layer's re-parse.
    func testAMarkdownShellFenceKeepsThePredicateAfterAnEdit() async throws {
        try await assertPredicateHoldsAfterAnEdit(in: "injected-shell.md", as: .markdown)
    }

    private func assertPredicateHoldsAfterAnEdit(in fixtureName: String, as language: SyntaxLanguage) async throws {
        let text = try fixture(fixtureName)
        let view = try await paintedView(text, as: language)
        let storage = try XCTUnwrap(view.textView.textStorage)
        let insertion = (text as NSString).range(of: "--strict").location
        storage.replaceCharacters(in: NSRange(location: insertion, length: 0), with: "-x ")

        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, view.captures()[insertion] != "constant" {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let painted = view.captures()
        XCTAssertEqual(painted[insertion], "constant", "the inserted `-x` was never repainted")
        let edited = view.textView.string as NSString
        let lastLine = edited.range(of: "swiftlint lint -x --strict")
        XCTAssertNotEqual(lastLine.location, NSNotFound)
        let constants = runs(of: painted, in: view.textView.string)
            .filter { $0.hasSuffix("=constant") }
        XCTAssertEqual(constants, ["-v=constant", "-x=constant", "--strict=constant"])
    }

    /// What `testAStandaloneScriptPaintsWhatItPaintedBeforeTheFix` pins: the
    /// fixture's captured runs in order, `<text>=<capture>`.
    /// Only `-v` and `--strict` are `constant`; the second `swiftlint` and
    /// `lint` are arguments the predicate leaves uncaptured.
    private static let standaloneRuns: [String] = [
        "command=function",
        "-v=constant",
        ">=operator",
        "2=number",
        "exit=function",
        "echo=function",
        "\"swiftlint is not installed\"=string",
        "swiftlint=function",
        "--strict=constant",
    ]

    /// The painted runs in order: each maximal stretch of one capture name,
    /// spelled `<text>=<capture>`. Uncaptured text is skipped.
    private func runs(of painted: [String?], in text: String) -> [String] {
        let ns = text as NSString
        var result: [String] = []
        var start = 0
        while start < painted.count {
            var end = start + 1
            while end < painted.count, painted[end] == painted[start] { end += 1 }
            if let name = painted[start] {
                result.append("\(ns.substring(with: NSRange(start..<end)))=\(name)")
            }
            start = end
        }
        return result
    }

    // MARK: - Every other predicate-carrying injected target

    /// One captured name the editor must paint at `token`, found inside the
    /// first occurrence of `anchor` (so a token that appears twice is named by
    /// its context); `nil` means painted plain — uncaptured, or a name such as
    /// Markdown's `@none` over a fence that `SyntaxTokenKind` reads as `.plain`.
    private struct Probe {
        let anchor: String
        let token: String
        let name: String?

        init(_ token: String, in anchor: String? = nil, is name: String?) {
            self.anchor = anchor ?? token
            self.token = token
            self.name = name
        }
    }

    /// An injection whose target's highlights query carries a predicate:
    /// `snippet` sits verbatim inside `host`, and each probe names a token whose
    /// paint the predicate decides — so a skipped predicate fails at least one.
    /// When `standalone` is set, the snippet must also paint as it does in a
    /// file of that language, kind for kind.
    private struct InjectedTarget {
        let label: String
        let host: SyntaxLanguage
        let text: String
        let snippet: String
        let standalone: SyntaxLanguage?
        let probes: [Probe]
    }

    /// The enumeration `app-editor-overlays.md` records, reduced to the targets
    /// whose highlights query carries a predicate (`#match?`, `#eq?`,
    /// `#any-of?`). Bash is the suite's own subject above; HTML, YAML and
    /// `markdown_inline` carry none, and every other injected name resolves to
    /// `nil`.
    private static let javaScriptSnippet = "const lower = MAX_SIZE + Widget(console);"
    private static let cssSnippet = "a { color: red; --main: blue; }"
    private static let javaScriptProbes = [
        Probe("lower", is: "variable"),
        Probe("MAX_SIZE", is: "constant"),
        Probe("Widget", is: "constructor"),
        Probe("console", is: "variable.builtin"),
    ]
    private static let cssProbes = [
        Probe("color", is: "property"),
        Probe("--main", is: "variable"),
    ]

    private static let injectedTargets: [InjectedTarget] = [
        InjectedTarget(
            label: "HTML <script> → JavaScript", host: .html,
            text: "<p>x</p>\n<script>\n\(javaScriptSnippet)\n</script>\n",
            snippet: javaScriptSnippet, standalone: .javascript, probes: javaScriptProbes
        ),
        InjectedTarget(
            label: "HTML <style> → CSS", host: .html,
            text: "<p>x</p>\n<style>\n\(cssSnippet)\n</style>\n",
            snippet: cssSnippet, standalone: .css, probes: cssProbes
        ),
        // A tagged template's tag names its language. Only the probes apply:
        // the host's own `string` capture over the template shows through
        // wherever CSS captures nothing, so it is no standalone file.
        InjectedTarget(
            label: "JavaScript css`…` → CSS", host: .javascript,
            text: "const sheet = css`\(cssSnippet)`;\n",
            snippet: cssSnippet, standalone: nil, probes: cssProbes
        ),
        // A macro's token tree is reparsed as Rust; it is no whole Rust file,
        // so only the probes apply. `lower` is uncaptured, `Upper` takes the
        // `^[A-Z]` constructor pattern.
        InjectedTarget(
            label: "Rust macro → Rust", host: .rust,
            text: "fn main() {\n    vec![lower, Upper];\n}\n",
            snippet: "[lower, Upper]", standalone: nil,
            probes: [Probe("lower", in: "[lower", is: nil), Probe("Upper", in: "Upper]", is: "constructor")]
        ),
    ] + fencedTargets

    /// One Markdown fence per predicate-carrying language a fence can name.
    private static let fencedTargets: [InjectedTarget] = [
        ("js", .javascript, javaScriptSnippet, javaScriptProbes),
        ("ts", .typescript, "let lower: Upper = foo;", [Probe("lower", is: "variable"), Probe("Upper", is: "type")]),
        ("css", .css, cssSnippet, cssProbes),
        ("python", .python, "lower = Upper(MAX_SIZE)",
         [Probe("lower", is: "variable"), Probe("MAX_SIZE", is: "constant")]),
        ("go", .go, "package main\nfunc f() { x := len(y); foo(x) }",
         [Probe("len", is: "function.builtin"), Probe("foo", is: "variable")]),
        ("rust", .rust, "fn main() { let lower = Upper::new(); }",
         [Probe("lower", is: nil), Probe("Upper", is: "type")]),
        ("swift", .swift, "/// doc\n// plain\nlet lower = Widget.make()",
         [
             Probe("/// doc", is: "comment.documentation"),
             Probe("// plain", is: "spell"),
             Probe("Widget", is: "type"),
         ]),
        ("sql", .sql, "SELECT 'text', 1 FROM t;", [Probe("'text'", is: "string"), Probe("1", in: " 1 ", is: "string")]),
        ("make", .make, ".PHONY: all\nbuild: dep .WAIT",
         [Probe("all", is: "function"), Probe("dep", is: nil), Probe(".WAIT", is: "function.builtin")]),
        ("dockerfile", .dockerfile, "FROM alpine\nENV lower=$lower UPPER=$UPPER",
         [Probe("lower", in: "$lower", is: nil), Probe("UPPER", in: "$UPPER", is: "constant")]),
    ].map { info, language, snippet, probes in
        InjectedTarget(
            label: "Markdown ```\(info) fence", host: .markdown,
            text: "# Title\n\n```\(info)\n\(snippet)\n```\n",
            snippet: snippet, standalone: language, probes: probes
        )
    }

    func testEveryPredicateCarryingInjectedTargetKeepsItsPredicates() async throws {
        for target in Self.injectedTargets {
            let painted = try await paintedView(target.text, as: target.host) { painted in
                Self.unmetProbes(target.probes, in: painted, text: target.text).isEmpty
            } onTimeout: {
                "\(target.label): the probes never all held"
            }.captures()
            let unmet = Self.unmetProbes(target.probes, in: painted, text: target.text)
            XCTAssertEqual(unmet, [], "\(target.label): painted \(runs(of: painted, in: target.text))")

            guard let language = target.standalone else { continue }
            let standalone = try await paintedView(target.snippet, as: language) { painted in
                Self.unmetProbes(target.probes, in: painted, text: target.snippet).isEmpty
            } onTimeout: {
                "\(target.label): the standalone probes never all held"
            }.captures()
            let offset = (target.text as NSString).range(of: target.snippet).location
            XCTAssertNotEqual(offset, NSNotFound, "\(target.label): the host lost its snippet")
            guard offset != NSNotFound else { continue }
            let length = (target.snippet as NSString).length
            let injectedKinds = (0..<length).map { Self.paintedKind(painted[offset + $0]) }
            let standaloneKinds = (0..<length).map { Self.paintedKind(standalone[$0]) }
            XCTAssertEqual(injectedKinds, standaloneKinds,
                           "\(target.label): the injected snippet paints differently from a standalone file")
        }
    }

    /// The probes whose token is not painted the stated name, spelled
    /// `<token>=<painted>`; a probe whose anchor is missing is unmet too.
    private static func unmetProbes(_ probes: [Probe], in painted: [String?], text: String) -> [String] {
        let ns = text as NSString
        return probes.compactMap { probe in
            let anchor = ns.range(of: probe.anchor)
            guard anchor.location != NSNotFound else { return "\(probe.token)=<missing>" }
            let token = (probe.anchor as NSString).range(of: probe.token)
            let range = (anchor.location + token.location)..<(anchor.location + NSMaxRange(token))
            let names = Set(range.map { painted[$0] })
            let holds = probe.name.map { names == [$0] } ?? names.allSatisfy { paintedKind($0) == nil }
            return holds ? nil : "\(probe.token)=\(names.map { $0 ?? "nil" }.sorted())"
        }
    }

    // MARK: - Every site goes through the resolving highlighter

    /// No view constructs Neon's own `TextViewHighlighter`, whose synchronous
    /// path skips predicates; every attaching site goes through
    /// `PredicateResolvingHighlighter`. Read over comment- and literal-stripped
    /// text, so a doc comment naming the type does not count; any mention of the
    /// identifier counts, so `.init(`, a typealias or a spaced call cannot slip by
    /// (`TextViewHighlighterError` is a different identifier and stays allowed).
    func testNoViewAttachesNeonsUnresolvingHighlighter() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Pisaka")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        let identifier = try NSRegularExpression(pattern: "\\bTextViewHighlighter\\b")
        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let code = SyntaxBaseForegroundGatingTests.strippingCommentsAndStringLiterals(
                try String(contentsOf: url, encoding: .utf8)
            )
            if identifier.firstMatch(in: code, range: NSRange(location: 0, length: (code as NSString).length)) != nil {
                offenders.append(url.lastPathComponent)
            }
        }
        XCTAssertEqual(offenders, [], "these files attach Neon's highlighter directly and lose every predicate")
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
    ///
    /// Names are compared as the editor reads them: through `SyntaxTokenKind`,
    /// with `.plain` counted as uncaptured, so the Markdown host's `@none` over a
    /// fence's content — painted plain — is not a difference.
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
                if let name = Self.paintedKind(standalone[scriptStart + column]) {
                    expected.insert(Capture(line: index, column: column, name: name))
                }
                if let name = Self.paintedKind(painted[hostLine.location + column]) {
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

    /// The kind the editor paints for a capture name, `nil` when it paints plain.
    private static func paintedKind(_ name: String?) -> String? {
        guard let name else { return nil }
        let kind = SyntaxTokenKind(captureName: name)
        return kind == .plain ? nil : "\(kind)"
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
        try await paintedView(text, as: language).captures()
    }

    /// A hidden text view painted as `language`, settled on the same rendezvous
    /// as `paint`, kept alive with its highlighter so a test can edit it.
    private struct PaintedView {
        let scrollView: NSScrollView
        let textView: NSTextView
        let highlighter: PredicateResolvingHighlighter

        @MainActor
        func captures() -> [String?] {
            let layoutManager = textView.layoutManager
            return (0..<(textView.string as NSString).length).map {
                layoutManager?.temporaryAttribute(
                    InjectedHighlightPredicateTests.captureKey, atCharacterIndex: $0, effectiveRange: nil
                ) as? String
            }
        }
    }

    private func paintedView(_ text: String, as language: SyntaxLanguage) async throws -> PaintedView {
        let quoted = (text as NSString).range(of: "\"swiftlint is not installed\"")
        return try await paintedView(text, as: language) { painted in
            (quoted.location..<NSMaxRange(quoted)).allSatisfy { painted[$0] == "string" }
        } onTimeout: {
            """
            \(language): the quoted string never received its `string` capture — the last \
            paint over it skipped the bash query's predicates
            """
        }
    }

    /// A hidden text view painted as `language`, polled until `settled` holds
    /// over its captures; a deadline without it fails loudly with `onTimeout`.
    private func paintedView(
        _ text: String,
        as language: SyntaxLanguage,
        until settled: ([String?]) -> Bool,
        onTimeout: () -> String
    ) async throws -> PaintedView {
        let languageConfiguration = try XCTUnwrap(SyntaxLanguageConfiguration.configuration(for: language))

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 900, height: 1200))
        let textView = NSTextView(usingTextLayoutManager: false)
        textView.frame = scrollView.bounds
        scrollView.documentView = textView
        textView.string = text

        let view = PaintedView(
            scrollView: scrollView,
            textView: textView,
            highlighter: try PredicateResolvingHighlighter(
                textView: textView,
                languageConfiguration: languageConfiguration,
                attributeProvider: { token in [Self.captureKey: token.name] }
            )
        )

        let deadline = Date().addingTimeInterval(10)
        var reached = false
        while Date() < deadline {
            if settled(view.captures()) {
                reached = true
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        if !reached {
            XCTFail(onTimeout())
        }
        return view
    }
}
#endif
