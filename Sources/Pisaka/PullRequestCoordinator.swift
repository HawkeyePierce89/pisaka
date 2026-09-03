#if os(macOS)
import Combine
import Foundation
import PisakaCore

/// Who owns the Pull Requests feature, and where its one write reaches the app.
///
/// `DatabaseViewerTabs`' arrangement applied to a second injected seam: the
/// model and its transport live here rather than in the scene, the scene wires
/// the answers it alone can give exactly once through `start(…)`, and no file
/// under this feature names a gate call. `PisakaApp.swift` sits at its measured
/// `file_length` ceiling with `type_body_length` one behind it, and this feature
/// is state with a shape rather than scene wiring, so it lands in a file of its
/// own and the scene gains a `@StateObject`, a `start(…)` block and a menu item.
///
/// **The one checkout site.** `gh pr checkout` rewrites the worktree, which
/// makes it the app's eighth gated operation (G12) — and every one of the other
/// seven raises `autosave.suspend()` + `localChanges.beginRevert()`
/// synchronously, snapshots the open tabs, captures Local History as its first
/// `await` and resyncs the tabs afterwards. None of that is expressible in Core,
/// and none of it may be re-implemented here: the scene hands over its own
/// bracket (`PisakaApp.runBranchOperation(_:_:)`) as `runCheckout`, this file
/// passes it straight into the model, and `GitHubSourceGatingTests` pins that it
/// is the only route.
///
/// **The gate is asked, never taken.** The feature is a reader in every other
/// respect — listing pull requests and reading checks neither suspends the disk
/// writers nor waits on them, exactly like the symbol index — but a *checkout*
/// landing in the middle of a revert or a merge apply would move the worktree
/// out from under an operation already snapshotting it. So the question travels
/// as a closure, wired in the scene alone to `LocalChangesModel.isReverting`,
/// and this file names neither `autosave` nor `localChanges`.
///
/// **It owns the feature's refresh triggers**, which is why the branch model is
/// held here: a refresh needs to know which branch to ask about, and after a
/// checkout the branch has changed behind the widget's back — nothing else in
/// the app would tell it.
@MainActor
final class PullRequestCoordinator: ObservableObject {

    /// The one model, built once and observed by all three surfaces.
    ///
    /// `lazy` because its four closures read back through `self`: the project
    /// root, the gate and the bracket are all answers the scene supplies after
    /// this object exists, and a model built with today's values would be stuck
    /// with the defaults the whole app run — `DatabaseViewerTabs`' reason for
    /// reading its two hooks through `self` rather than capturing them.
    private(set) lazy var model = PullRequestModel(
        transport: transport,
        gitService: gitService,
        root: { [weak self] in self?.projectRoot() },
        isWriteBlocked: { [weak self] in self?.isWriteBlocked() ?? false },
        runCheckout: { [weak self] operation in self?.runCheckout(operation) }
    )

    private let transport: GitHubCLITransport
    private let gitService: GitServicing

    /// Where the repository is *now* — a closure for the model's own reason: the
    /// window is retargeted by a folder switch, and the root a command runs in is
    /// the one that is current when the command is composed.
    private var projectRoot: @MainActor () -> URL? = { nil }

    /// Whether a worktree-mutating operation is in flight, forwarded verbatim.
    private var isWriteBlocked: @MainActor () -> Bool = { false }

    /// The scene's writer bracket. The default runs nothing at all rather than
    /// running a checkout ungated: a coordinator the scene has not wired is a
    /// preview or a test, and an unbracketed worktree rewrite is the one thing
    /// this file exists to prevent.
    private var runBracket: (@escaping @MainActor () async -> String?) -> Void = { _ in }

    /// What the scene runs after the feature's write has landed — the branch
    /// widget's generation-pinned refresh.
    ///
    /// It is genuinely the scene's and not the bracket's: the bracket's own tail
    /// resyncs the open tabs and refreshes the tree, Local Changes and Log, but
    /// **not** the branch widget, because the seven operations that came before
    /// this one all move the branch through `BranchSwitcherModel` itself and
    /// leave it already correct. `gh pr checkout` moves it from outside, so
    /// without this the widget would go on naming the branch the reader left.
    private var didWrite: @MainActor () -> Void = {}

    /// The branch model, held weakly and read for one thing: which branch a
    /// refresh should ask GitHub about.
    private weak var branchSwitcher: BranchSwitcherModel?

    /// - Parameters:
    ///   - transport: how `gh` is run. The app always passes the real one; a
    ///     test or a preview can pass anything that answers the protocol.
    ///   - gitService: the repository's git, for the create flow's push.
    init(
        transport: GitHubCLITransport = GitHubCLIProcessTransport(),
        gitService: GitServicing = GitCLIService()
    ) {
        self.transport = transport
        self.gitService = gitService
    }

    /// Wire the four answers only the scene can give, once, from the scene.
    ///
    /// Idempotent and safe to call again — `.onAppear` can fire a second time for
    /// a reopened window, and every one of these is an answer to a standing
    /// question rather than a subscription.
    func start(
        root: @escaping @MainActor () -> URL?,
        branchSwitcher: BranchSwitcherModel,
        isWriteBlocked: @escaping @MainActor () -> Bool,
        runCheckout: @escaping (@escaping @MainActor () async -> String?) -> Void,
        didWrite: @escaping @MainActor () -> Void
    ) {
        self.projectRoot = root
        self.branchSwitcher = branchSwitcher
        self.isWriteBlocked = isWriteBlocked
        self.runBracket = runCheckout
        self.didWrite = didWrite
    }

    /// Re-read availability, the list and the current branch's pull request.
    ///
    /// The one entry point every trigger goes through, and the only place the
    /// checked-out branch is read: `gh pr list --head` wants the short name, and
    /// a detached HEAD has none, which the model already treats as "no branch to
    /// ask about" rather than as a failure.
    func refresh() {
        let branch = branchSwitcher?.current?.shortName
        Task { await model.refresh(branch: branch) }
    }

    /// Check out pull request `number`, through the scene's writer bracket.
    ///
    /// The model composes the command, asks the gate and hands the operation
    /// out; this is where the operation is put inside the bracket, and the only
    /// place in the app that happens.
    private func runCheckout(_ operation: @escaping @MainActor () async -> String?) {
        runBracket { [weak self] in
            let failure = await operation()
            // A checkout that failed moved nothing, so there is nothing for the
            // branch widget to catch up with.
            if failure == nil { self?.didWrite() }
            return failure
        }
    }
}
#endif
