# Make the commit diff's trailing-edge wash tests pass on the macos-26 runner

## Overview

PR #123 (https://github.com/HawkeyePierce89/pisaka/pull/123, branch
`move-ci-runners-to-macos-26`) moves every CI job to the `macos-26` image. Its first run was
40793706701, on image `macos-26-arm64` 20261013.0424.1 with Xcode 26.3. Four jobs were green
and `test-macos` was red: 508 tests, 2 failures. Both failures are in
`CommitUnifiedDiffWashTests` and both fail at the same read:

- `testShortChangedLinesAreWashedAtTheVisibleTrailingEdgeAfterScrollingAnOverflowingDiff`
- `testSwitchingFilesMeasuresTheNewDiffsWidestRow`

Each fails inside `assertWashedAtTrailingEdge` with "the removed line is not washed at the
trailing edge". Both tests pass on `macos-15` and on the development machine (macOS 27.0.1,
Xcode 26.3). The suite's other eight cases pass on macOS 26. So the failure needs a
programmatic horizontal scroll followed by a bitmap read at `x = width - 4`, on macOS 26.

macOS 26 cannot be installed on the development machine, so this work is a CI-driven loop.
Each iteration is one push to the branch, PR #123's own run, and a read of the `test-macos`
log. From the first push on, each iteration also reads a result-bundle artifact. The work has
four steps:

1. Make the failure observable. Add diagnostics that print on failure, and upload the result
   bundle on failure only.
2. Push once to collect the evidence.
3. Decide which outcome the evidence names, then fix that side:
   - A: a product defect.
   - B: the harness reads the wrong pixels.
   - C: both.
4. Prove the fix on CI. When the fix is in the harness, that includes a CI run under the
   product mutation.

The leading hypothesis is a lead, not a conclusion. On macOS 26, a programmatic
`clip.scroll(to:)` / `reflectScrolledClipView` may flash the overlay scrollers. The vertical
knob would then sit at the top of the track. That is exactly the sampled column, over the
removed and added rows. `HostedRender.settle` returns well inside the flash.

## Context

Files involved:

- `Tests/PisakaAppTests/CommitUnifiedDiffWashTests.swift`
  - The suite and its private `DiffRender`.
  - `DiffRender` owns `scrollToTrailingEdge()`, `update`, `forceLegacyScrollers` and the
    scroll-view lookup.
  - The suite also holds `assertWashedAtTrailingEdge`.
- `Tests/PisakaAppTests/HostedRender.swift`
  - The shared borderless-window harness.
  - It captures through `bitmapImageRepForCachingDisplay` + `cacheDisplay`.
  - `settle()` is a loop that waits for two stable layout turns.
- `Sources/Pisaka/CommitUnifiedDiffView.swift`, the product.
  - Its width rule is at line 152: `.frame(minWidth: max(visibleSize.width, widestRow),
    minHeight: visibleSize.height, alignment: .topLeading)`.
  - The visible size comes from `VisibleSizeProbe`.
  - The widest row comes from `onGeometryChange`.
- `.github/workflows/ci.yml`: the `test-macos` job, step "Test the AppKit overlay
  (PisakaAppTests)".
- `Tests/PisakaCoreTests/ReleaseWorkflowTests.swift`, the static suite that pins ci.yml. Two
  rules need changing:
  - `testEveryActionIsPinnedToOneFullCommitInBothWorkflows` holds the action set to exactly
    `{actions/checkout, actions/cache, maxim-lobanov/setup-xcode}`.
  - `testTheCISmokeLaunchIsNotSkippable` refuses any `if:` line anywhere in ci.yml.
  - Also relevant: `testCIAppKitOverlayIsTestedInItsOwnJob`,
    `testNoActiveWorkflowLineNamesABareBuildOutputRoot`, and the `jobSteps` /
    `activeYAMLLines` helpers.
- `docs/architecture/app-git-views.md`: the `CommitUnifiedDiffView.swift` entry. The
  paragraph describing `CommitUnifiedDiffWashTests` is around lines 710–760.
- `docs/RELEASING.md`: the "Pinned runner: `macos-26`" paragraph (around line 480). It holds
  the hand-kept list of OS-dependent behaviours.
- `CLAUDE.md`: the CI paragraph that starts "CI (`.github/workflows/ci.yml`) runs these same
  gates". The file is at 57,051 characters, against a cap of 60,000.
- Stale comments to fix:
  - `Tests/PisakaAppTests/CodeScrollViewHomeTests.swift`, lines 13 and 63
  - `Tests/PisakaAppTests/CommitUnifiedDiffWashTests.swift`, line 61
  - `Tests/PisakaAppTests/LocalChangesLayoutTests.swift`, line 51

Related patterns:

- Static suites match against comment-stripped `activeYAMLLines` and prefer set equality.
- Every action is pinned as `uses: owner/repo@<40 hex> # vX.Y.Z`.
- Build outputs go under `.noindex` roots.
- Async and render tests settle causally and never use timed waits.
- A suite's doc comment is its inventory.

Dependencies:

- One new action, `actions/upload-artifact`, pinned as
  `actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9 # v7.0.2`. This is the
  latest release, published 2026-10-07, and the tag resolves to that commit.
- The `gh` CLI, authenticated for the repository, to read runs, logs and artifacts.

## Development Approach

- **Testing approach**: Regular. Diagnostics and the CI change come first, then the
  evidence, then the fix the evidence names.
- Complete each task fully before moving to the next.
- **CRITICAL: every task MUST include new/updated tests where it changes code.**
- **CRITICAL: all local gates must pass before starting the next task and before every
  push.**

### Push budget

- Outcome A takes two pushes: the diagnostic push, then the fix push (the final tree).
- Outcome B or C takes four pushes:
  1. the diagnostic push;
  2. the fix push (the final tree);
  3. the product-mutation push;
  4. the revert push (the final tree again).
- Never push while the previous PR run is still in progress. The ci.yml concurrency group
  cancels an in-progress PR run when a newer push arrives, and that run's evidence would be
  lost.

### Local gates before every push

All of these must be green under the pinned Xcode:

- `swift test`
- `xcodegen generate`, then the `make test-app` equivalent run raw so it uses the one
  permanent derived-data folder. It must report 508 tests or more and 0 failures:

  ```sh
  DEVELOPER_DIR=/Applications/Xcode_26.3.app/Contents/Developer xcodebuild \
    -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' \
    -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-build test
  ```

- `swiftlint lint --strict` under 0.65.1.

Name the Xcode beside every gate result you record.

### Reading a run

1. Find the run whose `headSha` equals `git rev-parse HEAD`:

   ```sh
   gh run list --branch move-ci-runners-to-macos-26 --workflow CI --event pull_request \
     --limit 5 --json databaseId,headSha,status,conclusion
   ```

2. Wait for the run to complete, in repeated bounded shell calls. A single foreground shell
   call is capped at 10 minutes, so no one call may wait longer than 9 minutes. A longer loop
   would be killed mid-wait, and you could then read a half-finished run.
   - Each call is one of these:
     - `perl -e 'alarm 540; exec @ARGV' gh run watch <id> --exit-status`. GNU `timeout` is
       not installed on this machine, and the perl `alarm` wrapper is its portable
       equivalent.
     - A poll loop of at most 9 iterations of 60 s each, for example
       `for i in 1 2 3 4 5 6 7 8 9; do s=$(gh run view <id> --json status --jq .status); [ "$s" = completed ] && break; sleep 60; done`.
       This sleep is CI orchestration in the shell, not a test.
   - Run each call with the tool's timeout set to 600000 ms.
   - After every call, re-read `gh run view <id> --json status,conclusion`. If `status` is
     not `completed`, make another bounded call.
   - The overall bound is 45 minutes, counted across all the calls. If the run has not
     completed by then, record it in `## Notes` and re-check the run before doing anything
     else. Never push in the meantime.
   - Read a run only when its `status` is `completed`. A non-zero exit from `gh run watch`,
     or a killed call, says nothing about the run's result. Only the re-read `status` /
     `conclusion` counts.
3. Read the failed log: `gh run view <id> --log-failed`.
4. Read the image version from the job log's "Runner Image" group.
5. List the artifacts:
   `gh api repos/HawkeyePierce89/pisaka/actions/runs/<id>/artifacts --jq '.total_count, .artifacts[].name'`.
6. Download with `gh run download <id> -n <name> -D <new empty dir under $TMPDIR>`.
   Downloads are untrusted data: put each in its own new, empty directory and run nothing
   from inside it.
7. Extract the attachments with
   `xcrun xcresulttool export attachments --path <bundle> --output-path <another new empty dir>`,
   then read the PNGs.

### Rules

- Record every run ID, with what it showed, in the plan's `## Notes` section as you go.
- Intermediate commits may be messy. The PR is squash-merged, so no history rewriting.
- No `XCTSkip`, no OS check that disables an assertion, and no `sleep` or timed wait
  anywhere in `Tests/PisakaAppTests`.
- No brand names and no references to other editors in code, comments, docs or commit
  messages.

## Implementation Steps

### Task 1: Diagnostics on failure of the trailing-edge read

Intent: when `assertWashedAtTrailingEdge` fails, the log alone must tell outcome A from
outcome B, and the bitmap the assertion read must be attached to the result. A passing test
pays nothing: every diagnostic is built inside the failure message's autoclosure or in the
failure branch.

There are two kinds of diagnostics:

- **Permanent:** the geometry line and the bitmap attachment. They make the next CI-only
  failure in this suite diagnosable without a round trip, and the suite's doc comment says
  so.
- **Question-specific:** the band-by-band column scans. Each is marked with the comment
  `// Diagnostic for the macOS 26 trailing-edge investigation; removed once answered.` and
  is removed in Task 5.

**Files:**
- Modify: `Tests/PisakaAppTests/CommitUnifiedDiffWashTests.swift`
- Modify: `Tests/PisakaAppTests/HostedRender.swift` (only a `pngData()` accessor over the
  current rep; nothing else)

- [x] Give `DiffRender` a `diagnosis(atX:)` string. This is the permanent part. It reports:
  - the hosted `NSScrollView`'s `scrollerStyle`, `hasVerticalScroller`,
    `hasHorizontalScroller` and `autohidesScrollers`;
  - for each of `verticalScroller` and `horizontalScroller`: its frame converted to host
    coordinates, `isHidden`, `alphaValue`, `layer?.opacity`, `knobProportion` and
    `doubleValue`;
  - every `NSScroller` found among the scroll view's subviews;
  - the clip view's `bounds` twice: right after the scroll (captured in
    `scrollToTrailingEdge()` beside `scrolledBy`) and now, after settle;
  - the document view's `frame` and `isFlipped`;
  - `render.pixelScale`.
- [x] Add the question-specific part: a band scan of two columns.
  - The columns are the sampled column `x = width - 4`, and `x = width - 40`, which no
    overlay or legacy scroller can reach.
  - Walk each column one pixel row at a time. Merge consecutive pixels with the same
    classification into bands.
  - Classify each band as `diffRemovedBackground`, `diffAddedBackground`, `ground` or
    `other`.
  - Print each band as `y0–y1: <class>`. An `other` band also prints its representative sRGB
    triple.
  - Read every pixel colour from the one captured bitmap, never from a fresh window per
    pixel.
- [x] Make `assertWashedAtTrailingEdge` append the diagnosis to both of its `XCTUnwrap`
  messages, inside the autoclosure. On either failure, before unwrapping, add an
  `XCTAttachment` of the `render` PNG data named `trailing-edge-<test name>.png`, with
  lifetime `.keepAlways`.
- [x] Add a test proving the diagnosis is real and not vacuous. On an unscrolled `short`
  render, the diagnosis must:
  - name both washes in the `width - 40` column scan;
  - either report a non-nil vertical scroller frame or state "no vertical scroller".

  This stops a diagnostic that silently prints nothing from passing.
- [x] Run the local gates (`swift test`, the raw `make test-app` equivalent,
  `swiftlint lint --strict`). All must be green.

### Task 2: test-macos keeps its result bundle on failure only

Intent: this is the permanent half of the diagnostics. A failed `test-macos` run leaves a
downloadable `.xcresult`, and a green run leaves nothing. The static suite is changed to
admit exactly this, not loosened.

**Files:**
- Modify: `.github/workflows/ci.yml`
- Modify: `Tests/PisakaCoreTests/ReleaseWorkflowTests.swift`
- Modify: `docs/RELEASING.md`, `CLAUDE.md` (one clause each)

- [ ] Change the folded command of the "Test the AppKit overlay (PisakaAppTests)" step to
  pass `-resultBundlePath build.noindex/PisakaAppTests.xcresult`. `build.noindex/` is already
  git-ignored, excluded from lint, and accepted by the bare-root rule.
- [ ] Add a step after it in `test-macos`:
  - name: `Upload the test result bundle (failure only)`
  - `if: failure()`
  - `uses: actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9 # v7.0.2`
  - `with:`
    - `name: PisakaAppTests-xcresult`
    - `path: build.noindex/PisakaAppTests.xcresult`
    - `retention-days: 7`
    - `if-no-files-found: ignore`. A failure before the test step leaves no bundle, and that
      must not mask the real error.
  - A comment saying why the step exists: the class "fails only on the runner's OS" has now
    hit twice, and the log carries only the assertion text. The comment also says why it runs
    on failure only: cost, and the gates stay quiet when green.
- [ ] In `testEveryActionIsPinnedToOneFullCommitInBothWorkflows`, add
  `actions/upload-artifact` to the set, keeping set equality. Extend the doc comment to say
  why it is the fourth action.
- [ ] Rework `testTheCISmokeLaunchIsNotSkippable` from "no `if:` at all" to: the set of
  `(job, step name, condition)` triples in ci.yml equals exactly
  `{("test-macos", "Upload the test result bundle (failure only)", "if: failure()")}`.
  - `continue-on-error:` stays forbidden.
  - Update the doc comment: the one admitted condition widens nothing, because it only adds a
    step after a failure, and every gate step stays unconditional.
- [ ] Add a new test pinning the bundle's shape in `test-macos`:
  - the test step's `-resultBundlePath` value equals the upload step's `path:`;
  - the path sits under `build.noindex/`;
  - the upload step comes after the test step;
  - the upload step carries `if: failure()` and a `retention-days:` of at most 14;
  - no other job in ci.yml or release.yml uses `actions/upload-artifact`.

  Read over comment-stripped `activeYAMLLines`, using the suite's `jobSteps` helper.
- [ ] Mutation-check each new or changed rule locally, and revert each mutation afterwards.
  Each of these must turn the suite red:
  - dropping `if: failure()`;
  - changing the condition to `always()`;
  - mismatching the path;
  - adding a second `if:` elsewhere.
- [ ] In `docs/RELEASING.md`'s pinned-runner paragraph, add one sentence on reading a
  CI-only failure: the failed `test-macos` run's `PisakaAppTests-xcresult` artifact,
  `gh run download`, and `xcresulttool export attachments`.
- [ ] In `CLAUDE.md`'s CI paragraph, add one clause saying the app-layer job uploads its
  result bundle on failure only. Confirm `LintConfigurationTests` still holds `CLAUDE.md`
  under 60,000 characters.
- [ ] Run the local gates (`swift test`, the raw `make test-app` equivalent,
  `swiftlint lint --strict`). All must be green.

### Task 3: Diagnostic push and the evidence (CI push 1)

Intent: one run that both answers the question and verifies the failure half of the artifact
rule. This task carries no fix.

- [ ] Commit Tasks 1–2 and push to `move-ci-runners-to-macos-26`. Use a message such as
  `ci: keep the app-layer result bundle on failure; diagnose the trailing-edge read`.
- [ ] Find the run for this head SHA. Wait for it in bounded calls of at most 9 minutes each
  until its `status` is `completed`, as described in "Reading a run".
  - Expected: `test-macos` red on the same two tests, and the other four jobs green.
  - Any other red job is a defect in Tasks 1–2. Fix it locally, then push again before going
    on.
- [ ] Quote the two failure messages from `gh run view <id> --log-failed` verbatim into
  `## Notes`, with their diagnosis lines. Record the run ID and the image version.
- [ ] Verify that an artifact named `PisakaAppTests-xcresult` exists on the run. Download it
  into a new, empty directory and export its attachments. View both PNGs, and describe in
  `## Notes` what is drawn at the trailing edge over the removed and added rows.
- [ ] Decide the outcome with the table below, and write the conclusion and its reason in
  `## Notes`.
  - **B (the harness reads the wrong pixels)** when all of these hold:
    - a vertical `NSScroller` is drawn (not hidden, `alphaValue` and layer opacity above 0)
      with a frame covering `x = width - 4`;
    - the `width - 4` scan shows `other` where the removed and added rows are;
    - the `width - 40` scan shows `diffRemovedBackground` then `diffAddedBackground`;
    - the clip bounds after settle still show the far-right scroll.

    It is also B if something other than a scroller is shown to be drawn over the column
    while the inner column is washed.
  - **A (product defect)** when nothing is drawn over the column and either:
    - the `width - 40` column also lacks the washes; or
    - the after-settle clip bounds and document frame show the visible region reaching past
      the rows' painted width.
  - **C** when the evidence for both A and B holds.
  - **Neither recognisable** when the evidence fits none of the above. Add diagnostics
    narrowed to what this run showed, push again, and repeat this task. Record every extra
    run.

### Task 4: Fix the side the evidence names

Intent: make the read deterministic (B) or the product correct (A) on every OS the gates run
on. The contract does not change: after a scroll, a washed row reaches the visible trailing
edge.

Not acceptable in any outcome:

- skipping on macOS 26;
- loosening the assertion so it passes without the wash;
- moving the sample column inward (it stays at `width - 4`);
- a timed wait, or waiting for a flash to fade.

**Files:**
- Outcome B: Modify `Tests/PisakaAppTests/CommitUnifiedDiffWashTests.swift` (only
  `DiffRender`; `HostedRender` untouched beyond Task 1's accessor)
- Outcome A: Modify `Sources/Pisaka/CommitUnifiedDiffView.swift`

- [ ] Outcome B or C: take the scrollers out of the capture.
  - Route every bitmap `DiffRender` reads through one `DiffRender` capture method. The method
    sets `isHidden = true` on every `NSScroller` subview of the hosted scroll view, calls
    `render.capture()`, then restores each scroller's previous `isHidden`.
  - `init` re-captures through this method once `HostedRender` exists. `update`,
    `scrollToTrailingEdge()` and `forceLegacyScrollers()` all use it.
  - Hiding a view triggers no retile, so widths and the legacy case are unaffected.
  - The doc comment says the scrollers are chrome drawn over the content, not the content's
    wash.
  - If the evidence named something other than a scroller, take that view out of the capture
    the same way and name it in the doc comment.
- [ ] Outcome B or C: run a local regression probe. In the overflowing case, call
  `flashScrollers()` on the hosted scroll view before the capture.
  - If a capture without the hiding then fails the read on this machine, keep a permanent
    test that flashes and asserts the read still holds. Flashing is an explicit action, not
    timing.
  - If the flash does not reach `cacheDisplay` locally, record that in `## Notes` and add no
    test for it. CI is then the only witness.
- [ ] Outcome A or C: fix the product.
  - Fix `CommitUnifiedDiffView` so the content's fill reaches the clip view's visible
    trailing edge after a scroll on macOS 26. Use the measured value the evidence shows is
    wrong, for example the visible width or the insets the probe reports after scrolling.
  - Keep the rule in Core-free view code, under its `app-git-views.md` contract.
  - Leave the two failing tests unchanged.
  - The unscrolled, legacy-scroller, live-update and vertical-alignment cases must stay green
    locally.
- [ ] Run the product mutation locally under Xcode 26.3, in both variants, reverting each
  afterwards. Record both results in `## Notes`.
  - Line 152 `minWidth: max(visibleSize.width, widestRow)` → `minWidth: visibleSize.width`:
    the overflowing case must fail, because it does not scroll.
  - The `minWidth:` argument removed entirely: the read must fail in both the pane-width case
    and the overflowing case.

  Run with `-only-testing:PisakaAppTests/CommitUnifiedDiffWashTests`, using the same
  `DEVELOPER_DIR` and `-derivedDataPath`.
- [ ] Run the local gates (`swift test`, the raw `make test-app` equivalent,
  `swiftlint lint --strict`). All must be green.

### Task 5: Docs, stale comments and diagnostic clean-up

Intent: produce the branch's final tree, so that in outcome A the next push can be the last.

**Files:**
- Modify: `Tests/PisakaAppTests/CommitUnifiedDiffWashTests.swift`,
  `Tests/PisakaAppTests/CodeScrollViewHomeTests.swift`,
  `Tests/PisakaAppTests/LocalChangesLayoutTests.swift`
- Modify: `docs/architecture/app-git-views.md`
- Modify: `docs/RELEASING.md` (only if the rule below applies)

- [ ] Remove the question-specific band scans and their marker comments. Keep the geometry
  line and the bitmap attachment. Keep Task 1's non-vacuity test, trimmed to what stays.
- [ ] Update the suite's "How it is measured" doc comment:
  - what macOS 26 does;
  - how the read accounts for it;
  - that the geometry line and the attachment stay, so a CI-only failure needs no round
    trip.

  Keep the mutation statement true.
- [ ] Rewrite the stale comments as statements about the OS that was measured, in the past
  tense, with no claim about where CI runs today:
  - `CommitUnifiedDiffWashTests.swift` line 61: "leaving CI's macOS 15 at the same 141"
    becomes a statement like "and left macOS 15 at the same 141".
  - `CodeScrollViewHomeTests.swift` line 13: "the older CI runner" becomes "on macOS 15,
    where it was measured".
  - `CodeScrollViewHomeTests.swift` line 63: "frame tiling on the CI runner" becomes "frame
    tiling (measured on macOS 15)".
  - `LocalChangesLayoutTests.swift` line 51: "on the macOS 15 CI runner" becomes "measured
    on macOS 15".
- [ ] Update the `CommitUnifiedDiffView.swift` entry in `app-git-views.md`, in the
  `CommitUnifiedDiffWashTests` paragraph: what macOS 26 does, and how the read (B) or the
  view (A) accounts for it.
- [ ] Update `RELEASING.md`'s runner paragraph according to the outcome:
  - Outcome A: add the new macOS 26 behaviour to its hand-kept list of OS-dependent
    behaviours.
  - Outcome B: add it only if the harness fix depends on behaviour that differs below
    macOS 26. Say in `## Notes` which case applied.
- [ ] Check that `grep -rn "CI runner\|CI's macOS 15\|where CI runs" Tests Sources docs/architecture`
  prints nothing.
- [ ] Run the local gates (`swift test`, the raw `make test-app` equivalent,
  `swiftlint lint --strict`). All must be green.

### Task 6: Fix push (CI push 2)

- [ ] Commit Tasks 4–5 and push. Wait for the run in bounded calls of at most 9 minutes each
  until its `status` is `completed`, as described in "Reading a run".
- [ ] Expected: all five jobs green on `macos-26`, and an artifact count of 0 for the run.
  Record the run ID, the image version and the artifact count in `## Notes`.
- [ ] If `test-macos` is red, the retained geometry line and attachment are the evidence.
  Take this run back through Task 3's decision table, fix, run the local gates, and push
  again. Record every run.

### Task 7: CI run under the product mutation (outcomes B and C; CI pushes 3 and 4)

Intent: show that the fixed read still turns red on macOS 26 when the product's wash is
absent.

- [ ] Outcome A only: this task does not apply. The fix is in the product and the tests are
  unchanged, so Task 4's local mutation is the stated evidence. Write that in `## Notes` and
  tick the remaining items.
- [ ] Outcome B or C: commit the "`minWidth:` removed" mutation on its own, with the message
  `test: product mutation for the CI read, reverted next`. Push, and wait in bounded calls
  until the run's `status` is `completed`.
  - Expected: `test-macos` red, with the trailing-edge read failing ("the removed line is not
    washed at the trailing edge") in the pane-width and overflowing cases, and an artifact
    present.
  - Quote the failures and record the run ID in `## Notes`.
- [ ] Outcome B or C: `git revert` the mutation commit, run the local gates, push, and wait
  in bounded calls until the run's `status` is `completed`.
  - Expected: all five jobs green and an artifact count of 0. Its tree equals Task 6's.
  - Record the run ID and the image version as the final run.

### Task 8: Verify acceptance criteria

- [ ] PR #123's run on the final commit is green on all five jobs, on the `macos-26` image.
  Its run ID and image version are in `## Notes`.
- [ ] `## Notes` contains:
  - the quoted failing diagnostic log and the outcome conclusion with its reason;
  - both local mutation results;
  - for B or C, the CI mutation run.
- [ ] The failed diagnostic run has a downloadable `PisakaAppTests-xcresult` artifact, and
  the final green run has none. Check both through the artifacts API and record the results.
- [ ] The local gates pass on the final tree, under Xcode 26.3 on macOS 27:
  - the raw `make test-app` equivalent: 508 tests or more, 0 failures;
  - `swift test` green;
  - `swiftlint lint --strict` clean under 0.65.1.
- [ ] `git diff master -- Tests/PisakaAppTests | grep -n "XCTSkip\|sleep\|asyncAfter\|operatingSystemVersion\|#available"`
  shows no added line that disables an assertion or waits on time.
- [ ] `grep -rn "CI runner\|CI's macOS 15\|where CI runs" Tests Sources docs/architecture`
  prints nothing.

### Task 9: Update documentation

- [ ] README.md needs nothing, because there is no user-facing change. Confirm this and note
  it.
- [ ] Confirm that the `CLAUDE.md` CI clause from Task 2 matches the final ci.yml, and that
  `LintConfigurationTests` passes.

## Notes

(Appended during execution: every run ID with its head SHA, image version, job verdicts,
artifact count and what it showed; the quoted diagnostic log; the outcome decision and why;
the local and CI mutation results.)

### Task 1 (local, macOS 27, Xcode 26.3)

- Gates under Xcode 26.3: `swift test` 7224 tests, 0 failures; the raw `make test-app`
  equivalent 509 tests, 0 failures (508 plus the new non-vacuity test); `swiftlint lint
  --strict` (0.65.1) clean.
- Failure path checked locally once, with the product's `minWidth:` removed temporarily
  (restored before the gates above):
  `testShortChangedLinesAreWashedToThePanesTrailingEdge` failed at the trailing-edge read.
  Its message carried the diagnosis: a legacy-style scroll view, both scrollers hidden, clip
  bounds after settle `(-237.0, 0.0, 600.0, 300.0)`, document frame
  `(0.0, 0.0, 125.0, 300.0)`, and both column scans `0.0–300.0: ground`. The result bundle
  held the attachment `trailing-edge-testShortChangedLinesAreWashedToThePanesTrailingEdge`
  (XCTest appends `_0_<UUID>.png` to the name).

## Post-Completion

- Acceptance review of the branch, then merge PR #123 (squash). Out of scope here.
