# Chrome theme, part five (d): the database viewer, its SQL console and the problem-catalog surfaces

## Overview

This part moves the last seven unswept macOS chrome views onto the role vocabulary:

- the database viewer tab (`DatabaseViewerView.swift`) and its SQL console (`DatabaseConsoleView.swift`);
- the problem-catalog browser window, the statement pane, the judge section, the open-problem sheet (with the menu-bar commands in the same file) and the sign-in sheet.

It spends **no new colour role**. `ChromeColorRole` stays at twenty-one cases, and `currentLine` and `bracketMatch` stay unspent. It adds:

- three Core colour answers;
- one shared control, the spinner, with two geometry tokens.

Seven files join the gated set, taking it from 51 to 58:

- `DatabaseViewerView.swift`
- `DatabaseConsoleView.swift`
- `LeetCodeBrowserView.swift`
- `LeetCodeDescriptionView.swift`
- `LeetCodeOpenProblemSheet.swift`
- `LeetCodeJudgeView.swift`
- `LeetCodeLoginView.swift`

Four new rules take the suite from thirty-seven to forty-one:

- **38:** no platform table;
- **39:** the problem catalog's three colour mappings are Core's;
- **40:** one spinner;
- **41:** no alternating row fill.

Existing pins grow wherever the new files fall under a rule that already exists: 20, 22, 24, 26, 30, 32, 34, 35 and 37.

**The spinner scope was settled in Q&A: all twenty sites.** Every `ProgressView` in a macOS gated file moves onto the shared spinner. That is the five in the new files plus fifteen in already-gated files:

- the Log (2), the commit dialog, Find in Files;
- the Pull Requests panel (3), both pull-request sheets (3);
- Language Servers (3), Local History, Usages.

Rule forty then bans `ProgressView` in every gated file.

**Decisions this plan makes where the ticket is silent or the repository differs.** Each one is recorded in `core-theme.md`:

1. **Twenty-two `Divider()` sites, in six files, not five.** The judge section has none. The sites are:
   - the viewer 7, the console 6, the browser 3, the statement pane 3, the sign-in sheet 2;
   - one in the open-problem sheet's file, inside `LeetCodeCommands` (the menu-bar items). That one is a menu separator, so it becomes two `Section { }` groups rather than a hairline, which is rule twenty-four's own idiom.
2. **There are two `Picker`s, not one.** The browser's filter bar and the open-problem sheet both pick the solution language over `LeetCodeSolutionFile.offerableLanguages`. Both become `ChromeMenuField`, the same answer part five (c) gave the catalog settings tab for the same list.
3. **The six filter toggles become `ChromeCheckbox`es.** Difficulty and status are set-membership filters, where each case is independently in or out and an empty set means everything. That is an option of one action (the checkbox) and not a single choice (segmented) or a standing preference (switch), so the picker rule answers checkbox. The existing bindings are unchanged.
4. **The three `TextField`s and two `TextEditor`s:**
   - the browser's query and the open-problem sheet's input become `ChromeThemedTextField`, each with a private focus enum;
   - the grid's cell editor becomes `ChromeThemedTextField` over the grid's existing `$focus` / `.editor(coordinate)` and speaks the column name. Its `.onSubmit` / Escape handling stays on the outer view;
   - the judge's test-case `TextEditor` is wrapped in `ChromeControlBox`, following the commit dialog's message box;
   - the console's input is a pane between two hairlines, not a field. It stands on `bgEditor` with `.scrollContentBackground(.hidden)` and is not boxed.
5. **The database grid has no row selection, and none is added** (behaviour is out of scope):
   - a grid row and a console result row take `hoverTint` under the pointer;
   - the grid's one selection-like state, the focused cell, draws `accentTintStrong`;
   - the console's rows have hover only.
6. **The browser's rows follow `CommitRow`:**
   - selection is `accentTintStrong` whether or not the window is key; hover is `hoverTint`;
   - the `Table`'s per-column drag resize is not carried, because the model panel has none. The number, difficulty and status columns take fixed widths scaled from the old ideal widths (56 / 88 / 96), and the title column takes the rest;
   - keyboard:
     - the row list is one focusable container;
     - `onMoveCommand` moves the selection up and down, and a `ScrollViewReader` keeps it visible;
     - Return opens through a zero-sized shortcut button enabled only while the list holds focus. This is the viewer's `returnOpensTheFocusedCell` idiom, because `onKeyPress` is macOS 14;
     - the explicit Open button stays;
   - accessibility: each row is one combined element carrying the `.isSelected` trait and a named "Open" action. The lock glyph speaks "LeetCode Premium".
7. **The viewer's error banner** is a `bgPanel` strip with a `hairline` bottom rule, drawn behind. Its `exclamationmark.triangle.fill` mark and the sentence are both `statusRed`, and the orange wash is deleted. The console's message slot takes the same mark and colour.
8. **The spinner is drawn, not a platform control:**
   - `ChromeSpinner` is an open arc stroked in `textSecondary` and rotated by a repeating animation. A spinner reports activity, not selection, which is why it is not `accent`;
   - it is `spinnerSide` = 16 (the small control size it replaces) by `spinnerLineWidth` = 2, both new `ChromeGeometry` tokens scaled through the metrics;
   - under Reduce Motion it draws still;
   - **it speaks either its activity or nothing, decided at the call site, never both and never neither.** Part five (c)'s shape for exactly this case is followed (`SettingsView.swift`'s `.accessibilityHidden(controlSpeaksLabel)` on a label column whose control speaks for itself, and `ChromeControls.swift`'s six hidden decorative glyphs):
     - a spinner whose neighbour already names the activity (the Log's "Loading commits", Find in Files, Language Servers, the pull-request sheets, and every other site with a sentence beside it) is `.accessibilityHidden(true)` and speaks nothing, so VoiceOver reads the sentence once rather than the sentence followed by a second, vaguer one;
     - a spinner standing alone with no sentence beside it carries `.accessibilityLabel(…)` naming what is happening;
     - the type itself has **no default label** — a default would be exactly the duplicate this avoids — and carries `.updatesFrequently` in its body, which is inert when the site hides it;
     - each of the twenty sites is classified in Task 2–6 from the tree, and the classification is pinned per file (Task 7, rule forty);
   - the three `.progressViewStyle(.circular)` go with their views.
9. **The statement pane's resize handle** (a 5-point `separatorColor` fill today) takes `ContentView.panelDivider`'s shape: a transparent hit area with a centred `hairline` at `hairlineWidth`. Its cursor function joins rule twenty-two's pinned set.
10. **The tables-and-views sidebar:**
    - `.listStyle(.sidebar)` draws the platform's translucent material, so the list becomes `.plain` with `.scrollContentBackground(.hidden)` on `bgPanel`;
    - the section headers take `Section { } header: { }` in `textSecondary`;
    - the platform draws the selection, and no row background is set, so rule thirty-five pins `[[]]`.
11. **`VSplitView`'s divider stays**, carried with `HSplitView`'s as the same open question.
12. **The browser is a window root**, so rule thirty-two applies: it resolves colours through a private `chromeColor(_:)`, and its rows are a file-scope child struct reading the environment. `chromeColorRoots` grows from five to six.
13. **Only the colour tables move to Core.** The browser's two title switches and `statusCell`'s glyph choice stay in the view. Rule thirty-nine pins the browser's case-label count, rule eighteen's `sharedSpellingCaseLabels` mechanism, so a colour switch added later moves the count.
14. **The verdict's "good" rule moves with its colour.** `verdictRole(for:matchedExpected:)` answers `statusGreen` for `.accepted` unless `matchedExpected == false`, and `statusRed` otherwise. The run passes its `matchedExpected`; the submit passes `nil`.
15. **Medium difficulty is `statusYellow`.** There is no orange role, and attempted takes the same role.
16. **Styled buttons get a table with two numbers per file.** Menu items and the confirmation dialog's buttons cannot take a button style:
    - the cell menu's Copy and Set to NULL;
    - the browser's context-menu Open;
    - `LeetCodeCommands`' items;
    - the console's dialog Run and Cancel.

    So part five (d)'s table states, per file, its `Button` count and its `.buttonStyle(` count, with the unstyleable ones named in the comment. Both are confirmed against the tree.

17. **Named icon-only controls.** The statement pane's three icon-only buttons (hide, open on the site, show) and the grid footer's two paging chevrons gain `.accessibilityLabel` and hide their glyphs, and join rule twenty's builders.
18. **The page inside the statement pane stays unthemed** (out of scope), and the docs say so: the pane is themed, the served document is not. The sign-in sheet's web page is the site's own; only its header and footer are chrome.

## Context

**Files involved**

- Core:
  - `Sources/PisakaCore/ChromeColorRole.swift` (three answers)
  - `Sources/PisakaCore/ChromeGeometry.swift` (two tokens)
- Shared shapes:
  - `Sources/Pisaka/ChromeControls.swift` (`ChromeSpinner`)
- Joining the gated set: the seven files above.
- Already gated, touched only for the spinner:
  - `CommitLogView.swift`, `CommitDialogView.swift`, `ProjectSearchView.swift`
  - `PullRequestsPanelView.swift`, `NewPullRequestSheet.swift`, `PullRequestMergeSheet.swift`
  - `LSPServerSettingsView.swift`, `LocalHistoryView.swift`, `UsagesPanelView.swift`
- Tests:
  - `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`
  - `ChromeRoleMappingTests.swift`
  - `ChromeThemeTests.swift` (`testGeometryTokensCarryTheirTableValues`, `testGeometryDeclaresExactlyTheseTokensAndNoFontSize`)
- Read only, must stay green:
  - `DatabaseViewerSourceGatingTests` (the three disable terms and the console's rules);
  - `LeetCodeAccountSourceGatingTests` (`resolveAccount(` stays in its four files);
  - `ZoomSourceGatingTests` (the browser root's injection, the statement pane's code-zone marker, the console declaring no surface);
  - `InterfaceMetricsTests`, `MenuShortcutUniquenessTests`.
- Docs:
  - `docs/architecture/core-theme.md`, `core-database-viewer.md`, `core-leetcode.md`
  - `CLAUDE.md`

**Related patterns**

- Rows: `CommitLogView.swift`'s `CommitRow` (`rowBackground`, `onHover`, a scaled `minHeight`) and its `CommitLogLayout` enum of bare numbers scaled at the use site. Rule seven forbids arithmetic on a token.
- A Core colour answer and its rule: `checksRole(for:)` with rule eighteen (reader set, no `func` in an app file, case labels pinned by count), tested in `ChromeRoleMappingTests`.
- A lifted shape: `ChromeCheckbox` / `ChromeSwitch` in `ChromeControls.swift`. It reads `\.interfaceMetrics` and `\.chromeTheme` and owes its accessibility inside its own body.
- Speaking or staying silent: `SettingsView.swift`'s `.accessibilityHidden(controlSpeaksLabel)` and `ChromeControls.swift`'s hidden decorative glyphs — the spinner's two call-site markers follow them.
- Hairlines: a `Rectangle` filled `hairline` at `metrics.scaled(ChromeGeometry.hairlineWidth)`. Under a header with a ground, it is applied as `.background(alignment: .bottom)` **before** the ground (rule sixteen's ordering lesson).
- Rule matching: `LSPSourceGatingTests.containsToken`, `callRanges`, `matchedBody(after:in:)`, rule twenty's `ControlBuilder`. Stripped text only; nothing parsed or evaluated.

**Dependencies:** none new.

## Development Approach

- **Testing approach:** regular (code first, then tests). The exception is Task 7, where every new rule and every new clause is first shown red against a deliberate regression, then green, and the tree is confirmed clean with `git status`.
- **Gated immediately:** a task that restyles a file adds it to `gatedFiles` in the same task and brings every existing pin it trips (rules 20, 22, 24, 26, 30, 32, 34, 35, 37) up to date in that task.
- **Architecture entries:** read each file's `docs/architecture/` entry before modifying it.
- **No new role, no new exemption, no new font size.** A surface that seems to need a twenty-second role is left as it is and reported, per the stated refusal.
- **No behaviour change.** Every label, sentence, shortcut, disabled rule and generation-token capture stays verbatim.
- **No product or brand names** in prose, comments, docs or commit messages.
- **Derived data:** local `xcodebuild` uses `-derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-part5d`, never a path inside the repository.
- **Unattended verification only.** Appearance checks go in Post-Completion.
- **CRITICAL:** every task includes new or updated tests.
- **CRITICAL:** `swift test` passes before the next task starts. A task that touches app files also builds the macOS app.

## Implementation Steps

### Task 1: Core: the three colour answers and the spinner's tokens

**Files:**

- Modify: `Sources/PisakaCore/ChromeColorRole.swift`
- Modify: `Sources/PisakaCore/ChromeGeometry.swift`
- Modify: `Tests/PisakaCoreTests/ChromeRoleMappingTests.swift`
- Modify: `Tests/PisakaCoreTests/ChromeThemeTests.swift`
- [x] Add `difficultyRole(for: LeetCodeDifficulty) -> ChromeColorRole`: easy `statusGreen`, medium `statusYellow`, hard `statusRed` (decision 15).
- [x] Add `problemStatusRole(for: LeetCodeProblemStatus) -> ChromeColorRole`: solved `statusGreen`, attempted `statusYellow`, notStarted `textSecondary`.
- [x] Add `verdictRole(for: LeetCodeVerdict, matchedExpected: Bool?) -> ChromeColorRole` (decision 14).
- [x] Each answer gets a doc comment in the existing answers' manner, naming its one reader.
- [x] Update the type's header paragraph only where it inventories the answers. (No change needed: the header inventories spent roles, not answers, and the three answers spend no new role.)
- [x] Add `spinnerSide` = 16 and `spinnerLineWidth` = 2 to `ChromeGeometry`, each with a one-line comment. Neither is derived from another.
- [x] Tests, total over every case:
  - `testEveryDifficultyHasItsRole` and `testEveryProblemStatusHasItsRole`, over `allCases`;
  - `testEveryVerdictHasItsRoleForEveryMatchAnswer`, over every `LeetCodeVerdict` × {`nil`, `true`, `false`};
  - extend the two geometry tests (the table values and the set-equality inventory).
- [x] Run `swift test`. It must pass.

### Task 2: The shared spinner, and the fifteen already-gated sites

**Files:**

- Modify: `Sources/Pisaka/ChromeControls.swift`
- Modify: `CommitLogView.swift`, `CommitDialogView.swift`, `ProjectSearchView.swift`, `PullRequestsPanelView.swift`, `NewPullRequestSheet.swift`, `PullRequestMergeSheet.swift`, `LSPServerSettingsView.swift`, `LocalHistoryView.swift`, `UsagesPanelView.swift`
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`
- [x] Add `ChromeSpinner` (decision 8), with no label parameter and no default label, and name it in the file's header paragraph. Its doc comment states the call-site contract: exactly one of `.accessibilityHidden(true)` (a neighbour names the activity) or `.accessibilityLabel(…)` (it stands alone).
- [x] Replace the fifteen `ProgressView` sites in the nine files. Keep each site's padding and the text beside it. Classify each site from the tree:
  - a sentence or caption beside it already says what is happening → `.accessibilityHidden(true)`;
  - nothing beside it names the activity → `.accessibilityLabel(…)` in the site's own words, reusing the view's existing wording where there is one.
- [x] Rule twenty's clause for `struct ChromeSpinner` is checked at its **constructions** rather than in its body: every `ChromeSpinner(` call's trailing modifier chain (the lines after the call that begin with `.`, read from stripped text, nothing parsed) must spell exactly one of `.accessibilityLabel(` or `.accessibilityHidden(` — never neither, never both. The rule's comment names the two shapes it follows (`SettingsView.swift`'s hidden label column, `ChromeControls.swift`'s hidden glyphs) and says why the type carries no default.
- [x] Start the per-file classification table for rule forty (`labelled`, `hidden` per file) with these nine files, confirmed against the tree; Task 7 adds the rule that reads it. (`spinnerClassification`, read now by the constructions clause by set equality. From the tree: the Log header and load-more row, Find in Files, Usages, the commit dialog, Local History, the Pull Requests header and the two sheets' write spinners have no neighbour naming the activity, since each "Loading…"/"Searching…" is the empty list's alone, so they are labelled; the wait, "Reading checks…", the merge-settings line and the three Language Servers rows are hidden. That is 10 labelled and 5 hidden.)
- [x] Rule thirty-four: the spinner draws no symbol, so no glyph exemption is needed. Confirm this. (Confirmed: an arc on a `Circle`, with no `Image(`.)
- [x] Run `swift test` and the macOS build. Both must pass.

### Task 3: The database viewer

**Files:**

- Modify: `Sources/Pisaka/DatabaseViewerView.swift`
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`
- [x] **Ground and colour.** The pane stands on `bgPanel` and the grid on `bgEditor`. Every `.secondary` becomes `textSecondary` and every value text `textPrimary`.
- [x] **NULL.** A NULL cell keeps its italic and takes `textSecondary`; an ordinary value takes `textPrimary`. Correct the doc comment that says "tertiary". `refusedCellOpacity` stays a view opacity.
- [x] **The error banner** (decision 7).
- [x] **The sidebar list** (decision 10). The schema header is `textSecondary`. The key glyph gets its own scaled font and keeps its help.
- [x] **The grid:**
  - the header row is `bgPanel` with the sort chevron in `textSecondary` and a `hairline` bottom rule drawn behind;
  - the column separators become vertical `hairline` rules at `hairlineWidth`;
  - `isTinted` and its zebra expression are deleted (the ticket's requirement 2);
  - rows take `hoverTint`, and the focused cell `accentTintStrong` (decision 5);
  - the cell editor becomes the shared field (decision 4).
- [x] **The footer:**
  - the two chevron buttons become `.plain`, named "Previous page" / "Next page", with scaled, hidden glyphs;
  - their `.disabled(… || model.isWriteInFlight)` terms stay verbatim;
  - the spinner becomes `ChromeSpinner`, marked hidden or labelled per decision 8 from what stands beside it.
- [x] **The seven `Divider()`s** become the surface's own hairlines.
- [x] Add the file to `gatedFiles`, and bring each rule's pins up to the tree:
  - rule twenty (the paging buttons; the spinner's construction marker);
  - rule twenty-four (`menuFiles`, and `menuSectionFiles` too if the list's `Section` makes it one; state why); (Both: the file builds a context menu and spells `Section` for the sidebar list, and the computed set pairs the two; the cell menu itself has no separator.)
  - rule twenty-six (`sharedFieldConstructors`, plus the two `core-theme.md` passages that enumerate it);
  - rule thirty (part five (d)'s two-number table, decision 16);
  - rule thirty-four (every glyph sized);
  - rule thirty-five (`"DatabaseViewerView.swift": [[]]`);
  - the spinner classification table (this file's row).
- [x] Run `swift test` and the macOS build. Both must pass. `DatabaseViewerSourceGatingTests` must stay green.

### Task 4: The SQL console

**Files:**

- Modify: `Sources/Pisaka/DatabaseConsoleView.swift`
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`
- [x] The toolbar and status bar are `bgPanel`, and the "SQL" caption and the footer sentence are `textSecondary`.
- [x] Run becomes `.chromeSecondary`, with its ⌘↩ shortcut and `isRunDisabled` unchanged. The spinner becomes `ChromeSpinner`, marked hidden or labelled per decision 8.
- [x] The input is a pane on `bgEditor` (decision 4).
- [x] The result header row is `bgPanel` with its rule behind. The columns are separated by hairlines. `isTinted` is deleted; rows take `hoverTint` (decision 5). NULL follows the viewer's rendering.
- [x] The message slot uses the `statusRed` mark and sentence (decision 7).
- [x] The six `Divider()`s become hairlines.
- [x] The confirmation dialog is untouched.
- [x] Add the file to `gatedFiles`, and update rules thirty (the dialog's two buttons named as unstyleable) and thirty-four, and this file's row of the spinner classification table. (Rule thirty: 3 buttons, 1 styled; `chromeSecondary`'s caller set gains the file. Rule thirty-four needed no exemption: the message mark takes its own scaled font. Spinner row: 1 labelled, "Running SQL", since neither the "SQL" caption nor Run names the run. The result rows reuse the viewer's `GridRowHover`, no longer `private`.)
- [x] Run `swift test` and the macOS build. Both must pass. The console's rules in `DatabaseViewerSourceGatingTests` must stay green, and the console still declares no zoom surface.

### Task 5: The problem-catalog browser becomes the chrome's own rows

**Files:**

- Modify: `Sources/Pisaka/LeetCodeBrowserView.swift`
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`
- [x] **Root.** Add a private `chromeColor(_:)` over `settings.chromeTheme(systemPrefersDark:)`, following the five existing roots, and a `bgPanel` ground. The root struct reads no `\.chromeTheme` (decision 12).
- [x] **Filter bar:**
  - the query becomes the shared field with the magnifying-glass glyph;
  - Language becomes `ChromeMenuField`, framed at `menuFieldHeight`;
  - the six toggles become `ChromeCheckbox` (decision 3);
  - the vertical `Divider()` becomes a vertical hairline;
  - Open becomes `.chromeSecondary`;
  - the message is `statusRed`.
- [x] **Rows** (decision 6):
  - `ScrollView` + `ScrollViewReader` + `LazyVStack`;
  - a header row with the four titles "#", "Title", "Difficulty", "Status" on `bgPanel`, with its rule behind;
  - a file-scope `LeetCodeBrowserRow` struct with a scaled `minHeight` from a private layout enum of bare numbers;
  - the number in `textSecondary`, monospaced digits;
  - the title in `textPrimary`, with the lock glyph `textSecondary`, scaled, keeping its help and speaking it;
  - the difficulty coloured by `difficultyRole(for:)`;
  - the status drawn by the existing glyph and words and coloured by `problemStatusRole(for:)`;
  - single tap selects, double tap opens, and `.contextMenu` offers "Open";
  - keyboard and accessibility per decision 6;
  - `pruneSelection()` and both `onChange` hooks unchanged.
- [x] **Delete** `color(for:)`, the `Table`/`TableColumn` and the `Row` wrapper's `Table`-only comment. Keep `Row` only if the `ForEach` still wants it.
- [x] **The signed-out offer and the footer:**
  - text in `textSecondary`, the error in `statusRed`;
  - Sign In… and Refresh `.chromeSecondary`;
  - the spinner becomes `ChromeSpinner`, marked hidden or labelled per decision 8;
  - the offer's glyph keeps its scaled size.
- [x] Add the file to `gatedFiles`. Update:
  - rule twenty (the row; the spinner's construction marker);
  - rule twenty-four (`menuFiles`);
  - rule twenty-six;
  - rule thirty (`chromeSecondary`, `ChromeCheckbox`, the two-number table);
  - rule thirty-two (`chromeColorRoots` to six);
  - rule thirty-four;
  - rule thirty-seven (`ChromeMenuField` callers and counts);
  - the spinner classification table (this file's row).
  (Rule twenty names the row's body: the selected trait, the Open action and the spoken lock. Rule twenty-four: the row's context menu makes the file a `menuFiles` member; it spells no `Section`. Rule twenty-six's count message and both `core-theme.md` passages now say nine callers. Rule thirty: 5 buttons, 4 styled, with the context-menu Open unstyleable. Rule thirty-four needed no exemption. Rule thirty-seven: one `ChromeMenuField`. Spinner row: 1 labelled, "Opening problem" / "Loading problems", because "Loading…" is only the empty list's count line.)
- [x] Run `swift test` and the macOS build. Both must pass. `ZoomSourceGatingTests` and `LeetCodeAccountSourceGatingTests` must stay green.

### Task 6: The statement pane, the judge, the open-problem sheet and the sign-in sheet

**Files:**

- Modify: `Sources/Pisaka/LeetCodeDescriptionView.swift`
- Modify: `Sources/Pisaka/LeetCodeJudgeView.swift`
- Modify: `Sources/Pisaka/LeetCodeOpenProblemSheet.swift`
- Modify: `Sources/Pisaka/LeetCodeLoginView.swift`
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`
- [x] **The statement pane:**
  - the header is on `bgPanel`, with the title in `textPrimary` and the two icon buttons named with hidden, scaled glyphs (decision 17);
  - the collapsed strip is on `bgPanel`, and its button is named;
  - the three `Divider()`s become hairlines;
  - the resize handle follows decision 9;
  - the web view and its code-zone marker are untouched.
- [x] **The judge:**
  - Run and Submit become `.chromeSecondary`, and the spinner becomes `ChromeSpinner`, marked hidden or labelled per decision 8;
  - the info badge is `textSecondary`, scaled and still labelled;
  - the captions and fields are `textSecondary` / `textPrimary`;
  - the test-case box follows decision 4, and the `separatorColor` stroke is deleted;
  - every failure line (`lastError`, `errorText`) is `statusRed`;
  - `verdict(_:isGood:)` becomes `verdict(_:role:)`, fed by `verdictRole(for:matchedExpected:)`.
- [x] **The open-problem sheet:**
  - on `bgPanel`, title `textPrimary`, captions and the parse hint `textSecondary`;
  - the refusal `statusRed`;
  - the input becomes the shared field (decision 4) and Language becomes `ChromeMenuField`;
  - Sign In… and Cancel become `.chromeSecondary`, and Open becomes `.chromePrimary`, with shortcuts and the disabled rule unchanged;
  - the spinner becomes `ChromeSpinner`, marked hidden or labelled per decision 8.
- [x] **`LeetCodeCommands`:** the `Divider()` becomes two `Section { }` groups (decision 1). The shortcuts stay, and `MenuShortcutUniquenessTests` must stay green.
- [x] **The sign-in sheet:** the header and footer are on `bgPanel`, the captions `textSecondary`, Cancel `.chromeSecondary`, and the two `Divider()`s become hairlines.
- [x] Add the four files to `gatedFiles`. Update:
  - rule twenty (the statement pane's buttons; the spinners' construction markers);
  - rule twenty-two (`LeetCodeDescriptionView.swift: syncResizeHandleCursor`);
  - rule twenty-six (sheet and judge);
  - rule thirty (callers and the two-number table);
  - rule thirty-four;
  - rule thirty-seven;
  - the spinner classification table (the judge's and the sheet's rows), which now covers all twenty sites.
  (Rule twenty names the header, the collapsed strip and the shared hidden `iconGlyph(`. Rule twenty-six: eleven callers, the sheet's input through the themed field and the judge's test-case box through the box alone; both `core-theme.md` passages updated. Rule thirty: the statement pane 3/3 (`.plain`), the judge 2/2, the sheet 8/3 with `LeetCodeCommands`' five menu items unstyleable, the sign-in sheet 1/1; `chromePrimary` gains the sheet and `chromeSecondary` the judge, the sheet and the sign-in sheet. Rule thirty-four needed no exemption: every glyph takes its own scaled font. Rule thirty-seven: one `ChromeMenuField` in the sheet, beside a visible "Language" caption hidden from accessibility, since the field speaks the name. Rule twenty-four: the sheet's file builds no `Menu`, so neither menu set moves. Spinner rows: the judge's and the sheet's are each hidden, because "Running…"/"Submitting…" and "Fetching from LeetCode…" stand beside them.)
- [x] Run `swift test` and the macOS build. Both must pass. `LeetCodeAccountSourceGatingTests` and `ZoomSourceGatingTests` must stay green.

### Task 7: The four new rules, each shown red first

**Files:**

- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`
- Modify: `docs/architecture/core-theme.md` (canonical list items 38–41)
- Modify: `CLAUDE.md` (the rule count only)
- [x] **Rule thirty-eight: no gated file builds a platform table.**
  - No gated file spells `Table` or `TableColumn` (through `containsToken`, so `LazyVStack` and the identifiers holding "Table" are not hits; confirm against the tree).
  - `LeetCodeBrowserView.swift` spells `LazyVStack`.
  - The comment says a `Table`'s header, grounds, alternation and selection box are the platform's, which is the wall rule thirty-six names for form controls.
- [x] **Rule thirty-nine: the problem catalog's three colour mappings are Core's one answer each.**
  - No app file declares `func difficultyRole`, `func problemStatusRole` or `func verdictRole`.
  - The app files spelling `difficultyRole(for:` and `problemStatusRole(for:` equal `{LeetCodeBrowserView.swift}`, and `verdictRole(for:` equals `{LeetCodeJudgeView.swift}`. The iOS browser keeps its own table and is not gated; say so.
  - No gated file spells `isGood` or `isAccepted`.
  - The difficulty and status case labels are pinned by count per gated file (the browser's title tables and glyph switch; zero elsewhere), with rule eighteen's stated limit.
- [x] **Rule forty: one spinner.**
  - No gated file spells `ProgressView` or `progressViewStyle`.
  - The files spelling `ChromeSpinner` are pinned by set equality, `ChromeControls.swift` included.
  - Each caller file is pinned as a pair — how many of its constructions are `.accessibilityLabel(` and how many `.accessibilityHidden(` — read from each construction's trailing modifier chain with rule twenty's clause. The pairs sum to twenty, so a site cannot silently swap one marker for the other, drop both, or appear without moving a number.
- [x] **Rule forty-one: no alternating row fill.**
  - No gated file spells `alternatingRowBackgrounds`, `isMultiple` or `isTinted`.
  - The comment says the design's tables read by selection and hover, and that the platform's own alternation left with the `Table` (rule thirty-eight).
- [x] Extend `spelled` to forty-one. Add header bullets titled as the four markers, canonical items 38–41 in `core-theme.md`, and set `CLAUDE.md`'s count to "forty-one", so the four count checks agree.
- [x] **Mutation-verify.** Confirm each regression below is red, then revert: (All sixteen red, each against its own rule, and reverted. The per-file pair check moved from rule twenty's clause into rule forty, which now reads `spinnerClassification`; rule twenty keeps the exactly-one-marker check, both through the shared `spinnerMarkers(in:)`.)
  - **38:** a `Table(rows) {` in the browser.
  - **39:** a `color(for:)` switch restored in the browser; a second `difficultyRole(for:` reader; `isGood` restored in the judge.
  - **40:** a `ProgressView()` in `UsagesPanelView`; a `ChromeSpinner` added to an unpinned file; a second spinner in a pinned file; a hidden spinner in the Log switched to `.accessibilityLabel(` (the file's pair moves). (The Log's two spinners are both labelled, so the inverse was run: one switched to `.accessibilityHidden(`, and the pair moved.)
  - **Rule twenty's spinner clause:** a `ChromeSpinner()` with neither `.accessibilityLabel(` nor `.accessibilityHidden(` on its modifier chain; a `ChromeSpinner()` carrying both.
  - **41:** a `.background(index.isMultiple(of: 2) ? …)` in the console.
  - **Rule thirty-five:** a `listRowBackground` in the sidebar.
  - **Rule thirty-two:** an `@Environment(\.chromeTheme)` on the browser root.
  - **Rule twenty-two:** the statement pane's `onDisappear` sync call removed.
  - **Rule twenty-four:** a `Divider()` back in `LeetCodeCommands`.
  - **Rule one:** `.foregroundStyle(.secondary)` in the login view.
- [x] Confirm `git status` is clean apart from the intended changes.
- [x] Run `swift test`. It must pass.

### Task 8: Verify acceptance criteria

- [x] Run `swift test`. It must pass.
- [x] Run `xcodegen generate`, then the app bundle: `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-part5d test`. It must pass.
- [x] Run `swiftlint --strict` from the repository root. It must report zero violations.
- [x] Build macOS Release (`-configuration Release`) and iOS (`generic/platform=iOS`), both with derived data under `~/Library/Developer/Xcode/DerivedData/`.
- [x] Grep-confirm the remaining acceptance points:
  - `gatedFiles` holds 58 files;
  - none of the seven spells a system colour, a hex literal, `isTinted`, `Table(`, `Picker(`, `Toggle(`, `Stepper(`, `Form`, `TabView`, `Divider(` or `ProgressView`;
  - `ChromeColorRole` has 21 cases;
  - `currentLine` and `bracketMatch` have no reader outside the palette;
  - every `.frame(` added in the seven files names `metrics`;
  - every `ChromeSpinner(` construction carries exactly one of the two accessibility markers;
  - the count reads forty-one in the markers, the header, `core-theme.md` and `CLAUDE.md`.

### Task 9: Documentation

- [x] **`docs/architecture/core-theme.md`:**
  - a part five (d) section: the spinner and its tokens, including the call-site accessibility contract (hidden beside a sentence, labelled alone, no default); the three answers; decisions 1–18; the zebra's removal and why no wash role exists; the banner's ground;
  - rules 20, 22, 24, 26, 30, 32, 34, 35 and 37 updated to their new pins (rule twenty's spinner clause checked at constructions);
  - rules 38–41 in the canonical list;
  - the swept-surfaces list extended;
  - open questions: the spinner question closed; `VSplitView`/`HSplitView` carried; the platform focus ring on the grid's cells and the browser's list; the two served documents' palette (the pane themed, the page not); the terminal's colours; the remaining carried items unchanged.
- [x] **`core-database-viewer.md`:** the viewer's and the console's entries (the banner, NULL's two roles, hover and the focused cell, no alternation, the plain sidebar list, the shared cell editor). The two writes and the gate are unchanged, and the entries say so.
- [x] **`core-leetcode.md`:** the browser's rows (keyboard, accessibility, the dropped column resize), the checkboxes and menu field, the three Core answers, the statement pane's resize handle, the judge's verdict rule now in Core, the commands' `Section`s, and the statement page staying unthemed.
- [x] **`CLAUDE.md`:**
  - the chrome invariant: forty-one rules, fifty-eight files, part five (d)'s surfaces added to the swept list, the rule summaries for 38–41, and "leaving two roles unspent" kept;
  - the `ChromeControls.swift` index line names the spinner;
  - the `ChromeColorRole.swift` line mentions the catalog's answers.
- [x] Run `swift test` once more, since the documentation checks read these files.

## Post-Completion

These items need a running app and a person; they are not automatable.

- Open a `.sqlite` file in both appearances:
  - hover rows, focus a cell, edit a cell, run a console read and a confirmed mutation;
  - trigger an error and check the banner.
- Open the browser (⌘⇧B):
  - move with the arrow keys and open with Return, double-click and the context menu;
  - toggle the filters;
  - check a Premium row's lock.
- Open a problem, then Run and Submit in the judge. Collapse and resize the statement pane.
- Step the interface zoom to 200%. Confirm that no browser row, header or spinner is clipped.
- Use VoiceOver on a browser row: it speaks its cells, its selection and the Open action.
