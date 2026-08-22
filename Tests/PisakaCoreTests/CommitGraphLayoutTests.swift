import XCTest
@testable import PisakaCore

final class CommitGraphLayoutTests: XCTestCase {
    /// Build a minimal commit carrying only what the layout reads (hash + parents).
    private func commit(_ hash: String, parents: [String] = []) -> Commit {
        Commit(
            hash: hash,
            parents: parents,
            author: "Dev",
            date: "2026-06-25T00:00:00+00:00",
            subject: hash,
            refs: []
        )
    }

    func testEmptyInput() {
        XCTAssertEqual(CommitGraphLayout.layout([]), .empty)
        XCTAssertEqual(CommitGraphLayout.layout([]).width, 0)
    }

    func testLinearHistorySingleLane() {
        // A -> B -> C (root), newest first.
        let graph = CommitGraphLayout.layout([
            commit("A", parents: ["B"]),
            commit("B", parents: ["C"]),
            commit("C")
        ])
        XCTAssertEqual(graph.width, 1)
        XCTAssertEqual(graph.rows, [
            CommitGraphRow(column: 0, colorIndex: 0, edges: [GraphEdge(fromColumn: 0, toColumn: 0, colorIndex: 0)]),
            CommitGraphRow(column: 0, colorIndex: 0, edges: [GraphEdge(fromColumn: 0, toColumn: 0, colorIndex: 0)]),
            CommitGraphRow(column: 0, colorIndex: 0, edges: [])
        ])
    }

    func testRootCommitHasNoOutgoingEdges() {
        let graph = CommitGraphLayout.layout([commit("root")])
        XCTAssertEqual(graph.rows, [CommitGraphRow(column: 0, colorIndex: 0, edges: [])])
        XCTAssertEqual(graph.width, 1)
    }

    func testBranchThenMergeOpensThenClosesALane() {
        // M is a merge of A (first parent) and B (second parent); both reach `base`.
        //   M   parents [A, B]
        //   A   parents [base]
        //   B   parents [base]
        //   base (root)
        let graph = CommitGraphLayout.layout([
            commit("M", parents: ["A", "B"]),
            commit("A", parents: ["base"]),
            commit("B", parents: ["base"]),
            commit("base")
        ])
        XCTAssertEqual(graph.width, 2)

        // M: node lane 0; first parent A continues lane 0, second parent B opens lane 1.
        XCTAssertEqual(graph.rows[0], CommitGraphRow(column: 0, colorIndex: 0, edges: [
            GraphEdge(fromColumn: 0, toColumn: 0, colorIndex: 0),
            GraphEdge(fromColumn: 0, toColumn: 1, colorIndex: 1)
        ]))
        // A: node lane 0, continues to base (lane 0); lane 1 (B) passes through.
        XCTAssertEqual(graph.rows[1], CommitGraphRow(column: 0, colorIndex: 0, edges: [
            GraphEdge(fromColumn: 0, toColumn: 0, colorIndex: 0),
            GraphEdge(fromColumn: 1, toColumn: 1, colorIndex: 1)
        ]))
        // B: node lane 1; its parent base already has lane 0, so it merges in (diagonal
        // to column 0 in lane 0's color) and lane 1 closes.
        XCTAssertEqual(graph.rows[2], CommitGraphRow(column: 1, colorIndex: 1, edges: [
            GraphEdge(fromColumn: 1, toColumn: 0, colorIndex: 0)
        ]))
        // base: root, lane 0, no outgoing edges.
        XCTAssertEqual(graph.rows[3], CommitGraphRow(column: 0, colorIndex: 0, edges: []))
    }

    func testParallelBranchesGetDistinctLanesAndColors() {
        // Two independent tips that never merge within the window.
        //   X parents [bx]
        //   Y parents [by]
        //   bx (root)
        //   by (root)
        let graph = CommitGraphLayout.layout([
            commit("X", parents: ["bx"]),
            commit("Y", parents: ["by"]),
            commit("bx"),
            commit("by")
        ])
        XCTAssertEqual(graph.width, 2)

        XCTAssertEqual(graph.rows[0], CommitGraphRow(column: 0, colorIndex: 0, edges: [
            GraphEdge(fromColumn: 0, toColumn: 0, colorIndex: 0)
        ]))
        // Y is a fresh tip: new lane 1, new color 1; lane 0 (bx) passes through.
        // Parent edges come before pass-through edges, so lane 1's continuation
        // (Y -> by) is listed before lane 0's pass-through.
        XCTAssertEqual(graph.rows[1], CommitGraphRow(column: 1, colorIndex: 1, edges: [
            GraphEdge(fromColumn: 1, toColumn: 1, colorIndex: 1),
            GraphEdge(fromColumn: 0, toColumn: 0, colorIndex: 0)
        ]))
        // bx: root in lane 0; lane 1 (by) passes through.
        XCTAssertEqual(graph.rows[2], CommitGraphRow(column: 0, colorIndex: 0, edges: [
            GraphEdge(fromColumn: 1, toColumn: 1, colorIndex: 1)
        ]))
        // by: root in lane 1.
        XCTAssertEqual(graph.rows[3], CommitGraphRow(column: 1, colorIndex: 1, edges: []))
    }

    func testOctopusMergeOpensALanePerExtraParent() {
        let graph = CommitGraphLayout.layout([
            commit("M", parents: ["A", "B", "C"]),
            commit("A"),
            commit("B"),
            commit("C")
        ])
        XCTAssertGreaterThanOrEqual(graph.width, 3)
        // First parent continues lane 0; B and C each open a fresh lane + color.
        XCTAssertEqual(graph.rows[0], CommitGraphRow(column: 0, colorIndex: 0, edges: [
            GraphEdge(fromColumn: 0, toColumn: 0, colorIndex: 0),
            GraphEdge(fromColumn: 0, toColumn: 1, colorIndex: 1),
            GraphEdge(fromColumn: 0, toColumn: 2, colorIndex: 2)
        ]))
        // Each parent terminates in its own lane (roots, no outgoing edges).
        XCTAssertEqual(graph.rows[1].column, 0)
        XCTAssertEqual(graph.rows[2].column, 1)
        XCTAssertEqual(graph.rows[3].column, 2)
    }

    func testLaneColorIsStableAcrossRows() {
        // The second branch (lane 1, color 1) spans rows M, A, B; its color index
        // must stay 1 everywhere it appears.
        let graph = CommitGraphLayout.layout([
            commit("M", parents: ["A", "B"]),
            commit("A", parents: ["base"]),
            commit("B", parents: ["base"]),
            commit("base")
        ])
        // The lane-1 segment in each of the first three rows is color 1.
        func laneOneColor(_ row: CommitGraphRow) -> Int? {
            row.edges.first(where: { $0.toColumn == 1 || $0.fromColumn == 1 })?.colorIndex
                ?? (row.column == 1 ? row.colorIndex : nil)
        }
        XCTAssertEqual(laneOneColor(graph.rows[0]), 1) // opening edge to lane 1
        XCTAssertEqual(laneOneColor(graph.rows[1]), 1) // pass-through in lane 1
        XCTAssertEqual(graph.rows[2].colorIndex, 1)    // B's node sits in lane 1
    }

    func testFreedLaneSlotIsReusedToStayNarrow() {
        // A branch opens then closes; a later independent branch should reuse the
        // freed column rather than widening the graph.
        //   M  parents [A, B]      (opens lane 1)
        //   A  parents [base]
        //   B  parents [base]      (lane 1 closes here)
        //   base parents [old]
        //   Z  parents [zp]        (fresh tip -> reuses lane 1's freed slot)
        //   old (root)
        //   zp  (root)
        let graph = CommitGraphLayout.layout([
            commit("M", parents: ["A", "B"]),
            commit("A", parents: ["base"]),
            commit("B", parents: ["base"]),
            commit("base", parents: ["old"]),
            commit("Z", parents: ["zp"]),
            commit("old"),
            commit("zp")
        ])
        // Z is a fresh tip after lane 1 freed up; it should land in column 1, not 2.
        let zRow = graph.rows[4]
        XCTAssertEqual(zRow.column, 1)
        XCTAssertEqual(graph.width, 2)
    }
}
