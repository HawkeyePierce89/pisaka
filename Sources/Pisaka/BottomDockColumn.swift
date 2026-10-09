#if os(macOS)
import SwiftUI

/// The bottom dock's container: the editor split over the divider over the
/// panel slot, in one column pinned to the area it was given.
///
/// `ContentView.mainArea` renders this whenever a dock panel is visible and the
/// editor split directly otherwise. Everything this view knows about *what* it
/// stacks arrives through the three builders — the editor, the divider and the
/// panel slot, the latter two built from the available height, which is the one
/// input `BottomPanelHeightRule` needs. What it owns is the container's
/// geometry: the `GeometryReader`, the stack, the `.topLeading` pin and the
/// named coordinate space.
///
/// **It carries no clip, and must not.** A clip — `.clipped()`, `.clipShape`,
/// `.mask`, at any distance — applied to an ancestor of the platform's
/// `HSplitView` makes the split's panes drop the window's top safe-area inset:
/// the split's own frame stays put while the panes' content rises by the inset
/// and slides under the transparent title bar. That was the lost top row with
/// the dock open, when the editor's split was the platform's, and
/// `BottomDockLayoutTests` records the bisection. The editor's split is now
/// `ChromeSplitView`, which that trap may not reach at all; the column stays
/// unclipped regardless, because nothing has shown the new host is immune. The
/// guarantee the clip used to give — nothing in this column paints over the
/// bottom bar — is the window root's instead: the bar is drawn above the main
/// area on an opaque ground (`ContentView.body`), so whatever spills off this
/// column's bottom edge lands *under* it.
///
/// **Its own file so the real container can be hosted in a test.**
/// `ContentView` needs dozens of models and closures to exist at all, so a
/// layout suite cannot build it; this view needs none of them, and
/// `BottomDockLayoutTests` hosts it in a real window with stub panes.
struct BottomDockColumn<Editor: View, Divider: View, Panel: View>: View {
    /// The name of the coordinate space the column publishes, which the
    /// divider's drag is measured in. Owned by the caller, because the drag that
    /// reads it is built there (see `ContentView.panelColumnSpace`).
    let coordinateSpaceName: String
    @ViewBuilder let editor: () -> Editor
    /// The divider, given the available height so its drag can clamp through
    /// the same rule the slot is sized by.
    @ViewBuilder let divider: (CGFloat) -> Divider
    /// The panel slot *including* its fixed height, given the available height
    /// it is measured against. The column adds nothing to it.
    @ViewBuilder let panel: (CGFloat) -> Panel

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                editor()
                    .frame(maxHeight: .infinity)
                divider(geo.size.height)
                panel(geo.size.height)
            }
            // Pinned to the area, so the column reports the `GeometryReader`'s
            // own rect rather than its content's: a column whose children
            // refuse to shrink would otherwise report the oversized height, and
            // the coordinate space below would be a rect that grows with the
            // overflow. Top alignment sends any surplus off the bottom edge,
            // under the bottom bar, which the window root draws above this
            // column. The alignment is *leading* as well as top: `.top` alone
            // centers horizontally, and a column wider than the area — the
            // split's own panes state minimum widths the `GeometryReader`
            // erases, so in a narrow window it is — would then push half the
            // surplus off the leading edge, cutting the project tree's leading
            // edge. Leading keeps the placement the `GeometryReader` gave it
            // before the pin and sends the whole surplus off the trailing
            // edge, where the window ends.
            .frame(
                width: geo.size.width,
                height: geo.size.height,
                alignment: .topLeading
            )
            // The space the divider drag is measured in — see
            // `ContentView.panelColumnSpace`. Published on the column rather
            // than on the `GeometryReader` so it names exactly the stack the
            // drag moves, and after the frame so it is the pinned rect, which
            // cannot move while the divider does.
            .coordinateSpace(name: coordinateSpaceName)
        }
    }
}
#endif
