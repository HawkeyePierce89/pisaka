import XCTest
@testable import PisakaCore

final class SplitPaneRuleTests: XCTestCase {
    /// The project tree's bounds at 100%, against the editor's minimum (the
    /// rule is scale-agnostic, so unscaled numbers are what the tests use).
    private let rule = SplitPaneRule(minimum: 180, ideal: 240, maximum: 360, trailingMinimum: 320)

    // MARK: - One-to-one drag tracking

    func testTranslationMapsOneToOneInsideTheBounds() {
        // available 1000 → upper min(360, 680) = 360, floor 180: a base of 240
        // has 120pt of travel each way before either bound binds.
        for points in stride(from: 0.0, through: 60.0, by: 5.0) {
            XCTAssertEqual(rule.extent(base: 240, dragTranslation: points, available: 1000), 240 + points)
            XCTAssertEqual(rule.extent(base: 240, dragTranslation: -points, available: 1000), 240 - points)
        }
    }

    func testDragFormIsTheProposedFormWithTheTranslationAdded() {
        for translation in [-300.0, -37.5, 0, 12.25, 400] {
            XCTAssertEqual(
                rule.extent(base: 240, dragTranslation: translation, available: 1000),
                rule.extent(proposed: 240 + translation, available: 1000)
            )
        }
    }

    func testAZeroTranslationChangesNothing() {
        // The opening frame of a drag: the base is the rendered extent, which
        // already satisfies the clamp, so the answer is the base itself.
        for base in [180.0, 240, 300, 360] {
            XCTAssertEqual(rule.extent(base: base, dragTranslation: 0, available: 1000), base)
        }
        // In a narrow area the rendered extent is the squeezed one, and it too
        // survives a zero translation unchanged.
        let squeezed = rule.extent(proposed: 240, available: 400)
        XCTAssertEqual(rule.extent(base: squeezed, dragTranslation: 0, available: 400), squeezed)
    }

    // MARK: - Clamping at both ends

    func testTheLowerBoundIsTheLeadingMinimum() {
        XCTAssertEqual(rule.extent(proposed: 0, available: 1000), 180)
        XCTAssertEqual(rule.extent(proposed: -500, available: 1000), 180)
        XCTAssertEqual(rule.extent(base: 240, dragTranslation: -900, available: 1000), 180)
    }

    func testTheUpperBoundIsTheLeadingMaximumInAWideArea() {
        XCTAssertEqual(rule.upperBound(available: 1000), 360)
        XCTAssertEqual(rule.extent(proposed: 900, available: 1000), 360)
        XCTAssertEqual(rule.extent(base: 240, dragTranslation: 900, available: 1000), 360)
    }

    func testTheTrailingMinimumBindsBeforeTheMaximumInANarrowerArea() {
        // available 600 → the trailing pane needs 320, so the leading one stops
        // at 280, short of its own 360.
        XCTAssertEqual(rule.upperBound(available: 600), 280)
        XCTAssertEqual(rule.extent(proposed: 360, available: 600), 280)
        XCTAssertEqual(600 - rule.extent(proposed: 360, available: 600), 320)
    }

    // MARK: - A shortfall of space

    func testTheTrailingMinimumWinsWhenTheBoundsCross() {
        // available 400 → the ceiling 80 is below the leading minimum 180: the
        // trailing pane keeps its 320 and the leading pane is the one squeezed.
        XCTAssertEqual(rule.extent(proposed: 240, available: 400), 80)
        XCTAssertEqual(rule.extent(proposed: 0, available: 400), 80)
        XCTAssertEqual(400 - rule.extent(proposed: 240, available: 400), 320)
    }

    func testTheLeadingPaneCollapsesRatherThanGoingNegative() {
        // Not even the trailing minimum fits.
        XCTAssertEqual(rule.extent(proposed: 240, available: 200), 0)
        XCTAssertEqual(rule.upperBound(available: 200), 0)
    }

    func testTheAnswerAlwaysLiesWithinTheAvailableExtent() {
        for available in stride(from: 0.0, through: 1200.0, by: 37.0) {
            for proposed in [-1e6, 0, 180, 240, 360, 1e6] {
                let extent = rule.extent(proposed: proposed, available: available)
                XCTAssertGreaterThanOrEqual(extent, 0)
                XCTAssertLessThanOrEqual(extent, available)
            }
        }
    }

    // MARK: - A negative or oversized drag

    func testAnOversizedDragStopsAtTheCeilingAndANegativeOneAtTheFloor() {
        XCTAssertEqual(rule.extent(base: 240, dragTranslation: 1e9, available: 1000), 360)
        XCTAssertEqual(rule.extent(base: 240, dragTranslation: -1e9, available: 1000), 180)
        XCTAssertEqual(rule.extent(base: 240, dragTranslation: .infinity, available: 1000), 240)
        XCTAssertEqual(rule.extent(base: 240, dragTranslation: -.infinity, available: 1000), 240)
        XCTAssertEqual(rule.extent(base: 240, dragTranslation: .nan, available: 1000), 240)
    }

    // MARK: - Degenerate inputs

    func testAnUnusableAvailableExtentCollapsesToZero() {
        for available in [0.0, -10, .nan, .infinity] {
            XCTAssertEqual(rule.upperBound(available: available), 0)
            XCTAssertEqual(rule.extent(proposed: 240, available: available), 0)
        }
    }

    func testANonFiniteProposalFallsBackToTheIdeal() {
        XCTAssertEqual(rule.extent(proposed: .nan, available: 1000), 240)
        XCTAssertEqual(rule.extent(proposed: .infinity, available: 1000), 240)
    }

    func testANonFiniteOrNegativeBoundContributesNothing() {
        let broken = SplitPaneRule(minimum: .nan, ideal: 240, maximum: 360, trailingMinimum: -50)
        XCTAssertEqual(broken.extent(proposed: -10, available: 1000), 0)
        XCTAssertEqual(broken.upperBound(available: 1000), 360)
    }
}
