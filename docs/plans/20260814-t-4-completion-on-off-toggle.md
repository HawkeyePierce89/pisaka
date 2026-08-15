# T-4: Completion on/off toggle

## Overview

Add a persisted `completionEnabled` boolean to `SettingsStore` (default on) and gate
both completion surfaces on it: the macOS AppKit popup fed by `CompletionController`,
and the iOS QuickType-style strip driven by `CodeEditorCoordinator_iOS`. Off means no
completion UI at all — automatic and explicitly invoked alike — while the symbol
index, the LSP layer and go-to-definition are left completely untouched. Surfaces: a
compact toggle at the trailing edge of the macOS status bar, a checkbox in
Preferences → General, and a row in the iOS Settings screen — all three bound to the
one store property.

## Context

- Files involved:
  - Core: `Sources/PisakaCore/SettingsStore.swift`,
    `Tests/PisakaCoreTests/SettingsStoreTests.swift`
  - macOS: `Sources/Pisaka/CompletionController.swift`,
    `Sources/Pisaka/CodeEditorView.swift`, `Sources/Pisaka/ContentView.swift`,
    `Sources/Pisaka/SettingsView.swift`, `Sources/Pisaka/PisakaApp.swift`
  - iOS: `Sources/Pisaka/iOS/CodeEditorCoordinator_iOS.swift`,
    `Sources/Pisaka/iOS/CodeEditorView_iOS.swift`,
    `Sources/Pisaka/iOS/RootView_iOS.swift`,
    `Sources/Pisaka/iOS/SettingsView_iOS.swift`
  - Docs: `docs/architecture/core-services.md`, `docs/architecture/app-editor.md`,
    `docs/architecture/app-window.md`, `docs/architecture/app-ios.md`,
    `README.md`, `CLAUDE.md`
- Related patterns:
  - `fontSize` is the precedent for a store value reaching the editor: a plain `let`
    on the representable, applied in `updateNSView`/`updateUIView`. The new flag
    follows it exactly, so the editor gains no new observation path.
  - `Keys.*` stable strings + a lenient `init` read (`object(forKey:)` to tell
    "unset" from a stored value) is the store's existing key discipline.
  - `bottomBarButton` / `BranchSwitcherView` in `ContentView.bottomBar` is the
    status-bar idiom the new control follows (plain button style, accent tint when
    active).
- Dependencies: none. No SPM changes; `project.yml`, `Package.resolved`,
  `Package.swift`, `licenses.json` untouched.

## Design decisions to record in the docs

- The switch is **binary and total**: off silences the automatic popup/strip *and*
  explicit invocation (⌃Space, the Find > Complete menu item, AppKit's stock ⌥⎋/F5).
  The narrower JetBrains behaviour (auto-popup off, explicit invoke alive) was
  considered and deliberately rejected for this ticket as a complication; it is a
  possible follow-up. This must read as a decision in the docs, not as an omission.
- **Nothing in the intelligence stack is torn down.** No server is stopped, no
  session shut down, the registry is not touched, the symbol index keeps walking and
  refreshing. Only completion *requests* stop being made and completion *UI* stops
  being shown, which is what makes the toggle instant and free in both directions.
- Gating lives at the *entry* of each per-keystroke path, so when off there is no
  debounce task, no provider call, no resolve prefetch — not merely a discarded
  result.

## Development Approach

- **Testing approach**: Regular (code first, then tests). Core changes ship with
  `SettingsStoreTests` additions; the app layer is thin and untested by project
  convention, so its gate is the two `xcodebuild` builds.
- Complete each task fully before moving to the next.
- **CRITICAL: every task that changes Core MUST include new/updated tests.**
- **CRITICAL: `swift test` must pass before starting the next task.**

## Implementation Steps

### Task 1: The persisted setting in Core

**Files:**
- Modify: `Sources/PisakaCore/SettingsStore.swift`
- Modify: `Tests/PisakaCoreTests/SettingsStoreTests.swift`

- [x] add `Keys.completionEnabled = "settings.completionEnabled"` with a doc comment
      stating the key is stable and that this one flag is the single source of truth
      for both platforms
- [x] add `@Published public var completionEnabled: Bool` whose `didSet` writes
      straight through to `defaults`, defaulting to `true`
- [x] read it in `init` as `(defaults.object(forKey:) as? Bool) ?? true`, so both a
      missing key and a wrong-typed stored value fall back to on (the `fontSize`
      precedent — `bool(forKey:)` would read a missing key as `false`, i.e. silently
      off); comment why
- [x] extend the type-doc on `SettingsStore` to mention the new preference alongside
      the existing ones
- [x] tests in `SettingsStoreTests`: default is `true` on a fresh store; the value
      round-trips across a store rebuilt over the same suite; a wrong-typed stored
      value (a `String`) falls back to `true`; the key string is pinned in the
      stable-keys test
- [x] run `swift test` — must pass before Task 2

### Task 2: Gate the macOS completion path

**Files:**
- Modify: `Sources/Pisaka/CompletionController.swift`
- Modify: `Sources/Pisaka/CodeEditorView.swift`
- Modify: `Sources/Pisaka/ContentView.swift`

- [x] give `CompletionController` a `private(set) var isEnabled = true` plus
      `setEnabled(_:)`, ignoring an unchanged value
- [x] turning it off calls `reset()` (cancelling the pending debounce/provider task,
      bumping the generation, dropping the snapshot and every prefetched/in-flight
      resolve) and then, only if a snapshot was live, asks the text view to re-query
      — `textView.complete(nil)` — so the delegate, which now answers `[]`, closes a
      popup that is on screen; document that the snapshot's existence is the proxy
      for "the popup may be up", since only this controller ever supplies it
- [x] `update(provider:fileURL:language:explicit:)` returns immediately when
      disabled, after clearing the snapshot and forgetting the list, and *before*
      building the request or spawning the task: no debounce, no provider call, no
      resolve prefetch on any keystroke while off
- [x] `completions(forPartialWordRange:in:)` returns `[]` when disabled — this is
      what silences AppKit's stock ⌥⎋/F5, which reach the delegate without passing
      through `update`
- [x] `CodeEditorView` gains `var completionEnabled: Bool = true` (defaulted like
      `fontSize`'s neighbours so a default-constructed view still compiles),
      documented as a plain value rather than a new observed object so the editor
      gains no per-keystroke re-render path
- [x] apply it in `makeNSView` (beside `attachCompletion`) and in `updateNSView`
      through a coordinator method that forwards to the controller, so flipping the
      toggle takes effect on the very next SwiftUI update — no restart, no tab switch
- [x] `ContentView` passes `completionEnabled: settings.completionEnabled` to
      `CodeEditorView` (it already observes the store)
- [x] no unit tests: this layer is untested by convention; verified by the macOS
      build in Task 6

### Task 3: The macOS surfaces

**Files:**
- Modify: `Sources/Pisaka/ContentView.swift`
- Modify: `Sources/Pisaka/SettingsView.swift`
- Modify: `Sources/Pisaka/PisakaApp.swift`

- [x] add a compact toggle button at the **trailing end of `bottomBar`**, after
      `BranchSwitcherView`, in the existing plain-button idiom: an SF Symbol that
      reflects state (`lightbulb` when on, `lightbulb.slash` when off),
      accent-tinted when on and secondary when off, with a `.help(…)` tooltip naming
      the state ("Code completion: On" / "Code completion: Off")
- [x] the button writes straight through to `settings.completionEnabled` — no local
      `@State`, so the status bar and Preferences can never disagree
- [x] add `Toggle("Offer completions as you type", isOn: $settings.completionEnabled)`
      to `GeneralSettingsView`'s `Form`
- [x] disable the Find menu's "Complete" item while completion is off
      (`model.selectedID == nil || !settings.completionEnabled`), so an
      explicitly-invoked command is never a silent no-op; `PisakaApp` already holds
      the store as a `@StateObject`
- [x] no unit tests (view layer); verified by the macOS build in Task 6

### Task 4: Gate and expose the setting on iOS

**Files:**
- Modify: `Sources/Pisaka/iOS/CodeEditorCoordinator_iOS.swift`
- Modify: `Sources/Pisaka/iOS/CodeEditorView_iOS.swift`
- Modify: `Sources/Pisaka/iOS/RootView_iOS.swift`
- Modify: `Sources/Pisaka/iOS/SettingsView_iOS.swift`

- [x] give `CodeEditorCoordinator_iOS` a `completionEnabled` flag with a setter that
      ignores an unchanged value and, on being turned off, calls `clearCompletions()`
      — which cancels the in-flight debounce/provider task, bumps the generation and
      removes the accessory strip (`showCompletions([])` also drops `answeredMember`,
      so no receiver outlives the bar)
- [x] `updateCompletions(in:)` returns at the top when disabled (after hiding the
      strip), before the prefix scan and the request — so a keystroke or caret move
      costs nothing while off
- [x] `CodeEditorView_iOS` gains `var completionEnabled: Bool = true`, applied in
      `makeUIView` and `updateUIView` next to the existing font-size/`symbolIndex`
      wiring; `RootView_iOS` passes `settings.completionEnabled`
- [x] add `Toggle("Offer completions as you type", isOn: $settings.completionEnabled)`
      to the "Editor" section of `SettingsView_iOS`, beside the font-size stepper
- [x] no unit tests (view layer); verified by the iOS build in Task 6

### Task 5: Documentation

**Files:**
- Modify: `docs/architecture/core-services.md`, `docs/architecture/app-editor.md`,
  `docs/architecture/app-window.md`, `docs/architecture/app-ios.md`,
  `docs/architecture/app-shell.md`, `README.md`, `CLAUDE.md`

- [x] `core-services.md`: extend the `SettingsStore` entry with `completionEnabled` —
      the key string, the default-on lenient read (and why `object(forKey:)` rather
      than `bool(forKey:)`), that it is the single flag both platforms consult, that
      off is total (automatic *and* explicit), and that the auto-popup-only variant
      was considered and rejected as a follow-up
- [x] `app-editor.md`: update the `CompletionController` entry (the `isEnabled` gate
      at both the request entry and the delegate answer, the dismissal of a live
      popup, and that nothing in the LSP layer or the index is stopped) and the
      `CodeEditorView` entry (the plain-value flag, no new observation path)
- [x] `app-window.md`: note the status-bar toggle in the `ContentView` entry
      (trailing edge of the bottom bar, writes straight through to the store, mirrors
      the Preferences checkbox)
- [x] `app-ios.md`: note the gate in the `CodeEditorView_iOS` /
      `CodeEditorCoordinator_iOS` and `CompletionBar_iOS` entries, and the new row in
      the `SettingsView_iOS` entry
- [x] `app-shell.md`: the two files modified by Tasks 3–4 have their entries here —
      the `GeneralSettingsView` form enumeration gains the `Toggle` (and the
      settings-application list its fourth path), and the `PisakaApp` menu entry
      records "Complete"'s second gate plus the ⌃Space / ⌥⎋ / F5 asymmetry the
      greyed-out item cannot cover
- [x] `README.md`: mention the toggle where completion is described — the macOS
      autocompletion paragraph (status bar + Preferences, persisted, definition
      unaffected) and the iOS completion-strip paragraph (Settings row)
- [x] `CLAUDE.md`: update index one-liners only where a file's one-liner actually
      changed (the `SettingsStore.swift` line)

### Task 6: Verify acceptance criteria

- [x] `swift test` — full suite green (2712 tests, 0 failures)
- [x] `xcodegen generate` (no `project.yml` change is expected; confirm the project
      still generates) — regenerated cleanly
- [x] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' build`
      — BUILD SUCCEEDED
- [x] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'generic/platform=iOS' build`
      — BUILD SUCCEEDED
- [x] `git status` confirms `project.yml`, `Package.resolved`, `Package.swift` and
      `Resources/Licenses/licenses.json` are untouched (working tree clean; no diff
      in those four files across the branch)

## Post-Completion (user-run, manual)

- macOS: toggle off in the status bar → typing in a Swift file produces no popup,
  ⌃Space / Find > Complete produce nothing, ⌃⌘J go-to-definition still works; toggle
  on → completion returns on the next keystroke; the Preferences checkbox and the
  status-bar icon mirror each other; the state survives a relaunch; flipping off
  while a popup is on screen dismisses it.
- iOS: the strip disappears when the Settings row is turned off and returns when it
  is turned back on; Go to Definition from the edit menu keeps working while off.
