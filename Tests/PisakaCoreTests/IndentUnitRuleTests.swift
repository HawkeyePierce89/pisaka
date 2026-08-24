import XCTest
@testable import PisakaCore

/// Tests for the two indentation answers — what one level *is*, and what the Tab
/// key inserts — and for the multi-insertion-point arithmetic behind the key.
///
/// The matrix is written out in full on purpose: each case names which half the
/// configuration supplies and which half the content inference does, because the
/// hybrid rule is exactly the seam where the two meet.
final class IndentUnitRuleTests: XCTestCase {

    // MARK: - Helpers

    private func config(_ values: [String: String]) -> EditorConfigProperties {
        EditorConfigProperties(values)
    }

    /// Applies a plan the way the view must: back-to-front, so earlier ranges'
    /// offsets stay valid.
    private func apply(_ plan: TabInsertionPlan, to text: String) -> String {
        let result = NSMutableString(string: text)
        for replacement in plan.replacements.reversed() {
            result.replaceCharacters(in: replacement.range, with: replacement.replacement)
        }
        return result as String
    }

    // MARK: - The unit: `indent_style = tab`

    func testStyleTabIsATabWhateverTheFileLooksLike() {
        let config = config(["indent_style": "tab"])
        XCTAssertEqual(IndentUnitRule.unit(config: config, inferred: "\t"), "\t")
        XCTAssertEqual(IndentUnitRule.unit(config: config, inferred: "  "), "\t")
    }

    func testStyleTabIgnoresAConfiguredWidth() {
        // A width describes how a tab is *displayed*, never what is inserted.
        let config = config(["indent_style": "tab", "indent_size": "4", "tab_width": "8"])
        XCTAssertEqual(IndentUnitRule.unit(config: config, inferred: "  "), "\t")
    }

    // MARK: - The unit: `indent_style = space`

    func testStyleSpaceWithIndentSizeBeatsBothInferences() {
        let config = config(["indent_style": "space", "indent_size": "2"])
        XCTAssertEqual(IndentUnitRule.unit(config: config, inferred: "\t"), "  ")
        XCTAssertEqual(IndentUnitRule.unit(config: config, inferred: "        "), "  ")
    }

    func testStyleSpaceTakesItsWidthFromTabWidthWhenIndentSizeIsAbsent() {
        let config = config(["indent_style": "space", "tab_width": "3"])
        XCTAssertEqual(IndentUnitRule.unit(config: config, inferred: "\t"), "   ")
    }

    func testStyleSpaceWithIndentSizeTabTakesTheExplicitTabWidth() {
        let config = config(["indent_style": "space", "indent_size": "tab", "tab_width": "8"])
        XCTAssertEqual(IndentUnitRule.unit(config: config, inferred: "  "), "        ")
    }

    func testStyleSpaceWithIndentSizeTabAndNoTabWidthFallsBackToTheInferredWidth() {
        let config = config(["indent_style": "space", "indent_size": "tab"])
        XCTAssertEqual(IndentUnitRule.unit(config: config, inferred: "  "), "  ")
    }

    func testStyleSpaceWithNoWidthUsesTheInferredWidthWhenTheInferenceIsSpaces() {
        let config = config(["indent_style": "space"])
        XCTAssertEqual(IndentUnitRule.unit(config: config, inferred: "   "), "   ")
    }

    func testStyleSpaceWithNoWidthFallsBackToFourWhenTheInferenceIsATab() {
        // There is no width to carry over from a tab, so the rule states one.
        let config = config(["indent_style": "space"])
        XCTAssertEqual(IndentUnitRule.unit(config: config, inferred: "\t"), "    ")
    }

    func testAnUnrecognizedStyleIsTreatedAsAbsent() {
        let config = config(["indent_style": "spaces"])
        XCTAssertEqual(IndentUnitRule.unit(config: config, inferred: "\t"), "\t")
    }

    // MARK: - The unit: a width with no style

    func testAConfiguredWidthReWidensASpaceInference() {
        let config = config(["indent_size": "2"])
        XCTAssertEqual(IndentUnitRule.unit(config: config, inferred: "        "), "  ")
    }

    func testAConfiguredWidthLeavesATabInferenceATab() {
        // A width alone never converts a tab-indented file to spaces.
        XCTAssertEqual(IndentUnitRule.unit(config: config(["indent_size": "2"]), inferred: "\t"), "\t")
        XCTAssertEqual(IndentUnitRule.unit(config: config(["tab_width": "2"]), inferred: "\t"), "\t")
    }

    func testARejectedWidthIsNoWidthAtAll() {
        // `0`, negatives and non-numbers are absent, not errors — the inference
        // answers untouched.
        for raw in ["0", "-2", "two", ""] {
            XCTAssertEqual(IndentUnitRule.unit(config: config(["indent_size": raw]), inferred: "  "), "  ")
        }
    }

    func testAnAbsurdWidthIsClampedRatherThanAllocated() {
        // `indent_size` is any positive integer to the parser, and the unit is
        // built as a string on the main thread for every Enter and every Tab. An
        // untrusted config asking for two billion columns must not allocate two
        // gigabytes per keystroke; a merely-large width still behaves large.
        let huge = IndentUnitRule.unit(config: config(["indent_style": "space", "indent_size": "2000000000"]),
                                       inferred: "  ")
        XCTAssertEqual(huge.count, IndentUnitRule.maximumSpaceWidth)
        XCTAssertEqual(
            IndentUnitRule.unit(config: config(["indent_style": "space", "indent_size": "8"]), inferred: "  "),
            String(repeating: " ", count: 8)
        )
    }

    // MARK: - The unit: nothing applicable

    func testEmptyPropertiesReturnTheInferenceUnchanged() {
        XCTAssertEqual(IndentUnitRule.unit(config: config([:]), inferred: "\t"), "\t")
        XCTAssertEqual(IndentUnitRule.unit(config: config([:]), inferred: "   "), "   ")
        XCTAssertEqual(IndentUnitRule.unit(config: config(["charset": "utf-8"]), inferred: "  "), "  ")
    }

    // MARK: - The Tab key

    func testTabInsertsSpacesOnlyWhenTheConfigurationSaysSpace() {
        let config = config(["indent_style": "space", "indent_size": "2"])
        XCTAssertEqual(IndentUnitRule.tabInsertion(config: config, inferred: "\t"), "  ")
        XCTAssertEqual(IndentUnitRule.tabInsertion(config: config, inferred: "    "), "  ")
    }

    func testTabStaysATabWithNoConfiguration() {
        // The whole point of the stricter rule: a project without `.editorconfig`
        // keeps inserting a literal tab, whatever its content looks like.
        XCTAssertEqual(IndentUnitRule.tabInsertion(config: config([:]), inferred: "    "), "\t")
        XCTAssertEqual(IndentUnitRule.tabInsertion(config: config([:]), inferred: "\t"), "\t")
    }

    func testTabStaysATabForStyleTabAndForAWidthWithNoStyle() {
        XCTAssertEqual(
            IndentUnitRule.tabInsertion(config: config(["indent_style": "tab"]), inferred: "  "), "\t"
        )
        XCTAssertEqual(
            IndentUnitRule.tabInsertion(config: config(["indent_size": "2"]), inferred: "    "), "\t"
        )
    }

    func testTabUsesTheHybridWidthWhenTheStyleIsSpace() {
        // The inference supplies the width the configuration omits, exactly as
        // it does for Enter.
        XCTAssertEqual(
            IndentUnitRule.tabInsertion(config: config(["indent_style": "space"]), inferred: "   "), "   "
        )
    }

    // MARK: - The insertion plan

    func testAnEmptySelectionListAnswersNoEdits() {
        XCTAssertEqual(IndentUnitRule.tabInsertionPlan(ranges: [], insertion: "  "), .empty)
        XCTAssertTrue(IndentUnitRule.tabInsertionPlan(ranges: [], insertion: "  ").isEmpty)
    }

    func testOneCaretInsertsAtItAndLeavesTheCaretAfterTheInsertion() {
        let text = "let x = 1"
        let plan = IndentUnitRule.tabInsertionPlan(ranges: [NSRange(location: 0, length: 0)], insertion: "  ")

        XCTAssertEqual(apply(plan, to: text), "  let x = 1")
        XCTAssertEqual(plan.carets, [NSRange(location: 2, length: 0)])
    }

    func testOneNonEmptyRangeIsReplacedJustAsASingleReplacementWouldBe() {
        // The parity claim for the single-range case, checked as arithmetic
        // rather than by eyeballing the view: the plan reproduces exactly what
        // one `replaceCharacters` would have produced.
        let text = "let x = 1"
        let range = NSRange(location: 4, length: 1)
        let plan = IndentUnitRule.tabInsertionPlan(ranges: [range], insertion: "    ")

        let expected = NSMutableString(string: text)
        expected.replaceCharacters(in: range, with: "    ")
        XCTAssertEqual(apply(plan, to: text), expected as String)
        XCTAssertEqual(plan.carets, [NSRange(location: 8, length: 0)])
    }

    func testSeveralCaretsOnConsecutiveLinesEachGetTheirOwnInsertion() {
        // The column-selection shape: three zero-width carets, one per line.
        let text = "aa\nbb\ncc"
        let plan = IndentUnitRule.tabInsertionPlan(
            ranges: [
                NSRange(location: 0, length: 0),
                NSRange(location: 3, length: 0),
                NSRange(location: 6, length: 0),
            ],
            insertion: "  "
        )

        XCTAssertEqual(apply(plan, to: text), "  aa\n  bb\n  cc")
        XCTAssertEqual(plan.carets, [
            NSRange(location: 2, length: 0),
            NSRange(location: 7, length: 0),
            NSRange(location: 12, length: 0),
        ])
        XCTAssertEqual(plan.carets.count, 3, "every insertion point must survive the key press")
    }

    func testSeveralNonEmptyRangesAreEachReplacedAndTheCaretsFollowTheNetShift() {
        let text = "aaa\nbbb\nccc"
        let plan = IndentUnitRule.tabInsertionPlan(
            ranges: [
                NSRange(location: 0, length: 2),
                NSRange(location: 4, length: 3),
            ],
            insertion: "\t"
        )

        XCTAssertEqual(apply(plan, to: text), "\ta\n\t\nccc")
        XCTAssertEqual(plan.carets, [
            NSRange(location: 1, length: 0),
            NSRange(location: 4, length: 0),
        ])
    }

    func testTheCaretsAreOffsetsIntoTheResultingText() {
        // Applying the plan and then reading the text at each caret is what the
        // view effectively does when it calls `setSelectedRanges`.
        let text = "one\ntwo"
        let plan = IndentUnitRule.tabInsertionPlan(
            ranges: [NSRange(location: 0, length: 0), NSRange(location: 4, length: 0)],
            insertion: "    "
        )
        let result = apply(plan, to: text) as NSString

        for caret in plan.carets {
            XCTAssertLessThanOrEqual(caret.location, result.length)
        }
        XCTAssertEqual(result.substring(to: plan.carets[0].location), "    ")
        XCTAssertEqual(result.substring(with: NSRange(location: 0, length: plan.carets[1].location)), "    one\n    ")
    }

    func testUnorderedInputIsSortedSoTheEditsCanBeAppliedBackToFront() {
        let plan = IndentUnitRule.tabInsertionPlan(
            ranges: [NSRange(location: 6, length: 0), NSRange(location: 0, length: 0)],
            insertion: "  "
        )

        XCTAssertEqual(plan.replacements.map(\.range.location), [0, 6])
        XCTAssertEqual(apply(plan, to: "aa\nbb\ncc"), "  aa\nbb\n  cc")
    }

    func testOverlappingRangesAreUnionedIntoOneInsertionPoint() {
        let plan = IndentUnitRule.tabInsertionPlan(
            ranges: [NSRange(location: 0, length: 3), NSRange(location: 2, length: 3)],
            insertion: "-"
        )

        XCTAssertEqual(plan.replacements.map(\.range), [NSRange(location: 0, length: 5)])
        XCTAssertEqual(apply(plan, to: "abcdefg"), "-fg")
        XCTAssertEqual(plan.carets, [NSRange(location: 1, length: 0)])
    }

    func testDuplicateCaretsCollapseToOne() {
        let plan = IndentUnitRule.tabInsertionPlan(
            ranges: [NSRange(location: 2, length: 0), NSRange(location: 2, length: 0)],
            insertion: "  "
        )

        XCTAssertEqual(plan.replacements.count, 1)
        XCTAssertEqual(apply(plan, to: "abcd"), "ab  cd")
    }

    // MARK: - The plan is what the Tab key does

    // The macOS Tab handler applies the plan itself (back-to-front, inside one
    // `shouldChangeText` bracket) instead of calling `insertText`, so the claim
    // that it still does what the key always did is checked here, as arithmetic,
    // rather than by eyeballing the view.

    func testTheTabHandlerSingleRangePathMatchesOneNativeInsertion() {
        // One insertion point — a caret or a selection — must come out exactly as
        // a single `insertText(_:replacementRange:)` would have left it: the same
        // text, and the caret after the insertion.
        let text = "func f() {\n\tlet x = 1\n}"
        for range in [NSRange(location: 11, length: 0), NSRange(location: 11, length: 1)] {
            let plan = IndentUnitRule.tabInsertionPlan(ranges: [range], insertion: "  ")

            let native = NSMutableString(string: text)
            native.replaceCharacters(in: range, with: "  ")
            XCTAssertEqual(apply(plan, to: text), native as String)
            XCTAssertEqual(plan.replacements.count, 1)
            XCTAssertEqual(plan.carets, [NSRange(location: range.location + 2, length: 0)])
        }
    }

    func testTheTabHandlerMultiCaretPathInsertsOncePerCaretAndKeepsEveryCaret() {
        // What the native key does at several insertion points, which is the
        // state the column-selection gesture leaves behind: one insertion each,
        // and every caret still there afterwards.
        let text = "aaa\nbbb\nccc"
        let carets = [
            NSRange(location: 1, length: 0),
            NSRange(location: 5, length: 0),
            NSRange(location: 9, length: 0),
        ]
        let plan = IndentUnitRule.tabInsertionPlan(ranges: carets, insertion: "  ")

        XCTAssertEqual(plan.replacements.count, carets.count)
        XCTAssertEqual(plan.carets.count, carets.count)
        let result = apply(plan, to: text)
        XCTAssertEqual(result, "a  aa\nb  bb\nc  cc")
        // Each caret sits right after its own insertion in the resulting text.
        let resulting = result as NSString
        for caret in plan.carets {
            XCTAssertEqual(resulting.substring(with: NSRange(location: caret.location - 2, length: 2)), "  ")
        }
    }

    func testACaretAtTheEndOfASelectionStaysASecondInsertionPoint() {
        // Touching is not overlapping: the caret is its own insertion point.
        let plan = IndentUnitRule.tabInsertionPlan(
            ranges: [NSRange(location: 0, length: 2), NSRange(location: 2, length: 0)],
            insertion: "-"
        )

        XCTAssertEqual(plan.replacements.count, 2)
        XCTAssertEqual(apply(plan, to: "abcd"), "--cd")
    }

    func testACaretAtTheStartOfASelectionIsTheSameInsertionPoint() {
        // The mirror of the case above, and the one shape the union rule used to
        // miss: a zero-length range's `NSMaxRange` *is* its location, so a strict
        // `<` reads a caret at a selection's start as disjoint from it. Emitting
        // both would insert twice at the same offset and break the plan's own
        // "replacements never overlap" contract, which is what lets the view
        // apply them back-to-front.
        let plan = IndentUnitRule.tabInsertionPlan(
            ranges: [NSRange(location: 0, length: 0), NSRange(location: 0, length: 5)],
            insertion: "  "
        )

        XCTAssertEqual(plan.replacements.count, 1)
        XCTAssertEqual(plan.replacements[0].range, NSRange(location: 0, length: 5))
        XCTAssertEqual(plan.carets, [NSRange(location: 2, length: 0)])
        XCTAssertEqual(apply(plan, to: "abcdefg"), "  fg")
    }

    // MARK: - The touch editor's single range

    // The `UITextView` editor has exactly one insertion point, so its handler
    // hands the plan one range and applies the single replacement through the
    // same `applyEdit` every other programmatic edit uses. It goes through the
    // rule anyway so both platforms share one arithmetic — which is only worth
    // anything if a one-range plan really is one replacement and one caret.

    func testASingleRangeAnswersExactlyOneReplacementAndOneCaret() {
        let text = "func f() {\n    let x = 1\n}"
        let cases = [
            // A caret, mid-line: the ordinary Tab press.
            NSRange(location: 15, length: 0),
            // A non-empty selection, which the key *replaces* — the behavior the
            // touch editor inherits from the same rule rather than restating.
            NSRange(location: 11, length: 4),
            // A caret at the very end of the buffer.
            NSRange(location: (text as NSString).length, length: 0),
        ]
        for range in cases {
            let plan = IndentUnitRule.tabInsertionPlan(ranges: [range], insertion: "  ")

            XCTAssertEqual(plan.replacements.count, 1)
            XCTAssertEqual(plan.carets.count, 1)
            XCTAssertEqual(plan.replacements.first?.range, range)
            XCTAssertEqual(plan.replacements.first?.replacement, "  ")
            // What `applyEdit(in:range:replacement:selecting:)` installs.
            XCTAssertEqual(plan.carets.first, NSRange(location: range.location + 2, length: 0))

            let native = NSMutableString(string: text)
            native.replaceCharacters(in: range, with: "  ")
            XCTAssertEqual(apply(plan, to: text), native as String)
        }
    }

    func testATabAnsweredByTheRuleIsWhatLetsTheKeyThroughUntouched() {
        // Both editors suppress their platform's own Tab insertion *only* when the
        // rule answers something other than a tab. With no configuration it never
        // does — whatever the file looks like — which is what makes the key
        // byte-for-byte what it was before this layer existed.
        for inferred in ["\t", "  ", "    "] {
            XCTAssertEqual(
                IndentUnitRule.tabInsertion(config: EditorConfigProperties(), inferred: inferred),
                "\t"
            )
        }
    }

    // MARK: - Composed with the engine that consumes the unit

    func testTheConfiguredUnitIsWhatEnterAppendsAndExistingIndentationIsKept() {
        // The two halves the feature is actually made of: `IndentUnitRule.unit`
        // decides the unit and `IndentEngine.newlineIndentation` appends it. The
        // composed answer is worth pinning because it is not what a reader would
        // guess — the engine copies the current line's leading whitespace
        // *verbatim*, so a space configuration on a tab-indented file produces
        // `"\t" + "  "` rather than reformatting the line. That is the stated
        // "nothing already in the file is ever reformatted" rule, not a bug.
        let text = "\tif (x) {" as NSString
        let unit = IndentUnitRule.unit(config: config(["indent_style": "space", "indent_size": "2"]),
                                       inferred: "\t")
        let edit = IndentEngine.newlineIndentation(text: text, location: text.length, unit: unit)
        XCTAssertEqual(edit.text, "\n\t  ")

        // And with no configuration at all, byte-for-byte what the inference
        // alone produced before this layer existed.
        let plainUnit = IndentUnitRule.unit(config: config([:]), inferred: "\t")
        let plain = IndentEngine.newlineIndentation(text: text, location: text.length, unit: plainUnit)
        XCTAssertEqual(plain.text, "\n\t\t")
    }
}
