# Local Changes: Show Diff in the context menu, and Cmd+D opens the diff when the panel has focus

## Overview

The Local Changes panel opens a changed file's diff only on a double-click; the
row's context menu offers just "Commit…" and "Revert". This change adds a
**Show Diff** context-menu item and makes a clean **Cmd+D** open the selected
row's diff while the panel owns keyboard focus, without touching the editor's
Cmd+D duplicate.

Two things make this more than pure wiring, and both are handled the way the
repository already does it:

1. The "what does activating this row open?" decision (`.conflicted` → the merge
   resolver, everything else → the side-by-side diff) is today an inline ternary
   duplicated in the view, and the two new triggers would duplicate it a third
   and fourth time. It moves into `LocalChangesModel` as pure static rules —
   next to `guardRevert`/`reconcile`/`revertedURLs`, which are exactly this shape
   — and is unit-tested there. No new Core file, so no new CLAUDE.md index line.
2. Focus scoping is done at the AppKit level, mirroring the editor's own gate:
   a non-drawing, hit-test-transparent `NSView` placed behind the panel with
   `.background(...)` (the `ZoomSurfaceMarker` pattern already in the codebase)
   becomes the window's first responder when a row is clicked, and overrides
   `performKeyEquivalent` with the same `window?.firstResponder === self`
   guard `EditorTextView` uses. macOS 13-safe: no SwiftUI `@FocusState`/
   `.onKeyPress`, and no main-menu item, so nothing can steal the editor's
   Cmd+D window-wide.

Per the answered question in this session, the conflicted row's menu is left
alone: **Show Diff appears on non-conflicted rows only**, conflicted rows keep
their existing "Resolve…" item (two items doing the same thing would be noise).
Cmd+D on a conflicted row still opens the resolver, via the same rule.

## Context

- Files involved:
  - `Sources/PisakaCore/LocalChangesModel.swift` — gains the pure activation
    rules (statics, no state).
  - `Tests/PisakaCoreTests/LocalChangesModelTests.swift` — the new tests.
  - `Sources/Pisaka/LocalChangesView.swift` — the context-menu item, the
    double-click routed through the rule, the focus anchor and the Cmd+D
    interception (all inside the existing `#if os(macOS)` file).
  - `docs/architecture/core-git-models.md`, `docs/architecture/app-git-views.md`
    — the two entries whose behavior changes.
  - `README.md`, `docs/FEATURES.md` — the shortcut table and the two feature
    bullets that currently describe Cmd+D and the Local Changes panel.
- Related patterns:
  - `EditorTextView.performKeyEquivalent` (`Sources/Pisaka/CodeEditorView.swift`
    ~line 3123) — the clean-Cmd+D modifier mask and the first-responder gate to
    mirror verbatim; it is **not** modified.
  - `ZoomSurfaceMarker` / `ZoomSurfaceMarkerView` (`Sources/Pisaka/ZoomSurface.swift`)
    — an `NSViewRepresentable` placed behind SwiftUI content, non-drawing,
    `hitTest → nil`, out of the accessibility tree.
  - `LocalChangesModel.guardRevert` / `.reconcile` / `.revertedURLs` — pure
    static decisions on the model, the precedent the new rules follow.
- Dependencies: none. No new files, no new Core types beyond two nested enums'
  worth of API on an existing model.

## Development Approach

- **Testing approach**: TDD for Task 1 (the Core rules); Tasks 2–3 are view-layer
  wiring, untested by repository convention — their correctness is carried by the
  Core rules they call plus the manual check in Post-Completion.
- Complete each task fully before moving to the next.
- **CRITICAL: every task MUST include new/updated tests** — for the view-layer
  tasks this means the existing suite stays green and no new decision is
  introduced in the view that Core tests do not already cover.
- **CRITICAL: all tests must pass before starting the next task.**
- No product/brand names in code, comments or docs.

## Implementation Steps

### Task 1: The activation rules in `PisakaCore`

**Files:**
- Modify: `Sources/PisakaCore/LocalChangesModel.swift`
- Modify: `Tests/PisakaCoreTests/LocalChangesModelTests.swift`

- [x] Write the tests first: a `.conflicted` file activates as the conflict
      resolver and every other `FileStatus` (modified/added/deleted/renamed/
      untracked) as the diff; the shortcut with no selection yields nothing and
      with a selection yields that file's activation; the context menu offers
      "Show Diff" for every status except `.conflicted`.
- [x] Add to `LocalChangesModel` a nested `public enum RowActivation: Equatable`
      with `case diff` and `case resolveConflict`, documented as "what opening a
      changed-file row means" — the one place the conflicted/ordinary split is
      decided, shared by the double-click, the context menu and the shortcut.
- [x] Add `public static func activation(for file: ChangedFile) -> RowActivation`
      returning `.resolveConflict` for `.conflicted` and `.diff` otherwise.
- [x] Add `public static func shortcutActivation(selected: ChangedFile?) -> RowActivation?`
      returning `nil` for no selection (the keystroke is consumed by the focused
      panel but does nothing — stated in the doc comment, since "nothing happens"
      is a deliberate outcome rather than an oversight) and
      `activation(for:)` otherwise.
- [x] Add `public static func offersShowDiff(for status: FileStatus) -> Bool`
      returning `status != .conflicted`, its doc comment recording *why*: a
      conflicted row already offers "Resolve…", which opens the very same window,
      so a second item under a second name would be two names for one action.
- [x] run `swift test` — must pass before Task 2.

### Task 2: The context menu item and the shared activation path

**Files:**
- Modify: `Sources/Pisaka/LocalChangesView.swift`

- [x] In `ChangedFileRow`, replace the inline `status == .conflicted` ternary in
      the double-click handler with a single `activate()` helper that switches on
      `LocalChangesModel.activation(for:)` and calls `onResolveConflict()` or
      `onOpenDiff()` — the one routing point every trigger goes through, so no
      second diff-opening path exists.
- [x] The row's activation needs the `ChangedFile`, not just its `FileStatus`:
      thread the file (or a pre-bound `RowActivation`) into `ChangedFileRow` and
      `ChangeNodeView` alongside the existing values, keeping both call sites
      (flat list and by-folder leaf) identical.
- [x] Add the context-menu item: `Button("Show Diff", action: activate)` shown
      when `LocalChangesModel.offersShowDiff(for: status)`, placed **first**,
      above "Commit…" and above the destructive "Revert"; the conflicted branch
      keeps its existing "Resolve…" + `Divider()` untouched.
- [x] Make a double-click also select the row (`onSelect()` before `activate()`),
      so opening a diff by double-click leaves the panel focused on that row —
      this is what makes "double-click, then Cmd+D on the next row" behave.
- [x] Update the file's header doc comment to name the three triggers that now
      share one activation path.
- [x] Tests: no new decision is added in the view (every branch calls the Task 1
      rules); confirm by re-running `swift test`, which must stay green before
      Task 3.

### Task 3: Panel focus and the Cmd+D interception

**Files:**
- Modify: `Sources/Pisaka/LocalChangesView.swift`

- [ ] Add a private `LocalChangesFocusAnchor: NSViewRepresentable` and its
      `NSView` (kept in this file, like `ZoomSurfaceMarker` lives with its
      representable): non-drawing, `hitTest` answering `nil` so it never stands
      between the pointer and a row, hidden from accessibility,
      `acceptsFirstResponder == true`.
- [ ] Override `performKeyEquivalent(with:)` on that view with the *same* gate
      shape as `EditorTextView`: `charactersIgnoringModifiers?.lowercased() == "d"`,
      `modifierFlags.intersection([.command, .shift, .option, .control]) == [.command]`,
      and `window?.firstResponder === self`. Anything else falls through to
      `super`, so Cmd+Shift+D and friends stay untouched. When the gate passes it
      invokes the handler and returns `true` even if nothing was selected — the
      focused panel owns the key, which is what keeps the keystroke from beeping
      or reaching any other surface. Record that reasoning in the doc comment.
- [ ] Wire the handler to `LocalChangesModel.shortcutActivation(selected:)` and
      route its result through the *same* `onOpenDiff`/`onResolveConflict`
      closures the double-click uses; `nil` does nothing.
- [ ] Give `LocalChangesView` a `@State private var focusRequest = 0`, bump it in
      each row's `onSelect` closure (alongside `model.select(file)`), and pass it
      into the anchor; `updateNSView` calls `window?.makeFirstResponder(nsView)`
      when the token changed and the view is not already first responder,
      dispatched asynchronously on the main queue so the responder change does not
      land inside a SwiftUI update pass. Document why the token exists (a value
      change is the only signal a representable gets).
- [ ] Attach the anchor with `.background(...)` on the panel's outer `VStack` —
      not on the list — so focus survives the placeholder states and an empty
      change list.
- [ ] Confirm nothing new declares `ZoomSurfaceProviding` (the anchor is chrome,
      drawn at no font at all) so `ZoomSourceGatingTests`' set equality still
      holds.
- [ ] run `swift test` — must pass before Task 4.

### Task 4: Documentation

**Files:**
- Modify: `docs/architecture/core-git-models.md`
- Modify: `docs/architecture/app-git-views.md`
- Modify: `README.md`
- Modify: `docs/FEATURES.md`

- [ ] `core-git-models.md`: extend the `LocalChangesModel.swift` entry with
      `RowActivation`, `activation(for:)`, `shortcutActivation(selected:)` and
      `offersShowDiff(for:)` — the one place the conflicted/ordinary split is
      decided, why "no selection" is a deliberate no-op, and why a conflicted row
      is offered no "Show Diff".
- [ ] `app-git-views.md`: rewrite the `LocalChangesView.swift` entry's activation
      paragraph — the three triggers (double-click, "Show Diff", Cmd+D) sharing
      one path through the Core rule, the new menu order (Show Diff → Commit… →
      Revert, with "Resolve…" + divider still above them on a conflicted row),
      the focus anchor (what it is, why it exists, why `hitTest → nil`, the
      focus token) and the `performKeyEquivalent` gate mirroring
      `EditorTextView`'s — including that Cmd+D is consumed with nothing selected
      and that the editor's own gate is what keeps the two meanings apart.
- [ ] `README.md`: change the Cmd+D shortcut row to state both meanings —
      duplicate the line/selection in the editor, show the selected file's diff
      when the Local Changes panel has focus — keeping the table's one-line-per-
      shortcut format.
- [ ] `docs/FEATURES.md`: update the duplicate-line bullet (which currently says
      Cmd+D "does nothing while focus is in the terminal or the project tree") to
      name the Local Changes panel as the one other surface that answers it, and
      extend the Local Changes bullet with the "Show Diff" context-menu item and
      the Cmd+D shortcut.
- [ ] run `swift test` (the doc-shape suites read repository files, so keep them
      green) — must pass before Task 5.

### Task 5: Verify acceptance criteria

- [ ] run `swift test` — the full `PisakaCore` suite must be green.
- [ ] run `swiftlint --strict` from the repository root — must be clean.
- [ ] run `xcodegen generate`, then the macOS build:
      `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' build`.
- [ ] run the iOS build:
      `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build`
      (nothing here is iOS-facing; the build proves the macOS-gated file stays
      gated).
- [ ] grep the diff for a second diff-opening call site: `onOpenDiff` /
      `onResolveConflict` must be invoked only from the shared activation helper
      and the existing "Resolve…" item.

### Task 6: Update documentation

- [ ] confirm `CLAUDE.md` needs no change (no new file, no new invariant — the
      rules live on an already-indexed Core model and the view is already
      indexed).
- [ ] re-read the two architecture entries against the final code and correct any
      drift introduced while implementing.

## Post-Completion (manual verification by a human)

- In a DEBUG macOS build with a repository open: right-click an ordinary changed
  row → "Show Diff" appears first, above "Commit…" and "Revert", and opens the
  same window a double-click opens; right-click a conflicted row → the menu is
  unchanged ("Resolve…", divider, Commit…, Revert).
- Click a row, then press Cmd+D → the diff (or the merge resolver, for a
  conflicted row) opens. With no row selected, Cmd+D in the panel does nothing
  and does not beep.
- Click into the editor and press Cmd+D → the line/selection duplicates. Cmd+D in
  the terminal and in the project tree behaves as it did before.
- Cmd+Shift+D anywhere behaves as it did before.
