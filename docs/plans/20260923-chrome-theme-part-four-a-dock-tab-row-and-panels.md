# Chrome theme, part four (a): the dock's own tab row, and the Problems, Usages and Terminal panels

## Overview

Give the bottom dock the tab row the design states: one row across the top of the dock that names the panel on screen and offers the other five. Then move three panels' interiors onto the chrome roles and tokens: Problems, Usages and the Terminal panel's host. The row is drawn once, inside the dock's fixed-height slot. It changes nothing about the dock's height arithmetic, its divider, its drag or its clip. A click on a tab goes through the funnel the bar's toggles already use, and that funnel also creates the first terminal session, so `PisakaApp.swift` is not touched. The panels' names and their order become one Core table. The tab row reads it, and so do the bar's toggles; that is how "Git" and "Changes" become "Log" and "Local Changes". The severity-to-role mapping the gutter already draws with moves into Core as the one answer, and the Problems panel reads it too, rather than keeping a second table. No palette value changes. Four files join `ChromeThemeSourceGatingTests.gatedFiles`, one of them new. The suite grows from eleven rules to fifteen. `ChromeGeometry` gains four tokens and spends two it already declared.

## Context

Files involved:
- Modify: `Sources/PisakaCore/BottomPanel.swift`: `CaseIterable`, the one name per panel, the tab rule and its own answer type.
- Modify: `Sources/PisakaCore/ChromeColorRole.swift`: `diagnosticRole(for:)`, moved here from the ruler.
- Modify: `Sources/PisakaCore/ChromeGeometry.swift`: four tokens.
- Create: `Sources/Pisaka/DockTabRow.swift`: the dock's tab row.
- Modify: `Sources/Pisaka/ContentView.swift`: hosts the row inside `panelContent(_:)`; the toggles read their titles from Core.
- Modify: `Sources/Pisaka/LineNumberRulerView.swift`: loses its own mapping and calls Core's.
- Modify: `Sources/Pisaka/ProblemsPanelView.swift`, `Sources/Pisaka/UsagesPanelView.swift`, `Sources/Pisaka/TerminalPanelView.swift`.
- Tests: `Tests/PisakaCoreTests/BottomPanelTests.swift`, `ChromeThemeTests.swift`, `ChromeThemeSourceGatingTests.swift`, `BottomPanelSourceGatingTests.swift`; `Tests/PisakaAppTests/GutterFoldTests.swift`.
- Docs: `docs/architecture/core-theme.md`, `app-window.md`, `app-terminal.md`, `app-editor-overlays.md`, `core-services.md`, `CLAUDE.md`.

Related patterns:
- Part three's widgets read `@Environment(\.chromeTheme) private var theme` beside `\.interfaceMetrics` and spell `theme.color(.role)`. A panel never names `ChromeTheme` (gating rule five).
- Part two's breadcrumb and part three's bar and dividers: a surface draws its own one-point `hairline` rectangle as an `.overlay(alignment:)` on the edge it owns. It does not use a `Divider()`.
- `TabStripView.swift` spends `ChromeGeometry.accentIndicator` for its active-tab underline. The dock row spends the same token.
- Gating rule ten reads brace-matched bodies with `matchedBody(after:in:)` and counts with `occurrences(of:in:)`. The new rules reuse both helpers.
- Part three's bar keeps its gaps as bare local numbers scaled once, because gating rule seven forbids deriving them from a token.

Dependencies: none.

## Measured facts that shape the plan

- `PisakaApp.swift` is exactly at its `file_length` ceiling (1893), so any added non-comment line fails `swiftlint --strict`. `ContentView.onTogglePanel` reaches `PisakaApp.togglePanel(_:)`, which already creates the first terminal session when the terminal is about to be shown. The row reuses that funnel and adds no line to the scene file.
- `BottomPanel`'s six cases are already declared in the bar's order: terminal, log, changes, problems, usages, pullRequests. `CaseIterable` therefore yields the row's order with no second list.
- `BottomPanelSourceGatingTests.testPanelContentStatesNoMinimumHeight` reads `panelContent(_:)`'s body and its `switch` labels. `testThePanelSlotIsTopAligned` pins the `panelContent(panel).frame(height:…, alignment: .top)` call. Putting the row inside `panelContent(_:)`, above its `switch`, leaves both pins and the clip byte-identical.
- `ChromeThemeSourceGatingTests` declares eleven rules. Its `spelled` table ends at twelve, so fifteen needs three more entries. The count is cross-checked against `core-theme.md`'s canonical list and `CLAUDE.md`'s invariant sentence, so every added rule is a three-place edit that the suite enforces.
- `InterfaceTextStyle.caption` is 10 points. These files draw four labels at 10 points and one glyph at 8, not the two labels the ticket counts (see decision 7).
- `LineNumberRulerView.diagnosticRole(for:)` already maps the closed severity set to four roles: error → `statusRed`, warning → `statusYellow`, information → `accent`, hint → `textSecondary`. The gutter's dots draw from it. The Problems panel's badges and glyphs are the last chrome readers of `SyntaxTheme.diagnosticColor(for:)`. Its only other reader is the squiggle under the text, through `nsDiagnosticColor(for:)`.
- A correction to the premise that the mapping has never had a test: the app bundle's `GutterFoldTests.testEverySeverityResolvesToItsRole` pins it, along with the four resolved colours being pairwise distinct under both appearances. What it has never had is a test in the Core gate, and that is what this part adds.

## Decisions made where the ticket is silent, and one discrepancy reported

1. **The row lives in its own file**, `DockTabRow.swift`. This follows the precedent of the breadcrumb and the tab strip, each of which is "its own file so it can be gated". It is called once, from `ContentView.panelContent(_:)`. Swift's `internal` access cannot stop a panel file from naming it, so gating rule twelve pins reachability instead: `DockTabRow(` is spelled only in its own file and in `ContentView.swift` (exactly once there), and the six hosted panel files never name it.
2. **The seventh tab is left out.** It names a panel this application does not have, and a tab that does nothing when clicked is a defect, not a placeholder. This decision is recorded in `core-theme.md` (requirement 2).
3. **One name per panel, as one Core table.** `BottomPanel.title` returns "Terminal", "Log", "Local Changes", "Problems", "Usages" and "Pull Requests". `bottomBarButton` loses its `title:` parameter and reads `panel.title`, so the tab and the tooltip cannot disagree.
   - The View menu's item titles ("Show Git Log" and the others) are left alone because menu titles belong to the part that sweeps menus, which is out of scope here. That is the reason recorded in the plan and in `core-theme.md`.
   - `PisakaApp.swift`'s line ceiling is not the reason: editing a string literal in place adds no line.
4. **A tab click is one Core rule, with an answer type of its own.** The rule is `BottomPanel.tabActivation(_ current: BottomPanel?, tab: BottomPanel) -> DockTabActivation`, where `public enum DockTabActivation: Equatable, Sendable { case show(BottomPanel); case alreadyShowing }` is declared in `BottomPanel.swift`.
   - The type's doc says why it is not another `BottomPanel?`. `toggled(_:selecting:)` already returns a `BottomPanel?` whose `nil` means "collapse". A sibling whose `nil` meant "nothing to do" could have its answer handed to `toggled`'s `current:` parameter and compile, reading "nothing to do" as "no panel showing".
   - With a distinct type, that mistake is a compile error. It is not a test's job.
   - `ContentView` calls `onTogglePanel(target)` only on `case .show(let target)`. `toggled` then yields the target and never collapses.
   - The close action calls `onTogglePanel(panel)` with the showing panel, which `toggled` collapses. Both paths go through the one funnel (requirement 4).
5. **Close alone.** Minimise and close would perform the same action on a dock that has one state, so only close is drawn. The glyph is `xmark`. This decision is recorded in `core-theme.md` (requirement 5).
6. **New tokens:**
   - `panelHeaderHeight` = 28
   - `panelHeaderPaddingX` = 14
   - `dockTabRowPaddingX` = 10: the row's inset
   - `dockTabLabelPaddingX` = 10: a label's box, a distinct measurement from the row's inset, following the argument in `barPaddingX`'s comment

   Two existing tokens are spent: `dockTabRowHeight` and `accentIndicator`. The gaps (2 and 10 in the row, 8 in a panel header) and every number that belongs to one panel stay local, in one `private enum <Surface>Layout` per file whose doc comment says so. Row insets inside a hover highlight spend `rowPaddingX`, which is that token's stated meaning.
7. **Discrepancy reported: the ticket's font count.** Requirement 10 says only Usages' two 10-point labels move. The files also carry three more off-scale sizes:
   - `ProblemRow`'s `:line` (`.caption`, monospaced)
   - `UsageRow`'s line number (`.caption`, monospaced)
   - the terminal session tab's close glyph (`.system(size: 8, weight: .bold)`)

   By the tier rule, the two monospaced details take `.subheadline` (11). The glyph takes `.subheadline` at bold weight so it matches the label beside it. All three move, and the plan reports this rather than resolving it silently. Every size already on the scale stays. Headers change from `.headline` (13) to `.body` semibold (13), which is the same size under the chrome's own style name.
8. **One severity answer, in Core.** `LineNumberRulerView.diagnosticRole(for:)` moves unchanged to `Sources/PisakaCore/ChromeColorRole.swift` as `public static func diagnosticRole(for severity: DiagnosticSeverity) -> ChromeColorRole`. Both types already live in Core.
   - The ruler's copy is deleted. The gutter's dot and the Problems panel's header badges and row glyphs all call `ChromeColorRole.diagnosticRole(for:)`.
   - The function's doc comment moves with it. It keeps the reasoning for information → `accent` and hint → `textSecondary`, and keeps why this is deliberately not `SyntaxTheme`'s table. It now also names who reads it: the gutter's severity dot and the Problems panel's badges and glyphs.
   - Only the squiggle under the text stays on `SyntaxTheme.diagnosticColor(for:)`, because the squiggle is the code zone.
   - `ProblemsPanelView`'s "three surfaces, one palette" comment, and its file header's "`SyntaxTheme`'s severity color", are corrected to say there are two tables and which surface is on which: the gutter and the panel are chrome and read the role, and the squiggle is code and reads `SyntaxTheme`.
   - Gating rule fifteen keeps a second table from coming back.
9. **The terminal session strip is its panel's header strip.** It spends `panelHeaderHeight` and draws its hairline along its bottom edge. The selected session tab takes `accentTintStrong` at `cornerRadiusMax`, which that token's comment names as the chrome's one radius. The `+` and `xmark` glyphs take `textSecondary` explicitly, because a borderless button would otherwise tint them itself.
10. **Accessibility.** Each tab is a `Button` with `.accessibilityLabel(panel.title)` and `.accessibilityValue(isSelected ? "Selected" : "Not selected")`. The indicator strip is `.accessibilityHidden(true)`. The close action carries `.help("Close panel")` and `.accessibilityLabel("Close panel")`, so its glyph is not what names it. Rule thirteen pins this.
11. **Four new gating rules.** The suite goes from eleven to fifteen rules and from sixteen to twenty gated files:
   - Rule twelve: the tab row is configured in one place.
   - Rule thirteen: every dock tab and the close action carry a name, and the tab carries a spoken value.
   - Rule fourteen: no `Divider()` in the dock's swept files. The list starts with the tab row, Problems, Usages and Terminal, and part four (b) extends it.
   - Rule fifteen: the severity mapping is Core's one answer.
     - No app file declares `func diagnosticRole`.
     - The set of app files spelling `diagnosticRole(for:` equals `{"LineNumberRulerView.swift", "ProblemsPanelView.swift"}`.
     - `ProblemsPanelView.swift` names no `SyntaxTheme`.

   Rule eleven's list of files with fixed-height strips grows to include the four new fixed-height surfaces. Each of them sets a strip's height with a frame and must therefore spell `.lineLimit(1)`.
12. **Sixteen surfaces swept** after this part: part three's twelve, plus the dock tab row, Problems, Usages and the Terminal host.

## Development Approach

- **Testing approach**: Regular (code first, then tests), following the sweep guide's order: restyle, add the file to `gatedFiles`, then run the gates.
- Complete each task fully before moving to the next.
- A file joins `gatedFiles` in the same task that restyles it.
- A task that adds a gating rule updates three places in that same task: `core-theme.md`'s canonical list, `CLAUDE.md`'s rule-count sentence and the suite's `spelled` table. The suite fails otherwise.
- Builds go to `~/Library/Developer/Xcode/DerivedData/pisaka-chrome-part-four-a`, never inside the repository.
- No product or brand names in code, comments, documents or commit messages.
- **CRITICAL: every task MUST include new/updated tests**
- **CRITICAL: all tests must pass before starting next task**

## Implementation Steps

### Task 1: Core: one name per panel, the tab rule, and four tokens

**Files:**

- Modify: `Sources/PisakaCore/BottomPanel.swift`
- Modify: `Sources/PisakaCore/ChromeGeometry.swift`
- Modify: `Tests/PisakaCoreTests/BottomPanelTests.swift`
- Modify: `Tests/PisakaCoreTests/ChromeThemeTests.swift`

- [x] make `BottomPanel` `CaseIterable`. Document that the declaration order is the order of the bar's toggles and of the dock's tab row, and that neither keeps a second list.
- [x] add `public var title: String` with the six names from decision 3. Document it as the one name per panel that both the tooltip and the tab read.
- [x] add `DockTabActivation` and `tabActivation(_:tab:)` from decision 4.
  - The rule's doc says a tab selects and never collapses, and that collapsing belongs to the bar's toggle and the row's close action.
  - The type's doc says why it is not a second `BottomPanel?` (the opposite meanings of `nil`).
- [x] update the enum's doc comment ("Git Log" → "Log") so the prose uses the table's names.
- [x] tests:
  - `allCases` equals the six cases in the bar's order.
  - each `title`, pinned verbatim, and the titles are distinct.
  - `tabActivation` returns `.alreadyShowing` for the showing tab, `.show(tab)` for any other tab, and `.show(tab)` when `current` is `nil`.
  - for every pair, a `.show(target)` answer passed through `toggled(current, selecting: target)` yields `target`: a tab never collapses through the funnel.
- [x] add `panelHeaderHeight` 28, `panelHeaderPaddingX` 14, `dockTabRowPaddingX` 10 and `dockTabLabelPaddingX` 10, each with its meaning. The last two carry the distinct-measurement note. Update the file's doc comment so its inventory stays true.
- [x] extend `ChromeThemeTests`' value test and its set-equality token list with the four new tokens.
- [x] run `swift test`. It must pass before task 2.

### Task 2: The dock's tab row

**Files:**

- Create: `Sources/Pisaka/DockTabRow.swift`
- Modify: `Sources/Pisaka/ContentView.swift`
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`
- Modify: `Tests/PisakaCoreTests/BottomPanelSourceGatingTests.swift`
- Modify: `docs/architecture/core-theme.md`, `CLAUDE.md`

- [x] write `DockTabRow.swift` under `#if os(macOS)`:
  - A `struct DockTabRow: View` taking `selection: BottomPanel`, `onSelect: (BottomPanel) -> Void` and `onClose: () -> Void`. It reads `\.interfaceMetrics` and `\.chromeTheme`.
  - The row: `ForEach(BottomPanel.allCases)`, gap 2, a `Spacer()`, then the close action. Horizontal padding is `dockTabRowPaddingX` and height is `dockTabRowHeight`, with no minimum anywhere.
  - A one-point `hairline` overlay along the bottom edge. The row has no ground of its own, because the slot already paints `bgPanel`.
  - Each tab is a `.plain` `Button` whose label is a `VStack(spacing: 0)`:
    - the title at `.callout`, regular weight in both states, `.lineLimit(1)`, horizontal padding `dockTabLabelPaddingX`, filling the height above the strip. It is `textPrimary` when selected and `textSecondary` otherwise.
    - a strip of height `accentIndicator` spanning the tab's width, `accent` when selected and `Color.clear` otherwise, with `.accessibilityHidden(true)`.
    - `.contentShape(Rectangle())`, plus the accessibility of decision 10.
  - The close action is an `xmark` at `.body` in `textSecondary`, with `.help` and `.accessibilityLabel` ("Close panel").
  - Local gaps go in `private enum DockTabRowLayout`.
  - The doc comment records decisions 2, 4 and 5 and says why no weight changes.
- [x] in `ContentView.panelContent(_:)`, wrap the existing `switch` in a `VStack(spacing: 0)` with `DockTabRow` above it:
  - `onSelect: { tab in if case .show(let target) = BottomPanel.tabActivation(bottomPanel.wrappedValue, tab: tab) { onTogglePanel(target) } }`
  - `onClose: { onTogglePanel(panel) }`
  - Add a comment saying why the row sits here: it is one place, every panel gets it, and the pinned frame, its top alignment, the clip, the divider and `panelHeightRule` are untouched.
  - Change nothing else in `mainArea`.
- [x] `bottomBarButton(title:systemImage:panel:)` becomes `bottomBarButton(systemImage:panel:)`. `.help` and `.accessibilityLabel` read `panel.title`, and the six calls drop their titles. Glyphs, order and styling do not change. Fix the body comment that still says "Terminal/Git/Changes/Problems toggle buttons".
- [x] add `"DockTabRow.swift"` to `gatedFiles` and to rule eleven's file list. Reword that rule's doc from "the bar" to "a fixed-height chrome strip".
- [x] add **rule twelve** (`// MARK: - Rule twelve: the dock's tab row is configured in one place`):
  - Over the stripped sources, the set of files spelling `DockTabRow(` equals `{"DockTabRow.swift", "ContentView.swift"}`.
  - `ContentView.swift` spells it exactly once, inside `panelContent(`'s matched body.
  - None of the six hosted panel files names `DockTabRow`.
- [x] add **rule thirteen** (`// MARK: - Rule thirteen: every dock tab and the close action are identifiable without sight`):
  - In `DockTabRow.swift`, the matched body of the tab builder spells `.accessibilityLabel(`, `.accessibilityValue(` and `.accessibilityHidden(true)`.
  - The matched body of the close builder spells `.help(` and `.accessibilityLabel(`.
  - Both builders are named in the test, so renaming either fails loudly.
- [x] for each rule: add its doc paragraph, its item in `core-theme.md`'s canonical list, and the `spelled` entries through "fifteen". Bump `CLAUDE.md`'s count to thirteen and add both rules to that sentence's enumeration.
- [x] `BottomPanelSourceGatingTests`: add `DockTabRow`'s type body to the slot-facing bodies checked for `minHeight`, with a comment saying the row sits inside the fixed-height slot.
- [x] run `swift test` and the app-layer bundle. Both must pass before task 3.

### Task 3: One severity answer, in Core

**Files:**

- Modify: `Sources/PisakaCore/ChromeColorRole.swift`
- Modify: `Sources/Pisaka/LineNumberRulerView.swift`
- Modify: `Tests/PisakaCoreTests/ChromeThemeTests.swift`
- Modify: `Tests/PisakaAppTests/GutterFoldTests.swift`
- Modify: `docs/architecture/app-editor-overlays.md`

- [x] move `diagnosticRole(for:)` to `ChromeColorRole` as `public static`, unchanged in its four answers (decision 8). The doc comment moves with it:
  - it keeps the information/hint reasoning and why it is deliberately not `SyntaxTheme`'s table;
  - it now also says who reads it (the gutter's severity dot, and the Problems panel's badges and row glyphs);
  - it says the squiggle alone stays on `SyntaxTheme`.
- [x] delete the ruler's copy. Its drawing site calls `ChromeColorRole.diagnosticRole(for:)`.
- [x] Core test in `ChromeThemeTests`: pin the four answers verbatim, and assert they are pairwise distinct roles. This is the first time the Core gate sees the mapping.
- [x] `GutterFoldTests.testEverySeverityResolvesToItsRole`: call the Core function. Its mapping table is now the Core test's, so keep the resolved-colour distinctness half under both appearances (the half only the app bundle can see) and update its doc to say so.
- [x] `app-editor-overlays.md`, the ruler's entry: name `ChromeColorRole.diagnosticRole(for:)` as the one answer and the Problems panel as its second reader. The Core suite pins the mapping and the app bundle pins distinct colours. `SyntaxTheme` answers for the squiggle alone; correct the entry's mention of the hover popover after confirming that no hover code reads `SyntaxTheme`'s severity table.
- [x] run `swift test` and the app-layer bundle. Both must pass before task 4.

### Task 4: Problems and Usages

**Files:**

- Modify: `Sources/Pisaka/ProblemsPanelView.swift`, `Sources/Pisaka/UsagesPanelView.swift`
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`
- Modify: `docs/architecture/core-theme.md`, `CLAUDE.md`

- [x] both files add `@Environment(\.chromeTheme) private var theme`, and so do their private row structs.
- [x] header strip, in both files:
  - Replace `VStack { header; Divider(); content }` with the header plus its own one-point `hairline` overlay along its bottom edge.
  - Height `panelHeaderHeight`, horizontal padding `panelHeaderPaddingX`, gap 8 (local).
  - The title at `.body` semibold in `textPrimary`. Every `Text` in the header gets `.lineLimit(1)`.
- [x] Problems:
  - Header badges and row glyphs take `theme.color(ChromeColorRole.diagnosticRole(for:))` (decision 8).
  - Delete the `SyntaxTheme` severity helpers.
  - Correct the "three surfaces, one palette" comment and the file header to name the two tables and which surface is on which.
  - File-group header: icon `textSecondary`, path `textPrimary`.
  - Row: message `textPrimary`, `:line` at `.subheadline` monospaced in `textSecondary`.
  - Hover wash is `hoverTint`, replacing `accentColor.opacity(0.15)`.
  - Row and group horizontal insets are `rowPaddingX`. Other paddings go in `private enum ProblemsPanelLayout`.
  - The placeholder is `textSecondary`.
- [x] Usages:
  - The identifier stays `.callout` monospaced, in `textPrimary`.
  - The provenance note and the count move to `.subheadline` in `textSecondary`.
  - File-group header and hover wash are treated as in Problems.
  - The line number is `.subheadline` monospaced in `textSecondary`.
  - Preview: `before` and `after` are `textSecondary`; the hit is `textPrimary` semibold.
  - Local numbers go in `private enum UsagesPanelLayout`.
  - The placeholder is `textSecondary`.
- [x] neither file names a system semantic colour (`.primary`, `.secondary`, `Color.accentColor`) or a hex literal.
- [x] add both files to `gatedFiles` and to rule eleven's file list.
- [x] add **rule fourteen** (`// MARK: - Rule fourteen: the dock's swept surfaces draw their own rules`):
  - A named list `dockRuleOwners = ["DockTabRow.swift", "ProblemsPanelView.swift", "UsagesPanelView.swift"]`, each spelling no `Divider(` in stripped source.
  - Its doc says that part four (b) extends the list, and why a platform separator is wrong here.
- [x] add **rule fifteen** (`// MARK: - Rule fifteen: the severity mapping is Core's one answer`), with the three clauses of decision 11. Its doc names the regression it prevents: a second severity table reappearing in a view.
- [x] for both rules: add the doc paragraph and the canonical-list item, and bump `CLAUDE.md` to fifteen with both rules in its enumeration.
- [x] run `swift test` and the app-layer bundle. Both must pass before task 5.

### Task 5: The Terminal panel's host

**Files:**

- Modify: `Sources/Pisaka/TerminalPanelView.swift`
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`

- [ ] add `@Environment(\.chromeTheme) private var theme`.
- [ ] the session strip: remove its `Divider()`; use `panelHeaderHeight` (decision 9) in place of the bare 28; add a one-point `hairline` overlay along its bottom edge. Other numbers go in `private enum TerminalTabStripLayout`.
- [ ] session tab:
  - The selected ground is `accentTintStrong`, replacing `selectedControlColor`, clipped at `cornerRadiusMax`.
  - The title is `textPrimary` when selected and `textSecondary` otherwise.
  - The close glyph is `.subheadline` at bold weight in `textSecondary` (decision 7).
  - The `+` glyph is `textSecondary`.
- [ ] the no-session placeholder draws `bgPanel` in place of `textBackgroundColor`.
- [ ] `TerminalHostView`, the container view and the terminal palette stay untouched.
- [ ] add the file to `gatedFiles`, to rule eleven's file list and to rule fourteen's `dockRuleOwners`.
- [ ] run `swift test` and the app-layer bundle. Both must pass before task 6.

### Task 6: Documentation

**Files:**

- Modify: `docs/architecture/core-theme.md`, `docs/architecture/app-window.md`, `docs/architecture/app-terminal.md`, `docs/architecture/core-services.md`, `CLAUDE.md`

- [ ] `core-theme.md`, a **Part four (a)** record in the shape of the earlier parts:
  - each file and the roles it spends;
  - the tab row's contract;
  - decisions 2, 3 and 5, each with its reason. For decision 3 the reason is that menu titles belong to the part that sweeps menus.
  - the font-tier mapping (13 for primary text, 12 for secondary metadata, 11 for column headings and monospaced details, by tier and not by rounding), with the discrepancy from decision 7;
  - the one severity answer (decision 8), including which surface reads which table;
  - the terminal strip as its panel's header (decision 9).
- [ ] `core-theme.md`: update the `ChromeColorRole.swift` entry for `diagnosticRole(for:)` and the `ChromeGeometry.swift` entry's token inventory.
- [ ] `core-theme.md`, "What is still waiting":
  - Remove the tab row from the deferred items and say `dockTabRowHeight` is now spent.
  - List Log, Local Changes and Pull Requests as part four (b), which will follow the header-strip and rule-fourteen conventions set here.
  - Keep the caret readout, the dialogs, the popovers' `Divider()` calls, the find bar, the separate windows, Preferences and the terminal palette listed.
  - Re-verify the unused-role list and the swept-surface count against `ChromeColorRole.swift`'s doc comment, and correct both if either is wrong.
- [ ] `app-window.md`:
  - a full entry for `DockTabRow.swift`;
  - update the `ContentView.swift` entry: the row in `panelContent(_:)`, and toggle titles read from `BottomPanel.title`;
  - update the `ProblemsPanelView.swift` entry (the header strip, the roles, and the severity answer read from Core, replacing "three surfaces" with the two tables) and the `UsagesPanelView.swift` entry.
- [ ] `app-terminal.md`: update the `TerminalPanelView.swift` entry (the strip, the selected wash, the placeholder ground; the palette untouched).
- [ ] `core-services.md`: update the `BottomPanel.swift` entry (`CaseIterable` order, `title`, `tabActivation` and `DockTabActivation` with the reason it is not a `BottomPanel?`).
- [ ] `CLAUDE.md`:
  - an index line for `DockTabRow.swift` under `app-window.md`;
  - update the index lines for `BottomPanel.swift` and `ChromeColorRole.swift`;
  - in the chrome invariant, update the gated-file count (sixteen → twenty), the rule count and enumeration (fifteen, checked for coherence as a whole) and the swept-surface count (twelve → sixteen, each surface named).
- [ ] run `swift test`. The cross-file count rules must agree with both documents.

### Task 7: Verify acceptance criteria

- [ ] `swift test` is green.
- [ ] the app-layer bundle is green on a macOS destination, with derived data under `~/Library/Developer/Xcode/DerivedData/pisaka-chrome-part-four-a`.
- [ ] the macOS Release build and the iOS build (`generic/platform=iOS`) are green, under the same derived-data rule.
- [ ] `swiftlint --strict` is clean from the repository root, with no in-file disables.
- [ ] a search confirms:
  - no `Divider()`, system semantic colour or hex literal remains in the four swept files;
  - no app file declares `diagnosticRole`, and `ProblemsPanelView.swift` names no `SyntaxTheme`;
  - `ChromePalette.swift` is unchanged (`git diff --stat`);
  - the bar's only diff is the titles now read from `BottomPanel.title`;
  - `PisakaApp.swift` is unchanged.

## Post-Completion (manual verification)

- Open each panel from the bar. The row names all six; the showing tab is in the primary colour under the accent strip, and the others are secondary with no strip.
- Click another tab: the panel switches. Click the showing tab: nothing happens. Click close: the dock collapses.
- Click Terminal with no live session: a shell starts.
- With diagnostics present, the Problems panel's glyphs match the gutter's dots in colour, and the squiggle keeps its own colours.
- Switch Theme between Light, Dark and System. The row and the three panels repaint without a relaunch.
- Drag the dock divider down to its floor and past it. The row stays at the top, nothing paints over the bar, and a bare click leaves the height unchanged.
- Move through the row with VoiceOver. Each tab announces its name and "Selected" or "Not selected", and the close action announces "Close panel".

