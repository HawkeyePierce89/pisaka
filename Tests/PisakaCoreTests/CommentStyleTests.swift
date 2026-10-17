import XCTest
@testable import PisakaCore

final class CommentStyleTests: XCTestCase {

    func testEveryLanguageEitherHasAStyleOrIsExcluded() {
        let withStyle = Set(SyntaxLanguage.allCases.filter { CommentStyle.style(for: $0) != nil })
        let excluded = CommentStyle.languagesWithoutComments

        XCTAssertEqual(withStyle.union(excluded), Set(SyntaxLanguage.allCases))
        XCTAssertTrue(withStyle.isDisjoint(with: excluded))
    }

    func testExcludedLanguagesReturnNil() {
        for language in CommentStyle.languagesWithoutComments {
            XCTAssertNil(CommentStyle.style(for: language), "\(language.rawValue)")
        }
    }

    func testStylesAreCorrectAndNotEmpty() {
        for language in SyntaxLanguage.allCases {
            guard let style = CommentStyle.style(for: language) else { continue }

            switch style {
            case .line(let token):
                XCTAssertFalse(token.isEmpty, "\(language.rawValue) line comment token should not be empty")
            case .block(let open, let close):
                XCTAssertFalse(open.isEmpty, "\(language.rawValue) block comment open should not be empty")
                XCTAssertFalse(close.isEmpty, "\(language.rawValue) block comment close should not be empty")
            }
        }

        // Exact spelling checks for the major families
        XCTAssertEqual(CommentStyle.style(for: .swift), .line("//"))
        XCTAssertEqual(CommentStyle.style(for: .python), .line("#"))
        XCTAssertEqual(CommentStyle.style(for: .editorconfig), .line("#"))
        XCTAssertEqual(CommentStyle.style(for: .sql), .line("--"))
        XCTAssertEqual(CommentStyle.style(for: .css), .block(open: "/*", close: "*/"))
        XCTAssertEqual(CommentStyle.style(for: .html), .block(open: "<!--", close: "-->"))
    }

    func testShellUsesTheHashLineComment() {
        XCTAssertEqual(CommentStyle.style(for: .shell), .line("#"))
        XCTAssertFalse(CommentStyle.languagesWithoutComments.contains(.shell))
    }

    func testMakeUsesTheHashLineComment() {
        XCTAssertEqual(CommentStyle.style(for: .make), .line("#"))
        XCTAssertFalse(CommentStyle.languagesWithoutComments.contains(.make))
    }

    // MARK: - JSX context

    private typealias Chain = [(kind: String, startsAtLineOffset: Bool)]

    func testAChildElementLineIsJSXChildren() {
        // `    <span>a</span>` inside `<div>`: `<` → opening element → span → div.
        let chain: Chain = [
            ("jsx_opening_element", true), ("jsx_element", true), ("jsx_element", false),
            ("parenthesized_expression", false), ("return_statement", false), ("program", false),
        ]
        XCTAssertEqual(CommentStyle.context(ancestors: chain), .jsxChildren)
    }

    func testAJSXTextLineIsJSXChildren() {
        let chain: Chain = [("jsx_text", false), ("jsx_element", false), ("program", false)]
        XCTAssertEqual(CommentStyle.context(ancestors: chain), .jsxChildren)
    }

    func testALineInsideAnExpressionIsCode() {
        let chain: Chain = [
            ("identifier", true), ("member_expression", true), ("jsx_expression", false),
            ("jsx_element", false), ("program", false),
        ]
        XCTAssertEqual(CommentStyle.context(ancestors: chain), .code)
    }

    func testTheRootElementOfAReturnIsCode() {
        let chain: Chain = [
            ("jsx_opening_element", true), ("jsx_element", true),
            ("parenthesized_expression", false), ("return_statement", false), ("program", false),
        ]
        XCTAssertEqual(CommentStyle.context(ancestors: chain), .code)
    }

    func testPlainCodeAndAnEmptyChainAreCode() {
        let chain: Chain = [("identifier", true), ("lexical_declaration", true), ("program", false)]
        XCTAssertEqual(CommentStyle.context(ancestors: chain), .code)
        XCTAssertEqual(CommentStyle.context(ancestors: []), .code)
    }

    func testAnAttributeLineInsideAMultiLineOpeningTagIsCode() {
        // `      className="x"` continuing `<span` from the line above.
        let chain: Chain = [
            ("property_identifier", true), ("jsx_attribute", true),
            ("jsx_opening_element", false), ("jsx_element", false), ("jsx_element", false),
        ]
        XCTAssertEqual(CommentStyle.context(ancestors: chain), .code)
    }

    func testALoneSelfClosingEndIsCode() {
        // `    />` closing a multi-line `<img` among the children.
        let chain: Chain = [("jsx_self_closing_element", false), ("jsx_element", false), ("program", false)]
        XCTAssertEqual(CommentStyle.context(ancestors: chain), .code)
    }

    func testAChildsClosingTagLineIsJSXChildren() {
        // `    </span>` ending a multi-line child span.
        let chain: Chain = [
            ("jsx_closing_element", true), ("jsx_element", false), ("jsx_element", false), ("program", false),
        ]
        XCTAssertEqual(CommentStyle.context(ancestors: chain), .jsxChildren)
    }

    func testTheChildrenOfAFragmentAreJSXChildren() {
        // A fragment is a `jsx_element` whose opening element has no name.
        let element: Chain = [
            ("jsx_opening_element", true), ("jsx_element", true), ("jsx_element", false),
            ("parenthesized_expression", false),
        ]
        XCTAssertEqual(CommentStyle.context(ancestors: element), .jsxChildren)
        let selfClosing: Chain = [("jsx_self_closing_element", true), ("jsx_element", false)]
        XCTAssertEqual(CommentStyle.context(ancestors: selfClosing), .jsxChildren)
    }

    func testContextualStyleOverEveryLanguage() {
        let jsx: Set<SyntaxLanguage> = [.javascript, .typescript, .tsx]
        for language in SyntaxLanguage.allCases {
            XCTAssertEqual(CommentStyle.style(for: language, context: .code), CommentStyle.style(for: language),
                           "\(language)")
            if jsx.contains(language) {
                XCTAssertEqual(CommentStyle.style(for: language, context: .jsxChildren),
                               .block(open: "{/*", close: "*/}"), "\(language)")
            } else {
                XCTAssertEqual(CommentStyle.style(for: language, context: .jsxChildren),
                               CommentStyle.style(for: language), "\(language)")
            }
        }
    }
}

final class CommentStyleBlockDelimiterTests: XCTestCase {

    func testTheBlockCommentSetsPartitionEveryLanguage() {
        let with = CommentStyle.languagesWithBlockComments
        let without = CommentStyle.languagesWithoutBlockComments
        XCTAssertEqual(with.union(without), Set(SyntaxLanguage.allCases))
        XCTAssertTrue(with.isDisjoint(with: without))
    }

    func testTheSetsAgreeWithTheTableInBothContexts() {
        for language in SyntaxLanguage.allCases {
            for context in [CommentContext.code, .jsxChildren] {
                XCTAssertEqual(
                    CommentStyle.blockDelimiters(for: language, context: context) != nil,
                    CommentStyle.languagesWithBlockComments.contains(language),
                    "\(language) \(context)"
                )
            }
        }
    }

    func testDelimiterSpellings() {
        let slashStar = BlockCommentDelimiters(open: "/*", close: "*/")
        for language in [SyntaxLanguage.swift, .javascript, .typescript, .tsx, .go, .rust, .css] {
            XCTAssertEqual(CommentStyle.blockDelimiters(for: language, context: .code), slashStar, "\(language)")
        }
        XCTAssertEqual(
            CommentStyle.blockDelimiters(for: .html, context: .code), BlockCommentDelimiters(open: "<!--", close: "-->")
        )
        for language in [SyntaxLanguage.javascript, .typescript, .tsx] {
            XCTAssertEqual(
                CommentStyle.blockDelimiters(for: language, context: .jsxChildren),
                BlockCommentDelimiters(open: "{/*", close: "*/}"), "\(language)"
            )
        }
        // JSX children exist only in the JavaScript family.
        for language in [SyntaxLanguage.swift, .go, .rust, .css, .html] {
            XCTAssertEqual(
                CommentStyle.blockDelimiters(for: language, context: .jsxChildren),
                CommentStyle.blockDelimiters(for: language, context: .code), "\(language)"
            )
        }
    }
}
