# Unattended credential reads never wait on a person

## Overview

Opening the problem-catalog tab in Preferences can freeze the app until it is
force-quit. The pane's on-appear body runs inside `NSHostingView.layout()`. It
resolves the account, which reads the Keychain synchronously. When the login
keychain does not recognise the binary, `securityd` puts an authorization panel
on screen while the main thread is stuck in layout.

The fix keeps L27's synchronous resolution. It changes what a read may do
instead:

- A read nobody asked for (unattended) may fail, but may never prompt.
- A read that follows an explicit action (attended) may prompt.

Core's credential-store seam gains a way to say which kind of read it is
making. The model chooses the kind at each call site. On macOS the Keychain
store enforces "unattended" with the one mechanism shown to work against the
legacy login keychain. On iOS the store runs today's query unchanged for both
kinds.

Evidence gathered while planning. A probe stored an item from one binary and
read it back from a freshly built one, with a 12 s timeout:

- `kSecUseAuthenticationUI = kSecUseAuthenticationUIFail` still raised the
  panel and hung.
- An `LAContext` with `interactionNotAllowed = true`, passed as
  `kSecUseAuthenticationContext`, also raised the panel and hung.
- Only the process-wide legacy switch worked.
  `SecKeychainSetUserInteractionAllowed(false)` returned `errSecAuthFailed`
  (-25293) in 0.02 s with no panel. It is deprecated and macOS-only.

On iOS this item has no access-control flags, so the system never shows UI to
read it. The one case where the system cannot answer is a read before first
unlock, and there it already returns `errSecInteractionNotAllowed` without
asking, which the store turns into `nil`. So iOS needs no switch. The two
documented flags are not used on either destination, because both were
measured raising the panel. Requirement 4's fallback (taking the read off the
main thread) is not needed.

Decision recorded with the user: attended reads stay synchronous on the main
actor. They no longer run inside a layout pass, so a panel they raise can be
answered and the app resumes afterwards. The window cannot redraw while that
panel stands. That brief block is recorded as a known limit. The second
acceptance criterion is reworded to match: "the panel can be answered and the
app resumes".

## Context

- Files involved:
  - `Sources/PisakaCore/LeetCodeCredentials.swift`: the
    `LeetCodeCredentialStore` protocol and its defaults.
  - `Sources/PisakaCore/LeetCodeModel.swift`:
    - `resolveAccount(startingConfirmation:)`
    - `refreshUserStatus()`
    - `requireCredentials()`
    - `statement(forFileAt:in:)`
    - the private `storedCredentials()` accessor (today "the one place the
      store is read")
  - `Sources/PisakaCore/LeetCodeBrowserModel.swift` and
    `LeetCodeJudgeModel.swift`: they reach the store only through
    `requireCredentials()`. No code change is expected; tests cover them.
  - `Sources/Pisaka/Platform/LeetCodeKeychainStore.swift`: the one Keychain
    implementation, compiled for both destinations.
  - `Tests/PisakaCoreTests/Support/ScriptedLeetCodeTransport.swift`:
    `InMemoryLeetCodeCredentialStore`, which has a `loadCount` today.
  - `Tests/PisakaCoreTests/LeetCodeModelTests.swift`,
    `LeetCodeCredentialsTests.swift` (which has its own `MemoryStore` /
    `EmptyDefaultStore`), `LeetCodeBrowserModelTests.swift`,
    `LeetCodeJudgeModelTests.swift`.
  - `Tests/PisakaCoreTests/LeetCodeAccountSourceGatingTests.swift`.
  - `docs/architecture/core-leetcode.md`: decision L27, the credentials entry
    and the keychain-store entry.
- Related patterns:
  - A defaulted protocol member where absence is the safe answer (the
    `CredentialStore` / `GitServicing` precedent).
  - Source-gating suites that match against comment- and literal-stripped
    text, through `LSPSourceGatingTests.strippingCommentsAndStringLiterals` /
    `containsToken`.
  - The existing store rule: an unreadable Keychain yields `nil`, the `nil` is
    never cached as final, and the next `cachedCredentials ??
    storedCredentials()` site asks again.
  - The existing recovery when the Keychain hands back a pair later than
    resolution did: `markSessionAccepted()` flips the account to signed in once
    a request succeeds. Resolution deliberately does not tell the catalog about
    a session it did not see.
- Dependencies:
  - None new. `Security` is already imported.

## Development Approach

- **Testing approach**: TDD for the Core half. First write the
  resolution-path test against the new seam, and watch it fail with the
  resolution site set to attended. Then classify the sites.
- Complete each task fully before moving to the next.
- Keychain knowledge stays in the app file. Core sees only the read kind.
- No brand or product names in code, comments, docs or commits.
- **CRITICAL: every task MUST include new/updated tests**
- **CRITICAL: all tests must pass before starting next task** (`swift test`;
  the app bundle where noted).

## Implementation Steps

### Task 1: The seam can say what kind of read it is

**Files:**
- Modify: `Sources/PisakaCore/LeetCodeCredentials.swift`
- Modify: `Tests/PisakaCoreTests/Support/ScriptedLeetCodeTransport.swift`
- Modify: `Tests/PisakaCoreTests/LeetCodeCredentialsTests.swift`

- [ ] Introduce a closed two-case read kind (working name
  `LeetCodeCredentialRead`, cases `unattended` and `attended`). Each case's doc
  comment states its rule:
  - unattended: may fail, never waits on a person.
  - attended: follows an explicit action and may ask.
- [ ] Replace `load()` with `load(_ read:)`, defaulted to `nil` in the protocol
  extension. A store that implements nothing still reads as signed out, never
  as "ask the user". Remove the parameterless member rather than keep two ways
  to read.
- [ ] Extend `InMemoryLeetCodeCredentialStore`:
  - Record every read's kind in order. Keep `loadCount` as the log's count so
    the existing assertions stand.
  - Add a switch that simulates a keychain wanting permission: an unattended
    read answers `nil`, an attended read answers the stored pair.
- [ ] Update `LeetCodeCredentialsTests`' local stores and the defaults test.
  The empty store must answer `nil` for both kinds.
- [ ] Run `swift test`. It must pass before Task 2.

### Task 2: Classify every read site in the model; the regression test

**Files:**
- Modify: `Sources/PisakaCore/LeetCodeModel.swift`
- Modify: `Tests/PisakaCoreTests/LeetCodeModelTests.swift`
- Modify: `Tests/PisakaCoreTests/LeetCodeBrowserModelTests.swift`
- Modify: `Tests/PisakaCoreTests/LeetCodeJudgeModelTests.swift`

- [ ] Make the private accessor take the read kind. Each call site names its
  kind in place, so its choice is readable without tracing callers.
  - Unattended:
    - `resolveAccount(startingConfirmation:)`, and through it the four
      on-appear surfaces, the browser's pre-token resolve and the menu's await.
    - `refreshUserStatus()`, the confirmation that resolution starts.
  - Attended:
    - `requireCredentials()`, which covers opening a problem, the judge's
      Run/Submit and context, and the browser's lookup. Its leading
      `resolveAccount()` stays unattended; only its own fallback read is
      attended.
    - `statement(forFileAt:in:)`, the fetch after a deliberate solution-tab
      activation.
- [ ] Update the accessor's doc comment. It is still the one place the store is
  read. The kind is now a per-site argument rather than a property of the
  accessor.
- [ ] Write the test that matters: resolving the account never asks for a read
  that may interact. Cover each path with a stored pair and a scripted
  user-status answer:
  - `resolveAccount()`
  - `awaitAccountResolution()`, including the confirmation it starts
  - the browser's `load()` / `refresh()`
  - a direct `refreshUserStatus()` on an unresolved model

  The read log must contain no attended read. Confirm by hand that the test
  fails when the resolution site is switched to attended, then switch it back.
- [ ] Test that a refused unattended read is indistinguishable from "nothing
  stored". With the permission-wanting store:
  - Resolution publishes `.signedOut`, starts no confirmation, leaves the
    catalog untold, and surfaces no error.
  - A following `openProblem` makes exactly one attended read and succeeds, and
    `markSessionAccepted()` flips the account to signed in. That is the
    existing recovery rule, now pinned.
  - A judge Run and a statement fetch after the same refused resolution each
    make an attended read.
- [ ] Check the existing `loadCount` tests still hold. Tighten them to the kind
  where that is the claim: for example, construction and ordinary tabs read
  nothing, and sign-in/sign-out read nothing.
- [ ] Run `swift test`. It must pass before Task 3.

### Task 3: The Keychain store honours the read kind

**Files:**
- Modify: `Sources/Pisaka/Platform/LeetCodeKeychainStore.swift`

- [ ] Implement `load(_:)`. The attended read is today's query unchanged.
- [ ] Unattended read on macOS:
  - Save the current value with `SecKeychainGetUserInteractionAllowed`, set it
    to `false`, run the same query, and restore the saved value in a `defer`.
  - Any non-success status (`errSecAuthFailed`, `errSecInteractionNotAllowed`,
    and the rest) is `nil`, as today.
- [ ] Unattended read on iOS: today's query unchanged, the same as attended.
- [ ] Explain in comments, in this file only:
  - Why the legacy switch rather than the documented flags on macOS: both
    `kSecUseAuthenticationUIFail` and a non-interactive authentication context
    were measured raising the panel against the file-based login keychain.
  - That the switch is process-wide. It is held only for one synchronous
    main-actor read, and no other Keychain user runs in the macOS process.
  - That its deprecation warning is accepted on purpose.
  - Why iOS needs no switch: the item carries no access-control flags, so
    reading it never shows UI, and the one case the system cannot answer
    (before first unlock) already returns `errSecInteractionNotAllowed` without
    asking, which this file already maps to `nil`. For the same reason the
    measured-and-failed flag is not reached for there: it would guard a path
    that never prompts, with a mechanism that did not hold where it was tested.
- [ ] Rewrite the note that says the model reads the store on the main actor
  and "nothing here needs" otherwise. It is safe there only because a
  main-actor read the user did not ask for is non-interactive. An attended read
  on the main actor blocks the window while a panel stands, which is the
  recorded known limit.
- [ ] Build the app for macOS (Release) and for `generic/platform=iOS`. Run the
  app-layer test bundle. Derived data goes outside the repository root.

### Task 4: Source-gating keeps meaning what it claims

**Files:**
- Modify: `Tests/PisakaCoreTests/LeetCodeAccountSourceGatingTests.swift`

- [ ] Re-check rules 1–4 against the tree. The call shapes (`resolveAccount`,
  `awaitAccountResolution`, `refreshUserStatus`, `browser.load()`) do not
  change, so their pins stay.
- [ ] Rewrite the prose that describes the ad-hoc build's confirmation dialog
  as the cost of a resolution. After this change a resolution cannot raise it.
- [ ] Add rule 5: the read kind and its enforcement live in one place each.
  - The read kind's type and case names are spelled in no app file except
    `Platform/LeetCodeKeychainStore.swift`, which implements it, pinned by set
    equality. No view can choose an interactive read from a render path.
  - The macOS mechanism alone is pinned: `SecKeychainSetUserInteractionAllowed`
    is spelled in that file only, inside an `#if os(macOS)` block, and restored
    in a `defer`.
- [ ] Add rule 6: in `Sources/PisakaCore/LeetCodeModel.swift`:
  - The store's read member is spelled exactly once.
  - The attended kind is spelled at exactly the two sites named in Task 2.

  A new attended site then has to be argued rather than slipping into a path an
  appearance body reaches. The doc comment explains that this regression
  compiles, runs, and freezes only on the machine whose keychain disagrees.
- [ ] Run `swift test`. It must pass.

### Task 5: Verify acceptance criteria

- [ ] Run `swift test` (full Core suite).
- [ ] Run `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination
  'platform=macOS' test` (app bundle). Derived data goes under
  `~/Library/Developer/Xcode/DerivedData/pisaka-<purpose>`.
- [ ] Run `swiftlint --strict` from the repository root. It must be clean.
- [ ] Confirm the resolution-path test fails with the resolution site set to
  attended (Task 2), and record that in the progress log.

### Task 6: Update documentation

- [ ] `docs/architecture/core-leetcode.md`, L27:
  - Replace "an ad-hoc build costs a keychain confirmation dialog, out of
    scope" with the rule: resolution's reads are unattended and forbidden to
    interact, because an on-appear body runs inside the window's layout pass and
    a panel there freezes the app.
  - State the cost: a genuinely locked login keychain now reads as no session
    until the user does something explicit, which then asks.
  - State the known limit: an attended read still blocks the main thread while
    its panel stands, and the app resumes once the panel is answered.
- [ ] `docs/architecture/core-leetcode.md`, `LeetCodeCredentials.swift` entry:
  the read kind and its defaults. Keychain-store entry: the macOS mechanism, why
  iOS runs today's query unchanged, and the conditioned main-actor sentence.
- [ ] The `LeetCodeAccountSourceGatingTests` inventory and rules 5–6 wherever
  that doc lists them.
- [ ] `CLAUDE.md`: leave unchanged. "Nothing is read or requested until the
  feature is first used" stays true, and the index lines stay accurate.
- [ ] README / `docs/FEATURES.md`: no user-facing change, so leave unchanged.

## Post-Completion

Manual verification, done by running the app rather than by reasoning:

1. Build a local copy the login keychain does not recognise, with a session
   stored by a different build. Open Preferences → the problem-catalog tab.
   Expected:
   - no authorization panel
   - the pane renders
   - the account row reads as not signed in
   - the window stays responsive
2. On the same copy, trigger an explicit action: open a problem, or Run. The
   panel may appear. Answering it proceeds; dismissing it reports "not signed
   in" in the ordinary way. Either way the app resumes. The window does not
   redraw while the panel stands (the known limit).
3. On a copy the keychain recognises:
   - a stored session still resolves as signed in
   - the confirmation still corrects a dead session
   - sign-in and sign-out behave as before
4. iOS: a stored session still resolves on the Settings screen and the catalog
   route.
