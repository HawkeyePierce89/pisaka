#if os(macOS)
import SwiftUI
import PisakaCore

/// A single tab row: the file's display name, an unsaved-changes indicator, and a
/// close button. The active tab is highlighted. In `.vertical` orientation the row
/// stretches to the column width; in `.horizontal` orientation it hugs its content
/// so tabs sit side by side in a strip.
struct TabRowView: View {
    let file: OpenFile
    let isActive: Bool
    var orientation: TabOrientation = .vertical
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Text(file.displayName)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(
                    maxWidth: orientation == .vertical ? .infinity : nil,
                    alignment: .leading
                )

            // Close button on hover; otherwise the dirty dot (if any).
            ZStack {
                if isHovering {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .help("Close")
                } else if file.isDirty {
                    Circle()
                        .fill(Color.secondary)
                        .frame(width: 7, height: 7)
                        .help("Unsaved changes")
                }
            }
            .frame(width: 14, height: 14)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        // A horizontal-strip tab hugs its content (no full-width stretch); a
        // vertical-column tab fills the column.
        .frame(maxWidth: orientation == .vertical ? .infinity : nil, alignment: .leading)
        .background(isActive ? Color.accentColor.opacity(0.2) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
    }
}

#endif
