import Foundation

/// Observable state for the branch-switcher widget: the local/remote branch list,
/// the current branch, a display filter, and the "working tree dirty" flag that
/// warns a checkout may be blocked.
///
/// Mirrors `LocalChangesModel`/`CommitLogModel`'s shape — an `@MainActor
/// ObservableObject` that funnels mutation through testable methods and injects
/// its git I/O behind `GitServicing`, so the real `Process`/libgit2-backed service
/// runs in the view layer and an in-memory stub in tests. Pure Foundation — no
/// `Process`/AppKit/SwiftUI.
///
/// The branch *list* is built from the existing `references(root:)` (full
/// refnames) fed through `BranchRef.build(fromRefnames:current:)` — no separate
/// `branches(...)` git method exists; only `currentBranch` is queried in addition.
/// All the branching decisions (grouping/sorting/marking, filter, "remote start
/// requires fetch", the default name for a create-from-remote) live in pure
/// static helpers here and in `BranchRef`/`GitRefName`, so they stay under fast
/// unit tests while only the I/O/sequencing is async. The orchestration gates
/// (autosave suspend, tree lock, tab resync) live in the app layer, like the
/// revert/apply-merge paths.
@MainActor
public final class BranchSwitcherModel: ObservableObject {
    /// The branch list as of the last successful `refresh`: locals first, then
    /// remotes, each sorted by short name (the `BranchRef.build` order). Split for
    /// display via `filteredLocalBranches`/`filteredRemoteBranches`.
    @Published public private(set) var branches: [BranchRef] = []

    /// The currently checked-out local branch, or `nil` for a detached/unborn HEAD.
    @Published public private(set) var current: BranchRef?

    /// The widget's case-insensitive substring filter over short branch names. A
    /// mutable binding for the filter field; the filtered views apply it live.
    @Published public var filterText: String = ""

    /// Whether the working tree has uncommitted changes (any `changedFiles`). The
    /// widget uses it to warn before a checkout that git may refuse to overwrite
    /// local changes; git makes the final call (a real refusal surfaces via
    /// `errorMessage`).
    @Published public private(set) var isWorkingTreeDirty = false

    /// A human-readable description of the last failure (a failed refresh, a blocked
    /// checkout, a failed create), or `nil` after a success.
    @Published public private(set) var errorMessage: String?

    /// The repository root the model was last refreshed against, so `switchTo` /
    /// `createBranch` can run without the caller re-supplying it.
    @Published public private(set) var root: URL?

    private let gitService: GitServicing

    /// Monotonically increasing token identifying the latest `refresh`. Bumped
    /// **synchronously** by `prepareForRefresh` on the main-actor turn that creates
    /// the refresh `Task`, before any `await` — so two rapid folder opens settle on
    /// the most recent even when their unstructured tasks start out of creation
    /// order (the `LocalChangesModel`/`CommitLogModel` precedent). A token bumped
    /// only inside the async body would let the *earlier* folder's task, if it runs
    /// last, win and strand the widget on the repo the user left. Each `refresh`
    /// commits its published state only while its token is still the latest, so a
    /// slower superseded refresh discards its stale result.
    private var refreshGeneration = 0

    /// The opened folder last requested via `prepareForRefresh`/`refresh`, so a
    /// folder switch is detected and the previous repo's branch list cleared
    /// synchronously — it must not stay visible/actionable against a repo the user
    /// has left while the new refresh is in flight.
    private var lastRequestedRoot: URL?

    /// The current refresh token, for a caller that captures it synchronously
    /// before its own `Task` hop without a folder-switch reset. (`prepareForRefresh`
    /// is the usual entry point.)
    public var currentRefreshGeneration: Int { refreshGeneration }

    public init(gitService: GitServicing) {
        self.gitService = gitService
    }

    // MARK: - Filtered views

    /// The local branches narrowed by `filterText`.
    public var filteredLocalBranches: [BranchRef] {
        BranchRef.filtered(BranchRef.locals(branches), query: filterText)
    }

    /// The remote branches narrowed by `filterText`.
    public var filteredRemoteBranches: [BranchRef] {
        BranchRef.filtered(BranchRef.remotes(branches), query: filterText)
    }

    // MARK: - Refresh

    /// Capture the latest refresh token synchronously, on the main-actor turn that
    /// creates the refresh `Task`, before any `await`. Two rapid folder opens spawn
    /// two refresh tasks and unstructured tasks are not guaranteed to start in
    /// creation order, so a token bumped only inside the async body could let the
    /// earlier folder's task (running last) win; capturing it here orders requests
    /// by creation. On a folder switch it also clears the previous repo's branch
    /// list synchronously so the widget is never actionable against a repo the user
    /// left. Pass the returned token into `refresh(root:request:)`.
    @discardableResult
    public func prepareForRefresh(root requestedRoot: URL) -> Int {
        refreshGeneration += 1
        if requestedRoot != lastRequestedRoot {
            lastRequestedRoot = requestedRoot
            branches = []
            current = nil
            isWorkingTreeDirty = false
            errorMessage = nil
            // Clear `root` too: the widget gates every mutation (checkout / create)
            // on `root != nil`, so leaving the previous repo's resolved root here
            // would keep "New Branch…" et al. running against a repo the user has
            // left (a non-repo new folder never re-populates it). It is re-set only
            // when the new folder's refresh resolves.
            root = nil
        }
        return refreshGeneration
    }

    /// Reload the branch list, current branch, and dirty-tree flag against
    /// `requestedRoot` (resolved to the repository top level first, so a nested
    /// opened folder still reports the repo's branches). On failure it clears the
    /// list and sets `errorMessage`, never crashing the view.
    ///
    /// `request` is the token captured synchronously by `prepareForRefresh` before
    /// the caller's `Task` hop. When provided, the refresh bails immediately if a
    /// newer request has already superseded it (so an out-of-order task can't win)
    /// and uses that token as its post-`await` stale-result guard. A direct call
    /// (tests, the internal trailing refresh after a switch/create) may omit it, in
    /// which case a fresh token is bumped at entry and this refresh is the latest.
    public func refresh(root requestedRoot: URL, request: Int? = nil) async {
        let generation: Int
        if let request {
            // A newer request was registered after this one; it will publish, so
            // drop this superseded request rather than letting it win out of order.
            guard request == refreshGeneration else { return }
            generation = request
        } else {
            refreshGeneration += 1
            generation = refreshGeneration
        }
        // Defense in depth for a direct `refresh` (no `prepareForRefresh`): a folder
        // switch clears the previous repo's list here too; a no-op when
        // `prepareForRefresh` already handled the same switch.
        if requestedRoot != lastRequestedRoot {
            lastRequestedRoot = requestedRoot
            branches = []
            current = nil
            isWorkingTreeDirty = false
            root = nil
        }

        let resolvedRoot: URL
        do {
            resolvedRoot = try await gitService.repositoryRoot(for: requestedRoot)
        } catch {
            guard generation == refreshGeneration else { return }
            commitFailure(error)
            return
        }

        do {
            let refnames = try await gitService.references(root: resolvedRoot)
            let currentBranch = try await gitService.currentBranch(root: resolvedRoot)
            let changed = try await gitService.changedFiles(root: resolvedRoot)
            guard generation == refreshGeneration else { return }
            self.root = resolvedRoot
            self.current = currentBranch
            self.branches = BranchRef.build(fromRefnames: refnames, current: currentBranch?.shortName)
            self.isWorkingTreeDirty = !changed.isEmpty
            self.errorMessage = nil
        } catch {
            guard generation == refreshGeneration else { return }
            commitFailure(error)
        }
    }

    private func commitFailure(_ error: Error) {
        branches = []
        current = nil
        isWorkingTreeDirty = false
        errorMessage = error.localizedDescription
    }

    // MARK: - Switch / create

    /// Check out the local branch `branch`. Returns `true` on success (and
    /// refreshes so `current`/`branches` reflect the switch), `false` on failure —
    /// a blocked checkout (`GitError.checkoutFailed`) puts git's message (naming the
    /// conflicting files) into `errorMessage`.
    ///
    /// For a *remote* branch the widget calls `createBranch(from:)` instead (you
    /// can't check out a remote-tracking ref directly), so this is passed only local
    /// branches; it uses the short name git's `checkout` expects.
    ///
    /// `originGeneration` is the `currentRefreshGeneration` the app captured
    /// **synchronously**, in the same main-actor turn the user chose the branch,
    /// before its own `Task` hop. `root` is sampled only now, at task-body time — so
    /// if a folder switch to another repository fully committed in the gap (a
    /// `prepareForRefresh` bumps the generation and re-sets `root` when the new
    /// folder's refresh resolves), a checkout would otherwise run against the *new*
    /// repo (checking out a same-named branch there). Bailing when the pinned
    /// generation no longer matches keeps the checkout bound to the repository the
    /// user was looking at — the `LocalChangesModel.revert(_:originGeneration:)`
    /// precedent. A call with no pinned generation (the tests) skips the check.
    @discardableResult
    public func switchTo(_ branch: BranchRef, originGeneration: Int? = nil) async -> Bool {
        if let originGeneration, originGeneration != refreshGeneration { return false }
        guard let root else { return false }
        // Pin the generation *before* the off-main checkout so the trailing refresh
        // is superseded by a folder switch that lands during it, rather than
        // re-deriving a spurious "switch back" to this repo (bumping the generation
        // with `request: nil` would re-run the folder-switch reset for the old root
        // and strand the widget on the repo the user just left).
        let generation = refreshGeneration
        do {
            try await gitService.checkout(branch: branch.shortName, root: root)
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
        errorMessage = nil
        // Refresh against the *requested* folder, not the resolved repo `root`: for a
        // subfolder-opened repo the two differ, and passing the resolved root would
        // make `refresh` see `requestedRoot != lastRequestedRoot` and spuriously fire
        // its folder-switch reset (clearing the list and drifting `lastRequestedRoot`
        // to the repo top). Mirrors `LocalChangesModel`'s `lastRequestedRoot ?? root`.
        await refresh(root: lastRequestedRoot ?? root, request: generation)
        return true
    }

    /// The outcome of `createBranch`, so the caller can react without inspecting
    /// `errorMessage` for control flow.
    public enum CreateOutcome: Equatable {
        /// The branch was created and checked out; the model refreshed.
        case created
        /// `name` is not a valid git branch name (`GitRefName.isValid` failed); no
        /// git call was made.
        case invalidName
        /// The start point was a remote ref and the fetch failed (offline, or on
        /// iOS a PAT is required). The caller offers "create from the local tracking
        /// ref" (retry with `fetchRemote: false`) or cancel. Carries git's error so
        /// the caller can special-case `credentialsRequired` (direct to Settings).
        case fetchUnavailable(GitError)
        /// The create+checkout itself failed; `errorMessage` carries git's message.
        case failed
    }

    /// Where a new branch starts.
    public enum StartPoint: Equatable {
        /// The current `HEAD` (the default "New Branch…" start point).
        case head
        /// An existing branch ref — a local branch, or a remote one (which requires
        /// a fetch first so the start point is up to date).
        case ref(BranchRef)

        /// The git revision to start the branch at (a full refname or `HEAD`).
        var revision: String {
            switch self {
            case .head: return "HEAD"
            case .ref(let ref): return ref.name
            }
        }
    }

    /// The default new-branch name to pre-fill when creating from a remote branch:
    /// its short name with the `<remote>/` prefix stripped (`origin/master` →
    /// `master`). Pure, so the "click a remote branch → prefilled create dialog"
    /// flow is testable.
    public static func defaultBranchName(forRemote ref: BranchRef) -> String {
        guard ref.isRemote, let remote = ref.remoteName else { return ref.shortName }
        let prefix = remote + "/"
        if ref.shortName.hasPrefix(prefix) {
            return String(ref.shortName.dropFirst(prefix.count))
        }
        return ref.shortName
    }

    /// What clicking "Checkout" on a remote branch should do (git's DWIM behavior,
    /// as a pure decision over the passed branch list).
    public enum RemoteCheckoutDecision: Equatable {
        /// A same-named local branch already exists — just check it out.
        case checkoutLocal(BranchRef)
        /// No same-named local exists — create one from the remote ref (no fetch).
        case createLocal(name: String, from: BranchRef)
    }

    /// Decide how to check out a remote branch (git's DWIM): the target local name
    /// is `defaultBranchName(forRemote:)` (the `<remote>/` prefix stripped); if a
    /// local branch with that short name already exists, check it out, otherwise
    /// create a same-named local from the remote ref. Pure — a decision over the
    /// passed list only, no fetch — so the "click a remote branch → Checkout" flow
    /// is testable (the `defaultBranchName`/`StartPoint` precedent).
    public static func remoteCheckoutDecision(
        for remote: BranchRef,
        among branches: [BranchRef]
    ) -> RemoteCheckoutDecision {
        let name = defaultBranchName(forRemote: remote)
        if let local = BranchRef.locals(branches).first(where: { $0.shortName == name }) {
            return .checkoutLocal(local)
        }
        return .createLocal(name: name, from: remote)
    }

    /// Validate `name`, fetch first when starting from a remote ref (unless
    /// `fetchRemote` is `false`), then create+check out `name` at `startPoint` and
    /// refresh on success.
    ///
    /// A remote start with a failed fetch returns `.fetchUnavailable` *without*
    /// setting `errorMessage` (it is a recoverable choice, not a hard error): the
    /// caller can retry with `fetchRemote: false` to create from the local tracking
    /// ref as it stands, or cancel.
    ///
    /// `originGeneration` pins the create to the repository the user was looking at
    /// when they confirmed it, exactly like `switchTo`: `root` is sampled at
    /// task-body time, so a folder switch that fully committed across the app's
    /// `Task` hop would otherwise create+check out the branch in the *new* repo.
    /// Bailing on a mismatch (as `.failed`, without a git call) keeps the mutation
    /// bound to the origin repo. A call with no pinned generation (the tests) skips
    /// the check.
    @discardableResult
    public func createBranch(
        name: String,
        from startPoint: StartPoint,
        fetchRemote: Bool = true,
        originGeneration: Int? = nil
    ) async -> CreateOutcome {
        guard GitRefName.isValid(name) else { return .invalidName }
        if let originGeneration, originGeneration != refreshGeneration { return .failed }
        guard let root else { return .failed }

        // Pin the generation before the off-main fetch/create so the trailing
        // refresh is superseded by a folder switch that lands during them, rather
        // than re-deriving a spurious "switch back" to this repo (see `switchTo`).
        let generation = refreshGeneration

        if fetchRemote, case .ref(let ref) = startPoint, ref.isRemote, let remote = ref.remoteName {
            do {
                try await gitService.fetch(remote: remote, root: root)
            } catch {
                return .fetchUnavailable(Self.gitError(from: error))
            }
        }

        do {
            try await gitService.createAndCheckout(
                name: name,
                startPoint: startPoint.revision,
                root: root
            )
        } catch {
            errorMessage = error.localizedDescription
            return .failed
        }

        errorMessage = nil
        // See `switchTo`: refresh against the requested folder so a subfolder-opened
        // repo doesn't spuriously trip `refresh`'s folder-switch reset.
        await refresh(root: lastRequestedRoot ?? root, request: generation)
        return .created
    }

    /// Check out a *remote* branch with git's DWIM behavior. Computes
    /// `remoteCheckoutDecision(for:among:)` over the current `branches` and executes
    /// it through the existing paths: a same-named local already exists → `switchTo`
    /// it; otherwise create a same-named local from the remote ref via `createBranch`
    /// with **no fetch** (`fetchRemote: false`) — Checkout is meant to be immediate.
    /// Returns `true` on success.
    ///
    /// Both paths inherit the origin-generation pinning and trailing refresh from
    /// their delegates: `originGeneration` (the `currentRefreshGeneration` the app
    /// captured synchronously before its `Task` hop) is threaded straight through, so
    /// a folder switch that committed in the gap makes the delegate bail before any
    /// git call, leaving `errorMessage` untouched. The decision is computed in the
    /// task body over `branches` — after a folder switch clears `branches` the
    /// decision degrades to `.createLocal`, whose `createBranch` then bails on the
    /// generation mismatch, so a superseded checkout never reaches git.
    @discardableResult
    public func checkoutRemote(_ remote: BranchRef, originGeneration: Int? = nil) async -> Bool {
        // Bail *before any git call and before computing the decision* when a folder
        // switch superseded this checkout, leaving `errorMessage` untouched (the doc
        // contract above). Without this early guard, the `.createLocal` path's
        // `createBranch` validates the DWIM-derived name *before* its own generation
        // check, so a superseded checkout whose stripped name is invalid locally
        // (e.g. `origin/-foo` → `-foo`) would return `.invalidName` and set an
        // invalid-branch `errorMessage` for the repo the user already left. Mirrors
        // `switchTo`/`createBranch`'s guard; a call with no pinned generation (the
        // tests) skips it.
        if let originGeneration, originGeneration != refreshGeneration { return false }
        switch Self.remoteCheckoutDecision(for: remote, among: branches) {
        case .checkoutLocal(let local):
            return await switchTo(local, originGeneration: originGeneration)
        case .createLocal(let name, let from):
            let outcome = await createBranch(
                name: name,
                from: .ref(from),
                fetchRemote: false,
                originGeneration: originGeneration
            )
            // `createBranch` signals an invalid name only via its return value (the
            // create-dialog path reports it in the view layer). Here the result
            // collapses to `Bool`, so surface it as `errorMessage` — otherwise a
            // DWIM-derived local name git accepts but `GitRefName.isValid` rejects
            // (e.g. a leading `-`) would make Checkout a silent no-op. A superseded
            // checkout can't reach this line: the early generation guard above bails
            // before the decision, so `.invalidName` here always names the *current*
            // repo's remote and the `errorMessage` is never for a repo the user left.
            if outcome == .invalidName {
                errorMessage = "\"\(name)\" is not a valid git branch name."
            }
            return outcome == .created
        }
    }

    /// Map any thrown error to a `GitError` for the `.fetchUnavailable` payload — a
    /// `GitError` passes through, anything else becomes a `fetchFailed` carrying its
    /// message.
    private static func gitError(from error: Error) -> GitError {
        if let gitError = error as? GitError { return gitError }
        return .fetchFailed(reason: error.localizedDescription)
    }
}
