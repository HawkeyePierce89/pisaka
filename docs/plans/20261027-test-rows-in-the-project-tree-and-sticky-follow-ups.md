# Test rows in the project tree, and two follow-ups to the sticky parent folders

## Overview

One branch carrying three independent pieces of macOS project-tree work:

1. **Test rows.** A pure Core rule, `TreeTestRule`, decides from a row's
   root-relative path whether the row is a test row. The tree paints those rows
   with the existing `diffAddedBackground` wash, underneath the row-state
   tints, through the one row-background site that both row kinds and the
   pinned sticky copy already share. A test row's spoken value gains the word
   `Test`.
2. **Sticky slot tolerance.** `TreeStickyRule.slotTolerance` goes from `1e-6`
   to `0.5` points. SwiftUI's `ScrollViewProxy.scrollTo` rounds a programmatic
   offset to the backing pixel: at backing scale 1, a target of `1165.5`
   settled at `1165.0`. At scale 1, a click on a pinned copy therefore lands
   half a point short and leaves the clicked folder's row covered. A Core
   round-trip pass with floored offsets pins why the tolerance is needed, and
   an app-bundle measurement pins the rounding itself.
3. **Documentation drift.** `app-window.md` claims
   `TreeStickyScrollListingTests` reveals `a/f45`. It actually reveals
   `a/f00`. That sentence, and any other the merged implementation contradicts
   in the two sticky entries, gets corrected.

Nothing changes on iOS. There is no new setting. "Run Test", ⌘U and the test
runner keep their current predicate and behaviour.

## Context

- **Core files involved:**
  - `Sources/PisakaCore/TestCommand.swift`
  - `Sources/PisakaCore/TreeTestRule.swift` (new)
  - `Sources/PisakaCore/TreeGitStatus.swift` (`TreeGitState.accessibilityValue`)
  - `Sources/PisakaCore/ChromeColorRole.swift`
  - `Sources/PisakaCore/TreeStickyRule.swift`
- **App files involved:**
  - `Sources/Pisaka/ProjectTreeView.swift`: `DirectoryNodeView`,
    `TreeNodeShape`, `FolderDisclosureStyle`/`FolderDisclosureRow`,
    `FileRowView`, `TreeStickyFolderReport`, `TreeStickyFoldersKey`,
    `TreeStickyRowView`, `TreeRowBackground`
  - `Sources/Pisaka/ChromePalette.swift` (comment beside `diffAddedBackground`
    only; no value changes)
- **Core tests:**
  - `Tests/PisakaCoreTests/TreeTestRuleTests.swift` (new)
  - `TestCommandTests.swift`
  - `TreeGitStatusTests.swift`
  - `ChromeRoleMappingTests.swift`
  - `TreeStickyRuleTests.swift`
  - `ChromeThemeSourceGatingTests.swift`
- **App tests:**
  - `Tests/PisakaAppTests/TreeRowBackgroundTests.swift`
  - `Tests/PisakaAppTests/TreeTestRowWashTests.swift` (new)
  - `Tests/PisakaAppTests/TreeStickyScrollRoundingTests.swift` (new)
  - the existing sticky suites (`TreeStickyScrollListingTests`,
    `TreeStickyStackLayoutTests`)
- **Docs:**
  - `docs/architecture/core-workspace.md`: the new rule's entry, and the
    `TreeStickyRule.swift` entry's Tolerance paragraph
  - `docs/architecture/app-window.md`: the project tree's entry, and the
    sticky entry's **Tests**
  - `docs/architecture/core-theme.md`: the role reuse, the canonical rule
    list, rule fifty-two
  - `docs/architecture/core-services.md`: the `TestCommand` entry
  - `docs/FEATURES.md`, `README.md`
  - `CLAUDE.md`: the index entry and the rule count
- **Patterns to follow:**
  - **A pure Core rule read by the tree**, as with `TreeChainRule`,
    `TreeRevealRule` and `TreeStickyRule`.
  - **A colour reaching a tree row only through a Core role answer**, as
    `ChromeColorRole.treeNameRole(for:)` does under rule fifty-one.
  - **One row-background site for every tree row kind**, `TreeRowBackground`.
  - **Hosted-render bitmap tests** through `HostedRender`, which caches
    swatches. Keep window counts small: one render per appearance, and no
    loops of windows.
- **Dependencies:** none new.

## Development Approach

- **Testing approach.**
  - Regular (code first, then tests) for Part 1.
  - TDD for Part 2's tolerance. The floored round-trip pass is written first,
    seen red at `1e-6`, and then the constant changes.
- Complete each task fully before moving to the next. A task whose code change
  trips a source-gating suite updates that suite and the documents it pins
  **in the same task**, so the suite stays green at every task boundary.
- Read the `docs/architecture/` entry of every file before touching it, and
  update that entry with the change.
- Every `xcodebuild` uses the pinned Xcode and the project's single
  derived-data path:

  ```sh
  DEVELOPER_DIR=/Applications/Xcode_26.3.app/Contents/Developer xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-build test
  ```

  The macOS `build` uses the same flags, and so does the iOS build, with
  `-destination 'generic/platform=iOS'`.
- No brand names and no references to other editors anywhere: code, comments,
  docs or commits.
- **CRITICAL: every task MUST include new/updated tests**
- **CRITICAL: all tests must pass before starting next task**

## Execution notes (decisions already taken; record any further conflict found and its resolution here)

1. **Sharing the conventions with `TestCommand`.**
   - `TestCommand` gains a second public predicate beside `isTestFile`:
     `followsTestNamingConvention(fileName:)`. It holds the ecosystem naming
     table for every language and answers `false` for Rust.
   - `isTestFile(fileName:)` is redefined as "Rust, or
     `followsTestNamingConvention`". The table therefore exists once, and a
     convention added to it reaches both predicates by construction.
   - The tree reads only the new predicate.
   - What "Run Test" and ⌘U offer is unchanged. A Core test pins that for
     every non-Rust convention the two agree, both on positive samples and on
     near-miss negatives.
2. **The wash role cannot be spelled in the tree.**
   - Rule nineteen of `ChromeThemeSourceGatingTests` forbids any app file but
     the palette from naming `diffAddedBackground`.
   - Resolution: Core answers it, through
     `ChromeColorRole.treeRowWashRole(isTestRow:)`. It returns
     `.diffAddedBackground` for a test row and `nil` otherwise, beside
     `treeNameRole(for:)`. No role and no palette value is added.
   - A new rule **fifty-two** pins three things:
     - no app file declares `func treeRowWashRole`;
     - the app files spelling `treeRowWashRole(` equal
       `{ProjectTreeView.swift}`;
     - inside that file, the call appears only within
       `enum TreeRowBackground`'s body.
   - The rule count moves to fifty-two:
     - a marker for the new rule;
     - a bullet for it in the suite's header inventory;
     - an entry `52: "fifty-two"` in the spelled table;
     - `core-theme.md`'s "The fifty-two rules, each invisible to the
       compiler:";
     - `CLAUDE.md`'s "and its fifty-two rules".
   - The gated set stays sixty-six, because no new file under `Sources/Pisaka`
     is created.
3. **The shared site also serves the commit dialog.**
   - `CommitDialogView`'s `CommitFileRow` calls
     `TreeRowBackground.color(for:resolving:)`, and it must not be washed.
     That method stays exactly as it is.
   - `TreeRowBackground` gains two members:
     - `layers(for:isTestRow:)`: the roles bottom-to-top, wash first and then
       the state's role, with `nil`s dropped.
     - A `background(for:isTestRow:resolving:)` view that paints those layers.
       Each layer is the resolver's colour unchanged, with no alpha composed.
   - All three tree `rowBackground`s (the folder row, the file row and the
     pinned copy) call that one method. Rule thirteen's `chromeRowBackgrounds`
     pins their bodies, so it is updated to the new text.
   - The row-state switch detector must still find exactly one state→role
     table in `ProjectTreeView.swift`. `layers` calls `role(for:)` and does
     not restate the table.
4. **The floored round trip would be vacuous on the existing fixture.**
   - `deep` lies on whole points with a row height of 22, so every anchor
     lands on a whole point and flooring changes nothing.
   - The second pass therefore runs on that fixture shifted by half a point,
     every top and bottom `+ 0.5`. This puts rows on the half-point grid, as
     at interface scale 1.
   - The pass asserts that it is not vacuous: at least one floored landing
     differs from the exact one.
5. **The app-bundle rounding measurement and the backing scale.**
   - **What was measured, and where.** The acceptance review's probe ran in
     this same headless `xcodebuild` host, and every reading it took says
     backing 1.0, for example `h 43.00 target 30 k 3 animated 1 pixelScale 1.0
     backing 1.0: expected 1165.500000 landed 1165.000000`. The rounding was
     measured at scale 1 only. No public API forces a window's backing scale,
     and nothing here claims what another scale does.
   - **The scale is read at run time.** The test reads
     `render.window.backingScaleFactor` and records the value observed in
     these notes.
     - When it is exactly 1, the test asserts the three measured properties:
       - the settled offset lies on the whole-point grid;
       - it is exactly `0.5` short of the target
         (`settled == target − 0.5`);
       - that difference is `≤ TreeStickyRule.slotTolerance`.
     - At any other scale, the test asserts only the one property the
       tolerance guarantees: `|settled − target| ≤
       TreeStickyRule.slotTolerance`. The test never asserts a rounding nobody
       measured.
   - **The off-grid target comes from the measurement, not from an assumed
     viewport parity.** Tree rows lie on the half-point grid at interface
     scale 1. A viewport-parity trick that assumes a whole-point row top can
     therefore land the target back on the grid. Instead, the window height
     is derived from the revealed row's **measured** top, so that the computed
     target lies exactly half a point off the whole-point grid. Before
     scrolling, the test asserts that the target is off the grid (and inside
     the scrollable range), and fails rather than passing silently otherwise.
     This mirrors the non-vacuity assertion of the floored Core pass.
   - **How the row's top is measured.** Through the tree's own content-space
     report: the `TreeStickyFolderReport` of the revealed file's parent
     folder, read by the test's wrapper view through
     `.onPreferenceChange(TreeStickyFoldersKey.self)`. For this to be
     readable, the two types drop `private` and become internal (reached only
     through `@testable import`). Nothing else about them changes. If a
     source-gating suite pins their access level, it is updated in the same
     task and the change is recorded here.
   - With the scale read at run time and the target made off-grid by
     measurement, the test is deterministic. There is no fallback that
     deletes it.
6. **Root-relative components come from listing names, not URL arithmetic.**
   - `DirectoryNodeView` carries the root-relative components of its contents
     directory. The root is built with `[]`, which is also what keeps the root
     from ever being a test folder.
   - A child folder appends its entry's name; a chain appends every segment's
     name, via a `segmentNames` helper on `TreeNodeShape`; a file appends its
     own name.
   - Canonicalization never enters, and the cost is the row's depth.
7. **The wash suite's selected row is a file of its own (Task 3).**
   - Conflict: the hosted window is never key, so a selected row paints
     `selectionInactive`, which is opaque. A washed row that is also selected
     cannot show its wash, so `a_test.go` could not both be the active tab and
     be among the rows asserted washed.
   - Resolution: `TreeTestRowWashTests` adds a second convention-named file,
     `c_test.go`, opened as the active tab. The washed set asserted is the
     `Tests` folder, `Tests/Gate.swift` and `a_test.go`, all unselected; the
     selected-row assertion compares `c_test.go` against the unselected
     `a_test.go`.
   - Also: the plan names rule thirteen as `chromeRowBackgrounds`' rule; in the
     suite it is rule thirty-five. That is the rule updated.
8. **Task 4: other tests inside `(slot, slot + 0.5]`.** Only
   `testACappedCandidateJoinsExactlyOnceFullyUnderTheStack` pinned such a
   value as not yet joined (`43.5`, `43.999`); it was updated and `43.4` added
   as the nearest point still out. No other test in `TreeStickyRuleTests`
   needed a change, and the whole Core suite passed unchanged otherwise. The
   floored pass failed at `1e-6` with 1,314 assertions (the parent covered,
   e.g. "b covered — c clicked at 67.0, H 66.0, landed 44.0") and passes at
   `0.5`. The round trip became a shared helper both passes call, so the test
   count stays 32.
9. **Part 3 findings.** List here every sentence corrected in the two sticky
   entries, beyond the `a/f45` one.
10. **Task 5: what was observed, and two conflicts found.**
    - **Backing scale observed:** `render.window.backingScaleFactor` read
      `1.0` in this headless host, so the scale-1 branch ran: the measured
      target `1370.5` (viewport derived from `t`'s measured node) settled at
      `1370.0` — on the grid, exactly half a point short, within the tolerance.
    - **Access level.** `TreeStickyFolderReport` and `TreeStickyFoldersKey` are
      internal. The report's `shape` had to stay `fileprivate`, because
      `TreeNodeShape` is private and Swift refuses an internal property of a
      private type; the test identifies `t` by `scrollID` instead. No
      source-gating suite pins either type's access level.
    - **Conflict: the second reveal never reached the on-screen row.** Both
      `.onChange(of: reveal)` sites in `DirectoryNodeView` used the deprecated
      one-argument form, whose action reads the *previous* update's `reveal`
      (probed: `nil` while the tree's `liveReveal` was token 2). So a request
      never expanded an on-screen folder nor scrolled to an on-screen row in
      the shipping app either; only `.onAppear` honoured one. Resolution: both
      sites moved to the two-argument form (macOS 14, the deployment floor).
      The rounding test's second reveal pins the row half; a new
      `TreeRevealOnScreenTests` pins the node half (seen red with the node
      site reverted). The reveal host types (`TreeRevealHost`,
      `TreeRevealHostState`) are internal in the rounding suite's file and
      shared by both suites. Documented in `app-window.md`'s reveal entry.
    - The condition-waits lay the host out every turn, as `HostedRender`'s
      `settle()` does, since the hosted window is never ordered on screen.
    - **Deviation: the first reveal does not scroll.** As first written, the
      first reveal scrolled animated in the 300-point window; in the full
      bundle that animation stalled past the "held still" wait and resumed
      after the raw scroll to `0` (landing at `60`). The window now starts
      taller than the document (3,200 points), so the first reveal's centred
      target clamps to the top and nothing animates; the derived height is
      then sized around a nominal 300-point viewport,
      `T = floor(c − 150) + 0.5`, rather than from the first window's `H0`.
      Still one window, resized once. Stable over five iterations and the
      full bundle.

## Implementation Steps

### Task 1: Core — the test-row rule and the shared naming conventions

**Files:**
- Modify: `Sources/PisakaCore/TestCommand.swift`
- Create: `Sources/PisakaCore/TreeTestRule.swift`
- Create: `Tests/PisakaCoreTests/TreeTestRuleTests.swift`
- Modify: `Tests/PisakaCoreTests/TestCommandTests.swift`
- Modify: `docs/architecture/core-workspace.md`,
  `docs/architecture/core-services.md` (the `TestCommand` entry), `CLAUDE.md`
  (index)

- [x] Add `TestCommand.followsTestNamingConvention(fileName:)`.
  - It holds today's naming table, including JS/TS `.test.`/`.spec.`, py, rb,
    php, exs, go and swift, and answers `false` for `rs`.
  - Redefine `isTestFile` as `ext == "rs" || followsTestNamingConvention(...)`,
    so the table exists once.
  - Doc comments state why Rust is the one difference and that "Run Test"
    behaviour is unchanged.
- [x] Create `TreeTestRule`, a pure, Foundation-only enum.
  - The closed folder-name set is `test`, `tests`, `__tests__`, `spec`,
    `specs`, matched case-insensitively.
  - `isTestRow(components:isFolder:)` takes root-relative path components,
    where `[]` is the root and never a test row.
  - A folder is a test row when any of its components is a test-folder name.
    This covers itself, its ancestors and every segment of a chain judged by
    its tail's path.
  - A file is a test row when any ancestor component is a test-folder name, or
    when its own name follows a naming convention.
  - It reads no file and calls no service; the cost is one walk over the
    components. The doc comment states inheritance "the way a git ignore
    does" and the Rust exception.
- [x] Write `TreeTestRuleTests` covering:
  - every folder name in the set, in upper/mixed case;
  - a near miss (`testing`, `contest`) that is not a test folder;
  - the root exclusion: `[]` is never a test row;
  - inheritance through an ancestor: `Tests/PisakaCoreTests/Support/Gate.swift`
    and `src/test/java`;
  - a chain judged by its tail, with the test segment first, middle or last;
  - a Rust file washed only through a folder (`src/lib.rs` no,
    `tests/integration.rs` yes);
  - a file named `test` with no extension, which is not a folder and is not a
    test row by its own name.
- [x] In `TestCommandTests`, add the agreement test.
  - For a table holding one positive sample per non-Rust convention, plus
    near-miss negatives, `followsTestNamingConvention` and `isTestFile` agree.
  - For `rs`, `isTestFile` answers true and the naming predicate false.
  - Existing `isTestFile` tests stay green unchanged.
- [x] Add the `TreeTestRule.swift` entry to `core-workspace.md` (contract, edge
  cases, the Rust exception, the sharing decision). Update the `TestCommand`
  entry in `core-services.md` for the new predicate. Add `TreeTestRule.swift`
  to `CLAUDE.md`'s core-workspace index line.
- [x] Run `swift test`; it must pass before Task 2.

### Task 2: Core — the spoken `Test` word and the wash role

**Files:**
- Modify: `Sources/PisakaCore/TreeGitStatus.swift`
- Modify: `Sources/PisakaCore/ChromeColorRole.swift`
- Modify: `Tests/PisakaCoreTests/TreeGitStatusTests.swift`
- Modify: `Tests/PisakaCoreTests/ChromeRoleMappingTests.swift`
- Modify: `Sources/Pisaka/ProjectTreeView.swift` (call sites only, passing
  `isTestRow: false` until Task 3 wires the rule)

- [x] Give `TreeGitState.accessibilityValue` a required `isTestRow: Bool`
  parameter, so no call site can silently omit it.
  - A folder's words are `expanded`/`collapsed`, then `Test`, then the git
    word, then the diagnostic words.
  - A file's words are `Test`, then the git word, then the diagnostic words.
  - Words are joined with `", "` as today. Update its doc comment.
- [x] Add `ChromeColorRole.treeRowWashRole(isTestRow:)` beside
  `treeNameRole(for:)`.
  - It returns `.diffAddedBackground` for a test row and `nil` otherwise.
  - The doc comment states the reuse and its reason: the palette's faint green
    wash at its own alpha, no role added, and the role set closed against call
    sites.
- [x] Update the two existing call sites in `ProjectTreeView.swift` to pass
  `isTestRow: false` for now, so the build stays green.
- [x] Tests in `TreeGitStatusTests`:
  - every position of `Test`: a file alone (`"Test"`), a file with git
    (`"Test, Modified"`), a file with git and diagnostics, and a folder
    expanded and collapsed with and without git and diagnostics;
  - a non-test row, whose value is unchanged from today.
- [x] Tests in `ChromeRoleMappingTests`: both answers of `treeRowWashRole`.
- [x] Run `swift test`; it must pass before Task 3.

### Task 3: App — wire the rule to the rows through the one row-background site; gating rule fifty-two

**Files:**
- Modify: `Sources/Pisaka/ProjectTreeView.swift`
- Modify: `Sources/Pisaka/ChromePalette.swift` (comment beside
  `diffAddedBackground` naming the new consumer, as the palette's other reuse
  comments do; no value changes)
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`
- Modify: `Tests/PisakaAppTests/TreeRowBackgroundTests.swift`
- Create: `Tests/PisakaAppTests/TreeTestRowWashTests.swift`
- Modify: `docs/architecture/core-theme.md`, `docs/architecture/app-window.md`,
  `CLAUDE.md` (rule count)

- [x] Carry root-relative components down the recursion.
  - `DirectoryNodeView` gets a `relativeComponents: [String]` for its contents
    directory. The root passes `[]`.
  - A child node gets `relativeComponents + childShape.segmentNames`, where
    `segmentNames` is a new `TreeNodeShape` helper: `[entry.name]` for a folder
    and the chain's segment names for a chain.
  - Each node asks `TreeTestRule.isTestRow(components:isFolder: true)` once per
    render. Each file row is asked with `relativeComponents + [entry.name]` and
    `isFolder: false`.
- [x] Hand the answer to the rows.
  - `FolderDisclosureStyle`/`FolderDisclosureRow` and `FileRowView` take
    `isTestRow`.
  - `TreeStickyFolderReport` carries it, so the pinned copy reads the node's
    own answer.
  - The create draft row is not wired and is never washed.
  - The row being renamed keeps its wash: the background is unaffected by
    `isDrafted`. Its spoken value stays `""`.
- [x] Extend `TreeRowBackground`.
  - Add `layers(for:isTestRow:)`: the wash role from
    `ChromeColorRole.treeRowWashRole(isTestRow:)` first, then `role(for:)`,
    with `nil`s dropped. It must not restate the state→role table.
  - Add `background(for:isTestRow:resolving:)`, which paints each layer as the
    resolver's colour unchanged and bottom-to-top, composing no alpha.
  - The three tree `rowBackground`s (folder row, file row, pinned copy) call
    it.
  - `color(for:resolving:)` stays unchanged for `CommitFileRow`, which must not
    be washed. The pinned copy's `bgPanel` ground stays beneath its row
    background.
- [x] Pass `isTestRow` into both rows' `accessibilityValue` calls. The draft
  row's value stays `""`.
- [x] Update `ChromeThemeSourceGatingTests`.
  - Update `chromeRowBackgrounds` to the three new tree bodies.
  - Add **rule fifty-two**, "the tree's test wash is Core's one answer, painted
    at the one row-background site". Over stripped source, it checks:
    - no app file declares `func treeRowWashRole`;
    - the app files spelling `treeRowWashRole(` equal
      `{ProjectTreeView.swift}`;
    - in that file, every spelling lies inside `enum TreeRowBackground`'s body.
  - Add the marker, the header-inventory bullet, and `52: "fifty-two"` in the
    spelled table.
  - Confirm that rule nineteen (no app file names `diffAddedBackground`) and
    the row-state switch detector still pass untouched.
- [x] Update `core-theme.md`:
  - record the reuse beside `diffAddedBackground` (its consumer, reached
    through `treeRowWashRole`, and the reason);
  - add rule fifty-two to the canonical list, opening "The fifty-two rules,
    each invisible to the compiler:";
  - state that the tree rows paint the wash through `TreeRowBackground`'s one
    layered method while the commit row keeps `color(for:resolving:)`.

  Change `CLAUDE.md`'s "its fifty-one rules" to "fifty-two".
- [x] Update the project tree's entry in `app-window.md`:
  - the wash beneath the state tints;
  - the shared site;
  - the pinned copy washed from the same answer;
  - the drafts (renamed row keeps it, create draft never washed);
  - the spoken `Test` word and its position;
  - the components carried down the recursion.
- [x] Extend `TreeRowBackgroundTests` to pin `layers(for:isTestRow:)` for all
  ten (state × isTestRow) combinations: the wash role is first, the state's
  role follows, and `.plain` without a test row has no layers. Also pin that
  the layered background asks the resolver once per layer and composes no
  alpha, and that `color(for:resolving:)`'s existing pins are unchanged.
- [x] Create `TreeTestRowWashTests` (app bundle, `HostedRender`, interface
  scale 1).
  - **Project.** A temporary project with a `Tests/` folder (expanded, holding
    one file), a sibling plain folder, a convention-named test file
    (`a_test.go`) beside a plain `b.go`, and the test file open as the active
    tab so its row is selected.
  - **Renders.** One render per appearance (dark and light): two windows in
    total, and no window per sample.
  - **Assertions in each appearance:**
    - a washed row's background pixel, sampled in a text-free area of the row,
      differs from an unwashed sibling's and from the tree's canvas below the
      rows;
    - the washed rows include the `Tests` folder, its child file and
      `a_test.go`;
    - the selected test row's pixel differs from an unselected washed row's,
      so the selection tint is still shown over the wash.
- [x] Run `swift test`, `swiftlint --strict`, `xcodegen generate`, and the
  app-layer bundle under the pinned Xcode. All must pass before Task 4.
  (App bundle ran under the installed Xcode 27.1: the pinned 26.3 is not
  installed on this machine.)

### Task 4: Core — the sticky slot tolerance sized to the scroll rounding (TDD)

**Files:**
- Modify: `Tests/PisakaCoreTests/TreeStickyRuleTests.swift`
- Modify: `Sources/PisakaCore/TreeStickyRule.swift`
- Modify: `docs/architecture/core-workspace.md` (the `TreeStickyRule.swift`
  entry's **Tolerance** paragraph, and any sentence restating the old `1e-6`
  reasoning)

- [x] Write the floored pass of
  `testAClickLeavesTheFolderAndItsInnermostAncestorsInSight` first.
  - Add a second pass over the `deep` fixture shifted by `+0.5` on every top
    and bottom (rows on the half-point grid).
  - Scroll each clicked copy's folder to its anchor's landing **floored to a
    whole point** (the backing pixel at scale 1) and assert the same in-sight
    property for the clicked folder and its innermost `cap` ancestors.
  - Assert the pass is not vacuous: at least one floored landing differs from
    the exact one.
  - Run it, and confirm it fails at `slotTolerance = 1e-6`.
- [x] Change `TreeStickyRule.slotTolerance` to `0.5`.
  - Rewrite its doc comment. Keep the true half of the record: the raw
    `NSClipView` probe at backing scale 1 read `48.4`, `66.25` and `66.1` back
    unchanged through `scroll(to:)`. Add the measured half: SwiftUI's
    `ScrollViewProxy.scrollTo` settled a target of `1165.5` at `1165.0` at
    backing scale 1, and the click goes through `scrollTo`, not the raw clip
    view.
  - State that the tolerance is sized to the rounding (half a backing pixel at
    most for any scale ≥ 1), not to the drift, and stays far below the
    smallest row.
  - State the cost honestly: a candidate joins up to half a point early, so at
    most a half-point sliver of its real row shows under the copy in its slot,
    which is the right trade against a covered row after a click.
  - Correct the type-level **Tolerance** paragraph the same way. Also correct
    the **Chain** paragraph wherever it claims the click lands exactly at the
    equality.
- [x] Update `testACappedCandidateJoinsExactlyOnceFullyUnderTheStack`.
  - With cap 2, `top: 43.5` and `43.999` now join (`[b, c]`), and `43.4` and
    `43` do not (`[a, b]`).
  - Rewrite its comments: the full chain's `≤` now allows the rounding's half
    point.
  - Check every other test in the file that pins a value inside
    `(slot, slot + 0.5]` as not yet joined, update it to the new boundary, and
    record each one in the execution notes.
  - `testMeasurementDriftChangesNoAnswer`'s last assertion stays as it is.
- [x] Correct the **Tolerance** paragraph of `core-workspace.md`'s
  `TreeStickyRule.swift` entry: the same two halves of the record, the new
  value, its sizing, its cost, and the floored round-trip pass that pins it.
  `measurementTolerance`, the cap, the anchor arithmetic and the drawing stay
  unchanged.
- [x] Run `swift test`; it must pass before Task 5.

### Task 5: App — pin the scroll rounding the tolerance is sized against

**Files:**
- Create: `Tests/PisakaAppTests/TreeStickyScrollRoundingTests.swift`
- Modify: `Sources/Pisaka/ProjectTreeView.swift` (`TreeStickyFolderReport` and
  `TreeStickyFoldersKey` drop `private`; nothing else)
- Modify: `docs/architecture/app-window.md` (sticky entry's **Tests**, and the
  note that the two types are internal for the test's read)

- [x] Make `TreeStickyFolderReport` and `TreeStickyFoldersKey` internal, so
  the test reads them through `@testable import`. Their doc comments say why.
  If a source-gating suite pins their access level, update it here and record
  that in the execution notes.
- [x] Write one `HostedRender` test at interface scale 1. It uses one window,
  resized once, and no loop of windows.
  - **Project.** A temporary project `p` with:
    - sixty collapsed folders `d00`…`d59`;
    - a folder `t/` holding exactly one file `x`;
    - sixty root files after the folders.

    This places `t/x` deep enough that its centred offset is inside the
    scrollable range.
  - **Host.** A test-local wrapper view hosts `ProjectTreeView`. It takes its
    `reveal:` from a test-local `ObservableObject`, so the test can issue a
    second request later. It reads `TreeStickyFoldersKey` through
    `.onPreferenceChange` into that object.
  - **First reveal.** Issue a `TreeRevealRequest` for `t/x` to expand `t`, then
    wait until it settles.
  - **Measure `t`.** Read `t`'s report frame in the tree's content space;
    `XCTUnwrap` fails loudly if none arrived.
    - With `h = metrics.scaled(ChromeGeometry.rowHeight)`, first assert that
      `t.frame.height == 2h`. This checks the derivation against the
      measurement instead of assuming it.
    - `x`'s row is the node's last row, so its centre is
      `c = t.frame.maxY − h/2`.
  - **Derive the window height.** Read the clip view's height `H0` and the
    scrollable range.
    - Choose `T = floor(c − H0/2) + 0.5`, a target exactly half a point off the
      whole-point grid.
    - Set `H = 2·(c − T)`. Resize the window's content height by `H − H0` and
      settle.
    - Re-read the clip view's height and recompute `target = c − H/2`.
  - **Non-vacuity, before scrolling.** Assert that
    `target − floor(target) == 0.5` exactly, and that
    `0 < target < documentHeight − H`. If either fails, the test fails; it
    never passes silently.
  - **Second reveal.** Raw-scroll the clip view to `0`, then issue a second
    request for `t/x` with the next token. This is the tree's real reveal
    path: `ScrollViewProxy.scrollTo` at `TreeStickyRule.revealAnchorY`.
  - **Wait.** Use a causal condition-wait on the clip view's
    `bounds.origin.y`: it must have left `0` and held still across consecutive
    run-loop turns. `XCTFail` on timeout. No timed sleep.
  - **Assertions.** Read `s = render.window.backingScaleFactor` and record the
    value observed in the execution notes.
    - **If `s == 1`:**
      - the settled offset lies on the whole-point grid;
      - `settled == target − 0.5`;
      - `target − settled ≤ TreeStickyRule.slotTolerance`.
    - **Otherwise:** only `|settled − target| ≤ TreeStickyRule.slotTolerance`.
  - **Doc comment.** It records:
    - that the probe measured backing 1.0 in this host, and that the rounding
      was measured at scale 1 only;
    - why the target is derived from the measured row rather than from
      viewport parity;
    - that no other scale's rounding is asserted.
- [x] Re-run the existing sticky suites (`TreeStickyScrollListingTests`,
  `TreeStickyStackLayoutTests`) and update them only if the new tolerance
  changes something they pin.
- [x] Add the new suite to the sticky entry's **Tests** in `app-window.md`.
- [x] Run `swift test` and the app-layer bundle under the pinned Xcode (run
  under Xcode 27.1: the pinned 26.3 is not installed on this machine); both
  must pass before Task 6.

### Task 6: Documentation drift in the sticky entries

**Files:**
- Modify: `docs/architecture/app-window.md`,
  `docs/architecture/core-workspace.md`

- [ ] In the sticky parent folders entry's **Tests**, correct
  `TreeStickyScrollListingTests` "reveals `a/f45`". The suite reveals `a/f00`,
  which expands `a` without scrolling (the centre anchor clamps to the top),
  so nothing pins at the landing. That is what its first assertion checks.
- [ ] Re-read the whole sticky entry in `app-window.md` and the
  `TreeStickyRule.swift` entry in `core-workspace.md` against the merged code
  and both sticky app suites. Fix every other sentence the implementation
  contradicts, for example a described suite setup, a revealed file, a scale
  or a count, and list each fix in the execution notes.
- [ ] Run `swift test` (the documentation-reading suites,
  `LintConfigurationTests` among them); it must pass before Task 7.

### Task 7: Verify acceptance criteria

- [ ] `swift test` green, including:
  - `TreeTestRuleTests`;
  - the `TestCommand` agreement test;
  - the spoken-value positions;
  - `treeRowWashRole`;
  - the new slot boundary;
  - the floored round trip;
  - `ChromeThemeSourceGatingTests` with rule fifty-two and both summary counts.
- [ ] `swiftlint --strict` from the repository root clean at the pinned version
  (0.65.1); `xcodegen generate` clean.
- [ ] App-layer bundle green under the pinned Xcode, with the derived-data path
  above. This includes `TreeTestRowWashTests` and
  `TreeStickyScrollRoundingTests`, whose observed backing scale is recorded in
  the execution notes.
- [ ] macOS build and iOS build (`generic/platform=iOS`) green under the pinned
  Xcode.
- [ ] Coverage: every new Core function has direct tests, with the rule, the
  predicate, the spoken value, the wash role and the tolerance boundary all
  covered.
- [ ] `CLAUDE.md` under 60,000 characters (`LintConfigurationTests`).
- [ ] Grep the diff for brand names and for references to other editors: none.

### Task 8: Update documentation

- [ ] `docs/FEATURES.md`: under the project tree, say that test files and test
  folders, and everything below a test folder, are marked with a faint green
  row wash. Name the folder set and the naming conventions, note that Rust
  files are marked only inside a test folder, and note that the name colour
  stays the git state's.
- [ ] `README.md`: one line in the project tree's feature bullet for the
  test-row mark.
- [ ] `CLAUDE.md`: confirm the index carries `TreeTestRule.swift` (Task 1) and
  the rule count reads fifty-two (Task 3). No other change, and no growth
  beyond those words.
- [ ] Final consistency pass over `app-window.md`, `core-workspace.md`,
  `core-theme.md` and `core-services.md` against the code as merged on the
  branch.
