#if os(macOS)
import SwiftUI
import PisakaCore

/// The project-switcher widget for the always-visible bottom bar.
///
/// A thin SwiftUI view over `RecentProject` rows provided by the Core projection.
/// The widget shows the current project's name as a bottom-bar button that opens
/// the window's in-window popover (`ProjectSwitcherPopover`, presented by
/// `ChromePopoverPresenter`) with an "Open Folder…" action and the MRU list of
/// recent projects.
///
/// The orchestration — the existence guard and the switch funnel — lives in
/// `PisakaApp`. This view only reads the rows at popover-open time and forwards
/// the user's choice through the callbacks.
struct ProjectSwitcherView: View {
    var currentRoot: URL?
    /// Invoked to fetch the MRU list of recent projects.
    var recentProjects: () -> [RecentProject] = { [] }
    /// Invoked when the user requests the standard folder picker.
    var onOpenFolder: () -> Void = {}
    /// Invoked when a recent project is chosen.
    var onOpenRecent: (URL) -> Void = { _ in }

    /// The presenter's id for this widget's popover.
    static let popoverID = "projectSwitcher"

    /// The interface zone's metrics, inherited from the window root.
    @Environment(\.interfaceMetrics) private var metrics

    /// The chrome theme, read from the environment the window root injects.
    @Environment(\.chromeTheme) private var theme

    /// The window's popover presenter; absent outside a window root, where the
    /// button presents nothing.
    @Environment(\.chromePopoverPresenter) private var presenter

    /// This widget's frame in the root's coordinate space — the popover's anchor.
    @State private var frame: CGRect = .zero

    var body: some View {
        Button {
            // The rows are read once, at open time; a toggle that closes reads
            // them too and discards them, which costs one projection.
            let rows = recentProjects()
            presenter?.present(id: Self.popoverID, anchor: frame) { [onOpenFolder, onOpenRecent] context in
                AnyView(ProjectSwitcherPopover(
                    rows: rows,
                    context: context,
                    onOpenFolder: onOpenFolder,
                    onOpenRecent: onOpenRecent
                ))
            }
        } label: {
            // A `Button`'s children are *combined* into one accessibility
            // element; the two glyphs here are decoration beside a name that
            // already says everything, and `DesignGlyphImage` hides each from
            // accessibility itself, so neither folds anything into the name.
            HStack(spacing: metrics.scaled(4)) {
                DesignGlyphImage(.package, size: 12, slot: 12, role: .textSecondary)
                // One line, always. The bar states its own height now
                // (`ChromeGeometry.bottomBarHeight`), and a flexible `Text` in a
                // fixed-height frame does not make room for itself: a folder
                // name long enough to wrap on a narrow window is a name drawn in
                // two lines and clipped to one and a half. Truncating is the
                // same answer the popover's own rows give, for the same reason.
                Text(currentLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(theme.color(.textPrimary))
                // The caret the design draws on a widget that opens a list.
                DesignGlyphImage(.chevronDown, size: 10, slot: 10, role: .textSecondary)
            }
            .font(metrics.scaledFont(.callout))
            // No padding of its own: the bottom bar owns the 14-point gaps
            // between its widgets and its own height, so a padding here would
            // make the bar's stated measurements not the ones drawn. The whole
            // label stays the click target through `contentShape`.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The tooltip through AppKit, not `.help` — `BarToolTip` says why; the
        // bar keeps one tooltip mechanism (gating rule ten).
        .background(BarToolTip(text: "Current project — click to switch"))
        // What the widget is, as its name, and the folder it shows as its value
        // — the text the combined label announced before the name was stated.
        .accessibilityLabel("Current project")
        .accessibilityValue(currentLabel)
        .chromePopoverFrame { [presenter] in
            frame = $0
            presenter?.noteAnchor($0, for: Self.popoverID)
        }
    }

    /// The bottom-bar label: the current folder's name, or a placeholder when
    /// none is open.
    private var currentLabel: String {
        if let root = currentRoot { return root.lastPathComponent }
        return "No Folder"
    }

}

/// The project popover's content: "Open Folder…" in the Head, and a "Recent"
/// section of project rows — or one message when there are none — in the List.
///
/// The rows are the ones the widget read at open time. They are registered with
/// the presenter in display order, the action row first, on appear.
struct ProjectSwitcherPopover: View {
    let rows: [RecentProject]
    let context: ChromePopoverContext
    var onOpenFolder: () -> Void = {}
    var onOpenRecent: (URL) -> Void = { _ in }

    static let openFolderRowID = "openFolder"

    @Environment(\.chromePopoverPresenter) private var presenter

    var body: some View {
        ChromePopover(maxHeight: context.maxHeight) {
            ChromePopoverRow(
                title: "Open Folder…",
                glyph: .folderOpen,
                isSelected: context.selectedRowID == Self.openFolderRowID,
                action: { context.activateRow(Self.openFolderRowID) }
            )
            .chromePopoverRowAnchor(id: Self.openFolderRowID)
        } list: {
            if rows.isEmpty {
                ChromePopoverMessage(text: "No recent projects", role: .textSecondary)
            } else {
                ChromePopoverSectionHeader(title: "Recent")
                ForEach(rows) { row in
                    ChromePopoverProjectRow(
                        name: row.name,
                        path: row.path,
                        isCurrent: row.isCurrent,
                        isSelected: context.selectedRowID == Self.rowID(row),
                        accessibilityValue: row.isCurrent ? "Current project" : nil,
                        action: { context.activateRow(Self.rowID(row)) }
                    )
                    .chromePopoverRowAnchor(id: Self.rowID(row))
                }
            }
        }
        .scrolling(to: context.selectedRowID)
        .onAppear(perform: registerRows)
    }

    private static func rowID(_ row: RecentProject) -> String { "project:\(row.id)" }

    /// The row actions in display order. The current project's row only
    /// dismisses — the presenter dismisses before every row's closure.
    private func registerRows() {
        var actions = [ChromePopoverRowAction(id: Self.openFolderRowID, activate: onOpenFolder)]
        for row in rows {
            actions.append(ChromePopoverRowAction(id: Self.rowID(row), activate: { [onOpenRecent] in
                if !row.isCurrent { onOpenRecent(row.url) }
            }))
        }
        presenter?.setRows(actions)
    }
}
#endif
