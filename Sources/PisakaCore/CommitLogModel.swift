import Foundation

/// Observable state for the Log view: the commit history list, the current
/// selection, and the load/error state.
///
/// Mirrors `LocalChangesModel`'s shape — an `@MainActor ObservableObject` that
/// funnels mutation through testable methods and injects its git I/O behind
/// `GitServicing`, so the real `Process`-backed service runs in `Pisaka` and an
/// in-memory stub in tests. Pure Foundation — no `Process`/AppKit/SwiftUI.
///
/// The `git`-touching entry point (`refresh`) is `async`: the injected
/// `GitServicing` runs its blocking work off the main thread, so the main actor
/// never blocks on a subprocess. Overlapping refreshes are ordered by a monotonic
/// generation token so a slower, superseded fetch discards its stale result
/// rather than clobbering a newer one's published state.
@MainActor
public final class CommitLogModel: ObservableObject {
    /// The commit history, most recent first, as of the last successful refresh.
    @Published public private(set) var commits: [Commit] = []

    /// The currently selected commit, or `nil` when none is selected.
    ///
    /// Read-only to callers: selection goes through `select(_:)` (which validates
    /// the commit is in `commits`) or is reconciled by `refresh` (re-bound to its
    /// refreshed `Commit`, or cleared when it no longer appears), so the invariant
    /// "selected is always a current commit or nil" holds.
    @Published public private(set) var selected: Commit?

    /// A human-readable description of the last refresh failure (e.g. the folder
    /// is not a git repository), or `nil` after a successful refresh.
    @Published public private(set) var errorMessage: String?

    /// The repository root the model was last refreshed against. Stored so detail
    /// queries can resolve paths without the caller re-supplying it.
    @Published public private(set) var root: URL?

    /// `true` while a refresh's git I/O is in flight (so the view can show a
    /// spinner). Cleared when the latest refresh resolves.
    @Published public private(set) var isLoading = false

    /// The active server-side history filter (ref/author/date/path). Changing it
    /// (via `applyFilter`) rebuilds the `git log` arguments and re-fetches; the
    /// default spans all refs.
    ///
    /// This is the *committed* filter — the one the displayed `commits` reflect.
    /// It only changes once a filter's fetch is actually applied (inside the async
    /// `applyFilter`), so it lags behind a rapid sequence of requested changes. The
    /// no-op/ordering decision must therefore key off `requestedFilter` (the latest
    /// *synchronously requested* filter), never this lagging value.
    @Published public private(set) var filter = LogFilter()

    /// The client-side message-search query. Updating it (via `setSearchQuery`)
    /// re-derives `visibleCommits` from the already-loaded `commits` with **no**
    /// git re-fetch.
    @Published public private(set) var searchQuery = ""

    /// The branch/tag refs available for the filter bar's ref picker, refreshed
    /// alongside the commit list (best-effort: a failure to list refs leaves this
    /// empty without failing the whole refresh).
    @Published public private(set) var references: [String] = []

    /// The commits actually shown: `commits` narrowed by the client-side message
    /// search. Equal to `commits` when the search query is blank.
    public var visibleCommits: [Commit] {
        LogFilter.search(commits, query: searchQuery)
    }

    private let gitService: GitServicing

    /// The opened folder last requested (via `prepareForRefresh`/`refresh`). A
    /// change means a *different* repository, so the previous repo's ref-specific
    /// filter selection and ref list are reset: a stale `.ref` would query a branch
    /// the new repo lacks (stranding the new log in an error state), and the picker
    /// would otherwise still show the old repo's branches.
    private var lastRequestedRoot: URL?

    /// Monotonically increasing token identifying the latest refresh *request*.
    ///
    /// Bumped **synchronously** — by `prepareForRefresh` on the main-actor turn that
    /// *creates* the refresh task (before any `await`), or at `refresh` entry when
    /// called directly without a pinned token. Unstructured `Task`s are not
    /// guaranteed to start in creation order, so a token assigned only once the
    /// async `refresh` body began could let an older request (a superseded folder or
    /// filter change) win; capturing it synchronously orders requests by creation.
    /// Each `refresh` reuses its captured token to (a) bail at entry when a newer
    /// request has already superseded it and (b) after each `await`, commit its
    /// published state only while still the latest — so a slower, superseded fetch
    /// discards its stale result rather than clobbering a newer one.
    private var requestGeneration = 0

    /// The latest refresh-request token, for a caller to capture synchronously
    /// before a `Task` hop. (`prepareForRefresh` is the usual entry point; this is
    /// exposed for symmetry with `LocalChangesModel.currentRequestGeneration`.)
    public var currentRequestGeneration: Int { requestGeneration }

    /// The latest *requested* filter (the last value passed to `prepareForFilter`
    /// that was not a no-op, mirrored when `applyFilter` commits). Unlike the
    /// published `filter`, it reflects the user's latest intent synchronously; the
    /// publish lags it by one phase while a fetch is in flight. Exposed so the
    /// publish-lags-request contract is readable and the interleaving regression is
    /// assertable rather than folklore. The symmetric counterpart of
    /// `currentRequestGeneration`.
    public var currentRequestedFilter: LogFilter { requestedFilter }

    /// Whether a `refresh` has committed a result for the *current* repository into
    /// the published state yet (set on both the success and failure paths once it
    /// wins the stale-result guard). False before the first fetch lands, and reset
    /// to false by `resetForRepositoryChange` on a folder switch — the prior repo's
    /// data is cleared, so the new repo has no completed fetch.
    ///
    /// `applyFilter`'s no-op guard requires this alongside `!isLoading`: `!isLoading`
    /// alone means the displayed `commits` reflect the committed `filter` (a refresh
    /// that bailed post-`await` leaves `isLoading` true), but *only* once a fetch has
    /// actually populated them. A refresh that was merely *prepared* and superseded
    /// before its task started leaves `isLoading == false` with nothing displayed, so
    /// a `!isLoading`-only guard would wrongly skip and strand the log empty.
    private var hasCompletedFetch = false

    /// The most recently *requested* filter, updated **synchronously** (by
    /// `prepareForFilter`, and mirrored when the async `applyFilter` commits a
    /// filter). Unlike the published `filter` — which only changes once a fetch is
    /// applied, a later main-actor turn — this reflects the user's latest intent the
    /// instant a control fires. The filter-change no-op guard compares against this,
    /// not `filter`: otherwise a request reverting to a value equal to the *committed*
    /// (but already-superseded) filter would be dropped as a no-op while an in-flight
    /// change to a different filter still lands, so the displayed history would not
    /// match the user's last choice.
    private var requestedFilter = LogFilter()

    public init(gitService: GitServicing) {
        self.gitService = gitService
    }

    // MARK: - Pure decision helpers

    /// Reconcile the selection against a freshly fetched commit list, with no I/O.
    ///
    /// The selection is re-bound to its refreshed `Commit` (keeping its metadata
    /// current) or cleared when it no longer appears — e.g. it was filtered out,
    /// or the opened folder changed to a different repository. A `nil` selection
    /// stays `nil`.
    public static func reconcileSelection(
        selected: Commit?,
        commits: [Commit]
    ) -> Commit? {
        selected.flatMap { sel in commits.first { $0.id == sel.id } }
    }

    // MARK: - Refresh

    /// Synchronously register an intent to (re)load the history for `root`,
    /// returning the request token to pass into the `Task`-wrapped
    /// `refresh`/`applyFilter`.
    ///
    /// Bumping the token here — on the main-actor turn that *creates* the refresh
    /// task, before any `await` — orders requests by creation rather than by the
    /// (unguaranteed) order in which unstructured tasks start, so two rapid folder
    /// or filter changes always settle on the most recent rather than letting an
    /// out-of-order older task win.
    ///
    /// On a folder switch (the requested root differs from the last) it also resets
    /// the previous repository's ref-specific state — the `.ref` filter selection,
    /// the message search, the ref list, the selection, and any prior error — so a
    /// stale branch selection never queries the new repo and the picker never shows
    /// the old repo's refs.
    @discardableResult
    public func prepareForRefresh(root: URL) -> Int {
        requestGeneration += 1
        if root != lastRequestedRoot {
            lastRequestedRoot = root
            resetForRepositoryChange()
        } else {
            // A plain refresh (Refresh / Load More) for the *same* repo re-fetches with
            // the committed `filter`, superseding any filter request that was prepared
            // but never applied (its task bails on the bumped generation). Reconcile the
            // latest-*requested* filter back to the committed one so that dropped request
            // can't leave `requestedFilter` stale — otherwise re-selecting the same
            // filter would be misread as a no-op until a different filter is chosen
            // first. (On a folder switch, `resetForRepositoryChange` resets both.)
            requestedFilter = filter
        }
        return requestGeneration
    }

    /// Clear the previous repository's published state on a folder switch (see
    /// `prepareForRefresh`). The commit list is dropped too: leaving it would show
    /// (and let the user select, then query detail against the now-stale `root`) the
    /// *previous* repository's history for the whole window until the new fetch
    /// resolves — so clear it synchronously, mirroring `LocalChangesModel`, which
    /// clears `changedFiles` on a switch. The refresh's success/failure path then
    /// publishes the new repo's commits (or the empty error state).
    private func resetForRepositoryChange() {
        filter = LogFilter()
        requestedFilter = LogFilter()
        searchQuery = ""
        references = []
        commits = []
        selected = nil
        errorMessage = nil
        // `hasCompletedFetch` tracks whether the *current* repository's data is on
        // screen — the switch just cleared `commits`, so no fetch has completed for
        // the new repo. Leaving it true would let `applyFilter`'s no-op guard skip a
        // revert-to-default filter request whose committed `filter` happens to equal
        // the (also-reset) default while every superseded refresh bails, stranding
        // the new repo's log empty until another manual refresh.
        hasCompletedFetch = false
    }

    /// Re-query the repository containing `root` for its commit history.
    ///
    /// The opened folder may be a subdirectory of the repository, so the repo top
    /// level is resolved first and stored as `root`. On success, `commits` is
    /// replaced, `errorMessage` cleared, and the selection reconciled against the
    /// new list. On failure (not a repo, git missing, etc.) the state is cleared —
    /// *including* the stale ref list — and `errorMessage` set, never crashing the
    /// view.
    ///
    /// `request` is the token captured synchronously by `prepareForRefresh` before
    /// the caller's `Task` hop. When provided, the refresh bails immediately if a
    /// newer request has already superseded it (so an out-of-order task can't win),
    /// and uses the same token as its post-`await` stale-result guard. A direct
    /// call (tests, idempotent backstops) may omit it, in which case a fresh token
    /// is bumped at entry and this refresh is treated as the latest.
    public func refresh(root: URL, limit: Int, request: Int? = nil) async {
        let token: Int
        if let request {
            // A newer request was registered after this one; it will publish, so
            // drop this superseded request rather than letting it win out of order.
            guard request == requestGeneration else { return }
            token = request
        } else {
            requestGeneration += 1
            token = requestGeneration
        }
        // Defense in depth for a direct `refresh` (no `prepareForRefresh`): a folder
        // switch resets the previous repo's ref-specific filter/refs here too. A
        // no-op when `prepareForRefresh` already handled the same switch.
        if root != lastRequestedRoot {
            lastRequestedRoot = root
            resetForRepositoryChange()
        } else if request == nil {
            // A direct refresh (no `prepareForRefresh`) for the same root re-fetches
            // with the committed `filter`, superseding any prepared-but-unapplied
            // filter request. Mirror `prepareForRefresh`'s same-root reconciliation
            // so the dropped request can't leave `requestedFilter` stale — otherwise
            // re-selecting that cancelled filter would be misread as a no-op until a
            // different filter is chosen first. (A pinned-token refresh already had
            // `requestedFilter` reconciled by `prepareForRefresh`.)
            requestedFilter = filter
        }
        isLoading = true
        do {
            let repoRoot = try await gitService.repositoryRoot(for: root)
            let fetched = try await gitService.commits(filter: filter, limit: limit, root: repoRoot)
            // List the refs for the filter picker best-effort: a repo with no refs
            // (or a `git for-each-ref` hiccup) must not fail the whole refresh, so a
            // throw here degrades to an empty picker rather than an error placeholder.
            let refs = (try? await gitService.references(root: repoRoot)) ?? []
            // A newer request started and should win; discard this stale result.
            guard token == requestGeneration else { return }
            self.root = repoRoot
            commits = fetched
            references = refs
            selected = Self.reconcileSelection(selected: selected, commits: fetched)
            errorMessage = nil
            hasCompletedFetch = true
            isLoading = false
        } catch {
            // Same stale-result guard on the failure path: a superseded request
            // must not clear a newer one's published state.
            guard token == requestGeneration else { return }
            self.root = root
            commits = []
            selected = nil
            // Clear the stale ref list too: the old repo's branches are meaningless
            // for the folder that just failed to load, and leaving them would keep
            // an actionable picker over a log stuck in an error state.
            references = []
            errorMessage = error.localizedDescription
            hasCompletedFetch = true
            isLoading = false
        }
    }

    /// Select `commit` (no-op if it is not among the current commits), or clear
    /// the selection when passed `nil`.
    public func select(_ commit: Commit?) {
        guard let commit else {
            selected = nil
            return
        }
        guard commits.contains(where: { $0.id == commit.id }) else { return }
        selected = commit
    }

    // MARK: - Filter & search

    /// Synchronously register an intent to apply `newFilter`, returning the request
    /// token to thread into the `Task`-wrapped `applyFilter`, or `nil` when it is a
    /// no-op (equal to the latest *requested* filter).
    ///
    /// The no-op comparison is against `requestedFilter`, **not** the committed
    /// `filter`: the latter lags (it only changes once a fetch is applied, a later
    /// main-actor turn), so comparing against it would drop a request that reverts to
    /// a value equal to the committed-but-already-superseded filter while a different
    /// in-flight change still lands — leaving the history not matching the user's last
    /// choice. Comparing against the synchronously-updated `requestedFilter` lets such
    /// a revert through and supersede the pending change.
    ///
    /// This guard orders requests; it cannot suppress a view echo. The published
    /// `filter` lags the latest `requestedFilter` by one phase whenever two applies
    /// interleave (the publish happens synchronously at `applyFilter` entry, before
    /// the `await` on git), so an echo built from the published value is a genuinely
    /// different filter and is accepted here — it would spawn a fetch. Not echoing is
    /// the view's obligation: the filter bar's user-intent bindings apply only from
    /// `Binding.set`/`onSubmit`, and `seedFromFilter` assigns the draft directly, so a
    /// model-published filter change can never reach the apply path.
    ///
    /// Bumps the request generation (via `prepareForRefresh`) on a real change so the
    /// fetch is ordered by creation rather than task-start order.
    @discardableResult
    public func prepareForFilter(_ newFilter: LogFilter, root: URL) -> Int? {
        guard newFilter != requestedFilter else { return nil }
        let token = prepareForRefresh(root: root)
        requestedFilter = newFilter
        return token
    }

    /// Apply a new server-side `filter` and re-fetch the history against `root`.
    ///
    /// A no-op when `newFilter` equals the current filter *and* no refresh is in
    /// flight (so re-applying the same settled filter never spends a redundant
    /// `git log`). When a refresh *is* in flight, this request — the latest
    /// generation — has superseded it, so it must run the fetch itself rather than
    /// let the discarded refresh strand `isLoading`. Otherwise the filter is stored
    /// and `refresh` runs — inheriting its generation guard, so a filter change
    /// that supersedes an in-flight fetch wins.
    ///
    /// `request` is the token captured synchronously (via `prepareForFilter`/
    /// `prepareForRefresh`) before the caller's `Task` hop; it bails if already
    /// superseded and is threaded into `refresh` so the underlying fetch is ordered
    /// by creation, not by task-start order. A direct call (tests, idempotent
    /// backstops) may omit it; it then bumps a fresh token at entry — *before* the
    /// no-op check — so it is treated as the latest and supersedes any prepared-but-
    /// unstarted request rather than letting that older request win out of order.
    public func applyFilter(_ newFilter: LogFilter, root: URL, limit: Int, request: Int? = nil) async {
        let token: Int
        if let request {
            // A newer request superseded this one; drop it rather than let it win
            // out of order.
            guard request == requestGeneration else { return }
            token = request
        } else {
            // A direct call (tests, idempotent backstops) is treated as the latest —
            // mirroring `refresh`'s `request == nil` contract. Bump the generation
            // *before* the no-op check so the direct call supersedes any prepared-but-
            // unstarted filter request; otherwise that older request, never
            // superseded, would still win after this no-op returns. The bumped token
            // is threaded into `refresh` so it does not bump a second time.
            requestGeneration += 1
            token = requestGeneration
        }
        // Re-applying the committed filter is normally a redundant `git log`. Skip it
        // only when a fetch has already populated the display (`hasCompletedFetch`)
        // *and* nothing is in flight (`!isLoading`) — i.e. the committed filter's data
        // is genuinely on screen with no superseded refresh left to resolve. Both
        // checks are needed: if a refresh is still in flight, *this* request — the
        // latest generation, having passed the guard above — has superseded it, so it
        // would bail after its `await` without clearing `isLoading`, stranding the view
        // on "Loading…"; and if a refresh was merely *prepared* and superseded before
        // its task started, `isLoading` is still false yet nothing has loaded, so a
        // `!isLoading`-only guard would wrongly skip and strand the log empty. In either
        // case fall through and run the fetch.
        if newFilter == filter && !isLoading && hasCompletedFetch {
            // Keep `requestedFilter` in lock-step even on the no-op path so a
            // direct (non-`prepareForFilter`) call cannot leave it stale — otherwise a
            // later `prepareForFilter` re-selecting that same value would be misread as
            // a no-op until a different filter is chosen first.
            requestedFilter = newFilter
            return
        }
        filter = newFilter
        // Keep `requestedFilter` in lock-step with the committed filter so the two
        // never diverge through a direct (non-`prepareForFilter`) call site.
        requestedFilter = newFilter
        await refresh(root: root, limit: limit, request: token)
    }

    /// Update the client-side message-search query.
    ///
    /// Purely re-derives `visibleCommits` from the loaded `commits` — no git
    /// re-fetch — so it stays cheap on every keystroke. A blank query shows every
    /// loaded commit.
    public func setSearchQuery(_ query: String) {
        searchQuery = query
    }

    // MARK: - Commit detail

    /// The files changed by `commit` relative to its first parent, for the detail
    /// pane. Returns `[]` before the first refresh (no `root`) or when the query
    /// fails — the detail pane shows an empty list rather than crashing, mirroring
    /// `LocalChangesModel.rows(for:)`'s error-swallowing.
    public func changes(for commit: Commit) async -> [ChangedFile] {
        guard let root else { return [] }
        return (try? await gitService.commitChanges(hash: commit.hash, root: root)) ?? []
    }

    /// Build the side-by-side diff (first parent vs the commit) for `file` within
    /// `commit`, via the same `LineDiff` the Local Changes view uses.
    ///
    /// The old side is the file's contents at the commit's first parent (empty for
    /// an added file, a root commit with no parent, or a failed read); for a
    /// rename, the old side reads `oldPath` at the parent. The new side is the
    /// file's contents at the commit itself (empty for a deleted file or a failed
    /// read). Returns `[]` before the first refresh (no `root`).
    public func rows(for file: ChangedFile, in commit: Commit) async -> [DiffRow] {
        guard let root else { return [] }
        return LineDiff.rows(
            old: await oldText(for: file, in: commit, root: root),
            new: await newText(for: file, in: commit, root: root)
        )
    }

    // MARK: - Diff side resolution

    private func oldText(for file: ChangedFile, in commit: Commit, root: URL) async -> String {
        // An added file has no parent version, and a root commit has no parent to
        // read from — both leave the old side empty.
        guard file.status != .added, let parent = commit.parents.first else { return "" }
        // For a rename, the file lived under `oldPath` in the parent. `fileContents`
        // both throws and returns `String?`, so `try?` yields `String??`; flatten
        // both layers so any failure (or a missing object) is an empty side.
        let oldPath = file.oldPath ?? file.path
        return (try? await gitService.fileContents(at: parent, path: oldPath, root: root)).flatMap { $0 } ?? ""
    }

    private func newText(for file: ChangedFile, in commit: Commit, root: URL) async -> String {
        // A deleted file does not exist at the commit; the new side is empty.
        guard file.status != .deleted else { return "" }
        return (try? await gitService.fileContents(at: commit.hash, path: file.path, root: root)).flatMap { $0 } ?? ""
    }
}
