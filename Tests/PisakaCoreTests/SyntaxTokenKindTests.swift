import XCTest
@testable import PisakaCore

final class SyntaxTokenKindTests: XCTestCase {
    // MARK: - Plain capture names

    func testPlainCaptureNamesMapToTheirKind() {
        let expected: [String: SyntaxTokenKind] = [
            "keyword": .keyword,
            "string": .string,
            "comment": .comment,
            "number": .number,
            "type": .type,
            "function": .function,
            "variable": .variable,
            "constant": .constant,
            "operator": .operator,
            "punctuation": .punctuation,
            "property": .property,
            "parameter": .parameter,
            "label": .label,
        ]

        for (name, kind) in expected {
            XCTAssertEqual(SyntaxTokenKind(captureName: name), kind, "capture \(name)")
        }
    }

    // MARK: - Dotted capture names (longest known prefix wins)

    func testDottedCaptureNamesResolveByPrefix() {
        XCTAssertEqual(SyntaxTokenKind(captureName: "keyword.control"), .keyword)
        XCTAssertEqual(SyntaxTokenKind(captureName: "keyword.control.return"), .keyword)
        XCTAssertEqual(SyntaxTokenKind(captureName: "punctuation.bracket"), .punctuation)
        XCTAssertEqual(SyntaxTokenKind(captureName: "punctuation.delimiter"), .punctuation)
        XCTAssertEqual(SyntaxTokenKind(captureName: "string.special"), .string)
        XCTAssertEqual(SyntaxTokenKind(captureName: "function.method"), .function)
        XCTAssertEqual(SyntaxTokenKind(captureName: "variable.builtin"), .variable)
        XCTAssertEqual(SyntaxTokenKind(captureName: "type.builtin"), .type)
        XCTAssertEqual(SyntaxTokenKind(captureName: "constant.numeric"), .constant)
        XCTAssertEqual(SyntaxTokenKind(captureName: "comment.line"), .comment)
    }

    func testUnknownSuffixFallsBackToKnownPrefix() {
        // An unrecognised dotted suffix degrades to the broader known prefix:
        // `function.builtin` has no exact entry, so it resolves via `function`.
        XCTAssertEqual(SyntaxTokenKind(captureName: "function.builtin"), .function)
        // A dotted name whose first (and only known-candidate) segment is unknown
        // falls back to `.plain`.
        XCTAssertEqual(SyntaxTokenKind(captureName: "unknown.thing"), .plain)
    }

    // MARK: - Grammar-specific captures that must not fall through to plain

    func testMarkupCapturesResolve() {
        // HTML/XML element + attribute names are the dominant tokens in markup
        // and have no broader prefix, so they must map explicitly.
        XCTAssertEqual(SyntaxTokenKind(captureName: "tag"), .type)
        XCTAssertEqual(SyntaxTokenKind(captureName: "tag.error"), .type)
        XCTAssertEqual(SyntaxTokenKind(captureName: "attribute"), .property)
    }

    func testMarkdownTextCapturesResolve() {
        // Markdown's block grammar emits its dominant tokens under `@text.*`,
        // which have no broader mapped prefix, so they must resolve explicitly
        // rather than fall through to `.plain`.
        XCTAssertEqual(SyntaxTokenKind(captureName: "text.title"), .keyword)
        XCTAssertEqual(SyntaxTokenKind(captureName: "text.literal"), .string)
        XCTAssertEqual(SyntaxTokenKind(captureName: "text.uri"), .label)
        XCTAssertEqual(SyntaxTokenKind(captureName: "text.reference"), .label)
        // Inline bold/italic spans (`markdown_inline`) must resolve so they read
        // as emphasized rather than falling through to `.plain` (which would
        // also punch a default-color hole through any enclosing heading).
        XCTAssertEqual(SyntaxTokenKind(captureName: "text.emphasis"), .keyword)
        XCTAssertEqual(SyntaxTokenKind(captureName: "text.strong"), .keyword)
        // Markdown emits per-level heading captures (`text.title.1` … `text.title.6`);
        // the extra level segment must still resolve via the `text.title` prefix,
        // not fall through to `.plain`.
        XCTAssertEqual(SyntaxTokenKind(captureName: "text.title.1"), .keyword)
        // An unmapped `text.*` sibling still degrades to `.plain` (no bare
        // `text` prefix is mapped). (`@none` is pinned separately by
        // `testNoneCaptureNameStaysPlain`, which carries its own rationale.)
        XCTAssertEqual(SyntaxTokenKind(captureName: "text"), .plain)
    }

    // The capture names of the two queries that live in *this* repository
    // (gitignore's, hand-written; dotenv's, vendored verbatim) are pinned by
    // `VendoredGrammarQueryTests`, which reads the `.scm` files themselves — so a
    // query that gains or renames a capture fails there instead of silently
    // rendering default-colored text. The dockerfile, Go and Rust grammars are
    // remote, and so unreadable from this suite; their names stay pinned by hand
    // below.

    func testDockerfileGrammarQueryCaptureNamesResolve() {
        // The exact capture names emitted by the dockerfile grammar's own
        // `queries/highlights.scm` (camdencheek/tree-sitter-dockerfile 0.2.0),
        // read out of the resolved checkout at the time it was pinned. This
        // query is a *remote* dependency, so — unlike the two vendored ones —
        // nothing here can re-read it; these names are only as current as the
        // pin, and what the test actually guards is that the Core mapping keeps
        // resolving them (a name that stops resolving renders default-colored in
        // the editor with nothing else failing).
        let emitted: [String: SyntaxTokenKind] = [
            "keyword": .keyword,                 // FROM, RUN, COPY, … + heredoc markers
            "operator": .operator,               // `:` and `@`
            "comment": .comment,                 // `# …`
            "punctuation.special": .punctuation, // image tag/digest separators, `${…}`
            "string": .string,                   // quoted strings, JSON strings, heredoc lines
            "constant": .constant,               // SCREAMING_CASE variables
        ]

        for (name, kind) in emitted {
            XCTAssertEqual(SyntaxTokenKind(captureName: name), kind, "capture \(name)")
            XCTAssertNotEqual(SyntaxTokenKind(captureName: name), .plain, "capture \(name) must not render plain")
        }
    }

    func testGoGrammarQueryCaptureNamesResolve() {
        // The exact capture names emitted by the Go grammar's own
        // `queries/highlights.scm` (tree-sitter/tree-sitter-go 0.25.0, revision
        // 1547678a…), read out of the resolved checkout at the time it was
        // pinned — the dockerfile precedent above, for the same reason: a remote
        // query cannot be re-read from here, so what this guards is that the Core
        // mapping keeps resolving every name the grammar emits.
        //
        // Thirteen names, and `escape` is why `SyntaxTokenKind.nameMap` gained an
        // entry: this grammar spells string escapes bare rather than
        // `@string.escape`, so before that entry every `\n` in a Go string was
        // default-colored — the exact silent failure this suite exists to catch.
        let emitted: [String: SyntaxTokenKind] = [
            "keyword": .keyword,           // func, type, range, go, defer, …
            "type": .type,                 // type identifiers
            "function": .function,         // call targets, declared functions
            "function.builtin": .function, // len, cap, append, …
            "function.method": .function,  // method declarations and calls
            "property": .property,         // struct field names
            "variable": .variable,         // identifiers
            "constant.builtin": .constant, // nil, true, false, iota
            "string": .string,             // interpreted + raw string literals
            "escape": .string,             // `\n`, `\t`, `\uXXXX` inside a string
            "number": .number,             // int/float/imaginary literals
            "operator": .operator,         // `:=`, `<-`, arithmetic, …
            "comment": .comment,           // `//` and `/* … */`
        ]

        for (name, kind) in emitted {
            XCTAssertEqual(SyntaxTokenKind(captureName: name), kind, "capture \(name)")
            XCTAssertNotEqual(SyntaxTokenKind(captureName: name), .plain, "capture \(name) must not render plain")
        }
    }

    func testRustGrammarQueryCaptureNamesResolve() {
        // The exact capture names emitted by the Rust grammar's own
        // `queries/highlights.scm` (tree-sitter/tree-sitter-rust 0.24.2,
        // revision 77a37472…), read out of the resolved checkout at the time it
        // was pinned — the dockerfile and Go precedents above, for the same
        // reason: a remote query cannot be re-read from here, so what this
        // guards is that the Core mapping keeps resolving every name the
        // grammar emits.
        //
        // Twenty-one names, and this table needed **no** new `nameMap` entry —
        // which is worth stating, because one of the twenty-one only resolves
        // by inheritance: `escape` is mapped because the Go work added
        // `"escape": .string`. Without that entry every `\n` in a Rust string
        // would render default-colored here too, and nothing else would fail.
        let emitted: [String: SyntaxTokenKind] = [
            "attribute": .property,             // `#[derive(…)]`, `#![no_std]`
            "comment": .comment,                // `//` and `/* … */`
            "comment.documentation": .comment,  // `///` and `//!`
            "constant": .constant,              // SCREAMING_CASE identifiers
            "constant.builtin": .constant,      // `true`, `false`
            "constructor": .type,               // struct/enum literal names
            "escape": .string,                  // `\n`, `\u{…}` inside a string
            "function": .function,              // declarations and call targets
            "function.macro": .function,        // `println!`, `vec!`, macro rules
            "function.method": .function,       // method declarations and calls
            "keyword": .keyword,                // fn, let, impl, match, …
            "label": .label,                    // loop labels (`'outer`)
            "operator": .operator,              // `?`, `->`, `..`, arithmetic, …
            "property": .property,              // struct field names
            "punctuation.bracket": .punctuation,   // (), [], {}, `<`/`>`
            "punctuation.delimiter": .punctuation, // `,`, `;`, `::`, `.`
            "string": .string,                  // string/char/byte literals
            "type": .type,                      // type identifiers
            "type.builtin": .type,              // i32, u8, str, bool, …
            "variable.builtin": .variable,      // `self`, `Self`
            "variable.parameter": .parameter,   // function parameters
        ]

        XCTAssertEqual(emitted.count, 21, "the pinned Rust capture vocabulary is 21 names")

        for (name, kind) in emitted {
            XCTAssertEqual(SyntaxTokenKind(captureName: name), kind, "capture \(name)")
            XCTAssertNotEqual(SyntaxTokenKind(captureName: name), .plain, "capture \(name) must not render plain")
        }
    }

    func testNoneCaptureNameStaysPlain() {
        // `@none` is tree-sitter's conventional "deliberately not highlighted"
        // capture; the dockerfile query uses it on `(expansion)` so only the
        // `$`/`{`/`}` inside are colored and the expanded name is left alone.
        // Resolving to `.plain` is therefore the *intended* outcome, not an
        // unmapped-name accident — pinned so a future "map everything" change to
        // the table can't quietly give it a color.
        XCTAssertEqual(SyntaxTokenKind(captureName: "none"), .plain)
    }

    func testSpellCaptureStaysPlain() {
        // The tree-sitter-sql grammar emits `spell` in addition to `@comment`
        // on the same node (`(comment) @comment @spell`). Resolving to `.plain`
        // is the intended outcome, following the `@none` precedent, so it does
        // not break the existing comment highlighting and a future "map everything"
        // change cannot quietly give it a color.
        XCTAssertEqual(SyntaxTokenKind(captureName: "spell"), .plain)
    }

    func testBooleanAndConstructorResolve() {
        XCTAssertEqual(SyntaxTokenKind(captureName: "boolean"), .constant)
        XCTAssertEqual(SyntaxTokenKind(captureName: "constructor"), .type)
    }

    func testVariableParameterPrefersParameterOverVariable() {
        // Longest-prefix matching must pick `.parameter`, not the broader
        // `variable` entry, so function parameters get their own color.
        XCTAssertEqual(SyntaxTokenKind(captureName: "variable.parameter"), .parameter)
        // The broader `variable.*` family still resolves to `.variable`.
        XCTAssertEqual(SyntaxTokenKind(captureName: "variable.member"), .variable)
    }

    func testSqlSpecificCapturesResolve() {
        XCTAssertEqual(SyntaxTokenKind(captureName: "conditional"), .keyword)
        XCTAssertEqual(SyntaxTokenKind(captureName: "storageclass"), .keyword)
        XCTAssertEqual(SyntaxTokenKind(captureName: "field"), .property)
        // Ensure type.qualifier resolves to .keyword, overriding the `type` prefix.
        XCTAssertEqual(SyntaxTokenKind(captureName: "type.qualifier"), .keyword)
    }

    // MARK: - Unknown capture names

    func testUnknownCaptureNameMapsToPlain() {
        XCTAssertEqual(SyntaxTokenKind(captureName: ""), .plain)
        XCTAssertEqual(SyntaxTokenKind(captureName: "nonsense"), .plain)
    }

    // MARK: - Leading-dot / sanitization

    func testLeadingDotIsIgnored() {
        // tree-sitter capture names sometimes arrive with a leading "@" or "."
        XCTAssertEqual(SyntaxTokenKind(captureName: ".keyword.control"), .keyword)
    }

    func testLeadingAtSignIsIgnored() {
        // Some grammars emit capture names with a leading "@" (e.g. "@keyword").
        XCTAssertEqual(SyntaxTokenKind(captureName: "@keyword.control"), .keyword)
        XCTAssertEqual(SyntaxTokenKind(captureName: "@string"), .string)
    }

    func testNameConsistingOnlyOfSigilsMapsToPlain() {
        // A capture name that is entirely strippable sigils has no segments left.
        XCTAssertEqual(SyntaxTokenKind(captureName: "@"), .plain)
        XCTAssertEqual(SyntaxTokenKind(captureName: "."), .plain)
    }
}
