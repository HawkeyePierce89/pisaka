import Foundation
import XCTest

/// The three things a tree-sitter query says about a grammar: which named nodes
/// it matches, which anonymous literals it matches, and which captures it emits.
///
/// A hand-rolled scanner rather than a regex because the three are only
/// distinguishable with `;`-comment and string-literal state — a comment in the
/// gitignore query mentions node names in prose, and the query matches literal
/// `"["` / `"]"` / `"-"` tokens.
///
/// Shared test support because two suites read queries with it:
/// `VendoredGrammarQueryTests` (the two in-repo *highlight* queries) and
/// `SymbolQueryTests` (the eleven in-repo *symbol* queries under
/// `Resources/Queries/`). Having one scanner is the point — a query the two
/// suites read differently is a query only one of them really checks.
struct ParsedQuery {
    private(set) var captureNames: Set<String> = []
    private(set) var namedNodes: Set<String> = []
    private(set) var anonymousNodes: Set<String> = []
    /// The predicates the query invokes, spelled as written (`eq?`, `match?`).
    /// A predicate is only honored if the *client* evaluates it, so a query that
    /// grows one silently changes meaning for a cursor that walks raw matches —
    /// which is why the symbol-query suite pins this set.
    private(set) var predicateNames: Set<String> = []

    /// The auxiliary captures — the ones spelled `@_name`, tree-sitter's
    /// convention for "this capture exists only so a predicate can refer to it".
    /// The symbol queries use one (`@_attribute`, to filter HTML `id`
    /// attributes), and `SymbolKind(captureName:)` rejects it, so it can never
    /// become a symbol.
    var auxiliaryCaptureNames: Set<String> { captureNames.filter { $0.hasPrefix("_") } }

    /// The captures a query actually *emits* — everything that is not auxiliary.
    var outputCaptureNames: Set<String> { captureNames.subtracting(auxiliaryCaptureNames) }

    init(source: String) {
        let characters = Array(source)
        var index = 0
        var depth = 0
        // The paren depth a `(#predicate? …)` form opened at, while inside one.
        // A predicate's *arguments* are ordinary strings — `(#match? @constant
        // "^[A-Z_]+$")` — not anonymous nodes, so collecting them would make
        // `assertQueryNodesAreDeclared` demand a regex be declared in
        // `node-types.json`. Neither vendored highlight query uses a predicate
        // today, but upstream queries commonly do (the dockerfile grammar's own
        // does), the dotenv query is re-copied verbatim on every update, and the
        // HTML symbols query in this repository needs an `#eq?`.
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
                    index += 1  // step over the `#`
                    var predicate = ""
                    while index < characters.count, !characters[index].isWhitespace,
                          characters[index] != ")" {
                        predicate.append(characters[index])
                        index += 1
                    }
                    if !predicate.isEmpty { predicateNames.insert(predicate) }
                    break
                }
                let name = ParsedQuery.identifier(in: characters, from: &index, allowingDots: false)
                // A bare `_` is tree-sitter's *wildcard*, not a node name: the
                // Swift symbols query spells a type body `(_ …)` because a
                // struct uses `class_body` and an enum `enum_class_body`.
                // Collecting it would send `assertQueryNodesAreDeclared` looking
                // for a node called "_" that no grammar declares.
                if !name.isEmpty, name != "_", predicateDepth == nil { namedNodes.insert(name) }

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

/// Reading repository files the way the `#filePath`-based suites do — the
/// `ReleaseMetadataTests`/`VendoredGrammarQueryTests` pattern, shared so the
/// symbol-query suite resolves the same root.
enum TestRepository {
    /// The repository root, derived from this file's own compile-time path
    /// (`<root>/Tests/PisakaCoreTests/Support/<this file>`).
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Support
        .deletingLastPathComponent()  // PisakaCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // <root>

    static func url(atRepositoryPath path: String) -> URL {
        root.appendingPathComponent(path)
    }
}

/// Every node type a *vendored* grammar declares, split by its `named` flag.
///
/// `node-types.json` lists both kinds side by side at the top level, but the two
/// are *not* interchangeable in a query: a named node is matched as `(name)` and
/// an anonymous token as `"literal"`, and using the wrong form fails
/// `ts_query_new` with `TSQueryErrorNodeType` — the same silent degradation to
/// plain text (or, for a symbols query, to "this file declares nothing") an
/// unknown name causes. Merging them into one set would therefore pass a query
/// that cannot compile, which is exactly the failure the assertion below exists
/// to catch. It is a live hazard rather than a theoretical one in both
/// directions: gitignore declares 18 *anonymous* types that read like ordinary
/// identifiers (`digit`, `alpha`, `space`, …), so `(digit) @string` looks
/// correct, and a grammar update flipping a node's `named` status is an ordinary
/// upstream change.
func declaredNodeTypes(
    vendoredPackage: String,
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> (named: Set<String>, anonymous: Set<String>) {
    let url = TestRepository.url(atRepositoryPath: "Vendor/\(vendoredPackage)/src/node-types.json")
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
                   "read no node types out of \(url.lastPathComponent)",
                   file: file, line: line)
    return (named, anonymous)
}

/// Asserts every node name and anonymous literal `query` uses is declared by
/// `declared` *under the matching `named` flag*.
///
/// Shared by both query suites: the failure it catches — a typo, a node a
/// grammar update renamed, or one whose `named` status it flipped — is silent in
/// the app either way, and the two suites differ only in which file they read.
func assertQueryNodesAreDeclared(
    _ query: ParsedQuery,
    declaredBy declared: (named: Set<String>, anonymous: Set<String>),
    describedAs subject: String,
    consequence: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertFalse(query.namedNodes.isEmpty, "parsed no node names out of the query",
                   file: file, line: line)

    for node in query.namedNodes.sorted() where !declared.named.contains(node) {
        let asAnonymous = declared.anonymous.contains(node)
            ? " — it is declared, but as an *anonymous* token, so the query must spell it "
                + "\"\(node)\" rather than (\(node))"
            : ""
        XCTFail("query names node (\(node)), which \(subject)'s node-types.json "
                + "does not declare as a named node\(asAnonymous) — the query would fail to "
                + "compile and \(consequence)", file: file, line: line)
    }
    for literal in query.anonymousNodes.sorted() where !declared.anonymous.contains(literal) {
        let asNamed = declared.named.contains(literal)
            ? " — it is declared, but as a *named* node, so the query must spell it "
                + "(\(literal)) rather than \"\(literal)\""
            : ""
        XCTFail("query names anonymous node \"\(literal)\", which \(subject)'s "
                + "node-types.json does not declare as an anonymous token\(asNamed) — the "
                + "query would fail to compile and \(consequence)", file: file, line: line)
    }
}
