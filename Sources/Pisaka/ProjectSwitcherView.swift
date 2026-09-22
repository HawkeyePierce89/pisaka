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
    /// popover inherits it from this view, which is why the popover's own colours
    /// are roles too (its rules are not — see the note on `popoverContent`).
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
                Text(currentLabel)
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

    /// The popover's *colours* are roles because the chrome rules are per file
    /// and this file obeys them whole. Its `Divider()` calls deliberately stay:
    /// a divider names no colour, so no rule can see it, and the fix is not
    /// available yet — the popover's own ground is still the platform's material,
    /// and a `hairline` rule painted on that ground would be the mismatch rather
    /// than the cure. The rules go when the ground under them is swept, which is
    /// recorded as inherited work in `core-theme.md`'s part-three record.
    private var popoverContent: some View {
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
                Divider()

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
                Divider()
                Text("No recent projects")
                    .font(metrics.scaledFont(.callout))
                    .foregroundStyle(theme.color(.textSecondary))
                    .padding(.vertical, metrics.scaled(4))
            }
        }
        .padding(metrics.scaled(10))
        .frame(width: metrics.scaled(300))
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(metrics.scaledFont(.caption, weight: .semibold))
            .foregroundStyle(theme.color(.textSecondary))
            .padding(.top, metrics.scaled(4))
    }

    private func projectRow(_ row: RecentProject) -> some View {
        Button {
            isPresented = false
            if !row.isCurrent { onOpenRecent(row.url) }
        } label: {
            HStack(spacing: metrics.scaled(6)) {
                Image(systemName: row.isCurrent ? "checkmark" : "folder")
                    .frame(width: metrics.scaled(16))
                    .foregroundStyle(theme.color(row.isCurrent ? .accent : .textSecondary))
                    // Decoration beside the row's own name, hidden for the
                    // reason the bottom-bar label above states.
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
    }
}
#endif
