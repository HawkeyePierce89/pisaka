import Foundation

/// Decides when the cookies a login web view is holding are actually a *session*.
///
/// The login views watch a `WKWebView` and lift `LEETCODE_SESSION` + `csrftoken`
/// out of its cookie store as the user navigates. The shipped code treated the
/// presence of that pair as "the login succeeded" — which is wrong, and is why
/// GitHub/Google SSO could not sign in at all:
///
/// - LeetCode's SSO runs through django-allauth. Hitting
///   `leetcode.com/accounts/<provider>/login/` makes the server store the OAuth
///   `state` (and the `next` URL) *before* it redirects out to the provider, and
///   storing anything server-side creates a Django session — so `Set-Cookie:
///   LEETCODE_SESSION=…` arrives on the way **out** to GitHub, while the user is
///   still anonymous.
/// - The observer therefore fired mid-OAuth, the sheet dismissed, and
///   `LeetCodeModel.signIn(with:)`'s own confirmation then correctly answered
///   `notLoggedIn` — a failed sign-in with the web view already gone, and nothing
///   left to finish the round trip in.
///
/// So the pair a cookie store produces is a **candidate**, not a login, and this
/// gate is the one thing that turns one into the other: it asks LeetCode
/// (`globalData` → `userStatus.isSignedIn`, the integration's single login
/// signal) and hands the candidate back only if LeetCode confirmed it. A rejected
/// candidate is discarded silently — no error, no state, nothing published — and
/// the sheet stays open so the OAuth chain can run to its end.
///
/// It is also the *only* latch: the observers keep no `hasCaptured` of their own,
/// because "did the login succeed" is a decision, decisions live in Core, and
/// view code is untested by convention.
///
/// One gate belongs to one login surface (`LeetCodeModel.makeLoginGate()`, called
/// from each representable's `makeCoordinator()`): the one-shot and the memo are
/// the sheet's, so a second sheet after a failed attempt starts clean.
@MainActor
public final class LeetCodeLoginGate {

    /// Whether a candidate has already been handed out. Only a *confirmed*
    /// candidate consumes this: rejecting the anonymous mid-OAuth session must
    /// leave the gate armed for the real one that follows.
    private var hasHandedOut = false

    /// What LeetCode answered about a session value, keyed by the value itself.
    ///
    /// An OAuth round trip is a chain of navigations and each one is a check, so
    /// without a memo the same anonymous session would be confirmed five or six
    /// times over. Keying by `session` is sound precisely because completing the
    /// login **rotates** the cookie — Django cycles the session key on login, to
    /// defeat session fixation — so the real credentials never collide with the
    /// anonymous ones this memo is holding.
    private var verdicts: [String: Bool] = [:]

    /// The confirmation currently in flight, if any.
    ///
    /// At most one runs at a time, and an offer that arrives while one is running
    /// **waits for it and then re-evaluates its own guards** rather than issuing a
    /// parallel request. Waiting is what makes the duplicate case free (the answer
    /// is in the memo by then) *and* keeps the rotated case correct (it is
    /// confirmed immediately afterwards). Dropping offers while busy would be the
    /// bug this whole file exists to fix, one layer down: the final, real
    /// candidate would be discarded because a slow confirmation of the anonymous
    /// one was still running, leaving the sheet open with nothing left to
    /// retrigger it.
    private var confirmation: Task<Void, Never>?

    private let transport: LeetCodeTransport

    public init(transport: LeetCodeTransport) {
        self.transport = transport
    }

    /// Offer the pair the cookie store just produced.
    ///
    /// - Returns: `candidate` when LeetCode confirms it is a signed-in session and
    ///   nothing has been handed out yet; `nil` otherwise — which the caller must
    ///   treat as "keep watching", not as a failure.
    public func offer(_ candidate: LeetCodeCredentials) async -> LeetCodeCredentials? {
        while true {
            // The one-shot. Checked on every pass, including after a wait: two
            // overlapping offers of the same confirmed pair must still fire once.
            if hasHandedOut { return nil }

            if let verdict = verdicts[candidate.session] {
                guard verdict else { return nil }
                hasHandedOut = true
                return candidate
            }

            if let confirmation {
                await confirmation.value
                continue
            }

            // Nothing known and nothing running: confirm it ourselves. The task
            // records the verdict and clears itself *before* it completes, so
            // everyone waiting on it resumes into settled state.
            //
            // `self` is captured **strongly**, deliberately. The gate cannot go
            // away while this runs — `offer` is its own instance method and it
            // awaits the task below, so the call itself holds it — and a `[weak
            // self]` whose `else` branch ever ran would be far worse than a
            // retain: it would leave `confirmation` non-nil with no verdict
            // recorded, and every offer would then spin between "await a task
            // that already completed" and "continue", forever.
            let task = Task { @MainActor in
                let accepted = await Self.confirm(candidate, through: self.transport)
                self.verdicts[candidate.session] = accepted
                self.confirmation = nil
            }
            confirmation = task
            await task.value
        }
    }

    /// Ask LeetCode whether this pair is a session.
    ///
    /// Uses the integration's existing primitive and nothing else — one request
    /// builder, one parser, one GraphQL document, per L1.
    ///
    /// **Only an answer rejects.** `isSignedIn == false` is one, and so is
    /// `notLoggedIn`, which is what a 401/403 or an auth `errors` array parses to
    /// — the same conflation `signIn(with:)` already makes, so the two cannot
    /// disagree about what a dead session looks like. Everything else — `network`,
    /// `throttled`, `apiChanged`, a decode failure, a non-`LeetCodeError` thrown
    /// by a transport decorator — **accepts**, so an unreachable LeetCode behaves
    /// exactly as the shipped dismiss-first code did: the sheet closes, and the
    /// tolerant confirmation inside `signIn(with:)` is the next line of defence.
    /// Refusing on a failure would instead strand the user in a sheet that never
    /// dismisses, which is strictly worse than the bug being fixed.
    private static func confirm(
        _ candidate: LeetCodeCredentials,
        through transport: LeetCodeTransport
    ) async -> Bool {
        do {
            let response = try await transport.send(
                LeetCodeAPI.userStatusRequest(credentials: candidate)
            )
            return try LeetCodeAPI.parseUserStatus(response).isSignedIn
        } catch LeetCodeError.notLoggedIn {
            return false
        } catch {
            return true
        }
    }
}
