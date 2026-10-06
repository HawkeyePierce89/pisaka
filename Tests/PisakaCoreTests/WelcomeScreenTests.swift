import Foundation
import PisakaCore
import XCTest

final class WelcomeScreenTests: XCTestCase {

    private func row(_ name: String, current: Bool = false) -> RecentProject {
        let path = "/projects/\(name)"
        return RecentProject(id: path, url: URL(fileURLWithPath: path), name: name, path: path, isCurrent: current)
    }

    // MARK: - When it shows

    func testShowsOnlyWithNoFolderAndNoTab() {
        let root = URL(fileURLWithPath: "/projects/app")
        XCTAssertTrue(WelcomeScreen.shows(projectRoot: nil, openFileCount: 0))
        XCTAssertFalse(WelcomeScreen.shows(projectRoot: nil, openFileCount: 1))
        XCTAssertFalse(WelcomeScreen.shows(projectRoot: root, openFileCount: 0))
        XCTAssertFalse(WelcomeScreen.shows(projectRoot: root, openFileCount: 3))
    }

    // MARK: - Recents

    func testRecentsKeepOrderAndCap() {
        let rows = (0..<15).map { row("p\($0)") }
        let recents = WelcomeScreen.recents(rows)
        XCTAssertEqual(recents.map(\.name), (0..<10).map { "p\($0)" })
        XCTAssertEqual(WelcomeScreen.recents(rows, cap: 3).map(\.name), ["p0", "p1", "p2"])
        XCTAssertEqual(WelcomeScreen.recents(rows, cap: 0), [])
        XCTAssertEqual(WelcomeScreen.recents(rows, cap: -1), [])
    }

    func testRecentsDropTheCurrentRowBeforeCapping() {
        let rows = [row("a"), row("b", current: true), row("c"), row("d")]
        XCTAssertEqual(WelcomeScreen.recents(rows, cap: 3).map(\.name), ["a", "c", "d"])
    }

    func testEmptyRecentsMeanTheHint() {
        XCTAssertTrue(WelcomeScreen.recents([]).isEmpty)
        XCTAssertTrue(WelcomeScreen.recents([row("only", current: true)]).isEmpty)
    }

    // MARK: - Actions, footer, chords

    func testActionsTable() {
        XCTAssertEqual(WelcomeAction.allCases, [.openFolder, .openFile, .newFile, .openLeetCodeProblem])
        XCTAssertEqual(WelcomeAction.allCases.map(\.title),
                       ["Open Folder…", "Open File…", "New File", "Open LeetCode Problem…"])
        XCTAssertEqual(WelcomeAction.allCases.map(\.menuTitle),
                       ["Open Folder…", "Open…", "New File", "Open Problem…"])
        XCTAssertEqual(WelcomeAction.allCases.map(\.chord.display), ["⇧⌘O", "⌘O", "⌘N", "⌥⌘P"])
        XCTAssertEqual(WelcomeAction.openFolder.glyph, .folderOpen)
        XCTAssertEqual(WelcomeAction.openFile.glyph, .fileText)
        XCTAssertEqual(WelcomeAction.newFile.glyph, .plus)
        XCTAssertEqual(WelcomeAction.openLeetCodeProblem.glyph, .fileCode)
    }

    func testFooterTable() {
        XCTAssertEqual(WelcomeFooterEntry.allCases, [.terminal, .browseProblems, .zoom])
        XCTAssertEqual(WelcomeFooterEntry.allCases.map(\.display),
                       ["Show Terminal ⇧⌘T", "Browse Problems… ⇧⌘B", "Zoom ⌘+ ⌘− ⌘0"])
        XCTAssertEqual(WelcomeFooterEntry.zoom.shortcuts.map(\.menuTitle), ["Zoom In", "Zoom Out", "Reset Zoom"])
        XCTAssertEqual(WelcomeFooterEntry.zoom.chordsDisplay, "⌘+ ⌘− ⌘0")
    }

    func testChordDisplayUsesCanonicalModifierOrder() {
        XCTAssertEqual(WelcomeChord("a", [.command, .shift, .option, .control]).display, "⌃⌥⇧⌘A")
        XCTAssertEqual(WelcomeChord("-", [.command]).display, "⌘−")
        XCTAssertEqual(WelcomeChord("+", [.command]).display, "⌘+")
        XCTAssertEqual(WelcomeChord("0", []).display, "0")
    }

    // MARK: - Keyboard selection

    func testIndexMapsToActionsThenRecents() {
        let urls = [URL(fileURLWithPath: "/a"), URL(fileURLWithPath: "/b")]
        let selection = WelcomeSelection(recents: urls)
        XCTAssertEqual(selection.selectedIndex, 0)
        XCTAssertEqual(selection.target(at: 0), .action(.openFolder))
        XCTAssertEqual(selection.target(at: 3), .action(.openLeetCodeProblem))
        XCTAssertEqual(selection.target(at: 4), .recent(urls[0]))
        XCTAssertEqual(selection.target(at: 5), .recent(urls[1]))
        XCTAssertNil(selection.target(at: 6))
        XCTAssertNil(selection.target(at: -1))
        XCTAssertEqual(selection.column(of: 3), .actions)
        XCTAssertEqual(selection.column(of: 4), .recents)
    }

    func testArrowsClampAndReturnActivatesTheSelection() {
        let url = URL(fileURLWithPath: "/a")
        var selection = WelcomeSelection(recents: [url])
        selection = selection.movedUp()
        XCTAssertEqual(selection.selectedTarget, .action(.openFolder))
        for _ in 0..<10 { selection = selection.movedDown() }
        XCTAssertEqual(selection.selectedIndex, 4)
        XCTAssertEqual(selection.selectedTarget, .recent(url))
    }

    func testSwitchingColumns() {
        let urls = [URL(fileURLWithPath: "/a"), URL(fileURLWithPath: "/b")]
        let selection = WelcomeSelection(recents: urls).selecting(2)
        let inRecents = selection.switchedColumn()
        XCTAssertEqual(inRecents.selectedIndex, 4)
        XCTAssertEqual(inRecents.movedDown().switchedColumn().selectedIndex, 0)

        let noRecents = WelcomeSelection(recents: []).selecting(1)
        XCTAssertEqual(noRecents.switchedColumn().selectedIndex, 1)
        XCTAssertEqual(noRecents.selecting(99).selectedIndex, 3)

        let empty = WelcomeSelection(actions: [], recents: [])
        XCTAssertNil(empty.selectedIndex)
        XCTAssertNil(empty.selectedTarget)
        XCTAssertNil(empty.switchedColumn().selectedIndex)
    }
}
