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
}
