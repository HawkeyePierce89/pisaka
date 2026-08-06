# Bottom dock panel: Terminal/Git as buttons + fix the empty gap after closing the terminal

## Overview

Replace the "mode"-style access to the terminal and Log (currently menu-only via View) with a permanent bottom bar with buttons, VS Code-style. Both features become bottom dock panels above an always-visible bar. Along the way, fix the bug: closing the last terminal tab leaves `showTerminal == true`, so the panel draws an empty tab bar → "empty gap at the bottom". The full-screen Log mode (`workspaceMode == .log`) is removed — Log moves into the same bottom panel.

## Context

- Files involved:
  - `Sources/Pisaka/ContentView.swift` — window body, editorSplit; replace `workspaceMode`/`showTerminal` with `bottomPanel`
  - `Sources/Pisaka/PisakaApp.swift` — state, View menu, `toggleTerminal`
  - `Sources/Pisaka/TerminalPanelView.swift` — unchanged (close still calls `model.close`)
  - `Sources/PisakaCore/` — new pure toggle helper + enum
  - `Tests/PisakaCoreTests/` — test for the toggle
- Related patterns:
  - Color-free / pure logic in Core with a test — like `FileIconColor`, `LogFilter` (toggle logic moves to Core, the view stays thin)
  - Binding callbacks threaded `PisakaApp → ContentView` (like `showTerminal`, `workspaceMode`)
- State: one `BottomPanel` enum (`.terminal`, `.log`) + `BottomPanel?` (nil = panel hidden). Toggle: clicking the active one → nil, otherwise → the selected one.

## Development Approach

- **Testing approach**: Regular (code first, then test). The pure toggle logic moves to Core and is covered by a test; the rest is a thin view layer (untested, per project convention).
- CLAUDE.md: every behavioral change ships with a PisakaCore test; the toggle helper satisfies that requirement.
- Finish each task completely; the whole suite must be green before the next.
- **CRITICAL: every task that touches Core MUST include new/updated tests**
- **CRITICAL: all tests must pass before starting the next task**

## Implementation Steps

### Task 1: BottomPanel enum + pure toggle helper in Core (with test)

**Files:**
- Create: `Sources/PisakaCore/BottomPanel.swift`
- Create: `Tests/PisakaCoreTests/BottomPanelTests.swift`

- [x] Declare `public enum BottomPanel: Equatable { case terminal, log }`
- [x] Add pure `public static func toggled(_ current: BottomPanel?, selecting target: BottomPanel) -> BottomPanel?`: if `current == target` → nil, otherwise `target`
- [x] Tests: clicking the active one (`.terminal` when `current == .terminal`) → nil; clicking the inactive one → target; from nil → target; switching `.terminal` ↔ `.log`
- [x] `swift test` — must pass before Task 2

### Task 2: ContentView — bottom bar, panel, empty-gap fix

**Files:**
- Modify: `Sources/Pisaka/ContentView.swift`

- [x] Remove the `workspaceMode: Binding<WorkspaceMode>` and `showTerminal: Binding<Bool>` properties; introduce `var bottomPanel: Binding<BottomPanel?> = .constant(nil)`
- [x] Delete the file-scope `enum WorkspaceMode` (moved to Core as `BottomPanel`)
- [x] Body: `VStack(spacing: 0) { mainArea; Divider(); bottomBar }`, where mainArea is `VSplitView { editorSplit; panelContent(panel) }` when a panel is shown, otherwise `editorSplit`
- [x] Empty-gap fix: show the bottom branch only when `panel == .terminal && !terminalSessions.sessions.isEmpty` (no such condition for `.log`); this removes the empty tab bar
- [x] `.onChange(of: terminalSessions.sessions.isEmpty)`: if it became empty and `bottomPanel.wrappedValue == .terminal` → `bottomPanel.wrappedValue = nil` (so a repeat click/⌘⇧T reopens without a double press)
- [x] `panelContent(_:)`: `.terminal` → `TerminalPanelView(model: terminalSessions, projectRoot: model.projectRoot)`; `.log` → `CommitLogView(model: commitLog, projectRoot: model.projectRoot)` without `minWidth: 640`/`minHeight: 400` (they over-expand the panel), with a reasonable `minHeight` (e.g. 160)
- [x] `bottomBar`: an `HStack` of two toggle buttons (icon + label Terminal / Git), the active one highlighted, then a `Spacer`. Button click routed through the shared `onTogglePanel` handler (in `PisakaApp`) so it behaves identically to the View menu: for `.terminal`, if `terminalSessions.sessions.isEmpty` — create a session (`terminalSessions.newSession(projectRoot:)`), then `BottomPanel.toggled(bottomPanel, selecting: .terminal)`; for `.log` — just toggle to `.log`
- [x] Update previews/default values so a default-constructed ContentView compiles (`bottomPanel` defaults to `.constant(nil)`)
- [x] `swift build` — compiles

### Task 3: PisakaApp — state and View menu

**Files:**
- Modify: `Sources/Pisaka/PisakaApp.swift`

- [x] Replace `@State workspaceMode` and `@State showTerminal` with `@State private var bottomPanel: BottomPanel? = nil`; thread `bottomPanel: $bottomPanel` into `ContentView` (drop the `workspaceMode`/`showTerminal` threading)
- [x] View menu: "Git Log" (⌘⇧L) → `togglePanel(.log)`; "Terminal" (⌘⇧T) → create a session if needed, then `togglePanel(.terminal)`. Labels reflect active state (Show/Hide)
- [x] Remove the old full-screen Log logic and `toggleTerminal()` in its previous form (the first-session-creation logic now lives in the shared `togglePanel(_:)` handler, used by both the menu and the bottom bar via `onTogglePanel` — no duplication)
- [x] Keep `willTerminate → terminalSessions.terminateAll()` unchanged; keep the `commitLog`/`localChanges` refresh on folder change (`openFolder`) as is
- [x] `swift build` — compiles

### Task 4: Verify acceptance criteria

- [x] `swift build` — no errors
- [x] `swift test` — the whole suite green (including the new BottomPanelTests) — 502 tests, 0 failures

### Task 5: Update documentation

- [x] Update `CLAUDE.md`: the `ContentView` description (bottom bar + `bottomPanel`), `PisakaApp` (replacing `WorkspaceMode`/`showTerminal` with `BottomPanel?`, View menu), add `BottomPanel.swift` to the Core files list
- [x] Update `README.md` if user-facing shortcuts/behavior change (Log/Terminal as bottom panels)

## Post-Completion (manual, not automated)

- The Terminal/Git bar is always visible at the bottom; a click opens the panel below.
- A repeat click / closing the last terminal tab collapses the panel with no empty gap.
- ⌘⇧T/⌘⇧L work as a toggle for the same panel; Log is no longer full-screen.

## Note

`CommitLogView` was drawn at full width (graph + columns + detail HSplit). In the bottom panel it will be shorter — functionally fine, but the detail diff may feel cramped. For this task we leave it as is; if needed later — a horizontal split inside the panel.
