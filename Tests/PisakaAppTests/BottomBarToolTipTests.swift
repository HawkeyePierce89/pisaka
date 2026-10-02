#if os(macOS)
import AppKit
import SwiftUI
import XCTest
import PisakaCore
@testable import Pisaka

/// Every bottom-bar toggle exposes its tooltip through the mechanism the bar
/// actually uses: an AppKit `toolTip` on a `BarToolTipView` behind the toggle.
///
/// **Why AppKit, and why this is what is pinned.** `.help` on these toggles never
/// showed in the shipped window, and the headless diagnosis (`app-window.md`)
/// found SwiftUI's tooltip bridge answering the right string at every toggle —
/// so asserting *that* would stay green on the bug. What can be asserted is the
/// replacement: a walk of the hosted view hierarchy finds, for each of the six
/// panels and for the completion switch, a view whose `toolTip` is the text the
/// toggle owes, and whose frame is the toggle's square. Displaying the tooltip
/// itself needs an active application, which a test host is not, so the walk is
/// the strongest claim available here.
///
/// **What it costs.** The bar is hosted once per state in one titled window,
/// shaped like the main window (`MainWindowChrome` applied), closed in teardown;
/// nothing is rendered to a bitmap and no loop creates an AppKit object.
@MainActor
final class BottomBarToolTipTests: XCTestCase {

    func testEveryPanelToggleCarriesItsTitleAsAnAppKitToolTip() throws {
        let tips = try toolTips(completionOn: true, scale: 1)
        for panel in BottomPanel.allCases {
            XCTAssertNotNil(tips[panel.title], "no toggle view carries the tooltip \"\(panel.title)\"; found \(tips.keys.sorted())")
        }
    }

    func testTheCompletionToggleNamesItsStateInItsToolTip() throws {
        XCTAssertNotNil(try toolTips(completionOn: true, scale: 1)["Code completion: On"])
        XCTAssertNotNil(try toolTips(completionOn: false, scale: 1)["Code completion: Off"])
    }

    func testEachToolTipViewIsItsTogglesSquareAndNothingElseCarriesOne() throws {
        for scale in [1.0, 1.8] {
            let tips = try toolTips(completionOn: false, scale: scale)
            XCTAssertEqual(
                Set(tips.keys), Set(BottomPanel.allCases.map(\.title) + ["Code completion: Off"]),
                "the bar's tooltip views at scale \(scale) are exactly the seven toggles'"
            )
            let side = InterfaceMetrics(scale: scale).scaled(ChromeGeometry.bottomBarToggleSide)
            for (text, frame) in tips {
                XCTAssertEqual(frame.width, side, accuracy: 0.5, "\"\(text)\"'s tooltip view width at scale \(scale)")
                XCTAssertEqual(frame.height, side, accuracy: 0.5, "\"\(text)\"'s tooltip view height at scale \(scale)")
            }
        }
    }

    func testTheToolTipViewNeverTakesAClick() {
        let view = BarToolTipView()
        view.frame = NSRect(x: 0, y: 0, width: 22, height: 22)
        XCTAssertNil(view.hitTest(NSPoint(x: 11, y: 11)), "the click must land on the SwiftUI button in front")
        XCTAssertFalse(view.isAccessibilityElement(), "the toggle's own label is its name")
    }

    // MARK: - Hosting

    /// Every `BarToolTipView` in the hosted bar, keyed by its tooltip, with its
    /// frame in window coordinates. A text carried twice fails here.
    private func toolTips(completionOn: Bool, scale: Double) throws -> [String: NSRect] {
        let suite = "pisaka.tests.bottomBarToolTip.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        defaults.set(completionOn, forKey: SettingsStore.Keys.completionEnabled)
        let metrics = InterfaceMetrics(scale: scale)
        let bar = BottomBar(
            branchSwitcher: BranchSwitcherModel(gitService: GitCLIService()),
            pullRequestModel: PullRequestCoordinator(transport: NoGitHubCLI()).model,
            activePanel: .log,
            settings: SettingsStore(defaults: defaults)
        )
        .environment(\.interfaceMetrics, metrics)
        .environment(\.chromeTheme, ChromeTheme(.dark))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000 * scale, height: 200),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        MainWindowChrome.apply(to: window)
        addTeardownBlock { @MainActor in window.close() }
        let host = NSHostingView(rootView: VStack(spacing: 0) { Color.clear; bar.zIndex(1) })
        window.contentView = host

        var found: [String: NSRect] = [:]
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            host.layoutSubtreeIfNeeded()
            found = [:]
            var duplicate: String?
            for view in Self.descendants(of: host) {
                guard let tip = view as? BarToolTipView, let text = tip.toolTip else { continue }
                if found[text] != nil { duplicate = text }
                found[text] = tip.convert(tip.bounds, to: nil)
            }
            if let duplicate { XCTFail("two toggle views carry \"\(duplicate)\"") }
            if found.count == BottomPanel.allCases.count + 1, found.values.allSatisfy({ !$0.isEmpty }) { break }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return found
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }
}

/// A `gh` that is never installed, so nothing could run a process.
private struct NoGitHubCLI: GitHubCLITransport {
    func run(_ command: GitHubCommand) async throws -> GitHubCommandResult {
        throw GitHubCLIError.notInstalled
    }
}
#endif
