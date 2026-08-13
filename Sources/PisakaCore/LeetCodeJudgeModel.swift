import Foundation

/// Whether Run and Submit can be offered for the file on screen — and, when they
/// cannot, the sentence that says why.
///
/// A **pure, synchronous decision** with a case per refusal, rather than a
/// `Bool`. The point is that a disabled button always has something to say: every
/// case below carries the sentence the surface shows beside it, so "a dead
/// control with no explanation" is not a state this layer can reach. It is
/// resolved from the file name, the extension and the session — nothing that
/// needs a request — so it is answered the instant a tab becomes active and is
/// unit-tested as a table.
public enum LeetCodeJudgeAvailability: Equatable, Sendable {
    /// Run and Submit are offered, in this language.
    case ready(LeetCodeLanguage)
    /// The active tab is not a LeetCode solution file — it sits outside the
    /// configured folder, its name does not carry a problem, or LeetCode does not
    /// know the problem the name claims (the association rule is deliberately
    /// permissive: a `2024-notes.md` in the folder parses as problem 2024).
    case notASolutionFile
    /// The file *is* one of ours, but its extension names no language this app
    /// can submit under. Carries the extension so the sentence can name it.
    case unsupportedLanguage(String)
    /// There is no session, and every judge call requires one.
    case notSignedIn
    /// A run or a submission is already in flight.
    case busy

    /// The language a judge call would be made under, for the one case that has
    /// one.
    public var language: LeetCodeLanguage? {
        if case .ready(let language) = self { return language }
        return nil
    }

    /// Whether the two buttons are enabled.
    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    /// Why they are not, or `nil` when they are.
    public var reason: String? {
        switch self {
        case .ready:
            return nil
        case .notASolutionFile:
            return "Open a LeetCode solution file to run and submit."
        case .unsupportedLanguage(let fileExtension):
            let trimmed = fileExtension.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty
                ? "LeetCode does not accept files of this type."
                : "LeetCode does not accept “.\(trimmed)” files."
        case .notSignedIn:
            return "Sign in to LeetCode to run and submit solutions."
        case .busy:
            return "A LeetCode run is already in progress."
        }
    }
}

/// How far along the judge is.
///
/// Two cases and no third: there is no "finished" phase, because what finished
/// *is* the published result. A phase that also carried the outcome would be a
/// second place for it to live, and the two would eventually disagree.
public enum LeetCodeJudgePhase: Equatable, Sendable {
    case idle
    case running(LeetCodeJudgeKind)

    public var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    /// What is running, or `nil`.
    public var kind: LeetCodeJudgeKind? {
        if case .running(let kind) = self { return kind }
        return nil
    }
}

/// Run and Submit: the editable input, the POST, the poll, and the verdict.
///
/// **A companion model, owned by `LeetCodeModel` the way `catalog` is.** Two
/// reasons, both structural. `LeetCodeModel` is already the largest file in this
/// area and this adds a whole second state machine to it; and the judge surfaces
/// observe *this* object rather than the owner, so a keystroke in the test-case
/// box invalidates a section of one pane instead of every surface bound to the
/// account and the statement.
///
/// The back-reference to the owner is `unowned` and deliberately not a protocol
/// seam: what the judge needs — the session, the question-id memo, and the
/// session-rejected/accepted transitions — is `LeetCodeModel`'s and nothing
/// else's, this object is reachable only through its owner, and the suites drive
/// it through a real model over the scripted transport. A host protocol would be
/// a fourth abstraction standing in for one the tests already build.
///
/// **The fourth generation token.** Opening, the statement and the account each
/// have one; this is the judge's, and it obeys the same rule as the other three —
/// captured synchronously before the first `await`, checked after every
/// suspension, and a poll that comes back to find it moved publishes *nothing at
/// all*. It is bumped by a new run, by `cancel()`, and by a sign-in or sign-out
/// (through the owner's `invalidateInFlightWork()`), because a session change
/// invalidates a poll in flight as surely as it invalidates a fetch.
///
/// **A reader.** Like the symbol index and the LSP client, this layer never
/// raises `autosave.suspend()`/`beginRevert()` and is never gated by them: it
/// reads the live editor buffer, sends it to LeetCode, and writes nothing
/// anywhere — not the solution file, not the caches, not the worktree.
@MainActor
public final class LeetCodeJudgeModel: ObservableObject {

    // MARK: - Budgets

    /// How long a judge call may take before it is abandoned, per kind.
    ///
    /// **Budgets as data**, the `LSPSession.Budgets` shape: they are a value with
    /// a default, injectable in a test, and enforced against a deadline rather
    /// than an attempt count — so a slow network cannot silently double the wait
    /// by making each poll take longer. Submit gets twice Run's because it queues
    /// behind LeetCode's own judge on the full suite; both are generous enough
    /// that reaching one means something is wrong rather than merely slow.
    public struct Budgets: Equatable, Sendable {
        public var run: TimeInterval
        public var submit: TimeInterval

        public init(run: TimeInterval = 30, submit: TimeInterval = 60) {
            self.run = run
            self.submit = submit
        }

        public func seconds(for kind: LeetCodeJudgeKind) -> TimeInterval {
            switch kind {
            case .run: return run
            case .submit: return submit
            }
        }
    }

    // MARK: - Published state

    /// Whether a run or a submission is in flight, and which.
    @Published public private(set) var phase: LeetCodeJudgePhase = .idle

    /// The editable test-case box, prefilled from the problem's own examples.
    ///
    /// **Session state, and only that**: it is never written to disk, never
    /// carried across launches, and reset when the problem changes. Run sends it
    /// verbatim; Submit ignores it entirely (LeetCode's own suite is what a
    /// submission is judged against, and a `data_input` on that endpoint would be
    /// either ignored or, worse, honoured).
    @Published public var testInput: String = ""

    /// What the last finished Run answered, or `nil` when none has finished for
    /// this problem.
    @Published public private(set) var lastRun: LeetCodeRunResult?

    /// What the last finished Submit answered.
    @Published public private(set) var lastSubmit: LeetCodeSubmitResult?

    /// The last failure, cleared when a new attempt starts. A superseded or
    /// cancelled attempt sets nothing here — it publishes nothing at all.
    @Published public private(set) var lastError: LeetCodeError?

    /// Whether the buttons are offered, and what the surface says when they are
    /// not. Recomputed whenever the file, the session or the phase changes.
    @Published public private(set) var availability: LeetCodeJudgeAvailability = .notASolutionFile

    // MARK: - Seams

    /// The budgets this model enforces. A `var` rather than an init parameter so
    /// the owner can construct the judge with nothing but itself; the suites set
    /// it before driving a flow.
    public var budgets = Budgets()

    /// How long the poll waits between checks. LeetCode's own page polls about
    /// this often, and a shorter interval on an unofficial API is exactly the
    /// kind of thing that gets rate-limited.
    public var pollInterval: TimeInterval = 1

    /// The clock the deadline is measured against.
    public var now: () -> Date = Date.init

    /// The wait between polls, as a seam.
    ///
    /// Injectable so the whole state machine — including budget exhaustion, which
    /// is thirty sleeps deep — runs deterministically in `swift test` and adds no
    /// wall-clock time to it. The default swallows the cancellation error rather
    /// than propagating it: the loop's own `Task.isCancelled` check is the one
    /// place cancellation is handled, so there is exactly one rule for it.
    public var sleep: (TimeInterval) async -> Void = { seconds in
        guard seconds > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// The editor, for the one thing the judge reads out of it: the text of the
    /// file being judged.
    ///
    /// **Weak, and deliberately not observed.** The judge is what the views bind
    /// to, and an observed workspace would re-render the judge section on every
    /// keystroke in the editor — the same reason `ContentView` holds
    /// `commitDialog` unobserved. The buffer is read once, synchronously, at the
    /// moment a button is pressed.
    public weak var workspace: WorkspaceModel?

    // MARK: - Private state

    private unowned let owner: LeetCodeModel

    /// The fourth generation token. See the type's note.
    private var generation = 0

    /// The file the surface is currently prepared for, and the problem its name
    /// carries.
    private var preparedURL: URL?
    private var preparedSlug: String?

    /// LeetCode's answer that it does not know `preparedSlug` — which makes this
    /// file, as far as the judge is concerned, not a solution file at all.
    private var problemIsUnknown = false

    /// The question id and examples for the prepared problem, once resolved.
    /// `nil` means "not resolved yet", not "there is none".
    private var context: LeetCodeJudgeContext?

    public init(owner: LeetCodeModel) {
        self.owner = owner
    }

    // MARK: - The availability table

    /// Whether the judge can be offered, from the four facts that decide it.
    ///
    /// Pure and static so it is a table in a test rather than a sequence of model
    /// states. The order is the interesting part, and it goes from the most
    /// permanent fact to the most transient: what the *file* is cannot be fixed by
    /// signing in or waiting, so it is said first; the session comes next because
    /// it is fixed by one action; `busy` is last because it resolves itself in
    /// seconds. Reporting "a run is already in progress" for a Markdown file would
    /// be true and useless.
    ///
    /// - Parameters:
    ///   - problemSlug: the problem this file belongs to, or `nil` when it belongs
    ///     to none — including when LeetCode does not know the one its name names.
    ///   - fileExtension: the file's extension, without the dot.
    ///   - isSignedIn: whether the owner believes it has a session.
    ///   - isRunning: whether a judge call is already in flight.
    public static func availability(
        problemSlug: String?,
        fileExtension: String,
        isSignedIn: Bool,
        isRunning: Bool
    ) -> LeetCodeJudgeAvailability {
        guard problemSlug != nil else { return .notASolutionFile }
        guard let language = LeetCodeSolutionFile.language(forFileExtension: fileExtension) else {
            return .unsupportedLanguage(fileExtension)
        }
        guard isSignedIn else { return .notSignedIn }
        if isRunning { return .busy }
        return .ready(language)
    }

    // MARK: - Preparing a surface

    /// Point the judge at the active tab: resolve availability, resolve the
    /// problem's judge context, and prefill the test-case box.
    ///
    /// Driven by the view's `.task(id:)` on the same tab-and-folder key the
    /// statement pane uses, which is the LC-1 pattern. Two rules follow from
    /// that:
    ///
    /// - **Re-preparing the same file changes nothing.** The key fires again on
    ///   every re-render of the host view, and a prepare that reset the box would
    ///   throw away what the user typed into it — and cancel a poll in flight —
    ///   for no reason at all.
    /// - **A different file is a different problem.** The box, both results and
    ///   the last error are reset, and a poll still running for the previous
    ///   problem is superseded: its verdict has nowhere to go, since the surface
    ///   is now showing something else.
    ///
    /// The context comes from the owner's memo, which every detail fetch already
    /// warms; a slug this run has never fetched costs exactly one request here,
    /// and the answer "LeetCode does not know this problem" is a value that
    /// degrades availability to `.notASolutionFile` rather than an error.
    public func prepare(forFileAt url: URL?, in folder: URL?) async {
        if isPrepared(forFileAt: url) {
            refreshAvailability()
            return
        }

        generation += 1
        let generation = self.generation
        preparedURL = url
        preparedSlug = url.flatMap { file in
            folder.flatMap { owner.associatedProblem(forFileAt: file, in: $0)?.slug }
        }
        problemIsUnknown = false
        context = nil
        testInput = ""
        lastRun = nil
        lastSubmit = nil
        lastError = nil
        phase = .idle
        refreshAvailability()

        // Signed out, not one of ours, or a language LeetCode will not take: there
        // is nothing to resolve, and asking anyway would spend a request on a
        // surface whose buttons are disabled.
        guard availability.isReady, let slug = preparedSlug else { return }
        do {
            let resolved = try await owner.judgeContext(forSlug: slug)
            guard generation == self.generation, !Task.isCancelled else { return }
            guard let resolved else {
                problemIsUnknown = true
                refreshAvailability()
                return
            }
            context = resolved
            // LeetCode's own convention: the cases are one after another, newline
            // separated, exactly as they arrive in `data_input`.
            testInput = resolved.exampleTestCases.joined(separator: "\n")
        } catch let error as LeetCodeError {
            guard generation == self.generation, !Task.isCancelled else { return }
            // A rejected session is worth acting on even here — it changes what
            // every other surface says.
            publish(error)
        } catch {
            // The owner folds everything else into a `LeetCodeError` already; this
            // branch exists so a decorator that does not cannot escape the
            // vocabulary.
            guard generation == self.generation, !Task.isCancelled else { return }
            publish(.network(reason: error.localizedDescription))
        }
    }

    /// Whether `url` is the file this surface is already prepared for. Compared
    /// canonically, like every other "same file?" question in this app.
    private func isPrepared(forFileAt url: URL?) -> Bool {
        switch (url, preparedURL) {
        case (nil, nil):
            return true
        case (let new?, let old?):
            return CanonicalPath.canonical(new) == CanonicalPath.canonical(old)
        default:
            return false
        }
    }

    // MARK: - Running and submitting

    /// Run the buffer against the test-case box.
    public func run() async {
        await start(kind: .run)
    }

    /// Submit the buffer against LeetCode's full suite. The test-case box is
    /// ignored.
    public func submit() async {
        await start(kind: .submit)
    }

    /// Abandon whatever is in flight without publishing anything.
    ///
    /// What leaving the surface or closing the tab does. The submission itself is
    /// **not** undone — LeetCode has it and its result is on the site — which is
    /// the same statement `judgeTimedOut` makes and the reason neither of them
    /// pretends otherwise.
    public func cancel() {
        generation += 1
        phase = .idle
        refreshAvailability()
    }

    /// The one flow both buttons share.
    ///
    /// **A second press supersedes rather than being refused.** `availability`
    /// reports `.busy` so the button can disable itself, but the model's own
    /// readiness check deliberately ignores that: pressing Run again is a
    /// restart, and the first attempt — whose generation has just moved — then
    /// publishes nothing at all.
    private func start(kind: LeetCodeJudgeKind) async {
        let readiness = Self.availability(
            problemSlug: problemIsUnknown ? nil : preparedSlug,
            fileExtension: preparedURL?.pathExtension ?? "",
            isSignedIn: owner.isSignedIn,
            isRunning: false
        )
        guard case .ready(let language) = readiness, let url = preparedURL,
              let slug = preparedSlug
        else {
            // The buttons are disabled in exactly this state, so this is a
            // belt-and-braces refusal — stated rather than silent, because a
            // button that does nothing is the one outcome this area does not
            // allow.
            lastError = .judgeUnavailable(reason: readiness.reason ?? "")
            return
        }
        // The **live buffer**, read synchronously and before anything suspends:
        // the user must not have to save first, and what they see is what is
        // judged.
        guard let code = liveSource(forFileAt: url) else {
            lastError = .judgeUnavailable(
                reason: "Open this solution file in the editor before running it."
            )
            return
        }
        let input = testInput

        generation += 1
        let generation = self.generation
        let budget = budgets.seconds(for: kind)
        let deadline = now().addingTimeInterval(budget)
        phase = .running(kind)
        lastError = nil
        switch kind {
        case .run: lastRun = nil
        case .submit: lastSubmit = nil
        }
        refreshAvailability()

        var check: LeetCodeJudgeCheck?
        var failure: LeetCodeError?
        do {
            check = try await perform(
                kind: kind,
                slug: slug,
                language: language,
                code: code,
                input: input,
                budget: budget,
                deadline: deadline,
                generation: generation
            )
        } catch let error as LeetCodeError {
            failure = error
        } catch {
            failure = .network(reason: error.localizedDescription)
        }

        // Superseded: a newer attempt, a cancel, or a session change owns the
        // published state now, *including* the phase — touching it here would
        // switch off a spinner the newer attempt turned on.
        guard generation == self.generation else { return }
        // Cancelled from the outside (the view's task went away mid-flight):
        // `URLSession` reports that as an error, and it is not one the user asked
        // about. The phase is still cleared — nobody else will.
        if !Task.isCancelled {
            if let failure { publish(failure) }
            if let check { adopt(check) }
        }
        phase = .idle
        refreshAvailability()
    }

    /// POST, take the id, then poll until the judge says something terminal.
    ///
    /// - Returns: the terminal check, or `nil` when this attempt was superseded or
    ///   cancelled mid-flight — in which case the caller publishes nothing.
    private func perform(
        kind: LeetCodeJudgeKind,
        slug: String,
        language: LeetCodeLanguage,
        code: String,
        input: String,
        budget: TimeInterval,
        deadline: Date,
        generation: Int
    ) async throws -> LeetCodeJudgeCheck? {
        let credentials = try owner.requireCredentials()
        let context = try await resolvedContext(forSlug: slug)
        guard generation == self.generation, !Task.isCancelled else { return nil }
        guard let context else {
            // Between preparing the surface and pressing the button, LeetCode
            // answered that it does not know this problem. A stated refusal, not
            // a schema change — see `LeetCodeModel.judgeContext(forSlug:)`.
            problemIsUnknown = true
            throw LeetCodeError.judgeUnavailable(
                reason: LeetCodeJudgeAvailability.notASolutionFile.reason ?? ""
            )
        }

        let request: LeetCodeHTTPRequest
        switch kind {
        case .run:
            request = LeetCodeAPI.interpretRequest(
                slug: slug,
                questionID: context.questionID,
                langSlug: language.langSlug,
                code: code,
                input: input,
                credentials: credentials
            )
        case .submit:
            request = LeetCodeAPI.submitRequest(
                slug: slug,
                questionID: context.questionID,
                langSlug: language.langSlug,
                code: code,
                credentials: credentials
            )
        }

        let started = try await owner.send(request)
        guard generation == self.generation, !Task.isCancelled else { return nil }
        let id: String
        switch kind {
        case .run: id = try LeetCodeAPI.parseInterpretID(started)
        case .submit: id = try LeetCodeAPI.parseSubmissionID(started)
        }
        owner.markSessionAccepted()

        let poll = LeetCodeAPI.checkRequest(id: id, slug: slug, credentials: credentials)
        while true {
            let response = try await owner.send(poll)
            guard generation == self.generation, !Task.isCancelled else { return nil }
            let check = try LeetCodeAPI.parseJudgeCheck(response, kind: kind)
            owner.markSessionAccepted()
            if check.isTerminal { return check }
            // The deadline, not an attempt count: a network that slows down must
            // not silently double the wait the user was promised.
            guard now() < deadline else {
                throw LeetCodeError.judgeTimedOut(seconds: budget)
            }
            await sleep(pollInterval)
            guard generation == self.generation, !Task.isCancelled else { return nil }
        }
    }

    /// The prepared context, resolving it now for a surface that could not (it was
    /// signed out when it was prepared, or the memo was emptied under it).
    private func resolvedContext(forSlug slug: String) async throws -> LeetCodeJudgeContext? {
        if let context { return context }
        let resolved = try await owner.judgeContext(forSlug: slug)
        if let resolved, slug == preparedSlug { context = resolved }
        return resolved
    }

    /// The bytes that will be judged: the live buffer for `url`, whatever the
    /// disk holds, and `nil` when the editor has no buffer for it.
    ///
    /// Reading the file instead would mean a user who has not saved submits their
    /// previous attempt and is told it is wrong — the single most confusing thing
    /// this feature could do. The judge therefore never touches the disk at all.
    public func liveSource(forFileAt url: URL) -> String? {
        guard let workspace, let id = workspace.fileID(forURL: url) else { return nil }
        return workspace.text(for: id)
    }

    /// Publish a terminal check as the surface's result.
    private func adopt(_ check: LeetCodeJudgeCheck) {
        switch check {
        case .finishedRun(let result):
            lastRun = result
        case .finishedSubmit(let result):
            lastSubmit = result
        case .judgeFailed:
            // LeetCode's own judge gave up. A product refusal rather than a
            // verdict on the code, and emphatically not a schema change: LeetCode
            // documents this state by sending it.
            lastError = .judgeUnavailable(
                reason: "LeetCode’s judge did not finish this attempt. Try again."
            )
        case .pending, .started:
            // Not terminal, so `perform` never returns one.
            break
        }
    }

    /// Record a failure, letting a rejected session change the account state as
    /// well — the same rule `LeetCodeModel.publish(_:)` follows, applied on this
    /// axis: any response that says logged-out flips the state, wherever it
    /// arrives.
    private func publish(_ error: LeetCodeError) {
        lastError = error
        if error == .notLoggedIn { owner.markSessionRejected() }
    }

    // MARK: - The owner's hooks

    /// The session changed: everything in flight is answering for a session that
    /// no longer exists, and the memo the context came from has been emptied.
    ///
    /// Called from `LeetCodeModel.invalidateInFlightWork()`, so a sign-in and a
    /// sign-out bump this token with the other three.
    func invalidateInFlightWork() {
        generation += 1
        context = nil
        phase = .idle
        refreshAvailability()
    }

    /// The owner's `isSignedIn` moved, so the buttons' answer moved with it.
    ///
    /// Separate from `invalidateInFlightWork()` because the two happen at
    /// different moments: signing in bumps the token *before* the state flips, and
    /// `markSessionRejected()`/`markSessionAccepted()` flip it without any
    /// invalidation at all. Without this, signing in while looking at a solution
    /// file left the buttons disabled until the user switched tabs and back — the
    /// same stale-key problem `lastStatementRequest` exists to solve one layer up.
    func sessionDidChange() {
        refreshAvailability()
    }

    private func refreshAvailability() {
        availability = Self.availability(
            problemSlug: problemIsUnknown ? nil : preparedSlug,
            fileExtension: preparedURL?.pathExtension ?? "",
            isSignedIn: owner.isSignedIn,
            isRunning: phase.isRunning
        )
    }
}
