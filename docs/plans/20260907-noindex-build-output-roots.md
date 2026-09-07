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

- [ ] `ci.yml`: the three `-derivedDataPath DerivedData` values become
      `DerivedData.noindex`, and the smoke launch's
      `APP="DerivedData/Build/Products/Release/Pisaka.app"` becomes
      `APP="DerivedData.noindex/Build/Products/Release/Pisaka.app"`. Nothing
      else in the file changes — no step added, removed or reordered, no other
      flag touched.
- [ ] `release.yml`: `-derivedDataPath DerivedData` → `DerivedData.noindex`;
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
- [ ] Update the `::error::` message at 509 and the inline comments that spell a
      path under either root (including the whole-line comment at 1273) so they
      name the new one; leave every message whose text names only a flag
      (`-archivePath`, `-derivedDataPath`) as it is.
- [ ] Confirm by hand that the two smoke-launch bodies still differ in the
      `APP=` line alone.
- [ ] Move the existing `ReleaseWorkflowTests` literals to the new paths: the CI
      smoke launch's `APP=`, the archive-launched `APP=`, and the three
      `build/release-assets` assertions (the notarization/staging split and the
      `ZIP=`/publish pair). Update every failure message and doc comment that
      spells one of the two roots; leave the two `-archivePath` *flag-name*
      ordering lookups untouched.
- [ ] Run `swift test` — must pass before Task 2.

### Task 2: `.gitignore`, `.swiftlint.yml`, and the pin that keeps the suffix

**Files:**
- Modify: `.gitignore`
- Modify: `.swiftlint.yml`
- Modify: `Tests/PisakaCoreTests/ReleaseWorkflowTests.swift`

- [ ] `.gitignore`: `DerivedData/` → `DerivedData.noindex/` and `build/` →
      `build.noindex/`. The old names are **not** kept as a second ignore line —
      after Task 1 nothing writes to them. Extend the two existing comment
      blocks with the second reason the paths are shaped this way: a local
      reproduction of a documented command drops these in the checkout root, and
      the `.noindex` suffix is the one name-level opt-out that keeps the bundles
      inside them from being surfaced as installed applications.
- [ ] `.swiftlint.yml`: `excluded:` names `build.noindex` and
      `DerivedData.noindex` instead of `build` and `DerivedData`. `Vendor` and
      `SourcePackages` are unchanged.
- [ ] Add a `// MARK: - The build output roots` section to
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
- [ ] Add the paired configuration assertions in the same section: `.gitignore`
      names `DerivedData.noindex/` and `build.noindex/` and names neither bare
      directory as an ignore entry; `.swiftlint.yml`'s `excluded:` block (read
      through `topLevelBlock(_:in:)`) equals its four documented entries **by
      set equality**, which pins the two new names and the two untouched ones at
      once.
- [ ] Write the rationale into that section's doc comment, once: application
      bundles are surfaced from any indexed directory, a name ending in
      `.noindex` is the one name-level opt-out, and the workflows' relative
      output paths are reproduced verbatim on developer machines — so the suffix
      is a property of the *names*, not of any one command. State what the pin
      cannot see (whether the fix works on a given machine is a runtime property
      of that machine's index; what is assertable is the name).
- [ ] Run `swift test` and `swiftlint --strict` — both must pass before Task 3.

### Task 3: The documents that spell the two roots

**Files:**
- Modify: `CLAUDE.md`
- Modify: `docs/RELEASING.md`
- Modify: `docs/architecture/core-services.md`

- [ ] `CLAUDE.md`'s Commands section: the release archive command's
      `-archivePath` becomes `build.noindex/Pisaka-macOS.xcarchive`. Nothing
      else in the surrounding comment changes.
- [ ] `docs/RELEASING.md`: the local archive repro command, the archive product
      path, the two DerivedData-Release-product mentions and the
      `build.noindex/release-assets/Pisaka-${VERSION}.zip` chain (the staging
      prose and the cask-hash prose) all follow. Add the rationale in one place
      — a short note where the reader first meets the name, at the local archive
      repro command — saying why the two roots carry the suffix and that the pin
      lives in `ReleaseWorkflowTests`. Do not restate it at the other sites.
- [ ] `docs/architecture/core-services.md`: the required-reason-API audit's
      `find` and `nm -u` command lines read out of `DerivedData.noindex/…`; the
      smoke-launch prose naming the DerivedData Release product follows.
- [ ] Re-grep `docs/architecture/style-lint.md` for the excluded-directory names
      to confirm it still names none (it does today); update it only if the grep
      says otherwise.
- [ ] Leave `Tests/PisakaCoreTests/DependencyPinTests.swift`'s doc comment as it
      is — it describes Xcode's own DerivedData under `~/Library`, a different
      directory — and leave `docs/plans/completed/**` as the historical record it
      is.
- [ ] Run `swift test` — must pass before Task 4.

### Task 4: Verify acceptance criteria

**Files:** none modified (verification only; any failure sends work back to the
task that owns the file)

- [ ] Record in the plan's Notes the acceptance grep and its output: `grep -rn`
      over `.github/workflows/ci.yml`, `.github/workflows/release.yml`,
      `.gitignore`, `.swiftlint.yml`, `CLAUDE.md`, `docs/RELEASING.md` and
      `docs/architecture/core-services.md` for `-derivedDataPath
      DerivedData[^.]`, `-archivePath build/`,
      `\bbuild/(release-assets|notarization|Pisaka-)` and `\bDerivedData/` —
      expected empty.
- [ ] Reproduce `ci.yml`'s macOS Release build command verbatim from the
      repository root (`xcodegen generate`, the package resolve, then the
      Release build with `-derivedDataPath DerivedData.noindex`) and confirm the
      product lands at `DerivedData.noindex/Build/Products/Release/Pisaka.app`.
      **This is the one place the plan deliberately builds inside the checkout
      root** — it is the reproduction the fix exists to make safe, and the
      output directory is deleted immediately afterwards. Budget for a long run:
      a Release build compiles the app and every linked dependency with
      whole-module optimization, which is why CI gives this job 45 minutes.
- [ ] With the product in place, run `mdfind -name Pisaka.app` and record that
      the reproduction's path is absent from the output, and
      `git status --porcelain` and record that it is empty. Record honestly in
      the Notes what this observation is worth: an absent path is consistent
      with the suffix working, and cannot on its own distinguish "skipped by
      name" from "not yet indexed" — the structural guarantee is the name, and
      the pin in Task 2 is what keeps it.
- [ ] Delete `DerivedData.noindex/` afterwards.
- [ ] Run the full gate set and record each result: `swift test`,
      `swiftlint --strict`, `xcodegen generate`, the macOS build, the iOS
      Simulator build, and `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka
      -destination 'platform=macOS' test`.

### Task 5: Update the index and the notes

**Files:**
- Modify: `CLAUDE.md` (only if the Tests section needs the new pin named)
- Modify: the plan file's Notes section

- [ ] If the new pin warrants a mention, add it to `CLAUDE.md`'s existing
      `ReleaseWorkflowTests` sentence rather than as a new paragraph — that
      suite's inventory is explicitly delegated to its own doc comments and
      `docs/RELEASING.md`, so the index gains at most a clause, not an essay.
- [ ] Record in the plan's Notes what this change is *not* proven by: `ci.yml`'s
      half is exercised end to end by the pull request's three green jobs, and
      that is the only end-to-end check available. `release.yml`'s half — the
      archive path, the notarization scratch directory, the staging directory,
      the appcast input, the publish upload and the cask hash — is exercised
      only by the next `v*` tag. Say so plainly; do not claim it was verified.
- [ ] Run `swift test` and `swiftlint --strict` one final time.

## Post-Completion (outside the agent's reach)

- Open the pull request and confirm CI is green on all three jobs — the test
  job, the macOS Release build with its smoke launch (which now launches out of
  `DerivedData.noindex`), and the iOS build.
- The release workflow's half stays unverified until the next tag push. The
  first tagged release after this change should be watched through the archive,
  notarization, staging and cask-bump steps specifically, since those are where
  the `build.noindex` prefix first runs for real.

## Notes

- To be filled during execution: the acceptance grep and its output, the local
  reproduction's product path, the `mdfind` and `git status --porcelain`
  observations, and each gate's result.
