import XCTest
@testable import PisakaCore

/// The editor's top offset, as the line the preview is asked to show.
///
/// A small rule with one interesting property: it is **total**. Every offset a
/// scroll view can report — including a negative one during a rubber-band
/// bounce and one past the end during a live resize — has an answer, because the
/// alternative is an optional whose `nil` every caller would have to turn back
/// into a line anyway.
final class MarkdownScrollRuleTests: XCTestCase {

    /// Four lines, the last of them unterminated: offsets 0, 6, 12, 18.
    private let text = "line1\nline2\nline3\nline4" as NSString

    private func line(_ offset: Int) -> Int {
        MarkdownScrollRule.line(forTopOffset: offset, in: text)
    }

    func testTheStartOfTheDocumentIsLineOne() {
        XCTAssertEqual(line(0), 1)
    }

    func testAnOffsetInsideALineIsThatLine() {
        XCTAssertEqual(line(5), 1)
        XCTAssertEqual(line(6), 2)
        XCTAssertEqual(line(13), 3)
    }

    func testTheLastLineIsReachable() {
        XCTAssertEqual(line(18), 4)
        XCTAssertEqual(line(text.length), 4)
    }

    func testAnOffsetPastTheEndIsTheLastLine() {
        XCTAssertEqual(line(text.length + 500), 4)
    }

    func testANegativeOffsetIsLineOne() {
        XCTAssertEqual(line(-1), 1)
    }

    func testEmptyTextIsLineOne() {
        XCTAssertEqual(MarkdownScrollRule.line(forTopOffset: 0, in: "" as NSString), 1)
        XCTAssertEqual(MarkdownScrollRule.line(forTopOffset: 7, in: "" as NSString), 1)
    }

    func testATrailingSeparatorAddsItsEmptyLine() {
        // `LineStartIndex` counts the empty line after a final separator, as the
        // gutter does — so a document ending in a newline has one more line than
        // it has runs of text, and the preview may be asked for it.
        let terminated = "a\nb\n" as NSString
        XCTAssertEqual(MarkdownScrollRule.line(forTopOffset: terminated.length, in: terminated), 3)
    }

    func testTheEditorSeparatorSetIsUsedNotLFAlone() {
        // CR, CRLF, NEL, LS and PS all start a line here, which is what keeps
        // the number agreeing with the one in the gutter.
        let mixed = "a\rb\r\nc\u{0085}d\u{2028}e\u{2029}f" as NSString
        XCTAssertEqual(MarkdownScrollRule.line(forTopOffset: mixed.length - 1, in: mixed), 6)
    }

    func testAnEmptyLineStartTableReadsAsLineOne() {
        XCTAssertEqual(MarkdownScrollRule.line(forTopOffset: 42, lineStarts: []), 1)
    }

    /// The scroll-sync path end to end, on the one thing that could quietly
    /// disagree: the rule counts the *editor's* lines and the page matches
    /// against `data-line`, which the renderer wrote from the parser's own
    /// 1-based source lines. A document scrolled into its middle must therefore
    /// answer the very number the block sitting there carries — otherwise the
    /// page's "last block at or before this line" rule would land one block off
    /// on every document.
    func testAScrolledOffsetAnswersTheSourceLineOfTheBlockItIsIn() {
        // "# Title" / "" / "A paragraph." / "" / "## Section" / "" / "Another."
        let markdown = "# Title\n\nA paragraph.\n\n## Section\n\nAnother.\n" as NSString
        let starts = LineStartIndex.offsets(in: markdown)

        // The source lines the renderer emits as `data-line` for that document.
        for sourceLine in [1, 3, 5, 7] {
            XCTAssertEqual(
                MarkdownScrollRule.line(forTopOffset: starts[sourceLine - 1], in: markdown),
                sourceLine
            )
        }

        // Scrolled to a blank line — one no block starts on — the answer is that
        // line, and the page's own rule is what walks it back to the block above.
        XCTAssertEqual(MarkdownScrollRule.line(forTopOffset: starts[3], in: markdown), 4)

        // And mid-block: an offset inside the paragraph is still the paragraph's
        // own line, so a slow scroll through it sends the same line every frame
        // and the page does not twitch.
        XCTAssertEqual(MarkdownScrollRule.line(forTopOffset: starts[2] + 5, in: markdown), 3)
    }

    func testTheCachedAndUncachedFormsAgree() {
        let starts = LineStartIndex.offsets(in: text)
        for offset in -2...(text.length + 2) {
            XCTAssertEqual(
                MarkdownScrollRule.line(forTopOffset: offset, lineStarts: starts),
                line(offset)
            )
        }
    }
}
