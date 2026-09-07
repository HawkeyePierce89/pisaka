# Keep local build products out of Spotlight — `.noindex` build output roots

## Overview

The two repository-level build output roots that the workflows spell relatively
— `DerivedData` and `build` — are renamed to `DerivedData.noindex` and
`build.noindex` everywhere they are spelled. A directory whose name ends in
`.noindex` is skipped by the metadata importer wherever it lives, so a verbatim
local reproduction of any documented command stops dropping indexable
application bundles in the checkout root. Nothing else about what the workflows
build, sign, notarize, staple, launch, upload or bump changes: this is a rename
of two path prefixes, plus the tests and documents that spell them, plus one new
pin so the rename cannot silently regress.

`SourcePackages` is deliberately untouched — it is the package clone cache keyed
by `actions/cache` on `Package.resolved`, and holds no product bundle of this
app.

## Context

### Files that spell the two roots today (measured, not assumed)

**Workflows**

- `.github/workflows/ci.yml` — `-derivedDataPath DerivedData` at lines 71
  (AppKit test bundle), 95 (macOS Release build), 309 (iOS build);
  `APP="DerivedData/Build/Products/Release/Pisaka.app"` at line 141 (the smoke
  launch's one differing line).
- `.github/workflows/release.yml` — `-derivedDataPath DerivedData` (433) and
  `-archivePath build/Pisaka-macOS.xcarchive` (434), both continuation lines of
  the archive step's folded `run: >` scalar;
  `APP="build/Pisaka-macOS.xcarchive/Products/Applications/Pisaka.app"` at 497,
  602, 824, 999, 1089; the archive path inside the `::error::` text at 509;
  `rm -rf` / `mkdir -p` / `ditto` / `notarytool submit` against
  `build/notarization` at 1011–1020; `rm -rf` / `mkdir -p` / `ditto` / `ls`
  against `build/release-assets` at 1159–1164, with the `ditto` source
  `build/Pisaka-macOS.xcarchive/…` on its own continuation line at 1162;
  `generate_appcast`'s input directory `build/release-assets` at 1182; the
  publish upload at 1236; the cask step's
  `ZIP="build/release-assets/Pisaka-${VERSION}.zip"` at 1303. Line 1273 spells
  the staging zip inside a whole-line comment — dropped by `activeYAMLLines`,
  and reworded anyway since it names the path. The appcast output is
  `-o appcast.xml` at the repository root, not under `build/`, and is ignored
  separately — it stays as it is.

**Configuration**

- `.gitignore` — `DerivedData/` and `build/` entries, each with its own comment
  block explaining why the path exists.
- `.swiftlint.yml` — `excluded:` names `build` and `DerivedData` (lines 22–23)
  alongside `Vendor` and `SourcePackages`.

**Tests**

- `Tests/PisakaCoreTests/ReleaseWorkflowTests.swift` — the literals at
  2189/2196 (`build/release-assets` in the notarization vs. staging split),
  2387/2397 (the `ZIP=`/publish pair the cask hash depends on), 3049
  (`APP="DerivedData/…"`), 3454 (`APP="build/Pisaka-macOS.xcarchive/…"`), plus
  prose in failure messages and doc comments at 3051, 3110, 3427, 3439, 3456,
  3524. Two `firstIndex(where: { $0.contains("-archivePath") })` ordering
  lookups (710, 2892) match the flag name only and need no change.
- `Tests/PisakaCoreTests/LintConfigurationTests.swift` — **does not** pin
  `.swiftlint.yml`'s `excluded:` list today. The ticket allowed for either; the
  new pin below is what will cover it.
- `Tests/PisakaCoreTests/DependencyPinTests.swift:41` names
  `DerivedData/…/SourcePackages` in a doc comment about a resolve run **through
  Xcode**, i.e. Xcode's own default location under `~/Library`. Not the same
  directory — stays.

**Documents**

- `CLAUDE.md:947` — the release archive command in the Commands section.
- `docs/RELEASING.md` — the local archive repro command (88), the archive
  product path (596), the DerivedData Release product prose (735, 1099), and the
  `build/release-assets/Pisaka-${VERSION}.zip` chain (786, 1002).
- `docs/architecture/core-services.md` — the required-reason-API audit commands
  read products out of DerivedData (693, 708) and the smoke-launch prose (946).
- `docs/architecture/style-lint.md` — checked: does **not** name the excluded
  directories. No change expected; the plan re-greps to confirm.
- `docs/plans/completed/**` — historical records of past work. Not rewritten;
  they describe what those changes did at the time. The acceptance grep is
  scoped to the live files, matching the ticket.

**Untouched by design**

- `Makefile` — passes no `-derivedDataPath` and no `-archivePath`; builds into
  Xcode's default location. Confirmed by reading every target.
- Both `actions/cache` blocks (`path: SourcePackages`, key on
  `Package.resolved`).

### Patterns to follow

- `ReleaseWorkflowTests` reads repository files through `#filePath` with
  Foundation only, and **every substring assertion runs over comment-stripped
  lines** — `activeYAMLLines(of:)` from
  `Tests/PisakaCoreTests/Support/YAMLLineMatching.swift`, or
  `stepScript(named:in:because:)` for one step's body. Only *whole-line*
  comments are dropped, which covers the shell comments inside `run:` blocks;
  the path literals live in YAML scalars on live lines, so they survive the
  strip and are readable exactly as the suite already reads them. The new pin
  uses the same two helpers — no raw-text `contains`.
- Assertions are made *by mechanism*: exact literals or set equality, never a
  loose `contains` on a word a comment could satisfy.
- `testTheTwoSmokeLaunchesAreTheSameCheck` compares the two smoke-launch bodies
  line for line after dropping the single `APP=` line. Both `APP=` values
  change; the bodies stay byte-identical apart from that line, exactly as
  pinned.

### Where the new pin lives

In `ReleaseWorkflowTests`, as one new `// MARK: - The build output roots`
section. That suite already reads both workflow files and arbitrary repository
files, and the rule is about build *output*, not about style — so `.gitignore`
and `.swiftlint.yml` are read from there too rather than splitting one rule
across two suites. `LintConfigurationTests` is left alone: it pins the style
authority's rule configuration, and never has pinned `excluded:`.

## Development Approach

- **Testing approach**: Regular — the rename lands with the assertions that pin
  it in the same task, because the existing `ReleaseWorkflowTests` literals fail
  the moment a workflow line moves.
- Every task ends with `swift test` green before the next begins.
- **CRITICAL: every task includes new/updated tests.**
- Per `CLAUDE.md`: read the matching `docs/architecture/*.md` entry before
  touching a file and update it when behaviour changes.
- No brand or product names anywhere in code, comments, tests, docs, the plan or
  commit messages.

## Implementation Steps

### Task 1: Rename the two roots in both workflows

**Files:**
- Modify: `.github/workflows/ci.yml`
- Modify: `.github/workflows/release.yml`
- Modify: `Tests/PisakaCoreTests/ReleaseWorkflowTests.swift`

- [x] `ci.yml`: the three `-derivedDataPath DerivedData` values become
      `DerivedData.noindex`, and the smoke launch's
      `APP="DerivedData/Build/Products/Release/Pisaka.app"` becomes
      `APP="DerivedData.noindex/Build/Products/Release/Pisaka.app"`. Nothing
      else in the file changes — no step added, removed or reordered, no other
      flag touched.
- [x] `release.yml`: `-derivedDataPath DerivedData` → `DerivedData.noindex`;
      `-archivePath build/Pisaka-macOS.xcarchive` →
      `build.noindex/Pisaka-macOS.xcarchive`; every
      `APP="build/Pisaka-macOS.xcarchive/…"` (five occurrences) →
      `build.noindex/…`; the `build/notarization` scratch directory (`rm -rf`,
      `mkdir -p`, `ditto` destination, `notarytool submit` input) →
      `build.noindex/notarization`; the `build/release-assets` staging directory
      (`rm -rf`, `mkdir -p`, `ditto` destination, `ls -l`, `generate_appcast`'s
      input directory, the publish upload, the cask step's `ZIP=`) →
      `build.noindex/release-assets`; the `ditto` source at the staging step
      (line 1162) → `build.noindex/Pisaka-macOS.xcarchive/…`. The
      `-o appcast.xml` output stays at the repository root.
- [x] Update the `::error::` message at 509 and the inline comments that spell a
      path under either root (including the whole-line comment at 1273) so they
      name the new one; leave every message whose text names only a flag
      (`-archivePath`, `-derivedDataPath`) as it is.
- [x] Confirm by hand that the two smoke-launch bodies still differ in the
      `APP=` line alone.
- [x] Move the existing `ReleaseWorkflowTests` literals to the new paths: the CI
      smoke launch's `APP=`, the archive-launched `APP=`, and the three
      `build/release-assets` assertions (the notarization/staging split and the
      `ZIP=`/publish pair). Update every failure message and doc comment that
      spells one of the two roots; leave the two `-archivePath` *flag-name*
      ordering lookups untouched.
- [x] Run `swift test` — must pass before Task 2.

### Task 2: `.gitignore`, `.swiftlint.yml`, and the pin that keeps the suffix

**Files:**
- Modify: `.gitignore`
- Modify: `.swiftlint.yml`
- Modify: `Tests/PisakaCoreTests/ReleaseWorkflowTests.swift`

- [x] `.gitignore`: `DerivedData/` → `DerivedData.noindex/` and `build/` →
      `build.noindex/`. The old names are **not** kept as a second ignore line —
      after Task 1 nothing writes to them. Extend the two existing comment
      blocks with the second reason the paths are shaped this way: a local
      reproduction of a documented command drops these in the checkout root, and
      the `.noindex` suffix is the one name-level opt-out that keeps the bundles
      inside them from being surfaced as installed applications.
- [x] `.swiftlint.yml`: `excluded:` names `build.noindex` and
      `DerivedData.noindex` instead of `build` and `DerivedData`. `Vendor` and
      `SourcePackages` are unchanged.
- [x] Add a `// MARK: - The build output roots` section to
      `ReleaseWorkflowTests` carrying the rule itself, over comment-stripped
      lines only:
  - every `-derivedDataPath` value in **both** workflows ends in `.noindex` —
    parsed as the token following the flag on the same active line, asserted as
    a set so a fourth occurrence appearing later is judged too, and failing
    loudly if the set is empty (a rule that matches nothing passes vacuously);
  - every `-archivePath` value in both workflows sits under a `.noindex`
    directory, by the same parse and the same empty-set refusal;
  - **no active line of either workflow names a path under a bare
    `DerivedData/` or `build/`** — scanned over `activeYAMLLines(of:)` for the
    *whole file*, deliberately **not** over lines filtered by a leading command
    word. A command-prefixed scan would miss exactly the lines that matter: the
    archive step is a folded `run: >` scalar, so `-derivedDataPath` and
    `-archivePath` sit on continuation lines, and the staging step's `ditto`
    source is a continuation line too (`release.yml:1162`). The match is the
    substring `DerivedData/`, and `build/` by the regex `(^|[^.\w])build/` —
    which is what stops `build.noindex/` and any word ending in `build` from
    reading as a hit; lines that spell `.noindex/` are excluded before the
    match, so the two new names cannot satisfy the check by accident. Same loud
    failure if the scanned line set is empty. Verified today: the lines this
    would match are exactly the ones Task 1 renames, plus the one whole-line
    comment `activeYAMLLines` already drops.
- [x] Add the paired configuration assertions in the same section: `.gitignore`
      names `DerivedData.noindex/` and `build.noindex/` and names neither bare
      directory as an ignore entry; `.swiftlint.yml`'s `excluded:` block (read
      through `topLevelBlock(_:in:)`) equals its four documented entries **by
      set equality**, which pins the two new names and the two untouched ones at
      once.
- [x] Write the rationale into that section's doc comment, once: application
      bundles are surfaced from any indexed directory, a name ending in
      `.noindex` is the one name-level opt-out, and the workflows' relative
      output paths are reproduced verbatim on developer machines — so the suffix
      is a property of the *names*, not of any one command. State what the pin
      cannot see (whether the fix works on a given machine is a runtime property
      of that machine's index; what is assertable is the name).
- [x] Run `swift test` and `swiftlint --strict` — both must pass before Task 3.

### Task 3: The documents that spell the two roots

**Files:**
- Modify: `CLAUDE.md`
- Modify: `docs/RELEASING.md`
- Modify: `docs/architecture/core-services.md`

- [x] `CLAUDE.md`'s Commands section: the release archive command's
      `-archivePath` becomes `build.noindex/Pisaka-macOS.xcarchive`. Nothing
      else in the surrounding comment changes.
- [x] `docs/RELEASING.md`: the local archive repro command, the archive product
      path, the two DerivedData-Release-product mentions and the
      `build.noindex/release-assets/Pisaka-${VERSION}.zip` chain (the staging
      prose and the cask-hash prose) all follow. Add the rationale in one place
      — a short note where the reader first meets the name, at the local archive
      repro command — saying why the two roots carry the suffix and that the pin
      lives in `ReleaseWorkflowTests`. Do not restate it at the other sites.
- [x] `docs/architecture/core-services.md`: the required-reason-API audit's
      `find` and `nm -u` command lines read out of `DerivedData.noindex/…`; the
      smoke-launch prose naming the DerivedData Release product follows.
- [x] Re-grep `docs/architecture/style-lint.md` for the excluded-directory names
      to confirm it still names none (it does today); update it only if the grep
      says otherwise.
- [x] Leave `Tests/PisakaCoreTests/DependencyPinTests.swift`'s doc comment as it
      is — it describes Xcode's own DerivedData under `~/Library`, a different
      directory — and leave `docs/plans/completed/**` as the historical record it
      is.
- [x] Run `swift test` — must pass before Task 4.

### Task 4: Verify acceptance criteria

**Files:** none modified (verification only; any failure sends work back to the
task that owns the file)

- [x] Record in the plan's Notes the acceptance grep and its output: `grep -rn`
      over `.github/workflows/ci.yml`, `.github/workflows/release.yml`,
      `.gitignore`, `.swiftlint.yml`, `CLAUDE.md`, `docs/RELEASING.md` and
      `docs/architecture/core-services.md` for `-derivedDataPath
      DerivedData[^.]`, `-archivePath build/`,
      `\bbuild/(release-assets|notarization|Pisaka-)` and `\bDerivedData/` —
      expected empty.
- [x] Reproduce `ci.yml`'s macOS Release build command verbatim from the
      repository root (`xcodegen generate`, the package resolve, then the
      Release build with `-derivedDataPath DerivedData.noindex`) and confirm the
      product lands at `DerivedData.noindex/Build/Products/Release/Pisaka.app`.
      **This is the one place the plan deliberately builds inside the checkout
      root** — it is the reproduction the fix exists to make safe, and the
      output directory is deleted immediately afterwards. Budget for a long run:
      a Release build compiles the app and every linked dependency with
      whole-module optimization, which is why CI gives this job 45 minutes.
- [x] With the product in place, run `mdfind -name Pisaka.app` and record that
      the reproduction's path is absent from the output, and
      `git status --porcelain` and record that it is empty. Record honestly in
      the Notes what this observation is worth: an absent path is consistent
      with the suffix working, and cannot on its own distinguish "skipped by
      name" from "not yet indexed" — the structural guarantee is the name, and
      the pin in Task 2 is what keeps it.
- [x] Delete `DerivedData.noindex/` afterwards.
- [x] Run the full gate set and record each result: `swift test`,
      `swiftlint --strict`, `xcodegen generate`, the macOS build, the iOS
      Simulator build, and `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka
      -destination 'platform=macOS' test`.

### Task 5: Update the index and the notes

**Files:**
- Modify: `CLAUDE.md` (only if the Tests section needs the new pin named)
- Modify: the plan file's Notes section

- [x] If the new pin warrants a mention, add it to `CLAUDE.md`'s existing
      `ReleaseWorkflowTests` sentence rather than as a new paragraph — that
      suite's inventory is explicitly delegated to its own doc comments and
      `docs/RELEASING.md`, so the index gains at most a clause, not an essay.
- [x] Record in the plan's Notes what this change is *not* proven by: `ci.yml`'s
      half is exercised end to end by the pull request's three green jobs, and
      that is the only end-to-end check available. `release.yml`'s half — the
      archive path, the notarization scratch directory, the staging directory,
      the appcast input, the publish upload and the cask hash — is exercised
      only by the next `v*` tag. Say so plainly; do not claim it was verified.
- [x] Run `swift test` and `swiftlint --strict` one final time.

## Post-Completion (outside the agent's reach)

- Open the pull request and confirm CI is green on all three jobs — the test
  job, the macOS Release build with its smoke launch (which now launches out of
  `DerivedData.noindex`), and the iOS build.
- The release workflow's half stays unverified until the next tag push. The
  first tagged release after this change should be watched through the archive,
  notarization, staging and cask-bump steps specifically, since those are where
  the `build.noindex` prefix first runs for real.

## Notes

### Task 4 — acceptance verification (run 2026-09-07)

**The acceptance grep.** All four patterns, run with `grep -rnE` over
`.github/workflows/ci.yml`, `.github/workflows/release.yml`, `.gitignore`,
`.swiftlint.yml`, `CLAUDE.md`, `docs/RELEASING.md` and
`docs/architecture/core-services.md`, produced **no output** (exit status 1,
"no lines selected", for each):

- `-derivedDataPath DerivedData[^.]` — empty
- `-archivePath build/` — empty
- `\bbuild/(release-assets|notarization|Pisaka-)` — empty
- `\bDerivedData/` — empty

**Amendment (review, same day).** The review that followed restored the two
pre-rename `.gitignore` entries as legacy guards (see the correction recorded
below), so the fourth pattern no longer comes back empty over that file: re-run
today it reports `.gitignore:26:DerivedData/` and the comment line above the
`build/` guard. Both hits are the intended guards, not a regression. Over the
other six files all four patterns are still empty, which is what the recorded
result means from here on; the guards themselves are pinned by
`testTheIgnoreFileNamesTheNoIndexRootsAndTheLegacyGuards`.

**The local reproduction.** `ci.yml`'s macOS Release build was reproduced
verbatim from the repository root — `xcodegen generate`, then
`xcodebuild -project Pisaka.xcodeproj -resolvePackageDependencies
-clonedSourcePackagesDirPath SourcePackages`, then the Release build with
`-derivedDataPath DerivedData.noindex` — and ended `** BUILD SUCCEEDED **`
(exit 0). The product landed exactly where the smoke launch's `APP=` line now
names it:
`DerivedData.noindex/Build/Products/Release/Pisaka.app`, with the executable at
`Contents/MacOS/Pisaka`.

**`mdfind` and `git status`.** With that product in place,
`mdfind -name Pisaka.app` returned `/Applications/Pisaka.app` alone — the
reproduction's path was **absent** — and `mdfind -onlyin <checkout> -name
Pisaka.app` returned nothing at all. `git status --porcelain` was **empty**.

*What that observation is worth, stated honestly:* an absent path is
*consistent* with the suffix working and nothing more. It cannot on its own
distinguish "skipped by the metadata importer because of the name" from "not
yet indexed at the moment the query ran" — the index is a runtime property of
the machine that holds it. The structural guarantee here is the **name**, and
the pin added in Task 2 is what keeps that name from regressing.

*One further honest limit, observed in the build log:* the Release build's own
output carries an
`lsregister -f -R -trusted …/DerivedData.noindex/Build/Products/Release/Pisaka.app`
line — the build registers its product with LaunchServices directly, which is a
different mechanism from the metadata importer that `.noindex` governs. This
change is about the *index*; it does not claim anything about LaunchServices
registration, and none was measured.

`DerivedData.noindex/` was deleted immediately after the observations; the
checkout root holds neither it nor `build.noindex/` now.

**Correction, recorded in review.** The `git status --porcelain` result above is
not the evidence the checklist asked for, and the sentence before it is wrong as
written. The tree was clean at that moment because the *pre-rename* roots —
`build/` and `DerivedData/`, left on disk by earlier local runs — had already
been **committed** one task earlier: Task 2 renamed their `.gitignore` entries
instead of adding beside them, which un-ignored them, and the same commit swept
in 22 816 files (2.2 GiB), including a signed `Pisaka.app` and
`build/staging/Pisaka-1.0.zip`. So the checkout root did hold build output, and
`git status` could not see it. Task 2's stated premise — "the old names are not
kept as a second ignore line, after Task 1 nothing writes to them" — is true of
what *writes* and false of what an existing clone already *holds*, which is the
only thing an ignore entry governs.

Fixed in review: the 22 816 files were removed from this branch's history, both
bare roots were restored to `.gitignore` as commented legacy guards,
`ReleaseWorkflowTests` now *requires* all four entries rather than forbidding
two, and `docs/RELEASING.md` carries the one-time `rm -rf build DerivedData`
note. A tracked file is invisible to `git status`, so the check this task should
have run is `git ls-files build DerivedData DerivedData.noindex build.noindex`
— expected empty, and empty now.

**The gate set.** Each run from the repository root, each result recorded as it
came back:

| Gate | Result |
| --- | --- |
| `swift test` | passed — 5 280 tests, 0 failures |
| `swiftlint --strict` | passed — 0 violations, 0 serious, 517 files |
| `xcodegen generate` | passed — project written |
| macOS build (`-destination 'platform=macOS'`) | `** BUILD SUCCEEDED **` |
| iOS Simulator build (`iPhone 17 Pro`) | `** BUILD SUCCEEDED **` |
| App-layer bundle (`-destination 'platform=macOS' test`) | `** TEST SUCCEEDED **`, 0 failures |

Only the reproduction above used `-derivedDataPath` inside the checkout, which
is the point of that step; the three gate builds wrote to derived-data
directories under `~/Library/Developer/Xcode/DerivedData/`.

### Task 5 — what this change is *not* proven by

Stated plainly, because the two halves of this rename have very different
evidence behind them.

**`ci.yml`'s half is exercised end to end**, and that is the only end-to-end
check this repository has. The pull request's three jobs run the renamed
commands for real: the test job, the macOS Release build — which builds into
`DerivedData.noindex` and then *launches* the product out of it, so a wrong
`APP=` path fails the job rather than passing quietly — and the iOS build.
Three green jobs mean the `DerivedData.noindex` rename works where it runs.

**`release.yml`'s half is not exercised by anything until the next `v*` tag.**
Nothing in pull-request CI touches it, by design: the workflow runs only on a
tag, and its secrets are unreachable from a pull request. So every one of these
is renamed and statically pinned but **unrun**:

- the archive path (`build.noindex/Pisaka-macOS.xcarchive`) and the five
  `APP=` readings out of it,
- the notarization scratch directory (`build.noindex/notarization`),
- the staging directory (`build.noindex/release-assets`) and the `ditto` that
  fills it,
- the appcast generator's input directory,
- the publish upload,
- the cask step's `ZIP=` and therefore the `sha256` the cask bump records.

What stands behind that half is `ReleaseWorkflowTests` — which reads the
workflow's shape from the file and now also pins both roots' `.noindex` names —
plus the acceptance grep recorded above. That is a static guarantee about the
text of the workflow, not a demonstration that the tagged run succeeds. It is
not claimed to be one; the first tagged release after this change is where that
half is verified, and the Post-Completion section says which steps to watch.

### Where the shipped pin diverges from Task 2, and one root it does not cover

Recorded in review, because each is a decision the checklist above does not
describe.

**Task 2 said `.noindex/` lines are excluded before the bare-root match. They
are not.** The shipped rule judges every line **whole**. The skip would have
been redundant — neither path matcher can fire on a `.noindex` name, since
`DerivedData.noindex/` does not contain `DerivedData/` and the `[^.\w]` prefix
already refuses `build.noindex/` — and it would have exempted exactly the lines
the rule exists for: a two-path command line (`ditto SRC DST`, `rm -rf a b`)
where only one side kept its suffix. Every active line naming a build output
root is such a line, so the skip would have exempted all of them.

**Task 2 does not name the documents rule, which shipped as part of the same
section.** `testNoDocumentSpellsABareBuildOutputRoot` runs the same matchers
over `CLAUDE.md`, `docs/RELEASING.md` and `docs/architecture/core-services.md`,
turning Task 4's by-hand acceptance grep into a standing pin. It reads raw text
rather than comment-stripped lines — in Markdown the command *is* the content —
and asserts per document that a root is still spelled there, so a document
reworded until it names none is dropped from the roster rather than sitting in
it passing by matching nothing.

**A third relative root inside the checkout does hold an indexed application
bundle, and this change does not address it.** The Overview's reason for leaving
`SourcePackages` alone — "holds no product bundle of this app" — is true as
written and beside the point: Sparkle is a SwiftPM `binaryTarget`, so a package
resolve lands
`SourcePackages/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework/Versions/B/Updater.app`
in the checkout. Measured on this machine today, that path is returned by
`mdfind -onlyin <checkout> 'kMDItemContentType == "com.apple.application-bundle"'`
and `mdls` reports it as `com.apple.application-bundle` — so the goal stated in
the Overview is met for the two roots this plan renamed and not for the checkout
as a whole. Renaming it too means moving `-clonedSourcePackagesDirPath`, both
`actions/cache` blocks' `path:`, the `.gitignore` and `.swiftlint.yml` entries
and the pin's `styleExclusions` together; that is a separate change, deliberately
not folded into a review of this one.

### The matchers as shipped, after external review

Recorded because Task 2 spells one of them out and the shipped patterns are
narrower and wider in ways worth naming.

**The bare-root path matchers.** Task 2 names `(^|[^.\w])build/`. Both roots now
run through one shared prefix — `` (^|[\s"'`(=])(\./)? `` — which requires the root
to *begin* a path: line start or a delimiter that opens one (whitespace, a
quote, a backtick, `(`, or the `=` of a shell assignment), with an optional
`./`. Every live spelling still matches (`-archivePath build.noindex/…` after a
space, `APP="DerivedData.noindex/…"` after a quote, a Markdown backticked path).
What no longer matches is a root that is a *segment of somebody else's path* —
`~/Library/Developer/Xcode/DerivedData/…`, which is the out-of-checkout location
a local build is told to use precisely so nothing lands near the tree, and any
nested `…/build/…` in a URL. The old `[^.\w]` prefix treated `/` as a boundary
and so failed those with a message describing a repository-relative root they
are not.

**The checkout can also be spelled out loud.** Refusing an unqualified `/` in
front of a root leaves one shape uncovered, and a later review round named it:
`"$GITHUB_WORKSPACE/build/notarization"` and `$PWD/DerivedData/Build` have a
segment in front of the root, but that segment *is* this checkout, so they
recreate the very directory the suffix exists to keep out of the index. Both
matchers now take a `checkoutRootReference` — `$GITHUB_WORKSPACE`, `$PWD`,
`$(pwd)`, `${{ github.workspace }}`, braced or not — wherever they take the
optional `./`. Only roots that name the checkout itself qualify: `$RUNNER_TEMP/
build/…` is a directory outside the tree and stays live, and is pinned as such.

A later round named the second half of the same shape: a shell writer quotes the
*variable* alone, so `rm -rf "$GITHUB_WORKSPACE"/build/notarization` and
`-archivePath "${PWD}"/build/Pisaka.xcarchive` put a closing quote between the
reference and the root. That quote left the path matching neither the reference
branch (which demanded the `/` immediately) nor the bare one (whose `/` is no
delimiter), so the one spelling that names this checkout out loud *and* reads
naturally evaded both. Both matchers now take an optional closing quote after
the reference. It requalifies nothing on its own — `"$RUNNER_TEMP"/build/staging`
is still live, and pinned as such.

**The flag matcher takes a quoted value.** `-derivedDataPath "DerivedData"` names
the same stale root as the bare spelling and now fails the same way: the value
may carry one opening quote or backtick as well as the optional `./`.

**Annotations are cut out, not skipped and not truncated at.** The flag-*value*
scan (`assertFlagValuesAreNoIndexed`) skipped any line carrying `::error::` and
friends, because those spell a flag name inside a sentence where the next word
is prose. The skip was not free, contrary to what its comment claimed: the
paired absence rule can see a *bare* root attached to a flag, but nothing else
can see the **root-equality** rule — a value ending in `.noindex` that names a
root neither `.gitignore` nor `.swiftlint.yml` knows about. A command reporting
its own failure (`xcodebuild … -derivedDataPath X.noindex || echo "::error::…"`)
carries both halves on one line, and skipping it whole carried the value out of
the only rule that judges it. Verified by injecting exactly that line into
`ci.yml`: the rule now fails on it, naming `scratch.noindex` against
`DerivedData.noindex`.

Truncating at the marker was the first answer and only half of one, as the same
review round pointed out: shell lives on *both* sides of an annotation, which
`release.yml` already demonstrates (`test -d "$APP" || { echo "::error::no app
at ${APP}"; exit 1; }`), so a line whose command follows its annotation —
`echo "::notice::…"; xcodebuild -derivedDataPath scratch.noindex` — was carried
out of reach exactly as the skip had been. `commandHalf(of:)` now removes the
annotation as a *span*: from the marker to the end of the string literal that
opened it, matched on the same quote character and honouring backslash escapes,
so an apostrophe in the prose (`the app's Info.plist`) and an escaped quoted
phrase (`\"Signed Time=\"`) — both live in `release.yml` — cannot end it early
and leak the sentence back in as shell.

A marker with no string in front of it opens no literal, and the first answer —
the rest of that line is prose — was the truncation bug once more, one shape
further out. `echo ::notice::starting` is valid shell whenever the prose carries
nothing the shell would eat, so `echo ::notice::starting; xcodebuild
-derivedDataPath scratch.noindex` was carried out of reach exactly as the quoted
form had been. An unquoted annotation's prose is the rest of that *command*, and
ends where the next one begins: at the first unquoted `;`, `&`, `|`, `)` or `}`,
none of which can sit unquoted among an `echo`'s words without being that
operator. Only a marker with no separator after it is prose to the end of the
line.

A further round refuted both halves of that sentence's reasoning, in the same
direction each time — the cut reaching further than the prose. The quoted
branch asked for the *last* quote before the marker and took a matching quote
anywhere later as its terminator, but the last quote before a marker is as
often the **closing** one of an earlier string (`test -n "$APP" && echo
::notice::…`), so any quote later on the line — a `-scheme "Pisaka"` suffices —
was read as the annotation's end and every command between the two cut out as
prose, carrying a real `-derivedDataPath` out of reach exactly as truncating at
the marker had. Whether a literal is open is now read off `kept`, the shell the
cut has preserved, as *state*; a quote is never guessed from the quotes around
the marker. And two of the five terminators do sit unquoted mid-word after all,
closing what a `$` opened: `${APP}` and `$(basename "$APP")` are ordinary in
prose, and ending the command at their `}` or `)` left the rest of the sentence
in the line as shell — where `-archivePath on the command line` reads as a flag
whose value is `on` and fails a rule about a path nobody wrote. The scan now
tracks what each `$` opened (including the `))` of an arithmetic expansion) and
treats the five as terminators at the top level only; inside an expansion
nothing is, `$(a; b)` being one word too. All four shapes are pinned in
`testTheAnnotationRemovalKeepsTheCommandHalvesOfALine`, and each was confirmed
to fail against the previous parser before the fix landed.

**Both are pinned in both directions.** The matchers were read out of the
assertion into `staleBuildOutputRootSpelling(in:)` so
`testTheBareRootMatchersJudgeTheShapesTheyClaimTo` can feed them stale *and*
live lines no repository file holds — every other caller asserts an absence, and
an absence rule is green whether it matches the right shapes or nothing at all.
`testTheAnnotationRemovalKeepsTheCommandHalvesOfALine` does the same for the
annotation span, both sides of it included.

**Four boundary shapes from the round after that**, all of them the same two
mistakes the rounds above made — the cut reaching further than the prose, and a
delimiter list that is shorter than the shell's.

*An annotation's prose is prose only as far as the shell agrees.* A `$(…)` or a
backtick pair inside one is executed before `echo` sees a word of the sentence,
so `echo "::notice::$(xcodebuild -derivedDataPath scratch.noindex)"` is a real
build with a real flag value — and removing the annotation as one span carried
it out of reach of the root-equality rule, which is the failure the span exists
to prevent, one shape further in. `commandHalf(of:)` now puts the *contents* of
every substitution in the cut span back into the shell it keeps
(`substitutedShell(in:from:to:)`); the sentence around it stays cut, so a flag
name written as prose is still not read as a flag. Verified by injecting that
exact line into `ci.yml`: the rule fails on it, naming `scratch.noindex` against
`DerivedData.noindex`. An escaped backtick — `release.yml` writes one — opens
nothing, and `$((…))` runs no command and contributes nothing.

*Brackets nest inside an expansion too.* The terminator scan recorded only the
closers a `$` introduced, so an ordinary grouping `(` inside one —
`$(( (COUNT + 1) * 2 ))` — paid back a `)` the expansion still needed, the
expansion's own `)` read as a top-level terminator, and the prose behind it
(`-archivePath on the line`) leaked in as shell: the `on`-is-a-path failure the
previous round fixed, reached by another door. A bare `(` now pushes its own
closer while an expansion is open. A `{` needs no twin — the only closer it
could steal is the `}` of a `${…}`, whose body has no place for one.

*A redirection is a delimiter whose space is routinely left out.*
`echo … >build/report` and `xcodebuild … 2>DerivedData/error.log` name a bare
output root as squarely as the spaced spellings, and the path prefix's delimiter
class read the `>` as part of a word and let both past. `<` and `>` join it, and
both shapes are pinned stale (with `>build.noindex/report.txt` pinned live).

*And the live half of the flag rule now reads a value the way the stale half
already did.* `-derivedDataPath "DerivedData.noindex"` and `-archivePath
./build.noindex/…` name exactly the roots this section requires, but the scan
compared the raw whitespace token, whose first path segment is
`"DerivedData.noindex"` or `.` — so both failed with a message naming a root the
line does not spell. Every failure of that reading is a *false* one, and a rule
that fails on the correct answer is a rule someone deletes. `pathNamed(by:)`
takes the quoting and the `./` off the token, pinned in both directions by
`testAFlagValueIsReadAsThePathItNamesNotItsQuoting`; the quoted *stale* spelling
still fails, through the absence rule that has taken a quoted value all along.

**Four more from the round after that**, three of them the same mistake as
before — the cut reaching further than the prose — and one of them its mirror,
the rule failing on a line that is right.

*A `${…}` is one word of a substitution, brackets included.* The depth scan in
`commandSubstitution(in:at:before:)` counted raw parentheses and quotes but not
parameter expansions, so `$(echo ${X:-)}; xcodebuild -derivedDataPath
scratch.noindex)` ended at the expansion's `)` and everything the substitution
still ran was dropped — the silent direction, the one that leaves the suite
green. It now skips a `${…}` whole, by brace depth, exactly as the terminator
scan already did.

*Nothing is escapable inside a single-quoted string.* All four scanners honoured
the backslash unconditionally, so a sentence ending in one — `echo
'::notice::ends in a backslash \'; xcodebuild -derivedDataPath scratch.noindex
-scheme 'Pisaka'` — ran the span past its real terminator to the quote around
`Pisaka` and cut the whole command between them out as prose: the quote-parity
bug of two rounds ago, reached through the escape rule instead. The rule is now
the shell's — a backslash inside `'…'` is an ordinary character — in
`firstUnescapedQuote`, `openQuote(inShellPrefix:)`, `firstCommandSeparator` and
`commandSubstitution` alike. The last two have shapes of their own here, since
nothing that pins the first two can tell them apart.

*And a single-quoted annotation substitutes nothing.* `substitutedShell` pulled
every `$(…)` and backtick pair back out of the cut span without asking which
quote the annotation sat in, so `echo '::notice::$(xcodebuild -derivedDataPath
scratch.noindex)'` — words the shell prints, running no build — failed a rule
about a root nobody named. This is not the scan erring toward dropping but the
same reading one level up: a literal that executes nothing has no shell to keep.
The enclosing quote is now a parameter, and a `'…'` inside an *unquoted*
annotation suppresses the same way — while inside a double-quoted one an
apostrophe still opens nothing, which is pinned too.

*The checkout spelled out loud is the checkout.* `-archivePath
"$GITHUB_WORKSPACE"/build.noindex/Pisaka-macOS.xcarchive` names exactly the root
this section requires — `testTheBareRootMatchersJudgeTheShapesTheyClaimTo` pins
that very line as live for the stale matchers — yet its first path segment read
as `$GITHUB_WORKSPACE"` and failed. `pathNamed(by:)` now takes the same
reference family the matchers take, and `shellTokens(of:)` closes up the
internal spaces of `${{ github.workspace }}` first, since a whitespace split
otherwise leaves the value reading as the bare `${{`. Stripping costs the rule
nothing: the stale spelling behind the same reference still fails both checks,
now with a message naming the root the line actually spells, and
`"$RUNNER_TEMP"/…` is left alone exactly as the matchers leave it.

**Three more from the round after that** — two of them the same silent
direction, one nesting level further in than any shape above, and one a hole in
the rule rather than in the parser.

*A quoted brace is not a brace.* `parameterExpansion(in:at:before:)` counted
`{` and `}` by depth without reading the quotes around them, so `${X:-'}'}` —
an ordinary default value of `}` — closed at the *quoted* bracket. The scan
then read the rest of the line from inside a string that never ends, the
substitution around it looked unterminated, and `$(echo ${X:-'}'}; xcodebuild
-derivedDataPath scratch.noindex)` contributed nothing at all. It now tracks the
quote exactly as `commandSubstitution` and `firstCommandSeparator` already do.

*A command substitution is a quoting scope of its own.* `openQuote(inShellPrefix:)`
paired every quote flatly, but the quotes inside `$(…)` pair with each other and
not with the ones around them: `echo "$(printf "::notice::text"; xcodebuild
-derivedDataPath scratch.noindex)"` opens two strings, and read flat the inner
opener was taken for the outer's closer. The marker then read as *unquoted*, the
span was cut to a separator sitting inside the substitution's own string, and the
build behind it was carried out of reach — the quote-parity failure of two rounds
ago, reached a third way. The scope is now pushed at `$(` and popped at its `)`,
and skipped inside `'…'`, where `$(` substitutes nothing.

*And a value may not climb back out of its own root.* Both halves of
`assertFlagValuesAreNoIndexed` read the value's **first** path segment, so
`-archivePath build.noindex/../build/Pisaka.xcarchive` opened with
`build.noindex`, satisfied the suffix check and the root-equality check, and
landed the archive in `build` — indexed like the rest of the checkout. The
absence matchers cannot cover it either: a root with a `/` in front of it is
somebody else's directory by their own deliberate rule, which is what keeps
`~/Library/Developer/Xcode/DerivedData/…` live. A parent component is now
refused outright, ahead of the two checks that assume it away.

**One more from the round after that**, the same silent direction again and the
directly adjacent nesting level of the scope the previous round had just added.

*And that scope nests.* `openQuote(inShellPrefix:)` pushed at `$(` and popped at
the very next unquoted `)`, without counting the ordinary parentheses in
between — so a subshell or a grouped condition inside the substitution
(`echo "$( ( printf x ); printf "::notice::text"; xcodebuild -derivedDataPath
scratch.noindex)"`) paid the substitution's closer with the *group's* bracket.
The outer quote came back a bracket early, the marker read as unquoted, the span
was cut to a separator inside the substitution's own string, and the build behind
it was carried out of reach — the same failure the scope was added to prevent,
one level further in, and the shape both other scanners had already been taught
(`firstCommandSeparator` counts a nested `(` as a closer owed,
`commandSubstitution` finds its closer by depth). An unquoted `(` inside a scope
now owes a closer of its own; it is entered unquoted and left unquoted, which is
what pushing the current quote there says, and it makes `$((…))` balance through
the same two pops rather than by falling off the end.

**Two more from the round after that**, both the last two shapes the scope
rule had not yet been taught — and both the silent direction, again.

*A `${…}` inside the scope is not punctuation.* `openQuote(inShellPrefix:)` read
every bracket in a substitution by hand, so a parameter expansion spelling one as
a *value* paid the substitution's closer: `echo "$(echo ${X:-)}; printf
"::notice::text"; xcodebuild -derivedDataPath scratch.noindex)"` popped the scope
at the `)` inside `${X:-)}`, the outer quote came back early, the marker read as
unquoted, and the build behind it was cut away as prose. It is the
nested-grouping failure of the previous round reached through an expansion
instead of a subshell, and the fix is the one the two other scanners already
carry: the expansion is skipped whole, through the same
`parameterExpansion(in:at:before:)` `commandSubstitution` calls — which, since
that helper tracks quotes, also disposes of the `${X:-'}'}` shape at this scanner.

*And a backtick pair is that scope in the older spelling.* The scan pushed one at
`$(` alone, while ``echo "`printf "::notice::text"; xcodebuild -derivedDataPath
scratch.noindex`"`` is the same two strings written the other way — read flat,
the inner opener was again taken for the outer's closer and the build behind it
was carried out of reach. This file already reads a backtick substitution
(`substitutedShell` resurrects its contents), so the scanner that decides whether
the marker is quoted at all now pushes and pops a scope there too, delimited by
the next unescaped backtick — `substitutedShell`'s own rule — and opening
nothing inside `'…'`. The other two scanners need no such teaching:
`firstCommandSeparator` opens no quote at a backtick, so one can only end a span
*earlier*, which keeps shell rather than dropping it.

**Two more from the round after that**, and both are the nesting rule read one
step further than the previous rounds had taken it — still the silent direction.

*The quote that **ends** a span is read at the annotation's own level too.*
Every round so far had taught the scanner that decides whether a marker is
quoted; the one that decides where its string *closes* still scanned flatly for
the next quote, so `echo "::notice::$(xcodebuild -derivedDataPath
scratch.noindex; printf "x") done"` — one string around a substitution that
opens and closes another — ended the span at the inner opener. The span then
stopped *inside* the substitution, which left that substitution unterminated as
far as `substitutedShell` could see, so its contents were not resurrected either
and the whole build was dropped: the carried-out-of-reach failure reached
through the end of the span rather than through its start. The span's end is now
found by `stringEnd(openedBy:in:from:)`, which skips every nested scope whole —
and `'…'` remains the exception, substituting nothing and therefore ending at
the very next `'`.

*And a scope nested inside a `${…}` is not punctuation either.*
`parameterExpansion(in:at:before:)` tracked quotes and brace depth but read a
nested substitution's brackets as its own, so the `}` in ``${X:-`printf %s }`}``
— an argument the substitution prints — was taken for the expansion's closer.
That left `openQuote(inShellPrefix:)` walking the substitution's own text, where
the closing backtick pushed a scope nobody owed and the `)` that really ended
the substitution no longer popped one: the outer string never reopened, the
marker read as unquoted, and `echo "$(echo ${X:-`printf %s }`}) ::notice::text";
xcodebuild -derivedDataPath scratch.noindex` lost its build to the prose. It is
the previous round's `${X:-)}` failure with the two constructs swapped, so the
fix is stated once and shared: `nestedScopeEnd(in:at:before:)` is now the single
definition of "skip a nested `$(…)`, `${…}` or backtick pair whole", and the
three scanners that count punctuation call it instead of each learning the two
spellings it happened to meet. The two helpers recurse into each other because
the shell nests them that way, and a scope the span never closes is still not
skipped at all — the keeping direction, which leaves the caller counting exactly
what it counted before.
