import XCTest
@testable import PisakaCore

/// `ChangeHunk.hunks(from:)` reads hunks off `LineDiff`'s rows without
/// re-diffing; `lineMarkers(for:lineCount:)` projects them onto ruler lines; and
/// `ChromeColorRole.changeMarkerRole(for:)` colours the three kinds.
final class ChangeHunkTests: XCTestCase {

    private func hunks(old: String, new: String) -> [ChangeHunk] {
        ChangeHunk.hunks(from: LineDiff.rows(old: old, new: new))
    }

    private func rulerCount(_ text: String) -> Int {
        LineStartIndex.offsets(in: text as NSString).count
    }

    // MARK: - Kinds

    func testIdenticalTextsHaveNoHunks() {
        XCTAssertEqual(hunks(old: "a\nb\n", new: "a\nb\n"), [])
        XCTAssertEqual(hunks(old: "", new: ""), [])
    }

    func testAddedLines() {
        XCTAssertEqual(
            hunks(old: "a\nc\n", new: "a\nb1\nb2\nc\n"),
            [ChangeHunk(kind: .added, newLines: 1..<3, oldLines: 1..<1)]
        )
    }

    func testModifiedLine() {
        XCTAssertEqual(
            hunks(old: "a\nb\nc\n", new: "a\nB\nc\n"),
            [ChangeHunk(kind: .modified, newLines: 1..<2, oldLines: 1..<2)]
        )
    }

    func testDeletedMidFileIsAnchoredAfterThePrecedingLine() {
        let result = hunks(old: "a\nb\nc\n", new: "a\nc\n")
        XCTAssertEqual(result, [ChangeHunk(kind: .deleted, newLines: 1..<1, oldLines: 1..<2)])
        XCTAssertEqual(result.first?.anchor, 0)
    }

    func testDeletedBeforeLineOneAnchorsAtMinusOne() {
        let result = hunks(old: "x\ny\na\n", new: "a\n")
        XCTAssertEqual(result, [ChangeHunk(kind: .deleted, newLines: 0..<0, oldLines: 0..<2)])
        XCTAssertEqual(result.first?.anchor, -1)
    }

    func testDeletedAfterTheLastLineAnchorsOnIt() {
        let result = hunks(old: "a\nb\nc\n", new: "a\n")
        XCTAssertEqual(result, [ChangeHunk(kind: .deleted, newLines: 1..<1, oldLines: 1..<3)])
        XCTAssertEqual(result.first?.anchor, 0)
    }

    func testAnchorIsTheLineAboveForEveryKind() {
        XCTAssertEqual(ChangeHunk(kind: .added, newLines: 4..<6, oldLines: 3..<3).anchor, 3)
        XCTAssertEqual(ChangeHunk(kind: .modified, newLines: 0..<1, oldLines: 0..<1).anchor, -1)
    }

    /// Modified, removed and added rows of one run merge into one hunk.
    func testAdjacentRowsMergeIntoOneModifiedHunkWithUnequalSides() {
        let rows = LineDiff.rows(old: "a\nb\nc\nd\n", new: "a\nB\nd\n")
        XCTAssertEqual(rows.map(\.kind), [.unchanged, .modified, .removed, .unchanged])
        XCTAssertEqual(
            ChangeHunk.hunks(from: rows),
            [ChangeHunk(kind: .modified, newLines: 1..<2, oldLines: 1..<3)]
        )
        XCTAssertEqual(
            hunks(old: "a\nb\nd\n", new: "a\nB1\nB2\nB3\nd\n"),
            [ChangeHunk(kind: .modified, newLines: 1..<4, oldLines: 1..<2)]
        )
    }

    func testSeparateRunsStaySeparateAndOrdered() {
        XCTAssertEqual(
            hunks(old: "a\nb\nc\nd\ne\n", new: "A\nb\nd\ne\nf\n"),
            [
                ChangeHunk(kind: .modified, newLines: 0..<1, oldLines: 0..<1),
                ChangeHunk(kind: .deleted, newLines: 2..<2, oldLines: 2..<3),
                ChangeHunk(kind: .added, newLines: 4..<5, oldLines: 5..<5),
            ]
        )
    }

    func testEmptyBufferAgainstNonEmptyHeadIsOneDeletionBeforeLineOne() {
        XCTAssertEqual(
            hunks(old: "a\nb\n", new: ""),
            [ChangeHunk(kind: .deleted, newLines: 0..<0, oldLines: 0..<2)]
        )
        XCTAssertEqual(
            hunks(old: "", new: "a\n"),
            [ChangeHunk(kind: .added, newLines: 0..<1, oldLines: 0..<0)]
        )
    }

    // MARK: - Line markers

    func testMarkersCarryStripsAndWedgesOnTheRightLines() {
        let new = "A\nb\nd\ne\nf\n"
        let markers = ChangeHunk.lineMarkers(
            for: hunks(old: "a\nb\nc\nd\ne\n", new: new),
            lineCount: rulerCount(new)
        )
        XCTAssertEqual(markers, [
            ChangeLineMarker(strip: .modified),
            ChangeLineMarker(deletedBelow: true),
            ChangeLineMarker(),
            ChangeLineMarker(),
            ChangeLineMarker(strip: .added),
            ChangeLineMarker(), // the trailing separator's empty ruler line
        ])
    }

    func testDeletionBeforeLineOneMarksDeletedAbove() {
        let new = "a"
        let markers = ChangeHunk.lineMarkers(for: hunks(old: "x\na", new: new), lineCount: rulerCount(new))
        XCTAssertEqual(markers, [ChangeLineMarker(deletedAbove: true)])
    }

    func testDeletionAfterTheLastLineMarksItsDeletedBelow() {
        let new = "a\n"
        let markers = ChangeHunk.lineMarkers(for: hunks(old: "a\nb\n", new: new), lineCount: rulerCount(new))
        XCTAssertEqual(markers, [ChangeLineMarker(deletedBelow: true), ChangeLineMarker()])
    }

    func testLineOneMayCarryBothWedges() {
        let new = "b\nd\n"
        let markers = ChangeHunk.lineMarkers(for: hunks(old: "a\nb\nc\nd\n", new: new), lineCount: rulerCount(new))
        XCTAssertEqual(markers[0], ChangeLineMarker(deletedAbove: true, deletedBelow: true))
    }

    func testEmptyBufferMarksIndexZeroDeletedAbove() {
        let markers = ChangeHunk.lineMarkers(for: hunks(old: "a\nb\n", new: ""), lineCount: rulerCount(""))
        XCTAssertEqual(markers, [ChangeLineMarker(deletedAbove: true)])
    }

    /// The array is indexed by ruler line, so its length is the line-start count
    /// whatever the buffer's ending — including a trailing separator, which adds
    /// a ruler line but no diff line.
    func testMarkerCountEqualsLineStartCount() {
        let cases: [(old: String, new: String)] = [
            ("a\nb", "a\nB"),
            ("a\nb\n", "a\nB\n"),
            ("a\r\nb\r\n", "a\r\nb\r\nc\r\n"),
            ("a\u{2028}b", "a\u{2029}b\u{85}c\u{85}"),
            ("x\n", ""),
            ("", "\n\n"),
        ]
        for (old, new) in cases {
            let markers = ChangeHunk.lineMarkers(for: hunks(old: old, new: new), lineCount: rulerCount(new))
            XCTAssertEqual(markers.count, rulerCount(new), "\(old.debugDescription) → \(new.debugDescription)")
        }
    }

    func testOutOfRangeLinesAreDroppedNotTrapped() {
        let hunks = [
            ChangeHunk(kind: .added, newLines: 1..<5, oldLines: 0..<0),
            ChangeHunk(kind: .deleted, newLines: 9..<9, oldLines: 0..<1),
        ]
        XCTAssertEqual(
            ChangeHunk.lineMarkers(for: hunks, lineCount: 2),
            [ChangeLineMarker(), ChangeLineMarker(strip: .added)]
        )
        XCTAssertEqual(ChangeHunk.lineMarkers(for: hunks, lineCount: 0), [])
        let beforeLineOne = [ChangeHunk(kind: .deleted, newLines: 0..<0, oldLines: 0..<1)]
        XCTAssertEqual(ChangeHunk.lineMarkers(for: beforeLineOne, lineCount: 0), [])
    }

    func testMarkerIsEmpty() {
        XCTAssertTrue(ChangeLineMarker().isEmpty)
        XCTAssertFalse(ChangeLineMarker(strip: .added).isEmpty)
        XCTAssertFalse(ChangeLineMarker(deletedAbove: true).isEmpty)
        XCTAssertFalse(ChangeLineMarker(deletedBelow: true).isEmpty)
    }

    // MARK: - Role

    func testEveryKindHasItsRole() {
        let expected: [ChangeMarkerKind: ChromeColorRole] = [
            .added: .statusGreen,
            .modified: .statusYellow,
            .deleted: .statusRed,
        ]
        XCTAssertEqual(Set(expected.keys), Set(ChangeMarkerKind.allCases))
        for kind in ChangeMarkerKind.allCases {
            XCTAssertEqual(ChromeColorRole.changeMarkerRole(for: kind), expected[kind], "\(kind)")
        }
    }

    // MARK: - headLines(in:)

    func testHeadLinesAreTheOldSideWithSeparatorsStripped() {
        let base = "a\r\nb\u{2028}c\nd"
        let hunk = ChangeHunk(kind: .modified, newLines: 0..<1, oldLines: 1..<4)
        XCTAssertEqual(hunk.headLines(in: base), ["b", "c", "d"])
    }

    func testHeadLinesOfAnAddedHunkAreEmpty() {
        let hunk = ChangeHunk(kind: .added, newLines: 0..<2, oldLines: 1..<1)
        XCTAssertEqual(hunk.headLines(in: "a\nb\n"), [])
        // Past the base's end it is still an added hunk: empty, nothing omitted.
        let pastEnd = ChangeHunk(kind: .added, newLines: 9..<10, oldLines: 9..<9)
        let cut = pastEnd.headLines(in: "a\nb\n", limit: ChangeHunk.popoverLineLimit)
        XCTAssertEqual(cut.lines, [])
        XCTAssertEqual(cut.omitted, 0)
    }

    func testHeadLinesOfAHunkThatDoesNotFitTheBaseAreEmpty() {
        let hunk = ChangeHunk(kind: .deleted, newLines: 2..<2, oldLines: 1..<5)
        XCTAssertEqual(hunk.headLines(in: "a\nb\n"), [])
    }

    func testHeadLinesUnderALimitKeepTheFirstLinesAndCountTheRest() {
        let base = (0..<10).map { "l\($0)" }.joined(separator: "\n") + "\n"
        let hunk = ChangeHunk(kind: .deleted, newLines: 0..<0, oldLines: 2..<9)
        let cut = hunk.headLines(in: base, limit: 3)
        XCTAssertEqual(cut.lines, ["l2", "l3", "l4"])
        XCTAssertEqual(cut.omitted, 4)
        let whole = hunk.headLines(in: base, limit: 7)
        XCTAssertEqual(whole.lines, hunk.headLines(in: base))
        XCTAssertEqual(whole.omitted, 0)
        XCTAssertEqual(hunk.headLines(in: base, limit: 0).omitted, 7)
        XCTAssertEqual(hunk.headLines(in: "a\n", limit: 3).omitted, 0, "a hunk off the base omits nothing")
    }

    func testHeadLinesAgreeWithTheWholeSplitForEverySpanAndSeparator() {
        let bases = ["", "a", "a\n", "\n\n", "a\r\nb\rc\u{0085}d\u{2028}e\u{2029}f", "x\r\n\r\ny\n", "only\u{2029}"]
        for base in bases {
            let lines = TerminatedLines.split(base).map(\.content)
            for lower in 0...lines.count {
                for upper in lower...lines.count {
                    let hunk = ChangeHunk(kind: .deleted, newLines: 0..<0, oldLines: lower..<upper)
                    for limit in [0, 1, 2, 100] {
                        let shown = min(limit, upper - lower)
                        let cut = hunk.headLines(in: base, limit: limit)
                        XCTAssertEqual(cut.lines, Array(lines[lower..<lower + shown]), "\(base.debugDescription) \(lower)..<\(upper) limit \(limit)")
                        XCTAssertEqual(cut.omitted, upper - lower - shown)
                    }
                }
            }
            let past = ChangeHunk(kind: .deleted, newLines: 0..<0, oldLines: 0..<(lines.count + 1))
            XCTAssertEqual(past.headLines(in: base, limit: 3).lines, [], "a hunk past the base's end fits nothing")
        }
    }
}
