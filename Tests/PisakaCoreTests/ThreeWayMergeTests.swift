import XCTest
@testable import PisakaCore

final class ThreeWayMergeTests: XCTestCase {
    // Convenience: join lines back the way the document would, so assertions read
    // naturally. The merge works on logical lines (separator-stripped).
    private func text(_ lines: String...) -> String { lines.joined(separator: "\n") }

    func testNoChangeIsOneStableRegion() {
        let base = text("a", "b", "c")
        let regions = ThreeWayMerge.regions(base: base, ours: base, theirs: base)
        XCTAssertEqual(regions, [.stable(["a", "b", "c"])])
    }

    func testOursOnlyChangeAutoMergesToOurs() {
        let regions = ThreeWayMerge.regions(
            base: text("a", "b", "c"),
            ours: text("a", "B", "c"),
            theirs: text("a", "b", "c")
        )
        XCTAssertEqual(regions, [.stable(["a", "B", "c"])])
    }

    func testTheirsOnlyChangeAutoMergesToTheirs() {
        let regions = ThreeWayMerge.regions(
            base: text("a", "b", "c"),
            ours: text("a", "b", "c"),
            theirs: text("a", "B", "c")
        )
        XCTAssertEqual(regions, [.stable(["a", "B", "c"])])
    }

    func testBothChangeSameRegionConflicts() {
        let regions = ThreeWayMerge.regions(
            base: text("a", "b", "c"),
            ours: text("a", "X", "c"),
            theirs: text("a", "Y", "c")
        )
        XCTAssertEqual(regions, [
            .stable(["a"]),
            .conflict(ConflictHunk(base: ["b"], ours: ["X"], theirs: ["Y"])),
            .stable(["c"]),
        ])
    }

    func testBothChangeIdenticallyIsStable() {
        let regions = ThreeWayMerge.regions(
            base: text("a", "b", "c"),
            ours: text("a", "Z", "c"),
            theirs: text("a", "Z", "c")
        )
        XCTAssertEqual(regions, [.stable(["a", "Z", "c"])])
    }

    func testAddAddWithEmptyBaseConflicts() {
        let regions = ThreeWayMerge.regions(
            base: "",
            ours: text("X"),
            theirs: text("Y")
        )
        XCTAssertEqual(regions, [
            .conflict(ConflictHunk(base: [], ours: ["X"], theirs: ["Y"]))
        ])
    }

    func testModifyDeleteHasOneEmptySide() {
        // ours modifies line 2; theirs deletes it.
        let regions = ThreeWayMerge.regions(
            base: text("a", "b", "c"),
            ours: text("a", "B", "c"),
            theirs: text("a", "c")
        )
        XCTAssertEqual(regions, [
            .stable(["a"]),
            .conflict(ConflictHunk(base: ["b"], ours: ["B"], theirs: [])),
            .stable(["c"]),
        ])
    }

    func testMultipleConflictsInterleavedWithStable() {
        let regions = ThreeWayMerge.regions(
            base: text("a", "b", "c", "d", "e"),
            ours: text("a", "B1", "c", "D1", "e"),
            theirs: text("a", "B2", "c", "D2", "e")
        )
        XCTAssertEqual(regions, [
            .stable(["a"]),
            .conflict(ConflictHunk(base: ["b"], ours: ["B1"], theirs: ["B2"])),
            .stable(["c"]),
            .conflict(ConflictHunk(base: ["d"], ours: ["D1"], theirs: ["D2"])),
            .stable(["e"]),
        ])
    }

    func testNonConflictingDisjointChangesBothApplied() {
        // ours changes the first half, theirs the (disjoint, stable-separated)
        // second half: both auto-merge, no conflict.
        let regions = ThreeWayMerge.regions(
            base: text("a", "b", "c", "d", "e"),
            ours: text("A", "b", "c", "d", "e"),
            theirs: text("a", "b", "c", "d", "E")
        )
        XCTAssertEqual(regions, [.stable(["A", "b", "c", "d", "E"])])
    }

    func testAdjacentIndependentChangesAutoMerge() {
        // ours changes line b, theirs changes the immediately following line c —
        // adjacent base lines but each touched by only one side. They abut (no
        // stable line between) yet are independent, so they auto-merge rather than
        // collapsing into a spurious both-sides conflict.
        let regions = ThreeWayMerge.regions(
            base: text("a", "b", "c", "d"),
            ours: text("a", "B", "c", "d"),
            theirs: text("a", "b", "C", "d")
        )
        XCTAssertEqual(regions, [.stable(["a", "B", "C", "d"])])
    }

    func testMultiLineConflictSpan() {
        let regions = ThreeWayMerge.regions(
            base: text("a", "b", "c", "d"),
            ours: text("a", "X1", "X2", "d"),
            theirs: text("a", "Y1", "d")
        )
        XCTAssertEqual(regions, [
            .stable(["a"]),
            .conflict(ConflictHunk(base: ["b", "c"], ours: ["X1", "X2"], theirs: ["Y1"])),
            .stable(["d"]),
        ])
    }

    func testTrailingNewlinePreservedAsLogicalLines() {
        // A trailing newline is not a logical line (matching the editor): with or
        // without it the regions are identical, so trailing-newline handling is
        // deferred to MergeDocument.resolvedText, not lost here as a phantom line.
        let withNewline = ThreeWayMerge.regions(
            base: "a\nb\n",
            ours: "a\nb\n",
            theirs: "a\nb\n"
        )
        let withoutNewline = ThreeWayMerge.regions(
            base: "a\nb",
            ours: "a\nb",
            theirs: "a\nb"
        )
        XCTAssertEqual(withNewline, [.stable(["a", "b"])])
        XCTAssertEqual(withNewline, withoutNewline)
    }

    func testAdjacentConflictingLinesCoalesceIntoOneHunk() {
        // Two adjacent base lines both changed differently by each side coalesce
        // into a single multi-line conflict hunk (no stable line between them).
        let regions = ThreeWayMerge.regions(
            base: text("a", "b"),
            ours: text("X1", "X2"),
            theirs: text("Y1", "Y2")
        )
        XCTAssertEqual(regions, [
            .conflict(ConflictHunk(base: ["a", "b"], ours: ["X1", "X2"], theirs: ["Y1", "Y2"]))
        ])
    }

    func testAddAddWithIdenticalContentIsStable() {
        // Empty base, both sides add the *same* content → a false conflict that
        // reconciles to a stable region.
        let regions = ThreeWayMerge.regions(
            base: "",
            ours: text("X"),
            theirs: text("X")
        )
        XCTAssertEqual(regions, [.stable(["X"])])
    }

    func testInsertionOnOneSideAutoMerges() {
        let regions = ThreeWayMerge.regions(
            base: text("a", "c"),
            ours: text("a", "b", "c"),
            theirs: text("a", "c")
        )
        XCTAssertEqual(regions, [.stable(["a", "b", "c"])])
    }
}
