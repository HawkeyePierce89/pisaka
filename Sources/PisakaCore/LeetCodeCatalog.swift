import Foundation

/// The problem list, cached on disk, and the one thing it is for: turning the
/// number a person typed into the slug every other request is made by.
///
/// LeetCode's detail query takes a `titleSlug` and nothing else, while the
/// identifier a user knows is the number on the site. Nothing in the API answers
/// "what is problem 1", so the only way to bridge the two is to hold the catalog
/// — ~4000 rows, ~2 MB, one `GET /api/problems/all/` — and look it up. This class
/// owns that list, its disk cache, and the policy for when to fetch it again.
///
/// **The policy, stated once so no call site re-decides it:**
///
/// - The cache is good for a day (`maximumAge`). Within it, opening a problem
///   makes exactly one request — the detail — and the catalog costs nothing.
/// - A **miss forces one refresh**, because a day-old catalog is exactly what a
///   brand-new problem is missing from, and "no such problem" is the wrong answer
///   to give somebody looking at it on the site. One, not a loop: after a refresh
///   has landed from the network this session, a number that is still absent is
///   reported absent immediately (`hasRefreshedFromNetwork`), so a typo'd number
///   cannot turn into a request per keystroke.
/// - **Not-found is a value, not an error.** `nil` back from `resolveSlug` means
///   the catalog does not have that number, which is a truthful answer to a typo;
///   `LeetCodeError.apiChanged` stays reserved for LeetCode having changed shape.
/// - **An empty catalog is never published or cached.** A shape-valid response
///   with zero rows would poison the cache for a day and make every open fail
///   with "no such problem"; it is reported as `apiChanged` instead, in keeping
///   with the rule that nothing in this area shrugs.
///
/// **A reader with one write.** The refresh writes the cache through
/// `FileServicing`, and a failure to write it is *not* an error the user sees:
/// the catalog degrades to living in memory for the session (`lastCacheWriteFailed`
/// records it) rather than failing the open the user actually asked for. Nothing
/// here takes the disk-writer gate — the file it writes is the app's own cache,
/// inside a directory no git operation and no editor tab ever looks at.
///
/// `@MainActor` like every other model in this codebase: the state below is read
/// and written by the LeetCode model between `await`s, and the actor is what makes
/// "two opens at once" a question about ordering rather than about locking. The
/// in-flight refresh is coalesced (`refreshTask`) so two simultaneous opens
/// download the 2 MB list once — **keyed by the session it was started under**,
/// because the rows carry a per-account `status` and a fetch made for one account
/// is not an answer to a caller holding another (`refreshCredentials`). Which
/// session that is, this type is *told* (`sessionDidChange(to:)`): a fetch made
/// under a replaced one neither happens nor publishes, whatever order it started
/// in (`declaredSession`).
@MainActor
public final class LeetCodeCatalog {

    /// How long a fetched catalog is trusted without asking again: one day.
    ///
    /// LeetCode adds problems weekly and renames essentially nothing, so the
    /// staleness this window admits is "a problem added in the last day is
    /// missing" — which is exactly the case the forced-refresh-on-miss path
    /// covers. The window exists to stop *hourly* 2 MB fetches, not to guarantee
    /// freshness; the miss path does that.
    public static let maximumAge: TimeInterval = 24 * 60 * 60

    /// What is currently known, and when it was learned.
    public struct Snapshot: Equatable, Sendable {
        public let problems: [LeetCodeProblem]
        public let fetchedAt: Date

        public init(problems: [LeetCodeProblem], fetchedAt: Date) {
            self.problems = problems
            self.fetchedAt = fetchedAt
        }
    }

    private let layout: LeetCodeCacheLayout
    private let fileService: FileServicing
    private let transport: LeetCodeTransport
    private let now: () -> Date

    private var snapshot: Snapshot?
    /// `frontendID` → slug, and slug → problem: the two lookups the flow makes,
    /// rebuilt whenever the snapshot is replaced rather than searched linearly
    /// through four thousand rows per keystroke.
    private var slugsByNumber: [Int: String] = [:]
    private var problemsBySlug: [String: LeetCodeProblem] = [:]

    /// Whether the disk cache has been consulted this session. The read happens
    /// once: after it, absence of a snapshot means "there is no cache", not "it
    /// has not been looked at", and the two would otherwise be indistinguishable
    /// every time a lookup missed.
    private var hasConsultedDisk = false
    /// Whether a refresh has landed **from the network** this session — the flag
    /// that makes the forced-on-miss refresh happen once rather than per lookup.
    /// A snapshot restored from disk does not set it: the whole point of forcing
    /// one refresh is that the disk copy may predate the problem being asked for.
    private var hasRefreshedFromNetwork = false
    private var refreshTask: Task<Snapshot, Error>?
    /// The session the in-flight refresh was started under — what makes the
    /// coalescing above **per-session** rather than global.
    ///
    /// The catalog's rows carry a per-account `status`, so a fetch made under one
    /// session is not an answer to a caller holding another. Without this key, a
    /// browser `refresh()` immediately after signing in as somebody else joined the
    /// previous account's in-flight download and published *its* solved/attempted
    /// marks under the new account's name — the one thing that surface must never
    /// show — and, because the publish stamps a fresh `fetchedAt`, pinned them for
    /// a day against the very `refresh()` that is meant to be the way out (L24).
    private var refreshCredentials: LeetCodeCredentials?
    /// Which refresh is the current one. Only the newest may publish, and only the
    /// newest may clear the slot above: with two fetches alive at once (the ordinary
    /// consequence of the key above), an older one completing last would otherwise
    /// overwrite the newer session's rows, and its `defer` would open the coalescing
    /// window while the newer download is still running.
    private var refreshGeneration = 0
    /// The session this app currently holds, as its owner last stated it — and
    /// whether it has been stated at all, which is a third state rather than a
    /// synonym for "there is none".
    ///
    /// **Start order is not session currency**, which is why the generation above
    /// cannot be the whole guard. A caller holding a session this app has replaced
    /// can reach `refresh` *after* the current one has started its own: every path
    /// into this type suspends before it fetches (`loadFromDiskIfNeeded`, and the
    /// browser's catalog work is deliberately shielded in an unstructured task a
    /// session change does not cancel), so the straggler resumes, finds a session
    /// key that no longer matches, starts a fetch of its own — and is now the
    /// *newest* refresh by start order. By that guard alone it would publish the
    /// previous account's `status` column over the current account's, with a fresh
    /// `fetchedAt` and a cache file to match. Only the app knows which session is
    /// current, so it says (`sessionDidChange(to:)`) and that is what the guard
    /// asks.
    ///
    /// **Undeclared means unconstrained**, deliberately: a catalog nobody has told
    /// about sessions — every test that is about the caching policy, and any caller
    /// that only ever has one — behaves exactly as it did before. A declared `nil`
    /// (a sign-out) is the opposite and lets nothing publish, which is why the
    /// owner declares at launch only when it *has* a session: a session the
    /// Keychain hands back later, having been locked at launch, must not be
    /// mistaken for a superseded one.
    private var declaredSession: LeetCodeCredentials?
    private var sessionHasBeenDeclared = false
    /// The one in-flight disk read, coalesced for the same reason `refreshTask`
    /// is: the read suspends across the decode, and a second caller arriving in
    /// that window must *wait for the cache* rather than conclude there is none.
    private var diskLoadTask: Task<Void, Never>?

    /// Whether the last attempt to persist the catalog failed, leaving this
    /// session running on an in-memory catalog. Surfaced for the tests and for a
    /// diagnostic, never for an alert: the user asked to open a problem, and that
    /// succeeded.
    public private(set) var lastCacheWriteFailed = false

    public init(
        layout: LeetCodeCacheLayout,
        fileService: FileServicing,
        transport: LeetCodeTransport,
        now: @escaping () -> Date = Date.init
    ) {
        self.layout = layout
        self.fileService = fileService
        self.transport = transport
        self.now = now
    }

    // MARK: - What is known

    /// Every problem currently known, in LeetCode's own order. Empty until
    /// something has been loaded or fetched.
    public var problems: [LeetCodeProblem] { snapshot?.problems ?? [] }

    /// When the current catalog was fetched, or `nil` when there is none.
    public var fetchedAt: Date? { snapshot?.fetchedAt }

    /// Whether there is no catalog, or the one there is has aged out.
    ///
    /// A `fetchedAt` in the *future* counts as stale too: a clock that moved
    /// backwards (or a cache file copied from another machine) would otherwise
    /// pin the catalog until the calendar caught up.
    public var isStale: Bool {
        guard let fetchedAt = snapshot?.fetchedAt else { return true }
        let age = now().timeIntervalSince(fetchedAt)
        return age < 0 || age >= Self.maximumAge
    }

    /// The slug of a problem number, from what is already known. Pure — no disk,
    /// no network; `resolveSlug(for:credentials:)` is the one that may fetch.
    public func slug(forNumber number: Int) -> String? {
        slugsByNumber[number]
    }

    /// The catalog row for a slug, from what is already known.
    public func problem(forSlug slug: String) -> LeetCodeProblem? {
        LeetCodeProblemInput.normalizedSlug(slug).flatMap { problemsBySlug[$0] }
    }

    /// The catalog row for a problem number, from what is already known.
    public func problem(forNumber number: Int) -> LeetCodeProblem? {
        slug(forNumber: number).flatMap { problemsBySlug[$0] }
    }

    /// The catalog row for a slug, **consulting the disk cache** when nothing has
    /// yet this session. Still no network: this is the cached catalog or nothing.
    ///
    /// The disk copy was otherwise reachable only through `resolveSlug(forNumber:)`
    /// — the number path — so the statement panel, which resolves nothing, could
    /// not see it. The visible cost was the offline reopen this feature advertises:
    /// the fragment came back from its own cache and the header read "1. two-sum",
    /// with the real title sitting unread in `catalog.json` beside it.
    public func cachedProblem(forSlug slug: String) async -> LeetCodeProblem? {
        await loadFromDiskIfNeeded()
        return problem(forSlug: slug)
    }

    // MARK: - Browsing

    /// Have the whole catalog in hand, at the cost the policy on this type allows:
    /// the disk cache once, and a network refresh **only when it is stale**.
    ///
    /// The one entry point for a reader that wants the list rather than a single
    /// answer. `resolveSlug(forNumber:)` is the wrong door for it — it forces a
    /// refresh when the number it was asked about is missing, and a browser asks
    /// about no number at all, so every empty search field would have paid for a
    /// 2 MB download. Nothing new is decided here: `loadFromDiskIfNeeded()` and
    /// `refresh(credentials:)` are the existing coalesced ones, so two surfaces
    /// appearing at once still read the file once and fetch once, and `maximumAge`
    /// still says what "stale" means.
    ///
    /// **It throws whatever the refresh threw**, deliberately — this is the one
    /// place the "stale rows beat no rows" degradation `resolveSlug(forNumber:)`
    /// applies is *not* applied. That rule needs to know what the caller is going
    /// to do with the rows, and here the caller is a surface with a list already on
    /// screen: it keeps what it is showing, puts the error beside it, and reads the
    /// still-populated `problems` off the same accessor every other reader uses.
    /// Swallowing the failure here would instead leave that surface unable to tell
    /// a refresh that landed from one that never happened.
    public func loadIfNeeded(credentials: LeetCodeCredentials) async throws {
        await loadFromDiskIfNeeded()
        guard isStale else { return }
        try await refresh(credentials: credentials)
    }

    // MARK: - Resolution

    /// The slug to request a problem's detail by, or `nil` when no such problem
    /// is known.
    ///
    /// A **slug input needs neither disk nor network**: it already *is* the key
    /// the detail request is made by, and asking the catalog to confirm it would
    /// turn "open the problem I linked" into a 2 MB download and would refuse
    /// slugs newer than the catalog. LeetCode's own answer to an unknown slug
    /// (`data.question: null`) is the authority there.
    ///
    /// A **number input** goes through the policy on this type: consult the
    /// cache, refresh if there is none or it has aged out, and force exactly one
    /// refresh if the number is missing from a catalog that had not yet come off
    /// the network this session.
    ///
    /// The slug is re-checked against the one slug rule on the way out, even
    /// though `LeetCodeProblemInput.parse(_:)` already applied it: `.slug` is a
    /// public case with a plain `String` payload, and **this return value becomes
    /// a path component** — `LeetCodeSolutionFile.name(…)` appends it to the
    /// user's folder, and `appendingPathComponent` does not resolve `..`. That is
    /// the same boundary `LeetCodeAPI`'s wire-slug check guards, and the rule must
    /// not hold only because of who happens to call it today. An unusable spelling
    /// is `nil` — "no such problem", which is what a slug this app cannot request
    /// is.
    public func resolveSlug(
        for input: LeetCodeProblemInput,
        credentials: LeetCodeCredentials
    ) async throws -> String? {
        switch input {
        case .slug(let slug):
            return LeetCodeProblemInput.normalizedSlug(slug)
        case .number(let number):
            return try await resolveSlug(forNumber: number, credentials: credentials)
        }
    }

    /// The number half of `resolveSlug(for:credentials:)`, which is where all the
    /// policy is.
    public func resolveSlug(
        forNumber number: Int,
        credentials: LeetCodeCredentials
    ) async throws -> String? {
        await loadFromDiskIfNeeded()
        if isStale {
            do {
                try await refresh(credentials: credentials)
            } catch {
                // **A refresh that could not be made does not invalidate what is
                // on disk.** The catalog endpoint is the legacy REST one and 2 MB
                // — the likeliest thing in this integration to be throttled or
                // blocked while GraphQL still answers — and letting its failure
                // out here would refuse a number whose slug we already hold and
                // whose detail request would have succeeded. Age is a reason to
                // *try* for something newer, not a reason to throw away what
                // answers the question.
                guard let slug = slugsByNumber[number] else { throw error }
                return slug
            }
        }
        if let slug = slugsByNumber[number] { return slug }

        // Missing from a catalog that came off the disk: it may simply predate
        // the problem. One refresh decides it.
        guard !hasRefreshedFromNetwork else { return nil }
        try await refresh(credentials: credentials)
        return slugsByNumber[number]
    }

    // MARK: - The session behind the rows

    /// The session this app now holds, or `nil` when it holds none.
    ///
    /// Called by `LeetCodeModel` from the one hook that fires on every session
    /// *replacement*, beside the judge's and the browser's. It publishes nothing,
    /// cancels nothing and fetches nothing: what it changes is whose fetch may
    /// still land. A download already in flight for the previous account finishes
    /// into nothing, and one a straggler holding that account starts afterwards is
    /// never made at all.
    ///
    /// Necessary because this type cannot work the answer out for itself — see
    /// `declaredSession`, which is also where the two states of "nobody has said"
    /// and "there is no session" are told apart.
    public func sessionDidChange(to credentials: LeetCodeCredentials?) {
        declaredSession = credentials
        sessionHasBeenDeclared = true
    }

    /// Whether these credentials are the session this app holds — `true` for as
    /// long as nobody has said, see `declaredSession`.
    private func isCurrentSession(_ credentials: LeetCodeCredentials) -> Bool {
        guard sessionHasBeenDeclared else { return true }
        return declaredSession == credentials
    }

    // MARK: - Refresh

    /// Fetch the catalog and publish it, whatever its current age.
    ///
    /// Coalesced **per session**: a second caller arriving while one fetch is in
    /// flight awaits that fetch instead of starting another, *provided it is asking
    /// under the same credentials*. Two problems opened at once is the ordinary way
    /// that happens, and two 2 MB downloads is the ordinary way it used to go
    /// wrong; a caller holding a different session is the case the key exists for
    /// (see `refreshCredentials`), and it pays for its own download rather than
    /// being handed another account's per-row `status`.
    ///
    /// **A session this app has moved on from asks nothing at all.** Its rows could
    /// never be published (see `declaredSession`), so the download would be 2 MB
    /// spent on an answer with nowhere to go — and worse than wasted: the request
    /// would carry a cookie the user has replaced, and LeetCode's 403 to it is
    /// classified as `notLoggedIn`, a sentence about the *current* session that is
    /// not true of it. It returns rather than throws because the caller holding
    /// those credentials was invalidated by the same hook that told this type about
    /// the new session, so its whole result is already discarded; an error would be
    /// a second answer to a question nobody is holding any more.
    public func refresh(credentials: LeetCodeCredentials) async throws {
        guard isCurrentSession(credentials) else { return }
        let coalesced = refreshCredentials == credentials ? refreshTask : nil
        let task = coalesced ?? startRefresh(credentials: credentials)
        // **The wait is cancellable, and cancelling it cancels the fetch.**
        // `Task { }` is unstructured, so it inherits nothing from the caller and
        // `task.value` does not observe the awaiting task's cancellation either:
        // without this, pressing Esc in the Open Problem sheet left `openProblem`
        // suspended here until the 2 MB download finished or hit the transport's
        // 60-second resource timeout — and with it `beginOpen()`'s counter still
        // raised, so the *next* sheet came up with everything disabled. The cost
        // is that a second, uncancelled caller coalesced onto this fetch sees it
        // fail as `network(reason: "cancelled")`; that is a retry, against a
        // minute of a dead sheet.
        _ = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Start the one in-flight refresh and register it for coalescing.
    ///
    /// The registration is cleared from **inside** the task rather than in a
    /// `defer` on the initiating caller: the caller can now be cancelled while the
    /// fetch it started runs on for the others waiting on it, and clearing the
    /// slot there would let the next open start a second 2 MB download beside the
    /// first. The task's own lifetime is the coalescing window.
    ///
    /// **A superseded fetch returns its snapshot without publishing it.** Since the
    /// coalescing is keyed by session, two fetches can be alive at once, and the
    /// older one is answering for a session this app has moved on from — publishing
    /// it would put the previous account's `status` column back over the current
    /// one's *and* stamp a fresh `fetchedAt` that keeps it there for a day. The
    /// value still goes back to whoever awaited this task, which is the honest
    /// answer to "what did the fetch you were waiting on return"; every caller that
    /// reads the *catalog* reads the published one. Nothing is written to disk on
    /// that path either, for the same reason.
    ///
    /// **Superseded means either older or answering for a replaced session.** The
    /// generation covers the first; a session change alone starts no new refresh,
    /// so a sign-out — or a sign-in as somebody else that the browser has not yet
    /// asked anything under — would otherwise let the fetch already in flight land
    /// the departing account's marks in the cache with a fresh `fetchedAt`.
    private func startRefresh(credentials: LeetCodeCredentials) -> Task<Snapshot, Error> {
        refreshGeneration += 1
        let generation = refreshGeneration
        let task = Task { @MainActor [self] () async throws -> Snapshot in
            defer {
                if refreshGeneration == generation {
                    refreshTask = nil
                    refreshCredentials = nil
                }
            }
            let problems = try await fetchProblems(credentials: credentials)
            // Shape-valid and empty is not a catalog. Publishing it would cache
            // "there are no problems" for a day; see the note on this type.
            guard !problems.isEmpty else {
                throw LeetCodeError.apiChanged(detail: "stat_status_pairs: empty")
            }
            let snapshot = Snapshot(problems: problems, fetchedAt: now())
            guard refreshGeneration == generation, isCurrentSession(credentials) else {
                return snapshot
            }
            publish(snapshot, fromNetwork: true)
            await writeCache(snapshot)
            return snapshot
        }
        refreshTask = task
        refreshCredentials = credentials
        return task
    }

    /// One catalog request, with every non-`LeetCodeError` failure folded into
    /// `network` — a transport is contractually allowed to throw only that, and a
    /// stub that throws something else must still read as "could not reach
    /// LeetCode" rather than escaping this layer's error type.
    private func fetchProblems(
        credentials: LeetCodeCredentials
    ) async throws -> [LeetCodeProblem] {
        let request = LeetCodeAPI.problemListRequest(credentials: credentials)
        let response: LeetCodeHTTPResponse
        do {
            response = try await transport.send(request)
        } catch let error as LeetCodeError {
            throw error
        } catch {
            throw LeetCodeError.network(reason: error.localizedDescription)
        }
        // **Parsed off the main actor.** This is ~2 MB through
        // `JSONSerialization` and then four thousand rows each built, slug-checked
        // and status-mapped — hundreds of milliseconds on a phone, and every bit
        // of it pure. Left where it landed (an `await` inside a `@MainActor`
        // method resumes on the main actor) it froze the editor behind a sheet
        // whose own spinner could not turn. Only `publish` needs the actor.
        return try await Task.detached { try LeetCodeAPI.parseProblemList(response) }.value
    }

    /// Replace what is known, and rebuild the two indices with it.
    ///
    /// Where two rows claim one number or one slug — which the live catalog does
    /// not do, but a future one is under no obligation not to — the **first** row
    /// wins, so the answer is LeetCode's own ordering rather than whichever
    /// happened to be last.
    private func publish(_ snapshot: Snapshot, fromNetwork: Bool) {
        self.snapshot = snapshot
        slugsByNumber = [:]
        problemsBySlug = [:]
        slugsByNumber.reserveCapacity(snapshot.problems.count)
        problemsBySlug.reserveCapacity(snapshot.problems.count)
        for problem in snapshot.problems {
            if slugsByNumber[problem.frontendID] == nil {
                slugsByNumber[problem.frontendID] = problem.slug
            }
            if problemsBySlug[problem.slug] == nil {
                problemsBySlug[problem.slug] = problem
            }
        }
        if fromNetwork { hasRefreshedFromNetwork = true }
        hasConsultedDisk = true
    }

    // MARK: - The disk cache

    /// Read the cached catalog, once per session.
    ///
    /// Every failure — no file, unreadable file, unparsable JSON, a schema
    /// version this build does not know, a row whose difficulty is a word this
    /// build has never heard of — is treated identically: **there is no cache**.
    /// That is the whole recovery story, and it is deliberately not granular. The
    /// file is this app's own; a mismatch means a version drift or a half-written
    /// file, and in both cases the correct move is to fetch a fresh one, which
    /// costs one request. Salvaging a partial catalog would instead produce a
    /// catalog that is silently missing problems.
    /// **The read stays on the actor and the decode does not.** `FileServicing` is
    /// reached from the main actor everywhere in this app (the test doubles are
    /// plain mutable classes, and a second thread in one of their dictionaries is
    /// a corrupted hash table rather than a flaky assertion), so the IO is not
    /// moved; the four-thousand-row `JSONDecoder` pass and its slug validation
    /// behind it are pure, and are, for the reason written on `fetchProblems`.
    /// **Coalesced, and the flag is raised on the way *out*.** The decode below is
    /// a suspension point, and raising `hasConsultedDisk` before it made the two
    /// states this flag exists to tell apart indistinguishable again for the
    /// duration: a second caller — the statement panel's `cachedProblem(forSlug:)`
    /// against an open's `resolveSlug(forNumber:)`, which is the ordinary way two
    /// of these overlap — read "consulted, and there is no cache" off a cache that
    /// was mid-decode, and went and downloaded the 2 MB list the disk copy was
    /// about to answer for. Worse, its fresh snapshot was then replaced by the
    /// resuming disk one while `hasRefreshedFromNetwork` stayed raised, so the
    /// forced-refresh-on-miss path was spent and a problem present only in the
    /// fresh list reported "no such problem" for the rest of the session.
    /// A second caller now awaits the read, exactly as it awaits an in-flight
    /// refresh.
    private func loadFromDiskIfNeeded() async {
        guard !hasConsultedDisk else { return }
        await (diskLoadTask ?? startDiskLoad()).value
    }

    /// Start the one in-flight disk read and register it for coalescing.
    private func startDiskLoad() -> Task<Void, Never> {
        let task = Task { @MainActor [self] () async -> Void in
            defer {
                hasConsultedDisk = true
                diskLoadTask = nil
            }
            guard let text = try? fileService.read(url: layout.catalogFile) else { return }
            guard let cached = await Task.detached(operation: { CachedCatalog(json: text) }).value
            else { return }
            // Nothing newer may be overwritten by what was on disk. Coalescing
            // above closes the path today's callers take here, but `refresh` is
            // public and takes no disk detour, so the rule is stated where the
            // publish is rather than left resting on the call graph.
            guard snapshot == nil else { return }
            publish(
                Snapshot(problems: cached.decodedProblems, fetchedAt: cached.fetchedAt),
                fromNetwork: false
            )
        }
        diskLoadTask = task
        return task
    }

    /// Persist the catalog, or note that it could not be persisted.
    ///
    /// Deliberately does not throw. The caller is in the middle of opening a
    /// problem, the catalog it needs is in memory, and a read-only cache
    /// directory is not a reason to refuse. The cost of the degradation is one
    /// extra 2 MB fetch next launch, which the user never sees.
    ///
    /// The encode is off the actor and the write is not — the split
    /// `loadFromDiskIfNeeded()` makes, for the reason written there.
    private func writeCache(_ snapshot: Snapshot) async {
        do {
            let json = try await Task.detached {
                try CachedCatalog(snapshot: snapshot).json()
            }.value
            try fileService.ensureDirectory(at: layout.base)
            try fileService.write(json, to: layout.catalogFile)
            lastCacheWriteFailed = false
        } catch {
            lastCacheWriteFailed = true
        }
    }
}

// MARK: - The on-disk shape

/// The cached catalog's own DTO — deliberately *not* `LeetCodeProblem`.
///
/// `LeetCodeProblem` is a domain model that this codebase renames and extends
/// whenever the app needs it to; the bytes on a user's disk are a compatibility
/// surface that may only change on purpose. Keeping them apart means a field can
/// be added to the model without invalidating every user's cache, and — more
/// importantly — that changing the *file* is a visible edit to this struct and a
/// bump of `currentSchemaVersion`, rather than something that falls out of an
/// unrelated refactor.
///
/// The enums travel as their raw strings and are mapped back by hand, so a value
/// this build does not know invalidates the cache (see `loadFromDiskIfNeeded`)
/// instead of decoding into a wrong-but-plausible default.
private struct CachedCatalog: Codable {
    /// Bumped whenever the shape below changes in a way an older or newer build
    /// would misread. A file whose version is not exactly this is treated as
    /// absent — forward *and* backward, since a newer build's file may carry
    /// meaning this one would silently drop.
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var fetchedAt: Date
    var problems: [CachedProblem]

    struct CachedProblem: Codable {
        var id: Int
        var slug: String
        var title: String
        var difficulty: String
        var isPaidOnly: Bool
        var status: String
    }

    init(snapshot: LeetCodeCatalog.Snapshot) {
        schemaVersion = Self.currentSchemaVersion
        fetchedAt = snapshot.fetchedAt
        problems = snapshot.problems.map {
            CachedProblem(
                id: $0.frontendID,
                slug: $0.slug,
                title: $0.title,
                difficulty: $0.difficulty.rawValue,
                isPaidOnly: $0.isPaidOnly,
                status: $0.status.rawValue
            )
        }
    }

    /// Decode a cache file, or answer `nil` for anything at all that is wrong
    /// with it — including a row this build cannot map.
    init?(json text: String) {
        guard let data = text.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode(CachedCatalog.self, from: data),
              decoded.schemaVersion == Self.currentSchemaVersion,
              // **Empty is absent at this door too.** The policy on this type is
              // that an empty catalog is never published or cached, and only the
              // network path enforced it (`startRefresh` throws `apiChanged`).
              // A file with zero rows decoded cleanly — the validation loop below
              // simply does not run — and published a snapshot whose `fetchedAt`
              // is recent, so `isStale` was false and nothing fetched for a day:
              // `loadIfNeeded` returned immediately and the browser showed "No
              // problems loaded." with no error and no way back. The file is this
              // app's own, so zero rows in it means what every other mismatch here
              // means — there is no cache.
              !decoded.problems.isEmpty
        else { return nil }
        for problem in decoded.problems {
            guard LeetCodeDifficulty(rawValue: problem.difficulty) != nil,
                  LeetCodeProblemStatus(rawValue: problem.status) != nil,
                  // The slug is validated here for the same reason `LeetCodeAPI`
                  // validates it on the wire: a restored row's slug is what a
                  // detail request is made by and — through the parser's
                  // `requestedSlug` fallback — what a *file name* is composed
                  // from, so this file is the second door into that path and must
                  // not be the unguarded one. An unnormalised row invalidates the
                  // whole cache, exactly as an unknown difficulty does.
                  LeetCodeProblemInput.normalizedSlug(problem.slug) == problem.slug
            else { return nil }
        }
        self = decoded
    }

    /// The rows as domain models. Only ever called after `init?(json:)` has
    /// established every raw value maps, which is why the fallbacks here are
    /// unreachable rather than lenient.
    var decodedProblems: [LeetCodeProblem] {
        problems.map {
            LeetCodeProblem(
                frontendID: $0.id,
                slug: $0.slug,
                title: $0.title,
                difficulty: LeetCodeDifficulty(rawValue: $0.difficulty) ?? .easy,
                isPaidOnly: $0.isPaidOnly,
                status: LeetCodeProblemStatus(rawValue: $0.status) ?? .notStarted
            )
        }
    }

    /// The bytes to write, with sorted keys so a cache file diffs readably and
    /// two runs over one catalog produce identical text.
    func json() throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard let text = String(data: data, encoding: .utf8) else {
            throw LeetCodeError.fileSystem(reason: "The catalog could not be encoded.")
        }
        return text
    }
}
