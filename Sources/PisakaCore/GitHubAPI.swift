import Foundation

/// Everything this app knows about `gh`'s output schema, in one file (G2).
///
/// `LeetCodeAPI`'s rule applied to a second integration, for a different reason.
/// LeetCode publishes no contract, so concentration was damage control; `gh`
/// publishes one, and concentration here buys something else: a `--json` field
/// list and the parser that reads it live in two adjacent files that cannot drift
/// apart, because `GitHubCommands` owns the ordered field constants and this file
/// is their only reader. Ask for a field nobody parses and it is visible in one
/// diff; parse a field nobody asked for and the fixture suite fails.
///
/// Three rules the file keeps, and all three are the reason it is one file:
///
/// - **Nothing shrugs.** A missing key, a value outside a closed table, a number
///   where a string belongs — every one of them throws `GitHubSchemaError`
///   carrying the *key path* that did not match, so a bug report names the line
///   here to edit. A parser that returned an empty list instead would make "this
///   repository has no open pull requests" and "GitHub changed `pr list`"
///   indistinguishable, forever.
/// - **The exit status is not consulted, ever.** Not by anything in this file.
///   `gh pr checks` documents exit 8 for "checks pending" and uses exit 1 for
///   "some check failed", both of which are *answers*; that command is judged on
///   its stdout parsing succeeding and on nothing else (G3). Keeping the status
///   out of the schema file is what makes that rule impossible to forget at one
///   of the call sites.
/// - **No `owner/repo` is ever composed.** ``GitHubRepository/nameWithOwner`` is
///   read out of `gh repo view` and never built from a remote URL, which is the
///   other half of the decision that lets a GitHub Enterprise checkout work
///   without this app learning a host (G6).
public enum GitHubAPI {

    // MARK: - Key-path roots
    //
    // The prefix each error's key path is reported under. They name the *command*
    // rather than the type, because that is what somebody diagnosing a failure has
    // to re-run to see the shape for themselves.

    private static let listRoot = "pr list"
    private static let checksRoot = "pr checks"
    private static let repositoryRoot = "repo view"

    // MARK: - `pr list`

    /// Parse `gh pr list --json …`'s output into rows for the panel.
    ///
    /// The rollup is collapsed to a ``GitHubChecksSummary`` here and the array
    /// dropped; see ``GitHubPullRequest`` for why the raw entries are not carried.
    ///
    /// An **empty array is a valid answer**, not a failure: it is what a branch
    /// with no pull request answers under `--head`, and what a repository with
    /// nothing open answers under `--state open`. The distinction between that and
    /// a schema change is exactly what the throwing half of this function protects.
    public static func pullRequests(fromListJSON output: String) throws -> [GitHubPullRequest] {
        let rows = try array(output, keyPath: listRoot)
        return try rows.enumerated().map { index, element in
            let path = "\(listRoot)[\(index)]"
            let row = try object(element, at: path)
            let author = try object(try value(row, "author", at: path), at: "\(path).author")
            return GitHubPullRequest(
                number: try int(row, "number", at: path),
                title: try string(row, "title", at: path),
                authorLogin: try string(author, "login", at: "\(path).author"),
                headRefName: try string(row, "headRefName", at: path),
                baseRefName: try string(row, "baseRefName", at: path),
                isDraft: try bool(row, "isDraft", at: path),
                reviewDecision: try table(
                    GitHubReviewDecision.self,
                    try string(row, "reviewDecision", at: path),
                    at: "\(path).reviewDecision"
                ),
                url: try string(row, "url", at: path),
                state: try string(row, "state", at: path),
                summary: GitHubChecksSummary.summarise(try rollup(row, at: path))
            )
        }
    }

    /// The `statusCheckRollup` of one row, in the shape each entry's `__typename`
    /// gave it.
    ///
    /// A `null` rollup reads as *no entries* rather than as a violation: GraphQL
    /// answers `null` for a commit that has no rollup at all, which is the same
    /// fact `[]` states — and both become ``GitHubChecksSummary/noChecks``, a
    /// state of its own, so nothing is being quietly rounded to "success" here.
    private static func rollup(_ row: [String: Any], at path: String) throws -> [GitHubRollupItem] {
        let keyPath = "\(path).statusCheckRollup"
        guard let raw = row["statusCheckRollup"], !(raw is NSNull) else { return [] }
        guard let entries = raw as? [Any] else { throw GitHubSchemaError.malformed(keyPath: keyPath) }
        return try entries.enumerated().map { index, element in
            let itemPath = "\(keyPath)[\(index)]"
            let item = try object(element, at: itemPath)
            let typeName = try string(item, "__typename", at: itemPath)
            switch typeName {
            case "CheckRun":
                let conclusionText = try string(item, "conclusion", at: itemPath)
                return .checkRun(
                    status: try table(GitHubCheckStatus.self, try string(item, "status", at: itemPath), at: "\(itemPath).status"),
                    conclusion: conclusionText.isEmpty
                        ? nil
                        : try table(GitHubCheckConclusion.self, conclusionText, at: "\(itemPath).conclusion")
                )
            case "StatusContext":
                return .statusContext(
                    state: try table(GitHubStatusContextState.self, try string(item, "state", at: itemPath), at: "\(itemPath).state")
                )
            default:
                throw GitHubSchemaError.unknownValue(keyPath: "\(itemPath).__typename", value: typeName)
            }
        }
    }

    // MARK: - `pr checks`

    /// Parse `gh pr checks <n> --json …`'s output into the expanded row's job
    /// list.
    ///
    /// Called on the output of a command whose exit status was **not** looked at
    /// (G3). A pull request whose checks are still running exits 8 and prints a
    /// perfectly good array; one with a failing job exits 1 and does the same.
    public static func checkRows(fromChecksJSON output: String) throws -> [GitHubCheckRow] {
        let rows = try array(output, keyPath: checksRoot)
        return try rows.enumerated().map { index, element in
            let path = "\(checksRoot)[\(index)]"
            let row = try object(element, at: path)
            return GitHubCheckRow(
                name: try string(row, "name", at: path),
                workflow: try string(row, "workflow", at: path),
                bucket: try table(GitHubCheckBucket.self, try string(row, "bucket", at: path), at: "\(path).bucket"),
                state: try string(row, "state", at: path),
                description: try string(row, "description", at: path),
                link: try string(row, "link", at: path),
                startedAt: try timestamp(row, "startedAt", at: path),
                completedAt: try timestamp(row, "completedAt", at: path)
            )
        }
    }

    // MARK: - `repo view`

    /// Parse `gh repo view --json defaultBranchRef,nameWithOwner`.
    ///
    /// `defaultBranchRef: null` — a repository with no commits — is refused as a
    /// missing key rather than yielding an empty branch name: the sheet's whole
    /// base default comes from this answer, and an empty base silently passed to
    /// `pr create` would be a different pull request from the one the sentence
    /// promised. The create sheet's stated behaviour on a failure here is an empty
    /// picker with Create disabled, which is what a throw produces.
    public static func repository(fromViewJSON output: String) throws -> GitHubRepository {
        let root = try object(try json(output, keyPath: repositoryRoot), at: repositoryRoot)
        let refPath = "\(repositoryRoot).defaultBranchRef"
        let ref = try object(try value(root, "defaultBranchRef", at: repositoryRoot), at: refPath)
        return GitHubRepository(
            nameWithOwner: try string(root, "nameWithOwner", at: repositoryRoot),
            defaultBranch: try string(ref, "name", at: refPath)
        )
    }

    // MARK: - `pr create`

    /// The pull request number `gh pr create` printed, read out of the URL it
    /// printed it in.
    ///
    /// `gh pr create` has no `--json`: its whole answer is the new pull request's
    /// web URL on stdout, sometimes preceded by informational lines (a
    /// "Creating pull request for … into … " notice, a warning about an
    /// unconfigured remote). The **last** `…/pull/<n>` in the output is the
    /// answer, since the informational prose names branches rather than URLs.
    ///
    /// Returns `nil` rather than throwing, and this is the one place in the file
    /// that does not treat an unreadable answer as a schema violation: by the time
    /// this is called the pull request **exists**. Refusing here would report a
    /// failure for an operation that succeeded, and the refresh that follows will
    /// list the new row regardless — the number only decides whether it can be
    /// pre-selected.
    public static func pullRequestNumber(fromCreateOutput output: String) -> Int? {
        var found: Int?
        for line in output.components(separatedBy: .newlines) {
            var remainder = Substring(line)
            while let marker = remainder.range(of: "/pull/") {
                let digits = remainder[marker.upperBound...].prefix(while: \.isNumber)
                if !digits.isEmpty, let number = Int(digits) { found = number }
                remainder = remainder[marker.upperBound...]
            }
        }
        return found
    }

    // MARK: - JSON access
    //
    // Every accessor takes the key path it is reading under and reports it on
    // failure. Passing the path rather than reconstructing it means the string in
    // the error is the string somebody can paste after `--jq`.

    private static func json(_ output: String, keyPath: String) throws -> Any {
        guard let data = output.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) else {
            throw GitHubSchemaError.malformed(keyPath: keyPath)
        }
        return parsed
    }

    private static func array(_ output: String, keyPath: String) throws -> [Any] {
        guard let rows = try json(output, keyPath: keyPath) as? [Any] else {
            throw GitHubSchemaError.malformed(keyPath: keyPath)
        }
        return rows
    }

    private static func object(_ any: Any, at keyPath: String) throws -> [String: Any] {
        guard let object = any as? [String: Any] else { throw GitHubSchemaError.malformed(keyPath: keyPath) }
        return object
    }

    private static func value(_ object: [String: Any], _ key: String, at path: String) throws -> Any {
        guard let raw = object[key], !(raw is NSNull) else {
            throw GitHubSchemaError.missingKey(keyPath: "\(path).\(key)")
        }
        return raw
    }

    private static func string(_ object: [String: Any], _ key: String, at path: String) throws -> String {
        guard let text = try value(object, key, at: path) as? String else {
            throw GitHubSchemaError.malformed(keyPath: "\(path).\(key)")
        }
        return text
    }

    private static func int(_ object: [String: Any], _ key: String, at path: String) throws -> Int {
        guard let number = try value(object, key, at: path) as? Int else {
            throw GitHubSchemaError.malformed(keyPath: "\(path).\(key)")
        }
        return number
    }

    private static func bool(_ object: [String: Any], _ key: String, at path: String) throws -> Bool {
        guard let flag = try value(object, key, at: path) as? Bool else {
            throw GitHubSchemaError.malformed(keyPath: "\(path).\(key)")
        }
        return flag
    }

    /// One closed table's lookup, and the only place `unknownValue` is thrown.
    private static func table<T: RawRepresentable>(
        _ type: T.Type,
        _ raw: String,
        at keyPath: String
    ) throws -> T where T.RawValue == String {
        guard let value = T(rawValue: raw) else {
            throw GitHubSchemaError.unknownValue(keyPath: keyPath, value: raw)
        }
        return value
    }

    /// An RFC 3339 timestamp, or `nil` for the two ways `gh` says "not yet".
    ///
    /// Those two are an empty string and `0001-01-01T00:00:00Z` — Go's zero
    /// `time.Time`, which `gh` marshals verbatim for a job that has not started or
    /// not finished. Parsed as a *sentinel* rather than as a date in the year 1,
    /// because a panel that renders "started 2 025 years ago" is worse than one
    /// that renders nothing. Anything else that will not parse throws, so a real
    /// format change is loud.
    private static func timestamp(_ object: [String: Any], _ key: String, at path: String) throws -> Date? {
        let keyPath = "\(path).\(key)"
        guard let raw = object[key], !(raw is NSNull) else { return nil }
        guard let text = raw as? String else { throw GitHubSchemaError.malformed(keyPath: keyPath) }
        if text.isEmpty || text.hasPrefix(zeroTimePrefix) { return nil }
        if let date = internetDate.date(from: text) { return date }
        if let date = fractionalInternetDate.date(from: text) { return date }
        throw GitHubSchemaError.malformed(keyPath: keyPath)
    }

    /// Go's zero `time.Time` as `gh` marshals it.
    private static let zeroTimePrefix = "0001-01-01T00:00:00"

    private static let internetDate: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let fractionalInternetDate: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

// MARK: - The summary rule

extension GitHubChecksSummary {
    /// Collapse a pull request's whole rollup into the one state the panel row and
    /// the bottom-bar indicator both draw.
    ///
    /// The rule, in the order it is applied — the order *is* the rule:
    ///
    /// 1. **`noChecks`** when the rollup is empty. Its own state, never `success`.
    /// 2. **`pending`** when any entry has not finished. Unfinished outranks a
    ///    failure that is already in: a rollup with one failed job and one still
    ///    running has not decided anything yet, and calling it `failure` would put
    ///    a red badge on a pull request whose remaining job may be the one that
    ///    matters. GitHub's own rollup badge makes the same call.
    /// 3. **`failure`** when any finished entry did not pass — failed, errored,
    ///    was cancelled, timed out, went stale or wants action. The conservative
    ///    direction, for the reason on
    ///    ``GitHubCheckConclusion/isPassing``.
    /// 4. **`success`** otherwise: every entry finished and every one of them
    ///    passed, was neutral or was skipped.
    ///
    /// A `StatusContext` contributes through its `state`, a `CheckRun` through
    /// `status` **and** `conclusion`, and a mixed array is decided over both
    /// tables at once — which is the whole reason ``GitHubRollupItem`` keeps the
    /// two kinds apart rather than flattening them on the way in.
    public static func summarise(_ rollup: [GitHubRollupItem]) -> GitHubChecksSummary {
        if rollup.isEmpty { return .noChecks }
        if rollup.contains(where: { !$0.isFinished }) { return .pending }
        if rollup.contains(where: { !$0.isPassing }) { return .failure }
        return .success
    }
}

// MARK: - The schema error

/// The three ways `gh`'s output can fail to be the shape this app knows.
///
/// Every case carries the **key path** that did not match, in the spelling the
/// command itself uses (`pr list[0].author.login`), for the same reason
/// `LeetCodeError.apiChanged` carries one: with a parser this strict, that string
/// is the entire diagnosis, and it names the line of `GitHubAPI` to edit.
///
/// Lives in Core with its sentences so every message the user reads is
/// unit-testable, the way `GitError`, `LeetCodeError` and `GitHubCLIError`
/// already are — the model surfaces `errorDescription` directly.
public enum GitHubSchemaError: Error, Equatable, Sendable {
    /// A key the parser requires was absent, or explicitly `null`.
    case missingKey(keyPath: String)
    /// A key was present with a value of the wrong kind — a number where a string
    /// belongs, an object where an array does, or output that is not JSON at all
    /// (reported against the command's own root).
    case malformed(keyPath: String)
    /// A value outside one of the closed tables. `value` is what arrived, so the
    /// fix — a new case, or a deliberate refusal — can be made without re-running
    /// anything.
    case unknownValue(keyPath: String, value: String)

    /// The key path the failure is reported against, whichever case it is.
    public var keyPath: String {
        switch self {
        case .missingKey(let keyPath), .malformed(let keyPath): return keyPath
        case .unknownValue(let keyPath, _): return keyPath
        }
    }
}

extension GitHubSchemaError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingKey(let keyPath):
            return "The GitHub CLI answered without “\(keyPath)”."
        case .malformed(let keyPath):
            return "The GitHub CLI answered with an unreadable “\(keyPath)”."
        case .unknownValue(let keyPath, let value):
            return "The GitHub CLI answered “\(keyPath)” with “\(value)”, which Pisaka does not know."
        }
    }
}
