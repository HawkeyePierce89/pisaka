#if os(macOS)
import SwiftUI
import PisakaCore

/// The JetBrains-style project-switcher widget for the always-visible bottom bar.
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

    var body: some View {
        Button {
            rows = recentProjects()
            isPresented = true
        } label: {
            Label(currentLabel, systemImage: "folder")
                .font(metrics.scaledFont(.callout))
                .padding(.horizontal, metrics.scaled(8))
                .padding(.vertical, metrics.scaled(3))
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
                    .foregroundStyle(.secondary)
                    .padding(.vertical, metrics.scaled(4))
            }
        }
        .padding(metrics.scaled(10))
        .frame(width: metrics.scaled(300))
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(metrics.scaledFont(.caption, weight: .semibold))
            .foregroundStyle(.secondary)
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
                    .foregroundStyle(row.isCurrent ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 0) {
                    Text(row.name)
                        .foregroundStyle(row.isCurrent ? Color.accentColor : Color.primary)
                    Text(row.path)
                        .font(metrics.scaledFont(.caption))
                        .foregroundStyle(Color.secondary)
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
