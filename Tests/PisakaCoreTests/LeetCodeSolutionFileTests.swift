import XCTest
@testable import PisakaCore

final class LeetCodeSolutionFileTests: XCTestCase {

    private var swift: LeetCodeLanguage { LeetCodeSolutionFile.language(forLangSlug: "swift")! }
    private var python: LeetCodeLanguage { LeetCodeSolutionFile.language(forLangSlug: "python3")! }

    // MARK: - Language mapping

    /// Both directions exist for every offerable language — the property the
    /// one-row-per-language shape is meant to guarantee.
    func testEveryOfferableLanguageMapsBothWays() {
        for entry in LeetCodeSolutionFile.offerableLanguages {
            XCTAssertEqual(
                LeetCodeSolutionFile.language(forLangSlug: entry.langSlug),
                entry,
                "\(entry.langSlug) did not resolve from its own slug"
            )
            XCTAssertEqual(
                LeetCodeSolutionFile.language(for: entry.language),
                entry,
                "\(entry.langSlug) did not resolve from its own SyntaxLanguage"
            )
        }
    }

    func testTheAgreedLanguagesAreOffered() {
        let slugs = LeetCodeSolutionFile.offerableLanguages.map(\.langSlug)
        XCTAssertEqual(slugs, ["swift", "python3", "golang", "rust", "typescript", "javascript"])
    }

    /// The two slugs that are not the obvious ones — getting either wrong seeds
    /// the wrong starter code (Python 2) or resolves to nothing at all.
    func testPythonAndGoUseLeetCodesOwnSlugs() {
        XCTAssertEqual(LeetCodeSolutionFile.language(for: .python)?.langSlug, "python3")
        XCTAssertEqual(LeetCodeSolutionFile.language(for: .go)?.langSlug, "golang")
        XCTAssertNil(LeetCodeSolutionFile.language(forLangSlug: "python"))
    }

    func testSlugsAndExtensionsAreUnique() {
        let slugs = LeetCodeSolutionFile.offerableLanguages.map(\.langSlug)
        let extensions = LeetCodeSolutionFile.offerableLanguages.map(\.fileExtension)
        let languages = LeetCodeSolutionFile.offerableLanguages.map(\.language)
        XCTAssertEqual(Set(slugs).count, slugs.count)
        XCTAssertEqual(Set(extensions).count, extensions.count)
        XCTAssertEqual(Set(languages).count, languages.count)
    }

    /// The extension is what makes the editor highlight the file, so it must be
    /// one `SyntaxLanguage` resolves back to the same language from.
    func testExtensionResolvesBackToTheSameEditorLanguage() {
        for entry in LeetCodeSolutionFile.offerableLanguages {
            XCTAssertEqual(
                SyntaxLanguage(fileExtension: entry.fileExtension),
                entry.language,
                "\(entry.fileExtension) does not highlight as \(entry.language)"
            )
        }
    }

    func testUnofferedLanguagesResolveToNil() {
        XCTAssertNil(LeetCodeSolutionFile.language(for: .json))
        XCTAssertNil(LeetCodeSolutionFile.language(for: .markdown))
        XCTAssertNil(LeetCodeSolutionFile.language(forLangSlug: "kotlin"))
        XCTAssertNil(LeetCodeSolutionFile.language(forLangSlug: ""))
    }

    func testLangSlugLookupIsCaseAndWhitespaceTolerant() {
        XCTAssertEqual(LeetCodeSolutionFile.language(forLangSlug: " Python3 ")?.langSlug, "python3")
    }

    /// The judge names its `lang` from the file's extension, so every language
    /// this app can *write* a file in must map back from the extension it wrote —
    /// otherwise Run refuses a file the picker just created.
    func testEveryOfferableExtensionResolvesBackToItsLanguage() {
        for entry in LeetCodeSolutionFile.offerableLanguages {
            XCTAssertEqual(
                LeetCodeSolutionFile.language(forFileExtension: entry.fileExtension),
                entry,
                "\(entry.fileExtension) does not resolve back to \(entry.displayName)"
            )
        }
    }

    /// A file the folder happens to hold, and a language LeetCode accepts but
    /// this app does not offer: both answer `nil`, which the judge turns into a
    /// stated refusal rather than a guessed language.
    func testUnofferedExtensionsResolveToNil() {
        XCTAssertNil(LeetCodeSolutionFile.language(forFileExtension: "md"))
        XCTAssertNil(LeetCodeSolutionFile.language(forFileExtension: "rb"))
        XCTAssertNil(LeetCodeSolutionFile.language(forFileExtension: "cpp"))
        XCTAssertNil(LeetCodeSolutionFile.language(forFileExtension: ""))
        XCTAssertNil(LeetCodeSolutionFile.language(forFileExtension: "."))
    }

    /// Case-insensitively, because the volume is: `0001-two-sum.PY` is the same
    /// file as `0001-two-sum.py` on APFS. A leading dot is tolerated for a
    /// caller that spells the extension the way a human does.
    func testFileExtensionLookupToleratesCaseDotAndWhitespace() {
        XCTAssertEqual(LeetCodeSolutionFile.language(forFileExtension: "PY")?.langSlug, "python3")
        XCTAssertEqual(LeetCodeSolutionFile.language(forFileExtension: ".py")?.langSlug, "python3")
        XCTAssertEqual(
            LeetCodeSolutionFile.language(forFileExtension: " .Swift ")?.langSlug,
            "swift"
        )
    }

    func testDefaultLanguageIsSwift() {
        XCTAssertEqual(LeetCodeSolutionFile.defaultLanguage.language, .swift)
    }

    // MARK: - Names

    func testNameIsZeroPaddedToFourDigits() {
        XCTAssertEqual(
            LeetCodeSolutionFile.name(number: 1, slug: "two-sum", language: swift),
            "0001-two-sum.swift"
        )
        XCTAssertEqual(
            LeetCodeSolutionFile.name(number: 42, slug: "trapping-rain-water", language: python),
            "0042-trapping-rain-water.py"
        )
        XCTAssertEqual(
            LeetCodeSolutionFile.name(number: 999, slug: "candy", language: swift),
            "0999-candy.swift"
        )
    }

    func testPaddingBoundaries() {
        XCTAssertEqual(
            LeetCodeSolutionFile.name(number: 1000, slug: "candy", language: swift),
            "1000-candy.swift"
        )
        XCTAssertEqual(
            LeetCodeSolutionFile.name(number: 10000, slug: "candy", language: swift),
            "10000-candy.swift"
        )
    }

    // MARK: - Reverse parse

    func testRoundTripForEveryOfferableLanguage() {
        for entry in LeetCodeSolutionFile.offerableLanguages {
            let name = LeetCodeSolutionFile.name(number: 76, slug: "minimum-window-substring",
                                                 language: entry)
            XCTAssertEqual(LeetCodeSolutionFile.problemNumber(fromFileName: name), 76)
            XCTAssertEqual(
                LeetCodeSolutionFile.slug(fromFileName: name),
                "minimum-window-substring"
            )
        }
    }

    func testRoundTripAcrossPaddingBoundaries() {
        for number in [1, 9, 10, 99, 100, 999, 1000, 9999, 10000] {
            let name = LeetCodeSolutionFile.name(number: number, slug: "n-queens-ii",
                                                 language: swift)
            XCTAssertEqual(LeetCodeSolutionFile.problemNumber(fromFileName: name), number, name)
            XCTAssertEqual(LeetCodeSolutionFile.slug(fromFileName: name), "n-queens-ii", name)
        }
    }

    func testReverseParseAcceptsAPath() {
        let path = "/Users/x/Documents/LeetCode/0001-two-sum.swift"
        XCTAssertEqual(LeetCodeSolutionFile.problemNumber(fromFileName: path), 1)
        XCTAssertEqual(LeetCodeSolutionFile.slug(fromFileName: path), "two-sum")
    }

    /// A file rewritten in a language this build does not offer, or with no
    /// extension at all, is still recognisably a solution file.
    func testReverseParseToleratesUnknownAndMissingExtensions() {
        XCTAssertEqual(LeetCodeSolutionFile.problemNumber(fromFileName: "0001-two-sum.kt"), 1)
        XCTAssertEqual(LeetCodeSolutionFile.slug(fromFileName: "0001-two-sum.kt"), "two-sum")
        XCTAssertEqual(LeetCodeSolutionFile.problemNumber(fromFileName: "0001-two-sum"), 1)
        XCTAssertEqual(LeetCodeSolutionFile.slug(fromFileName: "0001-two-sum"), "two-sum")
    }

    func testHyphenatedSlugKeepsEveryHyphen() {
        XCTAssertEqual(
            LeetCodeSolutionFile.slug(fromFileName: "0004-median-of-two-sorted-arrays.swift"),
            "median-of-two-sorted-arrays"
        )
    }

    func testNamesThatAreNotOursAreRejected() {
        for name in [
            "two-sum.swift",      // no number
            "-two-sum.swift",     // empty digits
            "0000-two-sum.swift", // no problem zero
            "0001-.swift",        // no slug
            "0001-two sum.swift", // not a slug
            "0001.swift",         // no hyphen
            "README.md",
            "",
        ] {
            XCTAssertNil(LeetCodeSolutionFile.problemNumber(fromFileName: name), name)
            XCTAssertNil(LeetCodeSolutionFile.slug(fromFileName: name), name)
        }
    }

    func testUppercaseNameNormalizesItsSlug() {
        XCTAssertEqual(LeetCodeSolutionFile.slug(fromFileName: "0001-Two-Sum.swift"), "two-sum")
    }

    // MARK: - Header and contents

    func testHeaderUsesTheLanguagesLineComment() {
        XCTAssertEqual(
            LeetCodeSolutionFile.header(number: 1, title: "Two Sum", slug: "two-sum",
                                        language: swift),
            "// 1. Two Sum — https://leetcode.com/problems/two-sum"
        )
        XCTAssertEqual(
            LeetCodeSolutionFile.header(number: 1, title: "Two Sum", slug: "two-sum",
                                        language: python),
            "# 1. Two Sum — https://leetcode.com/problems/two-sum"
        )
    }

    func testHeaderIsOneLineForEveryOfferableLanguage() {
        for entry in LeetCodeSolutionFile.offerableLanguages {
            let header = LeetCodeSolutionFile.header(number: 3, title: "Longest Substring",
                                                     slug: "longest-substring", language: entry)
            XCTAssertFalse(header.contains("\n"), entry.langSlug)
            XCTAssertTrue(header.hasPrefix(entry.lineCommentPrefix + " "), entry.langSlug)
            XCTAssertTrue(header.contains("longest-substring"), entry.langSlug)
            XCTAssertTrue(header.contains("3."), entry.langSlug)
        }
    }

    /// One line is a guarantee, not a description of well-behaved input.
    ///
    /// The title goes into a *line* comment, so a separator inside it would end
    /// the comment and leave the remainder as bare, uncommented text on line 2 of
    /// a file the never-overwrite rule then keeps forever. Trimming the ends does
    /// not cover that.
    func testHeaderCollapsesSeparatorsInsideTheTitle() {
        let header = LeetCodeSolutionFile.header(
            number: 1,
            title: "Two\nSum",
            slug: "two-sum",
            language: swift
        )
        XCTAssertEqual(header, "// 1. Two Sum — https://leetcode.com/problems/two-sum")
        XCTAssertFalse(header.contains("\n"))

        // A CRLF is two separators with nothing between them, and must still cost
        // one space.
        XCTAssertEqual(
            LeetCodeSolutionFile.header(
                number: 1,
                title: "Two\r\nSum",
                slug: "two-sum",
                language: swift
            ),
            "// 1. Two Sum — https://leetcode.com/problems/two-sum"
        )
        // A title that is nothing but separators is as blank as "   ".
        XCTAssertEqual(
            LeetCodeSolutionFile.header(
                number: 1,
                title: "\n\n",
                slug: "two-sum",
                language: swift
            ),
            "// 1. two-sum — https://leetcode.com/problems/two-sum"
        )
    }

    func testHeaderFallsBackToTheSlugWhenTheTitleIsBlank() {
        XCTAssertEqual(
            LeetCodeSolutionFile.header(number: 1, title: "   ", slug: "two-sum", language: swift),
            "// 1. two-sum — https://leetcode.com/problems/two-sum"
        )
    }

    func testContentsIsHeaderBlankLineThenTheSnippetVerbatim() {
        let snippet = "class Solution {\n    func twoSum() {\n\n    }\n}"
        let header = "// 1. Two Sum — https://leetcode.com/problems/two-sum"
        XCTAssertEqual(
            LeetCodeSolutionFile.contents(header: header, snippet: snippet),
            header + "\n\n" + snippet + "\n"
        )
    }

    /// The snippet is the judge's expected signature: it is never reindented,
    /// trimmed or otherwise touched.
    func testContentsPreservesSnippetWhitespaceExactly() {
        let snippet = "  \tdef f(self):\n        pass  "
        let contents = LeetCodeSolutionFile.contents(header: "# x", snippet: snippet)
        XCTAssertTrue(contents.hasSuffix(snippet + "\n"))
    }

    func testASnippetThatAlreadyEndsInANewlineIsNotGivenASecond() {
        XCTAssertEqual(
            LeetCodeSolutionFile.contents(header: "// h", snippet: "code\n"),
            "// h\n\ncode\n"
        )
    }

    func testContentsWithoutAHeaderIsTheSnippetAlone() {
        XCTAssertEqual(LeetCodeSolutionFile.contents(header: nil, snippet: "code"), "code\n")
        XCTAssertEqual(LeetCodeSolutionFile.contents(header: "", snippet: "code"), "code\n")
    }

    func testContentsWithoutASnippetIsTheHeaderAlone() {
        XCTAssertEqual(LeetCodeSolutionFile.contents(header: "// h", snippet: ""), "// h\n")
        XCTAssertEqual(LeetCodeSolutionFile.contents(header: nil, snippet: ""), "")
    }

    /// The name a seeded file gets and the parse the description panel performs
    /// are one unit: whatever is written must be readable back.
    func testSeededFileNameAndContentsAgreeOnTheProblem() {
        let name = LeetCodeSolutionFile.name(number: 1, slug: "two-sum", language: swift)
        let header = LeetCodeSolutionFile.header(number: 1, title: "Two Sum", slug: "two-sum",
                                                 language: swift)
        let contents = LeetCodeSolutionFile.contents(header: header, snippet: "class Solution {}")

        XCTAssertEqual(LeetCodeSolutionFile.problemNumber(fromFileName: name), 1)
        XCTAssertEqual(LeetCodeSolutionFile.slug(fromFileName: name), "two-sum")
        XCTAssertEqual(SyntaxLanguage(forFileName: name), .swift)
        XCTAssertTrue(contents.contains(LeetCodeAPI.problemURL(slug: "two-sum").absoluteString))
    }
}
