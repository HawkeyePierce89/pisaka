#if os(macOS)
import SwiftUI
import PisakaCore

/// A single tab row in the **vertical** tab column: the file's icon, its display
/// name, and the trailing slot the two orientations share.
///
/// The active row is filled in `bgEditor` and carries an `accent` bar as wide as
/// `ChromeGeometry.accentIndicator` on its **leading** edge — the same statement
/// the strip's cell makes with an underline, turned through a right angle: the
/// row reads as the left edge of the editor rather than as a highlighted list
/// entry. Its label is `textPrimary`; every other row's is `textSecondary`. An
/// inactive row under the pointer takes `hoverTint`, which the active row does
/// not need: it is already the one row that is filled.
///
/// The horizontal strip's cell is `TabStripView`'s own, not a second branch
/// here; the two things the orientations genuinely share are views living
/// beside that cell — `TabStatusMark`, so the three-claimant precedence exists
/// once, and `TabFileIcon`, so the untitled-buffer fallback is spelled once.
struct TabRowView: View {
    let file: OpenFile
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false

    /// The interface zone's metrics, inherited from the window root.
    @Environment(\.interfaceMetrics) private var metrics
    /// The chrome's colours, inherited from the window root.
    @Environment(\.chromeTheme) private var theme

    var body: some View {
        HStack(spacing: metrics.scaled(6)) {
            TabFileIcon(file: file)

            Text(file.displayName)
                .font(metrics.scaledFont(.body))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(theme.color(isActive ? .textPrimary : .textSecondary))
                .frame(maxWidth: .infinity, alignment: .leading)

            TabStatusMark(
                isHovering: isHovering,
                isDirty: file.isDirty,
                isActive: isActive,
                onClose: onClose
            )
        }
        .padding(.horizontal, metrics.scaled(ChromeGeometry.rowPaddingX))
        .frame(
            maxWidth: .infinity,
            minHeight: metrics.scaled(ChromeGeometry.verticalTabRowHeight),
            maxHeight: metrics.scaled(ChromeGeometry.verticalTabRowHeight),
            alignment: .leading
        )
        .background(rowBackground)
        .overlay(alignment: .leading) {
            if isActive {
                Rectangle()
                    .fill(theme.color(.accent))
                    .frame(width: metrics.scaled(ChromeGeometry.accentIndicator))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
    }

    /// The row's ground: the editor's own background when it is the active row,
    /// the hover wash when the pointer is in an inactive one, and otherwise
    /// nothing at all — the column's ground shows through.
    private var rowBackground: Color {
        if isActive { return theme.color(.bgEditor) }
        if isHovering { return theme.color(.hoverTint) }
        return Color.clear
    }
}

#endif
