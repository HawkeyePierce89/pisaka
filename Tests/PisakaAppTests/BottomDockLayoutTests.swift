#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import Pisaka

/// The main window's top row with the bottom dock open and closed, measured in
/// a real window.
///
/// **The bug.** With any dock panel open the whole editor split — the project
/// tree's header, the tab strip — slid up under the transparent title bar by
/// the title bar's height, and with the dock closed it sat correctly. Nothing in
/// `swift test` can see a layout, and no static rule names a symptom that only
/// exists once AppKit has placed the views, so this suite hosts the real
/// container, `BottomDockColumn`, in a real `NSWindow` configured the way the
/// app's is: `.titled` / `.resizable` / `.fullSizeContentView` and
/// `MainWindowChrome.apply(to:)`. The root is body-shaped — the main area over a
/// stub bottom bar, carrying the root's minimum frame — and the stub editor is
/// an `HSplitView`, the real `editorSplit`'s structure, with a probe as each
/// pane's first child. A probe is an `NSView`, so its frame is read in window
/// coordinates with no SwiftUI coordinate space in between.
///
/// **The observed failure, on the container as it was** — pinned, then
/// clipped — in a 1000 × 700 window with a top safe-area inset of 32 and
/// `contentLayoutRect`'s top edge at y 668: with the dock closed the tree's
/// first row spans y 644–668, flush below the title bar; with
/// it open it spans y 676–700, its top at the window's top edge. The offset is
/// the inset exactly, which is why it never grew with the interface scale.
///
/// **The cause, bisected in this harness.** The split's *own* frame is
/// identical in every variant below — its top edge at y 668 — so the split is
/// placed correctly; what moves is the panes' content inside it, up by the top
/// inset, out of the split's own frame and under the title bar. Measured, one
/// construct at a time, around the same `HSplitView`:
///
/// - `GeometryReader` alone; with the `.topLeading` pin; with the pin and the
///   named coordinate space — **correct** (top at y 668).
/// - The pin followed by `.clipped()` — **shifted** (y 700). So is the column
///   clipped without the pin, the column clipped without any `GeometryReader`,
///   the split inside a plain `VStack` that is clipped, the bare split clipped
///   with nothing else around it, and `.clipShape(Rectangle())`,
///   `.mask(Rectangle())` or `.compositingGroup().clipped()` in the clip's
///   place. With an editor that refuses to shrink it is far worse: the clipped
///   column sent the tree's row to y 1137, past the window's top edge.
/// - The real container with a plain `VStack` in the split's place —
///   **correct**.
///
/// So the single construct is **a clip applied to an ancestor of the
/// `HSplitView`**: any clip, at any distance, with or without the reader.
/// The `GeometryReader`, the pin and the coordinate space are innocent, and the
/// split is the necessary second half — a pure-SwiftUI stack under the same
/// clip keeps the inset. The dock branch was the only one with a clip above the
/// split, which is the whole of the open-versus-closed difference.
///
/// **The fix** is to take the clip off: `BottomDockColumn` carries none, and the
/// guarantee it gave — nothing in the column paints over the bottom bar — is the
/// window root's, which draws the bar above the main area (`.zIndex(1)`) on its
/// own opaque ground. `BottomPanelSourceGatingTests` refuses a clip of any
/// spelling in the column's file.
///
/// **What this suite pins**: the top row's y is identical with the dock open and
/// closed and sits at or below the title bar's bottom edge — with horizontal
/// tabs, at interface scale 1.8 with every stub row and floor scaled, and with
/// the vertical-tabs split's three panes; the bottom bar's frame is the same in
/// both branches and the panel slot ends at or above its top edge; and with an
/// editor that refuses to shrink, the overflow lands under the bar — the bar's
/// pixels are its own colour and a click on it reaches it.
@MainActor
final class BottomDockLayoutTests: XCTestCase {

    func testTheHarnessHostsBothBranches() throws {
        let closed = BottomDockHarness(panelOpen: false)
        let open = BottomDockHarness(panelOpen: true)
        for probe in [DockProbe.treeTop, .editorTop, .bottomBar] {
            XCTAssertNotNil(closed.recorder.views[probe], "the closed branch never built \(probe)")
            XCTAssertNotNil(open.recorder.views[probe], "the open branch never built \(probe)")
        }
        XCTAssertNil(
            closed.recorder.views[.panelSlot],
            "the closed branch renders the split directly, with no panel slot"
        )
        XCTAssertNotNil(
            open.recorder.views[.panelSlot],
            "the open branch renders the split inside BottomDockColumn, with its panel slot"
        )
    }

    func testTheTopRowIsTheSameWithTheDockOpenAndClosed() throws {
        try assertTopRowUnmoved(DockHarnessShape())
    }

    func testTheTopRowIsTheSameAtInterfaceScaleOnePointEight() throws {
        try assertTopRowUnmoved(DockHarnessShape(scale: 1.8))
    }

    func testTheTopRowIsTheSameWithVerticalTabs() throws {
        try assertTopRowUnmoved(DockHarnessShape(verticalTabs: true))
    }

    func testTheBottomBarIsUnchangedAndThePanelEndsAboveIt() throws {
        let closed = BottomDockHarness(panelOpen: false)
        let open = BottomDockHarness(panelOpen: true)
        let closedBar = try closed.frame(of: .bottomBar)
        let openBar = try open.frame(of: .bottomBar)
        XCTAssertEqual(closedBar.minY, 0, "the bottom bar sits on the window's bottom edge")
        XCTAssertEqual(closedBar.height, DockHarnessRoot.barHeight, "the bottom bar keeps its own height")
        XCTAssertEqual(openBar, closedBar, "opening the dock must not move or resize the bottom bar")
        XCTAssertGreaterThanOrEqual(
            try open.frame(of: .panelSlot).minY, openBar.maxY,
            "the panel slot must end at or above the bottom bar's top edge"
        )
    }

    func testAnOverflowingColumnLandsUnderTheBottomBar() throws {
        let harness = BottomDockHarness(panelOpen: true, shape: DockHarnessShape(overflowing: true))
        let bar = try harness.frame(of: .bottomBar)
        XCTAssertLessThan(
            try harness.frame(of: .panelSlot).minY, bar.maxY,
            "the stub editor no longer overflows the column — the case below is not being exercised"
        )
        let content = try XCTUnwrap(harness.window.contentView)
        let rep = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: rep)
        let scale = CGFloat(rep.pixelsHigh) / content.bounds.height
        for x in [bar.minX + 40, bar.midX, bar.maxX - 40] {
            let color = try XCTUnwrap(
                rep.colorAt(x: Int(x * scale), y: rep.pixelsHigh - 1 - Int(bar.midY * scale))?
                    .usingColorSpace(.sRGB)
            )
            // Red against the panes' green and blue, with room for the colour
            // space the bitmap is cached in.
            XCTAssertGreaterThan(color.redComponent, 0.8, "the overflow painted over the bar at x \(x)")
            XCTAssertLessThan(color.greenComponent, 0.3, "the overflow painted over the bar at x \(x)")
            XCTAssertLessThan(color.blueComponent, 0.3, "the overflow painted over the bar at x \(x)")
            XCTAssertTrue(
                content.hitTest(NSPoint(x: x, y: bar.midY)) === harness.recorder.views[.bottomBar],
                "a click on the bar at x \(x) reaches the overflow instead of the bar"
            )
        }
    }

    /// The top-row probes' top edges, dock open versus closed, in one shape.
    private func assertTopRowUnmoved(
        _ shape: DockHarnessShape,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let closed = BottomDockHarness(panelOpen: false, shape: shape)
        let open = BottomDockHarness(panelOpen: true, shape: shape)
        let titleBarBottom = closed.window.contentLayoutRect.maxY
        XCTAssertLessThan(
            titleBarBottom, closed.window.frame.height,
            "the window has no title bar inset — the harness is not the app's window shape",
            file: file, line: line
        )
        for probe in shape.topRowProbes {
            let closedTop = try closed.frame(of: probe).maxY
            let openTop = try open.frame(of: probe).maxY
            XCTAssertEqual(
                openTop, closedTop,
                "\(probe) moves when the dock opens (\(shape))",
                file: file, line: line
            )
            XCTAssertLessThanOrEqual(
                closedTop, titleBarBottom,
                "\(probe) sits under the title bar with the dock closed (\(shape))",
                file: file, line: line
            )
            XCTAssertLessThanOrEqual(
                openTop, titleBarBottom,
                "\(probe) sits under the title bar with the dock open (\(shape))",
                file: file, line: line
            )
        }
    }
}

/// The places the harness measures.
enum DockProbe: Hashable {
    case treeTop, tabListTop, editorTop, bottomBar, panelSlot
}

/// What the stub split looks like: the interface scale its rows and floors are
/// multiplied by, whether it has the vertical-tabs tab-list pane, and whether
/// its panes refuse to shrink below a height no window here can give them.
struct DockHarnessShape: CustomStringConvertible {
    var scale: CGFloat = 1
    var verticalTabs = false
    var overflowing = false

    var topRowProbes: [DockProbe] {
        verticalTabs ? [.treeTop, .tabListTop, .editorTop] : [.treeTop, .editorTop]
    }

    var description: String {
        "scale \(scale), \(verticalTabs ? "vertical" : "horizontal") tabs"
            + (overflowing ? ", overflowing" : "")
    }
}

/// Holds each probe's `NSView` so its frame can be read in window coordinates.
@MainActor
final class DockProbeRecorder {
    var views: [DockProbe: NSView] = [:]
}

/// An empty `NSView` that registers itself with the recorder when built.
struct DockProbeView: NSViewRepresentable {
    let probe: DockProbe
    let recorder: DockProbeRecorder

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        recorder.views[probe] = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// A real window shaped like the main window, hosting `DockHarnessRoot`.
@MainActor
final class BottomDockHarness {
    let window: NSWindow
    let recorder = DockProbeRecorder()

    /// The window is 1000 × 700 at scale 1 and grows with the scale, so the
    /// scaled root floor (640 × 400) and the scaled panes' floors still fit.
    init(panelOpen: Bool, shape: DockHarnessShape = DockHarnessShape()) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000 * shape.scale, height: 700 * shape.scale),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        MainWindowChrome.apply(to: window)
        window.contentView = NSHostingView(
            rootView: DockHarnessRoot(panelOpen: panelOpen, shape: shape, recorder: recorder)
        )
        // The panes of an `HSplitView` are placed on a later pass than their
        // container, so one turn of the main run loop lets the split finish
        // before anything is measured.
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    func frame(of probe: DockProbe) throws -> NSRect {
        let view = try XCTUnwrap(recorder.views[probe], "probe \(probe) was never built")
        return view.convert(view.bounds, to: nil)
    }
}

/// `ContentView.body`'s shape: the main area over the bottom bar — drawn above
/// it on an opaque ground, as the real bar is — at the root's minimum size, with
/// the main area either the split alone or the split inside the real
/// `BottomDockColumn`.
struct DockHarnessRoot: View {
    static let barHeight: CGFloat = 28

    let panelOpen: Bool
    let shape: DockHarnessShape
    let recorder: DockProbeRecorder

    var body: some View {
        VStack(spacing: 0) {
            mainArea
            DockProbeView(probe: .bottomBar, recorder: recorder)
                .frame(height: Self.barHeight)
                .background(Color(red: 1, green: 0, blue: 0))
                .zIndex(1)
        }
        .frame(minWidth: scaled(640), minHeight: scaled(400))
    }

    private func scaled(_ value: CGFloat) -> CGFloat { value * shape.scale }

    @ViewBuilder
    private var mainArea: some View {
        if panelOpen {
            BottomDockColumn(coordinateSpaceName: "pisaka.test.bottomDockColumn") {
                split
            } divider: { _ in
                Rectangle().frame(height: scaled(5))
            } panel: { _ in
                DockProbeView(probe: .panelSlot, recorder: recorder)
                    .frame(height: scaled(200), alignment: .top)
            }
        } else {
            split
        }
    }

    /// `ContentView.editorSplit`'s structure: the tree pane, the tab-list pane
    /// with vertical tabs, and the editor pane, each with a top-row probe as its
    /// first child.
    private var split: some View {
        HSplitView {
            pane(.treeTop, rowHeight: 24, color: .green)
                .frame(minWidth: scaled(180), idealWidth: scaled(240), maxWidth: scaled(360))
            if shape.verticalTabs {
                pane(.tabListTop, rowHeight: 28, color: .green)
                    .frame(minWidth: scaled(180), idealWidth: scaled(220), maxWidth: scaled(360))
            }
            pane(.editorTop, rowHeight: 28, color: .blue)
                .frame(minWidth: scaled(320), maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func pane(_ probe: DockProbe, rowHeight: CGFloat, color: Color) -> some View {
        VStack(spacing: 0) {
            DockProbeView(probe: probe, recorder: recorder).frame(height: scaled(rowHeight))
            if shape.overflowing {
                color.frame(minHeight: scaled(900))
            } else {
                Spacer(minLength: 0)
            }
        }
    }
}
#endif
