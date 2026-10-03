import XCTest
@testable import PisakaCore

final class TabColumnWidthRuleTests: XCTestCase {
    private typealias Bounds = TabColumnWidthRule.Bounds

    func testAWideWindowAtScaleOneGetsTheTokens() {
        XCTAssertEqual(
            TabColumnWidthRule.bounds(metrics: InterfaceMetrics(scale: 1), windowWidth: 1600),
            Bounds(minimum: 180, ideal: 220, maximum: 320)
        )
    }

    func testAWideWindowAtScaleOnePointEightGetsTheScaledTokens() {
        XCTAssertEqual(
            TabColumnWidthRule.bounds(metrics: InterfaceMetrics(scale: 1.8), windowWidth: 3000),
            Bounds(minimum: 324, ideal: 396, maximum: 576)
        )
    }

    func testANarrowWindowCapsTheMaximumAtAThird() {
        XCTAssertEqual(
            TabColumnWidthRule.bounds(metrics: InterfaceMetrics(scale: 1), windowWidth: 900),
            Bounds(minimum: 180, ideal: 220, maximum: 300)
        )
        XCTAssertEqual(
            TabColumnWidthRule.bounds(metrics: InterfaceMetrics(scale: 1.8), windowWidth: 1500),
            Bounds(minimum: 324, ideal: 396, maximum: 500)
        )
    }

    func testTheThirdBelowTheIdealPullsTheIdealDownWithIt() {
        XCTAssertEqual(
            TabColumnWidthRule.bounds(metrics: InterfaceMetrics(scale: 1), windowWidth: 600),
            Bounds(minimum: 180, ideal: 200, maximum: 200)
        )
    }

    func testAThirdBelowTheMinimumHoldsTheMaximumAtTheMinimum() {
        XCTAssertEqual(
            TabColumnWidthRule.bounds(metrics: InterfaceMetrics(scale: 1), windowWidth: 450),
            Bounds(minimum: 180, ideal: 180, maximum: 180)
        )
        XCTAssertEqual(
            TabColumnWidthRule.bounds(metrics: InterfaceMetrics(scale: 1.8), windowWidth: 800),
            Bounds(minimum: 324, ideal: 324, maximum: 324)
        )
    }

    func testEveryAnswerIsAValidFrame() {
        for scale in [0.8, 1, 1.25, 1.8] {
            for width in stride(from: 0.0, through: 4000, by: 50) {
                let bounds = TabColumnWidthRule.bounds(metrics: InterfaceMetrics(scale: scale), windowWidth: width)
                XCTAssertLessThanOrEqual(bounds.minimum, bounds.ideal, "scale \(scale), width \(width)")
                XCTAssertLessThanOrEqual(bounds.ideal, bounds.maximum, "scale \(scale), width \(width)")
            }
        }
    }
}
