# Fix: close diff/merge windows on Esc

## Overview
Diff and merge windows are standalone, non-modal NSWindows. Pressing Esc makes
AppKit dispatch `cancelOperation(_:)` down the responder chain, but neither the
window nor the hosting controller handles it, so the window stays open. The fix:
add a small NSWindow subclass that calls `performClose(_:)` on `cancelOperation`,
and use it in both controllers instead of a plain NSWindow. Closing then goes
through the standard path (`windowWillClose` → `release` in the controller),
exactly like clicking the close button — no new leaks.

## Context
- Files involved:
  - Create: `Sources/Pisaka/EscClosableWindow.swift` — shared NSWindow subclass
  - Modify: `Sources/Pisaka/DiffWindowController.swift` — create the window via `EscClosableWindow`
  - Modify: `Sources/Pisaka/MergeWindowController.swift` — create the window via `EscClosableWindow`
- Related patterns:
  - `DiffWindowController.open(...)` creates the window via `NSWindow(contentViewController:)` (line 28)
  - `MergeWindowController.open(...)` creates the window via `NSWindow(contentRect:styleMask:backing:defer:)` (line 37)
  - Both retain the window in a set, install a `WindowDelegate`, and drop the
    window from the retained set in `windowWillClose` → `release(_:)`
  - `performClose(_:)` goes through `windowShouldClose`/`windowWillClose`, so
    `release(_:)` fires as usual
- Dependencies: AppKit only (view layer); no new external dependencies

## Development Approach
- **Testing approach**: Regular (view-only change)
- Per project convention (CLAUDE.md): all domain logic lives in `PisakaCore` and
  is unit-tested; the `Pisaka` layer (views, window controllers, NSWindow
  subclasses) is intentionally thin and not unit-tested. `EscClosableWindow` is
  pure view layer (like the windows and controllers themselves), so there are no
  new unit tests; verification is compilation plus a manual check.
- Existing `PisakaCore` tests are not touched and must continue to pass.
- Complete each task fully before moving to the next.

## Implementation Steps

### Task 1: Add the EscClosableWindow subclass and switch both controllers

**Files:**
- Create: `Sources/Pisaka/EscClosableWindow.swift`
- Modify: `Sources/Pisaka/DiffWindowController.swift`
- Modify: `Sources/Pisaka/MergeWindowController.swift`

- [x] Create `Sources/Pisaka/EscClosableWindow.swift` with `final class EscClosableWindow: NSWindow` overriding `cancelOperation(_:)` → `performClose(sender)`, with a doc comment explaining it is for the non-modal diff/merge windows and that `performClose` follows the standard `windowShouldClose`/`windowWillClose` → release-in-controller path
- [x] In `DiffWindowController.open(...)` replace `NSWindow(contentViewController: hosting)` with `EscClosableWindow(contentViewController: hosting)` (everything else unchanged)
- [x] In `MergeWindowController.open(...)` replace `NSWindow(contentRect:styleMask:backing:defer:)` with `EscClosableWindow(contentRect:styleMask:backing:defer:)` (everything else unchanged)
- [x] `swift build` — must compile without errors
- [x] `swift test` — the full existing `PisakaCore` suite must pass (the view layer is not test-covered per convention; no new tests)

### Task 2: Update documentation

**Files:**
- Modify: `CLAUDE.md`
- Modify: `README.md` (only if it has a shortcuts section)

- [x] Update `CLAUDE.md`: mention `EscClosableWindow` and that diff/merge windows close on Esc (in the `DiffWindowController`/`MergeWindowController` descriptions)
- [x] Update `README.md` only if it has a shortcuts section — add "Esc closes a diff/merge window" only if such a section exists (check first)

## Post-Completion

- [ ] Manual check (`swift run Pisaka`): open a diff window (double-click a file in Local Changes / a commit's file in Git Log) and close it with Esc; open a merge window (Resolve on a conflicted file) and close it with Esc.
- [ ] If Esc does not work in the merge window (the text view intercepts it) — fallback: override `keyDown` in `EscClosableWindow` and catch `event.keyCode == 53`.
