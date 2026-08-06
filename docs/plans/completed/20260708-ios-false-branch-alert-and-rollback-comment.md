# iOS false alert on stale origin + clarify rollback comment in createAndCheckout

## Overview

Two small, non-blocking fixes flagged in the review of plan
`20260707-branch-switcher-and-ios-https-git.md`:

1. iOS: remove the false "Couldn't switch branches." alert that `RootView_iOS`
   shows unconditionally whenever a branch operation fails — including the case
   where `originGeneration` no longer matches (the user switched folders between
   the tap and the task start), where no operation ran and `errorMessage` is
   empty. Bring iOS in line with macOS: show the alert only when
   `branchSwitcher.errorMessage != nil`.
2. `LibGit2Service.createAndCheckout`: clarify the rollback comment — "HEAD was
   not moved" is only true for `GIT_ECONFLICT` (failure at `git_checkout_tree`),
   but `checkoutBranch` can also fail at `git_repository_set_head`, where the
   worktree has already been rewritten. This is the same non-atomicity git
   itself has; only the comment text changes, behavior is unchanged.

## Context

- Files involved:
  - `Sources/Pisaka/iOS/RootView_iOS.swift` — `switchBranch` (~line 565) and
    `createBranch` `.failed` (~line 608)
  - `Sources/Pisaka/iOS/LibGit2Service.swift` — `createAndCheckout` rollback
    comment (~lines 266-274)
  - `Tests/PisakaCoreTests/BranchSwitcherModelTests.swift` — strengthen two
    existing contract tests + add two message-preservation tests
- Related patterns:
  - macOS reference: `PisakaApp.runBranchOperation` (line 726) and
    `createBranch` `.failed` (line 680) —
    `if let message = branchSwitcher.errorMessage { presentBranchError(message) }`,
    no fallback and no alert/beep on nil.
  - `BranchSwitcherModel.switchTo` (line 207) and `createBranch` (line 302)
    return `false`/`.failed` when `originGeneration != refreshGeneration`,
    before touching `errorMessage`.
  - `prepareForRefresh` (line 101): bumps `refreshGeneration` always, but clears
    `errorMessage` only on a folder switch (`requestedRoot != lastRequestedRoot`).
    A same-root call bumps the generation while leaving `errorMessage` untouched
    — the seam that lets a test isolate "the bail itself does not touch
    errorMessage."
  - Existing tests already seed a failure with the typed
    `GitError.checkoutFailed(reason:)` (`git.checkoutError` at line 335,
    `git.createError` at line 512), so `errorMessage` carries a deterministic
    string (e.g. "Your local changes would be overwritten: a.swift") rather than
    a Foundation description of an opaque `StubError.boom`. The new preservation
    tests reuse this typed-error seeding so the "unchanged" assertion compares
    against that exact reason string.
  - `StubGit.checkout`/`createAndCheckout` throw *before* recording to
    `checkedOut`/`created`, so a seeded failure leaves those arrays empty and a
    leaked op after the bail is observable.
- Scope notes:
  - The same false-alert bug exists in the iOS `createBranch` `.failed` branch
    (fallback "Couldn't create the branch.") — one root, one fix, so both sites
    are fixed together.
  - Fixes 1 and 2 are thin view-layer + comment; they add no domain logic. The
    contract the view fix relies on (a generation mismatch does not set — and
    does not touch — `errorMessage`) is pinned in Core tests.

## Development Approach

- **Testing approach**: Regular (change code, then strengthen tests)
- The view changes (`RootView_iOS`) follow the "thin, untested view layer"
  convention; their contract is protected by Core `BranchSwitcherModel` tests.
- The comment fix in `LibGit2Service` has no behavioral change, no test.
- **CRITICAL: every behavioral change ships with new/updated `PisakaCore`
  tests.**
- **CRITICAL: a full `swift test` run must pass after each task before starting
  the next.**

## Implementation Steps

### Task 1: Remove the false branch-operation alert on iOS

**Files:**
- Modify: `Sources/Pisaka/iOS/RootView_iOS.swift`
- Modify: `Tests/PisakaCoreTests/BranchSwitcherModelTests.swift`

- [x] In `switchBranch`: replace the unconditional alert-with-fallback with the
      macOS behavior — on `!ok`, show `PlatformFeedback.warning()` + the branch
      alert only when `branchSwitcher.errorMessage != nil`; when `errorMessage`
      is nil (generation mismatch), exit silently (no beep, no alert), matching
      `PisakaApp.runBranchOperation`.
- [x] In `createBranch` `.failed`: likewise remove the "Couldn't create the
      branch." fallback and show `warning()` + alert only when
      `errorMessage != nil` (reference: `PisakaApp.createBranch` `.failed`).
- [x] Strengthen `testSwitchToStaleOriginGenerationBailsBeforeCheckout`: add
      `XCTAssertNil(model.errorMessage)` — pin that a folder-switch bail leaves
      no message.
- [x] Strengthen `testCreateBranchStaleOriginGenerationBailsBeforeGitCall`: add
      `XCTAssertNil(model.errorMessage)`.
- [x] Add `testSwitchToStaleOriginGenerationPreservesExistingErrorMessage`
      (stronger "bail does not touch errorMessage"): refresh against `root`;
      seed a non-empty `errorMessage` via a failed checkout — set
      `git.checkoutError = GitError.checkoutFailed(reason: "seeded")`,
      `switchTo` → false, `errorMessage` now equals "seeded"; clear
      `git.checkoutError` so a leaked checkout would be observable; capture
      `origin = model.currentRefreshGeneration`; bump the generation with a
      same-root `prepareForRefresh(root: root)` (bumps `refreshGeneration`
      without clearing `errorMessage`); `switchTo(feature, originGeneration:
      origin)` → false; assert `errorMessage == "seeded"` (unchanged,
      deterministic string) and `git.checkedOut` is still empty (no checkout
      ran).
- [x] Add `testCreateBranchStaleOriginGenerationPreservesExistingErrorMessage`:
      same shape via `createBranch` — seed a non-empty `errorMessage` via a
      failed create using `git.createError = GitError.checkoutFailed(reason:
      "seeded")`, clear it, same-root generation bump, then
      `createBranch(name:from:originGeneration:)` with a valid name → `.failed`;
      assert `errorMessage == "seeded"` (unchanged) and `git.created` still
      empty.
- [x] Run `swift test` — must pass before moving to Task 2.

### Task 2: Clarify the rollback comment in LibGit2Service.createAndCheckout

**Files:**
- Modify: `Sources/Pisaka/iOS/LibGit2Service.swift`

- [x] Rewrite the comment in the `createAndCheckout` catch block
      (`git_branch_delete`): explain that the rollback is correct for
      `GIT_ECONFLICT` (failure at `git_checkout_tree`, HEAD not moved), but if
      `checkoutBranch` fails at `git_repository_set_head` the worktree is already
      rewritten while the created branch is deleted; this is the same
      non-atomicity as `git checkout -b`, not a separate bug.
- [x] Confirm behavior is unchanged (comment text only).
- [x] Run `swift test` — must pass.

### Task 3: Verify acceptance criteria

- [x] Run the full `swift test` suite — entire set green.
- [x] Build the macOS and iOS targets via `xcodebuild` (equivalent to CI) to
      confirm the `RootView_iOS` iOS changes compile.

### Task 4: Update documentation

- [x] CLAUDE.md/README — no changes required (internal patterns and user-facing
      behavior are unchanged; the fix only brings iOS in line with the
      already-documented macOS behavior). Note that no documentation update is
      needed.
