import Foundation

/// One `gh` invocation Core wants performed, described in nothing but Foundation
/// values (G1).
///
/// Deliberately *not* a `Process`. The whole point of this seam is that Core
/// composes every byte of every argument list — which subcommand, which flags,
/// which `--json` fields, in which order — so the command suite can assert them
/// byte for byte in a target that cannot link `Process`, and the app side
/// (`GitHubCLIProcessTransport`) knows nothing about what any of it means. That
/// is the same split `LSPTransport`/`LSPProcessTransport` and
/// `GitServicing`/`GitCLIService` already make, for the same reason.
///
/// The argument list never carries the executable: *which* `gh` runs is the app's
/// discovery problem and machine-specific knowledge of exactly the kind this seam
/// keeps out of Core.
public struct GitHubCommand: Equatable, Sendable {
    /// The arguments passed to `gh`, in order, excluding the executable itself.
    public var arguments: [String]

    /// The directory the command runs in — the repository root, always, because
    /// `gh` resolves `owner/repo` from the git remote of its working directory.
    ///
    /// That resolution is the reason this app never composes an `owner/repo`
    /// string anywhere (G6): a GitHub Enterprise checkout works for free, since
    /// `gh` reads its own host out of the remote the user already has.
    public var workingDirectory: URL?

    /// How long the command may run before the transport kills it, in seconds.
    ///
    /// A per-command bound rather than one global number: `pr checkout` performs
    /// network git work and `--version` does not, and a single deadline generous
    /// enough for the first would let the second hang a refresh.
    public var deadline: TimeInterval

    /// Whether running this command must make the transport re-locate the `gh`
    /// executable first.
    ///
    /// True for exactly one factory — the version probe, which is the first
    /// command of every refresh — and false for every other. It is how the
    /// transport is told to re-run its discovery without the app layer ever
    /// spelling `--version`, and it is the only thing the per-refresh location
    /// cache reads: located at most once per refresh, so a refresh costs one
    /// login-shell spawn rather than four, while a `gh` installed from the
    /// embedded terminal is still picked up by the very next refresh (G7).
    public var refreshesExecutableLocation: Bool

    public init(
        arguments: [String],
        workingDirectory: URL? = nil,
        deadline: TimeInterval,
        refreshesExecutableLocation: Bool = false
    ) {
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.deadline = deadline
        self.refreshesExecutableLocation = refreshesExecutableLocation
    }
}

/// What came back: both streams and the exit status.
///
/// All three are delivered raw. In particular the transport never interprets the
/// status — `gh auth status` writes its prose to *stderr* and is judged on the
/// status alone, while `gh pr checks` documents exit 8 for "checks pending" and
/// uses exit 1 for "some check failed", so that one command is judged on its
/// stdout parsing succeeding and never on the status (G3). Both rules live where
/// the answers are read, not here.
public struct GitHubCommandResult: Equatable, Sendable {
    /// Everything the command wrote to stdout, decoded as UTF-8.
    public var standardOutput: String
    /// Everything the command wrote to stderr, decoded as UTF-8. This is where
    /// `gh` puts its human sentences, so it is what a failure shows the user.
    public var standardError: String
    /// The process exit status.
    public var status: Int32

    public init(standardOutput: String = "", standardError: String = "", status: Int32 = 0) {
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.status = status
    }

    /// Whether the command exited zero. Correct for six of the seven commands;
    /// `pr checks` is the stated exception (G3).
    public var isSuccess: Bool { status == 0 }

    /// `standardError` with surrounding whitespace removed — the form every
    /// user-facing failure sentence in this layer uses, so `gh`'s own words are
    /// reported verbatim rather than paraphrased.
    public var trimmedStandardError: String {
        standardError.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The whole app/Core boundary of the GitHub integration: one command in, one
/// result out.
///
/// A transport never retries, never inspects a status, and never parses a byte of
/// output. The only interpretations it makes are the three that are *its*
/// knowledge and not Core's: there is no `gh` to run (`notInstalled`), the
/// process outlived its deadline (`timedOut`), or the launch itself failed
/// (`launchFailed`).
public protocol GitHubCLITransport: Sendable {
    /// Run `command` and return whatever `gh` answered.
    ///
    /// - Throws: `GitHubCLIError` — and only that — for the three failures above.
    ///   A non-zero exit is *not* a throw; it is a `GitHubCommandResult` the
    ///   caller inspects.
    func run(_ command: GitHubCommand) async throws -> GitHubCommandResult
}

/// The three ways running `gh` can fail before it has said anything.
///
/// Lives in Core rather than beside the `Process` transport so every sentence the
/// user reads is unit-testable, the way `GitError` and `LeetCodeError` already
/// are: the model surfaces `error.localizedDescription` directly.
public enum GitHubCLIError: Error, Equatable, Sendable {
    /// No `gh` executable could be found, or the cached one is gone. This is the
    /// probe answer that becomes `GitHubAvailability.notInstalled`.
    case notInstalled
    /// The command was still running when its deadline expired and was killed.
    /// `seconds` is that deadline, so the sentence can name it.
    case timedOut(seconds: TimeInterval)
    /// A `gh` was found and could not be started, or died in a way that is not a
    /// deadline. `message` carries the underlying description, which is the only
    /// thing that distinguishes a permissions problem from a broken install.
    case launchFailed(message: String)
}

extension GitHubCLIError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notInstalled:
            return GitHubAvailability.notInstalled.message
        case .timedOut(let seconds):
            let whole = Int(seconds.rounded())
            return "The GitHub CLI did not answer within \(whole) "
                + (whole == 1 ? "second." : "seconds.")
        case .launchFailed(let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty
                ? "The GitHub CLI could not be started."
                : "The GitHub CLI could not be started: \(trimmed)"
        }
    }
}

/// The environment every `gh` command runs under, as a Core value the app merges
/// over the inherited environment (G5).
///
/// `gh` is an interactive tool by default: it prompts, it paginates through a
/// pager, it colours its output with ANSI escapes and it checks for its own
/// updates. Every one of those is fatal to a command whose stdout is being
/// parsed and whose stdin is a closed pipe — a pager waits forever, a prompt
/// waits forever, and escape codes corrupt the very text a parser reads. The
/// overlay turns all four off, and `GIT_TERMINAL_PROMPT=0` does the same for the
/// `git` that `gh pr checkout` shells out to, matching what `GitCLIService`
/// already sets for its own invocations.
public enum GitHubCLIEnvironment {
    /// The variables set for every command, merged *over* whatever the app
    /// inherited so a user's own `GH_HOST` or `GH_TOKEN` survives untouched.
    public static let nonInteractive: [String: String] = [
        "GH_PROMPT_DISABLED": "1",
        "GH_NO_UPDATE_NOTIFIER": "1",
        "NO_COLOR": "1",
        "CLICOLOR": "0",
        "GH_PAGER": "cat",
        "PAGER": "cat",
        "GIT_TERMINAL_PROMPT": "0",
    ]

    /// `inherited` with the overlay applied, and — when the app's discovery
    /// found `gh` under a `PATH` of its own — that `PATH` too.
    ///
    /// The `PATH` matters for the same reason it does for rust-analyzer: a
    /// Finder-launched app inherits `launchd`'s `PATH`
    /// (`/usr/bin:/bin:/usr/sbin:/sbin`), which contains neither Homebrew's
    /// prefixes nor `gh` itself — and `gh pr checkout` needs to find `git`.
    public static func merged(over inherited: [String: String], searchPath: String? = nil) -> [String: String] {
        var environment = inherited
        for (key, value) in nonInteractive {
            environment[key] = value
        }
        if let searchPath, !searchPath.isEmpty {
            environment["PATH"] = searchPath
        }
        return environment
    }
}
