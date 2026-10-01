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
/// **The observed failure, on the unfixed container** (1000 × 700 window,
/// top safe-area inset 32, `contentLayoutRect` top edge at y 668): with the dock
/// closed the tree's first row spans y 644–668, flush below the title bar; with
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
///   with nothing else around it, and `.clipShape(Rectangle())` in the
///   clip's place.
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
/// **What this suite pins today** is what holds on the unfixed container: that
/// the harness hosts both branches, that with no panel the top row sits at or
/// below the title bar's bottom edge, and that the bottom bar is measurable and
/// on the window's bottom edge in both. The open-versus-closed equality — same
/// top y, at or below `contentLayoutRect`'s top — is the failure above and
/// arrives together with the fix.
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

    func testWithNoPanelTheTopRowSitsBelowTheTitleBar() throws {
        let closed = BottomDockHarness(panelOpen: false)
        let titleBarBottom = closed.window.contentLayoutRect.maxY
        XCTAssertLessThan(
            titleBarBottom, closed.window.frame.height,
            "the window has no title bar inset — the harness is not the app's window shape"
        )
        for probe in [DockProbe.treeTop, .editorTop] {
            XCTAssertLessThanOrEqual(
                try closed.frame(of: probe).maxY, titleBarBottom,
                "with no panel, \(probe) must sit at or below the title bar's bottom edge"
            )
        }
    }

    func testTheBottomBarIsMeasurableInBothBranches() throws {
        for panelOpen in [false, true] {
            let harness = BottomDockHarness(panelOpen: panelOpen)
            let bar = try harness.frame(of: .bottomBar)
            XCTAssertEqual(bar.minY, 0, "the bottom bar sits on the window's bottom edge (panel open: \(panelOpen))")
            XCTAssertEqual(
                bar.height, DockHarnessRoot.barHeight,
                "the bottom bar keeps its own height (panel open: \(panelOpen))"
            )
        }
    }
}

/// The places the harness measures.
enum DockProbe: Hashable {
    case treeTop, editorTop, bottomBar, panelSlot
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

    init(panelOpen: Bool) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        MainWindowChrome.apply(to: window)
        window.contentView = NSHostingView(
            rootView: DockHarnessRoot(panelOpen: panelOpen, recorder: recorder)
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

/// `ContentView.body`'s shape: the main area over the bottom bar, at the root's
/// minimum size, with the main area either the split alone or the split inside
/// the real `BottomDockColumn`.
struct DockHarnessRoot: View {
    static let barHeight: CGFloat = 28

    let panelOpen: Bool
    let recorder: DockProbeRecorder

    var body: some View {
        VStack(spacing: 0) {
            mainArea
            DockProbeView(probe: .bottomBar, recorder: recorder)
                .frame(height: Self.barHeight)
        }
        .frame(minWidth: 640, minHeight: 400)
    }

    @ViewBuilder
    private var mainArea: some View {
        if panelOpen {
            BottomDockColumn(coordinateSpaceName: "pisaka.test.bottomDockColumn") {
                split
            } divider: { _ in
                Rectangle().frame(height: 5)
            } panel: { _ in
                DockProbeView(probe: .panelSlot, recorder: recorder)
                    .frame(height: 200, alignment: .top)
            }
        } else {
            split
        }
    }

    /// `ContentView.editorSplit`'s structure with horizontal tabs: the tree pane
    /// and the editor pane, each with a top-row probe as its first child.
    private var split: some View {
        HSplitView {
            VStack(spacing: 0) {
                DockProbeView(probe: .treeTop, recorder: recorder).frame(height: 24)
                Spacer(minLength: 0)
            }
            .frame(minWidth: 180, idealWidth: 240, maxWidth: 360)
            VStack(spacing: 0) {
                DockProbeView(probe: .editorTop, recorder: recorder).frame(height: 28)
                Spacer(minLength: 0)
            }
            .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
#endif
