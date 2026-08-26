# Close the outstanding acceptance-review findings (deflake + EditorConfig part 3)

## Overview

Seven findings left open by two acceptance reviews (the test-deflake branch and
EditorConfig part 3), collected into one pass on top of current `master`
(`553e9f2`). One piece of lost test coverage is restored, one doc comment that
under-sells its own staging is rewritten, one falsified `project.yml` comment is
restored to the documented truth, and four small documentation/hygiene items are
settled (a wrong count, two noise blank lines, a wholesale JSON re-serialization,
and an unverified verification record).

No product behavior changes anywhere. The only file under `Sources/` that may
change is `SyntaxLanguageConfiguration.swift`, and only by deleting two blank
lines. If restoring the guard coverage surfaces an actual product defect, the
work stops with a report instead of a code change.

## Context

- Files involved:
  - `Tests/PisakaCoreTests/LSPDiagnosticsRoutingTests.swift` — the suite header's
    `closeStream()` audit inventory, the restaged
    `testAReplacementServersPushesSurviveThePredecessorsClear` (line 533), and
    the new absence-style sibling.
  - `Sources/PisakaCore/LSPWorkspace.swift` — read-only reference:
    `attachNotificationConsumer` (line 1141, the `filed !== session` guard at
    1158), `noteDeath` (1086), `liveSession` (871).
  - `Tests/PisakaCoreTests/LeetCodeCatalogTests.swift` — the doc comment above
    `testASessionReplacedWhileTheCacheIsEncodedIsNeverWritten` (line 1344) and
    the suite header's audit inventory (line 24).
  - `Sources/PisakaCore/LeetCodeCatalog.swift` — read-only reference:
    `writeCache` (line 583) and its detached-encode `await …value` (line 590).
  - `project.yml` — the `TreeSitterSql` package comment (lines 168-171).
  - `Vendor/TreeSitterSql/VENDORED.md` — the authority for that comment.
  - `docs/architecture/core-intelligence.md` — line 685-688, the EditorConfig
    keyword paragraph.
  - `Sources/PisakaCore/LanguageKeywords.swift` — read-only reference: the
    `editorConfig` list (18 entries: 9 property names + 9 value literals) and its
    correct doc comment.
  - `Sources/Pisaka/SyntaxLanguageConfiguration.swift` — the two blank lines in
    `markdownInlineConfiguration()` (after the cache early-return and after the
    `guard … else { return nil }`).
  - `Resources/Licenses/licenses.json` — re-serialized wholesale by part 3
    (210 insertions / 201 deletions for one added entry).
  - `Vendor/TreeSitterEditorconfig/VENDORED.md` — the "Verification / Last run"
    record and its own re-run recipe.

- Related patterns:
  - Staging discipline: causal rendezvous via `waitFor`; `settle()` (a 150 ms
    sleep) reserved for absence assertions. Both suites carry a
    "**Staging Discipline**" header with a per-test audit inventory that must
    stay in step with the file.
  - The documented crash contract: the request that notices a dead session
    answers `nil` and the *next* one restarts it
    (`testAWriteFailureLeavesTheSessionTerminalAndTheNextRequestRestartsIt`),
    so an unwaited replacement open must tolerate a `nil` first `prepare`.
  - Format-churn reasoning already applied to `Package.resolved` in the
    repository conventions — applied here to `licenses.json`.

- Dependencies: none new. The `VENDORED.md` re-run harness needs the already
  present `SourcePackages/checkouts/{SwiftTreeSitter,tree-sitter}`.
- Baseline for the `licenses.json` comparison: `553e9f2^` (`ca5dcc6`).

## Development Approach

- **Testing approach**: Regular. Six of the seven items are comments,
  documentation or formatting; the one code item *is* a test.
- Because the ticket forbids product-code change, most tasks have no new test to
  write. Each such task instead names the **existing** suite that must stay green
  and be re-run (`LicenseCoverageTests`, `DependencyPinTests`,
  `VendoredGrammarQueryTests`, `LanguageKeywordsTests`), and the whole suite must
  pass before the next task starts.
- Where a task changes a verdict recorded in a suite-level doc comment, that
  header is updated in the same task.
- Complete each task fully before moving to the next.

## Implementation Steps

### Task 1: Restore the notification consumer's replacement-guard coverage

**Files:**
- Modify: `Tests/PisakaCoreTests/LSPDiagnosticsRoutingTests.swift`

- [x] Read `LSPWorkspace.attachNotificationConsumer` and `noteDeath` and write
      down which interleavings can reach the `filed !== session` guard, given
      that every replacement path cancels the predecessor's consumer
      (`notificationTasks[key]?.cancel()`) in its synchronous prefix before the
      replacement is filed, and that the consumer checks `!Task.isCancelled`
      before the guard. This conclusion is what the new doc comment must state —
      claim only coverage that actually happens.
      Finding: neither legal interleaving reaches the guard's true branch —
      every slot-emptying/replacement site cancels the incumbent consumer
      synchronously first, so a cancelled task exits at `!Task.isCancelled`
      before the identity check; in the unwaited interleaving the check is
      simply false (the slot still holds the consumer's own session). Stated
      in the new doc comment.
- [x] Add an absence-style test beside the restaged sibling (suggested name
      `testAReplacementOpenedWithoutWaitingIsNotClearedByThePredecessor`):
      open `mainFile`, push `"old"`, wait for it (`waitFor`, liveness first);
      call `harness.latest.closeStream()` and **do not** wait for the
      predecessor's clear; open the replacement immediately, tolerating a `nil`
      first `prepare` per the documented contract (call `prepare` again and
      require the second to answer, asserting `harness.launches.count == 2`);
      push `"new"` through the replacement's transport and `waitFor` it; then
      `settle()` and assert that no `.cleared` event follows the last
      `.published` one.
- [x] Write the doc comment: what is staged, why the assertion is an absence one
      (`settle()`'s stated purpose), both legal interleavings and why the test
      passes deterministically under each, which of them can reach the guard,
      that the guard cannot be forced without a product-code seam the ticket
      forbids, and the honest reachability finding from the first step.
- [x] Cross-reference the pair: add a pointer from the restaged
      `testAReplacementServersPushesSurviveThePredecessorsClear` doc comment to
      the new test (its last paragraph currently records the gap this test
      closes) and back, so the two read as one story.
- [x] Extend the suite header's "Audit inventory of `closeStream()` sites" with
      the new site and its staging verdict (close-then-`open`, unwaited,
      absence-asserted).
- [x] Optionally, to make the reachability finding evidence-based rather than
      argued: temporarily instrument the guard locally (a counter or print inside
      `attachNotificationConsumer`), run the new test repeatedly, record what was
      observed, then revert the instrumentation. Nothing of it may be committed;
      `git status` must show `Sources/` untouched afterwards.
      (skipped - explicitly optional; finding derived by reading the source,
      `Sources/` untouched)
- [x] Run `swift test --filter LSPDiagnosticsRoutingTests` — green.
- [x] Run the new test **≥100 times** in a loop
      (`for i in $(seq 1 100); do swift test --filter
      LSPDiagnosticsRoutingTests/testAReplacementOpenedWithoutWaitingIsNotClearedByThePredecessor
      || break; done`, ~5 s per run), and record the iteration count and the
      zero-failure result in the task log.
      Recorded: 100/100 iterations, 0 failures.
- [x] Run `swift test` — the whole suite must pass before Task 2.
      3683 tests, 0 failures.

### Task 2: State the catalog test's structural guarantee

**Files:**
- Modify: `Tests/PisakaCoreTests/LeetCodeCatalogTests.swift`

- [x] Rewrite the doc comment above
      `testASessionReplacedWhileTheCacheIsEncodedIsNeverWritten` (currently
      "Staged empirically" / "`await` is a potential rather than guaranteed
      yield"): awaiting the detached encode's `value` from main-actor-isolated
      code is a call to a `nonisolated async` member, so it *always* leaves the
      actor and re-enqueues a main-actor job to return — the sign-out job the
      clock hook enqueued earlier is therefore guaranteed to run before the write
      continuation resumes.
- [x] Keep the honest half: `Gate` still cannot hold this window (it would block
      the actor and freeze the sign-out), and the clock hook remains the right
      staging seam.
- [x] Update the suite header's audit inventory line for this test so the verdict
      it records matches the rewritten comment.
- [x] Run `swift test --filter LeetCodeCatalogTests` — green (the test body is
      unchanged; this is a comment-only edit).
      51 tests, 0 failures.

### Task 3: Restore the true SQL vendoring rationale in `project.yml`

**Files:**
- Modify: `project.yml`

- [x] Replace the ABI-headers/version-pin story above `TreeSitterSql:` with the
      two documented reasons from `Vendor/TreeSitterSql/VENDORED.md` (the tagged
      tree ships no generated `src/parser.c`, so the manifest's `sources:` names
      a file that does not exist; and the manifest is a hard SwiftPM error
      through its test target's undeclared `SwiftTreeSitter` product), keeping
      the pointer to `VENDORED.md`. The pre-part-3 wording at `553e9f2^` is a
      correct starting point.
- [x] Confirm no other `project.yml` content changed
      (`git diff -- project.yml` is that comment block alone).
- [x] Run `swift test --filter DependencyPinTests` and
      `swift test --filter ReleaseMetadataTests` — both read `project.yml` and
      must stay green.

### Task 4: Correct the EditorConfig value-literal count in the architecture doc

**Files:**
- Modify: `docs/architecture/core-intelligence.md`

- [x] Change "the 9 property names plus the 8 identifier-shaped value literals"
      to 9, matching `LanguageKeywords.editorConfig` (18 entries) and its own
      correct doc comment.
      Done: paragraph now reads "the 9 property names plus the 9 identifier-shaped value literals".
- [x] Name `latin1` explicitly as the one identifier-shaped charset value that
      *is* included, in the same paragraph that explains why the hyphenated
      charset values (`utf-8`, `utf-16be`, …) are absent.
      Done: "`latin1` is the one charset value that is included, being the only identifier-shaped spelling among them".
- [x] Run `swift test --filter LanguageKeywordsTests` — green (the list itself is
      untouched; this pins that the doc now matches the code).
      16 tests, 0 failures.

### Task 5: Revert the two noise blank lines

**Files:**
- Modify: `Sources/Pisaka/SyntaxLanguageConfiguration.swift`

- [x] Delete the blank line after the cache early-return and the blank line after
      the `guard … else { return nil }` in `markdownInlineConfiguration()`,
      restoring the pre-part-3 shape. Logic untouched.
      Done: both blank lines removed; the function now matches `553e9f2^` byte-for-byte.
- [x] Confirm `git diff -- Sources/` shows exactly those two deletions and
      nothing else.
      Confirmed: only `-` lines for the two blanks; against `553e9f2^` the file
      differs only by part 3's legitimate editorconfig import + switch case.
- [x] Run `swiftlint --strict` from the repository root — clean.
      0 violations, 0 serious in 397 files.

### Task 6: Undo the wholesale re-serialization of `licenses.json`

**Files:**
- Modify: `Resources/Licenses/licenses.json`

- [ ] Restore the pre-part-3 file
      (`git show 553e9f2^:Resources/Licenses/licenses.json`)
      and re-add the single `TreeSitterEditorconfig` notice entry in that file's
      own key-spacing style (`"id" : "…"`), in the position part 3 put it (last
      in `notices`, after `libgit2`), with the same six field values.
- [ ] Verify `git diff 553e9f2^ -- Resources/Licenses/licenses.json` shows
      exactly one added entry and no reformatted lines.
- [ ] Run `swift test --filter LicenseCoverageTests` — green, the suite itself
      unchanged.

### Task 7: Make the vendored grammar's verification record honest

**Files:**
- Modify: `Vendor/TreeSitterEditorconfig/VENDORED.md`

- [ ] Actually run the verification by the file's own recipe: a throwaway SwiftPM
      package outside the repository depending on
      `Vendor/TreeSitterEditorconfig`, `SourcePackages/checkouts/SwiftTreeSitter`
      and `SourcePackages/checkouts/tree-sitter`; build the `Language`, compile
      `queries/highlights.scm` with `Query(language:data:)` (a compile failure is
      the loud version of the app's silent plain-text fallback), parse both
      fixtures, print every `(capture name, captured text)` pair by position and
      every uncaptured offset, and run each observed capture name through
      `SyntaxTokenKind(captureName:)`.
- [ ] Compare the observed pairs against both tables in the file. If they match,
      update the "Last run" paragraph with the run's date, what was executed, and
      the observed result — including the uncaptured-character metric as actually
      measured (state whether the zero count is over non-newline or
      non-whitespace characters, and correct the wording if the run contradicts
      it). Delete the throwaway package.
- [ ] If the run contradicts a table row (a capture that does not fire, an
      unexpected kind, a non-zero uncaptured count), **stop and report** rather
      than adjusting the tables or touching product code — that is a highlighting
      defect, which the ticket puts out of scope.
- [ ] Run `swift test --filter VendoredGrammarQueryTests` — the automated static
      half must stay green.

### Task 8: Verify acceptance criteria

- [ ] `swift test` — full suite green.
- [ ] `swiftlint --strict` from the repository root — clean.
- [ ] `xcodegen generate`, then
      `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' build`.
- [ ] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build`.
- [ ] `git diff --stat` review: no file under `Sources/` changed except the two
      blank-line deletions in `SyntaxLanguageConfiguration.swift`; `project.yml`
      changed only in the SQL comment; `licenses.json` diffs against `553e9f2^`
      as one added entry.
- [ ] Re-state in the task log: the new LSP test's iteration count and result,
      and the `VENDORED.md` run's date and result.

### Task 9: Update documentation

- [ ] Confirm `CLAUDE.md` needs no change (no new file, no changed invariant, no
      changed suite responsibility) and record that conclusion.
- [ ] Confirm `docs/architecture/core-lsp.md`'s D33 paragraph (the stream-finish
      clear and its replacement check) still describes what the tests now assert;
      adjust only if Task 1's reachability finding contradicts it.
- [ ] Confirm no other architecture doc references the corrected count, the SQL
      comment or the `licenses.json` formatting.
