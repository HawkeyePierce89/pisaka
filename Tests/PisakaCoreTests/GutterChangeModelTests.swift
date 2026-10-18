import XCTest
@testable import PisakaCore

/// `GutterChangeModel.compute(base:buffer:)` — the change column's answer, its
/// refusals (no base, a side over the cap) and `GutterChanges.hunk(atLine:)`.
final class GutterChangeModelTests: XCTestCase {

    private func rulerCount(_ text: String) -> Int {
        LineStartIndex.offsets(in: text as NSString).count
    }

    // MARK: - Empty answers

    func testNoBaseIsEmptyWithOneMarkerPerRulerLine() {
        let buffer = "a\nb\n"
        let changes = GutterChangeModel.compute(base: nil, buffer: buffer)
        XCTAssertEqual(changes.hunks, [])
        XCTAssertEqual(changes.markers.count, rulerCount(buffer))
        XCTAssertTrue(changes.markers.allSatisfy(\.isEmpty))
    }

    func testIdenticalFileHasNoHunks() {
        let text = "a\nb\nc\n"
        let changes = GutterChangeModel.compute(base: text, buffer: text)
        XCTAssertEqual(changes.hunks, [])
        XCTAssertEqual(changes.markers.count, rulerCount(text))
        XCTAssertTrue(changes.markers.allSatisfy(\.isEmpty))
    }

    // MARK: - Kinds

    func testTheThreeKindsTogether() {
        let base = "a\nb\nc\nd\ne\n"
        // b modified, a new line after c, e deleted.
        let buffer = "a\nB\nc\nnew\nd\n"
        let changes = GutterChangeModel.compute(base: base, buffer: buffer)
        XCTAssertEqual(changes.hunks, [
            ChangeHunk(kind: .modified, newLines: 1..<2, oldLines: 1..<2),
            ChangeHunk(kind: .added, newLines: 3..<4, oldLines: 3..<3),
            ChangeHunk(kind: .deleted, newLines: 5..<5, oldLines: 4..<5),
        ])
        XCTAssertEqual(changes.markers, [
            ChangeLineMarker(),
            ChangeLineMarker(strip: .modified),
            ChangeLineMarker(),
            ChangeLineMarker(strip: .added),
            ChangeLineMarker(deletedBelow: true),
            ChangeLineMarker(),
        ])
    }

    func testWhitespaceOnlyChangeIsModified() {
        let changes = GutterChangeModel.compute(base: "x\na b\n", buffer: "x\na  b\n")
        XCTAssertEqual(changes.hunks, [ChangeHunk(kind: .modified, newLines: 1..<2, oldLines: 1..<2)])
        XCTAssertEqual(changes.markers[1].strip, .modified)
    }

    // MARK: - Separators

    func testCRLF() {
        let buffer = "a\r\nX\r\nc\r\n"
        let changes = GutterChangeModel.compute(base: "a\r\nb\r\nc\r\n", buffer: buffer)
        XCTAssertEqual(changes.hunks, [ChangeHunk(kind: .modified, newLines: 1..<2, oldLines: 1..<2)])
        XCTAssertEqual(changes.markers.count, rulerCount(buffer))
        XCTAssertEqual(changes.markers.map(\.strip), [nil, .modified, nil, nil])
    }

    func testUnicodeSeparators() {
        for sep in ["\u{85}", "\u{2028}", "\u{2029}"] {
            let base = ["a", "b", "c"].joined(separator: sep)
            let buffer = ["a", "B", "c", "d"].joined(separator: sep)
            let changes = GutterChangeModel.compute(base: base, buffer: buffer)
            XCTAssertEqual(changes.hunks, [
                ChangeHunk(kind: .modified, newLines: 1..<2, oldLines: 1..<2),
                ChangeHunk(kind: .added, newLines: 3..<4, oldLines: 3..<3),
            ], "separator U+\(String(sep.unicodeScalars.first!.value, radix: 16))")
            XCTAssertEqual(changes.markers.count, rulerCount(buffer))
            XCTAssertEqual(changes.markers.map(\.strip), [nil, .modified, nil, .added])
        }
    }

    // MARK: - Size cap

    func testCapEqualsTheInlineDiffCap() {
        XCTAssertEqual(GutterChangeModel.maxSideBytes, 1 << 20)
        XCTAssertEqual(GutterChangeModel.maxSideBytes, LocalChangesInlineDiff.maxSideBytes)
    }

    func testCapOnEachSide() {
        let cap = GutterChangeModel.maxSideBytes
        let atCap = String(repeating: "a", count: cap - 2) + "\nx" // exactly `cap` bytes
        let overCap = atCap + "y"
        let small = "z\n"
        XCTAssertEqual(atCap.utf8.count, cap)

        // Base at the cap diffs; one byte over is empty.
        XCTAssertFalse(GutterChangeModel.compute(base: atCap, buffer: small).hunks.isEmpty)
        let overBase = GutterChangeModel.compute(base: overCap, buffer: small)
        XCTAssertEqual(overBase.hunks, [])
        XCTAssertEqual(overBase.markers.count, rulerCount(small))

        // Buffer at the cap diffs; one byte over is empty, markers still sized.
        XCTAssertFalse(GutterChangeModel.compute(base: small, buffer: atCap).hunks.isEmpty)
        let overBuffer = GutterChangeModel.compute(base: small, buffer: overCap)
        XCTAssertEqual(overBuffer.hunks, [])
        XCTAssertEqual(overBuffer.markers.count, rulerCount(overCap))
        XCTAssertTrue(overBuffer.markers.allSatisfy(\.isEmpty))
    }

    func testCapCountsUTF8BytesNotCharacters() {
        let cap = GutterChangeModel.maxSideBytes
        // Two-byte characters: half the cap in characters is already at it.
        let atCap = String(repeating: "é", count: cap / 2)
        XCTAssertEqual(atCap.utf8.count, cap)
        XCTAssertFalse(GutterChangeModel.compute(base: "x", buffer: atCap).hunks.isEmpty)
        XCTAssertEqual(GutterChangeModel.compute(base: "x", buffer: atCap + "é").hunks, [])
    }

    // MARK: - hunk(atLine:)

    func testHunkAtStripLines() {
        let changes = GutterChangeModel.compute(base: "a\nb\nc\n", buffer: "a\nB1\nB2\nB3\nc\n")
        let hunk = ChangeHunk(kind: .modified, newLines: 1..<4, oldLines: 1..<2)
        XCTAssertEqual(changes.hunks, [hunk])
        XCTAssertNil(changes.hunk(atLine: 0))
        for line in 1..<4 { XCTAssertEqual(changes.hunk(atLine: line), hunk) }
        XCTAssertNil(changes.hunk(atLine: 4))
        XCTAssertNil(changes.hunk(atLine: 99))
    }

    func testHunkAtDeletionAnchorLines() {
        // Mid-file deletion anchored after line index 0.
        let mid = GutterChangeModel.compute(base: "a\nb\nc\n", buffer: "a\nc\n")
        XCTAssertEqual(mid.hunk(atLine: 0), ChangeHunk(kind: .deleted, newLines: 1..<1, oldLines: 1..<2))
        XCTAssertNil(mid.hunk(atLine: 1))

        // Deletion after the last line anchors on the last real line.
        let end = GutterChangeModel.compute(base: "a\nb\nc\n", buffer: "a\nb\n")
        XCTAssertEqual(end.hunk(atLine: 1), ChangeHunk(kind: .deleted, newLines: 2..<2, oldLines: 2..<3))
        XCTAssertNil(end.hunk(atLine: 2))

        // Deletion before line 1 answers line 0.
        let top = GutterChangeModel.compute(base: "a\nb\nc\n", buffer: "b\nc\n")
        XCTAssertEqual(top.hunk(atLine: 0), ChangeHunk(kind: .deleted, newLines: 0..<0, oldLines: 0..<1))
        XCTAssertTrue(top.markers[0].deletedAbove)
    }

    func testLineOneCarryingBothWedgesAnswersTheUpperOne() {
        // HEAD's first and third lines are gone: one wedge above line 1, one below.
        let changes = GutterChangeModel.compute(base: "x\nb\ny\nc\n", buffer: "b\nc\n")
        let above = ChangeHunk(kind: .deleted, newLines: 0..<0, oldLines: 0..<1)
        let below = ChangeHunk(kind: .deleted, newLines: 1..<1, oldLines: 2..<3)
        XCTAssertEqual(changes.hunks, [above, below])
        XCTAssertEqual(changes.markers[0], ChangeLineMarker(deletedAbove: true, deletedBelow: true))
        XCTAssertEqual(changes.hunk(atLine: 0), above)
    }

    func testEmptyBufferAgainstNonEmptyHead() {
        let changes = GutterChangeModel.compute(base: "a\nb\n", buffer: "")
        XCTAssertEqual(changes.markers, [ChangeLineMarker(deletedAbove: true)])
        XCTAssertEqual(changes.hunk(atLine: 0), ChangeHunk(kind: .deleted, newLines: 0..<0, oldLines: 0..<2))
    }

    // MARK: - hunk(atMarkerLine:)

    func testHunkAtMarkerLineTellsLineOnesTwoWedgesApart() {
        // HEAD "x\na\ny\nb\n" → buffer "a\nb\n": a deletion before line 1 and one
        // anchored after it, both drawn on line 1.
        let changes = GutterChangeModel.compute(base: "x\na\ny\nb\n", buffer: "a\nb\n")
        XCTAssertEqual(changes.hunks.map(\.anchor), [-1, 0])
        XCTAssertEqual(changes.hunk(atMarkerLine: -1)?.oldLines, 0..<1)
        XCTAssertEqual(changes.hunk(atMarkerLine: 0)?.oldLines, 2..<3)
        // The lenient lookup answers the upper one for line 0.
        XCTAssertEqual(changes.hunk(atLine: 0)?.oldLines, 0..<1)
    }

    func testHunkAtMarkerLineForStripsAndUnmarkedLines() {
        let changes = GutterChangeModel.compute(base: "a\nb\nc\n", buffer: "a\nB\nc\nd\n")
        XCTAssertEqual(changes.hunk(atMarkerLine: 1)?.kind, .modified)
        XCTAssertEqual(changes.hunk(atMarkerLine: 3)?.kind, .added)
        XCTAssertNil(changes.hunk(atMarkerLine: 0))
        XCTAssertNil(changes.hunk(atMarkerLine: 2))
        XCTAssertNil(changes.hunk(atMarkerLine: -1))
    }
}
