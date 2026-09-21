#if os(macOS)
import SwiftUI
import PisakaCore

/// The list of open files (tabs) as the **vertical column** left of the editor.
/// Selecting a row switches the active file; each row exposes a close button.
///
/// The horizontal strip is `TabStripView`, a view of its own: the two
/// orientations state different chrome — the strip a height and a rule *under*
/// it, this column a width it is given and a rule *beside* it — so neither can
/// be a branch inside the other. The one thing they genuinely share, the
/// trailing slot's three-claimant precedence, is shared as `TabStatusMark`.
/// Which orientation a window shows is still `SettingsStore.tabOrientation`,
/// read by the host.
///
/// The column owns its ground and its trailing hairline for the reason the strip
/// owns its bottom one: the active row is filled in the editor's own background
/// so it reads as part of the pane beside it, and a rule the *host* drew would
/// sit between the two and undo that.
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
        // The rule between the column and the editor, on the column's own
        // trailing edge, so an active row filled in `bgEditor` can sit above it
        // and merge into the editor beside it.
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(theme.color(.hairline))
                .frame(width: metrics.scaled(ChromeGeometry.hairlineWidth))
        }
    }
}

#endif
