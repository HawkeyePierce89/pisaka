# LeetCode: resolve the account on first use, not at launch

## Overview

Today `LeetCodeModel.init` reads the credential store synchronously and both app
layers fire `refreshUserStatus()` from a launch-time `onAppear`. Every launch
therefore costs a Keychain read and a network round trip for a feature the user
may never open — and on an ad-hoc-signed developer build, a Keychain
confirmation dialog.

This work moves that moment: the model resolves its account state **the first
time any code path needs to know whether there is a session**, and never before.
Construction becomes inert. The published account state grows a third value —
"not asked yet" — so no surface claims "signed in" or "signed out" while the
model does not know. Everything past resolution behaves exactly as it does
today.

The decision of *what counts as first use* lives in Core. Views trigger
resolution only where they **render account state** (a sheet, a Settings tab, an
account screen); every credential-needing operation resolves itself, so no view
has to remember. One app site is neither — the macOS menu's Sign In…, which
cannot observe its own opening and therefore resolves *and awaits the
confirmation* before deciding whether to open the login sheet.

## Context

Core (`Sources/PisakaCore/`):

- `LeetCodeModel.swift` — the whole change: the tri-state, the resolution
  primitive, the public awaitable entry, and the resolving entries
  (`requireCredentials`, `refreshUserStatus`, `statement(forFileAt:in:)`,
  `signIn`, `signOut`, `markSessionAccepted/Rejected`).
- `LeetCodeBrowserModel.swift` — `load()`/`refresh()` resolve **before** they
  bump their generation token (resolution fires `sessionDidChange()` through the
  owner's observer, which bumps it too; resolving after the capture would have
  the browser discard its own work).
- `LeetCodeJudgeModel.swift` — reaches the session only through
  `owner.requireCredentials()`, so it inherits resolution; no change beyond
  checking that the unresolved→signed-in fan-out reaches `sessionDidChange()`.
- `LeetCodeCatalog.swift` — untouched; it keeps being *declared* the session,
  now from resolution instead of from `init`.

App (`Sources/Pisaka/`):

- `PisakaApp.swift` — the launch `Task { await leetCode.refreshUserStatus() }`
  (≈ line 1164) is removed; `LeetCodeCommands`' `onSignIn` resolves and awaits
  before deciding; the `makeLeetCode` doc comment claiming the Keychain is read
  in `init` is corrected.
- `iOS/RootView_iOS.swift` — the same launch call in the `onAppear` beside
  `LeetCodeFolder_iOS.publish` is removed.
- `LeetCodeOpenProblemSheet.swift` (the sheet and the menu), `SettingsView.swift`
  (`LeetCodeSettingsView`), `iOS/LeetCodeRoute_iOS.swift` (account screen),
  `iOS/SettingsView_iOS.swift` (LeetCode section) — the four surfaces that
  render account state resolve on appear.

Tests:

- `Tests/PisakaCoreTests/Support/ScriptedLeetCodeTransport.swift` —
  `InMemoryLeetCodeCredentialStore` gains `loadCount`.
- `Tests/PisakaCoreTests/LeetCodeModelTests.swift`,
  `LeetCodeBrowserModelTests.swift`, `LeetCodeJudgeModelTests.swift` — new
  assertions plus re-pointing.
- New `Tests/PisakaCoreTests/LeetCodeAccountSourceGatingTests.swift` — the
  repository-file rules, following `LocalHistorySourceGatingTests`' shape and
  reusing `LSPSourceGatingTests.strippingCommentsAndStringLiterals`.

Docs: `docs/architecture/core-leetcode.md` (three paragraphs + decision **L27**),
`CLAUDE.md` (the cross-cutting LeetCode bullet).

## Development Approach

- **Testing approach**: Regular (code first, then tests), matching the
  repository's habit; every task ships its tests and `swift test` must be green
  before the next one starts.
- All logic in `PisakaCore`; views only trigger and render. No brand names
  anywhere.
- Async tests stage races through the transport's per-route `Gate` and the public
  awaitable resolution entry — never a sleep, never a `Task.yield()` spin.

## Implementation Steps

### Task 1: The tri-state, the resolution primitive and its awaitable entry

**Files:**

- Modify: `Sources/PisakaCore/LeetCodeModel.swift`
- Modify: `Tests/PisakaCoreTests/Support/ScriptedLeetCodeTransport.swift`
- Modify: `Tests/PisakaCoreTests/LeetCodeModelTests.swift`

Intent: make constructing a model inert, and give the account one closed
vocabulary.

Design decisions to implement as stated:

- A closed `LeetCodeAccountState` — `unresolved` / `signedIn` / `signedOut` —
  declared in `LeetCodeModel.swift` (a new type in an existing file, so
  `CLAUDE.md`'s per-file index does not move). The enum rather than a second
  boolean: this repository's published vocabularies are closed on purpose, and a
  separate `isAccountResolved` flag admits the meaningless pair (unresolved,
  signed in) that a view can read without noticing.
- `@Published public private(set) var account: LeetCodeAccountState =
  .unresolved`, and `public var isSignedIn: Bool { account.isSignedIn }` as a
  **computed** property — every existing reader (the menu, the sheet, both
  Settings surfaces, the iOS screen, the judge, the browser) keeps compiling and
  keeps meaning what it meant.
- The fan-out `didSet` moves from `isSignedIn` to `account`, guarded on
  `oldValue.isSignedIn != account.isSignedIn` — so it still fires only on a real
  flip, unresolved→signed-out reaches nobody (exactly as today's `false`→`false`),
  and unresolved→signed-in reaches the judge and the browser the same way a
  sign-in does.
- `init` stops reading the store, stops setting the state and stops declaring the
  session to the catalog. That whole block becomes
  `resolveAccount(startingConfirmation:)`: read through the existing
  `storedCredentials()` accessor (which already honours
  `storedCredentialsAreDiscarded`), cache the pair, publish
  `.signedIn`/`.signedOut`, declare the pair to the catalog **only when there is
  one** (the "undeclared means unconstrained" rule the doc already states), and
  — when `startingConfirmation` is true and a pair was found — start the one
  launch-shaped `refreshUserStatus()`.
- `public func resolveAccount()` is the idempotent, **synchronous** view-facing
  trigger (`startingConfirmation: true`). It is what the browser calls before its
  token capture and what the four rendering surfaces call on appear. The
  `startingConfirmation: false` spelling exists for one caller,
  `refreshUserStatus()` itself: without it, an explicit refresh on an unresolved
  model would resolve, spawn a second refresh, and put two user-status requests
  on the wire.
- The spawned confirmation is retained as `accountResolution: Task<Void, Never>?`,
  and the awaitable spelling is **public**: `public func awaitAccountResolution()
  async` resolves if needed and then awaits whatever confirmation the resolution
  started (returning at once when there is none). Following
  `LeetCodeJudgeModel.awaitSessionResolution()`'s shape, but public rather than
  internal, because it has two kinds of caller: the suites, which must await the
  confirmation instead of racing it, and exactly one app site — the macOS menu's
  Sign In… (Task 3), which cannot decide whether to open the login sheet off the
  *optimistic* state.
- `markSessionRejected()` publishes `.signedOut`; `markSessionAccepted()`
  publishes `.signedIn` under its existing credentials guard.

- [ ] add `LeetCodeAccountState`, the published `account`, the computed
      `isSignedIn` and the relocated `didSet`
- [ ] extract `init`'s store read into `resolveAccount(startingConfirmation:)` +
      public `resolveAccount()`; `init` is left touching nothing
- [ ] retain the confirmation task and expose the public `awaitAccountResolution()`
- [ ] add `loadCount` to `InMemoryLeetCodeCredentialStore`
- [ ] tests: constructing a model performs zero loads and zero transport calls;
      one `resolveAccount()` with a stored pair performs exactly one load and
      exactly one user-status request; a second and third `resolveAccount()`
      perform neither; with no stored pair, one load, no request, state
      `.signedOut`; the state is published **before** the request returns (the
      route held on the transport's `Gate`, `isSignedIn` asserted true while it is
      held); an explicit `refreshUserStatus()` on an unresolved model is one load
      and one request, not two
- [ ] tests for the awaitable entry, which are also what Task 3's app rule rests
      on: a stored pair the transport **rejects** with `notLoggedIn` leaves
      `account == .signedOut` after `awaitAccountResolution()`; a stored pair the
      transport **confirms** leaves `account == .signedIn` with the username
      published; `awaitAccountResolution()` on a model with no stored pair returns
      without a request and leaves `.signedOut`
- [ ] run `swift test` — must pass before Task 2

### Task 2: Every credential-needing entry resolves first

**Files:**

- Modify: `Sources/PisakaCore/LeetCodeModel.swift`,
  `Sources/PisakaCore/LeetCodeBrowserModel.swift`
- Modify: `Tests/PisakaCoreTests/LeetCodeModelTests.swift`,
  `LeetCodeBrowserModelTests.swift`, `LeetCodeJudgeModelTests.swift`

Intent: no view can forget to ask, because the model asks for itself.

- `requireCredentials()` resolves first — which covers `openProblem`, the judge's
  Run/Submit and its context resolution, and the browser's own credential lookup.
- `refreshUserStatus()` resolves with `startingConfirmation: false`, then proceeds
  unchanged.
- `statement(forFileAt:in:)` resolves **immediately after the association guard**
  — a solution file becoming the active tab is a use; a tab that is not one asks
  nothing. This is the placement that makes "the project tree, the editor, an
  ordinary tab switch never resolve" true by construction rather than by luck.
- `LeetCodeBrowserModel.load()` and `refresh()` call `owner.resolveAccount()` as
  their **first statement, before `generation += 1`** — resolution reaches
  `sessionDidChange()` through the owner's observer, which bumps that same token,
  so resolving after the capture would make the browser discard its own load.
  Note this ordering in a comment; it is the one non-obvious hazard in the change.
- `signIn(with:)` and `signOut()` consult the store for nothing new: they
  **declare** a resolved state (`.signedIn` / `.signedOut`) where they set the
  flag today. That is the same rule read from the other side, and it is what keeps
  a sign-out from reading the Keychain merely to throw the answer away —
  `storedCredentialsAreDiscarded` already makes any later resolution answer `nil`
  without a load.
- Existing tests that read `isSignedIn` straight after `makeModel` are re-pointed
  at an explicit first use (a `resolveAccount()` or the operation the test is
  actually about), not deleted. Tests that count requests now account for the one
  confirmation the first use starts — `awaitAccountResolution()` before the
  assertion, so the count is deterministic rather than timing-dependent.
  `testOpeningByNumberCreatesTheSeededFile`'s `count(for: .userStatus) == 0`
  becomes `1` for exactly this reason, and that is the behaviour the ticket asks
  for.

- [ ] add the resolve call to `requireCredentials`, `refreshUserStatus`,
      `statement(forFileAt:in:)`, `LeetCodeBrowserModel.load()`/`refresh()`
- [ ] have `signIn`/`signOut`/`markSessionAccepted`/`markSessionRejected` publish
      `account` instead of `isSignedIn`
- [ ] tests: each entry resolves on its own (one load), the next entry adds none;
      an ordinary tab switch to a non-solution file performs zero loads and zero
      requests; a sign-out before any resolution performs **zero loads** and leaves
      the state `.signedOut` (the `clear()` still runs, as today — the rule is that
      the Keychain is never *read* for an answer that is about to be discarded);
      the browser's first `load()` publishes rows rather than discarding them
      behind its own token; `invalidateInFlightWork`'s existing guarantees still
      hold
- [ ] re-point the existing tests that relied on `init` resolving
- [ ] run `swift test` — must pass before Task 3

### Task 3: The macOS surfaces

**Files:**

- Modify: `Sources/Pisaka/PisakaApp.swift`,
  `Sources/Pisaka/LeetCodeOpenProblemSheet.swift`,
  `Sources/Pisaka/SettingsView.swift`

- The launch `Task { await leetCode.refreshUserStatus() }` and its comment are
  removed; the model owns the moment.
- The Open Problem sheet resolves on appear (it renders the signed-out notice).
- The Preferences LeetCode tab resolves on appear (it renders the account row).
  Stated limit worth a comment: macOS may build a `Settings` tab before the user
  selects it, so opening Preferences for another tab can resolve — acceptable,
  because Preferences is an explicit act and the confirmation then happens at most
  once per run.
- **The menu.** It cannot observe its own opening, so under `.unresolved` it
  renders the neutral entry (Sign In…), and the decision moves into `onSignIn`,
  which is the one app site outside the four rendering surfaces that touches
  resolution. It must **not** decide off the optimistic state: `resolveAccount()`
  publishes `.signedIn` before the service has answered, so a stored-but-dead
  session would open no sheet, flip to `.signedOut` a moment later, and leave the
  user pressing Sign In… again. So `onSignIn` awaits: `await
  leetCode.awaitAccountResolution()`, then open the login sheet **iff `account !=
  .signedIn`**. A stored, *confirmed* session therefore lands in the ordinary
  signed-in state with no sheet; a genuinely absent or rejected one opens the
  sheet exactly as today; and a confirmation that cannot be made at all (offline,
  throttled) keeps the optimistic `.signedIn` and opens nothing — consistent with
  the existing rule that only a rejection is an answer. Sign Out stays reachable
  only from a resolved signed-in state, as it is today.
- The `makeLeetCode` doc comment's "the Keychain is read exactly once, in
  `LeetCodeModel.init`" sentence is corrected to say that building one touches
  nothing at all.

No unit tests here: SwiftUI glue is untested by convention; the model half of this
rule is Task 1's two awaitable-entry tests, and Task 5's repository-file suite is
the net for where the calls live.

- [ ] remove the launch call; resolve from the sheet and the Preferences tab
- [ ] make `onSignIn` resolve, await the confirmation, then open the sheet only
      when the state is not `.signedIn`
- [ ] correct the `makeLeetCode` comment
- [ ] run `swift test` and `swiftlint --strict` — must pass before Task 4

### Task 4: The iOS surfaces

**Files:**

- Modify: `Sources/Pisaka/iOS/RootView_iOS.swift`,
  `Sources/Pisaka/iOS/LeetCodeRoute_iOS.swift`,
  `Sources/Pisaka/iOS/SettingsView_iOS.swift`

- The launch `Task { await leetCode.refreshUserStatus() }` in
  `RootView_iOS.onAppear` is removed; `LeetCodeFolder_iOS.publish` stays exactly
  where it is (pointing the model at a folder reads no secret and makes no
  request).
- The account/open screen and the Settings screen's LeetCode section resolve on
  appear, for the reason their macOS twins do. iOS has no menu, so it needs no
  awaiting site.
- The comments on both platforms' `accountDescription` helpers that say "while the
  launch-time confirmation is still out" are corrected to name first use.

- [ ] remove the launch call; resolve from the two iOS surfaces that render the
      account
- [ ] correct the two comments
- [ ] run `swift test` and `swiftlint --strict` — must pass before Task 5

### Task 5: The repository-file assertion

**Files:**

- Create: `Tests/PisakaCoreTests/LeetCodeAccountSourceGatingTests.swift`

A small gating suite in the established shape — Foundation only, read through
`#filePath`, matched against **comment- and literal-stripped** text via
`LSPSourceGatingTests.strippingCommentsAndStringLiterals` (the ordinary reason:
these files quote their own rules in comments).

The rules:

- `refreshUserStatus(` is spelled in **no** file under `Sources/Pisaka` — by set
  equality over the app tree, not by naming the two files that used to call it.
  The confirmation is Core's to start, so the app layer having no caller at all is
  the stronger and more durable statement of "no launch-time site".
- Resolution — `resolveAccount(` and `awaitAccountResolution(` together — is
  reachable from exactly five app files: the **four that render account state**,
  pinned by **set equality** (`LeetCodeOpenProblemSheet.swift`,
  `SettingsView.swift`, `iOS/LeetCodeRoute_iOS.swift`,
  `iOS/SettingsView_iOS.swift`), plus `PisakaApp.swift`, pinned **by count** —
  exactly one spelling in the whole file, the menu's `onSignIn`. The count rather
  than membership is the point, `DatabaseViewerSourceGatingTests`' way:
  `PisakaApp.swift` renders no account state and is precisely the file the
  launch-time `onAppear` used to live in, so admitting it to the set by name would
  retire the regression the rule exists to catch, while a count of one lets the
  menu's site stand and still fails the moment a second, launch-shaped one appears
  beside it.
- The doc comment carries the inventory, as the other gating suites do, and says
  why `PisakaApp.swift` is counted rather than listed.

- [ ] write the suite with both rules, the count pin and its inventory comment
- [ ] run `swift test` — must pass before Task 6

### Task 6: Documentation

**Files:**

- Modify: `docs/architecture/core-leetcode.md`, `CLAUDE.md`

- The "*The account.* `isSignedIn` is **optimistic at launch**" paragraph becomes
  "optimistic at **first use**", and the `refreshUserStatus()` sentence stops
  saying "what the app calls at launch" — it is what resolution starts.
- The `init` description and the catalog's "the owner declares at launch" sentence
  follow the same edit; the `markSessionAccepted()` rationale's "the app calls it
  once, at launch" becomes "once, at first use".
- The `RootView_iOS` entry in the app-surfaces section stops saying it calls
  `refreshUserStatus()` at launch; the `LeetCodeOpenProblemSheet` entry records
  the menu's await-then-decide rule.
- New decision **L27** — *nothing is read or requested until the feature is used*
  — recording the rule, the tri-state it needs, where the resolution point sits,
  why `signIn`/`signOut` declare rather than consult, why the menu is the one app
  site that must **await** rather than read the optimistic state, and the trigger
  that surfaced it (a confirmation dialog on every launch of an ad-hoc-signed
  build, whose signature the login keychain cannot remember). The rule is recorded
  on its own terms, for both platforms; the signing question is named as out of
  scope.
- `CLAUDE.md`'s cross-cutting LeetCode bullet gains the clause: the store is not
  read and no request is made until the first use of the feature.

- [ ] update the four paragraphs and the two app-surfaces entries
- [ ] write L27 and bump the "decisions L1–L26" range line
- [ ] extend the `CLAUDE.md` bullet
- [ ] run `swift test` — must pass before Task 7

### Task 7: Verify acceptance criteria

- [ ] `swift test` green
- [ ] `swiftlint --strict` from the repository root clean, with no threshold
      raised and no new in-file disable
- [ ] the macOS app-test bundle green (`xcodebuild -project Pisaka.xcodeproj
      -scheme Pisaka -destination 'platform=macOS' test`, into a derived-data path
      outside the repository)
- [ ] the macOS and iOS builds green (`generic/platform=iOS` for the device arch)

## Post-Completion (manual, by the reviewer)

- Launch a fresh ad-hoc-signed Debug build, restore a session containing a
  LeetCode solution file among the **inactive** tabs, work in the editor: **no**
  Keychain dialog appears.
- Then use one LeetCode surface (⌘⌥P, ⌘⇧B, the Preferences LeetCode tab, or make a
  solution file the active tab): the dialog appears **once**, and every later use
  in that run is silent.
- Confirm the menu under an unused run shows "Sign In…", and that choosing it with
  a stored, confirmed session lands signed in without opening the login sheet —
  while a stored session that has since expired opens the login sheet after the
  confirmation comes back.
