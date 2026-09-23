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

    // MARK: - The one table: order and names

    func testAllCasesIsTheBarsOrder() {
        XCTAssertEqual(BottomPanel.allCases, [.terminal, .log, .changes, .problems, .usages, .pullRequests])
    }

    func testEveryPanelHasItsOneTitle() {
        XCTAssertEqual(BottomPanel.terminal.title, "Terminal")
        XCTAssertEqual(BottomPanel.log.title, "Log")
        XCTAssertEqual(BottomPanel.changes.title, "Local Changes")
        XCTAssertEqual(BottomPanel.problems.title, "Problems")
        XCTAssertEqual(BottomPanel.usages.title, "Usages")
        XCTAssertEqual(BottomPanel.pullRequests.title, "Pull Requests")
        XCTAssertEqual(Set(BottomPanel.allCases.map(\.title)).count, BottomPanel.allCases.count)
    }

    // MARK: - The tab rule

    func testTheShowingTabIsAlreadyShowing() {
        for panel in BottomPanel.allCases {
            XCTAssertEqual(BottomPanel.tabActivation(panel, tab: panel), .alreadyShowing)
        }
    }

    func testAnyOtherTabShowsItself() {
        for current in BottomPanel.allCases {
            for tab in BottomPanel.allCases where tab != current {
                XCTAssertEqual(BottomPanel.tabActivation(current, tab: tab), .show(tab))
            }
        }
    }

    func testFromHiddenEveryTabShowsItself() {
        for tab in BottomPanel.allCases {
            XCTAssertEqual(BottomPanel.tabActivation(nil, tab: tab), .show(tab))
        }
    }

    /// A tab's answer goes through the bar's funnel; for every pair, it never
    /// collapses the dock.
    func testATabNeverCollapsesThroughTheFunnel() {
        let states: [BottomPanel?] = [nil] + BottomPanel.allCases.map { $0 }
        for current in states {
            for tab in BottomPanel.allCases {
                guard case .show(let target) = BottomPanel.tabActivation(current, tab: tab) else { continue }
                XCTAssertEqual(BottomPanel.toggled(current, selecting: target), target)
            }
        }
    }
}
