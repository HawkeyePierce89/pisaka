# The `dependencies` caption becomes a tag, the rounding-direction test is judged under the pinned Xcode, and one comment is corrected

## Overview

Three follow-ups on `dependency-folders-in-the-project-tree` (PR #122), landed on top of
that branch:

1. The `dependencies` caption on a dependency root row is drawn as a **tag**: a smaller
   word inside a hairline capsule. It is drawn by one new shared chrome view,
   `ChromeTag`. The Pull Requests panel's state tags move onto it as well, so neither
   surface restates the other's numbers.
2. `TreeStickyScrollRoundingTests.testTheRevealScrollRoundsToTheNearestPointTiesDown`
   fails under Xcode 26.3 (the CI pin) and passes under 27.1. It is reproduced under
   26.3. Then one of two things happens: a change to the test alone makes it
   deterministic, or the method is cut and the docs are cut back to the measured fact.
   A fixed decision rule picks between the two inside this run.
3. One doc comment in `PisakaApp.swift` and one sentence in `app-shell.md` claim a
   Problems row can never name a file inside dependencies. Both are corrected to what
   the code does.

**Process rule for the whole plan.** Every `xcodebuild` runs under Xcode 26.3 at
`/Applications/Xcode_26.3.app`, with one derived-data path, and never falls back to
another Xcode. The only exception is the single 27.1 full-bundle run that outcome A of
Part 2 requires. It is labelled as that exception wherever it is cited, and it is never
evidence for a 26.3 gate. Every gate result recorded in the Execution notes names the
Xcode version it ran under.

## Context

- Files involved:
  - `Sources/Pisaka/ProjectTreeView.swift`: `TreeFolderLabel`, where the caption is
    drawn today as a `Text("dependencies")` in `textSecondary` at the label's `.body`
    font.
  - `Sources/Pisaka/PullRequestsPanelView.swift`:
    - `tag(_:role:)` (around line 603): `.subheadline` text, a `hairline`
      `Capsule().strokeBorder` at `ChromeGeometry.hairlineWidth`, no fill.
    - `PullRequestsLayout.tagPaddingX = 6` and `tagPaddingY = 1` (around line 795).
  - `Sources/Pisaka/ChromeTag.swift`: new file.
  - `Sources/PisakaCore/ChromeGeometry.swift` and
    `Tests/PisakaCoreTests/ChromeThemeTests.swift`: the token inventory, pinned by set
    equality in `testGeometryDeclaresExactlyTheseTokensAndNoFontSize`.
  - `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`:
    - `gatedFiles`, sixty-six files today;
    - the `spelled` table, which stops at 66;
    - `testBothSummariesSpellTheGatedSetsOwnSize`, which checks the size against
      `core-theme.md` ("**sixty-six** in all today") and `CLAUDE.md` ("sixty-six, by
      set equality").
  - `Tests/PisakaAppTests/TreeDependencyCaptionTests.swift`: rewritten.
  - `Tests/PisakaAppTests/TreeStickyScrollRoundingTests.swift`.
  - `Sources/PisakaCore/TreeStickyRule.swift`: the `slotTolerance` doc comment only.
  - `Sources/Pisaka/PisakaApp.swift`: the `activateProblem(url:row:)` doc comment only.
  - Docs:
    - `docs/architecture/app-window.md`: the dependency-folders entry and the sticky
      entry.
    - `docs/architecture/core-theme.md`: the gated-set running total, the place near
      the summaries paragraph that restates it, the `ChromeGeometry` entry, and a new
      `ChromeTag.swift` entry.
    - `docs/architecture/core-github.md`: the panel's tags paragraph.
    - `docs/architecture/core-workspace.md`: the **Tolerance** paragraph.
    - `docs/architecture/app-shell.md`: the open-funnel paragraph.
    - `docs/FEATURES.md` (lines 52, 59 and 61) and `README.md` (line 158): the word
      "caption".
    - `CLAUDE.md`: the core-theme app-surfaces index line and the "sixty-six" count.
- Related patterns:
  - `TreeGitStatusColourTests` builds a `TreeGitStatus` with `ignoredPaths` and compares
    a name's colour against a role. The rewritten caption test follows it.
  - `HostedRender` is the bitmap harness.
  - `DiagnosticsModel.forgetInsideDependencies(_:)` is the behaviour Part 3's sentences
    describe. It is not changed.
- Dependencies: none new. Xcode 26.3 is installed at `/Applications/Xcode_26.3.app`
  before the run starts. Xcode 27.1 is at `/Applications/Xcode.app`.

## Development Approach

- **Testing approach**: Regular (code first, then tests). Each bitmap assertion is
  checked against its mutation, as the ticket requires.
- Complete each task fully before moving to the next.
- **CRITICAL: every task MUST include new/updated tests**
- **CRITICAL: all tests must pass before starting next task**
- Before touching any file, read its `docs/architecture/` entry. Update that entry in
  the same task.
- **Gate commands.** Only these forms are used. `$DD` is
  `~/Library/Developer/Xcode/DerivedData/pisaka-build`, never a path inside the repo.
  - Version check, recorded before every app-layer gate:
    `DEVELOPER_DIR=/Applications/Xcode_26.3.app/Contents/Developer xcodebuild -version`
    must print `Xcode 26.3`.
  - Full app bundle: `xcodegen generate &&
    DEVELOPER_DIR=/Applications/Xcode_26.3.app/Contents/Developer xcodebuild -project
    Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' -derivedDataPath $DD
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO test`
  - One suite: the same command plus `-only-testing:PisakaAppTests/<Suite>`.
  - Five consecutive runs: one `build-for-testing`, then five separate
    `test-without-building -only-testing:PisakaAppTests/TreeStickyScrollRoundingTests`
    invocations with the same flags. Record each invocation's result.
  - macOS Release build: `… -configuration Release -destination 'platform=macOS'
    -derivedDataPath $DD CODE_SIGNING_ALLOWED=NO build`.
  - iOS build: `… -destination 'generic/platform=iOS' -derivedDataPath $DD
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build`.
  - Core gate: `swift test`.
  - Lint: `swiftlint lint --strict`, with `swiftlint version` = 0.65.1.
  - After every xcodebuild, `git status --porcelain` must show no change to
    `Pisaka.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`. CI
    refuses a resolution the pinned Xcode rewrote.
- **Execution notes.** Append them to a `## Execution notes` section at the bottom of
  this plan file. Each app-layer gate result is one line: the shape of the command, the
  Xcode version it printed, and the outcome (test counts and failures).
- No brand names and no references to other editors in code, comments, docs or commits.

## Implementation Steps

### Task 1: One shared tag view, `ChromeTag`, and its padding tokens in `ChromeGeometry`

Intent: the tag form exists in one place, so the panel and the tree cannot drift apart.

The decision is the **shared view**:

- It is one new file, `Sources/Pisaka/ChromeTag.swift`, under `#if os(macOS)`.
- It holds `struct ChromeTag: View`, which takes the text, a `ChromeColorRole` for the
  text and an `InterfaceTextStyle`.
- It draws:
  - the text at `metrics.scaledFont(style)` in `theme.color(role)`, with
    `.lineLimit(1)`;
  - padding of `metrics.scaled(ChromeGeometry.tagPaddingX)` horizontally and
    `metrics.scaled(ChromeGeometry.tagPaddingY)` vertically;
  - an overlay `Capsule().strokeBorder(theme.color(.hairline), lineWidth:
    metrics.scaled(ChromeGeometry.hairlineWidth))`;
  - no fill.
- It reads the metrics and the theme from the environment, the same way every gated
  view reads them.
- It carries no accessibility modifier and no `.fixedSize()`. Those belong to the call
  sites, so the panel draws exactly what it draws today.

**Files:**
- Create: `Sources/Pisaka/ChromeTag.swift`
- Modify: `Sources/PisakaCore/ChromeGeometry.swift`
- Modify: `Sources/Pisaka/PullRequestsPanelView.swift`
- Modify: `Tests/PisakaCoreTests/ChromeThemeTests.swift`
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`
- Modify: `docs/architecture/core-theme.md`
- Modify: `docs/architecture/core-github.md`
- Modify: `CLAUDE.md`

- [x] Add `tagPaddingX: Double = 6` and `tagPaddingY: Double = 1` to `ChromeGeometry`,
  each with a one-line doc comment ("a tag's horizontal/vertical inset inside its
  capsule").
- [x] Remove the two tokens from `PullRequestsLayout`.
- [x] Add `ChromeTag.swift` as specified.
- [x] At the panel's call sites, replace the private `tag(_:role:)` with
  `ChromeTag(text, role: role, style: .subheadline)`. Font, padding, roles and stroke
  stay as they are. No new colour role, no new palette value.
- [x] Core test, `ChromeThemeTests`:
  - add both token names to the inventory set in
    `testGeometryDeclaresExactlyTheseTokensAndNoFontSize`;
  - assert their values (6 and 1) next to the existing value asserts.
- [x] Gating suite, `ChromeThemeSourceGatingTests`. These are the only changes:
  - add `ChromeTag.swift` to `gatedFiles`, with a comment naming it as the shared tag;
  - add `67: "sixty-seven"` to `spelled`;
  - make the two summaries this suite checks spell sixty-seven (see the docs step).
- [x] Docs:
  - `core-theme.md`:
    - a full entry for `ChromeTag.swift`: its form, roles and tokens, what the call
      sites are responsible for, and its two users;
    - the two tokens added to the `ChromeGeometry` entry;
    - the gated-set running total ends on "the shared tag, `ChromeTag.swift`, one more:
      **sixty-seven** in all today";
    - the later paragraph that restates the size says sixty-seven too.
  - `core-github.md`: the panel's tags paragraph says the tags are drawn through
    `ChromeTag`.
  - `CLAUDE.md`:
    - add `ChromeTag.swift` to the core-theme app-surfaces line;
    - change "sixty-six, by set equality" to "sixty-seven, by set equality";
    - keep the file under 60,000 characters.
- [x] Run `swift test` and `swiftlint lint --strict`. `swift test` must be green,
  including `ChromeThemeSourceGatingTests`, `ChromeThemeTests`, `ZoomSourceGatingTests`
  and `LintConfigurationTests`, and lint must be clean before Task 2.

### Task 2: The tree's caption drawn as a tag, judged on the ignored-name case

Intent: in the common real case, a gitignored `node_modules` next to `package.json`,
the mark must read as a mark and not as more of the folder's name.

Requirements for the caption. Only its form changes:

- It keeps its word `dependencies` and its place after the name.
- It still appears on the pinned sticky copy and next to the rename field. It is still
  absent on rows inside dependencies and on the create draft.
- It stays `.accessibilityHidden(true)`, and the value still speaks `Dependencies`.
- `TreeFolderLabel` draws it as `ChromeTag("dependencies", role: .textSecondary, style:
  .caption)`, followed by `.fixedSize()` and `.accessibilityHidden(true)` at the call
  site.
- The label's `HStack` keeps its default centre alignment. The tag stays vertically
  centred on the row, and the name truncates before the tag does.

**Files:**
- Modify: `Sources/Pisaka/ProjectTreeView.swift`
- Modify: `Tests/PisakaAppTests/TreeDependencyCaptionTests.swift`
- Modify: `docs/architecture/app-window.md`
- Modify: `docs/FEATURES.md`
- Modify: `README.md`

- [ ] In `TreeFolderLabel`, replace the caption's `Text` with the `ChromeTag` call
  above. Update the comment next to it, and the type's doc comment if it describes the
  caption's form.
- [ ] Rewrite `TreeDependencyCaptionTests` (the suite doc comment is its inventory).
  - Setup:
    - The same project as today (`p` holding `package.json`, `node_modules/{a,b}`,
      `other/node_modules/{a,b}` and `other/readme.txt`), with the same reveal of
      `other/readme.txt`.
    - It now renders with a `TreeGitStatus` lookup that marks the root `node_modules`
      as **ignored**, built the way `TreeGitStatusColourTests` builds one. Spell the
      ignored path the way that type expects a directory to be spelled.
    - Two windows in total, one per appearance.
    - Geometry comes from the metrics at interface scale 1, as today:
      - the name ends at `nameEnd`;
      - the tag starts at `tagStart = nameEnd + scaled(4)`;
      - the tag is `tagWidth = width("dependencies" at the caption font, 10 pt) + 2 ×
        scaled(ChromeGeometry.tagPaddingX)` wide.
  - Assertions, in both appearances:
    - **The case is real.** The ink of the root `node_modules` name is drawn in
      `textSecondary`: its extreme pixel is closer to the resolved `textSecondary` than
      to `textPrimary`, compared the way `TreeGitStatusColourTests` compares a name to a
      role.
    - **Ring.** On the row's centre line, a narrow window at the tag's left end (around
      `tagStart`) and one at its right end (around `tagStart + tagWidth`) each hold a
      pixel that differs from the row background. Both windows are clear of the word,
      which starts `tagPaddingX` inside the ring.
    - **Size.** The vertical ink band of the word inside the tag is strictly shorter
      than the vertical ink band of the name `node_modules` on the same row.
      - The capsule's end radius is about half its height. With 10 pt text plus 2 × 1 pt
        padding that is about 7 pt, which is more than the 6 pt horizontal padding. So
        the word's first and last columns fall inside the rounded ends, where the
        outline is not a straight horizontal line.
      - Measure only on the **central half of the word's columns**: from `tagStart +
        tagPaddingX + wordWidth / 4` to `tagStart + tagPaddingX + 3 × wordWidth / 4`.
      - On those central columns, find the ring's top line and bottom line in the
        bitmap. They are the outermost rows within the row's height where every central
        column differs from the background.
      - Measure the word's ink band on the same central columns, using only rows
        strictly between those two ring lines.
    - **Unmarked row.** The unmarked `other/node_modules` row holds only its background
      in the band where a tag would sit, one indent step further right. The row-5
      expansion check stays.
- [ ] Mutation checks. Run each once, record it in the Execution notes with the Xcode
  version, and revert it afterwards:
  - remove the `strokeBorder` overlay: the ring assertion fails;
  - draw the tag at `.body`: the size assertion fails;
  - drop the tree's `ChromeTag` entirely: the ring assertion fails.
- [ ] Docs:
  - `app-window.md`'s dependency-folders entry. It describes:
    - the tag's form, drawn through `ChromeTag`;
    - its roles: `textSecondary` text and a `hairline` ring;
    - the `.caption` style;
    - the `ChromeGeometry.tagPaddingX/Y` tokens;
    - the call site's `.fixedSize()` and `.accessibilityHidden(true)`;
    - that no role and no palette value were added;
    - the test's new shape: ignored root, ring, size on the central columns, unmarked
      row.
  - `docs/FEATURES.md` and `README.md`: replace the word "caption" with "tag" wherever
    they describe the mark, so the two user-facing docs agree:
    - FEATURES.md line 52: "carries a quiet `dependencies` caption after its name"
      becomes "carries a `dependencies` tag after its name";
    - FEATURES.md line 59: "Only that boundary row is captioned" becomes "Only that
      boundary row is tagged";
    - FEATURES.md line 61: "carry no caption and no test wash" becomes "carry no tag and
      no test wash";
    - README.md line 158: "carry a `dependencies` caption" becomes "carry a
      `dependencies` tag".
  - Code identifiers (`showsCaption`, `TreeDependencyCaptionTests`) stay as they are.
- [ ] Run `swift test` and `swiftlint lint --strict`.
- [ ] Run `TreeDependencyCaptionTests` alone under 26.3, then the full app bundle under
  26.3. Record both with the Xcode version. Both must pass before Task 3.

### Task 3: Reproduce the rounding-direction failure under Xcode 26.3 and record what is observed

Intent: Task 4's decision rests on what 26.3 actually does, not on the CI log alone.

The CI log on PR #122 (Xcode 26.3, 509 tests, 4 failures):

- "no report for the expanded folder t1 arrived", and the same for t3 and t5;
- then "t1 is no longer reported expanded".

The even folders (`x` only) reported. The odd ones (`w` above `x`) did not report within
3 s.

The product code is not changed in this task or the next.

**Files:**
- Modify: `Tests/PisakaAppTests/TreeStickyScrollRoundingTests.swift` (temporary
  diagnostics only, removed before the task ends)
- Modify: this plan's `## Execution notes`

- [ ] Run `TreeStickyScrollRoundingTests` alone under 26.3, unchanged, and record the
  result.
- [ ] Add temporary diagnostics to the direction method, printed to the test log. After
  each reveal, record:
  - every report's `scrollID`, `isExpanded` and frame;
  - how long each folder's expanded report took to arrive, or that it never arrived
    within an extended wait (for example 15 s);
  - whether the odd folder's `w` and `x` rows exist in the rendered tree.
  - Leads to examine first. None of them is established:
    - whether revealing an odd `tK/x` expands `tK` at all under 26.3;
    - whether the report arrives later than 3 s;
    - whether a later reveal collapses or re-identifies an earlier folder;
    - whether the order of reveals matters (each odd folder revealed alone, or first).
- [ ] Record in the Execution notes:
  - which folders report, after how long, and what each report's `isExpanded` and frame
    say;
  - the Xcode version;
  - the cause, if one is identified.
- [ ] Remove the temporary diagnostics.
- [ ] Run `swift test`. It must pass before Task 4. This task leaves the suite as it
  found it.

### Task 4: Apply Part 2's decision rule: make the direction test deterministic, or cut it to the measured fact

Intent: settle the test within this run. Both outcomes are complete and acceptable.
`ProjectTreeView.swift` and the logic in `TreeStickyRule.swift` stay untouched.

**Outcome A** is tried first: a change to the test alone, informed by Task 3. Candidates
are how the folders are expanded and their reports awaited, the project's shape, and the
wait's condition. Outcome A is kept only if all three of these pass:

- the method passes five consecutive runs under 26.3 (the five-invocation form);
- one full bundle passes under 26.3;
- one full bundle passes under 27.1
  (`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`, version printed and
  recorded, labelled as the one stated exception).

Run the 27.1 bundle before the final 26.3 runs. If switching toolchains leaves a stale
module cache, clean under the same `$DD` and rerun.

**Outcome B** applies if A does not meet all three: cut the test and the docs to the
measured fact.

**Files:**
- Modify: `Tests/PisakaAppTests/TreeStickyScrollRoundingTests.swift`
- Modify: `Sources/PisakaCore/TreeStickyRule.swift` (doc comment only, outcome B)
- Modify: `docs/architecture/core-workspace.md` (outcome B)
- Modify: `docs/architecture/app-window.md`

- [ ] Attempt outcome A.
  - If it is kept, update the "The direction" section of the suite doc comment and
    `app-window.md`'s sticky entry to the new setup.
  - Record in the Execution notes the cause, the change, and the seven run results,
    each with its Xcode version.
- [ ] Otherwise apply outcome B.
  - Test file:
    - remove `testTheRevealScrollRoundsToTheNearestPointTiesDown`;
    - remove the helpers it leaves unused (`targetIndices`, `targetFile`, `expanded`,
      `makeDirectionProject`, `scrollToTop`);
    - keep `TreeRevealHostState` / `TreeRevealHost`, which `TreeRevealOnScreenTests`
      also uses;
    - remove the "The direction" section of the suite doc comment.
  - Cut the `TreeStickyRule.slotTolerance` doc comment to what the remaining test pins:
    through `ScrollViewProxy.scrollTo`, a target of `1165.5` settled at `1165.0` at
    backing scale 1, pinned by `TreeStickyScrollRoundingTests`, which asserts only the
    tolerance at any other scale. Delete:
    - "rounding to the nearest (ties down; `.6`–`.9` settled on the point above), not
      flooring";
    - the `.25`/`.5`/`.75` sentence;
    - any clause that relies on the rounding direction, such as "even off the
      half-point grid".
  - Cut `core-workspace.md`'s **Tolerance** paragraph the same way.
    - Delete:
      - the "nearest pixel, ties down, not a floor" sentence, and the plain-`ScrollView`
        `.1`–`.5` / `.6`–`.9` probe with its "off the half-point grid" conclusion;
      - the sentence that says the suite pins the direction, together with the
        description of `.25`/`.75` at interface scale 0.9.
    - Keep:
      - the raw clip-view half;
      - the `1165.5` → `1165.0` fact;
      - the consequence of being a half point short at interface scale 1;
      - the cost.
  - Remove the "Its second method, …" paragraph from `app-window.md`'s sticky entry.
  - Record the decision and its reason in the Execution notes.
- [ ] Run `swift test` and `swiftlint lint --strict`.
- [ ] Run `TreeStickyScrollRoundingTests` under 26.3: five consecutive times if the
  method was kept, once otherwise. Then run the full app bundle under 26.3. Record each
  result with the Xcode version. All must pass before Task 5.

### Task 5: Correct the Problems-row claim

Intent: two sentences say a Problems row can never name a file inside dependencies,
which overstates `DiagnosticsModel`'s drop. No behaviour changes.

What actually happens:

- A diagnostics set that landed before a marker file appeared next to the folder stays
  in the store.
- It stays until the next report about that file is dropped
  (`forgetInsideDependencies`).
- Until then a row can name such a file, and activating the row opens the viewer window
  at the file's start.

**Files:**
- Modify: `Sources/Pisaka/PisakaApp.swift` (the `activateProblem(url:row:)` doc comment)
- Modify: `docs/architecture/app-shell.md` (the open-funnel paragraph)

- [ ] Rewrite the last paragraph of the doc comment to say exactly what happens:
  - the method passes no viewer range, so the funnel's default, the file's start,
    applies;
  - the drop forgets a dependency file's set only when the next report about that file
    is dropped;
  - until then a row naming such a file can exist, and activating it opens the
    read-only viewer window at the file's start.
- [ ] In `app-shell.md`, replace the clause "since the diagnostics drop means a Problems
  row cannot name a dependency file" with the same statement, naming
  `forgetInsideDependencies`.
- [ ] No behaviour changes, so no new test is needed. Run `swift test` and `swiftlint
  lint --strict`. `swift test` reads `PisakaApp.swift` through several source-gating
  suites, and the `type_body_length` ceiling must still hold. Both must pass before
  Task 6.

### Task 6: Verify acceptance criteria

- [ ] `swift test`: green.
- [ ] `swiftlint lint --strict` at 0.65.1: clean.
- [ ] `xcodegen generate` leaves `git status` clean.
- [ ] The version check under 26.3 prints `Xcode 26.3`. The full app bundle then passes
  under 26.3, including the rewritten `TreeDependencyCaptionTests` and whichever outcome
  Task 4 produced.
- [ ] If the direction method was kept, `TreeStickyScrollRoundingTests` passes five
  consecutive times under 26.3.
- [ ] macOS Release build under 26.3: green.
- [ ] iOS build (`generic/platform=iOS`) under 26.3: green.
- [ ] `Package.resolved` is unchanged after all of them.
- [ ] `ChromeThemeSourceGatingTests` is green and its inventory is true:
  - no new role and no new palette value;
  - `ChromeTag.swift` is in the gated set;
  - both summaries spell sixty-seven.
- [ ] Every app-layer gate line in the Execution notes names its Xcode version. Only
  Task 4's labelled 27.1 bundle names a different one.
- [ ] Grep the diff for brand names and references to other editors: none.

### Task 7: Final documentation pass

- [ ] Re-read the entries this branch touched against the code. Each must state what
  the code does after Tasks 1–5:
  - `app-window.md` (dependency folders, sticky);
  - `core-theme.md` (`ChromeTag`, `ChromeGeometry`, the running total);
  - `core-github.md`;
  - `core-workspace.md` (Tolerance);
  - `app-shell.md`.
- [ ] Grep `README.md` and `docs/FEATURES.md` for "caption" (case-insensitive). No
  user-facing doc may still call the mark a caption.
- [ ] Check that `CLAUDE.md` carries the new index name and "sixty-seven", and stays
  under 60,000 characters (`LintConfigurationTests`).
- [ ] Run `swift test` one last time after any doc edit: green.

## Execution notes

(Appended during the run: one line per gate result with its Xcode version, Task 3's
observations, Task 4's decision and its reason, and Task 2's mutation results.)

- Task 1: `swift test` (host toolchain, no xcodebuild): 7221 tests, 0 failures, including ChromeThemeSourceGatingTests, ChromeThemeTests, ZoomSourceGatingTests and LintConfigurationTests. `swiftlint lint --strict` at 0.65.1: clean. No app-layer gate in this task.
