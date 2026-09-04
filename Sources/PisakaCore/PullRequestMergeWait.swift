import Foundation

/// How an armed wait ended — the whole table, and deliberately a closed one.
///
/// A wait is a promise the app makes on its own ("I will merge this when the
/// checks go green"), so the one thing it may never do is stop without saying
/// so. Four cases, each of which is reached from exactly one place in
/// ``PullRequestMergeWait``'s loop:
public enum PullRequestMergeWaitEnding: Equatable, Sendable {

    /// The plan said yes on some tick and the merge was handed to
    /// ``PullRequestModel/merge(row:method:subject:body:)``.
    ///
    /// Carries what that write answered — `nil` when the model *refused* it (a
    /// second write in flight, the gate up) or `gh` failed it, whose sentence is
    /// already in the model's own message slot under
    /// ``PullRequestModel/mergeMessage``. The wait ends either way, on purpose:
    /// its job is to decide **when** the merge is attempted, and re-arming
    /// itself around a refusal it did not make would turn a bounded wait into an
    /// unbounded retry loop against a state it cannot see.
    case merged(PullRequestModel.MergeOutcome?)

    /// A tick answered something waiting cannot change, and the wait stopped
    /// with that state's own sentence: a failing check, a refusal
    /// ``GitHubMergeRefusal/mayResolveByWaiting`` says no later tick can leave,
    /// a pull request that is no longer open, or a read that could not be made
    /// at all (in `gh`'s own words).
    case stopped(String)

    /// ``PullRequestMergeWait/deadline`` passed with the answer still "checks
    /// are running".
    case deadline

    /// Cancel, a project switch, quit, or another wait armed over this one.
    case cancelled

    /// What the surface says about this ending — `nil` for the two that speak
    /// for themselves.
    ///
    /// A merge has the whole panel to show for itself (the row leaves the list),
    /// and a cancellation is something the reader just did.
    public var message: String? {
        switch self {
        case .merged, .cancelled: return nil
        case .stopped(let sentence): return sentence
        case .deadline: return PullRequestMergeWait.deadlineMessage
        }
    }
}

/// *Merge when checks pass*: a bounded, visible, cancelable wait that re-reads
/// **one pull request row** every ``pollInterval`` seconds for at most
/// ``deadline`` seconds and merges the moment the same rule the Merge button is
/// drawn from says it may (G14).
///
/// **This is the feature's one deliberate exception to the no-polling ban**, and
/// it is scoped by construction rather than by promise: the interval and the
/// deadline are named constants, the wait between ticks is exactly one
/// injectable seam, there is no `Timer` and no `asyncAfter` anywhere in it, and
/// nothing arms it but an explicit press on a button whose label says what it
/// will do. Every other read in this feature stays event-driven.
///
/// **One rule, one table.** A tick runs `gh pr view <n>`, parses the row through
/// `GitHubAPI.pullRequest(fromViewJSON:)` and hands it to ``GitHubMergePlan`` —
/// the same value the button was drawn from. It never runs `pr checks`: that
/// command answers about *jobs* and cannot see `mergeable` or
/// `mergeStateStatus`, so checks can turn green while GitHub still answers
/// `BLOCKED`, `BEHIND` or `UNKNOWN`, and a wait deciding "green" from the jobs
/// table would hand a merge to a plan that refuses it.
///
/// `LeetCodeJudgeModel`'s shape (L18) applied to a second polled answer, and for
/// its reasons: a companion `@MainActor` model owned by ``PullRequestModel``,
/// with a `weak` reference back for the transport and the write (`weak` and not
/// `unowned` — see ``owner``), its own
/// generation token checked after **every** suspension, a `now` clock and a
/// `sleep` seam — so the whole state machine, deadline included, runs
/// deterministically in `swift test` and adds no wall-clock time to it.
///
/// It raises no gate and takes none: the polls are reads, and the one write it
/// reaches is the model's own `merge`, which asks the gate and raises
/// ``PullRequestModel/isWriteInFlight`` exactly as a merge from the sheet does.
@MainActor
public final class PullRequestMergeWait: ObservableObject {

    // MARK: - The two numbers

    /// How long the wait sleeps between reads of the row.
    ///
    /// Thirty seconds, and a named constant so the one place it is spent is the
    /// one place it is stated. A check run that finishes in under half a minute
    /// did not need a wait, and a shorter interval buys nothing but API calls:
    /// the whole point of the feature is to *stop watching*, so the cost of
    /// being up to 30 s late is nothing anybody is sitting in front of.
    public nonisolated static let pollInterval: TimeInterval = 30

    /// How long a wait may run before it gives up.
    ///
    /// Thirty minutes, measured against ``now`` rather than counted in ticks —
    /// `LeetCodeJudgeModel`'s budget rule, for its reason: a network that slows
    /// down must not silently double the wait the reader was promised. A suite
    /// of checks that has not finished in half an hour is a suite something is
    /// wrong with, and the ending says so rather than merging on it.
    public nonisolated static let deadline: TimeInterval = 30 * 60

    /// What the deadline ending says.
    ///
    /// It names the number of minutes out of ``deadline`` rather than spelling
    /// "30" a second time, so the sentence cannot drift from the constant it is
    /// about.
    public nonisolated static let deadlineMessage =
        "Checks did not finish within \(Int(deadline / 60)) minutes, so nothing was merged. "
        + "Merge this pull request when they do."

    /// What a tick that found the pull request no longer open says.
    ///
    /// The wait's own sentence rather than the plan's: this is not a refusal to
    /// merge, it is the row leaving from under the wait — which is what somebody
    /// else merging or closing it looks like from here, and the honest ending
    /// for it is a stop, not a merge attempt `gh` would refuse.
    public nonisolated static let noLongerOpenMessage =
        "This pull request is no longer open — it was merged or closed on GitHub while the wait was running."

    /// What a tick that found the world the wait was armed in gone says.
    ///
    /// Its own sentence rather than ``PullRequestModel/mergeRowMissingMessage``,
    /// which is the one this stop used to borrow. That sentence ends "Close this
    /// sheet and refresh the Pull Requests panel", and it is right where it is
    /// said — under an open merge sheet — but this ending is drawn in the
    /// *panel's* ending strip, and a wait runs precisely when nobody is standing
    /// in front of a sheet. Naming a control the reader cannot see is the one
    /// thing an ending nobody witnessed may not do.
    ///
    /// It names the state rather than guessing which of its three causes ran:
    /// `gh` stopped being ready, the project was closed or switched, or the rows
    /// — and with them the repository the plan is decided against — were blanked.
    public nonisolated static let stateLostMessage =
        "The wait stopped because this pull request could no longer be read — GitHub CLI is no longer "
        + "available, or this project changed while the wait was running. Nothing was merged."

    // MARK: - Published state

    /// What is armed, or `nil` when nothing is.
    ///
    /// **One wait per repository**, which is a property of there being one of
    /// these per model rather than a rule somebody has to enforce: ``arm(plan:method:subject:body:)``
    /// cancels whatever it finds here before it replaces it.
    @Published public private(set) var armed: Armed?

    /// How long the armed wait has been running, in seconds, re-published at the
    /// top of every tick.
    ///
    /// Published from ``now`` here so **no view runs a clock**: a `TimelineView`
    /// in the row would be a second source of "how long has this been going",
    /// ticking on its own schedule and disagreeing with the deadline this model
    /// is actually measuring.
    @Published public private(set) var elapsed: TimeInterval = 0

    /// How the last wait ended — `nil` before one has, and cleared when the next
    /// is armed.
    @Published public private(set) var ending: PullRequestMergeWaitEnding?

    /// What a wait was armed with: the row it is about, and the merge it will
    /// send when the row goes green.
    ///
    /// The number, and then exactly what the merge needs. It deliberately does
    /// **not** carry the row's title or the head the arm was made against: the
    /// panel draws its own row's title, and the merge is guarded by the head
    /// **this tick** read (see ``PullRequestMergeWait``'s note on the head
    /// guard), so a carried head would be a value with one reading and no
    /// reader.
    public struct Armed: Equatable, Sendable {
        public let number: Int
        public let method: GitHubMergeMethod
        public let subject: String
        public let body: String

        public init(number: Int, method: GitHubMergeMethod, subject: String, body: String) {
            self.number = number
            self.method = method
            self.subject = subject
            self.body = body
        }
    }

    // MARK: - Seams

    /// The clock the deadline and ``elapsed`` are measured against.
    public var now: () -> Date = Date.init

    /// The wait between ticks, as **exactly one seam**.
    ///
    /// Injectable so the whole state machine — including the deadline, which is
    /// sixty sleeps deep — runs deterministically in `swift test`. The default
    /// swallows the cancellation error rather than propagating it: the loop's
    /// generation check is the one place a cancelled wait is handled, so there
    /// is one rule for it.
    public var sleep: (TimeInterval) async -> Void = { seconds in
        guard seconds > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// What a merge the *wait* ran hands its outcome to.
    ///
    /// A seam rather than a published value, for ``PullRequestModel/MergeOutcome``'s
    /// own reason: the outcome is the answer to one merge, read once by the
    /// coordinator that owns the post-merge tail, and a published copy would sit
    /// there naming a base branch and a head that no longer exist. A merge run
    /// from the sheet returns its outcome to its caller; this is the same answer
    /// for the one merge nobody was standing in front of.
    public var didMerge: @MainActor (PullRequestModel.MergeOutcome) -> Void = { _ in }

    // MARK: - Private state

    /// The model this wait runs its commands and its merge through.
    ///
    /// **`weak`, not `unowned`, and the difference is a crash.** The running
    /// `Task` captures the *wait* weakly, but a tick already inside
    /// ``run(_:token:)`` holds it strongly for the whole call — so a wait
    /// suspended in a sleep outlives the model that owns it the moment the
    /// scene's `@StateObject` goes away, which a closed window does and which
    /// neither of the two cancellations covers (quit and a project switch both
    /// cancel first). An `unowned` reference resumed into that world is a
    /// dangling pointer; a `nil` one is a state this loop already has a sentence
    /// for — the world the wait was armed in is gone.
    ///
    /// Each tick binds it strongly for its own duration, so a model released
    /// mid-tick survives to the end of that tick and no longer: the next one
    /// reads `nil` and stops. Nothing outside this loop holds it, which is what
    /// `testAWaitWhoseModelIsReleasedStopsAtTheNextTickRatherThanReadingIt`
    /// asserts by watching the model deallocate.
    private weak var owner: PullRequestModel?

    /// The wait's own generation token, checked after **every** suspension — the
    /// two `await`s in a tick (the read and the merge) and the sleep between
    /// ticks. Bumped by arming, by cancelling and by every ending, so a tick
    /// that resumes into a world where its wait is over publishes nothing at
    /// all.
    private var generation = 0

    /// The loop in flight, kept so cancellation can wake a default sleep rather
    /// than leaving it to expire on its own. Internal so the suites can await a
    /// wait to a standstill without a clock.
    private(set) var runningTask: Task<Void, Never>?

    init(owner: PullRequestModel) {
        self.owner = owner
    }

    // MARK: - What the surfaces ask

    /// Whether a wait is running at all — the term every Merge button in the
    /// panel disables on.
    ///
    /// One armed wait disables **every** row's Merge, not merely its own: the
    /// merge it will run is this feature's one-write rule spent in advance, and
    /// a second row merged in the meantime would raise
    /// ``PullRequestModel/isWriteInFlight`` under a wait that is about to need
    /// it. Reads, Checkout and Create are untouched — none of them is a merge.
    public var isArmed: Bool { armed != nil }

    /// Whether *this* row is the one being waited on — what the row draws its
    /// elapsed time and its Cancel button from.
    public func isWaiting(on number: Int) -> Bool { armed?.number == number }

    /// How long the armed wait has been running, as the row prints it — `m:ss`.
    ///
    /// Formatted here rather than in the row for ``elapsed``'s own reason: the
    /// number is read off ``now`` at each tick, and a view formatting it is one
    /// step from a view that also *advances* it. It is a projection of published
    /// state and nothing else, so it re-renders exactly when the wait says so.
    public var elapsedLabel: String {
        let seconds = max(0, Int(elapsed.rounded()))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// Drop the last ending's sentence — the reader has read it.
    ///
    /// Needed because three of the four endings are things nobody was standing in
    /// front of: a deadline reached and a stop the plan named both publish a
    /// sentence into a panel that may not have been open when they landed, and
    /// ``arm(plan:method:subject:body:)`` — the only other thing that clears
    /// ``ending`` — may never be pressed again. Idempotent, and silent when there
    /// is nothing to acknowledge.
    public func acknowledgeEnding() {
        ending = nil
    }

    // MARK: - Arming

    /// Arm a wait from the state the sheet is showing. `true` when it was armed.
    ///
    /// Refused, without a sentence, in the two states the button offering it
    /// cannot be in: a plan whose refusal is not ``GitHubMergeRefusal/isArmable``
    /// — which is every state but "checks are still running", the one thing a
    /// reader would knowingly sit through — and a method this repository does
    /// not allow, which is the same refusal
    /// ``PullRequestModel/merge(number:method:subject:body:)`` makes, asked
    /// before half an hour is spent rather than after.
    ///
    /// Arming over an armed wait **cancels** it first: that is one of the four
    /// endings, and it is here rather than at the caller so there is no path
    /// that leaves two loops polling one repository.
    @discardableResult
    public func arm(
        plan: GitHubMergePlan,
        method: GitHubMergeMethod,
        subject: String,
        body: String
    ) -> Bool {
        guard plan.refusal?.isArmable == true else { return false }
        guard plan.allowedMethods.contains(method) else { return false }
        // And the third thing that button cannot be in: a commit-producing
        // method with a blank subject, which `PullRequestModel.merge(row:...)`
        // refuses at the write. Asked here for the method guard's own reason —
        // before half an hour is spent rather than after — and through the
        // plan's own reading of "blank", so the button, the arming and the
        // write it leads to cannot disagree.
        guard !method.composesACommit || GitHubMergePlan.hasSubject(subject) else { return false }

        cancel()
        generation &+= 1
        let token = generation
        let armed = Armed(
            number: plan.pullRequest.number,
            method: method,
            subject: subject,
            body: body
        )
        self.armed = armed
        elapsed = 0
        ending = nil
        runningTask = Task { [weak self] in await self?.run(armed, token: token) }
        return true
    }

    /// Stop the armed wait — Cancel, a project switch, quit, or another wait
    /// armed over this one.
    ///
    /// Idempotent, and silent when nothing is armed: a cancellation nobody asked
    /// for is not an ending, and publishing one would leave "cancelled" sitting
    /// under a panel where nothing had been waiting.
    public func cancel() {
        guard armed != nil else { return }
        generation &+= 1
        armed = nil
        let task = runningTask
        runningTask = nil
        ending = .cancelled
        // Woken rather than merely superseded: the token already guarantees the
        // loop publishes nothing, but a real sleep would otherwise hold a task
        // alive for up to `pollInterval` seconds past a project switch.
        task?.cancel()
    }

    // MARK: - The loop

    /// One read, one decision, one sleep — until one of the four endings.
    ///
    /// **The head guard needs no rule of its own.** Each tick merges with the
    /// `headRefOid` *this tick* read, so a push landing between that read and the
    /// merge is refused by GitHub, in GitHub's words, and the refusal ends the
    /// wait with them on screen. Comparing the tick's head to the arm's here
    /// would be a second, weaker guard against the same accident — weaker
    /// because it cannot see the push that lands after the comparison.
    private func run(_ arming: Armed, token: Int) async {
        // The token, before the first read as well as after every suspension:
        // starting this task *is* a suspension. `arm(plan:method:subject:body:)`
        // returns to its caller with the loop merely enqueued, so a cancellation
        // landing in that gap — a project switch, quit — would otherwise be
        // answered by a tick that composes and sends a `gh pr view` in whatever
        // root is current *then*. The answer is discarded by the check after the
        // await, but the command was already sent, which is precisely what the
        // cancellation exists to prevent.
        guard token == generation else { return }
        let startedAt = now()

        while true {
            elapsed = now().timeIntervalSince(startedAt)

            // **A tick that resumed late does not run at all.** The guard at
            // the bottom of the loop is the deadline's *statement* — asked
            // after a tick, so the read that lands on the half hour is one the
            // wait is still entitled to make (see there). This one is the
            // deadline's *bound*, and it is what makes the half hour a ceiling
            // rather than a schedule: `sleep` resumes no earlier than it was
            // asked to and may resume arbitrarily later — a machine that slept,
            // a system under load — so without this a wait woken hours after it
            // was armed would read the row once more and could merge on it,
            // long past the bound the button's label promised and with nobody
            // in front of it. Measured against `now` for the same reason the
            // other guard is, and asked before the read rather than after it,
            // because the write the read can reach is the thing being bounded.
            //
            // Strictly greater, so it never fires on the boundary read the
            // guard below is about: an on-time sixty-first tick lands *on*
            // `deadline` and is still made.
            guard elapsed <= Self.deadline else {
                finish(.deadline, token: token)
                return
            }

            guard
                let owner,
                owner.isReady,
                let root = owner.currentRoot,
                let repository = owner.repository
            else {
                // The world the wait was armed in is gone: `gh` stopped being
                // ready, the project closed, the rows — and with them the
                // repository the plan is decided against — were blanked, or the
                // model itself has been released out from under a suspended tick
                // (a closed window; quit and a project switch both cancel first).
                // Its own sentence, because this one is read in the panel's
                // ending strip rather than under a sheet (see `stateLostMessage`).
                finish(.stopped(Self.stateLostMessage), token: token)
                return
            }

            let row: GitHubPullRequest
            do {
                let result = try await owner.send(
                    GitHubCommands.pullRequest(number: arming.number, root: root)
                )
                guard token == generation else { return }
                guard result.isSuccess else {
                    finish(.stopped(PullRequestModel.message(for: result)), token: token)
                    return
                }
                row = try GitHubAPI.pullRequest(fromViewJSON: result.standardOutput)
            } catch {
                guard token == generation else { return }
                // A read that could not be made ends the wait rather than being
                // slept through. Half an hour of failing reads that then reports
                // a deadline would name the wrong thing: an expired login and an
                // unreachable host both have something to say, and they say it
                // now rather than in 30 minutes.
                finish(.stopped(PullRequestModel.message(for: error)), token: token)
                return
            }

            guard row.state == GitHubPullRequest.openState else {
                finish(.stopped(Self.noLongerOpenMessage), token: token)
                return
            }

            // The tick's plan, from the tick's row. `checkedOutBranch` is
            // deliberately not carried from the arm: nothing the wait decides
            // reads it, and the tail's own decision is re-made from a fresh
            // branch read inside the merge — where it is true at the moment the
            // merge lands rather than half an hour ago.
            let plan = GitHubMergePlan.plan(
                pullRequest: row,
                repository: repository,
                checkedOutBranch: nil
            )

            if plan.canMerge {
                // **A write of this app's own is as transient as a running
                // check, and is slept through rather than ended on.**
                // ``PullRequestModel/merge(row:method:subject:body:)`` refuses
                // while this feature's one-write flag is up or the writer gate
                // is held — a `gh pr checkout`, a New Pull Request, a revert, a
                // branch switch — and answers `nil`, which is the same `nil`
                // GitHub's own refusal answers with. The wait therefore cannot
                // tell the two apart *after* the fact, and ending on it would
                // publish `.merged(nil)`: an ending whose strip says nothing,
                // so the row's elapsed time and its Cancel button would simply
                // vanish and a half-hour promise would be spent because
                // somebody pressed a button in the same panel a second ago.
                // Asked here, ahead of the write, where the difference is
                // knowable — and the cost of deferring is one tick, against
                // writes all far shorter than the deadline.
                if !owner.mergeIsDeferred {
                    let outcome = await owner.merge(
                        row: row,
                        method: arming.method,
                        subject: arming.subject,
                        body: arming.body
                    )
                    // **The one ending published past a moved token.** Every
                    // other one is a decision this wait is still entitled to
                    // make, and a token that moved says it is not. This one is a
                    // *fact*: the merge either landed or was refused, the reader
                    // has to be told either way, and the post-merge tail is owed
                    // off the back of it. A Cancel pressed while the write was in
                    // flight cannot un-send what was already sent. Disarming
                    // still respects the token, so a wait armed in that window
                    // keeps its own state.
                    if token == generation {
                        generation &+= 1
                        self.armed = nil
                        runningTask = nil
                    }
                    ending = .merged(outcome)
                    if let outcome { didMerge(outcome) }
                    return
                }
            } else {
                guard let refusal = plan.refusal, refusal.mayResolveByWaiting else {
                    // Everything the plan refuses for a reason a later read
                    // cannot change — a failing check, a draft, a conflict, a
                    // blocked or behind branch — plus the one state that has no
                    // refusal at all (a repository allowing no merge method),
                    // which is the same sentence the sheet's own method guard
                    // uses.
                    finish(
                        .stopped(plan.refusal?.message ?? PullRequestModel.mergeMethodMissingMessage),
                        token: token
                    )
                    return
                }
            }

            // **The deadline is *stated* here, after the tick.** The wait
            // covers `[0, deadline]` inclusive: sixty on-time sleeps of thirty
            // seconds are the half hour, so the sixty-first read lands on it,
            // and that read is what the deadline ending is a statement about.
            // Stating it at the top of the loop *instead* would make the last
            // observation one whole interval early, and
            // `deadlineMessage` — "Checks did not finish within 30 minutes" —
            // would then be said over a suite that finished at 29:50 and was
            // never looked at again: a false sentence, and a merge the reader
            // asked for withheld on it. What this guard is *for* is the thing
            // counting ticks would miss: it is measured against `now`, so reads
            // that slow down shorten the wait rather than doubling it.
            //
            // It is only half the rule. A sleep that resumes *late* would
            // otherwise reach the next read without passing this guard at all,
            // which is the bound's business rather than its statement — see the
            // overrun guard at the top of the tick.
            guard now().timeIntervalSince(startedAt) < Self.deadline else {
                finish(.deadline, token: token)
                return
            }

            await sleep(Self.pollInterval)
            guard token == generation else { return }
        }
    }

    /// Publish one of the four endings and disarm — the single exit.
    ///
    /// Bumps the token as it lands, so anything of this wait's still suspended
    /// resumes into a moved token and returns without publishing.
    private func finish(_ ending: PullRequestMergeWaitEnding, token: Int) {
        guard token == generation else { return }
        generation &+= 1
        armed = nil
        runningTask = nil
        self.ending = ending
    }
}
