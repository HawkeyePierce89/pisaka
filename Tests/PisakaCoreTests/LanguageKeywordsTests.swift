import XCTest
@testable import PisakaCore

/// Pins the keyword source: that every language has made a decision (a list or
/// a stated absence), that each list has the shape `keywords(for:)` promises,
/// and that every entry is a token the editor can actually insert.
final class LanguageKeywordsTests: XCTestCase {

    // MARK: - Coverage

    /// The set-equality gate, the same one `SymbolQueryTests` applies to the
    /// shipped queries: a language added to `SyntaxLanguage` fails this suite
    /// until it either gets a list or is named in `languagesWithoutKeywords`.
    func testEveryLanguageEitherHasKeywordsOrIsExcluded() {
        let withKeywords = Set(SyntaxLanguage.allCases.filter { !LanguageKeywords.keywords(for: $0).isEmpty })
        let excluded = LanguageKeywords.languagesWithoutKeywords

        XCTAssertEqual(withKeywords.union(excluded), Set(SyntaxLanguage.allCases))
        XCTAssertTrue(withKeywords.isDisjoint(with: excluded))
    }

    func testExcludedLanguagesReturnNoKeywords() {
        for language in LanguageKeywords.languagesWithoutKeywords {
            XCTAssertEqual(LanguageKeywords.keywords(for: language), [], "\(language.rawValue)")
        }
    }

    func testTheDocumentedLanguagesAreTheOnesWithLists() {
        let withKeywords = Set(SyntaxLanguage.allCases.filter { !LanguageKeywords.keywords(for: $0).isEmpty })
        XCTAssertEqual(withKeywords, [.swift, .javascript, .typescript, .python, .dockerfile, .go])
    }

    // MARK: - Shape

    func testEveryListIsSortedAndDuplicateFree() {
        for language in SyntaxLanguage.allCases {
            let keywords = LanguageKeywords.keywords(for: language)
            XCTAssertEqual(keywords, keywords.sorted(), "\(language.rawValue) is not sorted")
            XCTAssertEqual(Set(keywords).count, keywords.count, "\(language.rawValue) has duplicates")
        }
    }

    /// The insertability rule: a keyword is offered in the same popup as an
    /// identifier and replaces the same typed prefix, so a token the scanner
    /// would split (a dot, a space, a leading digit) could be *offered* and then
    /// only partly inserted. Requiring every entry to round-trip through
    /// `completionPrefixRange` unchanged keeps that impossible.
    func testEveryKeywordIsASingleInsertableToken() {
        for language in SyntaxLanguage.allCases {
            for keyword in LanguageKeywords.keywords(for: language) {
                let text = keyword as NSString
                let range = IdentifierScanner.completionPrefixRange(in: text, at: text.length)
                XCTAssertEqual(
                    range,
                    NSRange(location: 0, length: text.length),
                    "\(language.rawValue): \(keyword) is not one identifier"
                )
            }
        }
    }

    /// Every keyword must also be reachable by the matcher that filters it —
    /// typing its own first character has to hit a word boundary, which for a
    /// whole-token query it trivially does. Cheap, but it is the join between
    /// this file and `FuzzyMatch`'s boundary rule.
    /// Every keyword is reachable through the matcher's *boundary* rule, which is
    /// what the completion sources have in common.
    ///
    /// Deliberately not `FuzzyMatch.matches(keyword, query: keyword.prefix(2))`:
    /// any string is a prefix of itself, so `quality`'s `hasPrefix` short-circuit
    /// answers before a single boundary is computed and the assertion cannot fail
    /// for any realistic list edit. The two properties asserted here are the ones
    /// the keyword source actually depends on — that a keyword's first character
    /// is its first boundary initial (the bucket rule symbols are filed under),
    /// and that a *non-prefix* query anchored on a later boundary reaches it, the
    /// path that goes through the subsequence walk rather than around it.
    func testEveryKeywordIsReachableThroughTheBoundaryRule() {
        for language in SyntaxLanguage.allCases {
            for keyword in LanguageKeywords.keywords(for: language) {
                let initials = FuzzyMatch.wordBoundaryInitials(of: keyword)
                XCTAssertEqual(
                    initials.first,
                    keyword.lowercased().first,
                    "\(language.rawValue): \(keyword) does not start its own first word"
                )
                // Anchor on the last boundary the matcher will accept and walk the
                // rest of the name from there — a genuinely fuzzy query.
                guard let anchor = initials.last, anchor != initials.first else { continue }
                XCTAssertNotNil(
                    FuzzyMatch.quality(of: keyword, matching: String(anchor)),
                    "\(language.rawValue): \(keyword) is unreachable by \(anchor)"
                )
            }
        }
    }

    // MARK: - Spot checks

    func testSwiftListCoversDeclarationAndStatementKeywords() {
        let swift = LanguageKeywords.keywords(for: .swift)
        for keyword in ["guard", "func", "struct", "async", "throws", "nil", "willSet", "some"] {
            XCTAssertTrue(swift.contains(keyword), keyword)
        }
    }

    func testTypeScriptIsJavaScriptPlusItsTypeVocabulary() {
        let javaScript = Set(LanguageKeywords.keywords(for: .javascript))
        let typeScript = Set(LanguageKeywords.keywords(for: .typescript))

        XCTAssertTrue(javaScript.isSubset(of: typeScript))
        for keyword in ["async", "interface", "readonly", "keyof", "satisfies", "type"] {
            XCTAssertTrue(typeScript.contains(keyword), keyword)
        }
        // The type-level words stay out of plain JavaScript.
        XCTAssertFalse(javaScript.contains("interface"))
        XCTAssertFalse(javaScript.contains("readonly"))
    }

    func testPythonListCoversReservedAndSoftKeywords() {
        let python = LanguageKeywords.keywords(for: .python)
        for keyword in ["elif", "def", "lambda", "None", "nonlocal", "match", "yield"] {
            XCTAssertTrue(python.contains(keyword), keyword)
        }
    }

    /// Dockerfile's tokens are the instructions themselves, uppercase as they
    /// are written — a lowercase spelling is not what the file contains.
    func testDockerfileListIsTheUppercaseInstructionSet() {
        let dockerfile = LanguageKeywords.keywords(for: .dockerfile)
        for keyword in ["FROM", "RUN", "COPY", "ENTRYPOINT", "HEALTHCHECK", "WORKDIR"] {
            XCTAssertTrue(dockerfile.contains(keyword), keyword)
        }
        XCTAssertFalse(dockerfile.contains("from"))
        for keyword in dockerfile {
            XCTAssertEqual(keyword, keyword.uppercased(), keyword)
        }
    }

    /// Go's list is the one that deliberately reaches past the reserved words
    /// into the universe block, so what it pins is *content*: the shape
    /// invariants (sorted, unique, insertable, reachable) already come free from
    /// the per-language sweeps above.
    ///
    /// The four families are spelled out separately because they are four
    /// different arguments for inclusion — a reserved word, a predeclared
    /// constant, a predeclared type and a built-in function — and dropping any
    /// one of them would leave that family uncompletable in a Go project with no
    /// other source able to offer it.
    ///
    /// Asserted by **set equality** against their union rather than as
    /// representative subsets, because a subset check is exactly what a hand edit
    /// slips through: dropping `close`, `println` or `float32` from a list of 69
    /// leaves every named spelling still present and every shape invariant still
    /// true, and the built-in it silently loses can never be offered by anything
    /// else. The equality also fails in the other direction, so a name that is
    /// *not* in the universe block cannot be added without saying which family it
    /// joins.
    func testGoListIsExactlyTheReservedWordsAndTheUniverseBlock() {
        // All 25 reserved words: the list's floor (Go spec, "Keywords").
        let reserved = [
            "break", "case", "chan", "const", "continue", "default", "defer",
            "else", "fallthrough", "for", "func", "go", "goto", "if", "import",
            "interface", "map", "package", "range", "return", "select",
            "struct", "switch", "type", "var",
        ]
        // The 22 predeclared types, the 4 predeclared constants (`nil` is
        // formally a zero value, and belongs here for the same reason) and the
        // 18 built-in functions — the universe block, which no source file
        // declares and so no index can ever offer.
        let types = [
            "any", "bool", "byte", "comparable", "complex64", "complex128", "error",
            "float32", "float64", "int", "int8", "int16", "int32", "int64", "rune",
            "string", "uint", "uint8", "uint16", "uint32", "uint64", "uintptr",
        ]
        let constants = ["true", "false", "iota", "nil"]
        let builtins = [
            "append", "cap", "clear", "close", "complex", "copy", "delete", "imag",
            "len", "make", "max", "min", "new", "panic", "print", "println", "real",
            "recover",
        ]

        XCTAssertEqual(reserved.count, 25)
        XCTAssertEqual(types.count, 22)
        XCTAssertEqual(constants.count, 4)
        XCTAssertEqual(builtins.count, 18)

        XCTAssertEqual(
            Set(LanguageKeywords.keywords(for: .go)),
            Set(reserved + types + constants + builtins)
        )
        XCTAssertEqual(LanguageKeywords.keywords(for: .go).count, 69, "the list gained a duplicate")
    }

    /// The line the list must not cross: a package's declarations are the symbol
    /// index's job, not the keyword source's. `fmt.Println` is the canonical
    /// temptation — it is what a Go file types first — and it is a declaration in
    /// a package, so it stays out, along with any other dotted or qualified name.
    func testGoListIsNotAStandardLibraryIndex() {
        let go = LanguageKeywords.keywords(for: .go)

        for keyword in ["fmt.Println", "fmt", "Println", "errors", "context", "Sprintf"] {
            XCTAssertFalse(go.contains(keyword), keyword)
        }
        for keyword in go {
            XCTAssertFalse(keyword.contains("."), keyword)
        }
    }
}
