# UI zoom: three independent zoom zones on macOS, targeted by the pointer

## Overview

Add proportional zoom to the macOS app, split into three independently
persisted zones — **code**, **terminal**, **interface** — with the target of
every gesture chosen by where the pointer is at that moment, in any of the
app's windows.

The code zone *is* the existing `SettingsStore.fontSize` (no second setting).
The terminal gains `terminalFontSize` (default 13 = SwiftTerm's own default, so
nothing changes at 100%). The interface gains `interfaceScale` (default 1.0),
applied through a new `\.interfaceMetrics` SwiftUI environment value that every
macOS chrome view reads for its fonts, paddings, frames, icon sizes and row
heights — a full sweep, per the owner's answer, so 150% is genuinely
proportional rather than text-only.

All the decisions are pure `PisakaCore` code with tests: which zone a set of
hit-test candidates resolves to, the step/clamp/reset arithmetic shared by the
three scales, the accumulation of continuous scroll/pinch deltas into the same
discrete steps the keyboard produces, and the persisted keys with clamping on
write. The app layer contributes only: collecting candidates under the pointer,
one event monitor, three menu items, and applying the three scales to views.

### Planner decisions worth stating up front

- **"Code zone" is defined as "draws with the shared editor font."** That is the
  five surfaces the ticket lists *plus* two that already read `settings.fontSize`
  today: the Find-in-Files result rows and the LeetCode statement's HTML body
  (its CSS size is `settings.fontSize`). Both are therefore tagged as code
  surfaces for pointer targeting, so zooming over them grows what they draw —
  the alternative (targeting interface while the text follows the code size) is
  incoherent. Their surrounding chrome stays interface.
- **Pointer outside every app window** (only reachable via the menu shortcut):
  fall back to the key window's focused surface (code/terminal), else interface.
  A pure Core rule, tested.
- **One event monitor instead of per-view `scrollWheel` overrides.** A local
  `NSEvent` monitor for `[.scrollWheel, .magnify]` resolves the zone and
  swallows the event, which is what makes the terminal and the interface zone
  reachable at all (SwiftTerm and SwiftUI lists would otherwise consume the
  scroll). `CodeFontScroll.swift` and its four call sites are deleted; ⌘-scroll
  keeps working because the monitor accepts ⌘ as well as ⌃.
- **Known limit to document:** the LeetCode statement is a `WKWebView`; it
  follows the *code* zone through its CSS and does not follow the interface
  scale. Its chrome does.
- **Shortcuts:** ⌘= (and ⌘+), ⌘−, ⌘0. Verified free — no existing shortcut uses
  a digit or a punctuation key.

## Context

- Files involved (Core, new): `Sources/PisakaCore/ZoomZone.swift`,
  `ZoomScaleRule.swift`, `ZoomGestureAccumulator.swift`, `InterfaceMetrics.swift`
- Files involved (Core, modified): `SettingsStore.swift`
- Files involved (app, new): `Sources/Pisaka/ZoomSurface.swift`,
  `ZoomController.swift`, `InterfaceScaleEnvironment.swift`
- Files involved (app, deleted): `Sources/Pisaka/CodeFontScroll.swift`
- Files involved (app, modified): `PisakaApp.swift` (menu + monitor install),
  `TerminalSession.swift`, `TerminalSessionsModel.swift`, `TerminalPanelView.swift`,
  `SettingsView.swift`, plus the ~22 macOS view files carrying `.font(`/`.padding(`/
  `.frame(` (ContentView, ProjectTreeView, TabListView, TabRowView,
  BranchSwitcherView, SearchBarView, LocalChangesView, LogFilterBar,
  CommitLogView, CommitGraphView, MergeView, DiffWindowContent,
  ProjectSearchView, CommitDialogView, CommitUnifiedDiffView,
  AcknowledgementsView, LSPConsentBanner, LSPServerSettingsView,
  LSPInstalledLicenses, LeetCodeBrowserView, LeetCodeDescriptionView,
  LeetCodeJudgeView, LeetCodeLoginView, LeetCodeOpenProblemSheet)
- Docs: new `docs/architecture/core-zoom.md`; updates to `core-services.md`,
  `app-shell.md`, `app-terminal.md`, `app-window.md`, `CLAUDE.md` index,
  `docs/FEATURES.md`
- Related patterns: `SettingsStore`'s `didSet` clamp-on-write discipline;
  `TerminalSessionsModel.applyTheme(for:)` as the precedent for pushing a
  setting into every live session; the single `SettingsStore` created in
  `PisakaApp.init` and passed explicitly into every window/sheet root
- Dependencies: none new. SwiftTerm's `TerminalView.font` setter already
  re-computes cell dimensions and resizes (`resetFont()`), so a font change
  resizes the PTY without restarting the shell

## Development Approach

- **Testing approach**: Regular (code first, then tests) for the Core types;
  the app layer is untested by repository convention (thin views)
- Complete each task fully before moving to the next
- Every behavioral change lands with `PisakaCore` tests; `swift test` must be
  green before the next task starts
- Core stays Foundation-only and platform-neutral (the new types must compile
  for iOS even though nothing on iOS uses them); all app additions are inside
  `#if os(macOS)`
- No iOS file is touched; iOS behavior must not change
- **CRITICAL: every task MUST include new/updated tests**
- **CRITICAL: all tests must pass before starting the next task**

## Implementation Steps

### Task 1: Core — zones, scale arithmetic, and the three persisted scales

**Intent.** One vocabulary for "which zone", one arithmetic for "step, clamp,
reset", and three settings that all obey it — with the editor font size
re-expressed in terms of the shared rule rather than duplicated.

**Files:**
- Create: `Sources/PisakaCore/ZoomZone.swift`
- Create: `Sources/PisakaCore/ZoomScaleRule.swift`
- Modify: `Sources/PisakaCore/SettingsStore.swift`
- Create: `Tests/PisakaCoreTests/ZoomZoneTests.swift`
- Create: `Tests/PisakaCoreTests/ZoomScaleRuleTests.swift`
- Modify: `Tests/PisakaCoreTests/SettingsStoreTests.swift`

- [x] `ZoomZone` (`code`, `terminal`, `interface`), `ZoomSurfaceKind`
      (`code`, `terminal` — illegal states unrepresentable, `.interface` is
      never a surface) and `ZoomSurfaceCandidate` (`kind` + `depth`)
- [x] `ZoomZone.resolve(pointer:focusedSurface:)` where `pointer` is either
      `.insideApp([ZoomSurfaceCandidate])` or `.outsideApp`: deepest candidate
      wins, ties resolve to the first in scan order (documented), no candidates
      → `.interface`, `.outsideApp` → `focusedSurface?.zone ?? .interface`
- [x] `ZoomScaleRule` (min/max/default/step) with `clamp(_:)` — non-finite
      collapses to the default, keeping the existing NaN-recursion guard's
      reasoning — and `stepped(_:by:)`, which snaps to the step grid so N steps
      up and N down return *exactly* the starting value
- [x] Three shipped rules: `.editorFont` (8…32, default 13, step 1 — the
      existing constants), `.terminalFont` (8…32, default 13 = SwiftTerm's
      `NSFont.systemFontSize` default, step 1), `.interfaceScale`
      (0.8…2.0, default 1.0, step 0.1)
- [x] Re-express `SettingsStore.clampFontSize` / `stepFontSize` over
      `ZoomScaleRule.editorFont` with the public API and existing behavior
      unchanged
- [x] Add `terminalFontSize` and `interfaceScale` `@Published` properties with
      the same clamp-in-`didSet` write discipline, under new stable keys
      `settings.terminalFontSize` and `settings.interfaceScale`, both clamped on
      load and both falling back to their default for an absent/wrong-typed/
      non-finite stored value
- [x] Add the zone-keyed API the app layer will use: `scale(for:)`,
      `stepZoom(_:by:)`, `resetZoom(_:)` — so no view has to know which property
      backs which zone
- [x] Write tests: zone resolution for every case (deepest wins, nested
      candidates, empty → interface, outside-app with and without a focused
      surface); step/clamp/reset for all three rules incl. bounds, non-finite,
      and the round-trip-to-exactly-the-default property; settings round-trip
      and clamp-on-write for the two new keys; key stability
- [x] run `swift test` — must pass before Task 2

### Task 2: Core — continuous gesture accumulation and interface metrics

**Intent.** Scroll and pinch must reach the same discrete values the keyboard
does, and the interface scale must turn into concrete point sizes somewhere
pure, so the whole view sweep is arithmetic-free.

**Files:**
- Create: `Sources/PisakaCore/ZoomGestureAccumulator.swift`
- Create: `Sources/PisakaCore/InterfaceMetrics.swift`
- Create: `Tests/PisakaCoreTests/ZoomGestureAccumulatorTests.swift`
- Create: `Tests/PisakaCoreTests/InterfaceMetricsTests.swift`

- [x] `ZoomGestureAccumulator`: a threshold-configured value type whose
      `accumulate(...)` returns the whole number of steps to apply and retains
      the remainder, so a slow drag feels continuous and never double-steps
- [x] Normalize both scroll flavors *in Core*: precise (trackpad, points) and
      line-based (wheel), so the app passes the raw delta plus a `precise` flag
      and makes no decision of its own; a pinch feeds magnification deltas
      against a smaller threshold
- [x] `reset()` (gesture end, or the pointer crossing into another zone
      mid-gesture) and a documented direction-reversal rule
- [x] `InterfaceTextStyle` — the semantic styles the macOS views actually use —
      with each style's macOS base point size, and `InterfaceMetrics(scale:)`
      exposing `font(_:)` → point size and `pt(_:)` → a scaled metric, rounding
      so text lands on crisp sizes
- [x] Write tests: accumulating N×threshold reaches exactly the N discrete
      steps; sub-threshold deltas produce nothing but are not lost; mixed
      precise/line input; reset clears the remainder; `InterfaceMetrics(scale: 1)`
      returns every style's base size unchanged (the "nothing changes at 100%"
      guarantee) and scaling is monotonic across the whole range
- [x] run `swift test` — must pass before Task 3

### Task 3: App — pointer hit-testing, the event monitor, and the View menu

**Intent.** One place that answers "what is under the pointer", one place that
receives every zoom gesture, and three menu items that go through the same path.

**Files:**
- Create: `Sources/Pisaka/ZoomSurface.swift`
- Create: `Sources/Pisaka/ZoomController.swift`
- Modify: `Sources/Pisaka/PisakaApp.swift`
- Modify: `Sources/Pisaka/CodeEditorView.swift`, `DiffView.swift`,
  `MergeView.swift`, `SourceViewerContent.swift`, `TerminalSession.swift`,
  `ProjectSearchView.swift`, `LeetCodeDescriptionView.swift`
- Delete: `Sources/Pisaka/CodeFontScroll.swift`

- [x] `ZoomSurfaceProviding` (an `NSView` declaring its `ZoomSurfaceKind`),
      conformed to by the code text views and SwiftTerm's terminal view, plus a
      zero-cost `ZoomSurfaceMarker` representable for the two SwiftUI-drawn code
      surfaces (Find-in-Files result rows, the statement web view)
- [x] Candidate collection: find the frontmost window at the pointer via
      `NSWindow.windowNumber(at:belowWindowWithWindowNumber:)` — a window
      belonging to another app resolves to `.outsideApp` — then walk that
      window's view tree collecting conforming, non-hidden views whose
      *visible* rect (so a scrolled-away view does not count) contains the
      point, with their depth; hand the list to `ZoomZone.resolve`
- [x] `ZoomController`: owns the per-zone accumulators, resolves the zone, and
      calls `settings.stepZoom/resetZoom`; installs one local `NSEvent` monitor
      for `[.scrollWheel, .magnify]` that handles ⌃ *and* ⌘ modified scrolls and
      every pinch, swallowing what it handles and passing everything else through
- [x] Install and tear the monitor down alongside the existing app-lifecycle
      observers in `PisakaApp`
- [x] View menu: Zoom In (⌘=, with a ⌘+ alternate), Zoom Out (⌘−), Reset Zoom
      (⌘0), each resolving the zone from the pointer at invocation time
- [x] Delete `CodeFontScroll.swift` and its four `scrollWheel` overrides — the
      monitor now covers them
- [x] Tests: the Core rules exercised here are already covered by Tasks 1–2;
      extend `ZoomZoneTests` with the candidate shapes this task actually
      produces (editor nested in a scroll view inside a split view; terminal
      under the bottom panel's chrome; a marker inside a list row)
- [x] run `swift test` — must pass before Task 4

### Task 4: App — the terminal zone

**Intent.** A persisted terminal font size applied to every live session the way
the theme already is, and a Preferences row beside the editor's.

**Files:**
- Modify: `Sources/Pisaka/TerminalSession.swift`, `TerminalSessionsModel.swift`,
  `TerminalPanelView.swift`, `ContentView.swift`, `SettingsView.swift`
- Modify: `Tests/PisakaCoreTests/SettingsStoreTests.swift`

- [x] `TerminalSession.applyFont(size:)` setting `terminalView.font` to a
      monospaced system font, guarded like `applyTheme` so a no-op assignment
      does not disturb a running session
- [x] `TerminalSessionsModel.applyFontSize(_:)` fanning it over every session,
      and applying the current size to each newly created session
- [x] Wire the size from `settings.terminalFontSize` at creation and on change
      (the `applyTheme` precedent), leaving the panel's tab strip on the
      *interface* zone
- [x] Preferences: a "Terminal font size" stepper beside the editor's, sharing
      the store's clamping
- [x] Extend the settings tests with the terminal size's stepping/clamping
      through the zone-keyed API
- [x] run `swift test` — must pass before Task 5

### Task 5: App — interface scale plumbing and the main window sweep

**Intent.** Get `InterfaceMetrics` into every SwiftUI root, then make the
surfaces the user lives in genuinely proportional.

**Files:**
- Create: `Sources/Pisaka/InterfaceScaleEnvironment.swift`
- Modify: `Sources/Pisaka/ContentView.swift`, `ProjectTreeView.swift`,
  `TabListView.swift`, `TabRowView.swift`, `BranchSwitcherView.swift`,
  `SearchBarView.swift`, `TerminalPanelView.swift`, `LocalChangesView.swift`,
  `LogFilterBar.swift`, `CommitLogView.swift`, `CommitGraphView.swift`,
  `MergeView.swift`, `DiffWindowContent.swift`, `ProjectSearchView.swift`,
  `PisakaApp.swift`

- [x] `EnvironmentValues.interfaceMetrics` plus an `.interfaceScaled(settings)`
      modifier applied at the `ContentView` root, the `Settings` scene, and
      every `NSHostingController` root (diff windows, source viewer, Find in
      Files, LeetCode browser, merge windows, sheets) — each of which already
      receives the one shared `SettingsStore`
- [x] Sweep the main-window chrome: every `.font(...)`, numeric `.padding(...)`,
      fixed `.frame(...)`, icon size and row height goes through
      `metrics.font(...)` / `metrics.pt(...)`, including the minimum window/pane
      widths so nothing clips at the top of the range
- [x] Leave code-font sites alone: anything reading `settings.fontSize` (the
      Find-in-Files snippets, the commit dialog's diff) stays on the code zone
      and must **not** be multiplied by the interface scale
- [x] Scale the commit-graph gutter's lane geometry with the interface scale so
      the graph keeps pace with the Log rows
- [x] Tests: any per-view constant that becomes a computed value derived from
      the scale gets its arithmetic covered by `InterfaceMetricsTests`
      (extend rather than duplicate)
- [x] run `swift test` — must pass before Task 6

### Task 6: App — sweep the dialogs, Preferences, LSP and LeetCode surfaces

**Intent.** Finish the sweep so the interface zone has no islands at 150%.

**Files:**
- Modify: `Sources/Pisaka/CommitDialogView.swift`, `CommitUnifiedDiffView.swift`,
  `SettingsView.swift`, `AcknowledgementsView.swift`, `LSPConsentBanner.swift`,
  `LSPServerSettingsView.swift`, `LSPInstalledLicenses.swift`,
  `LeetCodeBrowserView.swift`, `LeetCodeDescriptionView.swift`,
  `LeetCodeJudgeView.swift`, `LeetCodeLoginView.swift`,
  `LeetCodeOpenProblemSheet.swift`

- [ ] Same sweep over the commit dialog (its chrome; the unified diff body stays
      on the code font), Preferences and Acknowledgements, the three LSP
      provisioning surfaces, and the five LeetCode surfaces
- [ ] Scale sheet and window minimum sizes so a 200% Preferences pane or commit
      sheet still fits its content and nothing becomes unreachable
- [ ] Confirm by inspection that the statement `WKWebView` body remains on the
      code zone (its CSS already takes `settings.fontSize`) and note it for the
      known-limits doc entry in Task 7
- [ ] Tests: extend `InterfaceMetricsTests` with any newly derived metric that
      is not a plain multiply
- [ ] run `swift test` — must pass before Task 7

### Task 7: Documentation

**Files:**
- Create: `docs/architecture/core-zoom.md`
- Modify: `CLAUDE.md`, `docs/FEATURES.md`, `docs/architecture/core-services.md`,
  `app-shell.md`, `app-terminal.md`, `app-window.md`

- [ ] `core-zoom.md`: full entries for the four new Core files — the zone
      vocabulary and the deepest-candidate rule, the shared scale arithmetic and
      the three rules' numbers with their rationale, the accumulator's
      thresholds and reset rule, the interface metric tables — plus the app-side
      halves (hit-testing, the single event monitor, the three roots that inject
      the environment)
- [ ] `CLAUDE.md`: one index line per new file, the new doc in the index, and a
      cross-cutting note that the three zones are one arithmetic with one
      pointer rule and that the code zone remains the single `fontSize`
- [ ] `core-services.md`: `SettingsStore`'s two new keys and the zone-keyed API;
      `app-terminal.md`: the terminal font application path; `app-shell.md`: the
      menu items and the event monitor's lifecycle; `app-window.md`: the
      environment injection at each window root
- [ ] `docs/FEATURES.md`: the three zones, the pointer rule, all three gestures
      and the shortcuts, in the macOS section — and, under Known limitations,
      the LeetCode statement pane following the code zone rather than the
      interface scale
- [ ] run `swift test` — must pass (the repository-file suites read these docs'
      neighbours; keep them green)

### Task 8: Verify acceptance criteria

- [ ] `swift test` — full suite green
- [ ] `xcodegen generate` (only if `project.yml` changed; it should not have)
- [ ] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' build` — green
- [ ] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'generic/platform=iOS' build` — green
- [ ] Confirm by diff that no file under `Sources/Pisaka/iOS/` was modified and
      that no new Core type is referenced from iOS code — no behavior change on iOS
- [ ] Confirm `PisakaCore` still imports Foundation only

## Post-Completion (owed manual verification, performed by the user)

- ⌘+ with the pointer over the editor enlarges only the code — gutter and
  minimap following, exactly as the Preferences slider does today
- ⌘+ over the terminal enlarges only the terminal text; its tab strip does not
  change; the running shell survives and reflows to the new cell size
- ⌘+ over the project tree grows the whole interface proportionally, with layout
  reflow and crisp text; nothing clips or becomes unreachable at the extremes
- Ctrl-scroll and trackpad pinch do the same, by zone, and feel continuous
- The same three gestures resolve identically in a diff window, the source
  viewer, Find in Files and the LeetCode browser
- ⌘0 resets only the zone under the pointer
- All three scales survive a relaunch; the Preferences font-size row and code
  zoom stay in sync in both directions
