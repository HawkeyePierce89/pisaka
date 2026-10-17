import XCTest
@testable import PisakaCore

final class BlockCommentEngineTests: XCTestCase {

    private let slashStar = BlockCommentDelimiters(open: "/*", close: "*/")

    private func apply(_ plan: RangeEditPlan, to text: String) -> String {
        let result = NSMutableString(string: text)
        for edit in plan.edits.reversed() {
            result.replaceCharacters(in: edit.range, with: edit.replacement)
        }
        return result as String
    }

    private func selected(_ plan: RangeEditPlan, in text: String) -> [String] {
        let result = apply(plan, to: text) as NSString
        return plan.selections.map { result.substring(with: $0) }
    }

    private func range(of needle: String, in text: String) -> NSRange {
        (text as NSString).range(of: needle)
    }

    private func toggle(
        _ text: String, _ ranges: [NSRange], language: SyntaxLanguage?,
        context: @escaping (Int) -> CommentContext = { _ in .code }
    ) -> RangeEditPlan? {
        BlockCommentEngine.toggle(text: text as NSString, selectedRanges: ranges, language: language, context: context)
    }

    // MARK: - Wrap, unwrap, caret

    func testASelectionIsWrappedAndSelectedSoASecondPressUnwraps() {
        let text = "let a = b + c"
        let wrap = BlockCommentEngine.toggle(
            text: text as NSString, selectedRanges: [range(of: "b + c", in: text)], delimiters: slashStar
        )
        let wrapped = apply(wrap, to: text)
        XCTAssertEqual(wrapped, "let a = /* b + c */")
        XCTAssertEqual(selected(wrap, in: text), ["/* b + c */"])

        let unwrap = BlockCommentEngine.toggle(
            text: wrapped as NSString, selectedRanges: wrap.selections, delimiters: slashStar
        )
        XCTAssertEqual(apply(unwrap, to: wrapped), text)
        XCTAssertEqual(selected(unwrap, in: wrapped), ["b + c"])
    }

    func testUnwrapTakesTheInnerSpacesOnlyWhenPresent() {
        let cases = [
            ("/*x*/", "x"), ("/* x*/", "x"), ("/*x */", "x"), ("/*  x  */", " x "), ("/**/", ""),
            ("/* */", ""), ("/*  */", ""),
        ]
        for (input, inner) in cases {
            let plan = BlockCommentEngine.toggle(
                text: input as NSString, selectedRanges: [NSRange(location: 0, length: (input as NSString).length)],
                delimiters: slashStar
            )
            XCTAssertEqual(apply(plan, to: input), inner, input)
            XCTAssertEqual(selected(plan, in: input), [inner], input)
        }
    }

    func testDelimitersSharingCharactersAreNotAWholeComment() {
        // `/*/` starts with `/*` and ends with `*/`, but only by sharing the `*`.
        let plan = BlockCommentEngine.toggle(
            text: "/*/" as NSString, selectedRanges: [NSRange(location: 0, length: 3)], delimiters: slashStar
        )
        XCTAssertEqual(apply(plan, to: "/*/"), "/* /*/ */")
    }

    func testACaretInsertsAnEmptyPairWithTheCaretBetweenTheTwoSpaces() {
        let text = "let a = 1\nlet b = 2"
        let k = range(of: "1", in: text).location
        let plan = BlockCommentEngine.toggle(
            text: text as NSString, selectedRanges: [NSRange(location: k, length: 0)], delimiters: slashStar
        )
        XCTAssertEqual(plan.edits, [IndentReplacement(range: NSRange(location: k, length: 0), replacement: "/*  */")])
        XCTAssertEqual(plan.selections, [NSRange(location: k + 3, length: 0)])
        XCTAssertEqual(apply(plan, to: text), "let a = /*  */1\nlet b = 2")
    }

    func testTheSwiftCommandAtACaretIsExactlyTheEmptyPair() throws {
        let text = "func f() {}\n"
        let k = 9
        let plan = try XCTUnwrap(toggle(text, [NSRange(location: k, length: 0)], language: .swift))
        XCTAssertEqual(plan.edits, [IndentReplacement(range: NSRange(location: k, length: 0), replacement: "/*  */")])
        XCTAssertEqual(plan.selections, [NSRange(location: k + 3, length: 0)])
    }

    // MARK: - Delimiters per language

    func testHTMLWrapsInMarkupComments() throws {
        let text = "<p>hi</p>"
        let plan = try XCTUnwrap(toggle(text, [NSRange(location: 0, length: 9)], language: .html))
        let wrapped = apply(plan, to: text)
        XCTAssertEqual(wrapped, "<!-- <p>hi</p> -->")
        let back = try XCTUnwrap(toggle(wrapped, plan.selections, language: .html))
        XCTAssertEqual(apply(back, to: wrapped), text)
    }

    func testJSXChildrenWrapInBracedComments() throws {
        let text = "return (\n  <div>\n    <span />\n  </div>\n)"
        let child = range(of: "<span />", in: text)
        let childLineStart = child.location
        let plan = try XCTUnwrap(toggle(text, [child], language: .tsx) { offset in
            offset == childLineStart ? .jsxChildren : .code
        })
        let wrapped = apply(plan, to: text)
        XCTAssertEqual(wrapped, "return (\n  <div>\n    {/* <span /> */}\n  </div>\n)")
        let back = try XCTUnwrap(toggle(wrapped, plan.selections, language: .tsx) { offset in
            offset == childLineStart ? .jsxChildren : .code
        })
        XCTAssertEqual(apply(back, to: wrapped), text)
    }

    func testTheContextIsAskedAtTheStartingLinesFirstNonWhitespace() throws {
        let text = "a\n    b c\n"
        var asked: [Int] = []
        _ = toggle(text, [range(of: "c", in: text)], language: .javascript) { offset in
            asked.append(offset)
            return .code
        }
        XCTAssertEqual(asked, [range(of: "b", in: text).location])
    }

    func testCodeInAJSXLanguageUsesSlashStar() throws {
        let text = "const a = 1"
        let plan = try XCTUnwrap(toggle(text, [range(of: "1", in: text)], language: .typescript))
        XCTAssertEqual(apply(plan, to: text), "const a = /* 1 */")
    }

    func testANonJSXLanguageNeverAsksTheContext() throws {
        let plan = try XCTUnwrap(toggle("x", [NSRange(location: 0, length: 1)], language: .rust) { _ in
            XCTFail("rust has no contextual delimiters")
            return .code
        })
        XCTAssertEqual(apply(plan, to: "x"), "/* x */")
    }

    // MARK: - Multi-range

    func testEveryRangeIsAnsweredInOnePlan() throws {
        let text = "a b\nc d\n"
        let ranges = [range(of: "a", in: text), NSRange(location: 2, length: 0), range(of: "d", in: text)]
        let plan = try XCTUnwrap(toggle(text, ranges, language: .go))
        XCTAssertEqual(apply(plan, to: text), "/* a */ /*  */b\nc /* d */\n")
        XCTAssertEqual(selected(plan, in: text), ["/* a */", "", "/* d */"])
        let result = apply(plan, to: text) as NSString
        XCTAssertEqual(plan.selections[1].location, result.range(of: "/*  */b").location + 3)
    }

    func testMixedWrapAndUnwrapAcrossRanges() throws {
        let text = "/* a */ b"
        let plan = try XCTUnwrap(toggle(text, [NSRange(location: 0, length: 7), range(of: "b", in: text)],
                                        language: .css))
        XCTAssertEqual(apply(plan, to: text), "a /* b */")
        XCTAssertEqual(selected(plan, in: text), ["a", "/* b */"])
    }

    func testIdenticalCaretsInsertOnce() throws {
        let plan = try XCTUnwrap(toggle("ab", [NSRange(location: 1, length: 0), NSRange(location: 1, length: 0)],
                                        language: .swift))
        XCTAssertEqual(apply(plan, to: "ab"), "a/*  */b")
        XCTAssertEqual(plan.selections.count, 1)
    }

    // MARK: - Fallbacks

    func testLineOnlyLanguagesRunTheLineToggle() throws {
        for (language, text) in [(SyntaxLanguage.python, "x = 1\ny = 2\n"), (.sql, "select 1\nselect 2\n")] {
            let ranges = [NSRange(location: 0, length: (text as NSString).length)]
            let plan = try XCTUnwrap(toggle(text, ranges, language: language), "\(language)")
            let line = try XCTUnwrap(ToggleCommentEngine.toggle(
                text: text as NSString, selectedRanges: ranges, language: language
            ))
            XCTAssertEqual(plan, line, "\(language)")
        }
        XCTAssertEqual(
            apply(try XCTUnwrap(toggle("x = 1", [NSRange(location: 0, length: 0)], language: .python)), to: "x = 1"),
            "# x = 1"
        )
        XCTAssertEqual(
            apply(try XCTUnwrap(toggle("select 1", [NSRange(location: 0, length: 0)], language: .sql)), to: "select 1"),
            "-- select 1"
        )
    }

    func testLanguagesWithoutCommentsAreANoOp() {
        XCTAssertNil(toggle("{}", [NSRange(location: 0, length: 2)], language: .json))
        XCTAssertNil(toggle("# h", [NSRange(location: 0, length: 0)], language: .markdown))
        XCTAssertNil(toggle("x", [NSRange(location: 0, length: 0)], language: nil))
    }

    func testEveryLanguageWithoutBlockCommentsFallsBackOrIsANoOp() {
        for language in CommentStyle.languagesWithoutBlockComments {
            let result = toggle("x", [NSRange(location: 0, length: 0)], language: language)
            XCTAssertEqual(result == nil, CommentStyle.languagesWithoutComments.contains(language), "\(language)")
        }
    }
}
