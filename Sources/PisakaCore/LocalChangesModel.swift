import Foundation

/// Observable state for the Local Changes view: the files differing from `HEAD`,
/// the flat/by-folder grouping mode, the current selection, and the side-by-side
/// diff rows for the selected file.
///
/// Mirrors `WorkspaceModel`'s shape: an `ObservableObject` that funnels all
/// mutation through testable methods and injects its I/O behind protocols
/// (`GitServicing` for repo access, `FileServicing` for the working copy) so the
/// real, `Process`-backed service is used in `Pisaka` and an in-memory stub in
/// tests. Pure Foundation — no `Process`/AppKit/SwiftUI.
///
/// `@MainActor`-isolated: all published state is mutated on the main actor, while
/// the injected `GitServicing` runs its blocking `git` work off-main (the methods
/// `await` it, so the main thread never blocks on a subprocess).
@MainActor
public final class LocalChangesModel: ObservableObject {
    /// How the changed-file list is grouped in the view.
    public enum GroupingMode: Equatable {
        /// One flat, sorted list of files.
        case flat
        /// A directory tree (`ChangeTree`).
        case byFolder
    }

    /// The files differing from `HEAD`, as of the last successful `refresh`.
    @Published public private(set) var changedFiles: [ChangedFile] = []

    /// Whether the list is shown flat or grouped by folder.
    @Published public var groupingMode: GroupingMode = .flat

    /// The currently selected changed file, or `nil` when none is selected.
    ///
    /// Read-only to callers: selection goes through `select(_:)` (which validates
    /// the file is in `changedFiles`) or is cleared by `refresh` when the file no
    /// longer differs, so the invariant "selected is always a current changed
    /// file or nil" holds.
    @Published public private(set) var selected: ChangedFile?

    /// A human-readable description of the last refresh failure (e.g. the folder
    /// is not a git repository), or `nil` after a successful refresh.
    @Published public private(set) var errorMessage: String?

    /// The repository root the model was last refreshed against. Stored so
    /// `rows(for:)`/`tree` can resolve paths without the caller re-supplying it.
    @Published public private(set) var root: URL?

    /// The ids of the changed files the user has checked for a multi-file revert.
    ///
    /// Read-only to callers: membership is toggled through `toggleChecked(_:)`,
    /// cleared after a `revert`, and pruned by `refresh` — which intersects it
    /// with the refreshed ids (dropping any file no longer changed) and clears it
    /// outright when the repository root changes. So a checked file that vanishes
    /// cannot rejoin a destructive batch by reappearing under the same path, and a
    /// same-relative-path file in a different opened repo never inherits a check.
    @Published public private(set) var revertSelection: Set<String> = []

    /// `true` while one or more reverts have their disk mutations in flight.
    ///
    /// A revert runs `git` off the main thread, so the editor and project tree stay
    /// interactive while it works — but a project-tree file operation
    /// (create / rename / delete) is a *second, uncoordinated disk writer* that
    /// would race the git mutation (e.g. `FileManager.removeItem` running
    /// concurrently with `git checkout` on the same file, or recreating a file the
    /// revert is about to restore from `HEAD`). The app gates those operations on
    /// this flag — refusing them while a revert is in flight — the same way it
    /// `suspend()`s autosave (the other uncoordinated writer) around a revert.
    ///
    /// Driven by `beginRevert()`/`endRevert()`, which the app calls *synchronously*
    /// before spawning the revert `Task` and from its completion `defer`. A
    /// re-entrant counter backs it so overlapping reverts (the UI permits a second
    /// context-menu revert while one is in flight) each balance their own
    /// begin/end and the flag only clears once the last finishes. Read-only to
    /// callers.
    @Published public private(set) var isReverting = false

    /// Re-entrant counter behind `isReverting`. Booleans would let an earlier
    /// revert's `endRevert()` clear the flag while a later overlapping revert is
    /// still mutating the disk.
    private var revertGateCount = 0

    private let gitService: GitServicing
    private let fileService: FileServicing

    /// Monotonically increasing token identifying the latest `refresh`. Each
    /// `refresh` captures the value it bumped this to; after its `await`ed git
    /// I/O resolves it commits its published state only while the token is still
    /// the latest, so a slower refresh that was superseded by a newer one (e.g.
    /// the user saved twice in quick succession, or switched folders mid-query)
    /// discards its now-stale result instead of overwriting the newer state.
    private var refreshGeneration = 0

    /// The folder last *requested* for a refresh — the raw opened-folder URL,
    /// before repo-root resolution. Used to detect that the opened project
    /// changed at refresh entry, so the previous project's still-displayed files
    /// are cleared up front: they belong to a different repository and must not
    /// stay actionable (selectable or revertable) during the `await` for the new
    /// project's status. A same-root refresh (a save, the manual refresh button)
    /// leaves the list in place, so there is no flicker on the common path.
    private var lastRequestedRoot: URL?

    /// Monotonically increasing token bumped *synchronously at refresh entry*
    /// whenever the opened project (the requested folder) changes. Unlike the
    /// published `root` — which only flips to the new repo *after* its `await`ed
    /// git I/O resolves — this advances the instant a folder switch is requested,
    /// before the first suspension. `revert` captures it at entry and uses it to
    /// detect a mid-revert project switch: keying that detection off `root` would
    /// miss the window between `refresh(B)` recording the switch and committing
    /// `self.root = B`, during which a suspended revert would still see the old
    /// `root` and so mutate / re-publish the project the user just left.
    private var rootRequestGeneration = 0

    /// The `rootRequestGeneration` value that the currently published `root`
    /// corresponds to. A refresh commits it alongside `self.root` *after* its
    /// `await`ed git I/O resolves — whereas `rootRequestGeneration` advances
    /// *synchronously at refresh entry* on a folder switch. So while a switch is
    /// pending (its refresh has bumped the request generation but not yet
    /// committed the new `root`), `publishedRootGeneration < rootRequestGeneration`
    /// — the signal that `self.root` is stale. `revert` checks this at entry so a
    /// revert that *starts* inside that window — capturing the already-bumped
    /// request generation next to the not-yet-updated `root`, which would make
    /// every `projectStillCurrent` check pass — bails instead of mutating the
    /// repository the user is leaving.
    private var publishedRootGeneration = 0

    /// Monotonically increasing token identifying the latest *operation* — a
    /// public `refresh` or a `revert`. Distinct from `refreshGeneration` (which
    /// orders two refreshes' published state) and the root-generation tokens
    /// (which detect a folder switch): this guards a `revert`'s trailing
    /// `errorMessage` writes against an *older* operation restoring a stale
    /// message over a newer one's result *within the same project*. The UI lets
    /// operations overlap (a save's auto-refresh, the manual refresh button, a
    /// second context-menu revert), so an older failed revert suspended on its
    /// internal `await refresh` can resume after a newer refresh/revert already
    /// published — and without this would clobber it. `revert` captures the token
    /// at entry; its own internal refreshes go through the non-bumping
    /// `refreshImpl`, so only a *different* newer operation advances it, and each
    /// of `revert`'s error writes is gated on the token still matching (so a
    /// superseded revert drops its message instead of overwriting newer state).
    private var operationGeneration = 0

    public init(gitService: GitServicing, fileService: FileServicing = FileService()) {
        self.gitService = gitService
        self.fileService = fileService
    }

    // MARK: - Pure decision helpers

    /// The selection + revert-checkbox state a refresh should publish, computed
    /// from the freshly fetched `files`. Returned by `reconcile`.
    public struct RefreshReconciliation: Equatable {
        /// The selection re-bound to its refreshed `ChangedFile`, or `nil`.
        public let selected: ChangedFile?
        /// The pruned revert-checkbox set.
        public let revertSelection: Set<String>
    }

    /// Reconcile the selection and the revert-checkbox set against a freshly
    /// fetched changed-file list, with no I/O.
    ///
    /// The checkbox set is cleared outright when the repository root changed —
    /// path-equal ids in two different repositories are unrelated files — and
    /// otherwise intersected with the current ids, dropping any file no longer
    /// changed (so a checked file that disappears cannot silently rejoin a
    /// destructive batch by reappearing under the same path). The selection is
    /// re-bound to its refreshed `ChangedFile` (keeping its status/metadata
    /// current — e.g. a file that flips from deleted to modified) or cleared when
    /// it no longer appears. A `nil` selection stays `nil`.
    public static func reconcile(
        previousRoot: URL?,
        newRoot: URL,
        files: [ChangedFile],
        selected: ChangedFile?,
        revertSelection: Set<String>
    ) -> RefreshReconciliation {
        let prunedSelection: Set<String>
        if previousRoot != newRoot {
            prunedSelection = []
        } else {
            prunedSelection = revertSelection.intersection(files.map(\.id))
        }
        let reboundSelection = selected.flatMap { sel in files.first { $0.id == sel.id } }
        return RefreshReconciliation(selected: reboundSelection, revertSelection: prunedSelection)
    }

    /// The verdict of the per-file pre-revert stale check (`guardRevert`).
    public enum RevertGuard: Equatable {
        /// The file still matches the snapshot; the revert may proceed.
        case proceed
        /// The file changed since the list was last refreshed; abort with this
        /// user-facing reason.
        case abort(reason: String)
    }

    /// Decide whether `file` may still be reverted, given the repository's
    /// `current` view of it from a fresh re-query, with no I/O.
    ///
    /// Proceeds only when a file at the same id exists with the *same* `status`
    /// and `oldPath`; otherwise the user confirmed against state that no longer
    /// holds (e.g. an untracked file that became tracked and modified, which a
    /// stale revert would delete, discarding the new content), so it aborts with
    /// the "changed since the list was last refreshed" message.
    public static func guardRevert(file: ChangedFile, current: ChangedFile?) -> RevertGuard {
        guard let current,
              current.status == file.status,
              current.oldPath == file.oldPath else {
            return .abort(reason: "“\(file.path)” changed since the list was last refreshed. Refresh and try again.")
        }
        return .proceed
    }

    /// The absolute URLs whose on-disk state a *successful* revert of `file`
    /// changed, with no I/O: the file's own path, plus — for a rename — the
    /// restored old path (an open tab there must reload its `HEAD` contents).
    public static func revertedURLs(for file: ChangedFile, root: URL) -> [URL] {
        var urls = [root.appendingPathComponent(file.path)]
        if file.status == .renamed, let oldPath = file.oldPath {
            urls.append(root.appendingPathComponent(oldPath))
        }
        return urls
    }

    /// Re-query the repository containing `root` for changed files.
    ///
    /// The opened folder may be a subdirectory of the repository, so the repo
    /// top level is resolved first and stored as `root`; every path the model
    /// then resolves (`HEAD` lookups, working-copy reads, the folder tree) is
    /// repo-root-relative and consistent.
    ///
    /// On success, `changedFiles` is replaced and `errorMessage` cleared; the
    /// selection is re-bound to its refreshed `ChangedFile` (so its status/metadata
    /// stay current — e.g. a file that flips from deleted to modified) or cleared
    /// when it no longer appears. On failure (not a repo, git missing, etc.), the
    /// state is cleared and `errorMessage` set — never crashing the view.
    ///
    /// Overlapping refreshes are guarded by a generation token: each call bumps
    /// `refreshGeneration` at entry and, after its `await`ed git I/O resolves,
    /// commits its result only while it is still the latest refresh — so a slower,
    /// superseded refresh discards its stale result rather than clobbering a newer
    /// one's published state.
    public func refresh(root: URL, requestGeneration: Int? = nil) async {
        // Reject a refresh launched for a folder-open request that a *newer*
        // folder-open has since superseded. The app captures the request
        // generation synchronously from `prepareForFolderChange` and passes it
        // here; unstructured `Task`s are not guaranteed to start in creation
        // order, so an older folder's refresh task can begin running after a
        // newer folder's. Without this it would re-derive the switch from `root
        // != lastRequestedRoot` in `refreshImpl`, rewrite `lastRequestedRoot`
        // back to the old folder, win `refreshGeneration`, and leave the Changes
        // panel showing a different repository than the workspace. Rejecting here
        // — before bumping `operationGeneration`, so a dropped refresh supersedes
        // nothing — keeps the latest folder-open request authoritative. Every app
        // refresh call site (folder-open, the post-save refresh, the manual refresh
        // button, and the view's `onAppear`/`onChange` backstop) now passes the
        // generation captured *synchronously* at the call site, so any of them that
        // ends up running after a newer folder switch is rejected here rather than
        // entering `refreshImpl` and being misread as a switch *back* to its
        // now-stale root (which would rewrite `lastRequestedRoot`, bump the request
        // generation, and reject the newer folder's legitimate refresh — stranding
        // the panel on the previous repository). A refresh with no pinned generation
        // (only the tests construct one) is never rejected.
        if let requestGeneration, requestGeneration != rootRequestGeneration { return }
        // A public refresh is a new top-level operation: advance the operation
        // token so an older, still-suspended `revert` defers its trailing error
        // write to this newer result. Internal trailing refreshes inside `revert`
        // go through `refreshImpl` instead, so they do not advance it (a revert
        // must not suppress its *own* error via its *own* refresh).
        operationGeneration += 1
        await refreshImpl(root: root)
    }

    /// Synchronously record that the opened project is switching to `root`,
    /// *before* launching the async `refresh` that queries it.
    ///
    /// `refresh` already records the switch (clearing the previous project's
    /// files/selection/checks and bumping `rootRequestGeneration`) at its entry —
    /// but a caller that wraps `refresh` in a `Task` (as the app does for a folder
    /// open, since the model's methods are `async`) runs that entry a *later*
    /// main-actor turn than the folder-open event itself. A `revert` continuation
    /// whose off-main git I/O completes in that gap can resume first, observe the
    /// not-yet-bumped generation, and mutate the *previous* repository. Calling
    /// this synchronously in the same main-actor turn that handles the folder
    /// switch closes that gap: the generation is bumped before the main actor can
    /// run any suspended revert, so the revert sees the switch and bails. The
    /// subsequent `refresh(root:)` then no-ops this block (its `root ==
    /// lastRequestedRoot`), so there is no double-clear. Idempotent for a repeated
    /// same-folder call.
    ///
    /// Returns the `rootRequestGeneration` this folder-open request corresponds
    /// to (after the possible bump). The caller passes it back into the
    /// `Task`-wrapped `refresh(root:requestGeneration:)` so that refresh, should
    /// it run after a *newer* folder-open superseded it, is rejected instead of
    /// rewriting the displayed project backward. (A no-op same-folder call returns
    /// the current, unchanged generation.)
    @discardableResult
    public func prepareForFolderChange(root: URL) -> Int {
        guard root != lastRequestedRoot else { return rootRequestGeneration }
        lastRequestedRoot = root
        rootRequestGeneration += 1
        changedFiles = []
        selected = nil
        revertSelection = []
        errorMessage = nil
        return rootRequestGeneration
    }

    /// The `rootRequestGeneration` the currently displayed project corresponds to.
    ///
    /// A caller that defers a `revert` across a `Task` hop captures this
    /// synchronously — in the same main-actor turn the user acted in — and passes
    /// it back as `revert(_:originGeneration:)`, so a revert queued against one
    /// project is rejected if the opened folder changed before the task ran.
    public var currentRequestGeneration: Int { rootRequestGeneration }

    private func refreshImpl(root: URL) async {
        refreshGeneration += 1
        let generation = refreshGeneration
        // A change of opened folder invalidates the currently displayed files
        // immediately: they belong to the previous repository and must not stay
        // actionable (a revert would hit the old repo) during the `await` for the
        // new repository's status. Clear them synchronously, up front, before the
        // first suspension — the resolved-root reconciliation below still runs on
        // the fresh list. A same-root refresh (save, manual refresh) skips this,
        // so the list and selection do not flicker on the common path.
        if root != lastRequestedRoot {
            lastRequestedRoot = root
            // Advance the request generation synchronously, before the first
            // suspension, so an in-flight `revert` (suspended on off-main git
            // I/O) detects this project switch immediately — without waiting for
            // the slower `self.root = repoRoot` commit below.
            rootRequestGeneration += 1
            changedFiles = []
            selected = nil
            revertSelection = []
            errorMessage = nil
        }
        // The request generation this refresh's `root` corresponds to (captured
        // after the possible bump above). Committed with `self.root` once the git
        // I/O resolves, so `publishedRootGeneration` tracks the published root.
        let rootGeneration = rootRequestGeneration
        do {
            let repoRoot = try await gitService.repositoryRoot(for: root)
            let files = try await gitService.changedFiles(root: repoRoot)
            // A newer refresh started and is the one that should win; discard this
            // now-stale result rather than overwriting the newer published state.
            // Also discard if the opened folder switched since this refresh began:
            // a folder switch bumps `rootRequestGeneration` (but *not*
            // `refreshGeneration`), so a refresh that started against the previous
            // project would otherwise re-publish its files after
            // `prepareForFolderChange`/`refreshImpl` already cleared them up front —
            // making the previous repository's files reappear (and stay actionable)
            // throughout the new project's query.
            guard generation == refreshGeneration,
                  rootGeneration == rootRequestGeneration else { return }
            let previousRoot = self.root
            self.root = repoRoot
            publishedRootGeneration = rootGeneration
            changedFiles = files
            errorMessage = nil
            // Reconcile the checkbox set and selection against the refreshed
            // list in one pure step (clear-on-root-change vs intersect, plus the
            // selection re-bind) — see `reconcile`.
            let reconciliation = Self.reconcile(
                previousRoot: previousRoot,
                newRoot: repoRoot,
                files: files,
                selected: selected,
                revertSelection: revertSelection
            )
            revertSelection = reconciliation.revertSelection
            selected = reconciliation.selected
        } catch {
            // Same stale-result guards on the failure path: a superseded refresh —
            // whether superseded by a newer refresh of the same folder
            // (`refreshGeneration`) or by a folder switch (`rootRequestGeneration`) —
            // must not clear a newer refresh's (or the post-switch cleared) state.
            guard generation == refreshGeneration,
                  rootGeneration == rootRequestGeneration else { return }
            self.root = root
            publishedRootGeneration = rootGeneration
            changedFiles = []
            selected = nil
            // Clear the revert checkbox set too. A failure stores the *unresolved*
            // passed-in `root` (the repo top level couldn't be resolved), so a later
            // successful refresh whose resolved repo root happens to equal it — e.g.
            // the user opened a different repository at its top level and the first
            // refresh failed — would see `previousRoot == repoRoot` and *intersect*
            // rather than clear, silently carrying path-equal checks across into an
            // unrelated repository. Clearing here also keeps the set consistent with
            // the now-empty `changedFiles`.
            revertSelection = []
            errorMessage = error.localizedDescription
        }
    }

    /// Select `file` (no-op if it is not among the current changed files), or
    /// clear the selection when passed `nil`.
    public func select(_ file: ChangedFile?) {
        guard let file else {
            selected = nil
            return
        }
        guard changedFiles.contains(where: { $0.id == file.id }) else { return }
        selected = file
    }

    // MARK: - Revert

    /// Raise the revert gate (`isReverting`), recording one in-flight revert.
    ///
    /// The app calls this *synchronously* in the same main-actor turn it confirms a
    /// revert — before spawning the `Task` that awaits the off-main git work — so a
    /// project-tree file operation cannot slip in (and start a racing disk write)
    /// in the gap before the task body runs. Balanced by `endRevert()`.
    public func beginRevert() {
        revertGateCount += 1
        isReverting = true
    }

    /// Lower the revert gate, balancing one `beginRevert()`. `isReverting` clears
    /// only once every overlapping revert has ended (the counter returns to zero).
    public func endRevert() {
        revertGateCount = max(0, revertGateCount - 1)
        if revertGateCount == 0 {
            isReverting = false
        }
    }

    /// Toggle whether `file` is checked for a multi-file revert.
    public func toggleChecked(_ file: ChangedFile) {
        if revertSelection.contains(file.id) {
            revertSelection.remove(file.id)
        } else {
            revertSelection.insert(file.id)
        }
    }

    /// Resolve which files a revert triggered from `contextFile` should affect.
    ///
    /// If `contextFile` is itself checked, the revert applies to every currently
    /// changed file that is checked (a batch revert of the checked set); otherwise
    /// it applies to just `contextFile` (acting on an unchecked row reverts only
    /// that row). Pure — touches no I/O.
    public func filesToRevert(contextFile: ChangedFile) -> [ChangedFile] {
        guard revertSelection.contains(contextFile.id) else { return [contextFile] }
        return changedFiles.filter { revertSelection.contains($0.id) }
    }

    /// Discard the local changes in `files`, restoring each from `HEAD` (or
    /// deleting the no-`HEAD` cases) via the injected `GitServicing`.
    ///
    /// Destructive and irreversible — callers confirm first. The displayed list is
    /// a snapshot and nothing watches the filesystem on its behalf (the macOS
    /// FSEvents watcher feeds the *project tree* only, never this list), so
    /// immediately before
    /// *each* file's mutation the repository is re-queried and that file is checked
    /// against its *current* status: a file that changed (e.g. an untracked/added
    /// file that became tracked and was then modified, so deleting it would discard
    /// newer uncommitted content) aborts the batch with `errorMessage` set, leaving
    /// the not-yet-reverted files for a retry against the refreshed state. The
    /// re-query runs per file rather than once before the loop because reverting
    /// the earlier files takes time, during which a later file can change out of
    /// band; a single up-front snapshot would leave a window that grows with the
    /// batch size. This collapses a possibly-minutes-old snapshot to the
    /// milliseconds between each file's re-query and its revert; the residual
    /// window is git's own to close.
    ///
    /// Each remaining file is reverted in turn; the first failure sets
    /// `errorMessage` and stops. The files already reverted in this batch are
    /// dropped from the checked set and the list (a retry would otherwise
    /// re-attempt them and fail immediately on the now-gone file, masking the one
    /// that actually failed); the failing and not-yet-tried files stay checked,
    /// with the message visible, for a retry. A failure that left part of the
    /// working tree changed — a *rename* that fails between its two steps, or a
    /// `checkout` that restored the worktree before a late index-write failure —
    /// reports exactly the paths the service says it changed (via
    /// `PartialRevertError`), so the caller resyncs only those; a failure that
    /// reports nothing changed nothing.
    /// On full success `errorMessage` is cleared, the list refreshed (dropping the
    /// reverted files and re-binding/clearing the selection), and the reverted
    /// files removed from the checked set (only those — not the whole set — so a
    /// file the user checks during the trailing refresh's `await` is preserved).
    /// Returns the absolute URLs whose on-disk state the revert changed,
    /// so the caller can resync any open editor tabs — for a rename this is *both*
    /// the new path (deleted) and the restored old path. A no-op returning `[]`
    /// before the first refresh (no `root`).
    @discardableResult
    public func revert(_ files: [ChangedFile], originGeneration: Int? = nil) async -> [URL] {
        guard let root else { return [] }
        // Reject a revert deferred across a `Task` hop whose originating project
        // was replaced before the task started running. The app captures
        // `originGeneration` synchronously from `currentRequestGeneration` (in the
        // same main-actor turn the user confirmed the revert) and passes it here;
        // the `files` were captured against that project too. But `root` and the
        // generations read just below are sampled only now, at task start — so if
        // a folder switch to a new repository fully committed in the gap, those
        // would describe the *new* repo, and a path-equal file with a matching
        // status would pass `guardRevert` and be destructively reverted there.
        // Bailing when the pinned generation no longer matches keeps the revert
        // bound to the project it was confirmed against. (A revert with no pinned
        // generation — none of the app's paths today — skips this check.)
        if let originGeneration, originGeneration != rootRequestGeneration { return [] }
        // Capture the request generation at entry. A *folder switch* bumps this
        // synchronously at refresh entry (before `self.root` is committed), so it
        // catches a mid-revert switch that a `self.root == root` check would miss
        // during the window between `refresh(B)` recording the switch and
        // committing `self.root = B`. `projectStillCurrent` is true while the
        // opened project has not changed since this revert began.
        let requestGeneration = rootRequestGeneration
        // A folder switch bumps `rootRequestGeneration` synchronously at refresh
        // entry but commits the new `self.root` only after its git I/O resolves.
        // If a switch is pending in that window, `self.root` is still the *old*
        // repo while the request generation has already advanced — so a revert
        // starting now would capture the new generation (every `projectStillCurrent`
        // check would pass) next to the stale root and mutate the repository the
        // user just left. `publishedRootGeneration` lags the request generation in
        // exactly that window, so bail when they disagree.
        guard publishedRootGeneration == requestGeneration else { return [] }
        func projectStillCurrent() -> Bool { rootRequestGeneration == requestGeneration }

        // Capture the operation token. A *different* later operation (a manual or
        // save-driven `refresh`, or another `revert`) advances `operationGeneration`,
        // so `operationStillLatest()` going false means this revert was superseded
        // within the same project — it must then drop its trailing `errorMessage`
        // write rather than restore a stale error over the newer result. This
        // revert's own internal refreshes use `refreshImpl`, which does not bump
        // the token, so they never make it look superseded by itself.
        operationGeneration += 1
        let operation = operationGeneration
        func operationStillLatest() -> Bool { operationGeneration == operation }

        // Refresh against the *requested* folder, not the resolved repo `root`:
        // when a subfolder was opened the two differ, and passing the resolved root
        // would look like a folder switch to `refresh` (it differs from
        // `lastRequestedRoot`), spuriously clearing state and bumping the request
        // generation — which would then make `projectStillCurrent` report a switch
        // that never happened. `lastRequestedRoot` is always set once `root` is.
        let requestedRoot = lastRequestedRoot ?? root

        var revertedURLs: [URL] = []
        var revertedIDs: Set<String> = []
        for file in files {
            // Stop if the opened project switched out from under this revert (a
            // folder change bumped `rootRequestGeneration` while we were suspended
            // on off-main git I/O between batch files). The captured-generation
            // check fires the instant the switch is *requested*, before the new
            // repo's `self.root` is committed — so the window where `self.root`
            // still equals the old `root` cannot let a stale revert through.
            // Continuing would discard changes in the repository the user just
            // left, and the post-revert refresh below would clobber the new
            // repository's freshly published state. Already-reverted files stand
            // and are returned so their tabs resync; the new project's state
            // (list, selection, checks) is left untouched — its refresh owns it.
            guard projectStillCurrent() else { return revertedURLs }

            // Re-query immediately before *this* file's mutation: a destructive
            // revert must never act on a stale snapshot (the panel can sit
            // refreshed for a while, git operations can happen out from under it,
            // and reverting the earlier files in the batch took time too). If the
            // re-query itself fails there is no safe ground to act on, so surface
            // it and stop — dropping any already-reverted files from the checked
            // set and refreshing first so a retry sees current state.
            let currentByID: [String: ChangedFile]
            do {
                currentByID = Dictionary(
                    try await gitService.changedFiles(root: root).map { ($0.id, $0) },
                    uniquingKeysWith: { first, _ in first }
                )
            } catch {
                // Only touch published state if the project is still the one this
                // revert began on — otherwise a newer repository's refresh owns it.
                if projectStillCurrent() {
                    let message = error.localizedDescription
                    if !revertedIDs.isEmpty {
                        revertSelection.subtract(revertedIDs)
                        await refreshImpl(root: requestedRoot)
                    }
                    // `refresh` above awaited, so the project may have switched
                    // while it was suspended (its own generation guard discards the
                    // stale result); only write if it is still the current project
                    // *and* no newer same-project operation has superseded us (else
                    // we would restore this stale error over the newer result).
                    if projectStillCurrent() && operationStillLatest() {
                        errorMessage = message
                    }
                }
                return revertedURLs
            }

            // The re-query is an `await`, so re-check for a project switch before
            // the destructive call and any state commit below.
            guard projectStillCurrent() else { return revertedURLs }

            // Abort if the file changed (status flipped, was committed away, …)
            // since this re-query — the user confirmed against state that no
            // longer holds, and reverting now could delete newer content. Drop
            // what already reverted from the checked set (as on a failure) and
            // refresh so the next attempt sees current state. (Safe to commit
            // unconditionally: the guard just above ran with no suspension since,
            // so the project is still current.)
            if case .abort(let reason) = Self.guardRevert(file: file, current: currentByID[file.id]) {
                revertSelection.subtract(revertedIDs)
                await refreshImpl(root: requestedRoot)
                // `refresh` awaited; only write if the project is still current and
                // this revert was not superseded by a newer same-project operation.
                if projectStillCurrent() && operationStillLatest() {
                    errorMessage = reason
                }
                return revertedURLs
            }
            do {
                try await gitService.revert(file, root: root)
                // The file's own path, plus — for a rename — the restored old
                // path, whose open tab must reload its `HEAD` contents.
                revertedURLs.append(contentsOf: Self.revertedURLs(for: file, root: root))
                revertedIDs.insert(file.id)
            } catch {
                // A failure can leave the working tree partly changed: a rename
                // revert is two on-disk operations (restore the old path, then
                // remove the new one) and can fail *between* them, and a
                // `checkout` writes the worktree before a late index-write failure
                // that still exits non-zero. The service reports exactly which
                // paths it changed before failing via `PartialRevertError`, so
                // resync only those — guessing would reload/close a tab the revert
                // never touched (discarding unsaved edits there). A failure that
                // does not conform changed nothing on disk.
                if let partial = error as? PartialRevertError {
                    for path in partial.changedPaths {
                        revertedURLs.append(root.appendingPathComponent(path))
                    }
                }
                // Stop on the first failure, but drop the files already reverted
                // in this batch from both the checked set and the list (via
                // `refresh`). Otherwise a retry would re-attempt them, and a
                // revert of an already-reverted added/renamed file fails
                // immediately (`git rm` on a vanished path) — masking the file
                // that actually failed and never reaching it. The failing file
                // and any not-yet-attempted files stay checked for the retry.
                // `refresh` clears `errorMessage`, so restore it afterwards. Only
                // commit if the project did not switch during the `revert` await;
                // otherwise the new repository's refresh owns the published state.
                if projectStillCurrent() {
                    let message = error.localizedDescription
                    revertSelection.subtract(revertedIDs)
                    await refreshImpl(root: requestedRoot)
                    // `refresh` awaited; only write if the project is still current
                    // and a newer same-project operation has not superseded us.
                    if projectStillCurrent() && operationStillLatest() {
                        errorMessage = message
                    }
                }
                return revertedURLs
            }
        }
        // Full success: publish only if the project is still the one we started
        // on — a refresh of the captured `root` would otherwise re-publish the old
        // repository over a project the user switched to mid-revert.
        if projectStillCurrent() {
            errorMessage = nil
            await refreshImpl(root: requestedRoot)
            // `refresh` awaited; only update the checked set if the project is still
            // current and no newer same-project operation has superseded us (a
            // switch or newer op during the await leaves the published state to its
            // owner's refresh, which already reconciled `revertSelection`). Subtract
            // only the files this batch reverted rather than clearing the whole set:
            // the main actor processes UI events during the awaits above, so the
            // user may have checked another file in that window — `= []` would
            // silently erase that fresh check. (`refresh`'s reconcile already pruned
            // the reverted ids, since they left `changedFiles`, so this is
            // consistent with the failure paths, which likewise `subtract(revertedIDs)`.)
            if projectStillCurrent() && operationStillLatest() {
                revertSelection.subtract(revertedIDs)
            }
        }
        return revertedURLs
    }

    /// The folder-grouped tree of the current changed files, or `[]` before the
    /// first refresh.
    public var tree: [ChangeNode] {
        guard let root else { return [] }
        return ChangeTree.build(from: changedFiles, root: root)
    }

    /// Side-by-side diff rows for the selected file, or `[]` when nothing is
    /// selected.
    public func selectedRows() async -> [DiffRow] {
        guard let selected else { return [] }
        return await rows(for: selected)
    }

    /// Build the side-by-side diff (working copy vs `HEAD`) for `file`.
    ///
    /// The old side is `HEAD`'s contents (empty for an added/untracked file, or
    /// when the read fails); for a rename, `HEAD` is read from `oldPath`. The new
    /// side is the working-copy text (empty for a deleted file, or when the read
    /// fails). Returns `[]` before the first refresh (no `root`).
    public func rows(for file: ChangedFile) async -> [DiffRow] {
        guard let root else { return [] }
        return LineDiff.rows(
            old: await headText(for: file, root: root),
            new: workingText(for: file, root: root)
        )
    }

    // MARK: - Diff side resolution

    private func headText(for file: ChangedFile, root: URL) async -> String {
        switch file.status {
        case .added, .untracked:
            // No `HEAD` version exists; the old side is empty.
            return ""
        case .modified, .deleted, .renamed, .conflicted:
            // For a rename, `HEAD` holds the pre-rename path. `headContents` both
            // throws and returns `String?`, so `try?` yields `String??`; flatten
            // both layers so any failure (or a missing object) is an empty side.
            let headPath = file.oldPath ?? file.path
            return (try? await gitService.headContents(of: headPath, root: root)).flatMap { $0 } ?? ""
        }
    }

    private func workingText(for file: ChangedFile, root: URL) -> String {
        // A deleted file has no working copy; the new side is empty.
        guard file.status != .deleted else { return "" }
        let url = root.appendingPathComponent(file.path)
        // Git stores a symlink's *target string* as its blob (so `HEAD` reads it
        // back), so the working side must compare against that target, not the
        // dereferenced target file's contents — reading through the link would
        // both produce a wrong diff and pull in content from outside the repo.
        if let target = fileService.symbolicLinkDestination(at: url) {
            return target
        }
        return (try? fileService.read(url: url)) ?? ""
    }
}
