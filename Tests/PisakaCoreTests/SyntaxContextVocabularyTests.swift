import XCTest
@testable import PisakaCore

/// Pins the lexing vocabulary that `SyntaxContextScanner` will ask.
///
/// The tests here assert the *shape* of the table rather than re-stating every
/// delimiter: that the closed-set patterns close, that the table is consistent
/// with `CommentStyle`, and that no language silently falls through.
final class SyntaxContextVocabularyTests: XCTestCase {

    // MARK: - Closure over all languages

    func testLanguagesWithAndWithoutStringVocabularyPartitionAllCases() {
        let withStrings = Set(
            SyntaxLanguage.allCases.filter { !SyntaxContextVocabulary.stringForms(for: $0).isEmpty }
        )
        let without = SyntaxContextVocabulary.languagesWithoutStringVocabulary

        XCTAssertEqual(withStrings.union(without), Set(SyntaxLanguage.allCases))
        XCTAssertTrue(withStrings.isDisjoint(with: without))
    }

    func testLanguagesWithoutStringVocabularyIsExactlyDocumented() {
        XCTAssertEqual(
            SyntaxContextVocabulary.languagesWithoutStringVocabulary,
            [.markdown, .gitignore, .editorconfig]
        )
    }

    func testLanguagesWithAndWithoutCommentVocabularyPartitionAllCases() {
        let withComments = Set(
            SyntaxLanguage.allCases.filter { !SyntaxContextVocabulary.commentForms(for: $0).isEmpty }
        )
        let without = CommentStyle.languagesWithoutComments

        XCTAssertEqual(withComments.union(without), Set(SyntaxLanguage.allCases))
        XCTAssertTrue(withComments.isDisjoint(with: without))
    }

    // MARK: - CommentStyle containment

    /// Every token `CommentStyle.style(for:)` names must appear among that
    /// language's `SyntaxContextVocabulary` comment forms.
    ///
    /// Asserted as containment and not equality because the vocabulary refines the
    /// toggle style: editorconfig toggles with `#` but the lexing vocabulary
    /// additionally recognizes `;` at line start, since both are real comments in
    /// the file. Equality would either force the vocabulary to drop `;` or force
    /// `CommentStyle` to carry it, conflating the preferred toggle with the full
    /// lexical set.
    func testCommentStyleTokensAreContainedInTheVocabulary() {
        for language in SyntaxLanguage.allCases {
            guard let style = CommentStyle.style(for: language) else {
                // A language without a toggle style must declare no comment forms.
                XCTAssertTrue(
                    SyntaxContextVocabulary.commentForms(for: language).isEmpty,
                    "\(language.rawValue) has no CommentStyle but declares comment forms"
                )
                continue
            }

            let forms = SyntaxContextVocabulary.commentForms(for: language)
            let tokensInForms: Set<String> = Set(forms.compactMap { form in
                switch form {
                case .line(let token, _): return token
                case .block(let open, _, _): return open
                }
            })
            // Block forms also carry the close delimiter, but the toggle only
            // names the open side for block comments — check that open.
            switch style {
            case .line(let token):
                XCTAssertTrue(
                    tokensInForms.contains(token),
                    "\(language.rawValue): CommentStyle token \(token) not in vocabulary"
                )
            case .block(let open, _):
                XCTAssertTrue(
                    tokensInForms.contains(open),
                    "\(language.rawValue): CommentStyle block open \(open) not in vocabulary"
                )
            }
        }
    }

    func testLanguagesWithoutCommentsDeclareNoCommentForms() {
        for language in CommentStyle.languagesWithoutComments {
            XCTAssertTrue(
                SyntaxContextVocabulary.commentForms(for: language).isEmpty,
                "\(language.rawValue) is without comments but declares forms"
            )
        }
    }

    // MARK: - stringsSuppressCompletion

    func testStringsSuppressCompletionIsFalseForTheFourDocumentVocabularyLanguages() {
        for language in [SyntaxLanguage.json, .yaml, .html, .dotenv] as [SyntaxLanguage] {
            XCTAssertFalse(
                SyntaxContextVocabulary.stringsSuppressCompletion(for: language),
                "\(language.rawValue) should not gate strings"
            )
            XCTAssertFalse(
                SyntaxContextVocabulary.vocabulary(for: language).stringsSuppressCompletion,
                "\(language.rawValue) vocabulary flag"
            )
        }
    }

    func testStringsSuppressCompletionIsTrueForGatedLanguages() {
        for language in [SyntaxLanguage.swift, .javascript, .typescript, .python, .go, .rust, .css, .sql, .dockerfile] as [SyntaxLanguage] {
            XCTAssertTrue(
                SyntaxContextVocabulary.stringsSuppressCompletion(for: language),
                "\(language.rawValue) should gate strings"
            )
        }
    }

    func testStringsSuppressCompletionIsFalseForLanguagesWithoutStrings() {
        for language in SyntaxContextVocabulary.languagesWithoutStringVocabulary {
            XCTAssertFalse(
                SyntaxContextVocabulary.stringsSuppressCompletion(for: language),
                "\(language.rawValue) has no strings to gate"
            )
        }
    }

    // MARK: - canSuppressCompletion

    func testCanSuppressCompletionIsFalseOnlyForMarkdownAndJson() {
        for language in SyntaxLanguage.allCases {
            let can = SyntaxContextVocabulary.canSuppressCompletion(language)
            if language == .markdown || language == .json {
                XCTAssertFalse(can, "\(language.rawValue) should not suppress")
            } else {
                XCTAssertTrue(can, "\(language.rawValue) should suppress")
            }
        }
    }

    // MARK: - No empty or duplicated delimiters

    func testNoStringFormHasAnEmptyDelimiter() {
        for language in SyntaxLanguage.allCases {
            for form in SyntaxContextVocabulary.stringForms(for: language) {
                XCTAssertFalse(form.open.isEmpty, "\(language.rawValue) string open is empty")
                XCTAssertFalse(form.close.isEmpty, "\(language.rawValue) string close is empty")
            }
        }
    }

    func testNoCommentFormHasAnEmptyDelimiter() {
        for language in SyntaxLanguage.allCases {
            for form in SyntaxContextVocabulary.commentForms(for: language) {
                switch form {
                case .line(let token, _):
                    XCTAssertFalse(token.isEmpty, "\(language.rawValue) line comment token is empty")
                case .block(let open, let close, _):
                    XCTAssertFalse(open.isEmpty, "\(language.rawValue) block open is empty")
                    XCTAssertFalse(close.isEmpty, "\(language.rawValue) block close is empty")
                }
            }
        }
    }

    func testNoLanguageHasDuplicatedStringDelimiters() {
        for language in SyntaxLanguage.allCases {
            let forms = SyntaxContextVocabulary.stringForms(for: language)
            // Duplicate means same (open, close, poundPadding, prefix) tuple.
            var seen: Set<String> = []
            for form in forms {
                let key = "\(form.open)|\(form.close)|\(form.allowsPoundPadding)|\(form.allowedPrefixLetters?.sorted().map(String.init).joined() ?? "")|\(form.escape)"
                XCTAssertTrue(seen.insert(key).inserted, "\(language.rawValue) has duplicated string form \(key)")
            }
        }
    }

    func testNoLanguageHasDuplicatedCommentDelimiters() {
        for language in SyntaxLanguage.allCases {
            let forms = SyntaxContextVocabulary.commentForms(for: language)
            var seen: Set<String> = []
            for form in forms {
                let key: String
                switch form {
                case .line(let token, let anchor): key = "line:\(token):\(anchor)"
                case .block(let open, let close, let nestable): key = "block:\(open):\(close):\(nestable)"
                }
                XCTAssertTrue(seen.insert(key).inserted, "\(language.rawValue) has duplicated comment form \(key)")
            }
        }
    }

    // MARK: - Spot checks for non-obvious decisions

    /// Rust's `'` is not a string delimiter — lifetime `&'a` would open a bogus
    /// literal, and a char literal is one character wide and never worth
    /// completing inside.
    func testRustHasNoSingleQuoteStringForm() {
        let forms = SyntaxContextVocabulary.stringForms(for: .rust)
        XCTAssertFalse(forms.contains { $0.open == "'" }, "Rust must not model ' as a string delimiter")
    }

    /// SQL's `"` is not a string delimiter — it quotes an identifier, which is
    /// exactly the thing worth completing.
    func testSqlHasNoDoubleQuoteStringForm() {
        let forms = SyntaxContextVocabulary.stringForms(for: .sql)
        XCTAssertFalse(forms.contains { $0.open == "\"" }, "SQL must not model \" as a string delimiter")
    }

    func testMarkdownIsCompletelyUngated() {
        let v = SyntaxContextVocabulary.vocabulary(for: .markdown)
        XCTAssertTrue(v.stringForms.isEmpty)
        XCTAssertTrue(v.commentForms.isEmpty)
        XCTAssertFalse(v.stringsSuppressCompletion)
        XCTAssertFalse(SyntaxContextVocabulary.canSuppressCompletion(.markdown))
    }

    // MARK: - Line anchors

    /// The anchor each language holds, by whole-set equality, so a new language
    /// or a re-pointed one has to be decided here rather than inherited.
    func testLineAnchorAssignmentPerLanguage() {
        var byAnchor: [SyntaxContextVocabulary.LineAnchor: Set<SyntaxLanguage>] = [:]
        for language in SyntaxLanguage.allCases {
            for form in SyntaxContextVocabulary.commentForms(for: language) {
                guard case .line(_, let anchor) = form else { continue }
                byAnchor[anchor, default: []].insert(language)
            }
        }
        // The key set closes the vocabulary from the other side: a fifth
        // `LineAnchor` case would otherwise add a key nothing below looks at, and
        // the four assertions would all still pass while a whole reading of what
        // starts a comment went unstated.
        XCTAssertEqual(Set(byAnchor.keys), [.anywhere, .trueLineStart, .afterIndent, .afterWhitespace])
        XCTAssertEqual(byAnchor[.anywhere], [.swift, .javascript, .typescript, .python, .go, .rust, .sql])
        XCTAssertEqual(byAnchor[.trueLineStart], [.gitignore])
        XCTAssertEqual(byAnchor[.afterIndent], [.dockerfile, .dotenv, .editorconfig])
        XCTAssertEqual(byAnchor[.afterWhitespace], [.yaml])
    }

    /// editorconfig anchors *both* of its tokens the same way — the `;` must not
    /// quietly hold a different reading from the `#`.
    func testEditorconfigAnchorsBothCommentTokensAfterIndent() {
        XCTAssertEqual(
            SyntaxContextVocabulary.commentForms(for: .editorconfig),
            [.line(token: "#", anchor: .afterIndent), .line(token: ";", anchor: .afterIndent)]
        )
    }

    // MARK: - The dotenv escape decision

    /// dotenv has no normative grammar and its loaders disagree about escapes,
    /// so the vocabulary states the lexically conservative reading — the first
    /// matching quote closes the literal — rather than borrowing another
    /// language's backslash convention. Nothing depends on the choice; this test
    /// pins the stated reading so a future edit is a decision, not a drift.
    func testDotenvStringFormsDeclareNoEscape() {
        let forms = SyntaxContextVocabulary.stringForms(for: .dotenv)
        XCTAssertEqual(forms.count, 2)
        XCTAssertEqual(Set(forms.map(\.open)), ["'", "\""])
        for form in forms {
            XCTAssertEqual(form.escape, .none, "dotenv \(form.open) must declare no escape rule")
        }
    }
}
