# Deflake the two CI-flaky async tests

## Overview

Two tests stage a race with a timing assumption instead of a rendezvous. Both are
test-staging defects; the product is correct in both cases and must not change.
This plan restages each on a *causal* signal — something that provably happened —
strengthens the assertions so the intended interleaving is the only one that can
make them pass, and applies the same treatment to the siblings in the two suites
that share the pattern.

## Context

### Files involved

- Modify: `Tests/PisakaCoreTests/LeetCodeCatalogTests.swift`
- Modify: `Tests/PisakaCoreTests/LSPDiagnosticsRoutingTests.swift`
- Modify: `Tests/PisakaCoreTests/Support/ScriptedLSPTransport.swift` (one new hook)
- Read-only (must not change): `Sources/PisakaCore/LeetCodeCatalog.swift`,
  `Sources/PisakaCore/LSPWorkspace.swift`, `Sources/PisakaCore/LSPSession.swift`

### What the investigation established

**Catalog (`LeetCodeCatalog.startRefresh` → `writeCache`).** The sequence on the
main actor is: `now()` → pre-publish guard → `publish` → `writeCache` → detached
encode (`Task.detached { CachedCatalog(snapshot:).json() }`) → **suspension** →
post-encode guard → `ensureDirectory` → `write`. Everything from `now()` through
the encode's `await` runs synchronously on the actor, and everything after the
guard is a `FileServicing` call that only happens once the guard has *passed*.

Consequence: **`Gate` cannot hold the encode window open.** `Gate.wait()` blocks a
thread; the only thing running in that window is a closed, pure detached encode
with no seam, and every other point in the write path is on the main actor, where
blocking would deadlock the sign-out (`sessionDidChange` is main-actor isolated).
The existing `StubFileTree` hooks are all downstream of the guard, so gating them
would only observe the *failure* case. A hold-the-fetch staging (the existing
`transport.hold`) puts the sign-out before the *pre*-publish guard, which is the
sibling test `testAFetchInFlightWhenTheSessionGoesAwayPublishesNothing`.

The one test-owned seam the refresh touches on the actor in the step immediately
before it publishes is the **injected clock** (`now: { clock.now }`). Enqueuing the
sign-out from there puts a main-actor job on the queue *before the encode's task
exists*, so it is the first thing the actor runs when the publish suspends into the
encode — provably after the publish and provably before the post-encode guard. No
product change, no new support machinery: the `Clock` helper is already private to
that suite.

**LSP (`LSPWorkspace.liveSession` / `LSPSession.close`).** `close(reason:)` sets
`phase = .terminated` *before* it finishes the notification stream, and the
workspace's per-session consumer emits `.cleared(.server(...))` when that stream
ends. So the consumer's clear is an **observable proof that the session is already
terminal** — after it, the next `prepare` deterministically takes the
`!isRunning` → `noteDeath` → restart branch. That is exactly the rendezvous the
already-sound `testACrashMidSessionClearsThatKey` uses.

The other legal interleaving — `prepare` acquiring a session whose EOF has not been
noticed yet, the write failing, `prepare` returning `nil` by contract — is
currently *not* pinned anywhere; it is only the accidental outcome that makes the
named test flake. It can be staged deterministically by failing the transport's
**write** while leaving its stream open (`LSPSession.send` closes the session on a
write failure), which needs one small hook on `ScriptedLSPTransport` beside the
existing `onSend`/`closeStream`.

### Audit inventory (requirement 4)

`LSPDiagnosticsRoutingTests`, all five `closeStream()` sites:

| Site | Test | Verdict |
|---|---|---|
| L491 | `testACrashMidSessionClearsThatKey` | already sound — waits for the clear |
| L512 | `testAReplacementServersPushesSurviveTheDeadConsumersExit` | **restage** — close-then-`open` |
| L713 | `testACrashNoticedByTheNextRequestClearsBeforeTheRestart` | **restage** — the named defect |
| L735 | `testASpentCrashBudgetEmitsTheKeysClear` (loop) | **restage** — close-then-`open`, ×3 |
| L744 | `testASpentCrashBudgetEmitsTheKeysClear` (4th death) | **restage** — close-then-`prepare` |

`LeetCodeCatalogTests`:

| Site | Test | Verdict |
|---|---|---|
| L1341 | `testASessionReplacedWhileTheCacheIsEncodedIsNeverWritten` | **restage** — the named defect |
| L851/908/996/1040/1125/1165/1272 | the `Gate` + double-`Task.yield()` coalescing tests | already sound — the gate holds the fetch, and the joining task's first scheduling is enqueued before the test's yield; its join point is its first suspension |
| L1067 | `testThePreviousSessionsFetchLandingLastPublishesNothing` | already sound — two gates, released in order |
| L928 | `testALookupDuringTheDiskReadWaitsForItInsteadOfRefetching` | already sound — both tasks are main-actor jobs and the second's join point precedes the first's resumption; `readGate` is *not* usable here (it blocks the actor) |

The audit table above is the deliverable for requirement 4 and goes into the two
suites' doc comments, not just this plan.

### Related patterns

- `Gate` and `StubFileTree` (`Tests/PisakaCoreTests/Support/`), `waitFor`/`settle`
  in the LSP suite: condition-waits on a signal that *must* arrive, failing loudly
  via `XCTFail` on timeout rather than passing vacuously.
- Convention: shared helpers live in the support directory; a fake standing in for
  a `nonisolated async` seam hops to the main actor before touching shared state.

## Development Approach

- **Testing approach**: this *is* test work — each task restages a test and then
  proves the restaging with repeated runs before the next task starts.
- Strengthen, never weaken: every restaged test must assert something the *wrong*
  interleaving cannot satisfy, so a future scheduling change fails loudly instead
  of passing vacuously.
- **Hard constraint**: no file under `Sources/` may change. If any task turns out
  to need one, stop and report instead of proceeding.
- **CRITICAL: all tests must pass before starting the next task.**

## Implementation Steps

### Task 1: Confirm the diagnosis before changing anything

**Files:** none modified (baseline measurement only)

Establish the starting point so the fix is demonstrably a fix. Run each of the two
named tests in a loop at the current `HEAD` and record the result; then try to
provoke the failure by running the loop under load (several concurrent
`swift test --filter` processes, or a parallel CPU-burner) so the slower-runner
conditions are approximated. A local reproduction is *desirable, not required* —
requirement 5 says "where feasible" — but the attempt and its outcome must be
recorded, because it is what distinguishes "the diagnosis was confirmed" from "the
symptom stopped appearing".

- [x] run `swift test --filter testASessionReplacedWhileTheCacheIsEncodedIsNeverWritten` and `--filter testACrashNoticedByTheNextRequestClearsBeforeTheRestart` in a loop (≥50 iterations each), recording pass/fail counts
- [x] repeat both loops under CPU load and record whether either fails
- [x] write the counts and the load recipe into the progress notes so Task 5 can quote them

### Task 2: Restage the catalog's encode-window test

**Files:**
- Modify: `Tests/PisakaCoreTests/LeetCodeCatalogTests.swift`

Replace the `while catalog.problems.isEmpty { await Task.yield() }` spin in
`testASessionReplacedWhileTheCacheIsEncodedIsNeverWritten` with the clock-seam
rendezvous described in Context: give the suite's private `Clock` a one-shot
`onFirstRead` hook, and from it enqueue the sign-out as its own main-actor job at a
priority no lower than the refresh's. The refresh holds the actor from `now()`
through the publish into the encode's `await`, so the enqueued job cannot run
before the publish and cannot run after the post-encode guard.

Then strengthen the assertions so the staging is self-verifying: the publish must
have **stood** (`problems` non-empty, `fetchedAt == now`) *and* nothing may have
reached the disk (`writtenPaths.isEmpty`, `lastCacheWriteFailed == false`). That
pair is producible only by a sign-out landing strictly between the publish and the
write — a sign-out that arrived earlier would leave `problems` empty, and one that
arrived later would leave a written path. Assert the hook actually fired, so a
future refactor that stops reading the clock there fails instead of silently
reverting the test to a race.

Rewrite the doc comment: it must describe the seam actually used and why `Gate`
cannot hold this particular window, so "staged deterministically" becomes a true
statement rather than a claim. Leave the sibling `Gate`-staged tests alone.

- [x] add the one-shot read hook to the suite's private `Clock` and use it to enqueue the sign-out
- [x] strengthen the assertions to pin publish-stood *and* nothing-written, plus that the hook fired
- [x] rewrite the test's doc comment (staging + why the fetch-side gate cannot stage this window)
- [x] run the test ≥100 times in a loop; all green
- [x] run the whole `LeetCodeCatalogTests` suite; green

### Task 3: Restage the LSP crash-noticed-by-the-next-request test and its two siblings

**Files:**
- Modify: `Tests/PisakaCoreTests/LSPDiagnosticsRoutingTests.swift`

Introduce one private helper in the suite — "kill the live server and wait until
its death has been *processed*" — that closes the stream and then waits for the
dead life's clear, which only the consumer can emit and only after
`phase == .terminated`. Use it at all four defective `closeStream()` sites.

For `testACrashNoticedByTheNextRequestClearsBeforeTheRestart`: after the wait,
drain `events` so the consumer's clear cannot be mistaken for `noteDeath`'s, then
open. Any clear seen afterwards is unambiguously the synchronous one `noteDeath`
emits before the restart — which makes the existing assertion strictly stronger
than it was. Its doc comment must state which interleaving it pins (the consumer
notices first; the request notices too and clears again) and record that the other
interleaving is legal, idempotent by the product's own at-least-once clear rule,
and pinned by the test added in Task 4.

For `testAReplacementServersPushesSurviveTheDeadConsumersExit` and
`testASpentCrashBudgetEmitsTheKeysClear`, apply the same helper. Both keep their
subjects: the former asserts ordering *relative to the replacement's push*, which
the rendezvous does not disturb; the latter gains attribution, because draining the
consumer's clear before each request makes the remaining clears provably the
budget path's own.

- [x] add the "kill and wait until the death is processed" helper to the suite
- [x] restage the named test, draining events so the asserted clear is attributable to `noteDeath`
- [x] restage the two siblings at the remaining three `closeStream()` sites
- [x] update all three doc comments (interleaving pinned, why the rendezvous is causal not timed)
- [x] run each restaged test ≥100 times in a loop; all green
- [x] run the whole `LSPDiagnosticsRoutingTests` suite; green

### Task 4: Pin the other legal interleaving

**Files:**
- Modify: `Tests/PisakaCoreTests/Support/ScriptedLSPTransport.swift`
- Modify: `Tests/PisakaCoreTests/LSPDiagnosticsRoutingTests.swift`

The interleaving the named test used to hit by accident — a request acquiring a
session whose death has not been noticed — is a documented contract and currently
has no test of its own. Add a write-failure injection to `ScriptedLSPTransport`
(`send` throws while `incomingBytes` stays open), documented beside the existing
`onSend` hook as *the* way to stage "the pipe went away without an EOF". Note that
this is deliberately different from `terminate()`, which also closes the stream and
therefore reintroduces the race.

Add one test: after a live push, arm the write failure and `prepare`. It must
answer `nil` (the contract: "the session has already gone terminal; the next
request restarts it"), and nothing may have relaunched on that request. The *next*
`prepare` must restart the server and emit the dead key's clear before it does.
Both interleavings are then pinned rather than assumed, and the pair documents why
each is legal.

**If the observed behaviour contradicts the contract as documented in
`LSPWorkspace.prepare`/`core-lsp.md`, stop and report — do not adjust the product.**

- [x] add the write-failure hook to `ScriptedLSPTransport` with a doc comment covering the `terminate()` distinction
- [x] add the test pinning: request answers nothing, no relaunch on it, next request restarts and clears first
- [x] cross-reference the two tests' doc comments so the pair reads as one contract
- [x] run the new test ≥100 times in a loop; all green

### Task 5: Verify acceptance criteria

**Files:** none modified

- [ ] confirm `git diff --stat` touches nothing under `Sources/`
- [ ] run `swift test` in full; green
- [ ] run `swiftlint --strict` from the repository root; clean
- [ ] re-run all four restaged/new tests ≥100 iterations each and record the counts
- [ ] run `xcodegen generate` and the macOS + iOS `xcodebuild` builds to confirm the two build jobs are unaffected

### Task 6: Update documentation

**Files:**
- Modify: `Tests/PisakaCoreTests/LeetCodeCatalogTests.swift`,
  `Tests/PisakaCoreTests/LSPDiagnosticsRoutingTests.swift` (suite-level doc comments)
- Check: `docs/architecture/core-leetcode.md`, `docs/architecture/core-lsp.md`

Both suite-level doc comments already make claims about their staging discipline
("staged deterministically", "the assertions poll for the sink's record rather than
assuming any particular hop count"). Bring them in line: state the rule the suites
now follow — a rendezvous is a wait on a signal that *must* arrive, never on a
window that may already have closed — and carry the audit table's verdicts.

- [ ] update both suite-level doc comments with the staging rule and the audit verdicts
- [ ] grep the two architecture docs for any statement of the old staging as fact; update only if one exists
- [ ] confirm no product or brand name appears in the new comments
- [ ] re-run `swift test` and `swiftlint --strict`; both clean

## Post-Completion

- Watch the next few CI runs on the branch: the point of the work is that this
  class of failure stops recurring, which only CI can confirm.
