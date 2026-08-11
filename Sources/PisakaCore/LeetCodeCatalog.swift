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
/// download the 2 MB list once.
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
    public func resolveSlug(
        for input: LeetCodeProblemInput,
        credentials: LeetCodeCredentials
    ) async throws -> String? {
        switch input {
        case .slug(let slug):
            return slug
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
        loadFromDiskIfNeeded()
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

    // MARK: - Refresh

    /// Fetch the catalog and publish it, whatever its current age.
    ///
    /// Coalesced: a second caller arriving while one fetch is in flight awaits
    /// that fetch instead of starting another. Two problems opened at once is the
    /// ordinary way that happens, and two 2 MB downloads is the ordinary way it
    /// used to go wrong.
    public func refresh(credentials: LeetCodeCredentials) async throws {
        if let existing = refreshTask {
            _ = try await existing.value
            return
        }
        let task = Task { @MainActor [self] () async throws -> Snapshot in
            let problems = try await fetchProblems(credentials: credentials)
            // Shape-valid and empty is not a catalog. Publishing it would cache
            // "there are no problems" for a day; see the note on this type.
            guard !problems.isEmpty else {
                throw LeetCodeError.apiChanged(detail: "stat_status_pairs: empty")
            }
            let snapshot = Snapshot(problems: problems, fetchedAt: now())
            publish(snapshot, fromNetwork: true)
            writeCache(snapshot)
            return snapshot
        }
        refreshTask = task
        defer { refreshTask = nil }
        _ = try await task.value
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
        return try LeetCodeAPI.parseProblemList(response)
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
    private func loadFromDiskIfNeeded() {
        guard !hasConsultedDisk else { return }
        hasConsultedDisk = true
        guard let text = try? fileService.read(url: layout.catalogFile),
              let cached = CachedCatalog(json: text)
        else { return }
        publish(
            Snapshot(problems: cached.decodedProblems, fetchedAt: cached.fetchedAt),
            fromNetwork: false
        )
    }

    /// Persist the catalog, or note that it could not be persisted.
    ///
    /// Deliberately does not throw. The caller is in the middle of opening a
    /// problem, the catalog it needs is in memory, and a read-only cache
    /// directory is not a reason to refuse. The cost of the degradation is one
    /// extra 2 MB fetch next launch, which the user never sees.
    private func writeCache(_ snapshot: Snapshot) {
        do {
            let json = try CachedCatalog(snapshot: snapshot).json()
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
              decoded.schemaVersion == Self.currentSchemaVersion
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
