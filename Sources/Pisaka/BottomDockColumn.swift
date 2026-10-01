#if os(macOS)
import SwiftUI

/// The bottom dock's container: the editor split over the divider over the
/// panel slot, in one column pinned to the area it was given and clipped to it.
///
/// `ContentView.mainArea` renders this whenever a dock panel is visible and the
/// editor split directly otherwise. Everything this view knows about *what* it
/// stacks arrives through the three builders — the editor, the divider and the
/// panel slot, the latter two built from the available height, which is the one
/// input `BottomPanelHeightRule` needs. What it owns is the container's
/// geometry: the `GeometryReader`, the stack, the `.topLeading` pin, the named
/// coordinate space and the clip.
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
            // Pinned to the area before it is clipped, because `.clipped()`
            // clips a view to the frame it *reported*, not to the one it was
            // proposed. A column whose children refuse to shrink reports the
            // oversized height, and a clip attached straight to it would then
            // clip to the overflow — the very case it is here to catch. With
            // the frame stated the rect is the `GeometryReader`'s own, and
            // top alignment sends any surplus off the bottom edge, where the
            // clip removes it. The alignment is *leading* as well as top:
            // `.top` alone centers horizontally, and a column wider than the
            // area — the split's own panes state minimum widths the
            // `GeometryReader` erases, so in a narrow window it is — would
            // then have the clip take half the surplus off each side,
            // cutting the project tree's leading edge. Leading keeps the
            // placement the `GeometryReader` gave it before the pin.
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
            // The guarantee behind requirement "never over the bottom bar".
            // The rule's clamp is the *behavior* and the absence of any
            // minimum inside the panel slot is its *precondition*; both rest
            // on arithmetic and on every child honoring its proposal. The
            // clip rests on neither, so no future layout edit, intrinsic
            // minimum in the editor zone's fixed strips (breadcrumb, tab
            // strip, consent banner, find bar) or arithmetic slip can paint
            // outside `mainArea`. Nothing that must escape the window content
            // passes through here: the completion panel, the hover popover
            // and context menus are all separate windows.
            .clipped()
        }
    }
}
#endif
