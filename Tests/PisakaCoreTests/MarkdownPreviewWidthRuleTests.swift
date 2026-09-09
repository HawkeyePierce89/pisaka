import XCTest
@testable import PisakaCore

final class MarkdownPreviewWidthRuleTests: XCTestCase {
    /// The shipping constant, unscaled (the view hands the rule an
    /// interface-scaled number; the rule itself is scale-agnostic, so 100% is
    /// what the tests use).
    private let rule = MarkdownPreviewWidthRule()

    // MARK: - One-to-one drag tracking

    func testTranslationMapsOneToOneInsideTheBounds() {
        // available 2000 → the proportional bounds are [0.2, 0.8] (240/2000 =
        // 0.12 never binds), so a base of 0.5 has 600pt of travel each way
        // before either bound does; the sweep stays inside that.
        let available = 2000.0
        for points in stride(from: 0.0, through: 500.0, by: 25.0) {
            XCTAssertEqual(
                rule.editorWidth(
                    fraction: rule.fraction(base: 0.5, dragTranslation: points, available: available),
                    available: available
                ),
                1000 + points,
                accuracy: 0.0001,
                "dragging right \(points)pt must grow the editor exactly \(points)pt"
            )
            XCTAssertEqual(
                rule.editorWidth(
                    fraction: rule.fraction(base: 0.5, dragTranslation: -points, available: available),
                    available: available
                ),
                1000 - points,
                accuracy: 0.0001,
                "dragging left \(points)pt must shrink the editor exactly \(points)pt"
            )
        }
    }

    func testDragFormIsTheProposedFormWithTheTranslationAdded() {
        let available = 2000.0
        for translation in [-1500.0, -37.5, 0, 12.25, 900] {
            XCTAssertEqual(
                rule.fraction(base: 0.5, dragTranslation: translation, available: available),
                rule.fraction(proposed: 0.5 + translation / available, available: available)
            )
        }
    }

    // MARK: - The proportional bounds

    func testTheFractionIsClampedAtBothEnds() {
        XCTAssertEqual(rule.fraction(proposed: 0, available: 2000), 0.2, accuracy: 0.0001)
        XCTAssertEqual(rule.fraction(proposed: -3, available: 2000), 0.2, accuracy: 0.0001)
        XCTAssertEqual(rule.fraction(proposed: 1, available: 2000), 0.8, accuracy: 0.0001)
        XCTAssertEqual(rule.fraction(proposed: 4.5, available: 2000), 0.8, accuracy: 0.0001)
    }

    func testAFractionInsideTheBoundsIsUntouched() {
        for value in [0.2, 0.35, 0.5, 0.61, 0.8] {
            XCTAssertEqual(rule.fraction(proposed: value, available: 2000), value, accuracy: 0.0001)
        }
    }

    // MARK: - The two point minimums

    func testThePointMinimumBindsBeforeTheProportionalOneInANarrowWindow() {
        // available 800 → 240/800 = 0.3, which is above 0.2, so the *editor's*
        // minimum is what a leftward drag runs into.
        XCTAssertEqual(rule.fraction(proposed: 0.05, available: 800), 0.3, accuracy: 0.0001)
        XCTAssertEqual(rule.editorWidth(fraction: 0.05, available: 800), 240, accuracy: 0.0001)
    }

    func testThePreviewKeepsItsOwnMinimumAtTheOtherEnd() {
        // The same window, read from the other end: 1 - 0.3 = 0.7 is the widest
        // the editor may be before the preview drops below 240pt.
        XCTAssertEqual(rule.fraction(proposed: 0.95, available: 800), 0.7, accuracy: 0.0001)
        XCTAssertEqual(rule.previewWidth(fraction: 0.95, available: 800), 240, accuracy: 0.0001)
    }

    func testBothMinimumsAreHonoredAcrossTheWholeRangeOfAWindowThatFitsThem() {
        let available = 600.0 // exactly two minimums plus 120pt of slack
        for proposed in stride(from: -1.0, through: 2.0, by: 0.05) {
            let editor = rule.editorWidth(fraction: proposed, available: available)
            let preview = rule.previewWidth(fraction: proposed, available: available)
            XCTAssertGreaterThanOrEqual(editor, 240 - 0.0001, "editor kept \(editor)pt")
            XCTAssertGreaterThanOrEqual(preview, 240 - 0.0001, "preview kept \(preview)pt")
            XCTAssertEqual(editor + preview, available, accuracy: 0.0001)
        }
    }

    // MARK: - The degenerate window

    func testAWindowTooNarrowForTwoMinimumsSplitsEvenly() {
        // 400pt cannot hold two 240pt halves: there is no legal fraction, and the
        // even split is the answer whatever the stored preference says.
        for proposed in [0.0, 0.2, 0.5, 0.8, 1.0] {
            XCTAssertEqual(
                rule.fraction(proposed: proposed, available: 400),
                MarkdownPreviewWidthRule.defaultFraction
            )
        }
        XCTAssertEqual(rule.editorWidth(fraction: 0.8, available: 400), 200, accuracy: 0.0001)
        XCTAssertEqual(rule.previewWidth(fraction: 0.8, available: 400), 200, accuracy: 0.0001)
    }

    func testExactlyTwoMinimumsIsNotDegenerate() {
        // 480pt fits both halves at their floor and nothing more, so the only
        // legal fraction is the even split — reached through the bounds rather
        // than through the degenerate branch, which is what makes the boundary
        // continuous.
        XCTAssertEqual(rule.fraction(proposed: 0.05, available: 480), 0.5, accuracy: 0.0001)
        XCTAssertEqual(rule.fraction(proposed: 0.95, available: 480), 0.5, accuracy: 0.0001)
    }

    // MARK: - The guards

    func testANonPositiveOrNonFiniteAvailableAnswersTheEvenSplit() {
        for available in [0.0, -100, Double.nan, .infinity] {
            XCTAssertEqual(
                rule.fraction(proposed: 0.3, available: available),
                MarkdownPreviewWidthRule.defaultFraction,
                "available \(available)"
            )
            XCTAssertEqual(rule.editorWidth(fraction: 0.3, available: available), 0)
            XCTAssertEqual(rule.previewWidth(fraction: 0.3, available: available), 0)
        }
    }

    func testANonFiniteProposalFallsBackToTheEvenSplitRatherThanToABound() {
        for proposed in [Double.nan, .infinity, -.infinity] {
            XCTAssertEqual(
                rule.fraction(proposed: proposed, available: 2000),
                MarkdownPreviewWidthRule.defaultFraction,
                "proposed \(proposed)"
            )
        }
    }

    func testANonFiniteTranslationLeavesTheBaseWhereItIs() {
        for translation in [Double.nan, .infinity, -.infinity] {
            XCTAssertEqual(
                rule.fraction(base: 0.35, dragTranslation: translation, available: 2000),
                0.35,
                accuracy: 0.0001,
                "translation \(translation)"
            )
        }
    }

    func testANonFinitePaneMinimumContributesNothing() {
        // A poisoned constant must not make every comparison below it false; the
        // proportional bounds then carry the whole rule.
        let poisoned = MarkdownPreviewWidthRule(paneMinimum: .nan)
        XCTAssertEqual(poisoned.fraction(proposed: 0.05, available: 800), 0.2, accuracy: 0.0001)
        let negative = MarkdownPreviewWidthRule(paneMinimum: -50)
        XCTAssertEqual(negative.fraction(proposed: 0.95, available: 800), 0.8, accuracy: 0.0001)
    }

    func testEveryAnswerIsAWidthTheCallerCanUseUnchecked() {
        for available in [0.0, 1, 400, 480, 800, 2000, 50_000, Double.nan] {
            for proposed in [-5.0, 0, 0.5, 1, 12, Double.nan] {
                let editor = rule.editorWidth(fraction: proposed, available: available)
                let preview = rule.previewWidth(fraction: proposed, available: available)
                XCTAssertTrue(editor.isFinite && preview.isFinite)
                XCTAssertGreaterThanOrEqual(editor, 0)
                XCTAssertGreaterThanOrEqual(preview, 0)
                if available.isFinite, available > 0 {
                    XCTAssertEqual(editor + preview, available, accuracy: 0.0001)
                }
            }
        }
    }

    // MARK: - The width-free half

    func testTheStaticClampIsTheProportionalBoundsAlone() {
        XCTAssertEqual(MarkdownPreviewWidthRule.clampFraction(0.05), 0.2)
        XCTAssertEqual(MarkdownPreviewWidthRule.clampFraction(0.5), 0.5)
        XCTAssertEqual(MarkdownPreviewWidthRule.clampFraction(9), 0.8)
        XCTAssertEqual(
            MarkdownPreviewWidthRule.clampFraction(.nan),
            MarkdownPreviewWidthRule.defaultFraction
        )
    }
}
