import XCTest
@testable import PisakaCore

final class ScaledFrameFitRuleTests: XCTestCase {
    private typealias Size = ScaledFrameFitRule.Size

    /// A 1440×900 display's visible area under the menu bar.
    private let laptop = Size(width: 1440, height: 875)

    func testASizeThatFitsComesBackUnchanged() {
        let minimum = Size(width: 600, height: 400)
        let ideal = Size(width: 800, height: 500)
        let frame = ScaledFrameFitRule.fit(minimum: minimum, ideal: ideal, available: laptop)
        XCTAssertEqual(frame, ScaledFrameFitRule.Frame(minimum: minimum, ideal: ideal))
    }

    func testEachAxisIsCappedSeparately() {
        let tall = ScaledFrameFitRule.fit(
            minimum: Size(width: 600, height: 900),
            ideal: Size(width: 800, height: 1000),
            available: laptop
        )
        XCTAssertEqual(tall.ideal, Size(width: 800, height: 875))
        XCTAssertEqual(tall.minimum, Size(width: 600, height: 875))

        let wide = ScaledFrameFitRule.fit(
            minimum: Size(width: 1500, height: 300),
            ideal: Size(width: 1600, height: 400),
            available: laptop
        )
        XCTAssertEqual(wide.ideal, Size(width: 1440, height: 400))
        XCTAssertEqual(wide.minimum, Size(width: 1440, height: 300))
    }

    func testTheMinimumNeverExceedsTheIdeal() {
        // Capping the ideal below the minimum pulls the minimum down with it…
        let capped = ScaledFrameFitRule.fit(
            minimum: Size(width: 1400, height: 860),
            ideal: Size(width: 1600, height: 1000),
            available: Size(width: 1000, height: 700)
        )
        XCTAssertEqual(capped.minimum, Size(width: 1000, height: 700))
        XCTAssertEqual(capped.ideal, Size(width: 1000, height: 700))
        // …and an input that was already inverted is ordered too.
        let inverted = ScaledFrameFitRule.fit(
            minimum: Size(width: 500, height: 500),
            ideal: Size(width: 400, height: 300),
            available: laptop
        )
        XCTAssertLessThanOrEqual(inverted.minimum.width, inverted.ideal.width)
        XCTAssertLessThanOrEqual(inverted.minimum.height, inverted.ideal.height)
    }

    func testAnUnknownScreenLeavesTheAxisUncapped() {
        let minimum = Size(width: 1350, height: 840)
        let ideal = Size(width: 1500, height: 960)
        let expected = ScaledFrameFitRule.Frame(minimum: minimum, ideal: ideal)
        XCTAssertEqual(ScaledFrameFitRule.fit(minimum: minimum, ideal: ideal, available: nil), expected)
        XCTAssertEqual(
            ScaledFrameFitRule.fit(minimum: minimum, ideal: ideal, available: Size(width: 0, height: -1)),
            expected
        )
        XCTAssertEqual(
            ScaledFrameFitRule.fit(minimum: minimum, ideal: ideal, available: Size(width: .nan, height: .infinity)),
            expected
        )
    }

    /// The two offenders, by their base sizes: at scale 1.0 a 1440×900 screen
    /// gives the input back, so nothing moves for a user who chose 100%.
    func testAtScaleOneBothSheetsComeBackUnchanged() {
        let metrics = InterfaceMetrics(scale: 1.0)
        for (name, minimum, ideal) in offenders(metrics) {
            let frame = ScaledFrameFitRule.fit(minimum: minimum, ideal: ideal, available: laptop)
            XCTAssertEqual(frame, ScaledFrameFitRule.Frame(minimum: minimum, ideal: ideal), name)
        }
    }

    /// At the 1.5 resting scale both overflow a 1440×875 visible area; fitted,
    /// both come back inside it.
    func testAtTheRestingScaleBothSheetsFitALaptopScreen() {
        let metrics = InterfaceMetrics(scale: 1.5)
        for (name, minimum, ideal) in offenders(metrics) {
            XCTAssertTrue(ideal.width > laptop.width || ideal.height > laptop.height, "\(name) overflows unfitted")
            let frame = ScaledFrameFitRule.fit(minimum: minimum, ideal: ideal, available: laptop)
            for size in [frame.minimum, frame.ideal] {
                XCTAssertLessThanOrEqual(size.width, laptop.width, name)
                XCTAssertLessThanOrEqual(size.height, laptop.height, name)
            }
        }
        let commit = ScaledFrameFitRule.fit(
            minimum: Size(width: metrics.pt(900), height: metrics.pt(560)),
            ideal: Size(width: metrics.pt(1000), height: metrics.pt(640)),
            available: laptop
        )
        XCTAssertEqual(commit.minimum, Size(width: 1350, height: 840))
        XCTAssertEqual(commit.ideal, Size(width: 1440, height: 875))
    }

    /// The commit dialog's and the LeetCode login sheet's base frames, restated
    /// from `CommitDialogView` and `LeetCodeLoginView`.
    private func offenders(_ metrics: InterfaceMetrics) -> [(String, Size, Size)] {
        [
            (
                "commit dialog",
                Size(width: metrics.pt(900), height: metrics.pt(560)),
                Size(width: metrics.pt(1000), height: metrics.pt(640))
            ),
            (
                "LeetCode login",
                Size(width: metrics.pt(520), height: metrics.pt(520)),
                Size(width: metrics.pt(760), height: metrics.pt(780))
            ),
        ]
    }
}
