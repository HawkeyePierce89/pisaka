import Foundation

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
/// **Two tokens, because there are two independently re-triggerable reads.** A
/// refresh — availability, the list, the current branch's lookup — is re-asked
/// by a branch change, by the panel becoming visible and by the refresh button;
/// the per-row checks list is re-asked by expanding a row, which the reader can
/// do faster than a large pull request answers. One shared token would let a
/// finished refresh cancel a checks load that has nothing to do with it, so the
/// two are counted apart. A superseded run publishes *nothing*: not its rows,
/// not its message, not its loading flag.
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
/// schema refusal lands in `errorMessage` and leaves `pullRequests`,
/// `currentBranchPullRequest` and `checks` exactly as they were: a list that
/// failed to refresh is still the list the reader was reading, and replacing it
/// with emptiness would destroy the only context the message has. The one
/// deliberate exception is availability going *not ready* — a `gh` that is gone,
/// too old or signed out is not a failed read but a different state of the
/// world, in which the panel draws no rows at all, so rows left standing under
/// "sign in to GitHub" would be a lie the sentence does not correct.
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
/// **A reader.** Nothing in this file writes to the worktree; the one write in
/// the whole feature is `pr checkout`, which arrives in a later task, runs
/// inside the app's writer bracket and is the only thing `isWriteInFlight` is
/// ever raised for.
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
    @Published public private(set) var currentBranchPullRequest: GitHubPullRequest?

    /// The per-job checks of every row that has been expanded, keyed by number.
    ///
    /// Kept across refreshes for the rows that are still open — an expanded row
    /// whose jobs vanished for a moment while the list reloaded would flicker —
    /// and dropped for the rows that are not, so a closed pull request's jobs
    /// cannot be shown under a reopened one that reused nothing but the key.
    @Published public private(set) var checks: [Int: [GitHubCheckRow]] = [:]

    /// The one expanded row, or `nil`. One at a time: the checks list is a
    /// per-row network read and the panel is a dock pane, not a page.
    @Published public private(set) var expandedNumber: Int?

    /// The one message slot — `gh`'s own words for a failed command, the schema
    /// error's sentence for output that did not parse.
    @Published public private(set) var errorMessage: String?

    /// Whether a refresh is in flight. What the panel draws its spinner from.
    @Published public private(set) var isLoading = false

    /// Whether the feature's one write — `pr checkout` — is running.
    ///
    /// Published here rather than in the coordinator because both surfaces
    /// disable on it: the panel greys New Pull Request, Checkout and refresh,
    /// and nothing else may start a second one. It is raised and lowered by the
    /// checkout flow alone; every read path leaves it untouched.
    @Published public private(set) var isWriteInFlight = false

    // MARK: - Collaborators

    private let transport: GitHubCLITransport

    /// The repository root **as it is now**.
    ///
    /// A closure rather than a stored URL, for `DatabaseConsoleModel.fileURL`'s
    /// reason: this model outlives the folder it was created under — switching
    /// projects retargets the whole window — so the directory a command runs in
    /// is asked for at the moment the command is composed. `nil` is a project
    /// root that is not there, which is a state and not a failure.
    private let projectRoot: @MainActor () -> URL?

    // MARK: - Ordering

    /// Orders refreshes against each other. Bumped in `refresh(branch:)`'s
    /// synchronous prefix.
    private var listGeneration = 0

    /// Orders checks loads against each other. Bumped in `expand(_:)`'s
    /// synchronous prefix — including when it collapses a row, so a load whose
    /// row the reader has since closed publishes nothing.
    private var checksGeneration = 0

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
    }

    /// - Parameters:
    ///   - transport: the seam. Never a `Process` — that lives in the app layer,
    ///     behind this protocol, which is what lets every rule in this file be
    ///     asserted in a target that cannot link one.
    ///   - root: where the repository is now.
    public init(transport: GitHubCLITransport, root: @escaping @MainActor () -> URL?) {
        self.transport = transport
        self.projectRoot = root
    }

    /// Whether pull requests can be listed at all — the only state the panel
    /// draws rows in and the indicator is visible under.
    public var isReady: Bool { availability?.isReady == true }

    // MARK: - The refresh

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
    /// when the panel is showing one; the version probe is always the first, so
    /// the transport re-locates `gh` exactly once per refresh (G7).
    public func refresh(branch: String?) async {
        listGeneration &+= 1
        let token = listGeneration

        guard let root = projectRoot() else {
            // No project is open, so there is no remote to resolve and nothing
            // to ask about. Not a failure and not a not-ready state: the panel
            // has no repository, which is what `availability == nil` says.
            availability = nil
            clearRows()
            clearError(from: .refresh)
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
            if let detail = probe.detail {
                setMessage(detail, from: .refresh)
            } else {
                clearError(from: .refresh)
            }
            isLoading = false
            return
        }

        var failure: String?

        do {
            let result = try await transport.run(GitHubCommands.openPullRequests(root: root))
            guard token == listGeneration else { return }
            if result.isSuccess {
                let rows = try GitHubAPI.pullRequests(fromListJSON: result.standardOutput)
                pullRequests = rows
                pruneChecks(keeping: rows)
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
                } else if failure == nil {
                    failure = Self.message(for: result)
                }
            } catch {
                guard token == listGeneration else { return }
                if failure == nil { failure = Self.message(for: error) }
            }
        } else {
            // A detached HEAD has no branch a pull request could be open from.
            currentBranchPullRequest = nil
        }

        if let failure {
            setMessage(failure, from: .refresh)
        } else {
            clearError(from: .refresh)
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
        expandedNumber = number

        guard let number, isReady, let root = projectRoot() else { return }
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
    /// Output that did not parse is read two ways, because two different things
    /// produce it. Empty stdout with something on stderr is `gh` declining to
    /// answer in JSON at all — "no checks reported on the … branch" is the
    /// common one — and that sentence is `gh`'s own, so it is shown verbatim.
    /// Stdout that *is* there and did not parse is the schema having changed,
    /// and the typed error names the key path to edit.
    private func loadChecks(number: Int, root: URL, token: Int) async {
        let result: GitHubCommandResult
        do {
            result = try await transport.run(GitHubCommands.checks(pullRequest: number, root: root))
        } catch {
            guard token == checksGeneration else { return }
            setMessage(Self.message(for: error), from: .checks)
            return
        }
        guard token == checksGeneration else { return }

        do {
            checks[number] = try GitHubAPI.checkRows(fromChecksJSON: result.standardOutput)
            clearError(from: .checks)
        } catch {
            let hasOutput = !result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if !hasOutput, !result.trimmedStandardError.isEmpty {
                setMessage(result.trimmedStandardError, from: .checks)
            } else {
                setMessage(Self.message(for: error), from: .checks)
            }
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
        pullRequests = []
        currentBranchPullRequest = nil
        checks = [:]
        expandedNumber = nil
    }

    /// Drop the cached checks of pull requests that are no longer open, and
    /// collapse the expanded row when it was one of them.
    private func pruneChecks(keeping rows: [GitHubPullRequest]) {
        let open = Set(rows.map(\.number))
        checks = checks.filter { open.contains($0.key) }
        if let expandedNumber, !open.contains(expandedNumber) { self.expandedNumber = nil }
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
