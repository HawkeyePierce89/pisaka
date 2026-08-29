# Recent-projects switcher in the macOS bottom bar

## Overview

Add a project-switcher widget to the always-visible macOS bottom bar, beside the
branch switcher. The button shows the current project's folder name; clicking it
opens a popover with an "Open Folder…" action and a "Recent" list built from the
session catalog the app already keeps (up to 20 projects, most-recently-opened
first). Choosing a row switches projects through the existing `openFolder(url:)`
funnel, which already restores that project's tabs.

All new logic is a pure Core projection with unit tests; the view is thin glue.
No new persistence: the session catalog is the single source. One behavioral
change to the funnel itself: `openFolder(url:)` gains an existence guard at its
top so a folder deleted since it was recorded refuses with a user-visible alert
instead of half-switching (decided in Q&A, iteration 1).

## Context

Files involved:

- `Sources/PisakaCore/EditorSession.swift` — `SessionCatalog` (MRU, capped at 20,
  keyed store-as-spelled / match-canonically, may hold one `nil`-folder entry)
  and `SessionStore`, whose `catalog()` reader is currently `private`.
- `Sources/PisakaCore/CanonicalPath.swift` — the canonical match rule used to
  mark the current project's row.
- `Sources/Pisaka/BranchSwitcherView.swift` — the bottom-bar-widget pattern the
  new view copies: plain-button label, `.popover(arrowEdge: .bottom)`, rows
  forwarding through no-op-defaulted callbacks, every font/padding/width through
  `\.interfaceMetrics`.
- `Sources/Pisaka/ContentView.swift` — `bottomBar` (line ~673) hosts the branch
  switcher and the completion toggle; the new widget goes beside them.
- `Sources/Pisaka/PisakaApp.swift` — owns `sessionStore`, the `openFolder()`
  panel form (line ~1763), the `openFolder(url:)` funnel (line ~1834),
  `isExistingDirectory(atPath:)` (line ~2443), `restoreLastSession()` (which
  already pre-checks existence itself and must stay silent), and
  `reportUnsavedBeforeFolderSwitch(_:)` (line ~2245), the alert idiom the new
  refusal follows.
- `Tests/PisakaCoreTests/EditorSessionTests.swift` — the existing catalog suite.
- `Tests/PisakaCoreTests/ZoomSourceGatingTests.swift` — pins who may name
  `interfaceScale`, who applies `.interfaceScaled(...)`, and who declares a zoom
  surface. The new widget belongs to none of those sets, so the suite must stay
  green with no edit to its lists.

Related patterns:

- Pure engine + thin glue; store-as-spelled / match-canonically; generation
  tokens are not needed here (nothing async is added).
- Existence is injected into the Core projection as a closure, so the projection
  stays pure and the filter rule is unit-tested without touching the disk.

Dependencies: none new.

## Development Approach

- **Testing approach**: Regular (code first, then tests) for the Core projection.
- Complete each task fully before moving to the next.
- **CRITICAL: every task MUST include new/updated tests**
- **CRITICAL: all tests must pass before starting next task**
- The view layer stays untested by convention; the view tasks' test item is the
  source-gating suites that *do* police the view layer plus the full `swift test`
  run.
- No product or brand names in code, comments, tests, docs or commit messages.

## Implementation Steps

### Task 1: The Core projection and the catalog reader

**Files:**

- Create: `Sources/PisakaCore/RecentProject.swift`
- Modify: `Sources/PisakaCore/EditorSession.swift`
- Create: `Tests/PisakaCoreTests/RecentProjectTests.swift`
- Modify: `Tests/PisakaCoreTests/EditorSessionTests.swift`

- [ ] add `RecentProject`: an `Identifiable, Equatable` row value carrying `url`
      (built from the verbatim stored path), `name` (the folder's last path
      component, falling back to the whole path when there is none), `path` (the
      stored spelling, verbatim — no tilde abbreviation, no canonicalization) and
      `isCurrent`; identity is the canonical path, so a row is stable across
      spellings
- [ ] add the projection `RecentProject.rows(catalog:currentRoot:folderExists:)`,
      a pure static function: MRU order preserved as the catalog stores it; the
      `nil`-`folderPath` entry excluded before anything else (and never handed to
      `folderExists`); each remaining entry kept only when `folderExists` says its
      url is still there; `isCurrent` decided by comparing
      `CanonicalPath.canonical(_:).path` against `currentRoot`, so any spelling of
      the open folder marks its row
- [ ] give `folderExists` no default, so every call site states its answer; the
      documentation comment records the two rules the ticket fixes in place —
      the list is read at display time and may trail the live catalog by one
      debounce of the session writer (acceptable; the button's own label comes
      from the live project root, never from the catalog's head), and the
      remaining race (a folder deleted between display and click) is settled by
      the funnel's refusal added in Task 3
- [ ] promote `SessionStore.catalog()` to a public reader named `loadCatalog()`
      (keeping the private helper as its implementation), documented as the one
      read the recents projection needs and as returning an empty catalog for
      every unreadable-blob case, exactly like the existing readers
- [ ] write `RecentProjectTests`: MRU order preserved; the `nil`-folder entry
      excluded; the current project marked when the catalog spells it differently
      (`/tmp` vs `/private/tmp`, a trailing slash, a `.` detour) and unmarked when
      no folder is open; paths reported verbatim while identity/marking is
      canonical; name derivation including a trailing-slash path; the
      existence filter dropping exactly the entries the closure refuses and
      calling it once per non-`nil` entry; the empty-catalog case returning no
      rows
- [ ] extend `EditorSessionTests` with a case for `loadCatalog()` — the stored
      catalog read back whole, and an empty catalog for an unwritten/garbage blob
- [ ] run `swift test` — must pass before Task 2

### Task 2: The bottom-bar widget

**Files:**

- Create: `Sources/Pisaka/ProjectSwitcherView.swift`
- Modify: `Sources/Pisaka/ContentView.swift`

- [ ] add `ProjectSwitcherView` (whole file under `#if os(macOS)`), shaped like
      `BranchSwitcherView`: inputs are `currentRoot: URL?`, a
      `recentProjects: () -> [RecentProject]` reader and two no-op-defaulted
      callbacks `onOpenFolder: () -> Void` and `onOpenRecent: (URL) -> Void`
- [ ] the bottom-bar label is a `Label` with a folder SF Symbol plus the current
      folder's name, or the stated placeholder "No Folder" when none is open;
      plain button style, a `.help` tooltip, `.popover(arrowEdge: .bottom)`
- [ ] read the rows in the button's action into `@State` *before* presenting, so
      the list (and its existence checks — at most 20, once per open) is produced
      exactly at popover-open time
- [ ] popover content: an "Open Folder…" button that dismisses and calls
      `onOpenFolder`, a divider, a "Recent" section header and the rows in a
      capped-height `ScrollView`; a row shows a checkmark and the accent color
      when it is the current project, a folder icon otherwise, with the name on
      the first line and the verbatim path beneath it in the secondary style;
      clicking a non-current row dismisses and calls `onOpenRecent(row.url)`,
      clicking the current row only dismisses; an empty list renders a short
      empty-state line with "Open Folder…" still above it; no filter field
- [ ] every font, padding, row spacing, scroll cap and the popover width goes
      through `\.interfaceMetrics` (`metrics.scaledFont` / `metrics.scaled`); the
      view names `interfaceScale` nowhere, applies `.interfaceScaled(...)`
      nowhere and declares no zoom surface
- [ ] add two `ContentView` inputs — `recentProjects: () -> [RecentProject]` and
      `onOpenRecentProject: (URL) -> Void`, both no-op-defaulted like their
      neighbours — and place `ProjectSwitcherView` in `bottomBar` between the
      `Spacer()` and `BranchSwitcherView`, passing `model.projectRoot` as the
      current root
- [ ] run `swift test` (the zoom and bottom-panel source-gating suites are the
      tests that police this layer; both must stay green with no edit to their
      pinned sets) — must pass before Task 3

### Task 3: The funnel guard and the app wiring

**Files:**

- Modify: `Sources/Pisaka/PisakaApp.swift`

- [ ] add an existence guard as the first statement of `openFolder(url:)`, before
      `isSwitch`/`hadFolder` are decided and before anything is flushed or
      swapped: when `isExistingDirectory(atPath: url.path)` is false, warn and
      return, leaving the workspace exactly as it was
- [ ] add the refusal helper beside `reportUnsavedBeforeFolderSwitch(_:)`,
      following it exactly — `PlatformFeedback.warning()` plus
      `PlatformAlert.presentMessage(title: "Cannot open project folder", …)`
      naming the folder that is gone
- [ ] document on the funnel why the guard is there and why it is at the top: the
      recents list can offer a folder deleted since it was recorded, and every
      present and future programmatic caller inherits the refusal rather than
      re-implementing it
- [ ] leave `restoreLastSession()` untouched — its own pre-check keeps launch
      restore on the silent path, so the new alert can never fire at launch; state
      that in the guard's comment
- [ ] add a private `recentProjectRows()` in `PisakaApp` that reads
      `sessionStore.loadCatalog()` and calls the Core projection with
      `model.projectRoot` and `isExistingDirectory(atPath:)` as the existence
      answer
- [ ] wire the two new `ContentView` inputs: `recentProjects: { recentProjectRows() }`
      and `onOpenRecentProject: { openFolder(url: $0) }` — the existing funnel
      verbatim, so the unsaved-titled-buffers refusal, the session flush and every
      retargeting apply unchanged and no `WorkspaceModel` mutation happens from
      the widget
- [ ] run `swift test` — must pass before Task 4

### Task 4: Verify acceptance criteria

- [ ] run `swift test` — full suite green
- [ ] run `swiftlint --strict` from the repository root — clean
- [ ] `xcodegen generate`, then build macOS:
      `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' build`
- [ ] build iOS (the widget is macOS-gated; iOS must compile unchanged):
      `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build`
- [ ] confirm `ZoomSourceGatingTests` passed with no edit to its pinned sets

### Task 5: Update documentation

**Files:**

- Modify: `CLAUDE.md`, `docs/architecture/core-services.md`,
  `docs/architecture/app-window.md`, `docs/architecture/app-shell.md`,
  `docs/FEATURES.md`, `README.md`

- [ ] `CLAUDE.md`: one index line for `RecentProject.swift` under
      `core-services.md` (beside `EditorSession.swift`) and one for
      `ProjectSwitcherView.swift` under `app-window.md`
- [ ] `docs/architecture/core-services.md`: a full entry for `RecentProject.swift`
      — the four rules (MRU order, `nil`-entry exclusion, canonical marking over
      verbatim display, injected existence) and the one-debounce staleness note;
      update the `EditorSession.swift` entry for `SessionStore.loadCatalog()`;
      record the out-of-scope iOS follow-up beside the `ScopedFileAccess` entry
      (the bookmark store already accumulates recents there, so a future ticket
      can add a list to the folder-picker screen)
- [ ] `docs/architecture/app-window.md`: a full entry for
      `ProjectSwitcherView.swift` (read-at-open, the two callbacks, current-row
      short-circuit, empty state, interface-zone scaling, declares no zoom
      surface) and an updated `ContentView.swift` entry for the two new inputs
- [ ] `docs/architecture/app-shell.md`: update the `PisakaApp.swift` entry for the
      funnel's existence guard, its refusal, and the recents reader
- [ ] `README.md` / `docs/FEATURES.md`: one user-facing line for the bottom-bar
      project switcher, in the existing voice and with no product names
- [ ] re-run `swift test` and `swiftlint --strict` after the documentation edits

## Post-Completion (manual, by the user)

- Open two or three projects in turn, then check the widget lists the others
  most-recently-opened first and that choosing one restores its tabs.
- With a dirty titled buffer, confirm the switch still refuses with the existing
  alert.
- Delete a recorded folder, reopen the popover (row gone), and — for the race —
  delete one while the popover is open, then click it: the new refusal alert
  appears and the workspace is unchanged.
