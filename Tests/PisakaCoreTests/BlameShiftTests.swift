import XCTest
@testable import PisakaCore

final class BlameShiftTests: XCTestCase {
    // MARK: - Helpers

    /// One distinct annotation per line, so an annotation that migrates to a
    /// foreign index is immediately visible in a failure.
    private func ann(_ n: Int) -> BlameLine {
        BlameLine(
            hash: String(repeating: "0", count: 39) + String(n % 10),
            author: "author\(n)",
            date: "2026-01-01T00:00:0\(n % 10)+00:00",
            summary: "summary\(n)"
        )
    }

    private func annotations(_ count: Int) -> [BlameLine?] {
        (0..<count).map { ann($0) }
    }

    /// The three inputs `BlameShift` takes beside `previous`, produced exactly as
    /// the gutter produces them: the cached line starts from before the edit, the
    /// incrementally updated ones from after it, and the `NSTextStorage`-shaped
    /// `(editedRange, changeInLength)` pair.
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

    private func shift(_ previous: [BlameLine?], _ edit: Edit) -> [BlameLine?] {
        BlameShift.updated(
            previous: previous,
            previousLineStarts: edit.previousStarts,
            newLineStarts: edit.newStarts,
            editedRange: edit.editedRange,
            changeInLength: edit.delta
        )
    }

    // MARK: - Insertions

    func testInsertingOneLineMidDocumentBlanksTheSpanAndKeepsTheSuffix() {
        // "aaa\nbbb\nccc\nddd", split line 1 in the middle.
        let text = NSMutableString(string: "aaa\nbbb\nccc\nddd")
        let previous = annotations(4)
        let edit = apply(to: text, at: 5, delete: 0, insert: "X\n")

        XCTAssertEqual(text as String, "aaa\nbX\nbb\nccc\nddd")
        XCTAssertEqual(shift(previous, edit), [previous[0], nil, nil, previous[2], previous[3]])
    }

    func testMultiLinePasteBlanksTheSpanAndKeepsTheSuffix() {
        let text = NSMutableString(string: "aaa\nbbb\nccc\nddd")
        let previous = annotations(4)
        let edit = apply(to: text, at: 5, delete: 0, insert: "X\nY\nZ")

        let result = shift(previous, edit)
        XCTAssertEqual(result.count, edit.newStarts.count)
        XCTAssertEqual(result.first ?? nil, previous[0])
        XCTAssertEqual(Array(result.suffix(2)), [previous[2], previous[3]])
        XCTAssertTrue(result.dropFirst().dropLast(2).allSatisfy { $0 == nil })
    }

    func testEnterAtColumnZeroBlanksBothResultingLines() {
        // The rejected "first touched line keeps its annotation" rule would hand
        // the brand-new empty line line 1's commit.
        let text = NSMutableString(string: "aaa\nbbb\nccc\nddd")
        let previous = annotations(4)
        let edit = apply(to: text, at: 4, delete: 0, insert: "\n")

        XCTAssertEqual(text as String, "aaa\n\nbbb\nccc\nddd")
        XCTAssertEqual(shift(previous, edit), [previous[0], nil, nil, previous[2], previous[3]])
    }

    func testInsertingALineAtALineStartBlanksBothResultingLines() {
        let text = NSMutableString(string: "aaa\nbbb\nccc\nddd")
        let previous = annotations(4)
        let edit = apply(to: text, at: 4, delete: 0, insert: "new\n")

        XCTAssertEqual(text as String, "aaa\nnew\nbbb\nccc\nddd")
        XCTAssertEqual(shift(previous, edit), [previous[0], nil, nil, previous[2], previous[3]])
    }

    // MARK: - Structure-preserving edits

    func testStructurePreservingEditKeepsThatLinesAnnotation() {
        let text = NSMutableString(string: "aaa\nbbb\nccc\nddd")
        let previous = annotations(4)
        let edit = apply(to: text, at: 5, delete: 0, insert: "X")

        XCTAssertEqual(text as String, "aaa\nbXbb\nccc\nddd")
        XCTAssertEqual(shift(previous, edit), previous)
    }

    func testSameLineReplacementOfAnyLengthKeepsThatLinesAnnotation() {
        let text = NSMutableString(string: "aaa\nbbb\nccc\nddd")
        let previous = annotations(4)
        let edit = apply(to: text, at: 4, delete: 3, insert: "LONGER")

        XCTAssertEqual(text as String, "aaa\nLONGER\nccc\nddd")
        XCTAssertEqual(shift(previous, edit), previous)
    }

    func testMultiLineReplacementOfTheSameLineCountKeepsTheSpanPositionForPosition() {
        let text = NSMutableString(string: "aaa\nbbb\nccc\nddd")
        let previous = annotations(4)
        // Replace lines 1 and 2 (with their terminators) by two other lines.
        let edit = apply(to: text, at: 4, delete: 8, insert: "BB\nCC\n")

        XCTAssertEqual(text as String, "aaa\nBB\nCC\nddd")
        XCTAssertEqual(shift(previous, edit), previous)
    }

    // MARK: - Document edges

    func testEditAtTheVeryStartOfTheDocument() {
        let text = NSMutableString(string: "aaa\nbbb\nccc")
        let previous = annotations(3)

        // Structure-preserving: line 0 keeps its annotation.
        let typed = apply(to: text, at: 0, delete: 0, insert: "X")
        XCTAssertEqual(shift(previous, typed), previous)

        // Structural: the span (line 0) blanks, the suffix is untouched.
        let split = apply(to: text, at: 0, delete: 0, insert: "Y\n")
        XCTAssertEqual(text as String, "Y\nXaaa\nbbb\nccc")
        XCTAssertEqual(shift(previous, split), [nil, nil, previous[1], previous[2]])
    }

    func testEditAtTheVeryEndOfTheDocument() {
        let text = NSMutableString(string: "aaa\nbbb")
        let previous = annotations(2)

        let typed = apply(to: text, at: 7, delete: 0, insert: "X")
        XCTAssertEqual(text as String, "aaa\nbbbX")
        XCTAssertEqual(shift(previous, typed), previous)
    }

    func testEnterAtTheEndOfTheDocumentAddsATrailingEmptyLine() {
        let text = NSMutableString(string: "aaa\nbbb")
        let previous = annotations(2)
        let edit = apply(to: text, at: 7, delete: 0, insert: "\n")

        XCTAssertEqual(edit.newStarts.count, 3)
        XCTAssertEqual(shift(previous, edit), [previous[0], nil, nil])
    }

    func testEditOnTheTrailingEmptyLine() {
        // "aaa\nbbb\n" is three displayed lines; the last one has no blame data.
        let text = NSMutableString(string: "aaa\nbbb\n")
        let previous: [BlameLine?] = [ann(0), ann(1), nil]
        let edit = apply(to: text, at: 8, delete: 0, insert: "c")

        XCTAssertEqual(edit.previousStarts, [0, 4, 8])
        XCTAssertEqual(shift(previous, edit), previous)
    }

    // MARK: - Whole-line deletions (the `max(loc, oldEnd - 1)` span boundary)

    func testDeletingOneWholeLineLeavesEveryFollowingLineWithItsOwnAnnotation() {
        // The `oldEnd` (rather than `oldEnd - 1`) boundary would pull old line 2
        // into the span; the annotations after the deletion would then each sit
        // one line off.
        let text = NSMutableString(string: "aaa\nbbb\nccc\nddd")
        let previous = annotations(4)
        let edit = apply(to: text, at: 4, delete: 4, insert: "")

        XCTAssertEqual(text as String, "aaa\nccc\nddd")
        XCTAssertEqual(shift(previous, edit), [previous[0], previous[2], previous[3]])
    }

    func testDeletingSeveralWholeLinesLeavesEveryFollowingLineWithItsOwnAnnotation() {
        let text = NSMutableString(string: "aaa\nbbb\nccc\nddd\neee")
        let previous = annotations(5)
        let edit = apply(to: text, at: 4, delete: 8, insert: "")

        XCTAssertEqual(text as String, "aaa\nddd\neee")
        XCTAssertEqual(shift(previous, edit), [previous[0], previous[3], previous[4]])
    }

    func testDeletionJoiningTwoLinesBlanksTheJoinedLine() {
        // A selection spanning the break, with surviving content on both sides:
        // the joined line is neither of the two originals, so it blanks while the
        // untouched prefix and suffix keep theirs.
        let text = NSMutableString(string: "aaa\nbbb\nccc\nddd")
        let previous = annotations(4)
        let edit = apply(to: text, at: 6, delete: 3, insert: "")

        XCTAssertEqual(text as String, "aaa\nbbcc\nddd")
        XCTAssertEqual(shift(previous, edit), [previous[0], nil, previous[3]])
    }

    // MARK: - CRLF

    func testCRLFDocumentDeletingAWholeLineKeepsTheSuffix() {
        let text = NSMutableString(string: "aaa\r\nbbb\r\nccc")
        let previous = annotations(3)
        XCTAssertEqual(LineStartIndex.offsets(in: text), [0, 5, 10])

        let edit = apply(to: text, at: 5, delete: 5, insert: "")
        XCTAssertEqual(text as String, "aaa\r\nccc")
        XCTAssertEqual(shift(previous, edit), [previous[0], previous[2]])
    }

    func testCRLFDocumentStructurePreservingEditKeepsEverything() {
        let text = NSMutableString(string: "aaa\r\nbbb\r\nccc")
        let previous = annotations(3)
        let edit = apply(to: text, at: 6, delete: 0, insert: "X")

        XCTAssertEqual(text as String, "aaa\r\nbXbb\r\nccc")
        XCTAssertEqual(shift(previous, edit), previous)
    }

    // MARK: - Fallbacks

    func testEmptyPreviousArrayYieldsAllNilAtTheNewLength() {
        let result = BlameShift.updated(
            previous: [],
            previousLineStarts: [],
            newLineStarts: [0, 4],
            editedRange: NSRange(location: 0, length: 4),
            changeInLength: 4
        )
        XCTAssertEqual(result, [nil, nil])
    }

    func testCountMismatchYieldsAllNilAtTheNewLength() {
        let result = BlameShift.updated(
            previous: annotations(3),
            previousLineStarts: [0, 4, 8, 12],
            newLineStarts: [0, 4, 8],
            editedRange: NSRange(location: 0, length: 0),
            changeInLength: -4
        )
        XCTAssertEqual(result, [nil, nil, nil])
    }

    func testNonZeroAnchoredLineStartsYieldAllNil() {
        let result = BlameShift.updated(
            previous: annotations(2),
            previousLineStarts: [1, 5],
            newLineStarts: [0, 5],
            editedRange: NSRange(location: 2, length: 0),
            changeInLength: 0
        )
        XCTAssertEqual(result, [nil, nil])

        let newSideBroken = BlameShift.updated(
            previous: annotations(2),
            previousLineStarts: [0, 5],
            newLineStarts: [1, 5],
            editedRange: NSRange(location: 2, length: 0),
            changeInLength: 0
        )
        XCTAssertEqual(newSideBroken, [nil, nil])
    }

    func testOutOfRangeEditYieldsAllNil() {
        let negativeLocation = BlameShift.updated(
            previous: annotations(2),
            previousLineStarts: [0, 4],
            newLineStarts: [0, 4],
            editedRange: NSRange(location: -1, length: 0),
            changeInLength: 0
        )
        XCTAssertEqual(negativeLocation, [nil, nil])

        // A delta claiming more was removed than the edit could have replaced,
        // so the pre-edit end lands before the edit's start.
        let impossibleDelta = BlameShift.updated(
            previous: annotations(2),
            previousLineStarts: [0, 4],
            newLineStarts: [0, 4],
            editedRange: NSRange(location: 0, length: 0),
            changeInLength: 3
        )
        XCTAssertEqual(impossibleDelta, [nil, nil])
    }

    func testInconsistentLineStartArraysYieldAllNil() {
        // The edit touches only line 0, so four lines should survive it — but the
        // new array says the document has two. `newSpanLength` comes out negative.
        let result = BlameShift.updated(
            previous: annotations(5),
            previousLineStarts: [0, 4, 8, 12, 16],
            newLineStarts: [0, 4],
            editedRange: NSRange(location: 0, length: 1),
            changeInLength: 1
        )
        XCTAssertEqual(result, [nil, nil])
    }

    // MARK: - updated(...) fuzz invariants

    /// A tiny deterministic LCG so the fuzz run is reproducible across machines.
    private struct LCG {
        var state: UInt64
        mutating func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return bound <= 0 ? 0 : Int((state >> 33) % UInt64(bound))
        }
    }

    /// Independent (linear) restatement of the span boundaries the implementation
    /// binary-searches for, so the fuzz assertions do not reuse its arithmetic.
    private func lastIndex(in starts: [Int], notAfter value: Int) -> Int {
        var result = 0
        for (index, start) in starts.enumerated() where start <= value { result = index }
        return result
    }

    /// A line's own text, **without** its terminator. The terminator is excluded
    /// deliberately: an LF inserted at a line start pairs with a preceding CR into
    /// one CRLF separator, so the *previous* line's terminator can grow even
    /// though that line sits entirely before the edit and its text is untouched.
    private func lineText(_ text: NSString, _ starts: [Int], _ index: Int) -> String {
        var contentsEnd = 0
        text.getLineStart(nil, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: starts[index], length: 0))
        return text.substring(with: NSRange(location: starts[index], length: max(0, contentsEnd - starts[index])))
    }

    func testShiftKeepsAnnotationsAnchoredUnderRandomEdits() {
        let alphabet = ["a", "b", "c", " ", "\t", "\n", "\r", "\r\n", "\u{2028}", "\u{2029}", "x", "y"]
        let seeds: [UInt64] = [0x1234_5678_9abc_def0, 0xdead_beef_cafe_babe, 0x0f0f_0f0f_f0f0_f0f0]

        for seed in seeds {
            var rng = LCG(state: seed)
            let text = NSMutableString(string: "the quick\nbrown\r\nfox\u{2028}jumps")
            var starts = LineStartIndex.offsets(in: text)
            var previous: [BlameLine?] = annotations(starts.count)
            var minted = starts.count

            for _ in 0..<1500 {
                let oldText = NSString(string: text as String)
                let oldStarts = starts
                let oldAnnotations = previous

                let loc = rng.next(text.length + 1)
                let deleteLength = rng.next(text.length - loc + 1)
                var insertion = ""
                for _ in 0..<rng.next(4) { insertion += alphabet[rng.next(alphabet.count)] }

                let edit = apply(to: text, at: loc, delete: deleteLength, insert: insertion)
                let result = shift(oldAnnotations, edit)

                let context = """
                    seed=\(String(format: "%016x", seed)) loc=\(loc) del=\(deleteLength) \
                    ins=\(insertion.debugDescription)
                    """

                // (a) The invariant that makes the array safe to index by line.
                XCTAssertEqual(result.count, edit.newStarts.count, context)
                guard result.count == edit.newStarts.count else { return }

                let oldEnd = loc + deleteLength
                let first = lastIndex(in: oldStarts, notAfter: loc)
                let last = lastIndex(in: oldStarts, notAfter: max(loc, oldEnd - 1))
                let suffixCount = oldAnnotations.count - last - 1
                let newSpanLength = result.count - first - suffixCount
                XCTAssertGreaterThanOrEqual(newSpanLength, 0, context)
                guard newSpanLength >= 0 else { return }

                // (b) Outside the span, every line carries exactly the annotation
                // of the original line with the same content. The prefix is
                // provably untouched; so is every suffix line whose start is
                // strictly past the edit's pre-edit end. The single suffix line
                // that can start *exactly* at `oldEnd` is the documented boundary
                // case — a deletion ending on a line start joins that line onto
                // the edited one, so only its annotation (not its content) is
                // asserted here.
                for index in 0..<first {
                    XCTAssertEqual(result[index], oldAnnotations[index], context)
                    XCTAssertEqual(
                        lineText(oldText, oldStarts, index),
                        lineText(text, edit.newStarts, index),
                        context
                    )
                }
                for offset in 0..<suffixCount {
                    let oldIndex = oldAnnotations.count - 1 - offset
                    let newIndex = result.count - 1 - offset
                    XCTAssertEqual(result[newIndex], oldAnnotations[oldIndex], context)
                    if oldStarts[oldIndex] > oldEnd {
                        XCTAssertEqual(
                            lineText(oldText, oldStarts, oldIndex),
                            lineText(text, edit.newStarts, newIndex),
                            context
                        )
                    }
                }

                // (c) Inside the span: either the line count is unchanged and the
                // old span survives position for position, or the whole span is
                // nil. Nothing from outside can appear inside it, and nothing
                // inside it can move to another index.
                let span = Array(result[first..<(first + newSpanLength)])
                if newSpanLength == last - first + 1 {
                    XCTAssertEqual(span, Array(oldAnnotations[first...last]), context)
                } else {
                    XCTAssertTrue(span.allSatisfy { $0 == nil }, context)
                }

                // Carry the result forward as production does, minting a fresh
                // annotation for every blanked line so each line stays uniquely
                // identifiable and any drift cascades into the next step.
                starts = edit.newStarts
                previous = result.map { value in
                    if let value { return value }
                    minted += 1
                    return ann(minted)
                }
            }
        }
    }
}
