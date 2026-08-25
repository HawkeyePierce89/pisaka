import XCTest
@testable import PisakaCore

/// The acceptance list for the one save-time transform, written out case by
/// case: what each property changes, what it deliberately does not, how the
/// three compose, and where the caret, the selection and the scroll anchor land
/// afterwards.
///
/// Every assertion goes through `assertPlan`, which additionally re-checks the
/// two structural promises the view layer rests on — the replacements are
/// ascending and non-overlapping, and applying them back-to-front reproduces
/// `plan.text` — so a plan that is right about the bytes but wrong about the
/// edits cannot pass.
final class SaveTransformTests: XCTestCase {

    // MARK: - Helpers

    private func config(_ values: [String: String]) -> EditorConfigProperties {
        EditorConfigProperties(values)
    }

    /// Applies the plan the way the view must: back-to-front, so earlier ranges'
    /// offsets stay valid.
    private func apply(_ plan: SaveTransformPlan, to text: String) -> String {
        let result = NSMutableString(string: text)
        for edit in plan.replacements.reversed() {
            result.replaceCharacters(in: edit.range, with: edit.replacement)
        }
        return result as String
    }

    @discardableResult
    private func assertPlan(
        _ text: String,
        _ values: [String: String],
        protecting positions: [Int] = [],
        becomes expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> SaveTransformPlan {
        let plan = SaveTransform.plan(text: text, config: config(values), protectedPositions: positions)
        XCTAssertEqual(plan.text, expected, "resulting text", file: file, line: line)
        XCTAssertEqual(apply(plan, to: text), expected, "the edits must produce the text", file: file, line: line)
        XCTAssertEqual(plan.isEmpty, text == expected, "an empty plan iff nothing changed", file: file, line: line)

        var previousEnd = 0
        for edit in plan.replacements {
            XCTAssertGreaterThanOrEqual(edit.range.location, previousEnd, "ascending, non-overlapping", file: file, line: line)
            XCTAssertLessThanOrEqual(NSMaxRange(edit.range), (text as NSString).length, "in range", file: file, line: line)
            previousEnd = NSMaxRange(edit.range)
        }
        return plan
    }

    // MARK: - No configuration: the case that must change nothing

    func testAnEmptyPropertyMapChangesNothing() {
        let text = "a  \r\n\tb   \n\n   "
        let plan = assertPlan(text, [:], becomes: text)
        XCTAssertTrue(plan.isEmpty)
        XCTAssertTrue(plan.replacements.isEmpty)
    }

    func testAMapOfOnlyIndentationPropertiesChangesNothing() {
        // Part 1's three properties, all present, none of them a save-time one.
        let text = "func f() {\n\t\treturn 1   \n}   "
        let plan = assertPlan(
            text,
            ["indent_style": "space", "indent_size": "2", "tab_width": "8"],
            becomes: text
        )
        XCTAssertTrue(plan.isEmpty)
    }

    func testTheThreePropertiesSetToFalseOrUnrecognizedChangeNothing() {
        let text = "a   \r\nb   "
        assertPlan(
            text,
            ["trim_trailing_whitespace": "false", "insert_final_newline": "false", "end_of_line": "lfcr"],
            becomes: text
        )
        // `unset`, and a capitalization the parser did not produce, are equally
        // "absent rather than an error".
        assertPlan(text, ["trim_trailing_whitespace": "unset", "insert_final_newline": "TRUE"], becomes: text)
    }

    func testAnEmptyBufferIsUntouchedByEveryProperty() {
        assertPlan(
            "",
            ["trim_trailing_whitespace": "true", "insert_final_newline": "true", "end_of_line": "crlf"],
            becomes: ""
        )
    }

    // MARK: - `trim_trailing_whitespace`

    private let trim = ["trim_trailing_whitespace": "true"]

    func testTrimsSpacesTabsAndMixedRuns() {
        assertPlan("a  \nb\n", trim, becomes: "a\nb\n")
        assertPlan("a\t\t\nb\n", trim, becomes: "a\nb\n")
        assertPlan("a \t \t\nb\n", trim, becomes: "a\nb\n")
    }

    func testTrimsAWhitespaceOnlyLineToEmpty() {
        assertPlan("a\n   \nb\n", trim, becomes: "a\n\nb\n")
        assertPlan("a\n\t \nb\n", trim, becomes: "a\n\nb\n")
    }

    func testTrimsTheUnterminatedLastLineToo() {
        assertPlan("a\nb   ", trim, becomes: "a\nb")
        assertPlan("a\n   ", trim, becomes: "a\n")
        // A buffer that is nothing but whitespace becomes empty; nothing else
        // then puts a terminator back (see the final-newline cases below).
        assertPlan("   ", trim, becomes: "")
    }

    func testTrimsNothingWhenThereIsNoTrailingWhitespace() {
        assertPlan("a\nb\n", trim, becomes: "a\nb\n")
        // Leading and interior whitespace is content, not trailing whitespace.
        assertPlan("    a  b\n", trim, becomes: "    a  b\n")
    }

    func testTrimsEveryLineOfAMixedBuffer() {
        assertPlan(
            "one \ntwo\t\nthree\n\t\nfour  ",
            trim,
            becomes: "one\ntwo\nthree\n\nfour"
        )
    }

    // MARK: - The spared line

    func testTheCaretsLineKeepsItsTrailingWhitespace() {
        // "a  \n   \nb  " — the caret sits in the middle line's whitespace.
        let text = "a  \n   \nb  "
        assertPlan(text, trim, protecting: [5], becomes: "a\n   \nb")
    }

    func testTheSameBufferIsTrimmedOnceTheCaretHasMovedAway() {
        let text = "a  \n   \nb  "
        assertPlan(text, trim, protecting: [0], becomes: "a  \n\nb")
        assertPlan(text, trim, becomes: "a\n\nb")
    }

    func testACaretAtTheEndOfALinesContentSparesThatLineNotTheNext() {
        // Offset 3 is the end of "a  ", before the terminator: the case the rule
        // exists for — someone who just typed the indentation they are about to
        // type into.
        assertPlan("a  \nb  \n", trim, protecting: [3], becomes: "a  \nb\n")
    }

    func testACaretAtColumnZeroSparesOnlyItsOwnLine() {
        // Offset 4 is the start of the second line; the first line's trailing
        // whitespace is not under the caret and goes.
        assertPlan("a  \nb  \n", trim, protecting: [4], becomes: "a\nb  \n")
    }

    func testACaretAtEndOfAnUnterminatedFileSparesTheLastLine() {
        // The caret really is on `b  ` — there is no line after it — so this is
        // the case the sparing rule exists for: someone still typing that line.
        let text = "a  \nb  "
        assertPlan(text, trim, protecting: [(text as NSString).length], becomes: "a\nb  ")
    }

    func testACaretAtEndOfATerminatedFileSparesNothing() {
        // The other end of the text. `b  ` is terminated, so the caret sits on the
        // empty line *after* it — a line `TerminatedLines` deliberately does not
        // emit — and `b  ` is a line the caret has already left. Sparing it would
        // protect a run nobody is typing, and (since the tab is written clean) owe
        // a trim on every autosave tick for as long as the caret rested there.
        let text = "a  \nb  \n"
        let plan = assertPlan(text, trim, protecting: [(text as NSString).length], becomes: "a\nb\n")
        XCTAssertFalse(plan.deferredTrim, "nothing was spared, so nothing is owed")
    }

    func testACaretOnTheLastLinesContentEndStillSparesItWhenTerminated() {
        // One offset earlier than the case above, and the answer flips back: this
        // caret *is* on `b  `, at the end of its content, which is precisely the
        // position the rule protects.
        let plan = assertPlan("a  \nb  \n", trim, protecting: [7], becomes: "a\nb  \n")
        XCTAssertTrue(plan.deferredTrim)
    }

    func testBothSelectionEndpointsSpareTheirLines() {
        // A selection running from the first line into the third spares both
        // ends; the line between them is not protected by anything.
        assertPlan("a  \nb  \nc  \n", trim, protecting: [1, 9], becomes: "a  \nb\nc  \n")
    }

    func testNoProtectedPositionsTrimsInFull() {
        // The shape the iOS save and every closed-tab save take.
        assertPlan("a  \nb  \nc  ", trim, protecting: [], becomes: "a\nb\nc")
    }

    func testTheSparedLineIsSparedFromTrimmingOnly() {
        // The caret neither stops a terminator from being normalized nor stops
        // the final newline: neither can delete something just typed.
        assertPlan(
            "a  \r\nb  ",
            ["trim_trailing_whitespace": "true", "insert_final_newline": "true", "end_of_line": "lf"],
            protecting: [1],
            becomes: "a  \nb\n"
        )
    }

    // MARK: - `insert_final_newline`

    private let finalNewline = ["insert_final_newline": "true"]

    func testAppendsTheFilesOwnTerminatorFlavor() {
        assertPlan("a\nb", finalNewline, becomes: "a\nb\n")
        assertPlan("a\r\nb", finalNewline, becomes: "a\r\nb\r\n")
        assertPlan("a\rb", finalNewline, becomes: "a\rb\r")
    }

    /// A separator `end_of_line` cannot name is *not* the file's own answer:
    /// appending one would leave the file with no final newline by every
    /// reckoning outside this editor's splitter, and the next save — seeing a
    /// terminator — would append nothing, so the property would never be
    /// satisfied for that file again. LF is the answer instead, and the unnamed
    /// separators already in the text are still left exactly as they are.
    func testAppendsLFRatherThanASeparatorEndOfLineCannotName() {
        assertPlan("a\u{2028}b", finalNewline, becomes: "a\u{2028}b\n")
        assertPlan("a\u{2029}b", finalNewline, becomes: "a\u{2029}b\n")
        assertPlan("a\u{0085}b", finalNewline, becomes: "a\u{0085}b\n")
    }

    func testAppendsLFWhenTheFileHasNoTerminatorOfItsOwn() {
        assertPlan("a", finalNewline, becomes: "a\n")
    }

    func testAppendsTheConfiguredTerminatorWhenEndOfLineStatesOne() {
        assertPlan("a\nb", finalNewline.merging(["end_of_line": "crlf"]) { _, new in new }, becomes: "a\r\nb\r\n")
        assertPlan("a", finalNewline.merging(["end_of_line": "cr"]) { _, new in new }, becomes: "a\r")
    }

    func testNeverDoublesAnExistingFinalTerminator() {
        assertPlan("a\nb\n", finalNewline, becomes: "a\nb\n")
        assertPlan("a\r\n", finalNewline, becomes: "a\r\n")
        assertPlan("a\n\n", finalNewline, becomes: "a\n\n")
        assertPlan("a\u{0085}", finalNewline, becomes: "a\u{0085}")
    }

    func testNeverRemovesATerminatorAndDoesNothingWhenFalseOrAbsent() {
        assertPlan("a\n\n\n", ["insert_final_newline": "false"], becomes: "a\n\n\n")
        assertPlan("a", ["insert_final_newline": "false"], becomes: "a")
        assertPlan("a", ["insert_final_newline": "unset"], becomes: "a")
    }

    func testAnEmptyBufferGainsNoTerminator() {
        assertPlan("", finalNewline, becomes: "")
    }

    func testALastLineTrimmingEmptiesIsNotThenTerminatedAgain() {
        // "a\n   " trims to "a\n", which already ends in a terminator: composing
        // the two in the stated order must not leave "a\n\n".
        assertPlan("a\n   ", trim.merging(finalNewline) { _, new in new }, becomes: "a\n")
        // …and a buffer that trimming empties entirely stays empty.
        assertPlan("   ", trim.merging(finalNewline) { _, new in new }, becomes: "")
    }

    func testATrimmedButNonEmptyLastLineIsTerminated() {
        assertPlan("a\nb   ", trim.merging(finalNewline) { _, new in new }, becomes: "a\nb\n")
    }

    /// A last line the caret spared is *not* terminated when trimming would have
    /// emptied it: the final-terminator decision reads the trim the configuration
    /// asks for, not the one this caret position allowed.
    ///
    /// Otherwise sparing would stop being a deferral. Terminating "a\\n   " while
    /// the caret sits on it gives "a\\n   \\n", the next save (caret moved away)
    /// trims to "a\\n\\n", and that is a *fixed point* — a blank line nobody typed,
    /// kept forever, on a buffer that reaches "a\\n" from any other caret position.
    func testASparedLastLineTrimmingWouldEmptyIsNotTerminated() {
        let both = trim.merging(finalNewline) { _, new in new }
        let text = "a\n   "
        // Spared: the whitespace survives this save, and nothing is appended.
        assertPlan(text, both, protecting: [(text as NSString).length], becomes: text)
        // The caret moves away and the deferred trim happens — reaching exactly
        // the same bytes the unspared save reaches in one step.
        assertPlan(text, both, becomes: "a\n")
    }

    /// A spared last line that still holds content *is* terminated: trimming it
    /// would leave "b", not nothing, so the file genuinely lacks a final
    /// terminator either way.
    func testASparedLastLineWithContentIsStillTerminated() {
        let text = "a\nb   "
        assertPlan(
            text,
            trim.merging(finalNewline) { _, new in new },
            protecting: [(text as NSString).length],
            becomes: "a\nb   \n"
        )
    }

    // MARK: - `end_of_line`

    func testNormalizesToLF() {
        assertPlan("a\nb\nc", ["end_of_line": "lf"], becomes: "a\nb\nc")
        assertPlan("a\r\nb\r\nc", ["end_of_line": "lf"], becomes: "a\nb\nc")
        assertPlan("a\rb\rc", ["end_of_line": "lf"], becomes: "a\nb\nc")
        assertPlan("a\r\nb\rc\nd", ["end_of_line": "lf"], becomes: "a\nb\nc\nd")
    }

    func testNormalizesToCRLF() {
        assertPlan("a\nb\nc", ["end_of_line": "crlf"], becomes: "a\r\nb\r\nc")
        assertPlan("a\r\nb\r\nc", ["end_of_line": "crlf"], becomes: "a\r\nb\r\nc")
        assertPlan("a\rb\rc", ["end_of_line": "crlf"], becomes: "a\r\nb\r\nc")
        assertPlan("a\r\nb\rc\nd", ["end_of_line": "crlf"], becomes: "a\r\nb\r\nc\r\nd")
    }

    func testNormalizesToCR() {
        assertPlan("a\nb\nc", ["end_of_line": "cr"], becomes: "a\rb\rc")
        assertPlan("a\r\nb\r\nc", ["end_of_line": "cr"], becomes: "a\rb\rc")
        assertPlan("a\rb\rc", ["end_of_line": "cr"], becomes: "a\rb\rc")
        assertPlan("a\r\nb\rc\nd", ["end_of_line": "cr"], becomes: "a\rb\rc\rd")
    }

    func testAnUnrecognizedEndOfLineNormalizesNothing() {
        assertPlan("a\r\nb\rc\n", ["end_of_line": "dos"], becomes: "a\r\nb\rc\n")
    }

    func testTheCRLFPairIsOneTerminatorNotTwo() {
        // Splitting the pair would yield "a\n\nb" (two empty-terminator
        // replacements) instead of "a\nb".
        let plan = assertPlan("a\r\nb", ["end_of_line": "lf"], becomes: "a\nb")
        XCTAssertEqual(plan.replacements.count, 1)
        XCTAssertEqual(plan.replacements[0].range, NSRange(location: 1, length: 2))
    }

    // MARK: - The stated limit: NEL, LS and PS

    func testTheThreeUnnamedSeparatorsSurviveEveryCombination() {
        let text = "a \u{0085}b\t\u{2028}c \u{2029}d\r\n"
        for target in ["lf", "cr", "crlf"] {
            assertPlan(text, ["end_of_line": target], becomes: "a \u{0085}b\t\u{2028}c \u{2029}d" + terminator(target))
        }
        assertPlan(text, trim, becomes: "a\u{0085}b\u{2028}c\u{2029}d\r\n")
        assertPlan(
            text,
            ["trim_trailing_whitespace": "true", "insert_final_newline": "true", "end_of_line": "lf"],
            becomes: "a\u{0085}b\u{2028}c\u{2029}d\n"
        )
        // And an unterminated file ending on one of them keeps it.
        assertPlan("a\u{2029}b", ["end_of_line": "lf"], becomes: "a\u{2029}b")
    }

    private func terminator(_ value: String) -> String {
        EditorConfigProperties.EndOfLine(rawValue: value)?.terminator ?? ""
    }

    // MARK: - Composition

    func testAllThreeComposeInTheStatedOrder() {
        let text = "one  \r\ntwo\t\rthree \n\r\nfour   "
        assertPlan(
            text,
            ["trim_trailing_whitespace": "true", "insert_final_newline": "true", "end_of_line": "lf"],
            becomes: "one\ntwo\nthree\n\nfour\n"
        )
    }

    // MARK: - The remap

    func testAnOffsetBeforeEveryEditIsUnchanged() {
        let plan = SaveTransform.plan(text: "aa\r\nbb", config: config(["end_of_line": "lf"]))
        XCTAssertEqual(plan.remappedOffset(0), 0)
        XCTAssertEqual(plan.remappedOffset(1), 1)
        // At the edit's start counts as before it.
        XCTAssertEqual(plan.remappedOffset(2), 2)
    }

    func testOffsetsShiftAcrossAShrinkingEdit() {
        // "aa\r\nbb\r\ncc" → "aa\nbb\ncc": two two-unit ranges become one each.
        let plan = SaveTransform.plan(text: "aa\r\nbb\r\ncc", config: config(["end_of_line": "lf"]))
        XCTAssertEqual(plan.text, "aa\nbb\ncc")
        XCTAssertEqual(plan.remappedOffset(4), 3)   // just after the first pair
        XCTAssertEqual(plan.remappedOffset(6), 5)   // start of the second pair
        XCTAssertEqual(plan.remappedOffset(8), 6)   // just after it
        XCTAssertEqual(plan.remappedOffset(10), 8)  // end of file
    }

    func testAnOffsetInsideAShrinkingEditIsClampedIntoTheReplacement() {
        let plan = SaveTransform.plan(text: "aa\r\nbb", config: config(["end_of_line": "lf"]))
        // Between the CR and the LF: the replacement is one unit long, so the
        // offset lands at its end rather than anywhere undefined.
        XCTAssertEqual(plan.remappedOffset(3), 3)
        XCTAssertEqual(plan.text, "aa\nbb")
    }

    func testOffsetsInsideADeletionCollapseToItsStart() {
        // "a   \nb  " → "a\nb": both trims are pure deletions.
        let plan = SaveTransform.plan(text: "a   \nb  ", config: config(trim))
        XCTAssertEqual(plan.text, "a\nb")
        XCTAssertEqual(plan.remappedOffset(1), 1)
        XCTAssertEqual(plan.remappedOffset(2), 1)
        XCTAssertEqual(plan.remappedOffset(3), 1)
        XCTAssertEqual(plan.remappedOffset(4), 1)
        XCTAssertEqual(plan.remappedOffset(5), 2)
        XCTAssertEqual(plan.remappedOffset(7), 3)
        XCTAssertEqual(plan.remappedOffset(8), 3)
    }

    func testOffsetsShiftAcrossAGrowingEdit() {
        // "aa\nbb" → "aa\r\nbb".
        let plan = SaveTransform.plan(text: "aa\nbb", config: config(["end_of_line": "crlf"]))
        XCTAssertEqual(plan.text, "aa\r\nbb")
        XCTAssertEqual(plan.remappedOffset(2), 2)
        XCTAssertEqual(plan.remappedOffset(3), 4)
        XCTAssertEqual(plan.remappedOffset(5), 6)
    }

    func testTheAppendedTerminatorLeavesTheCaretAtTheEndOfTheText() {
        // The one insertion this engine emits is zero-length and sits at end of
        // file: a caret there must not be pushed onto the new empty line.
        let plan = SaveTransform.plan(text: "abc", config: config(finalNewline))
        XCTAssertEqual(plan.text, "abc\n")
        XCTAssertEqual(plan.remappedOffset(3), 3)
        XCTAssertEqual(plan.remappedOffset(0), 0)
    }

    func testRangesRemapThroughTheirTwoEnds() {
        let plan = SaveTransform.plan(text: "a   \nb  \nc", config: config(trim))
        XCTAssertEqual(plan.text, "a\nb\nc")
        // A selection spanning both trims shrinks by both.
        XCTAssertEqual(plan.remappedRange(NSRange(location: 0, length: 10)), NSRange(location: 0, length: 5))
        // A selection wholly inside one trim collapses to a caret.
        XCTAssertEqual(plan.remappedRange(NSRange(location: 2, length: 2)), NSRange(location: 1, length: 0))
        // An untouched selection keeps its length.
        XCTAssertEqual(plan.remappedRange(NSRange(location: 5, length: 1)), NSRange(location: 2, length: 1))
    }

    /// The pair the macOS funnel actually remaps for a viewport: every selected
    /// range through `remappedRange`, the scroll anchor through `remappedOffset`.
    /// There is deliberately no whole-`EditorViewport` convenience — the editor's
    /// column selection is several ranges, which one viewport cannot carry.
    func testASelectionAndAScrollAnchorRemapTogether() {
        let plan = SaveTransform.plan(text: "aa\r\nbb\r\ncc", config: config(["end_of_line": "lf"]))
        XCTAssertEqual(plan.remappedRange(NSRange(location: 4, length: 4)), NSRange(location: 3, length: 3))
        XCTAssertEqual(plan.remappedOffset(8), 6)
    }

    func testAnAbsentSelectionIsNotInventedAPosition() {
        let plan = SaveTransform.plan(text: "a   \n", config: config(trim))
        XCTAssertEqual(plan.remappedOffset(NSNotFound), NSNotFound)
        let absent = NSRange(location: NSNotFound, length: 0)
        XCTAssertEqual(plan.remappedRange(absent), absent)
    }

    func testAnEmptyPlanRemapsEveryPositionToItself() {
        let plan = SaveTransform.plan(text: "a\nb\n", config: config([:]))
        for offset in 0...4 {
            XCTAssertEqual(plan.remappedOffset(offset), offset)
        }
    }

    // MARK: - The deferred trim a spared line records

    func testASparedRunIsReportedAsADeferredTrim() {
        // The whole point of the flag: this plan is *empty*, so nothing but the
        // flag can tell "already conforming" from "owes a trim".
        let plan = SaveTransform.plan(text: "a  ", config: config(trim), protectedPositions: [0])
        XCTAssertTrue(plan.isEmpty)
        XCTAssertTrue(plan.deferredTrim)
    }

    func testASparedLineWithNothingToTrimDefersNothing() {
        // A caret on a line that carries no trailing run owes nothing, and must
        // not put its buffer on the re-offer list forever.
        let plan = SaveTransform.plan(text: "a\nb  \n", config: config(trim), protectedPositions: [0])
        XCTAssertEqual(plan.text, "a\nb\n")
        XCTAssertFalse(plan.deferredTrim)
    }

    func testANonEmptyPlanStillReportsTheRunItSpared() {
        // Other lines trimmed, the caret's line kept: both halves are true at once.
        let plan = SaveTransform.plan(text: "a  \nb  \n", config: config(trim), protectedPositions: [0])
        XCTAssertEqual(plan.text, "a  \nb\n")
        XCTAssertTrue(plan.deferredTrim)
    }

    func testTheDeferredTrimClearsOnceTheCaretHasMovedAway() {
        let first = SaveTransform.plan(text: "a  \nb\n", config: config(trim), protectedPositions: [0])
        XCTAssertTrue(first.deferredTrim)
        let second = SaveTransform.plan(text: first.text, config: config(trim), protectedPositions: [5])
        XCTAssertEqual(second.text, "a\nb\n")
        XCTAssertFalse(second.deferredTrim)
    }

    func testAConfigurationThatDoesNotTrimDefersNothing() {
        let plan = SaveTransform.plan(
            text: "a  \n",
            config: config(["insert_final_newline": "true"]),
            protectedPositions: [0]
        )
        XCTAssertFalse(plan.deferredTrim)
    }

    func testAnAbandonedBufferPassesNoPositionsAndDefersNothing() {
        // What the quit flush, the folder switch and the close prompt do: no
        // protected positions at all, so the file is trimmed in full and owes
        // nothing afterwards.
        let plan = SaveTransform.plan(text: "a  \nb  ", config: config(trim))
        XCTAssertEqual(plan.text, "a\nb")
        XCTAssertFalse(plan.deferredTrim)
    }

    // MARK: - `rewrites(under:)`, the pre-filter callers ask before doing work

    func testRewritesIsFalseForAConfigurationStatingNoneOfTheThree() {
        XCTAssertFalse(SaveTransform.rewrites(under: config([:])))
        XCTAssertFalse(SaveTransform.rewrites(under: config(["indent_style": "space", "indent_size": "2"])))
        // Explicit `false` is a stated answer, and the stated answer is "change
        // nothing" — the same as absence, for this question.
        XCTAssertFalse(SaveTransform.rewrites(under: config([
            "trim_trailing_whitespace": "false",
            "insert_final_newline": "false",
        ])))
    }

    func testRewritesIsTrueForEachOfTheThreeOnItsOwn() {
        XCTAssertTrue(SaveTransform.rewrites(under: config(["end_of_line": "lf"])))
        XCTAssertTrue(SaveTransform.rewrites(under: config(trim)))
        XCTAssertTrue(SaveTransform.rewrites(under: config(["insert_final_newline": "true"])))
    }

    func testRewritesAgreesWithThePlanItGuards() {
        // The contract that makes it safe as a pre-filter: `false` here means an
        // empty plan for *any* text and *any* caret, so a caller may skip the work
        // it would have to do before it could call `plan` at all.
        let texts = ["", "a", "a  \r\n b \rc  ", "\n\n", "a\r\n"]
        let configurations: [[String: String]] = [
            [:],
            ["indent_style": "tab"],
            ["trim_trailing_whitespace": "false", "insert_final_newline": "false", "indent_size": "4"],
        ]
        for values in configurations {
            XCTAssertFalse(SaveTransform.rewrites(under: config(values)), "\(values)")
            for text in texts {
                let plan = SaveTransform.plan(
                    text: text,
                    config: config(values),
                    protectedPositions: [0, (text as NSString).length]
                )
                XCTAssertTrue(plan.isEmpty, "\(String(reflecting: text)) under \(values)")
                XCTAssertEqual(plan.text, text)
                XCTAssertFalse(plan.deferredTrim)
            }
        }
    }

    // MARK: - The protected positions a selection contributes

    func testABareCaretContributesItsOwnLocationOnly() {
        XCTAssertEqual(
            SaveTransform.protectedPositions(forSelectedRanges: [NSRange(location: 7, length: 0)]),
            [7]
        )
    }

    func testASelectionContributesBothOfItsEndpoints() {
        XCTAssertEqual(
            SaveTransform.protectedPositions(forSelectedRanges: [NSRange(location: 3, length: 5)]),
            [3, 8]
        )
    }

    func testEveryRangeOfAColumnSelectionContributes() {
        // The middle-drag column selection: several carets at once, each of which
        // an autosave must spare.
        let ranges = [
            NSRange(location: 2, length: 0),
            NSRange(location: 9, length: 3),
            NSRange(location: 20, length: 0),
        ]
        XCTAssertEqual(SaveTransform.protectedPositions(forSelectedRanges: ranges), [2, 9, 12, 20])
    }

    func testAnAbsentRangeContributesNothing() {
        XCTAssertEqual(
            SaveTransform.protectedPositions(forSelectedRanges: [NSRange(location: NSNotFound, length: 0)]),
            []
        )
        XCTAssertEqual(SaveTransform.protectedPositions(forSelectedRanges: []), [])
    }

    func testAPositionNamingNoOffsetSparesNoLine() {
        // `NSNotFound`, a negative and an offset past the end all name no
        // position, so none of them may quietly spare a line: the buffer is
        // trimmed exactly as it is with no protected positions at all.
        let text = "a  \nb  "
        assertPlan(text, trim, protecting: [NSNotFound], becomes: "a\nb")
        assertPlan(text, trim, protecting: [-1], becomes: "a\nb")
        // Past the end is the one that still resolves: it belongs to the last
        // line, which is where a caret at end of file is.
        assertPlan(text, trim, protecting: [(text as NSString).length + 5], becomes: "a\nb  ")
    }

    // MARK: - Characters outside the BMP

    func testTheEngineCountsUTF16UnitsNotCharacters() {
        // Every offset below is a UTF-16 offset, and each emoji is two units —
        // the one input class that tells `NSString` arithmetic apart from
        // `Character` arithmetic.
        //  0 1 2 3 4  5 6 7  8 9
        // "🙂 🙂 _ _ \r \n 🙃 🙃 \t"
        let plan = assertPlan(
            "🙂  \r\n🙃\t",
            ["trim_trailing_whitespace": "true", "insert_final_newline": "true", "end_of_line": "lf"],
            becomes: "🙂\n🙃\n"
        )
        // Before the first edit: unchanged. Between the surrogates of the second
        // emoji: still between them, because nothing before it moved by an odd
        // amount.
        XCTAssertEqual(plan.remappedOffset(0), 0)
        XCTAssertEqual(plan.remappedOffset(2), 2)
        // After both the trimmed run and the CRLF→LF collapse: three units gone.
        XCTAssertEqual(plan.remappedOffset(6), 3)
        XCTAssertEqual(plan.remappedOffset(8), 5)
    }

    // MARK: - The shape the edits are handed over in

    /// Applying `replacements` one by one is quadratic in the file when the run
    /// is dense, so the plan offers the single replacement covering them instead
    /// — and whichever shape it offers must produce `text` byte for byte.
    private func applying(_ edits: [IndentReplacement], to text: String) -> String {
        let result = NSMutableString(string: text)
        for edit in edits.reversed() {
            result.replaceCharacters(in: edit.range, with: edit.replacement)
        }
        return result as String
    }

    func testAScatteredRunIsHandedOverAsItsOwnEdits() {
        let text = "a  " + String(repeating: "\n", count: 400) + "b  "
        let plan = SaveTransform.plan(text: text, config: config(trim))
        XCTAssertEqual(plan.replacements.count, 2)
        XCTAssertEqual(plan.applicableReplacements(originalLength: (text as NSString).length), plan.replacements)
    }

    func testADenseRunCollapsesIntoTheOneReplacementCoveringIt() {
        let text = String(repeating: "a\r\n", count: 200)
        let plan = SaveTransform.plan(text: text, config: config(["end_of_line": "lf"]))
        XCTAssertEqual(plan.replacements.count, 200)
        let edits = plan.applicableReplacements(originalLength: (text as NSString).length)
        XCTAssertEqual(edits.count, 1)
        XCTAssertEqual(applying(edits, to: text), plan.text)
    }

    /// The regression the collapsed span used to have: `insert_final_newline`
    /// emits a **zero-length insertion at end of file**, and `remappedOffset`
    /// deliberately reads an offset at an edit's start as *before* it — so a span
    /// ending at the remapped end of file stopped short of the inserted
    /// terminator and the save dropped the final newline the configuration asked
    /// for. The buffer was then clean, so nothing came back for it.
    func testACollapsedRunKeepsTheFinalNewlineItInserts() {
        let text = "a \r\nb "
        let plan = SaveTransform.plan(
            text: text,
            config: config(["trim_trailing_whitespace": "true", "insert_final_newline": "true", "end_of_line": "lf"])
        )
        XCTAssertEqual(plan.text, "a\nb\n")
        let edits = plan.applicableReplacements(originalLength: (text as NSString).length)
        XCTAssertEqual(edits.count, 1)
        XCTAssertEqual(applying(edits, to: text), "a\nb\n")
    }

    func testAnEmptyPlanHandsOverNoEdits() {
        let plan = SaveTransform.plan(text: "a\nb\n", config: config([:]))
        XCTAssertEqual(plan.applicableReplacements(originalLength: 4), [])
    }

    /// Whichever branch the cost comparison picks, the bytes are the plan's.
    func testEitherShapeReproducesThePlansText() {
        let texts = [
            "one  \r\ntwo\t\rthree \n\r\nfour   ",
            "a \u{0085}b\t\u{2028}c \u{2029}d\r\n",
            "\n\n   \n",
            "   ",
            "a",
            "a\r\n\r\n  b",
            "🙂  \r\n🙃\t",
            String(repeating: "x \r\n", count: 50) + "tail",
        ]
        let configurations: [[String: String]] = [
            ["trim_trailing_whitespace": "true"],
            ["insert_final_newline": "true"],
            ["end_of_line": "lf"],
            ["end_of_line": "crlf"],
            ["end_of_line": "cr"],
            ["trim_trailing_whitespace": "true", "insert_final_newline": "true", "end_of_line": "lf"],
            ["trim_trailing_whitespace": "true", "insert_final_newline": "true", "end_of_line": "crlf"],
            ["trim_trailing_whitespace": "true", "insert_final_newline": "true", "end_of_line": "cr"],
        ]
        for text in texts {
            for values in configurations {
                let plan = SaveTransform.plan(text: text, config: config(values))
                let edits = plan.applicableReplacements(originalLength: (text as NSString).length)
                XCTAssertEqual(
                    applying(edits, to: text),
                    plan.text,
                    "\(String(reflecting: text)) under \(values)"
                )
            }
        }
    }

    // MARK: - Idempotence

    func testTheComposedTransformIsIdempotent() {
        let texts = [
            "one  \r\ntwo\t\rthree \n\r\nfour   ",
            "a \u{0085}b\t\u{2028}c \u{2029}d\r\n",
            "\n\n   \n",
            "   ",
            "",
            "a",
            "a\r\n\r\n  b",
        ]
        let configurations: [[String: String]] = [
            ["trim_trailing_whitespace": "true"],
            ["insert_final_newline": "true"],
            ["end_of_line": "lf"],
            ["end_of_line": "crlf"],
            ["end_of_line": "cr"],
            ["trim_trailing_whitespace": "true", "insert_final_newline": "true", "end_of_line": "lf"],
            ["trim_trailing_whitespace": "true", "insert_final_newline": "true", "end_of_line": "crlf"],
            ["trim_trailing_whitespace": "true", "insert_final_newline": "true", "end_of_line": "cr"],
        ]
        for text in texts {
            for values in configurations {
                let positions = [0, 1, (text as NSString).length]
                let first = SaveTransform.plan(text: text, config: config(values), protectedPositions: positions)
                let second = SaveTransform.plan(
                    text: first.text,
                    config: config(values),
                    protectedPositions: positions.map(first.remappedOffset)
                )
                XCTAssertTrue(
                    second.isEmpty,
                    "\(String(reflecting: text)) under \(values) still had \(second.replacements.count) edits"
                )
                XCTAssertEqual(second.text, first.text)
            }
        }
    }
}
