#if os(macOS)
import SwiftUI
import PisakaCore

/// The project-switcher widget for the always-visible bottom bar.
///
/// A thin SwiftUI view over `RecentProject` rows provided by the Core projection.
/// The widget shows the current project's name as a bottom-bar button that opens
/// a popover with an "Open Folder…" action and the MRU list of recent projects.
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

    @State private var isPresented = false
    @State private var rows: [RecentProject] = []

    /// The interface zone's metrics, inherited from the window root. The popover
    /// inherits the environment from this view, so its rows scale with the widget
    /// that opened them.
    @Environment(\.interfaceMetrics) private var metrics

    /// The chrome theme, read from the environment the window root injects. The
    /// popover inherits it from this view, so its content is drawn on `bgPopover`
    /// too.
    @Environment(\.chromeTheme) private var theme

    var body: some View {
        Button {
            if !isPresented {
                rows = recentProjects()
            }
            isPresented.toggle()
        } label: {
            // A `Button`'s children are *combined* into one accessibility
            // element, and an unhidden SF Symbol folds its own name into that
            // element's name — the announcement part one recorded on the tree
            // row ("chevron.right, folder fill, Sources") is the same mechanism
            // read from the other side. Both symbols here are decoration beside
            // a name that already says everything, so both are hidden, in
            // `ProjectTreeView`'s idiom.
            HStack(spacing: metrics.scaled(4)) {
                Image(systemName: "folder")
                    .foregroundStyle(theme.color(.textSecondary))
                    .accessibilityHidden(true)
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
                // Neither switcher carried one before this sweep.
                Image(systemName: "chevron.down")
                    .foregroundStyle(theme.color(.textSecondary))
                    .accessibilityHidden(true)
            }
            .font(metrics.scaledFont(.callout))
            // No padding of its own: the bottom bar owns the 14-point gaps
            // between its widgets and its own height, so a padding here would
            // make the bar's stated measurements not the ones drawn. The whole
            // label stays the click target through `contentShape`.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Current project — click to switch")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            popoverContent
        }
    }

    /// The bottom-bar label: the current folder's name, or a placeholder when
    /// none is open.
    private var currentLabel: String {
        if let root = currentRoot { return root.lastPathComponent }
        return "No Folder"
    }

    /// The popover's content, drawn on `bgPopover`. The popover's arrow keeps the
    /// system material, because the content background cannot reach it.
    private var popoverContent: some View {
        // The popover's arrow keeps the system material, because the content background cannot reach it.
        VStack(alignment: .leading, spacing: metrics.scaled(8)) {
            Button {
                isPresented = false
                onOpenFolder()
            } label: {
                Label("Open Folder…", systemImage: "folder.badge.plus")
                    .font(metrics.scaledFont(.body))
            }
            .buttonStyle(.plain)

            if !rows.isEmpty {
                Rectangle()
                    .fill(theme.color(.hairline))
                    .frame(height: metrics.scaled(ChromeGeometry.hairlineWidth))

                ScrollView {
                    VStack(alignment: .leading, spacing: metrics.scaled(2)) {
                        sectionHeader("Recent")
                        ForEach(rows) { row in
                            projectRow(row)
                        }
                    }
                }
                .frame(maxHeight: metrics.scaled(300))
            } else {
                Rectangle()
                    .fill(theme.color(.hairline))
                    .frame(height: metrics.scaled(ChromeGeometry.hairlineWidth))
                Text("No recent projects")
                    .font(metrics.scaledFont(.callout))
                    .foregroundStyle(theme.color(.textSecondary))
                    .padding(.vertical, metrics.scaled(4))
            }
        }
        .padding(metrics.scaled(10))
        .frame(width: metrics.scaled(300))
        .background(theme.color(.bgPopover))
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(metrics.scaledFont(.caption, weight: .semibold))
            .foregroundStyle(theme.color(.textSecondary))
            .padding(.top, metrics.scaled(4))
    }

    /// A recent-project row.
    ///
    /// This row's glyph is the one symbol in this file whose *name and colour
    /// are both chosen by a value* — `checkmark`/accent for the project that is
    /// open, `folder`/secondary for every other. That is the row's **state**,
    /// not decoration, and the accent on the name beside it carries the same
    /// state in the same unreadable currency: colour. So the glyph stays hidden
    /// — a spoken value says it better than a folded-in symbol name would — and
    /// the state it showed is spoken by the row itself, as an accessibility
    /// *value* on the combined element the `Button` makes of its children. A
    /// non-current row has no state to report and says nothing.
    private func projectRow(_ row: RecentProject) -> some View {
        Button {
            isPresented = false
            if !row.isCurrent { onOpenRecent(row.url) }
        } label: {
            HStack(spacing: metrics.scaled(6)) {
                Image(systemName: row.isCurrent ? "checkmark" : "folder")
                    .frame(width: metrics.scaled(16))
                    .foregroundStyle(theme.color(row.isCurrent ? .accent : .textSecondary))
                    // Hidden because the state it showed is now spoken: the
                    // value below is the carrier, and an unhidden symbol would
                    // fold its own name into the row's instead.
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text(row.name)
                        .foregroundStyle(theme.color(row.isCurrent ? .accent : .textPrimary))
                    Text(row.path)
                        .font(metrics.scaledFont(.caption))
                        .foregroundStyle(theme.color(.textSecondary))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
            }
            .font(metrics.scaledFont(.body))
            .padding(.vertical, metrics.scaled(2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(row.isCurrent ? "Current project" : "")
    }
}
#endif
