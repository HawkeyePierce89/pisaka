#if os(macOS)
import Foundation
import XCTest
import PisakaCore
@testable import Pisaka

/// The shipped `Resources/Queries/shell/symbols.scm`, compiled against the
/// pinned `tree-sitter-bash` grammar and **executed** over a fixture script.
///
/// **This is the only place in the pipeline where that happens.** A broken
/// symbols query is silent by construction: `SymbolQueryCatalog.query(for:)`
/// returns `nil` and `SymbolExtractor` returns `[]`, so an unindexed file looks
/// exactly like a file that declares nothing. `swift test` structurally cannot
/// close the gap — `PisakaCore` does not link SwiftTreeSitter, so
/// `SymbolQueryTests` can only check the query's node names against the
/// grammar's `node-types.json` — and neither the macOS nor the iOS build runs a
/// query either. The app-host bundle does both, headlessly.
///
/// The test scheme builds Debug, so a query that fails to *compile* trips
/// `SymbolQueryCatalog`'s `assertionFailure` before the `XCTAssertNotNil` below
/// is reached. That is still a hard failure, and it arrives naming the language
/// and quoting tree-sitter's own error.
///
/// The fixture is read through `#filePath`, the way `MarkdownParserTests` reads
/// its own: it is source data about the query, not a resource the product ships.
final class ShellSymbolQueryTests: XCTestCase {
    private func fixtureURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/shell-symbols.sh")
    }

    private func fixtureText() throws -> String {
        try String(contentsOf: fixtureURL(), encoding: .utf8)
    }

    /// The grammar loads and its bundled highlight query resolves. Asserted
    /// first because `SymbolQueryCatalog` degrades *silently* when the grammar
    /// is the thing that failed — it declines to assert twice for one cause —
    /// so without this the next test would report a missing query for a reason
    /// that is not the query's.
    func testTheShellGrammarLoads() {
        XCTAssertNotNil(SyntaxLanguageConfiguration.configuration(for: .shell))
    }

    /// The shipped `.scm` compiles against the pinned grammar. This is the
    /// assertion that is silent today for every other language.
    func testTheShellSymbolsQueryCompiles() {
        XCTAssertNotNil(SymbolQueryCatalog.query(for: .shell))
    }

    /// The four decisions the query's header states, asserted by execution
    /// rather than by reading: every function in either spelling is indexed at
    /// any depth; every top-level assignment in all three captured shapes is
    /// indexed; nothing assigned inside a function body or a loop is; and
    /// neither `arr[2]=x` nor a valueless `export PATH` is.
    ///
    /// Compared by **set equality** over `(kind, name, line)` triples — the
    /// comparison shape carries no absolute path, so the fixture's location on
    /// disk is not part of the assertion. Set equality rather than a subset is
    /// what makes the exclusions assertions instead of readings.
    func testTheFixtureIndexesExactlyTheDeclarationsTheQueryClaims() throws {
        let symbols = SymbolExtractor.symbols(
            in: try fixtureText(),
            language: .shell,
            fileURL: fixtureURL()
        )
        let found = Set(symbols.map { Triple(kind: $0.kind, name: $0.name, line: $0.line) })

        let expected: Set<Triple> = [
            // Both function spellings, including the one nesting a loop.
            Triple(kind: .function, name: "greet", line: 21),
            Triple(kind: .function, name: "announce", line: 27),
            Triple(kind: .function, name: "deploy", line: 31),
            // A bare top-level assignment.
            Triple(kind: .variable, name: "ROOT", line: 16),
            // The three declaration-command forms, each with a value.
            Triple(kind: .variable, name: "RELEASE", line: 17),
            Triple(kind: .variable, name: "CHANNEL", line: 18),
            Triple(kind: .variable, name: "TAG", line: 19),
            // A second bare assignment, below the function definitions.
            Triple(kind: .variable, name: "DONE", line: 52),
            // The `A=1 B=2` form, which nests one level deeper — last in the
            // file for the reason the fixture's own header states.
            Triple(kind: .variable, name: "HOST", line: 53),
            Triple(kind: .variable, name: "PORT", line: 53),
        ]
        XCTAssertEqual(found, expected)

        // The exclusions, named individually so a failure says which rule broke
        // rather than only that two sets differ.
        let names = Set(symbols.map(\.name))
        XCTAssertFalse(names.contains("salutation"), "a `local` inside a function body is not a declaration the index files")
        XCTAssertFalse(names.contains("GREETING_SEEN"), "an assignment inside a function body is not top level")
        XCTAssertFalse(names.contains("attempt"), "an assignment inside a loop inside a function is not top level")
        XCTAssertFalse(names.contains("LAST_REGION"), "an assignment inside a top-level loop is still not a child of `program`")
        XCTAssertFalse(names.contains("arr"), "`arr[2]=x` is a `subscript`, not a `variable_name`, and declares nothing new")
        XCTAssertFalse(names.contains("PATH"), "a valueless `export PATH` names a variable bound elsewhere")
    }

    /// The `(kind, name, line)` comparison shape — deliberately not `Symbol`,
    /// which carries the fixture's absolute `fileURL` and would make the set
    /// above depend on where the clone lives.
    private struct Triple: Hashable {
        let kind: SymbolKind
        let name: String
        let line: Int
    }
}

#endif
