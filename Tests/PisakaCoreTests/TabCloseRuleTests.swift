import XCTest
@testable import PisakaCore

final class TabCloseRuleTests: XCTestCase {

    private let root = URL(fileURLWithPath: "/tmp/proj")

    private func file(_ name: String, dirty: Bool = false) -> OpenFile {
        OpenFile(
            url: root.appendingPathComponent(name),
            text: dirty ? "edited" : "",
            savedText: ""
        )
    }

    private func ids(_ files: [OpenFile], _ indices: [Int]) -> [UUID] {
        indices.map { files[$0].id }
    }

    // MARK: - Targets

    func testEveryCommandWithTheAnchorFirst() {
        let files = [file("a"), file("b"), file("c")]
        let anchor = files[0].id
        XCTAssertEqual(TabCloseRule.targets(.close, in: files, anchor: anchor), ids(files, [0]))
        XCTAssertEqual(TabCloseRule.targets(.closeOthers, in: files, anchor: anchor), ids(files, [1, 2]))
        XCTAssertEqual(TabCloseRule.targets(.closeToTheRight, in: files, anchor: anchor), ids(files, [1, 2]))
        XCTAssertEqual(TabCloseRule.targets(.closeAll, in: files, anchor: anchor), ids(files, [0, 1, 2]))
        XCTAssertEqual(TabCloseRule.targets(.closeSaved, in: files, anchor: anchor), ids(files, [0, 1, 2]))
    }

    func testEveryCommandWithTheAnchorInTheMiddle() {
        let files = [file("a"), file("b"), file("c")]
        let anchor = files[1].id
        XCTAssertEqual(TabCloseRule.targets(.close, in: files, anchor: anchor), ids(files, [1]))
        XCTAssertEqual(TabCloseRule.targets(.closeOthers, in: files, anchor: anchor), ids(files, [0, 2]))
        XCTAssertEqual(TabCloseRule.targets(.closeToTheRight, in: files, anchor: anchor), ids(files, [2]))
        XCTAssertEqual(TabCloseRule.targets(.closeAll, in: files, anchor: anchor), ids(files, [0, 1, 2]))
        XCTAssertEqual(TabCloseRule.targets(.closeSaved, in: files, anchor: anchor), ids(files, [0, 1, 2]))
    }

    func testEveryCommandWithTheAnchorLast() {
        let files = [file("a"), file("b"), file("c")]
        let anchor = files[2].id
        XCTAssertEqual(TabCloseRule.targets(.close, in: files, anchor: anchor), ids(files, [2]))
        XCTAssertEqual(TabCloseRule.targets(.closeOthers, in: files, anchor: anchor), ids(files, [0, 1]))
        XCTAssertEqual(TabCloseRule.targets(.closeToTheRight, in: files, anchor: anchor), [])
        XCTAssertEqual(TabCloseRule.targets(.closeAll, in: files, anchor: anchor), ids(files, [0, 1, 2]))
        XCTAssertEqual(TabCloseRule.targets(.closeSaved, in: files, anchor: anchor), ids(files, [0, 1, 2]))
    }

    func testALoneTabHasNoOthersAndNothingToTheRight() {
        let files = [file("a")]
        let anchor = files[0].id
        XCTAssertEqual(TabCloseRule.targets(.close, in: files, anchor: anchor), [anchor])
        XCTAssertEqual(TabCloseRule.targets(.closeOthers, in: files, anchor: anchor), [])
        XCTAssertEqual(TabCloseRule.targets(.closeToTheRight, in: files, anchor: anchor), [])
        XCTAssertEqual(TabCloseRule.targets(.closeAll, in: files, anchor: anchor), [anchor])
    }

    func testCloseSavedIsEmptyWhenEveryTabIsDirty() {
        let files = [file("a", dirty: true), file("b", dirty: true)]
        XCTAssertEqual(TabCloseRule.targets(.closeSaved, in: files, anchor: files[0].id), [])
    }

    /// The anchor is included when clean and skipped when dirty; order is the
    /// tab order either way.
    func testCloseSavedReturnsExactlyTheCleanTabsInOrder() {
        let files = [file("a"), file("b", dirty: true), file("c"), file("d", dirty: true), file("e")]
        XCTAssertEqual(TabCloseRule.targets(.closeSaved, in: files, anchor: files[1].id), ids(files, [0, 2, 4]))
        XCTAssertEqual(TabCloseRule.targets(.closeSaved, in: files, anchor: files[2].id), ids(files, [0, 2, 4]))
    }

    func testAnUnknownAnchorTargetsNothing() {
        let files = [file("a"), file("b")]
        for command in TabCloseCommand.allCases {
            XCTAssertEqual(TabCloseRule.targets(command, in: files, anchor: UUID()), [], "\(command)")
        }
    }

    // MARK: - Walk

    func testWalkStopsAtTheFirstRefusalAndNeverAsksAgain() {
        let targets = [UUID(), UUID(), UUID(), UUID()]
        var asked: [UUID] = []
        let closed = TabCloseRule.walk(targets) { id in
            asked.append(id)
            return id != targets[1]
        }
        XCTAssertEqual(closed, [targets[0]])
        XCTAssertEqual(asked, [targets[0], targets[1]])
    }

    func testWalkOnAnEmptyListClosesNothing() {
        var asked = 0
        let closed = TabCloseRule.walk([]) { _ in
            asked += 1
            return true
        }
        XCTAssertEqual(closed, [])
        XCTAssertEqual(asked, 0)
    }

    func testWalkClosesEverythingWhenNothingIsRefused() {
        let targets = [UUID(), UUID(), UUID()]
        var asked: [UUID] = []
        let closed = TabCloseRule.walk(targets) { id in
            asked.append(id)
            return true
        }
        XCTAssertEqual(closed, targets)
        XCTAssertEqual(asked, targets)
    }

    func testWalkRefusingTheFirstClosesNothing() {
        let targets = [UUID(), UUID()]
        XCTAssertEqual(TabCloseRule.walk(targets) { _ in false }, [])
    }

    // MARK: - Availability

    func testAnUntitledBufferHasNoPathItemsAndNoLocalHistory() {
        let untitled = OpenFile(url: nil)
        let files = [file("a"), untitled]
        let menu = TabCloseRule.MenuAvailability(files: files, anchor: untitled.id, projectRoot: root)
        XCTAssertFalse(menu.copyPath)
        XCTAssertFalse(menu.copyRelativePath)
        XCTAssertFalse(menu.localHistory)
        XCTAssertTrue(menu.close)
        XCTAssertTrue(menu.closeOthers)
        XCTAssertFalse(menu.closeToTheRight)
    }

    func testAViewerTabHasPathItemsButNoLocalHistory() {
        let viewer = OpenFile(viewerFor: root.appendingPathComponent("data.sqlite"))
        let menu = TabCloseRule.MenuAvailability(files: [viewer], anchor: viewer.id, projectRoot: root)
        XCTAssertTrue(menu.copyPath)
        XCTAssertTrue(menu.copyRelativePath)
        XCTAssertFalse(menu.localHistory)
        XCTAssertTrue(menu.closeSaved)
    }

    func testALoneTextTab() {
        let lone = file("a")
        let menu = TabCloseRule.MenuAvailability(files: [lone], anchor: lone.id, projectRoot: root)
        XCTAssertTrue(menu.close)
        XCTAssertFalse(menu.closeOthers)
        XCTAssertFalse(menu.closeToTheRight)
        XCTAssertTrue(menu.closeAll)
        XCTAssertTrue(menu.closeSaved)
        XCTAssertTrue(menu.copyPath)
        XCTAssertTrue(menu.copyRelativePath)
        XCTAssertTrue(menu.localHistory)
    }

    func testTheLastTabHasNothingToTheRight() {
        let files = [file("a"), file("b", dirty: true)]
        let menu = TabCloseRule.MenuAvailability(files: files, anchor: files[1].id, projectRoot: root)
        XCTAssertTrue(menu.closeOthers)
        XCTAssertFalse(menu.closeToTheRight)
        XCTAssertTrue(menu.closeSaved)
        for command in TabCloseCommand.allCases {
            XCTAssertEqual(
                menu.isEnabled(command),
                !TabCloseRule.targets(command, in: files, anchor: files[1].id).isEmpty,
                "\(command)"
            )
        }
    }

    func testAFileOutsideTheRootHasNoRelativePathOrTreeItem() {
        let outside = OpenFile(url: URL(fileURLWithPath: "/elsewhere/x.swift"))
        let menu = TabCloseRule.MenuAvailability(files: [outside], anchor: outside.id, projectRoot: root)
        XCTAssertTrue(menu.copyPath)
        XCTAssertFalse(menu.copyRelativePath)
        XCTAssertTrue(menu.localHistory)
    }

    func testNoProjectRootHasNoRelativePath() {
        let lone = file("a")
        let menu = TabCloseRule.MenuAvailability(files: [lone], anchor: lone.id, projectRoot: nil)
        XCTAssertFalse(menu.copyRelativePath)
        XCTAssertTrue(menu.copyPath)
    }

    func testAnUnknownAnchorDisablesEverything() {
        let menu = TabCloseRule.MenuAvailability(files: [file("a")], anchor: UUID(), projectRoot: root)
        for command in TabCloseCommand.allCases {
            XCTAssertFalse(menu.isEnabled(command), "\(command)")
        }
        XCTAssertFalse(menu.copyPath)
        XCTAssertFalse(menu.copyRelativePath)
        XCTAssertFalse(menu.localHistory)
    }
}
