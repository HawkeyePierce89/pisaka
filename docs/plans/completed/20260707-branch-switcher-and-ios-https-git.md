# Branch Switcher (both platforms) + iOS network git over HTTPS/PAT

## Overview

JetBrains-style branch widget on macOS and iOS: shows the current branch, lets you
switch to a local branch (checkout) or create-and-switch to a new branch off any ref
(including `origin/master`, fetching before branching). Part A is self-contained (local
branches + creating from local refs on both platforms, fetch from origin on macOS via the
system git). Part B adds network fetch on iOS over HTTPS with a Personal Access Token from
the Keychain.

All decidable logic (branch grouping/sorting/marking, git-ref name validation, remote-host
parsing, "dirty tree" flag, model, PAT-by-host selection) lives in PisakaCore under tests.
The widgets and git services (macOS git CLI, iOS libgit2) are thin IO. Git access stays
behind the async `GitServicing` protocol; new methods are defaulted in an extension so
existing test stubs keep compiling. The branch list reuses the existing `references(root:)`
(full refnames) — no separate `branches(...)` method is added; only `currentBranch` is new.

## Context

- Protocol/models: `Sources/PisakaCore/GitServicing.swift`, `GitError.swift`,
  `ChangedFile.swift`; new `BranchRef.swift` / `BranchSwitcherModel.swift` /
  `GitRefName.swift` / `RemoteHost.swift` / `GitCredentials.swift`. `references(root:)`
  already exists and returns full refnames — the branch list is built from it.
- Services: `Sources/Pisaka/GitCLIService.swift` (macOS, Process),
  `Sources/Pisaka/iOS/LibGit2Service.swift` (iOS, libgit2 C API).
- Orchestration with gates: `Sources/Pisaka/PisakaApp.swift` (`revertChanges` /
  `applyMerge` pattern — `autosave.suspend()` + `localChanges.beginRevert()` synchronously
  before the await, `defer` resume, tab resync via `model.reloadFromDisk` /
  `reconcileSavedBaseline`, refresh Changes/Log/tree), `Sources/Pisaka/iOS/RootView_iOS.swift`
  (iOS peer).
- UI points: macOS always-visible bottom bar in `Sources/Pisaka/ContentView.swift`; iOS —
  `RootView_iOS.swift` toolbar + `SettingsView_iOS.swift` for the PAT.
- Tests: `Tests/PisakaCoreTests/` (pattern from `LocalChangesModelTests`, `FileNameTests`,
  the `GitServicing` stub).
- Dependencies: none new. iOS libgit2 (`ibrahimcetin/libgit2`, exact 1.9.2) already ships
  HTTPS + Apple TLS. PAT via the `Security` framework (Keychain) in the iOS view layer.
- SSH on iOS is impossible with this libgit2 (its SSH transport is `GIT_SSH_EXEC`, i.e. it
  execs the system `ssh` binary — no subprocess on iOS), so the iOS network path is
  HTTPS-only and only works for an HTTPS `origin` URL.

## Development Approach

- Testing approach: Regular (code first, then tests). Each Core task ends with new/updated
  tests; `swift test` green before moving to the next.
- Domain logic in PisakaCore (Foundation-only); views thin and untested; macOS under
  `#if os(macOS)`, iOS in `Sources/Pisaka/iOS/`.
- New GitServicing methods are defaulted in a protocol extension so existing stubs keep
  compiling.
- CRITICAL: every task includes new/updated tests; all tests pass before the next task.

## Implementation Steps

### Task 1: Core — domain types and pure branch logic

Files:
- Create: `Sources/PisakaCore/BranchRef.swift`, `Sources/PisakaCore/GitRefName.swift`,
  `Sources/PisakaCore/RemoteHost.swift`
- Create: `Tests/PisakaCoreTests/BranchRefTests.swift`, `GitRefNameTests.swift`,
  `RemoteHostTests.swift`

Intent: all decidable widget logic — pure, testable, ahead of any IO.

- [x] `BranchRef` — value type (`Equatable`/`Identifiable`): `name` (full, e.g.
  `refs/remotes/origin/master` or short `master`), `isRemote`, `remoteName?`, `shortName`
  (for display), `isCurrent`. Plus pure grouping/sorting: build `[BranchRef]` **from full
  refnames** (the shape `GitServicing.references(root:)` returns) + the current short name;
  split into Local/Remote, drop tags and any `.../HEAD` symbolic ref, sort by name, mark the
  current one; substring name filter (case-insensitive).
- [x] `GitRefName.isValid(_:)` — validate a new branch name per git check-ref-format rules
  (reject spaces, `..`, `~^:?*[`, control chars, leading/trailing `/`, `.lock` suffix, `@{`,
  a lone `@`, a leading dot / dot after `/`). Separate from `isValidFileName`.
- [x] `RemoteHost.host(fromRemoteURL:)` — extract the host from an **HTTPS** remote URL
  (`https://user@github.com:443/u/r.git` → `github.com`), the Keychain key for PAT selection
  in Part B. Returns `nil` for a non-http(s) URL (e.g. an scp-style `git@github.com:u/r.git`,
  which can't be fetched with a PAT on iOS anyway) or garbage.
- [x] Tests for grouping/sorting/marking/filter (from refnames + current, detached →
  none current, tag/`HEAD` dropped), name validation (valid and every invalid class), host
  parsing (https with/without user/port/`.git`; scp-style → nil; garbage → nil).
- [x] `swift test` — green.

### Task 2: Core — extend GitServicing and errors

Files:
- Modify: `Sources/PisakaCore/GitServicing.swift`, `Sources/PisakaCore/GitError.swift`
- Create/Modify: `Tests/PisakaCoreTests/GitErrorTests.swift`

Intent: describe the branch/fetch git surface behind the protocol, with defaults for
existing stubs. Reuse the existing `references(root:)` for the branch list — add only
`currentBranch` plus the mutations/fetch.

- [x] Add async methods to `GitServicing`: `currentBranch(root:) -> BranchRef?`,
  `checkout(branch:root:)` (local branch), `createAndCheckout(name:startPoint:root:)`
  (create+switch in one step), `fetch(remote:root:)`. Default them in the protocol
  extension — `currentBranch` → `nil`; `checkout`/`createAndCheckout`/`fetch` → `throw
  GitError.gitUnavailable` (there is no `GitError.unsupported`; `gitUnavailable` is the
  existing "this stub/service can't do it" signal) — so Local Changes/merge stubs keep
  compiling. Do NOT add a `branches(...)` method: the list comes from the existing
  `references(root:)`.
- [x] `GitError`: add case `checkoutFailed(reason:)` (blocked checkout — carries the exact
  git message naming the conflicting files), `fetchFailed(reason:)`, and
  `credentialsRequired(host:)` (Part B: no PAT for that host); extend `errorDescription` for
  each (human-readable text, `credentialsRequired` → e.g. "Add a Personal Access Token for
  <host> in Settings").
- [x] `GitErrorTests` for the human-readable `errorDescription` of the new cases; confirm
  existing GitServicing stubs in tests compile without implementing the new methods.
- [x] `swift test` — green.

### Task 3: Core — BranchSwitcherModel

Files:
- Create: `Sources/PisakaCore/BranchSwitcherModel.swift`
- Create: `Tests/PisakaCoreTests/BranchSwitcherModelTests.swift`

Intent: `@MainActor ObservableObject` mirroring `LocalChangesModel`'s shape — inject
`GitServicing`, all branching logic in pure static helpers.

- [x] Publishes `branches`, `current`, `filterText`, `isWorkingTreeDirty`, `errorMessage`,
  `root`. Methods: `refresh(root:) async` (loads the list via `references(root:)` +
  `currentBranch(root:)` fed through the Task-1 builder, and the dirty-tree flag via
  non-empty `changedFiles`), `switchTo(_:) async` (checkout; on `checkoutFailed` puts the
  git message into `errorMessage`), `createBranch(name:startPoint:) async` (validates the
  name via `GitRefName`; if `startPoint` is a remote ref: fetch first, and on failure signal
  the caller to "offer create-from-local or cancel").
- [x] Pure helpers (testable without IO): the "remote start requires fetch" decision,
  treating a remote-branch click as "create from this remote with a pre-filled name" (derive
  the default name from `shortName`), reconcile selection/filter after refresh.
- [x] Tests with a stub `GitServicing`: refresh fills the groups (from stub `references` +
  `currentBranch`) and the dirty-tree flag; `switchTo` on success / on `checkoutFailed`;
  `createBranch` with valid/invalid name; a remote start calls fetch first; a fetch failure
  returns the "offline" decision.
- [x] `swift test` — green.

### Task 4: macOS — GitCLIService branch/fetch implementation

Files:
- Modify: `Sources/Pisaka/GitCLIService.swift`

Intent: thin Process IO over the system git; the list reuses `references`, so only
`currentBranch`/`checkout`/`createAndCheckout`/`fetch` are added; fetch delegates trivially
to git.

- [x] `currentBranch`: `git symbolic-ref --short HEAD` (or rev-parse) → a `BranchRef` for the
  current local branch; detached → `nil`.
- [x] `checkout`: `git checkout <branch>`; on non-zero exit throw
  `GitError.checkoutFailed(reason: stderr)` (stderr names the conflicting files).
  `createAndCheckout`: `git checkout -b <name> <startPoint>`. `fetch`: `git fetch <remote>`
  (inherits system credentials); non-zero exit → `GitError.fetchFailed`.
- [x] Branch methods async through the same serial `run(_:in:)` as the rest of the service.
- [x] Check: `swift test` (Core) green (service is in the app target); the build is verified
  in Task 10.

### Task 5: iOS — LibGit2Service branch implementation (no network)

Files:
- Modify: `Sources/Pisaka/iOS/LibGit2Service.swift`

Intent: the iOS peer via the libgit2 C API, same Core values; network fetch is not wired in
Part A yet.

- [x] `currentBranch`: via `git_repository_head` / `git_reference_*`, produce the same
  `BranchRef`; unborn/detached → `nil`. `checkout`: `git_checkout_tree` on the branch tree +
  `git_repository_set_head`; on conflict (`GIT_ECONFLICT`) throw
  `GitError.checkoutFailed(reason:)` with the conflicting paths from libgit2.
  `createAndCheckout`: `git_branch_create` from the start ref's commit + checkout.
- [x] `fetch(remote:root:)`: in Part A throws `GitError.credentialsRequired` (network is
  enabled in Part B), so creating from a remote ref on iOS correctly offers "create from
  local or cancel".
- [x] All calls on the service's serial queue under the security scope, like the rest of the
  libgit2 code.
- [x] Check: `swift test` green; iOS build verified in Task 10.

### Task 6: macOS — widget and orchestration in PisakaApp

Files:
- Create: `Sources/Pisaka/BranchSwitcherView.swift`
- Modify: `Sources/Pisaka/ContentView.swift`, `Sources/Pisaka/PisakaApp.swift`

Intent: thin widget in the always-visible bottom bar (JetBrains status-bar convention) +
orchestration under the same gates as revert/apply-merge.

- [x] Widget: current branch in the bottom bar; on click — a popover with the Local/Remote
  list, the current one marked, a filter field; a "New Branch…" item (name + start point,
  default HEAD, any ref allowed). A remote-branch click → create dialog with a pre-filled
  name. Before checkout on a dirty tree — a warning that checkout may be blocked (git decides;
  on a real refusal show git's `errorMessage`).
- [x] Orchestration in `PisakaApp` (a wrapper around `switchTo` / `createBranch`):
  synchronously before the await — `autosave.suspend()` + `localChanges.beginRevert()`
  (project-tree ops gate), `defer` resume / endRevert; snapshot open-tab buffers; on success
  — tab resync (`reloadFromDisk` for clean, `reconcileSavedBaseline`+beep for edited), refresh
  the tree (`treeRevision`), Local Changes and Log (with a pinned generation, like
  `openFolder`).
- [x] Construct `BranchSwitcherModel` alongside `localChanges`/`commitLog`; refresh on
  openFolder and after a successful switch/create.
- [x] `swift test` green (logic covered in Task 3; view untested).

### Task 7: iOS — widget and orchestration in RootView_iOS

Files:
- Create: `Sources/Pisaka/iOS/BranchSwitcherView_iOS.swift`
- Modify: `Sources/Pisaka/iOS/RootView_iOS.swift`

Intent: iOS peer of the widget and orchestration, minus the gates iOS lacks (the same ones
the iOS revert path uses).

- [x] Widget: current branch in the toolbar/nav; a tap — sheet/popover with the Local/Remote
  list + filter + "New Branch…". The same create-from-remote flow (in Part A fetch is
  unavailable on iOS → offer create-from-local or cancel).
- [x] Orchestration in `RootView_iOS`: the same gates (autosave pause / tree lock, like the
  iOS revert path), tab resync, refresh Local Changes/Log via the existing generation-pinned
  path (`prepareForFolderChange` / `prepareForRefresh`).
- [x] `swift test` green.

### Task 8: Part B — iOS fetch over HTTPS (public repo, no credentials)

Files:
- Modify: `Sources/Pisaka/iOS/LibGit2Service.swift`
- Create: `Sources/PisakaCore/GitCredentials.swift`,
  `Tests/PisakaCoreTests/GitCredentialsTests.swift`

Intent: first enable and verify the network HTTPS fetch itself on iOS (Apple TLS backend, no
new dependencies), ahead of the credentials UI.

- [x] Implement `fetch(remote:root:)` via `git_remote_lookup` + `git_remote_fetch` with
  `git_fetch_options` (HTTPS through the built-in Apple TLS). For a public repo — no
  credentials callback.
- [x] Core: `GitCredentials` — pure credential-by-host selection logic (uses
  `RemoteHost.host(...)`), a `CredentialStore` protocol (lookup/save/delete by host),
  defaulted so an absent token is an explicit signal. Tests for host selection / absent
  token.
- [x] `swift test` green. (The real "does a public HTTPS repo fetch on device" check is in
  Post-Completion, since it needs a device/network.)

### Task 9: Part B — PAT in Keychain + Settings + credentials-callback fetch

Files:
- Create: `Sources/Pisaka/iOS/KeychainCredentialStore.swift`
- Modify: `Sources/Pisaka/iOS/LibGit2Service.swift`, `Sources/Pisaka/iOS/SettingsView_iOS.swift`,
  `Sources/Pisaka/iOS/RootView_iOS.swift`

Intent: the user stores a PAT (Keychain, key = remote host); fetch supplies it; no token →
message + go to Settings.

- [x] `KeychainCredentialStore` (iOS view, `Security` framework) implements Core's
  `CredentialStore` — save/lookup/delete the PAT by host. No new dependencies.
- [x] Wire a credentials callback into `git_fetch_options`
  (`GIT_CREDENTIAL_USERPASS_PLAINTEXT`: username + PAT as the password; username
  `"x-access-token"` for GitHub, any non-empty otherwise). When fetch needs auth and there is
  no token → `GitError.credentialsRequired(host:)`. The host comes from the `origin` remote
  URL via `RemoteHost.host(...)`; a non-HTTPS origin yields no host → surface a clear "HTTPS
  origin required" error.
- [x] Settings PAT UI (`SettingsView_iOS`): a section to manage the token by host
  (enter/save/delete). On `credentialsRequired` in the branch-create flow — report and direct
  to this screen.
- [x] Tests: the selection/absent-token logic already lives in Core (Task 8); the Keychain
  wrapper is thin IO, untested.
- [x] `swift test` green.

### Task 10: Verify acceptance criteria

- [x] `swift test` — the whole Core suite green.
- [x] `xcodegen generate` if needed; `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka
  -destination 'platform=macOS' build` — green.
- [x] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'generic/platform=iOS'
  build` — green (covers libgit2 linking).
- [x] Confirm the new Core tests cover: branch grouping (from refnames + current), name
  validation, remote-host parsing, the model, credential-by-host selection.

### Task 11: Update documentation

- [x] Update `CLAUDE.md` (new Core files:
  BranchRef/GitRefName/RemoteHost/BranchSwitcherModel/GitCredentials; the new GitServicing
  methods reusing `references`; widgets and orchestration; iOS PAT/Keychain path; SSH-on-iOS
  is out — HTTPS/PAT only).
- [x] Update `README.md` (the branch-switcher feature and the iOS PAT in the feature
  list/shortcuts, if applicable).

## Post-Completion (manual, require a device/network — outside automation)

- Part B runtime check: before the credentials UI, run a fetch of a public HTTPS repo on the
  iOS Simulator/device and confirm the network actually works.
- iOS acceptance: add a PAT in Settings → create a branch from `origin/master` → confirm the
  HTTPS fetch passes and the branch is created. Note: iOS network fetch works only for an
  **HTTPS `origin`** URL — an SSH remote (`git@…`) can't be fetched with a PAT (SSH is
  exec-based, unavailable on iOS).
- macOS acceptance: switching local branches; creating from `origin/master` (fetch first); a
  dirty tree shows the warning; a blocked checkout shows the exact git message; tabs and the
  Changes/Log panels reflect the new branch.
