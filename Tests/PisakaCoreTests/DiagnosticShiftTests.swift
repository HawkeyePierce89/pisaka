import XCTest
@testable import PisakaCore

/// D32's three-way rule as arithmetic: entirely-before survives untouched,
/// entirely-after shifts and renumbers, anything intersecting the touched span
/// is dropped — and inconsistent input falls back to an honest `[]`.
///
/// The edits are applied through the same helper shape ``BlameShiftTests`` uses,
/// so the inputs here are produced exactly as the editor coordinator will
/// produce them (`NSTextStorage`'s `(editedRange, changeInLength)` pair over the
/// ruler's two line-start tables), not hand-invented numbers.
final class DiagnosticShiftTests: XCTestCase {
    private let url = URL(fileURLWithPath: "/tmp/pkg/Sources/App/main.swift")

    // MARK: - Helpers

    /// One diagnostic per line of "aaa\nbbb\nccc" by default, each covering its
    /// line's three content characters, so a survivor landing anywhere but its
    /// own line or offset is visible in the assertion.
    private func lines(_ text: String) -> [Int] {
        LineStartIndex.offsets(in: text as NSString)
    }

    private func diagnostic(
        at location: Int,
        length: Int = 3,
        line: Int,
        severity: DiagnosticSeverity = .error
    ) -> Diagnostic {
        Diagnostic(
            range: NSRange(location: location, length: length),
            line: line,
            severity: severity,
            message: "m",
            source: "test",
            fileURL: url
        )
    }

    private struct Edit {
        let previousStarts: [Int]
        let newStarts: [Int]
        let editedRange: NSRange
        let delta: Int
    }

    /// Apply an edit to `text` in place and return the shift inputs for it.
    @discardableResult
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
        return Edit(
            previousStarts: previousStarts,
            newStarts: newStarts,
            editedRange: editedRange,
            delta: delta
        )
    }

    private func shift(_ diagnostics: [Diagnostic], _ edit: Edit) -> [Diagnostic] {
        DiagnosticShift.updated(
            diagnostics,
            previousLineStarts: edit.previousStarts,
            newLineStarts: edit.newStarts,
            editedRange: edit.editedRange,
            changeInLength: edit.delta
        )
    }

    // MARK: - Insertion before / after / inside

    func testAnInsertionBeforeADiagnosticShiftsItsOffsetButNotItsLine() {
        let text = NSMutableString(string: "aaa\nbbb\nccc")
        // One diagnostic per line, covering each line's content.
        let previous = [
            diagnostic(at: 0, line: 0),
            diagnostic(at: 4, line: 1),
            diagnostic(at: 8, line: 2),
        ]
        let edit = apply(to: text, at: 0, delete: 0, insert: "X")

        XCTAssertEqual(text as String, "Xaaa\nbbb\nccc")
        let result = shift(previous, edit)
        XCTAssertEqual(result[0].range, NSRange(location: 1, length: 3))
        XCTAssertEqual(result[0].line, 0)
        XCTAssertEqual(result[1].range, NSRange(location: 5, length: 3))
        XCTAssertEqual(result[1].line, 1)
        XCTAssertEqual(result[2].range, NSRange(location: 9, length: 3))
        XCTAssertEqual(result[2].line, 2)
    }

    func testAnInsertionAfterADiagnosticLeavesItBitForBit() {
        let text = NSMutableString(string: "aaa\nbbb\nccc")
        let previous = [diagnostic(at: 4, line: 1)]
        let edit = apply(to: text, at: 11, delete: 0, insert: "X")

        XCTAssertEqual(shift(previous, edit), previous)
    }

    func testAnInsertionInsideADiagnosticDropsOnlyIt() {
        let text = NSMutableString(string: "aaa\nbbb\nccc")
        let previous = [
            diagnostic(at: 0, line: 0),
            diagnostic(at: 4, line: 1),
            diagnostic(at: 8, line: 2),
        ]
        // Inside line 1's diagnostic.
        let edit = apply(to: text, at: 5, delete: 0, insert: "X")

        let result = shift(previous, edit)
        XCTAssertEqual(result.map(\.range.location), [0, 9])
        XCTAssertEqual(result.map(\.line), [0, 2])
    }

    // MARK: - Deletions

    func testADeletionSpanningADiagnosticDropsItAndShiftsTheSuffixBack() {
        let text = NSMutableString(string: "aaa\nbbb\nccc")
        let previous = [
            diagnostic(at: 0, line: 0),
            diagnostic(at: 4, line: 1),
            diagnostic(at: 8, line: 2),
        ]
        // Remove exactly line 1's content.
        let edit = apply(to: text, at: 4, delete: 3, insert: "")

        XCTAssertEqual(text as String, "aaa\n\nccc")
        let result = shift(previous, edit)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.last?.range, NSRange(location: 5, length: 3))
        XCTAssertEqual(result.last?.line, 2, "the suffix renumbers onto the joined geometry")
    }

    func testAReplacementExactlyCoveringADiagnosticDropsOnlyIt() {
        let text = NSMutableString(string: "aaa\nbbb\nccc")
        let previous = [
            diagnostic(at: 0, line: 0),
            diagnostic(at: 4, line: 1),
            diagnostic(at: 8, line: 2),
        ]
        let edit = apply(to: text, at: 4, delete: 3, insert: "LONGER")

        XCTAssertEqual(text as String, "aaa\nLONGER\nccc")
        let result = shift(previous, edit)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.first?.range, NSRange(location: 0, length: 3))
        XCTAssertEqual(result.last?.range, NSRange(location: 11, length: 3))
        XCTAssertEqual(result.last?.line, 2)
    }

    /// The whole-line-deletion boundary the span rule exists for: the following
    /// diagnostic starts exactly at the pre-edit end of the replaced region, so
    /// half-open containment keeps it — an inclusive bound would silently
    /// discard it along with the deleted line's own.
    func testAWholeLineDeletionKeepsTheFollowingDiagnosticStartingAtOldEnd() {
        let text = NSMutableString(string: "aaa\nbbb\nccc")
        let previous = [
            diagnostic(at: 0, line: 0),
            diagnostic(at: 4, line: 1),
            diagnostic(at: 8, line: 2),
        ]
        // Delete line 1 *with* its separator.
        let edit = apply(to: text, at: 4, delete: 4, insert: "")

        XCTAssertEqual(text as String, "aaa\nccc")
        let result = shift(previous, edit)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.last?.range, NSRange(location: 4, length: 3))
        XCTAssertEqual(result.last?.line, 1)
    }

    func testADeletionBeforeADiagnosticLeavesItUnchangedWhenNothingItCoversMoved() {
        let text = NSMutableString(string: "aaa\nbbb\nccc")
        let previous = [diagnostic(at: 4, line: 1)]
        let edit = apply(to: text, at: 0, delete: 3, insert: "")

        XCTAssertEqual(text as String, "\nbbb\nccc")
        let result = shift(previous, edit)
        XCTAssertEqual(result.first?.range, NSRange(location: 1, length: 3))
        XCTAssertEqual(result.first?.line, 1)
    }

    // MARK: - Structural edits

    func testAnEnterSplitDropsTheSplitDiagnosticAndRenumbersTheSuffix() {
        let text = NSMutableString(string: "aaa\nbbb\nccc")
        let previous = [
            diagnostic(at: 0, line: 0),
            diagnostic(at: 4, line: 1),
            diagnostic(at: 8, line: 2),
        ]
        let edit = apply(to: text, at: 5, delete: 0, insert: "\n")

        XCTAssertEqual(text as String, "aaa\nb\nbb\nccc")
        let result = shift(previous, edit)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.first?.range, NSRange(location: 0, length: 3))
        XCTAssertEqual(result.last?.range, NSRange(location: 9, length: 3))
        XCTAssertEqual(result.last?.line, 3, "renumbered from the new table, not drifted by line delta")
    }

    func testAMultiLinePasteDropsWhatItSpansAndRenumbersTheSuffixOntoItsNewLine() {
        let text = NSMutableString(string: "aaa\nbbb\nccc")
        let previous = [
            diagnostic(at: 0, line: 0),
            diagnostic(at: 4, line: 1),
            diagnostic(at: 8, line: 2),
        ]
        let edit = apply(to: text, at: 5, delete: 0, insert: "X\nY\nZ")

        XCTAssertEqual(text as String, "aaa\nbX\nY\nZbb\nccc")
        let result = shift(previous, edit)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.first?.range, NSRange(location: 0, length: 3))
        XCTAssertEqual(result.last?.range, NSRange(location: 13, length: 3))
        XCTAssertEqual(result.last?.line, 4)
    }

    // MARK: - Zero-length diagnostics at the span's edges

    /// Half-open containment: a caret-sized diagnostic sitting exactly where an
    /// insertion lands survives, rather than blinking off on ordinary typing.
    func testAZeroLengthDiagnosticAtTheInsertionPointSurvivesUnchanged() {
        let text = NSMutableString(string: "aaa\nbbb\nccc")
        let previous = [diagnostic(at: 5, length: 0, line: 1)]
        let edit = apply(to: text, at: 5, delete: 0, insert: "X")

        XCTAssertEqual(shift(previous, edit), previous)
    }

    func testAZeroLengthDiagnosticAtADeletionStartSurvivesUnchanged() {
        let text = NSMutableString(string: "aaa\nbbb\nccc")
        let previous = [diagnostic(at: 4, length: 0, line: 1)]
        let edit = apply(to: text, at: 4, delete: 3, insert: "")

        XCTAssertEqual(shift(previous, edit), previous)
    }

    // MARK: - Ordering and empties

    func testSurvivorsPreserveTheirInputOrder() {
        let text = NSMutableString(string: "aaa\nbbb\nccc")
        // Deliberately out of buffer order; the shifter filters, never sorts.
        let previous = [
            diagnostic(at: 8, line: 2),
            diagnostic(at: 0, line: 0),
            diagnostic(at: 4, line: 1),
        ]
        let edit = apply(to: text, at: 5, delete: 0, insert: "X")

        XCTAssertEqual(shift(previous, edit).map(\.range.location), [9, 0])
    }

    func testNoDiagnosticsMeansNoOutputRegardlessOfTheEdit() {
        let text = NSMutableString(string: "aaa\nbbb\nccc")
        let edit = apply(to: text, at: 4, delete: 0, insert: "X")
        XCTAssertEqual(shift([], edit), [])
    }

    // MARK: - Inconsistent-input fallbacks

    private func shifted(
        previous: [Int],
        new: [Int],
        editedRange: NSRange,
        delta: Int
    ) -> [Diagnostic] {
        DiagnosticShift.updated(
            [diagnostic(at: 4, line: 1)],
            previousLineStarts: previous,
            newLineStarts: new,
            editedRange: editedRange,
            changeInLength: delta
        )
    }

    func testAnEmptyOrUnanchoredTableOnEitherSideYieldsEmpty() {
        let good = [0, 4]
        XCTAssertTrue(shifted(previous: [], new: good, editedRange: NSRange(location: 0, length: 0), delta: 0).isEmpty)
        XCTAssertTrue(shifted(previous: good, new: [], editedRange: NSRange(location: 0, length: 0), delta: 0).isEmpty)
        XCTAssertTrue(shifted(previous: [1, 5], new: good, editedRange: NSRange(location: 0, length: 0), delta: 0).isEmpty)
        XCTAssertTrue(shifted(previous: good, new: [1, 5], editedRange: NSRange(location: 0, length: 0), delta: 0).isEmpty)
    }

    func testANegativeEditRangeYieldsEmpty() {
        let good = [0, 4]
        XCTAssertTrue(shifted(previous: good, new: good, editedRange: NSRange(location: -1, length: 0), delta: 0).isEmpty)
        XCTAssertTrue(shifted(previous: good, new: good, editedRange: NSRange(location: 0, length: -1), delta: 0).isEmpty)
    }

    func testAnImpossibleDeltaYieldsEmpty() {
        // Claims more was removed than the edit could have replaced, so the
        // pre-edit end lands before the edit's start.
        XCTAssertTrue(shifted(previous: [0, 4], new: [0, 4], editedRange: NSRange(location: 0, length: 0), delta: 3).isEmpty)
    }

    func testADegenerateRangeOverflowsIntoTheFallbackInsteadOfTrapping() {
        let result = shifted(
            previous: [0, 4],
            new: [0, 4],
            editedRange: NSRange(location: Int.max, length: 1),
            delta: 0
        )
        XCTAssertTrue(result.isEmpty)
    }

    /// A diagnostic whose end offset overflows poisons the whole answer — the
    /// documented "one bad entry" rule, pinned so it cannot be weakened into a
    /// partial shift (which would look exactly like truth).
    func testADiagnosticEndOffsetOverflowPoisonsTheAnswer() {
        let result = DiagnosticShift.updated(
            [
                diagnostic(at: 4, line: 1),
                diagnostic(at: Int.max - 1, length: 5, line: 1),
            ],
            previousLineStarts: [0, 4],
            newLineStarts: [0, 4],
            editedRange: NSRange(location: 0, length: 0),
            changeInLength: 0
        )
        XCTAssertTrue(result.isEmpty)
    }

    /// A survivor entirely after the edit whose *shifted* bounds would overflow
    /// also poisons the answer rather than trapping or shifting partially.
    func testAShiftedSurvivorBoundsOverflowPoisonsTheAnswer() {
        let result = DiagnosticShift.updated(
            [diagnostic(at: Int.max - 10, length: 3, line: 1)],
            previousLineStarts: [0, 4],
            newLineStarts: [0, 4],
            editedRange: NSRange(location: 0, length: 0),
            changeInLength: 100
        )
        XCTAssertTrue(result.isEmpty)
    }
}
