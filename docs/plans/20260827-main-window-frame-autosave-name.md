# Main window: an explicit frame autosave name

## Overview

The main window opens small and centered on every launch: the size and position
the user gave it are never restored. The persistence layer is running — the
app's preferences domain accumulates one `NSWindow Frame …` entry per quit —
but the *key* it saves under is different every time.

Root cause (verified in this tree): with no explicit frame autosave name set,
the framework derives the key from the mangled type name of the window's
content view. Two types in that chain are declared in private contexts — the
sheet-selector enum `LeetCodeSheet` (`Sources/Pisaka/PisakaApp.swift:673`,
declared inside the `App` struct) and the interface-scale modifier applied to
the sheet content — and a private context renders in a mangled name as
`(unknown context at $10490b1e0)`. That placeholder is a **load address,
randomized by ASLR on every launch**. Both are reached from the scene-level
chain attached to `ContentView(…)` (`PisakaApp.swift:833`
`.sheet(item: $leetCodeSheet)` … `.interfaceScaled(settings)`), which is why the
key was stable before the sheets moved out to the scene and unstable after.
Each launch therefore computes a fresh key, finds nothing under it, falls back
to the default size (which here is the scaled `minWidth: 640` / `minHeight: 400`
floor at `ContentView.swift:323`, there being no `.defaultSize`) and centers; on
quit it writes the frame under that launch's one-off key.

The fix: give the main window an explicit, deliberately chosen frame autosave
name, so the key stops depending on the modifier chain's type names at all —
under ASLR today and under any future refactor.

## Placement: this is view-side glue, and Core gets nothing (requirement 5)

Stated explicitly, as the ticket asks. Reaching the hosting window and calling
the window API is macOS view-layer by nature. There is also no *decision* left
over for Core to own: the name is one constant, the sequence is two calls in a
fixed order, and neither has an input, a branch or a value another surface would
have to agree with. Putting the string in Core would create a second home for a
constant used in exactly one file and tested by nothing that Core could see —
the persisted-key comparison to `SettingsStore` does not hold, because a
settings key is read and written by Core itself while this one is only ever
handed to the framework.

What `swift test` *can* see is the source-level rule, and that is where the
coverage goes: a new repository-file gating suite in the
`BottomPanelSourceGatingTests` / `ZoomSourceGatingTests` mould, reading
`Sources/Pisaka/**` through `#filePath` with Foundation only and matching
against comment- and literal-stripped text (load-bearing as always — the new
file documents its own rules at length).

## Context

- Modify: `Sources/Pisaka/PisakaApp.swift` — attach the glue to the scene's
  content.
- Create: `Sources/Pisaka/MainWindowFrameAutosave.swift` — the whole fix,
  `#if os(macOS)`-gated.
- Create: `Tests/PisakaCoreTests/MainWindowFrameSourceGatingTests.swift`.
- Modify: `docs/architecture/app-shell.md`, `CLAUDE.md` (one index line + the
  gating-suite list in Tests).

Related patterns:

- `Sources/Pisaka/ZoomSurface.swift` — `ZoomSurfaceMarker` /
  `ZoomSurfaceMarkerView`: the precedent for a zero-cost, non-drawing,
  hit-test-transparent `NSViewRepresentable` marker attached with
  `.background(…)` purely to reach AppKit.
- `Sources/Pisaka/ProjectTreeDraftField.swift:260` — the `viewDidMoveToWindow`
  precedent (the first moment AppKit guarantees a window).
- `Tests/PisakaCoreTests/LSPSourceGatingTests.swift` —
  `strippingCommentsAndStringLiterals(_:)` and `containsToken(_:in:)`, reused by
  the bottom-panel suite and to be reused here.
- The five auxiliary window controllers (`DiffWindowController.swift:34`,
  `MergeWindowController.swift:62`, `ProjectSearchWindowController.swift:44`,
  `SourceViewerWindowController.swift:105`,
  `LeetCodeBrowserWindowController.swift:53`) each call `window.center()` —
  deliberate, out of scope, and pinned as such.

Dependencies: none.

## Development Approach

- **Testing approach**: Regular (code first, then the gating suite).
- The fix is macOS-gated end to end (`#if os(macOS)` around the whole new file),
  so the iOS build is untouched.
- Complete each task fully before moving to the next.
- **CRITICAL: every task MUST include new/updated tests**
- **CRITICAL: all tests must pass before starting the next task**

## Implementation Steps

### Task 1: The autosave glue

**Files:**
- Create: `Sources/Pisaka/MainWindowFrameAutosave.swift`

- [x] Wrap the whole file in `#if os(macOS)`; import `AppKit` and `SwiftUI`.
- [x] Declare the chosen name once, as a private file-level constant:
      `private let mainWindowFrameAutosaveName = "MainWindow"`. Document that it
      is chosen, not derived; that the framework writes it into the preferences
      domain as `NSWindow Frame MainWindow`; and that renaming it later is a
      deliberate, one-time loss of the saved frame.
- [x] Add `struct MainWindowFrameAutosave: NSViewRepresentable` over an internal
      `final class MainWindowFrameAutosaveView: NSView`, in the
      `ZoomSurfaceMarker` mould: draws nothing, `hitTest(_:)` answers `nil`,
      `setAccessibilityElement(false)`, `updateNSView` empty.
- [x] In `viewDidMoveToWindow()`, after `super`: return early when already
      adopted, when `window == nil`, or when `window.isSheet` (defensive — the
      marker lives in the window content, never in a sheet, and a sheet must
      never take the main window's name).
- [x] Perform the two calls in this exact order, and say in a comment why the
      order is the rule: **restore first** —
      `_ = window.setFrameUsingName(mainWindowFrameAutosaveName)`, which applies
      the saved frame if one exists and does nothing on a first run — **then
      adopt** — `guard window.setFrameAutosaveName(mainWindowFrameAutosaveName)
      else { return }`, which registers the window to save on move/resize/close.
      Adopting first can write the window's *current* (default) frame under the
      name and destroy the value about to be read. `setFrameAutosaveName`
      returning `false` means another window already holds the name: leave the
      one-shot flag down so a later `viewDidMoveToWindow` retries, and do not
      treat it as success.
- [x] Set the one-shot flag only on success. Note in the comment that restore is
      idempotent anyway (re-applying the same frame is a no-op) and that the flag
      exists so a SwiftUI re-parent cannot undo a resize the user has since made.
- [x] Document the sizing interaction (requirement 2): `viewDidMoveToWindow` is
      the first moment a window exists and it fires before the window is ordered
      front, so the restored frame lands before first paint and wins over the
      content's `minWidth`/`minHeight` floor, which is a *minimum* and not a
      preferred size — the two do not fight, they compose (a saved frame below
      the floor is clamped up by `setFrame`, which honours `minSize`; a saved
      frame off the current display arrangement is constrained to a screen by the
      same call). Record the escalation ladder in the same comment, so a future
      reader knows what was considered and in what order: re-applying once on the
      next main-runloop turn, and only then a one-shot
      `NSWindow.didBecomeKeyNotification` observer — neither is implemented,
      because neither is needed unless the manual check in Post-Completion shows
      a visible jump.
- [x] Write the file's doc comment as the record of the root cause: what the
      derived key is made of, why a private context makes it address-mangled, and
      that this is why the name is explicit.
- [x] No test yet — the gating suite lands in Task 3 and needs the attachment
      from Task 2.

### Task 2: Attach it to the main scene

**Files:**
- Modify: `Sources/Pisaka/PisakaApp.swift`

- [x] Attach `.background(MainWindowFrameAutosave())` to the scene's
      `ContentView(…)`, in the same modifier chain that carries
      `.sheet(item: $leetCodeSheet)` and `.onAppear`. Place it **before** the
      sheet modifier so the marker is part of the window content proper and
      cannot be pulled into a presentation.
- [x] Comment at the call site: this is the only place the main window's frame
      identity is established, the auxiliary windows deliberately have none, and
      the attachment must not be moved inside `ContentView` (the marker must sit
      in the scene's own content so exactly one window ever adopts the name).
- [x] Leave everything else in the chain untouched — the sheets, the
      interface-scale injection on the sheet content, and `.onAppear`'s session
      restore all keep their current behavior; the fix deliberately does *not*
      try to un-mangle the derived key by moving the sheets back.
- [x] Confirm nothing else in the file needs a change (no `.defaultSize` is
      introduced — a default size would compete with the restored frame for no
      benefit).

### Task 3: The gating suite

**Files:**
- Create: `Tests/PisakaCoreTests/MainWindowFrameSourceGatingTests.swift`

- [x] Read `Sources/Pisaka/` through `#filePath`, Foundation only, reusing
      `LSPSourceGatingTests.strippingCommentsAndStringLiterals(_:)` and
      `containsToken(_:in:)` exactly as `BottomPanelSourceGatingTests` does.
      Write the suite's doc comment explaining each rule and why the compiler
      cannot see it.
- [x] `testExactlyOneAppFileNamesTheFrameAutosaveAPI` — scan every `.swift` file
      under `Sources/Pisaka/` (recursively, iOS subtree included) for
      `setFrameAutosaveName` or `setFrameUsingName` and assert the resulting
      file-name set equals `["MainWindowFrameAutosave.swift"]` **by set
      equality**. This is what pins requirement 3 and requirement 4 at once: a
      second window adopting a name, or the main window's adoption being
      duplicated somewhere else, fails here.
- [x] `testRestoreComesBeforeAdopt` — in the stripped source of
      `MainWindowFrameAutosave.swift`, locate the first line naming
      `setFrameUsingName` and the first naming `setFrameAutosaveName`, and assert
      the former is strictly earlier. Swapping the two compiles, type-checks and
      reads as reasonable while silently overwriting the saved frame with the
      default one on every launch — exactly the bug this ticket fixes, in a new
      disguise.
- [x] `testTheGlueIsMacOSGated` — the first significant (non-blank, non-comment)
      line of `MainWindowFrameAutosave.swift` is `#if os(macOS)`, matching the
      check `LSPSourceGatingTests` already makes for the app-side LSP files, so
      the iOS build cannot start compiling AppKit.
- [x] `testTheSceneInstallsTheMarker` — the stripped source of `PisakaApp.swift`
      names `MainWindowFrameAutosave`. Without this the glue file could exist,
      satisfy every rule above, and be attached to nothing.
- [x] `testAuxiliaryWindowsStillCenterThemselves` — each of the five controller
      files (`DiffWindowController`, `MergeWindowController`,
      `ProjectSearchWindowController`, `SourceViewerWindowController`,
      `LeetCodeBrowserWindowController`) names `center` in stripped source. Their
      per-use centering is the deliberate alternative to a saved frame, and the
      set-equality test above only says they carry no autosave name.
- [x] Run `swift test` — must pass before Task 4.

### Task 4: Verify the automated gates

- [ ] `swift test` — green.
- [ ] `swiftlint --strict` from the repository root — clean.
- [ ] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination
      'platform=macOS' build` — green (run `xcodegen generate` first if the
      project file is stale; the new source file needs no `project.yml` change,
      the target globs `Sources/Pisaka`).
- [ ] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination
      'platform=iOS Simulator,name=iPhone 17 Pro' build` — green, proving the
      gating.

### Task 5: Update documentation

- [ ] `docs/architecture/app-shell.md` — add a full entry for
      `MainWindowFrameAutosave.swift` recording the rule: the main window carries
      an explicit frame autosave name because the framework-derived key embeds
      private-context type names that are address-mangled and therefore unstable
      across launches; the restore-before-adopt order and what breaks without it;
      the name being a chosen constant whose rename costs the saved frame once;
      the sizing interaction with the content's minimum-size floor and the
      un-taken escalation ladder; and that the auxiliary windows deliberately
      carry no name and center per use.
- [ ] `docs/architecture/app-shell.md` — extend the `PisakaApp.swift` entry with
      the one-line note that the scene attaches the marker to its content, before
      the sheet modifiers, and why it must not move into `ContentView`.
- [ ] `CLAUDE.md` — one index line under the `app-shell.md` list for
      `MainWindowFrameAutosave.swift`, and add `MainWindowFrameSourceGatingTests`
      to the Tests section's list of repository-file gating suites (one clause;
      keep the file's size target in mind — the full rationale stays in
      `app-shell.md`).
- [ ] No `README.md` / `docs/FEATURES.md` change: a window that reopens where it
      was left is restored expected behavior, not a new feature to announce.

## Post-Completion (manual — for the user)

- Launch the app, move/resize the window to the left half of the display, quit,
  relaunch: the window returns at that exact frame, not small-and-centered.
  Repeat once more — two consecutive relaunches prove the key is stable.
- `defaults read ws.karmanov.pisaka | grep 'NSWindow Frame'`: exactly one new
  entry, `NSWindow Frame MainWindow`, updated in place across relaunches rather
  than joined by a new sibling each time. The pre-existing dead entries stay as
  they are — cleaning them is out of scope.
- Spot-check that nothing else moved: session restore still reopens the folder,
  tabs and selection; both sheets still present at the right scale; the window
  still refuses to shrink past its minimum.
- If a visible jump appears after first paint (the restored frame briefly losing
  to the framework's own sizing), take the next rung of the ladder recorded in
  the glue file's comment — re-apply once on the next main-runloop turn — and
  only then the one-shot key-window observer.

## Out of scope

Frame persistence for the auxiliary windows; full state restoration beyond what
session restore already does; cleaning the accumulated dead preference entries;
multi-window support for the main scene.
