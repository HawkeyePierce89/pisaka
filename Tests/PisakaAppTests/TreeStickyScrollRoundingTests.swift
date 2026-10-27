#if os(macOS)
import AppKit
import SwiftUI
import XCTest
import PisakaCore
@testable import Pisaka

/// The scroll rounding `TreeStickyRule.slotTolerance` is sized against.
///
/// **The property.** A click on a pinned copy scrolls through SwiftUI's
/// `ScrollViewProxy.scrollTo`, not through the raw clip view, and `scrollTo`
/// settles a programmatic offset on the backing pixel: the acceptance review's
/// probe, run in this same headless `xcodebuild` host, read backing 1.0 every
/// time and saw a target of `1165.5` land at `1165.0`. The tolerance is half a
/// point so that a landing half a point short still counts as fully under the
/// stack. The rounding was measured at scale 1 only, and no public API forces a
/// window's backing scale, so this suite reads the scale at run time: at
/// exactly 1 it asserts the measured rounding — the settled offset on the
/// whole-point grid, exactly half a point short of the target, and that short
/// fall within the tolerance — and at any other scale only what the tolerance
/// guarantees, `|settled − target| ≤ slotTolerance`. No other scale's rounding
/// is asserted, because nobody measured one.
///
/// **Why the target is derived from the measured row.** At interface scale 1
/// tree rows lie on the half-point grid, so a viewport-parity trick that assumes
/// a whole-point row top can land the target back on the grid and pass on a
/// scroll that rounded nothing. Instead the revealed file's parent folder `t`
/// is measured through the tree's own content-space report
/// (`TreeStickyFoldersKey`, read through `.onPreferenceChange` by a test-local
/// host), the window's height is derived from that measurement so the reveal's
/// centred target lies exactly half a point off the whole-point grid, and the
/// test fails before scrolling — never passing silently — when that target is
/// on the grid or outside the scrollable range.
///
/// **The setup.** One window at interface scale 1, resized once: a temporary
/// project `p` with sixty empty folders `d00`…`d59`, a folder `t/` holding one
/// file `x`, and sixty root files after the folders — `t/x` deep enough that its
/// centred offset is inside the scrollable range. The window starts taller than
/// the whole document, so a first reveal of `t/x` expands `t` while its centred
/// target clamps to the top: no animated scroll is left in flight (one that
/// stalled past a "held still" wait under load and then resumed is what this
/// avoids). `t` is measured, the window is resized to the derived height of
/// about 300 points, the clip view is raw-scrolled to `0`, and a second reveal
/// of `t/x` goes the tree's real path — `scrollTo` at
/// `TreeStickyRule.revealAnchorY`. The animated scroll moves the clip view's
/// bounds and no view's frame, so the wait is a condition on the clip view's
/// origin, failing loudly if it never holds still.
/// That second request reaches a row already drawn, so it also pins that an
/// on-screen row reports a reveal from `.onChange(of: reveal)` — the row half of
/// what `TreeRevealOnScreenTests` pins for a folder.
@MainActor
final class TreeStickyScrollRoundingTests: XCTestCase {

    func testTheRevealScrollSettlesWithinTheSlotTolerance() throws {
        let metrics = InterfaceMetrics(scale: 1)
        let root = try makeProject()
        let file = root.appendingPathComponent("t/x")
        let model = WorkspaceModel()
        model.openFolder(url: root)
        let first = try XCTUnwrap(TreeRevealRequest(after: nil, revealing: file, root: root))
        let state = TreeRevealHostState(reveal: first)

        // Taller than the whole document, so the first reveal's centred target
        // clamps to the top: it expands `t` and leaves no animated scroll in
        // flight to race the measurement or the second reveal.
        let render = try HostedRender(
            size: CGSize(width: 240, height: 3_200),
            root: TreeRevealHost(model: model, state: state, metrics: metrics)
        )
        addTeardownBlock { @MainActor in render.window.close() }
        let scrollView = try XCTUnwrap(Self.scrollView(in: render.host), "the tree hosts no NSScrollView")
        let clip = scrollView.contentView

        // `t`'s node in the content space: its own row and `x`'s, which is the
        // node's last row. Waited for as a condition, failing loudly.
        let deadline = Date().addingTimeInterval(3)
        while expandedT(in: state) == nil, Date() < deadline {
            render.host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        let folder = try XCTUnwrap(expandedT(in: state), "no report for the expanded folder t arrived")
        render.settle()
        XCTAssertEqual(clip.bounds.origin.y, 0, "the first reveal scrolled a window taller than the document")
        let h = metrics.scaled(ChromeGeometry.rowHeight)
        XCTAssertEqual(folder.frame.height, 2 * h, "t's node is not its own row and x's")
        let centre = folder.frame.maxY - h / 2

        // A viewport of about 300 points, its height derived so the centred
        // target lies exactly half a point off the whole-point grid.
        let initialHeight = clip.bounds.height
        let offGrid = (centre - 150).rounded(.down) + 0.5
        let height = 2 * (centre - offGrid)
        render.window.setContentSize(
            NSSize(width: render.host.frame.width, height: render.host.frame.height + (height - initialHeight))
        )
        render.settle()
        let viewportHeight = clip.bounds.height
        let target = centre - viewportHeight / 2
        let documentHeight = try XCTUnwrap(scrollView.documentView, "the scroll view has no document").frame.height

        // Non-vacuity, before scrolling: a target on the grid could pass on a
        // scroll that rounded nothing.
        XCTAssertEqual(target - target.rounded(.down), 0.5,
                       "the target \(target) is not half a point off the grid (viewport \(viewportHeight))")
        XCTAssertGreaterThan(target, 0, "the target \(target) is above the scrollable range")
        XCTAssertLessThan(target, documentHeight - viewportHeight,
                          "the target \(target) is below the scrollable range (document \(documentHeight))")
        guard target - target.rounded(.down) == 0.5, target > 0, target < documentHeight - viewportHeight else {
            return
        }

        // The tree's real reveal path, from the top.
        clip.scroll(to: .zero)
        scrollView.reflectScrolledClipView(clip)
        render.settle()
        XCTAssertEqual(clip.bounds.origin.y, 0, "the raw scroll back to the top did not land")
        state.reveal = TreeRevealRequest(after: first, revealing: file, root: root)
        let settled = try waitForScrollToSettle(clip, in: render)

        let tolerance = CGFloat(TreeStickyRule.slotTolerance)
        let scale = render.window.backingScaleFactor
        if scale == 1 {
            XCTAssertEqual(settled, settled.rounded(.down), "the settled offset \(settled) is off the whole-point grid")
            XCTAssertEqual(settled, target - 0.5, "the scroll did not settle half a point short of \(target)")
            XCTAssertLessThanOrEqual(target - settled, tolerance,
                                     "the rounding \(target - settled) exceeds the slot tolerance")
        } else {
            XCTAssertLessThanOrEqual(abs(settled - target), tolerance,
                                     "at backing scale \(scale) the scroll settled \(settled), target \(target)")
        }
    }

    // MARK: - Helpers

    private func expandedT(in state: TreeRevealHostState) -> TreeStickyFolderReport? {
        state.reports.first { $0.isExpanded && $0.scrollID.hasSuffix("/p/t") }
    }

    /// A real temporary project `p`: sixty empty folders `d00`…`d59`, `t/`
    /// holding one file `x`, and sixty root files `f00`…`f59`.
    private func makeProject() throws -> URL {
        let fm = FileManager.default
        let holder = fm.temporaryDirectory.appendingPathComponent("tree-sticky-rounding-\(UUID().uuidString)")
        let root = holder.appendingPathComponent("p")
        for index in 0..<60 {
            try fm.createDirectory(
                at: root.appendingPathComponent(String(format: "d%02d", index)), withIntermediateDirectories: true
            )
            try Data().write(to: root.appendingPathComponent(String(format: "f%02d", index)))
        }
        let folder = root.appendingPathComponent("t")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: folder.appendingPathComponent("x"))
        addTeardownBlock { try? FileManager.default.removeItem(at: holder) }
        return root
    }

    /// Turns the run loop until the clip view's origin has left the top and
    /// held still for five turns, and answers it; `XCTFail` after three
    /// seconds. A condition, not a window: the animated reveal lands whenever
    /// it lands. Each turn also lays the host out, as `HostedRender.settle()`
    /// does, the window never being ordered on screen.
    private func waitForScrollToSettle(_ clip: NSClipView, in render: HostedRender) throws -> CGFloat {
        let deadline = Date().addingTimeInterval(3)
        var previous = clip.bounds.origin.y
        var stableTurns = 0
        while Date() < deadline {
            render.host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            let origin = clip.bounds.origin.y
            stableTurns = origin == previous && origin > 0 ? stableTurns + 1 : 0
            if stableTurns >= 5 { return origin }
            previous = origin
        }
        XCTFail("the reveal's scroll never settled")
        return clip.bounds.origin.y
    }

    private static func scrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView { return scrollView }
        for subview in view.subviews {
            if let found = scrollView(in: subview) { return found }
        }
        return nil
    }
}

/// The host's reveal, settable after the window is up, and the folder reports
/// it last read. Shared with `TreeRevealOnScreenTests`.
@MainActor
final class TreeRevealHostState: ObservableObject {
    @Published var reveal: TreeRevealRequest?
    var reports: [TreeStickyFolderReport] = []

    init(reveal: TreeRevealRequest?) {
        self.reveal = reveal
    }
}

/// The tree under test, its reveal taken from `state` and its folder reports
/// read back into it. Shared with `TreeRevealOnScreenTests`.
struct TreeRevealHost: View {
    let model: WorkspaceModel
    @ObservedObject var state: TreeRevealHostState
    let metrics: InterfaceMetrics

    var body: some View {
        ProjectTreeView(model: model, reveal: state.reveal)
            .onPreferenceChange(TreeStickyFoldersKey.self) { state.reports = $0 }
            .environment(\.interfaceMetrics, metrics)
            .environment(\.chromeTheme, ChromeTheme(.dark))
    }
}
#endif
