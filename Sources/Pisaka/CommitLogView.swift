#if os(macOS)
import SwiftUI
import PisakaCore

/// The Git Log view shown in the VS Code-style bottom dock panel: a
/// JetBrains-style read-only commit history list.
///
/// Renders the commit table (short hash, ref badges, subject, author, date)
/// wired to `CommitLogModel`, with a branch-graph gutter, a filter/search bar,
/// and a commit-detail pane (changed files only) that opens beside the list when
/// a commit is selected; double-clicking a changed file opens its
/// commit-vs-parent diff in a separate window. Clicking a row sets
/// `model.selected`. The view holds no domain logic — it observes
/// `CommitLogModel` and renders its published state, mirroring `LocalChangesView`.
struct CommitLogView: View {
    @ObservedObject var model: CommitLogModel
    /// The current project root, used as the repository root for refresh. `nil`
    /// when no folder is open.
    var projectRoot: URL?
    /// Invoked when a commit's changed file is double-clicked, to open that file's
    /// commit-vs-parent diff in a separate window. Defaults to a no-op so
    /// previews/tests can construct the view without the app wiring.
    var onOpenCommitDiff: (ChangedFile, Commit) -> Void = { _, _ in }

    /// How many commits the first fetch (and a fresh folder) requests.
    static let initialLimit = 100
    /// How many more commits each "Load more" press adds to the limit.
    private static let loadMoreStep = 100

    /// The current `git log -n <limit>` cap. Bumped by "Load more", which re-fetches
    /// the whole list with the larger limit (no infinite/incremental paging — the
    /// model replaces `commits` wholesale, matching its refresh contract).
    @State private var limit = CommitLogView.initialLimit

    /// Fixed *base* height of every commit row so the branch-graph gutter (drawn
    /// per row as a fixed-height AppKit cell) aligns with the text columns. The
    /// row and its gutter cell both scale it through the same
    /// `InterfaceMetrics.pt`, so they stay aligned at every scale — an unscaled
    /// gutter beside scaled rows is the one way this graph can visibly break.
    static let baseRowHeight: Double = 24

    /// The interface zone's metrics, inherited from the window root.
    @Environment(\.interfaceMetrics) private var metrics

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            // The filter/search bar sits above the list once a repo is open. Its
            // server-side dimensions re-fetch (generation-guarded); the message
            // search filters the loaded commits client-side.
            if projectRoot != nil {
                LogFilterBar(
                    references: model.references,
                    filter: model.filter,
                    searchQuery: model.searchQuery,
                    onApplyFilter: applyFilter,
                    onSearch: { model.setSearchQuery($0) }
                )
                Divider()
            }
            content
        }
        // Refresh when the view first appears (e.g. switching into Log mode) or the
        // open folder changes, so the list reflects the repo without a manual
        // refresh. A folder switch also resets the limit so the new repo starts at
        // the initial page size.
        .onAppear(perform: refreshIfPossible)
        .onChange(of: projectRoot) { _ in
            limit = Self.initialLimit
            refreshIfPossible()
        }
    }

    private var header: some View {
        HStack(spacing: metrics.scaled(8)) {
            Text("History")
                .font(metrics.scaledFont(.headline, weight: .semibold))
            if model.isLoading {
                ProgressView()
                    .controlSize(.small)
            }
            Spacer()
            Button(action: refreshIfPossible) {
                Image(systemName: "arrow.clockwise")
                    .font(metrics.scaledFont(.body))
            }
            .buttonStyle(.borderless)
            .disabled(projectRoot == nil)
            .help("Refresh commit history")
        }
        .padding(.horizontal, metrics.scaled(10))
        .padding(.vertical, metrics.scaled(6))
    }

    @ViewBuilder
    private var content: some View {
        if projectRoot == nil {
            placeholder("Open a folder to see its commit history")
        } else if let message = model.errorMessage {
            placeholder(message)
        } else if model.commits.isEmpty {
            placeholder(model.isLoading ? "Loading…" : "No commits")
        } else {
            // Full width when nothing is selected; once a commit is selected the
            // detail pane (changed files only; the diff opens in a separate
            // window on double-click) opens beside the list.
            HSplitView {
                commitList
                    .frame(
                        minWidth: metrics.scaled(360),
                        idealWidth: metrics.scaled(520),
                        maxWidth: .infinity
                    )
                if let selected = model.selected {
                    CommitDetailPane(model: model, commit: selected, onOpenCommitDiff: onOpenCommitDiff)
                        .frame(minWidth: metrics.scaled(280), maxWidth: .infinity)
                }
            }
        }
    }

    private var commitList: some View {
        // Render the search-narrowed list. Lay out the branch graph once for the
        // shown commits (pure, cheap). Each row gets its own graph cell plus the
        // previous row's edges as incoming continuations, so the lanes draw as
        // continuous lines down the gutter.
        //
        // A graph only makes sense over *contiguous* history. The client-side
        // message search narrows the list to a non-contiguous subset, and so do
        // the server-side commit-limiting filters (author/date) — a shown commit
        // can name a parent the filter excluded — so a graph laid out over either
        // would route lanes toward parents that never appear, drawing broken,
        // dangling lanes that misrepresent ancestry. (Ref selection walks a
        // connected ancestry and a path pathspec is parent-rewritten by
        // `--parents`, so those stay contiguous — see
        // `LogFilter.mayProduceNonContiguousHistory`.) Suppress the gutter
        // entirely in those cases (`layout([])` yields an empty graph, so every
        // row renders with no graph cell) rather than show a graph that disagrees
        // with real history.
        let shown = model.visibleCommits
        let graph = CommitGraphLayout.layout(shouldSuppressGraph ? [] : shown)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, commit in
                    CommitRow(
                        commit: commit,
                        isSelected: model.selected?.id == commit.id,
                        graphRow: index < graph.rows.count ? graph.rows[index] : nil,
                        incomingEdges: index > 0 && index <= graph.rows.count
                            ? graph.rows[index - 1].edges : [],
                        laneCount: graph.width,
                        onSelect: { model.select(commit) }
                    )
                }
                loadMoreRow
            }
            .padding(.vertical, metrics.scaled(4))
        }
    }

    /// Whether the branch graph should be suppressed because the shown list is not
    /// contiguous history: either a non-blank message search is narrowing it
    /// client-side, or a commit-limiting server filter (author/date) is in effect.
    /// Both can leave a shown commit pointing at an excluded parent, which the
    /// graph layout can only render as a dangling lane.
    private var shouldSuppressGraph: Bool {
        let isSearching = !model.searchQuery
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return isSearching || model.filter.mayProduceNonContiguousHistory
    }

    /// A "Load more" affordance shown only when the last fetch *filled* the limit
    /// (so more history may exist). Pressing it raises the limit and re-fetches.
    @ViewBuilder
    private var loadMoreRow: some View {
        if model.commits.count >= limit {
            Button(action: loadMore) {
                HStack {
                    Spacer()
                    if model.isLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Load more")
                            .font(metrics.scaledFont(.callout))
                    }
                    Spacer()
                }
                .padding(.vertical, metrics.scaled(8))
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(model.isLoading)
        }
    }

    private func placeholder(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .foregroundStyle(.secondary)
                .font(metrics.scaledFont(.callout))
                .multilineTextAlignment(.center)
                // The default `.padding()` inset, stated so it scales with the
                // rest of the Log instead of staying a fixed 16pt.
                .padding(metrics.scaled(16))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadMore() {
        limit += Self.loadMoreStep
        refreshIfPossible()
    }

    /// Apply a rebuilt server-side filter and re-fetch. Generation-guarded inside
    /// the model, so a rapid sequence of filter changes settles on the latest.
    private func applyFilter(_ filter: LogFilter) {
        guard let projectRoot else { return }
        // `prepareForFilter` both decides the no-op *and* captures the request token,
        // synchronously, before the `Task` hop — so the request is ordered by creation
        // rather than by (unguaranteed) task-start order (see `refreshIfPossible`). It
        // returns `nil` for a no-op (a filter equal to the latest *requested* filter),
        // in which case the generation is never disturbed. The comparison is against
        // the latest requested filter, not the committed one: the bar re-seeds and
        // fires its controls' `onChange` whenever the model re-publishes its filter
        // (e.g. a folder switch resets it to the default), and that echo must no-op so
        // it cannot supersede the folder's own in-flight refresh — yet a genuine revert
        // to the committed-but-already-superseded filter while a different change is
        // pending must still go through (the lagging committed `filter` can't tell the
        // two apart; `requestedFilter` can).
        guard let request = model.prepareForFilter(filter, root: projectRoot) else { return }
        let currentLimit = limit
        Task { await model.applyFilter(filter, root: projectRoot, limit: currentLimit, request: request) }
    }

    private func refreshIfPossible() {
        guard let projectRoot else { return }
        // Capture the request token and limit synchronously before the `Task` hop.
        // `prepareForRefresh` bumps the model's request generation now (in creation
        // order), and `refresh` rejects a superseded request — so an older fetch
        // overtaken by a newer one (a folder switch, a second "Load more") discards
        // its stale result rather than clobbering the newer published state, even
        // when the unstructured tasks start out of order.
        let request = model.prepareForRefresh(root: projectRoot)
        let currentLimit = limit
        Task { await model.refresh(root: projectRoot, limit: currentLimit, request: request) }
    }
}

/// One commit row: short hash, any ref badges, the subject, the author, and the
/// formatted date. Clicking selects the commit.
private struct CommitRow: View {
    let commit: Commit
    let isSelected: Bool
    /// This commit's laid-out graph row (node + outgoing edges); `nil` if the
    /// graph and commit list briefly disagree on length.
    let graphRow: CommitGraphRow?
    /// The previous row's outgoing edges, drawn as this row's incoming lanes.
    let incomingEdges: [GraphEdge]
    /// Total lane count, for consistent column spacing across rows.
    let laneCount: Int
    let onSelect: () -> Void

    @State private var isHovering = false

    /// The interface zone's metrics, inherited from the window root.
    @Environment(\.interfaceMetrics) private var metrics

    /// Base spacing between the gutter's lanes, and the base margin after the
    /// last one. Both are scaled below and handed to the AppKit cell, so the
    /// gutter's own drawing keeps pace with the rows it sits beside.
    private static let baseLaneSpacing: Double = 14
    private static let baseGraphMargin: Double = 6

    /// This row's height at the current interface scale.
    private var rowHeight: CGFloat { metrics.scaled(CommitLogView.baseRowHeight) }

    /// Width reserved for the graph gutter: one lane's spacing per column, with a
    /// small minimum so a single-lane history still shows its line.
    private var graphWidth: CGFloat {
        CGFloat(max(laneCount, 1)) * metrics.scaled(Self.baseLaneSpacing)
            + metrics.scaled(Self.baseGraphMargin)
    }

    var body: some View {
        HStack(spacing: metrics.scaled(8)) {
            if let graphRow {
                CommitGraphView(
                    row: graphRow,
                    incomingEdges: incomingEdges,
                    laneCount: max(laneCount, 1),
                    rowHeight: rowHeight,
                    laneSpacing: metrics.scaled(Self.baseLaneSpacing),
                    nodeRadius: metrics.scaled(3.5),
                    lineWidth: metrics.scaled(1.5)
                )
                .frame(width: graphWidth, height: rowHeight)
            }

            Text(shortHash)
                .font(metrics.scaledFont(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: metrics.scaled(58), alignment: .leading)

            ForEach(commit.refs, id: \.self) { ref in
                RefBadge(name: ref)
            }

            Text(commit.subject)
                .font(metrics.scaledFont(.body))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: metrics.scaled(8))

            Text(commit.author)
                .font(metrics.scaledFont(.caption))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: metrics.scaled(160), alignment: .trailing)

            Text(displayDate)
                .font(metrics.scaledFont(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: metrics.scaled(120), alignment: .trailing)
        }
        .padding(.horizontal, metrics.scaled(10))
        .frame(maxWidth: .infinity, minHeight: rowHeight,
               maxHeight: rowHeight, alignment: .leading)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
    }

    private var shortHash: String { String(commit.hash.prefix(7)) }

    private var rowBackground: Color {
        if isSelected { return Color.accentColor.opacity(0.25) }
        if isHovering { return Color.accentColor.opacity(0.15) }
        return .clear
    }

    /// The author date formatted for display. `Commit.date` is the raw strict
    /// ISO-8601 string (Core stays locale-free); parse it here and render a short,
    /// locale-aware date+time. Falls back to the raw string if parsing fails.
    private var displayDate: String {
        guard let date = Self.isoParser.date(from: commit.date) else { return commit.date }
        return Self.displayFormatter.string(from: date)
    }

    private static let isoParser = ISO8601DateFormatter()
    private static let displayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}

/// A small pill for a branch/tag ref decoration attached to a commit.
private struct RefBadge: View {
    let name: String

    /// The interface zone's metrics, inherited from the window root.
    @Environment(\.interfaceMetrics) private var metrics

    var body: some View {
        Text(name)
            .font(metrics.scaledFont(.caption2))
            .lineLimit(1)
            .padding(.horizontal, metrics.scaled(5))
            .padding(.vertical, metrics.scaled(1))
            .background(Color.accentColor.opacity(0.2))
            .foregroundStyle(Color.accentColor)
            .clipShape(Capsule())
    }
}

/// The commit-detail pane: the selected commit's changed files as a list.
/// Double-clicking a file opens its commit-vs-parent diff in a separate window
/// (via `onOpenCommitDiff`); single-click selects/highlights the row.
///
/// Loads the changed-file list from `model.changes(for:)` (a `git diff-tree`
/// subprocess) off the body path, behind a `@State` generation token so a slow
/// result for a since-changed commit can't land on the wrong pane — the same
/// pattern `DiffPane` uses for diff rows. The view holds no domain logic.
private struct CommitDetailPane: View {
    @ObservedObject var model: CommitLogModel
    let commit: Commit
    let onOpenCommitDiff: (ChangedFile, Commit) -> Void

    @State private var files: [ChangedFile] = []
    @State private var selectedFile: ChangedFile?
    /// Monotonic token identifying the latest `loadChanges`. A `CommitDetailPane`
    /// is recreated with a new `commit` on selection change; `@State` persists
    /// across that recreation, so a newer load's bump invalidates an older
    /// in-flight one before it can assign a stale file list.
    @State private var loadGeneration = 0

    /// The interface zone's metrics, inherited from the window root.
    @Environment(\.interfaceMetrics) private var metrics

    var body: some View {
        filesList
            .onAppear { loadChanges(for: commit) }
            .onChange(of: commit) { loadChanges(for: $0) }
    }

    private var filesList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(commit.subject)
                .font(metrics.scaledFont(.headline, weight: .semibold))
                .lineLimit(2)
                .padding(.horizontal, metrics.scaled(10))
                .padding(.top, metrics.scaled(8))
                .padding(.bottom, metrics.scaled(4))
            Divider()
            if files.isEmpty {
                Text("No changed files")
                    .foregroundStyle(.secondary)
                    .font(metrics.scaledFont(.callout))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(files) { file in
                            CommitFileRow(
                                file: file,
                                isSelected: selectedFile?.id == file.id,
                                onSelect: { selectedFile = file },
                                onOpenDiff: { onOpenCommitDiff(file, commit) }
                            )
                        }
                    }
                    .padding(.vertical, metrics.scaled(4))
                }
            }
        }
    }

    private func loadChanges(for requested: Commit) {
        loadGeneration += 1
        let generation = loadGeneration
        // Clear the previous commit's file list and selection *synchronously*,
        // before the async fetch. `@State` persists across the view's recreation
        // with a new `commit`, so without this the detail pane would keep showing
        // the old commit's files until `changes(for:)` resolves.
        files = []
        selectedFile = nil
        Task { @MainActor in
            let loaded = await model.changes(for: requested)
            guard generation == loadGeneration else { return }
            files = loaded
        }
    }
}

/// One changed-file row in the commit detail: a status-tinted icon, the path, and
/// a one-letter status badge. Single-click selects the row; double-click opens its
/// diff in a separate window.
private struct CommitFileRow: View {
    let file: ChangedFile
    let isSelected: Bool
    let onSelect: () -> Void
    let onOpenDiff: () -> Void

    @State private var isHovering = false

    /// The interface zone's metrics, inherited from the window root.
    @Environment(\.interfaceMetrics) private var metrics

    var body: some View {
        let icon = FileIcon(for: DirectoryEntry(
            url: URL(fileURLWithPath: file.path),
            isDirectory: false
        ))
        HStack(spacing: metrics.scaled(4)) {
            Image(systemName: icon.symbolName)
                .foregroundStyle(commitStatusColor(file.status))
            Text(file.path)
            Spacer(minLength: metrics.scaled(4))
            Text(commitStatusLetter(file.status))
                .font(metrics.scaledFont(.caption2, design: .monospaced))
                .foregroundStyle(commitStatusColor(file.status))
        }
        .font(metrics.scaledFont(.body))
        .lineLimit(1)
        .truncationMode(.middle)
        .padding(.horizontal, metrics.scaled(10))
        .padding(.vertical, metrics.scaled(3))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .contentShape(Rectangle())
        // Double-click opens the diff window; declared before the single-tap so a
        // two-click sequence prefers it while one click still selects.
        .onTapGesture(count: 2, perform: onOpenDiff)
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
    }

    private var rowBackground: Color {
        if isSelected { return Color.accentColor.opacity(0.25) }
        if isHovering { return Color.accentColor.opacity(0.15) }
        return .clear
    }
}

/// Semantic color for a git `FileStatus` in the commit detail, matching the Local
/// Changes view's VCS-convention colors.
private func commitStatusColor(_ status: FileStatus) -> Color {
    switch status {
    case .modified: return .blue
    case .added: return .green
    case .deleted: return .red
    case .renamed: return .orange
    case .untracked: return .gray
    case .conflicted: return .purple
    }
}

/// One-letter status badge, mirroring `git`'s short codes.
private func commitStatusLetter(_ status: FileStatus) -> String {
    switch status {
    case .modified: return "M"
    case .added: return "A"
    case .deleted: return "D"
    case .renamed: return "R"
    case .untracked: return "U"
    case .conflicted: return "C"
    }
}

#endif
