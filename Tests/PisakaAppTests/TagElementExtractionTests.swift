#if os(macOS)
import AppKit
import PisakaCore
import SwiftTreeSitter
import XCTest
@testable import Pisaka

/// The matching-tag highlight's app half (R5): `SyntaxTreeSnapshot` parses the
/// TSX, JSX and HTML fixtures with the real grammars, `TagElementExtraction`
/// reads the caret's enclosing elements off the tree, and
/// `TagHighlightController` paints what `TagMatchRule` decides.
///
/// What it pins:
/// - the extracted chain at chosen offsets — innermost first, both names of a
///   closed element, one name of a self-closing one, a fragment's `<>`/`</>`;
/// - nested same-name elements pair with their own closing tag, not an outer one;
/// - a caret at either edge of a name still sees its element;
/// - the snapshot serves an unchanged buffer from its cache and re-parses
///   after an edit;
/// - the controller paints the rule's ranges, reports the bracket-pair
///   suppression, and an edit during a settle discards its answer.
///
/// The fixtures are read through `#filePath`: source data about the grammars,
/// not resources the product ships. The causal hop is the settle's own task,
/// awaited — never a sleep.
@MainActor
final class TagElementExtractionTests: XCTestCase {

    // MARK: - TSX

    func testTSXClosingTagNameGivesTheElementsTwoNames() throws {
        let text = try fixture("tags.tsx")
        let caret = nth("</header", 0, in: text).location + 4
        let chain = try elements(text, .tsx, at: caret)
        let header = try XCTUnwrap(chain.first)
        XCTAssertEqual(header.openName, name("header", after: "<header", 0, in: text))
        XCTAssertEqual(header.closeName, name("header", after: "</header", 0, in: text))
        let highlight = TagMatchRule.highlight(caret: caret, enclosing: chain, bracketPairActive: false)
        XCTAssertEqual(highlight.tagRanges, [header.openName, try XCTUnwrap(header.closeName)])
        XCTAssertTrue(highlight.suppressBracketPair)
    }

    func testTSXChainIsInnermostFirstThroughNestedSameNameElements() throws {
        let text = try fixture("tags.tsx")
        let caret = nth("{title}</span>", 0, in: text).location + 1
        let chain = try elements(text, .tsx, at: caret)
        XCTAssertEqual(chain.map { substring($0.openName, in: text) }, ["span", "div", "div", "header"])
        // The inner `div` is the second opened and the first closed.
        XCTAssertEqual(chain[1].openName, name("div", after: "<div", 1, in: text))
        XCTAssertEqual(chain[1].closeName, name("div", after: "</div", 0, in: text))
        XCTAssertEqual(chain[2].openName, name("div", after: "<div", 0, in: text))
        XCTAssertEqual(chain[2].closeName, name("div", after: "</div", 1, in: text))

        let highlight = TagMatchRule.highlight(caret: caret, enclosing: chain, bracketPairActive: false)
        XCTAssertEqual(highlight.tagRanges, [chain[0].openName, try XCTUnwrap(chain[0].closeName)])
        XCTAssertFalse(highlight.suppressBracketPair)
    }

    func testTSXInnerClosingDivPairsWithItsOwnOpening() throws {
        let text = try fixture("tags.tsx")
        let innerClose = name("div", after: "</div", 0, in: text)
        let chain = try elements(text, .tsx, at: innerClose.location)
        let highlight = TagMatchRule.highlight(caret: innerClose.location, enclosing: chain, bracketPairActive: false)
        XCTAssertEqual(highlight.tagRanges, [name("div", after: "<div", 1, in: text), innerClose])
    }

    func testBothEdgesOfANameSeeTheElement() throws {
        let text = try fixture("tags.tsx")
        let open = name("header", after: "<header", 0, in: text)
        for caret in [open.location, NSMaxRange(open)] {
            let chain = try elements(text, .tsx, at: caret)
            XCTAssertEqual(chain.first?.openName, open, "caret \(caret)")
        }
    }

    func testTSXSelfClosingElementHasOneName() throws {
        let text = try fixture("tags.tsx")
        let icon = nth("Icon", 0, in: text)
        let chain = try elements(text, .tsx, at: icon.location + 2)
        let element = try XCTUnwrap(chain.first)
        XCTAssertEqual(element.openName, icon)
        XCTAssertNil(element.closeName)
        let highlight = TagMatchRule.highlight(caret: icon.location + 2, enclosing: chain, bracketPairActive: false)
        XCTAssertEqual(highlight.tagRanges, [icon])
    }

    func testTSXFragmentNamesAreItsTags() throws {
        let text = try fixture("tags.tsx")
        let caret = nth(" tail", 0, in: text).location + 2
        let chain = try elements(text, .tsx, at: caret)
        let fragment = try XCTUnwrap(chain.first)
        XCTAssertEqual(fragment.openName, nth("<>", 0, in: text))
        XCTAssertEqual(fragment.closeName, nth("</>", 0, in: text))
        XCTAssertEqual(substring(chain[1].openName, in: text), "header")
    }

    // MARK: - JSX

    func testJSXNestedSameNameAndMemberSelfClosingAndFragment() throws {
        let text = try fixture("tags.jsx")
        let caret = nth("{items[0]}", 0, in: text).location + 1
        let chain = try elements(text, .javascript, at: caret)
        XCTAssertEqual(chain.map { substring($0.openName, in: text) }, ["li", "li", "ul"])
        XCTAssertEqual(chain[0].openName, name("li", after: "<li", 1, in: text))
        XCTAssertEqual(chain[0].closeName, name("li", after: "</li", 0, in: text))

        let row = nth("Item.Row", 0, in: text)
        let rowChain = try elements(text, .javascript, at: row.location + 1)
        XCTAssertEqual(rowChain.first?.openName, row)
        XCTAssertNil(rowChain.first?.closeName)

        let fragmentChain = try elements(text, .javascript, at: nth("fragment text", 0, in: text).location)
        XCTAssertEqual(fragmentChain.first?.openName, nth("<>", 0, in: text))
        XCTAssertEqual(fragmentChain.first?.closeName, nth("</>", 0, in: text))
    }

    // MARK: - HTML

    func testHTMLElementsVoidAndSelfClosingAndScript() throws {
        let text = try fixture("tags.html")
        let caret = nth("text</div>", 0, in: text).location + 1
        let chain = try elements(text, .html, at: caret)
        XCTAssertEqual(chain.map { substring($0.openName, in: text) }, ["div", "div", "body", "html"])
        XCTAssertEqual(chain[0].openName, name("div", after: "<div", 1, in: text))
        XCTAssertEqual(chain[0].closeName, name("div", after: "</div", 0, in: text))
        XCTAssertEqual(chain[1].closeName, name("div", after: "</div", 1, in: text))

        let br = name("br", after: "<br", 0, in: text)
        let brChain = try elements(text, .html, at: br.location + 1)
        XCTAssertEqual(brChain.first?.openName, br)
        XCTAssertNil(brChain.first?.closeName)

        let img = name("img", after: "<img", 0, in: text)
        let imgChain = try elements(text, .html, at: img.location + 1)
        XCTAssertEqual(imgChain.first?.openName, img)
        XCTAssertNil(imgChain.first?.closeName, "a void element has no closing name")

        let scriptChain = try elements(text, .html, at: nth("let x", 0, in: text).location)
        XCTAssertEqual(scriptChain.first?.openName, name("script", after: "<script", 0, in: text))
        XCTAssertEqual(scriptChain.first?.closeName, name("script", after: "</script", 0, in: text))
    }

    func testALanguageWithoutTagsExtractsNothing() throws {
        let text = "let a = <b>(1)\n"
        let tree = try XCTUnwrap(SyntaxTreeSnapshot.parse(text: text, language: .typescript))
        XCTAssertEqual(TagElementExtraction.enclosingElements(in: tree, language: .typescript, at: 9), [])
    }

    // MARK: - Snapshot cache

    func testTheSnapshotCachesUntilAnEdit() async throws {
        let text = try fixture("tags.tsx")
        let snapshot = SyntaxTreeSnapshot()
        let fileID = UUID()
        let first = await snapshot.tree(text: text, language: .tsx, fileID: fileID)
        XCTAssertNotNil(first)
        let second = await snapshot.tree(text: text, language: .tsx, fileID: fileID)
        XCTAssertTrue(first === second, "an unchanged buffer was re-parsed")
        XCTAssertEqual(snapshot.parseCount, 1)
        XCTAssertNotNil(snapshot.cached(language: .tsx, fileID: fileID))

        snapshot.noteEdit()
        XCTAssertNil(snapshot.cached(language: .tsx, fileID: fileID))
        _ = await snapshot.tree(text: text, language: .tsx, fileID: fileID)
        XCTAssertEqual(snapshot.parseCount, 2)
        _ = await snapshot.tree(text: text, language: .tsx, fileID: UUID())
        XCTAssertEqual(snapshot.parseCount, 3, "another buffer was served this one's tree")
    }

    // MARK: - Controller

    func testTheControllerPaintsTheRulesRangesAndReportsSuppression() async throws {
        let text = try fixture("tags.tsx")
        let (harness, controller, suppression) = makeController(text: text)
        let close = name("header", after: "</header", 0, in: text)
        harness.textView.setSelectedRange(NSRange(location: close.location + 2, length: 0))
        await controller.settleNow()?.value

        let open = name("header", after: "<header", 0, in: text)
        XCTAssertEqual(controller.paintedRanges, [open, close])
        XCTAssertEqual(suppression.values.last, true)
        XCTAssertNotNil(background(harness, at: open.location), "the opening name is not painted")
        XCTAssertNotNil(background(harness, at: close.location), "the closing name is not painted")

        // Mid-identifier: `{|title}` would touch a brace, where the bracket pair wins.
        let span = nth("{title}", 0, in: text).location + 3
        harness.textView.setSelectedRange(NSRange(location: span, length: 0))
        await controller.settleNow()?.value
        XCTAssertEqual(controller.paintedRanges.map { substring($0, in: text) }, ["span", "span"])
        XCTAssertEqual(suppression.values.last, false)
        XCTAssertNil(background(harness, at: open.location), "the previous pair was left painted")
    }

    func testAnEditDuringASettleDiscardsItsAnswer() async throws {
        let text = try fixture("tags.tsx")
        let (harness, controller, _) = makeController(text: text)
        let close = name("header", after: "</header", 0, in: text)
        harness.textView.setSelectedRange(NSRange(location: close.location + 2, length: 0))
        let task = controller.settleNow()
        controller.noteEdit()
        await task?.value
        XCTAssertEqual(controller.paintedRanges, [])
    }

    func testASelectionOrAnUntaggedLanguagePaintsNothing() async throws {
        let text = try fixture("tags.tsx")
        let (harness, controller, _) = makeController(text: text)
        let close = name("header", after: "</header", 0, in: text)
        harness.textView.setSelectedRange(NSRange(location: close.location, length: 3))
        await controller.settleNow()?.value
        XCTAssertEqual(controller.paintedRanges, [])

        controller.language = { .typescript }
        harness.textView.setSelectedRange(NSRange(location: close.location, length: 0))
        await controller.settleNow()?.value
        XCTAssertEqual(controller.paintedRanges, [])
    }

    // MARK: - Helpers

    private final class Recorder {
        var values: [Bool] = []
    }

    private func makeController(text: String) -> (EditorLayoutHarness, TagHighlightController, Recorder) {
        let harness = EditorLayoutHarness()
        harness.textView.string = text
        harness.layOut()
        harness.textView.sizeToFit()
        let controller = TagHighlightController()
        let snapshot = SyntaxTreeSnapshot()
        let fileID = UUID()
        let recorder = Recorder()
        controller.snapshot = snapshot
        controller.fileID = { fileID }
        controller.language = { .tsx }
        controller.onBracketPairSuppression = { recorder.values.append($0) }
        controller.attach(textView: harness.textView)
        return (harness, controller, recorder)
    }

    private func fixture(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func elements(_ text: String, _ language: SyntaxLanguage, at offset: Int) throws -> [TagElement] {
        let tree = try XCTUnwrap(SyntaxTreeSnapshot.parse(text: text, language: language), "the grammar did not load")
        return TagElementExtraction.enclosingElements(in: tree, language: language, at: offset)
    }

    /// The `index`-th occurrence of `needle`, zero-based.
    private func nth(_ needle: String, _ index: Int, in text: String) -> NSRange {
        let ns = text as NSString
        var start = 0
        var found = NSRange(location: NSNotFound, length: 0)
        for _ in 0...index {
            found = ns.range(of: needle, range: NSRange(location: start, length: ns.length - start))
            guard found.location != NSNotFound else { break }
            start = NSMaxRange(found)
        }
        XCTAssertNotEqual(found.location, NSNotFound, "fixture lacks occurrence \(index) of \(needle)")
        return found
    }

    /// The range of `tag` inside the `index`-th occurrence of `prefix` (which
    /// ends with `tag`), e.g. `div` of the second `<div`.
    private func name(_ tag: String, after prefix: String, _ index: Int, in text: String) -> NSRange {
        let found = nth(prefix, index, in: text)
        let length = (tag as NSString).length
        return NSRange(location: NSMaxRange(found) - length, length: length)
    }

    private func substring(_ range: NSRange, in text: String) -> String {
        (text as NSString).substring(with: range)
    }

    private func background(_ harness: EditorLayoutHarness, at index: Int) -> NSColor? {
        harness.layoutManager.temporaryAttribute(.backgroundColor, atCharacterIndex: index, effectiveRange: nil)
            as? NSColor
    }
}
#endif
