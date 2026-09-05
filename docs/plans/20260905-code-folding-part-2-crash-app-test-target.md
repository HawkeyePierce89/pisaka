# Code folding, part 2 — the crash, an app-layer test target, Fold All / Unfold All, folded-header severity

## Overview

Part 1 (PR #57) shipped folding with a launch-time trap that no gate in the
repository can see. `FoldingTypesetter` declares only `init(folded:)`, so Swift
emits an "unimplemented initializer" stub for the inherited `init()`; TextKit
re-enters layout (`_setExtraLineFragmentRect` → `invalidateDisplay` →
`_ensureLayoutCompleteForVisibleRect`) while the manager's typesetter is busy
and allocates a **second** instance of the typesetter's class through
Objective-C `init` — straight into that trap. It needs no fold at all: any
document long enough to produce an extra line fragment on
`textView.string = text` is enough, which is every session restore and every
tab switch. The diagnosis was reproduced standalone during planning: a Swift
`NSATSTypesetter` subclass with only a custom designated initializer, allocated
and `init`-ed through the Objective-C runtime, dies with `Fatal error: Use of
unimplemented initializer 'init()'` — the exact `EXC_BREAKPOINT` in the report.

This plan fixes it **test-first**, adds the missing test layer (a headless
macOS XCTest bundle driving the editor's real TextKit stack), makes both smoke
launches render a real document so a launch/tab-switch crash fails CI, settles
by measurement the hiding question the part 1 docs admit was never measured,
and then completes the feature: Fold All / Unfold All, and the worst diagnostic
severity on a folded header line. macOS only; iOS untouched.

## Context

**Files involved**

- Fix: `Sources/Pisaka/BracketOverlayLayoutManager.swift` (`FoldedRanges`,
  `FoldingTypesetter`, `BracketOverlayLayoutManager.init()`).
- New app-layer test bundle: `Tests/PisakaAppTests/` (new), `project.yml`
  (target + explicit `schemes:` block), `.github/workflows/ci.yml` (new step).
- Smoke launch: `.github/workflows/ci.yml` and `.github/workflows/release.yml`
  (the two copies of one body, which `ReleaseWorkflowTests` pins as identical
  apart from `APP=`).
- Fold All / Unfold All: `Sources/PisakaCore/FoldState.swift`,
  `Sources/Pisaka/FoldCommands.swift`, `Sources/Pisaka/CodeEditorView.swift`,
  `Sources/Pisaka/FoldController.swift`.
- Folded-header severity: new `Sources/PisakaCore/FoldSeverityRule.swift`,
  `Sources/Pisaka/LineNumberRulerView.swift`.
- Gutter seam + severity draw: `Sources/Pisaka/LineNumberRulerView.swift`.
- Suites that pin the above:
  `Tests/PisakaCoreTests/FoldingSourceGatingTests.swift`,
  `ReleaseMetadataTests.swift`, `ReleaseWorkflowTests.swift`,
  `LintConfigurationTests.swift`, `FoldStateTests.swift`.
- Docs: `docs/architecture/core-folding.md`,
  `docs/architecture/app-editor-overlays.md`, `CLAUDE.md`, `README.md`,
  `docs/FEATURES.md`, `docs/RELEASING.md`.

**Facts established during planning** (do not re-derive)

- `Tests/` already carries the nested `.swiftlint.yml`; the root config
  `included:` is `[Sources, Tests]`, so `Tests/PisakaAppTests/` is linted under
  the same pair with no config change.
- `Package.swift` uses SwiftPM's **default layout** for both targets — neither
  `PisakaCore` nor `PisakaCoreTests` declares a `path:` — and SwiftPM ignores an
  undeclared directory under `Tests/` **silently**: a probe directory
  `Tests/PisakaAppTests` containing a Swift file produced no warning and no
  error from `swift build --build-tests`. That is why `swift test` stays
  untouched and Foundation-only.
- The generated project ships **no** shared scheme today (`Pisaka.xcodeproj`
  has no `xcschemes/`); `xcodebuild -scheme Pisaka` works off an autocreated
  one. A test action cannot be relied on there, so `project.yml` gains an
  explicit `schemes:` block.
- `swiftlint --strict` is clean at 0.65.1. `CodeEditorView.swift` measures
  ~1741 effective lines against the 1886 ceiling, so the app-side additions
  have room; the ceilings are measured off `PisakaApp.swift`, which this plan
  does not grow.
- The session lives in `UserDefaults` under `session.projects` (a
  `PropertyListEncoder`-encoded `SessionCatalog`), domain `ws.karmanov.pisaka`.
  That is the seam the smoke launch seeds.
- `DiagnosticSeverity` is `Comparable` **by seriousness**, `.error` greatest,
  so "worst" is `max(...)` — the same expression
  `DiagnosticStore.worstSeverityPerLine` already uses.
- ⌘⌥⇧← / ⌘⌥⇧→ are free: the only arrow shortcuts declared in the app are
  `FoldCommands`' two, and the existing gating regex `\[\.command, \.option\]`
  does not match a three-modifier list.
- The part 1 manual pass has **eight** numbered items (the ticket says seven);
  all eight are carried here.
- `CanonicalPath` is `internal` to Core, and the app layer already spells
  `standardizedFileURL.resolvingSymlinksInPath().path` inline at five sites
  (`SourceViewerWindowController`, `PisakaApp` ×2, `RootView_iOS`, and the fold
  key). The fold key is therefore not a fourth spelling — it is the established
  app-layer idiom, and this plan records the exception rather than opening a
  cross-cutting refactor.

**Related patterns**

- `DatabaseViewerSourceGatingTests` / `FoldingSourceGatingTests` — the
  comment-and-literal-stripped repository-file suite shape.
- `ReleaseWorkflowTests.testTheTwoSmokeLaunchesAreTheSameCheck` — the two smoke
  bodies must stay byte-identical apart from `APP=`, so any change to one is a
  change to both.
- The writer-gate reader rule: folding names neither `autosave` nor
  `localChanges`, and nothing here changes that.

## Development Approach

- **Testing approach**: TDD for the crash (Task 1 writes and runs the failing
  test; Task 2 fixes it). Regular for everything after.
- Domain decisions in `PisakaCore` with `swift test` coverage; AppKit behaviour
  in the new headless bundle; SwiftUI glue stays untested.
- Read the matching `docs/architecture/*.md` entry before touching a file and
  update it in the same task.
- **CRITICAL: every task includes new/updated tests.**
- **CRITICAL: all gates pass before the next task** — `swift test`,
  `swiftlint --strict`, and (from Task 1 on) `xcodebuild test -scheme Pisaka
  -destination 'platform=macOS'`. Task 1 is the one stated exception, below.
- No timers, no polling, no sleeps in the new tests: force layout with
  `ensureLayout`, assert on the layout manager's answers.
- No product or brand name anywhere: code, comments, tests, docs, commits.

## Implementation Steps

### Task 1: The app-layer test target, and the failing reproduction

**Files:**

- Modify: `project.yml`
- Create: `Tests/PisakaAppTests/EditorLayoutHarness.swift`
- Create: `Tests/PisakaAppTests/FoldLayoutTests.swift`
- Modify: `.github/workflows/ci.yml`
- Modify: `Tests/PisakaCoreTests/ReleaseMetadataTests.swift`,
  `Tests/PisakaCoreTests/ReleaseWorkflowTests.swift`

- [x] Add a `PisakaAppTests` target to `project.yml`: `type: bundle.unit-test`,
      `supportedDestinations: [macOS]`, `sources: [Tests/PisakaAppTests]`,
      `dependencies: [- target: Pisaka]`. Declare `TEST_HOST`
      (`$(BUILT_PRODUCTS_DIR)/Pisaka.app/Contents/MacOS/Pisaka`) and
      `BUNDLE_LOADER: $(TEST_HOST)` explicitly if XcodeGen's preset does not
      supply them; verify by building rather than by assumption. Record in the
      file's comments why the app is the host (`@testable import Pisaka` against
      an application target) and why the target is macOS-only (every file it
      exercises is inside `#if os(macOS)`).
- [x] Add an explicit `schemes:` block for `Pisaka`: build action = the app,
      test action = `PisakaAppTests`. Record why it is explicit — the project
      shipped no shared scheme, so a test action would otherwise depend on
      whatever `xcodebuild` autocreates. Confirm
      `xcodebuild build -scheme Pisaka -destination 'generic/platform=iOS'`
      still does **not** build the macOS-only test target.
- [x] `EditorLayoutHarness.swift`: build the real stack headlessly, exactly as
      `makeNSView` builds it — `NSTextView(usingTextLayoutManager: false)`, then
      `textContainer?.replaceLayoutManager(BracketOverlayLayoutManager())`,
      inside an `NSScrollView` with a frame, no window;
      `allowsNonContiguousLayout = true` set through `textView.layoutManager`
      after the swap, so the ordering `makeNSView` documents is the ordering
      under test. Expose the storage, the manager, the container and the view,
      plus a `layOut()` helper that calls `ensureLayout(for:)` over the whole
      container. No timers, no run loop spins.
- [x] `FoldLayoutTests.swift`: **the reproduction**. Lay out a multi-line
      document, then assign `textView.string` to a second multi-line document
      exactly as `updateNSView`'s content-replaced branch does, then lay out
      again — one case with no fold installed and one with a fold installed
      before the swap. Both must survive and answer.
- [x] Add the CI step to `ci.yml`'s `build-macos` job, **before** the Release
      build and after the package resolve:
      `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination
      'platform=macOS' -clonedSourcePackagesDirPath SourcePackages
      -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO
      CODE_SIGNING_REQUIRED=NO test`, with a comment saying what this layer
      covers that `swift test` structurally cannot (AppKit subclasses with
      behaviour of their own) and why it is Debug.
- [x] Teach `ReleaseMetadataTests` the new target: it exists, it is macOS-only,
      its sources are `Tests/PisakaAppTests`, and the scheme's test action names
      it — each assertion carrying the reason it exists.
- [x] Teach `ReleaseWorkflowTests` the new step: `ci.yml`'s macOS job runs
      `xcodebuild … test` as its own step, positioned before the build step, and
      it is not skippable (no `continue-on-error`, no `if:`).
- [x] Run `xcodegen generate`, then
      `xcodebuild test -scheme Pisaka -destination 'platform=macOS'`.
      **Expected on the pre-fix code: the test process traps** with
      `Fatal error: Use of unimplemented initializer 'init()' for class
      Pisaka.FoldingTypesetter`. Capture the failure output verbatim into the
      plan's Notes section at the bottom of this file — that recorded trap is
      the test-first evidence the ticket asks for. This is the one task whose
      gate is *not* "the new bundle is green": `swift test` and
      `swiftlint --strict` must both pass, and the reproduction must trap.

### Task 2: The fix, and the hiding measurement

**Files:**

- Modify: `Sources/Pisaka/BracketOverlayLayoutManager.swift`
- Modify: `Tests/PisakaAppTests/FoldLayoutTests.swift`
- Modify: `docs/architecture/app-editor-overlays.md`

- [x] Make every instance TextKit can create equivalent: give
      `FoldingTypesetter` a working `override init()` and **no state of its
      own**. It reads the hidden set from the manager it is laying out —
      `layoutManager as? BracketOverlayLayoutManager` — which TextKit sets for
      the duration of a pass; a typesetter with no manager, or a manager of
      another class, defers to `super` for every character.
- [x] Expose the box for exactly that read: `nonisolated let foldedRanges` on
      `BracketOverlayLayoutManager` (the class is main-actor isolated through
      `NSLayoutManager`, the typesetter is asked its question off that
      isolation), and mark `FoldedRanges` `@unchecked Sendable` with the
      main-thread-only argument its doc comment already makes. Both halves of
      hiding stay in this one file, which `FoldingSourceGatingTests` pins.
- [x] Update the class's own doc comment to state the crash and the rule it
      buys: **a typesetter subclass installed on a layout manager must have a
      working `init()`**, because TextKit allocates a second instance through
      Objective-C when layout re-enters itself, and a Swift subclass that
      declares only a custom designated initializer has an `init()` that traps.
- [x] The reproduction from Task 1 now passes, both cases.
- [x] **The measurement the docs owe.** Add the hiding assertions against the
      real stack: fold a bracket block, `ensureLayout`, then assert (a) every
      hidden character carries `GlyphProperty.null`, (b) the header line and the
      block's last line share **one** line fragment, (c) the document's line
      fragment count dropped by exactly the number of hidden separators, and
      (d) unfolding restores the fragment count. Then settle whether half two is
      load-bearing, by measurement: run the same assertions with the typesetter
      half neutralised (a harness-local manager subclass, or a temporary local
      edit reverted before the task ends) and record which of (b)/(c) fail
      without it.
- [x] **A second typesetter instance sees the set**: with a fold installed,
      swap the document as `updateNSView` does, lay out again, and assert the
      fold is still hidden — the case the fix exists for.
- [x] **Placeholder geometry**: `placeholderRect(forFoldedRangeAt:)` answers a
      rect on the header line's row for a folded range's start, and `nil` for an
      offset outside the storage.
- [x] Rewrite the `app-editor-overlays.md` paragraph that says "**That is the
      reasoning, not a measurement** … still owed": state what was measured,
      where the measurement lives, and the verdict on half two. If half two
      proves inert, delete it and its gating rule per the part 1 plan and say
      so; if it is load-bearing, say exactly which assertion fails without it.
      That paragraph must not survive this task unchanged.
- [x] Run `swift test`, `swiftlint --strict`, and the new macOS test run — all
      green before Task 3.

### Task 3: The gutter's skip and the bounded invalidation, as seams

**Files:**

- Modify: `Sources/Pisaka/LineNumberRulerView.swift`
- Modify: `Sources/Pisaka/BracketOverlayLayoutManager.swift`
- Create: `Tests/PisakaAppTests/GutterFoldTests.swift`
- Modify: `docs/architecture/app-editor-overlays.md`

- [ ] Lift the collapsed-run skip out of `drawHashMarksAndLabels(in:)` into an
      `internal` seam that answers the rows the gutter *will* draw for a
      character range — the 1-based number and the line range of each — with the
      draw loop consuming it. The decision stops being visible only as pixels;
      the drawing code below it is unchanged.
- [ ] Add a small internal record on `BracketOverlayLayoutManager` of the range
      the last `setFoldedRanges(_:clampingInvalidationTo:)` invalidated,
      documented as the seam that makes the boundedness assertable. It records;
      it decides nothing.
- [ ] `GutterFoldTests.swift`: told a folded set, the ruler's row seam skips the
      collapsed run in one step and the numbering stays the buffer's (`12` then
      `27`); with nothing folded it reports every line. And: replacing the folded
      set invalidates the **union of the symmetric difference** only — folding a
      block near the end of a long document leaves the range above it
      untouched — while an unchanged set is a no-op that invalidates nothing.
- [ ] Update the ruler's and the manager's entries in `app-editor-overlays.md`
      with the two seams and why they exist.
- [ ] Run all three gates — green before Task 4.

### Task 4: Both smoke launches render a document

**Files:**

- Modify: `.github/workflows/ci.yml`, `.github/workflows/release.yml`
- Modify: `Tests/PisakaCoreTests/ReleaseWorkflowTests.swift`
- Modify: `docs/RELEASING.md`

- [ ] Extend the **shared** smoke-launch body — identically in both files, since
      `testTheTwoSmokeLaunchesAreTheSameCheck` pins them byte-for-byte apart from
      `APP=` — to seed a restorable session before the launch: write a small
      fixture project of two multi-line files under `$RUNNER_TEMP`, build a
      `SessionCatalog` plist naming that folder and those tabs, convert it to
      binary and install it with
      `defaults write ws.karmanov.pisaka session.projects -data <hex>`.
      Record in the body's comments **why** this exists: with no session there is
      no document, no layout and no re-entrant pass, which is exactly why the
      part 1 crash passed CI.
- [ ] Back the domain up with `defaults export` before seeding and restore it on
      every exit path, for the reason the existing `MARKER` line already states:
      this body is run by hand on developer Macs, where the domain is a real
      session.
- [ ] Note in the comments that the launch `exec`s the executable directly and
      passes **no arguments** — the review's observation that `open --args
      <path>` produced no window at all is recorded there as the reason the file
      route was not taken.
- [ ] **Verify the seeding actually reaches the content swap**, rather than
      asserting it: run the body locally against the built app twice — once as
      shipped (it must survive the deadline) and once with the Task 2 fix
      temporarily stashed (it must produce a crash report naming
      `FoldingTypesetter`). Restore the stash. Record both outcomes in the Notes
      section. A seeded launch that crashes only when the fix is absent is proof
      the document was laid out.
- [ ] Teach `ReleaseWorkflowTests` the seeding: both bodies carry it, the backup
      is restored on every path, the seed precedes the launch, and the two copies
      remain identical apart from `APP=`.
- [ ] Update `docs/RELEASING.md` where it describes the smoke launch's shape and
      what it does and does not prove.
- [ ] Run all three gates — green before Task 5.

### Task 5: Fold All / Unfold All

**Files:**

- Modify: `Sources/PisakaCore/FoldState.swift`,
  `Sources/Pisaka/FoldController.swift`, `Sources/Pisaka/CodeEditorView.swift`,
  `Sources/Pisaka/FoldCommands.swift`
- Modify: `Tests/PisakaCoreTests/FoldStateTests.swift`,
  `Tests/PisakaCoreTests/FoldingSourceGatingTests.swift`
- Modify: `README.md`, `docs/FEATURES.md`, `docs/architecture/core-folding.md`

- [ ] Core gains the two pure forms: "fold every candidate" and "empty",
      normalising and merging coverage exactly as the existing initialiser does,
      so nested candidates collapse to one hidden set. Unit-test both: nested
      candidates, an empty candidate list, a state that was already fully folded,
      and that the round trip fold-all → unfold-all is the empty state.
- [ ] `FoldController` gains two members that hand a **whole value** through
      `apply(_:)` — the gating suite's count of three region-level mutations
      (toggle, fold, unfold) must stay three.
- [ ] `CodeEditorView`: `foldAll()` / `unfoldAll()` on the coordinator and the
      matching entry points on the text view, mirroring `foldAtCaret()` /
      `unfoldAtCaret()` including the weakly-captured closures. After Fold All
      the caret is placed by asking `FoldCaretRule` **once, with no direction**
      (a `previous` whose location is `NSNotFound`), the same way `toggleFold`
      asks it. `CodeEditorView` must not start naming `FoldState` — the gating
      suite pins the two files that may.
- [ ] `FoldCommands` gains *Fold All* (⌘⌥⇧←) and *Unfold All* (⌘⌥⇧→) in the same
      command group, through the same first-responder route, beeping the same
      way. `PisakaApp.swift` still names `FoldCommands` exactly once and grows by
      nothing.
- [ ] Extend `FoldingSourceGatingTests`: the two new chords are spelled in
      `FoldCommands.swift` alone, the two new entry points are declared by the
      text view and called by the commands and by nobody else, and the
      three-mutation count is unchanged.
- [ ] `README.md` and `docs/FEATURES.md` list both shortcuts beside the existing
      pair; `core-folding.md` gains the two commands and the caret rule they ask.
- [ ] Run all three gates — green before Task 6.

### Task 6: The worst severity on a folded header

**Files:**

- Create: `Sources/PisakaCore/FoldSeverityRule.swift`
- Create: `Tests/PisakaCoreTests/FoldSeverityRuleTests.swift`
- Modify: `Sources/Pisaka/LineNumberRulerView.swift`,
  `Tests/PisakaCoreTests/FoldingSourceGatingTests.swift`,
  `docs/architecture/core-folding.md`, `docs/FEATURES.md`
- Modify: `Tests/PisakaAppTests/GutterFoldTests.swift`

- [ ] The pure rule: per-line worst severities (the store's existing answer) plus
      the folded state plus the line-start table in, the same array with every
      **folded header line** raised to the worst severity among itself and every
      line it hides, out. "Worst" is `max(...)` over `DiagnosticSeverity`'s
      seriousness order — the same expression
      `DiagnosticStore.worstSeverityPerLine` uses, asked rather than restated.
      Nothing new is computed off the wire; hidden lines' own entries are left
      alone, since the gutter never draws them.
- [ ] Unit-test: nested folds (the outer header shows the worst of everything
      below it, the inner header still shows its own), ties, a fold hiding
      nothing diagnosed (unchanged), an unfolded document (unchanged),
      a diagnostic on the header line itself, and degenerate geometry — an empty
      or unanchored line table — answering the input unchanged rather than
      trapping.
- [ ] Wire it in the gutter, which is the one place holding both inputs and is
      already the file the gating suite allows to be *told* a `FoldState`: it
      asks the Core rule when either input is installed and draws the answer. It
      decides nothing and computes no severity of its own.
- [ ] Extend `FoldingSourceGatingTests`: the new rule is named by exactly one app
      file, and the ruler still never mutates the state it was told.
- [ ] Extend `GutterFoldTests`: a folded header hiding an error draws the error's
      dot; folding a block that hides nothing diagnosed changes no dot.
- [ ] `core-folding.md` gains the rule; `docs/FEATURES.md` states the behaviour
      in one sentence.
- [ ] Run all three gates — green before Task 7.

### Task 7: The fold memory key, and the documentation

**Files:**

- Modify: `Sources/Pisaka/CodeEditorView.swift`, `CLAUDE.md`,
  `docs/architecture/core-folding.md`,
  `docs/architecture/app-editor-overlays.md`

- [ ] Record the path exception rather than opening a refactor: `CanonicalPath`
      is `internal` to Core, and the app layer already spells
      `standardizedFileURL.resolvingSymlinksInPath().path` inline at five sites,
      of which the fold key is one. State that in the fold key's own doc comment
      and beside the three spellings `CLAUDE.md`'s **Paths** invariant already
      names — with the reason (the transform is Core's `canonical(_:)` verbatim;
      making it `public` and routing all five through it is a cross-cutting
      change with its own verification and is deliberately not bundled here).
- [ ] Rewrite `CLAUDE.md`'s "the view layer is untested by convention" sentence
      wherever it appears (the Architecture preamble and the `Pisaka` target
      section) to say what is now true: **thin SwiftUI glue is untested; AppKit
      subclasses with behaviour of their own — the layout manager, the
      typesetter, the ruler — are tested headlessly in the app-layer bundle.**
- [ ] Add a short section to `CLAUDE.md`'s **Tests** describing the new bundle:
      what layer it covers, why it exists (a launch-time trap in a TextKit
      subclass that every existing gate was blind to), that it is headless XCTest
      and not UI automation, and that `swift test` remains the Foundation-only
      Core gate — the new directory sits under `Tests/` unreferenced by
      `Package.swift`, which SwiftPM ignores silently. Add the command to
      **Commands**. Keep both entries short — the file must stay well under its
      budget.
- [ ] `core-folding.md`: the crash, its cause, the shape of the fix and the rule
      it buys; Fold All / Unfold All; the severity rule; the memory key's
      exception.
- [ ] Run `swift test`, `swiftlint --strict` and the macOS test run.

### Task 8: Verify acceptance criteria

- [ ] `swift test` — green.
- [ ] `swiftlint --strict` from the repository root — clean. Any measured ceiling
      that moved does so **by the measured amount**, with its reason written into
      `.swiftlint.yml` beside the others, per `style-lint.md`.
- [ ] `xcodegen generate` — clean.
- [ ] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination
      'platform=macOS' build` — green.
- [ ] `xcodebuild test -project Pisaka.xcodeproj -scheme Pisaka -destination
      'platform=macOS'` — the whole new bundle green.
- [ ] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination
      'platform=iOS Simulator,name=iPhone 17 Pro' build` — green (iOS untouched;
      this is the proof, and it also proves the macOS-only test target does not
      reach the iOS build).
- [ ] Run the seeded smoke-launch body locally against the built product: it
      survives the deadline and leaves no crash report.
- [ ] Confirm the Notes section at the bottom of this plan carries both recorded
      runs — the pre-fix trap and the pre-fix seeded-launch crash report.

## Post-Completion: the mandatory manual DEBUG pass part 1 owes

Run from a DEBUG build, all eight items of the part 1 plan's pass, and record
each outcome — including anything it finds, which is fixed in this ticket — in
`docs/architecture/app-editor-overlays.md` beside the measurement Task 2 wrote.

1. The collapsed line's geometry: no leftover blank row, no clipped glyph, the
   closer behind the `…`.
2. The placeholder at two zoom levels (⌘+ / ⌘−).
3. Caret behaviour at both boundaries, the placeholder click, and shift-select
   across a folded block copying the hidden text.
4. Gutter numbering skips hidden lines, never overlaps, and the blame column and
   diagnostic markers follow — including near the end of a file.
5. Light and dark appearance, switched while a block is folded.
6. The two sources: a served language shows comment/import chevrons; an unserved
   one shows bracket and indentation chevrons.
7. The lifecycle: tab switch, close/reopen, relaunch, branch switch, autosave
   inside a folded block.
8. The reveal funnel end to end, and the one non-reveal scroll left in place.

Plus, for this ticket specifically: launch with a restored multi-tab session and
switch between tabs repeatedly — no crash report, and the folded-header severity
dot shows the error hidden below it.

## Notes (filled in during execution)

- Recorded pre-fix trap from Task 1: `Pisaka/BracketOverlayLayoutManager.swift:1185: Fatal error: Use of unimplemented initializer 'init()' for class 'Pisaka.FoldingTypesetter'` — `xcodebuild test -scheme Pisaka -destination 'platform=macOS'` traps on `FoldLayoutTests.testFoldingTypesetterSupportsObjCInit` (and the two layout tests) with:
  ```
  Pisaka/BracketOverlayLayoutManager.swift:1185: Fatal error: Use of unimplemented initializer 'init()' for class 'Pisaka.FoldingTypesetter'
  2026-09-06 00:54:20.845664+0400 Pisaka[28903:5663607] Pisaka/BracketOverlayLayoutManager.swift:1185: Fatal error: Use of unimplemented initializer 'init()' for class 'Pisaka.FoldingTypesetter'
  Test Case '-[PisakaAppTests.FoldLayoutTests testFoldingTypesetterSupportsObjCInit]' started.
  Failing tests: FoldLayoutTests.testFoldingTypesetterSupportsObjCInit()
  ** TEST FAILED **
  ```
  This is the test-first evidence the plan requires — the pre-fix bundle traps exactly as diagnosed, while `swift test` (5258 tests) and `swiftlint --strict` remain green, and `xcodebuild build -scheme Pisaka -destination 'generic/platform=iOS'` still succeeds without building the macOS-only target.
- Recorded pre-fix seeded-launch crash from Task 4: _(paste the crash report's
  leading frames)_
- Half two's load-bearing verdict from Task 2: with `FoldingTypesetter` replaced by a plain `NSATSTypesetter` after `setFoldedRanges`, (a) still passes — every hidden character still carries `GlyphProperty.null` — but (c) fails: fragment count is 3 not 2 (baseline 5 minus hidden separators 3 => 2 with both halves, 3 without), the visible newline after the block occupies its own line fragment as a blank row. (b) still holds — header `header {` and closer `}` share one fragment even with only half one, because null glyphs already hide the separators inside the block — but the overall collapsing is incomplete, confirming half two is load-bearing. Measured in `PisakaAppTests/FoldLayoutTests.testFoldHidesTextAndCollapsesLines` via a harness-local `typesetter = NSATSTypesetter()` neutralisation; both halves stay, docs in `app-editor-overlays.md` updated.
