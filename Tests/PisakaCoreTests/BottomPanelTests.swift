import XCTest
@testable import PisakaCore

final class BottomPanelTests: XCTestCase {
    func testClickingActivePanelCollapsesIt() {
        XCTAssertNil(BottomPanel.toggled(.terminal, selecting: .terminal))
        XCTAssertNil(BottomPanel.toggled(.log, selecting: .log))
        XCTAssertNil(BottomPanel.toggled(.changes, selecting: .changes))
        XCTAssertNil(BottomPanel.toggled(.problems, selecting: .problems))
        XCTAssertNil(BottomPanel.toggled(.usages, selecting: .usages))
        XCTAssertNil(BottomPanel.toggled(.pullRequests, selecting: .pullRequests))
    }

    func testClickingInactivePanelSwitchesToIt() {
        XCTAssertEqual(BottomPanel.toggled(.log, selecting: .terminal), .terminal)
        XCTAssertEqual(BottomPanel.toggled(.terminal, selecting: .log), .log)
        XCTAssertEqual(BottomPanel.toggled(.terminal, selecting: .changes), .changes)
        XCTAssertEqual(BottomPanel.toggled(.changes, selecting: .log), .log)
        XCTAssertEqual(BottomPanel.toggled(.changes, selecting: .problems), .problems)
        XCTAssertEqual(BottomPanel.toggled(.problems, selecting: .log), .log)
        XCTAssertEqual(BottomPanel.toggled(.problems, selecting: .usages), .usages)
        XCTAssertEqual(BottomPanel.toggled(.usages, selecting: .problems), .problems)
        XCTAssertEqual(BottomPanel.toggled(.usages, selecting: .pullRequests), .pullRequests)
        XCTAssertEqual(BottomPanel.toggled(.pullRequests, selecting: .changes), .changes)
    }

    func testFromHiddenShowsTarget() {
        XCTAssertEqual(BottomPanel.toggled(nil, selecting: .terminal), .terminal)
        XCTAssertEqual(BottomPanel.toggled(nil, selecting: .log), .log)
        XCTAssertEqual(BottomPanel.toggled(nil, selecting: .changes), .changes)
        XCTAssertEqual(BottomPanel.toggled(nil, selecting: .problems), .problems)
        XCTAssertEqual(BottomPanel.toggled(nil, selecting: .usages), .usages)
        XCTAssertEqual(BottomPanel.toggled(nil, selecting: .pullRequests), .pullRequests)
    }
}
