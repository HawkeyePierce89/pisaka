# Session Restore on Launch (macOS)

## Overview

Today every Pisaka launch starts from a blank slate: the opened folder and the tabs are forgotten, and the contents of unsaved "Untitled" buffers are lost for good (autosave skips them — they have nowhere to write). This introduces JetBrains/VS Code behavior: a launch brings back the last session — the folder, the tabs in the same order, the selected tab — plus hot exit for Untitled buffers (their text survives a restart). The session is written continuously with a debounce, not only on exit, so it also survives a crash / force-quit.

The split follows the rest of the repository: all logic (the session model, the snapshot, persistence, restore) is Foundation-only in `PisakaCore` and under tests; `Pisaka` keeps only thin trigger wiring (a writer controller shaped like `AutosaveController`) and the launch-time restore call. macOS only; iOS is a follow-up over the same Core model.

## Context

Files involved:

- Create: `Sources/PisakaCore/EditorSession.swift` — `SessionTab`, `EditorSession` (+ the pure snapshot), `SessionStore`.
- Modify: `Sources/PisakaCore/WorkspaceModel.swift` — `restoreSession(_:)`.
- Create: `Sources/Pisaka/SessionController.swift` — the debounced writer (view layer, macOS-gated).
- Modify: `Sources/Pisaka/AutosaveController.swift` — make `flushNow()` internal (currently `private`, line 248); no behavior change.
- Modify: `Sources/Pisaka/PisakaApp.swift` — split `openFolder()` (line 518), restore on launch, flush ordering on `willTerminate`.
- Create: `Tests/PisakaCoreTests/EditorSessionTests.swift`; modify `Tests/PisakaCoreTests/WorkspaceModelTests.swift` (adds a path-reading `FileServicing` stub).
- Modify: `README.md`, `CLAUDE.md`.

Related patterns:

- `BookmarkStore` (in `ScopedFileAccess.swift`) — injected `UserDefaults`, one plist blob under a stable key, `try?` instead of trapping; `SettingsStore` — same shape, tests over an isolated suite.
- `AutosaveController` — idempotent `start`, Combine subscriptions on `model.$openFiles`/`$selectedID`, main-queue debounce, `stop()`/`deinit`, synchronous flush on `willTerminateNotification`.
- `WorkspaceModel.open(url:)` — dedup by `CanonicalPath.canonical`; `PisakaApp.openFolder()` — the single point that registers a folder change with Local Changes / Git Log / branch switcher / Project Search / the FSEvents watcher.

Dependencies: none new. Persistence is `UserDefaults` + `PropertyListEncoder`/`Decoder`.

## Development Approach

- **Testing approach**: Regular (code first, then tests within the same task).
- Complete each task fully before moving to the next.
- **CRITICAL: every task must include new/updated tests** (except tasks living entirely in the view layer — the repo convention leaves those untested, but `swift test` must still stay green).
- **CRITICAL: all tests pass before starting the next task** (`swift test`).
- Deliberate limits are recorded in doc comments, not only in this plan: the contents of dirty titled files are not persisted (quit is covered by `flushNow`, a crash loses at most one autosave window, ~2 s); Untitled text size is not capped (if it ever bites, move the blob to Application Support without changing the model); multi-window is last-writer-wins with no coordination.

## Implementation Steps

### Task 1: Session model and pure snapshot in Core

A `Codable`/`Equatable` session value type plus a pure snapshot function over the live model state. The key encoding requirement is forward compatibility: unknown keys written by a future version must not break the current decoder. So a tab is encoded not as an enum with associated values (its synthesized `Codable` throws on an unknown case name) but as a flat struct with two optional fields — the titled file's path and the Untitled buffer's text. The synthesized keyed decoder skips unknown keys on its own, which is exactly the forward compatibility needed.

The decoder is therefore deliberately permissive: a record with neither field decodes successfully as a `SessionTab` whose `path` and `text` are both `nil`. Deciding what such a record *means* is not the decoder's job — it belongs to restore (Task 3), which is the only place that knows how to turn a record into a tab. That record is precisely the "tab written by a future version" case (a new kind whose fields this version doesn't know), and restore skips it exactly like an unreadable file.

Snapshot rules: tabs in `openFiles` order; a titled file → its path; an Untitled buffer with non-empty text → the text; an Untitled buffer with literally empty text (no trimming) is dropped; `selectedIndex` is the index of the selected tab among the *stored* records (i.e. adjusted for dropped empty Untitled buffers), `nil` when there is no selection or its record was dropped; the folder path comes from `projectRoot` and is optional.

Paths are stored **exactly as the tab spells them** — the snapshot deliberately does not canonicalize (no `CanonicalPath`, no symlink resolution): the stored spelling is the one the user opened, which is what keeps the restored tab, the project tree and the breadcrumb agreeing after a restart, exactly as `DisplayPath` prefers the lexical spelling today. Canonicalization is a *matching* rule, so it belongs on the read side, where restore applies it for dedup (Task 3) — the same asymmetry `open(url:)` already has (it stores `url` as given and matches canonically).

**Files:**

- Create: `Sources/PisakaCore/EditorSession.swift`
- Create: `Tests/PisakaCoreTests/EditorSessionTests.swift`

- [x] define `SessionTab` (`Codable`/`Equatable`, optional `path`/`text`, static factories `file(path:)`/`untitled(text:)`) and `EditorSession` (`folderPath: String?`, `tabs: [SessionTab]`, `selectedIndex: Int?`)
- [x] implement the pure `EditorSession.snapshot(openFiles:selectedID:projectRoot:)` per the rules above
- [x] document on `SessionTab` that a record with neither field is a valid decode and that skipping it is restore's decision, not the decoder's (the future-version-tab case)
- [x] document on the snapshot that paths are stored verbatim and canonicalization is deliberately left to restore
- [x] record the three deliberate limits in doc comments (dirty titled file contents are not persisted and why that is safe; Untitled text size is uncapped; multi-window is last-writer-wins)
- [x] tests for the snapshot: tab order, empty Untitled dropped, selection index shifted past a dropped record, selected record dropped → `nil`, no folder, empty model, a tab url spelled through a symlink stored verbatim rather than resolved
- [x] run `swift test` — must pass before Task 2

### Task 2: Session persistence (SessionStore)

A thin wrapper over an injected `UserDefaults` following the `BookmarkStore` precedent: one plist blob under a stable, never-renamed key. An unreadable or partially corrupt blob → `nil` without trapping (`try?`); a missing key → `nil`. An empty session (no folder, no tabs) is a valid value and is stored and read like any other.

**Files:**

- Modify: `Sources/PisakaCore/EditorSession.swift`
- Modify: `Tests/PisakaCoreTests/EditorSessionTests.swift`

- [x] implement `SessionStore` (injected `UserDefaults`, `Keys.lastSession`, `load() -> EditorSession?`, `save(_:)`, `clear()`)
- [x] tests: round-trip through two instances over one isolated suite; corrupt blob → `nil`; missing key → `nil`; empty-session round-trip; a blob carrying an unknown key still decodes (forward compatibility), including a tab record with neither `path` nor `text`, which decodes rather than failing the whole blob
- [x] run `swift test` — must pass before Task 3

### Task 3: Session restore in WorkspaceModel

The method applies a session to an empty model. Titled tabs are opened through `fileService` — a missing or unreadable file is silently skipped and the batch continues. Untitled records are restored as dirty url-less tabs: `text` from the session, `savedText` empty, so `close` asks for confirmation like it does for any unsaved buffer. Dedup by canonical path works exactly as in `open(url:)` — a hand-edited blob with duplicates, or two different spellings of one file, does not yield two tabs (this is the read side of the write-verbatim rule from Task 1).

This is also where a record carrying neither a path nor text is handled: it names nothing this version can open, so it is skipped like an unreadable file (silently, batch continues) and shifts the selection mapping the same way. The rule lives here rather than in the decoder because it is a restore decision about meaning, and it is what keeps a session written by a future version — one whose tabs have a kind this build doesn't know — loading with everything else intact instead of failing wholesale.

Selection: the mapping is built over the tabs actually restored, so skipped records shift the index by construction; a missing, out-of-range, or skipped-record index falls back to the last tab. An empty session is a no-op. The method does not touch `projectRoot` — opening the folder stays with the app layer.

**Files:**

- Modify: `Sources/PisakaCore/WorkspaceModel.swift`
- Modify: `Tests/PisakaCoreTests/WorkspaceModelTests.swift`

- [x] implement `restoreSession(_:)` (tab order, silent skip of unreadable files and of records naming neither a path nor text, dirty Untitled buffers, dedup by canonical path, selection restore with a last-tab fallback, `projectRoot` untouched)
- [x] add a `FileServicing` stub serving contents by path and throwing on an unknown path
- [x] tests: a skipped missing file shifts the selection; a record with neither `path` nor `text` is skipped and shifts the selection the same way; a restored Untitled tab is dirty and carries the right text; two spellings of one path collapse into a single tab; an invalid index → last tab; an empty session is a no-op; `projectRoot` stays `nil`
- [x] run `swift test` — must pass before Task 4

### Task 4: Session writer controller (view layer)

A controller shaped like `AutosaveController`: idempotent `start(model:store:)`, subscriptions on `model.$openFiles`/`$selectedID`/`$projectRoot`, a ~1 s main-queue debounce, writing the snapshot through the store; `stop()`/`deinit` teardown; a synchronous `flushNow()` for exit. An empty session is written like any other — a user who closed everything must not get the session before last resurrected on the next launch.

The subscriptions are a *trigger only*: when the debounce fires, the snapshot is taken from the live model (`model.openFiles`/`selectedID`/`projectRoot` read at that moment), never from values captured in the subscription closure — a `@Published` value is delivered *before* the property is committed, and the other two properties are not part of that delivery at all, so a cached snapshot would be stale in a way the debounce makes permanent until the next change.

The controller deliberately does not register its own `willTerminateNotification` observer: the "the snapshot is written after autosave's `flushNow`" requirement must not rest on observer registration order. Instead `AutosaveController.flushNow()` becomes internal (no behavior change — `saveAllDirty()` is idempotent) and both flushes are called back to back from one place in `PisakaApp` (Task 5).

**Files:**

- Create: `Sources/Pisaka/SessionController.swift`
- Modify: `Sources/Pisaka/AutosaveController.swift`

- [x] implement `SessionController` (`#if os(macOS)`, idempotent `start`, debounced subscriptions, `flushNow()`, `stop()`/`deinit`), the snapshot read from the live model inside the debounced action
- [x] document why the `willTerminate` observer lives in `PisakaApp` rather than here (deterministic ordering against autosave)
- [x] drop `private` from `AutosaveController.flushNow()`, extending its doc comment to mention the external caller
- [x] run `swift test` — must stay green (Core untouched, no regressions expected)

### Task 5: Launch-time restore and writing in PisakaApp

Opening the folder during restore must go through the existing `openFolder()` path: it is the only one that registers the folder change with Local Changes / Git Log / the branch switcher / Project Search and starts the FSEvents watcher. To reach it, the current `openFolder()` is split into a no-argument form (which shows the panel) and `openFolder(url:)` carrying all the rest of the logic.

Launch order, before the first interaction: read the session; if a folder path was recorded and still exists as a directory, open it via `openFolder(url:)` — a vanished folder is simply not opened; then restore the tabs through the Core method. Tab restore does not depend on the folder's fate, and everything is silent — no alerts about missing files. The writer controller starts *after* the session is applied, so a half-built state cannot overwrite what was saved; restore runs exactly once (`.onAppear` can fire again, and so can a second `WindowGroup` window).

In the app's existing `willTerminate` observer, `autosave.flushNow()` is called first and `session.flushNow()` second: the snapshot then captures a state in which dirty titled files have already reached disk.

**Files:**

- Modify: `Sources/Pisaka/PisakaApp.swift`

- [x] split `openFolder()` into the no-argument panel form and `openFolder(url:)` holding all the folder-change registration, the former calling the latter
- [x] add `sessionStore`/`sessionController` and the one-shot restore in `.onAppear`: read the session → open an existing folder via `openFolder(url:)` → `model.restoreSession(_:)` → start the writer controller
- [x] in the existing `willTerminateNotification` observer call `autosave.flushNow()` then `session.flushNow()`, recording the order and its reason in a comment
- [x] run `swift test` — must stay green

### Task 6: Verify acceptance criteria

The build commands are exactly the ones gating CI (`.github/workflows/ci.yml`), so a local check matches what would fail on a PR. The iOS gate is the device-arch `generic/platform=iOS` build without signing (it covers libgit2 linking), not the simulator.

- [x] `swift test` — whole suite green (1264 tests, 0 failures)
- [x] `xcodegen generate`
- [x] macOS build: `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build` — BUILD SUCCEEDED
- [x] iOS build (Core additions don't break the iOS target): `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build` — BUILD SUCCEEDED

### Task 7: Update documentation

- [x] `README.md`: describe launch-time session restore and Untitled hot exit next to the autosave section, including the boundaries (dirty titled file contents are not persisted, multi-window is last-writer-wins)
- [x] `CLAUDE.md`: add `EditorSession.swift`/`SessionStore` to the Core inventory (including the write-verbatim / match-canonically asymmetry), `restoreSession` to the `WorkspaceModel` entry (including that the neither-path-nor-text rule lives in restore, not the decoder), `SessionController` to the view-layer inventory (including the live-model snapshot rule), and the `PisakaApp` changes (`openFolder(url:)`, flush ordering on `willTerminate`)

## Post-Completion (manual verification, outside automation)

- Open a folder + several files + an Untitled buffer with text → restart → everything is back, including the selected tab and the Untitled text (tab dirty).
- Delete one of the files between launches → its tab is silently gone, the rest intact, the selection sensible.
- Close every tab and restart → empty; the session before last does not come back.
- `kill -9` while running → the session comes back no more than a couple of seconds stale.

## Out of scope

The iOS variant (the same session model plus security-scoped bookmarks for individual files), per-tab caret/scroll positions, restoring panel/terminal/tree state, a history of several sessions, and a "don't restore the session" setting.
