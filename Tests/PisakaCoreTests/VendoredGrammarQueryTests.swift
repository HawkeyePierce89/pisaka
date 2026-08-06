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
        try assertQueryNodesAreDeclared(vendoredPackage: "TreeSitterGitignore")
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
        try assertQueryNodesAreDeclared(vendoredPackage: "TreeSitterDotenv")
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

    private func assertQueryNodesAreDeclared(
        vendoredPackage: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let query = try parsedQuery(vendoredPackage: vendoredPackage)
        let declared = try declaredNodeTypes(vendoredPackage: vendoredPackage)

        XCTAssertFalse(query.namedNodes.isEmpty, "parsed no node names out of the query",
                       file: file, line: line)

        for node in query.namedNodes.sorted() where !declared.named.contains(node) {
            let asAnonymous = declared.anonymous.contains(node)
                ? " — it is declared, but as an *anonymous* token, so the query must spell it "
                    + "\"\(node)\" rather than (\(node))"
                : ""
            XCTFail("query names node (\(node)), which \(vendoredPackage)'s node-types.json "
                    + "does not declare as a named node\(asAnonymous) — the query would fail to "
                    + "compile and the file would degrade to plain text", file: file, line: line)
        }
        for literal in query.anonymousNodes.sorted() where !declared.anonymous.contains(literal) {
            let asNamed = declared.named.contains(literal)
                ? " — it is declared, but as a *named* node, so the query must spell it "
                    + "(\(literal)) rather than \"\(literal)\""
                : ""
            XCTFail("query names anonymous node \"\(literal)\", which \(vendoredPackage)'s "
                    + "node-types.json does not declare as an anonymous token\(asNamed) — the "
                    + "query would fail to compile and the file would degrade to plain text",
                    file: file, line: line)
        }
    }

    // MARK: - Reading the vendored files

    /// The repository root, derived from this file's own compile-time path
    /// (`<root>/Tests/PisakaCoreTests/<this file>`).
    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // PisakaCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // <root>

    private func vendoredFile(_ package: String, _ relativePath: String) -> URL {
        Self.repositoryRoot
            .appendingPathComponent("Vendor")
            .appendingPathComponent(package)
            .appendingPathComponent(relativePath)
    }

    private func captureNames(vendoredPackage: String) throws -> Set<String> {
        try parsedQuery(vendoredPackage: vendoredPackage).captureNames
    }

    private func parsedQuery(vendoredPackage: String) throws -> ParsedQuery {
        let url = vendoredFile(vendoredPackage, "queries/highlights.scm")
        let source = try String(contentsOf: url, encoding: .utf8)
        return ParsedQuery(source: source)
    }

    /// Every node type the grammar declares, split by its `named` flag.
    ///
    /// `node-types.json` lists both kinds side by side at the top level, but the
    /// two are *not* interchangeable in a query: a named node is matched as
    /// `(name)` and an anonymous token as `"literal"`, and using the wrong form
    /// fails `ts_query_new` with `TSQueryErrorNodeType` — the same silent
    /// degradation to plain text an unknown name causes. Merging them into one
    /// set would therefore pass a query that cannot compile, which is exactly the
    /// failure this assertion exists to catch. It is a live hazard rather than a
    /// theoretical one in both directions: gitignore declares 18 *anonymous*
    /// types that read like ordinary identifiers (`digit`, `alpha`, `space`, …),
    /// so `(digit) @string` looks correct, and a grammar update flipping a node's
    /// `named` status is an ordinary upstream change.
    private func declaredNodeTypes(
        vendoredPackage: String
    ) throws -> (named: Set<String>, anonymous: Set<String>) {
        let url = vendoredFile(vendoredPackage, "src/node-types.json")
        let data = try Data(contentsOf: url)
        let entries = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []

        var named: Set<String> = []
        var anonymous: Set<String> = []
        for entry in entries {
            guard let type = entry["type"] as? String else { continue }
            // A missing `named` flag means anonymous, matching tree-sitter's own
            // default — but every entry both vendored grammars emit carries it.
            if entry["named"] as? Bool == true { named.insert(type) } else { anonymous.insert(type) }
        }

        XCTAssertFalse(named.isEmpty && anonymous.isEmpty,
                       "read no node types out of \(url.lastPathComponent)")
        return (named, anonymous)
    }
}

/// The three things a tree-sitter query says about a grammar: which named nodes
/// it matches, which anonymous literals it matches, and which captures it emits.
///
/// A hand-rolled scanner rather than a regex because the three are only
/// distinguishable with `;`-comment and string-literal state — a comment in the
/// gitignore query mentions node names in prose, and the query matches literal
/// `"["` / `"]"` / `"-"` tokens.
private struct ParsedQuery {
    private(set) var captureNames: Set<String> = []
    private(set) var namedNodes: Set<String> = []
    private(set) var anonymousNodes: Set<String> = []

    init(source: String) {
        let characters = Array(source)
        var index = 0
        var depth = 0
        // The paren depth a `(#predicate? …)` form opened at, while inside one.
        // A predicate's *arguments* are ordinary strings — `(#match? @constant
        // "^[A-Z_]+$")` — not anonymous nodes, so collecting them would make
        // `assertQueryNodesAreDeclared` demand a regex be declared in
        // `node-types.json`. Neither vendored query uses a predicate today, but
        // upstream queries commonly do (the dockerfile grammar's own does), and
        // the dotenv query is re-copied verbatim on every update.
        var predicateDepth: Int?

        while index < characters.count {
            let character = characters[index]

            switch character {
            case ";":  // comment — the rest of the line is prose
                while index < characters.count, !characters[index].isNewline { index += 1 }

            case "\"":  // anonymous node, e.g. "[" or "export"
                index += 1
                var literal = ""
                while index < characters.count, characters[index] != "\"" {
                    if characters[index] == "\\", index + 1 < characters.count {
                        index += 1
                    }
                    literal.append(characters[index])
                    index += 1
                }
                index += 1  // closing quote
                if predicateDepth == nil { anonymousNodes.insert(literal) }

            case "@":  // capture name, e.g. @punctuation.delimiter
                // Collected inside a predicate too: a predicate can only refer to
                // a capture its own pattern already emitted, so the name is real
                // either way.
                index += 1
                let name = ParsedQuery.identifier(in: characters, from: &index, allowingDots: true)
                if !name.isEmpty { captureNames.insert(name) }

            case "(":  // node pattern, e.g. (bracket_expr …) — or a (#predicate?)
                index += 1
                depth += 1
                while index < characters.count, characters[index].isWhitespace { index += 1 }
                if index < characters.count, characters[index] == "#" {
                    if predicateDepth == nil { predicateDepth = depth }
                    break  // leave `#` for the default branch to step over
                }
                let name = ParsedQuery.identifier(in: characters, from: &index, allowingDots: false)
                if !name.isEmpty, predicateDepth == nil { namedNodes.insert(name) }

            case ")":
                index += 1
                depth -= 1
                if let opened = predicateDepth, depth < opened { predicateDepth = nil }

            default:
                index += 1
            }
        }
    }

    private static func identifier(
        in characters: [Character],
        from index: inout Int,
        allowingDots: Bool
    ) -> String {
        var name = ""
        while index < characters.count {
            let character = characters[index]
            let isIdentifierCharacter = character.isLetter || character.isNumber
                || character == "_" || (allowingDots && character == ".")
            guard isIdentifierCharacter else { break }
            name.append(character)
            index += 1
        }
        return name
    }
}
