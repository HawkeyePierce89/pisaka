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
/// bracket (`PisakaApp.runBranchOperation(_:_:_:)`) as `runBracket`, once, this
/// file names the event at each of its three call sites, and
/// `GitHubSourceGatingTests` pins that they are the only route.
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
///
/// **And it owns the post-merge tail's order.** A merge whose head is the
/// checked-out branch owes two more gated operations — a switch to the base and
/// a `--ff-only` pull, the app's **ninth** — and this file is where the bracket
/// is named for all three: `.pullRequest` for the checkout, `.branch` for the
/// tail's switch, `.pull` for the tail's pull. Which steps there are, in which
/// order, and what stops them is `PullRequestModel.runMergeTail(…)`'s, so the
/// rule is testable without a window; what each step *does* — the widget's two
/// checkouts, `GitServicing.pull` — is this file's, because those are the app's
/// own objects.
@MainActor
final class PullRequestCoordinator: ObservableObject {

    /// The scene's writer bracket, as this file uses it: an event to label
    /// Local History's pre-operation capture with, the operation, and a
    /// completion called on both paths.
    ///
    /// The completion is not decoration: `PisakaApp.runBranchOperation` is
    /// fire-and-forget, and the tail's pull must not start until the tail's
    /// switch has finished and been judged.
    typealias BracketRunner = @MainActor (
        LocalHistoryEvent,
        @escaping @MainActor () async -> String?,
        @escaping @MainActor (String?) -> Void
    ) -> Void

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
    /// this file exists to prevent. It answers its completion all the same, with
    /// the empty string — a failure whose sentence is nowhere, which is the only
    /// honest thing to say about an operation that never ran — so a tail handed
    /// to an unwired coordinator stops at its first step instead of pulling.
    private var runBracket: BracketRunner = { _, _, completion in completion("") }

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
        runBracket: @escaping BracketRunner,
        confirmCheckout: @escaping @MainActor () -> Bool,
        didWrite: @escaping @MainActor () -> Void
    ) {
        self.projectRoot = root
        self.branchSwitcher = branchSwitcher
        self.isWriteBlocked = isWriteBlocked
        self.runBracket = runBracket
        self.confirmCheckout = confirmCheckout
        self.didWrite = didWrite
        self.isWired = true

        // The merge a wait runs is the one merge nobody is standing in front of,
        // so its outcome has nowhere to be returned to. The tail is owed for it
        // exactly as it is for a merge run from the sheet — same decision, same
        // two bracketed steps — so both arrive here through one method.
        model.mergeWait.didMerge = { [weak self] outcome in self?.runTail(outcome) }

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
        //
        // It is also where an armed merge wait is **cancelled**, and the reason
        // is sharper than the clear's: a wait polls one pull request by number
        // in whatever root is current when its tick composes the command, and
        // half an hour of that under a repository nobody opened would end by
        // merging project A's pull request from inside project B — then switching
        // *B's* worktree to A's base branch. Cancelling is one of the wait's four
        // endings and needs no second path: `cancel()` is idempotent and silent
        // when nothing is armed.
        rootObserver = branchSwitcher.$root
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                self?.model.mergeWait.cancel()
                self?.model.prepareForRefresh()
            }
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
        // The token comes back from the clear and travels into the read, so two
        // refreshes queued by two triggers settle in the order the triggers
        // fired — unstructured tasks are not guaranteed to start in the order
        // they were created, which is the whole reason every project-scoped
        // model in this app captures its token on this side of the hop.
        let token = model.prepareForRefresh()
        Task { await model.refresh(branch: branch, token: token) }
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
    ///
    /// **The one-write flag is asked ahead of both**, which is the order
    /// `checkout(_:)` itself refuses in. Reversed, a checkout arriving while one
    /// of this feature's own writes is in flight would publish "another
    /// operation is writing to the working tree" and put up the dirty-tree
    /// modal, only for the model to refuse it silently on the flag afterwards —
    /// a sentence and a confirmation for an operation that was never going to
    /// run. The row's button is disabled on the same flag, so this is the two
    /// sites agreeing rather than a second gate.
    func checkout(_ number: Int) {
        guard isWired, !model.isWriteInFlight, !model.checkoutIsBlocked(), confirmCheckout() else { return }
        model.checkout(number)
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
        // The armed wait first, and for a reason the transport cannot cover: it
        // is not a `gh` in flight but a *sleep* between two of them, and a tick
        // waking after the observer would compose a `pr merge` — and then a
        // branch switch and a pull — against a project the app has stopped
        // having open. One of the four endings, again.
        model.mergeWait.cancel()
        (transport as? GitHubCLIProcessTransport)?.terminateNow()
    }

    /// Check out pull request `number`, through the scene's writer bracket.
    ///
    /// The model composes the command, asks the gate and hands the operation
    /// out; this is where the operation is put inside the bracket, and the only
    /// place in the app that happens.
    private func runCheckout(_ operation: @escaping @MainActor () async -> String?) {
        // The first of this file's three bracket call sites, and the only one
        // that labels its capture `.pullRequest`.
        runBracket(.pullRequest, { [weak self] in
            let failure = await operation()
            // Only a checkout that *succeeded* is re-read here. A failed one is
            // not automatically a checkout that moved nothing — `gh pr checkout`
            // is several commands and the ones after the checkout can fail on
            // their own — but that case is the bracket's to notice, not this
            // wrapper's: `runBranchOperation` re-reads the branch on its failure
            // path and publishes it, which fires the branch subscription above
            // and refreshes this feature for the move. A second trigger here
            // would spend a round trip on every ordinary failure to learn that
            // nothing changed.
            if failure == nil {
                // The third trigger, and it is the branch subscription rather
                // than a read started here: `didWrite()` re-reads the branch
                // widget, the widget publishes the branch `gh` moved to, and the
                // sink refreshes for it. One trigger, and the *local* branch is
                // the right question — `pr list --head` matches a ref by name in
                // the base repository, so a cross-repository pull request's own
                // head ref both names a branch this checkout did not create and
                // is free to match a different fork's pull request of the same
                // name. A read started here could only ask ahead of the widget
                // and be superseded by the sink a moment later, which is the
                // racing pair of reads `create` refuses for the same reason.
                self?.didWrite()
            }
            return failure
        }, { _ in })
    }

    // MARK: - The merge, and the tail it owes

    /// Merge pull request `number`, then run whatever tail it leaves behind.
    ///
    /// The sheet's Merge button, and the one place a merge run from a surface
    /// reaches the tail. Every refusal is the model's — the one-write rule, the
    /// gate, the plan re-decided from the row in hand — and each leaves its own
    /// sentence in the panel's slot, which is why nothing is asked here first:
    /// unlike the checkout, a merge puts no modal in front of anybody and has no
    /// answer only the scene can give.
    func merge(
        number: Int,
        method: GitHubMergeMethod,
        subject: String,
        body: String
    ) async {
        let outcome = await model.merge(number: number, method: method, subject: subject, body: body)
        guard let outcome else { return }
        runTail(outcome)
    }

    /// The post-merge tail: switch to the base branch, then pull it — the app's
    /// **ninth** gated operation riding the same bracket the other eight do.
    ///
    /// The decision, the order and the stop-at-first-failure rule are
    /// `PullRequestModel.runMergeTail(…)`'s, which is why they are asserted in
    /// `swift test` rather than described here. What this method supplies is the
    /// three things Core cannot have: the branch widget's list, the dirty-tree
    /// confirmation (a modal), and a runner that puts each step inside the
    /// scene's bracket under the event that step deserves.
    private func runTail(_ outcome: PullRequestModel.MergeOutcome) {
        let branches = branchSwitcher?.branches ?? []
        model.runMergeTail(
            outcome,
            branches: branches,
            confirm: { [weak self] in self?.confirmCheckout() ?? false },
            run: { [weak self] step, completion in self?.runTailStep(step, completion) ?? completion("") }
        )
    }

    /// The tail's two bracket call sites — the second and third in this file.
    ///
    /// The refresh generation is pinned **synchronously**, in this turn, before
    /// the bracket's own `Task` hop, which is `switchBranch`'s rule and its
    /// reason: a folder switch landing in the gap makes the widget's checkout
    /// bail rather than move the newly opened repository's worktree.
    ///
    /// Each step answers the bracket's own vocabulary: `nil` for success, and a
    /// message for a failure — the widget's `errorMessage` for the switch, git's
    /// own words for the pull. Neither is published into the pull request
    /// panel's slot: the merge landed, and this model's one sentence must not
    /// start saying otherwise.
    private func runTailStep(
        _ step: PullRequestModel.MergeTailStep,
        _ completion: @escaping @MainActor (String?) -> Void
    ) {
        guard let branchSwitcher, let root = projectRoot() else { return completion("") }
        let origin = branchSwitcher.currentRefreshGeneration
        switch step {
        case .switchToBase(let ref):
            runBracket(.branch, {
                let moved = ref.isRemote
                    ? await branchSwitcher.checkoutRemote(ref, originGeneration: origin)
                    : await branchSwitcher.switchTo(ref, originGeneration: origin)
                return moved ? nil : (branchSwitcher.errorMessage ?? "")
            }, completion)
        case .pullBase:
            runBracket(.pull, { [gitService] in
                do {
                    try await gitService.pull(root: root)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }, completion)
        }
    }
}
#endif
