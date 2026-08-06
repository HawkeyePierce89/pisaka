import XCTest
@testable import PisakaCore

final class TabLayoutTests: XCTestCase {
    func testCompactWidthAlwaysUsesSwitcher() {
        // Compact width collapses to the switcher regardless of orientation.
        XCTAssertEqual(
            TabLayout.presentation(isCompactWidth: true, orientation: .horizontal),
            .switcher
        )
        XCTAssertEqual(
            TabLayout.presentation(isCompactWidth: true, orientation: .vertical),
            .switcher
        )
    }

    func testRegularWidthHonorsOrientation() {
        XCTAssertEqual(
            TabLayout.presentation(isCompactWidth: false, orientation: .horizontal),
            .horizontalStrip
        )
        XCTAssertEqual(
            TabLayout.presentation(isCompactWidth: false, orientation: .vertical),
            .verticalColumn
        )
    }

    func testEveryOrientationMapsAtBothWidths() {
        // Defensive: total function — no input combination is left undecided.
        for orientation in TabOrientation.allCases {
            for compact in [true, false] {
                _ = TabLayout.presentation(isCompactWidth: compact, orientation: orientation)
            }
        }
    }
}
