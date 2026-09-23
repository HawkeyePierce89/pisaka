#if os(macOS)
import SwiftUI
import PisakaCore

/// The Git Log view shown in the bottom dock panel: a
/// read-only commit history list.
///
/// Renders the commit table (short hash, ref badges, subject, author, date)
/// wired to `CommitLogModel`, with a branch-graph gutter, a filter/search bar,
/// and a commit-detail pane (changed files only) that opens beside the list when
/// a commit is selected; double-clicking a changed file opens its
/// commit-vs-parent diff in a separate window. Clicking a row sets
/// `model.selected`. The view holds no domain logic — it observes
/// `CommitLogModel` and renders its published state, mirroring `LocalChangesView`.
///
/// On the chrome roles and tokens since part four (b) of the chrome theme: every
/// colour is a role read from `\.chromeTheme`, each strip draws its own one-point
/// `hairline` by overlay rather than leaving a `Divider()` to the stack, and a
/// changed file's letter, colour and spoken name are Core's one answer
/// (`FileStatus.letter`, `ChromeColorRole.changedFileRole(for:)`,
/// `FileStatus.spokenName`). The branch-graph gutter's lane hues are the one
/// colour table this panel does not read from the roles — `CommitGraphPalette`,
/// the fourth stated exemption.
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
    static let baseRowHeight: Double = 25

    /// The detail pane's width, in scaled points, once the divide beside it has
    /// been dragged; `nil` until then, which lays the pane out at its ideal width.
    /// `@State` only, like the other panels' split positions: it lives as long as
    /// the panel does.
    @State private var detailWidth: CGFloat?
    /// The detail width captured at the start of a divide drag, so the cumulative
    /// translation is applied to the width the drag started from.
    @State private var detailDragStartWidth: CGFloat?
    /// Whether the pointer is inside the divide's hit strip.
    @State private var isDivideHovering = false
    /// Whether this view has pushed the resize cursor — one flag, written only by
    /// `syncDivideCursor()`, so every push is balanced by exactly one pop: from
    /// `onHover(false)`, from the drag's `onEnded`, or — when the strip leaves the
    /// tree with the pointer on it or mid-drag, where neither callback arrives —
    /// from the handle's `onDisappear`.
    @State private var divideCursorPushed = false

    /// The interface zone's metrics, inherited from the window root.
    @Environment(\.interfaceMetrics) private var metrics
    /// The chrome's colours, inherited from the window root.
    @Environment(\.chromeTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            header
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
            }
            content
        }
        // Refresh when the view first appears (e.g. switching into Log mode) or the
        // open folder changes, so the list reflects the repo without a manual
        // refresh. A folder switch also resets the limit so the new repo starts at
        // the initial page size.
        //
        // The change handler refreshes the root its *parameter* carries, never
        // `self.projectRoot`: `projectRoot` is a plain stored property of this view
        // value, and the macOS 13 `onChange(of:perform:)` overload runs the closure
        // captured before the change, so off `self` it is still the folder the user
        // just left. Refreshing that root is not a harmless one-behind display here —
        // `prepareForRefresh` *bumps* the request generation, so the stale request
        // supersedes the correct one the folder-open path already launched, rewrites
        // `lastRequestedRoot` back to the old folder and leaves the panel showing the
        // previous repository's history. (`LogFilterBar` states the same rule for the
        // same reason; a `@State` or `@ObservedObject` read would have been live.)
        .onAppear(perform: refreshIfPossible)
        .onChange(of: projectRoot) { newRoot in
            limit = Self.initialLimit
            refresh(root: newRoot)
        }
    }

    /// The panel's header strip: the Problems panel's shape — a
    /// `panelHeaderHeight` strip drawing its own bottom `hairline`.
    private var header: some View {
        HStack(spacing: metrics.scaled(CommitLogLayout.headerGap)) {
            Text("History")
                .font(metrics.scaledFont(.body, weight: .semibold))
                .foregroundStyle(theme.color(.textPrimary))
                .lineLimit(1)
            if model.isLoading {
                ProgressView()
                    .controlSize(.small)
            }
            Spacer()
            Button(action: refreshIfPossible) {
                Image(systemName: "arrow.clockwise")
                    .font(metrics.scaledFont(.body))
                    .foregroundStyle(theme.color(.textSecondary))
                    .accessibilityHidden(true)
            }
            .buttonStyle(.borderless)
            .disabled(projectRoot == nil)
            .help("Refresh commit history")
            .accessibilityLabel("Refresh commit history")
        }
        .padding(.horizontal, metrics.scaled(ChromeGeometry.panelHeaderPaddingX))
        .frame(height: metrics.scaled(ChromeGeometry.panelHeaderHeight))
        .overlay(alignment: .bottom) { hairline(horizontal: true) }
    }

    /// The one-point rule a strip draws along its own edge: a horizontal rule
    /// when `horizontal` is true, a vertical one otherwise.
    private func hairline(horizontal: Bool) -> some View {
        Rectangle()
            .fill(theme.color(.hairline))
            .frame(
                width: horizontal ? nil : metrics.scaled(ChromeGeometry.hairlineWidth),
                height: horizontal ? metrics.scaled(ChromeGeometry.hairlineWidth) : nil
            )
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
            //
            // Not an `HSplitView`: its divider is drawn by the system in the
            // platform's separator value, which no role can reach. The list owns
            // the divide instead — a trailing `hairline` by overlay, with a
            // drag strip over it that resizes the pane.
            GeometryReader { geo in
                HStack(spacing: 0) {
                    commitList
                        .frame(minWidth: metrics.scaled(CommitLogLayout.listMinWidth), maxWidth: .infinity)
                        .overlay(alignment: .trailing) {
                            if model.selected != nil {
                                ZStack {
                                    hairline(horizontal: false)
                                    divideHandle(total: geo.size.width)
                                }
                            }
                        }
                    if let selected = model.selected {
                        CommitDetailPane(model: model, commit: selected, onOpenCommitDiff: onOpenCommitDiff)
                            .frame(width: clampedDetailWidth(total: geo.size.width))
                    }
                }
            }
        }
    }

    /// The detail pane's width: the dragged width, or the ideal one, clamped so
    /// neither the pane nor the list drops below its minimum.
    private func clampedDetailWidth(total: CGFloat) -> CGFloat {
        let minimum = metrics.scaled(CommitLogLayout.detailMinWidth)
        let maximum = max(minimum, total - metrics.scaled(CommitLogLayout.listMinWidth))
        let wanted = detailWidth ?? metrics.scaled(CommitLogLayout.detailIdealWidth)
        return min(max(wanted, minimum), maximum)
    }

    /// The invisible strip over the divide that resizes the detail pane. What is
    /// drawn is the list's hairline; this is only what is dragged.
    ///
    /// Hand-rolled because the system divider cannot be drawn in a role, and the
    /// dock's swept surfaces draw their own hairlines — which is also why the
    /// cursor is this view's to push and to pop, on every way the strip can go.
    private func divideHandle(total: CGFloat) -> some View {
        Color.clear
            .frame(width: metrics.scaled(CommitLogLayout.divideHitWidth))
            .contentShape(Rectangle())
            .onHover { inside in
                isDivideHovering = inside
                syncDivideCursor()
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = detailDragStartWidth ?? clampedDetailWidth(total: total)
                        if detailDragStartWidth == nil {
                            detailDragStartWidth = start
                            syncDivideCursor()
                        }
                        detailWidth = start - value.translation.width
                    }
                    .onEnded { _ in
                        detailWidth = clampedDetailWidth(total: total)
                        detailDragStartWidth = nil
                        syncDivideCursor()
                    }
            )
            .onDisappear {
                // The strip exists only while a commit is selected, and the model
                // clears `selected` on its refresh paths; a dock tab switch takes
                // the whole panel away. Either can land with the pointer on the
                // strip, where no `onHover(false)` arrives, or mid-drag, where no
                // `onEnded` does — so the push is released here, and the drag's
                // start width dropped, or the next drag would begin from a width
                // the user abandoned.
                isDivideHovering = false
                detailDragStartWidth = nil
                syncDivideCursor()
            }
    }

    /// Push the resize cursor while the divide is hovered or dragged, pop it
    /// otherwise — off the one flag, so a push is never doubled nor a pop spent
    /// on a cursor this view did not push.
    private func syncDivideCursor() {
        let wanted = isDivideHovering || detailDragStartWidth != nil
        if wanted, !divideCursorPushed {
            NSCursor.resizeLeftRight.push()
            divideCursorPushed = true
        } else if !wanted, divideCursorPushed {
            NSCursor.pop()
            divideCursorPushed = false
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
        return VStack(spacing: 0) {
            CommitColumnHeader(showsGraph: !graph.rows.isEmpty, laneCount: graph.width)
            commitRows(shown, graph: graph)
        }
    }

    private func commitRows(_ shown: [Commit], graph: CommitGraph) -> some View {
        ScrollView {
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
                            .foregroundStyle(theme.color(.accent))
                            .lineLimit(1)
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
                .foregroundStyle(theme.color(.textSecondary))
                .font(metrics.scaledFont(.callout))
                .multilineTextAlignment(.center)
                // The default `.padding()` inset, stated so it scales with the
                // rest of the Log instead of staying a fixed 16pt.
                .padding(metrics.scaled(CommitLogLayout.placeholderPadding))
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
        // the latest requested filter, not the committed one: a genuine revert to the
        // committed-but-already-superseded filter while a different change is pending
        // must still go through (the lagging committed `filter` can't tell the two
        // apart; `requestedFilter` can). This guard orders requests; it cannot suppress
        // a view echo — the published `filter` lags the latest request by one phase
        // whenever two applies interleave, so an echo built from the published value
        // would be accepted and spawn a fetch. Not echoing is the view's obligation
        // (the bar's user-intent bindings apply only from `Binding.set`/`onSubmit`, and
        // the bar's `seed(from:)` assigns the draft directly).
        guard let request = model.prepareForFilter(filter, root: projectRoot) else { return }
        let currentLimit = limit
        Task { await model.applyFilter(filter, root: projectRoot, limit: currentLimit, request: request) }
    }

    /// Refresh for the currently-held root. Safe from `onAppear` and the Refresh
    /// button, where the view's own property is current; a change handler must call
    /// `refresh(root:)` with its parameter instead.
    private func refreshIfPossible() {
        refresh(root: projectRoot)
    }

    private func refresh(root: URL?) {
        guard let root else { return }
        // Capture the request token and limit synchronously before the `Task` hop.
        // `prepareForRefresh` bumps the model's request generation now (in creation
        // order), and `refresh` rejects a superseded request — so an older fetch
        // overtaken by a newer one (a folder switch, a second "Load more") discards
        // its stale result rather than clobbering the newer published state, even
        // when the unstructured tasks start out of order.
        let request = model.prepareForRefresh(root: root)
        let currentLimit = limit
        Task { await model.refresh(root: root, limit: currentLimit, request: request) }
    }
}

/// The Log's own measurements, bare numbers scaled once at the use site. The
/// rows and the column header read the same widths, which is what keeps the
/// header's labels over the columns they name (gating rule seven: none of these
/// is derived from a `ChromeGeometry` token).
private enum CommitLogLayout {
    /// The column header row's height.
    static let headerRowHeight: Double = 24
    /// A commit row's and the header row's horizontal inset.
    static let rowPaddingX: Double = 12
    /// Between a commit row's columns (and the header's labels).
    static let columnGap: Double = 16
    /// Between a row's ref badges and its subject.
    static let badgeGap: Double = 6
    /// The short-hash column.
    static let hashWidth: Double = 58
    /// The author column.
    static let authorWidth: Double = 160
    /// The date column.
    static let dateWidth: Double = 120
    /// Spacing between the gutter's lanes.
    static let laneSpacing: Double = 14
    /// The margin after the last lane.
    static let graphMargin: Double = 6
    /// The gutter's minimum width: a short history still gets a gutter this
    /// wide, and a wide one grows past it by lane count.
    static let minGraphWidth: Double = 40
    /// The commit node's radius (a 6 pt dot).
    static let nodeRadius: Double = 3
    /// The edge lines' stroke width.
    static let lineWidth: Double = 2
    /// Between the header strip's title and its spinner and refresh glyph.
    static let headerGap: Double = 8
    /// Around the empty-state sentence: the default `.padding()` inset.
    static let placeholderPadding: Double = 16
    /// The commit list's narrowest width beside the detail pane.
    static let listMinWidth: Double = 360
    /// The detail pane's narrowest width.
    static let detailMinWidth: Double = 280
    /// The detail pane's width before its divide is first dragged.
    static let detailIdealWidth: Double = 360
    /// The divide's drag strip: wider than the hairline it sits over, so it
    /// can be grabbed.
    static let divideHitWidth: Double = 5

    /// Width reserved for the graph gutter: one lane's spacing per column plus
    /// the trailing margin, never narrower than the stated minimum.
    static func graphWidth(laneCount: Int, metrics: InterfaceMetrics) -> CGFloat {
        max(
            metrics.scaled(minGraphWidth),
            CGFloat(max(laneCount, 1)) * metrics.scaled(laneSpacing) + metrics.scaled(graphMargin)
        )
    }
}

/// The static column header above the commit rows: Hash, Message, Author, Date,
/// over an empty graph column when the gutter is drawn. It lays its labels out
/// through the rows' own widths, so "Message" sits where the ref badges and the
/// subject start. Non-interactive: there is no sorting.
private struct CommitColumnHeader: View {
    let showsGraph: Bool
    let laneCount: Int

    /// The interface zone's metrics, inherited from the window root.
    @Environment(\.interfaceMetrics) private var metrics
    /// The chrome's colours, inherited from the window root.
    @Environment(\.chromeTheme) private var theme

    var body: some View {
        HStack(spacing: metrics.scaled(CommitLogLayout.columnGap)) {
            if showsGraph {
                Color.clear
                    .frame(width: CommitLogLayout.graphWidth(laneCount: laneCount, metrics: metrics))
            }
            label("Hash")
                .frame(width: metrics.scaled(CommitLogLayout.hashWidth), alignment: .leading)
            label("Message")
                .frame(maxWidth: .infinity, alignment: .leading)
            label("Author")
                .frame(width: metrics.scaled(CommitLogLayout.authorWidth), alignment: .trailing)
            label("Date")
                .frame(width: metrics.scaled(CommitLogLayout.dateWidth), alignment: .trailing)
        }
        .padding(.horizontal, metrics.scaled(CommitLogLayout.rowPaddingX))
        .frame(height: metrics.scaled(CommitLogLayout.headerRowHeight))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.color(.hairline))
                .frame(height: metrics.scaled(ChromeGeometry.hairlineWidth))
        }
        .allowsHitTesting(false)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(metrics.scaledFont(.subheadline, weight: .semibold))
            .foregroundStyle(theme.color(.textSecondary))
            .lineLimit(1)
    }
}

/// One commit row: short hash, any ref badges, the subject, the author, and the
/// formatted date. Clicking selects the commit.
///
/// The selection wash is `accentTintStrong` whether or not the window is key —
/// the Problems panel's precedent, whose rows carry no second, inactive state —
/// and the pointer's is `hoverTint`.
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
    /// The chrome's colours, inherited from the window root.
    @Environment(\.chromeTheme) private var theme

    /// This row's height at the current interface scale.
    private var rowHeight: CGFloat { metrics.scaled(CommitLogView.baseRowHeight) }

    var body: some View {
        HStack(spacing: metrics.scaled(CommitLogLayout.columnGap)) {
            if let graphRow {
                // The gutter's base measurements, each scaled here and handed to
                // the AppKit cell, so its own drawing keeps pace with the rows.
                CommitGraphView(
                    row: graphRow,
                    incomingEdges: incomingEdges,
                    laneCount: max(laneCount, 1),
                    rowHeight: rowHeight,
                    laneSpacing: metrics.scaled(CommitLogLayout.laneSpacing),
                    nodeRadius: metrics.scaled(CommitLogLayout.nodeRadius),
                    lineWidth: metrics.scaled(CommitLogLayout.lineWidth)
                )
                .frame(width: CommitLogLayout.graphWidth(laneCount: laneCount, metrics: metrics), height: rowHeight)
            }

            Text(shortHash)
                .font(metrics.scaledFont(.subheadline, design: .monospaced))
                .foregroundStyle(theme.color(.textSecondary))
                .lineLimit(1)
                .frame(width: metrics.scaled(CommitLogLayout.hashWidth), alignment: .leading)

            HStack(spacing: metrics.scaled(CommitLogLayout.badgeGap)) {
                ForEach(commit.refs, id: \.self) { ref in
                    RefBadge(name: ref)
                }
                Text(commit.subject)
                    .font(metrics.scaledFont(.body))
                    .foregroundStyle(theme.color(.textPrimary))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(commit.author)
                .font(metrics.scaledFont(.callout))
                .foregroundStyle(theme.color(.textSecondary))
                .lineLimit(1)
                .frame(width: metrics.scaled(CommitLogLayout.authorWidth), alignment: .trailing)

            Text(displayDate)
                .font(metrics.scaledFont(.callout))
                .monospacedDigit()
                .foregroundStyle(theme.color(.textSecondary))
                .lineLimit(1)
                .frame(width: metrics.scaled(CommitLogLayout.dateWidth), alignment: .trailing)
        }
        .padding(.horizontal, metrics.scaled(CommitLogLayout.rowPaddingX))
        .frame(maxWidth: .infinity, minHeight: rowHeight,
               maxHeight: rowHeight, alignment: .leading)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
    }

    private var shortHash: String { String(commit.hash.prefix(7)) }

    private var rowBackground: Color {
        if isSelected { return theme.color(.accentTintStrong) }
        if isHovering { return theme.color(.hoverTint) }
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

/// A small pill for a branch/tag ref decoration attached to a commit: the
/// `accentTint` ground under `accent` text, both roles, no opacity computed.
private struct RefBadge: View {
    let name: String

    /// The interface zone's metrics, inherited from the window root.
    @Environment(\.interfaceMetrics) private var metrics
    /// The chrome's colours, inherited from the window root.
    @Environment(\.chromeTheme) private var theme

    var body: some View {
        Text(name)
            .font(metrics.scaledFont(.caption2))
            .lineLimit(1)
            .padding(.horizontal, metrics.scaled(5))
            .padding(.vertical, metrics.scaled(1))
            .background(theme.color(.accentTint))
            .foregroundStyle(theme.color(.accent))
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
    /// The chrome's colours, inherited from the window root.
    @Environment(\.chromeTheme) private var theme

    var body: some View {
        filesList
            .onAppear { loadChanges(for: commit) }
            .onChange(of: commit) { loadChanges(for: $0) }
    }

    private var filesList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(commit.subject)
                .font(metrics.scaledFont(.body, weight: .semibold))
                .foregroundStyle(theme.color(.textPrimary))
                .lineLimit(2)
                .padding(.horizontal, metrics.scaled(10))
                .padding(.top, metrics.scaled(8))
                .padding(.bottom, metrics.scaled(4))
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(theme.color(.hairline))
                        .frame(height: metrics.scaled(ChromeGeometry.hairlineWidth))
                }
            if files.isEmpty {
                Text("No changed files")
                    .foregroundStyle(theme.color(.textSecondary))
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
///
/// The letter, its colour and its spoken name are Core's one answer
/// (`FileStatus.letter`, `ChromeColorRole.changedFileRole(for:)`,
/// `FileStatus.spokenName`): the letter carries the identity, the colour the
/// weight, so the row reads the same to someone who cannot tell the colours apart.
private struct CommitFileRow: View {
    let file: ChangedFile
    let isSelected: Bool
    let onSelect: () -> Void
    let onOpenDiff: () -> Void

    @State private var isHovering = false

    /// The interface zone's metrics, inherited from the window root.
    @Environment(\.interfaceMetrics) private var metrics
    /// The chrome's colours, inherited from the window root.
    @Environment(\.chromeTheme) private var theme

    var body: some View {
        let icon = FileIcon(for: DirectoryEntry(url: URL(fileURLWithPath: file.path), isDirectory: false))
        let statusColor = theme.color(ChromeColorRole.changedFileRole(for: file.status))
        HStack(spacing: metrics.scaled(4)) {
            Image(systemName: icon.symbolName)
                .foregroundStyle(statusColor)
                .accessibilityHidden(true)
            Text(file.path)
                .foregroundStyle(theme.color(.textPrimary))
            Spacer(minLength: metrics.scaled(4))
            Text(file.status.letter)
                .font(metrics.scaledFont(.caption2, design: .monospaced))
                .foregroundStyle(statusColor)
                .accessibilityHidden(true)
        }
        .font(metrics.scaledFont(.body))
        .lineLimit(1)
        .truncationMode(.middle)
        .padding(.horizontal, metrics.scaled(10))
        .padding(.vertical, metrics.scaled(3))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(file.status.spokenName)
        // Double-click opens the diff window; declared before the single-tap so a
        // two-click sequence prefers it while one click still selects.
        .onTapGesture(count: 2, perform: onOpenDiff)
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
    }

    private var rowBackground: Color {
        if isSelected { return theme.color(.accentTintStrong) }
        if isHovering { return theme.color(.hoverTint) }
        return .clear
    }
}

#endif
