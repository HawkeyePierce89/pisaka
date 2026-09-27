# Fix plan 01: database viewer sidebar, revmux round 01-initial

## Overview

This plan answers revmux round `01-initial` on the branch
`database-viewer-sidebar-resizable-collapsible` (task
`database-viewer-sidebar-resizable-collapsible`, profile `comprehensive`, 4 of 4
sources, no degradation). It carries all four kept findings plus the one revmux
listed as immaterial, which is folded in because it is the same class as two of
the four — a document sentence stating the opposite of what the code does — and
in this repository a rule or a document weaker than its own prose is a defect.

Two of these were raised as **major** by the finders and lowered to minor by the
verify stage. One of the two is treated as gating here regardless, because the
file it lands in states the very principle the change broke: `DatabaseViewerTabs
.swift`'s own doc comment says re-selecting a tab hands back its model "with its
selected table, its page and its sort intact, which is the whole reason this
state does not live in the view."

Three of the five are sentences that were dictated in the ticket and the plan
review rather than written by the implementation, so the fix is to make each
sentence say what the code does — or, where the code is wrong, to change the
code.

## Validation Commands

```sh
swift test
xcodegen generate && xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-sidebar-fix test
swiftlint --strict
xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -configuration Release -destination 'platform=macOS' -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-sidebar-fix build
xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'generic/platform=iOS' -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-sidebar-fix build
```

Derived data stays outside the repository. No product or brand names in code,
comments, documents or commit messages.

A pin is updated to state the new truth, never widened into a pattern and never
deleted. If a pin outside the ones named in a task goes red, stop and find out
why rather than loosening it.

## Implementation Steps

### Task 1: The clamp spends the divide strip before it divides what is left

**Finding** (minor, confirmed, conf 95, two sources — `bugs+impl` and
`arch+quality`), `Sources/Pisaka/DatabaseViewerView.swift:246`:
`clampedSidebarWidth(total:wanted:)` computes its maximum as
`max(minimum, total - metrics.scaled(gridMinWidth))` where `total` is the whole
width the geometry reader reports. The horizontal stack also lays out
`sidebarDivide`, a transparent strip `metrics.scaled(divideHitWidth)` (5) wide
that takes real layout width. So with the sidebar at its maximum the grid
receives `total - maximum - 5`, which is `gridMinWidth - 5` — 315 points at scale
one, five below the minimum the clamp's own doc comment and
`core-database-viewer.md` both promise.

The repository already answers this question the other way one file over:
`ContentView.swift:1240` reads `let available = max(0, size.width - metrics.scaled(5))`
with the comment "The divider is spent before either half gets anything, so the
rule divides what is left — which is what keeps the two frames summing to no more
than the area."

**Files:**
- Modify: `Sources/Pisaka/DatabaseViewerView.swift`
- Modify: `docs/architecture/core-database-viewer.md`

- [x] Spend the divide strip before the clamp divides anything, following
  `ContentView`'s spelled precedent: the width available to the sidebar and the
  grid is the total minus `metrics.scaled(DatabaseViewerLayout.divideHitWidth)`,
  and the clamp's maximum is that available width minus the grid's minimum,
  still floored at the sidebar's own minimum. Guard the subtraction so a
  transient zero or negative total cannot produce a negative available width.
- [x] State in the clamp's doc comment that the strip is spent first and why, and
  point at `ContentView`'s own line as the precedent rather than restating its
  reasoning.
- [x] Correct the promise in `core-database-viewer.md`: the grid keeps its stated
  minimum, and the strip's width is spent before the split, so the two frames
  plus the strip sum to no more than the pane.
- [x] **Sweep for the shape, not the site.** The defect is "a hand-drawn divide
  whose clamp divides the whole width although the strip itself consumes some of
  it". Grep the repository for every hand-drawn divide's clamp — the Log panel's
  `clampedDetailWidth(total:)` and the statement pane's `clamped(_:)` are the two
  others — and confirm for each whether its strip takes layout width (the Log's
  handle is an overlay on the list and takes none; the statement pane's is a
  sibling in the stack and does). Fix any that has the same gap in the same
  commit, or record in the commit message which ones were checked and why they
  do not.
- [x] No test: the clamp is SwiftUI glue, untested by convention. Say so in the
  commit message rather than adding a test that pins the arithmetic by text.

### Task 2: The grid's floor states what it actually guarantees

**Finding** (minor, refined, conf 80, `adversarial`),
`Sources/Pisaka/DatabaseViewerView.swift:935`:
`DatabaseViewerLayout.gridMinHeight` (40) is justified in the code and in
`core-database-viewer.md` as "the header row plus one data row … about 21 + 19".
But the floor is applied to `grid`, which is a vertical stack of the scrolling
region, a one-point `hairline`, the `footer` (body-font chevrons padded
`metrics.scaled(5)` above and below, roughly 26 points at scale one) and a
zero-size return-key affordance. At the floor the scrolling region therefore gets
about 13 points — less than the header row alone — so the stated goal is not met.
The grid does not vanish, because the footer stays, so the behaviour is
acceptable and the recorded rationale is false.

**Files:**
- Modify: `Sources/Pisaka/DatabaseViewerView.swift`
- Modify: `docs/architecture/core-database-viewer.md`

- [x] Keep the number at 40. Do not raise it to fit a header and a row: the
  binding constraint is the editor zone's 120-point minimum that
  `BottomPanelHeightRule`'s `editorMinimum` sets, which the console's unchanged
  140 already exceeds on its own, and a floor sized for header plus row plus
  footer would roughly double this side's demand against that zone.
- [x] Replace the rationale, in the constant's comment and in the document, with
  what 40 actually buys: the grid keeps its footer and the rule above it — so the
  paging controls and the row-range readout survive the drag — plus a sliver of
  the scrolling region, instead of the grid disappearing entirely. Name the
  footer as part of what the floor covers, since that is the fact the old
  sentence missed.
- [x] Keep the known limit already recorded (the console's 140 against the
  120-point zone) exactly as it stands; this task does not change it.
- [x] No test, for Task 1's reason.

### Task 3: The sidebar's width and fold survive leaving the tab

**Finding** (raised **major** by `docs+tests`, lowered to minor by verify,
conf 85; treated as gating here), `Sources/Pisaka/DatabaseViewerView.swift:98`:
the `@State` comments say `sidebarWidth` is "Session state only, like the
statement pane's width and the Log's detail width" and that `isSidebarCollapsed`
is "Session state only, like the width", and `core-database-viewer.md` repeats
that the two sibling panes "already answer the same question in the view". They
do not answer it the same way. `LeetCodeDescriptionPane`'s width is documented as
"held here so it survives every statement change and every tab switch", and its
folded state "survives tab switches for the same reason". The viewer's do not:
`ContentView.editorZone` shows `DatabaseViewerHost` only while a viewer tab is
selected, and the host keys the surface with `.id(file.id)`, so leaving the tab
tears the view down and discards both values. Fold the sidebar or drag it to 400,
switch to a text tab, come back: it is unfolded at 220.

This is gating because the file that would own the surviving state states the
principle outright — `DatabaseViewerTabs.swift`'s doc comment says re-selecting a
tab hands back the model it already had "with its selected table, its page and
its sort intact, which is the whole reason this state does not live in the view".
The width and the fold are the same kind of thing, and the ticket's own precedent
was chosen for its survival.

**Files:**
- Modify: `Sources/Pisaka/DatabaseViewerTabs.swift`
- Modify: `Sources/Pisaka/DatabaseViewerView.swift`
- Modify: `Tests/PisakaCoreTests/DatabaseViewerSourceGatingTests.swift`
- Modify: `docs/architecture/core-database-viewer.md`

- [ ] Move the source of truth for the sidebar's width and its folded state onto
  `DatabaseViewerTabs`, the per-window object whose lifetime already outlives a
  tab switch, and have the surface reach them through bindings so the
  `.id(file.id)` keying — which exists to stop one database's scroll and
  selection being reused under another's rows — stays exactly as it is.
- [ ] Hold **one** width and **one** folded state for the window rather than one
  per tab, on the statement pane's stated reasoning: it is a preference about the
  window, not about one database. Say that in the property's comment.
- [ ] Do **not** move the drag's start width or either cursor flag. Those are
  per-drag and per-view, and chrome rule twenty-two requires the push to be
  balanced by the view that made it.
- [ ] Do not put layout state on `DatabaseViewerModel`: it is Core, and a Core
  model holding a pane's width is the boundary this repository keeps.
- [ ] Correct the two `@State` comments and the document sentence: they may no
  longer claim the statement pane's behaviour without having it. Say what now
  survives (leaving and re-entering a viewer tab, and switching between two
  viewer tabs) and what does not (quitting the app — nothing is persisted, which
  stays deliberate).
- [ ] **The test that would have caught it.** Add a rule to
  `DatabaseViewerSourceGatingTests` pinning where this state lives: the width and
  the folded state are declared on `DatabaseViewerTabs` and `DatabaseViewerView`
  declares no `@State` for either, so moving one back into the keyed surface
  fails rather than silently resetting on every tab switch. Follow that suite's
  existing style — pinned by name and by file, with the entry's comment stating
  the regression it names — and inventory it in the suite's doc comments and in
  `core-database-viewer.md`, as that suite's other rules are.
- [ ] **Enumerate what you touched.** The state's input space is: no viewer tab
  open, one open, two open and switched between, a viewer tab closed and
  reopened, and the fold set while a second viewer tab is showing. Confirm each
  behaves as the corrected comment says, and that closing the last viewer tab
  leaves nothing dangling.

### Task 4: The stored width's contract says what the drag actually stores

**Finding** (minor, listed by revmux as **immaterial** and folded in here),
`Sources/Pisaka/DatabaseViewerView.swift:98`: the `sidebarWidth` doc comment says
the stored width is "never re-clamped when it is stored — the clamp is asked
where the width is drawn", and `core-database-viewer.md` goes further with
"nothing is written, so there is nothing to clamp at write time". The drag is the
only writer and it clamps at write time: its `onChanged` stores the clamped
value against the current total and scale. So a drag made in a narrow window
lowers the remembered width for good, and widening the window later does not
restore it. The behaviour is acceptable; the stated contract is the opposite of
it, and a reader who believes it will reason wrongly about what survives a resize
or a zoom.

**Files:**
- Modify: `Sources/Pisaka/DatabaseViewerView.swift`
- Modify: `docs/architecture/core-database-viewer.md`

- [ ] Correct both sentences to state that the drag stores an already-clamped
  width, and name the consequence plainly: a width narrowed in a small window
  stays narrowed when the window grows, because what is remembered is the clamped
  value and not the reach the pointer asked for.
- [ ] The sentence "nothing is written, so there is nothing to clamp at write
  time" was about there being no `SettingsStore` write, and it reads as a claim
  about the in-memory store. Rewrite it so the two are not conflated: nothing is
  *persisted*, and the in-memory write is clamped.
- [ ] Decide and record, in one sentence, whether storing the clamped value is
  intended. Keep it — it is what the statement pane's handle does, whose
  `onChanged` also captures and stores the rendered width — and say so rather
  than leaving the asymmetry with the Log's raw-stored detail width unexplained.

### Task 5: The theme document's restated pins agree with the pins

**Finding** (minor, confirmed, conf 99, two sources — `docs+tests` and
`adversarial`), `docs/architecture/core-theme.md:2702`: numbered item 30 still
reads "`DatabaseViewerView.swift` 6 buttons, 4 styled" while
`partFiveDButtonCounts` now holds `(buttons: 8, styled: 6)`. Numbered item 20 has
the same gap: it lists that file's builders as the footer's `labelCount: 3` and
its hidden `pagingGlyph(`, and not the three this change added — `sidebarHeader`,
`collapsedSidebarStrip` (each `labelCount: 1`) and `sidebarGlyph(`. Only item 22
was brought level, so for this file the document and the suite now disagree.

**Files:**
- Modify: `docs/architecture/core-theme.md`
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`

- [ ] Bring item 30's numbers and item 20's builder list level with the pins.
- [ ] **Sweep for the shape, not the site.** The defect is "a document sentence
  restating a pin's numbers, which can drift from the pin". Check every other
  file whose counts item 30 and item 20 restate against what those pins now hold,
  and fix every one that has drifted in the same commit — not only the viewer's.
- [ ] **The test that would have caught it.** Add a cross-file check, beside the
  rules rather than among them so the rule count stays forty-three, that the
  numbers `core-theme.md` spells for each entry of `partFiveDButtonCounts` equal
  what the pin holds — generated from the pin, so the document cannot drift from
  it again. `testBothSummariesSpellTheSuitesOwnRuleCount` is the established
  shape for a check of this kind; follow it, including its failure message naming
  the file and both numbers.
- [ ] If pinning item 20's builder list by generation proves brittle — a builder
  list is prose, not a number — say so in the check's doc comment and pin only
  what can be read honestly, rather than writing a check that passes on a
  sentence it cannot actually verify.
- [ ] Confirm the rule count is still forty-three and that both summaries' own
  cross-file count sentence is unchanged.

### Task 6: Run the gates

- [ ] `swift test` — green. Report the count; it was 5816 before this plan, and
  any change is the tests this plan adds.
- [ ] `xcodegen generate`, then the app-layer bundle — green, 126 tests.
- [ ] `swiftlint --strict` — clean across 591 files.
- [ ] The macOS Release build and the `generic/platform=iOS` build — both
  succeed.
- [ ] Re-read the whole diff against `master` and confirm: every pinned set that
  moved is stated, none widened; no `SettingsStore` key was added; no Core type
  was added; `CLAUDE.md` is unmodified.
