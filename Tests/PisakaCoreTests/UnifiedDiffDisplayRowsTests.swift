import XCTest
@testable import PisakaCore

final class UnifiedDiffDisplayRowsTests: XCTestCase {

    private func rows(
        _ old: String, _ new: String, file: ChangedFile = ChangedFile(path: "a.txt", status: .modified)
    ) -> [UnifiedDiffDisplayRow] {
        let lines = CommitDiffUnits.unified(rows: LineDiff.rows(old: old, new: new))
        return UnifiedDiffDisplayRows.rows(for: file, lines: lines)
    }

    private func hunkHeaders(_ rows: [UnifiedDiffDisplayRow]) -> [String] {
        rows.compactMap { if case let .hunkHeader(text) = $0 { return text } else { return nil } }
    }

    private func fileHeaders(_ rows: [UnifiedDiffDisplayRow]) -> [String] {
        rows.compactMap { if case let .fileHeader(text) = $0 { return text } else { return nil } }
    }

    private func numbered(_ range: ClosedRange<Int>) -> String {
        range.map { "line \($0)\n" }.joined()
    }

    // MARK: - File headers

    func testAModifiedFileNamesItsPathOnBothSidesFirst() {
        let result = rows("a\n", "b\n")
        XCTAssertEqual(Array(result.prefix(2)), [.fileHeader("--- a/a.txt"), .fileHeader("+++ b/a.txt")])
    }

    func testAnAddedOrUntrackedFilesOldSideIsDevNull() {
        for status in [FileStatus.added, .untracked] {
            let result = rows("", "x\ny\n", file: ChangedFile(path: "new.txt", status: status))
            XCTAssertEqual(fileHeaders(result), ["--- /dev/null", "+++ b/new.txt"], "\(status)")
            XCTAssertEqual(hunkHeaders(result), ["@@ -0,0 +1,2 @@"], "\(status)")
        }
    }

    func testADeletedFilesNewSideIsDevNull() {
        let result = rows("x\ny\nz\n", "", file: ChangedFile(path: "gone.txt", status: .deleted))
        XCTAssertEqual(fileHeaders(result), ["--- a/gone.txt", "+++ /dev/null"])
        XCTAssertEqual(hunkHeaders(result), ["@@ -1,3 +0,0 @@"])
    }

    func testARenameNamesItsOldPathOnTheOldSide() {
        let file = ChangedFile(path: "new/name.txt", status: .renamed, oldPath: "old/name.txt")
        XCTAssertEqual(fileHeaders(rows("a\n", "b\n", file: file)), ["--- a/old/name.txt", "+++ b/new/name.txt"])
    }

    // MARK: - Hunk numbers

    func testAnAdditionInsideAFile() {
        // Line 6 added after line 5 of ten: three context lines each side.
        let old = numbered(1...10)
        let new = numbered(1...5) + "added\n" + numbered(6...10)
        let result = rows(old, new)
        XCTAssertEqual(hunkHeaders(result), ["@@ -3,6 +3,7 @@"])
        let lines = result.compactMap(\.line)
        XCTAssertEqual(lines.map(\.text), ["line 3", "line 4", "line 5", "added", "line 6", "line 7", "line 8"])
    }

    func testARemovalInsideAFile() {
        let old = numbered(1...10)
        let new = numbered(1...4) + numbered(6...10)
        XCTAssertEqual(hunkHeaders(rows(old, new)), ["@@ -2,7 +2,6 @@"])
    }

    func testAMixedChangeAtTheTopOfAFile() {
        let old = numbered(1...10)
        let new = "first\n" + numbered(2...10)
        let result = rows(old, new)
        XCTAssertEqual(hunkHeaders(result), ["@@ -1,4 +1,4 @@"])
        XCTAssertEqual(result.compactMap(\.line).map(\.kind), [.removed, .added, .context, .context, .context])
    }

    func testAPureAdditionAtTheTopCountsNoOldLineBeforeIt() {
        // An insertion before line 1: the old side has no changed line, but its
        // context lines start the old range at line 1.
        let old = numbered(1...5)
        let new = "top\n" + old
        XCTAssertEqual(hunkHeaders(rows(old, new)), ["@@ -1,3 +1,4 @@"])
    }

    func testAPureAdditionWithNoContextStartsAfterTheLinesBeforeIt() {
        let old = numbered(1...4)
        let new = numbered(1...4) + "end\n"
        let lines = CommitDiffUnits.unified(rows: LineDiff.rows(old: old, new: new))
        let result = UnifiedDiffDisplayRows.rows(
            for: ChangedFile(path: "a.txt", status: .modified), lines: lines, contextLines: 0
        )
        XCTAssertEqual(hunkHeaders(result), ["@@ -4,0 +5,1 @@"])
    }

    func testChangesFarApartAreSeparateHunks() {
        let old = numbered(1...30)
        let new = numbered(1...4) + "five\n" + numbered(6...24) + "twenty-five\n" + numbered(26...30)
        let result = rows(old, new)
        XCTAssertEqual(hunkHeaders(result), ["@@ -2,7 +2,7 @@", "@@ -22,7 +22,7 @@"])
        // Each hunk header is immediately followed by its own lines, and the
        // context between the hunks is not drawn.
        let texts = result.compactMap(\.line).map(\.text)
        XCTAssertFalse(texts.contains("line 15"))
        XCTAssertEqual(texts.filter { $0 == "line 8" }.count, 1)
    }

    func testChangesCloseTogetherShareOneHunkWithoutRepeatingContext() {
        // Six context lines between the two changes: exactly twice the context
        // width, so the hunks touch and merge.
        let old = numbered(1...20)
        let new = numbered(1...4) + "five\n" + numbered(6...11) + "twelve\n" + numbered(13...20)
        let result = rows(old, new)
        XCTAssertEqual(hunkHeaders(result), ["@@ -2,14 +2,14 @@"])
        let texts = result.compactMap(\.line).map(\.text)
        XCTAssertEqual(texts.count, Set(texts).count, "a context line is drawn twice")
    }

    func testSevenContextLinesBetweenChangesSplitTheHunk() {
        let old = numbered(1...20)
        let new = numbered(1...4) + "five\n" + numbered(6...12) + "thirteen\n" + numbered(14...20)
        XCTAssertEqual(hunkHeaders(rows(old, new)), ["@@ -2,7 +2,7 @@", "@@ -10,7 +10,7 @@"])
    }

    // MARK: - Layout

    func testEveryChangedLineIsKeptWithItsUnitAndInOrder() {
        let old = numbered(1...30)
        let new = numbered(1...4) + "five\n" + numbered(6...24) + "twenty-five\n" + numbered(26...30)
        let lines = CommitDiffUnits.unified(rows: LineDiff.rows(old: old, new: new))
        let result = UnifiedDiffDisplayRows.rows(for: ChangedFile(path: "a.txt", status: .modified), lines: lines)
        XCTAssertEqual(
            result.compactMap(\.line).filter { $0.kind != .context },
            lines.filter { $0.kind != .context }
        )
    }

    func testHeaderRowsCarryNoLine() {
        let result = rows("a\n", "b\n")
        for row in result {
            switch row {
            case .fileHeader, .hunkHeader: XCTAssertNil(row.line)
            case .line: XCTAssertNotNil(row.line)
            }
        }
        // Header, header, hunk, then the hunk's lines.
        XCTAssertEqual(result.count, 3 + result.compactMap(\.line).count)
        if case .hunkHeader = result[2] {} else { XCTFail("the third row is not the hunk header") }
    }

    func testNoChangedLineMeansNoRows() {
        XCTAssertEqual(rows("same\n", "same\n"), [])
        XCTAssertEqual(UnifiedDiffDisplayRows.rows(for: ChangedFile(path: "a", status: .modified), lines: []), [])
    }
}
