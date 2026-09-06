#if os(macOS)
import AppKit
import XCTest
@testable import Pisaka

@MainActor
final class FoldLayoutTests: XCTestCase {
    /// A document long enough to produce an extra line fragment on
    /// `textView.string = text` — the shape that triggers the re-entrant
    /// typesetter allocation described in the plan's Overview.
    private let firstDocument = (0..<50).map { "line \($0) — the quick brown fox jumps over the lazy dog" }.joined(separator: "\n")
    private let secondDocument = (0..<50).map { "replaced \($0) — lorem ipsum dolor sit amet consectetur" }.joined(separator: "\n")

    func testReplacingDocumentWithoutFoldSurvivesLayout() {
        let harness = EditorLayoutHarness()
        harness.textView.string = firstDocument
        harness.layOut()
        // Exactly as updateNSView's content-replaced branch does: assign string,
        // then lay out again.
        harness.textView.string = secondDocument
        harness.layOut()
        XCTAssertEqual(harness.textView.string, secondDocument)
        XCTAssertGreaterThan(harness.layoutManager.numberOfGlyphs, 0)
    }

    func testReplacingDocumentWithFoldInstalledSurvivesLayout() {
        let harness = EditorLayoutHarness()
        harness.textView.string = firstDocument
        harness.layOut()
        // Install a fold before the swap — the second case the plan requires.
        let foldRange = NSRange(location: 0, length: 20)
        harness.layoutManager.setFoldedRanges([foldRange])
        harness.layOut()
        harness.textView.string = secondDocument
        harness.layOut()
        XCTAssertEqual(harness.textView.string, secondDocument)
        XCTAssertGreaterThan(harness.layoutManager.numberOfGlyphs, 0)
    }

    func testFoldingTypesetterSupportsObjCInit() {
        // Diagnosis from the plan: a Swift NSATSTypesetter subclass with only
        // a custom designated initializer traps when allocated through
        // Objective-C `init` — TextKit does exactly that during re-entrant
        // layout. Before the fix this traps with "Use of unimplemented
        // initializer 'init()'" — the EXC_BREAKPOINT in the report.
        let cls: AnyClass = FoldingTypesetter.self
        guard let nsCls = cls as? NSObject.Type else {
            XCTFail("FoldingTypesetter is not an NSObject subclass")
            return
        }
        let instance = nsCls.init()
        XCTAssertTrue(instance is FoldingTypesetter)
        // And it must answer control characters without crashing when it has no
        // manager (the second instance TextKit creates has no folded set).
        guard let typesetter = instance as? FoldingTypesetter else {
            XCTFail("instance is not a FoldingTypesetter")
            return
        }
        _ = typesetter.actionForControlCharacter(at: 0)
    }

    // MARK: - Hiding measurement

    func testFoldHidesTextAndCollapsesLines() {
        let text = "header {\n    body1\n    body2\n}\nfooter"
        let harness = EditorLayoutHarness()
        harness.textView.string = text
        harness.layOut()
        let baselineFragments = fragmentCount(harness.layoutManager)
        XCTAssertGreaterThan(baselineFragments, 0)

        // Fold the bracket block: from end of "header {" (offset 8) through
        // "\n    body1\n    body2\n" (3 separators) — the shape
        // FoldRegionScanner and the LSP provider produce for this text:
        // hidden "\n    body1\n    body2\n" (the closer "}" stays visible and
        // joins the header's row).
        let hidden = NSRange(location: 8, length: 21)
        let hiddenText = (text as NSString).substring(with: hidden)
        let hiddenSeparators = hiddenText.filter { $0 == "\n" }.count
        XCTAssertEqual(hiddenSeparators, 3, "hidden range must contain 3 separators for this fixture")

        harness.layoutManager.setFoldedRanges([hidden])
        harness.layOut()

        // (a) Every hidden character carries GlyphProperty.null.
        for offset in hidden.location..<(hidden.location + hidden.length) {
            let glyph = harness.layoutManager.glyphIndexForCharacter(at: offset)
            let prop = harness.layoutManager.propertyForGlyph(at: glyph)
            XCTAssertTrue(prop.contains(.null), "offset \(offset) should be hidden (null glyph)")
        }
        // Visible characters before and after the hidden run are not null.
        for offset in [0, 1, 2, text.utf16.count - 1] {
            let glyph = harness.layoutManager.glyphIndexForCharacter(at: offset)
            let prop = harness.layoutManager.propertyForGlyph(at: glyph)
            XCTAssertFalse(prop.contains(.null), "offset \(offset) should be visible")
        }

        // (b) Header line and the block's last line share one line fragment.
        // Header starts at offset 0, closer "}" at offset 29 in this fixture.
        let headerGlyph = harness.layoutManager.glyphIndexForCharacter(at: 0)
        let closerOffset = (text as NSString).range(of: "}").location
        let closerGlyph = harness.layoutManager.glyphIndexForCharacter(at: closerOffset)
        let headerFragment = harness.layoutManager.lineFragmentRect(forGlyphAt: headerGlyph, effectiveRange: nil)
        let closerFragment = harness.layoutManager.lineFragmentRect(forGlyphAt: closerGlyph, effectiveRange: nil)
        XCTAssertEqual(headerFragment.minY, closerFragment.minY, "header and closer should be on one visual line")
        XCTAssertEqual(headerFragment.height, closerFragment.height)

        // (c) Document's line fragment count dropped by exactly number of hidden separators.
        let foldedFragments = fragmentCount(harness.layoutManager)
        XCTAssertEqual(foldedFragments, baselineFragments - hiddenSeparators, "fragments should drop by hidden separator count")

        // (d) Unfolding restores fragment count.
        harness.layoutManager.setFoldedRanges([])
        harness.layOut()
        let restoredFragments = fragmentCount(harness.layoutManager)
        XCTAssertEqual(restoredFragments, baselineFragments, "unfolding should restore fragment count")
        // And hidden chars are no longer null.
        for offset in hidden.location..<(hidden.location + hidden.length) {
            let glyph = harness.layoutManager.glyphIndexForCharacter(at: offset)
            let prop = harness.layoutManager.propertyForGlyph(at: glyph)
            XCTAssertFalse(prop.contains(.null), "offset \(offset) should be visible after unfold")
        }
    }

    func testSecondTypesetterInstanceSeesFoldAfterDocumentSwap() {
        let harness = EditorLayoutHarness()
        harness.textView.string = firstDocument
        harness.layOut()
        let foldRange = NSRange(location: 0, length: 120)
        harness.layoutManager.setFoldedRanges([foldRange])
        harness.layOut()
        // Verify it is hidden before the swap.
        assertHidden(harness, range: foldRange, shouldBeHidden: true)

        // Swap document as updateNSView's content-replaced branch does.
        harness.textView.string = secondDocument
        harness.layOut()

        // The second typesetter instance TextKit allocated during the re-entrant
        // pass must still see the set — the case the fix exists for.
        assertHidden(harness, range: foldRange, shouldBeHidden: true)
        XCTAssertEqual(harness.textView.string, secondDocument)
    }

    func testPlaceholderRect() {
        let text = "header {\n    body1\n    body2\n}\nfooter"
        let hidden = NSRange(location: 8, length: 21)
        let harness = EditorLayoutHarness()
        harness.textView.string = text
        harness.layOut()
        harness.layoutManager.setFoldedRanges([hidden])
        harness.layOut()

        // Answers a rect on the header line's row for the folded range's start.
        guard let rect = harness.layoutManager.placeholderRect(forFoldedRangeAt: hidden.location) else {
            XCTFail("placeholder rect should exist for folded range start")
            return
        }
        XCTAssertGreaterThan(rect.width, 0)
        XCTAssertGreaterThan(rect.height, 0)
        let headerGlyph = harness.layoutManager.glyphIndexForCharacter(at: 0)
        let headerFragment = harness.layoutManager.lineFragmentRect(forGlyphAt: headerGlyph, effectiveRange: nil)
        XCTAssertEqual(rect.minY, headerFragment.minY + ((headerFragment.height - rect.height) / 2).rounded(), accuracy: 0.5)
        // Rect's x is at end of header content (where first hidden glyph was laid out).
        XCTAssertGreaterThan(rect.minX, headerFragment.minX)

        // Nil for offset outside storage.
        XCTAssertNil(harness.layoutManager.placeholderRect(forFoldedRangeAt: -1))
        XCTAssertNil(harness.layoutManager.placeholderRect(forFoldedRangeAt: harness.layoutManager.textStorage?.length ?? 9999))
        XCTAssertNil(harness.layoutManager.placeholderRect(forFoldedRangeAt: (harness.layoutManager.textStorage?.length ?? 0) + 10))
    }

    // MARK: - Helpers

    private func fragmentCount(_ manager: NSLayoutManager) -> Int {
        guard let container = manager.textContainers.first else { return 0 }
        var count = 0
        let glyphRange = NSRange(location: 0, length: manager.numberOfGlyphs)
        manager.enumerateLineFragments(forGlyphRange: glyphRange) { _, _, _, _, _ in
            count += 1
        }
        // Fallback for empty document: enumerateLineFragments may not call block.
        if count == 0, manager.numberOfGlyphs > 0 {
            // Ensure layout has at least one fragment for non-empty text.
            let glyph = 0
            _ = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            count = 1
        }
        _ = container
        return count
    }

    private func assertHidden(_ harness: EditorLayoutHarness, range: NSRange, shouldBeHidden: Bool) {
        let length = harness.textStorage.length
        let clamped = NSIntersectionRange(range, NSRange(location: 0, length: length))
        guard clamped.length > 0 else {
            XCTFail("clamped hidden range empty (storage \(length), range \(range))")
            return
        }
        for offset in clamped.location..<(clamped.location + clamped.length) {
            let glyph = harness.layoutManager.glyphIndexForCharacter(at: offset)
            let prop = harness.layoutManager.propertyForGlyph(at: glyph)
            if shouldBeHidden {
                XCTAssertTrue(prop.contains(.null), "offset \(offset) should be hidden")
            } else {
                XCTAssertFalse(prop.contains(.null), "offset \(offset) should be visible")
            }
        }
    }
}
#endif
