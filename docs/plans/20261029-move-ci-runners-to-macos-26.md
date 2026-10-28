# Move the GitHub Actions runners to macos-26 and pin the runner label like the Xcode version

## Overview

All seven jobs in `.github/workflows/ci.yml` (`test`, `build-macos`, `test-macos`,
`build-ios`, `lint`) and `.github/workflows/release.yml` (`test`, `release`) move from
`runs-on: macos-15` to `runs-on: macos-26`. The Xcode pin stays `26.3`. The runner label
gets the same treatment `XcodePin` gives the Xcode version: one value in every job, read by
a test, so a partial move (six jobs on `macos-26`, one left on `macos-15`) or a moving alias
(`macos-latest`) fails `swift test`. `docs/RELEASING.md` describes the new runner and gets a
new entry for the release workflow's first run on the new image, which nothing can check
before that run. One architecture doc sentence becomes false after the move and gets
corrected.

Why: CI on macOS 15 and the development machine on macOS 27 are two major versions apart.
SwiftUI ships with the OS, so layouts differ between them, and that gap is what caused the
last PR's `test-macos` failure. `macos-26` is the newest generally available image. It ships
Xcode 26.3 (17C529) at `/Applications/Xcode_26.3.app` and is arm64 like `macos-15`.

## Context

- Files involved:
  - `.github/workflows/ci.yml` — five `runs-on:` lines (jobs `test`, `build-macos`,
    `test-macos`, `build-ios`, `lint`)
  - `.github/workflows/release.yml` — two `runs-on:` lines (jobs `test`, `release`; the
    `release` job's line comes after `needs: test`)
  - `Tests/PisakaCoreTests/Support/XcodePin.swift` — the model to copy: the workflows are
    the authority, `steps()` / `versionLineCount()` / `pinnedVersion()` with a
    `Disagreement` error that names every site, and a doc comment that lists every reader
  - `Tests/PisakaCoreTests/Support/YAMLLineMatching.swift` — the shared workflow reading:
    `workflowJobs(in:)`, `workflowJobSteps(_:in:)`, `activeYAMLLines(of:)`, and the private
    `indentedActiveYAMLLines` / `yamlIndent`
  - `Tests/PisakaCoreTests/Support/RunnerPin.swift` — new, sits next to `XcodePin`
  - `Tests/PisakaCoreTests/ReleaseWorkflowTests.swift` — `testEveryWorkflowPinsTheSameXcode`
    and `testReleasingDocNamesTheWorkflowPin` (around line 2990 onward);
    `testTheReleaseJobIsGatedOnTheTestJob` holds today's `test:` / `runs-on: macos-15`
    assertion (around line 280)
  - `Tests/PisakaCoreTests/LintConfigurationTests.swift` —
    `testCIDeclaresALintJobIndependentOfTheBuildGraph` holds today's `runs-on: macos-15`
    assertion (line 387)
  - `docs/RELEASING.md` — the "Pinned toolchain: Xcode `26.3`" paragraph (around line 456)
    and "### Manual verification owed for this feature" (around line 1286)
  - `docs/architecture/app-git-views.md` line 749 — "did nothing on macOS 15, where CI
    runs", which is false after the move
  - `CLAUDE.md` — its list of shared test helpers ("`XcodePin` and `RepositorySources`")
    gets the new helper's name
- Related patterns: `XcodePin` (the authority is the workflows, every other spelling is a
  reader; set equality; a `Disagreement` that names every site); comment-stripped matching
  through the `YAMLLineMatching` functions; `testReleasingDocNamesTheWorkflowPin`'s
  anchored-phrase rule (exactly one occurrence, equal to the pin).
- Dependencies: none added.
- Deliberately left alone:
  - The SwiftPM cache key (`spm-<Xcode version>-<hash of Package.resolved>`) in the three
    XcodeGen jobs. The cached `SourcePackages` holds source checkouts and the downloaded
    binary-artifact archives. Neither depends on the OS, and both images report
    `Xcode-26.3`, so the first `macos-26` run may restore a cache written on `macos-15`, and
    that is correct. Resolution runs under the same Xcode build either way, so the committed
    `Package.resolved` guard sees the same input. The plan found no reason to change the key.
  - Two app-test doc comments that mention CI on macOS 15:
    `Tests/PisakaAppTests/CommitUnifiedDiffWashTests.swift:61` and
    `LocalChangesLayoutTests.swift:51`. Both record what was measured on that runner at the
    time and remain accurate as history. The ticket also keeps every Swift file outside
    `Tests/PisakaCoreTests` unchanged.
  - The completed plans under `docs/plans/completed/`.

## Development Approach

- **Testing approach**: TDD. Write the rule first, watch it fail against today's `macos-15`
  labels with a message naming all seven sites, then move the labels.
- Complete each task fully before starting the next.
- In the workflows, change only the seven `runs-on:` values. Leave the six
  `xcode-version: '26.3'` lines, the job graph, the timeouts, the caches and every action
  SHA untouched.
- Never use `macos-latest`, or any `-intel` / `-large` / x64 label, anywhere.
- Test conventions from `CLAUDE.md`:
  - match against comment-stripped lines
  - prefer set equality to counting
  - each suite's doc comment is its inventory, and `RunnerPin`'s doc comment lists every
    reader the same way `XcodePin`'s does
- No brand names or references to other editors in code, comments, docs or commit messages.
- One branch off `master`. Commits in the imperative.
- **CRITICAL: every task MUST include new/updated tests**
- **CRITICAL: all tests must pass before starting next task**

## Implementation Steps

### Task 1: One runner-label rule across both workflows, and the move to macos-26

**Files:**
- Create: `Tests/PisakaCoreTests/Support/RunnerPin.swift`
- Modify: `Tests/PisakaCoreTests/ReleaseWorkflowTests.swift`
- Modify: `Tests/PisakaCoreTests/LintConfigurationTests.swift`
- Modify: `.github/workflows/ci.yml`
- Modify: `.github/workflows/release.yml`

The intent: the workflows' `runs-on:` values work exactly like their `xcode-version:`
values. Every job states one label, all jobs state the same label, and that label is an
explicit versioned macOS image.

- [ ] Add `RunnerPin` in the support directory, built like `XcodePin`:
  - **Inventory.** `jobs()` returns every job across `ci.yml` and `release.yml`, taken from
    the shared `workflowJobs(in:)` reading. For each job it records the workflow, the job
    id, and every `runs-on:` value written directly under the job header (indentation
    exactly one level below the job). The values are kept as a list, so a job with no
    `runs-on:` or with two is reported instead of collapsed.
  - **Value reading.** Each value has any trailing ` #` comment and surrounding quotes
    removed, matching `XcodePin.versionValue(of:)`.
  - **Stray-line count.** `runsOnLineCount()` counts every active `runs-on:` line in both
    workflows, so a line outside any job's header level shows up.
  - **The pinned label.** `static let label = "macos-26"` is the pinned value, and changing
    it is the deliberate act. `pinnedLabel()` returns that label only when all of these
    hold:
    - every job carries exactly one value
    - the set of values has exactly one member
    - that member matches `^macos-[0-9]+$`, which refuses `macos-latest`, `-intel` /
      `-large` variants, matrix expressions and list syntax
    - that member equals `label`

    Otherwise it throws a `Disagreement` that names every job and its value. Its message
    says the label must be an explicit versioned image so GitHub cannot change the OS under
    the pin without a commit.
  - **Doc comment.** States that the workflows are the authority, explains why a versioned
    label is required (a moving alias moves without a commit), and lists every reader
    checked against the value. The readers are the two rewired assertions below and the
    `RELEASING.md` phrase added in Task 3.
- [ ] In `ReleaseWorkflowTests`, add `testEveryWorkflowJobRunsOnThePinnedRunner` next to
  `testEveryWorkflowPinsTheSameXcode`. It asserts:
  - the set of `"<workflow>: <job>"` sites equals the seven named jobs (set equality), with
    a message saying a new job must be named here before it can run
  - each job carries exactly one `runs-on:`
  - `runsOnLineCount()` equals the number of jobs
  - `pinnedLabel()` succeeds, which is the one-value, versioned-label and equals-`macos-26`
    checks together

  Update the suite's doc comment inventory to cover the new rule.
- [ ] Rewire the two existing label assertions so they read through the rule and no longer
  carry a literal of their own:
  - `testTheReleaseJobIsGatedOnTheTestJob`: the consecutive `test:` / `runs-on: …` check
    uses `RunnerPin.pinnedLabel()`.
  - `testCIDeclaresALintJobIndependentOfTheBuildGraph`: the lint job's `runs-on:` lines
    must equal exactly `["runs-on: <pinnedLabel>"]`.

  Update `LintConfigurationTests`' doc comment inventory where it describes the lint job's
  runner assertion.
- [ ] Run `swift test` before changing the workflows and confirm the new rule fails with a
  message naming all seven `macos-15` sites.
- [ ] Change the seven `runs-on: macos-15` lines to `runs-on: macos-26`. Touch no other
  workflow line.
- [ ] Run `swift test`; it must pass.

### Task 2: Prove the rule refuses a half-move and a moving alias

**Files:**
- Modify (temporarily, then reverted): `.github/workflows/ci.yml`,
  `.github/workflows/release.yml`
- Modify: this plan file (task notes)

- [ ] Throwaway edit: set only `ci.yml`'s `build-ios` job back to `runs-on: macos-15`, run
  `swift test` (filtered to `ReleaseWorkflowTests` and `LintConfigurationTests`), and record
  the failure messages.
- [ ] Throwaway edit: set only `release.yml`'s `release` job to `runs-on: macos-latest`, run
  the same tests, and record the failure messages.
- [ ] Throwaway edit: set only `ci.yml`'s `lint` job to `runs-on: macos-15`, and confirm
  both the cross-workflow rule and the lint suite's rewired assertion fail.
- [ ] Revert every throwaway edit. Confirm `git diff` on the workflows shows only the seven
  `macos-15` → `macos-26` changes, then run `swift test` and confirm it passes.
- [ ] Write the observed failure messages into a "Notes" block under this task in the plan
  file.

### Task 3: docs/RELEASING.md tells the truth about the runner

**Files:**
- Modify: `docs/RELEASING.md`
- Modify: `Tests/PisakaCoreTests/ReleaseWorkflowTests.swift`
- Modify: `Tests/PisakaCoreTests/Support/RunnerPin.swift` (doc comment reader list)

- [ ] Rewrite the "Pinned toolchain: Xcode `26.3`" paragraph:
  - Keep the anchored phrase ``Pinned toolchain: Xcode `26.3` `` exactly as written, because
    `testReleasingDocNamesTheWorkflowPin` reads it.
  - Drop "on the `macos-15` runner", "the newest Xcode present on both the `macos-15` and
    the `macos-26` runner images" and "moving the jobs to `macos-26` is a separate
    follow-up".
  - State instead:
    - every job in both workflows runs on the `macos-26` image (macOS 26), introduced by one
      new anchored phrase ``Pinned runner: `macos-26` ``
    - the label is an explicit versioned image rather than `macos-latest`, so GitHub cannot
      change the OS under the pin without a commit
    - `ReleaseWorkflowTests` holds all seven jobs to that one label, with `RunnerPin`
      listing the readers, the same way it holds the six `setup-xcode` steps to one Xcode
    - the Xcode pin stays 26.3 because it is the Xcode the development machines run the
      app-layer gates under (the `Makefile` refuses any other), and the image ships it at
      `/Applications/Xcode_26.3.app`
    - why moving narrowed the gap: SwiftUI ships with the OS, not with Xcode, so a runner
      two major versions behind the development machine draws some layouts differently
  - Keep the CommandsBuilder history and the `Makefile` / `DEVELOPER_DIR` sentences.
- [ ] Extend `testReleasingDocNamesTheWorkflowPin`, or add a sibling test beside it, so the
  doc carries exactly one ``Pinned runner: `X` `` phrase and `X` equals
  `RunnerPin.pinnedLabel()`. This is the same anchored-phrase shape as the Xcode phrase. Add
  this reader to `RunnerPin`'s doc comment and to the suite's doc comment inventory.
- [ ] Add an entry to "### Manual verification owed for this feature" covering the first
  release on `macos-26`:
  - `release.yml` runs only on a `v*` tag, so its two jobs first run on `macos-26` at the
    next release.
  - The PR's CI run proves `ci.yml` on the new image. The static suites prove
    `release.yml`'s shape, but not that it runs.
  - What to check on that run: the job log's "Runner Image" group names a macOS 26 image,
    and the archive, notarize, staple and smoke-launch steps all pass.
- [ ] Run `swift test`; it must pass. Also confirm the new doc rule fails when the phrase is
  temporarily set to `macos-15`, then revert.

### Task 4: Correct the one claim the move makes false

**Files:**
- Modify: `docs/architecture/app-git-views.md`
- Modify: `CLAUDE.md`

- [ ] In `app-git-views.md` around line 749, "did nothing on macOS 15, where CI runs" stops
  being true. Rewrite it so it no longer says CI runs on macOS 15, while keeping the
  observation and its reasoning. The observation: `.defaultScrollAnchor(.topLeading)`
  worked on macOS 26 and did nothing on macOS 15, which the app still supports (macOS 14+),
  so the measured minimum height is what holds on every supported macOS.
- [ ] Add `RunnerPin` to `CLAUDE.md`'s list of shared helpers in
  `Tests/PisakaCoreTests/Support/`, next to `XcodePin`, so the list is still complete.
  Change nothing else in `CLAUDE.md`, which names no runner label. `LintConfigurationTests`
  keeps it under the 60,000-character limit; it is about 56,750 characters today.
- [ ] Run `swift test`; it must pass, including the `CLAUDE.md` size rule.

### Task 5: Verify acceptance criteria

- [ ] `grep -n "runs-on" .github/workflows/*.yml` prints seven lines, all `macos-26`.
- [ ] `grep -n "xcode-version" .github/workflows/*.yml` prints six lines, all `'26.3'`.
- [ ] `git diff master -- .github/workflows` shows only the seven `runs-on:` changes.
- [ ] `swift test` passes in full.
- [ ] `swiftlint lint --strict` from the repository root is clean under 0.65.1.
- [ ] `grep -rn "macos-15" docs/RELEASING.md docs/architecture CLAUDE.md .github` prints
  nothing.
- [ ] The app-layer gates (`make test-app`, `make build`) are not re-run locally: no Swift
  source outside `Tests/PisakaCoreTests` changes, and the PR's CI run covers them on the new
  image.

### Task 6: Update documentation

- [ ] `README.md` needs no change: it names no runner.
- [ ] `CLAUDE.md` gets only the helper-list addition from Task 4.
- [ ] Re-read the doc comments of `RunnerPin`, `ReleaseWorkflowTests` and
  `LintConfigurationTests` and confirm each inventory matches what the code now asserts.

## Post-Completion

These items are manual or external and are not part of any task's checkboxes.

- **The PR's own CI run is the acceptance for `ci.yml`.** It needs:
  - all five jobs passing
  - each job log's "Runner Image" group naming a macOS 26 image
  - the cache-key step still reporting `Xcode-26.3`

  Record the run ID and the reported image version in the PR description.
- **A possible `test-macos` failure on macOS 26.** If `test-macos` fails only because of how
  SwiftUI draws on macOS 26, that is the OS gap the move exists to expose, not a regression
  from this change. Treat it as a separate finding.
- **`release.yml` on `macos-26` is first exercised by the next `v*` tag.** The check for
  that run is the new owed-verification entry in `docs/RELEASING.md`.
