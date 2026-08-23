import XCTest
@testable import PisakaCore

final class BottomPanelTests: XCTestCase {
    func testClickingActivePanelCollapsesIt() {
        XCTAssertNil(BottomPanel.toggled(.terminal, selecting: .terminal))
        XCTAssertNil(BottomPanel.toggled(.log, selecting: .log))
        XCTAssertNil(BottomPanel.toggled(.changes, selecting: .changes))
        XCTAssertNil(BottomPanel.toggled(.problems, selecting: .problems))
    }

    func testClickingInactivePanelSwitchesToIt() {
        XCTAssertEqual(BottomPanel.toggled(.log, selecting: .terminal), .terminal)
        XCTAssertEqual(BottomPanel.toggled(.terminal, selecting: .log), .log)
        XCTAssertEqual(BottomPanel.toggled(.terminal, selecting: .changes), .changes)
        XCTAssertEqual(BottomPanel.toggled(.changes, selecting: .log), .log)
        XCTAssertEqual(BottomPanel.toggled(.changes, selecting: .problems), .problems)
        XCTAssertEqual(BottomPanel.toggled(.problems, selecting: .log), .log)
    }

    func testFromHiddenShowsTarget() {
        XCTAssertEqual(BottomPanel.toggled(nil, selecting: .terminal), .terminal)
        XCTAssertEqual(BottomPanel.toggled(nil, selecting: .log), .log)
        XCTAssertEqual(BottomPanel.toggled(nil, selecting: .changes), .changes)
        XCTAssertEqual(BottomPanel.toggled(nil, selecting: .problems), .problems)
    }
}
