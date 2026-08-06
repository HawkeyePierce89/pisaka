# Click on Remote Branch → "Checkout" / "New Branch from…" Menu

## Overview

Change the behavior of clicking a remote branch in the branch-switcher on both
platforms: instead of jumping straight into the create-branch dialog, a
remote-branch row becomes a small menu with two actions — Checkout (git DWIM)
and New Branch from 'origin/x'… (the existing create flow). All the "what to do"
logic is a pure, testable function in PisakaCore; the model gains one new entry
point that executes the decision through the already-existing checkout /
create+checkout paths without fetch; the view layer and app orchestration stay
thin and reuse the mechanics of an ordinary branch switch.

## Context

- Files involved:
  - `Sources/PisakaCore/BranchSwitcherModel.swift` — add the pure decision
    function (following the `defaultBranchName(forRemote:)` precedent) + the
    model method `checkoutRemote(...)`.
  - `Sources/PisakaCore/BranchRef.swift` — `BranchRef` type (unchanged, for
    reference).
  - `Sources/Pisaka/BranchSwitcherView.swift` (macOS) — remote-branch row → two-
    item menu; new callback `onCheckoutRemote`.
  - `Sources/Pisaka/iOS/BranchSwitcherView_iOS.swift` — same for the iOS sheet;
    the new callback dismisses the sheet (like `onSwitch`/`onCreateBranch`) and
    the dirty-tree confirmation before Checkout is routed separately from the
    local-switch confirmation.
  - `Sources/Pisaka/ContentView.swift` — thread the new callback down to
    `BranchSwitcherView`.
  - `Sources/Pisaka/PisakaApp.swift` — new handler `checkoutRemote(_:)` (mirror
    of `switchBranch`, via `runBranchOperation`).
  - `Sources/Pisaka/iOS/RootView_iOS.swift` — new handler `checkoutRemote(...)`
    (mirror of `switchBranch`).
  - `Tests/PisakaCoreTests/BranchSwitcherModelTests.swift` — tests for the
    decision function and the model path.
- Related patterns:
  - Pure static function + enum result: `defaultBranchName(forRemote:)`,
    `StartPoint`, `CreateOutcome`.
  - Origin-generation pinning + trailing refresh: `switchTo(_:originGeneration:)`,
    `createBranch(...)`.
  - App orchestration: `runBranchOperation(_:)` already accepts `() async ->
    Bool`; `switchBranch` shows the dirty-tree warning and calls git;
    `resyncOpenTabsAfterCheckout` / `finishBranchOperation` for tab resync and
    Changes/Log/tree refresh.
  - iOS sheet wiring: the outer `BranchSwitcherView_iOS` wraps each sub-callback
    as `{ ...; isPresented = false; onX(...) }` (see `onSwitch`/`onCreateBranch`).
  - Test stub `StubGit` in `BranchSwitcherModelTests` (records `checkedOut`,
    `created`, `fetched`, supports `checkoutError`/`createError`).
- Dependencies: none new. `GitServicing` is not extended — the existing
  `checkout`/`createAndCheckout` are sufficient.

## Development Approach

- **Testing approach**: TDD for the Core tasks (decision function and model
  path) — following the precedent of the other Core types; the view layer stays
  thin and is not tested.
- Complete each task fully before moving to the next.
- **CRITICAL: every task MUST include new/updated tests (Core tasks).**
- **CRITICAL: all tests must pass before starting the next task.**

## Implementation Steps

### Task 1: Pure decision function in Core

**Files:**
- Modify: `Sources/PisakaCore/BranchSwitcherModel.swift`
- Modify: `Tests/PisakaCoreTests/BranchSwitcherModelTests.swift`

- [x] Add a public `enum RemoteCheckoutDecision: Equatable` with cases
  `checkoutLocal(BranchRef)` (a same-named local already exists) and
  `createLocal(name: String, from: BranchRef)` (create a same-named local from
  the remote ref).
- [x] Add a public static function `remoteCheckoutDecision(for remote: BranchRef,
  among branches: [BranchRef]) -> RemoteCheckoutDecision`: the local name =
  `defaultBranchName(forRemote: remote)`; if any local (`BranchRef.locals`) has
  that `shortName` → `.checkoutLocal(thatLocal)`, otherwise → `.createLocal(name:
  name, from: remote)`. No fetch, purely a decision over the passed list.
- [x] Write tests: remote with no same-named local → `.createLocal(name:from:)`;
  remote with a same-named local → `.checkoutLocal(local)`; verify the
  `<remote>/` prefix strip (`origin/feature` → `feature`); that remote branches
  are not treated as candidates for "the local".
- [x] Run `swift test` — must pass before Task 2.

### Task 2: Model entry point `checkoutRemote` executing the decision

**Files:**
- Modify: `Sources/PisakaCore/BranchSwitcherModel.swift`
- Modify: `Tests/PisakaCoreTests/BranchSwitcherModelTests.swift`

- [x] Add `@discardableResult public func checkoutRemote(_ remote: BranchRef,
  originGeneration: Int? = nil) async -> Bool`: compute `remoteCheckoutDecision(
  for: remote, among: branches)` in the task body and execute it through the
  existing paths — `.checkoutLocal(local)` → `return await switchTo(local,
  originGeneration:)`; `.createLocal(name, from)` → `await createBranch(name:,
  from: .ref(from), fetchRemote: false, originGeneration:)`, return `== .created`.
  The same origin-generation pinning and trailing refresh are inherited from the
  delegates; no fetch is performed (`fetchRemote: false`).
- [x] Write model-path tests: (a) existing local → `checkedOut` contains the
  short name, `current` updated, `fetched` empty, returns `true`; (b) no local →
  `created` contains `(name, startPoint == full refname of the remote ref)`,
  `fetched` empty (no fetch), returns `true`; (c) failure — blocked checkout of
  an existing local (`checkoutError`) → `false` + `errorMessage`; and/or a create
  error on the create path (`createError`) → `false` + `errorMessage`.
- [x] MANDATORY — stale `originGeneration` test on the CREATE path: with a
  `stale` generation (older than the model's current `refreshGeneration`),
  `checkoutRemote` must bail with `false`, make NO git call (`created` empty,
  `checkedOut` empty, `fetched` empty), and leave `errorMessage == nil` (no error
  is written on a superseded bail). This locks the "bail without a git call and
  without writing `errorMessage`" contract the recent iOS silent-exit fix relies
  on, and pins that a decision computed over an already-cleared `branches` (after
  a folder switch) never reaches git. (Add a symmetric stale test on the
  `.checkoutLocal` path too if the stub makes it cheap, but the create-path
  assertion is required.)
- [x] Run `swift test` — must pass before Task 3.

### Task 3: macOS UI and orchestration

**Files:**
- Modify: `Sources/Pisaka/BranchSwitcherView.swift`
- Modify: `Sources/Pisaka/ContentView.swift`
- Modify: `Sources/Pisaka/PisakaApp.swift`

- [x] `BranchSwitcherView`: add a callback `onCheckoutRemote: (BranchRef) -> Void
  = { _ in }`; replace the remote-branch row's single Button with a `Menu` of two
  items — "Checkout" (`onCheckoutRemote(branch)`) and "New Branch from
  '\(branch.shortName)'…" (`onCreateFromRemote(branch)`), dismissing the popover
  on selection. Do not change the local-branch rows.
- [x] `ContentView`: add a parameter `onCheckoutRemote: (BranchRef) -> Void = { _
  in }` and thread it into `BranchSwitcherView(... onCheckoutRemote:
  onCheckoutRemote)`.
- [x] `PisakaApp`: add a handler `checkoutRemote(_ ref: BranchRef)` — mirror of
  `switchBranch`: the same dirty-tree warning (the checkout part of DWIM may be
  blocked just the same), synchronous pinning of `currentRefreshGeneration`, then
  `runBranchOperation { await self.branchSwitcher.checkoutRemote(ref,
  originGeneration: origin) }`; thread `onCheckoutRemote: { checkoutRemote($0) }`
  into `ContentView(...)` alongside `onCreateBranchFromRemote`.
- [x] Build the macOS target (`xcodebuild ... -destination 'platform=macOS'
  build`) — must build.

### Task 4: iOS UI and orchestration

**Files:**
- Modify: `Sources/Pisaka/iOS/BranchSwitcherView_iOS.swift`
- Modify: `Sources/Pisaka/iOS/RootView_iOS.swift`

- [x] `BranchSwitcherView_iOS` (outer wrapper): add a callback `onCheckoutRemote:
  (BranchRef) -> Void = { _ in }` and wire it into the `.sheet`'s
  `BranchListSheet_iOS(...)` exactly like the existing `onSwitch`/`onCreateBranch`
  — `onCheckoutRemote: { branch in isPresented = false; onCheckoutRemote(branch)
  }` — so selecting Checkout dismisses the sheet before the handler runs.
- [x] `BranchListSheet_iOS`: add the matching `var onCheckoutRemote: (BranchRef)
  -> Void` property; replace the remote-branch row's direct `beginCreate(...)`
  action with a `Menu` of two items — "Checkout" (calls a new
  `tapCheckoutRemote(branch)`) and "New Branch from '\(branch.shortName)'…" (the
  existing `beginCreate(from: .ref(branch), defaultName:
  BranchSwitcherModel.defaultBranchName(forRemote: branch))`). Do not change the
  local-branch rows or the create alert.
- [x] CRITICAL — separate dirty-confirmation routing (the review trap): the
  confirmed dirty-tree checkout MUST route a *remote* branch into
  `onCheckoutRemote` (the DWIM path), NOT `onSwitch` (which would run `git
  checkout origin/foo` → detached HEAD). Do this by replacing the single `@State
  private var dirtySwitchTarget: BranchRef?` with an enum-typed target, e.g.
  `private enum DirtyCheckoutTarget: Equatable { case local(BranchRef); case
  remote(BranchRef) }` and `@State private var dirtyCheckoutTarget:
  DirtyCheckoutTarget?`. Update `dirtySwitchBinding` and the
  `.confirmationDialog(presenting:)` to use `dirtyCheckoutTarget`; the "Switch"
  button switches on the target — `.local(b) → onSwitch(b)`, `.remote(b) →
  onCheckoutRemote(b)` — and Cancel clears it. (A separate second `@State` var
  would also satisfy this; the enum is preferred to keep one confirmation dialog.)
- [x] `tapCheckoutRemote(branch)`: mirror `tapLocal` but for the remote/DWIM path
  — on a clean tree call `onCheckoutRemote(branch)` directly; on a dirty tree set
  `dirtyCheckoutTarget = .remote(branch)` (no `isCurrent` guard — a remote ref is
  never the current branch). Update `tapLocal` to set `dirtyCheckoutTarget =
  .local(branch)` on the dirty path.
- [x] `RootView_iOS`: add `@MainActor func checkoutRemote(_ branch: BranchRef,
  originGeneration: Int? = nil) async` — mirror of `switchBranch`, calling
  `branchSwitcher.checkoutRemote(branch, originGeneration:)`, with the same tab
  snapshot/resync and `finishBranchOperation`; in the toolbar thread
  `onCheckoutRemote: { branch in let origin =
  branchSwitcher.currentRefreshGeneration; Task { await checkoutRemote(branch,
  originGeneration: origin) } }` into `BranchSwitcherView_iOS`.
- [x] Build the iOS target (`xcodebuild ... -destination 'generic/platform=iOS'
  build`) — must build.

### Task 5: Verify acceptance criteria

- [x] `swift test` — the whole PisakaCore suite green.
- [x] `xcodegen generate` if needed, then build the macOS target `xcodebuild
  -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' build`.
- [x] Build the iOS target `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka
  -destination 'generic/platform=iOS' build`.
- [x] Verify against acceptance criteria in code: clicking a remote branch yields
  a two-item menu (no direct jump into create); Checkout with no local creates a
  local at the remote ref's commit and makes it current, with an existing local
  it just switches; on iOS the Checkout item dismisses the sheet and the dirty-
  tree confirmation for a remote Checkout routes into `onCheckoutRemote` (not
  `onSwitch`); "New Branch from…" leads to the previous dialog with the previous
  behavior (fetch-first + fallback); a blocked checkout shows git's message; the
  warning before the attempt matches the local switch.

### Task 6: Update documentation

- [x] Update `CLAUDE.md`: in the `BranchSwitcherModel` description (new decision
  function + `checkoutRemote`), `BranchSwitcherView`/`BranchSwitcherView_iOS`
  (remote row = Checkout / New Branch from… menu; iOS sheet dismisses on Checkout
  and the dirty-confirmation routes remote checkouts through the DWIM path), and
  the app orchestration in `PisakaApp`/`RootView_iOS` (handler `checkoutRemote`,
  mirror of `switchBranch`).
