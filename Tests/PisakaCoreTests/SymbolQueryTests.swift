import XCTest
@testable import PisakaCore

/// Static verification of the `symbols.scm` queries shipped in
/// `Resources/Queries/<language>/` — the language knowledge behind
/// go-to-definition and autocompletion.
///
/// This is `VendoredGrammarQueryTests`' reasoning applied to a *quieter* failure.
/// A broken highlight query degrades a file to plain text, which a reader
/// notices. A broken symbols query degrades a file to *no symbols*, which looks
/// exactly like a file that declares nothing: no error, no visual difference,
/// just a jump that beeps and a completion list that is a little shorter than it
/// should be. Both of the query failure modes are in play —
///
///  * an unknown *node* name fails `ts_query_new` with `TSQueryErrorNodeType`,
///    so `SymbolQueryCatalog` compiles nothing and the language silently indexes
///    zero symbols;
///  * an unknown *field* name fails it just as fatally with `TSQueryErrorField`,
///    and fields carry almost every pattern here (`name:`, `body:`, `key:`,
///    `heading_content:`, `left:`, `value:`, `as:`), so they are checked and
///    pinned exactly like node names;
///  * a mistyped *capture* name compiles fine and is then dropped by
///    `SymbolKind(captureName:)`, which is strict by design — so that
///    declaration alone disappears from the index.
///
/// — and neither shows up in a build, in CI, or in a screenshot.
///
/// What is *not* covered here is the runtime half: that each query compiles
/// against its grammar and that a fixture's declarations are really captured.
/// That needs SwiftTreeSitter, which `PisakaCore` deliberately does not link, so
/// it stays a debug-build `assertionFailure` in `SymbolQueryCatalog` plus the
/// manual recipe recorded in `docs/architecture/core-intelligence.md`.
final class SymbolQueryTests: XCTestCase {
    // MARK: - Coverage

    /// Every language the editor recognizes ships a symbols query — except the
    /// ones `SymbolIndexModel.unindexableLanguages` names, which are deliberately
    /// absent.
    ///
    /// Asserted as *set equality* against `SyntaxLanguage.allCases` in both
    /// directions, so adding a language to Core fails here until its query
    /// exists, and a query directory for a language that no longer exists fails
    /// here too. A missing query is not a crash and not a build error — the file
    /// type simply stops contributing symbols — so this assertion is the only
    /// thing standing between "we added Rust" and "Rust files declare nothing".
    ///
    /// The exception set is **read from Core**, not spelled again here. That is
    /// what makes the documented escape hatch real in both directions: a new
    /// language is satisfied by shipping a query *or* by declaring it
    /// unindexable, and moving an already-shipped language into
    /// `unindexableLanguages` fails here until its now-dead query directory is
    /// deleted. A second hard-coded copy of the rule could only drift from the
    /// one the index actually consults.
    func testEveryLanguageShipsASymbolsQueryExceptTheUnindexableOnes() throws {
        let directories = try shippedQueryDirectories()
        let expected = Set(
            SyntaxLanguage.allCases
                .filter(SymbolIndexModel.isIndexable)
                .map(\.rawValue)
        )

        XCTAssertEqual(directories, expected, """
            Resources/Queries must hold exactly one directory per SyntaxLanguage that \
            SymbolIndexModel considers indexable. A language with no query must be listed in \
            SymbolIndexModel.unindexableLanguages with its reason — today only .gitignore, \
            whose whole grammar is patterns and which therefore declares nothing.
            """)
    }

    /// A directory that exists but whose query is empty (or is a stray file
    /// under some other name) is the same outcome as no query at all, and the
    /// set-equality check above cannot see it.
    func testEverySymbolsQueryIsNonEmpty() throws {
        for language in try indexableLanguages() {
            let source = try querySource(for: language)
            XCTAssertFalse(source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           "Resources/Queries/\(language.rawValue)/symbols.scm is empty")
        }
    }

    /// An unindexable language has no query *directory*, not merely an empty one
    /// — the negative half of the coverage rule, spelled out so it reads as a
    /// decision rather than as an omission. Which languages those are is pinned
    /// by `SymbolIndexModelTests`; this asserts what their absence must look like
    /// on disk.
    func testUnindexableLanguagesShipNoSymbolsQuery() {
        XCTAssertFalse(SymbolIndexModel.unindexableLanguages.isEmpty)
        for language in SymbolIndexModel.unindexableLanguages {
            let directory = TestRepository.url(
                atRepositoryPath: "Resources/Queries/\(language.rawValue)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path),
                           "\(language.rawValue) is unindexable but ships a query directory")
        }
    }

    // MARK: - Captures

    /// Every capture the shipped queries emit is one Core resolves.
    ///
    /// Set equality in both directions is the point, exactly as in
    /// `VendoredGrammarQueryTests`: a query that gains a capture fails here until
    /// someone confirms `SymbolKind` covers it (otherwise that declaration is
    /// silently dropped), and a `SymbolKind` case no query emits fails here too
    /// (dead vocabulary that reads as supported).
    func testShippedQueriesEmitExactlyTheCapturesCoreResolves() throws {
        var emitted: Set<String> = []
        for language in try indexableLanguages() {
            emitted.formUnion(try parsedQuery(for: language).outputCaptureNames)
        }

        var expected = Set(SymbolKind.allCases.map(\.captureName))
        expected.insert(SymbolKind.containerCaptureName)

        XCTAssertEqual(emitted, expected, """
            The symbols queries and SymbolKind must describe the same vocabulary. A capture the \
            queries emit but Core does not resolve is dropped by SymbolKind(captureName:) and \
            that declaration never reaches the index; a kind no query emits is a promise the \
            editor cannot keep.
            """)
    }

    /// Each emitted kind capture really does resolve, and to the kind its name
    /// says. The set equality above compares *names*; this pins the mapping
    /// itself, so renaming a `SymbolKind` case's raw value without updating the
    /// queries cannot pass by matching some other case.
    func testEveryKindCaptureResolvesToItsOwnKind() throws {
        for language in try indexableLanguages() {
            for name in try parsedQuery(for: language).outputCaptureNames
            where name != SymbolKind.containerCaptureName {
                XCTAssertEqual(SymbolKind(captureName: name)?.captureName, name,
                               "@\(name) in \(language.rawValue)/symbols.scm does not resolve")
            }
        }
    }

    /// The one auxiliary capture, pinned by set equality of its own.
    ///
    /// `@_attribute` exists only so the HTML query's `#match?` predicate can filter
    /// `id` attributes — the leading underscore is tree-sitter's "not an output"
    /// convention, and `SymbolKind` rejects it, so it can never become a symbol.
    /// Pinning the set keeps the *strictness* of the check above: a new
    /// underscore capture is reviewed rather than waved through as auxiliary.
    func testTheOnlyAuxiliaryCaptureIsTheHTMLAttributeFilter() throws {
        var auxiliary: Set<String> = []
        for language in try indexableLanguages() {
            auxiliary.formUnion(try parsedQuery(for: language).auxiliaryCaptureNames)
        }

        XCTAssertEqual(auxiliary, ["_attribute"])
        for name in auxiliary {
            XCTAssertNil(SymbolKind(captureName: name),
                         "@\(name) is auxiliary but resolves to a kind, so it would be indexed")
        }
    }

    /// The HTML query is the only one that needs a predicate, and it needs it
    /// badly enough to assert: without the `#match?`, `(attribute (attribute_name) …
    /// (attribute_value) @definition.anchor)` matches *every* attribute in the
    /// document, so `class="page"` and `href="#header"` would be indexed as
    /// anchors. This pins that the filter is still there — and, by implication,
    /// that the extractor has to resolve predicates rather than walk raw matches.
    func testTheHTMLQueryFiltersAttributesByName() throws {
        let source = try querySource(for: .html)
        // `#match?` with a case-insensitive, fully anchored pattern rather than
        // `#eq? "id"`: HTML attribute names are case-insensitive, so `ID=`/`Id=`
        // name the same attribute, while the anchors keep `data-id`/`idx` out.
        XCTAssertTrue(source.contains("#match? @_attribute \"^[iI][dD]$\""), """
            The HTML symbols query no longer filters attributes by name. An `id` attribute is \
            structurally identical to every other attribute, so without the predicate every \
            attribute value in every HTML file is indexed as an anchor.
            """)

        XCTAssertEqual(try parsedQuery(for: .html).predicateNames, ["match?"])

        for language in try indexableLanguages() where language != .html {
            XCTAssertEqual(try parsedQuery(for: language).predicateNames, [], """
                \(language.rawValue)/symbols.scm gained a predicate. A predicate only takes \
                effect when the *client* evaluates it, so the extractor resolves predicates \
                solely because HTML needs it; a query that grows one elsewhere means re-checking \
                that dependency rather than assuming it.
                """)
        }
    }

    // MARK: - Node names

    /// The dotenv query, checked against the vendored grammar's own
    /// `node-types.json` — the same assertion `VendoredGrammarQueryTests` makes
    /// about the highlight queries, now available because the grammar's sources
    /// are in this repository.
    func testDotenvSymbolsQueryUsesOnlyNodeNamesTheGrammarDeclares() throws {
        assertQueryNodesAreDeclared(
            try parsedQuery(for: .dotenv),
            declaredBy: try declaredNodeTypes(vendoredPackage: "TreeSitterDotenv"),
            describedAs: "TreeSitterDotenv",
            consequence: "every .env file would index zero symbols"
        )
    }

    /// The twelve *remote* grammars' sources are not in this repository, so their
    /// `node-types.json` cannot be read and the check above cannot be made. What
    /// can be pinned is the set of node names, anonymous literals and field names
    /// each query uses — by hand, the way `SyntaxTokenKindTests` pins the
    /// dockerfile grammar's capture names.
    ///
    /// This does not catch an upstream rename on its own — nothing in a
    /// repository that cannot see the grammar can. What it catches is the *edit*:
    /// a bump of a grammar pin in `project.yml` that comes with a query change
    /// fails here with the language named, which is the moment to re-run the
    /// runtime check from `docs/architecture/core-intelligence.md`. Left
    /// unasserted, a query could drift node by node with nothing to review.
    func testRemoteGrammarQueriesUseExactlyThePinnedNodeNames() throws {
        for (language, expected) in Self.pinnedNodeNames {
            let query = try parsedQuery(for: language)
            XCTAssertEqual(query.namedNodes, expected.named,
                           "\(language.rawValue)/symbols.scm changed which named nodes it matches")
            XCTAssertEqual(query.anonymousNodes, expected.anonymous,
                           "\(language.rawValue)/symbols.scm changed which literals it matches")
            XCTAssertEqual(query.fieldNames, expected.fields, """
                \(language.rawValue)/symbols.scm changed which fields it navigates by. An \
                undeclared field fails ts_query_new with TSQueryErrorField exactly as an \
                undeclared node does, so the language would index zero symbols with nothing \
                else to notice it.
                """)
        }

        // Every language with a query is either pinned here or read from its
        // vendored grammar above, so a new language cannot arrive unpinned.
        XCTAssertEqual(Set(Self.pinnedNodeNames.keys).union([.dotenv]),
                       Set(try indexableLanguages()))
    }

    private static let pinnedNodeNames: [SyntaxLanguage: (
        named: Set<String>,
        anonymous: Set<String>,
        fields: Set<String>
    )] = [
        .swift: (named: [
            "associatedtype_declaration", "class_declaration", "enum_class_body", "enum_entry",
            "function_declaration", "init_declaration", "pattern", "property_declaration",
            "protocol_body", "protocol_declaration", "protocol_function_declaration",
            "protocol_property_declaration", "simple_identifier", "source_file", "type_identifier",
            "typealias_declaration", "user_type", "value_binding_pattern",
        ], anonymous: ["init", "let", "var"], fields: ["body", "name"]),

        .javascript: (named: [
            "arrow_function", "class_body", "class_declaration", "export_statement",
            "field_definition", "function_declaration", "function_expression",
            "generator_function_declaration", "identifier", "lexical_declaration",
            "method_definition", "pair", "private_property_identifier", "program",
            "property_identifier", "variable_declaration", "variable_declarator",
        ], anonymous: ["const", "let"], fields: ["body", "key", "name", "property", "value"]),

        .typescript: (named: [
            "abstract_class_declaration", "abstract_method_signature", "arrow_function",
            "class_body", "class_declaration", "enum_assignment", "enum_body", "enum_declaration",
            "export_statement", "function_declaration", "function_expression", "function_signature",
            "generator_function_declaration", "identifier", "interface_body",
            "interface_declaration", "internal_module", "lexical_declaration", "method_definition",
            "method_signature", "module", "nested_identifier", "pair",
            "private_property_identifier", "program", "property_identifier", "property_signature",
            "public_field_definition", "type_alias_declaration", "type_identifier",
            "variable_declaration", "variable_declarator",
        ], anonymous: ["const", "let"], fields: ["body", "key", "name", "value"]),

        .python: (named: [
            "assignment", "block", "class_definition", "decorated_definition",
            "expression_statement", "function_definition", "identifier", "module",
        ], anonymous: [], fields: ["body", "left", "name"]),

        // Go's anonymous set is empty on purpose, and one absence in it is
        // load-bearing: the const pattern navigates by *position* rather than by
        // `name:`, because that field is declared to hold the separating `,`
        // tokens and so yields only its first identifier. Were that pattern ever
        // "tidied" back into `const_spec name: (identifier)`, this pin would not
        // move — the query's node and field vocabulary is identical either way —
        // so the reasoning lives on the query itself and in the recorded capture
        // table, which is where a multi-name `const A, B = 1, 2` is shown
        // indexing both names.
        .go: (named: [
            "const_declaration", "const_spec", "field_declaration", "field_declaration_list",
            "field_identifier", "function_declaration", "generic_type", "identifier",
            "interface_type", "method_declaration", "method_elem", "parameter_declaration",
            "parameter_list", "pointer_type", "source_file", "struct_type", "type_alias",
            "type_declaration", "type_identifier", "type_spec", "var_declaration", "var_spec",
            "var_spec_list",
        ], anonymous: [], fields: ["name", "receiver", "type"]),

        // Rust's anonymous set is empty, and that is the whole shape of the
        // query: every distinction it draws is drawn by a *named* node or a
        // field, never by a literal token. Two of them are load-bearing and
        // invisible in this set — `mod_item body:` anchors what `impl_item
        // body:` and `trait_item body:` deliberately do not (all three hold a
        // `declaration_list`, so only the parent tells them apart), and
        // `generic_type`/`scoped_type_identifier` appear solely to be stepped
        // *through*, so `impl<T> Worker<T>` files its methods under `Worker`
        // rather than under `Worker<T>`. Both reasons live on the query itself
        // and in the recorded capture table.
        .rust: (named: [
            "const_item", "declaration_list", "enum_item", "enum_variant", "enum_variant_list",
            "field_declaration", "field_declaration_list", "field_identifier", "function_item",
            "function_signature_item", "generic_type", "identifier", "impl_item", "mod_item",
            "scoped_type_identifier", "source_file", "static_item", "struct_item", "trait_item",
            "type_identifier", "type_item", "union_item",
        ], anonymous: [], fields: ["body", "name", "type"]),

        .markdown: (named: ["atx_heading", "inline", "paragraph", "setext_heading"],
                    anonymous: [], fields: ["heading_content"]),

        .css: (named: [
            "class_name", "class_selector", "id_name", "id_selector", "keyframes_name",
            "keyframes_statement",
        ], anonymous: [], fields: []),

        .yaml: (named: [
            "anchor", "anchor_name", "block_mapping", "block_mapping_pair", "block_node",
            "document", "flow_node",
        ], anonymous: [], fields: ["key"]),

        .json: (named: ["document", "object", "pair", "string", "string_content"],
                anonymous: [], fields: ["key"]),

        .html: (named: ["attribute", "attribute_name", "attribute_value", "quoted_attribute_value"],
                anonymous: [], fields: []),

        .dockerfile: (named: ["from_instruction", "image_alias"], anonymous: [], fields: ["as"]),
    ]

    // MARK: - Reading the shipped queries

    /// The languages that ship a query — read off the directory rather than
    /// hard-coded, so the coverage test above is the one place the rule lives.
    private func indexableLanguages() throws -> [SyntaxLanguage] {
        try shippedQueryDirectories().compactMap(SyntaxLanguage.init(rawValue:)).sorted {
            $0.rawValue < $1.rawValue
        }
    }

    private func shippedQueryDirectories() throws -> Set<String> {
        let root = TestRepository.url(atRepositoryPath: "Resources/Queries")
        let contents = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        return Set(contents.filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }.map(\.lastPathComponent))
    }

    private func querySource(for language: SyntaxLanguage) throws -> String {
        let url = TestRepository.url(
            atRepositoryPath: "Resources/Queries/\(language.rawValue)/symbols.scm")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func parsedQuery(for language: SyntaxLanguage) throws -> ParsedQuery {
        ParsedQuery(source: try querySource(for: language))
    }
}
