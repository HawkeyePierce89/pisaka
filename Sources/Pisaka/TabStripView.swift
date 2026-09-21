#if os(macOS)
import SwiftUI
import PisakaCore

/// The horizontal tab strip above the editor: the whole strip's chrome, owned
/// here rather than by its host.
///
/// Split out of `TabListView` rather than left as a branch inside it, for two
/// reasons. The vertical column is explicitly out of this part's scope and must
/// keep drawing exactly what it drew — one view serving both orientations would
/// have to keep a system colour for one of its two branches, which
/// `ChromeThemeSourceGatingTests` (rightly) forbids a gated file. And the strip
/// is not a list of rows that happens to run sideways: it has chrome of its own
/// — a height, a background, a bottom rule the editor below it sits under — that
/// a row view cannot state.
///
/// Which is why the host adds neither a `.frame(height:)` nor a `Divider()`: the
/// strip states its own height (`ChromeGeometry.tabStripHeight`) and draws its
/// own hairline, so the two cannot disagree.
struct TabStripView: View {
    @ObservedObject var model: WorkspaceModel
    var onClose: (UUID) -> Void = { _ in }

    /// The interface zone's metrics, inherited from the window root.
    @Environment(\.interfaceMetrics) private var metrics
    /// The chrome's colours, inherited from the window root.
    @Environment(\.chromeTheme) private var theme

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(model.openFiles) { file in
                    TabStripCell(
                        file: file,
                        isActive: file.id == model.selectedID,
                        onSelect: { model.select(file.id) },
                        onClose: { onClose(file.id) }
                    )
                }
            }
        }
        .frame(height: metrics.scaled(ChromeGeometry.tabStripHeight))
        .background(theme.color(.bgPanel))
        // The rule between the strip and the editor. Drawn as an overlay on the
        // strip's own bottom edge so an active tab — which is filled in the
        // editor's own background, to read as part of it — can sit *above* it
        // and merge into the editor below.
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.color(.hairline))
                .frame(height: metrics.scaled(ChromeGeometry.hairlineWidth))
        }
    }
}

/// One tab in the horizontal strip.
///
/// The active tab is filled in `bgEditor` and carries an `accent` underline as
/// tall as `ChromeGeometry.accentIndicator`, so it reads as the top edge of the
/// editor rather than as a highlighted row. Its label is `textPrimary`; every
/// other tab's is `textSecondary`.
private struct TabStripCell: View {
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
            // The file icon, drawn monochrome: `FileIcon` answers a symbol *and*
            // a semantic tint, and the strip deliberately reads only the symbol.
            // A row of tinted glyphs competes with the accent underline for the
            // eye, and the underline is the one thing the strip has to say.
            Image(systemName: iconSymbolName)
                .font(.system(size: metrics.scaled(11)))
                .foregroundStyle(theme.color(.textSecondary))

            Text(file.displayName)
                .font(metrics.scaledFont(.callout))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(theme.color(isActive ? .textPrimary : .textSecondary))

            // The close mark on the active tab and under the pointer; otherwise
            // the unsaved-changes dot, in the same slot. Showing it on the active
            // tab too means the tab a user is most likely to close does not have
            // to be hunted for first.
            ZStack {
                if isActive || isHovering {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: metrics.scaled(9), weight: .bold))
                            .foregroundStyle(theme.color(.textSecondary))
                    }
                    .buttonStyle(.plain)
                    .help("Close")
                } else if file.isDirty {
                    Circle()
                        .fill(theme.color(.textSecondary))
                        .frame(width: metrics.scaled(7), height: metrics.scaled(7))
                        .help("Unsaved changes")
                }
            }
            .frame(width: metrics.scaled(14), height: metrics.scaled(14))
        }
        .padding(.horizontal, metrics.scaled(ChromeGeometry.rowPaddingX))
        .frame(maxHeight: .infinity)
        .background(isActive ? theme.color(.bgEditor) : Color.clear)
        .overlay(alignment: .bottom) {
            if isActive {
                Rectangle()
                    .fill(theme.color(.accent))
                    .frame(height: metrics.scaled(ChromeGeometry.accentIndicator))
            }
        }
        // The rule between two tabs, drawn on each tab's trailing edge.
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(theme.color(.hairline))
                .frame(width: metrics.scaled(ChromeGeometry.hairlineWidth))
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
    }

    /// The symbol `FileIcon` answers for this tab's file.
    ///
    /// An unsaved buffer has no url, and is asked about under its display name
    /// so the answer is still `FileIcon`'s — its own fallback for a name it does
    /// not recognise — rather than a second guess spelled here.
    private var iconSymbolName: String {
        let url = file.url ?? URL(fileURLWithPath: file.displayName)
        return FileIcon(for: DirectoryEntry(url: url, isDirectory: false)).symbolName
    }
}

#endif
