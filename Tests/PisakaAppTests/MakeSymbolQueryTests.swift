#if os(macOS)
import Foundation
import XCTest
import PisakaCore
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
    /// and a target-specific assignment) is indexed as `.variable`.
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
        ]
        XCTAssertEqual(found, expected)

        // The exclusions, named individually so a failure says which rule broke.
        let names = Set(symbols.map(\.name))
        XCTAssertFalse(names.contains(".PHONY"), "a dot-led special target is filtered by the query's #not-match?")
        XCTAssertFalse(names.contains(".SUFFIXES"), "a dot-led special target is filtered by the query's #not-match?")
        XCTAssertFalse(names.contains(".DEFAULT_GOAL"), "a special variable is filtered by the query's #not-match?")
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

    /// The `(kind, name, line)` comparison shape, which carries no absolute
    /// path, so the set above does not depend on where the clone lives.
    private struct Triple: Hashable {
        let kind: SymbolKind
        let name: String
        let line: Int
    }
}

#endif
