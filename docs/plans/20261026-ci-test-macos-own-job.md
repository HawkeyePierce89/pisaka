# CI: the app-layer test bundle gets its own job; the macOS job only builds and launches

## Overview

Today `build-macos` runs three heavy steps on one runner, one after another: the
`PisakaAppTests` bundle (a Debug build plus 496 headless tests, 4–7.5 min), the
Release build (6–12 min) and the smoke launch. That makes it the critical path of
every CI run (20 m 34 s measured).

This plan moves the bundle into a fifth job, `test-macos`. It has no `needs:`,
uses the same toolchain, XcodeGen, Xcode-keyed SwiftPM cache (same key string, so
both jobs share one cache entry), resolve step and `Package.resolved` guard. The
test step itself does not change. `build-macos` then only builds Release and
launches the product. The two run in parallel, so the expected critical path is
about 8–14 min.

The pins in `ReleaseWorkflowTests` are re-scoped to the new shape and none is
weakened:

- The app-test pin moves to `test-macos` and gains a "not in `build-macos`"
  assertion.
- The resolve-guard pin is asked of both jobs that resolve, and their cache keys,
  xcode-version steps, resolve steps and guard steps are held equal.
- The Xcode-site set gains `ci.yml: test-macos`.

`release.yml` stays byte-identical.

## Context

- Files involved:
  - `.github/workflows/ci.yml`: the new `test-macos` job; the test step and its
    comment leave `build-macos`; the job-level comment about the absent `needs:`
    is reworded.
  - `Tests/PisakaCoreTests/ReleaseWorkflowTests.swift`:
    - `testEveryWorkflowPinsTheSameXcode` (around line 2949)
    - `testCIRefusesARewrittenPackageResolved` (around line 3031)
    - `testCIAppKitOverlayIsTestedBeforeTheBuild` (around line 3143)
    - the doc comment on `ciMacBuildBudget` (around line 928), which says "that
      file has three jobs"
  - `Tests/PisakaCoreTests/DependencyPinTests.swift`: the type doc comment
    (around line 67) that names `build-macos` as the job that resolves and runs
    the guard.
  - `CLAUDE.md`: the Commands section's CI sentence (around lines 539–545).
  - `docs/RELEASING.md`: the toolchain paragraph (around lines 456–459), which
    says "three in `ci.yml` (`test`, `build-macos`, `build-ios`)" and "holds all
    five".
- Checked, no change needed:
  - `Tests/PisakaCoreTests/Support/XcodePin.swift`. Its doc comment lists the
    *documents* that read the pin (RELEASING.md, the Makefile, CLAUDE.md) and
    names no job. The set of `setup-xcode` jobs is held by equality in
    `testEveryWorkflowPinsTheSameXcode`. Adding a job list to the doc comment
    would create a second, unpinned copy of that set, so the doc comment stays as
    it is. (The ticket expected a job list there; exploration found none.)
  - `docs/architecture/app-shell.md` (around line 1966): "`ci.yml`'s macOS job
    therefore builds `-configuration Release`". Still true.
  - `docs/architecture/core-services.md` (around line 1270): "`ci.yml`'s macOS
    job launches the … Release app". Still true.
  - `docs/architecture/core-provisioning.md` (around line 1610), `README.md`
    (around line 270), `SparkleSourceGatingTests`' doc comment,
    `docs/architecture/style-lint.md`, `Makefile`. None says the bundle runs in
    the macOS job.
  - RELEASING.md line 763 ("That bundle is `ci.yml`'s gate") stays true. Lines
    445, 484, 794, 1026, 1039, 1059 and 1167 speak of concurrency, the `test`
    job, the smoke launch and the build budget, not the bundle's job.
  - `GitHubAPITests`, `PullRequestModelTests` and `Fixtures/github/*` list check
    names as fixture data. They do not change.
  - `LintConfigurationTests` pins only the lint job. It must pass unchanged.
- Related patterns:
  - The shared `workflowJobSteps(_:in:)` reading in
    `Support/YAMLLineMatching.swift` returns one job's steps as comment-stripped,
    trimmed lines, scoped by indentation. `Self.jobSteps(_:in:)` wraps it. Every
    new or re-scoped assertion reads through it, not through raw-file line
    indices.
  - Step names are `private static let` constants (`ciAppKitTestStepName`,
    `ciMacBuildStepName`, `resolvedGuardStepName`), so a renamed step fails
    loudly.
  - `isJobHeader(_:)` plus raw lines answer which job owns a step. The
    smoke-launch pin uses this and stays unchanged.
  - `ciMacBuildBudget` walks back from the Release build step to the nearest
    `timeout-minutes:`. With `test-macos` placed *after* `build-macos`, that walk
    still lands on `build-macos`'s own `45`.
- Dependencies: none. The only tools are Foundation and XCTest; the YAML check in
  the acceptance task uses the system `ruby -ryaml`, because PyYAML is not
  installed.

## Design decisions (resolved here, not during execution)

- **Job placement.** `test-macos` sits directly after `build-macos` and before
  `build-ios`. This keeps `build-macos`'s `timeout-minutes: 45` as the nearest
  budget above the Release build step.
- **`test-macos` steps, in order:**
  1. checkout (same SHA)
  2. setup-xcode (same SHA, `xcode-version: '26.3'`)
  3. `Install XcodeGen 2.45.4` (same URL, same digest, same body)
  4. `Read the selected Xcode for the cache key` (`id: xcode`, same body)
  5. `Cache SwiftPM source packages` (same `path`, `key` and `restore-keys` lines)
  6. `Generate Xcode project`
  7. `Resolve package dependencies` (same command)
  8. `Package.resolved is unchanged by resolution` (same script)
  9. `Test the AppKit overlay (PisakaAppTests)` (same body)

  These are byte-identical to `build-macos`'s steps apart from indentation, which
  is the same anyway. The cache-key comment and the guard's comment are repeated
  in front of their copies, since each job's reader should see the reason where
  the step is.
- **Timeouts.** `test-macos` gets `timeout-minutes: 30`, with a one-line comment:
  a Debug build plus the bundle, 4–7.5 minutes measured, with the iOS job's budget
  as the ceiling. `build-macos` keeps `45` and its comment.
- **Job comments.**
  - The block above `build-macos:` is reworded to cover `build-macos`,
    `test-macos` and `build-ios`: none waits on `test`, and "these three runners'
    minutes" replaces "these two". The `release.yml` sentence stays.
  - A short block above `test-macos:` says three things. The bundle has its own
    job so that it runs in parallel with the Release build. This gives up the old
    "fail before building what would not launch" ordering for wall time. The trap
    the bundle names is caught on every run whichever job builds the product, and
    `build-macos`'s smoke launch still executes the shipped product after its
    build.
  - The existing step comment ("The app-layer test bundle that `swift test`
    structurally cannot cover…") moves verbatim with the step.
- **The renamed app-test pin.** `testCIAppKitOverlayIsTestedBeforeTheBuild`
  becomes `testCIAppKitOverlayIsTestedInItsOwnJob`.
  - It reads `Self.jobSteps("test-macos", in: "ci.yml")` and finds the step whose
    first line is `- name: \(ciAppKitTestStepName)`. A missing step fails with a
    message naming the job.
  - Every existing assertion is kept against that step's lines, with its existing
    message: `xcodebuild`, the test action, `-destination 'platform=macOS'`,
    `CODE_SIGNING_ALLOWED=NO`.
  - New: the step's index within `test-macos` is greater than that job's resolve
    step (the first step containing `-resolvePackageDependencies`).
  - The owning-job assertion (raw lines plus `isJobHeader`) now expects
    `test-macos:`.
  - New, "not in `build-macos`": no `build-macos` step is named
    `ciAppKitTestStepName`, and no `build-macos` step that contains `xcodebuild`
    has `test` or `test-without-building` as a whitespace-separated token on any
    line.
  - The old "before the Release build" assertion is removed on purpose. The doc
    comment states the trade from the ticket: the ordering is given up for wall
    time, the trap is caught by this bundle on every run whichever job builds the
    product, and the Release build's own smoke launch still runs the product after
    the build.
- **The resolve-guard pin.** The body of `testCIRefusesARewrittenPackageResolved`
  becomes a private helper, `assertResolvedGuard(inJob:)`.
  - Every existing assertion stays, with messages naming the job passed in, and
    the helper returns the job's single hashed path.
  - The test calls the helper for `build-macos` and for `test-macos`.
  - It then asserts, between the two jobs, that these are equal as line arrays:
    - the `key:` and `restore-keys:` lines of the cache step;
    - the `id: xcode` step;
    - the resolve step;
    - the guard step.
  - Both hashed paths must also be equal. The doc comment says both jobs resolve,
    why each observes the pinned Xcode, and that equal keys mean they share one
    cache entry.
- **No new pins** on `needs:` absence or on `test-macos`'s timeout, matching the
  previous CI change's decision. The acceptance task checks both by parsing the
  YAML.
- **Small doc-comment fixes in `ReleaseWorkflowTests`.**
  - `testEveryWorkflowPinsTheSameXcode`: "a sixth step" becomes "an additional
    step", so the comment stops restating a count.
  - `ciMacBuildBudget`: "that file has three jobs with three different budgets"
    becomes "that file has several jobs, each with its own budget".

## Development Approach

- **Testing approach**: workflow and pins change together inside each task,
  because a pin can only go green against the edited workflow. Each task ends with
  `swift test --filter ReleaseWorkflowTests` and then the full `swift test`.
- Complete each task fully before moving to the next. `swift test` must pass
  before the next task starts.
- No `xcodebuild` is expected. If one is ever needed, it uses
  `-derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-build`.
- Run `swiftlint --strict` (pinned 0.65.1, via `make lint`) after every Swift
  edit.
- **CRITICAL: every task MUST include new/updated tests**
- **CRITICAL: all tests must pass before starting next task**

## Implementation Steps

### Task 1: Add the `test-macos` job and move the app-test step out of `build-macos`

**Files:**
- Modify: `.github/workflows/ci.yml`
- Modify: `Tests/PisakaCoreTests/ReleaseWorkflowTests.swift`

- [x] Record the baseline: `swift test --filter ReleaseWorkflowTests` gives the
  test count, and `shasum -a 256 .github/workflows/release.yml` gives the release
  workflow's digest. Put both in Notes.
- [x] In `ci.yml`, add the `test-macos` job directly after `build-macos`, with
  exactly the steps, `timeout-minutes: 30` and comments listed under Design
  decisions.
  - Copy the shared steps from `build-macos` so the lines are identical.
  - Move the `Test the AppKit overlay (PisakaAppTests)` step and its comment block
    verbatim, then delete both from `build-macos`.
  - Leave every other `build-macos` line unchanged: the timeout and its comment,
    the Release build step and its full comment, the smoke launch.
- [x] Reword the comment block above `build-macos:` so it covers three
  independent build/test jobs, as described under Design decisions.
- [x] Update `testEveryWorkflowPinsTheSameXcode`:
  - add `"ci.yml: test-macos"` to the expected site set;
  - change the doc comment's "a sixth step" to "an additional step".
- [x] Replace `testCIAppKitOverlayIsTestedBeforeTheBuild` with
  `testCIAppKitOverlayIsTestedInItsOwnJob`, exactly as described under Design
  decisions. This includes the "not in `build-macos`" assertion and the doc
  comment stating the trade.
- [x] Fix the `ciMacBuildBudget` doc comment ("several jobs, each with its own
  budget").
- [x] Check that the new pin can fail:
  - temporarily copy the test step back into `build-macos`; the "not in
    `build-macos`" assertion must fail;
  - temporarily delete the step from `test-macos`; the test must fail with the
    job-naming message;
  - restore `ci.yml` after each check (`git diff` shows only the intended
    changes).
  - Record both failure messages in Notes.
- [x] Run `swift test --filter ReleaseWorkflowTests`; it must be green.
  `testCILaunchesWhatItBuilds`, `testCIBuildsTheConfigurationThatShips`,
  `testTheJobBudgetCoversTheNotaryWait`, `testTheTwoSmokeLaunchesAreTheSameCheck`
  and `testXcodeGenIsPinnedIdenticallyToCI` must pass with no edits.
- [x] Run the full `swift test` and `make lint`.

### Task 2: Ask the `Package.resolved` guard of both jobs that resolve

**Files:**
- Modify: `Tests/PisakaCoreTests/ReleaseWorkflowTests.swift`
- Modify: `Tests/PisakaCoreTests/DependencyPinTests.swift` (doc comment only)

- [ ] Refactor `testCIRefusesARewrittenPackageResolved` into the private helper
  `assertResolvedGuard(inJob:)`.
  - Keep every existing assertion: the guard is the step directly after resolve;
    `git diff` is present with `--exit-code`; no `continue-on-error`; no `if:`;
    no `|| true`; the failing diff fails the step; the cache key hashes exactly
    one file; the diffed path equals the hashed path; the file exists.
  - Each message names the job it was asked of.
  - The helper returns the hashed path.
- [ ] In the test, call the helper for `build-macos` and for `test-macos`. Then
  assert cross-job equality of:
  - the cache step's `key:` and `restore-keys:` lines;
  - the `id: xcode` step;
  - the resolve step;
  - the guard step;
  - the hashed path.

  Rewrite the doc comment so it scopes the pin to both jobs and says why the keys
  must be equal.
- [ ] Check that the pin can fail:
  - temporarily change `test-macos`'s cache key (for example, drop the Xcode
    segment); the cross-job assertion must fail;
  - temporarily move `test-macos`'s guard below its test step; the "directly after
    resolve" assertion must fail and name `test-macos`;
  - restore `ci.yml` after each check.
  - Record both messages in Notes.
- [ ] In `DependencyPinTests`' type doc comment, say that ci.yml's `build-macos`
  and `test-macos` jobs both resolve and then run the guard. Keep the rest of the
  paragraph.
- [ ] Run `swift test --filter ReleaseWorkflowTests` and
  `swift test --filter DependencyPinTests`; both must be green. Then run the full
  `swift test` and `make lint`.

### Task 3: Update documentation

**Files:**
- Modify: `CLAUDE.md`
- Modify: `docs/RELEASING.md`

- [ ] In CLAUDE.md's Commands section, rewrite the CI sentence as five independent
  jobs, none with a `needs:` on another, keeping the text after it unchanged ("No
  signing, secrets, or simulator. The **macOS build is `-configuration
  Release`…**", "The macOS job then **launches what it built**…"). The five jobs:
  - `swift test`;
  - the macOS job, which refuses a rewritten `Package.resolved` (keep the "remedy
    in `DependencyPinTests`' doc comment" pointer), builds Release and launches
    what it built;
  - the app-layer `PisakaAppTests` bundle (Debug, headless);
  - the unsigned iOS build (device arch, `generic/platform=iOS`, covering libgit2
    linking);
  - `lint` (pinned SwiftLint 0.65.1, `--strict`).
- [ ] Confirm by grep that CLAUDE.md's Tests section has no clause saying the
  bundle runs "in the macOS job". Exploration found none; correct one only if it
  is there.
- [ ] Run `wc -c CLAUDE.md`. It must stay under 60,000 (56,702 before). Record
  both numbers in Notes.
- [ ] In `docs/RELEASING.md`'s toolchain paragraph:
  - "three in `ci.yml` (`test`, `build-macos`, `build-ios`)" becomes "four in
    `ci.yml` (`test`, `build-macos`, `test-macos`, `build-ios`)";
  - "holds all five" becomes "holds all six".

  First grep the tests for "all five" and for that parenthesis, to confirm nothing
  pins the old wording; record the result in Notes. Leave the anchored "Pinned
  toolchain" phrase untouched.
- [ ] Re-read every other `ci.yml` mention in RELEASING.md (lines ~445, 484, 763,
  794, 1026, 1039, 1059, 1167) and correct only a sentence that says the bundle
  runs inside the macOS build job. Exploration found none; record the finding in
  Notes.
- [ ] Run `git grep -n -e "macOS job" -e "build-macos" -- ':!docs/plans'` and
  confirm that no hit says the bundle runs inside the macOS job. README.md,
  `docs/architecture/*` and `Makefile` are expected to stay unchanged.
- [ ] Run the full `swift test` (`LintConfigurationTests` must be green, with
  CLAUDE.md under the ceiling) and `make lint`.

### Task 4: Verify acceptance criteria

- [ ] Run the full `swift test`; it must pass. Record the `Executed N tests` line
  in Notes. N equals the pre-change total, because the renamed test replaces the
  old one one-for-one and the new assertions live inside existing tests.
- [ ] Run `make lint` (SwiftLint 0.65.1, `--strict`); it must be clean.
- [ ] Run `ruby -ryaml -e` over `ci.yml` and assert all of the following; record
  the output in Notes:
  - there are exactly five jobs: `test`, `build-macos`, `test-macos`,
    `build-ios`, `lint`;
  - no job has a `needs` key;
  - `test-macos` and `build-macos` have equal cache `key` and `restore-keys`,
    equal resolve `run` and equal guard `run`;
  - no `build-macos` step's `run` contains ` test` as the xcodebuild action;
  - `build-macos` `timeout-minutes` is 45 and `test-macos` is 30.
- [ ] Run `git diff --exit-code master -- .github/workflows/release.yml`; it must
  be empty. The `shasum` must equal Task 1's baseline.
- [ ] Coverage note: this change touches only a workflow file and the suites that
  pin it. Every new assertion was shown to fail on a hand-broken workflow in
  Tasks 1–2, which takes the place of a coverage percentage here.

### Task 5: Final documentation check

- [ ] README.md has no user-facing change. Confirm it still has no claim about
  which CI job runs the bundle.
- [ ] CLAUDE.md is updated (Task 3). No new file was added, so no new index entry
  is needed.

## Out-of-scope observation (recorded, not acted on)

The Release build step's comment in `ci.yml`, `app-shell.md` around line 1980 and
`SparkleSourceGatingTests`' doc comment all say that "macOS-gated code under
`#if DEBUG` is now built by no CI job". The app-test step has built the macOS
Debug configuration on every run since it was added, and after this change it
does so in `test-macos`. The ticket keeps the Release step's comment unchanged, so
this plan leaves all three as they are. Correcting them is a separate follow-up.

## Notes (filled in during execution)

- Baseline: the ReleaseWorkflowTests count; the release.yml digest.
  - Task 1 baseline: `swift test --filter ReleaseWorkflowTests` executed 69 tests,
    0 failures; `shasum -a 256 .github/workflows/release.yml` =
    `56c8e0ce09e406356fc7f777cfb7902927d7609fcad80932d541eca0625769cb`.
    After Task 1: still 69 tests, green; full `swift test` 7118 tests, 0 failures;
    `make lint` 0 violations in 784 files.
- Hand-break messages (Tasks 1–2).
  - Task 1, test step copied back into `build-macos` (after its guard): three
    failures — the owning-job check ("It is currently under “  build-macos:”"),
    "ci.yml's `build-macos` job must not carry `Test the AppKit overlay
    (PisakaAppTests)` — the bundle runs in `test-macos`, in parallel with the
    Release build, not in front of it.", and "ci.yml's `build-macos` job must not
    run xcodebuild's test action — …" listing the step.
  - Task 1, step deleted from `test-macos`: XCTUnwrap failed — "ci.yml's
    `test-macos` job has no `Test the AppKit overlay (PisakaAppTests)` step. It is
    the only gate that drives the editor's real TextKit stack headlessly — …".
    `ci.yml` restored byte-identically (`cmp`) after each check.
- CLAUDE.md character count before and after.
- RELEASING.md findings (wording pins grep; other `ci.yml` mentions).
- Final `swift test` line, `make lint` line, YAML check output.

## Post-Completion

- On the branch's first CI run, confirm:
  - all five jobs start within the same minute;
  - `test-macos` finishes on its own;
  - `build-macos` finishes without running the bundle;
  - the run's wall time equals the longest job.
- Record in this plan's Notes:
  - the five job durations;
  - the step times of `test-macos`: XcodeGen, cache, resolve, guard, test;
  - the step times of `build-macos`: XcodeGen, cache, resolve, guard, Release
    build, smoke launch.

  Compare against the 20 m 34 s baseline (`test` 4 m 54 s, `build-ios` 4 m 47 s,
  `lint` 22 s).
