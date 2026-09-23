# Chrome theme, part five (a): the popovers and the search surfaces

## Overview

This part carries the chrome sweep into the floating surfaces and the two search
surfaces: the completion panel, the hover popover, the find/replace bar above the
editor, the Find in Files window and its window controller, and the
recent-searches menu. The two bottom-bar popovers (branch switcher, project
switcher) and the Log filter bar's date-picker calendar popover get a
`bgPopover` ground. The two switchers can then lose their `Divider()` calls.

It spends `bgPopover`, which leaves three roles unspent (`currentLine`,
`bracketMatch`, `conflictBackground`). The completion badge goes monochrome, and
its colour is removed from Core. One shared themed text-field shape replaces the
Log filter bar's private copy. Four new gating rules take the chrome suite from
twenty-two rules over twenty-seven gated files to twenty-six rules over
thirty-four.

**Correction to the ticket's gated-file list.** The ticket says seven files join
`gatedFiles`, but it lists six: five named files plus the shared field's new
file. The seventh is `ProjectSearchWindowController.swift`. It paints the Find in
Files window's own ground `bgPanel` through `ChromePalette.nsColor(_:)`, so a
live resize never shows the system window colour around the hosted SwiftUI root.
That makes it a role-naming chrome file, so it belongs in the set. The ticket's
own count, 27 + 7 = 34, already assumes it.

The design and this repository disagree in four places. Each is settled in the
repository's favour and recorded in `core-theme.md`:

1. **A match preview line is code.** It stays on the code font and in
   `SyntaxTheme`'s plain colour.
2. **The highlight stays the editor's.** The match highlight inside a preview
   keeps the editor's own current-match background.
3. **No selection is added to the match list.** `accentTintStrong` goes unused
   on that surface, because this part changes no behaviour. This was settled in
   Q&A.
4. **The Find in Files window keeps the standard system title bar**, per
   requirement 7. The design's 28-point title strip and its 12-point
   `textSecondary` title are therefore not drawn. `MainWindowChrome.swift` stays
   the only file that makes a title bar transparent.

The line number beside a preview line stays on the code font, as the preview
does. Its colour becomes `textSecondary`, the role the editor's own gutter
numbers use (`LineNumberRulerView.swift`). So the number takes its size from the
code zone and its colour from a role, like the gutter it mirrors. Today it uses
`.secondary`, a system colour that a gated file may not spell.

**The three SwiftUI popovers get one answer, with no branch.** Both switchers and
the Log calendar carry `bgPopover` on their content, and no availability branch
appears anywhere. The popover's arrow keeps the system material, because a
content background cannot reach it, and each of the three files says so in one
line. `presentationBackground` is not shipped here. `core-theme.md` records it as
an open question for the part that sweeps sheets and dialogs. The modifier is
documented to apply to sheets, and a sheet is big enough for the difference to
matter.

## Context

**Files involved**

- Core:
  - `Sources/PisakaCore/CompletionPopup.swift` (loses `Badge.color`)
  - `Sources/PisakaCore/ChromeGeometry.swift` (new shared tokens)
  - `Sources/PisakaCore/ChromeColorRole.swift` (the doc comment that lists the
    unspent roles)
- App:
  - `Sources/Pisaka/CompletionPanel.swift`
  - `Sources/Pisaka/HoverPanel.swift`
  - `Sources/Pisaka/SearchBarView.swift`
  - `Sources/Pisaka/ProjectSearchView.swift`
  - `Sources/Pisaka/ProjectSearchWindowController.swift`
  - `Sources/Pisaka/SearchHistoryMenu.swift`
  - `Sources/Pisaka/LogFilterBar.swift` (its private field shape, and its
    calendar popover at ~line 421)
  - `Sources/Pisaka/BranchSwitcherView.swift`
  - `Sources/Pisaka/ProjectSwitcherView.swift`
  - `Sources/Pisaka/ContentView.swift` (the `Divider()` under the find bar,
    ~line 1164)
  - New: `Sources/Pisaka/ChromeControls.swift`, holding the shared field shape
    and the secondary button style
- Tests:
  - `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`
  - `Tests/PisakaCoreTests/ChromeThemeTests.swift` (the geometry inventory)
  - `Tests/PisakaCoreTests/CompletionPopupTests.swift`
  - `Tests/PisakaCoreTests/ZoomSourceGatingTests.swift` (read only; must stay
    green unchanged)
- Docs:
  - `docs/architecture/core-theme.md`
  - `docs/architecture/app-editor.md`
  - `docs/architecture/app-window.md`
  - `docs/architecture/app-git-views.md`
  - `docs/architecture/core-intelligence.md`
  - `docs/architecture/core-search.md`
  - `CLAUDE.md`

**Related patterns**

- **The shape to lift.** The Log filter bar's private `controlBox`/`filterField`
  (`LogFilterBar.swift` ~260–300) is the field shape: a `bgEditor` ground, a
  one-point `hairline` border and two points of `accent` on focus, with a plain
  `TextField` over a `textSecondary` placeholder.
- **Where numbers live.** A number used by one surface lives in a private layout
  enum in that surface's file, as `FilterBarLayout` does. A number shared across
  surfaces becomes a `ChromeGeometry` token, never derived from another token.
- **Edges.** A swept strip draws its own one-point `hairline` on the edge it
  owns. Rule fourteen is the precedent.
- **AppKit colour.** An AppKit surface reaches the palette through
  `ChromePalette.nsColor(_:)`. Every layer `CGColor` (border *and* background) is
  set only inside `appearance.performAsCurrentDrawingAppearance { … }`, as
  `match(_:to:)` already does for the border in both panels.
- **SwiftUI popovers.** The ground goes on the popover's content as a
  background. There is no `presentationBackground` and no `#available` branch.
- **Accessibility.** Follow the bottom-bar widgets and rule twenty:
  - icon-only and letter-pair controls get a label and a `.help` tooltip;
  - a toggle speaks its state through `.accessibilityValue`;
  - decorative symbols get `.accessibilityHidden(true)` on the symbol itself.
- **How gating rules match.** They read comment- and literal-stripped text
  through `LSPSourceGatingTests.strippingCommentsAndStringLiterals`. A multi-line
  call is matched with a whitespace-tolerant regular expression or a
  brace-matched body (`matchedBody(after:in:)` / `matchedBodies(after:in:)`),
  never with a contiguous substring.

**Dependencies:** none new.

## Development Approach

- **Testing approach:** regular (code first, then tests), with one exception.
  Each gating rule in Task 7 is first shown red against a deliberately broken
  local edit, then green.
- **Order of work:** complete each task fully before moving to the next. A task
  that restyles a file adds that file to `gatedFiles` in the same task, so rules
  one and two cover it immediately.
- **Architecture entries:** read each file's `docs/architecture/` entry before
  modifying it.
- **Names:** no product or brand names in code, comments, docs or commit
  messages.
- **Derived data:** any local `xcodebuild` uses `-derivedDataPath
  ~/Library/Developer/Xcode/DerivedData/pisaka-<purpose>`, never a path inside
  the repository.
- **Font sizes:** no font size is added to `ChromeGeometry`. The design's
  13/12/11 are `InterfaceTextStyle.body`/`.callout`/`.subheadline`. The
  `.caption` that both search surfaces use today is replaced by one of these
  three.
- **Roles and exemptions:** no new role and no new exemption. If a surface seems
  to need either, stop and bring it back as a design question.
- **Unattended verification only:**
  - No task takes a screen capture.
  - No task depends on a human opening a menu, a popover or a window.
  - Building and launching the app is fine, but a task never waits on what the
    running window shows.
  - Anything that can only be confirmed by looking at a running window belongs
    to the acceptance review after this plan, not inside it.
- **CRITICAL:** every task includes new or updated tests. Task 6 is the one
  exception: its net is rules twenty-three and twenty-four in Task 7, so Task 6
  is not complete until Task 7 is.
- **CRITICAL:** `swift test` must pass before the next task starts. A task that
  touches app files also builds the macOS app.

## Implementation Steps

### Task 1: The shared field shape and secondary button; the Log filter bar as first caller, its calendar popover on `bgPopover`

**Files:**
- Create: `Sources/Pisaka/ChromeControls.swift`
- Modify: `Sources/PisakaCore/ChromeGeometry.swift`
- Modify: `Sources/Pisaka/LogFilterBar.swift`
- Modify: `Tests/PisakaCoreTests/ChromeThemeTests.swift`
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`

- [x] Add five tokens to `ChromeGeometry`, the numbers the lifted shape and the button need: field corner radius 4, focused border width 2, field horizontal padding 10, secondary button height 28 and secondary button horizontal padding 14. Each is a distinct token with a one-line comment, and none is derived from another.
- [x] Update `ChromeThemeTests`' set-equality token inventory to include them.
- [x] Create `ChromeControls.swift` (macOS-gated) with three pieces:
  - **A control box.** It has a `bgEditor` ground, a one-point `hairline` border, `accent` at the focused width while focused, and the new corner-radius token. It takes its horizontal inset as a parameter and states **no height**, so the container decides: 22 in a filter strip, 33 in Find in Files.
  - **A themed text field built on that box.** It is a plain `TextField` with `textPrimary` content, a `textSecondary` placeholder, an optional leading glyph hidden from accessibility, and a spoken label. Focus comes in as a `FocusState` binding plus the value it equals, so each caller keeps its own focus enum.
  - **A secondary button style.** It is 28 high, with a one-point `hairline` border, radius `buttonCornerRadius`, padding 14 and a `callout` label in `textPrimary`.
  - Everything is scaled through `InterfaceMetrics`, and colours come from `\.chromeTheme`.
- [x] Move `LogFilterBar.swift` onto the shared box:
  - It draws its text fields and its three boxed system controls (the branch menu and the two date bounds) through the box.
  - It passes its own 22-point height and its own horizontal inset, so its pixels are unchanged.
  - Delete its private `controlBox`/`filterField` and the `FilterBarLayout` entries that become unused, so no second copy survives.
  - Its doc comment says the shape is shared.
- [x] Draw the Log filter bar's date-picker calendar popover (~line 421) on `bgPopover`:
  - The popover's content gets a `bgPopover` background. There is no `presentationBackground` and no availability branch.
  - One line in the file says that the popover's arrow keeps the system material, because the content background cannot reach it.
  - The graphical date picker's own drawing is left to the system.
- [x] Add `ChromeControls.swift` to `gatedFiles`.
- [x] Rule twenty-one must stay red when a fixed `.frame(width:` is reintroduced. Confirm this against a local edit, then revert.
- [x] Run `swift test` and the macOS build. Both must pass.

### Task 2: The completion panel on `bgPopover`, and the badge's colour leaves Core

**Files:**
- Modify: `Sources/PisakaCore/CompletionPopup.swift`
- Modify: `Sources/Pisaka/CompletionPanel.swift`
- Modify: `Tests/PisakaCoreTests/CompletionPopupTests.swift`
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`

- [x] Remove `color` from `CompletionPopup.Badge`: the stored property, the initializer parameter and every table entry's colour. `init(symbolName:)` and `init(source:)` remain. `FileIconColor` stays, because `FileIcon` still uses it.
- [x] `CompletionPopupTests` still asserts a badge for every `SymbolKind`, plus the keyword and word badges, by symbol name only. Confirm by grep that nothing in `Sources/` reads a badge colour.
- [x] Replace the panel's vibrancy background with a flat `bgPopover` layer fill: a one-point `hairline` border, corner radius `cornerRadiusMax`, and the window's shadow kept. The floating non-activating behaviour, the pass-through parent matching and the refusal of key status do not change.
- [x] In `match(_:to:)`, set both layer colours inside `performAsCurrentDrawingAppearance`: `borderColor` from `ChromePalette.nsColor(.hairline)` and `backgroundColor` from `ChromePalette.nsColor(.bgPopover)`. Nothing else in the file sets a layer colour. Extend the existing comment to say that the background is a `CGColor` too, so it carries the same trap as the border.
- [x] Row colours:
  - Row text is `textPrimary`.
  - The selected row has an `accent` ground and `onAccent` text.
  - The badge is monochrome: `textSecondary` on an ordinary row, `onAccent` on the selected one.
  - The private `color(for:)` hue table is deleted.
- [x] Add `CompletionPanel.swift` to `gatedFiles`.
- [x] Run `swift test` and the macOS build. Both must pass, including `ZoomSourceGatingTests`' completion-panel rules, unchanged.

### Task 3: The hover popover on `bgPopover`

**Files:**
- Modify: `Sources/Pisaka/HoverPanel.swift`
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`

- [x] Replace the vibrancy background with a flat `bgPopover` layer fill, on the same terms as Task 2: a one-point `hairline`, radius `cornerRadiusMax`, shadow kept. Both layer colours (border and background) are set only inside `match(_:to:)`'s drawing-appearance block. That block keeps its existing explanation, updated to cover the background.
- [x] Prose is `textSecondary`, code segments are `textPrimary`, and the truncation marker is `textSecondary`. The doc comment states that the chrome has two text tones.
- [x] `ignoresMouseEvents`, the absence of a zoom surface and the exclusion from the window cycle all stay unchanged.
- [x] Add `HoverPanel.swift` to `gatedFiles`.
- [x] Run `swift test` and the macOS build. Both must pass, including the hover pass-through rules in `ZoomSourceGatingTests`.

### Task 4: The find/replace bar and the recent-searches menu

**Files:**
- Modify: `Sources/Pisaka/SearchBarView.swift`
- Modify: `Sources/Pisaka/SearchHistoryMenu.swift`
- Modify: `Sources/Pisaka/ContentView.swift`
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`

- [x] Give the bar a `bgPanel` ground and have it draw its own one-point `hairline` along its bottom edge. Remove the `Divider()` under it in `ContentView`, leaving a one-line comment in the style of the one at ~line 403.
- [x] The query and replace fields use the shared themed field. The system rounded-border style is gone.
- [x] Colours:
  - The match counter and the labels are `textSecondary`.
  - The inline regular-expression error is `statusRed`.
  - The three query-mode toggles are `accent` on an `accentTint` ground while on, and `textPrimary` with no ground while off.
  - The navigation, close and disclosure glyphs take roles.
  - Replace and Replace All use the shared secondary button style.
  - The `.caption` text becomes `.subheadline`.
- [x] Accessibility:
  - Each toggle has a spoken name, a `.help` tooltip and an on/off `.accessibilityValue`.
  - Previous, Next, Close and the replace disclosure have a spoken name and a tooltip, and their symbols are hidden.
  - The fields speak their names.
- [x] In `SearchHistoryMenu`, the trigger glyph becomes `textSecondary` and is hidden from accessibility, and the menu keeps a spoken name. The menu's rows and its one `Divider()` are untouched. A comment names that separator as the one `Divider()` a gated file may spell.
- [x] Add `SearchBarView.swift` and `SearchHistoryMenu.swift` to `gatedFiles`.
- [x] Run `swift test` and the macOS build. Both must pass.

### Task 5: The Find in Files window

**Files:**
- Modify: `Sources/Pisaka/ProjectSearchView.swift`
- Modify: `Sources/Pisaka/ProjectSearchWindowController.swift`
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`

- [x] The root is `bgPanel`. The window controller paints the window's own background through `ChromePalette.nsColor(.bgPanel)`. The standard title bar and its style mask are unchanged.
- [x] Apply the design values:
  - **Content body:** padding 16 at the top and on both sides, 0 at the bottom, gap 12 between rows.
  - **Query row:** 33 high in the shared field, with three 16-point toggles at its trailing end, gap 10, in `textSecondary`.
  - **Replace row:** the shared field, gap 8, then *Replace All* in the secondary button style.
  - **Scope line:** `callout` in `textSecondary`.
  - **Results:** gap 8.
  - **Group header:** 24 high, padding 8, a 14-point icon, the path in `callout` and the count in `subheadline`, all in `textSecondary`.
  - **Match row:** 24 high, padding 8 on the right and 34 on the left.
  - **Footer:** 32 high, with its own top `hairline`, padding 16, and the summary in `callout` `textSecondary`.
  - The file-mask field is also the shared field.
  - The `Divider()` between the header and the results is replaced by a `hairline` rule the content draws.
- [x] Numbers with no `ChromeGeometry` home live in a private layout enum in this file. Existing tokens are reused where they fit.
- [x] The group header icon stays monochrome `textSecondary`, following the monochrome-icon decision and the tab icon rule.
- [x] The match row keeps its zones:
  - The preview text stays on the code font in `SyntaxTheme`'s plain colour, and the highlight keeps the editor's current-match background.
  - The line number stays on the code font and takes `textSecondary`.
  - The row keeps its `ZoomSurfaceMarker(kind: .code)`.
  - Nothing sized by the code font is multiplied by the interface scale, and nothing sized by the interface reads `settings.fontSize`.
  - No selection state is added.
- [x] The regular-expression and validation error is `statusRed`.
- [x] Accessibility: the fields, the toggles (name, tooltip, value) and *Replace All* are named, and decorative symbols are hidden.
- [x] Add `ProjectSearchView.swift` and `ProjectSearchWindowController.swift` to `gatedFiles`.
- [x] Run `swift test` and the macOS build. Both must pass, and `ZoomSourceGatingTests`' surface and root sets must pass unchanged.

### Task 6: The two bottom-bar popovers get their ground and lose their dividers

**Files:**
- Modify: `Sources/Pisaka/BranchSwitcherView.swift`
- Modify: `Sources/Pisaka/ProjectSwitcherView.swift`

This task adds no test of its own. Its net is rules twenty-three and
twenty-four in Task 7, so this task is not complete until Task 7 is.

- [x] Draw both popovers' content on `bgPopover` with a content background:
  - There is no `presentationBackground` and no `#available` branch, which matches the Log calendar from Task 1.
  - Each file says in one line that the popover's arrow keeps the system material, because the content background cannot reach it.
- [x] Each `Divider()` becomes a one-point `hairline` rule that the content draws.
- [x] The branch switcher's filter field uses the shared themed field.
- [x] Rewrite the doc comments on `theme` and `popoverContent` in both files, which explain why the dividers had to stay, so that they say what is true now. No sentence describing the old material ground or the kept dividers remains.
- [x] Run `swift test` and the macOS build. Both must pass. `swift test` covers rules one and two and the bottom-bar rules, because both files are already gated.

### Task 7: Four new gating rules and the count bookkeeping

**Files:**
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`
- Modify: `docs/architecture/core-theme.md` (the canonical list and its opening count)
- Modify: `CLAUDE.md` (the rule-count sentence)

- [x] **Rule twenty-three — a popover surface names `bgPopover`.**
  - The gated files naming `bgPopover` equal {`CompletionPanel.swift`, `HoverPanel.swift`, `BranchSwitcherView.swift`, `ProjectSwitcherView.swift`, `LogFilterBar.swift`}.
  - Every gated file that presents a popover (`.popover(`) or declares an `NSPanel` is in that set. This clause is what lets the rule see a sixth popover appearing on a system material, and it stays.
  - No gated file spells `NSVisualEffectView`, a `.material` assignment or `presentationBackground`.
- [x] **Rule twenty-four — `Divider()` in exactly one place.**
  - The gated files spelling `Divider(` equal {`SearchHistoryMenu.swift`}, with exactly one occurrence there.
  - The doc comment names the reason: a menu's separator is drawn by the system's menu machinery.
- [x] **Rule twenty-five — AppKit layer colours are set only inside the drawing appearance.**
  - In `CompletionPanel.swift` and `HoverPanel.swift`, every layer `borderColor` assignment *and* every layer `backgroundColor` assignment lies inside a brace-matched `performAsCurrentDrawingAppearance` body.
  - A body containing a `borderColor` assignment names `hairline`, and a body containing a `backgroundColor` assignment names `bgPopover`.
  - Non-vacuity is checked per file per property: each file has at least one `borderColor` and at least one `backgroundColor` assignment.
  - Matching tolerates whitespace around `.` and `=`.
- [x] **Rule twenty-six — one field shape.**
  - No gated file spells the rounded-border style: `.textFieldStyle(` followed by `.roundedBorder` across any whitespace, or `RoundedBorderTextFieldStyle`.
  - The set of files constructing the shared field or box equals {`LogFilterBar.swift`, `SearchBarView.swift`, `ProjectSearchView.swift`, `BranchSwitcherView.swift`}, plus `ChromeControls.swift`, where the box is composed into the field.
- [x] Extend rule twenty's control-builder table to the two search surfaces' toggles and buttons. It keeps its name, value and hidden-symbol checks and its "Rule twenty:" marker.
- [x] Show each new rule red against a deliberately broken local edit, then revert. The edits:
  - a border colour set outside the block;
  - a background colour set outside the block;
  - a multi-line `.textFieldStyle(\n .roundedBorder)`;
  - a `Divider()` put back in a switcher;
  - the Log calendar popover's `bgPopover` removed;
  - a `presentationBackground` added to a switcher.
- [x] Update the suite's header bullet list with the four rules, and extend `spelled` to 26.
- [x] Update `core-theme.md`'s canonical list to open with "The twenty-six rules, each invisible to the compiler:" and to include items 23–26.
- [x] Update `CLAUDE.md`'s sentence to "and its twenty-six rules", listing the four.
- [x] Run `swift test`. It must pass.

### Task 8: Verify acceptance criteria

- [x] Run `swift test`. It must be green.
- [x] Run `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-test test`. It must be green.
- [x] Build macOS with `-configuration Release`, and iOS for `generic/platform=iOS` (Debug), both with derived data outside the repository.
- [x] Run `swiftlint --strict` from the repository root. It must be clean.
- [x] Confirm by grep:
  - `gatedFiles` has 34 entries, and the exemptions and `roleNamingExemptions` are unchanged.
  - `bgPopover` has five readers.
  - No `Badge.color` reader remains.
  - The only gated `Divider()` is the menu's.
  - No `presentationBackground` and no `#available` branch was added by this part.
  - `ZoomSourceGatingTests`' sets are unchanged.

### Task 9: Update documentation

- [ ] Add the part five (a) record to `core-theme.md`:
  - the surfaces swept (including the Log calendar popover), with the gated set at thirty-four;
  - `bgPopover` spent;
  - how the three SwiftUI popovers carry the ground: on their content, with no availability branch, and the arrow on the system material;
  - `presentationBackground` as an open question for the part that sweeps sheets and dialogs. The modifier is documented to apply there, and a sheet is big enough for the difference to matter. It was not shipped here as an unverified branch;
  - the four departures from the design with their reasons, including the line number's `textSecondary` on the code font;
  - the correction of the ticket's gated-file list (`ProjectSearchWindowController.swift` as the seventh);
  - the badge's lost hue and the removed Core property;
  - `ChromeControls.swift` and its callers;
  - the new tokens;
  - the four rules, with rule twenty-five covering both layer colours.
- [ ] Update the "unspent" paragraphs in `core-theme.md` and the doc comment in `ChromeColorRole.swift` to three roles: `currentLine`, `bracketMatch`, `conflictBackground`.
- [ ] Update the other architecture docs:
  - `app-editor.md`: CompletionPanel, HoverPanel, SearchBarView, ProjectSearchView and its window controller, SearchHistoryMenu.
  - `app-window.md`: ProjectSwitcherView, and ContentView's removed divider.
  - `app-git-views.md`: BranchSwitcherView, and the Log filter bar's shared field and calendar ground.
  - `core-intelligence.md`: `CompletionPopup.Badge` is symbol-only.
  - `core-search.md`: the history menu's trigger and its one separator.
- [x] Update `CLAUDE.md`:
  - The chrome-theme invariant says thirty-four gated files and twenty-six rules.
  - The swept-surfaces sentence adds this part's surfaces and ends with three unspent roles.
  - The chrome-theme index gains one line for `ChromeControls.swift`.
- [ ] Make no README change: nothing user-facing changes beyond appearance and accessibility.
