#if os(macOS)
import SwiftUI
import PisakaCore

/// The horizontal tab strip above the editor: the whole strip's chrome, owned
/// here rather than by its host.
///
/// Split out of `TabListView` rather than left as a branch inside it: the strip
/// is not a list of rows that happens to run sideways. It has chrome of its own
/// — a height, a background, a bottom rule the editor below it sits under — that
/// a row view cannot state, and the column's own chrome differs in every one of
/// those three. What the two genuinely share is the trailing slot's precedence,
/// and that is shared as one view (`TabStatusMark` below) rather than as one
/// branching view.
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

            TabStatusMark(
                isHovering: isHovering,
                isDirty: file.isDirty,
                isActive: isActive,
                onClose: onClose
            )
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

/// The one slot both tab orientations draw at the trailing edge of a tab, with
/// three claimants, in this order: the close mark while the pointer is in the
/// tab, then the unsaved-changes dot, then the close mark on the active tab.
///
/// The dot therefore **outranks** the mark on an active tab — unsaved work is a
/// fact about the file that nothing else states, while the mark is reachable by
/// pointing at the tab — and the mark still shows on the active tab whenever
/// there is nothing to report, so the tab most likely to be closed does not have
/// to be hunted for.
///
/// It is one view rather than one rule restated in each orientation: the strip
/// and the column show the same three facts about the same file, and two
/// spellings of that precedence would drift the moment either is touched. It
/// lives here, beside the strip that first stated the rule.
struct TabStatusMark: View {
    let isHovering: Bool
    let isDirty: Bool
    let isActive: Bool
    let onClose: () -> Void

    /// The interface zone's metrics, inherited from the window root.
    @Environment(\.interfaceMetrics) private var metrics
    /// The chrome's colours, inherited from the window root.
    @Environment(\.chromeTheme) private var theme

    var body: some View {
        ZStack {
            if isHovering {
                closeMark
            } else if isDirty {
                Circle()
                    .fill(theme.color(.textSecondary))
                    .frame(width: metrics.scaled(7), height: metrics.scaled(7))
                    .help("Unsaved changes")
            } else if isActive {
                closeMark
            }
        }
        .frame(width: metrics.scaled(14), height: metrics.scaled(14))
    }

    /// The close mark, drawn in either of the two slots that claim it.
    private var closeMark: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: metrics.scaled(9), weight: .bold))
                .foregroundStyle(theme.color(.textSecondary))
        }
        .buttonStyle(.plain)
        .help("Close")
    }
}

#endif
