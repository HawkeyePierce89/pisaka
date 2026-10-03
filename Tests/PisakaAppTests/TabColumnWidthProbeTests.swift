#if os(macOS)
import Combine
import XCTest
import PisakaCore
@testable import Pisaka

/// `TabColumnWidthProbe` publishes the tab column's bounds only when they
/// change, so a resize above the window-third threshold — where the maximum is
/// the scaled 320 whatever the width — re-evaluates nothing. A plain unit test:
/// no view, the publishes counted off `objectWillChange`.
@MainActor
final class TabColumnWidthProbeTests: XCTestCase {

    func testWidthsAboveTheThresholdPublishOnceAndANarrowWidthPublishesNewBounds() {
        let metrics = InterfaceMetrics(scale: 1)
        let probe = TabColumnWidthProbe()
        var publishes = 0
        let subscription = probe.objectWillChange.sink { publishes += 1 }
        defer { subscription.cancel() }

        // A third of 1200 and of 1500 both exceed 320.
        probe.update(windowWidth: 1200, metrics: metrics)
        probe.update(windowWidth: 1500, metrics: metrics)
        XCTAssertEqual(publishes, 1, "a resize above the threshold published again")
        XCTAssertEqual(probe.bounds?.maximum, 320)

        // A third of 750 is 250, under the maximum.
        probe.update(windowWidth: 750, metrics: metrics)
        XCTAssertEqual(publishes, 2, "a width below the threshold did not publish")
        XCTAssertEqual(probe.bounds?.maximum, 250)
        XCTAssertEqual(probe.bounds, TabColumnWidthRule.bounds(metrics: metrics, windowWidth: 750))
    }
}
#endif
