# Chrome theme part four (a) — review fixes, round 01

## Overview

Answers the seven findings of revmux round `01-initial` on the task
`chrome-theme-part-four-a-dock-tab-row-and-panels`, all of them `minor`, none
of them gating. Four sources of four reported; nothing degraded. The record is
`.revmux/tasks/chrome-theme-part-four-a-dock-tab-row-and-panels/01-initial/report.md`.

Three classes. **One is visible on screen**: the strip's own bottom rule is an
overlay, so it paints over the lower half of the active tab's two-point accent
indicator — in the new dock row and, identically, in the horizontal tab strip,
where it also defeats the comment that explains why that overlay exists. **Three
are claims that are not true**: a doc comment and an architecture entry say the
bottom bar lists its panels through `allCases` when the bar keeps a hand-written
list of six; another entry still names three readers of a severity table that
now has one; and the user-facing feature list still names two buttons by the
names this branch removed. **Two are gates that do not gate**: a rule that
forbids a second severity table cannot see an inline switch, and a rule the
documents present as guarding the new header labels is satisfied by an unrelated
occurrence that was already there on master.

Only Task 1 changes what anything looks like. Task 4 deletes a second list
rather than restating the sentence that describes it, because the sentence is
already written in two documents and the honest repair is to make it true.

## Development Approach

- Complete each task fully before moving to the next.
- **CRITICAL: every task that changes executable code MUST carry the test that
  would have caught the defect.** Two tasks here are documentation alone and
  carry none; each says so in its own text.
- **CRITICAL: all tests must pass before starting the next task.**
- Core gate: `swift test`. App gate: the app-layer bundle. Style gate:
  `swiftlint --strict` from the repository root.
- Builds and test runs write nothing into the repository tree: pass
  `-derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-part4a`.
- No product or brand names anywhere — code, comments, documents or commit
  messages.
- **Before committing each fix, sweep for the shape rather than the site.** Name
  the defect as a construct and grep for that construct across the repository,
  fixing every occurrence in the same commit. Task 1 is exactly this: the
  finding quotes one file and the construct lives in two.
- The chrome gating suite's rule count is asserted equal in three places — the
  suite's own declaration, `core-theme.md`'s canonical list and `CLAUDE.md`'s
  invariant sentence — and its `spelled` table must carry the new count's word.
  A task that adds a rule edits all four in that same task.

## Validation Commands

```sh
swift test
xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-part4a test
swiftlint --strict
```

## Implementation Steps

### Task 1: A strip's bottom rule must not paint over an active tab's indicator

**Finding** (`Sources/Pisaka/DockTabRow.swift:66`, confirmed, confidence 80):
each tab's label fills the row's frame, so the `accentIndicator` strip sits at
the very bottom of the row; the row then adds `.overlay(alignment: .bottom)`
with an opaque `hairline`. An overlay draws on top of its content, so the
selected tab shows one point of accent over one point of grey rather than the
two-point accent bar the goal and `core-theme.md` describe. The finding notes
the same pattern in `TabStripView.swift`.

**Verified before writing this plan:** the tab strip has it too, and there it is
worse. `TabStripView.swift:47` draws the strip's rule as `.overlay(alignment:
.bottom)` directly above a comment saying it is an overlay *so that* an active
tab — filled in `bgEditor` to read as part of the editor — "can sit above it and
merge into the editor below". A container's overlay draws above every one of its
children, so the active tab's fill and its `accentIndicator` underline
(`TabStripView.swift:95-101`) are both covered along their bottom point. The
comment states an intent the code defeats.

**Files:**
- Modify: `Sources/Pisaka/DockTabRow.swift`, `Sources/Pisaka/TabStripView.swift`
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`
- Modify: `docs/architecture/core-theme.md`, `docs/architecture/app-window.md`, `CLAUDE.md`

- [x] in both files, draw the container's own bottom rule **behind** its content
      instead of over it, so an active tab's indicator interrupts the rule for
      its own width rather than being half-covered. Mind the layering order: a
      strip that also fills a ground must end up with the ground furthest back,
      then the rule, then the content.
- [x] `TabStripView.swift`: correct or confirm the comment at its bottom rule so
      it describes what the code now does — the active tab really does merge
      into the editor below once the rule is behind it, which is what that
      comment always claimed.
- [x] `DockTabRow.swift`: say in the row's doc comment that the rule is behind
      the tabs and why, so the next surface that copies this row copies the
      right thing.
- [x] **the test that would have caught it** — add **rule sixteen** to
      `ChromeThemeSourceGatingTests`: a chrome strip that draws an accent
      indicator at its own bottom edge must not also draw its bottom rule as an
      overlay. Pin it by the construct over stripped source in the two files
      that have one, named in a list the way rule fourteen names its own, so a
      third such strip is added to the list rather than left unguarded. Its doc
      paragraph states the defect: an overlay covers the indicator, and nothing
      in the compiler or in a headless test can see a one-point overlap.
- [x] the three-place count edit plus the `spelled` entry, per the approach above.
- [x] record the fix in `core-theme.md`'s part-four (a) entry and in
      `app-window.md`'s `TabStripView.swift` / `DockTabRow.swift` entries.
- [x] run `swift test` and the app bundle.

### Task 2: Rule eleven pins nothing for the three panels it just gained

**Finding** (`Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift:770`,
refined, confidence 85): rule eleven asserts that each listed file contains
`.lineLimit(1)` somewhere in its stripped source. `ProblemsPanelView.swift`,
`UsagesPanelView.swift` and `TerminalPanelView.swift` each already carried one
on master — the file-group path, the identifier and group path, the session
title. The labels the rule is meant to protect here are the new ones inside the
fixed `panelHeaderHeight` frames: the "Problems" title, the severity-badge
count, the provenance note and the count label. Deleting `.lineLimit(1)` from
any of them leaves the suite green, because the older occurrence still matches.
`app-window.md:629` presents rule eleven as what guards those headers.

**Files:**
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`
- Modify: `docs/architecture/app-window.md`, `docs/architecture/core-theme.md`

- [x] narrow the rule for the files whose fixed-height strip is a *builder*
      rather than the whole view: read that builder's brace-matched body and
      require the limit inside it, the way rule ten reads the bottom bar's
      button builder. Name the builder in the test so renaming it fails loudly.
- [x] keep the whole-file form for the files where it is still the honest check,
      and say in the rule's doc which files take which form and why — the
      existing doc already states that a source rule cannot see a layout, and it
      must now also state that a file-level `contains` is satisfied by any older
      occurrence.
- [x] **the test that would have caught it**: this task *is* that test. Verify
      the narrowing bites by deleting one header's `.lineLimit(1)` locally,
      confirming the suite goes red, and restoring it. Say in the task's commit
      message that this was done.
- [x] correct `app-window.md:629` if the narrowed rule still does not cover
      everything that sentence claims.
- [x] run `swift test`.

### Task 3: Rule fifteen cannot see an inline severity mapping

**Finding** (`Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift:975`,
confirmed, confidence 90): rule fifteen checks that no app file declares a
function named `diagnosticRole`, that the reader set is exactly two files, and
that `ProblemsPanelView.swift` names no `SyntaxTheme`. A row struct that grew a
local `switch` over `DiagnosticSeverity` returning roles would satisfy all
three, and that is the second table the rule says it prevents.

**Files:**
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`
- Modify: `docs/architecture/core-theme.md`

- [x] add a clause that catches the mapping by its shape rather than by a
      function name: no gated app file may spell the severity vocabulary's own
      case labels. Choose the spelling that is total over the closed severity
      set, so a mapping that handles three of the four is caught as well.
- [x] state the limit honestly in the rule's doc, whatever it turns out to be —
      a source rule can see a switch's labels and cannot see a dictionary
      literal keyed by the same values, and a rule that claims more than it
      checks is the defect this finding is about.
- [x] **the test that would have caught it**: this task is that test. Verify it
      bites by adding a local severity switch to a gated file, confirming red,
      and removing it. Say so in the commit message.
- [x] update `core-theme.md`'s canonical list entry for rule fifteen so its
      wording matches what the rule now checks.
- [x] run `swift test`.

### Task 4: The bottom bar keeps a second list of panels while two documents say it does not

**Findings** (`Sources/PisakaCore/BottomPanel.swift:10`, confirmed, confidence
99, three sources; and `docs/architecture/core-services.md:113`, confirmed,
confidence 95): the new doc comment says "the bottom bar's toggles and the
dock's tab row both list the panels in it, and neither keeps a second list", and
`core-services.md` repeats it. Only the tab row reads `allCases`. The bar is six
hand-written `bottomBarButton(systemImage:panel:)` calls, each carrying its own
glyph — a second list. Reordering the enum on the strength of that sentence
reorders the tab row alone and the two strips disagree. No test catches it:
`BottomPanelTests.testAllCasesIsTheBarsOrder` compares `allCases` to a
hard-coded literal and never reads the bar.

**Files:**
- Modify: `Sources/PisakaCore/BottomPanel.swift`, `Sources/Pisaka/ContentView.swift`
- Modify: `Tests/PisakaCoreTests/BottomPanelTests.swift`, `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`
- Modify: `docs/architecture/core-services.md`, `docs/architecture/app-window.md`, `CLAUDE.md`

- [x] make the sentence true rather than softening it: give `BottomPanel` the
      glyph beside the title, as one more column of the same table, and have the
      bar build its six toggles from `allCases`. A symbol name is a string, and
      Core already answers one for a file icon, so this stays Foundation-only
      and colour-free.
- [x] carry the existing reasoning across with the value: the comment explaining
      why Pull Requests draws a merge glyph rather than the one Local Changes
      already uses belongs beside the glyph it is about, now that the two sit in
      one table.
- [x] the completion toggle is not a panel and stays as it is. So does the
      pull-request indicator in the bar's leading zone. Glyphs, order, spacing
      and styling of the six do not change.
- [x] `bottomBarButton` loses its `systemImage:` parameter and reads both the
      glyph and the name from the panel.
- [x] **the test that would have caught it**: extend the bottom-bar gating rule
      — rule ten, which already owns the bar — with a clause that the bar builds
      its toggles from `allCases` and names no panel case literally in that
      body. A Core test cannot see the bar; the source rule can. Keep the
      existing `allCases`-order test and say in its doc that it pins the order
      and the source rule pins who reads it.
- [x] correct `BottomPanel.swift`'s doc comment and `core-services.md`'s entry
      so both describe the table as it now is; update `app-window.md`'s
      `ContentView.swift` entry and `CLAUDE.md`'s `BottomPanel.swift` index line.
- [x] run `swift test` and the app bundle.

### Task 5: The severity table's own entry still names readers it no longer has

**Finding** (`docs/architecture/app-editor-overlays.md:1009`, refined,
confidence 80, two sources): the `SyntaxTheme.swift` entry justifies its four
diagnostic colours with "three surfaces (squiggle, gutter dot, panel icon) must
draw one severity identically". The gutter half was already stale before this
branch; the panel half became stale in it. The squiggle is now the table's only
reader. The rewritten ruler paragraph nearby does say so, so the document does
not contradict itself — but the entry a maintainer reads before editing
`SyntaxTheme.swift` names two readers that do not exist.

**Documentation only; no test.** Nothing executable changes, and the suite
already pins the reader set.

**Files:**
- Modify: `docs/architecture/app-editor-overlays.md`

- [x] rewrite the entry's justification to name the one reader it has and to
      point at the Core answer the two chrome surfaces read instead.
- [x] sweep for the shape: grep the architecture documents for any other
      sentence counting readers of that table, and fix each.
- [x] run `swift test` (the cross-file document rules).

### Task 6: The feature list names two buttons by names this branch removed

**Finding** (`docs/FEATURES.md:898`, confirmed, confidence 80): the tooltips and
accessibility names now read "Log" and "Local Changes" from the table, while
`FEATURES.md` still says "the Changes button on the bottom bar" (898) and "the
Git button on the bottom bar" (998), and line 615 lists the dock's panels as
"Terminal, Git Log, …". The buttons are icon-only, so a reader following the
document finds no button by those names. The new user-visible control — the tab
row and its close action — is missing from the document entirely.

**Documentation only; no test.**

**Files:**
- Modify: `docs/FEATURES.md`

- [x] bring every name in the document to the one the table now answers, and
      sweep the whole file rather than the three quoted lines.
- [x] describe the dock's tab row and its close action where the document
      describes the dock, in the register the rest of the file uses.
- [x] check `README.md` for the same names and fix them there too if present.
- [x] run `swift test`.

### Task 7: Gates

- [ ] `swift test` is green.
- [ ] the app-layer bundle is green on a macOS destination.
- [ ] the macOS Release build and the iOS build are green.
- [ ] `swiftlint --strict` is clean from the repository root.
- [ ] the chrome suite's rule count agrees with `core-theme.md` and `CLAUDE.md`.
- [ ] `ChromePalette.swift` is still unchanged against the default branch.
