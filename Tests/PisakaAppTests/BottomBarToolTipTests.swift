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
/// The bar's widgets carry theirs the same way, so the exact set also holds the
/// project and branch widgets' texts as this fixture draws them — no folder, no
/// repository — each asserted to lie inside the bar's band rather than on a
/// square. The pull-request indicator is drawn only when the checked-out branch
/// has an open pull request, which this fixture's `gh` never reports, so its
/// tooltip is pinned by gating rule ten alone
/// (`ChromeThemeSourceGatingTests`), not here.
///
/// **The widgets' extent.** Each widget's tooltip view takes the widget's own
/// frame through `.background`, so its width is pinned against the widget's
/// `fittingSize`, measured by hosting the widget alone in an `NSHostingView`
/// with the bar's environment. That measure is the ideal width rounded up,
/// while the bar aligns both of the widget's edges to the pixel grid, so the
/// drawn width is the measure or one backing pixel less — at scale 1.8 the
/// project widget measures 147 and draws 146 — and the assertion is exactly
/// that window, not a flat tolerance. The tooltip view must also lie inside
/// the window and overlap neither the other widget's tooltip nor any toggle's
/// square. The vertical claim — inside the bar's band — stays.
///
/// **Why the hit test, and not accessibility.** `BarToolTipView` is not an
/// accessibility element, but neither is a plain `NSView` —
/// `isAccessibilityElement()` answers `false` for both, so asserting it could
/// not tell the tooltip host from any other view and is not asserted. What only the host answers is the hit
/// test: at the centre of a hosted toggle's tooltip view it returns `nil`, while
/// a plain `NSView` given the same frame returns itself, checked side by side;
/// the same hosted instance carries the toggle's tooltip text.
///
/// **What it costs.** Every `hostedBar` call hosts the bar in one titled window,
/// shaped like the main window (`MainWindowChrome` applied), closed in teardown.
/// Each test makes exactly one such call — the completion-state test two, one per
/// state — so the suite makes six windows. The two scale tests each also host the
/// project and branch widgets once in a window-less `NSHostingView` to read their
/// `fittingSize`. Nothing is rendered to a bitmap and no loop creates an AppKit
/// object.
@MainActor
final class BottomBarToolTipTests: XCTestCase {

    func testEveryPanelToggleCarriesItsTitleAsAnAppKitToolTip() throws {
        let tips = try hostedBar(completionOn: true, scale: 1).frames
        for panel in BottomPanel.allCases {
            XCTAssertNotNil(tips[panel.title], "no toggle view carries the tooltip \"\(panel.title)\"; found \(tips.keys.sorted())")
        }
    }

    func testTheCompletionToggleNamesItsStateInItsToolTip() throws {
        XCTAssertNotNil(try hostedBar(completionOn: true, scale: 1).frames["Code completion: On"])
        XCTAssertNotNil(try hostedBar(completionOn: false, scale: 1).frames["Code completion: Off"])
    }

    func testEachToolTipViewIsItsTogglesSquareAndNothingElseCarriesOneAtScale1() throws {
        try assertToolTipViewsAreTheirControls(scale: 1)
    }

    func testEachToolTipViewIsItsTogglesSquareAndNothingElseCarriesOneAtScale1_8() throws {
        try assertToolTipViewsAreTheirControls(scale: 1.8)
    }

    func testTheToolTipViewNeverTakesAClick() throws {
        let bar = try hostedBar(completionOn: true, scale: 1)
        let text = BottomPanel.log.title
        let tip = try XCTUnwrap(bar.views[text], "no tooltip view carries \"\(text)\"")
        XCTAssertEqual(tip.toolTip, text, "the hosted instance carries the toggle's tooltip")
        // `hitTest` takes a point in the superview's coordinates, where the
        // view's frame lives.
        let centre = NSPoint(x: tip.frame.midX, y: tip.frame.midY)
        let plain = NSView(frame: tip.frame)
        XCTAssertTrue(plain.hitTest(centre) === plain, "a plain view of the same frame takes the point")
        XCTAssertNil(tip.hitTest(centre), "the click must land on the SwiftUI button in front")
    }

    // MARK: - Assertions

    private func assertToolTipViewsAreTheirControls(scale: Double) throws {
        let bar = try hostedBar(completionOn: false, scale: scale)
        let tips = bar.frames
        let toggles = BottomPanel.allCases.map(\.title) + ["Code completion: Off"]
        XCTAssertEqual(
            Set(tips.keys), Set(toggles + Self.widgetToolTips),
            "the bar's tooltip views at scale \(scale) are exactly the seven toggles' and the two widgets'"
        )
        let metrics = InterfaceMetrics(scale: scale)
        let side = metrics.scaled(ChromeGeometry.bottomBarToggleSide)
        var squares: [NSRect] = []
        for text in toggles {
            let frame = try XCTUnwrap(tips[text], "no tooltip view carries \"\(text)\" at scale \(scale)")
            XCTAssertEqual(frame.width, side, accuracy: 0.5, "\"\(text)\"'s tooltip view width at scale \(scale)")
            XCTAssertEqual(frame.height, side, accuracy: 0.5, "\"\(text)\"'s tooltip view height at scale \(scale)")
            squares.append(frame)
        }
        // The bar is the window's bottom band; window coordinates grow up.
        let band = metrics.scaled(ChromeGeometry.bottomBarHeight)
        let widths = widgetWidths(metrics: metrics)
        var extents: [NSRect] = []
        for (text, width) in zip(Self.widgetToolTips, widths) {
            let frame = try XCTUnwrap(tips[text], "no tooltip view carries \"\(text)\" at scale \(scale)")
            XCTAssertFalse(frame.isEmpty, "\"\(text)\"'s tooltip view is empty at scale \(scale)")
            XCTAssertGreaterThanOrEqual(frame.minY, -0.5, "\"\(text)\"'s tooltip view leaves the bar at scale \(scale)")
            XCTAssertLessThanOrEqual(frame.maxY, band + 0.5, "\"\(text)\"'s tooltip view leaves the bar at scale \(scale)")
            // `fittingSize` is the widget's ideal width rounded up; the bar
            // aligns both of its edges to the pixel grid, so the drawn width
            // is that ceiling or one backing pixel less — never wider.
            XCTAssertLessThanOrEqual(frame.width, width + 0.01, "\"\(text)\"'s tooltip view is wider than its widget at scale \(scale)")
            XCTAssertGreaterThanOrEqual(frame.width, width - bar.pixel - 0.01, "\"\(text)\"'s tooltip view is narrower than its widget at scale \(scale)")
            XCTAssertGreaterThanOrEqual(frame.minX, bar.windowBounds.minX - 0.5, "\"\(text)\"'s tooltip view leaves the window at scale \(scale)")
            XCTAssertLessThanOrEqual(frame.maxX, bar.windowBounds.maxX + 0.5, "\"\(text)\"'s tooltip view leaves the window at scale \(scale)")
            for square in squares {
                XCTAssertFalse(Self.overlaps(frame, square), "\"\(text)\"'s tooltip view overlaps a toggle's square at scale \(scale)")
            }
            extents.append(frame)
        }
        if extents.count == 2 {
            XCTAssertFalse(Self.overlaps(extents[0], extents[1]), "the two widgets' tooltip views overlap at scale \(scale)")
        }
    }

    /// Two rects share area — touching edges do not count.
    private static func overlaps(_ lhs: NSRect, _ rhs: NSRect) -> Bool {
        let shared = lhs.intersection(rhs)
        return !shared.isNull && shared.width > 0.5 && shared.height > 0.5
    }

    // MARK: - Hosting

    /// The project and branch widgets' tooltips, verbatim from their former
    /// `.help`, as drawn with no folder open.
    private static let widgetToolTips = [
        "Current project — click to switch",
        "Current branch — click to switch or create",
    ]

    /// The bar's tooltip views, keyed by their tooltip, with each one's frame in
    /// window coordinates and the window's content bounds in the same space.
    private struct HostedBar {
        var views: [String: BarToolTipView]
        var frames: [String: NSRect]
        var windowBounds: NSRect
        /// One backing pixel, in points.
        var pixel: CGFloat
    }

    /// The project and branch widgets' widths, in `widgetToolTips` order, each
    /// hosted alone — no window — with the bar's environment, as drawn with no
    /// folder open.
    private func widgetWidths(metrics: InterfaceMetrics) -> [CGFloat] {
        let project = NSHostingView(rootView: ProjectSwitcherView(currentRoot: nil)
            .environment(\.interfaceMetrics, metrics)
            .environment(\.chromeTheme, ChromeTheme(.dark)))
        let branch = NSHostingView(rootView: BranchSwitcherView(model: BranchSwitcherModel(gitService: GitCLIService()))
            .environment(\.interfaceMetrics, metrics)
            .environment(\.chromeTheme, ChromeTheme(.dark)))
        return [project.fittingSize.width, branch.fittingSize.width]
    }

    /// Every `BarToolTipView` in the hosted bar. A text carried twice fails here.
    private func hostedBar(completionOn: Bool, scale: Double) throws -> HostedBar {
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
        MainWindowChrome.apply(to: window, title: MainWindowTitle.defaultTitle)
        addTeardownBlock { @MainActor in window.close() }
        let host = NSHostingView(rootView: VStack(spacing: 0) { Color.clear; bar.zIndex(1) })
        window.contentView = host

        var views: [String: BarToolTipView] = [:]
        var found: [String: NSRect] = [:]
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            host.layoutSubtreeIfNeeded()
            views = [:]
            found = [:]
            var duplicate: String?
            for view in Self.descendants(of: host) {
                guard let tip = view as? BarToolTipView, let text = tip.toolTip else { continue }
                if found[text] != nil { duplicate = text }
                views[text] = tip
                found[text] = tip.convert(tip.bounds, to: nil)
            }
            if let duplicate { XCTFail("two tooltip views carry \"\(duplicate)\"") }
            if found.count == BottomPanel.allCases.count + 1 + Self.widgetToolTips.count, found.values.allSatisfy({ !$0.isEmpty }) { break }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return HostedBar(views: views, frames: found, windowBounds: host.convert(host.bounds, to: nil),
            pixel: 1 / window.backingScaleFactor
        )
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
