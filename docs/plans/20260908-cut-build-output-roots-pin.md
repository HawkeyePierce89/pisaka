# Cut the build-output-roots pin back to its stated shape

## Overview

`ReleaseWorkflowTests`' `// MARK: - The build output roots` section is 1 505 lines
(3651–5155) for four rules the plan that introduced it described in a few lines each.
Roughly 500 of those lines are a hand-written shell parser and ~300 are tests of that
parser against shapes neither workflow writes. The whole parser exists to keep one
prose sentence in `release.yml` from being read as a command line.

This plan reverses that: reword the sentence, delete the parser, trim the matchers and
their self-test to the shapes the repository actually writes, and rewrite the doc
comments to describe what each rule reads and what it cannot see. What the four rules
pin, and the fact that they fail loudly on a stale spelling, does not change. The
section must end at **at most 250 lines** from its heading to the next `// MARK:`, and
that is a gate, not a target.

## Context

Files involved:

- `.github/workflows/release.yml` — line 509, the archive-step refusal whose `::error::`
  prose spells `-archivePath`. The one line the parser exists for.
- `Tests/PisakaCoreTests/ReleaseWorkflowTests.swift` — lines 3651–5155, the section.
- `.gitignore` — the `DerivedData/` and `build/` legacy-guard comments.
- `docs/RELEASING.md` — around line 108, the `rm -rf build DerivedData` note that already
  carries the full legacy-guard telling.
- `docs/architecture/style-lint.md` — its "One stated exception" paragraph about
  `excluded:` (must stay accurate; expected to need no edit).

Facts established by exploration:

- `release.yml:509` is the **only** active line in either workflow carrying a workflow
  annotation and one of the two scanned flag names on the same line. `release.yml:287`
  carries `base64 -i`, but no rule reads `-i`. So exactly one reword is needed, as the
  ticket predicted.
- The two other `-derivedDataPath` mentions in prose (`ci.yml:156`, `release.yml:839`) are
  whole-line comments, already dropped by `activeYAMLLines(of:)`.
- Every symbol the ticket names for deletion is private to this section: `commandHalf`,
  `substitutedShell`, `commandSubstitution`, `parameterExpansion`,
  `firstCommandSeparator`, `expansionOpened`, `openQuote`, `nestedScopeEnd`, `stringEnd`,
  `firstUnescapedQuote`, `annotationMarkers`, plus `closingQuote`. Zero uses outside
  lines 3651–5155; zero uses in any other file under `Tests/`.
- The section's four surviving rules and their helpers stay:
  `testEveryDerivedDataPathBuildsIntoANoIndexDirectory`,
  `testEveryArchivePathIsUnderANoIndexDirectory`,
  `testNoActiveWorkflowLineNamesABareBuildOutputRoot`,
  `testNoDocumentSpellsABareBuildOutputRoot`,
  `testTheIgnoreFileNamesTheNoIndexRootsAndTheLegacyGuards`,
  `testTheStyleAuthorityExcludesTheNoIndexRoots`,
  `testTheBareRootMatchersJudgeTheShapesTheyClaimTo`,
  `testAFlagValueIsReadAsThePathItNamesNotItsQuoting`,
  and the helpers `assertFlagValuesAreNoIndexed`, `assertNamesNoBareBuildOutputRoot`,
  `staleBuildOutputRootSpelling`, `shellTokens`, `pathNamed`, `ignoreEntries`.
- `testTheTwoSmokeLaunchesAreTheSameCheck` and `testTheReleaseLaunchesWhatItArchived` sit
  in a different MARK section and read a different step; line 509 is not in either
  smoke-launch body, so nothing there is touched.

Related patterns: assertions by mechanism over comment-stripped lines
(`activeYAMLLines(of:)` from `Tests/PisakaCoreTests/Support/YAMLLineMatching.swift`);
absence rules paired with a both-directions self-test so a matcher cannot rot green.

Dependencies: none.

## The one design decision this plan makes

**The checkout-root reference family stays, as a single alternation inside
`relativePathPrefix`, and the quote-closed spelling goes.** Keeping
`$GITHUB_WORKSPACE`/`$PWD`/`$(pwd)`/`${{ github.workspace }}` in front of a root costs one
`let` and one alternation and preserves real coverage — those are this checkout's own
output root written absolutely — whereas `closingQuote`, `pathNamed(by:)`'s reference
stripping and `shellTokens(of:)`'s expression closing-up all exist only for the
quote-closed spelling `"$GITHUB_WORKSPACE"/build/…`, which neither workflow nor any
document writes; that shape is recorded in the doc comment as deliberately unhandled
rather than parsed for.

## Development Approach

- **Testing approach**: the deliverable *is* test code, so each task ends by running
  `swift test` and, where a workflow or ignore file changed, confirming the affected rules
  still judge what they claim to.
- Complete each task fully — including its gate — before starting the next.
- The 250-line budget is checked at the end of every task that touches the section, not
  only at the end. A review remark inside this plan that would breach it is answered by
  rewording the input or by recording the shape as deliberately unhandled, never by
  growing a parser. Shapes no workflow in this repository writes are out of scope.
- Section length is measured with:
  `awk '/^    \/\/ MARK: - The build output roots$/{f=1} f{n++; if(n>1 && /^    \/\/ MARK: -/){print n-1; exit}}' Tests/PisakaCoreTests/ReleaseWorkflowTests.swift`

## Implementation Steps

### Task 1: Reword the one annotation

**Files:**
- Modify: `.github/workflows/release.yml`

- [x] Reword `release.yml:509`'s `::error::` prose so it names no flag: "check the archive
      path on the archive command line" in place of "check the `-archivePath` on the
      archive command line". Everything else about the line — the refusal, the `exit 1`,
      the `See docs/RELEASING.md.` tail — is unchanged.
- [x] Audit both workflows for a second active line carrying an annotation marker and
      either `-derivedDataPath` or `-archivePath`:
      `grep -n "::error::\|::warning::\|::notice::" .github/workflows/*.yml | grep -e -derivedDataPath -e -archivePath`
      Expect no remaining hit. Reword the same way if one exists.
- [x] Run `swift test --filter ReleaseWorkflowTests` — green with the section still in its
      current form, proving the reword breaks none of the existing rules.

### Task 2: Delete the parser; the flag-value rule reads active lines directly

**Files:**
- Modify: `Tests/PisakaCoreTests/ReleaseWorkflowTests.swift`

- [x] In `assertFlagValuesAreNoIndexed`, drop the `Self.commandHalf(of:)` call: tokenize
      each active line directly.
- [x] Delete `annotationMarkers`, `commandHalf(of:)`, `substitutedShell`,
      `commandSubstitution`, `parameterExpansion`, `firstCommandSeparator`,
      `expansionOpened`, `openQuote`, `nestedScopeEnd`, `stringEnd`, `firstUnescapedQuote`
      and their doc comments, and `testTheAnnotationRemovalKeepsTheCommandHalvesOfALine`
      in full.
- [x] Keep, unchanged in what they assert: the empty-values check, the
      occurrences-vs-values check, the `..` refusal, the `.noindex` suffix check and the
      root-equality check against `derivedDataRoot`/`archiveRoot`.
- [x] Reduce `shellTokens(of:)` to a whitespace split (the tab argument stays; the
      `${{ … }}` closing-up goes with the reference stripping in Task 3).
- [x] Confirm nothing in the file names an annotation marker any more:
      `grep -n "::error::\|::notice::\|::warning::\|annotation" Tests/PisakaCoreTests/ReleaseWorkflowTests.swift`
      returns nothing inside the section.
- [x] Run `swift test --filter ReleaseWorkflowTests`.

### Task 3: Trim the matchers, `pathNamed(by:)` and the two self-tests

**Files:**
- Modify: `Tests/PisakaCoreTests/ReleaseWorkflowTests.swift`

- [x] Fold the checkout-root family into `relativePathPrefix` as one alternation
      (`checkoutRootReference` may stay as its own `let` for readability); delete
      `closingQuote` and every use of it in `relativePathPrefix`,
      `staleBuildOutputRootSpelling` and `pathNamed`.
- [x] Reduce `pathNamed(by:)` to stripping surrounding quotes/backticks and a leading
      `./`; delete the reference-stripping branch and the `${{ … }}` closing-up in
      `shellTokens(of:)`.
- [x] Keep `staleBuildOutputRootSpelling(in:)` with its three matchers (two path regexes,
      one flag regex), path matchers first, and both absence rules
      (`testNoActiveWorkflowLineNamesABareBuildOutputRoot`,
      `testNoDocumentSpellsABareBuildOutputRoot`) exactly as they judge today, including
      the two loud-vacuity guards inside them.
- [x] Trim `testTheBareRootMatchersJudgeTheShapesTheyClaimTo`'s fixtures to the shapes the
      repository writes plus one representative of each deliberate refusal: stale —
      `-derivedDataPath DerivedData`, `APP="build/…"`, `./DerivedData/Build`, a document
      line naming `-archivePath build`, one `$GITHUB_WORKSPACE/build/…` and one
      `>build/report.txt`; live — the four `.noindex` spellings the workflows write,
      `~/Library/Developer/Xcode/DerivedData/…`, `"$RUNNER_TEMP/build/staging"`,
      `xcodebuild -scheme Pisaka build`, and a URL containing `/build/`. No line per
      hypothetical quoting style.
- [x] Trim `testAFlagValueIsReadAsThePathItNamesNotItsQuoting` to the cases that survive
      the reduced `pathNamed(by:)`: the quote/backtick strips, the `./` strip, the
      untouched unquoted value, and that a stale root stays stale however quoted. Delete
      the checkout-reference and `${{ … }}` cases.
- [x] Leave `testTheIgnoreFileNamesTheNoIndexRootsAndTheLegacyGuards` and
      `testTheStyleAuthorityExcludesTheNoIndexRoots` alone in what they assert (their doc
      comments are rewritten in Task 4).
- [x] Run `swift test --filter ReleaseWorkflowTests`; measure the section and record the
      running number.

### Task 4: Doc comments proportionate to the code, legacy-guard story told once

**Files:**
- Modify: `Tests/PisakaCoreTests/ReleaseWorkflowTests.swift`
- Modify: `.gitignore`
- Modify: `docs/RELEASING.md`

- [x] Rewrite the section's doc comments: the heading comment says what the suffix is and
      why it is a property of the names (keeping the "what this cannot see" paragraph, one
      short version); each rule gets a paragraph or two saying what it reads and what it
      cannot see. Delete every "the round after that" narrative — the completed plan's
      Notes hold that history — and every comment explaining the absence of a helper that
      no longer exists. Record the quote-closed checkout spelling as deliberately
      unhandled in one clause on `relativePathPrefix`.
- [x] The legacy-guard story: keep the full telling (bare entries kept beside the renamed
      ones; a rename un-ignores what an existing clone holds; the 22 816 files) in
      `docs/RELEASING.md` beside the `rm -rf build DerivedData` note — it already lives
      there at ~line 108; extend it only if a detail is lost from the other three sites.
- [x] Cut `.gitignore`'s two legacy-guard comments to one pointer sentence each, naming
      `docs/RELEASING.md` and not repeating the number.
- [x] Cut the same story in `testTheIgnoreFileNamesTheNoIndexRootsAndTheLegacyGuards`'s
      doc comment and in `testTheStyleAuthorityExcludesTheNoIndexRoots`'s to one pointer
      sentence in the section, again without the number. The assertion messages keep
      enough to be actionable, without the count.
- [x] Check `docs/architecture/style-lint.md`'s "One stated exception" paragraph is still
      accurate (it names `ReleaseWorkflowTests` and the MARK section, both of which
      survive) and update if the wording drifted.
- [x] `grep -rn "22 816" . --exclude-dir=.git --exclude-dir=docs/plans` must return
      `docs/RELEASING.md` alone.
- [x] Run `swift test --filter ReleaseWorkflowTests`; measure the section again.

### Task 5: Prove the pin still fails, and record the numbers

**Files:**
- Modify (temporarily, then restore): `.github/workflows/ci.yml`

- [x] Measure the section with the `awk` command above; it must be ≤ 250. If it is not,
      cut doc comments and assertion prose further — never by re-introducing a helper.
      Record the number.
- [x] Record the deletion grep:
      `grep -n "commandHalf\|substitutedShell\|commandSubstitution\|parameterExpansion\|firstCommandSeparator\|expansionOpened\|openQuote\|nestedScopeEnd\|stringEnd\|firstUnescapedQuote\|annotationMarkers" Tests/PisakaCoreTests/ReleaseWorkflowTests.swift`
      must return nothing.
- [x] Inject `-derivedDataPath DerivedData` into an active line of `ci.yml`, run
      `swift test --filter ReleaseWorkflowTests`, and confirm both
      `testEveryDerivedDataPathBuildsIntoANoIndexDirectory` and
      `testNoActiveWorkflowLineNamesABareBuildOutputRoot` fail with a message naming the
      stale root. Restore `ci.yml` exactly (`git diff` clean for that file) and re-run.
- [x] Confirm `testTheTwoSmokeLaunchesAreTheSameCheck` is green and its two step bodies
      were not touched (`git diff` over `release.yml` shows the one reworded prose line
      and nothing else).
- [x] Record all three results (line count, grep, injection with the failing test names)
      in the plan's Notes section.

### Task 6: Verify acceptance criteria

- [ ] `swift test` — full Core suite green.
- [ ] `swiftlint --strict` from the repository root — clean.
- [ ] `xcodegen generate`.
- [ ] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' build`
      (derived data outside the repository root, per the local-build convention).
- [ ] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build`.
- [ ] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' test`
      — the app-layer bundle.
- [ ] Re-confirm the section line count after any late edit.

### Task 7: Update documentation

- [ ] `docs/RELEASING.md` — the legacy-guard telling is the single full account; the
      `// MARK: - The build output roots` description stays accurate about what the
      section reads.
- [ ] `docs/architecture/style-lint.md` — the `excluded:` "One stated exception"
      paragraph accurate.
- [ ] `CLAUDE.md` — the `ReleaseWorkflowTests` index entry already says "full inventory in
      that suite's doc comments and `docs/RELEASING.md`"; confirm it needs no change and
      leave it alone if so.
- [ ] No product or brand name introduced anywhere: code, comments, tests, docs, the plan,
      the commit messages.

## Post-Completion (manual)

- Open a pull request and confirm CI is green on all three jobs (`swift test`, the macOS
  job, the iOS build) plus the independent `lint` job.

## Notes

**Section line count** — the `awk` measurement over
`Tests/PisakaCoreTests/ReleaseWorkflowTests.swift` returns **250**, at the plan's ≤ 250
gate (down from 1 505).

**Deletion grep** — 
`grep -n "commandHalf\|substitutedShell\|commandSubstitution\|parameterExpansion\|firstCommandSeparator\|expansionOpened\|openQuote\|nestedScopeEnd\|stringEnd\|firstUnescapedQuote\|annotationMarkers" Tests/PisakaCoreTests/ReleaseWorkflowTests.swift`
returns **nothing** (exit 1). Every parser symbol the plan named is gone from the file.

**`grep -rn "22 816"`** — returns `docs/RELEASING.md` alone (recorded in Task 4).

**Stale-spelling injection** — `.github/workflows/ci.yml:71` was temporarily rewritten
from `-derivedDataPath DerivedData.noindex` to `-derivedDataPath DerivedData`. Exactly the
two expected tests failed, each naming the stale root:

- `testEveryDerivedDataPathBuildsIntoANoIndexDirectory` — two assertions, at
  `ReleaseWorkflowTests.swift:3697`: "`-derivedDataPath DerivedData` must sit under a
  `.noindex` directory…" and "…builds into `DerivedData`, but `.gitignore` and
  `.swiftlint.yml` name `DerivedData.noindex`".
- `testNoActiveWorkflowLineNamesABareBuildOutputRoot` — at `ReleaseWorkflowTests.swift:3716`:
  "ci.yml spells the stale build output root `-derivedDataPath DerivedData` in
  “-derivedDataPath DerivedData”… Use `-derivedDataPath DerivedData.noindex`."

No other test failed; `testNoDocumentSpellsABareBuildOutputRoot` and
`testEveryArchivePathIsUnderANoIndexDirectory` stayed green, as the injection was a
workflow flag value. `ci.yml` was restored with `git checkout --`; `git diff` for that file
is clean, and the re-run is **66 tests, 0 failures**.

**Smoke launches untouched** — `testTheTwoSmokeLaunchesAreTheSameCheck` passes, and
`git diff master...HEAD -- .github/workflows/release.yml` is the single reworded `::error::`
prose line at 509 (`-archivePath` → `archive path`) and nothing else.
