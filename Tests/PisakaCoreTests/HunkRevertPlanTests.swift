import XCTest
@testable import PisakaCore

/// `HunkRevertPlan.plan(hunk:base:buffer:)` — the byte-exact revert of one hunk,
/// the end-of-text rule, the caret, and a fuzz holding the whole against HEAD.
final class HunkRevertPlanTests: XCTestCase {

    private func apply(_ plan: RangeEditPlan, to text: String) -> String {
        let result = NSMutableString(string: text)
        for edit in plan.edits.reversed() {
            result.replaceCharacters(in: edit.range, with: edit.replacement)
        }
        return result as String
    }

    private func hunks(base: String, buffer: String) -> [ChangeHunk] {
        GutterChangeModel.compute(base: base, buffer: buffer).hunks
    }

    /// Reverts the buffer's only hunk and returns the result and the caret.
    private func revertOnly(base: String, buffer: String,
                            file: StaticString = #filePath, line: UInt = #line) -> (String, Int)? {
        let all = hunks(base: base, buffer: buffer)
        XCTAssertEqual(all.count, 1, "expected one hunk", file: file, line: line)
        guard let hunk = all.first,
              let plan = HunkRevertPlan.plan(hunk: hunk, base: base, buffer: buffer) else {
            XCTFail("no plan", file: file, line: line)
            return nil
        }
        XCTAssertEqual(plan.edits.count, 1, file: file, line: line)
        return (apply(plan, to: buffer), plan.selections.first?.location ?? -1)
    }

    // MARK: - Cases

    func testHunkAtStartOfFile() {
        guard let (result, caret) = revertOnly(base: "a\nb\nc\n", buffer: "X\nY\nZ\nb\nc\n") else { return }
        XCTAssertEqual(result, "a\nb\nc\n")
        XCTAssertEqual(caret, 0)
    }

    func testModifiedHunkEndingAtUnterminatedLastLine() {
        guard let (result, caret) = revertOnly(base: "a\nb\nc\n", buffer: "a\nb\nX") else { return }
        XCTAssertEqual(result, "a\nb\nc\n")
        XCTAssertEqual(caret, 4)

        guard let (back, _) = revertOnly(base: "a\nb\nc", buffer: "a\nb\nX\n") else { return }
        XCTAssertEqual(back, "a\nb\nc")
    }

    func testAddedLineAtUnterminatedEnd() {
        guard let (result, caret) = revertOnly(base: "a\nb", buffer: "a\nb\nnew") else { return }
        XCTAssertEqual(result, "a\nb")
        XCTAssertEqual(caret, 3)

        guard let (terminated, _) = revertOnly(base: "a\nb\n", buffer: "a\nb\nnew") else { return }
        XCTAssertEqual(terminated, "a\nb\n")
    }

    func testCRLFFileKeepsItsTerminators() {
        guard let (result, caret) = revertOnly(base: "a\r\nb\r\nc\r\n", buffer: "a\r\nB\r\nB2\r\nc\r\n") else { return }
        XCTAssertEqual(result, "a\r\nb\r\nc\r\n")
        XCTAssertEqual(caret, 3)
    }

    func testDeletionAfterTheLastLine() {
        // HEAD terminated, buffer's last line unterminated.
        guard let (result, caret) = revertOnly(base: "a\nb\nc\n", buffer: "a") else { return }
        XCTAssertEqual(result, "a\nb\nc\n")
        XCTAssertEqual(caret, 2)

        // HEAD unterminated, buffer's last line terminated.
        guard let (unterminated, _) = revertOnly(base: "a\nb", buffer: "a\n") else { return }
        XCTAssertEqual(unterminated, "a\nb")

        // Both unterminated.
        guard let (both, _) = revertOnly(base: "a\nb", buffer: "a") else { return }
        XCTAssertEqual(both, "a\nb")
    }

    func testMidFileDeletionInsertsAfterTheAnchor() {
        guard let (result, caret) = revertOnly(base: "a\nb\nc\nd\n", buffer: "a\nd\n") else { return }
        XCTAssertEqual(result, "a\nb\nc\nd\n")
        XCTAssertEqual(caret, 2)
    }

    func testDeletionBeforeLineOne() {
        guard let (result, caret) = revertOnly(base: "a\nb\nc\n", buffer: "c\n") else { return }
        XCTAssertEqual(result, "a\nb\nc\n")
        XCTAssertEqual(caret, 0)
    }

    func testEmptyBufferRestoresHead() {
        guard let (result, caret) = revertOnly(base: "a\nb", buffer: "") else { return }
        XCTAssertEqual(result, "a\nb")
        XCTAssertEqual(caret, 0)
    }

    func testWholeBufferHunkRemovesAnAddedFile() {
        guard let (result, _) = revertOnly(base: "a\n", buffer: "X\nY") else { return }
        XCTAssertEqual(result, "a\n")
    }

    func testModifiedHunkWithUnequalSideCounts() {
        guard let (result, caret) = revertOnly(base: "a\nb\nc\nd\ne\n", buffer: "a\nX\ne\n") else { return }
        XCTAssertEqual(result, "a\nb\nc\nd\ne\n")
        XCTAssertEqual(caret, 2)

        guard let (fewer, _) = revertOnly(base: "a\nb\ne\n", buffer: "a\nX\nY\nZ\ne\n") else { return }
        XCTAssertEqual(fewer, "a\nb\ne\n")
    }

    func testMixedSeparatorsAreHeadsVerbatim() {
        guard let (result, _) = revertOnly(base: "a\u{2028}b\rc\u{85}", buffer: "a\u{2028}X") else { return }
        XCTAssertEqual(result, "a\u{2028}b\rc\u{85}")
    }

    func testStaleHunkIsNil() {
        let hunk = ChangeHunk(kind: .modified, newLines: 3..<5, oldLines: 0..<1)
        XCTAssertNil(HunkRevertPlan.plan(hunk: hunk, base: "a\n", buffer: "a\nb\n"))
        let oldPast = ChangeHunk(kind: .modified, newLines: 0..<1, oldLines: 2..<4)
        XCTAssertNil(HunkRevertPlan.plan(hunk: oldPast, base: "a\n", buffer: "a\nb\n"))
    }

    func testNegativeBoundsAreNil() {
        let negativeOld = ChangeHunk(kind: .modified, newLines: 0..<1, oldLines: -1..<1)
        XCTAssertNil(HunkRevertPlan.plan(hunk: negativeOld, base: "a\n", buffer: "b\n"))
        let negativeNew = ChangeHunk(kind: .modified, newLines: -1..<1, oldLines: 0..<1)
        XCTAssertNil(HunkRevertPlan.plan(hunk: negativeNew, base: "a\n", buffer: "b\n"))
    }

    func testEndOfBufferHunkWithNoUnchangedLineAboveOnTheHeadSideIsNil() {
        // Reaching the buffer's end below line 1 needs HEAD's preceding line for
        // its terminator; a hunk whose HEAD side starts at line 1 has none.
        let hunk = ChangeHunk(kind: .modified, newLines: 1..<2, oldLines: 0..<1)
        XCTAssertNil(HunkRevertPlan.plan(hunk: hunk, base: "a", buffer: "x\nb"))
    }

    func testFinalNewlineOnlyHunkRevertsToHeadsTerminatorState() {
        guard let (gained, _) = revertOnly(base: "a\nb", buffer: "a\nb\n") else { return }
        XCTAssertEqual(gained, "a\nb")
        guard let (lost, _) = revertOnly(base: "a\r\nb\r\n", buffer: "a\r\nb") else { return }
        XCTAssertEqual(lost, "a\r\nb\r\n")
    }

    /// A blank last line appended or removed is an insert or a delete, not the
    /// final-newline row, and its revert still restores HEAD's terminator state
    /// on the line above.
    func testBlankLastLineHunkRevertsToHeadsTerminatorState() {
        guard let (appended, _) = revertOnly(base: "a", buffer: "a\n\n") else { return }
        XCTAssertEqual(appended, "a")
        guard let (removed, _) = revertOnly(base: "a\n\n", buffer: "a") else { return }
        XCTAssertEqual(removed, "a\n\n")
    }

    // MARK: - Fuzz

    private struct LCG {
        var state: UInt64
        mutating func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return bound <= 0 ? 0 : Int((state >> 33) % UInt64(bound))
        }
    }

    /// The blank entry puts empty lines — a trailing blank one included — next
    /// to the end-of-text rule.
    private static let words = ["alpha", "beta", "gamma", "delta", "eps", "zeta", "eta", "theta", "iota", "kappa", ""]

    /// A random small text. Each line's terminator is a function of its content
    /// — so a line the diff calls unchanged is byte-identical on both sides —
    /// except the last, whose final separator is the caller's choice.
    private func randomText(_ rng: inout LCG, finalNewline: Bool) -> String {
        let count = rng.next(7)
        var text = ""
        for index in 0..<count {
            let word = Self.words[rng.next(Self.words.count)]
            let separator = ["\n", "\r\n", "\u{2028}"][word.count % 3]
            text += word + (index < count - 1 || finalNewline ? separator : "")
        }
        return text
    }

    func testRevertingEveryHunkBackToFrontYieldsHead() {
        var rng = LCG(state: 0x5eed_cafe_f00d_beef)
        for iteration in 0..<3000 {
            let base = randomText(&rng, finalNewline: rng.next(2) == 0)
            let buffer = randomText(&rng, finalNewline: rng.next(2) == 0)
            let all = hunks(base: base, buffer: buffer)
            let context = "#\(iteration) base=\(String(reflecting: base)) buffer=\(String(reflecting: buffer))"

            var result = buffer
            for hunk in all.reversed() {
                guard let plan = HunkRevertPlan.plan(hunk: hunk, base: base, buffer: result) else {
                    XCTFail("no plan for \(hunk) \(context)")
                    return
                }
                result = apply(plan, to: result)
            }

            // A final newline differing on an unchanged last line is a hunk of
            // its own, so the answer is HEAD byte for byte without exception.
            XCTAssertEqual(result, base, context)
        }
    }

    /// A base of distinct lines and a buffer edited from it — lines kept in
    /// order, deleted, rewritten or inserted, every new line distinct too — so
    /// the diff's alignment is unique. A text built from repeated words has
    /// several equally long alignments, and reverting one hunk may legitimately
    /// make the diff pick another, which would test `LineDiff`'s tie-break
    /// rather than the revert.
    private func distinctPair(_ rng: inout LCG) -> (base: String, buffer: String) {
        func line(_ content: String, last: Bool, finalNewline: Bool) -> String {
            let separator = ["\n", "\r\n", "\u{2028}"][Int(content.unicodeScalars.last!.value) % 3]
            return content + (!last || finalNewline ? separator : "")
        }
        func join(_ lines: [String], finalNewline: Bool) -> String {
            lines.indices.map { line(lines[$0], last: $0 == lines.count - 1, finalNewline: finalNewline) }.joined()
        }
        let baseLines = (0..<rng.next(8)).map { "base\($0)" }
        var bufferLines: [String] = []
        var fresh = 0
        for baseLine in baseLines {
            if rng.next(6) == 0 { bufferLines.append("new\(fresh)"); fresh += 1 }
            switch rng.next(10) {
            case 0, 1: break
            case 2, 3: bufferLines.append("new\(fresh)"); fresh += 1
            default: bufferLines.append(baseLine)
            }
        }
        if rng.next(4) == 0 { bufferLines.append("new\(fresh)") }
        return (join(baseLines, finalNewline: rng.next(2) == 0), join(bufferLines, finalNewline: rng.next(2) == 0))
    }

    func testRevertingOneHunkLeavesTheOthersIntact() {
        var rng = LCG(state: 0x0dd_ba11_5ca1_ab1e)
        var checked = 0
        for iteration in 0..<3000 {
            let (base, buffer) = distinctPair(&rng)
            let all = hunks(base: base, buffer: buffer)
            guard all.count > 1 else { continue }
            checked += 1
            let pick = rng.next(all.count)
            let context = "#\(iteration) pick=\(pick) base=\(String(reflecting: base)) buffer=\(String(reflecting: buffer))"
            guard let plan = HunkRevertPlan.plan(hunk: all[pick], base: base, buffer: buffer) else {
                XCTFail("no plan \(context)")
                return
            }
            let reverted = all[pick]
            let delta = reverted.oldLines.count - reverted.newLines.count
            let expected = all.enumerated().compactMap { index, hunk -> ChangeHunk? in
                if index < pick { return hunk }
                if index == pick { return nil }
                let shifted = hunk.newLines.lowerBound + delta
                return ChangeHunk(
                    kind: hunk.kind,
                    newLines: shifted..<(shifted + hunk.newLines.count),
                    oldLines: hunk.oldLines
                )
            }
            XCTAssertEqual(hunks(base: base, buffer: apply(plan, to: buffer)), expected, context)
        }
        // The fuzz is only as good as the multi-hunk cases it actually reached.
        XCTAssertGreaterThan(checked, 500)
    }
}
