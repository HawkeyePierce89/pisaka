# Code folding part 2 follow-ups: the test bundle's Info.plist, and honest smoke-launch comments (macOS)

## Overview

Four small, independent corrections left over from the part 2 acceptance review.

1. `PisakaAppTests` has no Info.plist, so the documented test command refuses to
   code-sign the bundle on a developer Mac; it passes only with the CI step's
   `CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO`. The target learns
   `GENERATE_INFOPLIST_FILE: YES` and `ReleaseMetadataTests` pins it.
2. The seeded smoke launch is described — in both workflow bodies and in
   `docs/RELEASING.md` — as the net that would have caught the part 1 crash. The
   part 2 Notes record the opposite: with the typesetter fix stashed the seeded
   launch **survived**. The comments say what the step proves, what it was
   measured not to prove, and why the seeding stays anyway. No mechanism changes.
3. Whitespace-only reindentation from part 2 in
   `docs/architecture/app-editor-overlays.md` and `docs/FEATURES.md` is restored.
4. `FoldLayoutTests.testFoldHidesTextAndCollapsesLines`'s comment claims the
   fixture's hidden range is the shape the producers make; it is not. The comment
   is corrected, the assertions stay. And the manual DEBUG pass results the review
   actually observed are recorded beside the measurement in
   `app-editor-overlays.md`.

Nothing about folding behaviour, the harness or any assertion changes.

## Context

Files involved:

- `project.yml` — the `PisakaAppTests:` target block (currently lines ~484–503):
  `type: bundle.unit-test`, `supportedDestinations: [macOS]`, `sources:`,
  `dependencies:`, and a `settings.base` holding `TEST_HOST` + `BUNDLE_LOADER`
  only. XcodeGen already emits `PRODUCT_BUNDLE_IDENTIFIER =
  ws.karmanov.pisaka.PisakaAppTests` for it, so a generated plist has an
  identifier to carry; it emits no `INFOPLIST_FILE` and no
  `GENERATE_INFOPLIST_FILE`, which is exactly the refusal.
- `Tests/PisakaCoreTests/ReleaseMetadataTests.swift` —
  `testProjectDeclaresTheAppLayerTestTarget()` (line ~422) pins the target's
  facts through `activeProjectLines()` (comment- and blank-stripped) with
  `contains(consecutively:)`. **The app target already sets
  `GENERATE_INFOPLIST_FILE: YES` (project.yml line ~297), so a bare one-line
  assertion would match the wrong target** — the new pin must be a consecutive
  triple anchored on `TEST_HOST` / `BUNDLE_LOADER`.
- `.github/workflows/ci.yml` — the `Launch the built app (smoke test)` step; the
  seeding comment block is lines ~175–180.
- `.github/workflows/release.yml` — the `Launch the archived app (smoke test)`
  step; the same block is lines ~858–863, byte-identical.
- `Tests/PisakaCoreTests/ReleaseWorkflowTests.swift` —
  `stepScript(named:in:because:)` (line ~455) **skips blank and `#`-prefixed
  lines**, so `testTheTwoSmokeLaunchesAreTheSameCheck` and
  `testSmokeLaunchSeedsSessionAndBacksUpDomain` compare comment-stripped bodies:
  rewriting comments cannot break either pin. What *does* need to learn the truth
  is the doc comment on `testSmokeLaunchSeedsSessionAndBacksUpDomain` (lines
  ~3552–3563), which currently repeats "which is exactly why the part 1 crash
  passed CI".
- `docs/RELEASING.md` — the `Launch the archived app (smoke test)` bullet, lines
  ~670–708; the untrue sentence is at ~695–697.
- `docs/architecture/app-editor-overlays.md` — the folding measurement paragraph
  (~228–260) and the gutter-skip paragraph (~660–680).
- `docs/FEATURES.md` — the folding paragraph, lines 656–665.
- `Tests/PisakaAppTests/FoldLayoutTests.swift` — the comment at lines 72–76.
- `Sources/PisakaCore/FoldRegion.swift` — the doc that settles the fixture
  question: the hidden range "starts at the end of the header line's *content*
  and ends at the end of the last line's *content*", so both producers hide the
  closer `}` too. The fixture's `NSRange(location: 8, length: 21)` stops *before*
  the `}`, deliberately, so assertion (b) can check that the header and a
  *visible* closer share one fragment.
- `docs/plans/completed/20260905-code-folding-part-2-crash-app-test-target.md` —
  the Notes (lines ~454–472) hold the two facts the rewritten comments must cite:
  the pre-fix trap on `FoldLayoutTests.testFoldingTypesetterSupportsObjCInit`
  "(and the two layout tests)" — three tests — and "the local seeded smoke binary
  with the stashed fix also survived 5s with no new DiagnosticReports report".

Measured whitespace damage (against `01732f8^`, the commit before part 2):

- `docs/FEATURES.md`: lines 656–665 (10 lines) carry 3 leading spaces where the
  list continuation is 2; line 663 additionally carries `overlapping ones.
  Gutter` — three spaces mid-sentence.
- `docs/architecture/app-editor-overlays.md`: 36 lines between 263 and 679 carry
  5 leading spaces where the continuation is 4; line 231 additionally carries
  `no folds nothing. *Half two*` — five spaces mid-sentence. (Line 241's multiple
  spaces are inside a `\n  body1` code literal and must be left alone.)

**Stated assumption about the whitespace acceptance check.** The ticket asks that
`git diff -w master..HEAD --stat` and `git diff master..HEAD --stat` agree for the
two documentation files. On this branch that is unsatisfiable by construction:
master already *is* the damaged state (commit `01732f8`), so restoring the
indentation is itself a whitespace-only change, which `-w` erases and plain `diff`
counts. The check is therefore run against the **pre-part-2 baseline** —
`git diff [-w] 01732f8^ HEAD -- docs/FEATURES.md
docs/architecture/app-editor-overlays.md --stat` — which is what the requirement's
own sentence asks for ("restore the original indentation so `git diff -w` and
`git diff` agree on those files") and what makes the cumulative part 2 +
follow-up diff free of whitespace-only lines.

Dependencies: none. No new files.

## Development Approach

- **Testing approach**: regular — change, then pin. Every change here is either a
  build setting, a comment or documentation, so the "tests" are the static
  repository suites (`ReleaseMetadataTests`, `ReleaseWorkflowTests`) that read the
  files back.
- Complete each task fully before the next; all gates green between tasks.
- Gates, in this repository's order: `swift test`, `swiftlint --strict`,
  `xcodegen generate`, the macOS build, the iOS Simulator build, and
  `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination
  'platform=macOS' test` **with no extra flags**.
- Per `CLAUDE.md`: read the matching `docs/architecture/*.md` entry before
  touching a file and update it in the same task.
- No product or brand name anywhere — code, comments, tests, docs, the plan,
  commit messages.

## Implementation Steps

### Task 1: The test bundle generates its Info.plist

**Files:**
- Modify: `project.yml`
- Modify: `Tests/PisakaCoreTests/ReleaseMetadataTests.swift`

- [x] Reproduce first: run `xcodegen generate` then `xcodebuild -project
      Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' test` with
      **no** signing flags and capture the refusal verbatim (expected: *"Cannot
      code sign because the target does not have an Info.plist file"* against
      `PisakaAppTests`). Record it in the Notes.
- [x] Add `GENERATE_INFOPLIST_FILE: YES` to the `PisakaAppTests` target's
      `settings.base`, beside `TEST_HOST` and `BUNDLE_LOADER`, with a comment
      saying why the bundle needs one: signing a bundle needs a plist to sign, and
      an application-hosted unit-test bundle gets none from the generator by
      default — so the documented, flag-free `xcodebuild … test` refuses on a
      developer Mac while CI's signing-free form passes. Extend the existing
      comment block above the target rather than starting a second one.
- [x] Extend `testProjectDeclaresTheAppLayerTestTarget()` with a
      `contains(consecutively:)` assertion over the three settings lines together
      — `TEST_HOST: …`, `BUNDLE_LOADER: $(TEST_HOST)`,
      `GENERATE_INFOPLIST_FILE: YES` — **not** a bare one-line check, because the
      application target already carries the same setting and a one-line match
      would pass against it. Give it the failure message the reason states:
      without the plist the documented command cannot sign the bundle, and only
      the CI step's `CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO` hides it.
- [x] Leave `.github/workflows/ci.yml`'s step and its flags untouched (a
      signing-free runner stays the right default there), and leave `CLAUDE.md`'s
      Commands section as it is.
- [x] `swift test` — `ReleaseMetadataTests` green.
- [x] `xcodegen generate`, then run the **plain** command again: `xcodebuild
      -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS'
      test`. It must pass with no extra flags. Record the pass — test count and
      the command as typed — in the Notes.
- [x] `swiftlint --strict`.

### Task 2: The smoke launch says what it proves

**Files:**
- Modify: `.github/workflows/ci.yml`
- Modify: `.github/workflows/release.yml`
- Modify: `docs/RELEASING.md`
- Modify: `Tests/PisakaCoreTests/ReleaseWorkflowTests.swift`

- [x] Rewrite the seeding comment block in `ci.yml`'s `Launch the built app
      (smoke test)` step (the `# Seed a restorable session …` paragraph) to state
      exactly three things: (a) what the seeded launch proves — the app restores a
      session, opens a project and lays out a real document without producing a
      crash report inside the deadline; (b) what it was measured **not** to prove
      — with the typesetter fix stashed the seeded launch survived, so the part 1
      crash (`FoldingTypesetter.init()` reached through a re-entrant layout) does
      not fire under it, and a regression of that class is caught by
      `PisakaAppTests` — three tests trapped before the fix, recorded in the part
      2 plan — not by this step; (c) that the seeding is kept because a launch
      with no document proves strictly less, not because it proves that crash.
- [x] Copy the rewritten block **verbatim** into `release.yml`'s `Launch the
      archived app (smoke test)` step. Copy, do not re-type: the two bodies must
      stay byte-identical apart from `APP=`, and a hand-merge is how they drift.
- [x] Change no mechanism: the fixture, the `defaults export`/`import` backup
      pair, the `trap restore_defaults EXIT`, the `defaults write …
      session.projects -data`, the ordering of seed before launch, `DEADLINE=5`,
      the marker, the crash-report poll and the SIGTERM→SIGKILL teardown all stay
      exactly as they are.
- [x] Rewrite the matching sentences in `docs/RELEASING.md`'s `Launch the
      archived app (smoke test)` bullet — the "With no session there is no
      document, no layout and no re-entrant pass, which is exactly why the part 1
      crash passed CI" clause — in the same three terms, keeping the surrounding
      description of the mechanism (the fixture, the domain backup, the
      `exec`-not-`open` note) intact.
- [x] Update the doc comment on
      `ReleaseWorkflowTests.testSmokeLaunchSeedsSessionAndBacksUpDomain` for the
      same reason: it currently repeats the untrue rationale. The assertions
      themselves do not move — `stepScript` strips comments, so the identity pin
      and the seeding pins are unaffected by the rewrite; note that explicitly in
      the doc comment so a future reader does not think the comments are pinned.
- [x] `swift test` — `testTheTwoSmokeLaunchesAreTheSameCheck` and
      `testSmokeLaunchSeedsSessionAndBacksUpDomain` green; if any assertion turns
      out to match a rewritten sentence, it learns the new one rather than the
      sentence being bent back.
- [x] `swiftlint --strict`.

### Task 3: Restore the reindented documentation lines

**Files:**
- Modify: `docs/architecture/app-editor-overlays.md`
- Modify: `docs/FEATURES.md`

- [x] `docs/FEATURES.md`: drop one leading space from lines 656–665 (3 spaces → 2,
      the list continuation the rest of that bullet uses) and collapse
      `overlapping ones.   Gutter` to a single space.
- [x] `docs/architecture/app-editor-overlays.md`: drop one leading space from the
      36 lines between 263 and 679 that carry 5 (→ 4, the continuation the rest of
      those bullets use) and collapse `no folds nothing.     *Half two*` at line
      231 to a single space. Leave line 241's spacing alone — it is inside a
      `"\n  body1\n  body2\n"` code literal.
- [x] Verify with the pre-part-2 baseline: `git diff -w 01732f8^ HEAD --stat --
      docs/FEATURES.md docs/architecture/app-editor-overlays.md` and the same
      command without `-w` must report the same insertion/deletion counts, i.e. no
      line in either file differs from its `01732f8^` counterpart by whitespace
      alone. Record both outputs in the Notes, together with the reason the
      ticket's literal `master..HEAD` spelling cannot be the check here (master
      *is* the damaged state, so a restoration is itself whitespace-only).
- [x] `swift test` and `swiftlint --strict` — documentation only, but the
      repository-file suites read these paths.

### Task 4: The fixture's comment, and the manual pass results that exist

**Files:**
- Modify: `Tests/PisakaAppTests/FoldLayoutTests.swift`
- Modify: `docs/architecture/app-editor-overlays.md`

- [x] Correct the comment in `testFoldHidesTextAndCollapsesLines`: the fixture's
      `NSRange(location: 8, length: 21)` is **not** the shape the producers make.
      `FoldRegion`'s hidden range ends at the end of the *last line's content*, so
      both the fallback scanner and a server-sourced region hide the closer `}` as
      well (offsets 8..30 for this text) and `footer` joins the header's row. The
      fixture deliberately stops one character short so the `}` stays visible and
      assertion (b) can check that a visible closer shares the header's fragment.
      Say that. The assertions do not change.
- [x] Record the manual DEBUG pass results beside the measurement in
      `docs/architecture/app-editor-overlays.md` — as **observed, dated
      2026-09-06, on a DEBUG build against a restored multi-tab session**: launch
      with a restored six-tab session and three tab switches with no crash report;
      Fold on a paren block collapses the header and hides the closer's line
      behind the `…` with no blank row; gutter numbering skips the hidden run (`2`
      followed by `9`); Fold All and Unfold All; a click on the `…` reopens the
      block with the caret at the block's start; a fold survives switching to
      another tab and back.
- [x] List the rest as **still unverified**, by name and in the same place: the
      placeholder at two zoom levels; caret behaviour at both boundaries by arrow
      key; light appearance; server-sourced regions; the severity dot on a folded
      header; the reveal funnel end to end; autosave inside a folded block; branch
      switch; relaunch.
- [x] Keep the new lines at the surrounding 4-space continuation indent so Task
      3's restoration is not undone.
- [x] `swift test`, `swiftlint --strict`, and `xcodebuild -project
      Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' test` (no
      flags) — the comment change is in that bundle.

### Task 5: Verify acceptance criteria

- [x] `swift test` — green.
- [x] `swiftlint --strict` from the repository root — clean.
- [x] `xcodegen generate` — clean.
- [x] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination
      'platform=macOS' build` — green.
- [x] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination
      'platform=iOS Simulator,name=iPhone 17 Pro' build` — green.
- [x] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination
      'platform=macOS' test` — green **with no extra flags**; record the command
      and the result.
- [x] Confirm the two smoke bodies are still byte-identical apart from `APP=`
      (`testTheTwoSmokeLaunchesAreTheSameCheck`), and that
      `.github/workflows/ci.yml`'s AppKit test step still carries
      `CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO` unchanged.
- [x] Re-run the whitespace check from Task 3 on the final tree and record it.
- [x] Read back the rewritten smoke-launch comments and the `docs/RELEASING.md`
      paragraph and confirm no product or brand name appears anywhere in the diff.

### Task 6: Update documentation

- [x] `CLAUDE.md`: the Commands section stays as it is — it now describes a
      command that works. Add nothing about the plist unless the Tests section's
      description of `ReleaseMetadataTests`' pinned inventory would otherwise be
      wrong; if it would, extend that one sentence and nothing else.
      *(Amended on review: the Commands section's `xcodebuild` spelling and the
      CI paragraph's description of the macOS job were stale on `master` — the
      job runs the `PisakaAppTests` bundle before the build — so both were
      corrected and `make test-app` named. The deviation from "stays as it is"
      is deliberate and recorded here rather than left as drift.)*
- [x] `README.md`: no user-facing change — confirm and leave it alone.
      *(Amended on review: the new `make test-app` target and the app-layer test
      command are user-facing, so both were documented beside `swift test`.)*
- [x] Confirm `docs/architecture/app-editor-overlays.md` and `docs/RELEASING.md`
      carry the changes from Tasks 2–4 and that no other architecture doc claims
      the smoke launch catches the part 1 crash (`grep -rn "smoke"
      docs/architecture/ CLAUDE.md README.md` currently returns nothing).

## Post-Completion

- The still-unverified half of the manual DEBUG pass listed in Task 4 remains owed
  and is deliberately not attempted here.
- Making the seeded launch actually reproduce the part 1 crash is out of scope; it
  would need a separate investigation against a pre-fix build.

## Notes (filled in during execution)

- (Task 1) The pre-change refusal, verbatim — from `xcodegen generate` followed
  by `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination
  'platform=macOS' test` with no signing flags:

  ```
  error: Cannot code sign because the target does not have an Info.plist file and one is not being generated automatically. Apply an Info.plist file to the target using the INFOPLIST_FILE build setting or generate one automatically by setting the GENERATE_INFOPLIST_FILE build setting to YES (recommended). (in target 'PisakaAppTests' from project 'Pisaka' at path '/Users/antonkarmanov/git/pisaka/Pisaka.xcodeproj')

  Testing failed:
  	Cannot code sign because the target does not have an Info.plist file and one is not being generated automatically. …
  	Testing cancelled because the build failed.

  ** TEST FAILED **
  ```
- (Task 1) The flag-free `xcodebuild … test` result after the change: the same
  command as typed above — `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka
  -destination 'platform=macOS' test`, no extra flags — reports
  `Test Suite 'PisakaAppTests.xctest' passed … Executed 14 tests, with 0 failures
  (0 unexpected)` and `** TEST SUCCEEDED **`. `swift test`: 5275 tests, 0
  failures. `swiftlint --strict`: 0 violations in 517 files. **Re-measured on
  the final tree after review**, which added
  `testProducerShapedFoldHidesTheCloserAndKeepsTheNextLineSeparate`: the same
  flag-free command reports `Executed 15 tests, with 0 failures (0 unexpected)`
  and `** TEST SUCCEEDED **`; `swift test` 5275/0; `swiftlint --strict` 0
  violations in 517 files.
- (Task 3) `git diff -w 01732f8^ HEAD --stat` vs `git diff 01732f8^ HEAD --stat`
  for the two documentation files — after the restoration the two agree exactly,
  so no line in either file differs from its `01732f8^` counterpart by whitespace
  alone:

  ```
  $ git diff 01732f8^ HEAD --stat -- docs/FEATURES.md docs/architecture/app-editor-overlays.md
   docs/FEATURES.md                         |  7 +++--
   docs/architecture/app-editor-overlays.md | 47 ++++++++++++++++++++++++--------
   2 files changed, 40 insertions(+), 14 deletions(-)

  $ git diff -w 01732f8^ HEAD --stat -- docs/FEATURES.md docs/architecture/app-editor-overlays.md
   docs/FEATURES.md                         |  7 +++--
   docs/architecture/app-editor-overlays.md | 47 ++++++++++++++++++++++++--------
   2 files changed, 40 insertions(+), 14 deletions(-)
  ```

  Before the restoration the same pair disagreed (plain: 63 insertions / 37
  deletions; `-w`: 40 / 14), the difference being exactly the 46 whitespace-only
  lines part 2 reindented. The ticket's literal `master..HEAD` spelling cannot be
  the check here: master *is* the damaged state (commit `01732f8`), so restoring
  the indentation is itself a whitespace-only change — `-w` erases it and plain
  `diff` counts it, which makes the two disagree by construction no matter how
  correct the restoration is. The pre-part-2 baseline is what the requirement's
  own sentence asks for and what makes the cumulative part 2 + follow-up diff free
  of whitespace-only lines.

  What changed: `docs/FEATURES.md` lines 656–665 (3 leading spaces → 2) plus
  `overlapping ones.   Gutter` → one space on line 663;
  `docs/architecture/app-editor-overlays.md` 36 lines (263–277, 316–319, 663–679:
  5 leading spaces → 4) plus `no folds nothing.     *Half two*` → one space on
  line 231. Line 241's `\n    body1` spacing is inside a code literal and was left
  alone. `swift test`: 5275 tests, 0 failures. `swiftlint --strict`: 0 violations
  in 517 files.
- (Task 5) Final gate results, run in this repository's order on the finished
  tree (working tree clean, `xcodegen generate` producing no change):

  - `swift test` — `Executed 5275 tests, with 0 failures (0 unexpected)`.
  - `swiftlint --strict` from the repository root — `Found 0 violations, 0
    serious in 517 files`.
  - `xcodegen generate` — `Created project at .../Pisaka.xcodeproj`, and
    `git status --porcelain` empty afterwards.
  - `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination
    'platform=macOS' build` — `** BUILD SUCCEEDED **`.
  - `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination
    'platform=iOS Simulator,name=iPhone 17 Pro' build` — `** BUILD SUCCEEDED **`.
  - The command Task 1 exists for, typed with **no extra flags** —
    `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination
    'platform=macOS' test` — `Test Suite 'PisakaAppTests.xctest' passed …
    Executed 14 tests, with 0 failures (0 unexpected)` and
    `** TEST SUCCEEDED **`. This is the refusal recorded at the top of these
    Notes, now gone. (Re-run on the final tree after review, which added a
    second layout test: `Executed 15 tests, with 0 failures (0 unexpected)`,
    `** TEST SUCCEEDED **`.)

  The two smoke bodies: `testTheTwoSmokeLaunchesAreTheSameCheck` and
  `testSmokeLaunchSeedsSessionAndBacksUpDomain` both pass. Diffing the two step
  bodies by hand reports three differing lines and no others — the step name
  (`Launch the built app` vs `Launch the archived app`), the reciprocal
  cross-reference *comment* naming the other file (`release.yml` vs `ci.yml`),
  and `APP=`. The comment line is not part of what the pin compares
  (`stepScript` strips `#` lines), so the bodies are identical apart from
  `APP=` exactly as the criterion states. `.github/workflows/ci.yml`'s AppKit
  test step still carries `CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
  test` unchanged at line 72 — a signing-free runner stays the right default
  there; the plist makes the *documented* flag-free command work on a developer
  Mac, it does not change CI.

  The whitespace check re-run on the final tree — the counts are larger than
  Task 3's recording because Task 4 added prose to `app-editor-overlays.md`,
  and the point is that the two agree:

  ```
  $ git diff 01732f8^ HEAD --stat -- docs/FEATURES.md docs/architecture/app-editor-overlays.md
   docs/FEATURES.md                         |  7 ++--
   docs/architecture/app-editor-overlays.md | 61 +++++++++++++++++++++++++-------
   2 files changed, 54 insertions(+), 14 deletions(-)

  $ git diff -w 01732f8^ HEAD --stat -- docs/FEATURES.md docs/architecture/app-editor-overlays.md
   docs/FEATURES.md                         |  7 ++--
   docs/architecture/app-editor-overlays.md | 61 +++++++++++++++++++++++++-------
   2 files changed, 54 insertions(+), 14 deletions(-)
  ```

  Brand-name read-back: the rewritten seeding comment in both workflows and the
  `docs/RELEASING.md` bullet were read in full, and the whole `master..HEAD`
  diff was scanned for editor and vendor names. No product or brand name
  appears. (The scan's only hits were the substring `zed` inside
  `standardizedFileURL` on a line that merely moved.)

- (Task 6) Documentation read-back on the finished tree. The read-back as first
  written recorded `CLAUDE.md` and `README.md` as unchanged; **the branch's
  later review-fix commits changed both**, so what shipped is recorded here
  instead. `CLAUDE.md`: the Tests section's `ReleaseMetadataTests` inventory
  reads "…, the `project.yml` wiring, …", which already covers Task 1's pin on
  the `PisakaAppTests` target's settings lines and needed no extension — but the
  Commands section's `xcodebuild` spelling and the CI paragraph's description of
  the macOS job were stale on `master` (the job runs the `PisakaAppTests` bundle
  before the build), and both were corrected, with `make test-app` named.
  `README.md` gained `make test-app` in the target list and the flag-free
  app-layer test command beside `swift test`; its Code folding bullet is
  untouched by this plan. Tasks 2–4's edits confirmed present:
  `docs/RELEASING.md` carries the rewritten three-term paragraph (lines ~695–703
  — what the seeded launch proves, what it was measured *not* to prove, why the
  seeding is kept), both workflow bodies carry the same rewritten comment block
  (`ci.yml` ~175–186, `release.yml` ~858–869),
  `docs/architecture/app-editor-overlays.md` carries the dated manual-pass
  record and the still-unverified list (lines ~253–260), and
  `Tests/PisakaAppTests/FoldLayoutTests.swift` carries the corrected fixture
  comment. The untrue clause is gone everywhere: `grep -n "which is exactly why
  the part 1 crash passed CI" docs/RELEASING.md .github/workflows/*.yml
  Tests/PisakaCoreTests/ReleaseWorkflowTests.swift` exits 1. And `grep -rn
  "smoke" docs/architecture/ CLAUDE.md README.md` returns three hits — two in
  `docs/architecture/core-folding.md` (lines 42 and 45) and one in `CLAUDE.md`
  (line 779), all three added by this branch's own review-fix commits and all
  three saying the opposite of the removed claim: that
  the crash passed CI and that the seeded launch does *not* catch it. No
  architecture doc claims the smoke launch catches the part 1 crash.
