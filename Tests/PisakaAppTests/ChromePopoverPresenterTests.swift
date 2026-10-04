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
/// executes the rule's answer against the right selection. No monitor is
/// installed here — with no root view attached there is no window to scope
/// one to — so nothing in this suite touches the event stream.
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
}
#endif
