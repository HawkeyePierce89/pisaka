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
        XCTAssertEqual(withKeywords, [.swift, .javascript, .typescript, .python, .dockerfile])
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
    func testEveryKeywordMatchesItsOwnPrefix() {
        for language in SyntaxLanguage.allCases {
            for keyword in LanguageKeywords.keywords(for: language) {
                let prefix = String(keyword.prefix(2))
                XCTAssertTrue(
                    FuzzyMatch.matches(keyword, query: prefix),
                    "\(language.rawValue): \(keyword) is unreachable by \(prefix)"
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
}
