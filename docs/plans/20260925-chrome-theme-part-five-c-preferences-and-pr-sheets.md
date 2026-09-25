# Chrome theme, part five (c): Preferences, the language-server settings, Acknowledgements and the two pull-request sheets

## Overview

This part moves the settings surfaces onto the chrome's role vocabulary:

- the Preferences window (host, tab bar and all four pages: General, Language Servers, the problem-catalog tab, Acknowledgements);
- the licence text pane behind Acknowledgements;
- the create and merge pull-request sheets.

It spends **no new colour role**. `currentLine` and `bracketMatch` stay unspent. What it adds is controls. The design draws a replacement for every platform form control these files use, and those replacements are built here, in `ChromeControls.swift`.

Seven files join the gated set, taking it from 44 to 51:

- `SettingsView.swift`
- `LSPServerSettingsView.swift`
- `LSPInstalledLicenses.swift`
- `AcknowledgementsView.swift`
- `Platform/LicenseTextView.swift`
- `NewPullRequestSheet.swift`
- `PullRequestMergeSheet.swift`

Two new rules take the suite from thirty-five to thirty-seven. Six existing rules gain clauses: sixteen, twenty, twenty-four, twenty-six, twenty-seven and thirty. Two existing pins grow: thirty-one and thirty-five.

**Decisions this plan makes where the ticket is silent or the repository differs.** Each one is recorded in `core-theme.md`:

1. **The Divider sites are not where the ticket puts them.** `LSPInstalledLicenses.swift` has no view and no `Divider()`. All three language-server dividers are in `LSPServerSettingsView.swift`: the separator run `if index > 0 { Divider() }` and the two around the toolchain rows. The fourth is in `AcknowledgementsView.swift`. The count of four is right.
2. **`LSPInstalledLicenses.swift` is gated but paints nothing.** It is a Foundation-only enum that returns documents. It joins `roleNamingExemptions` on the same footing as `ChromeThemeEnvironment.swift`: it is gated for rules one and two, which are the rules it could break.
3. **A fifth shape is lifted, not invented: the menu field.** The "existing menu idiom" is `Menu` + `.menuStyle(.borderlessButton)` + `.menuIndicator(.hidden)` with a themed label. It is drawn as a dropdown in exactly one place today, the Log filter bar's branch menu (`LogFilterBar.refPicker`: a `ChromeControlBox`, a `Menu`, a chevron). That menu wraps a `Picker(…).pickerStyle(.inline)`, which the new platform-control ban would find red on day one. So the Log bar has to be swept anyway, and it becomes the first caller of a lifted `ChromeMenuField`. The menu's items become plain `Button`s, and the chosen item is labelled with a checkmark (`Label(title, systemImage: "checkmark")`). The fetched problem's default language and the new pull request's base branch are the other two callers. That gives one definition and three callers, the way the checkbox was lifted in part five (b).
4. **Two already-gated files fail the new ban and are swept in this part.** The ban is not weakened for them:
   - `CommitDialogView.swift`'s `AuthorEditorView` uses `Form { TextField… }`. It becomes two stacked `ChromeThemedTextField`s ("Name", "Email") with their own `@FocusState`.
   - The Log bar's inline `Picker` is handled by decision 3.
5. **Draft stays a checkbox.** "Draft" on the create sheet is an option of one action, not a standing preference. It becomes `ChromeCheckbox` with the title "Draft", the same shape as Amend and Push in the commit dialog. The two preference toggles in General become switches.
6. **The merge method is a segmented control, although its segments are filtered.** The allowed methods are a subset of the closed three-case `GitHubMergeMethod`, so the most it can ever lay out is known at build time. `plan.showsMethodPicker` already hides a one-method control. The binding stays `GitHubMergeMethod?`, and each option's value is `Optional(method)`.
7. **The Preferences pages share one size.** `TabView` sized the window to its widest tab. The new host frames every page at the one size Acknowledgements already needed, `metrics.scaled(640)` × `metrics.scaled(420)`, under the 36-point tab bar, so switching tabs does not resize the window:
   - the size moves into a private layout enum in `SettingsView.swift`, and the arithmetic `InterfaceMetricsTests` pins is unchanged;
   - the old per-page widths go: 340 (General), 460 (catalog), and 480×300 (Language Servers, which keeps its `ScrollView` inside the page);
   - only the selected page is built now, unlike `TabView`'s eager build. The two comments that relied on the eager build are corrected: `AcknowledgementsView.documents` and the catalog tab's `onAppear` note (L27);
   - Acknowledgements' list selection resets on each visit, which is stated.
8. **The page padding and the four settings-page measurements are `ChromeGeometry` tokens.** The ticket asks for "a token of its own" for everything new, and the page padding is used by two files (General/catalog and Language Servers). Language Servers' padding moves from 20 to the page's 28.
9. **The menu field gets a height token, `menuFieldHeight` = 26.** The design draws no height for it. 26 matches the segmented control beside it on the same page, so the rows line up. It is a token of its own, not `segmentedControlHeight` reused. The Log bar keeps framing its field at its own `FilterBarLayout.controlHeight`.
10. **The stepper's eleven-point glyphs are `.subheadline`.** That is the chrome's 11. A glyph's size is a font, and `ChromeGeometry` carries none.
11. **An armable merge refusal reads as a warning.** Requirement 4 says a refusal is `statusRed` and a warning is `statusYellow`.
   - The create plan's refusal and every merge refusal the reader cannot wait out are `statusRed`.
   - The one refusal a reader can knowingly sit through (checks still running, the one behind *Merge when checks pass*) is `statusYellow`. That is read from the refusal's own `isArmable`; no view table is added.
12. **The licence text stands on `bgEditor`, under a `bgPanel` header, with a `hairline` between them.** This follows the commit dialog's diff preview. The ground is painted by SwiftUI behind the representable (`drawsBackground = false` stays). An AppKit `backgroundColor` assignment would be rule thirty-one's.
13. **`LicenseTextView.swift` is shared with iOS, and its iOS half is not swept (iOS is out of scope).** Two consequences, both stated rather than hidden:
   - the iOS half's `textView.backgroundColor = .clear` becomes a sixth pin in rule thirty-one's `pinnedBackgroundAssignments`, with its reason: a `UITextView` made clear so the screen's ground shows through, not a code pane;
   - the iOS half's `textColor = .label` is a UIKit name, which rule one's AppKit/SwiftUI list does not carry. It is recorded as an open question, not as an exemption.
14. **The origin link becomes a button.** `Link` draws the platform's link colour. It becomes a `.plain` button with an `accent` label that calls `@Environment(\.openURL)`, as part five (b) did with "Edit…".
15. **Three platform pieces stay, stated as open questions:**
   - `ProgressView` (the small spinners) — the ticket names no replacement;
   - `HSplitView`'s divider — already accepted in three gated files;
   - the Acknowledgements `List`'s platform selection.

## Context

**Files involved**

- Core:
  - `Sources/PisakaCore/ChromeGeometry.swift`: twenty-one new tokens.
- Shared shapes:
  - `Sources/Pisaka/ChromeControls.swift`
- Joining the gated set:
  - `SettingsView.swift`, `LSPServerSettingsView.swift`, `LSPInstalledLicenses.swift`, `AcknowledgementsView.swift`
  - `Platform/LicenseTextView.swift`
  - `NewPullRequestSheet.swift`, `PullRequestMergeSheet.swift`
- Already gated, touched where a requirement names them:
  - `LogFilterBar.swift` (decision 3)
  - `CommitDialogView.swift` (decision 4 and the message box)
- Tests:
  - `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`
  - `ChromeThemeTests.swift`: `testGeometryTokensCarryTheirTableValues`, `testGeometryDeclaresExactlyTheseTokensAndNoFontSize`
  - `ZoomSourceGatingTests.swift`: `testThePreferencesTerminalStepperReadsItsGridFromTheZoomRule`
  - Read only, must stay green: `InterfaceMetricsTests`, `LeetCodeAccountSourceGatingTests` (`resolveAccount(` stays in `SettingsView.swift`), `GitHubSourceGatingTests`, `LSPSourceGatingTests`
- Docs:
  - `docs/architecture/core-theme.md`, `app-shell.md`, `core-provisioning.md`, `app-ios.md`, `core-github.md`, `app-git-views.md`, `core-leetcode.md`
  - `CLAUDE.md`

**Related patterns**

- **Lifting a shape:** follow `ChromeCheckbox`, lifted from Local Changes in part five (b). The shape lives in `ChromeControls.swift`, reads `\.interfaceMetrics` and `\.chromeTheme`, and takes every measurement from a token scaled through `metrics.scaled(_:)`. Its accessibility is owed inside its own body.
- **Tab accessibility:** follow `DockTabRow.swift`: `.accessibilityValue(isSelected ? "Selected" : "Not selected")`.
- **Themed list:** `.scrollContentBackground(.hidden)` over a role background. A selectable `List` is pinned by rule thirty-five even when it sets no row background: the rule records an empty list of backgrounds for it.
- **The Settings scene root is `PisakaApp.swift`** (`.interfaceScaled(settings).chromeThemed(settings)` on `SettingsView`). So `SettingsView` and every page read `@Environment(\.chromeTheme)` as children, and rule thirty-two gains no root. The two sheets inherit the theme from `PullRequestsPanelView`, as the commit dialog does from its presenter.
- **Rule matching.**
  - Every identifier ban and presence check goes through `LSPSourceGatingTests.containsToken(_:in:)`. For example, `ChromeStepper(` must not be a hit for a `Stepper` ban, and `ChromeQueryToggle(` must not be a hit for `Toggle`.
  - A leading-dot member is matched as its bare identifier (`pickerStyle`, `tabItem`).
  - Calls are found through `callRanges(_:in:)`, so a wrapped call counts.
  - Bodies are read with `matchedBody(after:in:)` / `matchedBodies(after:in:)`.
  - The accessibility checks reuse rule twenty's `ControlBuilder` (`path`, `required`, `hidesSymbols`) and `isHiddenByItsOwnChain`.

**Dependencies:** none new.

## Development Approach

- **Testing approach:** regular (code first, then tests). The exception is Task 8, where every new rule and every new clause is first shown red against a deliberate regression, then green, and the tree is confirmed clean with `git status`.
- **Gated immediately:** a task that restyles a file adds it to `gatedFiles` in the same task, so rules one and two cover it at once.
- **Architecture entries:** read each file's `docs/architecture/` entry before modifying it.
- **No new role, no new exemption, no new font size.** Chrome text uses `InterfaceTextStyle` only.
- **Keep the code's words:** every preference label, tab title and segment title stays verbatim. The design's rewording of the tab-placement row is an open question, not a change.
- **No product or brand names** in prose, comments, docs or commit messages.
- **Derived data:** local `xcodebuild` uses `-derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-part5c`, never a path inside the repository.
- **Unattended verification only:** no task takes a screen capture or depends on a human opening a window, sheet or menu. Appearance checks go in Post-Completion.
- **CRITICAL:** every task includes new or updated tests.
- **CRITICAL:** `swift test` passes before the next task starts. A task that touches app files also builds the macOS app.

## Implementation Steps

### Task 1: Core: the new geometry tokens

**Files:**

- Modify: `Sources/PisakaCore/ChromeGeometry.swift`
- Modify: `Tests/PisakaCoreTests/ChromeThemeTests.swift`

- [x] Add twenty-one tokens, each with a one-line comment. None is derived from another; where two values coincide, the comment names the other measurement, in `barPaddingX`'s manner.
  - Segmented control:
    - `segmentedControlHeight` = 26
    - `segmentHeight` = 22
    - `segmentedControlInset` = 2
    - `segmentGap` = 2
    - `segmentPaddingX` = 12
  - Stepper:
    - `stepperHeight` = 24
    - `stepperPaddingX` = 8
    - `stepperPartGap` = 10
  - Switch:
    - `switchWidth` = 36
    - `switchHeight` = 20
    - `switchInset` = 2
    - `switchKnobSide` = 16 (its own token: the knob is not computed from the height and the inset)
  - Settings tab bar:
    - `settingsTabBarHeight` = 36
    - `settingsTabBarPaddingX` = 16
    - `settingsTabGap` = 4
    - `settingsTabLabelPaddingX` = 10
  - Settings page:
    - `settingsPagePadding` = 28
    - `settingsRowSpacing` = 22
    - `settingsLabelColumnWidth` = 180
    - `settingsLabelGap` = 16
  - Menu field:
    - `menuFieldHeight` = 26 (decision 9)
- [x] Reused tokens are not duplicated, and the comments say which is which:
  - the segmented control's outer radius is `cornerRadiusMax` and its inner radius `fieldCornerRadius`;
  - the stepper's radius is `fieldCornerRadius`;
  - the tab indicator is `accentIndicator`.
- [x] Update the type's doc comment: the inventory of insets (now including the new padding and inset tokens) and the note that the settings tab bar's measurements are deliberately not the dock tab row's.
- [x] Extend `testGeometryTokensCarryTheirTableValues` and the set-equality inventory in `testGeometryDeclaresExactlyTheseTokensAndNoFontSize`.
- [x] Run `swift test`. It must pass.

### Task 2: The shared shapes, and the Log bar as the menu field's first caller

**Files:**

- Modify: `Sources/Pisaka/ChromeControls.swift`
- Modify: `Sources/Pisaka/LogFilterBar.swift`
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`

Every shape below reads `\.interfaceMetrics` and `\.chromeTheme`, and takes every measurement from a token through `metrics.scaled(_:)`.

- [x] **`ChromeSegmentedControl<Value: Hashable>`**
  - Takes a spoken label, `options: [(value: Value, title: String)]` and a `Binding<Value>`.
  - Outer box: a `bgEditor` ground, a `hairline` border at `cornerRadiusMax`, `segmentedControlInset` padding, `segmentGap` between segments, and `segmentedControlHeight` tall.
  - Each segment is a `.plain` `Button` that is `segmentHeight` tall with `segmentPaddingX` around a `.callout` label.
  - Selected segment: an `accentTintStrong` fill at `fieldCornerRadius` and a `textPrimary` label. Others: no ground and a `textSecondary` label.
  - Accessibility: the control is `.accessibilityElement(children: .contain)` with `.accessibilityLabel(label)` and `.accessibilityValue(<selected title>)`. Each segment speaks its selection as a value.
- [x] **`ChromeStepper`**
  - Takes a spoken label, a `Binding<Double>`, a `ZoomScaleRule` and a value formatter (for example `"\(Int(v)) pt"`).
  - Box: a `bgEditor` ground, a `hairline` border at `fieldCornerRadius`, `stepperPaddingX` horizontal padding, `stepperPartGap` between its parts, and `stepperHeight` tall.
  - Parts: minus, value, plus.
  - The value is `.callout` in `textPrimary`.
  - The two glyph buttons come from one `private func stepButton(` builder:
    - the glyph is `textSecondary`, carries its own `.font(metrics.scaledFont(.subheadline))` (decision 10) and its own `.accessibilityHidden(true)`;
    - the button is `.plain` and carries `.accessibilityLabel("Decrease …")` / `("Increase …")`;
    - the button writes `rule.stepped(value, by: ∓1)` and is disabled when that answer equals the value.
  - The whole control also carries `.accessibilityLabel`, `.accessibilityValue` and an `.accessibilityAdjustableAction` that goes through the same `stepped(_:by:)`.
- [x] **`ChromeSwitch`**
  - Takes a spoken label and a `Binding<Bool>`.
  - A `switchWidth` × `switchHeight` `Capsule` track: `accent` when on, `hairline` when off, with `switchInset` padding.
  - A `switchKnobSide` circle knob in `onAccent`, leading when off and trailing when on.
  - It is a `.plain` `Button`, dims when disabled, and carries `.accessibilityLabel(label)` and `.accessibilityValue(isOn ? "On" : "Off")`.
  - The doc comment states why it is not the checkbox:
    - a preference that is on or off is a switch; one selection among many is a checkbox;
    - two meanings, two shapes, and neither is folded into the other.
- [x] **`ChromeSettingsTabBar<Tab: Hashable>`**
  - Takes `tabs: [(tab: Tab, title: String)]` and a `Binding<Tab>`.
  - `settingsTabBarHeight` tall on `bgPanel`, with `settingsTabBarPaddingX` inset and `settingsTabGap` between tabs.
  - Each tab is a `.plain` `Button` with `settingsTabLabelPaddingX` around a `.callout` semibold label: `textPrimary` when active, `textSecondary` otherwise.
  - The active tab carries an `accent` indicator of `accentIndicator` thickness across its full width, drawn at its bottom.
  - The strip's `hairline` bottom rule is drawn with `.background(alignment: .bottom)`, never as an overlay.
  - Each tab has `.accessibilityValue(isSelected ? "Selected" : "Not selected")`.
  - The doc comment says why this is not the dock's tab row:
    - it has no close action, a different height and a different inset;
    - it shares the indicator thickness and the behind-the-tabs rule.
- [x] **`ChromeMenuField<Value: Hashable>`**, lifted from `LogFilterBar.refPicker` (decision 3):
  - Takes a spoken label, `options: [(value: Value, title: String)]`, a `Binding<Value>` and the title shown for the current value.
  - Structure: a `ChromeControlBox`, a `Menu` with `.menuStyle(.borderlessButton)` and `.menuIndicator(.hidden)`, and a `.callout` `textPrimary` single-line label.
  - The Log bar's `textSecondary` `chevron.down` moves here, hidden by its own chain.
  - Each option is a `Button`, and the chosen one's label is `Label(title, systemImage: "checkmark")`.
  - The field carries `.accessibilityLabel(label)` and `.accessibilityValue(<current title>)`.
  - The caller supplies the height and the width limits.
- [x] **State the picker rule in the file's doc comment**, where the shapes are defined:
  - a choice over a fixed, small, closed set is a `ChromeSegmentedControl`;
  - a choice over a dynamic or long list is a `ChromeMenuField`;
  - a segmented control whose segment count is unknown at build time is the wrong shape, because it cannot be laid out.
- [x] Also update the file's header paragraph to list the new shapes.
- [x] **`LogFilterBar.refPicker`** becomes a `ChromeMenuField` over `"All"` plus `uniqueReferences`:
  - selection goes through the existing `refSelectionBinding`, so the `displayRefTag` / `selectRef(tag:)` seam is unchanged;
  - it keeps its frame (`FilterBarLayout.controlHeight`, `branchMinWidth` / `branchMaxWidth`), help and label;
  - delete the private `chevron` if nothing else in the file uses it.
  - Afterwards the file spells neither `Picker` nor `pickerStyle`.
- [x] Update the suite:
  - **Rule twenty-four:** `menuFiles` gains `ChromeControls.swift`. `LogFilterBar.swift` leaves it if no `Menu` remains there; the comment says why.
  - **Rule twenty's `panelControlBuilders`**, under `ChromeControls.swift`:
    - `struct ChromeSegmentedControl`: requires `.accessibilityLabel(` and `.accessibilityValue(`;
    - `struct ChromeStepper`: requires `.accessibilityLabel(`, `.accessibilityValue(` and `.accessibilityAdjustableAction(`;
    - `struct ChromeStepper` → `private func stepButton(`: requires `.accessibilityLabel(`, `hidesSymbols: true`;
    - `struct ChromeSwitch`: requires `.accessibilityLabel(` and `.accessibilityValue(`;
    - `struct ChromeSettingsTabBar`: requires `.accessibilityValue(`;
    - `struct ChromeMenuField`: requires `.accessibilityLabel(` and `.accessibilityValue(`, `hidesSymbols: true`.
  - **Rule sixteen:** `indicatorStripFiles` becomes a list of `(file, declaration?)`. The existing two stay whole-file. `("ChromeControls.swift", "struct ChromeSettingsTabBar")` is scoped to that struct's brace-matched body, so another shape's background in the same file cannot satisfy it.
- [x] Run `swift test` and the macOS build. Both must pass. Rules twenty-one and thirty-four must stay green over the Log bar.

### Task 3: The two carry-overs in the commit dialog

**Files:**

- Modify: `Sources/Pisaka/CommitDialogView.swift`
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`

- [x] **The message box follows the code zone.**
  - Replace `.frame(minHeight: 70, maxHeight: 120)` with a height counted in lines of the code font. Add a private `messageLineHeight`: the default line height of `NSFont.monospacedSystemFont(ofSize: settings.fontSize, weight: .regular)`, read through `NSLayoutManager().defaultLineHeight(for:)`.
  - The minimum and maximum are named private line counts, 4 and 7, chosen so the default code size lands near today's 70–120.
  - The box's padding stays interface-scaled chrome.
  - Rewrite the doc comment: the old one claimed the height was "off the interface scale" but it followed no zone at all, so the text grew while the box stood still.
- [x] **`AuthorEditorView` loses its `Form`** (decision 4):
  - two `ChromeThemedTextField`s ("Name", "Email") stacked with the existing spacing, 360 wide as before;
  - a private focus enum;
  - `isUsable` and the Save/Cancel behaviour unchanged.
- [x] **Rule twenty-seven gains a clause.** `CommitDialogView.swift`'s `private var messageBox` brace-matched body:
  - every `.frame(` argument list in it names the `messageLineHeight` token;
  - none names `metrics`.
- [x] Run `swift test` and the macOS build. Both must pass. `sharedFieldConstructors` is unchanged, because `CommitDialogView.swift` is already in it.

### Task 4: The Preferences window: host, General and the problem-catalog tab

**Files:**

- Modify: `Sources/Pisaka/SettingsView.swift`
- Modify: `Tests/PisakaCoreTests/ZoomSourceGatingTests.swift`
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`

- [x] **Host.**
  - A private four-case enum in today's order: General, Language Servers, the catalog tab, Acknowledgements. The titles are the existing ones, verbatim.
  - `@State` holds the selection, starting on General.
  - The body is a `VStack(spacing: 0)`: a `ChromeSettingsTabBar`, then the selected page framed at the one page size (decision 7), on `bgPanel`.
  - `TabView`, `tabItem` and the tab icons are deleted.
  - Rewrite the doc comment, which described the `TabView` sizing.
- [x] **One private `SettingsRow` view**, the design's layout:
  - an `HStack` holding a label column `settingsLabelColumnWidth` wide, `.callout` in `textSecondary`, which may wrap (`.fixedSize(horizontal: false, vertical: true)`) and is never clipped;
  - `settingsLabelGap` to the control;
  - the control at its natural width with a trailing `Spacer`.
  - A page stacks rows with `settingsRowSpacing` and pads by `settingsPagePadding`.
  - Where a row's control is one of the shared shapes, the control speaks the row's label and the label column is hidden from accessibility, so the name is read once. A composite row keeps its label readable.
- [x] **General:**
  - "Tab orientation" → `ChromeSegmentedControl` (Vertical, Horizontal).
  - "Theme" → `ChromeSegmentedControl` (System, Light, Dark).
  - "Editor font size" → `ChromeStepper` over `ZoomScaleRule.editorFont`.
  - "Terminal font size" → `ChromeStepper` over `ZoomScaleRule.terminalFont`.
  - Both steppers show `"<n> pt"`.
  - The two editor flags → `ChromeSwitch`, labelled with their existing sentences.
  - Keep the existing comments on each row, adjusted where they named `Stepper` or `Toggle`.
- [x] **The catalog tab (`LeetCodeSettingsView`)**, with its Form sections dissolved into three rows:
  - **Account row:**
    - the description is `textPrimary` when signed in and `textSecondary` otherwise;
    - Sign In… / Sign Out use `.chromeSecondary`;
    - `lastError` is `.caption` in `statusRed`.
  - **Solution-files row:**
    - the path is `textPrimary`, or `textSecondary` when none is chosen, with its middle-truncation and help kept;
    - Change… uses `.chromeSecondary`.
  - **Default language row:** a `ChromeMenuField` over `offerableLanguages` by `displayName`, framed at `menuFieldHeight`.
  - The rest is unchanged: `resolveAccount()` on appear (its comment corrected per decision 7), the sign-in sheet, `LeetCodeFolderChooser`.
- [x] **Re-point the zoom suite's stepper test** as `testThePreferencesStepperReadsItsGridFromTheZoomRule`:
  - `SettingsView.swift`'s `ChromeStepper(` call bound to `$settings.terminalFontSize` names `ZoomScaleRule.terminalFont`, and the one bound to `$settings.fontSize` names `ZoomScaleRule.editorFont`, each read inside that call's brace-matched argument list;
  - `ChromeStepper`'s body in `ChromeControls.swift` spells the `stepped` token;
  - it no longer asserts `.minimum` / `.maximum` / `.step` at the call site.
- [x] Add `SettingsView.swift` to `gatedFiles`, and add `SettingsView.swift` to rule thirty's `chromeSecondary` callers.
- [x] Run `swift test` and the macOS build. Both must pass. `LeetCodeAccountSourceGatingTests` must stay green.

### Task 5: Language Servers and the installed licences

**Files:**

- Modify: `Sources/Pisaka/LSPServerSettingsView.swift`
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`

- [x] **Page.**
  - The `ScrollView` fills the page frame. The 480×300 frame and the inner 480 width are deleted, and the doc comment's sizing paragraph is rewritten: the page scrolls because failure sentences are unbounded, and the host now fixes the size.
  - Padding is `settingsPagePadding` (decision 8).
  - The intro and the three footnotes are `textSecondary`.
- [x] **Rows container:**
  - `bgEditor` instead of `textBackgroundColor`;
  - clipped and bordered at `cornerRadiusMax`;
  - the border is `hairline` at `hairlineWidth` instead of `separatorColor`.
- [x] **The three `Divider()`s** (the `index > 0` separator run and the two around the toolchain rows) become horizontal `hairline` rules at `hairlineWidth`.
- [x] **Each of the three row builders:**
  - the name is `textPrimary`;
  - the component id, status and runtime note are `textSecondary`;
  - a failure is `statusRed`;
  - Install / Retry / Remove use `.chromeSecondary`;
  - `ProgressView` stays (decision 15).
- [x] Add `LSPServerSettingsView.swift` and `LSPInstalledLicenses.swift` to `gatedFiles`, and add `LSPInstalledLicenses.swift` to `roleNamingExemptions` with decision 2 in the comment.
- [x] Add `LSPServerSettingsView.swift` to rule thirty's `chromeSecondary` callers.
- [x] Run `swift test` and the macOS build. Both must pass. `LSPSourceGatingTests` must stay green.

### Task 6: Acknowledgements and the licence pane

**Files:**

- Modify: `Sources/Pisaka/AcknowledgementsView.swift`
- Modify: `Sources/Pisaka/Platform/LicenseTextView.swift`
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`

- [x] **Failure state:**
  - the glyph is `textSecondary`, keeps its scaled font and is hidden by its own `.accessibilityHidden(true)`;
  - the sentence is `textSecondary`.
- [x] **The list:**
  - `.scrollContentBackground(.hidden)` on `bgPanel`, with platform selection and no `listRowBackground`;
  - section headers become `Section { … } header: { Text(…) }` in `textSecondary`;
  - a row's name is `textPrimary` and its SPDX line `textSecondary`.
- [x] **The detail pane:**
  - the header is on `bgPanel`: name `textPrimary`, SPDX `textSecondary`, `LabeledField` labels `textSecondary` and values `textPrimary`;
  - the origin becomes a `.plain` button with an `accent` label calling `openURL` (decision 14);
  - the `Divider()` becomes a horizontal `hairline` rule;
  - `LicenseTextView` is backed by `bgEditor` (decision 12);
  - "Select a dependency." is `textSecondary`.
- [x] The 640×420 frame moves to the host (Task 4), and the page fills it. Update the comments that named the `TabView`.
- [x] **`LicenseTextView.swift`, macOS half:**
  - `textColor = ChromePalette.nsColor(.textPrimary)` instead of `.labelColor`. A dynamic colour needs no appearance bracket; one line says so.
  - Correct the header comment that calls `Platform/` non-gated for this file.
  - The iOS half is untouched (decision 13).
- [x] Add `AcknowledgementsView.swift` and `LicenseTextView.swift` to `gatedFiles`.
- [x] **Rule thirty-five:** pin `"AcknowledgementsView.swift": [[]]`, one selectable list with no row background, with a comment saying the platform draws the selection.
- [x] **Rule thirty-one:** add `"LicenseTextView.swift": (1, …)` with decision 13's reason.
- [x] Run `swift test` and the macOS build. Both must pass. `InterfaceMetricsTests`' Acknowledgements arithmetic is unchanged and must stay green.

### Task 7: The two pull-request sheets

**Files:**

- Modify: `Sources/Pisaka/NewPullRequestSheet.swift`
- Modify: `Sources/Pisaka/PullRequestMergeSheet.swift`
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`
- Modify: `docs/architecture/core-theme.md` (only rule twenty-six's two file-set passages, which `testTheCanonicalListsFileSetsAreTheSuitesOwn` reads)

- [x] **Both sheets:**
  - `bgPanel` ground; title `textPrimary`;
  - plan sentences `textSecondary`;
  - the message slot (`createMessage` / `mergeMessage` / `unavailableMessage`) `statusRed`;
  - refusals per decision 11;
  - the reading line `textSecondary`;
  - Cancel `.chromeSecondary`, Create / Merge `.chromePrimary`, with shortcuts and disabled rules unchanged.
- [x] **The text areas.** The title and the merge subject become `ChromeThemedTextField` with a private focus enum each, at `.body`. The two `TextEditor`s are wrapped in `ChromeControlBox`, following the commit dialog's message box:
  - `.scrollContentBackground(.hidden)` and `textPrimary`;
  - their own focus;
  - the existing interface-scaled heights (140 and 110);
  - the `Color.secondary.opacity(0.35)` overlays deleted.
- [x] **The create sheet's controls:**
  - Base → `ChromeMenuField`, framed at `menuFieldHeight` and `maxWidth` 280, keeping the `"—"` empty state as an option only while `base` is empty, and `onChange` → `setCreateBase`;
  - Draft → `ChromeCheckbox` titled "Draft" (decision 5).
- [x] **The merge sheet:** Method → `ChromeSegmentedControl` over `plan.allowedMethods` with `methodLabel` titles (decision 6), still shown only when `plan.showsMethodPicker`.
- [x] Add both files to `gatedFiles`.
- [x] **Rule twenty-six:** `sharedFieldConstructors` gains both sheets, and its message is updated. Update the two passages in `core-theme.md` that enumerate that set in the same task, so the file-set check stays green.
- [x] **Rule thirty's pinned callers:**
  - `chromePrimary`: + both sheets;
  - `chromeSecondary`: + both sheets;
  - `ChromeCheckbox`: + `NewPullRequestSheet.swift`.
- [x] Run `swift test` and the macOS build. Both must pass. `GitHubSourceGatingTests` must stay green.

### Task 8: The new rules and the carried convention sentence, each rule shown red first

**Files:**

- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`
- Modify: `docs/architecture/core-theme.md` (canonical list items 36–37 and the convention sentence)
- Modify: `CLAUDE.md` (the rule count only)

- [x] **Rule thirty-six: no gated file builds a platform form control.**
  - No gated file spells any of these tokens: `Form`, `Picker`, `pickerStyle`, `Stepper`, `Toggle`, `TabView`, `tabItem`.
  - Match through `containsToken`. `pickerStyle` and `tabItem` are bare because of the leading-dot reason.
  - The comment names the two surfaces swept to make this green (decision 4) and states that `Toggle` overlaps rule thirty on purpose, so the family is listed whole in one place.
- [x] **Rule thirty-seven: a picker's shape follows its set, and each settings shape has its pinned callers.**
  - The files spelling each token are pinned by set equality, the defining file included:
    - `ChromeSegmentedControl`: `ChromeControls`, `SettingsView`, `PullRequestMergeSheet`;
    - `ChromeMenuField`: `ChromeControls`, `LogFilterBar`, `SettingsView`, `NewPullRequestSheet`;
    - `ChromeStepper`: `ChromeControls`, `SettingsView`;
    - `ChromeSwitch`: `ChromeControls`, `SettingsView`;
    - `ChromeSettingsTabBar`: `ChromeControls`, `SettingsView`.
  - The comment states the picker rule and that the two sets together are its whole expression: a segmented base-branch list, or a switch where a checkbox belongs, moves a file between sets.
- [x] **Rule thirty gains part five (c)'s styled-button table:** each of the seven files' `Button` count equals its `buttonStyle` count and its stated number. Expected today:
  - `SettingsView` 2 — the tree's actual count is 3 (Sign In…, Sign Out and Change…), stated as 3 (the account row builds one of Sign In… / Sign Out conditionally, but both are spelled; state the tree's actual count);
  - `LSPServerSettingsView` 6;
  - `AcknowledgementsView` 1;
  - `NewPullRequestSheet` 2;
  - `PullRequestMergeSheet` 2;
  - `LSPInstalledLicenses` 0;
  - `LicenseTextView` 0.
  - Each number is confirmed against the tree before it is written.
- [x] **Carried item 9a.** In both places the convention appears (the suite's closing header paragraph and `core-theme.md` beside the rules), add one sentence: thirty-four is the third shape — a balanced region per link, then a token assertion inside it — which is why "no rule is excepted from the three" holds.
- [x] Extend `spelled` to thirty-seven. Add header bullets for rules thirty-six and thirty-seven, titled as their markers. Add canonical items 36–37 to `core-theme.md`, and set `CLAUDE.md`'s count to "thirty-seven", so the four count checks agree.
- [x] **Mutation-verify every new rule and every new clause.** For each regression below, confirm it is red, then revert:
  - **Rule thirty-six**, using the guarded files' real formatting:
    - a `Picker(` wrapped across lines in `SettingsView`;
    - `Form {` in `AuthorEditorView`;
    - a `Stepper(`, a `TabView {`, a `.tabItem {` and a `.pickerStyle(.inline)` in a gated file.
    - Also confirm that `ChromeStepper(` and `ChromeQueryToggle(` are not hits as the tree stands.
  - **Rule thirty-seven:**
    - the base branch built as `ChromeSegmentedControl`;
    - Draft built as `ChromeSwitch`;
    - `ChromeMenuField` removed from `SettingsView`.
  - **Rule twenty:**
    - `.accessibilityValue(` deleted from `ChromeSwitch`;
    - `.accessibilityLabel(` deleted from `stepButton(`;
    - the stepper glyph's `.accessibilityHidden(true)` moved to its enclosing `HStack` (the later-sibling regression);
    - the tab bar's value deleted.
  - **Rule sixteen:** the tab bar's rule moved to `.overlay(alignment: .bottom)`, and confirm that another shape's bottom background in `ChromeControls.swift` does not satisfy it.
  - **Rule twenty-seven:** `.frame(minHeight: 70, maxHeight: 120)` restored in `messageBox`, and a wrapped `.frame(\n minHeight: metrics.scaled(70)`.
  - **Rule thirty:** an unstyled `Button("Remove")` in `LSPServerSettingsView`, and a `.buttonStyle(.bordered)`.
  - **Rule thirty-five:** a `listRowBackground` added to the Acknowledgements list.
  - **Rule thirty-one:** a second `backgroundColor =` in `LicenseTextView`.
  - **Rule one:** `.labelColor` restored in `LicenseTextView`.
- [x] Confirm `git status` is clean apart from the intended changes.
- [x] Run `swift test`. It must pass.

### Task 9: Verify acceptance criteria

- [ ] Run `swift test`. It must pass.
- [ ] Run `xcodegen generate`, then run the app bundle with `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-part5c test`. It must pass.
- [ ] Run `swiftlint --strict` from the repository root. It must report zero violations.
- [ ] Build macOS Release (`-configuration Release`) and iOS (`generic/platform=iOS`), both with derived data under `~/Library/Developer/Xcode/DerivedData/`.
- [ ] Grep-confirm the remaining acceptance points:
  - `gatedFiles` holds 51 files;
  - no gated file spells `Divider(`;
  - no new `ChromeColorRole` case exists;
  - `currentLine` and `bracketMatch` have no reader outside the palette;
  - the rule count reads thirty-seven in the markers, the header, `core-theme.md` and `CLAUDE.md`.

### Task 10: Documentation

- [ ] **`docs/architecture/core-theme.md`:**
  - a part five (c) section:
    - the five shapes (four new, one lifted) and their measurements;
    - why a switch is not a checkbox;
    - the picker rule and its two answers;
    - why the settings tab bar is not the dock's;
    - decisions 1–15;
    - every departure from the drawing: the fourth tab, the 640×420 page, the menu field's height, the `.subheadline` glyph, Language Servers' padding.
  - rules sixteen, twenty, twenty-four, twenty-six, twenty-seven, thirty, thirty-one and thirty-five updated to their new clauses and pins;
  - the swept-surfaces list extended;
  - open questions: the tab-placement wording, the spinners, `HSplitView`, the iOS half's `.label`, the list's platform selection.
- [ ] **Per-surface entries:**
  - `app-shell.md`: `SettingsView.swift` (the host, the tab bar and the pages; `TabView` gone), `AcknowledgementsView.swift`;
  - `core-provisioning.md`: `LSPServerSettingsView.swift` (no fixed size; the page scrolls), `LSPInstalledLicenses.swift` (gated, paints nothing);
  - `app-ios.md`: `LicenseTextView.swift` (the macOS half's role; the iOS half unchanged);
  - `core-github.md`: both sheets (the menu field, the segmented method, Draft as a checkbox, decision 11);
  - `app-git-views.md`: the commit dialog's message box and author editor, and the Log bar's lifted menu;
  - `core-leetcode.md`: the settings tab's rows and the corrected `onAppear` note, spelled as that document already spells it.
- [ ] **`CLAUDE.md`:**
  - the chrome invariant: thirty-seven rules, fifty-one files, and part five (c)'s surfaces added to the swept list;
  - the new rule summaries (no platform form control; a picker's shape follows its set);
  - the `ChromeControls.swift` index line names the new shapes;
  - the three-space indentation on the resize-cursor lines corrected to two.
- [ ] Run `swift test` once more, since the documentation checks read these files.

## Post-Completion

These items need a running app and a person; they are not automatable.

- Open Preferences in the light and dark appearances. Change the Theme preference while the window is open, and confirm that the tab bar, all four pages, the switches, the steppers and the segmented controls follow it.
- Open both pull-request sheets from the Pull Requests panel and check both appearances.
- Step the interface zoom to 200% and confirm that no label in a settings row is clipped, and that the commit message box grows with the code font.
- Read out Preferences with VoiceOver: each control speaks its name once and its value, and the stepper's two buttons are named actions.
