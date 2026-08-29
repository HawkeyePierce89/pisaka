import Foundation

/// Every way a LeetCode operation can fail, as one type.
///
/// The integration talks to an **unofficial** API: there is no contract, no
/// versioning and no deprecation notice, so the failure that matters most is the
/// one where LeetCode simply changed something. `apiChanged` exists to make that
/// case loud and self-diagnosing — it carries the key path or shape that did not
/// match, so a bug report names the one line of `LeetCodeAPI` to fix — and it is
/// why no parser in this area is allowed to shrug a mismatch off into an empty
/// result. A silent empty catalog looks exactly like a problem that does not
/// exist.
///
/// Lives in Core rather than beside the `URLSession` transport so every sentence
/// the user reads is unit-testable, the way `GitError` already is: the models
/// surface `error.localizedDescription` directly.
public enum LeetCodeError: Error, Equatable {
    /// No stored session, or LeetCode answered a request by saying the session is
    /// not signed in. Every operation in this integration requires a login (the
    /// paid-only flag and solved status only exist with one), so this is the
    /// answer to "open a problem" while signed out — offered alongside sign-in
    /// rather than silently fetching anonymous content.
    case notLoggedIn
    /// No HTTP response could be obtained: offline, DNS, TLS, a timeout, or a
    /// non-HTTP response. `reason` is the underlying description, which is the
    /// only thing that distinguishes "airplane mode" from "LeetCode is down".
    case network(reason: String)
    /// A response arrived and did not have the shape this app knows. `detail`
    /// names the key path or value that did not match (`"data.question.content"`,
    /// `"difficulty.level = 7"`), because with an unofficial API that string is
    /// the entire diagnosis.
    case apiChanged(detail: String)
    /// The problem is LeetCode Premium and its statement/snippets are not
    /// available to this account.
    case paidOnly(slug: String)
    /// LeetCode is rate-limiting. `retryAfter` is the server's own `Retry-After`
    /// in seconds when it supplied one, and `nil` when it only said "too many
    /// requests" — the difference is whether the message can name a wait.
    case throttled(retryAfter: TimeInterval?)
    /// The configured LeetCode folder is not set, no longer exists, or could not
    /// be reached (an iOS bookmark that no longer resolves). The solution file has
    /// nowhere to go until the user chooses a folder again.
    case folderUnavailable
    /// Reading or writing on disk failed — creating the folder, or writing the
    /// seeded solution file. `reason` carries the underlying description.
    case fileSystem(reason: String)
    /// The judge was asked, answered, and then never finished within the budget
    /// the run was given. `seconds` is that budget, so the sentence can name it.
    ///
    /// **A product refusal, not a wire mismatch** — nothing about the response
    /// was wrong; LeetCode simply kept saying `PENDING`. It exists so that the
    /// one thing a poll loop must never do is possible to state: hang. The
    /// submission itself is *not* undone by this — LeetCode has it, and the
    /// verdict appears on the site — which is why the sentence says so rather
    /// than implying the attempt was lost.
    case judgeTimedOut(seconds: TimeInterval)
    /// Run or Submit cannot be offered for this file at all: not signed in, not
    /// a LeetCode solution file, a language LeetCode does not accept, or a
    /// problem it no longer knows. `reason` is the already-user-facing half of
    /// the sentence, decided one layer up where the file and the session are
    /// both in view.
    ///
    /// It carries one answer that is not about the *file*: LeetCode's own
    /// `state: "FAILURE"`, its judge giving up on an attempt. That belongs here
    /// rather than beside `apiChanged` for the same reason as the rest — LeetCode
    /// documents that state by sending it, so nobody should be sent hunting a
    /// schema change — and the sentence tells the user to try again.
    ///
    /// Also a product refusal, and separate from `apiChanged` on purpose: none
    /// of these mean LeetCode changed anything, so none of them should send
    /// somebody hunting a schema change.
    case judgeUnavailable(reason: String)
}

extension LeetCodeError: LocalizedError {
    /// The sentence shown in the alert, the Open Problem sheet's inline error, or
    /// the iOS route's failure row.
    ///
    /// Without this, `localizedDescription` would fall back to "operation couldn't
    /// be completed (PisakaCore.LeetCodeError error N)", throwing away the
    /// `apiChanged` detail — the one string that says what broke — and the
    /// throttle's wait.
    public var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "Not signed in to LeetCode. Sign in to open problems."
        case .network(let reason):
            let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty
                ? "Could not reach LeetCode."
                : "Could not reach LeetCode: \(trimmed)"
        case .apiChanged(let detail):
            let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty
                ? "LeetCode returned something Pisaka did not understand. Its API may have changed."
                : "LeetCode returned something Pisaka did not understand (\(trimmed)). "
                + "Its API may have changed."
        case .paidOnly(let slug):
            let trimmed = slug.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty
                ? "This problem is available to LeetCode Premium subscribers only."
                : "“\(trimmed)” is available to LeetCode Premium subscribers only."
        case .throttled(let retryAfter):
            // The same "a wait worth naming" rule `LeetCodeAPI` parses by, applied
            // a second time here because this is a `public` case anyone can build:
            // `Int(_:)` traps on an infinite or over-`Int.max` `Double`, so a value
            // that never went through the parser would crash the app in the one
            // path whose whole job is reporting a transient failure gracefully.
            // NaN fails every comparison and degrades the same way.
            guard let retryAfter, retryAfter > 0, retryAfter <= 3600 else {
                return "LeetCode is rate-limiting requests. Try again in a moment."
            }
            let seconds = Int(retryAfter.rounded(.up))
            return "LeetCode is rate-limiting requests. Try again in \(seconds) "
                + (seconds == 1 ? "second." : "seconds.")
        case .folderUnavailable:
            return "The LeetCode folder is unavailable. Choose a folder for your solutions."
        case .fileSystem(let reason):
            let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Could not write the solution file." : trimmed
        case .judgeTimedOut(let seconds):
            // The same "a wait worth naming" guard the throttle case carries, and
            // for the identical reason: this is a `public` case anyone can build,
            // and `Int(_:)` traps on an infinite or over-`Int.max` `Double`.
            let suffix = "LeetCode still has the submission — its result is on the site."
            guard seconds > 0, seconds <= 3600 else {
                return "LeetCode did not return a result in time. " + suffix
            }
            let whole = Int(seconds.rounded(.up))
            return "LeetCode did not return a result within \(whole) "
                + (whole == 1 ? "second. " : "seconds. ") + suffix
        case .judgeUnavailable(let reason):
            let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty
                ? "This file cannot be run on LeetCode."
                : trimmed
        }
    }
}
