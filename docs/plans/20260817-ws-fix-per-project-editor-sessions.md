# WS-fix: per-project editor sessions — Open Folder swaps the tabs with the tree

## Overview

`WorkspaceModel.openFolder(url:)` sets `projectRoot` and nothing else, so opening a
different project mid-run swaps the tree while the tab list, the editor and the
persisted session keep the previous project's files. This makes sessions
**per-project**: switching folders snapshots the outgoing project's tabs under that
folder's key and applies the incoming folder's stored session (empty on first open),
and the persisted store grows from one blob to a keyed, MRU-ordered collection whose
head is what launch restore follows. The legacy `session.lastSession` blob migrates
into the collection. All decision logic lands in `PisakaCore` and is unit-tested; the
macOS app layer gains only the trigger inside the folder-switch orchestration it
already funnels every open through.

## Context

- Files involved:
  - `Sources/PisakaCore/EditorSession.swift` — `SessionTab`, `EditorSession`,
    `EditorSession.snapshot`, `SessionStore`. Gains `SessionCatalog` (same file — no
    new file, so `CLAUDE.md`'s index is untouched) and a keyed `SessionStore`.
  - `Sources/PisakaCore/WorkspaceModel.swift` — `openFolder(url:)`,
    `restoreSession(_:)`, `close(id:force:)`/`closeFiles(ids:)`, `canonicalURL`.
    Gains `isCurrentProjectRoot(_:)` and `replaceSession(with:)`.
  - `Sources/PisakaCore/CanonicalPath.swift` — the keying rule (`canonical(_:)`,
    including the documented `/private` caveat). Unchanged, used as-is.
  - `Sources/Pisaka/PisakaApp.swift` — `openFolder(url:)` (the one folder-switch
    orchestration, ~line 1452) and `restoreLastSession()` (~line 1830); the existing
    `revertInFlight()`, `autosave.flushNow(reportingSaves:)` and
    `unsavedTitledFileNames()` helpers are reused verbatim.
  - `Sources/Pisaka/SessionController.swift` — the debounced writer. **No code
    change**: it calls `store.save(_:)`, which becomes an upsert keyed by the
    snapshot's own `folderPath`. Doc comment updated.
  - `Tests/PisakaCoreTests/EditorSessionTests.swift`,
    `Tests/PisakaCoreTests/WorkspaceModelTests.swift`.
  - `docs/architecture/core-services.md`, `core-workspace.md`, `app-shell.md`.
- Related patterns:
  - Store-as-spelled / match-canonically (`EditorSession.snapshot`'s verbatim paths
    vs. `WorkspaceModel.open(url:)`'s canonical dedup) — the keying follows it exactly.
  - `BookmarkStore`/`SettingsStore` shape: injected `UserDefaults`, one property-list
    blob under a stable key, every read failure resolving to a blank slate via `try?`.
  - `ScopedFileAccess.updatedRecents(_:remembering:max:)` — MRU-first, dedup by path,
    count cap of 20. The catalog's retention rule is deliberately the same shape.
  - The writer-gate posture of `save(id:)`: `guard !revertInFlight() else { return }`.
  - The commit dialog's pre-flush idiom: `autosave.flushNow(reportingSaves: true)`
    followed by `unsavedTitledFileNames()`.
- Dependencies: none. Core stays Foundation-only.

## Design decisions (recorded here, then in the architecture docs)

**Storage shape.** One property-list blob under a new stable key
`session.projects`, decoding to `SessionCatalog`: an **MRU-ordered array of entries**,
each a `folderPath: String?` (verbatim spelling; `nil` is the no-folder workspace)
plus its `EditorSession`. The "last opened" pointer *is* `entries.first` — one piece
of state rather than a separate field that could name an absent entry, so "the
pointer points at a session that is not stored" is unrepresentable.

**Retention.** Capped at **20 entries** (`SessionCatalog.maxStoredProjects`, the same
number and rationale as the iOS recents cap), evicting the tail. The cap is by
**entry count, never by byte size** — that is precisely what makes one project's
pathologically large untitled buffer unable to evict another project's session. Each
entry is an independent value, so nothing one project stores changes what another
decodes to; the only shared failure mode is an unreadable *whole* blob, which
resolves to a blank slate exactly as today's single blob does (a trap at launch is
the least recoverable thing there is). If the total size ever bites, the escape hatch
is unchanged and already recorded on `EditorSession`'s limit (2): move the backing
store to Application Support — the model does not change.

**Migration.** `session.lastSession` is read **only when `session.projects` is
absent**, and seeds a one-entry catalog (its `folderPath`, which may be `nil`, becomes
that entry's key and the head). The legacy key is never written again and is
deliberately **not deleted**: deleting buys nothing and keeping it lets a downgrade
still restore. `Keys.lastSession` stays, renamed in meaning only.

**No lost edits, and the one refusal.** A switch refuses outright while the
disk-writer gate is up (`revertInFlight()`), the same posture as ⌘S. Otherwise it
flushes autosave first (`reportingSaves: true`, so Local Changes and the tree get the
same follow-up an ordinary autosave gets), and — because the flush is best-effort and
the switch is about to force-close those tabs — if any dirty titled buffer is still
unsaved afterwards the switch is **refused and the files named**, rather than
force-closing a buffer whose contents never reached disk. Untitled text needs no
flush: it travels inside the outgoing snapshot.

**Why the outgoing snapshot goes through `SessionController.flushNow()`.** It is
taken while `projectRoot` is still the *outgoing* folder, so `save(_:)` keys it
correctly, and it inherits `flushNow()`'s `hasObservedChange` guard — which is
load-bearing here, not incidental: at launch, restore runs `openFolder(url:)` before
the controller is started, and an unguarded snapshot would write the empty live model
over the no-folder workspace's stored session (a stored untitled buffer, gone). After
the swap the model has changed, so the ordinary 1 s debounce promotes the incoming
project to head; the debounce always snapshots the *live* model at fire time, so no
half-swapped state can be written.

## Development Approach

- **Testing approach**: Regular (code first, then tests in the same task), per the
  repo convention that every behavioral change ships with `PisakaCore` tests.
- Complete each task fully before moving to the next.
- Core-only logic; the app layer gets the trigger and stays untested by convention.
- **CRITICAL: every task MUST include new/updated tests**
- **CRITICAL: all tests must pass before starting next task**

## Implementation Steps

### Task 1: `SessionCatalog` — the keyed, MRU collection

**Files:**
- Modify: `Sources/PisakaCore/EditorSession.swift`
- Modify: `Tests/PisakaCoreTests/EditorSessionTests.swift`

- [x] add `public struct SessionCatalog: Codable, Equatable` with a nested
      `Entry: Codable, Equatable` (`folderPath: String?`, `session: EditorSession`)
      and `entries: [Entry]`, MRU-ordered (index 0 = last opened)
- [x] add `public static let maxStoredProjects = 20` and document the count-not-bytes
      reasoning on the type
- [x] add `public var lastOpened: EditorSession?` (`entries.first?.session`) — the
      launch pointer, with the doc note that head *is* the pointer
- [x] add `public func session(forFolder folder: URL?) -> EditorSession?`, matching
      via `CanonicalPath.canonical(_:)` on both sides (`nil` matches only the
      `nil`-key entry), so two spellings of one folder land on one session
      (the key is `canonical(_:).path`, as `SymbolIndex`/`ProjectSearchModel` key —
      url equality would split `file:///p/root/` from `file:///p/root`)
- [x] add `public mutating func store(_ session: EditorSession, limit: Int = maxStoredProjects)`:
      canonical-match the existing entry, replace it (adopting the incoming verbatim
      `folderPath` spelling — the user's latest spelling wins), move it to the head,
      insert when absent, then drop entries beyond `limit` from the tail
- [x] add `public static func migrating(_ legacy: EditorSession) -> SessionCatalog`
- [x] write tests: keying by canonical path unifies `/tmp` vs `/private/tmp`,
      trailing slashes and `.`/`..`; the `nil` folder key is its own entry and never
      matches a real folder; `store` promotes to head, replaces rather than
      duplicates, and updates the recorded spelling; the cap evicts the least
      recently used and never the head; a huge untitled text in one entry evicts
      nothing; a round trip through `PropertyListEncoder`/`Decoder` preserves order
- [x] run `swift test` — must pass before Task 2

### Task 2: `SessionStore` becomes keyed, with migration

**Files:**
- Modify: `Sources/PisakaCore/EditorSession.swift`
- Modify: `Tests/PisakaCoreTests/EditorSessionTests.swift`

- [x] add `Keys.projectSessions = "session.projects"` alongside the untouched
      `Keys.lastSession`, both documented as never-renamed
- [x] add a private `catalog()` read: decode `session.projects` when present;
      otherwise migrate from a decodable `session.lastSession`; otherwise an empty
      catalog — every failure resolving to a blank slate via `try?`, as today
- [x] replace `load()` with `public func loadLastOpened() -> EditorSession?`
      (the catalog head; `nil` when nothing was ever written), and add
      `public func session(forFolder folder: URL?) -> EditorSession?`
- [x] keep `save(_ session: EditorSession)`'s signature, reimplemented as
      "upsert into the catalog keyed by `session.folderPath`, promote to head, apply
      the cap, encode under `session.projects`" — so `SessionController` needs no
      change; an encode failure still leaves the previous blob in place
- [x] make `clear()` remove both keys
- [x] write tests: a legacy blob (with a folder, and with `folderPath == nil`)
      migrates so `loadLastOpened()` and `session(forFolder:)` both find it; the
      legacy key is ignored once `session.projects` exists; two projects saved in
      turn are both retrievable and the second is the head; saving under a different
      spelling of a stored folder overwrites that one entry rather than adding one;
      an empty session is stored and read back like any other; a corrupt or
      wrong-typed `session.projects` yields no sessions rather than trapping; the
      existing store tests are updated to the new entry points
- [x] run `swift test` — must pass before Task 3

### Task 3: `WorkspaceModel` — the same-root test and the tab swap

**Files:**
- Modify: `Sources/PisakaCore/WorkspaceModel.swift`
- Modify: `Tests/PisakaCoreTests/WorkspaceModelTests.swift`

- [x] add `public func isCurrentProjectRoot(_ url: URL) -> Bool`, canonical-comparing
      against `projectRoot` (`false` when none is open), reusing the model's existing
      `canonicalURL` helper
- [x] add `public func replaceSession(with session: EditorSession)`: force-close every
      open tab (`closeFiles(ids:)`, which leaves `selectedID` `nil` once the last one
      goes), then apply `session` through the existing `restoreSession(_:)` — same
      silent, skip-what-cannot-open semantics, and `projectRoot` deliberately
      untouched (the app owns that, as `restoreSession` already documents)
- [x] document on `openFolder(url:)` that setting `projectRoot` is still all it does,
      and that the tab half of a project switch is `replaceSession(with:)`, driven by
      the app orchestration that owns the store
- [x] write tests: `replaceSession` drops the previous project's tabs and opens the
      incoming ones with the recorded selection; an empty incoming session leaves an
      empty editor with `nil` selection; a dirty titled tab and a dirty untitled tab
      are both force-closed (no `needsConfirmation` path); an untitled record in the
      incoming session comes back dirty with its text; unreadable records are skipped
      silently; `isCurrentProjectRoot` is `true` across spelling differences and
      `false` for a sibling directory and when no folder is open
- [x] run `swift test` — must pass before Task 4

### Task 4: The app trigger inside the existing folder-switch orchestration

**Files:**
- Modify: `Sources/Pisaka/PisakaApp.swift`
- Modify: `Sources/Pisaka/SessionController.swift` (doc comment only)

- [x] in `openFolder(url:)`, compute `isSwitch = !model.isCurrentProjectRoot(url)`
      **first**; when it is a switch, before touching anything:
      `guard !revertInFlight() else { return }`, then
      `autosave.flushNow(reportingSaves: true)`, then — if
      `unsavedTitledFileNames()` is non-empty — name those files in an alert and
      return without switching (a new sibling of `reportUnsavedBeforeCommit`), then
      `sessionController.flushNow()` to persist the outgoing snapshot while
      `projectRoot` is still the outgoing folder
- [x] after `model.openFolder(url: url)` and before the existing collaborator
      registration, when `isSwitch`, apply the incoming session:
      `model.replaceSession(with: sessionStore.session(forFolder: url) ?? EditorSession())`
- [x] leave every existing collaborator call (watcher, Local Changes, Log, branch
      switcher, project search, commit dialog, symbol index, LSP) exactly as it is —
      re-opening the current folder stays the no-op for tabs that it now is for them
- [x] rewrite `restoreLastSession()` to read `sessionStore.loadLastOpened()` and,
      when the recorded folder still exists, open it through `openFolder(url:)`
      (which now applies the tabs); otherwise fall back to
      `model.restoreSession(session)` for the no-folder and vanished-folder cases;
      start `sessionController` last, exactly as today
- [x] update the doc comments on `openFolder(url:)`, `restoreLastSession()` and
      `SessionController` to state the switch semantics, why the outgoing snapshot
      goes through `flushNow()`'s `hasObservedChange` guard, and that `save(_:)` is
      now a keyed upsert
- [x] tests: none new here by convention (the view layer is untested); the behavior
      this task wires is the Core behavior already covered by Tasks 1–3
- [x] `xcodegen generate` and build macOS and iOS (`xcodebuild … -destination
      'platform=macOS'` and `'generic/platform=iOS'`) — both must succeed, and
      `swift test` must stay green, before Task 5

### Task 5: Architecture documentation

**Files:**
- Modify: `docs/architecture/core-services.md`
- Modify: `docs/architecture/core-workspace.md`
- Modify: `docs/architecture/app-shell.md`

- [x] `core-services.md`, the `EditorSession.swift` entry: rewrite limit (3) from
      "one session under one key" to the keyed store — `SessionCatalog`, the MRU
      order, head-is-the-pointer, the count-not-bytes cap of 20 and why, the
      migration from `session.lastSession` and why the legacy key survives — while
      **keeping the multi-window caveat**, which still stands (two independent
      windows would write under one project's key, last writer winning). Describe
      `SessionStore`'s new surface (`loadLastOpened()`, `session(forFolder:)`,
      the upserting `save(_:)`, the two-key `clear()`)
- [x] `core-workspace.md`, the `WorkspaceModel` entry: drop the "opening a folder is
      independent of opening files" rationale from `openFolder(url:)`, and add
      `isCurrentProjectRoot(_:)` and `replaceSession(with:)` with the force-close
      rule and the "`projectRoot` stays the app's job" boundary
- [x] `app-shell.md`, the `openFolder(url:)` / `restoreLastSession()` /
      `SessionController` entries: the refuse-flush-snapshot-swap order, the
      unsaved-titled-file refusal, why the outgoing snapshot is keyed before
      `projectRoot` moves, and that launch restore now applies its tabs through the
      same switch path
- [x] no `CLAUDE.md` index change (no file added or renamed) — confirm this holds
- [x] run `swift test` — must stay green

### Task 6: Verify acceptance criteria

- [ ] `swift test` — full suite green
- [ ] `xcodegen generate` then `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka
      -destination 'platform=macOS' build` — green
- [ ] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination
      'generic/platform=iOS' build` — green (Core stays platform-neutral; iOS session
      restore remains the documented follow-up)
- [ ] re-read the acceptance list and confirm each unit-test claim is covered by a
      named test: outgoing snapshot + incoming restore, first-open folder is empty,
      re-opening the current folder is a tab no-op, untitled text travels with its
      project, canonical keying unifies spellings, the legacy blob migrates and
      launch restore still finds it
- [ ] no repository is left with `Pisaka.xcodeproj` regenerated but uncommitted state
      that contradicts `project.yml` (the project file is generated, not edited)

## Post-Completion (owed manual verification, performed by the user)

- Open project A with several tabs and a selection; Open Folder → project B: the tree
  **and** the tab list both show B, empty on B's first open.
- Open Folder back to A: A's tabs return in order with the selection restored.
- Quit and relaunch: the last project's folder and its session restore exactly as
  before the change.
- With an unsaved untitled scratch buffer in A, switch to B and back: the buffer
  returns, still dirty, with its text.
- Confirm autosave, the writer gate and launch restore show no other behavior change.
