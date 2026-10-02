# Three chrome surfaces that do not draw what their own documentation says

## Overview

A live check of the running macOS app found three surfaces that contradict their own documented contract. This plan fixes all three at their cause and pins each fix where the pipeline can see it.

1. The dock's tab row spreads its six tabs across the whole width. They should be packed at the leading edge.
2. The shared themed text field draws the native focus ring and does not draw its own 33-point box.
3. The commit dialog's unified diff stops a line's wash where the line's text ends.

Per the answer recorded in the progress log, the macOS deployment target goes up from 13 to 14. `.focusEffectDisabled()` then applies with no `#available` branch.

Causes found while exploring (master `d917dc6a`). The implementer must confirm each one in the harness before fixing it:

- **Dock tab row (`DockTabRow.swift`).** `tabButton(_:)` builds each label as a `VStack` of the title over a `Rectangle` that has only a height frame. The rectangle accepts any width it is offered, so every tab is width-flexible. The outer `HStack` then shares the row's spare width among the six tabs instead of giving it to the `Spacer` before the close action.
- **Shared field (`ChromeControls.swift`), two separate causes:**
  - *The ring.* The inner `TextField(...).textFieldStyle(.plain)` never suppresses its focus effect, so the platform draws its ring around the text line.
  - *The missing box.* `ChromeControlBox` puts its ground and border on `content().padding(...)`, which hugs the text line. Callers state the height outside the field (`.frame(height: SearchLayout.queryFieldHeight)` in Find in Files, `FilterBarLayout.controlHeight` in the Log strip, two in the LeetCode views). That outer frame adds transparent space around the box and never makes the box itself taller. So the box is one text line high, not 33 points, and its border is lost under the ring. `core-theme.md` already says the box "states no height so the container decides". The box simply does not fill what the container decides.
- **Unified diff (`CommitUnifiedDiffView.swift`).** The rows sit in a `LazyVStack` inside `ScrollView([.vertical, .horizontal])`. The horizontal axis proposes no width, so each row's `.frame(maxWidth: .infinity)` resolves to that row's own content width. The `.background` wash follows the row and ends after its last character.

## Context

- Files involved:
  - `project.yml`, `Package.swift`, `README.md`, `CLAUDE.md`, `.github/workflows/release.yml` (release notes say "macOS 13 or later")
  - Comment and doc sentences that call macOS 13 the deployment target: `Sources/Pisaka/LogFilterBar.swift`, `Tests/PisakaCoreTests/MarkdownPreviewAssetTests.swift`, `Sources/PisakaCore/MarkdownPreviewAsset.swift`, `docs/architecture/core-markdown-preview.md`, and any others a grep finds
  - `Sources/Pisaka/DockTabRow.swift`, `Sources/Pisaka/ChromeControls.swift`, `Sources/Pisaka/CommitUnifiedDiffView.swift`
  - `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`, `Tests/PisakaCoreTests/ReleaseMetadataTests.swift` (or whichever existing suite already reads `project.yml` and `Package.swift`)
  - New app-layer suites in `Tests/PisakaAppTests/`
  - `docs/architecture/app-window.md`, `core-theme.md`, `app-git-views.md`, `app-editor.md` (the find bar's sentence about the shared field)
- Related patterns:
  - `BottomDockLayoutTests` hosts the real view in a real `NSWindow` and measures it in window coordinates.
  - `ProjectTreeDraftField` already suppresses the native ring (`focusRingType = .none`).
  - `ChromeThemeSourceGatingTests` matches on comment- and literal-stripped text, and its rule count is pinned against the documented count (CLAUDE.md says "forty-four rules").
  - Callers of `ChromeThemedTextField` that state **no** height and must keep their current height after the fix:
    - the in-editor find bar (two fields)
    - the branch switcher's filter
    - the commit dialog's author Name/Email
    - the new pull request sheet's title
    - the merge sheet's subject
    - the database grid's cell editor
- Dependencies: none new.

## Development Approach

- **Testing approach**: Regular (code first, then tests). Each layout fix is confirmed in its headless harness before it is written: reproduce, then fix, then assert.
- Complete each task fully before moving to the next.
- Fix causes, not symptoms:
  - no hard-coded width standing in for a measured one;
  - no per-call-site workaround for the shared field's look: the ring and the box are fixed in the shared control, and a call site only passes the height it already states (Task 3);
  - no new colour roles, palette values or `ChromeGeometry` tokens.
- Accessibility stays as it is:
  - each dock tab keeps its label and its "Selected"/"Not selected" value;
  - the accent strip stays `accessibilityHidden`;
  - every themed field keeps its spoken name.
- No product or brand names in code, comments, docs or commit messages.
- **CRITICAL: every task MUST include new/updated tests**
- **CRITICAL: all tests must pass before starting next task**

## Implementation Steps

### Task 1: Raise the macOS deployment target to 14

**Files:**
- Modify: `project.yml`, `Package.swift`, `README.md`, `CLAUDE.md`, `.github/workflows/release.yml`
- Modify: the comment and doc sentences that state 13 as the deployment target or the supported floor (found by grep)
- Modify: the existing static suite that reads `project.yml` / `Package.swift`

- [x] Set `options.deploymentTarget.macOS` to `"14.0"` in `project.yml` and `.macOS(.v14)` in `Package.swift`. Keep iOS at 17.
- [x] Update every statement of the floor: README "Requires macOS 14+", CLAUDE.md's two mentions, the header comments of `project.yml` and `Package.swift`, and the release notes string in `release.yml`. If `ReleaseWorkflowTests` pins that string, update it too.
- [x] Reword the sentences that justify code by "the deployment target is macOS 13" so they stay true. A historical fact about macOS 13's own behaviour may stay when stated as such.
- [x] Deprecation warnings are accepted. Raising the floor to macOS 14 deprecates the single-parameter `onChange(of:perform:)`, used at about 57 call sites, and those sites will now emit deprecation warnings. Migrating them is out of scope for this ticket: do not touch them. The project does not treat warnings as errors, so the macOS Release and iOS builds must still succeed with these warnings present.
- [x] Add a static assertion that `project.yml`'s macOS deployment target and `Package.swift`'s macOS platform name the same version. Put it in the existing suite that already reads those files, so a restated floor cannot drift.
- [x] Run `xcodegen generate`. Run `swift test` (must pass), plus the macOS Release and iOS builds (must succeed).

### Task 2: The dock's tab row packs its tabs at the leading edge

**Files:**
- Modify: `Sources/Pisaka/DockTabRow.swift`
- Create: `Tests/PisakaAppTests/DockTabRowLayoutTests.swift`
- Modify: `docs/architecture/app-window.md`

- [x] Reproduce in a headless harness: host `DockTabRow` in a real window, about 1000 points wide, and confirm the tabs spread across it.
- [x] Make each tab exactly as wide as its padded title. The title is the only thing that sizes the tab. The accent strip takes its width from the title and sits below it, so it can never ask for width of its own. Both states keep the same height and title position. No weight change, no hard-coded widths.
- [x] Keep the gating rules on this file green:
  - rule twelve (sole caller);
  - rule thirteen (the strip hidden from accessibility, the selection spoken as a value);
  - rule sixteen (the bottom rule drawn behind the tabs).
- [x] Write the tests:
  - the six tabs are packed from the leading padding with `tabGap` between neighbours;
  - the close action sits at the trailing edge;
  - the space between the last tab and the close action takes up the rest of the row;
  - each selected strip is as wide as its tab;
  - the same at interface scale 1.8.

  Measure through what the view already exposes (each tab's accessibility element and frame, or a rendered bitmap) rather than adding a test-only seam to the production view. If a seam turns out to be unavoidable, state why in the suite header.
- [x] Update the `DockTabRow.swift` entry in `app-window.md` with the cause (a width-flexible strip made every tab greedy) and the rule that now prevents it (the title alone sizes a tab; the headless suite measures the packing). Leave no sentence describing the old behaviour.
- [x] Run `swift test` and the app-layer bundle (must pass).

### Task 3: The shared themed field draws its box and no native ring

**Why the box needs its height from the caller.** A first attempt made `ChromeControlBox` fill whatever height it is offered. That fixed the framed fields but grew the in-editor find bar from about 29 to 239 points, because a stack's spare room reaches the box exactly the way a caller's fixed frame does — as an offered height. A custom layout that fills only finite offers grew it the same way. So the box cannot tell "fill my frame" from "do not take the stack's spare room" on its own; the caller that wants a fixed height must say so to the box. The draft suite from that attempt is at `/tmp/pisaka-task3/ChromeThemedTextFieldLayoutTests.swift` and may be reused.

**Files:**
- Modify: `Sources/Pisaka/ChromeControls.swift`
- Modify: the call sites that frame a shared field's or box's height from outside — today `Sources/Pisaka/ProjectSearchView.swift` (query, replace and file-mask fields), `Sources/Pisaka/LogFilterBar.swift` (its fields, and its own `ChromeControlBox` use if that is framed the same way), `Sources/Pisaka/LeetCodeOpenProblemSheet.swift` and `Sources/Pisaka/LeetCodeBrowserView.swift`; confirm the list by grep before editing
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift` (new rule forty-five, with its header inventory entry)
- Create: `Tests/PisakaAppTests/ChromeThemedTextFieldLayoutTests.swift`
- Modify: `CLAUDE.md` (rule count), `docs/architecture/core-theme.md`, `docs/architecture/app-editor.md`, and the doc entries of the edited call-site files

- [x] The ring: apply `.focusEffectDisabled()` to the inner `TextField` inside `ChromeThemedTextField`. This fixes every caller at once.
- [x] The box: give `ChromeControlBox` an optional height parameter, threaded through `ChromeThemedTextField`'s initialisers. With a height, the box frames itself at exactly that height and draws its ground and border on that frame, the content vertically centred. With no height (the default), it behaves exactly as today — sized by its content, never greedy. The parameter takes the unscaled value and the box scales it, matching how the box already scales its padding.
- [x] Edit each call site that frames a shared field's or box's height from outside so it passes that height through the new parameter instead, removing the outer `.frame(height:)`. The value is the same named layout constant each site already uses (`SearchLayout.queryFieldHeight`, `FilterBarLayout.controlHeight`, `OpenProblemSheetLayout.inputHeight`, `LeetCodeBrowserLayout.queryFieldHeight`). Call sites that state no height are not touched.
- [x] Add rule forty-five to `ChromeThemeSourceGatingTests`: the shared field's declaration applies `focusEffectDisabled` to its `TextField`. That is the whole rule — no sweep of other files for bare `TextField(` constructions, which is outside this ticket's scope. Then bump the documented rule count from forty-four to forty-five everywhere it is restated: the suite header, `core-theme.md`'s canonical list and CLAUDE.md. The cross-file count check must stay green.
- [x] Write the headless tests:
  - a field given a height of 33 paints its `bgEditor` ground and its border across the full 33 points (render to a bitmap and sample above and below the text line; compare against a swatch rendered through the same pipeline, since the cached bitmap applies a colour-space conversion);
  - a field with no height, hosted the way the in-editor find bar sits — above a flexible view in a tall window — keeps its single-line height;
  - repeat both at interface scale 1.8.

  The native focus ring is drawn by the platform only on a key window with real first-responder focus, so the headless bundle cannot reliably see it. Say so in the suite header and in `core-theme.md`. That half is pinned by rule forty-five and the live check.
- [x] Update `core-theme.md`'s `ChromeControls.swift` entry:
  - the box takes an optional height from its caller and draws on exactly that height, and with none it is sized by its content;
  - the native focus effect is suppressed in the shared field;
  - the cause (an outer frame that could not reach the box, and an unsuppressed ring), why the height has to come from the caller (a stack's spare room and a fixed frame reach the box identically), and the rule and suite that now prevent it.

  Update the entries of the edited call-site files the same way, and the find bar's sentence in `app-editor.md` if it describes the old look.
- [x] Run `swift test` and the app-layer bundle (must pass).

### Task 4: The unified diff washes a changed line across the whole pane

**Files:**
- Modify: `Sources/Pisaka/CommitUnifiedDiffView.swift`
- Create: `Tests/PisakaAppTests/CommitUnifiedDiffWashTests.swift`
- Modify: `docs/architecture/app-git-views.md`, `docs/architecture/core-theme.md`

- [x] Reproduce in a harness: host `CommitUnifiedDiffView` in a real window about 600 points wide, with a short added line, a short removed line and one context line long enough to overflow the pane. Confirm the short line's wash stops after its text.
- [x] Give the scrolled content a width of the larger of two values: the pane's measured visible width, and the widest row's natural width. Then every row fills that width, so its `diffWashRole(for:)` wash spans it.
  - The visible width is measured from the scroll view's own geometry, never a constant.
  - The row's existing click target, checkbox, gutters, monospaced text, code-zone marker and `fixedSize` title behaviour all stay as they are.
- [x] Write the tests:
  - with no horizontal overflow, the short added and removed lines are washed to the pane's trailing edge;
  - with an overflowing line, after scrolling the hosted scroll view to its far right, the short lines are washed at the visible trailing edge as well;
  - context lines stay unwashed.

  Sample a rendered bitmap against the palette's resolved colours.
- [x] Update the `CommitUnifiedDiffView.swift` entry in `app-git-views.md` and the unified-diff paragraph in `core-theme.md`:
  - the cause (no width proposal on the horizontal axis, so a row's width is its own content width);
  - the rule now in place (the content is at least the pane wide, and every row fills it);
  - the suite that measures it.

  Leave no sentence describing the old behaviour.
- [x] Run `swift test` and the app-layer bundle (must pass).

### Task 5: Verify acceptance criteria

- [ ] `swift test` passes.
- [ ] `swiftlint --strict` from the repository root is clean.
- [ ] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' test` passes. DerivedData goes outside the repository.
- [ ] The macOS Release build (`-configuration Release`) and the iOS build (`generic/platform=iOS`) succeed. The `onChange` deprecation warnings from Task 1 are expected and accepted.
- [ ] Each of the three fixes has its headless suite, and the field also has its new gating rule. The rule count is consistent across the suite, `core-theme.md` and CLAUDE.md.

### Task 6: Update documentation

- [ ] CLAUDE.md: the platform floor is macOS 14 in both places, and the theme suite's rule count is forty-five. Re-check that `LintConfigurationTests`' size bound on CLAUDE.md still holds.
- [ ] `docs/architecture/` entries updated per Tasks 2–4. No sentence anywhere still describes the old tab spreading, the hugging box, the native ring or the text-length wash, or a caller framing a shared field's height from outside.
- [ ] README states macOS 14+.

## Post-Completion

Manual live check, run by hand and not automated:

- Use a Debug build with DerivedData outside the repository.
- Capture windows only with `screencapture -l <windowID>`.
- Pass settings as launch arguments and never write them to the user's defaults.
- Check at interface scale 1.0 and again at 1.8.

What to look for:

- The dock's six tabs sit together at the leading edge, with the close button at the trailing edge. Each accent strip is as wide as its tab.
- Find in Files: the query field, focused, shows the 33-point themed box with the `accent` border and no native ring; unfocused, it shows the `hairline` border. The file-mask and replace fields and the in-editor find bar look the same.
- The Log filter strip and the branch switcher's filter look right. The no-height callers (commit author, pull request sheets, the grid's cell editor) have not changed height.
- Commit dialog: a short added line and a short removed line are washed across the full pane, also after scrolling horizontally on a file whose longest line overflows.

Release consequences of the macOS 14 floor:

- The release notes string now says macOS 14.
- The release workflow only bumps the cask's version and `sha256` in the tap repository; it sets no macOS floor. If the tap's cask declares a `depends_on macos` floor, it must be raised by hand in that repository.
- Updates: the appcast generator (`generate_appcast`) reads `LSMinimumSystemVersion` from the archived app, so the appcast carries the new minimum. Installs on macOS 13 are simply not offered the update. This is worth stating in the release that ships it.
