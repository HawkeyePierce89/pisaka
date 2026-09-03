import Foundation

/// How a checkout reaches the app's writer bracket: hand the bracket an
/// operation, and it runs it with the disk writers suspended, Local History
/// captured and the open tabs resynced around it.
///
/// The operation answers `nil` for success, a sentence for a failure the app
/// should say out loud, and `""` for a failure that has already been published
/// where the reader is looking — which is the only failure this feature returns
/// (see ``PullRequestModel/performCheckout(_:)``).
///
/// **A runner must invoke the operation exactly once.** The one-write flag is
/// raised synchronously at the hand-out — so a second Checkout pressed before
/// the bracket's own `Task` has started is refused — and lowered only inside the
/// operation. A runner that accepts an operation and drops it therefore leaves
/// the flag up for the rest of the app run, with Checkout, New Pull Request and
/// refresh all disabled and no sentence saying why. A runner that cannot run one
/// must refuse *before* ``PullRequestModel/checkout(_:)`` is called, which is
/// what the coordinator's unwired guard does.
public typealias GitHubCheckoutRunner = @MainActor (@escaping @MainActor () async -> String?) -> Void

/// The reader behind both GitHub surfaces: the Pull Requests panel and the
/// bottom-bar indicator (G9).
///
/// `DatabaseViewerModel`'s shape applied to a second injected seam — a
/// `@MainActor ObservableObject` whose I/O is a protocol
/// (`GitHubCLITransport`), whose published state is only ever touched on the
/// main actor, and whose overlapping work is ordered by monotonic generation
/// tokens bumped in each method's **synchronous prefix**, the run of statements
/// before the first `await` that the main actor executes without interruption.
/// Foundation only: every argument list it sends is composed by
/// `GitHubCommands` and every answer is read by `GitHubAPI`, so nothing here
/// knows what `gh`'s output looks like and nothing here spells a `gh` flag.
///
/// **Three tokens, because there are three independently re-triggerable
/// reads.** A refresh — availability, the list, the current branch's lookup — is
/// re-asked by a branch change, by the panel becoming visible and by the refresh
/// button; the per-row checks list is re-asked by expanding a row, which the
/// reader can do faster than a large pull request answers; the create sheet's
/// own read is re-asked every time the sheet opens, while the panel behind it
/// stays live. One shared token would let a finished refresh cancel a checks
/// load that has nothing to do with it, or blank an open sheet's base picker, so
/// the three are counted apart. A superseded run publishes *nothing*: not its
/// rows, not its message, not its loading flag.
///
/// **Availability is re-probed on every refresh and never more often** (G8).
/// `gh` is the user's own binary: it can be installed, upgraded, signed in or
/// signed out from the embedded terminal a second before the panel is looked at,
/// and there is no event to subscribe to for any of that. Re-deciding the four
/// states from the two probes at the top of every refresh is what makes the
/// panel honest without a timer — and re-deciding them at any *other* moment
/// would be polling, which this feature does not do. The probes are two of the
/// three or four commands a refresh costs; the second is skipped entirely when
/// the first already decided the answer, because the version is judged before
/// the sign-in and a `gh` that is too old is too old either way.
///
/// **A failure never blanks a good list.** Every command failure and every
/// schema refusal lands in `errorMessage` and leaves `pullRequests` and `checks`
/// exactly as they were: a list that failed to refresh is still the list the
/// reader was reading, and replacing it with emptiness would destroy the only
/// context the message has. Two deliberate exceptions. The first is availability
/// going *not ready* — a `gh` that is gone, too old or signed out is not a failed
/// read but a different state of the world, in which the panel draws no rows at
/// all, so rows left standing under "sign in to GitHub" would be a lie the
/// sentence does not correct. The second is `currentBranchPullRequest`, which a
/// failed `--head` lookup **does** clear: the rule keeps a stale answer because
/// it is still this repository's, and that one value is scoped to a *branch*
/// instead — after a branch change it would go on naming the pull request of the
/// branch the user just left, in a bottom-bar indicator with no message slot to
/// qualify it. The rule is also about *one repository*: a project switch drops
/// everything before the next read starts (`prepareForRefresh()`), because
/// another repository's rows are not this one's stale answer.
///
/// **A failure is cleared by the read that caused it, and by no other.** The one
/// message slot records whose sentence it is holding (`ErrorSource`), for
/// `DatabaseViewerModel`'s reason: a refresh that succeeded says nothing about
/// an expand that failed a moment earlier, and clearing that sentence would
/// leave a row expanded over an empty checks list with no explanation.
///
/// **`pr checks` is judged on stdout parsing and never on its exit status**
/// (G3). `gh` documents exit 8 for "checks pending" and uses exit 1 for "some
/// check failed", both of which are *answers*: a model that read the status
/// would report a red pull request as a broken command. The status is consulted
/// for the other six commands and for that one it is not, which is a rule with
/// exactly one site — `loadChecks(number:root:token:)` below.
///
/// **A reader except for `create` and `checkout`.** Nothing in this file writes
/// to the *worktree*: `create` pushes the branch it is already on and opens a
/// pull request, which changes nothing on disk and therefore takes no writer
/// gate, and `checkout` — the one operation that does rewrite the worktree —
/// composes the command and hands it to the app's writer bracket rather than
/// running it here (G12). This file names no gate call at all: it *asks* one,
/// through the `isWriteBlocked` closure, exactly as `DatabaseViewerModel` does.
/// Both writes raise `isWriteInFlight`, which is the panel's one "something is
/// being written" term and the term each of them refuses on: exactly one write
/// per repository at a time.

@MainActor
public final class PullRequestModel: ObservableObject {

    // MARK: - Published state

    /// The four-state answer, or `nil` before the first refresh has decided one.
    ///
    /// Optional rather than defaulted to `.notInstalled`, because those are
    /// different claims: a panel opening on "The GitHub CLI (gh) was not found.
    /// brew install gh" before it has looked would accuse a perfectly good
    /// install of not existing for as long as the two probes take.
    @Published public private(set) var availability: GitHubAvailability?

    /// Every open pull request, in `gh`'s own order.
    @Published public private(set) var pullRequests: [GitHubPullRequest] = []

    /// The open pull request whose head is the checked-out branch, or `nil` when
    /// there is none — which is the ordinary answer for most branches, and the
    /// only answer on a detached HEAD, where there is no branch to ask about.
    ///
    /// Also `nil` when its own `--head` lookup *failed*: this is the one answer
    /// here that is scoped to a branch rather than to the repository, so it is
    /// the one the "a failure never blanks a good answer" rule cannot keep.
    @Published public private(set) var currentBranchPullRequest: GitHubPullRequest?

    /// The per-job checks of every row that has been expanded, keyed by number.
    ///
    /// Kept across refreshes for the rows that are still open — an expanded row
    /// whose jobs vanished for a moment while the list reloaded would flicker —
    /// and dropped for the rows that are not, so a closed pull request's jobs
    /// cannot be shown under a reopened one that reused nothing but the key.
    @Published public private(set) var checks: [Int: [GitHubCheckRow]] = [:]

    /// The numbers whose checks read *failed*, so the expanded row can say so
    /// instead of spinning.
    ///
    /// A third state, and the reason it is not folded into ``checks``: `nil`
    /// there means "still reading" and `[]` means "GitHub reported no jobs", and
    /// a failure is neither. Left out, a `pr checks` that threw or answered
    /// something unparseable leaves the row on a spinner that never stops —
    /// which is the very thing the two-state split was written to avoid. The
    /// sentence itself stays in the one message slot; this only says which row
    /// it belongs to. Pruned and cleared exactly like ``checks``.
    @Published public private(set) var checksFailures: Set<Int> = []

    /// The one expanded row, or `nil`. One at a time: the checks list is a
    /// per-row network read and the panel is a dock pane, not a page.
    @Published public private(set) var expandedNumber: Int?

    /// The row the panel has selected, or `nil`.
    ///
    /// Written by exactly one thing: a successful `create`, which selects the
    /// pull request it just opened so the row the reader was writing about is
    /// the row they are looking at when the sheet closes. Cleared with the rows
    /// it points into.
    @Published public private(set) var selectedNumber: Int?

    /// What `gh repo view` answered — the repository's name and, the reason the
    /// command is in scope at all, its default branch (G11).
    ///
    /// `nil` until a create sheet has opened, and `nil` again when that read
    /// failed: the create plan's `base` is this value and nothing else, so a
    /// failure here is exactly the empty picker with Create disabled that
    /// `GitHubCreatePlan` describes.
    @Published public private(set) var repository: GitHubRepository?

    /// The one message slot — `gh`'s own words for a failed command, the schema
    /// error's sentence for output that did not parse.
    @Published public private(set) var errorMessage: String?

    /// The message slot, but only when the sentence in it is the create sheet's
    /// own.
    ///
    /// The one slot is shared by four independently re-triggerable reads, which
    /// is exactly why each sentence is tagged with the read that produced it. A
    /// sheet drawing ``errorMessage`` raw would show a failed background refresh
    /// — or a checks read that failed under a row behind it — in red above its
    /// buttons, reading as though Create had been refused on a sheet where
    /// nothing has been submitted yet. `prepareCreate()` cannot clear that
    /// sentence by design: it is not the create's to clear.
    public var createMessage: String? { errorSource == .create ? errorMessage : nil }

    /// Whether a refresh is in flight. What the panel draws its spinner from.
    @Published public private(set) var isLoading = false

    /// Whether one of the feature's two writes — `create` or `pr checkout` — is
    /// running.
    ///
    /// Published here rather than in the coordinator because both surfaces
    /// disable on it: the panel greys New Pull Request, Checkout and refresh,
    /// and nothing else may start a second one. It is raised and lowered by
    /// those two flows alone, each of which also *refuses* on it, so the rule
    /// holds even when a button forgot to disable; every read path leaves it
    /// untouched.
    @Published public private(set) var isWriteInFlight = false

    // MARK: - Collaborators

    private let transport: GitHubCLITransport

    /// The repository's own git, for the one thing `gh` is not asked to do: the
    /// push that has to happen before `pr create` (G11).
    ///
    /// The existing `GitServicing`, not a second git: it already reads the
    /// commit context the refusals are decided from and already performs both
    /// `PushPlan` branches, with `GitCLIService`'s serial queues, its
    /// `GIT_TERMINAL_PROMPT=0` and its typed failures. `gh` would push too — it
    /// pushes silently as part of `pr create` — but only after prompting for a
    /// remote on a branch that has none, which is a prompt no pipe can answer,
    /// and it would make the push invisible to the sentence the sheet showed.
    private let gitService: GitServicing

    /// The repository root **as it is now**.
    ///
    /// A closure rather than a stored URL, for `DatabaseConsoleModel.fileURL`'s
    /// reason: this model outlives the folder it was created under — switching
    /// projects retargets the whole window — so the directory a command runs in
    /// is asked for at the moment the command is composed. `nil` is a project
    /// root that is not there, which is a state and not a failure.
    private let projectRoot: @MainActor () -> URL?

    /// Whether there is a project open at all, for the one question `availability
    /// == nil` cannot answer on its own.
    ///
    /// `nil` availability means "nothing has been decided yet", which covers two
    /// different worlds: no project is open, and a project is open whose first
    /// read has not run — the state the root observer leaves behind, since it
    /// clears without starting a replacement read. The panel's placeholder has to
    /// tell them apart or it accuses an open repository of not being one. Asked
    /// at draw time rather than published, exactly like ``projectRoot`` itself:
    /// this model is retargeted rather than recreated, and a stored answer would
    /// be the stale one.
    public var hasProjectRoot: Bool { projectRoot() != nil }

    /// The root everything published was read under, so a project change can be
    /// *seen* — there is no folder-change notification this file could take.
    private var lastRoot: URL?

    // MARK: - Ordering

    /// Orders refreshes against each other. Bumped in `refresh(branch:)`'s
    /// synchronous prefix, and in `prepareForRefresh()`'s when the root changed
    /// — a list read of the project that was left is not a stale answer to keep.
    private var listGeneration = 0

    /// Orders checks loads against each other. Bumped in `expand(_:)`'s
    /// synchronous prefix — including when it collapses a row, so a load whose
    /// row the reader has since closed publishes nothing.
    private var checksGeneration = 0

    /// Orders the create sheet's reads and its write against each other. Bumped
    /// in `prepareCreate()`'s and `create(...)`'s synchronous prefixes.
    ///
    /// A third token, and the reason it is not the list's: the sheet's base
    /// default is read while the panel behind it stays live, so a branch-change
    /// refresh landing in that window would supersede the sheet's own read and
    /// leave it with an empty picker and no explanation. The two reads are
    /// independently re-triggerable — a sheet can be opened, cancelled and
    /// opened again without a refresh in between — which is the same argument
    /// that separated the list's token from the checks'. Bumped in
    /// `clearRows()` too — which is what `prepareForRefresh()` and the
    /// not-ready branch of `refresh(branch:)` reach it through — because that is
    /// where the sheet's state is blanked, and a read still in flight over
    /// blanked state is exactly what a token is for.
    private var createGeneration = 0

    /// Which read put the current sentence in the one message slot.
    private var errorSource: ErrorSource?

    /// The two reads that can put a sentence in the one message slot.
    ///
    /// Two rather than one because they are independently re-triggerable and
    /// each outlives the other: a branch change refreshes the list while a
    /// checks failure is still the only explanation for an empty expanded row,
    /// and a successful refresh may not speak for it.
    private enum ErrorSource {
        case refresh
        case checks
        /// The create sheet's own read and its write. Third for the reason the
        /// second exists: a background refresh that succeeded says nothing about
        /// a `pr create` that was refused a moment ago, and clearing that
        /// sentence would close the sheet's explanation while the sheet is still
        /// open showing the fields it refused.
        case create
        /// The checkout. Fourth for the third's reason: the operation runs
        /// inside the app's writer bracket and finishes long after the panel
        /// behind it has refreshed itself, so a refresh that succeeded may not
        /// clear the one sentence explaining why the worktree did not move.
        case checkout
        /// A checkout **refused by the gate**, which is a different sentence from
        /// a checkout that ran and failed — and the one case in this enum that a
        /// successful refresh *may* speak for.
        ///
        /// The others all record something that happened and stays true: a
        /// command answered, or refused, and no later read changes what it said.
        /// This one records a *condition* — another operation is rewriting the
        /// worktree — that ends silently, with nothing in this feature told.
        /// Sharing `.checkout` left it pinned above a list that had since
        /// refreshed cleanly for the rest of the app run, telling a reader who
        /// did what the sentence asked (wait, then look again) to keep waiting.
        case checkoutBlocked
    }

    /// Whether a worktree-mutating operation is in flight right now, asked at
    /// the moment a checkout is attempted (G12).
    ///
    /// A closure rather than the gate's own API, `DatabaseViewerModel`'s reason
    /// exactly: this file may not name `autosave.suspend()` or
    /// `localChanges.beginRevert()`, and the question it actually needs
    /// answering — "is git rewriting this worktree right now?" — is one the
    /// scene can answer and Core cannot. The default answers "nothing is in the
    /// way", which is the truth in a test or a preview that has no gate.
    private let isWriteBlocked: @MainActor () -> Bool

    /// How a checkout reaches the app's writer bracket.
    ///
    /// Handed an operation to run; the app raises the gates, captures Local
    /// History and resyncs the open tabs around it, then reports the operation's
    /// answer — `nil` for success, a sentence for a failure worth an alert, and
    /// `""` for a failure this model has already published in its own message
    /// slot, which is the one this feature ever returns. The operation is handed
    /// out exactly once per accepted checkout and never for a refused one.
    ///
    /// The default runs it with **no bracket at all**, which is the honest
    /// answer where there is nothing to gate — a preview, or a test exercising
    /// the command rather than the coordination. The app never takes it: the
    /// coordinator wires the real bracket when it builds the model.
    private let runCheckout: GitHubCheckoutRunner

    /// - Parameters:
    ///   - transport: the seam. Never a `Process` — that lives in the app layer,
    ///     behind this protocol, which is what lets every rule in this file be
    ///     asserted in a target that cannot link one.
    ///   - gitService: the repository's git, for the create flow's push alone.
    ///   - root: where the repository is now.
    ///   - isWriteBlocked: whether the worktree is being rewritten right now.
    ///   - runCheckout: the app's writer bracket, as a closure.
    public init(
        transport: GitHubCLITransport,
        gitService: GitServicing,
        root: @escaping @MainActor () -> URL?,
        isWriteBlocked: @escaping @MainActor () -> Bool = { false },
        runCheckout: @escaping GitHubCheckoutRunner = { operation in
            Task { @MainActor in _ = await operation() }
        }
    ) {
        self.transport = transport
        self.gitService = gitService
        self.projectRoot = root
        self.isWriteBlocked = isWriteBlocked
        self.runCheckout = runCheckout
    }

    /// Whether pull requests can be listed at all — the only state the panel
    /// draws rows in and the indicator is visible under.
    public var isReady: Bool { availability?.isReady == true }

    // MARK: - The refresh

    /// Drop everything the *previous* project left behind, the instant the
    /// project root has changed — synchronously, before any `await`, the way
    /// every other project-scoped model's `prepareFor…` does.
    ///
    /// **The one thing "a failure never blanks a good list" does not cover.**
    /// That rule is about one repository's list: a read that failed leaves the
    /// rows the reader was reading, because they are still this repository's
    /// answer. Rows read under a *different* root are not a stale answer worth
    /// keeping — they are another repository's, with another repository's
    /// numbers — and leaving them standing after a folder switch whose own
    /// `pr list` fails (a folder that is not a repository, or has no GitHub
    /// remote, or a refused API call) would list project A's pull requests under
    /// project B, with Checkout composing `gh pr checkout <A's number>` in B.
    ///
    /// Called by the coordinator before its `Task` hop, so the previous
    /// project's rows are gone in the same main-actor turn the folder changed
    /// in, and again at the top of `refresh(branch:)`, so a model driven
    /// directly is exactly as honest as one driven through the coordinator.
    /// Idempotent: a root that has not changed costs a comparison.
    ///
    /// **Every token is bumped, not just the checks'.** Blanking what is
    /// published is only half of a folder switch: a `pr list` or a `repo view`
    /// already suspended in `await transport.run(…)` captured the *previous*
    /// root's token, and nothing between the clear and the next refresh's own
    /// prefix would stop it resuming and publishing project A's rows — or
    /// project A's default base — over the cleared state. The read that is in
    /// flight is a read of another repository, so it is superseded here, in the
    /// same turn its answer stopped being about this project. `clearRows()`
    /// bumps the checks token for its own reason; the other two are bumped
    /// beside it.
    ///
    /// **The loading flag comes down with the tokens, and unconditionally.**
    /// Bumping them supersedes whatever was in flight, and a superseded run
    /// publishes nothing — including its `isLoading = false`. The root observer
    /// calls this *without* starting a replacement read, on purpose, so the flag
    /// would otherwise stay raised for the rest of the app run: a panel spinning
    /// on "Reading…" for a command nobody sent, which is the one lie a read this
    /// quiet can still tell. No read for this project is in flight once the
    /// tokens have moved, so the honest value is `false`.
    ///
    /// It sits with the bump rather than with the clear because the two answer
    /// different questions, and the root observer is where they come apart: the
    /// folder-switch clear is right only when the rows stopped being this
    /// project's, while a superseded read leaves the flag raised whether or not
    /// the root moved. `BranchSwitcherModel.root` is cleared on a folder switch
    /// and re-set when that folder's refresh resolves, so its observer fires a
    /// *second* time — with the project root already settled, and so on the
    /// early-return path — and a read started in between (Refresh pressed, the
    /// panel shown) is superseded there by a call that starts no replacement.
    /// Lowering it costs at most one frame of a spinner that is about to come
    /// back; leaving it raised costs a spinner that never goes away.
    ///
    /// **It returns the list token, and that is the whole reason it is
    /// separable from the read.** The token is bumped here, in the caller's own
    /// turn, and handed to ``refresh(branch:token:)`` — the
    /// `CommitLogModel.prepareForRefresh(root:)` shape, and for its reason:
    /// unstructured tasks are not guaranteed to start in the order they were
    /// created, so a token captured *inside* the async read lets two refreshes
    /// queued for two different branches settle on the older one, leaving
    /// ``currentBranchPullRequest`` describing a branch nobody is on. Captured
    /// before the hop, the ordering is the order the triggers fired in.
    ///
    /// The bump is unconditional, unlike the clear: superseding whatever read is
    /// in flight is right for every refresh, while blanking the rows is right
    /// only when they stopped being this project's.
    @discardableResult
    public func prepareForRefresh() -> Int {
        let root = projectRoot()
        listGeneration &+= 1
        isLoading = false
        guard root != lastRoot else { return listGeneration }
        lastRoot = root
        availability = nil
        clearRows()
        clearMessage()
        return listGeneration
    }

    /// Re-probe availability, then re-read the list and the current branch's
    /// pull request.
    ///
    /// The whole read path, in the one order it is ever run in, and the only
    /// place availability is decided. `branch` is the checked-out branch, or
    /// `nil` on a detached HEAD — where the `--head` lookup is skipped rather
    /// than asked with an empty string, since "no branch" is not a branch whose
    /// pull requests could be listed.
    ///
    /// Three commands on a repository whose branch has no pull request, four
    /// when the panel is showing one, five when a row is expanded — its jobs are
    /// re-read with the list that carries its badge, or the two would contradict
    /// each other on screen. The version probe is always the first, so the
    /// transport re-locates `gh` exactly once per refresh (G7).
    public func refresh(branch: String?) async {
        // The clear comes *first*, and it is what hands over the token: a
        // refresh that captured one before that bump would supersede its own
        // read.
        await refresh(branch: branch, token: prepareForRefresh())
    }

    /// The same read for a token a caller already took, synchronously, before
    /// its `Task` hop — the one entry point the app layer uses (`PullRequest\
    /// Coordinator.refresh(branch:)`), so two refreshes fired by two triggers
    /// settle in the order the triggers fired rather than in the order their
    /// unstructured tasks happened to start.
    public func refresh(branch: String?, token: Int) async {
        // Superseded before it began: another trigger took a token after this
        // one and before this task started. Nothing here may publish.
        guard token == listGeneration else { return }

        guard let root = projectRoot() else {
            // No project is open, so there is no remote to resolve and nothing
            // to ask about. Not a failure and not a not-ready state: the panel
            // has no repository, which is what `availability == nil` says.
            availability = nil
            clearRows()
            clearMessage()
            isLoading = false
            return
        }

        isLoading = true

        let probe = await probeAvailability()
        guard token == listGeneration else { return }
        availability = probe.availability

        guard probe.availability.isReady else {
            // The stated exception to "a failure never blanks a good list": this
            // is a different world, not a failed read, and the panel draws the
            // state's own sentence instead of rows.
            clearRows()
            // Unconditionally, and not `clearError(from: .refresh)`: the rows a
            // checks failure or a refused create was talking about have just
            // been blanked, and a sentence about rows that are no longer drawn
            // would sit above the state's own next step contradicting it.
            clearMessage()
            if let detail = probe.detail {
                setMessage(detail, from: .refresh)
            }
            isLoading = false
            return
        }

        var failure: String?
        /// The expanded row whose jobs this refresh must re-read, set only when
        /// the list it is still open in was itself re-read.
        var expandedReload: Int?

        do {
            let result = try await transport.run(GitHubCommands.openPullRequests(root: root))
            guard token == listGeneration else { return }
            if result.isSuccess {
                let rows = try GitHubAPI.pullRequests(fromListJSON: result.standardOutput)
                pullRequests = rows
                pruneChecks(keeping: rows)
                // The row's summary badge has just been re-read from the rollup
                // this list carries, and its per-job list is read by a command
                // of its own. Left alone, the two drift apart in front of the
                // reader: the badge flips green while the jobs underneath still
                // say "pending", and Refresh — the one control there is for
                // exactly that question — appears to do nothing to the detail
                // being watched. Survives `pruneChecks`, which collapses a row
                // that closed, so a row read here is a row still open.
                expandedReload = expandedNumber
            } else {
                failure = Self.message(for: result)
            }
        } catch {
            guard token == listGeneration else { return }
            failure = Self.message(for: error)
        }

        if let branch, !branch.isEmpty {
            do {
                let command = GitHubCommands.pullRequest(forHeadBranch: branch, root: root)
                let result = try await transport.run(command)
                guard token == listGeneration else { return }
                if result.isSuccess {
                    // An empty array is the ordinary answer — most branches have
                    // no pull request — and is "no pull request", never an error.
                    currentBranchPullRequest = try GitHubAPI
                        .pullRequests(fromListJSON: result.standardOutput)
                        .first
                } else {
                    // The second exception to "a failure never blanks a good
                    // answer", and for the rule's own reason: the rule keeps a
                    // stale answer because it is still *this repository's*, and
                    // this one value is scoped to a **branch** rather than to the
                    // repository. A `--head` lookup that failed after a branch
                    // change would leave the branch the user just left asserting
                    // its pull request under the branch they are now on — the
                    // indicator drawing `#10` for a branch that has none, with no
                    // message slot of its own to qualify it, and a click opening
                    // the panel on a row the current branch never opened. The
                    // list above is repository-scoped and stands; this does not.
                    currentBranchPullRequest = nil
                    if failure == nil { failure = Self.message(for: result) }
                }
            } catch {
                guard token == listGeneration else { return }
                currentBranchPullRequest = nil
                if failure == nil { failure = Self.message(for: error) }
            }
        } else {
            // A detached HEAD has no branch a pull request could be open from.
            currentBranchPullRequest = nil
        }

        // A gate-refused checkout's sentence goes here rather than waiting for the
        // next checkout attempt. It names a condition that ends without anything
        // in this feature being told — "another operation is writing to the
        // working tree" — and `checkout(_:)` is the only other place that clears
        // it, so a reader who takes the sentence at its word and simply waits
        // would keep it above a list that has since refreshed cleanly for the
        // rest of the app run. A refresh that reached this line with the gate
        // down is the proof the condition has passed; a refresh that ran while it
        // is still up leaves the sentence standing, because it is still true.
        //
        // Scoped to `.checkoutBlocked` and never to `.checkout`: a checkout that
        // *ran* and failed said something a refresh has no standing to withdraw,
        // and its row is still on screen waiting to be understood.
        if !isWriteBlocked() { clearError(from: .checkoutBlocked) }

        if let failure {
            setMessage(failure, from: .refresh)
        } else {
            clearError(from: .refresh)
        }

        // Last, and inside the refresh rather than after it: the loading flag is
        // still up, because a read *is* still in flight, and the sentence this
        // may leave is the one about the row the reader is looking at — so it
        // speaks after the refresh's own, not under it.
        if let number = expandedReload {
            checksGeneration &+= 1
            let checksToken = checksGeneration
            // A row that failed last time is re-read from scratch, exactly as
            // `expand(_:)` does, so it may not go on saying "could not read
            // checks" for the whole of the new read.
            checksFailures.remove(number)
            await loadChecks(number: number, root: root, token: checksToken)
            guard token == listGeneration else { return }
        }

        isLoading = false
    }

    // MARK: - The expanded row

    /// Expand `number`'s checks list, or collapse whatever is open when it is
    /// `nil`.
    ///
    /// The checks token is bumped either way, collapse included: a load whose
    /// row the reader has since closed must publish nothing, or the next expand
    /// of the same row would draw jobs the previous one raced in behind it.
    public func expand(_ number: Int?) async {
        checksGeneration &+= 1
        let token = checksGeneration

        guard let number, isReady, let root = projectRoot() else {
            // Published *after* the guard, not before it: the panel draws a row
            // whose checks are neither loaded nor failed as "Reading checks…",
            // so recording an expansion the guard then refuses to read for would
            // leave that row spinning for a command nobody sent. Nothing to read
            // is nothing expanded.
            expandedNumber = nil
            return
        }
        expandedNumber = number
        // A row that failed last time is re-read from scratch, so it may not go
        // on saying "could not read checks" for the whole of the new read. The
        // cached job list is deliberately *not* dropped with it: it describes
        // the same pull request and is replaced the moment the read lands,
        // whereas blanking it would flicker every re-expand through a spinner.
        checksFailures.remove(number)
        await loadChecks(number: number, root: root, token: token)
    }

    /// Expand `number`, or collapse it when it is already the expanded row.
    public func toggleExpansion(_ number: Int) async {
        await expand(expandedNumber == number ? nil : number)
    }

    /// Read one pull request's per-job checks.
    ///
    /// **The one place in this file that does not consult an exit status** (G3):
    /// `gh pr checks` exits 8 while checks are pending and 1 when one failed,
    /// and both of those print the very JSON this parses. The decision is
    /// whether stdout parsed, and nothing else.
    ///
    /// Output that did not parse is read three ways, because three different
    /// things produce it.
    ///
    /// The first is not a failure at all. `gh pr checks` has no JSON to print
    /// for a pull request that has no checks: it exits non-zero, writes "no
    /// checks reported on the … branch" to stderr and prints nothing — the
    /// ordinary answer for a pull request without CI, which is most of them on
    /// most repositories. The row already knows: its summary is read from the
    /// same rollup `pr checks` reads, and an empty rollup is
    /// ``GitHubChecksSummary/noChecks``. So an empty stdout under a `noChecks`
    /// row publishes the **empty list** the panel has a state for, rather than
    /// accusing `gh` of failing at the one thing it was asked.
    ///
    /// The second is the same shape without that agreement: empty stdout with
    /// something on stderr under a row that *does* claim checks is `gh`
    /// declining to answer in JSON, and that sentence is `gh`'s own, so it is
    /// shown verbatim. The third is stdout that *is* there and did not parse —
    /// the schema having changed — and the typed error names the key path.
    private func loadChecks(number: Int, root: URL, token: Int) async {
        let result: GitHubCommandResult
        do {
            result = try await transport.run(GitHubCommands.checks(pullRequest: number, root: root))
        } catch {
            guard token == checksGeneration else { return }
            setMessage(Self.message(for: error), from: .checks)
            checksFailures.insert(number)
            return
        }
        guard token == checksGeneration else { return }

        do {
            checks[number] = try GitHubAPI.checkRows(fromChecksJSON: result.standardOutput)
            checksFailures.remove(number)
            clearError(from: .checks)
        } catch {
            let hasOutput = !result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if !hasOutput, summary(of: number) == .noChecks {
                checks[number] = []
                checksFailures.remove(number)
                clearError(from: .checks)
                return
            }
            if !hasOutput, !result.trimmedStandardError.isEmpty {
                setMessage(result.trimmedStandardError, from: .checks)
            } else {
                setMessage(Self.message(for: error), from: .checks)
            }
            checksFailures.insert(number)
        }
    }

    /// What the listed row said about `number`'s checks, or `nil` when no row
    /// carries that number.
    private func summary(of number: Int) -> GitHubChecksSummary? {
        pullRequests.first { $0.number == number }?.summary
    }

    // MARK: - The create sheet

    /// What the New Pull Request sheet draws its base, its sentences and its
    /// disabled Create button from — `nil` before a sheet has been prepared.
    ///
    /// One value read from both sides: the sheet disables Create on
    /// `canCreate == false` and `create(...)` refuses on the same rule, computed
    /// again from a fresh reading of the repository, so a branch checked out
    /// behind an open sheet cannot slip past a stale verdict.
    @Published public private(set) var createPlan: GitHubCreatePlan?

    /// The repository state the open sheet was planned over, kept so moving the
    /// base picker re-plans without a second git read.
    private var createContext: CommitContext?

    /// Read everything the create sheet needs, once, as it opens: the
    /// repository — for the default base, which comes from `gh repo view` and
    /// from nowhere else (G11) — and the commit context the refusals are decided
    /// from.
    ///
    /// A failed `repo view` is not a refusal: it leaves ``repository`` `nil`,
    /// hence the plan's base empty, hence Create disabled until the picker is
    /// moved to a base by hand, with `gh`'s own words in the message slot. That
    /// is the whole stated behaviour, and it needs no case of its own.
    public func prepareCreate() async {
        createGeneration &+= 1
        let token = createGeneration
        repository = nil
        createPlan = nil
        createContext = nil
        clearError(from: .create)

        guard isReady, let root = projectRoot() else { return }

        var failure: String?

        do {
            let result = try await transport.run(GitHubCommands.repositoryView(root: root))
            guard token == createGeneration else { return }
            if result.isSuccess {
                repository = try GitHubAPI.repository(fromViewJSON: result.standardOutput)
            } else {
                failure = Self.message(for: result)
            }
        } catch {
            guard token == createGeneration else { return }
            failure = Self.message(for: error)
        }

        do {
            let context = try await gitService.commitContext(root: root)
            guard token == createGeneration else { return }
            createContext = context
            createPlan = GitHubCreatePlan.plan(context: context, base: repository?.defaultBranch)
        } catch {
            guard token == createGeneration else { return }
            if failure == nil { failure = Self.message(for: error) }
        }

        if let failure { setMessage(failure, from: .create) }
    }

    /// The create sheet has gone away — drop the sentence it was drawing.
    ///
    /// A `.create` sentence is the sheet's, and only the sheet draws it as such
    /// (``createMessage`` is what `NewPullRequestSheet` reads). The panel draws
    /// the slot raw, so a create that failed and was then cancelled would leave
    /// `gh`'s refusal — or git's rejected push — pinned above the list, where
    /// nothing on the ready path clears it: every later refresh asks
    /// ``clearError(from:)`` for `.refresh` and returns early. Cleared here
    /// instead, at the one moment the sentence stops having a surface that
    /// explains it. Scoped, so a refresh failure that landed behind the open
    /// sheet is not swept away with it.
    public func dismissCreate() {
        clearError(from: .create)
    }

    /// Re-plan for the base the picker has been moved to, so the sentences name
    /// the branch that is selected rather than the one that was defaulted to.
    ///
    /// Synchronous and free: the repository state was read when the sheet
    /// opened, and only the base has changed.
    public func setCreateBase(_ base: String) {
        guard let createContext else { return }
        createPlan = GitHubCreatePlan.plan(context: createContext, base: base)
    }

    /// Push the branch, open the pull request, re-read the list and select the
    /// new row. `true` when a pull request was created.
    ///
    /// **Push first, always** (G11), on both available `PushPlan` branches:
    /// `gh pr create` compares a *remote* head against the base, so a branch that
    /// was never pushed — or was pushed three commits ago — opens a pull request
    /// missing the work it was opened for. A push that fails **never reaches**
    /// `pr create`, which is the difference between "nothing happened" and a
    /// pull request published against the wrong commits.
    ///
    /// **The one-write rule**: `isWriteInFlight` is raised for the whole flow —
    /// the push, the create and the refresh that follows — and lowered on every
    /// exit path, which is what the panel's disabled Create, Checkout and refresh
    /// buttons read, and what the checkout refuses on. A second create started
    /// while the first is in flight is refused here rather than trusted to the
    /// disabled button.
    ///
    /// The refusals are the plan's, decided from a **fresh** commit context
    /// rather than the one the sheet was drawn over: a branch switched, or a
    /// remote removed, behind an open sheet must refuse rather than push.
    ///
    /// **The head is `gh`'s to resolve, and no argument names it** — see
    /// `GitHubCommands.createPullRequest` for why one cannot: a bare `--head`
    /// names a ref in the *base* repository, and the qualified form needs an
    /// owner this layer never composes. Which makes the branch checked out at
    /// `gh`'s own launch part of the answer, and the push above is seconds of
    /// network during which the sheet is dismissable and the widget or the
    /// embedded terminal can switch branches. So the branch is **re-read after
    /// the push** and the whole create refused when it moved (or cannot be read
    /// at all) — the sheet's sentence named a branch, and a pull request opened
    /// from a different one is the failure this flow exists to prevent. The root
    /// is pinned for the same window, by being read once above and used by both
    /// commands.
    ///
    /// **The gate is asked twice**, for the window neither of those two closes.
    /// `PushPlan.push(upstream:)` is a plain `git push`, which resolves HEAD at
    /// *its own* process launch rather than from the plan — deliberately, because
    /// the tracking ref may be named differently from the local branch and a
    /// refspec composed here would be a guess. So a branch switch landing between
    /// the context read and the push makes that push publish a branch this flow
    /// never planned. The re-read after the push refuses to *open* anything on
    /// that reading — but by then the stray push has already happened, and a push
    /// is not undone by returning `false`. That is the half no check after the
    /// fact can repair, so it is refused before instead: while a branch switch, a
    /// revert, a merge apply or a project Replace All is rewriting the worktree,
    /// Create does not run.
    ///
    /// One reading would not be enough, and the second is the load-bearing one.
    /// The consult at the top only answers for rewrites already in flight; this
    /// flow then *suspends* — `commitContext` is several `git` subprocesses, and
    /// the main actor is free for all of them, which is precisely when a branch
    /// switch is started. Since none of the app's branch-change entry points
    /// consults this feature's own one-write flag (they refuse on the writer gate
    /// alone, which this flow deliberately never raises — it rewrites no file),
    /// a single consult would leave the whole context read open. So it is asked
    /// again as the last synchronous statement before the push, with no `await`
    /// between the two. What is left is the window the commit dialog's own push
    /// already names and accepts — the push's own process launch, and a
    /// `git checkout` from the embedded terminal inside it, which no gate in this
    /// app can see.
    @discardableResult
    public func create(title: String, body: String, base: String, draft: Bool) async -> Bool {
        guard !isWriteInFlight else { return false }
        guard !isWriteBlocked() else {
            setMessage(Self.createBlockedMessage, from: .create)
            return false
        }

        // Bumped, and deliberately never checked: a write is finished, not
        // superseded. The bump exists so a sheet read still in flight cannot
        // publish a plan over the one this flow just decided from fresher state.
        createGeneration &+= 1

        guard isReady, let root = projectRoot() else {
            // Said, rather than returned in silence: this refusal is reachable
            // from a sheet that is still on screen with its fields intact — `gh`
            // signed out, or the project closed, while it stood open — and every
            // other exit from this method leaves a sentence behind.
            setMessage(Self.unavailableMessage, from: .create)
            return false
        }

        isWriteInFlight = true
        defer { isWriteInFlight = false }
        clearError(from: .create)

        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            setMessage(Self.untitledMessage, from: .create)
            return false
        }

        let context: CommitContext
        do {
            context = try await gitService.commitContext(root: root)
        } catch {
            setMessage(Self.message(for: error), from: .create)
            return false
        }

        let plan = GitHubCreatePlan.plan(context: context, base: base)
        createContext = context
        createPlan = plan

        guard plan.canCreate else {
            // A refusal has a sentence; an empty base has none by design — the
            // `repo view` failure that produced it already put `gh`'s words in
            // the slot, and a second sentence would talk over them.
            if let refusal = plan.refusal { setMessage(refusal.message, from: .create) }
            return false
        }

        // The gate again, and this is the reading that matters: the one at the
        // top catches a rewrite that was already running, this one catches the
        // one that *started while this flow was suspended*. `commitContext` is
        // several `git` subprocesses long, and the main actor is free for every
        // one of them — which is exactly when a branch switch is initiated. It
        // is read here rather than only there because the branch a plain
        // `git push` publishes is decided at the push's own process launch, so
        // the last synchronous moment before that launch is the last moment this
        // question has an answer worth having. Nothing awaits between here and
        // the push, which is what makes it that moment.
        guard !isWriteBlocked() else {
            setMessage(Self.createBlockedMessage, from: .create)
            return false
        }

        do {
            try await gitService.push(plan.push, root: root)
        } catch {
            setMessage(Self.message(for: error), from: .create)
            return false
        }

        // The head is `gh`'s to resolve — see `GitHubCommands.createPullRequest`
        // for why an argument cannot name it: a bare `--head` names a ref in the
        // *base* repository, and the qualified `<user>:<branch>` form needs an
        // owner this layer never composes and that `gh` rejects for an
        // organization anyway. So `gh` reads the checked-out branch's tracking
        // configuration, which is the one place a fork's head is known.
        //
        // Which makes the branch that is checked out *at `gh`'s launch* part of
        // the answer, and the push above is exactly where that can change: it is
        // seconds of network during which the sheet is dismissable and the widget
        // or the embedded terminal can switch branches. So it is re-read here and
        // the whole create is refused when it moved — the sheet's sentence named
        // a branch, and a pull request opened from a different one is the failure
        // this flow exists to prevent, not something to publish and report after
        // the fact. A `nil` reading (a detached HEAD, or `git` failing) is a
        // refusal for the same reason: it is not the branch that was stated.
        //
        // Note this closes the *stated* window and no more. The push's own
        // process launch, and a `git checkout` racing inside it, remain what the
        // commit dialog's push already names and accepts.
        let branchAfterPush: BranchRef?
        do {
            branchAfterPush = try await gitService.currentBranch(root: root)
        } catch {
            setMessage(Self.message(for: error), from: .create)
            return false
        }

        guard branchAfterPush?.shortName == plan.headBranch else {
            setMessage(Self.branchMovedMessage, from: .create)
            return false
        }

        let command = GitHubCommands.createPullRequest(
            title: title,
            body: body,
            base: plan.base,
            draft: draft,
            root: root
        )
        let result: GitHubCommandResult
        do {
            result = try await transport.run(command)
        } catch {
            setMessage(Self.message(for: error), from: .create)
            return false
        }

        guard result.isSuccess else {
            setMessage(Self.message(for: result), from: .create)
            return false
        }

        // The pull request exists from here on, so nothing below may report a
        // failure: an unreadable number costs the selection and nothing else.
        let number = GitHubAPI.pullRequestNumber(fromCreateOutput: result.standardOutput)
        await refresh(branch: context.currentBranch)
        selectedNumber = number
        return true
    }

    /// What a create refused for want of a title says.
    ///
    /// Here rather than in the sheet for the reason every other refusal is here:
    /// the sheet disables Create on the same rule, and a rule that lives only in
    /// a view is a rule no test can see and a second caller can walk past.
    public static let untitledMessage = "A pull request needs a title."

    /// What a create refused because `gh` stopped being ready — or the project
    /// closed — behind the open sheet says.
    ///
    /// Every other exit from `create(...)` puts a sentence in the one message
    /// slot, and this one used to be the exception: a reader whose `gh` was
    /// signed out while the sheet stood open pressed Create and got nothing at
    /// all — no dismissal, no message, no spinner. Its own constant rather than
    /// the availability state's sentence, which the *panel* is already drawing
    /// behind the sheet: the question this one answers is why the **button** did
    /// nothing, and the next step belongs to the state that owns it.
    public static let unavailableMessage =
        "Pull requests are no longer available for this project. "
        + "Close this sheet and refresh the Pull Requests panel."

    /// The sentence a create refused because git is already rewriting the
    /// worktree gets.
    ///
    /// Its own constant rather than ``blockedMessage``, for the reason that one
    /// is its own constant: both name the operation the reader is being told to
    /// try again, and a create is not a checkout. The first half is deliberately
    /// word-for-word the checkout's — it describes the same state of the same
    /// repository, and two wordings for one state read as two different
    /// problems.
    public static let createBlockedMessage =
        "Another operation is writing to the working tree. "
        + "Create the pull request again when it has finished."

    /// The sentence a create refused because the checked-out branch moved while
    /// the branch was being pushed gets.
    ///
    /// The refusal exists because the head is `gh`'s to resolve, and `gh`
    /// resolves it from the branch that is checked out at *its own* launch —
    /// which the push, seconds of network with the sheet dismissable behind it,
    /// is exactly long enough to change. It says the pull request was not opened
    /// because that is the one thing the reader needs: the push already
    /// happened, and it is the only part of this flow that did.
    public static let branchMovedMessage =
        "The checked-out branch changed while the branch was being pushed. "
        + "No pull request was opened — reopen this sheet to create one from the branch you are on."

    // MARK: - The checkout

    /// The sentence a checkout refused because git is already rewriting the
    /// worktree gets.
    ///
    /// This layer's own words rather than `gh`'s, because `gh` was never asked:
    /// the refusal happens before anything is sent, which is the whole point of
    /// asking the gate first.
    public static let blockedMessage =
        "Another operation is writing to the working tree. Try the checkout again when it has finished."

    /// The gate, asked on its own, publishing its sentence when it refuses.
    /// `true` when a checkout may **not** run.
    ///
    /// Public so the caller may ask it *before* whatever it puts in front of the
    /// operation — the panel's Checkout puts a dirty-tree confirmation there —
    /// which is the order `switchBranch` and `checkoutRemote` already ask in:
    /// a refusal is then one alert rather than a confirmation followed by one.
    /// ``checkout(_:)`` asks this same method, so the refusal keeps a single
    /// site whether or not the caller asked first, and asking twice is free —
    /// the gate is a synchronous predicate and the sentence it sets is the same
    /// one both times.
    @discardableResult
    public func checkoutIsBlocked() -> Bool {
        guard isWriteBlocked() else { return false }
        setMessage(Self.blockedMessage, from: .checkoutBlocked)
        return true
    }

    /// Check out pull request `number` into the worktree — the feature's one
    /// worktree write, and the app's **eighth** gated operation (G12).
    ///
    /// Nothing is sent from here. The command is composed, and then handed to
    /// the app's writer bracket through ``runCheckout``, which is what makes
    /// "capture Local History first, then move the worktree, then resync the
    /// open tabs" the app's order rather than a promise this file makes. The
    /// hand-out happens **exactly once** for an accepted checkout and **not at
    /// all** for a refused one, which is what a refusal has to mean for an
    /// operation nobody can take back.
    ///
    /// The three refusals, in the order they are asked:
    ///
    ///  1. a write of this feature's own is already in flight — the one-write
    ///     rule `create` refuses on too, read from the same flag;
    ///  2. **the gate**, asked before anything is composed: a checkout landing
    ///     in the middle of a revert, a merge apply or a branch switch would
    ///     move the worktree out from under an operation already snapshotting
    ///     it;
    ///  3. `gh` is not ready, or there is no project root, which are the same
    ///     two states every other command refuses on.
    ///
    /// Synchronous, and deliberately: it is called from a button, its answer is
    /// "was this accepted", and everything after the hand-out belongs to the
    /// bracket. `true` when the operation was handed out.
    @discardableResult
    public func checkout(_ number: Int) -> Bool {
        guard !isWriteInFlight else { return false }
        guard !checkoutIsBlocked() else { return false }
        guard isReady, let root = projectRoot() else { return false }

        isWriteInFlight = true
        clearError(from: .checkout)
        clearError(from: .checkoutBlocked)
        let command = GitHubCommands.checkoutPullRequest(number: number, root: root)
        runCheckout { [weak self] in
            // Spelled out rather than `self?.performCheckout(command) ?? …`: an
            // optional chain over a method that already answers `String?`
            // flattens the two cases into one, and they mean opposite things
            // here. A deallocated model is a checkout that **never ran**, and
            // `nil` is this runner's *success* value — the bracket would resync
            // the open tabs, bump the tree revision and re-read Local Changes
            // and the Log for a `gh pr checkout` nobody sent. `""` is already
            // this feature's "it failed and the sentence is elsewhere" answer,
            // so nothing spurious is presented either.
            guard let self else { return "" }
            return await self.performCheckout(command)
        }
        return true
    }

    /// Run the composed checkout inside whatever bracket was handed it.
    ///
    /// The write flag is lowered on every exit path, including the two failures
    /// — the panel's Checkout, New Pull Request and refresh buttons all read it,
    /// and a flag left up by a failed checkout would disable the feature for the
    /// rest of the app run.
    ///
    /// A failure is published here, in this model's one message slot, and
    /// reported to the bracket as `""`: the panel the reader just clicked
    /// Checkout in is on screen showing `gh`'s own words, and a modal saying the
    /// same thing a second time is not a second piece of information.
    private func performCheckout(_ command: GitHubCommand) async -> String? {
        defer { isWriteInFlight = false }
        do {
            let result = try await transport.run(command)
            guard result.isSuccess else {
                setMessage(Self.message(for: result), from: .checkout)
                return ""
            }
            return nil
        } catch {
            setMessage(Self.message(for: error), from: .checkout)
            return ""
        }
    }

    // MARK: - Availability

    /// What the two probes decided, and the detail sentence — if any — that the
    /// four states cannot carry themselves.
    private struct AvailabilityProbe {
        let availability: GitHubAvailability
        /// A transport failure's own words: the difference between "there is no
        /// `gh`" and "the `gh` that is there did not answer in fifteen seconds",
        /// which the four states deliberately do not model and the reader needs.
        let detail: String?
    }

    /// Run `gh --version` and, when that answered something new enough, `gh auth
    /// status`, then decide.
    ///
    /// Publishes nothing: it is called before the caller's token check, so every
    /// answer travels back as a value and the caller decides whether it is still
    /// wanted.
    ///
    /// `auth status` is skipped whenever the version already settled the answer,
    /// which is what makes the not-installed and too-old refreshes one command
    /// rather than two. Its *exit status* is the whole reading — that command
    /// writes its prose to stderr in a shape that has changed between releases,
    /// and the status has not.
    private func probeAvailability() async -> AvailabilityProbe {
        var detail: String?
        let probe: GitHubVersionProbe

        do {
            let result = try await transport.run(GitHubCommands.version())
            if result.isSuccess, let version = GitHubVersion.parse(result.standardOutput) {
                probe = .version(version)
            } else {
                probe = .unreadable
                if !result.isSuccess, !result.trimmedStandardError.isEmpty {
                    detail = result.trimmedStandardError
                }
            }
        } catch GitHubCLIError.notInstalled {
            // The expected answer on a Mac without `gh`, and the one the state's
            // own sentence already says in full. Adding a second sentence saying
            // the same thing would be noise on the commonest not-ready panel.
            probe = .unavailable
        } catch {
            probe = .unavailable
            detail = Self.message(for: error)
        }

        var isSignedIn = false
        if case .version(let found) = probe, found >= GitHubVersion.minimum {
            do {
                isSignedIn = try await transport.run(GitHubCommands.authStatus()).isSuccess
            } catch {
                // A probe that could not run is not a sign-in: the safe reading
                // is "not signed in", with the reason shown beside it so the
                // reader is not sent to `gh auth login` for a timeout.
                isSignedIn = false
                detail = Self.message(for: error)
            }
        }

        return AvailabilityProbe(
            availability: GitHubAvailability.decide(version: probe, isSignedIn: isSignedIn),
            detail: detail
        )
    }

    // MARK: - The one message slot

    private func setMessage(_ message: String, from source: ErrorSource) {
        errorMessage = message
        errorSource = source
    }

    /// Drop whatever the one slot holds, whoever put it there — for the two
    /// moments the model blanks everything a sentence could refer to.
    private func clearMessage() {
        errorMessage = nil
        errorSource = nil
    }

    /// Clear the message only when it is `source`'s own — see `ErrorSource` for
    /// why a refresh may not speak for an expand.
    private func clearError(from source: ErrorSource) {
        guard errorSource == source else { return }
        errorMessage = nil
        errorSource = nil
    }

    // MARK: - Rows

    /// Everything a not-ready state has no business showing.
    private func clearRows() {
        // The checks token goes with them, for `expand(_:)`'s reason read the
        // other way round: a load in flight for a row that has just been blanked
        // must publish nothing — not its jobs, and above all not its sentence,
        // which would land in the one message slot the caller clears on the very
        // next line and sit there talking about rows nobody is drawing.
        checksGeneration &+= 1
        // And the create token, for the same reason applied to the sheet's read:
        // this method blanks the create state a few lines down, and a
        // `prepareCreate()` suspended in `repo view` or in the commit context
        // would otherwise resume against an unmoved token and re-publish a plan
        // over what was just blanked — a sheet whose Create button is enabled
        // again over a `create` that now refuses. This is the *only* site that
        // bumps it outside `prepareCreate()` and `create(...)`, which is why it
        // lives beside the assignments it protects rather than at either caller.
        createGeneration &+= 1
        pullRequests = []
        currentBranchPullRequest = nil
        checks = [:]
        checksFailures = []
        expandedNumber = nil
        selectedNumber = nil
        // The create sheet's state goes with them. It is read from both sides —
        // the sheet disables Create on `createPlan?.canCreate` and `create(...)`
        // refuses on the same rule — and a plan left standing after `gh` stopped
        // being ready is a sheet whose Create button is enabled over a `create`
        // that now returns at its own readiness guard without a word.
        repository = nil
        createPlan = nil
        createContext = nil
    }

    /// Drop the cached checks of pull requests that are no longer open, and
    /// collapse — and deselect — the row when it was one of them.
    private func pruneChecks(keeping rows: [GitHubPullRequest]) {
        let open = Set(rows.map(\.number))
        checks = checks.filter { open.contains($0.key) }
        checksFailures = checksFailures.intersection(open)
        if let expandedNumber, !open.contains(expandedNumber) {
            // Collapsing is the same statement `expand(nil)` makes, so it carries
            // the same token bump: the read the row was closed on may not land
            // afterwards and re-fill the entry this line has just pruned.
            checksGeneration &+= 1
            self.expandedNumber = nil
        }
        if let selectedNumber, !open.contains(selectedNumber) { self.selectedNumber = nil }
    }

    // MARK: - Sentences

    /// What a *failed command* says: `gh`'s own words when it wrote any, a
    /// stated fallback when it exited non-zero in silence.
    ///
    /// Never a paraphrase. `gh`'s messages name the repository, the host and the
    /// scope that is missing, none of which this app knows.
    private static func message(for result: GitHubCommandResult) -> String {
        let stderr = result.trimmedStandardError
        if !stderr.isEmpty { return stderr }
        return "The GitHub CLI exited with status \(result.status)."
    }

    /// What a *thrown* error says — the transport's three failures and the
    /// schema's three, each of which already carries its own sentence.
    private static func message(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}
