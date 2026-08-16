# LC-fix: SSO login must not capture an anonymous session

## Overview

Signing in through GitHub/Google SSO fails because `LeetCodeLoginObserver`
treats "the `LEETCODE_SESSION` + `csrftoken` pair exists" as "the login
succeeded". django-allauth creates an **anonymous** Django session (and
therefore sets `LEETCODE_SESSION`) at `leetcode.com/accounts/github/login/`,
before redirecting to the provider — so the observer fires mid-OAuth, the sheet
dismisses, and `signIn`'s own confirmation correctly answers `notLoggedIn`.

The fix redefines "login succeeded" as "LeetCode confirmed this session". A new
Core policy object — `LeetCodeLoginGate` — takes a *candidate* pair, confirms
it with the existing user-status call, and only then hands it back. A rejected
candidate is discarded silently, does not consume the one-shot, and the sheet
stays open so the OAuth round trip completes. The observer keeps no latch of
its own; the gate is the single latch, and it is unit-tested.

## Context

- Files involved:
  - `Sources/PisakaCore/LeetCodeLoginGate.swift` (new) — the whole gating
    policy.
  - `Sources/PisakaCore/LeetCodeModel.swift` — vends a per-sheet gate over its
    own transport (`makeLoginGate()`), plus the corrected doc note;
    `signIn(with:)` itself is unchanged.
  - `Sources/PisakaCore/LeetCodeCredentials.swift` — corrects the stale "the
    pair means signed in" claim in the doc comment; the parsing rule itself
    does not change (it now extracts a *candidate*).
  - `Sources/Pisaka/Platform/LeetCodeWebSession.swift` — `LeetCodeLoginObserver`
    gains the gate and loses `hasCaptured`.
  - `Sources/Pisaka/LeetCodeLoginView.swift`,
    `Sources/Pisaka/iOS/LeetCodeLoginView_iOS.swift` — the two representables
    build the observer with `model.makeLoginGate()`.
  - `Tests/PisakaCoreTests/LeetCodeLoginGateTests.swift` (new),
    `Tests/PisakaCoreTests/LeetCodeModelTests.swift` (one wiring test).
  - `docs/architecture/core-leetcode.md`, `CLAUDE.md` (one index line — a Core
    file is added).
- Related patterns: `ScriptedLeetCodeTransport` (route-keyed sticky script,
  `count(for:)`, `hold(_:on:)`) and `Gate` in `Tests/PisakaCoreTests/Support/`;
  the L1 rule that all LeetCode schema knowledge stays in `LeetCodeAPI`; the
  "decision in Core, view is chrome" rule the observer already follows.
- Dependencies: none new.

## Decisions taken by this plan

- **The gate confirms, `signIn` re-confirms.** The gate's user-status answer is
  *not* threaded into `LeetCodeModel.signIn(with:)`. `signIn` keeps its
  existing signature, generation token, publishing and error semantics exactly
  as they are; the second round trip is one cheap request that happens once per
  successful login. Threading an "already confirmed" result through `signIn`
  would add a second adoption path through the most state-heavy method in the
  integration for no user-visible gain — and the two calls cannot race, because
  the second one starts only after the gate has handed the pair out, once.
- **The gate is per login surface.** `makeLoginGate()` is called from each
  representable's `makeCoordinator()`, so the one-shot latch and the
  rejected-value memo are scoped to the sheet, which is exactly what "fires
  exactly once per sheet" means. Nothing is stored on the model.
- **A rejection is only an answer from LeetCode.** `isSignedIn == false` or
  `LeetCodeError.notLoggedIn` (which is also what a 401/403 or an auth `errors`
  array parses to — the same conflation `signIn` already makes) rejects.
  Everything else — `network`, `throttled`, `apiChanged`, a decode failure, a
  non-`LeetCodeError` thrown by a transport decorator — accepts, so an offline
  moment behaves exactly as the shipped code did.
- **Popups (`WKUIDelegate`)**: the plan does not add one. GitHub's allauth flow
  is a same-window redirect chain, and this failure is not a popup failure; it
  is recorded as an unverified known limit in the docs, not as work.

## Development Approach

- **Testing approach**: Regular (code first, then tests) — the gate is a small
  policy object whose behavior is easiest to state once the seam exists.
- Complete each task fully before moving to the next.
- **CRITICAL: every task MUST include new/updated tests** (the app-layer wiring
  task is the documented exception — view code is untested by convention; its
  task is gated on the builds instead).
- **CRITICAL: all tests must pass (`swift test`) before starting the next
  task.**

## Implementation Steps

### Task 1: The Core confirmation gate

**Files:**
- Create: `Sources/PisakaCore/LeetCodeLoginGate.swift`
- Create: `Tests/PisakaCoreTests/LeetCodeLoginGateTests.swift`

- [x] Add `@MainActor public final class LeetCodeLoginGate`, initialised with a
      `LeetCodeTransport`, exposing one operation:
      `public func offer(_ candidate: LeetCodeCredentials) async -> LeetCodeCredentials?`
      — "here is a pair the cookie store just produced; give it back only if it
      is a session".
- [x] Confirmation uses the existing primitive and nothing else:
      `LeetCodeAPI.userStatusRequest(credentials:)` sent through the transport,
      parsed by `LeetCodeAPI.parseUserStatus(_:)`. No new endpoint, no new
      parser, no second copy of the GraphQL document.
- [x] Implement the four rules, each documented in place with the reasoning
      (why the cookie pair is not a login; what allauth does at
      `/accounts/<provider>/login/`):
  - **One-shot for confirmed sessions.** Once a candidate has been handed out,
    every later offer answers `nil`. A rejected candidate does *not* consume it.
  - **Rejected values are remembered by `session` value** for the gate's
    lifetime, so the repeated navigations of an OAuth round trip cost one
    confirmation, not one per navigation. Keying by value is sound: completing
    the real login rotates the cookie.
  - **At most one confirmation in flight.** An offer arriving while a
    confirmation is running awaits that confirmation and then re-evaluates its
    own guards, rather than issuing a parallel request: a duplicate value then
    costs nothing (it is already in the memo) and a rotated value is confirmed
    immediately afterwards. Deliberately *not* "drop while busy" — dropping the
    final, real candidate because a slow confirmation of the anonymous one is
    still running would leave the sheet open forever with nothing left to
    retrigger it.
  - **Only an answer rejects.** Accept on `isSignedIn == true`; reject on
    `isSignedIn == false` and on `LeetCodeError.notLoggedIn`; accept on every
    other thrown failure, so an unreachable LeetCode behaves exactly as the
    shipped dismiss-first code did and the tolerant confirmation inside `signIn`
    remains the next line of defence.
- [x] Write `LeetCodeLoginGateTests` against `ScriptedLeetCodeTransport`,
      asserting behavior *and* request counts via `count(for: .userStatus)`:
  - an anonymous candidate (`isSignedIn: false`) answers `nil`, and a later
    candidate with a rotated session value that confirms is handed out — the
    latch survived the rejection;
  - the confirmed pair is handed out **exactly once**: a second offer of the
    same pair answers `nil` and issues no request;
  - the ordinary email/password path: the first candidate confirms, is returned
    on the first offer, one request total;
  - rejected-value memoization: three offers of the same anonymous value ⇒
    exactly one request; a rotated value ⇒ a second request;
  - single-in-flight, using `hold(.userStatus, on: Gate())`: two overlapping
    offers of the same value while the first is held ⇒ one request after
    release; a second offer carrying a *different*, confirmable value ⇒ two
    requests, and that offer returns the credentials;
  - transport failure (`fail(.userStatus)`) ⇒ the candidate is accepted
    (returned) and the latch is consumed;
  - a `403` (and an auth-`errors` GraphQL body) ⇒ rejected, matching `signIn`'s
    existing reading of `notLoggedIn`.
- [x] Run `swift test` — must pass before Task 2.

### Task 2: The model vends the gate

**Files:**
- Modify: `Sources/PisakaCore/LeetCodeModel.swift`
- Modify: `Tests/PisakaCoreTests/LeetCodeModelTests.swift`

- [x] Add `public func makeLoginGate() -> LeetCodeLoginGate`, returning a fresh
      gate over the model's own transport, documented as "one per login surface:
      the latch and the memo are the sheet's, not the app's", and noting that
      the gate's confirmation is deliberately not reused by `signIn(with:)`
      (one cheap extra request, no second adoption path).
- [x] Leave `signIn(with:)`, `refreshUserStatus()`, `signOut()`, the credential
      store and the cookie purge untouched — this fix must not change sign-out,
      purging or storage behavior.
- [x] Add a test that the vended gate goes through the model's transport (a
      candidate that confirms is handed out and one `userStatus` request is
      recorded), and one that two gates from the same model are independent (a
      value rejected on one is re-confirmed by the other — the "second sheet
      after a failed attempt" case).
- [x] Run `swift test` — must pass before Task 3.

### Task 3: Wire the observer and both login surfaces

**Files:**
- Modify: `Sources/Pisaka/Platform/LeetCodeWebSession.swift`
- Modify: `Sources/Pisaka/LeetCodeLoginView.swift`
- Modify: `Sources/Pisaka/iOS/LeetCodeLoginView_iOS.swift`

- [x] Give `LeetCodeLoginObserver` a `LeetCodeLoginGate` at init and route every
      check through it: read the cookies (unchanged, including the
      `leetcode.com` domain filter), build the candidate with
      `LeetCodeCredentials.from(cookies:)`, offer it to the gate, and fire
      `onCredentials` only for what the gate hands back.
- [x] Remove the observer's own `hasCaptured` so there is exactly one latch, in
      tested Core code; keep the two check points (`didCommit`, `didFinish`) and
      the existing pre-load cookie purge in `makeWebView()` exactly as they are.
- [x] Update the observer's and `LeetCodeWebSession.credentials(in:)`'s doc
      comments: what the cookie read now produces is a *candidate*, and the
      sheet stays open until LeetCode confirms one.
- [x] Pass the model into both private representables and build the coordinator
      as `LeetCodeLoginObserver(gate: model.makeLoginGate(), onCredentials: capture)`
      in `makeCoordinator()` — once per surface, never in `body`.
      `updateNSView`/`updateUIView` keep re-pointing the callback only and still
      never reload.
- [x] Update the macOS view's "Dismiss first, confirm behind it" note: dismissal
      now happens only after LeetCode has confirmed the session, and the tolerant
      post-dismissal confirmation stays for the offline case.
- [x] Run `swift test`, then `xcodegen generate` and both builds (macOS and iOS
      Simulator) — all must be green before Task 4. (No new Core tests here:
      view code is untested by convention; the decision it lost lives in Task 1's
      suite.)

### Task 4: Documentation

**Files:**
- Modify: `docs/architecture/core-leetcode.md`
- Modify: `CLAUDE.md`

- [x] Add decision **L26 — "signed in" means LeetCode confirmed it**: the false
      assumption (`LEETCODE_SESSION` appears only after login), the allauth
      mechanism that breaks it (the OAuth `state` needs a server-side session
      before the redirect, so an anonymous session exists on the way *out* to
      the provider), the confirmation-gate rule, the rejected-value memo and
      single-in-flight rule (why no confirmation storms), the
      transport-failure-accepts fallback and its rationale, and the note that
      `signIn`'s own confirmation is left in place rather than being fed the
      gate's result.
- [x] Add the `LeetCodeLoginGate.swift` file entry under the Core section, and
      update the `Platform/LeetCodeWebSession.swift` and login-view entries: the
      "fired at most once / `hasCaptured`" paragraph becomes the gate's latch,
      and "dismiss first" becomes "confirm, then dismiss — with the offline
      fallback intact".
- [x] Correct the stale claim wherever it is stated: the `LeetCodeCredentials`
      doc comment and the file entry around line 137 of the architecture doc —
      both cookies are still required, but their presence now means *candidate*,
      not session.
- [x] Extend the doc's Tests section with the new suite, and add one
      Known-limits line: a provider that drives its flow through a popup window
      would still need a `WKUIDelegate`; GitHub's does not, and this was not
      verified for every provider.
- [x] Add the one `CLAUDE.md` index line for `LeetCodeLoginGate.swift` under
      `docs/architecture/core-leetcode.md` (a Core file is added — the only
      reason convention permits touching that file here).
- [x] Run `swift test` — must pass. (2783 tests, 0 failures.)

### Task 5: Verify acceptance criteria

- [x] `swift test` — full suite green. (2783 tests, 0 failures.)
- [x] `xcodegen generate` and `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' build` — green (`** BUILD SUCCEEDED **`).
- [x] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build` — green (`** BUILD SUCCEEDED **`).
- [x] Re-read the acceptance list and confirm each unit-test claim is actually
      asserted by a named test: anonymous candidate does not fire and does not
      consume the one-shot; a confirmed session fires exactly once; a rejected
      value is not re-confirmed; a transport failure falls back to acceptance.
      Each maps to a named test in `LeetCodeLoginGateTests`:
      `testAnAnonymousCandidateIsRejectedWithoutConsumingTheLatch`,
      `testAConfirmedCandidateIsHandedOutExactlyOnce` (plus
      `testAConfirmedCandidateIsHandedBackOnTheFirstOffer`),
      `testARejectedValueIsRememberedAndCostsOneConfirmation`, and
      `testATransportFailureAcceptsTheCandidate` (plus
      `testEveryNonAnswerFailureAcceptsTheCandidate`); the auth-refusal reading
      is `testAnAuthenticationRefusalRejectsTheCandidate` and the wiring is
      `LeetCodeModelTests.testTheVendedGateConfirmsThroughTheModelsTransport` /
      `testGatesFromTheSameModelAreIndependent`.
- [x] Confirm by inspection that sign-out, cookie purging and the credential
      store are byte-for-byte unchanged in behavior. `git diff master` removes
      **no** line from `LeetCodeModel.swift` (the change is `makeLoginGate()`
      plus doc comments), and every removal in
      `Platform/LeetCodeWebSession.swift` is a doc comment or part of the
      observer's `hasCaptured` latch — `signOut()`, both sign-out halves, the
      scoped purge, `makeWebView()`'s pre-load purge and the credential store
      are untouched.

## Post-Completion (manual, performed by the user)

- GitHub SSO sign-in on macOS: the sheet stays open through the GitHub round
  trip, dismisses only after the return to LeetCode, and the app shows the
  signed-in account.
- Email/password sign-in on macOS still dismisses on the first confirmed
  navigation.
- iOS is not manually verified (no device in the loop); it lands through the
  shared `Platform/` layer by construction.
