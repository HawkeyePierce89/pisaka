# Pisaka app — platform shims & iOS layer

Design documentation moved verbatim from the root `CLAUDE.md` (which now holds only a one-line-per-file index). Each entry records a file's contract, invariants and the reasoning behind non-obvious decisions — read the relevant entry before modifying that file, and update it when behavior changes.

- **`Pisaka`** (the app target, `Sources/Pisaka/`) — a thin SwiftUI/AppKit
  (macOS) and SwiftUI/UIKit (iOS) layer. Views hold no domain logic; they
  observe `WorkspaceModel`/`LocalChangesModel`/`CommitLogModel`/`MergeModel`. The
  **macOS** files described below are all wrapped in `#if os(macOS)`; the
  **iOS** counterparts live in `Sources/Pisaka/iOS/` (each mirrors a macOS
  view), and a small platform-shim layer in `Sources/Pisaka/Platform/` bridges
  the per-platform APIs:
  - `Platform/PlatformColor.swift` — `PlatformColor` typealias (`NSColor` on
    macOS, `UIColor` on iOS) + `init(rgb:)` / `dynamic(light:dark:)` so
    `SyntaxTheme` resolves appearance-aware colors on both platforms (macOS output
    stays byte-identical — `PlatformColor == NSColor`). The diff-background
    palettes stay per-platform and are *not* routed through this bridge —
    `DiffColors` (raw `NSColor`) on macOS, a parallel `DiffColors_iOS` (raw
    `UIColor`) on iOS — using the system semantic colors directly.
  - `Platform/PlatformFeedback.swift` — `warning()` (beep on macOS, error haptic
    on iOS), the single reroute for every former `NSSound.beep()` call site.
  - `Platform/PlatformAlert.swift` — `presentMessage` over `NSAlert` /
    `UIAlertController`.
  - `Platform/PlatformRoute.swift` — `RoutePresentation` (separate window on
    macOS; sheet / navigation push on iOS, compact-vs-regular aware).
  - `Platform/LicenseCatalogLoader.swift` — the bundled-license reader shared by
    both Acknowledgements screens (one-shot `static let` cache, reads
    `Licenses/licenses.json` + every `.txt` beside it, all decisions in Core's
    `LicenseCatalog`). Documented in full in `app-shell.md`, since nothing in it
    is platform-specific.
  - `iOS/PisakaApp_iOS.swift` — the iOS `@main` App (the macOS `@main` is gated
    out under one-`@main`-per-platform `#if`).
  - `iOS/RootView_iOS.swift` — adaptive root: `NavigationSplitView` (iPad/regular
    width: project-tree sidebar + editor detail) vs `NavigationStack`
    (iPhone/compact: tree → pushed editor), plus the Local Changes / Git Log /
    Merge sheet routes and the revert/apply-merge orchestration (the iOS peer of
    `PisakaApp`, minus the autosave/project-tree gates iOS lacks). It also owns the
    `BranchSwitcherModel` (constructed alongside `localChanges`/`commitLog`,
    refreshed on folder open and after a successful switch/create) and hosts the
    `BranchSwitcherView_iOS` in the toolbar/nav; its switch/create/checkout-remote
    orchestration mirrors the iOS revert path's gates (autosave pause / tree lock),
    tab resync (`reloadFromDisk` for a clean tab, `reconcileSavedBaseline`+beep for an
    edited one), and generation-pinned Local Changes / Log refresh
    (`prepareForFolderChange` / `prepareForRefresh`). `checkoutRemote(_:
    originGeneration:)` is the git-DWIM peer of `PisakaApp.checkoutRemote` and a mirror
    of `switchBranch` (calling `branchSwitcher.checkoutRemote`, same snapshot/resync/
    `finishBranchOperation`); the toolbar threads `onCheckoutRemote` into
    `BranchSwitcherView_iOS` capturing `currentRefreshGeneration` synchronously before
    the `Task` hop, and the widget's dirty-tree confirmation routes a *remote* checkout
    here (not `switchBranch`, which would detach HEAD). A `credentialsRequired`
    outcome from a remote-start create directs the user to the Settings PAT screen.
  - `iOS/BranchSwitcherView_iOS.swift` — the iOS branch-switcher widget: the
    current branch shown in the toolbar/nav, tapped to a sheet/popover with the
    Local/Remote list (current marked), a filter field, and a "New Branch…" item. A
    remote-branch row is a two-item `Menu` — "Checkout" (git DWIM via
    `tapCheckoutRemote` → `onCheckoutRemote`) and "New Branch from '\(shortName)'…"
    (the existing create flow via `beginCreate`, pre-filled name; in Part A iOS fetch
    is unavailable → offer create-from-local or cancel; in Part B a real HTTPS fetch
    runs, needing a PAT for a private repo). The outer `BranchSwitcherView_iOS` wires
    `onCheckoutRemote` into `BranchListSheet_iOS` as `{ branch in isPresented = false;
    onCheckoutRemote(branch) }` so the sheet dismisses before the handler runs (the
    `onSwitch`/`onCreateBranch` pattern). The dirty-tree confirmation is routed by an
    enum-typed `DirtyCheckoutTarget` (`.local(BranchRef)`/`.remote(BranchRef)`)
    replacing the old single `dirtySwitchTarget`: `tapLocal` sets `.local` on a dirty
    tree, `tapCheckoutRemote` sets `.remote` (no `isCurrent` guard — a remote ref is
    never current), and the single `.confirmationDialog`'s "Switch" button routes
    `.local → onSwitch`, `.remote → onCheckoutRemote` — so a confirmed *remote*
    checkout goes through the DWIM path, not `onSwitch` (which would run `git checkout
    origin/foo` → detached HEAD). Thin `@ObservedObject
    BranchSwitcherModel` view (untested, logic in Core).
  - `iOS/CodeEditorView_iOS.swift` / `iOS/CodeEditorCoordinator_iOS.swift` — the
    `UITextView`-backed editor mirroring `CodeEditorView`: Neon highlighting,
    `IndentEngine`/`AutoPairEngine` wired through `UITextViewDelegate` with the
    same programmatic-edit re-entry guard and single-undo discipline; pinch-to-
    zoom font stepping (the iOS analog of macOS Cmd+scroll). No gutter/minimap on
    iOS (deferred).
  - `iOS/FilePicker_iOS.swift` / `iOS/SecurityScopedBookmarks.swift` — document-
    picker folder/file open + the `SecurityScopedFileService` decorator that
    brackets every `FileService` op with the registered scope's access grant;
    bookmark persistence via Core's `BookmarkStore`/`ScopedFileAccess`. Every
    mutating method is *forwarded* through `withScope` rather than left to inherit
    the protocol extension's default — including `ensureDirectory(at:)`, so a whole
    created chain lands under the covering scope's grant (iOS has no tree
    create/rename UI yet, so this is consistency, not a live call site).
    `SecurityScopedFileService` also conforms to `SecurityScopeProviding` (a small
    `AnyObject` protocol vending `withSecurityScope(covering:_:)`): `LibGit2Service`
    touches the working tree/index directly via `FileManager`/libgit2 rather than
    through `FileServicing`, so it can't rely on the decorator's per-op bracketing —
    it instead takes a `SecurityScopeProviding` and runs every git operation under
    the covering registered scope's grant (without it, on a real device every git
    operation — Local Changes / Log / revert / merge staging — would fail outside an
    active scope). The registry (`scopedURLs`) is `NSLock`-guarded and the service is
    `@unchecked Sendable` because it is read from `LibGit2Service`'s serial git queue
    while mutated on the main actor (folder open/close); `FileAccessController`
    releases the previous root's scope (`unregister`) before registering a new folder
    so stale grants don't accumulate. The "which registered scope covers this target"
    decision is the pure, tested `ScopedFileAccess.path(_:isWithin:)` in Core (an
    empty root scopes nothing). The iOS folder-open path (`RootView_iOS.handlePicked`)
    also synchronously registers the switch with `LocalChangesModel`/`CommitLogModel`
    (`prepareForFolderChange`/`prepareForRefresh` + a generation-pinned refresh),
    mirroring `PisakaApp.openFolder`, so an in-flight revert can't keep mutating the
    repo the user just left.
  - `iOS/TabStrip_iOS.swift` / `iOS/SettingsView_iOS.swift` — the open-tabs strip/
    switcher (form picked by Core's `TabLayout.presentation`) and the Preferences
    sheet bound to `SettingsStore`. `SettingsView_iOS` also carries the Personal
    Access Token section (Part B): enter / save / delete a PAT by remote host via the
    `KeychainCredentialStore`, the destination the branch-create flow directs the
    user to on a `credentialsRequired` outcome. Its last section is "About", a
    single `NavigationLink` to `AcknowledgementsView_iOS` — a push rather than
    another sheet, the `Form` already sitting in a `NavigationStack`, and the
    peer of the macOS Preferences "Acknowledgements" tab.
  - `iOS/AcknowledgementsView_iOS.swift` — the iOS Acknowledgements screen: a
    `List` of dependencies (name + SPDX) pushing `LicenseTextView_iOS`, the
    detail screen carrying that entry's identity (name, SPDX, version/revision,
    origin) and the full license text. Two levels rather than the macOS split
    view because that is what a phone has room for; everything else matches the
    macOS peer, deliberately — the text is a monospaced, `.textSelection(
    .enabled)` `Text` in a `ScrollView` rendered **whole** (never truncated or
    reflowed: the copyright lines and the permission notice are the obligation),
    `version` is omitted when `nil` instead of rendered blank, `revision` is
    always shown in full, `origin` is a `Link` exactly when Core's
    `LicenseNotice.originURL` is non-nil (the `https://` remotes) — the same rule
    the macOS screen asks, kept in Core so the two cannot drift —
    and `LicenseCatalogLoader.failureDescription` replaces the list when the
    bundle is broken so "no dependencies" is never the silent reading. Thin view,
    untested; the logic is Core's `LicenseCatalog` (`core-services.md`).
  - `iOS/LibGit2Service.swift` — the iOS `GitServicing` implemented as a **direct
    C binding** against libgit2 (the in-process peer of the macOS
    `GitCLIService`), producing the *same* Core value types the CLI parsers do
    (`ChangedFile`/`FileStatus`/`Commit`/`GitError`/`PartialRevertError`): the
    Local Changes surface (`repositoryRoot`/`changedFiles`/`headContents`/`blob`/
    `revert` with the same per-`FileStatus` edge cases), the Log surface
    (`commits`/`references`/`commitChanges`/`fileContents`), and the conflict
    surface (`stage`/`stageRemoval`). It deliberately does **not** implement
    `blame(fileURL:)` — the annotation column is a macOS-gutter feature and iOS has
    no gutter — inheriting the protocol extension's `[]` default. The
    branch-switcher surface is likewise a
    direct libgit2 binding: `currentBranch` (via `git_repository_head` /
    `git_reference_*` — unborn/detached → `nil`), `checkout` (`git_checkout_tree` +
    `git_repository_set_head`, a `GIT_ECONFLICT` → `GitError.checkoutFailed` with the
    conflicting paths), and `createAndCheckout` (`git_branch_create` from the start
    ref's commit + checkout). `fetch(remote:root:)` performs a real HTTPS network
    fetch (Part B) via `git_remote_lookup` + `git_remote_fetch` over the built-in
    Apple TLS backend (no new dependency): a credentials callback wired into
    `git_fetch_options` supplies `GIT_CREDENTIAL_USERPASS_PLAINTEXT` (the host's
    `GitCredentials.username(...)` + the stored PAT as the password); with no token
    for the host it throws `GitError.credentialsRequired(host:)`, and a non-HTTPS
    `origin` (no host from `RemoteHost.host(...)`) surfaces a clear "HTTPS origin
    required" error. SSH remotes are unsupported on iOS (libgit2's SSH transport is
    exec-based — no subprocess on iOS), so the network path is HTTPS-only. It holds a
    `CredentialStore` (the `KeychainCredentialStore`) for the callback, and runs all
    calls on the service's serial queue under the security scope like the rest of the
    libgit2 code.
  - `iOS/KeychainCredentialStore.swift` — the iOS view-layer `CredentialStore`
    (Core protocol) implemented over the `Security` framework (Keychain): save /
    lookup / delete a Personal Access Token keyed by remote host (a generic-password
    item), no new dependencies. Thin IO (untested), the pure host-selection logic
    lives in Core's `GitCredentials`.
  - `iOS/LocalChangesView_iOS.swift` / `iOS/DiffView_iOS.swift` /
    `iOS/DiffRoute_iOS.swift` — the Local Changes list + two-`UITextView`
    side-by-side diff, presented as sheets / pushed screens.
  - `iOS/CommitLogView_iOS.swift` / `iOS/CommitGraphView_iOS.swift` /
    `iOS/LogFilterBar_iOS.swift` — the Git Log list with the branch-graph gutter
    (UIKit over `CommitGraphLayout`) and the filter/search bar.
  - `iOS/MergeView_iOS.swift` / `iOS/MergeRoute_iOS.swift` — the adaptive 3-pane
    conflict resolver (side-by-side on regular width, stacked on compact).
