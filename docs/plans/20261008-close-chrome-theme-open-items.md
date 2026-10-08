# Close the chrome theme's remaining open items (lanes, bracketMatch, code-zone checkbox, platform leftovers, Make recipe injection)

## Overview

This plan settles every question still open in parts five (b) through five (h) of `core-theme.md`, plus the Make combined-layer highlighting limit, in five independent parts. Each part is its own commit series:

- **Part A** chooses the eight commit-graph lane hues against the Log's actual ground.
- **Part B** makes the bracket-pair overlay draw `bracketMatch`, so the role is used.
- **Part C** gives the unified diff's per-line checkbox a code-zone drawing of the shared checkbox shape.
- **Part D** replaces all four platform splits with one shared split that draws a hairline. It also gives the focusable surfaces the design's focus border, moves Acknowledgements to the gated list rule, and closes the iOS `.label` question.
- **Part E** makes each Make `shell_text` node include its line terminator. Bash then stops joining the end of one recipe line to the start of the next.

## Context

- **Files involved:**
  - Part A: `Sources/Pisaka/CommitGraphPalette.swift`, `Tests/PisakaAppTests/CommitGraphPaletteTests.swift`, and a new app-bundle test helper `Tests/PisakaAppTests/ContrastArithmetic.swift`
  - Part B: `Sources/Pisaka/BracketOverlayLayoutManager.swift`, `Sources/Pisaka/SyntaxTheme.swift`, `Sources/PisakaCore/ChromeColorRole.swift`
  - Part C: `Sources/Pisaka/ChromeControls.swift`, `Sources/Pisaka/CommitUnifiedDiffView.swift`, and a new `Sources/PisakaCore/CodeZoneCheckboxRule.swift`
  - Part D: `Sources/Pisaka/ContentView.swift`, `Sources/Pisaka/LocalHistoryView.swift`, `Sources/Pisaka/AcknowledgementsView.swift`, `Sources/Pisaka/DatabaseViewerView.swift`, `Sources/Pisaka/LeetCodeBrowserView.swift`, `Sources/Pisaka/WelcomeView.swift`, `Sources/Pisaka/Platform/LicenseTextView.swift`, and two new files: `Sources/Pisaka/ChromeSplitView.swift` and `Sources/PisakaCore/SplitPaneRule.swift`
  - Part E: `Vendor/TreeSitterMake/{grammar.js,src/parser.c,src/grammar.json,src/node-types.json,VENDORED.md}`, `Tests/PisakaAppTests/InjectedHighlightPredicateTests.swift` and its fixtures
  - Gates and docs: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`, `docs/architecture/{core-theme,app-editor-overlays,app-git-views,app-window}.md`, `CLAUDE.md`
- **Related patterns:**
  - Hand-drawn splits already exist in four places: the dock divider in `ContentView.panelDivider`, the Markdown preview divider, the Log's list/detail divide and the database sidebar divide. Each draws a hairline inside a clear drag strip, and each pushes the resize cursor and pops it in `onDisappear` (rule twenty-two). Core already holds their size rules: `BottomPanelHeightRule`, `MarkdownPreviewWidthRule` and `TabColumnWidthRule`.
  - Contrast arithmetic is computed by the test's own code, the way `TerminalThemeTests` does it. The pin never relies on a converter it is checking. Shared test helpers live beside `HostedRender.swift` and `EditorLayoutHarness.swift` in the app bundle.
  - Layout suites measure through `HostedRender`, as `CommitUnifiedDiffWashTests` does.
  - The bracket-overlay app tests use `EditorLayoutHarness`, as `CurrentLineHighlightTests` does.
  - The gated-control focus pattern is `ChromeControlBox`'s focus border: `accent` at `fieldFocusedBorderWidth`.
- **Dependencies:**
  - Nothing new is linked.
  - Part E needs the tree-sitter CLI only to regenerate the parser. It runs through `npx tree-sitter-cli@<pinned version>`, and that version is recorded in `VENDORED.md`. Nothing is added to `project.yml` or `Package.swift`.
- **Decision already taken:** the user chose to replace all four platform splits with one shared hand-drawn split.

## Development Approach

- **Testing approach:** Regular (code first, then tests). Part E starts with a reproduction before any change.
- Complete each task fully before moving to the next. Each part (A–E) is its own commit series.
- Before touching a file, read its entry in `core-theme.md`, `app-editor-overlays.md`, `app-git-views.md` or `app-window.md`, and update that entry in the same commit.
- Core holds the pure decisions that have app readers: the code-zone checkbox sizing and the split clamp. The contrast arithmetic is test-only, so it lives in the app test bundle. The app layer draws.
- Gating suites change together with the code they gate, never as a follow-up. A restyled file joins `gatedFiles` in the same commit.
- No product names appear in comments, docs or commit messages.
- **CRITICAL: every task MUST include new or updated tests.**
- **CRITICAL: all tests must pass before the next task starts.** That means `swift test`, plus the app bundle (`xcodebuild … -destination 'platform=macOS' test`) whenever app files changed, plus `swiftlint --strict`.

## Measured values (stated here as the ticket requires)

### Part A — lane hues

**Ground:** the lanes sit on `bgPanel`, which the dock sets as its own ground (`ContentView.swift:644`, "The dock's own ground"). Neither `CommitGraphView` nor an unselected `CommitRow` draws anything beneath the lanes. `bgPanel` is `#ECECEF` in light and `#2B2D30` in dark. Each contrast value below is the WCAG ratio against `bgPanel`. The number in brackets is the ratio against a selected row, for information only. A selected row is `accentTintStrong` over `bgPanel`: `#C6D3EC` in light, `#324059` in dark. The 3:1 floor is pinned against `bgPanel` only.

| Lane | Light | Light contrast | Dark | Dark contrast |
|---|---|---|---|---|
| blue | `#2F64C8` | 4.71 (3.69) | `#6AA2FF` | 5.41 (4.09) |
| green | `#2E7D32` | 4.35 (3.40) | `#5FC46A` | 6.31 (4.76) |
| orange | `#B8560A` | 4.07 (3.19) | `#F0954A` | 5.99 (4.52) |
| purple | `#8A3FC0` | 5.01 (3.92) | `#C08CF5` | 5.47 (4.13) |
| red | `#C0392B` | 4.61 (3.61) | `#F2706A` | 4.80 (3.63) |
| teal | `#00798A` | 4.34 (3.40) | `#3FC4D4` | 6.61 (5.00) |
| pink | `#C2185B` | 4.98 (3.90) | `#F27AAE` | 5.37 (4.06) |
| yellow | `#8A6D00` | 4.17 (3.26) | `#E3C449` | 8.06 (6.09) |

- Every entry clears 3:1, so there are no exceptions.
- **Hue families**, in table order (blue, green, orange, purple, red, teal, pink, yellow):
  - light: 219, 123, 26, 275, 6, 187, 336, 47°;
  - dark: 217, 127, 27, 270, 3, 186, 334, 48°.
- **Pairwise distinctness:** pinned as a minimum hue separation of 20° per appearance. The closest pair is orange–red in light (20.6°) and orange–yellow in dark (20.8°).
- **No chrome meaning:** none of the sixteen values equals `statusRed`, `statusGreen`, `statusYellow` or `accent` in either appearance.

### Part B — rainbow brackets on the pair background

This table checks that the rainbow depth colours and the unmatched-bracket red stay readable over `bracketMatch` (light `#DBE6F5`, dark `#3D4A5C`):

| Appearance | Five depth colours | Unmatched red |
|---|---|---|
| Light | 3.97, 5.56, 4.14, 3.92, 4.28 | 4.61 |
| Dark | 6.41, 4.53, 4.10, 5.16, 5.86 | 3.23 |

All six colours stay at or above 3:1 in both appearances.

## Implementation Steps

### Task 1: Part A — shared contrast arithmetic for the app test bundle

**Files:**

- Create: `Tests/PisakaAppTests/ContrastArithmetic.swift` (a test-support file beside `HostedRender.swift` and `EditorLayoutHarness.swift`)
- Create: `Tests/PisakaAppTests/ContrastArithmeticTests.swift`
- [x] Write the helper's own arithmetic over 8-bit sRGB `0xRRGGBB` values:
  - WCAG relative luminance, using the standard linearisation;
  - the contrast ratio between two colours;
  - the hue angle in degrees;
  - the circular separation between two hues.
- [x] State in the header why this is test arithmetic and not Core code: no production code reads it, and the pin must not rely on a converter it is checking.
- [x] Leave `TerminalThemeTests` as it is. Its arithmetic works on 16-bit components, and switching it gains nothing.
- [x] Test the helper:
  - black on white is 21:1, and the ratio is symmetric;
  - a known mid-grey gives its known value;
  - pure red, green and blue have hues 0°, 120° and 240°;
  - the circular separation wraps, so 350° and 10° are 20° apart.
- [x] Run the app bundle and `swiftlint --strict`; both must pass. (swiftlint clean; the new suite passes. Eight scale-1.8 layout assertions in BottomBar/ChromePopover/CommitDialog layout suites fail identically on the untouched tree on this host, so they are pre-existing and environmental.)

### Task 2: Part A — choose the lane hues and pin them

**Files:**

- Modify: `Sources/Pisaka/CommitGraphPalette.swift`
- Modify: `Tests/PisakaAppTests/CommitGraphPaletteTests.swift`
- Modify: `docs/architecture/core-theme.md`, plus `docs/architecture/app-git-views.md` if it restates the values
- [x] Replace the eight entries with the values in the table above. Keep the case names and their order.
- [x] Rewrite the file's comment so it states:
  - the ground: `bgPanel` and its two values;
  - the measured contrast values;
  - that the palette stays the fourth stated exemption: lanes are identity tokens and get no `ChromeColorRole`.
- [x] Update the test's `expected` table to the new values.
- [x] Add tests that use `ContrastArithmetic` on the table's values:
  - every entry is at least 3:1 against `bgPanel`. The ground comes from `ChromePalette`'s resolved value for each appearance, not from a literal;
  - the minimum pairwise hue separation is at least 20° in each appearance;
  - no entry equals the resolved `statusRed`, `statusGreen`, `statusYellow` or `accent` in either appearance;
  - the existing exact pairwise-distinct assertion stays.
- [x] Update the fourth-exemption section of `core-theme.md` with the values, the ground and the measurements. Remove the lane question from *What is still waiting*.
- [x] Run `swift test`, the app bundle and `swiftlint --strict`; all must pass. (swift test and swiftlint clean; CommitGraphPaletteTests passes in full. The same eight scale-1.8 layout assertions noted in Task 1 still fail, unchanged and environmental.)

### Task 3: Part B — the pair overlay draws `bracketMatch`

**Files:**

- Modify: `Sources/Pisaka/BracketOverlayLayoutManager.swift`
- Modify: `Sources/Pisaka/SyntaxTheme.swift`
- Modify: `Sources/PisakaCore/ChromeColorRole.swift`
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`
- Create: `Tests/PisakaAppTests/BracketPairBackgroundTests.swift`
- [x] In `paintBackgrounds(clippedTo:clampingTo:)`, paint the pair with `ChromePalette.nsColor(.bracketMatch)`. This is the dynamic colour: it is read at paint time and never stored.
- [x] Delete `SyntaxTheme`'s `pairBackground`, `matchedPairBackground` and `nsMatchedPairBackground`.
  - The rainbow palette, the unmatched red and the indent tint stay in `SyntaxTheme`, because they are code colouring.
  - Move the reasoning "opaque and neutral, so the rainbow stays readable on it" to the role's doc comment.
- [x] Rule three (the exempt and gated sets stay disjoint) still holds, and the gated-file count does not change in this part:
  - `BracketOverlayLayoutManager.swift` is already gated and stays gated.
  - `SyntaxTheme.swift` stays exempt and ungated.
  - `BracketHighlightController.swift` stays ungated. It draws nothing itself; it only passes `SyntaxTheme`'s rainbow colours, which are code colouring, to the layout manager.
- [x] Amend rule twenty-nine:
  - pin, by set equality, the files allowed to spell `bracketMatch`: {`ChromePalette.swift`, `BracketOverlayLayoutManager.swift`};
  - remove "unspent" from its doc comment;
  - add a clause that `SyntaxTheme.swift` spells no pair background (`pairBackground` or `matchedPair`), so the private value cannot return.
- [x] Update `ChromeColorRole`'s type doc comment: no role is unspent any more, and the table and the call sites agree.
- [x] Add app-bundle tests through `EditorLayoutHarness`:
  - after `setPairRanges`, the temporary `.backgroundColor` on both pair ranges resolves to `ChromePalette.nsColor(.bracketMatch, in:)` under `.aqua` and under `.darkAqua`;
  - a bitmap sample inside the open bracket's cell matches the role within 3/255, as `CurrentLineHighlightTests` does;
  - using `ContrastArithmetic`, the five depth colours and the unmatched red each clear 3:1 over `bracketMatch` in both appearances.
- [x] Update the docs:
  - `core-theme.md`: every sentence that calls `bracketMatch` "the one unspent" role, the waiting list, and rule twenty-nine's entry;
  - `app-editor-overlays.md`: the entries for the layout manager and `SyntaxTheme`;
  - `CLAUDE.md`'s theme invariant paragraph: drop "the unspent roles".
- [x] Run `swift test`, the app bundle and `swiftlint --strict`; all must pass. (swift test and swiftlint clean; BracketPairBackgroundTests passes in full. The same eight scale-1.8 layout assertions noted in Task 1 still fail, unchanged and environmental.)

### Task 4: Part C — a Core sizing rule for the code-zone checkbox

**Files:**

- Create: `Sources/PisakaCore/CodeZoneCheckboxRule.swift`
- Create: `Tests/PisakaCoreTests/CodeZoneCheckboxRuleTests.swift`
- [x] Add a pure rule that maps the code font size to four values: the box's side, the glyph's side, the corner radius and the stroke width.
- [x] The interface box is `checkboxSide` 14 against 13-pt default text, so the code-zone side is `fontSize × 14 / 13`.
- [x] The glyph is `side × 10 / 14`, which is the shared shape's proportion.
- [x] The corner radius is `checkboxCornerRadius × side / 14`. The stroke is never thinner than 1 pt.
- [x] Every value is rounded to the half-point grid that `InterfaceMetrics.pt` uses.
- [x] The context-line placeholder's width equals the side.
- [x] The rule names neither `InterfaceMetrics` nor the interface scale.
- [x] Add tests:
  - a 13-pt font gives side 14 and glyph 10;
  - the 8-pt and 32-pt bounds of `ZoomScaleRule.editorFont`;
  - the side grows with the font size;
  - the glyph-to-side proportion holds within rounding.
- [x] Add the file to `core-theme.md`'s file list and to `CLAUDE.md`'s `core-theme.md` index line.
- [x] Run `swift test`; it must pass.

### Task 5: Part C — one checkbox shape at two sizes

**Files:**

- Modify: `Sources/Pisaka/ChromeControls.swift`
- Modify: `Sources/Pisaka/CommitUnifiedDiffView.swift`
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`
- Create: `Tests/PisakaAppTests/CommitDiffCheckboxLayoutTests.swift`
- [x] In `ChromeControls.swift`, move the box drawing out of `ChromeCheckbox` into one internal shape view. It takes the state, the side, the glyph side, the corner radius, the stroke width and the role for the off stroke.
- [x] `ChromeCheckbox` passes its interface-scaled tokens and keeps the `hairline` off stroke, so it draws exactly as before.
- [x] Add a second public entry in the same file for code-zone rows, sized from `CodeZoneCheckboxRule(fontSize:)`:
  - when on: an `accent` fill with an `onAccent` check glyph;
  - when off: a `textSecondary` stroke. A `hairline` box would disappear on the diff washes, so this one is stronger; the shape's comment says why.
- [x] After this change there is still exactly one drawing of a checkbox, and it lives in `ChromeControls.swift`.
- [x] In `CommitUnifiedDiffView`:
  - replace the `Image(systemName:)` toggle with the code-zone entry inside the existing borderless `Button`, keeping `.help` and `.disabled`;
  - set the context-line placeholder's width to the rule's side instead of the literal 14;
  - declare no `let` or `var` whose name contains "checkbox" or "checkmark" (rule thirty's ban);
  - read no `metrics`.
- [x] Update `ChromeThemeSourceGatingTests`:
  - rule thirty's caller pin gains the code-zone entry's callers, {`ChromeControls`, `CommitUnifiedDiffView`}, and its "one checkbox" wording becomes "one checkbox shape at two zones";
  - remove rule thirty-four's `.offBothScales` exemption for `checkbox(for`, because that function no longer holds a glyph;
  - rule twenty-seven gains a clause: the diff's checkbox site names `fontSize` and never `metrics`;
  - update the header inventory to match.
- [x] If `SyntaxBaseForegroundGatingTests` or the zoom suites pin anything in `CommitUnifiedDiffView.swift` that changes, update them. (nothing pinned there changed; both suites pass unchanged)
- [x] Add an app-bundle layout test that hosts `CommitUnifiedDiffView` through `HostedRender`, as `CommitUnifiedDiffWashTests` does:
  - at font sizes 13 and 20, the `accent` extent of a checked row's box equals the rule's side, scaled by the backing factor, within one pixel;
  - at a fixed font size, the measured side is the same with the interface scale at 1.0 and at 1.5;
  - a context row's text starts at the same x as a changed row's text, so the placeholder width matches the box.
- [x] In `core-theme.md`, close departure six with the decision, update the entries for rules thirty and thirty-four, and remove the item from *What is still waiting*. Update `CommitUnifiedDiffView`'s entry in `app-git-views.md`.
- [x] Run `swift test`, the app bundle and `swiftlint --strict`; all must pass. (the only app-bundle failures are the eight scale-1.8 layout tests that fail on the untouched tree too, as in Tasks 1–4)

### Task 6: Part D — the shared split: a Core rule and a gated host

**Files:**

- Create: `Sources/PisakaCore/SplitPaneRule.swift`
- Create: `Tests/PisakaCoreTests/SplitPaneRuleTests.swift`
- Create: `Sources/Pisaka/ChromeSplitView.swift`
- Create: `Tests/PisakaAppTests/ChromeSplitLayoutTests.swift`
- [x] Add a pure `SplitPaneRule` that clamps the extent of the leading (or top) pane:
  - its inputs are that pane's minimum, ideal and maximum, the trailing pane's minimum, the available extent, and the drag translation;
  - when space runs short, the trailing pane's minimum wins;
  - a zero translation, as on the opening frame, changes nothing, the way `BottomPanelHeightRule` already behaves.
- [x] Test the rule: clamping at both ends, a shortfall of space, and a negative or oversized drag.
- [x] Add `ChromeSplitView`, a macOS two-pane split with a horizontal or vertical axis:
  - it draws a `hairline` line at the scaled `hairlineWidth` inside a clear 5-pt drag strip;
  - a `DragGesture` resizes the panes through `SplitPaneRule`;
  - one flag drives the cursor push and pop, and `.onDisappear` releases it (rule twenty-two);
  - the pane extent is held in `@State`, starting at the ideal;
  - the host applies no `.clipped()`, `.clipShape` or `.mask` (see Task 7 for why);
  - a three-pane layout nests two splits.
- [x] Add the file to `gatedFiles`, which takes the count from 63 to 64.
- [x] Add an app-bundle layout test through `HostedRender`:
  - the divider draws `hairline` at one hairline width in both appearances;
  - the panes keep their minimums at a narrow width.
- [x] Add both files to `core-theme.md`'s lists and to `CLAUDE.md`'s index line.
- [x] Run `swift test`, the app bundle and `swiftlint --strict`; all must pass. (swift test and swiftlint clean; ChromeSplitLayoutTests passes in full. The app bundle's only failures are the same scale-1.8 layout tests noted in Tasks 1–5, unchanged and environmental.)

### Task 7: Part D — replace the four platform splits

**Files:**

- Modify: `Sources/Pisaka/ContentView.swift`
- Modify: `Sources/Pisaka/LocalHistoryView.swift`
- Modify: `Sources/Pisaka/AcknowledgementsView.swift`
- Modify: `Sources/Pisaka/DatabaseViewerView.swift`
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`
- [x] Replace each split with `ChromeSplitView`, following the six-step sweep guide in `core-theme.md`:
  - `ContentView.editorSplit`: the tree at 180/240/360 (minimum/ideal/maximum, scaled), then the tab column within `TabColumnWidthRule`'s bounds, then the editor with a minimum of 320;
  - Local History: 220/260/380 against a trailing minimum of 360;
  - Acknowledgements: 180/200/280;
  - the database viewer's vertical split: `gridMinHeight` against `consoleMinHeight`.
- [x] Keep the host free of any clip, because a clip is what made the platform split's panes lose the top safe-area inset (`BottomDockColumn.swift`'s comment).
- [x] Do not claim more for the safe-area guard than it delivers:
  - `BottomDockLayoutTests` hosts `BottomDockColumn` with stub panes, because `ContentView` cannot be built in a test;
  - so that suite cannot see the main window's real split being replaced;
  - the trap it records belongs to the platform split, and may not apply to the new host at all.
  - 
  - Write this in `app-window.md`'s `ContentView` and `BottomDockColumn` entries. The real check of the main window's top row is the live check in Post-Completion.
- [x] `BottomDockLayoutTests`, `TabColumnLayoutTests` and every other app-bundle suite stay green, with no test weakened.
- [x] Add a new rule: no gated file spells `HSplitView` or `VSplitView`, matched against comment- and literal-stripped text. This is rule forty-eight, with a `// MARK: - Rule` marker and a header bullet.
- [x] Update `core-theme.md`:
  - remove the `HSplitView`/`VSplitView` items from the part five (c) and (d) open-question lists and from *What is still waiting*;
  - record the decision in decision 15 (part five (c)) and decision 11 (part five (d)).
- [x] Run `swift test`, the app bundle and `swiftlint --strict`; all must pass. (swift test and swiftlint clean; the app bundle's only failures are the same eight scale-1.8 layout tests recorded in Tasks 1–6)

### Task 8: Part D — focus treatment, the Acknowledgements selection, and the iOS `.label`

**Files:**

- Modify: `Sources/Pisaka/DatabaseViewerView.swift`
- Modify: `Sources/Pisaka/LeetCodeBrowserView.swift`
- Modify: `Sources/Pisaka/WelcomeView.swift` (comment only)
- Modify: `Sources/Pisaka/AcknowledgementsView.swift`
- Modify: `Sources/Pisaka/Platform/LicenseTextView.swift` (comment only)
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`
- Create or extend: app-bundle layout tests for the focused cell and the focused row
- [x] **Database grid:** the focused cell keeps its `accentTintStrong` fill and adds an `accent` border at the scaled `fieldFocusedBorderWidth`. Apply `.focusEffectDisabled()` next to its `.focusable(`.
- [x] **Problem browser:** while the list holds focus, the selected row draws the same `accent` border over its `accentTintStrong` wash. Apply `.focusEffectDisabled()` to the focusable list.
- [x] **Welcome root:** closed by reason, with no code change.
  - Its focus exists only so the whole screen receives key equivalents; it marks no control.
  - A border around the whole canvas would therefore suggest a selection that does not exist.
  - The platform ring is already suppressed.
  - 
  - Record this in the welcome screen's section and in `app-window.md`.
- [x] **Acknowledgements:** move from `List(selection:)` to the gated list shape the problem browser and the Log already use:
  - a `LazyVStack` of rows, with `accentTintStrong` on the selected row and `hoverTint` on hover;
  - no platform highlight;
  - `.focusable` plus `onMoveCommand` for keyboard selection, with the same focus border when focused.
- [x] Change rule thirty-five's pin for `AcknowledgementsView.swift` from `[[]]` to its selected-row background expression. Rewrite decision 15's "no row background" sentence.
- [x] **iOS `.label`:** closed with the sentence "iOS is outside the theme", and no iOS code changes. Rule one's list does not grow. Write the sentence in two places:
  - `LicenseTextView.swift`'s header sentence, which already says the iOS half is not swept;
  - decision 13 of part five (c).
- [x] Add rule forty-nine: in every gated file, each `.focusable(` modifier chain also applies `.focusEffectDisabled(`. Pin it by count equality per file, cross-checked against the set of files that spell `.focusable(`.
- [x] Extend the suite's `spelled` number table so it can spell forty-eight, forty-nine and sixty-four.
- [x] Add app-bundle layout tests through `HostedRender`:
  - a focused grid cell shows the `accent` border at the focused-border width;
  - the selected Acknowledgements row draws `accentTintStrong`;
  - the focused browser row shows the border.
- [x] Rewrite the open-question lists in parts five (c) and (d) without these items. Anything that stays open goes into a new explicit list, one reason per line.
- [x] Run `swift test`, the app bundle and `swiftlint --strict`; all must pass. (swift test (6184) and swiftlint clean; FocusBorderLayoutTests passes in full; the app bundle's only failures are the same eight scale-1.8 layout tests recorded in Tasks 1–7)

### Task 9: Part D — keep the counts from drifting

**Files:**

- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`
- Modify: `CLAUDE.md`
- Modify: `docs/architecture/core-theme.md`
- [x] Add a test that `CLAUDE.md` and `core-theme.md` both spell `gatedFiles.count` in words, using the same `spelled` table. Today only prose states 63; no test pins it. (testBothSummariesSpellTheGatedSetsOwnSize)
- [x] Update every number in the prose:
  - the gated-file count, now sixty-four;
  - the rule count, now forty-nine, both in "The forty-nine rules, each invisible to the compiler:" and in `CLAUDE.md`'s "and its forty-nine rules";
  - the canonical list, numbered 1 to 49;
  - the header inventory;
  - the stated-exceptions paragraph, if a new reading keeps literals.
- [x] Check that `CLAUDE.md` stays under 60,000 characters (`LintConfigurationTests`).
- [x] Run `swift test` and `swiftlint --strict`; both must pass. (6185 tests green; swiftlint clean; CLAUDE.md 51,789 characters)

### Task 10: Part E — reproduce the mechanism outside the app

**Files:**

- Create: a throwaway harness under `/tmp`, outside the repository, as #99 did. Its results are summarised in `Vendor/TreeSitterMake/VENDORED.md` and `app-editor-overlays.md`.
- [ ] Build a SwiftPM executable that depends on the pinned Neon, SwiftTreeSitter and tree-sitter-bash, with `Vendor/TreeSitterMake` as a path dependency.
- [ ] Run a Make root `LanguageLayer` over `Tests/PisakaAppTests/Fixtures/injected-shell.mk` and confirm the joined word `1echo` appears.
- [ ] Parse bash directly with `includedRanges`, in two cases:
  - with ranges that stop before each `\n`, the lexer spans the gap and gives `1echo`;
  - with the same ranges extended to include each `\n`, the words stay separate.
- [ ] Rule out the two other acceptable fixes:
  - a query-only fix: `NL` cannot be captured by a query, because it is an unnamed immediate regex token inside a hidden rule;
  - an app-side range extension: SwiftTreeSitterLayer exposes no hook to transform ranges.
- [ ] Record both dumps and both conclusions in the progress log. This task changes nothing in the repository, so the only test run is `swift test`, which must stay green.

### Task 11: Part E — the recipe line's `shell_text` includes its terminator

**Files:**

- Modify: `Vendor/TreeSitterMake/grammar.js`
- Modify (regenerated): `Vendor/TreeSitterMake/src/{parser.c,grammar.json,node-types.json}`
- Modify: `Vendor/TreeSitterMake/VENDORED.md`
- Modify, only if the new node shape forces it: `Vendor/TreeSitterMake/queries/*.scm` and `Resources/Queries/make/symbols.scm`
- [ ] Edit `grammar.js`, marking each change with an `// EDIT:` comment:
  - `_prefixed_recipe_line` and `_attached_recipe_line` move their `NL` into an aliased `shell_text`: a hidden `_shell_line: seq($._line_text, NL)` aliased to `shell_text`, so the node ends after its newline;
  - an empty prefixed line still parses, with a bare `NL`;
  - `shell_assignment`'s `shell_command` gets the same treatment;
  - nothing else in the grammar changes.
- [ ] Regenerate with `npx tree-sitter-cli@<the version recorded in VENDORED.md> generate --abi 15`.
  - Confirm `LANGUAGE_VERSION` is 15 or lower.
  - Confirm `swift build --package-path Vendor/TreeSitterMake` succeeds.
- [ ] Update `VENDORED.md`:
  - `grammar.js` is now edited here;
  - `parser.c`, `grammar.json` and `node-types.json` are generated here from it, with the CLI version and command;
  - the update procedure gains a step to re-apply the edits and regenerate;
  - the verbatim list shrinks to the headers, `LICENSE` and `injections.scm`.
- [ ] Re-run the full verification recipe:
  - static half: `VendoredGrammarQueryTests` passes against the new `node-types.json`;
  - runtime half, through the Task 10 harness: both queries compile, fixtures A and B parse, and the dump is unchanged except that the joined words are now split;
  - record the result in `VENDORED.md`. The by-hand check in a DEBUG build is listed under Post-Completion.
- [ ] Run `swift test`, the app bundle and `swiftlint --strict`; all must pass.

### Task 12: Part E — invert the loss test and check Markdown fences

**Files:**

- Modify: `Tests/PisakaAppTests/InjectedHighlightPredicateTests.swift`
- Create: `Tests/PisakaAppTests/Fixtures/injected-shell-two-fences.md`
- Modify: `docs/architecture/app-editor-overlays.md`
- [ ] Delete `makeCombinedLayerLosses`. The Make case now asserts that the injected captures equal the standalone `.sh` captures exactly, over the same fixture, so every recipe line's first word carries `function`.
- [ ] Add a Markdown fixture with two adjacent `sh` fences that split the same three lines between them, with prose in between.
- [ ] Assert that every first word matches the standalone captures. The expected result is no loss, because `code_fence_content` includes its line endings.
- [ ] If the fence case does show a loss, stop and report it as an open item. The Markdown grammars are out of scope, so this plan cannot fix it.
- [ ] Update the docs:
  - in `app-editor-overlays.md`, replace the "Stated limit" paragraph with the fix and its mechanism;
  - in `app-editor-overlays.md`, update the injection enumeration (Make, plus the two-fence Markdown case);
  - in `core-theme.md`, update *What is still waiting* if it listed the limit.
- [ ] Run `swift test`, the app bundle and `swiftlint --strict`; all must pass.

### Task 13: Verify acceptance criteria

- [ ] Run `swift test`.
- [ ] Run `xcodegen generate`, then `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' test`.
- [ ] Run `swiftlint --strict` from the repository root.
- [ ] Run `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -configuration Release -destination 'platform=macOS' build`.
- [ ] Run `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'generic/platform=iOS' build`.
- [ ] Check that `ChromeThemeSourceGatingTests`' header inventory, the rule count (49), the gated-file count (64) and `CLAUDE.md`'s invariant paragraph all agree.
- [ ] Check that `core-theme.md`'s *What is still waiting* names nothing from parts five (b)–(h).

### Task 14: Update documentation

- [ ] Update `CLAUDE.md`:
  - add the new Core and app files (`CodeZoneCheckboxRule.swift`, `SplitPaneRule.swift`, `ChromeSplitView.swift`) to the `core-theme.md` index lines;
  - in the theme invariant, update the counts and drop "the unspent roles";
  - in the conventions, note that the Make grammar's parser is now generated here;
  - keep the file under 60,000 characters.
- [ ] Update `README.md` and `docs/FEATURES.md` only if their user-facing descriptions mention the dividers or the bracket-pair colour.

## Post-Completion (manual)

- Take screenshots from a DEBUG build, in both appearances:
  - the Log graph with at least four concurrent lanes;
  - the editor with the caret inside a bracket pair;
  - the commit dialog's unified diff with checked and unchecked lines, at two code font sizes;
  - one restyled divider from the main window, and the focused database cell;
  - the repository's own `Makefile` with a multi-line recipe whose every first word is coloured.
- Check the main window's top row live, in a DEBUG build, because `BottomDockLayoutTests` cannot see the real split:
  - check with the dock open and with it closed, in both appearances, at the default window size;
  - the editor's first line and the tree's first row must be visible under the title bar;
  - check before and after dragging a divider.
- Run the by-hand half of `Vendor/TreeSitterMake/VENDORED.md`'s verification in a DEBUG build: open a Makefile and confirm ⌃⌘J answers and highlighting holds.
- Confirm CI is green on the PR.
