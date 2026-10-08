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
/// The configuration's injections query is checked here too: recipe bodies are
/// handed to `"bash"`, and that name must resolve to a configuration, or recipe
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
            Triple(kind: .target, name: "build", line: 26),
            Triple(kind: .target, name: "test", line: 29),
            Triple(kind: .target, name: "lint", line: 32),
            // Every assignment operator.
            Triple(kind: .variable, name: "CC", line: 8),
            Triple(kind: .variable, name: "CFLAGS", line: 9),
            Triple(kind: .variable, name: "SOURCES", line: 10),
            Triple(kind: .variable, name: "GIT_SHA", line: 11),
            // A `define` block.
            Triple(kind: .variable, name: "BANNER", line: 13),
            // Both branches of a conditional: the patterns are unanchored.
            Triple(kind: .variable, name: "LDFLAGS", line: 18),
            Triple(kind: .variable, name: "LDFLAGS", line: 20),
            // A target-specific assignment is a definition site of its own.
            Triple(kind: .variable, name: "CFLAGS", line: 35),
            Triple(kind: .variable, name: "OUTPUT_DIR", line: 40),
        ]
        XCTAssertEqual(found, expected)

        // The exclusions, named individually so a failure says which rule broke.
        let names = Set(symbols.map(\.name))
        XCTAssertFalse(names.contains(".PHONY"), "a dot-led special target is filtered by the query's #not-match?")
        XCTAssertFalse(names.contains(".SUFFIXES"), "a dot-led special target is filtered by the query's #not-match?")
        XCTAssertFalse(names.contains("%.o"), "a pattern target declares no name and is filtered by the query's #not-match?")
        XCTAssertFalse(names.contains("$(OUTPUT_DIR)"), "a `$(VAR):` target is a reference, not a `word`")
        XCTAssertFalse(names.contains("app"), "a prerequisite is not a target")
        XCTAssertFalse(names.contains("debug"), "a target-specific assignment's target is not a rule")
    }

    /// The predicate in isolation: the same three targets, with nothing else in
    /// the source, yield exactly the ordinary one.
    func testThePredicateIsEvaluatedNotMerelyPresent() {
        let source = """
        .PHONY: all
        %.o: %.c
        \tcc -c $<
        all:
        \ttrue

        """
        let symbols = SymbolExtractor.symbols(
            in: source,
            language: .make,
            fileURL: URL(fileURLWithPath: "/inline/Makefile")
        )
        XCTAssertEqual(symbols.map(\.name), ["all"])
        XCTAssertEqual(symbols.map(\.kind), [.target])
    }

    /// Recipe bodies are injected as `"bash"`: the configuration carries an
    /// injections query, and the name it emits resolves to a configuration.
    func testRecipeInjectionResolvesToTheShellGrammar() throws {
        let configuration = try XCTUnwrap(SyntaxLanguageConfiguration.configuration(for: .make))
        XCTAssertNotNil(configuration.queries[.injections], "the vendored injections.scm must load")
        XCTAssertNotNil(SyntaxLanguageConfiguration.configuration(forInjectionName: "bash"))
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
