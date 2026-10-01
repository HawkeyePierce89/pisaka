# Keep the main window's top row below the title bar when the dock is open

## Overview

When any bottom-dock panel is open, `ContentView.mainArea` renders the editor
split inside a `GeometryReader` column. That column is pinned `.topLeading`,
carries the named coordinate space and is clipped. In that branch the whole
content moves up by about the title bar's height and slides under the
transparent title bar. With the dock closed the split renders directly and sits
correctly. The shift does not grow with the interface scale, which suggests the
top safe-area inset is being lost in the dock branch.

This plan does three things, in order:

1. Reproduce the shift headlessly and find its actual cause.
2. Fix that cause, with no hard-coded offset and no padding sized to the title
   bar.
3. Pin the fix where the pipeline can see it, and document the cause and the
   rule that now prevents it.

The comments for every guarantee the dock branch already makes must stay true
and accurate:

- nothing paints over the bottom bar;
- the divider drag is measured in the column's own space and tracks one-to-one;
- `BottomPanelHeightRule` stays the one authority on the panel's height;
- the window's minimum content size stays stated at the body root;
- the `.topLeading` pin still keeps the project tree's leading edge.

## Context

- Files involved:
  - `Sources/Pisaka/ContentView.swift` (`body`, `mainArea`, `editorSplit`,
    `panelDivider`, `panelColumnSpace`)
  - `Sources/Pisaka/MainWindowChrome.swift` (read only; it stays the title
    bar's only configurer)
  - `Sources/Pisaka/PisakaApp.swift` (read only; it shows how the scene
    attaches the chrome)
  - a new small app-layer file for the extracted dock column (see Task 1)
  - `Tests/PisakaAppTests/` (a new headless layout suite)
  - `Tests/PisakaCoreTests/BottomPanelSourceGatingTests.swift` (only if the
    cause can be stated as a source rule)
  - `docs/architecture/app-window.md`
  - `CLAUDE.md` (one index name for the new file)
- Related patterns:
  - `Tests/PisakaAppTests/MainWindowChromeTests.swift` already builds a real
    `NSWindow` and applies `MainWindowChrome.apply(to:)`.
  - `EditorLayoutHarness.swift` is the app bundle's precedent for headless
    layout.
  - SwiftUI's `WindowGroup` windows carry `fullSizeContentView`, so the content
    relies on the top safe area to stay clear of the title bar
    (`ProjectTreeDraftField.swift` notes this).
- Dependencies: none new.

## Development Approach

- **Testing approach**: reproduce first, but never commit a failing test.
  Task 1 builds the harness and runs the open-versus-closed assertion locally to
  observe the failure and bisect the cause; it commits only assertions that pass
  on the unfixed code, with the observed failure and the bisection result
  recorded in the suite's doc comment. Task 2 commits the equality assertion
  together with the fix.
- Every task ends with all gates green; each task is committed and the next one
  starts green.
- Logic that can live in Core lives in Core. This bug is pure SwiftUI/AppKit
  layout, so the test belongs in the app-layer bundle, plus a source rule in
  Core's gating suite if the cause is a modifier.
- No product or brand names in code, comments, docs or commits.
- Complete each task fully before moving to the next.
- **CRITICAL: every task MUST include new/updated tests**
- **CRITICAL: all tests must pass before starting next task**

## Implementation Steps

### Task 1: Extract the dock column, build the headless harness, and find the root cause

**Files:**
- Create: `Sources/Pisaka/BottomDockColumn.swift` (name may be adjusted, but it
  must be its own small file)
- Modify: `Sources/Pisaka/ContentView.swift`
- Create: `Tests/PisakaAppTests/BottomDockLayoutTests.swift`

**Why extract the container.** `ContentView` is too heavy to host in a test: it
has dozens of required models and closures. Move the dock branch's container
into a small internal generic view and leave `ContentView` behind it with
unchanged behaviour. The container is:

- the `GeometryReader`;
- the editor / divider / panel `VStack`;
- the `.topLeading` frame pin;
- the named coordinate space;
- the clip.

`ContentView` passes in its `editorSplit`, its divider (built from the available
height) and its panel slot (`panelContent` with the `BottomPanelHeightRule`
frame). This is a pure refactor: no layout change yet.

**Comments move with the code.** Every comment stating a dock-branch guarantee
moves with the code it describes and stays accurate. This covers the pin's
reasoning, the clip's reasoning, the coordinate space note, and the reference to
`panelColumnSpace` from the divider's drag.

**The harness.** Build a headless harness that does the following:

1. Hosts a body-shaped root in a real `NSWindow`: a `VStack` with the main area
   over a stub bottom bar, carrying the root's minimum frame.
2. Gives the window a `.titled` / `.resizable` / `.fullSizeContentView` style
   mask and calls `MainWindowChrome.apply(to:)`.
3. Uses a stub editor that is an `HSplitView`, matching the real
   `editorSplit`'s structure, with a top-row marker as each pane's first child.
4. Measures the marker's frame in window coordinates, through a preference or
   an `NSView` probe. It can measure with no panel (the split rendered
   directly) and with a panel (the split inside the extracted container).

**Reproduce, without committing the failure.** Locally, run the
open-versus-closed assertion (both frames have the same top y, and that top y is
at or below the title bar's bottom edge, `window.contentLayoutRect`) against the
unfixed container and observe it fail. Do not commit that assertion in this
task.

**Finding the cause.** Bisect the container in the harness: the
`GeometryReader` alone, then the frame pin, the coordinate space, the clip, and
the `HSplitView` child versus a plain `VStack` child. Do this until the single
construct that drops the top safe-area inset is identified. Write the observed
failure (the measured top y with the dock open and closed) and the cause with
its evidence in the suite's doc comment, as a plain statement of mechanism, not
a guess.

**What Task 1 commits as tests.** Only assertions that pass on the unfixed code:
for example, that the harness hosts both branches, that with no panel the
top-row marker sits at or below `contentLayoutRect`'s top, and that the bottom
bar's frame is measurable in both branches. The suite's doc comment states that
the open-versus-closed equality assertion arrives with the fix in Task 2.

**If the harness cannot reproduce the shift** (for example, the safe area is not
computed for an offscreen window), say so explicitly in the suite's doc comment.
Keep the passing harness assertions, and carry the diagnosis through Task 2 with
the live build instead.

- [x] extract the dock column container into its own file; `ContentView` uses it with identical behaviour and its guarantee comments move intact
- [x] build the headless harness and commit only assertions that pass on the unfixed container
- [x] run the open-versus-closed assertion locally (uncommitted), observe the failure, bisect to the single construct responsible, and record the failure and root cause in the suite's doc comment
- [x] run `swift test`, `swiftlint --strict` and the app-layer bundle; all gates green

### Task 2: Fix the root cause and commit the equality assertion

**Files:**
- Modify: `Sources/Pisaka/BottomDockColumn.swift`
- Modify: `Sources/Pisaka/ContentView.swift` (only if the cause sits on its side
  of the seam)
- Modify: `Tests/PisakaAppTests/BottomDockLayoutTests.swift`

Change the construct Task 1 identified so that the dock branch keeps the top
safe-area inset, exactly as the no-panel branch does. The fix must not contain:

- a constant offset;
- a padding equal to a title-bar height;
- a read of `safeAreaInsets` that is added back by hand;
- any change to the title bar's configuration (it stays transparent;
  `MainWindowChrome` stays its only configurer).

Re-check every guarantee listed in the Overview against the fixed code, and
rewrite any comment the fix makes inaccurate. In particular:

- the pin-before-clip reasoning;
- the coordinate space still being the pinned rect, which cannot move while the
  divider does;
- the `.topLeading` reason for narrow windows;
- the body-root minimum-size comment, which refers to the `GeometryReader`
  erasing minimums. If the fix removes or replaces the `GeometryReader`, that
  comment must say what now erases them, or that nothing does.

- [ ] apply the fix to the identified construct
- [ ] commit the open-versus-closed equality assertion (same top y; top y at or below the title bar's bottom edge) together with the fix, and update the suite's doc comment so it no longer says the assertion is pending
- [ ] extend the suite so that, with a panel open, the bottom bar's frame is unchanged and the panel slot ends at or above the bottom bar's top edge
- [ ] add a case at interface scale 1.8 (scaled stub rows) and a case with a vertical-tabs-shaped split (three panes), both asserting identical top y with the dock open and closed
- [ ] update every affected guarantee comment in `ContentView.swift` and the extracted file
- [ ] run `swift test`, `swiftlint --strict` and the app-layer bundle; all green

### Task 3: Pin the cause as a source rule (if expressible) and document it

**Files:**
- Modify: `Tests/PisakaCoreTests/BottomPanelSourceGatingTests.swift` (conditional)
- Modify: `docs/architecture/app-window.md`
- Modify: `CLAUDE.md`

**The source rule.** If the cause is a modifier or construct that must or must
not appear on the dock branch, add one rule to `BottomPanelSourceGatingTests`.
The rule has three parts:

- it reads the extracted file's comment- and literal-stripped text;
- it adds an inventory entry in the suite's own doc comment stating what it pins
  and why;
- if it changes the suite's rule count, the count is updated wherever it is
  pinned cross-file.

If the cause cannot be stated as a source rule, write that sentence in the
suite-free form in `app-window.md`, and treat the Task 1/2 app-layer test as the
pin.

`ChromeThemeSourceGatingTests` keeps its rule count. If the new file falls
within the chrome theme's gated file set, the set changes, and the suite's
set-equality inventory and `core-theme.md`'s list must name it. Otherwise the
theme suite is untouched.

**The documentation.**

- In `docs/architecture/app-window.md`, update the `ContentView.swift` entry:
  the dock branch now delegates to the extracted column, the root cause of the
  lost top row, and the rule or test that now prevents it.
- In the same doc, add a full entry for the new file: its contract, the
  guarantees it carries, and why it is a file of its own (testability of the
  real container).
- In `CLAUDE.md`, add the new file's name to the `app-window.md` index line, and
  nothing else. The file must stay under the 60,000-character limit
  `LintConfigurationTests` enforces.

- [ ] add the source-gating rule with its inventory entry, or record why none can express the cause
- [ ] update `app-window.md` (`ContentView.swift` entry plus the new file's entry) and the `CLAUDE.md` index line
- [ ] run `swift test` (including `LintConfigurationTests` and the gating suites) and `swiftlint --strict`; all green

### Task 4: Verify acceptance criteria

- [ ] `swift test` clean
- [ ] `swiftlint --strict` clean from the repository root
- [ ] app-layer bundle passes: `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' test`, with DerivedData under `~/Library/Developer/Xcode/DerivedData/pisaka-<purpose>`, never inside the repository
- [ ] macOS Release build and iOS build (`generic/platform=iOS`) succeed

### Task 5: Update documentation

- [ ] README.md: no user-facing change beyond the bug fix; leave it untouched unless it describes the dock's layout
- [ ] CLAUDE.md: only the index name added in Task 3

## Post-Completion (manual)

**Live check.** Run a Debug build, with DerivedData outside the repository. Pass
the settings as launch arguments (argument-domain `-key value`); never write
them to the user's defaults. Capture the main window with
`screencapture -l <windowID>` only.

Do this at two settings:

- interface scale 1.0 with horizontal tabs;
- interface scale 1.8 with vertical tabs.

At each setting, capture three states: dock closed, Terminal open, Log open. In
every capture, the sidebar's PROJECT header and the tab strip (or the tab column
header) must be fully visible below the title bar, and their y positions must be
identical across the three captures.

**Behaviour checks on the same build:**

- dragging the dock divider tracks the pointer one-to-one;
- the panel never paints over the bottom bar;
- closing the last terminal tab collapses the dock.
