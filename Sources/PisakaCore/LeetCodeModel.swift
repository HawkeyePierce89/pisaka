import Foundation

/// One solution file, named by the problem it belongs to.
///
/// What `openProblem` hands back for the app to open as an ordinary editor tab —
/// deliberately *not* a tab, a window or anything the view layer owns: this
/// model's whole contribution to opening a problem is "there is a file here, and
/// it is problem N in this language".
public struct LeetCodeSolution: Equatable, Sendable {
    /// Where the file is, inside the configured LeetCode folder.
    public let url: URL
    /// The problem the file's name encodes.
    public let problem: LeetCodeProblem
    /// The language it was seeded in.
    public let language: LeetCodeLanguage

    public init(url: URL, problem: LeetCodeProblem, language: LeetCodeLanguage) {
        self.url = url
        self.problem = problem
        self.language = language
    }
}

/// What an "Open Problem…" attempt came to.
///
/// An enum rather than a struct-with-a-flag because two of the four answers are
/// not files at all, and both of them are **values rather than errors**:
///
/// - `noSuchProblem` is the honest answer to a typo — the same decision
///   `LeetCodeCatalog.resolveSlug` makes when it returns `nil`, carried up one
///   layer. Reporting it as `apiChanged` would tell somebody who mistyped a
///   number that LeetCode's API had changed; inventing a `notFound` error case
///   would put a typo in the same vocabulary as a broken schema.
/// - `superseded` is what a generation token discards. The user asked again
///   before the first answer landed, so the first one publishes nothing and
///   **writes nothing** — the caller must not open a tab for it.
public enum LeetCodeOpenOutcome: Equatable, Sendable {
    /// The file did not exist and was written, seeded from LeetCode's snippet.
    case created(LeetCodeSolution)
    /// The file was already there and was left **byte for byte** untouched.
    case resumed(LeetCodeSolution)
    /// Neither the catalog nor LeetCode knows this problem.
    case noSuchProblem
    /// A newer open replaced this one before it finished.
    case superseded

    /// The file, for the two outcomes that have one.
    public var solution: LeetCodeSolution? {
        switch self {
        case .created(let solution), .resumed(let solution): return solution
        case .noSuchProblem, .superseded: return nil
        }
    }

    /// Whether the file came into existence just now — what the app tells the
    /// project tree about, and what decides whether "resumed" is worth saying.
    public var wasCreated: Bool {
        if case .created = self { return true }
        return false
    }
}

/// The statement being shown beside the editor, and where it came from.
public struct LeetCodeStatement: Equatable, Sendable {
    /// The problem's slug — the cache key and the identity the panel compares by.
    public let slug: String
    /// The problem number read out of the file name.
    public let number: Int
    /// A display title: the catalog's, LeetCode's, or the slug when neither is
    /// known yet.
    public let title: String
    /// LeetCode's own HTML **fragment**, verbatim.
    /// `LeetCodeStatementDocument.html(fragment:…)` wraps it on the way to the web
    /// view — every time, because theme and font size are session state.
    public let fragment: String
    /// Whether this came off the disk cache rather than the network. The panel
    /// does not distinguish them visually; the flag exists so a refresh landing
    /// behind a cached render is observable, and so the tests can tell the
    /// offline path from the live one.
    public let isFromCache: Bool

    public init(slug: String, number: Int, title: String, fragment: String, isFromCache: Bool) {
        self.slug = slug
        self.number = number
        self.title = title
        self.fragment = fragment
        self.isFromCache = isFromCache
    }
}

/// The one `@MainActor ObservableObject` the LeetCode integration is driven
/// through: who is signed in, opening a problem, and the statement for the active
/// tab.
///
/// Everything below it is pure or single-purpose — the schema file parses, the
/// catalog resolves, the layout computes paths, the document composes HTML — and
/// **this is the only place in the area that sequences `await`s**. That is why it
/// is also the only place generation tokens live: every entry point bumps its
/// counter *synchronously*, before its first suspension, and discards its result
/// rather than publishing over newer state when it comes back to find the counter
/// moved. The counters are separate per concern (opening, the statement, the
/// account) so a statement refresh cannot cancel an open, but signing out bumps
/// all of them, because a session change invalidates everything in flight.
///
/// **A reader with exactly one create.** The model never calls
/// `autosave.suspend()` or `localChanges.beginRevert()` and is never gated by
/// them — the same position the symbol index and the LSP client hold. The
/// justification is narrower here than there, and worth stating: this layer does
/// write, but only ever *creates* a file that does not exist, inside a folder the
/// user set aside for it. It never rewrites a file the editor may have buffered,
/// never touches the worktree git is operating on, and has no plan of its own to
/// invalidate. Taking the writer gate would serialise "open a LeetCode problem"
/// behind whatever the project's git operations are doing, for a write that
/// cannot conflict with any of them.
///
/// **Never overwrite.** An existing solution file is returned untouched
/// (`.resumed`), because the whole point of the naming rule is that reopening a
/// problem returns you to your work. Re-seeding would silently delete a
/// half-finished solution — the one failure in this integration a user could not
/// undo.
@MainActor
public final class LeetCodeModel: ObservableObject {

    // MARK: - Dependencies

    private let transport: LeetCodeTransport
    private let credentialStore: LeetCodeCredentialStore
    private let fileService: FileServicing
    private let statementCache: LeetCodeStatementCache

    /// The problem list and its policy. Exposed because the app surfaces "last
    /// refreshed" and, later, the problem browser; it owns its own cache and
    /// staleness rules and this model does not second-guess them.
    public let catalog: LeetCodeCatalog

    // MARK: - Published state

    /// The account name LeetCode last confirmed, or `nil` when signed out or not
    /// yet confirmed. A stored session with an unconfirmed name is the ordinary
    /// state at launch — the name arrives with `refreshUserStatus()`.
    @Published public private(set) var signedInUsername: String?

    /// Whether this app believes it has a usable session.
    ///
    /// Optimistic at launch: a stored credential pair sets it before anything has
    /// been confirmed, because the alternative is showing "signed out" for the
    /// duration of a network round trip to somebody who is signed in. LeetCode's
    /// own `isSignedIn == false`, wherever it appears, is what clears it.
    @Published public private(set) var isSignedIn: Bool

    /// Whether any LeetCode operation is running — a count under the hood, so two
    /// overlapping operations do not have the first one's completion switch the
    /// spinner off.
    @Published public private(set) var isBusy = false

    /// Whether an "Open Problem…" is running, counted the same way.
    ///
    /// Separate from `isBusy` because the two answer different questions and the
    /// entry sheets bind their controls to this one. A statement refresh raises
    /// `isBusy` too, and it is started by *switching tabs* — so a single counter
    /// meant that selecting a LeetCode tab on a slow link and then pressing ⌘⇧P
    /// produced a sheet with a disabled field and a dead Open button, waiting on
    /// a request that has nothing to do with what the user is trying to do.
    @Published public private(set) var isOpening = false

    /// The most recent failure, for the sheet's inline error and the iOS row.
    /// Cleared when a new operation starts, so a stale sentence never sits under
    /// a fresh attempt.
    @Published public private(set) var lastError: LeetCodeError?

    /// The statement for the tab the user is looking at, or `nil` when that tab is
    /// not a LeetCode solution file.
    @Published public private(set) var statement: LeetCodeStatement?

    /// Where solution files are written, as the user configured it — a plain
    /// persisted path on macOS (the app is unsandboxed) and a bookmark-resolved
    /// URL on iOS. `nil` is "not configured yet", which every open reports as
    /// `folderUnavailable` rather than guessing a location.
    @Published public var solutionsFolder: URL?

    /// Whether the last attempt to persist the session to the Keychain failed.
    ///
    /// The `LeetCodeCatalog.lastCacheWriteFailed` shape, for the same reason: the
    /// user signed in and the session works *this run*: a Keychain that would not
    /// take the item is not a reason to refuse the sign-in they just completed. It
    /// costs one sign-in next launch.
    public private(set) var lastCredentialSaveFailed = false

    // MARK: - Private state

    /// The session, held in memory so a request per keystroke does not become a
    /// Keychain read per keystroke. The store remains the source of truth across
    /// launches; this is a cache of it, and `signOut()` clears both.
    private var cachedCredentials: LeetCodeCredentials?

    /// Whether an explicit sign-out has happened this run.
    ///
    /// `signOut()` clears the store, but a Keychain that refuses the delete
    /// leaves the pair on disk — and every credential lookup here falls back to
    /// the store, so the very next open would read the session back out and
    /// succeed while the app showed "signed out". The flag is what makes the
    /// sign-out hold regardless of what the Keychain did; a new `signIn` clears
    /// it, and next launch reads the store afresh (a stored pair the user asked
    /// to forget is the residue of a Keychain failure, and one they can sign out
    /// of again).
    private var storedCredentialsAreDiscarded = false

    /// Slugs whose statement came off the *network* during this run.
    ///
    /// The panel's refresh is started by a tab change, and the statement was
    /// usually just fetched: `openProblem` already has the detail in hand and
    /// caches it, so re-fetching when the tab it opened becomes active is a
    /// second request for bytes we hold — against an unofficial API the whole
    /// design is built around not annoying. Switching back and forth between two
    /// LeetCode tabs is the same request twice more. A slug in here is refreshed
    /// from the cache alone; `signOut()` empties it, since a session change
    /// invalidates what was fetched under the old one.
    private var slugsFetchedThisRun: Set<String> = []

    /// Slugs LeetCode has answered `data.question: null` for this run.
    ///
    /// The counterpart of `slugsFetchedThisRun` for the *negative* answer, and it
    /// exists for the same reason. The file-name association is deliberately
    /// permissive — a `2024-notes.md` the user happened to drop in the LeetCode
    /// folder parses as problem 2024, slug `notes` — and the panel's refresh is
    /// started by every tab change, so without this a file like that issues a
    /// GraphQL request that is *permanently* going to answer "no such problem",
    /// once per switch to it, forever.
    ///
    /// A statement with **no content** is recorded here too, for the same reason
    /// and with the same consequence: a Premium problem answers `isPaidOnly: true`
    /// with a null `content`, which is as stable an answer about that slug as
    /// `null` is, and a solution file for one that reached the folder some other
    /// way would otherwise ask again on every switch to it.
    ///
    /// Only those two answers are recorded. Offline, throttled and rejected are
    /// failures to *ask*, and must still be retried; both of these are LeetCode
    /// answering the question. `signOut()` empties it with `slugsFetchedThisRun`,
    /// so a session change starts every one of this run's conclusions over — which
    /// is also what lets a user who subscribes mid-run see the statement after
    /// signing back in.
    private var slugsKnownAbsent: Set<String> = []

    /// Problem titles this run has seen on the wire, by slug.
    ///
    /// The panel's title has two sources and both can be empty. The catalog knows
    /// every title, but it is only ever loaded to resolve a *number* — opening by
    /// slug or by URL returns the slug verbatim without fetching it (see
    /// `LeetCodeCatalog.resolveSlug`) — and the disk fragment cache stores markup,
    /// not a title. Without this, a problem opened by URL showed "1. Two Sum"
    /// while its detail was in hand and then permanently degraded to "1. two-sum"
    /// the first time the user switched tabs and came back, since that refresh is
    /// answered from the cache and short-circuits before any fetch could correct
    /// it.
    ///
    /// Not cleared by `signOut()`, like the disk fragment cache it parallels: a
    /// problem's title is public content, not something the session revealed.
    private var titlesBySlug: [String: String] = [:]

    private var openGeneration = 0
    private var statementGeneration = 0
    private var accountGeneration = 0
    private var busyCount = 0
    private var openCount = 0

    public init(
        transport: LeetCodeTransport,
        credentialStore: LeetCodeCredentialStore,
        fileService: FileServicing,
        cacheLayout: LeetCodeCacheLayout,
        solutionsFolder: URL? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.transport = transport
        self.credentialStore = credentialStore
        self.fileService = fileService
        self.statementCache = LeetCodeStatementCache(
            layout: cacheLayout,
            fileService: fileService
        )
        self.catalog = LeetCodeCatalog(
            layout: cacheLayout,
            fileService: fileService,
            transport: transport,
            now: now
        )
        self.solutionsFolder = solutionsFolder
        let stored = credentialStore.load()
        self.cachedCredentials = stored
        self.isSignedIn = stored != nil
    }

    // MARK: - The account

    /// Adopt the session lifted out of the login web view's cookie store, and
    /// confirm it with LeetCode.
    ///
    /// - Returns: the confirmed account name, or `nil` when LeetCode reported the
    ///   session as signed in but named nobody.
    /// - Throws: `notLoggedIn` when LeetCode says the session is not signed in —
    ///   in which case nothing is left stored, since a session LeetCode rejects at
    ///   the moment it was obtained is not one worth keeping.
    @discardableResult
    public func signIn(with credentials: LeetCodeCredentials) async throws -> String? {
        accountGeneration += 1
        let generation = accountGeneration
        invalidateInFlightWork()
        cachedCredentials = credentials
        storedCredentialsAreDiscarded = false
        isSignedIn = true
        signedInUsername = nil
        lastError = nil
        do {
            try credentialStore.save(credentials)
            lastCredentialSaveFailed = false
        } catch {
            lastCredentialSaveFailed = true
        }

        beginWork()
        defer { endWork() }
        do {
            let status = try await fetchUserStatus(credentials: credentials)
            guard generation == accountGeneration else { return signedInUsername }
            guard status.isSignedIn else {
                signOut()
                lastError = .notLoggedIn
                throw LeetCodeError.notLoggedIn
            }
            isSignedIn = true
            signedInUsername = status.username
            return status.username
        } catch let error as LeetCodeError {
            // A confirmation that could not be *made* — offline, throttled — is
            // not a rejection: the cookies came out of a browser session that had
            // just signed in, so they stay, and the name fills in on the next
            // refresh.
            //
            // `notLoggedIn` is the other half, and it is a rejection: LeetCode
            // answers a dead session with a 401/403 or an auth `errors` array as
            // readily as with `isSignedIn: false`, and the two must not end
            // differently. Without this the pair the user just signed in with is
            // already in the Keychain, every surface says "Signed in", and the
            // state is corrected only by whatever operation next happens to fail
            // — which is the exact "a dead session reading as signed in" that
            // `refreshUserStatus` spells out one method down.
            guard generation == accountGeneration else { throw error }
            if error == .notLoggedIn { signOut() }
            lastError = error
            throw error
        }
    }

    /// Ask LeetCode who this session is, updating the published state.
    ///
    /// Non-throwing: this is what the app calls at launch, and a failure there
    /// must not produce an alert. A rejection still flips `isSignedIn`, because
    /// that one *is* an answer.
    @discardableResult
    public func refreshUserStatus() async -> LeetCodeAPI.UserStatus? {
        accountGeneration += 1
        let generation = accountGeneration
        guard let credentials = cachedCredentials ?? storedCredentials() else {
            markSessionRejected()
            return nil
        }
        cachedCredentials = credentials

        beginWork()
        defer { endWork() }
        let status: LeetCodeAPI.UserStatus
        do {
            status = try await fetchUserStatus(credentials: credentials)
        } catch LeetCodeError.notLoggedIn {
            // A rejection *is* an answer, and the only one this method must act
            // on: swallowing it with the rest would leave a dead session reading
            // as signed in — with the account name in the menu — until the user
            // tried to open something. Everything else (offline, throttled) is
            // still silent, which is what "the launch-time call raises no alert"
            // means.
            guard generation == accountGeneration else { return nil }
            markSessionRejected()
            return nil
        } catch {
            return nil
        }
        guard generation == accountGeneration else { return status }
        if status.isSignedIn {
            isSignedIn = true
            signedInUsername = status.username
        } else {
            markSessionRejected()
        }
        return status
    }

    /// Forget the session: the in-memory copy, the stored one, and everything on
    /// screen that depended on it.
    ///
    /// The web view's own cookies are the app layer's half of this (the login view
    /// clears them); either half alone leaves the user half signed in.
    ///
    /// **The statement is deliberately left standing.** It is a problem
    /// description — public content, still in the fragment cache, and republished
    /// from that cache by `statement(forFileAt:in:)` with no session at all — so
    /// clearing it here would be the one piece of state a sign-out removes that
    /// signing back in does not restore: the panel's refresh is keyed on the
    /// *file* the user is looking at, which a sign-out does not change, so nothing
    /// would re-ask the question until they switched tabs and back.
    public func signOut() {
        accountGeneration += 1
        invalidateInFlightWork()
        cachedCredentials = nil
        // Raised whether or not the delete succeeded — see the flag's own note:
        // a Keychain that refuses it must not leave a session every later
        // lookup can read back out.
        storedCredentialsAreDiscarded = true
        try? credentialStore.clear()
        slugsFetchedThisRun.removeAll()
        slugsKnownAbsent.removeAll()
        isSignedIn = false
        signedInUsername = nil
        lastError = nil
    }

    // MARK: - Opening a problem

    /// Resolve what the user typed, fetch the problem, and make sure a solution
    /// file for it exists.
    ///
    /// The sequence is fixed and every step of it can be the last: no folder →
    /// `folderUnavailable`; no session → `notLoggedIn`; no such number →
    /// `.noSuchProblem`; Premium → `paidOnly`, *before* anything is written.
    /// Nothing is created until every one of those has passed, which is what
    /// "leaves no partial file" means here.
    ///
    /// An existing file is returned as `.resumed` and not read, not rewritten and
    /// not compared — see the note on this type.
    @discardableResult
    public func openProblem(
        input: LeetCodeProblemInput,
        language: LeetCodeLanguage
    ) async throws -> LeetCodeOpenOutcome {
        openGeneration += 1
        let generation = openGeneration
        // Captured synchronously: the folder may be re-pointed while this runs,
        // and the file belongs where it was asked for.
        let folder = solutionsFolder
        lastError = nil

        beginWork()
        beginOpen()
        defer {
            endOpen()
            endWork()
        }
        do {
            return try await performOpen(
                input: input,
                language: language,
                folder: folder,
                generation: generation
            )
        } catch let error as LeetCodeError {
            if generation == openGeneration { publish(error) }
            throw error
        } catch {
            let wrapped = LeetCodeError.network(reason: error.localizedDescription)
            if generation == openGeneration { publish(wrapped) }
            throw wrapped
        }
    }

    private func performOpen(
        input: LeetCodeProblemInput,
        language: LeetCodeLanguage,
        folder: URL?,
        generation: Int
    ) async throws -> LeetCodeOpenOutcome {
        guard let folder else { throw LeetCodeError.folderUnavailable }
        let credentials = try requireCredentials()

        // The generation is checked *before* "no such problem" on both steps, not
        // after: `.noSuchProblem` is a sentence the caller shows, and a superseded
        // attempt must contribute nothing at all — including the answer to a
        // question the user has already replaced.
        let resolved = try await catalog.resolveSlug(for: input, credentials: credentials)
        guard generation == openGeneration else { return .superseded }
        guard let slug = resolved else { return .noSuchProblem }

        let fetched = try await fetchDetail(slug: slug, credentials: credentials)
        guard generation == openGeneration else { return .superseded }
        guard let detail = fetched else { return .noSuchProblem }
        guard !detail.isPaidOnly else { throw LeetCodeError.paidOnly(slug: detail.slug) }

        let name = LeetCodeSolutionFile.name(
            number: detail.frontendID,
            slug: detail.slug,
            language: language
        )
        let url = folder.appendingPathComponent(name)

        do {
            try fileService.ensureDirectory(at: folder)
        } catch {
            // The folder is gone, or something that is not a directory occupies
            // its path — the user has to choose one again, which is exactly what
            // `folderUnavailable` says.
            throw LeetCodeError.folderUnavailable
        }
        if let existing = try existingFile(named: name, in: folder) {
            // The file the user is returning to, at the name it actually carries
            // on disk — see `existingFile`.
            adoptStatement(from: detail)
            return .resumed(
                LeetCodeSolution(url: existing, problem: detail.problem, language: language)
            )
        }

        // A language LeetCode does not offer this problem in yields the header
        // alone rather than a refusal: the file, the name and the panel are all
        // still correct, and the user can type the signature themselves.
        let contents = LeetCodeSolutionFile.contents(
            header: LeetCodeSolutionFile.header(
                number: detail.frontendID,
                title: detail.title,
                slug: detail.slug,
                language: language
            ),
            snippet: detail.snippet(forLanguageSlug: language.langSlug) ?? ""
        )
        do {
            try fileService.write(contents, to: url)
        } catch {
            throw LeetCodeError.fileSystem(reason: describe(error))
        }

        // The statement is already in hand; cache and publish it here so the panel
        // is populated the moment the tab opens, and so a later offline reopen has
        // something to show. **After the file exists, never before**: the panel is
        // published globally and is not keyed to the active tab, so adopting it on
        // a path that then throws would leave a statement for a problem the user
        // has no file for, sitting beside whatever unrelated tab was open.
        adoptStatement(from: detail)
        return .created(
            LeetCodeSolution(url: url, problem: detail.problem, language: language)
        )
    }

    // MARK: - The statement panel

    /// The problem a file belongs to, or `nil` when it belongs to none.
    ///
    /// **Association is by file name, and only inside the LeetCode folder** — both
    /// halves, because the name rule alone is deliberately permissive (a project's
    /// own `2024-notes.md` parses as problem 2024). Containment is asked through
    /// the canonical-path primitives every other "is this file inside that
    /// directory" question in this app goes through, so a folder reached by a
    /// symlink still matches.
    public func associatedProblem(
        forFileAt url: URL,
        in folder: URL
    ) -> (number: Int, slug: String)? {
        let file = CanonicalPath.canonical(url).path
        let root = CanonicalPath.canonical(folder).path
        guard file != root, ScopedFileAccess.path(file, isWithin: root) else { return nil }
        return LeetCodeSolutionFile.parts(fromFileName: url.lastPathComponent)
    }

    /// Publish the statement for the tab the user just switched to.
    ///
    /// **Cache first, network behind it.** A cached fragment is published before
    /// the request is even made, so switching tabs is instant and an offline
    /// reopen shows yesterday's statement; the fetch then replaces it. The
    /// consequence, stated so it is not read as a bug: *a failure with a cached
    /// fragment present is not an error* and sets no `lastError`, because the user
    /// is looking at the statement either way.
    ///
    /// - Parameters:
    ///   - url: the active tab's file, or `nil` when there is none.
    ///   - folder: the configured LeetCode folder, or `nil` when unset — either
    ///     `nil` clears the panel.
    /// - Returns: what was published, which is the cached fragment when the
    ///   refresh could not land.
    @discardableResult
    public func statement(forFileAt url: URL?, in folder: URL?) async -> LeetCodeStatement? {
        statementGeneration += 1
        let generation = statementGeneration

        guard let url, let folder,
              let parts = associatedProblem(forFileAt: url, in: folder)
        else {
            statement = nil
            return nil
        }

        let slug = parts.slug
        var published: LeetCodeStatement?
        if let fragment = statementCache.fragment(forSlug: slug) {
            published = LeetCodeStatement(
                slug: slug,
                number: parts.number,
                // This run's own answer first, the catalog behind it: opening by
                // slug or URL never loads the catalog, so it is empty on exactly
                // the paths where the title matters most. See `titlesBySlug`.
                title: titlesBySlug[slug] ?? catalog.problem(forSlug: slug)?.title ?? slug,
                fragment: fragment,
                isFromCache: true
            )
            statement = published
        } else {
            statement = nil
        }

        // Already fetched this run — the cache we just published *is* that
        // fetch's bytes. See `slugsFetchedThisRun`.
        if let published, slugsFetchedThisRun.contains(slug) { return published }
        // Already asked, and LeetCode said there is no such problem. Asking again
        // on every tab switch would be a request per switch, forever. See
        // `slugsKnownAbsent`.
        if slugsKnownAbsent.contains(slug) { return published }

        guard let credentials = cachedCredentials ?? storedCredentials() else {
            if published == nil { publish(.notLoggedIn) }
            return published
        }
        cachedCredentials = credentials

        beginWork()
        defer { endWork() }
        do {
            let detail = try await fetchDetail(slug: slug, credentials: credentials)
            guard generation == statementGeneration else { return published }
            // Both of LeetCode's own answers are recorded, not just `null`: a
            // detail with no content is a Premium problem, which is as settled a
            // fact about that slug as "no such problem". See `slugsKnownAbsent`.
            if detail == nil || detail?.content.isEmpty == true {
                slugsKnownAbsent.insert(slug)
            }
            guard let detail, !detail.content.isEmpty else { return published }
            let title = detail.title.isEmpty ? slug : detail.title
            let fresh = LeetCodeStatement(
                slug: slug,
                number: parts.number,
                title: title,
                fragment: detail.content,
                isFromCache: false
            )
            titlesBySlug[slug] = title
            statementCache.store(detail.content, forSlug: slug)
            slugsFetchedThisRun.insert(slug)
            statement = fresh
            // The panel is showing a statement that just arrived; a sentence
            // from an older failure sitting beside it on some other surface
            // would be describing a state that no longer exists.
            lastError = nil
            return fresh
        } catch let error as LeetCodeError {
            guard generation == statementGeneration else { return published }
            // A rejected session is worth recording whether or not the panel had
            // something to show — it changes what every *other* surface says.
            if error == .notLoggedIn { markSessionRejected() }
            if published == nil { lastError = error }
            return published
        } catch {
            return published
        }
    }

    // MARK: - Requests

    private func fetchUserStatus(
        credentials: LeetCodeCredentials
    ) async throws -> LeetCodeAPI.UserStatus {
        let response = try await send(LeetCodeAPI.userStatusRequest(credentials: credentials))
        return try LeetCodeAPI.parseUserStatus(response)
    }

    /// One detail request. `nil` is LeetCode's own "no such slug"
    /// (`data.question: null`), which is a value here exactly as it is in the
    /// parser.
    private func fetchDetail(
        slug: String,
        credentials: LeetCodeCredentials
    ) async throws -> LeetCodeProblemDetail? {
        let response = try await send(
            LeetCodeAPI.questionDetailRequest(slug: slug, credentials: credentials)
        )
        return try LeetCodeAPI.parseQuestionDetail(response, requestedSlug: slug)
    }

    /// Every request goes through here so a transport that throws something other
    /// than a `LeetCodeError` — which the real one does not, but a decorator or a
    /// stub might — still reads as "could not reach LeetCode" rather than escaping
    /// this layer's vocabulary. The same fold `LeetCodeCatalog` applies.
    private func send(_ request: LeetCodeHTTPRequest) async throws -> LeetCodeHTTPResponse {
        do {
            return try await transport.send(request)
        } catch let error as LeetCodeError {
            throw error
        } catch {
            throw LeetCodeError.network(reason: describe(error))
        }
    }

    // MARK: - Plumbing

    /// The session, or the error every operation reports without one.
    private func requireCredentials() throws -> LeetCodeCredentials {
        if let cachedCredentials { return cachedCredentials }
        guard let stored = storedCredentials() else { throw LeetCodeError.notLoggedIn }
        cachedCredentials = stored
        return stored
    }

    /// The persisted session — unless the user has signed out this run, in which
    /// case there is none as far as this app is concerned, whatever the Keychain
    /// still holds. The one place the store is read after `init`.
    private func storedCredentials() -> LeetCodeCredentials? {
        guard !storedCredentialsAreDiscarded else { return nil }
        return credentialStore.load()
    }

    /// Record a failure, and let a rejected session change the account state as
    /// well — the rule that "any operation whose response says logged-out flips
    /// the state".
    private func publish(_ error: LeetCodeError) {
        lastError = error
        if error == .notLoggedIn { markSessionRejected() }
    }

    /// LeetCode has told us this session is not signed in.
    ///
    /// The published state flips, but the **stored credentials stay**: a 403 from
    /// an unofficial endpoint is as often a throttle in disguise as a dead
    /// session, and clearing the Keychain on one would turn a transient failure
    /// into a mandatory re-login through a web view. Signing out is the explicit
    /// act that forgets them.
    private func markSessionRejected() {
        isSignedIn = false
        signedInUsername = nil
    }

    /// Adopt a freshly fetched detail as the published statement, and cache it.
    ///
    /// Bumps the statement generation so a refresh that was already in flight for
    /// some other tab cannot land on top of it.
    private func adoptStatement(from detail: LeetCodeProblemDetail) {
        guard !detail.content.isEmpty else { return }
        statementGeneration += 1
        let title = detail.title.isEmpty ? detail.slug : detail.title
        statementCache.store(detail.content, forSlug: detail.slug)
        slugsFetchedThisRun.insert(detail.slug)
        // Remembered here and not only published, because the next refresh for
        // this slug is answered from the fragment cache, which holds no title.
        titlesBySlug[detail.slug] = title
        statement = LeetCodeStatement(
            slug: detail.slug,
            number: detail.frontendID,
            title: title,
            fragment: detail.content,
            isFromCache: false
        )
    }

    /// The file the folder already holds under this name, or `nil` when it holds
    /// none.
    ///
    /// Asked as a **directory listing** rather than as a read: a read that failed
    /// for any reason other than absence — an unreadable file, a decoding failure
    /// on something that is not text — would read as "not there" and the next step
    /// would overwrite it. A listing distinguishes the two, and the folder holds a
    /// few dozen files.
    ///
    /// **A listing that fails throws rather than answering "absent"**, which is
    /// the same argument one step further out: a folder that is searchable but
    /// not readable would otherwise take the identical path a read failure would
    /// have, and destroy a half-finished solution. The caller has already made
    /// sure the directory exists, so a failure here is a real one and
    /// `fileSystem` says so — refusing to write is the only answer that keeps
    /// "never overwrite" true when we cannot see what is there.
    ///
    /// **The comparison is case-insensitive, and the answer is the name on disk.**
    /// APFS and HFS+ are case-insensitive by default, so a user who renamed
    /// `0001-two-sum.swift` to `0001-Two-Sum.swift` and kept working in it would,
    /// under an exact comparison, be told the file is absent — and the write that
    /// followed would land on that very file and delete their solution, the one
    /// loss this layer exists to make impossible. Returning the entry's *own* URL
    /// rather than the composed one is what makes this correct on a case-sensitive
    /// volume too: the tab that opens is the file that was found, not a name that
    /// exists nowhere.
    private func existingFile(named name: String, in folder: URL) throws -> URL? {
        let entries: [DirectoryEntry]
        do {
            entries = try fileService.contentsOfDirectory(at: folder)
        } catch {
            throw LeetCodeError.fileSystem(reason: describe(error))
        }
        return entries.first {
            !$0.isDirectory
                && $0.url.lastPathComponent.caseInsensitiveCompare(name) == .orderedSame
        }?.url
    }

    /// Everything in flight is now answering a question nobody asked any more.
    private func invalidateInFlightWork() {
        openGeneration += 1
        statementGeneration += 1
    }

    private func beginWork() {
        busyCount += 1
        if !isBusy { isBusy = true }
    }

    private func endWork() {
        busyCount = max(0, busyCount - 1)
        if busyCount == 0, isBusy { isBusy = false }
    }

    private func beginOpen() {
        openCount += 1
        if !isOpening { isOpening = true }
    }

    private func endOpen() {
        openCount = max(0, openCount - 1)
        if openCount == 0, isOpening { isOpening = false }
    }

    /// A sentence for an arbitrary error, preferring a `LocalizedError`'s own —
    /// `localizedDescription` on a bare Swift error is the useless "operation
    /// couldn't be completed" string.
    private func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
