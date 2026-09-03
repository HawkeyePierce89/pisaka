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

    /// Whether the reader wants a checkout to go ahead over an uncommitted
    /// working tree — the same warning `switchBranch` and `checkoutRemote` ask,
    /// asked for the same reason.
    ///
    /// `gh pr checkout` runs git's own checkout, so it is blocked by exactly the
    /// changes those two warn about, and a reader who is shown the warning for
    /// the branch widget's checkout and not for this one is being told the two
    /// are different operations. It is asked *before* the model composes
    /// anything, because the model raises the one-write flag at the hand-out and
    /// a refusal after that would strand it.
    ///
    /// The default agrees, which is the right answer where there is no window to
    /// put an alert on.
    private var confirmCheckout: @MainActor () -> Bool = { true }

    /// Whether the scene has wired this coordinator yet.
    ///
    /// Read by ``checkout(_:)`` alone. An unwired coordinator is a preview or a
    /// test: its `runBracket` runs nothing, and handing the model a checkout it
    /// would raise the one-write flag for and never lower is worse than doing
    /// nothing at all.
    private var isWired = false

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

    /// The branch model, held weakly and read for two things: which branch a
    /// refresh should ask GitHub about, and which local branches the create
    /// sheet's base picker offers.
    private weak var branchSwitcher: BranchSwitcherModel?

    /// The head ref of the pull request a checkout is running for, recorded at
    /// the click and read once by ``refreshAfterCheckout()``.
    private var checkedOutHeadBranch: String?

    /// The branch-change trigger (G9), and one of the feature's two
    /// subscriptions.
    ///
    /// Held here rather than in the scene for `DatabaseViewerTabs`' reason: it
    /// is state with a shape, and the scene is at its measured ceiling. Assigning
    /// a second one cancels the first, which is what makes `start(…)` idempotent
    /// for a reopened window.
    private var branchObserver: AnyCancellable?

    /// The folder-switch registration, and the second subscription. Not a
    /// trigger: it reads nothing — see `start(…)` for why a branch change alone
    /// cannot see every folder switch.
    private var rootObserver: AnyCancellable?

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

    /// Wire the six answers only the scene can give, once, from the scene, and
    /// take out the feature's two subscriptions.
    ///
    /// Idempotent and safe to call again — `.onAppear` can fire a second time for
    /// a reopened window. Five of the six are answers to standing questions and
    /// are simply overwritten; the sixth, the branch model, is subscribed to
    /// twice, and assigning over either cancellable cancels the previous
    /// subscription rather than leaving two sinks reacting to every change.
    func start(
        root: @escaping @MainActor () -> URL?,
        branchSwitcher: BranchSwitcherModel,
        isWriteBlocked: @escaping @MainActor () -> Bool,
        runCheckout: @escaping (@escaping @MainActor () async -> String?) -> Void,
        confirmCheckout: @escaping @MainActor () -> Bool,
        didWrite: @escaping @MainActor () -> Void
    ) {
        self.projectRoot = root
        self.branchSwitcher = branchSwitcher
        self.isWriteBlocked = isWriteBlocked
        self.runBracket = runCheckout
        self.confirmCheckout = confirmCheckout
        self.didWrite = didWrite
        self.isWired = true

        // The branch-change trigger. `@Published` fires *before* the property is
        // written, so the branch this feature must ask about is the one the
        // publisher hands over and never `branchSwitcher.current`, which is still
        // the branch being left — `DatabaseViewerTabs` reads its own subscription
        // the same way and for the same reason.
        //
        // `dropFirst()` drops the value that was already current when the scene
        // wired this up: that is what the widget was showing a moment ago, not a
        // change, and at launch it is the `nil` of a branch model that has not
        // read the repository yet. Everything after it is a real transition —
        // including the one *to* `nil`, a detached HEAD, which must clear the
        // indicator rather than leave it naming the branch that was left.
        branchObserver = branchSwitcher.$current
            .map { $0?.shortName }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] branch in self?.refresh(branch: branch) }

        // The folder switch, registered in its own turn — and **not** a fourth
        // trigger: it reads nothing, it only tells the model the rows it is
        // holding belong to a project that is no longer open.
        //
        // A folder switch usually arrives as a branch change, because
        // `BranchSwitcherModel.prepareForRefresh` clears `current` in
        // `openFolder`'s own turn. But `nil` is where a detached HEAD, an unborn
        // HEAD and a folder that is not a repository all already sit, so
        // switching *from* one of them clears `current` to the value it already
        // had, `removeDuplicates()` swallows it, and the sink above never fires
        // — leaving project A's rows listed, and Checkout composing `gh pr
        // checkout <A's number>`, under project B. `root` is cleared on every
        // root change and on that one alone, so it sees the switches the branch
        // cannot.
        //
        // It clears rather than refreshes because a read here would be a second
        // one for every ordinary folder switch, where the branch sink is about
        // to fire in the same turn: this feature spends a login shell and two
        // network round trips per refresh, and safety is the clear. A new
        // project whose branch never resolves (it, too, is detached) is read
        // when the panel is next shown or its refresh button pressed — with
        // nothing false on screen in the meantime.
        rootObserver = branchSwitcher.$root
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.model.prepareForRefresh() }
    }

    /// Re-read availability, the list and the current branch's pull request.
    ///
    /// The one entry point every trigger goes through, and the only place the
    /// checked-out branch is read: `gh pr list --head` wants the short name, and
    /// a detached HEAD has none, which the model already treats as "no branch to
    /// ask about" rather than as a failure.
    func refresh() {
        refresh(branch: branchSwitcher?.current?.shortName)
    }

    /// The same refresh for a branch the caller already knows — the subscription
    /// above, which is handed the branch being switched *to* while the widget
    /// still names the one being left.
    private func refresh(branch: String?) {
        // Synchronously first, then the hop — the `prepareForFolderChange` rule
        // every project-scoped model in this app follows. The branch trigger is
        // what a folder switch arrives here as (`BranchSwitcherModel
        // .prepareForRefresh` clears `current` in `openFolder`'s own turn, so
        // the sink fires there), and the previous project's rows must be gone in
        // that turn rather than one `Task` start later, while the panel is still
        // drawing them and Checkout would still run one.
        model.prepareForRefresh()
        Task { await model.refresh(branch: branch) }
    }

    /// The panel became visible.
    ///
    /// The second of the three triggers, called from `PullRequestsPanelView`'s
    /// one `.onAppear` — the panel's own view is where "the panel is on screen"
    /// is actually known, since the scene holds the selected panel in `@State`
    /// and publishes nothing this file could subscribe to. Opening the panel is
    /// the moment its contents are looked at, which is exactly when they are
    /// worth a read; nothing re-reads while it merely stays open, because that
    /// would be polling.
    func panelShown() {
        refresh()
    }

    /// The local branches the create sheet's base picker offers, in the branch
    /// widget's own order.
    ///
    /// Read from the model the widget already keeps refreshed rather than asked
    /// of git a second time: the sheet opens over the repository the widget is
    /// describing, and two lists of the same branches are two lists free to
    /// disagree.
    var localBranchNames: [String] {
        (branchSwitcher?.branches ?? []).filter { !$0.isRemote }.map(\.shortName)
    }

    /// The subject line of `HEAD`'s message, for the create sheet's pre-filled
    /// title — empty when there is no repository, no commit, or git refused.
    ///
    /// A failure is silent here and deliberately so: this is a *suggestion* for a
    /// text field the user is about to type in, and a sentence explaining why a
    /// field is empty would talk over the one slot the sheet keeps for the
    /// refusals that actually stop a pull request being opened.
    func headSubject() async -> String {
        guard let root = projectRoot() else { return "" }
        let message = try? await gitService.headMessage(root: root)
        let subject = (message ?? "")
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? ""
        return subject.trimmingCharacters(in: .whitespaces)
    }

    /// Open a pull request, through the model, and let the sheet know whether it
    /// may close.
    ///
    /// The create flow's post-operation read is the model's own tail — it
    /// re-reads the list and selects the row it just opened — so there is
    /// deliberately no second refresh here: two reads of the same list, one of
    /// them racing the other's generation token, is the shape this feature's
    /// three tokens exist to avoid.
    @discardableResult
    func create(title: String, body: String, base: String, draft: Bool) async -> Bool {
        await model.create(title: title, body: body, base: base, draft: draft)
    }

    /// The panel's Checkout button.
    ///
    /// Two refusals happen here rather than in the model, because both are
    /// answers only the scene has: an unwired coordinator has no bracket to run
    /// the operation in, and a dirty working tree is a modal alert. Everything
    /// after them is the model's — the one-write rule and the command — and the
    /// model is deliberately not asked to *accept* until both have passed, since
    /// it raises the one-write flag the moment it does.
    ///
    /// **The gate is asked before the dirty-tree prompt**, which is the order
    /// `switchBranch` and `checkoutRemote` ask in for the same reason: a refusal
    /// is then one alert rather than a confirmation the reader gives to an
    /// operation that is refused straight afterwards. The question is still the
    /// model's to answer and the sentence still the model's to publish —
    /// `checkoutIsBlocked()` is the same call `checkout(_:)` makes — so the gate
    /// keeps one site and this line only chooses *when* it is asked.
    func checkout(_ number: Int) {
        guard isWired, !model.checkoutIsBlocked(), confirmCheckout() else { return }
        // The branch the post-checkout refresh must ask about, read *before* the
        // operation runs — see `runCheckout` for why the branch widget cannot
        // answer that question at the moment it is asked.
        checkedOutHeadBranch = model.pullRequests.first { $0.number == number }?.headRefName
        model.checkout(number)
    }

    /// Re-read for the branch `gh pr checkout` just moved to.
    ///
    /// The head ref is the pull request's own — the name the pull request is
    /// open *from* on GitHub, which is what `--head` matches — rather than the
    /// local branch `gh` created for it, which for a cross-repository pull
    /// request is free to be spelled differently. Nothing recorded (a row that
    /// vanished between the click and the answer) falls back to the widget,
    /// which by then is the best reading there is.
    private func refreshAfterCheckout() {
        let branch = checkedOutHeadBranch
        checkedOutHeadBranch = nil
        if let branch, !branch.isEmpty {
            refresh(branch: branch)
        } else {
            refresh()
        }
    }

    /// End every `gh` this feature still has running, immediately.
    ///
    /// Called from the app's terminate observer beside the language servers'
    /// own, and for a sharper version of their reason: a `gh pr checkout` in
    /// flight has a `git` beneath it that is *rewriting the worktree* of a
    /// project the app is about to stop having open, and a discovery login shell
    /// is exactly the child slow enough to outlive a quit. Permanent as well as
    /// immediate, so nothing started after the observer can leave a second one.
    func terminateNow() {
        (transport as? GitHubCLIProcessTransport)?.terminateNow()
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
            // branch widget to catch up with — and nothing to re-read.
            if failure == nil {
                self?.didWrite()
                // The third trigger: the worktree is now on the pull request's
                // head, so the row that was "checkout this" is the row the
                // indicator is about to describe. The branch subscription would
                // fire for the same move once the widget's own refresh lands, but
                // that refresh is generation-pinned and asynchronous, and the
                // panel the reader is looking at may not wait on it.
                //
                // Which is exactly why the branch is the one `checkout(_:)`
                // recorded and never `branchSwitcher.current`: `didWrite()` only
                // *starts* the widget's re-read, so at this line the widget still
                // names the branch that was just left — and asking `gh pr list
                // --head` about it would spend a round trip to describe the
                // indicator with the pull request of the branch the reader left,
                // the very thing this call exists to prevent.
                self?.refreshAfterCheckout()
            }
            return failure
        }
    }
}
#endif
