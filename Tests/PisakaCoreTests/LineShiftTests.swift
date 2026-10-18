import XCTest
@testable import PisakaCore

/// `LineShift` is the generic half of `BlameShift`: the same span arithmetic
/// over any payload. `BlameShiftTests` pins the rule at `BlameLine` (including
/// the fuzz block); these pin it at a payload that is not a blame line, so the
/// generic signature is exercised on its own and a change marker — the second
/// rider — is covered by construction.
final class LineShiftTests: XCTestCase {
    /// A non-`BlameLine` payload, distinct per line so a migration to a foreign
    /// index shows in a failure.
    private struct Marker: Equatable {
        let tag: Int
    }

    private func markers(_ count: Int) -> [Marker?] {
        (0..<count).map { Marker(tag: $0) }
    }

    private struct Edit {
        let previousStarts: [Int]
        let newStarts: [Int]
        let editedRange: NSRange
        let delta: Int
    }

    /// Apply an edit to `text` in place and return the shift inputs, produced
    /// exactly as the ruler produces them.
    private func apply(
        to text: NSMutableString,
        at location: Int,
        delete deleteLength: Int,
        insert insertion: String
    ) -> Edit {
        let previousStarts = LineStartIndex.offsets(in: text)
        let insertedLength = (insertion as NSString).length
        text.replaceCharacters(in: NSRange(location: location, length: deleteLength), with: insertion)
        let editedRange = NSRange(location: location, length: insertedLength)
        let delta = insertedLength - deleteLength
        let newStarts = LineStartIndex.updated(
            previous: previousStarts,
            editedRange: editedRange,
            changeInLength: delta,
            newText: text
        )
        return Edit(previousStarts: previousStarts, newStarts: newStarts, editedRange: editedRange, delta: delta)
    }

    private func shift(_ previous: [Marker?], _ edit: Edit) -> [Marker?] {
        LineShift.updated(
            previous: previous,
            previousLineStarts: edit.previousStarts,
            newLineStarts: edit.newStarts,
            editedRange: edit.editedRange,
            changeInLength: edit.delta
        )
    }

    // MARK: - The four edit shapes

    func testKeystrokeKeepsEveryMarkerInPlace() {
        let text = NSMutableString(string: "aaa\nbbb\nccc")
        let previous = markers(3)
        let edit = apply(to: text, at: 5, delete: 0, insert: "X")

        XCTAssertEqual(text as String, "aaa\nbXbb\nccc")
        XCTAssertEqual(shift(previous, edit), previous)
    }

    func testEnterSplitBlanksBothHalvesAndShiftsTheSuffix() {
        let text = NSMutableString(string: "aaa\nbbb\nccc\nddd")
        let previous = markers(4)
        let edit = apply(to: text, at: 5, delete: 0, insert: "\n")

        XCTAssertEqual(text as String, "aaa\nb\nbb\nccc\nddd")
        XCTAssertEqual(shift(previous, edit), [previous[0], nil, nil, previous[2], previous[3]])
    }

    func testWholeLineDeleteKeepsEveryFollowingLinesOwnMarker() {
        // The `oldEnd - 1` clamp: the deletion ends exactly on old line 2's
        // start, which must stay outside the span.
        let text = NSMutableString(string: "aaa\nbbb\nccc\nddd")
        let previous = markers(4)
        let edit = apply(to: text, at: 4, delete: 4, insert: "")

        XCTAssertEqual(text as String, "aaa\nccc\nddd")
        XCTAssertEqual(shift(previous, edit), [previous[0], previous[2], previous[3]])
    }

    func testMultiLinePasteBlanksTheSpanAtTheNewLength() {
        let text = NSMutableString(string: "aaa\nbbb\nccc")
        let previous = markers(3)
        let edit = apply(to: text, at: 4, delete: 0, insert: "x\ny\nz\n")

        XCTAssertEqual(text as String, "aaa\nx\ny\nz\nbbb\nccc")
        XCTAssertEqual(shift(previous, edit), [previous[0], nil, nil, nil, nil, previous[2]])
    }

    func testResultLengthAlwaysEqualsTheNewLineStartCount() {
        let text = NSMutableString(string: "aaa\nbbb\n")
        var current = markers(3)
        let steps: [(Int, Int, String)] = [(8, 0, "c\nd"), (0, 4, ""), (2, 3, "\r\n"), (0, 0, "\u{2028}")]
        for (location, length, insertion) in steps {
            let edit = apply(to: text, at: location, delete: length, insert: insertion)
            current = shift(current, edit)
            XCTAssertEqual(current.count, edit.newStarts.count)
            XCTAssertEqual(current.count, LineStartIndex.offsets(in: text).count)
        }
    }

    // MARK: - Fallback guards

    private func assertBlank(
        _ result: [Marker?],
        count: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(result.count, count, file: file, line: line)
        XCTAssertTrue(result.allSatisfy { $0 == nil }, file: file, line: line)
    }

    func testMismatchedPreviousCountFallsBackToBlank() {
        let result = LineShift.updated(
            previous: markers(2),
            previousLineStarts: [0, 4, 8],
            newLineStarts: [0, 4, 8],
            editedRange: NSRange(location: 1, length: 1),
            changeInLength: 1
        )
        assertBlank(result, count: 3)
    }

    func testLineStartsNotAnchoredAtZeroFallBackToBlank() {
        let unanchoredPrevious = LineShift.updated(
            previous: markers(2),
            previousLineStarts: [1, 4],
            newLineStarts: [0, 4],
            editedRange: NSRange(location: 1, length: 0),
            changeInLength: 0
        )
        assertBlank(unanchoredPrevious, count: 2)

        let emptyNew = LineShift.updated(
            previous: markers(1),
            previousLineStarts: [0],
            newLineStarts: [],
            editedRange: NSRange(location: 0, length: 0),
            changeInLength: 0
        )
        assertBlank(emptyNew, count: 0)
    }

    func testNegativeRangeFallsBackToBlank() {
        let result = LineShift.updated(
            previous: markers(2),
            previousLineStarts: [0, 4],
            newLineStarts: [0, 4],
            editedRange: NSRange(location: -1, length: 0),
            changeInLength: 0
        )
        assertBlank(result, count: 2)
    }

    func testReplacedSpanEndingBeforeItsStartFallsBackToBlank() {
        // `changeInLength` larger than the edited length: the pre-edit end
        // would lie before `loc`.
        let result = LineShift.updated(
            previous: markers(2),
            previousLineStarts: [0, 4],
            newLineStarts: [0, 4],
            editedRange: NSRange(location: 1, length: 1),
            changeInLength: 5
        )
        assertBlank(result, count: 2)
    }

    func testNotFoundRangeFallsBackInsteadOfTrapping() {
        let result = LineShift.updated(
            previous: markers(2),
            previousLineStarts: [0, 4],
            newLineStarts: [0, 4],
            editedRange: NSRange(location: NSNotFound, length: 1),
            changeInLength: 0
        )
        assertBlank(result, count: 2)
    }

    func testNegativeNewSpanLengthFallsBackToBlank() {
        // The new text claims fewer lines than the untouched suffix alone holds.
        let result = LineShift.updated(
            previous: markers(4),
            previousLineStarts: [0, 4, 8, 12],
            newLineStarts: [0],
            editedRange: NSRange(location: 0, length: 0),
            changeInLength: 0
        )
        assertBlank(result, count: 1)
    }
}
