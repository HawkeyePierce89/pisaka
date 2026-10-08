#if os(macOS)
import SwiftUI
import PisakaCore

/// The list of open files (tabs) as the **vertical column** left of the editor.
/// Selecting a row switches the active file; each row exposes a close button.
///
/// The horizontal strip is `TabStripView`, a view of its own: the two
/// orientations state different chrome — the strip a height and a rule *under*
/// it, this column a width it is given and a boundary its splitter states for
/// it — so neither can be a branch inside the other. The one thing they genuinely share, the
/// trailing slot's three-claimant precedence, is shared as `TabStatusMark`.
/// Which orientation a window shows is still `SettingsStore.tabOrientation`,
/// read by the host, which also bounds the column's width through
/// `TabColumnWidthRule` (a third of the window at most), by way of
/// `TabColumnWidthProbe` and `TabColumnSplit` below.
///
/// The column owns its ground and draws **no pane-edge rule of its own**. Its
/// host is not a stack but the `ChromeSplitView` in `ContentView.editorSplit`,
/// which draws a `hairline` divider at the column/editor boundary whatever the
/// column does — so a trailing hairline here would be a second rule beside that one.
/// `ProjectTreeView`, the pane immediately left of it in the same split view,
/// states that boundary the same way: by leaving it to the splitter. (The
/// strip's bottom rule is a different case — its host *is* a `VStack`, which
/// draws nothing between its children.)
struct TabListView: View {
    @ObservedObject var model: WorkspaceModel
    var onClose: (UUID) -> Void = { _ in }

    /// The interface zone's metrics, inherited from the window root.
    @Environment(\.interfaceMetrics) private var metrics
    /// The chrome's colours, inherited from the window root.
    @Environment(\.chromeTheme) private var theme

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.openFiles) { file in
                    TabRowView(
                        file: file,
                        isActive: file.id == model.selectedID,
                        onSelect: { model.select(file.id) },
                        onClose: { onClose(file.id) }
                    )
                }
            }
            // No top inset: the first row sits flush under the title bar, the
            // design's placement. The bottom keeps a little room past the last
            // row's rule.
            .padding(.bottom, metrics.scaled(4))
        }
        .background(theme.color(.bgPanel))
    }
}

/// The vertical tab column's width bounds, published only when they change.
///
/// The bounds depend on the window's width only below the threshold where a
/// third of the window falls under the scaled maximum; above it every width
/// gives the same bounds. Publishing the width itself would invalidate the
/// column on every point of a resize, so the probe takes the width and the
/// metrics and assigns the bounds only when `TabColumnWidthRule` answers
/// something new. `nil` until the first read: the column's first layout is
/// then given the bounds of an unbounded window, so the split — which
/// adopts the ideal once and does not revisit it — starts at the default width
/// rather than at a maximum computed from nothing.
@MainActor
final class TabColumnWidthProbe: ObservableObject {
    @Published private(set) var bounds: TabColumnWidthRule.Bounds?

    /// Recompute the bounds for a window `windowWidth` points wide under
    /// `metrics`, publishing only when they differ from the current ones.
    func update(windowWidth: CGFloat, metrics: InterfaceMetrics) {
        let next = TabColumnWidthRule.bounds(metrics: metrics, windowWidth: Double(windowWidth))
        if next != bounds { bounds = next }
    }
}

/// Splits the vertical tab column from the editor with `TabColumnWidthProbe`'s
/// bounds. It is the probe's only observer, so a change of bounds re-evaluates
/// this split and not the window root that owns the probe. The split keeps its
/// dragged width across a change of bounds and only re-clamps it, so a window
/// narrowed and widened again gets the column's width back.
struct TabColumnSplit<Column: View, Editor: View>: View {
    @ObservedObject var probe: TabColumnWidthProbe
    /// The editor's floor, already scaled.
    let trailingMinimum: CGFloat
    @ViewBuilder var column: Column
    @ViewBuilder var trailing: Editor

    /// The interface zone's metrics, inherited from the window root.
    @Environment(\.interfaceMetrics) private var metrics

    var body: some View {
        let bounds = probe.bounds ?? TabColumnWidthRule.bounds(metrics: metrics, windowWidth: .infinity)
        ChromeSplitView(
            .horizontal,
            minimum: CGFloat(bounds.minimum),
            ideal: CGFloat(bounds.ideal),
            maximum: CGFloat(bounds.maximum),
            trailingMinimum: trailingMinimum
        ) {
            column
        } trailing: {
            trailing
        }
    }
}
#endif
