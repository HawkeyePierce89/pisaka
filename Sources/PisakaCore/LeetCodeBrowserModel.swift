import Foundation

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
/// `openProblem` it writes nothing whatsoever: it reads the catalog the rest of
/// the area already keeps, filters it in memory, and publishes value types. The
/// one create in this integration remains `openProblem`'s, which is also the one
/// path a row in this list opens through — there is no second open path.
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
            if forced {
                try await owner.catalog.refresh(credentials: credentials)
            } else {
                try await owner.catalog.loadIfNeeded(credentials: credentials)
            }
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
        availability = owner.isSignedIn ? .ready : .notSignedIn
        lastError = nil
        problems = []
        visibleProblems = []
        fetchedAt = nil
        // Nothing in flight will clear this now — its generation has moved.
        isLoading = false
    }
}
