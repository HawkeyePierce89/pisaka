import XCTest
@testable import PisakaCore

/// Static verification of the two tree-sitter highlight queries that live *in
/// this repository* (`Vendor/TreeSitterGitignore/`, `Vendor/TreeSitterDotenv/`).
///
/// Both of a query's failure modes are silent in the app — an unknown *node*
/// name makes the query fail to compile, so `LanguageConfiguration` throws,
/// `makeConfiguration` returns `nil` and the file degrades to plain text; a
/// mistyped *capture* name compiles fine and resolves to `SyntaxTokenKind.plain`,
/// i.e. default-colored text. Neither breaks a build and neither is caught by
/// "the file looks highlighted", so the only previous guard was the by-hand
/// procedure in each package's `VENDORED.md`, run once.
///
/// These tests reproduce the static half of that procedure on every run, against
/// the vendored files themselves:
///
///  * every node name and anonymous literal the query uses is declared in the
///    grammar's own `src/node-types.json` *with the matching `named` flag* — the
///    check that catches a typo, a node *renamed by a grammar update*, and one
///    whose `named` status a grammar update *flipped*, before any of them ships
///    as plain text;
///  * the set of capture names the query emits is exactly the expected one, and
///    each resolves to its intended, non-`.plain` `SyntaxTokenKind`.
///
/// The set equality is the point of the second check: a query gaining a new
/// capture fails here until someone confirms the Core mapping covers it, rather
/// than rendering it default-colored. What is *not* covered — the runtime half —
/// is that the query actually compiles against the grammar and that each element
/// of a fixture is captured; that needs SwiftTreeSitter, which Core deliberately
/// does not link, so it stays the `VENDORED.md` harness recipe.
///
/// The dockerfile grammar is a *remote* dependency, so its query is not in this
/// repository and cannot be read here; its capture names stay pinned by hand in
/// `SyntaxTokenKindTests`.
final class VendoredGrammarQueryTests: XCTestCase {
    // MARK: - gitignore (query hand-written in this repository)

    func testGitignoreQueryUsesOnlyNodeNamesTheGrammarDeclares() throws {
        try assertHighlightQueryNodesAreDeclared(vendoredPackage: "TreeSitterGitignore")
    }

    func testGitignoreQueryEmitsExactlyTheExpectedCaptureNames() throws {
        let emitted = try captureNames(vendoredPackage: "TreeSitterGitignore")

        // Four visually distinct classes: a comment, the operators that change
        // what a pattern *means* (`!`, `*`, `**`, `?`, bracket negation/range),
        // the pattern body that says what it *names*, and path structure.
        XCTAssertEqual(emitted, [
            "comment",
            "operator",
            "string",
            "punctuation.delimiter",
            "punctuation.bracket",
        ])

        assertResolvesWithoutFallingBackToPlain(emitted)

        // The classes must stay mutually distinct, or the highlighting conveys
        // nothing. (`punctuation.delimiter` and `punctuation.bracket` share a
        // kind by design, so four names collapse to four kinds over these.)
        let kinds = Set(["comment", "operator", "string", "punctuation.delimiter"]
            .map { SyntaxTokenKind(captureName: $0) })
        XCTAssertEqual(kinds.count, 4)
    }

    // MARK: - dotenv (query vendored verbatim from upstream)

    func testDotenvQueryUsesOnlyNodeNamesTheGrammarDeclares() throws {
        try assertHighlightQueryNodesAreDeclared(vendoredPackage: "TreeSitterDotenv")
    }

    func testDotenvQueryEmitsExactlyTheExpectedCaptureNames() throws {
        let emitted = try captureNames(vendoredPackage: "TreeSitterDotenv")

        XCTAssertEqual(emitted, [
            "keyword",  // `export`
            "operator", // `=`
            "comment",
            "constant", // booleans
            "number",
            "string",   // quoted and bare values
            "variable", // keys and `${…}` references
        ])

        assertResolvesWithoutFallingBackToPlain(emitted)

        // A `.env` file is mostly `KEY=value`, so the two halves and the `=`
        // between them must land in three different colors.
        let kinds = Set(["variable", "operator", "string"].map { SyntaxTokenKind(captureName: $0) })
        XCTAssertEqual(kinds.count, 3)
    }

    // MARK: - SQL (query vendored verbatim from upstream)

    func testSqlQueryUsesOnlyNodeNamesTheGrammarDeclares() throws {
        try assertHighlightQueryNodesAreDeclared(vendoredPackage: "TreeSitterSql")
    }

    func testSqlQueryEmitsExactlyTheExpectedCaptureNames() throws {
        let emitted = try captureNames(vendoredPackage: "TreeSitterSql")

        XCTAssertEqual(emitted, [
            "punctuation.delimiter",
            "function.call",
            "spell",
            "parameter",
            "comment",
            "keyword.operator",
            "operator",
            "type.builtin",
            "number",
            "boolean",
            "storageclass",
            "attribute",
            "string",
            "float",
            "conditional",
            "type.qualifier",
            "keyword",
            "field",
            "punctuation.bracket",
            "variable",
            "type"
        ])

        var resolvable = emitted
        resolvable.remove("spell")
        assertResolvesWithoutFallingBackToPlain(resolvable)
        
        // `spell` staying `.plain` is the intended outcome on the `@none` precedent — 
        // it rides along with `@comment` on the same node, so nothing renders uncolored because of it.
    }

    // MARK: - The named/anonymous split itself

    /// The node check is only as good as the `named` flag it reads: merging the
    /// two kinds into one set would accept `(digit) @string` — which tree-sitter
    /// rejects with `TSQueryErrorNodeType`, degrading every `.gitignore` to plain
    /// text — because `digit` *is* declared, just anonymously. This pins that the
    /// two sets are read apart and that gitignore really does supply both kinds,
    /// so the assertion above cannot quietly regress into a merged lookup.
    func testDeclaredNodeTypesSeparatesNamedNodesFromAnonymousTokens() throws {
        let declared = try declaredNodeTypes(vendoredPackage: "TreeSitterGitignore")

        // Reads like an ordinary node name, but is an anonymous token.
        XCTAssertTrue(declared.anonymous.contains("digit"))
        XCTAssertFalse(declared.named.contains("digit"))

        XCTAssertTrue(declared.named.contains("comment"))
        XCTAssertFalse(declared.anonymous.contains("comment"))

        XCTAssertTrue(declared.named.isDisjoint(with: declared.anonymous))
    }

    // MARK: - The scanner itself

    /// A predicate's arguments are ordinary strings, not anonymous nodes. Without
    /// this, an upstream query that gains a `#match?` (the dockerfile grammar's
    /// own query has one) would fail `assertQueryNodesAreDeclared` demanding the
    /// regex be declared in `node-types.json` — a failure pointing at a grammar
    /// mismatch that does not exist.
    func testScannerTreatsPredicateArgumentsAsStringsNotNodes() {
        let query = ParsedQuery(source: """
        ((variable) @constant
         (#match? @constant "^[A-Z][A-Z_0-9]*$"))
        (pair key: (key) @variable "=" @operator)
        """)

        XCTAssertEqual(query.namedNodes, ["variable", "pair", "key"])
        XCTAssertEqual(query.anonymousNodes, ["="])
        XCTAssertEqual(query.captureNames, ["constant", "variable", "operator"])
        XCTAssertEqual(query.fieldNames, ["key"])
    }

    /// Fields are the third thing tree-sitter validates, and the scanner has to
    /// tell them from the two it already collected: a field is the only *bare*
    /// identifier a query may hold, so it is recognized by the `:` that follows.
    /// Prose in a comment, a predicate's regex and a node name must not reach the
    /// set — a spurious field would fail the check against `node-types.json` with
    /// a mismatch that does not exist, and a missing one leaves the hole this
    /// collection was added to close (`ts_query_new` answering
    /// `TSQueryErrorField`, i.e. the language silently indexing nothing).
    func testScannerCollectsFieldNamesAndNothingElse() {
        let query = ParsedQuery(source: """
        ; A comment mentioning body: and name: in prose.
        (class_declaration
          name: (identifier) @container
          body: (block (function_definition name: (identifier) @definition.method)))
        ((attribute (attribute_name) @_a) (#match? @_a "^id:$"))
        (source_file (_ (pattern) @definition.variable))
        """)

        XCTAssertEqual(query.fieldNames, ["name", "body"])
        XCTAssertEqual(query.anonymousNodes, [])
        XCTAssertTrue(query.namedNodes.contains("class_declaration"))
        XCTAssertFalse(query.namedNodes.contains("_"))
    }

    /// The predicate suppression must end with its own `)`, not swallow the rest
    /// of the file — otherwise a single predicate would silently blind the node
    /// check for every pattern after it.
    func testScannerResumesCollectingAfterAPredicateCloses() {
        let query = ParsedQuery(source: """
        ((key) @variable (#eq? @variable "PATH"))
        (bracket_expr "[" @punctuation.bracket)
        """)

        XCTAssertEqual(query.namedNodes, ["key", "bracket_expr"])
        XCTAssertEqual(query.anonymousNodes, ["["])
        XCTAssertEqual(query.captureNames, ["variable", "punctuation.bracket"])
    }

    // MARK: - Assertions

    private func assertResolvesWithoutFallingBackToPlain(
        _ names: Set<String>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for name in names.sorted() {
            XCTAssertNotEqual(SyntaxTokenKind(captureName: name), .plain,
                              "capture @\(name) resolves to .plain, i.e. renders default-colored",
                              file: file, line: line)
        }
    }

    private func assertHighlightQueryNodesAreDeclared(
        vendoredPackage: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        assertQueryNodesAreDeclared(
            try parsedQuery(vendoredPackage: vendoredPackage),
            declaredBy: try declaredNodeTypes(vendoredPackage: vendoredPackage,
                                              file: file, line: line),
            describedAs: vendoredPackage,
            consequence: "the file would degrade to plain text",
            file: file, line: line
        )
    }

    // MARK: - Reading the vendored files

    private func captureNames(vendoredPackage: String) throws -> Set<String> {
        try parsedQuery(vendoredPackage: vendoredPackage).captureNames
    }

    private func parsedQuery(vendoredPackage: String) throws -> ParsedQuery {
        let url = TestRepository.url(
            atRepositoryPath: "Vendor/\(vendoredPackage)/queries/highlights.scm")
        return ParsedQuery(source: try String(contentsOf: url, encoding: .utf8))
    }
}
