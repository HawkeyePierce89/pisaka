# Chrome theme, part four (b): the Log, Local Changes and Pull Requests panels

## Overview

This part finishes the bottom dock's chrome sweep. The Log panel (with its branch-graph gutter and filter bar), the Local Changes panel and the Pull Requests panel move onto `ChromeColorRole` / `ChromeGeometry`. So do the side-by-side diff pane and the unified diff's row wash. Colour tables that exist in more than one copy each become one Core answer, and the changed-file letter moves to Core with them:

- the changed-file status colour and its letter;
- the checks-state colour;
- the diff row wash.

The part spends the two diff background roles and adds no role. The branch-graph lane palette becomes the fourth stated colour exemption. The gating suite grows from sixteen rules to twenty, and every new rule is shown to fail against a deliberate break.

Decisions settled during planning. Each one departs from the ticket's wording. The plan follows the decision, and the final report names each difference.

- **Graph gutter geometry.**
  - Lines become 2 pt and the node dot 6 pt (radius 3). Lane spacing stays 14 pt.
  - 40 pt is the gutter's minimum width. It still grows with the lane count: `max(40, lanes × 14 + 6)`, scaled.
- **The lane hues are carried over, not redesigned.** The eight lane colours are today's system values, written out as light/dark pairs. Nobody chose them against the design's ground. Keeping them is deliberate: it keeps this step a refactor off the system colours with no visual change to the gutter. Choosing hues that sit on the design's ground is recorded as an open design question.
- **Local Changes keeps its current structure.**
  - It stays a single list, and the diff still opens in its own window.
  - Commit becomes the toolbar's primary button. The flat/by-folder picker and the refresh glyph stay, restyled.
  - No revert glyph is added.
  - The side-by-side pane is restyled where it already lives, in the diff and history windows. It gets no file-path header.
- **The Log gains a static column-header row** with four labels: Hash, Message, Author, Date.
  - It is non-interactive and has no sorting.
  - It uses the rows' own column widths. "Message" starts where the ref badges and subject start, after the graph and hash columns.
- **The Log keeps today's short date+time format**, not a relative date.
- **The filter bar keeps all its controls**: the branch picker, the author field, the path field, the message search field and the two date pickers. The design's field and picker styles are applied by control kind.
- **The expanded job row keeps today's text** (name, workflow, description).
  - No duration is drawn, because `GitHubCheckRow` carries none.
  - The job's state is spoken as an accessibility value.
- **Context-menu `Divider()`s become `Section` groupings.** The two in Local Changes become sections, which render the same menu separators. No `Divider()` remains and the menus don't change.
- **The unified diff view is gated in full.** Once it joins the gated set, its three other colour sites (the checkbox's two tints and the line-number colour) also become roles. The commit dialog around it is untouched.
- **The commit dialog reads the new Core answers.** It shares the status helpers being deleted, so it now reads the Core letter and colour. Nothing else in the dialog changes; the rest is part five.
- **A macOS diff side is one type.** Core's `DiffSide` replaces `DiffTextView.Side` outright, so no mapping site exists to drift.
  - The iOS diff view keeps its own private `enum Side`: it has no chrome palette and is not gated.
  - Core's private `ThreeWayMerge.Side` (ours/theirs) answers a different question, merge sides rather than diff sides. It is left alone.
- **The iOS layer keeps its private tables.** It has no chrome palette, so the new rules apply only to the gated macOS files.

## Context

- Files involved:
  - Core: `Sources/PisakaCore/ChromeColorRole.swift`, `ChromeGeometry.swift`, `ChangedFile.swift`, `GitHubPullRequest.swift`, `LineDiff.swift`
  - App:
    - `Sources/Pisaka/CommitLogView.swift`, `CommitGraphView.swift`, `LogFilterBar.swift`
    - `LocalChangesView.swift`, `DiffView.swift`, `CommitUnifiedDiffView.swift`
    - `PullRequestsPanelView.swift`, `PullRequestIndicatorView.swift`
    - `CommitDialogView.swift` (reader only)
    - new `CommitGraphPalette.swift`
  - Tests:
    - `Tests/PisakaCoreTests/ChromeThemeTests.swift`
    - `ChromeThemeSourceGatingTests.swift`
    - Core tests for `FileStatus`, the checks vocabulary and `LineDiff`
    - new `Tests/PisakaAppTests/CommitGraphPaletteTests.swift`
  - Docs:
    - `docs/architecture/core-theme.md`, `app-git-views.md`, `core-github.md`, `core-git.md`, `core-diff-merge.md`
    - `CLAUDE.md`
- Related patterns (the precedents this part copies):
  - Part four (a)'s `ChromeColorRole.diagnosticRole(for:)`: one Core answer, a readers set pinned by equality, and a case-label regex over the gated files.
  - The `ProblemsPanelView` / `UsagesPanelView` restyle: `@Environment(\.chromeTheme)`, `metrics.scaledFont(...)`, private `Layout` enums, and hairlines drawn by overlay.
  - `LineNumberRulerView`: an AppKit code-zoom surface that reads `ChromePalette.nsColor(_:)` and draws its hairline unscaled.
  - The bottom-bar accessibility rules (10, 11 and 13).
  - `SyntaxTheme`, `TerminalTheme` and `FileIcon` as the existing colour exemptions.
- Dependencies: none new.

## Development Approach

- **Testing approach**: Regular (code first, then tests).
  - The Core mappings are tested in Core.
  - The lane table is tested in the app bundle.
  - The gating rules are tested by live mutation.
- Complete each task fully before moving to the next.
- `swift test` is the fast gate after every task. The app-layer bundle and the builds run in Task 8.
- Build products live outside the repository: `-derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-<purpose>`.
- Every value is written into this plan as a literal.
- Font sizes map onto the existing interface styles:
  - 12.5 → `.body`
  - 12 → `.callout`
  - 11.5 and 11 → `.subheadline`
  - Monospaced text asks for the monospaced design of the same style.
  - No token holds a font size.
- No brand or product names anywhere: plan, code, comments, docs, commit messages.
- **CRITICAL: every task MUST include new/updated tests**
- **CRITICAL: all tests must pass before starting next task**

## Implementation Steps

### Task 1: Core — the new Core answers and the two new geometry tokens

**Files:**
- Modify: `Sources/PisakaCore/ChromeColorRole.swift`, `ChangedFile.swift`, `GitHubPullRequest.swift`, `LineDiff.swift`, `ChromeGeometry.swift`
- Modify: `Tests/PisakaCoreTests/ChromeThemeTests.swift`, plus either the existing `ChangedFile`, GitHub-vocabulary and `LineDiff` test files or a new `ChromeRoleMappingTests.swift`

- [x] **`FileStatus` gains `letter` and `spokenName`:**
  - `letter`: M/A/D/R/U/C for modified/added/deleted/renamed/untracked/conflicted.
  - `spokenName`: "Modified", "Added", "Deleted", "Renamed", "Untracked", "Conflicted".
  - The doc comment says the letter carries the identity and the colour carries the weight.
- [x] **`ChromeColorRole.changedFileRole(for: FileStatus)`**, in the same extension as `diagnosticRole(for:)`:
  - added → `statusGreen`
  - modified, renamed → `statusYellow`
  - deleted, conflicted → `statusRed`
  - untracked → `textSecondary`
- [x] **`ChromeColorRole.checksRole(for: GitHubChecksSummary)`**:
  - noChecks → `textSecondary`
  - pending → `statusYellow`
  - failure → `statusRed`
  - success → `statusGreen`
- [x] **`ChromeColorRole.checksRole(for: GitHubCheckBucket)`**:
  - pass → `statusGreen`
  - fail → `statusRed`
  - pending → `statusYellow`
  - skipping, cancel → `textSecondary`
- [x] **The checks glyphs and words move to Core**, because the new case-label rule forbids views from spelling these cases:
  - `GitHubChecksSummary.symbolName`: noChecks "circle", pending "clock", failure "xmark.circle.fill", success "checkmark.circle.fill". "circle" is the indicator's documented choice, and the panel's "minus.circle" is unified onto it.
  - `GitHubChecksSummary.spokenWords`: "No checks" / "Checks running" / "Checks failed" / "Checks passed".
  - `GitHubCheckBucket.symbolName`: pass "checkmark.circle.fill", fail "xmark.circle.fill", pending "clock", skipping "minus.circle", cancel "slash.circle".
  - `GitHubCheckBucket.spokenWords`: "Passed" / "Failed" / "Running" / "Skipped" / "Cancelled".
- [x] **`public enum DiffSide { case old, new }`** in `LineDiff.swift`. This is the one definition of a diff side for the macOS surfaces; Task 5 deletes the app's `DiffTextView.Side` in its favour.
- [x] **The diff wash functions:**
  - `ChromeColorRole.diffWashRole(for: DiffRowKind, side: DiffSide) -> ChromeColorRole?`:
    - unchanged → nil
    - old side: removed and modified → `diffRemovedBackground`; added → nil (the filler row is plain)
    - new side: added and modified → `diffAddedBackground`; removed → nil
  - `diffWashRole(for: UnifiedDiffLine.Kind)`: context → nil, removed → `diffRemovedBackground`, added → `diffAddedBackground`.
  - `diffMarkerRole(for: DiffRowKind, side: DiffSide)`: `statusRed` on the old side for removed and modified, `statusGreen` on the new side for added and modified, nil otherwise.
- [x] **Update the `ChromeColorRole` doc comment's unspent list.** Six unspent roles become four: `bgPopover`, `currentLine`, `bracketMatch`, `conflictBackground`.
- [x] **Two new `ChromeGeometry` tokens**, each documented as its own measurement:
  - `buttonPaddingX = 10`: a chrome push button's horizontal padding, shared by the Local Changes toolbar and the pull-request rows. It is deliberately a separate token from `dockTabRowPaddingX` / `dockTabLabelPaddingX`, even though the values are equal.
  - `buttonCornerRadius = 5`.
  - Amend `cornerRadiusMax`'s "square or this" sentence so it names the small control radii honestly.
- [x] **Tests:**
  - Pin every answer verbatim over `allCases`, both `DiffSide` cases included.
  - Assert the filler cases answer nil.
  - Add both tokens to `ChromeThemeTests`' inventory by set equality.
- [x] Run `swift test` — must pass before Task 2.

### Task 2: The lane palette as the fourth exemption, and the gutter geometry

**Files:**
- Create: `Sources/Pisaka/CommitGraphPalette.swift`, `Tests/PisakaAppTests/CommitGraphPaletteTests.swift`
- Modify: `Sources/Pisaka/CommitGraphView.swift`, `Sources/Pisaka/CommitLogView.swift` (gutter width only)

- [ ] **Create `CommitGraphPalette`**: macOS-gated, one exhaustive light/dark table of eight lane identities. The values are today's eight system colours written out as light/dark pairs:
  - blue 0x007AFF / 0x0A84FF
  - green 0x28CD41 / 0x32D74B
  - orange 0xFF9500 / 0xFF9F0A
  - purple 0xAF52DE / 0xBF5AF2
  - red 0xFF3B30 / 0xFF453A
  - teal 0x30B0C7 / 0x40C8E0
  - pink 0xFF2D55 / 0xFF375F
  - yellow 0xFFCC00 / 0xFFD60A
- [ ] It answers `nsColor(forLane:)` with a dynamic `NSColor` resolved at draw time. The index wraps modulo the count, and negative indices still work, as today.
- [ ] Its doc comment states:
  - A lane colour is an identity token, not a chrome meaning (the ANSI-16 argument).
  - Pressing a lane into `statusRed` would be the misuse the closed vocabulary exists to prevent.
  - The design's two lane colours cannot tell several concurrent branches apart.
  - The eight hues are today's system values, carried over deliberately so this step changes nothing visually in the gutter. They were not chosen against the design's ground; choosing hues that sit on it is an open design question.
- [ ] **`CommitGraphView`**:
  - It reads `CommitGraphPalette` and keeps no palette of its own. After this task it spells no colour at all.
  - Line width becomes 2 and node radius 3 (a 6 pt dot). Lane spacing stays 14.
- [ ] **Gutter width in `CommitLogView`**: `max(40, laneCount × 14 + 6)`, scaled at the use site. The 40 is a minimum in a private `Layout` enum, not arithmetic on a token.
- [ ] **App-layer test `CommitGraphPaletteTests`**:
  - Both sets have eight entries, pairwise distinct within each set.
  - The dynamic colour resolves to the light value under the light appearance and to the dark value under the dark appearance.
  - A negative index and index 8 both wrap.
- [ ] Run `swift test` — must pass before Task 3. The app bundle runs in Task 8.

### Task 3: The Log panel — rows, header row, detail pane and filter bar

**Files:**
- Modify: `Sources/Pisaka/CommitLogView.swift`, `Sources/Pisaka/LogFilterBar.swift`

- [ ] **Remove the private tables.** Delete `commitStatusColor` / `commitStatusLetter`. The detail pane's file rows read `status.letter` and `theme.color(.changedFileRole(for:))`, with `status.spokenName` as the accessibility value.
- [ ] **Row washes**:
  - Selection is `accentTintStrong`, hover is `hoverTint`.
  - A selection in a window that is not key follows the Problems panel's precedent.
  - The 0.25 / 0.15 accent opacities are deleted.
- [ ] **Ref badges**: `accentTint` ground and `accent` text. No opacity is computed.
- [ ] **Commit row**: 25 pt tall, 12 pt horizontal padding and a 16 pt column gap, in a private `Layout`, scaled. Text:
  - message: `textPrimary`, `.body`
  - author and date: `textSecondary`, `.callout`
  - hash: `textSecondary`, `.subheadline`, monospaced
- [ ] **Static header row** above the rows:
  - 24 pt tall, 12 pt padding, 16 pt gap, bottom hairline by overlay.
  - Labels Hash / Message / Author / Date in `textSecondary`, `.subheadline`, semibold, one line each, over an empty graph column.
  - It uses the rows' own column widths. "Message" sits where the ref badges and subject start.
  - It is non-interactive.
- [ ] **Replace the three `Divider()`s** with the owning surface's own `hairline`: an overlay on the bottom or trailing edge, `hairlineWidth` scaled. This includes the divide between the list and the detail pane.
- [ ] **Filter bar strip**:
  - Height `panelHeaderHeight` (28, the panel's header strip), private padding 10 and gap 10, `bgPanel` ground, bottom hairline by overlay.
  - Text fields: the message search is 220 × 22; the author and path fields keep their current widths at 22 tall. Each field has:
    - a 4 pt radius (private), a `bgEditor` ground and a 1 pt `hairline` border;
    - where a magnifier glyph is drawn, 6 pt between it and the text, and 8 pt horizontal padding;
    - placeholder in `textSecondary` `.callout`, text in `textPrimary` `.callout`;
    - on focus, a 2 pt `accent` border in place of the hairline.
  - The branch picker and the two date pickers use the same 22 pt box, radius, border, padding and inner gap. The label is `textPrimary` `.callout`, the chevron `textSecondary`, and the system control inside is drawn borderless.
  - Every label stays on one line.
- [ ] **No leftover platform colours**: neither file keeps a system semantic colour, the accent colour, an opacity computed off a system colour, or a hex literal.
- [ ] **Tests**: extend the Core tests only if Task 1 missed a case this view reads. This task is view glue; its rules are pinned in Task 7.
- [ ] Run `swift test` — must pass before Task 4.

### Task 4: The Local Changes panel (and the commit dialog's two reads)

**Files:**
- Modify: `Sources/Pisaka/LocalChangesView.swift`, `Sources/Pisaka/CommitDialogView.swift`

- [ ] **Delete the shared helpers**: the internal `statusColor(_:)` / `statusLetter(_:)` and the private `iconColor(for:)`.
  - Local Changes and the commit dialog read `status.letter`, `theme.color(.changedFileRole(for:))` and `status.spokenName`.
  - The commit dialog changes nothing else.
- [ ] **Toolbar**, replacing today's header:
  - 32 pt tall, 10 pt padding, 8 pt gap (private), bottom hairline by overlay.
  - Commit becomes the primary button: `accent` ground, `onAccent` label in `.subheadline` semibold, `buttonPaddingX`, `buttonCornerRadius`.
  - The flat/by-folder picker is restyled.
  - Refresh is a 15 pt `textSecondary` glyph with an accessibility label and its symbol hidden.
- [ ] **Folder header**: 22 pt tall, 10 pt padding, 6 pt gap. The folder glyph is `textSecondary` (monochrome, like the Problems headers); the name is `textSecondary` `.subheadline` monospaced.
- [ ] **File row**: `rowHeight` (24).
  - Leading inset: 26 pt in the by-folder grouping, 10 pt in the flat one.
  - Checkbox: drawn at 14 pt with a 3 pt radius (private). Off, it has a `hairline` border; on, an `accent` ground with an `onAccent` check. Its accessibility label says whether the file is included, and it speaks on/off as its value.
  - Status letter: `.callout` monospaced semibold, in the status role, with `spokenName` as its accessibility value.
  - File glyph: `textSecondary`. File name: `textPrimary` `.body`.
- [ ] **Row washes**: `accentTintStrong` / `hoverTint`.
- [ ] **Dividers**: the header `Divider()` becomes a hairline. The two context-menu `Divider()`s become `Section` groupings, which render the same separators.
- [ ] **No leftover platform colours** in `LocalChangesView.swift`.
- [ ] **Tests**: Task 1 already covers the Core side. Confirm no Core test depended on the deleted helpers.
- [ ] Run `swift test` — must pass before Task 5.

### Task 5: The diff pane and the unified diff's wash

**Files:**
- Modify: `Sources/Pisaka/DiffView.swift`, `Sources/Pisaka/CommitUnifiedDiffView.swift`

- [ ] **Delete `DiffTextView.Side`.** Today it is declared and used in `DiffView.swift` alone:
  - the declaration at line 281;
  - `makePane(side:)`;
  - the gutter's stored `side` and its `init`;
  - `background(for:side:)` and `markerColor(for:side:)`.

  All of these now name Core's `DiffSide`, and the `.left`/`.right` calls become `.old`/`.new`. After this, the macOS diff surfaces have one side type with one definition, and no mapping site. `Sources/Pisaka/iOS/DiffView_iOS.swift`'s private `enum Side` and Core's private `ThreeWayMerge.Side` are not touched.
- [ ] **Delete the local tables.** `DiffColors` goes.
  - The row background reads `ChromePalette.nsColor(_:)` of `ChromeColorRole.diffWashRole(for:side:)`.
  - The marker strip reads `diffMarkerRole(for:side:)`.
  - The filler row carries no wash; the grey at 0.12 goes.
- [ ] **Gutter and divider**:
  - Gutter line numbers use `nsColor(.textSecondary)` instead of `secondaryLabelColor`.
  - The `NSBox` separator between the panes becomes a plain view filled with `nsColor(.hairline)`, `hairlineWidth` wide, drawn unscaled under the stated code-zoom exception.
  - The characters keep `SyntaxTheme`.
- [ ] **`CommitUnifiedDiffView`**:
  - The row background reads `diffWashRole(for: UnifiedDiffLine.Kind)` through the theme. The 0.14 alphas go.
  - Its three other colour sites become roles: the checkbox (`accent` / `textSecondary`) and the line number (`textSecondary`).
  - Nothing else in the dialog changes.
- [ ] **No leftover platform colours** in either file, and no `withAlphaComponent`.
- [ ] **Tests**: Task 1's wash and marker tests cover both `DiffSide` cases. Search to confirm that neither `DiffView.swift` nor `CommitUnifiedDiffView.swift` declares a `Side` enum, and that no macOS file under `Sources/Pisaka` (outside `Sources/Pisaka/iOS/`) spells `DiffTextView.Side`. Task 7 pins this as a gating rule.
- [ ] Run `swift test` — must pass before Task 6.

### Task 6: The Pull Requests panel and the indicator's reads

**Files:**
- Modify: `Sources/Pisaka/PullRequestsPanelView.swift`, `Sources/Pisaka/PullRequestIndicatorView.swift`

- [ ] **Delete the view tables**: `summarySymbol`, `summaryColor`, `summaryHelp`, `bucketSymbol` and `bucketColor` go from the panel; `symbol`, `role` and `summaryWords` go from the indicator. Both files read the Core glyph, role and words.
- [ ] **Header strip**:
  - `panelHeaderHeight` / `panelHeaderPaddingX`, bottom hairline by overlay.
  - Repository and open count: `textPrimary` `.body` semibold, one line.
  - A trailing refresh glyph in `textSecondary`, with an accessibility label and its symbol hidden.
- [ ] **Pull-request row**: 40 pt tall, 14 pt padding, 12 pt gap (private), bottom hairline. Parts in order:
  - a disclosure chevron, named "Expand"/"Collapse" and speaking expanded as its value;
  - the number: `textSecondary` `.callout` monospaced;
  - the title: `textPrimary` `.body`;
  - the author: `textSecondary` `.callout`;
  - the branch pair: `textSecondary` `.subheadline` monospaced;
  - the checks glyph in `checksRole(for:)`, labelled "Checks" with `spokenWords` as its value;
  - a secondary button: `hairline` border, `textPrimary` `.subheadline`, `buttonCornerRadius`, `buttonPaddingX`;
  - a primary button: `accent` ground, `onAccent` `.subheadline` semibold.
- [ ] **Row washes**: `accentTintStrong` / `hoverTint`. The 0.18 / 0.10 opacities go.
- [ ] **Expanded job row**:
  - 22 pt tall, leading inset 58 (private).
  - A 6 pt dot in `checksRole(for: bucket)`, hidden from accessibility. The row speaks the bucket's `spokenWords` as its value.
  - Name: `textPrimary` `.subheadline` monospaced. Workflow and description: `textSecondary` `.subheadline`.
- [ ] **Message and wait-ending strips**: the orange glyph becomes `statusYellow` on a `bgPanel` ground with a bottom hairline. The orange 0.12 / 0.08 washes go, as does the secondary 0.12 wash.
- [ ] **Tags**:
  - Review decisions are drawn as role-coloured text inside a `hairline`-bordered capsule with no fill: approved `statusGreen`, changes requested `statusRed`, review required `statusYellow`.
  - Neutral tags use `textSecondary`.
- [ ] **Divider**: the one `Divider()` becomes a hairline.
- [ ] **No leftover platform colours** in `PullRequestsPanelView.swift`. The indicator stays gated and clean.
- [ ] **Tests**: Task 1's Core tests cover the glyphs, words and roles.
- [ ] Run `swift test` — must pass before Task 7.

### Task 7: The gating suite — sixteen rules become twenty, each shown to bite

**Files:**
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`
- Modify: `docs/architecture/core-theme.md` (canonical list), `CLAUDE.md` (the rule-count sentence)

- [ ] **`gatedFiles` grows from twenty to twenty-seven.** Add `CommitLogView.swift`, `CommitGraphView.swift`, `LogFilterBar.swift`, `LocalChangesView.swift`, `DiffView.swift`, `CommitUnifiedDiffView.swift` and `PullRequestsPanelView.swift`.
  - `CommitGraphView.swift` is gated unconditionally. Being in the set enforces only the two negative rules (`testNoGatedFileNamesASystemSemanticColor`, `testOnlyThePaletteSpellsAHexColorLiteral`), and nothing requires a gated file to name a role.
  - After Task 2 the graph view spells no colour at all, which is the point.
  - It never enters `colorExemptions`: rule three asserts the two sets are disjoint.
- [ ] **Rule three: the four exemptions.**
  - `colorExemptions` gains `CommitGraphPalette.swift`, with its reason: a lane colour is an identity token, not a chrome meaning.
  - The rule's wording and messages change from three to four.
- [ ] **Existing lists grow**, each by name:
  - `iconNamers` goes from five to seven (`CommitLogView.swift`, `LocalChangesView.swift`).
  - `dockRuleOwners` gains the four panel files plus `LogFilterBar.swift`.
  - A new clause: `DiffView.swift` spells no `NSBox`.
  - The single-line rule's `headerBuilderFiles` gains the PR header and row builders, the filter bar, the Log header row and the Local Changes toolbar.
  - `indicatorStripFiles` is unchanged.
- [ ] **New rule seventeen: the changed-file status mapping is Core's one answer.**
  - No app file declares `func changedFileRole` or a `letter` table.
  - The readers of `changedFileRole(for:` equal `{CommitLogView.swift, LocalChangesView.swift, CommitDialogView.swift}`.
  - No gated file spells a case label naming `.renamed`, `.untracked` or `.conflicted`, or a qualified `FileStatus.` case.
  - Stated limit: `.added`, `.modified` and `.deleted` are also diff-kind case names, so the rule does not match them.
- [ ] **New rule eighteen: the checks-state mapping is Core's one answer.**
  - No app file declares `func checksRole`.
  - The readers equal `{PullRequestIndicatorView.swift, PullRequestsPanelView.swift}`.
  - No gated file spells a case label naming noChecks, pending, failure, success, pass, fail, skipping or cancel, or a qualified `GitHubChecksSummary.` / `GitHubCheckBucket.` case.
  - Stated limit: the same case-label shapes rule fifteen cannot see.
- [ ] **New rule nineteen: the diff row wash is Core's one answer, and a macOS diff side is Core's one type.**
  - No app file names `diffAddedBackground` / `diffRemovedBackground` directly.
  - No app file declares `func diffWashRole` / `func diffMarkerRole`.
  - The readers of `diffWashRole(for:` equal `{DiffView.swift, CommitUnifiedDiffView.swift}`.
  - Neither file spells `withAlphaComponent(` or `.opacity(`.
  - The side clause covers the macOS diff surfaces only:
    - Neither `DiffView.swift` nor `CommitUnifiedDiffView.swift` declares an `enum Side`.
    - No file under `Sources/Pisaka` outside `Sources/Pisaka/iOS/` spells `DiffTextView.Side`. Today `DiffView.swift` is the only macOS file that passes a side, so this also catches a new macOS caller that brings the old type back.
    - The clause never reads `Sources/PisakaCore`.
  - The rule's own message states both limits:
    - The iOS diff view has no chrome palette to read and is not gated, so its private `Side` is not the duplicate this rule is about.
    - Core's private `ThreeWayMerge.Side` names merge sides, not diff sides, and is a different question.
- [ ] **New rule twenty: the three panels' controls are identifiable without sight.** It keeps a named builder list per panel file, in the same shape as rule ten:
  - each icon-only control's builder carries `.accessibilityLabel(`;
  - the checks glyph, the status letter, the checkbox and the disclosure chevron carry `.accessibilityValue(`;
  - every `Image(systemName:` inside a labelled control's body is followed by `.accessibilityHidden(true)`;
  - a renamed builder fails loudly.
- [ ] **Bookkeeping**:
  - Extend `spelled` to twenty.
  - Update `core-theme.md`'s canonical list to "The twenty rules, each invisible to the compiler:" with items 1–20. Rule three names four exemptions; rules 17–20 are new.
  - Update `CLAUDE.md`'s "and its twenty rules".
- [ ] **Live mutation for each new or grown rule.** For each one: break the named code, run `swift test --filter ChromeThemeSourceGatingTests` and confirm red. Then restore it, confirm green, and check that `git status` shows no source changes. The breaks:
  - re-add a local status `switch` in `LocalChangesView`;
  - add a `case .pending` colour table to the panel;
  - add a `withAlphaComponent` wash to `DiffView`;
  - re-declare `enum Side` inside `DiffTextView`;
  - spell `DiffTextView.Side` in a scratch line of another macOS file under `Sources/Pisaka`;
  - drop an `accessibilityLabel` from the refresh glyph;
  - put a `Divider()` back in `LogFilterBar`;
  - add `CommitGraphPalette.swift` to `gatedFiles` (the disjointness collision);
  - put an `NSBox` back in `DiffView`.
- [ ] Also confirm rule nineteen is green against today's `Sources/Pisaka/iOS/DiffView_iOS.swift` (line 218's `enum Side`) and `Sources/PisakaCore/ThreeWayMerge.swift` (line 29's `enum Side`), both unchanged.
- [ ] Run `swift test` — must pass before Task 8.

### Task 8: Verify acceptance criteria

- [ ] Run `swift test` and report the counts.
- [ ] Run `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-test test` and report the app-bundle counts, including `CommitGraphPaletteTests`.
- [ ] Run `swiftlint --strict` from the repository root; it must be clean.
- [ ] Run the macOS Release build (`-configuration Release`) and the iOS build (`generic/platform=iOS`), both with derived data outside the repository.
- [ ] Search the seven newly gated files: no `Color.accentColor`, no system semantic colour, no hex literal, no `Divider()`.
- [ ] Confirm that:
  - each new Core answer (status colour, status letter, checks colour, diff wash) has exactly one definition;
  - the two diff roles have readers;
  - `DiffSide` is the only diff-side type on the macOS diff surfaces;
  - `ChromeColorRole.allCases.count` is still 21.

### Task 9: Update documentation

- [ ] **`docs/architecture/core-theme.md`**:
  - A new "Part four (b)" section:
    - the surfaces swept;
    - the diff roles spent, leaving four unspent;
    - the two new tokens;
    - the new Core answers;
    - the lane palette as the fourth exemption, with its reason.
  - The section records that the eight lane hues are today's system values, carried over deliberately so the gutter changes nothing visually. Choosing hues that sit on the design's ground is named as an open design question.
  - A `CommitGraphPalette.swift` entry. (Task 7 already updated the canonical list.)
- [ ] **`app-git-views.md`**: entries for:
  - `CommitLogView`: the header row and the gutter minimum;
  - `CommitGraphView`: the geometry, and that it reads the lane table and spells no colour;
  - `LogFilterBar`;
  - `LocalChangesView`: the toolbar, the Section menus and the Core reads;
  - `DiffView`: the roles, no filler wash, the unscaled hairline, and `DiffSide` replacing `DiffTextView.Side`. The entry notes that the iOS diff view keeps its own private side type;
  - `CommitUnifiedDiffView`;
  - `CommitDialogView`'s two reads.
- [ ] **`core-github.md`**: the checks glyph, words and role now live in Core with three readers; the panel's restyle; the indicator's reads.
- [ ] **`core-git.md`**: `FileStatus.letter` / `spokenName`.
- [ ] **`core-diff-merge.md`**: `DiffSide`, the one diff-side type, which the macOS app uses directly. The entry notes that it is unrelated to `ThreeWayMerge`'s private merge-side enum.
- [ ] **`CLAUDE.md`**:
  - Add an index line for `CommitGraphPalette.swift` under the chrome theme's app surfaces.
  - Update the chrome invariant:
    - twenty rules and twenty-seven gated files;
    - four exemptions, naming the lane palette and its reason;
    - twenty-three surfaces swept, adding the Log panel, its filter bar, its graph gutter, the Local Changes panel, the Pull Requests panel, the side-by-side diff pane and the unified diff's wash;
    - the diff roles spent, with four roles left unspent.
- [ ] README unchanged: there is no user-facing feature change.
