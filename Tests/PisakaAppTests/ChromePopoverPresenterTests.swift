#if os(macOS)
import AppKit
import SwiftUI
import XCTest
import PisakaCore
@testable import Pisaka

/// The presenter's wiring, driven without a window: the key-code mapping, the
/// toggle, the row registration and the order "dismiss, then run the row".
///
/// What each key *means* is `PopoverKeyRule`'s and is enumerated in the Core
/// suite; this suite asserts only that the presenter maps codes to keys and
/// executes the rule's answer against the right selection. Monitors are
/// installed only by the cases that attach a root view in a window — the focus
/// hand-back and the host's submenu frame — and each of those dismisses, which
/// removes them; no case posts an event.
@MainActor
final class ChromePopoverPresenterTests: XCTestCase {
    private func emptyContent(_ context: ChromePopoverContext) -> AnyView { AnyView(EmptyView()) }

    func testKeyCodesMapToPopoverKeys() {
        let cases: [(UInt16, PopoverKey)] = [
            (126, .up), (125, .down), (36, .return), (76, .return),
            (53, .escape), (123, .left), (124, .right), (0, .other), (48, .other),
        ]
        for (code, key) in cases {
            XCTAssertEqual(ChromePopoverPresenter.popoverKey(keyCode: code, modifiers: []), key, "key code \(code)")
        }
        // Arrow keys carry the function and numeric-pad flags; those are not chords.
        XCTAssertEqual(
            ChromePopoverPresenter.popoverKey(keyCode: 126, modifiers: [.function, .numericPad]), .up
        )
        XCTAssertEqual(ChromePopoverPresenter.popoverKey(keyCode: 125, modifiers: [.shift]), .down)
        for chord: NSEvent.ModifierFlags in [.command, .control, .option] {
            for code: UInt16 in [126, 125, 36, 76, 53, 123, 124] {
                XCTAssertEqual(
                    ChromePopoverPresenter.popoverKey(keyCode: code, modifiers: chord), .other,
                    "key code \(code) under a chord"
                )
            }
        }
    }

    func testPresentTogglesTheSameIDAndReplacesAnother() {
        let presenter = ChromePopoverPresenter()
        presenter.present(id: "branch", anchor: .zero, content: emptyContent)
        XCTAssertEqual(presenter.openID, "branch")
        presenter.present(id: "project", anchor: .zero, content: emptyContent)
        XCTAssertEqual(presenter.openID, "project")
        presenter.present(id: "project", anchor: .zero, content: emptyContent)
        XCTAssertNil(presenter.openID)
        XCTAssertNil(presenter.content)
    }

    /// Replacing one popover with another leaves none of the first one's rows,
    /// selection or submenu behind for a Return to act on.
    func testReplacingAPopoverClearsTheOldRowsSelectionAndSubmenu() {
        let presenter = ChromePopoverPresenter()
        var ran = false
        presenter.present(id: "branch", anchor: .zero, content: emptyContent)
        presenter.setRows([
            ChromePopoverRowAction(id: "remote", activate: {}, submenu: [
                ChromePopoverSubmenuRow(id: "checkout", title: "Checkout", activate: { ran = true }),
            ]),
        ])
        presenter.openSubmenu(for: "remote")
        XCTAssertNotNil(presenter.submenu)
        presenter.present(id: "project", anchor: .zero, content: emptyContent)
        XCTAssertTrue(presenter.rows.isEmpty)
        XCTAssertNil(presenter.selectedRowID)
        XCTAssertNil(presenter.submenu)
        presenter.activateSelected()
        XCTAssertFalse(ran, "Return ran the replaced popover's row")
        XCTAssertEqual(presenter.openID, "project")
    }

    func testSetRowsSelectsTheFirstRowAndArrowsMoveIt() {
        let presenter = ChromePopoverPresenter()
        presenter.present(id: "branch", anchor: .zero, content: emptyContent)
        presenter.setRows(["a", "b", "c"].map { ChromePopoverRowAction(id: $0, activate: {}) })
        XCTAssertEqual(presenter.selectedRowID, "a")
        XCTAssertTrue(presenter.handle(.down))
        XCTAssertTrue(presenter.handle(.down))
        XCTAssertTrue(presenter.handle(.down))
        XCTAssertEqual(presenter.selectedRowID, "c")
        presenter.setRows(["x", "y"].map { ChromePopoverRowAction(id: $0, activate: {}) })
        XCTAssertEqual(presenter.selectedRowID, "x")
        XCTAssertFalse(presenter.handle(.other), "typing passes through to the field")
        XCTAssertFalse(presenter.handle(.left))
    }

    func testActivationDismissesBeforeRunningTheRow() {
        let presenter = ChromePopoverPresenter()
        var openWhenRun: String??
        presenter.present(id: "branch", anchor: .zero, content: emptyContent)
        presenter.setRows([ChromePopoverRowAction(id: "a", activate: { openWhenRun = presenter.openID })])
        XCTAssertTrue(presenter.handle(.return))
        XCTAssertEqual(openWhenRun, .some(nil), "the row ran after the popover was dismissed")
        XCTAssertNil(presenter.openID)
    }

    func testSubmenuOpensClosesAndActivatesItsOwnSelection() {
        let presenter = ChromePopoverPresenter()
        var ran: [String] = []
        presenter.present(id: "branch", anchor: .zero, content: emptyContent)
        presenter.setRows([
            ChromePopoverRowAction(id: "local", activate: { ran.append("local") }),
            ChromePopoverRowAction(id: "remote", activate: { ran.append("remote") }, submenu: [
                ChromePopoverSubmenuRow(id: "checkout", title: "Checkout", activate: { ran.append("checkout") }),
                ChromePopoverSubmenuRow(id: "create", title: "New Branch", activate: { ran.append("create") }),
            ]),
        ])
        XCTAssertFalse(presenter.handle(.right), "→ on a row with no submenu passes through")
        presenter.handle(.down)
        XCTAssertTrue(presenter.handle(.right))
        XCTAssertEqual(presenter.submenu?.anchorRowID, "remote")
        XCTAssertTrue(presenter.handle(.escape))
        XCTAssertNil(presenter.submenu)
        XCTAssertEqual(presenter.openID, "branch", "Esc closed the submenu alone")
        XCTAssertTrue(presenter.handle(.return), "Return on a submenu row opens it")
        XCTAssertNotNil(presenter.submenu)
        presenter.handle(.down)
        XCTAssertEqual(presenter.selectedRowID, "remote", "the submenu's arrows leave the main selection")
        presenter.handle(.return)
        XCTAssertEqual(ran, ["create"])
        XCTAssertNil(presenter.openID)
        XCTAssertNil(presenter.submenu)
    }

    func testEscapeDismissesWithNoSubmenu() {
        let presenter = ChromePopoverPresenter()
        presenter.present(id: "project", anchor: .zero, content: emptyContent)
        XCTAssertTrue(presenter.handle(.escape))
        XCTAssertNil(presenter.openID)
    }

    // MARK: - The switchers' registration

    private func context(_ selected: String? = nil) -> ChromePopoverContext {
        ChromePopoverContext(maxHeight: 360, selectedRowID: selected, activateRow: { _ in })
    }

    /// The project popover registers "Open Folder…" first, then each recent
    /// project in order; the current project's row only dismisses.
    func testProjectPopoverRegistersItsRowsInDisplayOrder() throws {
        let presenter = ChromePopoverPresenter()
        presenter.present(id: ProjectSwitcherView.popoverID, anchor: .zero, content: emptyContent)
        var opened: [URL] = []
        var folderOpened = 0
        let current = URL(fileURLWithPath: "/tmp/alpha")
        let other = URL(fileURLWithPath: "/tmp/beta")
        let rows = [
            RecentProject(id: "a", url: current, name: "alpha", path: "/tmp/alpha", isCurrent: true),
            RecentProject(id: "b", url: other, name: "beta", path: "/tmp/beta", isCurrent: false),
        ]
        let root = ProjectSwitcherPopover(
            rows: rows,
            context: context(),
            onOpenFolder: { folderOpened += 1 },
            onOpenRecent: { opened.append($0) }
        )
        .environment(\.chromePopoverPresenter, presenter)
        let render = try HostedRender(size: CGSize(width: 320, height: 400), root: root)
        defer { render.window.close() }

        XCTAssertEqual(presenter.rows.map(\.id), ["openFolder", "project:a", "project:b"])
        XCTAssertEqual(presenter.selectedRowID, "openFolder")
        let registered = presenter.rows
        registered[0].activate()
        registered[2].activate()
        XCTAssertEqual(folderOpened, 1, "Open Folder… runs its callback")
        XCTAssertEqual(opened, [other], "a recent row opens its own URL")
        opened = []
        folderOpened = 0
        presenter.activateRow(id: "project:a")
        XCTAssertTrue(opened.isEmpty, "the current project's row only dismisses")
        XCTAssertNil(presenter.openID)
        XCTAssertEqual(folderOpened, 0)
    }

    /// The branch popover registers its action row first; with no branches
    /// that is its only row, and a filter change registers again, returning the
    /// selection to it.
    func testBranchPopoverRegistersTheActionRowFirstAndReRegistersOnFilter() throws {
        let presenter = ChromePopoverPresenter()
        presenter.present(id: BranchSwitcherView.popoverID, anchor: .zero, content: emptyContent)
        var created = 0
        let model = BranchSwitcherModel(gitService: GitCLIService())
        let root = BranchSwitcherPopover(model: model, context: context(), onNewBranch: { created += 1 })
            .environment(\.chromePopoverPresenter, presenter)
        let render = try HostedRender(size: CGSize(width: 320, height: 400), root: root)
        defer { render.window.close() }

        XCTAssertEqual(presenter.rows.map(\.id), [BranchSwitcherPopover.newBranchRowID])
        presenter.setRows([])
        XCTAssertNil(presenter.selectedRowID)
        model.filterText = "x"
        render.settle()
        XCTAssertEqual(presenter.rows.map(\.id), [BranchSwitcherPopover.newBranchRowID])
        XCTAssertEqual(presenter.selectedRowID, BranchSwitcherPopover.newBranchRowID)
        presenter.activateSelected()
        XCTAssertEqual(created, 1)
        XCTAssertNil(presenter.openID)
    }

    /// Branches arriving after the popover opened are registered in display
    /// order, each row runs its own callback with its own branch, and a HEAD
    /// move alone — the ids unchanged — registers again so the rows act on the
    /// new current branch.
    func testBranchPopoverRegistersRefreshedBranchesAndTracksTheCurrentOne() async throws {
        let presenter = ChromePopoverPresenter()
        presenter.present(id: BranchSwitcherView.popoverID, anchor: .zero, content: emptyContent)
        var calls: [String] = []
        let git = ChromePopoverStubGit()
        let model = BranchSwitcherModel(gitService: git)
        let root = BranchSwitcherPopover(
            model: model,
            context: context(),
            onSwitch: { calls.append("switch \($0.shortName)") },
            onCreateFromRemote: { calls.append("create \($0.shortName)") },
            onCheckoutRemote: { calls.append("checkout \($0.shortName)") }
        )
        .environment(\.chromePopoverPresenter, presenter)
        let render = try HostedRender(size: CGSize(width: 320, height: 400), root: root)
        defer { render.window.close() }
        XCTAssertEqual(presenter.rows.map(\.id), [BranchSwitcherPopover.newBranchRowID])

        let repo = URL(fileURLWithPath: "/tmp/repo")
        await model.refresh(root: repo)
        render.settle()
        XCTAssertEqual(
            presenter.rows.map(\.id),
            [BranchSwitcherPopover.newBranchRowID, "local:refs/heads/main", "local:refs/heads/topic", "remote:refs/remotes/origin/main"]
        )
        let rows = Dictionary(uniqueKeysWithValues: presenter.rows.map { ($0.id, $0) })
        try XCTUnwrap(rows["local:refs/heads/main"]).activate()
        try XCTUnwrap(rows["local:refs/heads/topic"]).activate()
        let submenu = try XCTUnwrap(rows["remote:refs/remotes/origin/main"]?.submenu)
        XCTAssertEqual(submenu.map(\.id), ["checkout", "newBranchFromRemote"])
        submenu.forEach { $0.activate() }
        XCTAssertEqual(calls, ["switch topic", "checkout origin/main", "create origin/main"])

        calls = []
        git.currentName = "topic"
        await model.refresh(root: repo)
        render.settle()
        let moved = Dictionary(uniqueKeysWithValues: presenter.rows.map { ($0.id, $0) })
        try XCTUnwrap(moved["local:refs/heads/main"]).activate()
        try XCTUnwrap(moved["local:refs/heads/topic"]).activate()
        XCTAssertEqual(calls, ["switch main"], "the rows still act on the old current branch")
    }

    /// The filter field takes the focus inside the main window, so dismissing
    /// gives it back to what held it at open time; a popover that never took
    /// the focus leaves it where it is.
    func testDismissGivesTheFocusBackOnlyWhenThePopoverTookIt() {
        let presenter = ChromePopoverPresenter()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = NSView(frame: window.contentLayoutRect)
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let filter = NSTextField(frame: NSRect(x: 0, y: 200, width: 200, height: 24))
        let rootStandIn = NSView(frame: content.bounds)
        [editor, filter, rootStandIn].forEach(content.addSubview)
        window.contentView = content
        presenter.attachRootView(rootStandIn)

        XCTAssertTrue(window.makeFirstResponder(editor))
        presenter.present(id: "branch", anchor: .zero, content: emptyContent)
        XCTAssertTrue(window.makeFirstResponder(filter))
        XCTAssertTrue((window.firstResponder as? NSTextView)?.isFieldEditor == true)
        presenter.dismiss()
        XCTAssertTrue(window.firstResponder === editor, "the focus was not given back")

        presenter.present(id: "project", anchor: .zero, content: emptyContent)
        presenter.dismiss()
        XCTAssertTrue(window.firstResponder === editor, "a popover that took no focus moved it")
    }

    /// The host reports the submenu's frame where it draws it — beside the
    /// popover, at the anchor row's top — which is the frame the mouse monitor
    /// reads to tell a press on a submenu row from a press outside.
    func testHostReportsTheSubmenuFrameWhereItDrawsIt() throws {
        let presenter = ChromePopoverPresenter()
        let size = CGSize(width: 800, height: 500)
        let root = ChromePopoverHost(presenter: presenter)
            .frame(width: size.width, height: size.height)
            .coordinateSpace(name: ChromePopoverPresenter.coordinateSpace)
            .environment(\.interfaceMetrics, InterfaceMetrics(scale: 1))
            .environment(\.chromeTheme, ChromeTheme(.dark))
        let render = try HostedRender(size: size, root: root)
        defer { render.window.close() }

        presenter.noteBarTop(470)
        presenter.present(id: "branch", anchor: CGRect(x: 40, y: 474, width: 80, height: 22)) { _ in
            AnyView(Color.clear.frame(width: 300, height: 200))
        }
        presenter.setRows([
            ChromePopoverRowAction(id: "remote", activate: {}, submenu: [
                ChromePopoverSubmenuRow(id: "checkout", title: "Checkout", activate: {}),
                ChromePopoverSubmenuRow(id: "create", title: "New Branch", activate: {}),
            ]),
        ])
        render.settle()
        XCTAssertEqual(presenter.popoverFrame.maxY, 470 - ChromeGeometry.popoverBarGap, accuracy: 0.5)
        XCTAssertEqual(presenter.popoverFrame.minX, 40, accuracy: 0.5)

        presenter.noteRowTop(presenter.popoverFrame.minY + 50, for: "remote")
        presenter.openSubmenu(for: "remote")
        render.settle()
        let expected = PopoverPlacement.submenu(
            popover: presenter.popoverFrame,
            anchorRowTop: presenter.popoverFrame.minY + 50,
            size: CGSize(
                width: ChromeGeometry.popoverWidth,
                height: ChromeGeometry.popoverRowHeight * 2 + ChromeGeometry.popoverListPaddingBottom
            ),
            window: CGRect(origin: .zero, size: size),
            gap: ChromeGeometry.popoverSubmenuGap
        )
        let drawn = presenter.submenuFrame
        XCTAssertEqual(drawn.minX, expected.minX, accuracy: 0.5, "submenu drawn at \(drawn), placed at \(expected)")
        XCTAssertEqual(drawn.minY, expected.minY, accuracy: 0.5, "submenu drawn at \(drawn), placed at \(expected)")
        XCTAssertEqual(drawn.height, expected.height, accuracy: 0.5, "the hand-computed submenu height is not the drawn one")
        presenter.dismiss()
    }
}
#endif
