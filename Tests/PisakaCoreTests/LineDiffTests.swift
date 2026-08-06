import XCTest
@testable import PisakaCore

final class LineDiffTests: XCTestCase {
    // MARK: - Helpers

    /// Asserts the filler/alignment invariant on every row:
    /// `added` → left is nil (right present); `removed` → right is nil (left
    /// present); `unchanged`/`modified` → both sides present. A `nil` side always
    /// pairs a real line on the other side, and 1-based line numbers never repeat
    /// or go backwards within a side.
    private func assertInvariants(_ rows: [DiffRow], file: StaticString = #filePath, line: UInt = #line) {
        var lastLeft = 0
        var lastRight = 0
        for row in rows {
            switch row.kind {
            case .added:
                XCTAssertNil(row.left, "added row must have no left line", file: file, line: line)
                XCTAssertNotNil(row.right, "added row must have a right line", file: file, line: line)
            case .removed:
                XCTAssertNotNil(row.left, "removed row must have a left line", file: file, line: line)
                XCTAssertNil(row.right, "removed row must have no right line", file: file, line: line)
            case .unchanged, .modified:
                XCTAssertNotNil(row.left, "\(row.kind) row must have a left line", file: file, line: line)
                XCTAssertNotNil(row.right, "\(row.kind) row must have a right line", file: file, line: line)
            }
            if let l = row.left {
                XCTAssertEqual(l.number, lastLeft + 1, "left line numbers must be 1-based and contiguous", file: file, line: line)
                lastLeft = l.number
            }
            if let r = row.right {
                XCTAssertEqual(r.number, lastRight + 1, "right line numbers must be 1-based and contiguous", file: file, line: line)
                lastRight = r.number
            }
        }
    }

    // MARK: - Identical / empty

    func testIdenticalFilesProduceNoChangedRows() {
        let text = "alpha\nbeta\ngamma"
        let rows = LineDiff.rows(old: text, new: text)
        assertInvariants(rows)
        XCTAssertEqual(rows.count, 3)
        XCTAssertTrue(rows.allSatisfy { $0.kind == .unchanged })
        XCTAssertEqual(rows.map { $0.left?.text }, ["alpha", "beta", "gamma"])
        XCTAssertEqual(rows.map { $0.right?.text }, ["alpha", "beta", "gamma"])
    }

    func testBothEmptyProducesNoRows() {
        XCTAssertEqual(LineDiff.rows(old: "", new: ""), [])
    }

    func testEmptyOldIsAllAdded() {
        let rows = LineDiff.rows(old: "", new: "one\ntwo\nthree")
        assertInvariants(rows)
        XCTAssertEqual(rows.count, 3)
        XCTAssertTrue(rows.allSatisfy { $0.kind == .added })
        XCTAssertEqual(rows.map { $0.right?.text }, ["one", "two", "three"])
        XCTAssertEqual(rows.map { $0.right?.number }, [1, 2, 3])
    }

    func testEmptyNewIsAllRemoved() {
        let rows = LineDiff.rows(old: "one\ntwo\nthree", new: "")
        assertInvariants(rows)
        XCTAssertEqual(rows.count, 3)
        XCTAssertTrue(rows.allSatisfy { $0.kind == .removed })
        XCTAssertEqual(rows.map { $0.left?.text }, ["one", "two", "three"])
        XCTAssertEqual(rows.map { $0.left?.number }, [1, 2, 3])
    }

    // MARK: - Single-kind hunks

    func testAddOnlyInMiddle() {
        let rows = LineDiff.rows(old: "a\nb", new: "a\nx\ny\nb")
        assertInvariants(rows)
        XCTAssertEqual(rows.map { $0.kind }, [.unchanged, .added, .added, .unchanged])
        XCTAssertEqual(rows.map { $0.right?.text }, ["a", "x", "y", "b"])
        // Old side: "a" then nothing for the inserts, then "b".
        XCTAssertEqual(rows.map { $0.left?.text }, ["a", nil, nil, "b"])
        XCTAssertEqual(rows.map { $0.left?.number }, [1, nil, nil, 2])
    }

    func testRemoveOnlyInMiddle() {
        let rows = LineDiff.rows(old: "a\nx\ny\nb", new: "a\nb")
        assertInvariants(rows)
        XCTAssertEqual(rows.map { $0.kind }, [.unchanged, .removed, .removed, .unchanged])
        XCTAssertEqual(rows.map { $0.left?.text }, ["a", "x", "y", "b"])
        XCTAssertEqual(rows.map { $0.right?.text }, ["a", nil, nil, "b"])
        XCTAssertEqual(rows.map { $0.right?.number }, [1, nil, nil, 2])
    }

    // MARK: - Modified

    func testModifiedLinePairsRemoveAndAdd() {
        let rows = LineDiff.rows(old: "a\nMID\nc", new: "a\nmid\nc")
        assertInvariants(rows)
        XCTAssertEqual(rows.map { $0.kind }, [.unchanged, .modified, .unchanged])
        let modified = rows[1]
        XCTAssertEqual(modified.left?.text, "MID")
        XCTAssertEqual(modified.right?.text, "mid")
        XCTAssertEqual(modified.left?.number, 2)
        XCTAssertEqual(modified.right?.number, 2)
    }

    func testHunkWithMoreRemovalsThanAdditions() {
        // Two old lines replaced by one new line: one modified row + one removed.
        let rows = LineDiff.rows(old: "a\nold1\nold2\nc", new: "a\nnew1\nc")
        assertInvariants(rows)
        XCTAssertEqual(rows.map { $0.kind }, [.unchanged, .modified, .removed, .unchanged])
        XCTAssertEqual(rows[1].left?.text, "old1")
        XCTAssertEqual(rows[1].right?.text, "new1")
        XCTAssertEqual(rows[2].left?.text, "old2")
        XCTAssertNil(rows[2].right)
    }

    func testHunkWithMoreAdditionsThanRemovals() {
        // One old line replaced by two new lines: one modified row + one added.
        let rows = LineDiff.rows(old: "a\nold1\nc", new: "a\nnew1\nnew2\nc")
        assertInvariants(rows)
        XCTAssertEqual(rows.map { $0.kind }, [.unchanged, .modified, .added, .unchanged])
        XCTAssertEqual(rows[1].left?.text, "old1")
        XCTAssertEqual(rows[1].right?.text, "new1")
        XCTAssertNil(rows[2].left)
        XCTAssertEqual(rows[2].right?.text, "new2")
    }

    // MARK: - Mixed

    func testMixedHunksKeepLineNumbersConsistent() {
        let old = "h1\nh2\nremoved\nshared\nold\nh3"
        let new = "h1\nh2\nshared\nnew\nadded\nh3"
        let rows = LineDiff.rows(old: old, new: new)
        assertInvariants(rows)
        // Reconstruct each side in order and confirm it matches the inputs.
        let leftText = rows.compactMap { $0.left?.text }
        let rightText = rows.compactMap { $0.right?.text }
        XCTAssertEqual(leftText, ["h1", "h2", "removed", "shared", "old", "h3"])
        XCTAssertEqual(rightText, ["h1", "h2", "shared", "new", "added", "h3"])
    }

    // MARK: - Separator semantics

    func testCRLFAndTrailingNewlineSplitLikeTheEditor() {
        // CRLF lines, with a trailing separator that should NOT add a phantom line.
        let rows = LineDiff.rows(old: "a\r\nb\r\n", new: "a\r\nB\r\n")
        assertInvariants(rows)
        XCTAssertEqual(rows.map { $0.kind }, [.unchanged, .modified])
        XCTAssertEqual(rows[0].left?.text, "a")
        XCTAssertEqual(rows[1].left?.text, "b")
        XCTAssertEqual(rows[1].right?.text, "B")
    }

    func testUnicodeSeparatorsSplitLikeTheEditor() {
        // Lone CR, U+2028 (line separator), and U+2029 (paragraph separator) must
        // split into the same logical lines as LF, so the diff stays aligned with
        // the gutter/minimap for files using those separators.
        for separator in ["\r", "\u{2028}", "\u{2029}"] {
            let old = "a\(separator)b\(separator)c"
            let new = "a\(separator)B\(separator)c"
            let rows = LineDiff.rows(old: old, new: new)
            assertInvariants(rows, line: UInt(#line))
            XCTAssertEqual(rows.map { $0.kind }, [.unchanged, .modified, .unchanged],
                           "separator \(separator.unicodeScalars.first!.value)")
            XCTAssertEqual(rows.map { $0.left?.text }, ["a", "b", "c"])
            XCTAssertEqual(rows.map { $0.right?.text }, ["a", "B", "c"])
        }
    }

    /// `splitLines` is the terminator-stripped projection of `TerminatedLines
    /// .split`, so a diff row index and a builder line index always name the same
    /// line. Stated here as well as in `TerminatedLinesTests` so a reader of the
    /// diff's own suite sees which splitter the row numbers come from.
    func testSplitLinesIsTheProjectionOfTerminatedLines() {
        for text in ["", "a", "a\nb", "a\r\nb\rc\u{2028}d\u{0085}e\u{2029}f", "\n\r\n\r"] {
            XCTAssertEqual(
                LineDiff.splitLines(text),
                TerminatedLines.split(text).map(\.content),
                "mismatch for \(String(reflecting: text))"
            )
        }
    }

    // MARK: - Large-file bounds (common prefix/suffix + matrix cap)

    func testEditInLargeFileIsLocalizedAfterPrefixSuffixTrim() {
        // A single changed line in an otherwise-identical large file still diffs
        // to exactly one modified row, with all surrounding lines unchanged — the
        // common prefix/suffix shortcut must not alter the result.
        let n = 5000
        var oldLines = (0..<n).map { "line \($0)" }
        var newLines = oldLines
        newLines[2500] = "line 2500 CHANGED"
        let rows = LineDiff.rows(old: oldLines.joined(separator: "\n"),
                                 new: newLines.joined(separator: "\n"))
        assertInvariants(rows)
        XCTAssertEqual(rows.count, n)
        let changed = rows.filter { $0.kind != .unchanged }
        XCTAssertEqual(changed.count, 1)
        XCTAssertEqual(changed.first?.kind, .modified)
        XCTAssertEqual(changed.first?.left?.number, 2501)
        XCTAssertEqual(changed.first?.left?.text, "line 2500")
        XCTAssertEqual(changed.first?.right?.text, "line 2500 CHANGED")
        oldLines.removeAll(); newLines.removeAll()
    }

    func testFullyDivergentLargeFilesFallBackToReplace() {
        // Two large files that differ on every line exceed the LCS matrix cap, so
        // the diff falls back to a plain replace (paired into modified rows)
        // instead of allocating a giant matrix. The result must still cover every
        // line on both sides and satisfy the alignment invariants.
        let n = 3000 // 3000 * 3000 = 9,000,000 cells > the 8,000,000 cap
        let old = (0..<n).map { "old \($0)" }.joined(separator: "\n")
        let new = (0..<n).map { "new \($0)" }.joined(separator: "\n")
        let rows = LineDiff.rows(old: old, new: new)
        assertInvariants(rows)
        XCTAssertEqual(rows.count, n)
        XCTAssertTrue(rows.allSatisfy { $0.kind == .modified })
        XCTAssertEqual(rows.first?.left?.text, "old 0")
        XCTAssertEqual(rows.first?.right?.text, "new 0")
        XCTAssertEqual(rows.last?.left?.text, "old \(n - 1)")
        XCTAssertEqual(rows.last?.right?.text, "new \(n - 1)")
    }
}
