# Chrome theme, part 1: colour roles, palette, injection, and three worked surfaces

## Overview

Give the macOS chrome a design system of its own: a closed set of semantic
colour roles and geometry tokens in `PisakaCore`, a two-valued palette in the
app layer, one SwiftUI environment value and one dynamic-`NSColor` bridge, a
repository-file gating suite pinning the rule, and three surfaces restyled end
to end — the horizontal tab strip (environment path), the line-number ruler
(AppKit bridge path) and the project tree rows (geometry + state path). Every
other surface is deliberately left alone for the follow-up sweep.

## Context

**Files involved**

Core (new):

- `Sources/PisakaCore/ChromeColorRole.swift` — the closed role enumeration.
- `Sources/PisakaCore/ChromeGeometry.swift` — the geometry tokens.
- `Sources/PisakaCore/ChromeAppearance.swift` — `dark`/`light` +
  `resolved(_:systemPrefersDark:)`.
- `Sources/PisakaCore/TreeRowState.swift` — the pure four-state (plus drop) row
  rule.

App (new):

- `Sources/Pisaka/ChromePalette.swift` — the hex table and the AppKit bridge.
- `Sources/Pisaka/ChromeThemeEnvironment.swift` — `\.chromeTheme`,
  `.chromeThemed(_:)`.
- `Sources/Pisaka/TabStripView.swift` — the horizontal strip, split out of
  `TabListView`.

App (modified):

- `Sources/Pisaka/ContentView.swift` — inject the theme, host `TabStripView`.
- `Sources/Pisaka/TabListView.swift` / `TabRowView.swift` — become
  vertical-only, otherwise untouched.
- `Sources/Pisaka/LineNumberRulerView.swift` — gutter, numbers, blame, severity
  markers, chevrons.
- `Sources/Pisaka/CodeEditorView.swift` — one line: the text view's background.
- `Sources/Pisaka/ProjectTreeView.swift` — rows, geometry, states; `color(for:)`
  deleted.
- `Sources/Pisaka/ProjectTreeDraftField.swift` — the drafted row, same
  treatment.
- The six other `.interfaceScaled(...)` roots — the second injection.

Tests:

- `Tests/PisakaCoreTests/ChromeThemeTests.swift` — roles, geometry, appearance,
  row rule.
- `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift` — the gating suite.
- `Tests/PisakaCoreTests/ZoomSourceGatingTests.swift` — one word removed (see
  Task 6).
- `Tests/PisakaAppTests/ChromePaletteTests.swift` — the palette's two value
  sets.

Docs: `docs/architecture/core-theme.md` (new), `app-window.md`,
`app-editor-overlays.md`, `CLAUDE.md`.

**Related patterns**

- `InterfaceMetrics` / `InterfaceScaleEnvironment.swift` — the exact injection
  shape to copy: a Core value type, an `EnvironmentKey` with a resting default,
  a `ViewModifier` taking the observed `SettingsStore`, applied at eight roots.
  It also already owns the chrome's type scale: `InterfaceTextStyle.body` is 13,
  `.callout` 12 and `.subheadline` 11 — exactly the three sizes the token table
  names — reached through `metrics.font(_:)`.
- `PlatformColor.dynamic(light:dark:alpha:)` in
  `Sources/Pisaka/Platform/PlatformColor.swift` — the dynamic-`NSColor`
  primitive already in the tree; the bridge is built on it, nothing new is
  invented.
- `MarkdownPreviewTheme.resolved(_:systemPrefersDark:)` and
  `LeetCodeStatementDocument.Theme.resolved(_:systemPrefersDark:)` — the two
  existing `ThemePreference` resolutions; the new one is the third, same
  signature.
- `ZoomSourceGatingTests` — the gating suite's mould, including
  `LSPSourceGatingTests.strippingCommentsAndStringLiterals(_:)` /
  `containsToken(_:in:)`.
- `FileIconColor` / `ThemePreference` — the "semantic token in Core, colour in
  the view layer" precedent the role enumeration follows.

**Dependencies** — none; nothing is added to `project.yml`.

**Decisions already settled**

- Tree selection is *derived, not interactive*: a row is selected when it is the
  file of the currently active editor tab (folders never selected); "with
  keyboard focus" means the window is key. No click-to-select is introduced.
- The horizontal strip becomes its own view rather than a branch inside
  `TabRowView`, because the vertical column is explicitly out of scope and a
  gated file may not keep `Color.accentColor.opacity(0.2)` for one of its two
  branches.
- `ProjectTreeDraftField.swift` joins the gated set: an inline draft *is* a tree
  row and must read identically to the row it replaces.
- **Chrome text sizes are not a new table.** `ChromeGeometry` carries no font
  constant at all; chrome text is drawn with `metrics.font(.body)` (13),
  `metrics.font(.callout)` (12) for tab labels and `metrics.font(.subheadline)`
  (11) for captions, which is where those three numbers already live.

## Development Approach

- **Testing approach**: Regular (code first, then tests) for the app-layer
  surfaces; TDD for the three pure Core rules (roles, geometry, row state),
  which are trivially testable before any view exists.
- Complete each task fully before moving to the next.
- **CRITICAL: every task MUST include new/updated tests.**
- **CRITICAL: all tests must pass before starting the next task.**
- Core gate: `swift test`. App gate: `xcodebuild -project Pisaka.xcodeproj
  -scheme Pisaka -destination 'platform=macOS' test`. Style gate:
  `swiftlint --strict` from the repository root.
- Builds and test runs write nothing into the repository tree: pass
  `-derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-chrome-theme`
  when a derived-data root is needed.
- No product or brand names anywhere — code, comments, docs or commit messages.

## Implementation Steps

### Task 1: Core — roles, geometry, appearance, and the tree-row state rule

**Files:**

- Create: `Sources/PisakaCore/ChromeColorRole.swift`
- Create: `Sources/PisakaCore/ChromeGeometry.swift`
- Create: `Sources/PisakaCore/ChromeAppearance.swift`
- Create: `Sources/PisakaCore/TreeRowState.swift`
- Create: `Tests/PisakaCoreTests/ChromeThemeTests.swift`

- [x] `ChromeColorRole`: a `public enum`, `String`-raw-valued, `CaseIterable`,
      `Hashable`, `Sendable`, one case per row of the token table — all 22,
      including the ones no surface in this part uses (`bgPopover`,
      `conflictBackground`, `diffAddedBackground`, `diffRemovedBackground`,
      `selectionInactive`). Foundation-only: no hex, no platform colour type,
      the `FileIconColor` precedent. Document that the set is closed and that
      the sweep adds views, never roles.
- [x] `ChromeGeometry`: a `public enum` namespace of `static let` `Double`s for
      every **geometry** token in the table (`rowHeight`, `rowPaddingX`,
      `treeIndentStep`, `cornerRadiusMax`, `hairlineWidth`, `tabStripHeight`,
      `verticalTabRowHeight`, `dockTabRowHeight`, `bottomBarHeight`,
      `breadcrumbHeight`, `bottomBarToggleSide`, `bottomBarToggleRadius`,
      `accentIndicator`) and **no font size**: the table's `font-ui-size` row is
      already `InterfaceTextStyle.body` (13), `.callout` (12) and
      `.subheadline` (11), so chrome text is drawn with
      `metrics.font(.body / .callout / .subheadline)` and no second table of
      those numbers is created. Document that every geometry token is scaled
      through `InterfaceMetrics` at its use site, that no view multiplies a
      number itself, and — in one sentence — where the type scale lives instead.
- [x] `ChromeAppearance`: `public enum { case dark, light }` plus
      `resolved(_ preference: ThemePreference, systemPrefersDark: Bool)` — the
      third instance of the existing signature, cross-referenced in its doc
      comment to the two that already exist.
- [x] `TreeRowState`: `public enum { plain, hover, selectedFocused,
      selectedUnfocused, dropTarget }` with a total pure rule
      `state(isSelected:isWindowKey:isHovering:isDropTarget:)`. State the
      precedence in the doc comment and pin it in the test: drop target wins
      over everything (it answers "will this drop land here?"), then selection
      (focused vs. unfocused by window key), then hover, then plain.
- [x] Tests: every role has a distinct raw value, asserted by **set equality**
      against a literal list of role names so a role added or removed fails;
      every geometry token equals its table value, and the geometry namespace's
      declared set is likewise pinned by set equality so a stray font constant
      would fail; the three chrome text sizes are pinned where they actually
      live — `InterfaceTextStyle.body/.callout/.subheadline` equal 13/12/11;
      `resolved` is total over the three preferences × two system answers;
      `TreeRowState` exhaustive over all sixteen input combinations, including
      the precedence cases (selected + hovering, drop target + selected).
- [x] run `swift test` — must pass before Task 2

### Task 2: App — the palette, the two paths, and the injection

**Files:**

- Create: `Sources/Pisaka/ChromePalette.swift`
- Create: `Sources/Pisaka/ChromeThemeEnvironment.swift`
- Create: `Tests/PisakaAppTests/ChromePaletteTests.swift`
- Modify: `Sources/Pisaka/ContentView.swift`, `PisakaApp.swift`,
  `DiffWindowContent.swift`, `SourceViewerContent.swift`,
  `ProjectSearchView.swift`, `MergeView.swift`, `LeetCodeBrowserView.swift`,
  `LocalHistoryView.swift`

- [x] `ChromePalette`: an **exhaustive `switch role`** (no `default`) returning
      the `(dark, light)` pair as `0xRRGGBB` plus an alpha — so a role added
      without a pair fails to *compile*, and the test below catches a wrong
      value. This is the one file allowed to spell hex.
- [x] The AppKit bridge: `ChromePalette.nsColor(_ role:) -> NSColor`, built on
      the existing `PlatformColor.dynamic(light:dark:alpha:)`, so AppKit
      resolves per appearance itself. Document explicitly that **no AppKit view
      caches a resolved colour and none observes appearance changes by hand** —
      `.preferredColorScheme` sets the window's `NSAppearance`, which every
      `NSView` inside it inherits, which is why the existing `SyntaxTheme`
      colours already follow the Theme preference.
- [x] The SwiftUI path: `ChromeTheme`, an `Equatable` value carrying the
      resolved `ChromeAppearance` and answering `color(_ role:) -> Color` from
      the palette's concrete side. Carrying the *resolved* appearance rather
      than a dynamic colour is what makes a preference change invalidate the
      whole subtree, so the recolour is live by construction.
- [x] `ChromeThemeEnvironment.swift`: the `EnvironmentKey` (defaulting to the
      dark theme, the primary appearance), `\.chromeTheme`, and a
      `.chromeThemed(_ settings: SettingsStore)` modifier that observes the
      store and reads `@Environment(\.colorScheme)` to answer
      `systemPrefersDark` for `ThemePreference.system`. Document the three rules
      the sweep obeys, in `InterfaceScaleEnvironment.swift`'s voice: nothing
      resolves a role itself, the modifier is applied only at roots, and the
      default is the resting one.
- [x] Apply `.chromeThemed(settings)` at **exactly the eight roots** that
      already apply `.interfaceScaled(settings)`, immediately beside it, and
      below the `.preferredColorScheme` site where one exists.
- [x] Tests (`Tests/PisakaAppTests/ChromePaletteTests.swift`,
      `@testable import Pisaka`): for every `ChromeColorRole.allCases`, assert
      the dark and the light `NSColor` resolve to exactly the sRGB components
      and alpha of the table's hex values; assert the dynamic `NSColor`
      resolves to the dark variant under `.darkAqua` and the light one under
      `.aqua`; assert `ChromeTheme(.dark)` and `ChromeTheme(.light)` differ for
      every role that has two different values.
- [x] run `swift test` and the app-layer bundle — both must pass before Task 3

### Task 3: Surface 1 — the horizontal tab strip (the environment path)

**Files:**

- Create: `Sources/Pisaka/TabStripView.swift`
- Modify: `Sources/Pisaka/TabListView.swift`, `Sources/Pisaka/TabRowView.swift`,
  `Sources/Pisaka/ContentView.swift`

- [x] Reduce `TabListView`/`TabRowView` to the **vertical column only**: drop
      the `orientation` parameter and the `.horizontal` branch. Their colours
      and metrics are otherwise untouched — the vertical column is the sweep's.
- [x] `TabStripView`: the strip's whole chrome, owned here rather than in
      `ContentView` — `ChromeGeometry.tabStripHeight` on `bgPanel`, a bottom
      hairline (`hairline` at `hairlineWidth`), a right hairline between tabs,
      every value through `metrics.scaled(...)`, labels through
      `metrics.font(.callout)`.
- [x] The tab cell: active tab filled `bgEditor` with an `accentIndicator`-tall
      `accent` underline so it merges into the editor below; active label
      `textPrimary`, inactive `textSecondary`; a modified tab shows a 7 pt
      `textSecondary` dot in place of the close mark; the close mark is visible
      on the active tab **and** on hover (today it is hover-only); the file icon
      is drawn monochrome in `textSecondary` through `FileIcon(for:)`'s symbol
      with its colour ignored.
- [x] `ContentView`'s `.horizontal` branch hosts `TabStripView` with no
      `.frame(height:)` and no `Divider()` of its own — the strip states its own
      height and draws its own hairline. The `.vertical` branch is unchanged.
- [x] Tests: the strip is SwiftUI glue and stays untested by convention; the
      gating suite in Task 6 is what covers it. Re-run the existing suites to
      confirm the `TabListView` signature change broke nothing.
- [x] run `swift test` and the app-layer bundle — must pass before Task 4

### Task 4: Surface 2 — the line-number ruler (the AppKit bridge path)

**Files:**

- Modify: `Sources/Pisaka/LineNumberRulerView.swift`,
  `Sources/Pisaka/CodeEditorView.swift`

- [x] Paint the gutter: fill the drawn rect with
      `ChromePalette.nsColor(.bgEditor)` at the top of
      `drawHashMarksAndLabels(in:)` and stroke a right hairline in `hairline` at
      `hairlineWidth`. Today the ruler paints no background at all; this is what
      makes the gutter and the text agree.
- [x] Line numbers and the blame column: `.foregroundColor` becomes
      `nsColor(.textSecondary)` in place of `NSColor.secondaryLabelColor`.
- [x] Severity markers: the three status roles in place of
      `SyntaxTheme.shared.nsDiagnosticColor(for:)`. `SyntaxTheme` keeps its own
      diagnostic colours for its other consumers — the underline and the hover
      popover are the sweep's, and changing them here would restyle a surface
      this ticket excludes. Note the deliberate duplication in the doc entry.
- [x] Fold chevrons: both spellings become `textSecondary` — the column keeps
      today's geometry and today's open/folded distinction is carried by the
      symbol, not by two greys.
- [x] `CodeEditorView`: set the text view's (and its clip/scroll view's)
      `backgroundColor` to `nsColor(.bgEditor)` so ruler and text agree. This is
      the one line this file gains; the syntax token colours, the
      `current-line`/`bracket-match` painting and the minimap are untouched, and
      `CodeEditorView.swift` is **not** added to the gated set.
- [x] Tests: extend the app-layer gutter suite
      (`Tests/PisakaAppTests/GutterFoldTests.swift`, via `EditorLayoutHarness`)
      with a case asserting the ruler resolves its four colours from the palette
      rather than from AppKit's semantic set — that the number attributes'
      foreground equals `ChromePalette.nsColor(.textSecondary)` and that each
      severity resolves to its status role — under both `.aqua` and `.darkAqua`.
- [x] run `swift test` and the app-layer bundle — must pass before Task 5

### Task 5: Surface 3 — the project tree rows (the geometry and state path)

**Files:**

- Modify: `Sources/Pisaka/ProjectTreeView.swift`,
  `Sources/Pisaka/ProjectTreeDraftField.swift`

- [x] Geometry: `TreeRowLayout`'s numbers move onto `ChromeGeometry` — rows take
      a fixed `metrics.scaled(ChromeGeometry.rowHeight)` frame instead of the
      present vertical padding, `rowPaddingX` replaces `horizontalPadding`, and
      the three child-indent sites take `treeIndentStep`. The chevron column's
      width, spacing and `chevronGutter` alignment rule are preserved exactly —
      that rule is load-bearing (it is what keeps a child from out-denting its
      parent) and is not what this ticket is changing.
- [x] Selection, derived: `ProjectTreeView` reads `model.selectedFile?.url` (it
      already observes the workspace) and threads it to `DirectoryNodeView` and
      `FileRowView`; a folder row passes `isSelected: false` unconditionally.
      Compare canonically, using the app layer's existing inline spelling
      (`standardizedFileURL.resolvingSymlinksInPath()`), as `CanonicalPath` is
      `internal` to Core.
- [x] Focus, derived: `@Environment(\.controlActiveState)` on the row — `.key`
      is focused, anything else is not.
- [x] Painting: each row asks `TreeRowState.state(...)` and maps the answer to
      `hoverTint` / `accentTintStrong` / `selectionInactive` / `Color.clear`;
      the drop highlight keeps its own stronger accent tint as its own
      role-based value. Chevrons, folder icons and file icons are drawn
      monochrome in `textSecondary`, the empty-state text in `textSecondary`.
- [x] Delete the app layer's `color(for: FileIconColor) -> Color` entirely: its
      only two readers are this file and `ProjectTreeDraftField.swift`, and both
      stop painting the colour. `FileIcon`'s Core table is untouched — iOS still
      reads it, and `CompletionPanel` keeps its own private mapping.
- [x] `ProjectTreeDraftField.swift`: the drafted row takes the same geometry,
      the same monochrome icon, `statusRed` for the validation state and
      `textPrimary` for the field's text (the `NSTextField` site goes through
      the `NSColor` bridge, exercising it a second time).
- [x] Tests: the row-state rule is already pinned in Task 1's Core suite; add
      the cases the views actually ask for — a hovered selected row in a key
      window, the same row once the window resigns key, a drop target over a
      selected row — so the mapping the views rely on is stated in
      `swift test`.
- [x] run `swift test` and the app-layer bundle — must pass before Task 6

### Task 6: The source-gating suite

**Files:**

- Create: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`
- Modify: `Tests/PisakaCoreTests/ZoomSourceGatingTests.swift`

- [x] In `ZoomSourceGatingTests`' mould, reading `Sources/` through `#filePath`
      with Foundation only and matching against
      `LSPSourceGatingTests.strippingCommentsAndStringLiterals(_:)` output — the
      gated files document their own rules at length, so a raw `contains` would
      pass while the code it names was deleted.
- [x] The gated set, asserted by **set equality** in both directions:
      `ChromePalette.swift`, `ChromeThemeEnvironment.swift`,
      `TabStripView.swift`, `LineNumberRulerView.swift`, `ProjectTreeView.swift`,
      `ProjectTreeDraftField.swift`. A file in the set that no longer exists
      fails, so the sweep adds a file deliberately when it restyles it.
- [x] Rule one — no system semantic colour: a closed forbidden-token list
      covering AppKit's (`labelColor`, `secondaryLabelColor`,
      `tertiaryLabelColor`, `textBackgroundColor`, `controlBackgroundColor`,
      `windowBackgroundColor`, `separatorColor`,
      `selectedContentBackgroundColor`,
      `systemRed`/`systemGreen`/`systemYellow`/`systemBlue`/`systemGray`) and
      SwiftUI's (`accentColor`, `primary`, `secondary`, `tertiary`, and the
      named hues). `clear` is deliberately allowed and documented as such: it is
      the absence of a colour, not a role.
- [x] Rule two — no hex literal: a `0x[0-9A-Fa-f]{6}` match over the stripped
      text. `ChromePalette.swift` is the one exemption, checked by the palette
      test in Task 2 instead, and the suite asserts it is the *only* gated file
      that spells hex, so the exemption cannot become a hole.
- [x] Rule three — the three named exemptions, each with its reason in the doc
      comment: `SyntaxTheme.swift` (a token-kind colour table is the code zone,
      not chrome), `TerminalTheme.swift` (an ANSI-16 palette is a protocol's
      vocabulary, not a design system's) and `FileIcon.swift` (a Core semantic
      token iOS still paints). The suite asserts these three are *not* in the
      gated set, so a later sweep cannot quietly add them.
- [x] Rule four — the theme is injected at the same roots as the interface
      scale: drop `private` from `ZoomSourceGatingTests.interfaceScaledRoots`
      (its only change, one word, with a one-line note in its doc comment saying
      the chrome-theme suite reads it), collect `.chromeThemed(` by file and
      assert set equality against **that one declared set**. The root list is
      not duplicated in the new suite, so a root that gains one modifier and
      forgets the other fails in exactly one place.
- [x] Rule five — no view constructs a theme inline: `ChromeTheme(` appears only
      in `ChromeThemeEnvironment.swift` and `ChromePalette.swift`.
- [x] Self-check, in the suite's own idiom: each gated file must actually *name*
      a role, so a rename cannot empty the checks into a vacuous pass.
- [x] run `swift test` — must pass before Task 7

### Task 7: Documentation

**Files:**

- Create: `docs/architecture/core-theme.md`
- Modify: `docs/architecture/app-window.md`,
  `docs/architecture/app-editor-overlays.md`, `CLAUDE.md`

- [x] `core-theme.md`: the role enumeration and why it is closed; the geometry
      tokens and the `InterfaceMetrics` scaling rule — including that
      `ChromeGeometry` carries **no font size**, the three chrome text sizes
      being `InterfaceTextStyle.body`/`.callout`/`.subheadline` (13/12/11) read
      through `metrics.font(_:)`, so no second table of those numbers exists;
      the palette's two value sets and the exhaustive switch that makes a
      missing pair a compile error; the SwiftUI environment path and its roots;
      the AppKit bridge and why no AppKit view caches or observes; the tree-row
      state rule with its precedence and the derived definitions of "selected"
      and "focused"; the monochrome-icon decision; the gating suite's five rules
      and three exemptions, noting that rule four reads
      `ZoomSourceGatingTests.interfaceScaledRoots` rather than restating it.
- [x] `core-theme.md` — the **sweep guide**: how a view is moved onto the roles
      (find its colour sites, map each to a role, move its numbers onto
      `ChromeGeometry`, draw its text with `metrics.font(_:)`, add the file to
      the gated set, run the suite), and what to do when a surface seems to need
      a role that does not exist (it does not — the set is closed; raise it as a
      design question instead).
- [x] `app-window.md`: updated entries for `TabListView`/`TabRowView` (now the
      vertical column alone), the new `TabStripView`, and `ProjectTreeView` /
      `ProjectTreeDraftField` (row geometry, the four states, monochrome icons,
      the deleted `color(for:)`).
- [x] `app-editor-overlays.md`: updated `LineNumberRulerView` entry — the gutter
      background and right hairline, the four colours through the bridge, and
      the deliberate duplication of the severity colours away from
      `SyntaxTheme`.
- [x] `CLAUDE.md`: the index lines for the four new Core files, the three new
      app files and `core-theme.md`, plus **one** cross-cutting-invariant
      paragraph — colour reaches a gated macOS chrome view only as a role, the
      palette has exactly two value sets and no third, and
      `ChromeThemeSourceGatingTests` pins which files obey it and which three
      are exempt. Keep the file well under its size target; no per-file essays.
- [x] run `swift test` and the app-layer bundle — must pass before Task 8

### Task 8: Verify acceptance criteria

- [x] `swift test` — green
- [x] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination
      'platform=macOS' -derivedDataPath
      ~/Library/Developer/Xcode/DerivedData/pisaka-chrome-theme test` — green
- [x] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination
      'generic/platform=iOS' -derivedDataPath
      ~/Library/Developer/Xcode/DerivedData/pisaka-chrome-theme build` — the iOS
      target still builds
- [x] `swiftlint --strict` from the repository root — clean
- [x] Confirm by inspection that the gating suite fails as designed: temporarily
      add a `.secondary` and a hex literal to a gated file and to the gated set,
      confirm three distinct failures, then revert
- [x] Confirm the palette test fails when a role's value is altered, then revert
- [x] Confirm nothing was written into the repository tree (`git status` clean
      but for the intended changes)

## Post-Completion (manual, by the user)

- Launch in dark and in light and confirm the tab strip, the ruler and the tree
  rows match the specification, and that every other surface is unchanged.
- Switch Appearance in Settings in both directions and confirm the three
  surfaces recolour live, with no relaunch.
- Zoom the interface and confirm the three surfaces' geometry scales with it.
