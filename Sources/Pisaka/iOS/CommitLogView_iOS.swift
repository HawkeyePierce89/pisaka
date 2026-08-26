#if os(iOS)
import SwiftUI
import PisakaCore

/// The iOS Git Log screen — the peer of the macOS `CommitLogView`. Presented as a
/// sheet from `RootView_iOS`; it shows the read-only commit history
/// (short hash, ref badges, subject, author, date) with a branch-graph gutter and a
/// filter/search bar. Tapping a commit pushes its changed-file list; tapping a file
/// pushes the commit-vs-first-parent diff. No separate windows — navigation is a
/// single `NavigationStack` driven by a `NavigationPath`.
///
/// The view holds no domain logic: it observes `CommitLogModel` and renders its
/// published state. Refresh / filter / search flow through the model (which owns the
/// generation-guarded ordering), exactly as the macOS view does.
struct CommitLogView_iOS: View {
    @ObservedObject var model: CommitLogModel
    @ObservedObject var settings: SettingsStore
    /// The current project root, used as the repository root for refresh. `nil` when
    /// no folder is open.
    var projectRoot: URL?
    /// Dismisses this screen.
    var onDone: () -> Void

    /// How many commits the first fetch (and a fresh folder) requests.
    static let initialLimit = 100
    /// How many more commits each "Load more" press adds to the limit.
    private static let loadMoreStep = 100

    /// The current `git log -n <limit>` cap. Bumped by "Load more", which re-fetches
    /// the whole list (the model replaces `commits` wholesale).
    @State private var limit = CommitLogView_iOS.initialLimit

    /// Fixed height of every commit row so the graph gutter aligns with the columns.
    static let rowHeight: CGFloat = 44

    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                if projectRoot != nil {
                    LogFilterBar_iOS(
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
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .navigationDestination(for: CommitTarget.self) { target in
                CommitDetailView_iOS(
                    model: model,
                    commit: target.commit,
                    onOpenDiff: { file in
                        path.append(CommitDiffTarget(file: file, commit: target.commit))
                    }
                )
            }
            .navigationDestination(for: CommitDiffTarget.self) { target in
                DiffRoute_iOS(
                    fileID: target.file.id,
                    fileName: (target.file.path as NSString).lastPathComponent,
                    load: { await model.rows(for: target.file, in: target.commit) },
                    settings: settings
                )
            }
        }
        .onAppear(perform: refreshIfPossible)
        .onChange(of: projectRoot) {
            limit = Self.initialLimit
            refreshIfPossible()
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if model.isLoading {
                ProgressView()
            }
            Button(action: refreshIfPossible) {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(projectRoot == nil)
            Button("Done", action: onDone)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if projectRoot == nil {
            placeholder("Open a folder to see its commit history")
        } else if let message = model.errorMessage {
            placeholder(message)
        } else if model.commits.isEmpty {
            placeholder(model.isLoading ? "Loading…" : "No commits")
        } else {
            commitList
        }
    }

    private var commitList: some View {
        // Lay the branch graph out once over the shown commits, suppressing it when
        // the list is not contiguous history (a message search, or a commit-limiting
        // server filter) — the same rule as the macOS view, since a graph over an
        // excluded-parent slice would draw dangling lanes.
        let shown = model.visibleCommits
        let graph = CommitGraphLayout.layout(shouldSuppressGraph ? [] : shown)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, commit in
                    CommitRow_iOS(
                        commit: commit,
                        graphRow: index < graph.rows.count ? graph.rows[index] : nil,
                        incomingEdges: index > 0 && index <= graph.rows.count
                            ? graph.rows[index - 1].edges : [],
                        laneCount: graph.width,
                        onSelect: {
                            model.select(commit)
                            path.append(CommitTarget(commit: commit))
                        }
                    )
                    Divider()
                }
                loadMoreRow
            }
        }
    }

    /// Whether the branch graph should be suppressed (non-contiguous history): a
    /// non-blank message search, or a commit-limiting server filter (author/date).
    private var shouldSuppressGraph: Bool {
        let isSearching = !model.searchQuery
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return isSearching || model.filter.mayProduceNonContiguousHistory
    }

    @ViewBuilder
    private var loadMoreRow: some View {
        if model.commits.count >= limit {
            Button(action: loadMore) {
                HStack {
                    Spacer()
                    if model.isLoading {
                        ProgressView()
                    } else {
                        Text("Load more").font(.callout)
                    }
                    Spacer()
                }
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .disabled(model.isLoading)
        }
    }

    private func placeholder(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .foregroundStyle(.secondary)
                .font(.callout)
                .multilineTextAlignment(.center)
                .padding()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func loadMore() {
        limit += Self.loadMoreStep
        refreshIfPossible()
    }

    /// Apply a rebuilt server-side filter and re-fetch (generation-guarded inside the
    /// model, so a rapid sequence settles on the latest) — the macOS `applyFilter`.
    private func applyFilter(_ filter: LogFilter) {
        guard let projectRoot else { return }
        guard let request = model.prepareForFilter(filter, root: projectRoot) else { return }
        let currentLimit = limit
        Task { await model.applyFilter(filter, root: projectRoot, limit: currentLimit, request: request) }
    }

    private func refreshIfPossible() {
        guard let projectRoot else { return }
        // Capture the request token synchronously before the `Task` hop so an
        // out-of-order/superseded refresh is rejected by the model (the macOS
        // `refreshIfPossible` rationale).
        let request = model.prepareForRefresh(root: projectRoot)
        let currentLimit = limit
        Task { await model.refresh(root: projectRoot, limit: currentLimit, request: request) }
    }
}

/// A routable commit (for value-based navigation): `Commit` is Identifiable +
/// Equatable but not Hashable, so wrap it. Identity is the full hash.
private struct CommitTarget: Hashable {
    let commit: Commit
    static func == (lhs: CommitTarget, rhs: CommitTarget) -> Bool { lhs.commit.hash == rhs.commit.hash }
    func hash(into hasher: inout Hasher) { hasher.combine(commit.hash) }
}

/// A routable commit-file diff target (the file plus its commit context).
private struct CommitDiffTarget: Hashable {
    let file: ChangedFile
    let commit: Commit
    static func == (lhs: CommitDiffTarget, rhs: CommitDiffTarget) -> Bool {
        lhs.commit.hash == rhs.commit.hash && lhs.file.id == rhs.file.id
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(commit.hash)
        hasher.combine(file.id)
    }
}

/// One commit row: the branch-graph gutter, short hash, ref badges, subject, author,
/// and the formatted date. Tapping the row opens its detail.
private struct CommitRow_iOS: View {
    let commit: Commit
    let graphRow: CommitGraphRow?
    let incomingEdges: [GraphEdge]
    let laneCount: Int
    let onSelect: () -> Void

    /// Width reserved for the graph gutter (one lane's spacing per column, with a
    /// small minimum) — matches the macOS `CommitRow.graphWidth`.
    private var graphWidth: CGFloat {
        CGFloat(max(laneCount, 1)) * 14 + 6
    }

    var body: some View {
        HStack(spacing: 8) {
            if let graphRow {
                CommitGraphView_iOS(
                    row: graphRow,
                    incomingEdges: incomingEdges,
                    laneCount: max(laneCount, 1),
                    rowHeight: CommitLogView_iOS.rowHeight
                )
                .frame(width: graphWidth, height: CommitLogView_iOS.rowHeight)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(shortHash)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    ForEach(commit.refs, id: \.self) { ref in
                        RefBadge_iOS(name: ref)
                    }
                    Text(commit.subject)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                HStack(spacing: 6) {
                    Text(commit.author)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text(displayDate)
                        .font(.caption.monospaced())
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: CommitLogView_iOS.rowHeight, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }

    private var shortHash: String { String(commit.hash.prefix(7)) }

    /// The author date formatted for display (Core keeps the raw ISO-8601 string).
    /// Falls back to the raw string if parsing fails.
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
private struct RefBadge_iOS: View {
    let name: String

    var body: some View {
        Text(name)
            .font(.caption2)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.accentColor.opacity(0.2))
            .foregroundStyle(Color.accentColor)
            .clipShape(Capsule())
    }
}

/// The commit-detail screen (pushed): the commit's subject and its changed-file
/// list. Tapping a file pushes its commit-vs-parent diff. Loads the file list from
/// `model.changes(for:)` behind a `@State` generation token, mirroring the macOS
/// `CommitDetailPane`.
private struct CommitDetailView_iOS: View {
    @ObservedObject var model: CommitLogModel
    let commit: Commit
    let onOpenDiff: (ChangedFile) -> Void

    @State private var files: [ChangedFile] = []
    @State private var loadGeneration = 0

    var body: some View {
        Group {
            if files.isEmpty {
                VStack {
                    Spacer()
                    Text("No changed files")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(files) { file in
                            CommitFileRow_iOS(file: file, onOpen: { onOpenDiff(file) })
                            Divider()
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle(commit.subject)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadChanges() }
    }

    private func loadChanges() {
        loadGeneration += 1
        let generation = loadGeneration
        Task { @MainActor in
            let loaded = await model.changes(for: commit)
            guard generation == loadGeneration else { return }
            files = loaded
        }
    }
}

/// One changed-file row in the commit detail: a status-tinted icon, the path, and a
/// one-letter status badge. Tapping opens its diff.
private struct CommitFileRow_iOS: View {
    let file: ChangedFile
    let onOpen: () -> Void

    var body: some View {
        let icon = FileIcon(for: DirectoryEntry(
            url: URL(fileURLWithPath: file.path),
            isDirectory: false
        ))
        HStack(spacing: 6) {
            Image(systemName: icon.symbolName)
                .foregroundStyle(commitStatusColor(file.status))
            Text(file.path)
            Spacer(minLength: 4)
            Text(commitStatusLetter(file.status))
                .font(.caption2.monospaced())
                .foregroundStyle(commitStatusColor(file.status))
        }
        .lineLimit(1)
        .truncationMode(.middle)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
    }
}

/// Semantic color for a git `FileStatus`, matching the Local Changes VCS conventions.
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

/// One-letter status badge, mirroring git's short codes.
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
