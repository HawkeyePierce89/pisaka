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

    func testACaretAtTheEndOfASelectionStaysASecondInsertionPoint() {
        // Touching is not overlapping: the caret is its own insertion point.
        let plan = IndentUnitRule.tabInsertionPlan(
            ranges: [NSRange(location: 0, length: 2), NSRange(location: 2, length: 0)],
            insertion: "-"
        )

        XCTAssertEqual(plan.replacements.count, 2)
        XCTAssertEqual(apply(plan, to: "abcd"), "--cd")
    }
}
