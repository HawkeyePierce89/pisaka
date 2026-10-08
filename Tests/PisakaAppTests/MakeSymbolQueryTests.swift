#if os(macOS)
import Foundation
import XCTest
import PisakaCore
import SwiftTreeSitter
@testable import Pisaka

/// The shipped `Resources/Queries/make/symbols.scm`, compiled against the
/// vendored `Vendor/TreeSitterMake` grammar and **executed** over a fixture
/// Makefile, the same way `ShellSymbolQueryTests` executes the shell query.
///
/// Make's query is the second that carries a predicate, and a predicate only
/// takes effect when the *client* evaluates it. `SymbolQueryTests` can pin the
/// predicate's presence and its text, but only execution can show it is
/// evaluated: if `SymbolExtractor` stopped resolving predicates, `.PHONY`,
/// `.SUFFIXES` and `%.o` would land in ⌃⌘J and every Core suite would stay green.
/// The absences below are what make that regression red.
///
/// The configuration's injections query is checked here too: the language name
/// it hands recipe bodies to must resolve to the shell configuration, or recipe
/// lines silently lose their shell highlighting.
///
/// The fixture is read through `#filePath`: it is source data about the query,
/// not a resource the product ships.
final class MakeSymbolQueryTests: XCTestCase {
    private func fixtureURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/make-symbols.mk")
    }

    private func fixtureText() throws -> String {
        try String(contentsOf: fixtureURL(), encoding: .utf8)
    }

    /// The vendored grammar loads from its `TreeSitterMake_TreeSitterMake`
    /// bundle. Asserted first for the reason `ShellSymbolQueryTests` states:
    /// `SymbolQueryCatalog` degrades silently when the grammar is what failed.
    func testTheMakeGrammarLoads() {
        XCTAssertNotNil(SyntaxLanguageConfiguration.configuration(for: .make))
    }

    /// The shipped `.scm` compiles against the vendored grammar.
    func testTheMakeSymbolsQueryCompiles() {
        XCTAssertNotNil(SymbolQueryCatalog.query(for: .make))
    }

    /// The decisions the query's header states, asserted by execution: ordinary
    /// rule targets are indexed as `.target`; every variable definition shape
    /// (`:=`, `?=`, `=`, `!=`, `define`, `+=` inside both branches of an `ifeq`,
    /// a target-specific assignment and `VPATH`) is indexed as `.variable`.
    ///
    /// Compared by **set equality** over `(kind, name, line)` triples, so every
    /// exclusion is an assertion rather than a reading.
    func testTheFixtureIndexesExactlyTheDeclarationsTheQueryClaims() throws {
        let symbols = SymbolExtractor.symbols(
            in: try fixtureText(),
            language: .make,
            fileURL: fixtureURL()
        )
        let found = Set(symbols.map { Triple(kind: $0.kind, name: $0.name, line: $0.line) })

        let expected: Set<Triple> = [
            // Ordinary rule targets.
            Triple(kind: .target, name: "build", line: 28),
            Triple(kind: .target, name: "test", line: 31),
            Triple(kind: .target, name: "lint", line: 34),
            // Every target of a multi-target rule, and a double-colon rule.
            Triple(kind: .target, name: "install", line: 51),
            Triple(kind: .target, name: "uninstall", line: 51),
            Triple(kind: .target, name: "clean", line: 54),
            // A dot-led file target is not a special name.
            Triple(kind: .target, name: ".venv", line: 57),
            // Nor is a dot-and-capitals target GNU make gives no meaning to.
            Triple(kind: .target, name: ".BUILD", line: 60),
            // Every assignment operator.
            Triple(kind: .variable, name: "CC", line: 10),
            Triple(kind: .variable, name: "CFLAGS", line: 11),
            Triple(kind: .variable, name: "SOURCES", line: 12),
            Triple(kind: .variable, name: "GIT_SHA", line: 13),
            // A `define` block.
            Triple(kind: .variable, name: "BANNER", line: 15),
            // Both branches of a conditional: the patterns are unanchored.
            Triple(kind: .variable, name: "LDFLAGS", line: 20),
            Triple(kind: .variable, name: "LDFLAGS", line: 22),
            // A target-specific assignment is a definition site of its own.
            Triple(kind: .variable, name: "CFLAGS", line: 37),
            Triple(kind: .variable, name: "OUTPUT_DIR", line: 42),
            // Assignments wrapped by export, override and private.
            Triple(kind: .variable, name: "PREFIX", line: 47),
            Triple(kind: .variable, name: "CFLAGS", line: 48),
            Triple(kind: .variable, name: "STAMP", line: 49),
            // VPATH is a dedicated node with an anonymous name token.
            Triple(kind: .variable, name: "VPATH", line: 63),
            // `.yl` is not a pair of default suffixes (`.ym` and `.lm` are).
            Triple(kind: .target, name: ".yl", line: 74),
            // A suffix-shaped target with prerequisites is an explicit target
            // too (GNU make records it as both), and a static-pattern rule
            // applies to the targets it enumerates.
            Triple(kind: .target, name: ".c.o", line: 77),
            Triple(kind: .target, name: ".s.o", line: 79),
            Triple(kind: .target, name: ".S.o", line: 82),
        ]
        XCTAssertEqual(found, expected)

        // The exclusions, named individually so a failure says which rule broke.
        let names = Set(symbols.map(\.name))
        XCTAssertFalse(names.contains(".PHONY"), "a special target is filtered by the query's #not-match?")
        XCTAssertFalse(names.contains(".SUFFIXES"), "a special target is filtered by the query's #not-match?")
        XCTAssertFalse(names.contains(".DEFAULT_GOAL"), "a special variable is filtered by the query's #not-match?")
        XCTAssertFalse(names.contains(".SHELLSTATUS"), "a special variable is filtered by the query's #not-match?")
        XCTAssertFalse(symbols.contains { $0.name == ".c.o" && $0.line == 66 },
                       "a prerequisite-less suffix rule declares no name and is filtered by the query's #not-match?")
        XCTAssertFalse(names.contains(".EXTRA_PREREQS"), "a special variable is filtered when set with !=")
        XCTAssertFalse(names.contains(".FEATURES"), "a special variable is filtered when set with define")
        XCTAssertFalse(names.contains(".lm.c"), "`.lm` is a default suffix, so `.lm.c` is a suffix rule")
        XCTAssertFalse(names.contains("%.o"), "a pattern target declares no name and is filtered by the query's #not-match?")
        XCTAssertFalse(names.contains("$(OUTPUT_DIR)"), "a `$(VAR):` target is a reference, not a `word`")
        XCTAssertFalse(names.contains("app"), "a prerequisite is not a target")
        XCTAssertFalse(names.contains("debug"), "a target-specific assignment's target is not a rule")
    }

    /// Recipe bodies are injected under the name the vendored `injections.scm`
    /// sets, and that name must resolve to the shell configuration, or recipe
    /// lines silently lose their shell highlighting with every gate green.
    ///
    /// The name is read out of the query file itself rather than restated here,
    /// so a grammar update that re-copies upstream with a different language
    /// name fails this test. The subject is a string literal, so the file is
    /// read raw: a literal-stripping scanner would delete the very text checked.
    func testRecipeInjectionResolvesToTheShellGrammar() throws {
        let configuration = try XCTUnwrap(SyntaxLanguageConfiguration.configuration(for: .make))
        XCTAssertNotNil(configuration.queries[.injections], "the vendored injections.scm must load")

        let queryURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Vendor/TreeSitterMake/queries/injections.scm")
        let query = try String(contentsOf: queryURL, encoding: .utf8)
        let pattern = try NSRegularExpression(pattern: #"injection\.language\s+"([^"]+)""#)
        let names = Set(pattern.matches(in: query, range: NSRange(query.startIndex..., in: query)).compactMap {
            Range($0.range(at: 1), in: query).map { String(query[$0]) }
        })
        XCTAssertFalse(names.isEmpty, "injections.scm no longer sets an injection.language")

        let shell = try XCTUnwrap(SyntaxLanguageConfiguration.configuration(for: .shell))
        for name in names {
            XCTAssertEqual(SyntaxLanguageConfiguration.configuration(forInjectionName: name)?.name, shell.name,
                           "injection.language \"\(name)\" does not resolve to the shell grammar")
        }
    }

    /// Every form the vendored grammar's newline edit rewrote parses with no
    /// `ERROR` or missing node, and each injected range ends after its newline:
    /// a recipe attached after `;`, an attached `;` with nothing after it, an
    /// empty tab-only recipe line, the `-` and `+` prefixes beside `@`, and a
    /// `!=` shell assignment. Compared by set equality over the injected text,
    /// so a lost injection fails as surely as a range stopping short.
    func testEveryEditedRecipeFormParsesAndInjectsThroughItsNewline() throws {
        let configuration = try XCTUnwrap(SyntaxLanguageConfiguration.configuration(for: .make))
        let query = try XCTUnwrap(configuration.queries[.injections], "the vendored injections.scm must load")
        let text = "attached: ; echo attached\n"
            + "bare: ;\n"
            + "\techo after-bare\n"
            + "prefixed:\n"
            + "\t-rm -f out\n"
            + "\t\n"
            + "\t+make sub\n"
            + "\t@echo done\n"
            + "SHA != git rev-parse HEAD\n"
        let parser = Parser()
        try parser.setLanguage(configuration.language)
        let tree = try XCTUnwrap(parser.parse(text))
        let root = try XCTUnwrap(tree.rootNode)
        XCTAssertFalse(root.hasError, "the edited forms must parse without an ERROR or missing node")

        let content = text as NSString
        var injected: [String] = []
        for match in query.execute(node: root, in: tree) {
            for capture in match.captures where capture.name == "injection.content" {
                injected.append(content.substring(with: capture.range))
            }
        }
        // The attached line's text keeps the space after `;`, as upstream's did:
        // only the newline moved into the range.
        XCTAssertEqual(Set(injected), [
            " echo attached\n",
            "echo after-bare\n",
            "rm -f out\n",
            "make sub\n",
            "echo done\n",
            "git rev-parse HEAD\n",
        ])
        XCTAssertEqual(injected.count, 6, "an injected range was captured twice")
    }

    /// A Markdown fence tagged with any of the names a Makefile goes by —
    /// the raw value, an extension, or the bare file name `makefile`, the most
    /// common fence tag — highlights as Make.
    func testMarkdownFenceNamesResolveToMake() throws {
        let make = try XCTUnwrap(SyntaxLanguageConfiguration.configuration(for: .make))
        for name in ["make", "mk", "makefile", "Makefile"] {
            XCTAssertEqual(SyntaxLanguageConfiguration.configuration(forInjectionName: name)?.name, make.name,
                           "fence tag \"\(name)\" should highlight as Make")
        }
    }

    /// The highlight query's built-in lists agree with the symbols query's
    /// filters: every special name the symbols query refuses to index because
    /// make gives it a meaning is drawn as a built-in, executed against the
    /// vendored grammar with predicates resolved — `.WAIT` both as a target and
    /// in its ordinary place among the prerequisites, of an ordinary rule and of
    /// a static-pattern one.
    func testTheHighlightQueryMarksGNUMakeSpecialNamesAsBuiltins() throws {
        let configuration = try XCTUnwrap(SyntaxLanguageConfiguration.configuration(for: .make))
        let query = try XCTUnwrap(configuration.queries[.highlights], "the vendored highlights.scm must load")
        let text = """
            .NOTINTERMEDIATE: gen.c
            .WAIT:
            all: one .WAIT two
            gen.o: %.o: %.c .WAIT gen.h
            .LIBPATTERNS = lib%.so
            .LOADED := x
            .SHELLSTATUS := 0
            .EXTRA_PREREQS != printf tools
            define .FEATURES
            x
            endef

            """
        let parser = Parser()
        try parser.setLanguage(configuration.language)
        let tree = try XCTUnwrap(parser.parse(text))
        let root = try XCTUnwrap(tree.rootNode)
        let context = Predicate.Context(string: text)

        // Keyed by range, so `.WAIT` the target and `.WAIT` the prerequisite are
        // asserted apart rather than one standing in for the other.
        var captured: [NSRange: Set<String>] = [:]
        for match in query.execute(node: root, in: tree) where match.allowed(in: context) {
            for capture in match.captures {
                guard let name = capture.name else { continue }
                captured[capture.range, default: []].insert(name)
            }
        }
        let content = text as NSString
        func names(at word: String, after anchor: String) -> Set<String> {
            let start = content.range(of: anchor).location
            let range = content.range(of: word, range: NSRange(location: start, length: content.length - start))
            return captured[range, default: []]
        }

        XCTAssertTrue(names(at: ".NOTINTERMEDIATE", after: ".NOTINTERMEDIATE").contains("function.builtin"),
                      ".NOTINTERMEDIATE is a special target and must be drawn as a built-in")
        XCTAssertTrue(names(at: ".WAIT", after: ".WAIT:").contains("function.builtin"),
                      ".WAIT is a special target and must be drawn as a built-in")
        XCTAssertTrue(names(at: ".WAIT", after: "all:").contains("function.builtin"),
                      ".WAIT among the prerequisites must be drawn as a built-in")
        XCTAssertTrue(names(at: ".WAIT", after: "gen.o:").contains("function.builtin"),
                      ".WAIT among a static-pattern rule's prerequisites must be drawn as a built-in")
        XCTAssertFalse(names(at: "one", after: "all:").contains("function.builtin"),
                       "an ordinary prerequisite is not a built-in")
        // `!=` is a `shell_assignment` and `define` a `define_directive`, each
        // with a pattern of its own beside the `variable_assignment` one.
        for variable in [".LIBPATTERNS", ".LOADED", ".SHELLSTATUS", ".EXTRA_PREREQS", ".FEATURES"] {
            XCTAssertTrue(names(at: variable, after: variable).contains("variable.builtin"),
                          "\(variable) is a special variable and must be drawn as a built-in")
        }
    }

    /// `VPATH` outside its dedicated `VPATH_assignment` node — set through
    /// `override` or `define` — is an ordinary `word` name, so it is drawn as a
    /// built-in only because the generic lists name it too. `VPATH != …` is not
    /// among them: at a line start the grammar lexes `VPATH` as the dedicated
    /// node's keyword, so that line never parses as a `shell_assignment`.
    func testTheHighlightQueryMarksVPATHAsABuiltinInEveryAssignmentForm() throws {
        let configuration = try XCTUnwrap(SyntaxLanguageConfiguration.configuration(for: .make))
        let query = try XCTUnwrap(configuration.queries[.highlights], "the vendored highlights.scm must load")
        let lines = [
            "override VPATH = src\n",
            "define VPATH\nsrc\nendef\n",
        ]
        for line in lines {
            let parser = Parser()
            try parser.setLanguage(configuration.language)
            let tree = try XCTUnwrap(parser.parse(line))
            let root = try XCTUnwrap(tree.rootNode)
            let context = Predicate.Context(string: line)
            let range = (line as NSString).range(of: "VPATH")
            var names: Set<String> = []
            for match in query.execute(node: root, in: tree) where match.allowed(in: context) {
                for capture in match.captures where capture.range == range {
                    if let name = capture.name { names.insert(name) }
                }
            }
            XCTAssertTrue(names.contains("variable.builtin"),
                          "VPATH in \(line.debugDescription) must be drawn as a built-in, got \(names)")
        }
    }

    /// The three directives upstream's query left uncaptured — `vpath`,
    /// `undefine` and `private` — are drawn as keywords, executed against the
    /// vendored grammar, the same as `override` beside them.
    func testTheHighlightQueryMarksEveryDirectiveAsAKeyword() throws {
        let configuration = try XCTUnwrap(SyntaxLanguageConfiguration.configuration(for: .make))
        let query = try XCTUnwrap(configuration.queries[.highlights], "the vendored highlights.scm must load")
        let text = """
            vpath %.c src
            undefine CACHE
            private CFLAGS := -g
            override undefine LEGACY

            """
        let parser = Parser()
        try parser.setLanguage(configuration.language)
        let tree = try XCTUnwrap(parser.parse(text))
        let root = try XCTUnwrap(tree.rootNode)
        XCTAssertFalse(root.hasError, "the fixture must parse without an ERROR node")
        let context = Predicate.Context(string: text)

        var captured: [NSRange: Set<String>] = [:]
        for match in query.execute(node: root, in: tree) where match.allowed(in: context) {
            for capture in match.captures {
                guard let name = capture.name else { continue }
                captured[capture.range, default: []].insert(name)
            }
        }
        let content = text as NSString
        let directives = [
            ("vpath", "vpath %.c"),
            ("undefine", "undefine CACHE"),
            ("private", "private CFLAGS"),
            ("override", "override undefine"),
            ("undefine", "undefine LEGACY"),
        ]
        for (directive, line) in directives {
            let start = content.range(of: line).location
            let range = NSRange(location: start, length: (directive as NSString).length)
            XCTAssertTrue(captured[range, default: []].contains("keyword"),
                          "`\(directive)` in `\(line)` must be drawn as a keyword")
        }
    }

    /// An include directive's keyword is drawn whatever its filenames are —
    /// a `$(DEPS)` reference or a `$(wildcard …)` call has no bare `word`, which
    /// once failed the whole pattern — and a bare filename is still a path.
    func testTheHighlightQueryMarksIncludeKeywordsWithoutABareFilename() throws {
        let configuration = try XCTUnwrap(SyntaxLanguageConfiguration.configuration(for: .make))
        let query = try XCTUnwrap(configuration.queries[.highlights], "the vendored highlights.scm must load")
        let text = """
            include $(DEPS)
            sinclude $(wildcard *.mk)
            -include local.mk

            """
        let parser = Parser()
        try parser.setLanguage(configuration.language)
        let tree = try XCTUnwrap(parser.parse(text))
        let root = try XCTUnwrap(tree.rootNode)
        XCTAssertFalse(root.hasError, "the fixture must parse without an ERROR node")
        let context = Predicate.Context(string: text)

        var captured: [NSRange: Set<String>] = [:]
        for match in query.execute(node: root, in: tree) where match.allowed(in: context) {
            for capture in match.captures {
                guard let name = capture.name else { continue }
                captured[capture.range, default: []].insert(name)
            }
        }
        let content = text as NSString
        for (keyword, line) in [("include", "include $(DEPS)"), ("sinclude", "sinclude $("), ("-include", "-include local")] {
            let start = content.range(of: line).location
            let range = NSRange(location: start, length: (keyword as NSString).length)
            XCTAssertTrue(captured[range, default: []].contains("keyword.import"),
                          "`\(keyword)` in `\(line)` must be drawn as a keyword")
        }
        XCTAssertTrue(captured[content.range(of: "local.mk"), default: []].contains("string.special.path"),
                      "a bare include filename must still be drawn as a path")
    }

    /// The `(kind, name, line)` comparison shape, which carries no absolute
    /// path, so the set above does not depend on where the clone lives.
    private struct Triple: Hashable {
        let kind: SymbolKind
        let name: String
        let line: Int
    }
}

#endif
