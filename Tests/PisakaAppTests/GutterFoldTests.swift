#if os(macOS)
import AppKit
import XCTest
@testable import Pisaka
@testable import PisakaCore

@MainActor
final class GutterFoldTests: XCTestCase {
    // MARK: - Gutter row seam

    func testGutterRowsSkipCollapsedRunAndKeepBufferNumbering() {
        // 30 lines, header line 12 (index 11) hides 13...26, next visible is 27.
        let lines = (1...30).map { "line \($0)" }
        let text = lines.joined(separator: "\n")
        let content = text as NSString
        let lineStarts = LineStartIndex.offsets(in: content)
        // Build hidden range for block 12 -> 26: from end of line 12 content to end of line 26 content.
        let headerRange = content.lineRange(for: NSRange(location: lineStarts[11], length: 0))
        let lastHiddenRange = content.lineRange(for: NSRange(location: lineStarts[25], length: 0))
        let hiddenLoc = NSMaxRange(headerRange) - 1
        let hiddenEnd = NSMaxRange(lastHiddenRange) - 1
        let hidden = NSRange(location: hiddenLoc, length: hiddenEnd - hiddenLoc)
        // headerLine 11 (line 12) per FoldRegion contract.
        guard let region = FoldRegion(hiddenRange: hidden, headerLine: 11) else {
            XCTFail("region not representable")
            return
        }
        let state = FoldState(regions: [region])

        let harness = makeRulerHarness(text: text)
        harness.ruler.setFoldRegions([region], folded: state)

        let fullCharRange = NSRange(location: 0, length: content.length)
        let rows = harness.ruler.gutterRows(forCharRange: fullCharRange)
        let numbers = rows.map(\.lineNumber)
        // Should skip 13...26, so 12 is followed by 27.
        XCTAssertTrue(numbers.contains(12), "12 should be visible")
        XCTAssertTrue(numbers.contains(27), "27 should be visible after fold")
        XCTAssertFalse(numbers.contains(13), "13 should be hidden")
        XCTAssertFalse(numbers.contains(26), "26 should be hidden")
        // Check ordering: 12 then 27 consecutively.
        if let idx12 = numbers.firstIndex(of: 12), let idx27 = numbers.firstIndex(of: 27) {
            XCTAssertEqual(idx27, idx12 + 1, "12 then 27 in one step")
        } else {
            XCTFail("numbers missing 12 or 27: \(numbers)")
        }
        // Count should be 30 - 14 = 16 visible lines (1...12, 27...30) but our seam
        // skips in one step so each hidden line not counted individually.
        XCTAssertEqual(rows.count, 16)
        // Line ranges should still be buffer's: row for 27 starts at lineStarts[26].
        if let row27 = rows.first(where: { $0.lineNumber == 27 }) {
            XCTAssertEqual(row27.lineRange.location, lineStarts[26])
        } else {
            XCTFail("missing row 27")
        }
    }

    func testGutterRowsWithNothingFoldedReportsEveryLine() {
        let lines = (1...5).map { "line \($0)" }
        let text = lines.joined(separator: "\n")
        let content = text as NSString
        let harness = makeRulerHarness(text: text)
        // No fold installed.
        let fullCharRange = NSRange(location: 0, length: content.length)
        let rows = harness.ruler.gutterRows(forCharRange: fullCharRange)
        XCTAssertEqual(rows.count, 5)
        XCTAssertEqual(rows.map(\.lineNumber), [1, 2, 3, 4, 5])
        // Each lineRange should match NSString.lineRange.
        for (index, row) in rows.enumerated() {
            let expected = content.lineRange(for: NSRange(location: row.lineRange.location, length: 0))
            XCTAssertEqual(row.lineRange, expected, "row \(index) range mismatch")
        }
    }

    func testGutterRowsForSubrangeRespectsFold() {
        // Visible char range in the middle should still skip folded run.
        let lines = (1...30).map { "line \($0)" }
        let text = lines.joined(separator: "\n")
        let content = text as NSString
        let lineStarts = LineStartIndex.offsets(in: content)
        let headerRange = content.lineRange(for: NSRange(location: lineStarts[11], length: 0))
        let lastHiddenRange = content.lineRange(for: NSRange(location: lineStarts[25], length: 0))
        let hiddenLoc = NSMaxRange(headerRange) - 1
        let hiddenEnd = NSMaxRange(lastHiddenRange) - 1
        let hidden = NSRange(location: hiddenLoc, length: hiddenEnd - hiddenLoc)
        guard let region = FoldRegion(hiddenRange: hidden, headerLine: 11) else {
            XCTFail("region")
            return
        }
        let state = FoldState(regions: [region])
        let harness = makeRulerHarness(text: text)
        harness.ruler.setFoldRegions([region], folded: state)

        // Char range covering lines 10...29 (indexes 9...28)
        let start = lineStarts[9]
        let end = lineStarts[28] + (content.lineRange(for: NSRange(location: lineStarts[28], length: 0)).length)
        let charRange = NSRange(location: start, length: end - start)
        let rows = harness.ruler.gutterRows(forCharRange: charRange)
        let numbers = rows.map(\.lineNumber)
        // Should contain 10,11,12,27,28,29 and not 13...26.
        XCTAssertTrue(numbers.contains(10))
        XCTAssertTrue(numbers.contains(12))
        XCTAssertTrue(numbers.contains(27))
        XCTAssertFalse(numbers.contains(15))
        if let idx12 = numbers.firstIndex(of: 12), let idx27 = numbers.firstIndex(of: 27) {
            XCTAssertEqual(idx27, idx12 + 1)
        }
    }

    // MARK: - Bounded invalidation seam

    func testBoundedInvalidationOnlyCoversChangedRanges() {
        let lines = (1...100).map { "line \($0) — filler text to make document long enough" }
        let text = lines.joined(separator: "\n")
        let content = text as NSString
        let lineStarts = LineStartIndex.offsets(in: content)
        // Block near the end: hide lines 90...95 (header 89).
        let headerLine = 89 - 1 // zero-based: line 89 is index 88
        let headerRange = content.lineRange(for: NSRange(location: lineStarts[headerLine], length: 0))
        let lastHiddenRange = content.lineRange(for: NSRange(location: lineStarts[94], length: 0)) // line 95 is index 94
        let hiddenLoc = NSMaxRange(headerRange) - 1
        let hiddenEnd = NSMaxRange(lastHiddenRange) - 1
        let hidden = NSRange(location: hiddenLoc, length: hiddenEnd - hiddenLoc)
        guard let region = FoldRegion(hiddenRange: hidden, headerLine: headerLine) else {
            XCTFail("region")
            return
        }
        let hiddenRanges = [hidden]
        let harness = EditorLayoutHarness()
        harness.textView.string = text
        harness.layOut()
        XCTAssertNil(harness.layoutManager.lastFoldInvalidation, "no invalidation yet")
        harness.layoutManager.setFoldedRanges(hiddenRanges)
        harness.layOut()
        guard let invalid = harness.layoutManager.lastFoldInvalidation else {
            XCTFail("should have invalidated")
            return
        }
        // Invalidated range is the symmetric difference (old empty vs new) => hidden.
        XCTAssertEqual(invalid.location, hidden.location)
        XCTAssertEqual(invalid.length, hidden.length)
        // Leaves the range above it untouched: invalid does not start at 0.
        XCTAssertGreaterThan(invalid.location, 0)
        // And does not extend to the start of document.
        XCTAssertFalse(NSLocationInRange(0, invalid))
        // Prefix before hidden should be outside invalid.
        let prefixEnd = hidden.location
        if prefixEnd > 0 {
            let prefixRange = NSRange(location: 0, length: prefixEnd)
            XCTAssertEqual(NSIntersectionRange(prefixRange, invalid).length, 0, "prefix should be untouched")
        }
    }

    func testUnchangedSetIsNoOpInvalidatesNothing() {
        let lines = (1...50).map { "line \($0)" }
        let text = lines.joined(separator: "\n")
        let content = text as NSString
        let lineStarts = LineStartIndex.offsets(in: content)
        let headerR = content.lineRange(for: NSRange(location: lineStarts[5], length: 0))
        let lastR = content.lineRange(for: NSRange(location: lineStarts[10], length: 0))
        let hidden = NSRange(location: NSMaxRange(headerR) - 1, length: (NSMaxRange(lastR) - 1) - (NSMaxRange(headerR) - 1))
        let harness = EditorLayoutHarness()
        harness.textView.string = text
        harness.layOut()
        harness.layoutManager.setFoldedRanges([hidden])
        harness.layOut()
        let firstInvalid = harness.layoutManager.lastFoldInvalidation
        XCTAssertNotNil(firstInvalid)
        // Second call with same set is a no-op.
        harness.layoutManager.setFoldedRanges([hidden])
        XCTAssertNil(harness.layoutManager.lastFoldInvalidation, "unchanged set should invalidate nothing")
        // Also empty to empty is no-op.
        harness.layoutManager.setFoldedRanges([])
        harness.layOut()
        let clearedInvalid = harness.layoutManager.lastFoldInvalidation
        // Clearing to empty invalidates the old range again.
        XCTAssertNotNil(clearedInvalid)
        harness.layoutManager.setFoldedRanges([])
        XCTAssertNil(harness.layoutManager.lastFoldInvalidation, "empty to empty is no-op")
    }

    func testSymmetricDifferenceMiddleBlock() {
        let lines = (1...50).map { "line \($0)" }
        let text = lines.joined(separator: "\n")
        let content = text as NSString
        let lineStarts = LineStartIndex.offsets(in: content)
        func hiddenFor(header: Int, lastHidden: Int) -> NSRange {
            let hr = content.lineRange(for: NSRange(location: lineStarts[header], length: 0))
            let lr = content.lineRange(for: NSRange(location: lineStarts[lastHidden], length: 0))
            return NSRange(location: NSMaxRange(hr) - 1, length: (NSMaxRange(lr) - 1) - (NSMaxRange(hr) - 1))
        }
        let a = hiddenFor(header: 5, lastHidden: 10)
        let b = hiddenFor(header: 20, lastHidden: 25)
        let harness = EditorLayoutHarness()
        harness.textView.string = text
        harness.layOut()
        harness.layoutManager.setFoldedRanges([a])
        harness.layOut()
        let first = harness.layoutManager.lastFoldInvalidation
        XCTAssertNotNil(first)
        // Switch from a to b: changedBounds is union of both => from a.location to b's end.
        harness.layoutManager.setFoldedRanges([b])
        guard let second = harness.layoutManager.lastFoldInvalidation else {
            XCTFail("should invalidate on switch")
            return
        }
        // Union of symmetric difference: both ranges are disjoint, so bounding is from min location to max end.
        let expectedLocation = min(a.location, b.location)
        let expectedEnd = max(NSMaxRange(a), NSMaxRange(b))
        XCTAssertEqual(second.location, expectedLocation)
        XCTAssertEqual(NSMaxRange(second), expectedEnd)
    }

    // MARK: - Helpers

    private struct RulerHarness {
        let scrollView: NSScrollView
        let textView: NSTextView
        let ruler: LineNumberRulerView
    }

    private func makeRulerHarness(text: String) -> RulerHarness {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 800))
        let tv = NSTextView(usingTextLayoutManager: false)
        let manager = BracketOverlayLayoutManager()
        tv.textContainer?.replaceLayoutManager(manager)
        tv.layoutManager?.allowsNonContiguousLayout = true
        scroll.documentView = tv
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = true
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.size = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.string = text
        // Ensure ruler has read the text — didProcessEditingNotification is synchronous on string assignment
        // but force layout so lineStartOffsets is consistent.
        manager.ensureLayout(for: tv.textContainer!)
        let ruler = LineNumberRulerView(scrollView: scroll, textView: tv)
        // Nudge the ruler to recompute line starts from current text (init already did,
        // but string assignment after init needs the edit notification; it already fired).
        // Accessing gutterRows will use the updated lineStartOffsets.
        return RulerHarness(scrollView: scroll, textView: tv, ruler: ruler)
    }
}
#endif
