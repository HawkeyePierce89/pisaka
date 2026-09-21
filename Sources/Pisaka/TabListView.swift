#if os(macOS)
import SwiftUI
import PisakaCore

/// The list of open files (tabs) as the **vertical column** left of the editor.
/// Selecting a row switches the active file; each row exposes a close button.
///
/// The horizontal strip is `TabStripView`, a view of its own: it has chrome this
/// column does not (a stated height, a background, a rule under it) and it is
/// drawn from the chrome's colour roles, which this column is not yet — that is
/// the surface-by-surface sweep's work. Which orientation a window shows is
/// still `SettingsStore.tabOrientation`, read by the host.
struct TabListView: View {
    @ObservedObject var model: WorkspaceModel
    var onClose: (UUID) -> Void = { _ in }

    /// The interface zone's metrics, inherited from the window root.
    @Environment(\.interfaceMetrics) private var metrics

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
    }
}

#endif
