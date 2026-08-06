# Settings / Preferences (tab orientation, theme, font size)

## Overview

Add a Preferences window (⌘,) with three persisted settings: tab orientation (vertical column ↔ horizontal strip), theme (system/light/dark), and a shared editor font size (also adjustable via Cmd+scroll over any code view). Pure option types and the settings store live in `PisakaCore` (tested); the Preferences UI and applying each setting are thin view-layer wiring.

## Context

- Files involved (Core, new):
  - `Sources/PisakaCore/TabOrientation.swift`, `Sources/PisakaCore/ThemePreference.swift`, `Sources/PisakaCore/SettingsStore.swift`
  - `Tests/PisakaCoreTests/SettingsStoreTests.swift`
- Files involved (view layer):
  - `Sources/Pisaka/PisakaApp.swift` — owns `@StateObject` models in a single WindowGroup with `.commands`; add a `Settings` scene and `@StateObject var settings`.
  - `Sources/Pisaka/ContentView.swift` — `editorSplit` three-column `HSplitView`; `VStack { mainArea; Divider(); bottomBar }`. Renders `TabListView` in the middle column.
  - `Sources/Pisaka/TabListView.swift` / `TabRowView.swift` — vertical `ScrollView`/`LazyVStack` list; needs a layout mode (column ↔ row).
  - `Sources/Pisaka/CodeEditorView.swift` — editor font; `minimapLineHeight = 3`; `refreshGeometry`; minimap tokenizer feed.
  - `Sources/Pisaka/DiffView.swift` and `Sources/Pisaka/MergeView.swift` — pane fonts.
  - `Sources/Pisaka/LineNumberRulerView.swift` — `rulerFont` derives from `textView?.font?.pointSize`, recomputed per draw.
  - `Sources/Pisaka/MinimapView.swift` — owns `scrollWheel` reporting via `onScrollToOffset` (must not conflict with Cmd+scroll).
  - `Sources/Pisaka/SettingsView.swift` (new) — the Preferences form.
- Related patterns:
  - ObservableObject style — `WorkspaceModel` (plain `final class … ObservableObject`, `@Published`, injectable service) is the closest precedent for `SettingsStore`.
  - Move-logic-into-Core convention: semantic enums (`TabOrientation`/`ThemePreference`) stay SwiftUI-free; the `ColorScheme?` mapping lives in the view.
- Dependencies: none new. PisakaCore stays Foundation-only.

## Development Approach

- **Testing approach**: Regular (code first, then tests) for Core; the view layer is thin and not unit-tested per project convention.
- Complete each task fully before the next.
- **CRITICAL: every Core task MUST include new/updated tests.**
- **CRITICAL: full `swift test` must pass before starting the next task.**

## Implementation Steps

### Task 1: Core option enums + SettingsStore (+ tests)

**Files:**
- Create: `Sources/PisakaCore/TabOrientation.swift`, `Sources/PisakaCore/ThemePreference.swift`, `Sources/PisakaCore/SettingsStore.swift`
- Create: `Tests/PisakaCoreTests/SettingsStoreTests.swift`

- [x] `TabOrientation: String, CaseIterable, Equatable` — `.vertical`, `.horizontal`.
- [x] `ThemePreference: String, CaseIterable, Equatable` — `.system`, `.light`, `.dark` (no SwiftUI import).
- [x] `SettingsStore: ObservableObject` (Foundation only): `@Published` `tabOrientation`, `themePreference`, `fontSize`; `init(defaults: UserDefaults = .standard)` injectable; stable string keys; load persisted values in init (falling back to defaults: `.vertical`, `.system`, default font size ~13).
- [x] Persist each change back to the injected `UserDefaults` (didSet/observer). `fontSize` clamped to a fixed range (8…32) on write; expose `fontSizeStep`, `minFontSize`, `maxFontSize`, `defaultFontSize` constants. Add a `stepFontSize(by:)` (or `adjustFontSize(by:)`) that applies the step then clamps, for the Cmd+scroll path.
- [x] Tests: defaults on a fresh store; `fontSize` clamps below min and above max; the step helper stays clamped at the bounds; persistence round-trip via injected `UserDefaults(suiteName:)` (value set on one instance read back by another over the same suite); `TabOrientation`/`ThemePreference` raw values are the stable persisted strings.
- [x] run `swift test` — must pass before Task 2.

### Task 2: Settings scene + Preferences window, wired to the app

**Files:**
- Create: `Sources/Pisaka/SettingsView.swift`
- Modify: `Sources/Pisaka/PisakaApp.swift`

- [x] Add `@StateObject private var settings = SettingsStore()` to `PisakaApp`.
- [x] Add a `Settings { SettingsView(settings: settings) }` scene alongside the existing `WindowGroup` (this gives the standard ⌘, Preferences menu item automatically).
- [x] `SettingsView`: `@ObservedObject var settings`; a `Form` with a `Picker` for tab orientation, a `Picker` for theme, and a `Stepper` + numeric display (bound to `settings.fontSize`, clamped through the store).
- [x] Pass `settings` into `ContentView` (new parameter) so downstream views can read it; default value so a default-constructed `ContentView` (previews) still compiles.
- [x] run `swift test` — must pass (no Core changes expected; confirms the build is green).

### Task 3: Theme application (preferredColorScheme)

**Files:**
- Modify: `Sources/Pisaka/ContentView.swift` (and/or `PisakaApp.swift`)

- [x] Add a view-layer mapping `ThemePreference -> ColorScheme?` (`.system → nil`, `.light → .light`, `.dark → .dark`) kept in the view layer.
- [x] Apply `.preferredColorScheme(...)` at the window content root so it propagates to SwiftUI and the hosted AppKit views; observe `settings.themePreference` so a change re-applies live.
- [x] run `swift test` — must pass.

### Task 4: Tab orientation (TabListView horizontal mode + ContentView layout)

**Files:**
- Modify: `Sources/Pisaka/TabListView.swift`, `Sources/Pisaka/TabRowView.swift`, `Sources/Pisaka/ContentView.swift`

- [x] Give `TabListView` a layout mode parameter (vertical column vs horizontal strip); horizontal uses a horizontal `ScrollView`/`LazyHStack` of `TabRowView`s sized for a row strip; `TabRowView` adapts (e.g. no `maxWidth: .infinity` stretch in row mode).
- [x] In `ContentView`, read `settings.tabOrientation`: vertical keeps the current middle column in `editorSplit`; horizontal removes the tabs column and instead stacks the strip above the editor zone (a `VStack { TabListView(strip); CodeEditorView/placeholder }` inside the right zone), leaving `ProjectTreeView`, the bottom dock, and the three-zone split otherwise intact.
- [x] run `swift test` — must pass.

### Task 5: Shared font size in code views + gutter/minimap re-sync + Cmd+scroll

**Files:**
- Modify: `Sources/Pisaka/CodeEditorView.swift`, `Sources/Pisaka/DiffView.swift`, `Sources/Pisaka/MergeView.swift`, `Sources/Pisaka/LineNumberRulerView.swift`, `Sources/Pisaka/MinimapView.swift`

- [x] Thread `settings` (or just the `fontSize` value + a step callback) into `CodeEditorView`, `DiffView`, and `MergeView`; set their `NSTextView.font` to `.monospacedSystemFont(ofSize: settings.fontSize, …)` in `makeNSView`/`makePane`, and update it in `updateNSView` when `fontSize` changes.
- [x] On a font change in `CodeEditorView`: re-derive the gutter (`LineNumberRulerView` already reads `textView.font?.pointSize`, so trigger a redraw/`needsDisplay` + `ruleThickness` recompute) and recompute minimap geometry (`refreshGeometry`) so line-height-dependent geometry and the viewport rect stay correct. Verify `DiffView`/`MergeView` line alignment is unaffected (font is uniform across panes, so rows stay aligned).
- [x] Cmd+scroll: in the code `NSTextView` subclass(es), override `scrollWheel(with:)` — when `event.modifierFlags.contains(.command)`, step `settings.fontSize` by `fontSizeStep` in the sign of `scrollingDeltaY` (clamped via the store) and consume the event (do not call `super`, no normal scroll); otherwise call `super`. Ensure this lives on the editor text view, not `MinimapView`, so it does not conflict with the minimap wheel handler or the diff synced-scroll.
- [x] run `swift test` — must pass.

### Task 6: Verify acceptance criteria

- [x] run full test suite: `swift test` — all pass.
- [x] run `swift build` — compiles clean (warnings reviewed).
- [x] confirm new Core logic (`SettingsStore`, enums) is covered by `SettingsStoreTests`.

### Task 7: Update documentation

- [x] `README.md`: add Preferences (⌘,) — tab orientation, theme, font size (Cmd+scroll) — to the feature list/shortcuts.
- [x] `CLAUDE.md`: document `TabOrientation`, `ThemePreference`, `SettingsStore` under PisakaCore; the `Settings` scene / `SettingsView`; and where each setting is applied (theme on the content root, tab layout in `ContentView`, shared font size + Cmd+scroll in the code views with gutter/minimap re-sync).
