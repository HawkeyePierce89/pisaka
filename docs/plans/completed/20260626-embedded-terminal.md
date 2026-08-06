# Embedded Terminal

## Overview

Add a built-in terminal to Pisaka: a collapsible bottom panel hosting one or more
live shell sessions, started in the project folder, toggled with ⌘⇧T. The terminal
lives below the editor in a vertical split, supports multiple tabs (new / close /
switch) without recreating running sessions, and cleans up its shell processes on
tab close and app termination. Per project convention, the only pure/testable
logic — launch-parameter resolution — lives in `PisakaCore`; everything else (PTY,
rendering, lifecycle) is thin macOS view-layer code like `CodeEditorView`/`DiffView`.

## Context

- Files to create:
  - `Sources/PisakaCore/TerminalLaunch.swift` — pure launch-parameter resolution.
  - `Tests/PisakaCoreTests/TerminalLaunchTests.swift` — unit tests for it.
  - `Sources/Pisaka/TerminalSession.swift` — wraps one `LocalProcessTerminalView` (id + process).
  - `Sources/Pisaka/TerminalSessionsModel.swift` — `ObservableObject` owning sessions + active tab + lifecycle.
  - `Sources/Pisaka/TerminalPanelView.swift` — tab bar + `NSViewRepresentable` host for the active session.
- Files to modify:
  - `Package.swift` — add `SwiftTerm` SPM dependency to the `Pisaka` target only (exact pin, mirroring the grammar-package convention).
  - `Sources/Pisaka/ContentView.swift` — wrap the editor zone in a vertical split `[editor | terminal]`; show the panel only in editor mode and only when toggled on; Log full-window mode unaffected.
  - `Sources/Pisaka/PisakaApp.swift` — own the `TerminalSessionsModel` and a `showTerminal` `@State`; add the View-menu "Show/Hide Terminal" command (⌘⇧T); pass `projectRoot` to new sessions; terminate all sessions on app termination.
  - `README.md` / `CLAUDE.md` — document the new feature, shortcut, and architecture.
- Related patterns:
  - `WorkspaceMode` toggle + View-menu command (⌘⇧L) in `PisakaApp.swift` — the model for the ⌘⇧T toggle.
  - `CodeEditorView`/`DiffView` — `NSViewRepresentable` precedent for hosting AppKit views.
  - `GitCLIService` — the "macOS-only process layer stays in `Pisaka`, pure logic in `PisakaCore`" split.
- Dependencies: `SwiftTerm` (SPM, https://github.com/migueldeicaza/SwiftTerm) — first GUI-heavy external dependency after Neon; confined to the `Pisaka` target.

## Development Approach

- **Testing approach**: Regular (code first, then tests) for `TerminalLaunch`; the view layer is intentionally thin and not unit-tested, per project convention.
- Complete each task fully before moving to the next.
- Every behavioral change in `PisakaCore` ships with tests; the full `swift test` suite must pass before starting the next task.
- **CRITICAL: every task that changes `PisakaCore` MUST include new/updated tests.**
- **CRITICAL: all tests must pass before starting the next task.**
- YAGNI: no split terminals, tab rename/reorder, custom theme/font/profiles, output search, clickable links, or session restore.

## Implementation Steps

### Task 1: Add SwiftTerm dependency

**Files:**
- Modify: `Package.swift`

- [x] Add the `SwiftTerm` package (exact version pin) to `dependencies`, with a comment explaining the pin rationale (mirroring the Neon/grammar pinning notes).
- [x] Add the `SwiftTerm` product to the `Pisaka` executable target's `dependencies` only — never `PisakaCore` or the test target.
- [x] Run `swift build` to resolve and compile; verify the dependency builds cleanly and commit the updated `Package.resolved`.

### Task 2: PisakaCore — TerminalLaunch (pure, tested)

**Files:**
- Create: `Sources/PisakaCore/TerminalLaunch.swift`
- Create: `Tests/PisakaCoreTests/TerminalLaunchTests.swift`

- [x] Add `public enum TerminalLaunch` with `static func shell(environment: [String: String]) -> String` returning `environment["SHELL"]` when set and non-empty, else `/bin/zsh`.
- [x] Add `static func workingDirectory(projectRoot: URL?, home: URL) -> URL` returning `projectRoot` when present, else `home`.
- [x] Foundation-only; no AppKit/Process import.
- [x] Write `TerminalLaunchTests`: `shell` returns `$SHELL` when set/non-empty, falls back to `/bin/zsh` when absent or empty; `workingDirectory` returns `projectRoot` when present and `home` when nil.
- [x] Run `swift test` — must pass before Task 3.

### Task 3: View layer — sessions and panel

**Files:**
- Create: `Sources/Pisaka/TerminalSession.swift`
- Create: `Sources/Pisaka/TerminalSessionsModel.swift`
- Create: `Sources/Pisaka/TerminalPanelView.swift`

- [x] `TerminalSession`: a final class holding a stable `id` (UUID), a display title, and its `LocalProcessTerminalView`, started on the resolved shell in the resolved working directory; expose a method to terminate its process.
- [x] `TerminalSessionsModel: ObservableObject`: publish `[TerminalSession]` + active id; `newSession(projectRoot:)` (resolves shell/cwd via `TerminalLaunch` using `ProcessInfo.processInfo.environment` and `FileManager.default.homeDirectoryForCurrentUser`), `close(id:)` (terminate process + drop tab, re-select a neighbor), `activate(id:)`, and `terminateAll()` for app shutdown. Switching tabs must not recreate sessions.
- [x] `TerminalPanelView`: a tab bar (tabs + "＋" + per-tab close) above the active session, hosting the active `LocalProcessTerminalView` via an `NSViewRepresentable`; the focused terminal view captures keyboard input and SwiftTerm maps view resize to the PTY.
- [x] Run `swift build` to confirm the view layer compiles; run `swift test` (no new Core tests, but the suite must still pass) before Task 4.

### Task 4: Layout integration and toggle

**Files:**
- Modify: `Sources/Pisaka/ContentView.swift`
- Modify: `Sources/Pisaka/PisakaApp.swift`

- [x] In `PisakaApp`: add a `@StateObject` (or owned reference) `TerminalSessionsModel` and a `@State var showTerminal: Bool = false`; pass both down to `ContentView`.
- [x] Add a View-menu command "Show/Hide Terminal" bound to ⌘⇧T that flips `showTerminal`; when turning it on with no sessions, create the first session via `newSession(projectRoot: model.projectRoot)`.
- [x] Register a `willTerminate` observer (or reuse the app-termination path) to call `terminateAll()` so no shell processes leak; verify tab-close also terminates that session's process.
- [x] In `ContentView`: wrap the `editorSplit` in a vertical split `[editorSplit | TerminalPanelView]` with a draggable divider, shown only when `showTerminal` is true and only in `.editor` mode (the `.log` full-window branch is unchanged). Existing terminals keep their working directory when `projectRoot` changes (only `newSession` reads the current root).
- [x] Run `swift build` and `swift test` — suite must pass before Task 5.

### Task 5: Verify acceptance criteria

- [x] Run the full test suite: `swift test` — all green.
- [x] Run `swift build` — clean compile with the new dependency.
- [x] Confirm `PisakaCore` and the test target import only Foundation (no SwiftTerm/AppKit leak).

### Task 6: Update documentation

- [x] Update `README.md` with the embedded-terminal feature and the ⌘⇧T shortcut.
- [x] Update `CLAUDE.md`: add `TerminalLaunch.swift` under `PisakaCore`, and `TerminalSession`/`TerminalSessionsModel`/`TerminalPanelView` plus the vertical-split layout and toggle under `Pisaka`; note the new `SwiftTerm` dependency and its pinning rationale in the conventions section.
