import Foundation
@testable import PisakaCore
import XCTest

final class RangeEditPlanTests: XCTestCase {

    private func edit(_ location: Int, _ length: Int, _ text: String) -> IndentReplacement {
        IndentReplacement(range: NSRange(location: location, length: length), replacement: text)
    }

    // MARK: - Validation

    func testAcceptsSortedNonOverlappingEdits() {
        let plan = RangeEditPlan(edits: [edit(0, 2, "x"), edit(4, 1, ""), edit(9, 0, "yy")], selections: [])
        XCTAssertNotNil(plan)
        XCTAssertEqual(plan?.edits.count, 3)
    }

    func testAcceptsAnEditStartingWhereThePreviousEnds() {
        XCTAssertNotNil(RangeEditPlan(edits: [edit(0, 3, "a"), edit(3, 2, "b")], selections: []))
    }

    func testAcceptsInsertionsAtTheSameOffset() {
        XCTAssertNotNil(RangeEditPlan(edits: [edit(5, 0, "a"), edit(5, 0, "b")], selections: []))
        XCTAssertNotNil(RangeEditPlan(edits: [edit(5, 0, "a"), edit(5, 2, "b")], selections: []))
    }

    func testRefusesUnsortedEdits() {
        XCTAssertNil(RangeEditPlan(edits: [edit(6, 0, "a"), edit(2, 0, "b")], selections: []))
    }

    func testRefusesOverlappingEdits() {
        XCTAssertNil(RangeEditPlan(edits: [edit(0, 4, "a"), edit(3, 1, "b")], selections: []))
        XCTAssertNil(RangeEditPlan(edits: [edit(2, 2, "a"), edit(2, 2, "b")], selections: []))
        // An insertion at the start of a range that precedes it in the list is
        // inside that range once sorted, so the list is refused either way.
        XCTAssertNil(RangeEditPlan(edits: [edit(5, 3, "a"), edit(5, 0, "b")], selections: []))
    }

    func testRefusesNegativeRanges() {
        XCTAssertNil(RangeEditPlan(edits: [edit(-1, 0, "a")], selections: []))
        XCTAssertNil(RangeEditPlan(edits: [edit(1, -1, "a")], selections: []))
    }

    // MARK: - The empty plan

    func testEmptyPlan() {
        XCTAssertTrue(RangeEditPlan.empty.isEmpty)
        XCTAssertEqual(RangeEditPlan.empty.selections, [])
        XCTAssertEqual(RangeEditPlan.empty.mapped(offset: 7), 7)
        XCTAssertEqual(RangeEditPlan(edits: [], selections: []), .empty)
    }

    func testAPlanWithOnlySelectionsIsEmpty() throws {
        let plan = try XCTUnwrap(RangeEditPlan(edits: [], selections: [NSRange(location: 2, length: 0)]))
        XCTAssertTrue(plan.isEmpty)
        XCTAssertFalse(try XCTUnwrap(RangeEditPlan(edits: [edit(0, 0, "a")], selections: [])).isEmpty)
    }

    // MARK: - Offset mapping

    func testMappingBeforeAnEditIsUnchanged() throws {
        let plan = try XCTUnwrap(RangeEditPlan(edits: [edit(4, 2, "xyz")], selections: []))
        XCTAssertEqual(plan.mapped(offset: 0), 0)
        XCTAssertEqual(plan.mapped(offset: 3), 3)
        XCTAssertEqual(plan.mapped(offset: 3, bias: .before), 3)
    }

    func testMappingInsideAReplacedRange() throws {
        // "abcdefgh", replace "ef" (4..<6) with "xyz" → "abcdxyzgh".
        let plan = try XCTUnwrap(RangeEditPlan(edits: [edit(4, 2, "xyz")], selections: []))
        XCTAssertEqual(plan.mapped(offset: 5), 7, "after: end of the replacement")
        XCTAssertEqual(plan.mapped(offset: 5, bias: .before), 4, "before: start of the replacement")
    }

    func testMappingAtAReplacedRangesStart() throws {
        let plan = try XCTUnwrap(RangeEditPlan(edits: [edit(4, 2, "xyz")], selections: []))
        XCTAssertEqual(plan.mapped(offset: 4), 7)
        XCTAssertEqual(plan.mapped(offset: 4, bias: .before), 4)
    }

    func testMappingAfterAnEditShiftsByItsNetChange() throws {
        let plan = try XCTUnwrap(RangeEditPlan(edits: [edit(4, 2, "xyz")], selections: []))
        XCTAssertEqual(plan.mapped(offset: 6), 7, "at the end of the replaced range")
        XCTAssertEqual(plan.mapped(offset: 6, bias: .before), 7, "the end is past the edit either way")
        XCTAssertEqual(plan.mapped(offset: 8), 9)
    }

    func testMappingAccumulatesAcrossSeveralEdits() throws {
        // "    a\n    b\n", remove two spaces at the start of each line.
        let plan = try XCTUnwrap(RangeEditPlan(edits: [edit(0, 2, ""), edit(6, 2, "")], selections: []))
        XCTAssertEqual(plan.mapped(offset: 4), 2)
        XCTAssertEqual(plan.mapped(offset: 7), 4, "inside the second deletion collapses to its start")
        XCTAssertEqual(plan.mapped(offset: 11), 7)
    }

    func testMappingThroughADeletion() throws {
        let plan = try XCTUnwrap(RangeEditPlan(edits: [edit(2, 3, "")], selections: []))
        XCTAssertEqual(plan.mapped(offset: 3), 2)
        XCTAssertEqual(plan.mapped(offset: 3, bias: .before), 2)
        XCTAssertEqual(plan.mapped(offset: 5), 2)
        XCTAssertEqual(plan.mapped(offset: 6), 3)
    }

    func testMappingAtAnInsertion() throws {
        let plan = try XCTUnwrap(RangeEditPlan(edits: [edit(3, 0, "ab")], selections: []))
        XCTAssertEqual(plan.mapped(offset: 3), 5)
        XCTAssertEqual(plan.mapped(offset: 3, bias: .before), 3)
        XCTAssertEqual(plan.mapped(offset: 4, bias: .before), 6)
    }

    func testMappingAtInsertionsAtTheSameOffset() throws {
        let plan = try XCTUnwrap(RangeEditPlan(edits: [edit(3, 0, "ab"), edit(3, 0, "c")], selections: []))
        XCTAssertEqual(plan.mapped(offset: 3), 6, "after: past every insertion at the offset")
        XCTAssertEqual(plan.mapped(offset: 3, bias: .before), 3, "before: in front of all of them")
        XCTAssertEqual(plan.mapped(offset: 4), 7)
    }

    func testMappingAtAnInsertionFollowedByAReplacementAtTheSameOffset() throws {
        let plan = try XCTUnwrap(RangeEditPlan(edits: [edit(3, 0, "ab"), edit(3, 2, "c")], selections: []))
        XCTAssertEqual(plan.mapped(offset: 3), 6)
        XCTAssertEqual(plan.mapped(offset: 3, bias: .before), 3)
        XCTAssertEqual(plan.mapped(offset: 4, bias: .before), 5, "inside the replacement, after the insertion")
        XCTAssertEqual(plan.mapped(offset: 5), 6)
    }

    func testMappingAtAdjacentEdits() throws {
        // Replace 0..<3 with "a", then 3..<5 with "bcd".
        let plan = try XCTUnwrap(RangeEditPlan(edits: [edit(0, 3, "a"), edit(3, 2, "bcd")], selections: []))
        XCTAssertEqual(plan.mapped(offset: 3, bias: .before), 1, "end of the first is the start of the second")
        XCTAssertEqual(plan.mapped(offset: 3), 4)
        XCTAssertEqual(plan.mapped(offset: 5), 4)
    }

    func testMappingCountsUTF16Units() throws {
        let plan = try XCTUnwrap(RangeEditPlan(edits: [edit(0, 0, "😀")], selections: []))
        XCTAssertEqual(plan.mapped(offset: 0), 2)
        XCTAssertEqual(plan.mapped(offset: 1), 3)
    }

    // MARK: - The Tab plan converts losslessly

    func testTabInsertionPlanIsAValidRangeEditPlan() throws {
        let tab = IndentUnitRule.tabInsertionPlan(
            ranges: [NSRange(location: 4, length: 0), NSRange(location: 0, length: 2), NSRange(location: 4, length: 0)],
            insertion: "    "
        )
        let plan = try XCTUnwrap(RangeEditPlan(edits: tab.replacements, selections: tab.carets))
        XCTAssertEqual(plan.edits, tab.replacements)
        XCTAssertEqual(plan.selections, tab.carets)
    }
}
