import Foundation

/// What both surfaces key their automatic load on.
///
/// **Availability alone is not that key**, which is the whole reason this type
/// exists. A surface re-arms its load when this value changes, and a session can
/// be *replaced* without the availability moving at all: `signIn(with:)` is
/// reached with `isSignedIn` already `true` whenever `markSessionAccepted()` has
/// put a rejected session back, so `LeetCodeBrowserModel/invalidateInFlightWork()`
/// clears the previous account's rows while `availability` stays `.ready`. Keyed
/// on availability alone, the surface would then sit on an empty list after a
/// *successful* sign-in until the user pressed Refresh by hand — the clearing half
/// of that hook landing without the reloading half.
///
/// It is one `Equatable` value rather than two things each view remembers to
/// combine, so the two platforms cannot disagree about when a load re-arms.
public struct LeetCodeBrowserLoadKey: Equatable, Sendable {
    /// Whether the list is offered at all.
    public let availability: LeetCodeBrowserAvailability
    /// How many times the session behind the rows has been changed or replaced.
    public let sessionEpoch: Int

    public init(availability: LeetCodeBrowserAvailability, sessionEpoch: Int) {
        self.availability = availability
        self.sessionEpoch = sessionEpoch
    }
}

/// Whether the problem list can be shown — and, when it cannot, the sentence the
/// surface shows in its place.
///
/// The `LeetCodeJudgeAvailability` shape, and for the same reason: a surface that
/// cannot show a list must always have something to say, so the refusal carries
/// the sentence rather than leaving each of the two platform views to invent one.
/// **Signed out is a value this browser renders, not an error it dumps**: nobody
/// asked a question that failed — there is simply no session yet, and the offer to
/// sign in is the whole content of the screen.
public enum LeetCodeBrowserAvailability: Equatable, Sendable {
    /// There is a session, so the list is the surface's content.
    case ready
    /// There is none, and every catalog request requires one.
    case notSignedIn

    /// Whether the list is offered.
    public var isReady: Bool { self == .ready }

    /// Why it is not, or `nil` when it is.
    public var reason: String? {
        switch self {
        case .ready:
            return nil
        case .notSignedIn:
            return "Sign in to LeetCode to browse problems."
        }
    }
}

/// The problem browser: the filter the user is typing into, the rows it leaves,
/// and the two ways the catalog behind them is brought up to date.
///
/// **A companion model, owned by `LeetCodeModel` the way `catalog` and `judge`
/// are.** Two reasons, both the ones the judge already states. `LeetCodeModel` is
/// the largest file in this area and this is a whole second concern; and the
/// browser surfaces observe *this* object, so a keystroke in the search field
/// invalidates the list alone rather than every view bound to the account, the
/// statement or the judge.
///
/// The back-reference is `unowned` and deliberately not a protocol seam: what the
/// browser needs — the session and the one catalog — is `LeetCodeModel`'s and
/// nothing else's, this object is reachable only through its owner, and the suite
/// drives it through a real model over the scripted transport.
///
/// **The fifth generation token.** Opening, the statement, the account and the
/// judge each have one; this is the browser's, and it obeys the same rule —
/// bumped synchronously before the first `await`, checked after every suspension,
/// and work that comes back to find it moved publishes *nothing at all*, the
/// spinner included. It is bumped by `load()`, by `refresh()` and by
/// `sessionDidChange()`.
///
/// **A reader with no create at all** (L23). It never raises
/// `autosave.suspend()`/`beginRevert()` and is never gated by them, and unlike
/// `openProblem` it creates nothing: it reads the catalog the rest of the area
/// already keeps, filters it in memory, and publishes value types. The one create
/// in this integration remains `openProblem`'s, which is also the one path a row
/// in this list opens through — there is no second open path.
///
/// **It does own no cache, but it is not write-free** — the distinction matters
/// enough to state. A fetch that `load()` finds stale, and *every* `refresh()`,
/// goes through `LeetCodeCatalog`, which rewrites its own `catalog.json` from the
/// response. That write is the catalog's, on the catalog's schedule and in the
/// catalog's one file, so this layer adds no second cache and no second staleness
/// clock — but ``refresh()`` is a new *trigger* for it, where before LC-3 only an
/// open could cause one. It is still nothing the writer gate covers: the file is
/// under `Application Support`, not in the worktree git operates on.
///
/// **Freshness is the catalog's fetch time, and the surface says so** (L24). A
/// row's solved/attempted mark is whatever the account looked like when the list
/// was fetched, so `fetchedAt` is published beside the rows and `refresh()` is
/// offered explicitly, rather than pretending the marks are live.
@MainActor
public final class LeetCodeBrowserModel: ObservableObject {

    // MARK: - Published state

    /// What the user is narrowing by, as one bindable value.
    ///
    /// **The one place filtering is recomputed.** Every control on both platforms
    /// writes a field of this value, and the `didSet` re-runs the filter — so a
    /// surface cannot set a field and forget to. Filtering is synchronous and
    /// pure (`LeetCodeProblemFilter.apply(to:)` is one pass over an array in
    /// hand), which is why it takes no generation token: there is nothing to
    /// supersede.
    @Published public var filter = LeetCodeProblemFilter() {
        didSet {
            guard oldValue != filter else { return }
            refilter()
        }
    }

    /// Every row the catalog knows, in LeetCode's own order.
    @Published public private(set) var problems: [LeetCodeProblem] = []

    /// The rows ``filter`` leaves — **stored, not computed**. A computed property
    /// would re-filter four thousand rows on every SwiftUI body evaluation, which
    /// is several per keystroke.
    @Published public private(set) var visibleProblems: [LeetCodeProblem] = []

    /// When the rows on screen were fetched, or `nil` when there are none. What
    /// the "Updated …" line renders from; see the note on this type.
    @Published public private(set) var fetchedAt: Date?

    /// Whether a load or a refresh is in flight.
    @Published public private(set) var isLoading = false

    /// The last failure, or `nil`. Set beside the rows rather than instead of
    /// them — see ``load()``.
    @Published public private(set) var lastError: LeetCodeError?

    /// Whether the list is offered, and what the surface says when it is not.
    @Published public private(set) var availability: LeetCodeBrowserAvailability

    /// How many times the session behind the rows has been changed or replaced.
    ///
    /// Bumped by ``sessionDidChange()``, so it moves on *both* of this model's
    /// session doors — including the one where `availability` does not. Only
    /// ``loadKey`` reads it; see that property for why the surfaces need it.
    @Published public private(set) var sessionEpoch = 0

    /// The value both surfaces key their automatic load on — see
    /// ``LeetCodeBrowserLoadKey``.
    ///
    /// Computed rather than stored: both halves are published already, so a view
    /// observing this model re-evaluates and sees the new key without a third
    /// piece of state that could fall out of step with them.
    public var loadKey: LeetCodeBrowserLoadKey {
        LeetCodeBrowserLoadKey(availability: availability, sessionEpoch: sessionEpoch)
    }

    // MARK: - Private state

    private unowned let owner: LeetCodeModel

    /// The fifth generation token. See the type's note.
    private var generation = 0

    public init(owner: LeetCodeModel) {
        self.owner = owner
        self.availability = owner.isSignedIn ? .ready : .notSignedIn
    }

    // MARK: - Loading

    /// Have the list, at the cost the catalog's own policy allows: the disk cache,
    /// and a fetch **only when it is stale**.
    ///
    /// The idempotent entry both surfaces call on appear, so re-entering the
    /// browser inside the staleness window costs no request at all. Everything it
    /// publishes comes off `LeetCodeCatalog`'s public accessors, because that
    /// catalog is the one the rest of this area already reads — a second one would
    /// mean a second disk cache and a second staleness clock disagreeing with it.
    ///
    /// **A failure with rows in hand keeps them** — `resolveSlug(forNumber:)`'s
    /// degradation rule, applied on this axis: a refresh that could not be made
    /// must not blank a list somebody is reading, so the typed error is published
    /// *beside* the rows. With no rows anywhere, the error stands alone.
    public func load() async {
        await update(forced: false)
    }

    /// Fetch the list whatever its age — the explicit affordance beside the
    /// automatic staleness rule, and the only way a solved mark from five minutes
    /// ago reaches the screen.
    public func refresh() async {
        await update(forced: true)
    }

    /// The one flow both entry points share.
    private func update(forced: Bool) async {
        generation += 1
        let generation = self.generation

        // Resolved synchronously, before anything suspends: signed out is not a
        // failure, so it clears no rows and publishes no error — it is the
        // availability value the surface renders an offer from.
        guard let credentials = currentCredentials() else {
            availability = .notSignedIn
            isLoading = false
            return
        }
        availability = .ready
        lastError = nil
        isLoading = true

        var failure: LeetCodeError?
        do {
            // **The catalog call is shielded from this task's cancellation.**
            // `LeetCodeCatalog.refresh` cancels the *shared*, coalesced 2 MB fetch
            // when the caller awaiting it is cancelled — the right trade where the
            // canceller is Esc in the Open Problem sheet, which is a question that
            // user withdrew. Here the canceller is SwiftUI tearing down a `.task`
            // because a window closed or a screen was popped, which is routine and
            // withdraws nobody *else's* question: an open coalesced onto the same
            // download would have failed with "cancelled" for a reason that was
            // never true of it, on a catalog it still needed. An unstructured
            // `Task` inherits no cancellation and `value` does not observe the
            // awaiting task's either, so the fetch runs on for whoever is waiting
            // on it — while this browser still publishes nothing, because the
            // `Task.isCancelled` check below is unchanged.
            let fetch = Task { @MainActor [owner] in
                if forced {
                    try await owner.catalog.refresh(credentials: credentials)
                } else {
                    try await owner.catalog.loadIfNeeded(credentials: credentials)
                }
            }
            try await fetch.value
        } catch let error as LeetCodeError {
            failure = error
        } catch {
            // The catalog folds everything into the typed vocabulary already; this
            // branch exists so a decorator that does not cannot escape it.
            failure = .network(reason: error.localizedDescription)
        }

        // Superseded — a newer load, a refresh, or a session change owns the
        // published state now, **including `isLoading`**: switching the spinner off
        // here would switch off one the newer attempt turned on.
        guard generation == self.generation else { return }
        // Cancelled from the outside (the view's task went away): `URLSession`
        // reports that as an error, and it is not one the user asked about. The
        // spinner is still cleared — nobody else will.
        if !Task.isCancelled {
            adoptCatalog()
            if let failure { publish(failure) }
        }
        isLoading = false
    }

    /// Republish the rows and the fetch time from the catalog.
    ///
    /// Called on the failure path too, and guarded on the catalog having anything
    /// at all: `loadIfNeeded` reads the disk before it fetches, so a refresh that
    /// failed can still leave rows there that were never on screen — and when it
    /// leaves none, whatever the surface is already showing is better than
    /// blanking it.
    private func adoptCatalog() {
        guard !owner.catalog.problems.isEmpty else { return }
        problems = owner.catalog.problems
        fetchedAt = owner.catalog.fetchedAt
        refilter()
    }

    /// Record a failure, letting a rejected session change the account state as
    /// well — the rule the model and the judge both follow: any response that says
    /// logged-out flips the state, wherever it arrives.
    ///
    /// The order matters. `markSessionRejected()` runs the owner's `isSignedIn`
    /// observer, which calls ``sessionDidChange()`` here and clears `lastError`
    /// with the rows, so the sentence has to be set *after* it or it would be
    /// wiped by the very thing it is reporting.
    private func publish(_ error: LeetCodeError) {
        if error == .notLoggedIn { owner.markSessionRejected() }
        lastError = error
    }

    /// The session to make catalog requests with, or `nil` when this app has none.
    ///
    /// Both halves are asked. `isSignedIn` is the published account state, which a
    /// rejection flips while deliberately keeping the stored pair (a 403 from an
    /// unofficial endpoint is as often a throttle in disguise) — so the store
    /// alone would have the browser go on fetching under a session every other
    /// surface has already stopped believing in.
    private func currentCredentials() -> LeetCodeCredentials? {
        guard owner.isSignedIn else { return nil }
        return try? owner.requireCredentials()
    }

    // MARK: - Filtering

    private func refilter() {
        visibleProblems = filter.apply(to: problems)
    }

    // MARK: - The owner's hook

    /// The session changed: everything in flight is answering for one that no
    /// longer exists.
    ///
    /// Called from `LeetCodeModel.isSignedIn`'s observer, beside the judge's — one
    /// writer, one hook.
    ///
    /// **The rows are cleared, and that is the point.** The status column is
    /// per-account, so leaving one account's solved marks standing under another's
    /// name is the single wrong thing this surface could show; the catalog's own
    /// cache is per app rather than per account, so the next `load()` republishes
    /// (and, inside the staleness window, republishes the *previous* account's
    /// marks until a `refresh()` — the limit L24 states rather than hides).
    func sessionDidChange() {
        generation += 1
        // **Rows cleared and the load re-armed are one act, not two.** The token
        // above stops the old session's work from publishing; this one tells the
        // surfaces that what they are showing is gone and has to be fetched again
        // — necessary because on the replacement door below `availability`, the
        // other half of the key, does not move. See ``LeetCodeBrowserLoadKey``.
        sessionEpoch += 1
        availability = owner.isSignedIn ? .ready : .notSignedIn
        lastError = nil
        problems = []
        visibleProblems = []
        fetchedAt = nil
        // Nothing in flight will clear this now — its generation has moved.
        isLoading = false
    }

    /// The session is being *replaced*, whether or not the flag moves — the hook
    /// `LeetCodeModel.invalidateInFlightWork()` calls beside the judge's.
    ///
    /// **The observer above cannot be the only hook**, which is why the judge has
    /// two and this now does as well. `isSignedIn`'s `didSet` is guarded on the
    /// flag actually moving, so a `signIn(with:)` under a flag already `true`
    /// reaches nothing here — and that is an ordinary shape rather than a corner:
    /// `markSessionAccepted()` puts a rejected session back the moment any
    /// authenticated request answers, so a sign-in completing in the sheet the
    /// rejection opened finds the flag already raised. Without this, the previous
    /// account's rows and its **per-account solved marks** stayed standing under
    /// the new account's name — the single wrong thing this surface can show, and
    /// the one ``sessionDidChange()`` exists to prevent — and the token stayed
    /// unmoved, so a `load()` still in flight under the old session published over
    /// the new one.
    ///
    /// It is exactly ``sessionDidChange()``'s work because here the two questions
    /// have one answer: every row is per-account, so a session being replaced
    /// invalidates them as surely as one already replaced. Idempotent, which is
    /// what lets both hooks fire on the paths that trigger both.
    func invalidateInFlightWork() {
        sessionDidChange()
    }
}
