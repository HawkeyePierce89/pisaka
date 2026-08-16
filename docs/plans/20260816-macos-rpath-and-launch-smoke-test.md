# R-4: fix the macOS rpath, and make the pipeline launch what it ships

## Overview

The published `v1.0` dies in dyld on launch: `Library not loaded:
@rpath/Sparkle.framework/Versions/B/Sparkle`, searched under
`Contents/MacOS/Frameworks/`. The multiplatform target inherits XcodeGen's
iOS-shaped `LD_RUNPATH_SEARCH_PATHS` preset (`$(inherited)` +
`@executable_path/Frameworks`) on **both** destinations; on macOS the executable
sits in `Contents/MacOS/`, so the entry must be `@executable_path/../Frameworks`.
Sparkle (R-1) is the project's first embedded dynamic framework, so this
long-standing default was never dereferenced until it became fatal.

This plan (a) sets the macOS-conditional runpath in `project.yml` and pins it,
(b) adds a runtime **launch smoke test** to both places that build the shipping
configuration — CI's macOS job and the release workflow — pinned statically in
the workflow test suites, and (c) records the incident and both lessons in the
release documentation.

No Swift source changes: build settings + workflows + repository-file tests +
docs.

### Facts already established while planning (do not re-derive)

- `Pisaka.xcodeproj/project.pbxproj` (generated) carries
  `LD_RUNPATH_SEARCH_PATHS = ("$(inherited)", "@executable_path/Frameworks")` in
  **both** Debug and Release, with no sdk condition — the XcodeGen preset, since
  `project.yml` sets nothing.
- The macOS Release product's `LC_RPATH` load commands are exactly
  `/usr/lib/swift` and `@executable_path/Frameworks`. The `/usr/lib/swift` entry
  is added by the Swift toolchain, **not** by `LD_RUNPATH_SEARCH_PATHS`, so a
  conditional override cannot lose it — but this is re-verified with `otool`
  after the change rather than assumed.
- Direct exec of
  `DerivedData/Build/Products/Release/Pisaka.app/Contents/MacOS/Pisaka` today
  prints the dyld message above and exits **134** (SIGABRT).
- Writing `LD_RUNPATH_SEARCH_PATHS[sdk=macosx*]` in `project.yml`'s
  `targets.Pisaka.settings.base` was tried against XcodeGen and passes through
  verbatim, into both configurations, as
  `"LD_RUNPATH_SEARCH_PATHS[sdk=macosx*]" = ("$(inherited)", "@executable_path/../Frameworks");`.
  (The experiment was reverted; `git status` is clean.)

### Design decision carried over from the Q&A

The smoke launch is written **inline in both workflows**, in the repo's existing
heavily-commented style. No `scripts/` directory and no composite action. The
test suite pins each step's mechanism separately **and** asserts the two scripts
stay equivalent — the same cross-file shape as the XcodeGen pin
(`testXcodeGenIsPinnedIdenticallyToCI`) and the CI-budget floor
(`ciMacBuildBudget`).

## Context

Files involved:

- Modify: `project.yml` — the macOS-conditional `LD_RUNPATH_SEARCH_PATHS` plus
  the comment recording why it exists.
- Modify: `.github/workflows/ci.yml` — a smoke-launch step in `build-macos`.
- Modify: `.github/workflows/release.yml` — the same step between
  `Verify the archived app` and `Notarize the archived app`.
- Modify: `Tests/PisakaCoreTests/ReleaseMetadataTests.swift` — the `project.yml`
  rpath pin.
- Modify: `Tests/PisakaCoreTests/ReleaseWorkflowTests.swift` — the smoke-step
  pins, the ordering pin, the cross-file equivalence pin.
- Modify: `docs/RELEASING.md`, `docs/architecture/core-services.md`, `CLAUDE.md`.

Related patterns (follow, do not invent):

- `Support/YAMLLineMatching.swift` — `activeYAMLLines(of:)` +
  `contains(consecutively:)`; **every** assertion runs over comment-stripped
  lines, because both files quote their own settings in comments.
- `ReleaseWorkflowTests.stepScript(named:in:because:)` — step-scoped,
  comment-stripped `run:` bodies; already takes a workflow name and is already
  used against `ci.yml`.
- `ReleaseWorkflowTests.assertGuardExits(_:in:step:because:)` — nesting-aware
  "this `if` branch actually `exit 1`s".
- `ReleaseWorkflowTests.testEveryStepFailureStopsTheRelease` — release.yml-wide
  "no `continue-on-error:`, the only `if:` is `always()`".
- `ReleaseMetadataTests.testProjectStillShipsTheReleaseMetadataResources` — the
  house style for pinning a `project.yml` line with a message naming the failure
  it prevents.

Dependencies: none new. XcodeGen, `otool`, `codesign` are already in play.

## Development Approach

- **Testing approach**: Regular — settings/workflow change first, then the
  static pins in the same task, then the full suite.
- The **local reproduction is the acceptance test** for the fix: before/after
  `otool -l` and before/after direct exec of the Release product, run as real
  commands and their output pasted into the task's completion notes.
- Every task ends with `swift test` green before the next starts.
- The two smoke-launch scripts must be **character-identical apart from the
  `APP=` line**, because a test asserts exactly that. Write the second by
  copying the first.
- Known limit, recorded rather than fixed: no iOS runtime smoke test — CI has no
  simulator by design.

### The smoke-launch script (both workflows, identical apart from `APP=`)

```bash
set -euo pipefail
# The one line that differs between this step and its twin in the other
# workflow; ReleaseWorkflowTests asserts everything else is identical.
APP="<DerivedData/Build/Products/Release/Pisaka.app | build/Pisaka-macOS.xcarchive/Products/Applications/Pisaka.app>"
EXECUTABLE="$APP/Contents/MacOS/Pisaka"
DEADLINE=5
LOG="${RUNNER_TEMP:-/tmp}/smoke-launch.log"
if ! test -x "$EXECUTABLE"; then
  echo "::error::no executable at ${EXECUTABLE} …"
  exit 1
fi
"$EXECUTABLE" > "$LOG" 2>&1 &
PID=$!
ALIVE=1
for _ in $(seq "$DEADLINE"); do
  sleep 1
  if ! kill -0 "$PID" 2>/dev/null; then ALIVE=0; break; fi
done
if [ "$ALIVE" -eq 0 ]; then
  STATUS=0
  wait "$PID" || STATUS=$?
  cat "$LOG"
  CRASH="$(ls -t "$HOME/Library/Logs/DiagnosticReports/Pisaka"*.ips 2>/dev/null | head -1 || true)"
  if [ -n "$CRASH" ]; then cat "$CRASH"; fi
  echo "::error::The app exited on its own with status ${STATUS} before the ${DEADLINE}s deadline … <names the dyld/rpath class of failure and points at docs/RELEASING.md>"
  exit 1
fi
kill "$PID" 2>/dev/null || true
wait "$PID" 2>/dev/null || true
echo "The app survived ${DEADLINE}s and was terminated by this step."
```

Why this shape:

- **Success is "we killed it", not "it exited 0".** The death branch is entered
  whenever the process is gone — a dyld abort, a crash in `main`, *or a clean
  exit* — and it refuses unconditionally. The app's status is printed, never used
  as a pass criterion.
- **Liveness is polled with `kill -0`, not inferred from `wait`**, so the two
  outcomes are structurally different code paths rather than two exit codes to
  tell apart (a killed process and a crashed one both report ≥128).
- `DEADLINE=0` would make the loop body never run and every launch "survive" — a
  false pass. The value is pinned by the tests for exactly that reason.
- `${RUNNER_TEMP:-/tmp}` and `$HOME` keep the script runnable verbatim on a
  developer Mac, which is what makes the local dry-run in Task 2 real evidence.
- The assertion is "the process lives", not "the UI behaves": windows appearing,
  Sparkle's Release-only updater starting and polling github.com, session restore
  finding no session, and Sparkle's first-launch permission prompt are all inert
  to it.

Risk noted in the docs, not designed around: this needs the runner's user session
to host an AppKit process. GitHub's macOS runners do run a real session. If a
first CI run ever showed otherwise, the failure is loud (the step refuses) and
the fallback — asserting only that the output carries no dyld "Library not
loaded" — is a deliberate weakening, not a silent one.

## Implementation Steps

### Task 1: Fix the macOS runpath and pin it

**Files:**
- Modify: `project.yml`
- Modify: `Tests/PisakaCoreTests/ReleaseMetadataTests.swift`

- [x] Record the **before** state as evidence: `xcodegen generate`, build
      `-configuration Release -destination 'platform=macOS' -derivedDataPath DerivedData`,
      then `otool -l …/Contents/MacOS/Pisaka | grep -A2 LC_RPATH` (expect
      `/usr/lib/swift` + `@executable_path/Frameworks`) and a direct exec of that
      executable (expect the `Library not loaded: @rpath/Sparkle.framework/…`
      abort). Paste both outputs into the task notes.
- [x] Add to `targets.Pisaka.settings.base`:
      `LD_RUNPATH_SEARCH_PATHS[sdk=macosx*]:` with `$(inherited)` and
      `"@executable_path/../Frameworks"`, leaving the unconditional preset (and
      therefore iOS) untouched.
- [x] Write the comment above it in the file's established voice: XcodeGen's
      default is iOS-shaped and applies to both destinations; on macOS the
      executable is in `Contents/MacOS/` and frameworks in `Contents/Frameworks/`;
      Sparkle is the first embedded dynamic framework ever to resolve through it,
      which is why a wrong default survived from the first commit until `v1.0`
      crashed at launch; `/usr/lib/swift` comes from the toolchain and is not this
      setting's to preserve; the conditional overrides rather than appends, so
      `$(inherited)` here inherits from the project level.
      *(Written, with one clause corrected against measurement — see the note
      below: `$(inherited)` does pick up the target's own unconditional entry.)*
- [x] Verify the **after** state: `xcodegen generate`, rebuild Release, `otool -l`
      must show `@executable_path/../Frameworks` **and** `/usr/lib/swift`; direct
      exec must survive (kill it after a few seconds). Paste both outputs.
- [x] Verify iOS is unchanged: build `-destination 'generic/platform=iOS'` green,
      and `otool -l` on the iOS product shows the same rpath set as before
      (`@executable_path`, `@executable_path/Frameworks`, the PackageFrameworks
      entry).
- [x] Add `testProjectPinsTheMacOSRunpath` to `ReleaseMetadataTests`, matching the
      three lines consecutively over `activeProjectLines()`; the failure message
      names the `v1.0` launch crash, says the XcodeGen default is iOS-shaped, and
      states that nothing in the build, in CI's byte-level checks, or in this
      suite's other assertions would notice its removal.
- [x] Doc-comment that test in the suite's style: why the pin exists, why the
      build stays green without it, why only a *launch* can see it.
- [x] `swift test` — must pass.

**Task 1 completion notes — measured evidence**

Before, `otool -l DerivedData/…/Pisaka.app/Contents/MacOS/Pisaka`:

```
path /usr/lib/swift
path @executable_path/Frameworks
```

Before, direct exec — exit status **134**:

```
dyld[66521]: Library not loaded: @rpath/Sparkle.framework/Versions/B/Sparkle
  Referenced from: … /Pisaka.app/Contents/MacOS/Pisaka
  Reason: tried: '/usr/lib/swift/Sparkle.framework/Versions/B/Sparkle' (no such
  file, not in dyld cache), … '…/Pisaka.app/Contents/MacOS/Frameworks/Sparkle.framework/Versions/B/Sparkle'
  (no such file), …
```

After (`xcodegen generate` emits
`"LD_RUNPATH_SEARCH_PATHS[sdk=macosx*]" = ("$(inherited)", "@executable_path/../Frameworks");`
into **both** the Debug and Release target configurations, alongside the
untouched unconditional key):

```
path /usr/lib/swift
path @executable_path/Frameworks
path @executable_path/../Frameworks
```

After, direct exec — polled with `kill -0` for 5s: **SURVIVED 5s, killed by this
step**, no output.

iOS (`generic/platform=iOS`) built green and its rpath set is identical before
and after: `@executable_path`, the absolute `…/PackageFrameworks` entry,
`@executable_path/Frameworks`.

**Correction to a planning assumption.** The plan said the conditional
"overrides rather than appends, so `$(inherited)` here inherits from the project
level". The `otool` output above shows otherwise: Xcode layers the conditional
assignment on top of the *same-level* unconditional one, so `$(inherited)`
picks up `@executable_path/Frameworks` and the macOS product carries both
entries. The surviving iOS-shaped entry simply never resolves to anything; the
comment in `project.yml` now records the measured behaviour rather than the
assumed one, and says why dropping `$(inherited)` to prune the dead entry is
deliberately not done. `/usr/lib/swift` is confirmed to come from the toolchain,
as planned — the override does not lose it.

The pin was confirmed non-vacuous by commenting out the
`LD_RUNPATH_SEARCH_PATHS[sdk=macosx*]:` line and watching
`testProjectPinsTheMacOSRunpath` fail with its own message; `project.yml` was
then restored (`git diff --stat`: insertions only).

### Task 2: CI's macOS job launches what it built

**Files:**
- Modify: `.github/workflows/ci.yml`
- Modify: `Tests/PisakaCoreTests/ReleaseWorkflowTests.swift`

- [x] Add the step `Launch the built app (smoke test)` to `build-macos`,
      immediately after the Release build, with the script above and
      `APP="DerivedData/Build/Products/Release/Pisaka.app"`. No
      `continue-on-error:`, no `if:`.
- [x] Comment it in the file's style: byte-level gates cannot see a dynamic-link
      failure; `v1.0` compiled, signed, notarized and died in dyld; the assertion
      is that the process lives, not that the UI behaves; the success path is
      being killed at the deadline; no iOS equivalent because CI has no simulator.
- [x] **Dry-run the exact script locally** against the fixed Release build (paste
      the output), then re-run it against a deliberately broken copy — e.g. a copy
      of the app with `Contents/Frameworks/Sparkle.framework` moved aside — and
      confirm it refuses with the dyld text and a non-zero exit. Restore the copy;
      leave the real product untouched.
- [x] Add to `ReleaseWorkflowTests`: constants for the two step names and the
      pinned `DEADLINE` value; `testCILaunchesWhatItBuilds` asserting the step
      exists in `ci.yml`, sits **after** the `Build (macOS, Release …)` step,
      launches `"$APP/Contents/MacOS/Pisaka"` in the background, polls liveness
      with `kill -0`, and names the DerivedData Release product.
- [x] Add `testTheSmokeLaunchSuccessPathIsSurvivalNotAZeroExit`: the branch taken
      when the process is gone `exit 1`s at depth 0 (via `assertGuardExits`), the
      script compares no exit status against zero and contains no `exit 0`, and
      the only non-refusing path runs `kill "$PID"`.
- [x] Add `testTheSmokeLaunchDeadlineIsNotDegenerate`: `DEADLINE` equals the
      pinned value, with a message explaining that `0` makes the loop body never
      run and every launch "survive".
- [x] Add `testTheSmokeLaunchSurfacesWhatKilledIt`: the death branch prints the
      captured output before refusing (a refusal with no evidence in a job nobody
      can re-run interactively is a refusal nobody can act on).
- [x] Add `testTheCISmokeLaunchIsNotSkippable`: `ci.yml` carries no
      `continue-on-error:` and no `if:` — the ci.yml-scoped counterpart to
      `testEveryStepFailureStopsTheRelease`, whose absence would demote every
      refusal above to a log line.
- [x] `swift test` — must pass.

**Task 2 completion notes — measured evidence**

The step's `run:` body was extracted back out of `ci.yml` programmatically (so
the dry-run is literally what CI will execute) and run twice.

Against the fixed Release product — exit **0**:

```
The app survived 5s and was terminated by this step.
```

Against a copy with `Contents/Frameworks/Sparkle.framework` moved aside, `APP=`
repointed at the copy and nothing else changed — exit **1**:

```
dyld[67701]: Library not loaded: @rpath/Sparkle.framework/Versions/B/Sparkle
  Referenced from: … /tmp/smoke-broken/Pisaka.app/Contents/MacOS/Pisaka
  Reason: tried: … (no such file) …
{"app_name":"Pisaka", … "bug_type":"309", …}          ← the .ips crash report
… "termination":{"namespace":"DYLD","indicator":"Library missing", …}
::error::The app exited on its own with status 134 before the 5s deadline. …
```

Both branches of the design are therefore observed rather than assumed: the
`kill -0` poll saw the live process for the full 5s in the first run, and in the
second it saw the process gone, `wait` reported **134**, and both the redirected
output *and* the system's crash report were printed before the refusal. The
broken copy was deleted; the real product was never touched.

**Two shape corrections against the drafted script**, both forced by
`assertGuardExits`'s nesting rules and by the mechanism, not by taste:

- the inner `if [ -n "$CRASH" ]; then cat "$CRASH"; fi` is written across four
  lines rather than as a one-liner. A single-line `if …; fi` increments the
  helper's depth counter and never decrements it, so the death branch's own
  `exit 1` would be read as sitting at depth 1 — i.e. as *not* refusing — and
  `testTheSmokeLaunchSuccessPathIsSurvivalNotAZeroExit` would fail against a
  script that is in fact correct. The liveness loop's inner `if` is spelled out
  for the same reason.
- `assertGuardExits` gained a `workflow:` parameter (defaulting to
  `"release.yml"`). It hardcoded that filename in both failure messages, and a
  ci.yml guard reported as a release.yml one sends the reader to the wrong file.

Each of the five new assertions was confirmed non-vacuous by mutating `ci.yml`
and watching exactly the intended test fail: `DEADLINE=0`, `cat "$LOG"` deleted,
the death branch's `exit 1` deleted, `continue-on-error: true` added to the step,
and the step moved above the build. `ci.yml` was restored after each
(`git diff --stat`: 65 insertions, no deletions).

### Task 3: The release workflow launches what it will notarize

**Files:**
- Modify: `.github/workflows/release.yml`
- Modify: `Tests/PisakaCoreTests/ReleaseWorkflowTests.swift`

- [x] Add the step `Launch the archived app (smoke test)` **between**
      `Verify the archived app` and `Notarize the archived app`, with the same
      script and
      `APP="build/Pisaka-macOS.xcarchive/Products/Applications/Pisaka.app"`.
- [x] Comment it in the file's style: it runs after the re-sign so it launches
      what ships (hardened runtime, Developer ID, not yet notarized — nothing
      quarantined, so Gatekeeper is not in play); it runs before the submission so
      a build that cannot start never reaches the notary queue, twenty minutes and
      a full archive later; launching does not modify the bundle, and the staple
      step's `codesign --verify --deep --strict` afterwards is the standing proof
      of that rather than an assumption.
- [x] Extend `testTheReleaseIsAssembledInTheOnlyOrderThatShipsAWorkingApp`: add
      the step to the pinned sequence between verify and notarize, and extend the
      doc comment with what the two new inversions ship — smoke-launching before
      the re-sign tests a bundle the run then replaces, and launching after the
      submission lets a dead build occupy the notary queue and, worse, reach a
      publish.
- [x] Add `testTheReleaseLaunchesWhatItArchived`: the release-side step's own
      mechanism pins (background exec of the archived app's
      `Contents/MacOS/Pisaka`, `kill -0` liveness poll, refusal on death, `APP=`
      naming the archive product path used by every other step).
- [x] Add `testTheTwoSmokeLaunchesAreTheSameCheck`: both step bodies, read through
      `stepScript`, are **equal after dropping the `APP=` line**, with a failure
      message explaining that two hand-maintained copies drifting apart means one
      pipeline half stops checking what the other does — and that the fix is to
      copy, not to reconcile by hand.
- [x] `swift test` — must pass (including the existing
      `testEveryStepFailureStopsTheRelease`, which now also covers this step).

**Task 3 completion notes — measured evidence**

The step body was written by copying ci.yml's verbatim and changing only the
`APP=` line and the one comment naming the twin workflow; `stepScript`'s parse of
both, comment-stripped, is 33 lines each and equal after dropping `APP=`
(confirmed out-of-band with the same parse before running the suite). The
release job's step list now reads `… Re-sign Sparkle's nested helpers → Verify
the archived app → Launch the archived app (smoke test) → Notarize the archived
app → Staple …`.

The three new/extended assertions were each confirmed non-vacuous by mutating
`release.yml` and watching exactly the intended test fail, restoring after each:

- a shared line perturbed (`No executable at` → `No exe at`) →
  `testTheTwoSmokeLaunchesAreTheSameCheck` alone;
- `APP=` repointed at the DerivedData product →
  `testTheReleaseLaunchesWhatItArchived` alone;
- the death branch's `exit 1` deleted → `testTheReleaseLaunchesWhatItArchived`
  (its `assertGuardExits`) *and* the equivalence test, which is the right pair:
  removing a refusal from one copy is also drift;
- the whole step moved to after the notarization →
  `testTheReleaseIsAssembledInTheOnlyOrderThatShipsAWorkingApp` alone.

`swift test`: **2771 tests, 0 failures**. `git diff --stat` on `release.yml`
after the last restore: 76 insertions, no deletions.

### Task 4: Documentation

**Files:**
- Modify: `docs/RELEASING.md`
- Modify: `docs/architecture/core-services.md`
- Modify: `CLAUDE.md`

- [x] `docs/RELEASING.md`, in the ordered workflow walk-through under *Cutting a
      release*: a bullet for the smoke launch between the verification and
      notarization bullets — what it asserts, the crash-vs-killed distinction, why
      it sits before the submission.
- [x] `docs/RELEASING.md`: the incident record, beside the existing "**Why the
      step exists: `v1.0` was rejected**" note — the dyld message and the searched
      `Contents/MacOS/Frameworks/`, the root cause (an XcodeGen default nobody had
      ever exercised, because Sparkle is the first embedded dynamic framework),
      why **every** gate passed (`swift test` compiles Core, CI builds, the
      release workflow checks signatures, plists and notarization — all
      byte-level; nothing between the compiler and the user ever executed the
      binary), and the smoke launch as the structural answer. The recovery (delete
      and re-push the tag) is already documented — link it, do not restate it
      differently.
- [x] `docs/RELEASING.md`: reconcile the *Manual verification owed* bullet about
      the first tag push with what actually happened, so the document does not
      describe a state that has been overtaken — what the notarized publish did
      prove, and that the download-and-double-click pass is what caught the crash.
- [x] `docs/architecture/core-services.md`: a subsection beside *Release-metadata
      resources* for the build setting that only the shipped app dereferences —
      the conditional spelling and why XcodeGen passes it through, why iOS keeps
      the preset, why `/usr/lib/swift` is not this setting's to preserve, the
      `ReleaseMetadataTests` pin, and the two smoke launches with the **known
      limit** that there is no iOS runtime equivalent because CI has no simulator.
- [x] `CLAUDE.md`: extend the `ReleaseWorkflowTests` inventory sentence with the
      two smoke launches (step-scoped and by mechanism, success = "survived until
      we killed it" and not "exited zero", the non-degenerate deadline, the
      ordering slot before notarization, and the cross-file equivalence); extend
      the `ReleaseMetadataTests` sentence with the macOS runpath pin; extend the
      CI paragraph in *Commands* to say the macOS job now launches what it built,
      and note the absent iOS runtime check. Keep the file's size discipline —
      clauses, not essays.
- [x] `swift test` — must pass (`ReleaseWorkflowTests` reads `CLAUDE.md`-adjacent
      documents for the Gatekeeper-workaround absence assertions).

**Task 4 completion notes**

`swift test`: **2771 tests, 0 failures** — including
`testTheGatekeeperWorkaroundIsGoneFromEveryDocumentThatCarriedIt`, which reads
`docs/RELEASING.md` raw and is the one assertion the new prose could have broken.

Where each piece landed:

- `docs/RELEASING.md` — a *Launch the archived app (smoke test)* bullet in the
  ordered walk-through, between the verification and notarization bullets; a new
  `### The v1.0 launch crash, and why every gate missed it` section carrying the
  incident record (the dyld message and the searched
  `Contents/MacOS/Frameworks/`, the XcodeGen preset as root cause, Sparkle as the
  first embedded dynamic framework, why every byte-level gate passed, the smoke
  launch as the structural answer, the no-iOS-runtime-check limit) with the
  recovery *linked* to `Cutting a release` / `the build number` rather than
  restated; the `ReleaseWorkflowTests` pin inventory extended with the two smoke
  launches and the step ordering updated to `verify < smoke launch < notarize`;
  and the two *Manual verification owed* bullets reconciled — the re-pushed
  `v1.0` did publish, so the happy path is exercised, and the
  download-and-double-click attempt is what found the crash, which is why that
  bullet is now owed **in full** rather than partly done.
- `docs/architecture/core-services.md` — `### The macOS runpath, and the one gate
  that can see it`, beside *Release-metadata resources*: the conditional
  spelling, XcodeGen passing it through, iOS keeping the preset, the measured
  `$(inherited)` behaviour, `/usr/lib/swift` not being this setting's to
  preserve, the `ReleaseMetadataTests` pin, the two smoke launches and the known
  limit.
- `CLAUDE.md` — clauses, not essays: the runpath pin on the
  `ReleaseMetadataTests` sentence, the two smoke launches on the
  `ReleaseWorkflowTests` one (by mechanism, survival-not-zero-exit, the
  non-degenerate `DEADLINE`, the slot before notarization, the cross-file
  equivalence), and the CI paragraph now saying the macOS job launches what it
  built with no iOS runtime equivalent.

One note for the reviewer: `CLAUDE.md` was already 39,989 characters and these
three clauses put it at ~40.5k, over the repo hook's 40k guideline. The per-file
rationale went into the two docs above (the hook's own prescription) and what
stayed in `CLAUDE.md` is index-level, but the file is over the line and trimming
it back is a separate edit to prose this task did not write.

### Task 5: Verify acceptance criteria

- [x] `swift test` — full suite green.
- [x] `xcodegen generate` + macOS Release build green; `otool -l` on the product
      shows `@executable_path/../Frameworks`; direct exec survives past the
      deadline (record the output).
- [x] iOS build (`generic/platform=iOS`) green; its rpath set unchanged from the
      before-state recorded in Task 1.
- [x] The two workflow smoke steps are byte-identical apart from `APP=` (the test
      asserts it; confirm the assertion actually ran and is not vacuous, e.g. by
      temporarily perturbing one line and seeing it fail).
- [x] `git status` clean apart from the intended changes; no generated project,
      DerivedData or archive committed.

**Task 5 completion notes — measured evidence**

`swift test`: **2771 tests, 0 failures**, run both at the start of the task and
again after the last mutation was restored.

`xcodegen generate` then
`xcodebuild -configuration Release -destination 'platform=macOS' -derivedDataPath DerivedData`:
**BUILD SUCCEEDED**. `otool -l …/Pisaka.app/Contents/MacOS/Pisaka`:

```
path /usr/lib/swift
path @executable_path/Frameworks
path @executable_path/../Frameworks
```

The launch was not re-improvised: `ci.yml`'s `run:` body was extracted back out
of the workflow programmatically (38 lines, `APP="DerivedData/Build/Products/Release/Pisaka.app"`)
and executed verbatim — exit **0**:

```
The app survived 5s and was terminated by this step.
```

iOS (`generic/platform=iOS`): **BUILD SUCCEEDED**, and
`otool -l …/Debug-iphoneos/Pisaka.app/Pisaka` reports the same three entries the
Task 1 before-state recorded, in the same order — `@executable_path`, the
absolute `…/Debug-iphoneos/PackageFrameworks` entry, `@executable_path/Frameworks`.
The macOS-conditional key is invisible to it, as intended.

Cross-file equivalence, confirmed non-vacuous rather than merely green:
`testTheTwoSmokeLaunchesAreTheSameCheck` passes as committed; changing
`release.yml`'s `DEADLINE=5` to `DEADLINE=7` fails **that test and only that
test** (52 `ReleaseWorkflowTests`, 1 failure), which is also the useful proof
that the release-side deadline is pinned *through* the equivalence assertion
rather than by a second literal. `release.yml` was restored from a copy taken
before the edit.

`git status --porcelain`: **empty**. `DerivedData/` and `build/` are matched by
`.gitignore` (lines 9 and 17) and `Pisaka.xcodeproj` is untracked apart from the
deliberately committed workspace `Package.resolved`, which the resolve step left
byte-identical.

### Task 6: Update documentation index

- [ ] No `README.md` change — this is not user-facing (state it rather than
      leaving it implicit).
- [ ] Confirm `CLAUDE.md` and `docs/architecture/core-services.md` were updated
      per convention in Task 4 and that the per-file index needs no new entry (no
      new source file was added).

## Out of Scope

- An iOS runtime smoke test (no simulator in CI) — documented as a known limit.
- Any change to signing, re-signing, notarization or publication mechanics.
- Sparkle version or configuration changes.
- Adding `destinationFilters:` to SwiftTerm/libgit2 — still the separately noted
  follow-up.
