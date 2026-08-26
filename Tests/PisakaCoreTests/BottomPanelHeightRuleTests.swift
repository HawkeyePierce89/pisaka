import XCTest
@testable import PisakaCore

final class BottomPanelHeightRuleTests: XCTestCase {
    /// The shipping constants, unscaled (the view hands the rule interface-scaled
    /// numbers; the rule itself is scale-agnostic, so 100% is what the tests use).
    private let rule = BottomPanelHeightRule(floor: 120, dividerHeight: 5, editorMinimum: 120)

    // MARK: - One-to-one drag tracking

    func testTranslationMapsOneToOneInsideTheBounds() {
        // available 1000 → upper bound min(500, 1000 - 5 - 120) = 500, floor 120,
        // so a base of 240 has 260pt of travel up and 120pt down before either
        // bound binds; the sweep stays inside the smaller of the two.
        for points in stride(from: 0.0, through: 120.0, by: 5.0) {
            XCTAssertEqual(
                rule.height(base: 240, dragTranslation: -points, available: 1000),
                240 + points,
                accuracy: 0.0001,
                "dragging up \(points)pt must grow the panel exactly \(points)pt"
            )
            XCTAssertEqual(
                rule.height(base: 240, dragTranslation: points, available: 1000),
                240 - points,
                accuracy: 0.0001,
                "dragging down \(points)pt must shrink the panel exactly \(points)pt"
            )
        }
    }

    func testDragFormIsTheProposedFormWithTheTranslationSubtracted() {
        for translation in [-300.0, -37.5, 0, 12.25, 400] {
            XCTAssertEqual(
                rule.height(base: 240, dragTranslation: translation, available: 1000),
                rule.height(proposed: 240 - translation, available: 1000)
            )
        }
    }

    // MARK: - Bounds

    func testLowerBoundIsTheFloor() {
        XCTAssertEqual(rule.height(proposed: 0, available: 1000), 120)
        XCTAssertEqual(rule.height(proposed: -500, available: 1000), 120)
        XCTAssertEqual(rule.height(base: 240, dragTranslation: 900, available: 1000), 120)
    }

    func testUpperBoundIsHalfTheAvailableHeightInATallArea() {
        XCTAssertEqual(rule.upperBound(available: 1000), 500)
        XCTAssertEqual(rule.height(proposed: 900, available: 1000), 500)
        XCTAssertEqual(rule.height(base: 240, dragTranslation: -900, available: 1000), 500)
    }

    func testEditorReservationBindsBeforeHalfInAShortArea() {
        // A rule whose editor reservation is the larger of the two constants, so
        // the reservation bound can bind while the result still clears the floor.
        let reserving = BottomPanelHeightRule(floor: 50, dividerHeight: 5, editorMinimum: 200)
        // available 300 → half is 150, but the reservation leaves only 95.
        XCTAssertEqual(reserving.upperBound(available: 300), 95)
        XCTAssertEqual(reserving.height(proposed: 150, available: 300), 95)
        // The editor keeps exactly what it reserved, never less.
        XCTAssertEqual(reserving.height(proposed: 150, available: 300) + 5 + 200, 300, accuracy: 0.0001)
    }

    func testUpperBoundNeverExceedsTheAvailableSpace() {
        for available in stride(from: 0.0, through: 2000.0, by: 25.0) {
            let upper = rule.upperBound(available: available)
            XCTAssertGreaterThanOrEqual(upper, 0)
            XCTAssertLessThanOrEqual(upper, available)
        }
    }

    // MARK: - The degenerate case

    func testFloorItselfShrinksWhenTheReservationCannotLeaveRoomForIt() {
        // available 200 → half is 100 and the reservation leaves 75; the floor of
        // 120 simply does not fit, so the rule shrinks below it rather than
        // returning a height the space cannot hold.
        XCTAssertEqual(rule.upperBound(available: 200), 75)
        XCTAssertEqual(rule.height(proposed: 240, available: 200), 75)
        XCTAssertEqual(rule.height(proposed: 10, available: 200), 75)
        XCTAssertLessThan(rule.height(proposed: 240, available: 200), rule.floor)
        XCTAssertGreaterThanOrEqual(rule.height(proposed: 240, available: 200), 0)
        XCTAssertLessThanOrEqual(rule.height(proposed: 240, available: 200), 200)
    }

    func testAVeryShortAreaCollapsesThePanelRatherThanOverflowing() {
        for available in stride(from: 0.0, through: 130.0, by: 5.0) {
            let height = rule.height(proposed: 240, available: available)
            XCTAssertGreaterThanOrEqual(height, 0, "available \(available)")
            XCTAssertLessThanOrEqual(height, available, "available \(available)")
        }
    }

    /// Pins the single-floor decision, which is what lets the view delete the
    /// per-panel `frame(minHeight:)` modifiers that used to sit *inside* the
    /// fixed-height panel slot (`panelContent`'s `.log` 160, `.changes` 120 and
    /// `.problems` 120). The rule deliberately returns a height *below* its own
    /// floor when the space cannot hold floor + divider + editor reservation, so
    /// no minimum stated below the rule — 160, 120 or any other number — can be
    /// honored on that path; a child that insists on one can only overflow the
    /// slot. The height is therefore a function of `floor`, `dividerHeight` and
    /// `editorMinimum` alone, and of nothing any panel says about itself.
    func testTheOnlyFloorIsTheRulesAndItYieldsWhenItMustNotFit() {
        let degenerate = rule.height(proposed: 240, available: 200)
        XCTAssertLessThan(degenerate, rule.floor)
        XCTAssertLessThan(degenerate, 120, "the deleted `.changes`/`.problems` minimum cannot be honored here")
        XCTAssertLessThan(degenerate, 160, "the deleted `.log` minimum cannot be honored here")

        // Same three constants → same answer, whatever is rendered in the slot.
        let twin = BottomPanelHeightRule(floor: 120, dividerHeight: 5, editorMinimum: 120)
        XCTAssertEqual(twin, rule)
        for available in stride(from: 0.0, through: 1200.0, by: 37.0) {
            XCTAssertEqual(twin.height(proposed: 240, available: available),
                           rule.height(proposed: 240, available: available))
        }
    }

    // MARK: - Degenerate inputs

    func testZeroAndNegativeAvailableCollapseToZero() {
        for available in [0.0, -1, -1000] {
            XCTAssertEqual(rule.upperBound(available: available), 0, "available \(available)")
            XCTAssertEqual(rule.height(proposed: 240, available: available), 0, "available \(available)")
            XCTAssertEqual(rule.height(base: 240, dragTranslation: -50, available: available), 0)
        }
    }

    func testNonFiniteAvailableCollapsesToZero() {
        for available in [Double.nan, .infinity, -.infinity] {
            XCTAssertEqual(rule.upperBound(available: available), 0)
            XCTAssertEqual(rule.height(proposed: 240, available: available), 0)
            XCTAssertEqual(rule.height(base: 240, dragTranslation: -50, available: available), 0)
        }
    }

    func testNonFiniteProposedHeightFallsBackToTheFloor() {
        for proposed in [Double.nan, .infinity, -.infinity] {
            XCTAssertEqual(rule.height(proposed: proposed, available: 1000), 120)
            // …and in the degenerate case, to what actually fits.
            XCTAssertEqual(rule.height(proposed: proposed, available: 200), 75)
        }
    }

    func testNonFiniteDragTranslationLeavesTheBaseWhereItIs() {
        for translation in [Double.nan, .infinity, -.infinity] {
            XCTAssertEqual(rule.height(base: 240, dragTranslation: translation, available: 1000), 240)
        }
    }

    func testNonFiniteConstantsDoNotSurviveIntoTheResult() {
        let broken = BottomPanelHeightRule(floor: .nan, dividerHeight: .infinity, editorMinimum: -50)
        for available in stride(from: 0.0, through: 1000.0, by: 50.0) {
            let height = broken.height(proposed: 240, available: available)
            XCTAssertTrue(height.isFinite, "available \(available)")
            XCTAssertGreaterThanOrEqual(height, 0)
            XCTAssertLessThanOrEqual(height, available)
        }
    }

    // MARK: - Invariants over a grid

    func testSweepHoldsBothInvariants() {
        for available in stride(from: 0.0, through: 2000.0, by: 13.0) {
            for proposed in stride(from: -200.0, through: 2200.0, by: 37.0) {
                let height = rule.height(proposed: proposed, available: available)
                XCTAssertTrue(height.isFinite, "available \(available), proposed \(proposed)")
                XCTAssertGreaterThanOrEqual(height, 0, "available \(available), proposed \(proposed)")
                XCTAssertLessThanOrEqual(height, available, "available \(available), proposed \(proposed)")
                if available >= rule.floor + rule.dividerHeight + rule.editorMinimum {
                    XCTAssertGreaterThanOrEqual(height, rule.floor,
                                                "available \(available), proposed \(proposed)")
                    XCTAssertLessThanOrEqual(height + rule.dividerHeight + rule.editorMinimum, available,
                                             "available \(available), proposed \(proposed)")
                }
            }
        }
    }

    func testHeightIsMonotonicInTheProposal() {
        var previous = rule.height(proposed: -500, available: 1000)
        for proposed in stride(from: -500.0, through: 1500.0, by: 7.0) {
            let height = rule.height(proposed: proposed, available: 1000)
            XCTAssertGreaterThanOrEqual(height, previous, "proposed \(proposed)")
            previous = height
        }
    }
}
