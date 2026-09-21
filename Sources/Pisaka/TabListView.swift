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
/// read by the host.
///
/// The column owns its ground and draws **no pane-edge rule of its own**. Its
/// host is not a stack but the `HSplitView` in `ContentView.editorSplit`, which
/// draws a splitter divider at the column/editor boundary whatever the column
/// does — so a trailing hairline here would be a second rule beside that one.
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
            .padding(.vertical, metrics.scaled(4))
        }
        .background(theme.color(.bgPanel))
    }
}

#endif
