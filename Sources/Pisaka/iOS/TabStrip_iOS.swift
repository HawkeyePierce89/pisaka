#if os(iOS)
import SwiftUI
import PisakaCore

/// The open-tabs UI for iOS, the peer of the macOS `TabListView`/`TabRowView`.
/// Two forms, chosen by `RootView_iOS` from the pure `TabLayout.presentation`
/// (size class × `SettingsStore.tabOrientation`):
///
/// - `TabStrip_iOS` — a scrolling strip of tab chips along an axis (a horizontal
///   strip above the editor on a regular-width "horizontal" preference, or a
///   vertical column beside it on the "vertical" preference).
/// - `TabSwitcher_iOS` — a compact single-row switcher (the active file plus a
///   menu of the rest) for compact width (iPhone), where a full strip does not
///   fit.
///
/// All selection/close logic stays in `WorkspaceModel`; these are thin views.
struct TabStrip_iOS: View {
    @ObservedObject var model: WorkspaceModel
    /// The strip's layout axis: `.horizontal` (a row above the editor) or
    /// `.vertical` (a column beside it).
    let axis: Axis
    var onClose: (UUID) -> Void = { _ in }

    var body: some View {
        ScrollView(axis == .horizontal ? .horizontal : .vertical, showsIndicators: false) {
            let layout = axis == .horizontal
                ? AnyLayout(HStackLayout(spacing: 4))
                : AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            layout {
                ForEach(model.openFiles) { file in
                    TabChip_iOS(
                        file: file,
                        isActive: file.id == model.selectedID,
                        fillsWidth: axis == .vertical,
                        onSelect: { model.select(file.id) },
                        onClose: { onClose(file.id) }
                    )
                }
            }
            .padding(axis == .horizontal ? .horizontal : .vertical, 6)
        }
    }
}

/// The compact-width tab switcher: the active file's name with a chevron, tapping
/// it presents a menu of every open tab (with a close affordance). Used on iPhone
/// where a strip would crowd the editor.
struct TabSwitcher_iOS: View {
    @ObservedObject var model: WorkspaceModel
    var onClose: (UUID) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(model.openFiles) { file in
                    Button {
                        model.select(file.id)
                    } label: {
                        Label(
                            tabTitle(file),
                            systemImage: file.id == model.selectedID ? "checkmark" : ""
                        )
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(activeTitle)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Close the active tab.
            if let active = model.selectedID {
                Button {
                    onClose(active)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Close tab")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    /// The active file's title, or a placeholder when none is open.
    private var activeTitle: String {
        guard let file = model.selectedFile else { return "No file open" }
        return tabTitle(file)
    }

    /// The display name plus a bullet when the file has unsaved edits.
    private func tabTitle(_ file: OpenFile) -> String {
        file.isDirty ? "• \(file.displayName)" : file.displayName
    }
}

/// One tab chip: the file's display name, an unsaved-changes dot, and a close
/// button. The active tab is highlighted. In a vertical column it stretches to
/// the column width; in a horizontal strip it hugs its content.
private struct TabChip_iOS: View {
    let file: OpenFile
    let isActive: Bool
    let fillsWidth: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if file.isDirty {
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 7, height: 7)
            }
            Text(file.displayName)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? Color.accentColor.opacity(0.2) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }
}
#endif
