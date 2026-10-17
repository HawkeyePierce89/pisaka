import XCTest
@testable import PisakaCore

/// Pins the matching-tag decision (R5): which tag names a caret highlights,
/// one level only, and which of the tag and bracket pairs wins where both
/// could paint.
final class TagMatchRuleTests: XCTestCase {

    // MARK: - Fixture helpers

    /// The `occurrence`-th range of `needle` in `text`.
    private func range(_ needle: String, _ occurrence: Int = 0, in text: NSString) -> NSRange {
        var searchStart = 0
        var found = NSRange(location: NSNotFound, length: 0)
        for _ in 0...occurrence {
            found = text.range(
                of: needle, options: .literal,
                range: NSRange(location: searchStart, length: text.length - searchStart)
            )
            XCTAssertNotEqual(found.location, NSNotFound, "no occurrence \(occurrence) of \(needle)")
            searchStart = NSMaxRange(found)
        }
        return found
    }

    /// An element named `name` opened by its `open`-th `<name` and closed by
    /// its `close`-th `</name>`.
    private func element(_ name: String, open: Int = 0, close: Int = 0, in text: NSString) -> TagElement {
        let opening = range("<\(name)", open, in: text)
        let closing = range("</\(name)>", close, in: text)
        return TagElement(
            range: NSRange(location: opening.location, length: NSMaxRange(closing) - opening.location),
            openName: NSRange(location: opening.location + 1, length: (name as NSString).length),
            closeName: NSRange(location: closing.location + 2, length: (name as NSString).length)
        )
    }

    /// A self-closing element `<name … />`, its `open`-th occurrence.
    private func selfClosing(_ name: String, open: Int = 0, in text: NSString) -> TagElement {
        let opening = range("<\(name)", open, in: text)
        let end = text.range(
            of: "/>", options: .literal,
            range: NSRange(location: opening.location, length: text.length - opening.location)
        )
        return TagElement(
            range: NSRange(location: opening.location, length: NSMaxRange(end) - opening.location),
            openName: NSRange(location: opening.location + 1, length: (name as NSString).length),
            closeName: nil
        )
    }

    private func highlight(
        _ caret: Int, _ chain: [TagElement], bracket: Bool = false
    ) -> TagMatchRule.Highlight {
        TagMatchRule.highlight(caret: caret, enclosing: chain, bracketPairActive: bracket)
    }

    private func names(_ element: TagElement) -> TagMatchRule.Highlight {
        TagMatchRule.Highlight(tagRanges: [element.openName, element.closeName!], suppressBracketPair: false)
    }

    // MARK: - The Header sample

    private let headerSample = """
    export function Header() {
      return (
        <header className="top">
          <span>Title</span>
        </header>
      );
    }
    """ as NSString

    func testCaretInTheClosingHeaderNameHighlightsBothHeaderNames() {
        let header = element("header", in: headerSample)
        let caret = header.closeName!.location + 3
        XCTAssertEqual(
            highlight(caret, [header]),
            TagMatchRule.Highlight(tagRanges: [header.openName, header.closeName!], suppressBracketPair: true)
        )
    }

    func testCaretInTheSpanTextHighlightsTheSpanNames() {
        let header = element("header", in: headerSample)
        let span = element("span", in: headerSample)
        let caret = range("Title", in: headerSample).location + 2
        XCTAssertEqual(highlight(caret, [span, header]), names(span))
    }

    func testTagNameEndsAreInclusive() {
        let header = element("header", in: headerSample)
        let expected = TagMatchRule.Highlight(
            tagRanges: [header.openName, header.closeName!], suppressBracketPair: true
        )
        XCTAssertEqual(highlight(header.openName.location, [header]), expected)
        XCTAssertEqual(highlight(NSMaxRange(header.openName), [header]), expected)
        XCTAssertEqual(highlight(NSMaxRange(header.closeName!), [header]), expected)
    }

    func testAnEmptyChainHighlightsNothing() {
        XCTAssertEqual(highlight(3, []), .none)
    }

    // MARK: - Nesting

    func testNestedSameNameElementsPairByStructureNotByName() {
        let text = "<div><div>x</div></div>" as NSString
        let outer = element("div", open: 0, close: 1, in: text)
        let inner = element("div", open: 1, close: 0, in: text)

        let inInnerClose = inner.closeName!.location + 1
        XCTAssertEqual(
            highlight(inInnerClose, [inner, outer]).tagRanges,
            [inner.openName, inner.closeName!]
        )
        let inOuterClose = outer.closeName!.location + 1
        XCTAssertEqual(highlight(inOuterClose, [outer]).tagRanges, [outer.openName, outer.closeName!])
        XCTAssertEqual(highlight(range("x", in: text).location, [inner, outer]), names(inner))
    }

    func testOnlyTheInnermostEnclosingElementIsHighlighted() {
        let text = "<ul><li>one</li></ul>" as NSString
        let list = element("ul", in: text)
        let item = element("li", in: text)
        XCTAssertEqual(highlight(range("one", in: text).location + 1, [item, list]), names(item))
    }

    // MARK: - Fragments

    func testFragmentsPairWithEachOther() {
        let text = "<><b>x</b> y</>" as NSString
        let fragment = TagElement(
            range: NSRange(location: 0, length: text.length),
            openName: range("<>", in: text),
            closeName: range("</>", in: text)
        )
        let bold = element("b", in: text)

        XCTAssertEqual(
            highlight(1, [fragment]),
            TagMatchRule.Highlight(tagRanges: [fragment.openName, fragment.closeName!], suppressBracketPair: true)
        )
        XCTAssertEqual(highlight(range(" y", in: text).location + 1, [fragment]).tagRanges, [fragment.openName, fragment.closeName!])
        XCTAssertEqual(highlight(range("x", in: text).location, [bold, fragment]), names(bold))
    }

    // MARK: - Self-closing and unclosed elements

    func testCaretInASelfClosingNameHighlightsItsOneName() {
        let text = "<div><Icon size={2} /></div>" as NSString
        let div = element("div", in: text)
        let icon = selfClosing("Icon", in: text)
        XCTAssertEqual(
            highlight(icon.openName.location + 2, [icon, div]),
            TagMatchRule.Highlight(tagRanges: [icon.openName], suppressBracketPair: true)
        )
    }

    func testCaretElsewhereInASelfClosingElementPassesOverIt() {
        let text = "<div><Icon size={2} /></div>" as NSString
        let div = element("div", in: text)
        let icon = selfClosing("Icon", in: text)
        XCTAssertEqual(highlight(range("size", in: text).location + 1, [icon, div]), names(div))
    }

    func testASelfClosingElementAloneHighlightsNothingOutsideItsName() {
        let text = "<Icon size={2} />" as NSString
        let icon = selfClosing("Icon", in: text)
        XCTAssertEqual(highlight(range("size", in: text).location, [icon]), .none)
    }

    func testAnUnclosedElementPassesToItsClosedParent() {
        let text = "<section><p>open</section>" as NSString
        let section = element("section", in: text)
        let paragraphOpen = range("<p", in: text)
        let paragraph = TagElement(
            range: NSRange(location: paragraphOpen.location, length: 7),
            openName: NSRange(location: paragraphOpen.location + 1, length: 1),
            closeName: nil
        )
        XCTAssertEqual(highlight(range("open", in: text).location + 1, [paragraph, section]), names(section))
        XCTAssertEqual(
            highlight(paragraph.openName.location, [paragraph, section]),
            TagMatchRule.Highlight(tagRanges: [paragraph.openName], suppressBracketPair: true)
        )
    }

    // MARK: - Attributes and children

    func testCaretInAnAttributeHighlightsItsElement() {
        let text = "<ul><a href=\"x\">link</a></ul>" as NSString
        let list = element("ul", in: text)
        let anchor = element("a", in: text)
        XCTAssertEqual(highlight(range("href", in: text).location + 2, [anchor, list]), names(anchor))
        XCTAssertEqual(highlight(range("\"x\"", in: text).location + 1, [anchor, list]), names(anchor))
    }

    func testCaretAmongChildrenHighlightsTheParent() {
        let text = "<ul> <li>one</li> </ul>" as NSString
        let list = element("ul", in: text)
        XCTAssertEqual(highlight(NSMaxRange(range("</li>", in: text)) + 1, [list]), names(list))
    }

    // MARK: - Bracket priority

    func testAtAnActiveBracketOutsideATagNameTheBracketWins() {
        let text = "<div>{value}</div>" as NSString
        let div = element("div", in: text)
        XCTAssertEqual(highlight(range("{", in: text).location, [div], bracket: true), .none)
        XCTAssertEqual(highlight(range("{", in: text).location, [div], bracket: false), names(div))
    }

    func testInATagNameTheTagWinsOverAnActiveBracket() {
        let text = "f(<></>)" as NSString
        let fragment = TagElement(
            range: NSRange(location: 2, length: 5),
            openName: range("<>", in: text),
            closeName: range("</>", in: text)
        )
        XCTAssertEqual(
            highlight(fragment.openName.location, [fragment], bracket: true),
            TagMatchRule.Highlight(tagRanges: [fragment.openName, fragment.closeName!], suppressBracketPair: true)
        )
    }

    func testOutsideATagNameWithoutABracketNothingIsSuppressed() {
        let header = element("header", in: headerSample)
        let caret = range("className", in: headerSample).location
        XCTAssertFalse(highlight(caret, [header]).suppressBracketPair)
    }
}
