import XCTest
@testable import PisakaCore

final class IndentLevelScannerTests: XCTestCase {

    // MARK: - Helpers

    private func runs(
        _ text: String,
        unit: Int = 4,
        tab: Int = 4,
        range: NSRange? = nil
    ) -> [IndentLevelRun] {
        let ns = text as NSString
        return IndentLevelScanner.runs(
            in: ns,
            range: range ?? NSRange(location: 0, length: ns.length),
            widths: IndentLevelWidths(unitWidth: unit, tabWidth: tab)
        )
    }

    private func run(_ location: Int, _ length: Int, _ level: Int) -> IndentLevelRun {
        IndentLevelRun(range: NSRange(location: location, length: length), level: level)
    }

    // MARK: - Spaces

    func testSpacesSplitIntoWholeUnits() {
        XCTAssertEqual(
            runs("        a", unit: 4),
            [run(0, 4, 0), run(4, 4, 1)]
        )
    }

    func testASingleUnitOfSpaces() {
        XCTAssertEqual(runs("    a", unit: 4), [run(0, 4, 0)])
    }

    /// Six spaces at a unit of four: a full block at level 0 and a shorter one
    /// at level 1. There is no error level and no realignment.
    func testPartialTrailingUnit() {
        XCTAssertEqual(
            runs("      a", unit: 4),
            [run(0, 4, 0), run(4, 2, 1)]
        )
    }

    func testATwoSpaceUnit() {
        XCTAssertEqual(
            runs("      a", unit: 2),
            [run(0, 2, 0), run(2, 2, 1), run(4, 2, 2)]
        )
    }

    func testNoLeadingWhitespaceYieldsNothing() {
        XCTAssertEqual(runs("alpha"), [])
    }

    func testEmptyLineYieldsNothing() {
        XCTAssertEqual(runs("a\n\nb"), [])
    }

    func testEmptyTextYieldsNothing() {
        XCTAssertEqual(runs(""), [])
    }

    /// A whitespace-only line is levelled like an indent of its own width — the
    /// same walk answers it, because its content range holds only whitespace.
    func testWhitespaceOnlyLineIsLevelledLikeAnIndent() {
        // "a\n" is 2 units, then six spaces, then "\nb".
        XCTAssertEqual(
            runs("a\n      \nb", unit: 4),
            [run(2, 4, 0), run(6, 2, 1)]
        )
    }

    /// Trailing whitespace on a line that *starts* with content is not
    /// indentation: the walk stops at the first non-indentation character.
    func testTrailingWhitespaceIsNotIndentation() {
        XCTAssertEqual(runs("a        "), [])
    }

    func testWhitespaceInsideALineIsNotIndentation() {
        XCTAssertEqual(runs("    a        b", unit: 4), [run(0, 4, 0)])
    }

    // MARK: - Tabs

    /// One tab is always one block, even when the tab stop crosses several unit
    /// boundaries — the next run's level then *skips*, which is honest: the
    /// column really did move that far.
    func testOneTabIsOneBlockEvenAcrossSeveralUnits() {
        XCTAssertEqual(
            runs("\t a", unit: 4, tab: 8),
            [run(0, 1, 0), run(1, 1, 2)]
        )
    }

    func testTabIndentedFileIsOneBlockPerTab() {
        XCTAssertEqual(
            runs("\t\t\ta", unit: 4, tab: 4),
            [run(0, 1, 0), run(1, 1, 1), run(2, 1, 2)]
        )
    }

    /// A tab advances the column to the next multiple of the tab width, not by
    /// the tab width: two spaces then a tab lands on column 4, not 6.
    func testTabAdvancesToTheNextTabStop() {
        // Columns: " "=0, " "=1, "\t" starts at 2 → level 0 for all three, and
        // the tab lands the column on 4, so "a" would be at level 1.
        XCTAssertEqual(
            runs("  \t a", unit: 4, tab: 4),
            [run(0, 3, 0), run(3, 1, 1)]
        )
    }

    func testTabAfterAFullUnitOfSpaces() {
        // Four spaces fill level 0; the tab starts at column 4 (level 1) and
        // lands on column 8; the trailing space starts at column 8 (level 2).
        XCTAssertEqual(
            runs("    \t x", unit: 4, tab: 4),
            [run(0, 4, 0), run(4, 1, 1), run(5, 1, 2)]
        )
    }

    /// Mixed indentation with a wider tab stop than the unit: the arithmetic is
    /// the column's, not the character count's.
    func testMixedTabsAndSpacesWithAWiderTabStop() {
        // "   " → columns 0,1,2 (level 0); "\t" starts at column 3 (level 0),
        // lands on 8; "  " start at columns 8 and 9 (level 2).
        XCTAssertEqual(
            runs("   \t  a", unit: 4, tab: 8),
            [run(0, 4, 0), run(4, 2, 2)]
        )
    }

    // MARK: - Separators

    /// Line boundaries are the editor's own set, applied by using
    /// `TerminatedLines` rather than by a second table here. CRLF is one
    /// terminator: it never yields the phantom empty line a split pair would.
    func testEverySeparatorInTheEditorsSet() {
        for separator in ["\n", "\r", "\r\n", "\u{0085}", "\u{2028}", "\u{2029}"] {
            let text = "    a\(separator)        b"
            let second = 5 + (separator as NSString).length
            XCTAssertEqual(
                runs(text, unit: 4),
                [run(0, 4, 0), run(second, 4, 0), run(second + 4, 4, 1)],
                String(reflecting: separator)
            )
        }
    }

    // MARK: - Bounding

    private static let threeLines = "        a\n    b\n\tc\n"
    // Offsets: 0–7 spaces, 8 "a", 9 "\n", 10–13 spaces, 14 "b", 15 "\n",
    //          16 "\t", 17 "c", 18 "\n".

    func testWholeTextRuns() {
        XCTAssertEqual(
            runs(Self.threeLines, unit: 4, tab: 4),
            [run(0, 4, 0), run(4, 4, 1), run(10, 4, 0), run(16, 1, 0)]
        )
    }

    /// A range starting mid-indent still answers that line's whole runs — the
    /// painter clips by drawing, the engine never clips by answering.
    func testRangeStartingMidIndentAnswersWholeRuns() {
        XCTAssertEqual(
            runs(Self.threeLines, unit: 4, tab: 4, range: NSRange(location: 2, length: 1)),
            [run(0, 4, 0), run(4, 4, 1)]
        )
    }

    /// And a range ending mid-indent answers the last line it touched whole.
    func testRangeEndingMidIndentAnswersWholeRuns() {
        XCTAssertEqual(
            runs(Self.threeLines, unit: 4, tab: 4, range: NSRange(location: 0, length: 12)),
            [run(0, 4, 0), run(4, 4, 1), run(10, 4, 0)]
        )
    }

    /// Only the lines the range touches are visited: a redraw never walks the
    /// whole file.
    func testRangeSpanningSeveralLinesAnswersOnlyThose() {
        XCTAssertEqual(
            runs(Self.threeLines, unit: 4, tab: 4, range: NSRange(location: 11, length: 6)),
            [run(10, 4, 0), run(16, 1, 0)]
        )
    }

    // MARK: - Degenerate widths

    func testZeroOrNegativeWidthsYieldNoRuns() {
        XCTAssertEqual(runs("        a", unit: 0, tab: 4), [])
        XCTAssertEqual(runs("        a", unit: 4, tab: 0), [])
        XCTAssertEqual(runs("        a", unit: -1, tab: 4), [])
        XCTAssertEqual(runs("\t\ta", unit: 4, tab: -8), [])
        XCTAssertEqual(runs("\t\ta", unit: 0, tab: 0), [])
    }

    /// The other end of the range, which an `.editorconfig` really can state:
    /// advancing the column to the next tab stop twice at a width near `Int.max`
    /// overflows and traps — inside a draw, so it is the app. Both widths are
    /// clamped to the rule's own ceiling, so the answer is the one that ceiling
    /// gives rather than a crash.
    func testAbsurdWidthsAreClampedRatherThanTrapping() {
        let clamped = IndentUnitRule.maximumSpaceWidth
        XCTAssertEqual(
            runs("\t\ta", unit: Int.max, tab: Int.max),
            runs("\t\ta", unit: clamped, tab: clamped)
        )
        XCTAssertEqual(
            runs("        a", unit: 5_000_000_000_000_000_000, tab: 4),
            runs("        a", unit: clamped, tab: 4)
        )
        // Reached the same way the app reaches it: a project's own `tab_width`.
        let widths = IndentLevelScanner.widths(unit: "\t", statedTabWidth: Int.max)
        let text = "\t\t\ta" as NSString
        XCTAssertEqual(
            IndentLevelScanner.runs(in: text, range: NSRange(location: 0, length: text.length), widths: widths),
            [run(0, 1, 0), run(1, 1, 1), run(2, 1, 2)]
        )
    }

    // MARK: - The width derivation

    func testTabUnitWithAStatedTabWidth() {
        let widths = IndentLevelScanner.widths(unit: "\t", statedTabWidth: 8)
        XCTAssertEqual(widths, IndentLevelWidths(unitWidth: 8, tabWidth: 8))
    }

    /// The unstated fallback is read from the rule that decides what Enter
    /// appends, never restated as a literal here, so the two cannot drift.
    func testTabUnitWithoutAStatedTabWidthFallsBackToTheRulesWidth() {
        let widths = IndentLevelScanner.widths(unit: "\t", statedTabWidth: nil)
        XCTAssertEqual(
            widths,
            IndentLevelWidths(
                unitWidth: IndentUnitRule.defaultSpaceWidth,
                tabWidth: IndentUnitRule.defaultSpaceWidth
            )
        )
    }

    /// Unit width equal to tab width is what makes a tab-indented file paint
    /// exactly one block per tab.
    func testATabUnitAlwaysPaintsOneBlockPerTab() {
        for stated in [nil, 2, 4, 8] as [Int?] {
            let widths = IndentLevelScanner.widths(unit: "\t", statedTabWidth: stated)
            XCTAssertEqual(widths.unitWidth, widths.tabWidth, String(describing: stated))
            let ns = "\t\t\ta" as NSString
            XCTAssertEqual(
                IndentLevelScanner.runs(in: ns, range: NSRange(location: 0, length: ns.length), widths: widths),
                [run(0, 1, 0), run(1, 1, 1), run(2, 1, 2)],
                String(describing: stated)
            )
        }
    }

    func testSpaceUnitIsAsWideAsItsOwnSpaces() {
        XCTAssertEqual(
            IndentLevelScanner.widths(unit: "  ", statedTabWidth: nil),
            IndentLevelWidths(unitWidth: 2, tabWidth: 2)
        )
    }

    /// A stated `tab_width` never re-widens a space unit — the spaces are what
    /// is actually in the file — but it *is* the tab stop.
    func testSpaceUnitWithAStatedTabWidthKeepsItsOwnWidth() {
        XCTAssertEqual(
            IndentLevelScanner.widths(unit: "  ", statedTabWidth: 8),
            IndentLevelWidths(unitWidth: 2, tabWidth: 8)
        )
    }

    func testTheDerivedWidthsFeedTheWalk() {
        let widths = IndentLevelScanner.widths(unit: "  ", statedTabWidth: 8)
        let ns = "\t  a" as NSString
        // The tab starts at column 0 (level 0) and lands on column 8; the two
        // spaces start at columns 8 and 9, both level 4.
        XCTAssertEqual(
            IndentLevelScanner.runs(in: ns, range: NSRange(location: 0, length: ns.length), widths: widths),
            [run(0, 1, 0), run(1, 2, 4)]
        )
    }

    /// The unit the rule answers is the unit the scan is asked for: the two
    /// halves are wired here rather than restated.
    func testDerivationFromTheUnitRulesOwnAnswer() {
        let config = EditorConfigProperties(["indent_style": "space", "indent_size": "2"])
        let unit = IndentUnitRule.unit(config: config, inferred: "    ")
        XCTAssertEqual(
            IndentLevelScanner.widths(unit: unit, statedTabWidth: config.tabWidth),
            IndentLevelWidths(unitWidth: 2, tabWidth: 2)
        )
    }
}
