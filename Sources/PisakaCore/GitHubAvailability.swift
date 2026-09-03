import Foundation

/// What `gh --version` answered, as the one value the availability decision reads
/// (G8).
///
/// Three cases rather than an optional version, because "there is no `gh`" and
/// "there is a `gh` that would not say what it is" arrive by different routes —
/// a thrown `GitHubCLIError.notInstalled` and a successful command whose output
/// did not parse — and collapsing them at the call site would put that decision
/// in the app layer instead of here.
public enum GitHubVersionProbe: Equatable, Sendable {
    /// No `gh` could be found or launched at all.
    case unavailable
    /// `gh --version` ran and its first line named this version.
    case version(GitHubVersion)
    /// `gh --version` ran and printed something no version could be read out of.
    case unreadable
}

/// Whether this feature can talk to GitHub at all, and what to do when it cannot
/// (G8).
///
/// Four states, decided purely from the two probes — `gh --version` and
/// `gh auth status` — and re-decided on every refresh, never cached across one.
/// Each carries both halves of what the panel shows: the sentence saying what is
/// wrong, and the *exact* next step, spelled as the command to run. A not-ready
/// panel that says only "GitHub is unavailable" makes the user guess; naming
/// `brew install gh` or `gh auth login` does not.
///
/// The order of the decision is fixed and load-bearing: the version is judged
/// before the sign-in. A `gh` too old to answer `pr checks --json` is too old
/// whether or not somebody is signed in, and telling that user to run
/// `gh auth login` would send them down a road that ends in the same refusal.
public enum GitHubAvailability: Equatable, Sendable {
    /// There is no usable `gh` on this Mac.
    case notInstalled
    /// There is a `gh`, and it predates the one flag this feature needs (G4).
    case tooOld(found: GitHubVersion, minimum: GitHubVersion)
    /// There is a new-enough `gh`, and it is not signed in to GitHub.
    case notSignedIn
    /// Everything is in place.
    case ready(version: GitHubVersion)

    /// Whether pull requests can be listed. The only state the panel draws rows
    /// in, and the only one the bottom-bar indicator is ever visible under.
    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    /// The version in hand, for the states that have one.
    public var version: GitHubVersion? {
        switch self {
        case .notInstalled, .notSignedIn: return nil
        case .tooOld(let found, _): return found
        case .ready(let version): return version
        }
    }

    /// The sentence the panel shows.
    public var message: String {
        switch self {
        case .notInstalled:
            return "The GitHub CLI (gh) was not found."
        case .tooOld(let found, let minimum):
            return "The GitHub CLI is version \(found). Pisaka needs \(minimum) or newer."
        case .notSignedIn:
            return "The GitHub CLI is not signed in to GitHub."
        case .ready(let version):
            return "GitHub CLI \(version)."
        }
    }

    /// The command to run, verbatim, or `nil` when there is nothing to do.
    ///
    /// `brew upgrade` rather than `brew install` for the too-old state: the
    /// binary is already there, and telling somebody to install what they have
    /// is the kind of advice that gets a panel ignored.
    public var nextStep: String? {
        switch self {
        case .notInstalled: return "brew install gh"
        case .tooOld: return "brew upgrade gh"
        case .notSignedIn: return "gh auth login"
        case .ready: return nil
        }
    }

    /// The four states, from the two probes and nothing else.
    ///
    /// `isSignedIn` is the *exit status* of `gh auth status` and never its text:
    /// that command writes its prose to stderr in a shape that has changed
    /// between releases, while the status has not. Judged by exit status only.
    public static func decide(version probe: GitHubVersionProbe, isSignedIn: Bool) -> GitHubAvailability {
        switch probe {
        case .unavailable, .unreadable:
            // A binary that will not name itself is not one this feature can
            // vouch for, and the next step — install a real `gh` — is the same.
            return .notInstalled
        case .version(let found):
            guard found >= GitHubVersion.minimum else {
                return .tooOld(found: found, minimum: GitHubVersion.minimum)
            }
            return isSignedIn ? .ready(version: found) : .notSignedIn
        }
    }
}
