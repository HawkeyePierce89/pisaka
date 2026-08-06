#if os(macOS)
import SwiftUI
import PisakaCore

/// The list of open files (tabs). In `.vertical` orientation it is the column on
/// the left of the editor; in `.horizontal` orientation it is a strip above the
/// editor. Selecting a row switches the active file; each row exposes a close
/// button. The orientation is driven by `SettingsStore.tabOrientation`.
struct TabListView: View {
    @ObservedObject var model: WorkspaceModel
    var orientation: TabOrientation = .vertical
    var onClose: (UUID) -> Void = { _ in }

    var body: some View {
        switch orientation {
        case .vertical:
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.openFiles) { file in
                        row(for: file)
                    }
                }
                .padding(.vertical, 4)
            }
        case .horizontal:
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(model.openFiles) { file in
                        row(for: file)
                    }
                }
                .padding(.horizontal, 4)
            }
        }
    }

    private func row(for file: OpenFile) -> some View {
        TabRowView(
            file: file,
            isActive: file.id == model.selectedID,
            orientation: orientation,
            onSelect: { model.select(file.id) },
            onClose: { onClose(file.id) }
        )
    }
}

#endif
