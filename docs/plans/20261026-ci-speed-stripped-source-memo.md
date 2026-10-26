# CI speed: read and strip the sources once per test process; build jobs stop waiting on the Core suite

## Overview

Two changes that don't depend on each other.

1. Every source-gating suite gets the text of a repository Swift file from one shared, lock-guarded reader in `Tests/PisakaCoreTests/Support/`. Each file is read once and stripped once per test process. The walk of a source directory is also done once. Today nineteen test files each walk `Sources/`, re-read files and re-run `LSPSourceGatingTests.strippingCommentsAndStringLiterals(_:)` in every test. `ChromeThemeSourceGatingTests` reaches the stripper from 94 sites. This costs about 8.5 of the `test` job's 10.5 execution minutes on CI.
2. The stripper is rewritten so it no longer allocates two arrays on every character. Its output stays byte-identical, and a new contract test pins its behaviour.
3. `build-macos` and `build-ios` in `ci.yml` drop `needs: test`. The run's wall time becomes the longest job instead of `test` plus `build-macos`.

Assertions, gated sets, rule counts, failure-message text, inventories and `allCases` comparisons do not change. `release.yml` stays byte-identical.

## Context

- Files involved:
  - New: `Tests/PisakaCoreTests/Support/RepositorySources.swift`, `Tests/PisakaCoreTests/SourceStripperContractTests.swift`, `Tests/PisakaCoreTests/RepositorySourcesTests.swift`
  - Stripper (stays where it is, rewritten in place): `Tests/PisakaCoreTests/LSPSourceGatingTests.swift`, `static func strippingCommentsAndStringLiterals(_:)`
  - Suites that move to the reader (the nineteen): `BottomPanelSourceGatingTests`, `ChromeThemeSourceGatingTests`, `ChromeThemeTests`, `DatabaseViewerSourceGatingTests`, `DrawDirtyRectSourceGatingTests`, `FoldingSourceGatingTests`, `GitCLIArgumentSourceGatingTests`, `GitHubSourceGatingTests`, `LeetCodeAccountSourceGatingTests`, `LibGit2FetchSourceGatingTests`, `LocalHistorySourceGatingTests`, `LSPSourceGatingTests`, `MainWindowFrameSourceGatingTests`, `MarkdownPreviewSourceGatingTests`, `MenuShortcutUniquenessTests`, `ReleaseMetadataTests`, `SparkleSourceGatingTests`, `WelcomeShortcutPinTests`, `ZoomSourceGatingTests`
  - CI: `.github/workflows/ci.yml`. `.github/workflows/release.yml` is not touched.
  - Docs: `CLAUDE.md` (Commands section's CI sentence, Tests section's Support helper list). `docs/RELEASING.md` is checked only.
- Related patterns:
  - Today the walkers are near-copies: `FileManager.default.enumerator(at:includingPropertiesForKeys: nil)`, filtered to `.swift`, some sorted and some not. Root is derived from `#filePath` with three `deletingLastPathComponent()` calls. A file in `Support/` needs four.
  - Each walker has its own nil-enumerator handling (`XCTUnwrap` / `guard … XCTFail`) and its own "found no Swift sources" assertion, with suite-specific messages.
  - Support helpers are enums or small types with a doc comment that serves as their own inventory (`XcodePin.swift`, `YAMLLineMatching.swift`).
  - Package is swift-tools 5.9, language mode 5, so there is no strict-concurrency checking. The test tree's `.swiftlint.yml` relaxes `file_length`, `type_body_length` and `function_body_length`.
- Constraints found while exploring that shape the design:
  - The comment-only scanner `GitHubSourceGatingTests.strippingComments(_:)` keeps string literals. It is called from ChromeTheme (9 sites), GitCLIArgument (2), LeetCodeAccount (2), MarkdownPreview (2), MenuShortcutUniqueness (1) and WelcomeShortcutPin (1).
  - `ChromeThemeSourceGatingTests.testTheHeaderNamesEveryLiteralKeepingReading` finds the literal-keeping readings by the literal text `GitHubSourceGatingTests.strippingComments(` inside each test body. It holds that set equal to the header's stated-exceptions paragraph.
  - So the comment-only scanner stays a local function and is not a reader mode. Its callers keep spelling the call in their test bodies and apply it to raw text served by the reader. It is not merged into the full stripper and not made faster.
  - Several ChromeTheme meta-tests read the suite's own file through `URL(fileURLWithPath: #filePath)`. The reader can serve those too, because the path is under the repository root.
  - No test pins `needs: test` on ci.yml's build jobs. `ReleaseWorkflowTests` pins `needs: test` only on release.yml's `release` job. `LintConfigurationTests` pins only that the lint job has no `needs:`. The job names `build-macos` / `build-ios` / `lint` / `test` appear in `GitHubAPITests` and `PullRequestModelTests` only as fixture data and do not change.
  - `docs/RELEASING.md` mentions ci.yml jobs at about lines 457, 484, 763 and 794. None of them says the build jobs wait for `test`. `docs/architecture/style-lint.md` (lint job only) is unaffected.
- Dependencies: none (Foundation + XCTest only).

## Design decisions (resolved here, not during execution)

- **Name and shape.** `enum RepositorySources` in `Support/RepositorySources.swift`, with this surface:
  - `static let root: URL`, the repository root from `#filePath`.
  - `static func url(_ relativePath: String) -> URL`.
  - `static func swiftFiles(under relativeDirectory: String = "Sources") -> [URL]?`. Returns `nil` when the enumerator cannot be created, so each caller keeps its own `XCTUnwrap` / `guard` message and its own "found no Swift sources" assertion. Results are sorted by path.
  - `static func raw(_ url: URL) throws -> String` and `raw(at relativePath: String)`.
  - `static func stripped(_ url: URL) throws -> String` and `stripped(at relativePath: String)`.
  - Two `internal` counters, `readCount(of:)` and `stripCount(of:)`. They exist so the reader's tests can check "at most once" by counting work instead of timing it.
- **Memo key.** The repository-relative path. A URL is turned into its key by removing the root's standardized path as a prefix. A path outside the root (none exists today) falls back to its absolute standardized path. Walks are keyed by the relative directory.
- **Thread safety.** One private `final class` holds the dictionaries behind an `NSLock`. The lock is held across read and strip, so each key is computed at most once even when asked for concurrently. Internal helpers run with the lock already held; nothing locks twice. No unguarded mutable dictionary exists.
- **Failures are not memoized.** A read that throws rethrows the same `String(contentsOf:encoding: .utf8)` error on every call. A nil enumerator is not cached. A test that fails today on a missing file fails the same way afterwards.
- **Per process only.** Nothing is written to disk. The memo lives in static storage and is gone when the process ends.
- **Two modes.** Stripped is the default. Raw is only for readings whose subject is a literal; these keep stating their reason where they do today. The comment-only scanner is applied by the caller over `raw(…)` and is deliberately not a mode, for the meta-test reason above.
- **The stripper stays in `LSPSourceGatingTests`** under its current name, so every doc comment and CLAUDE.md citation still points at something that exists. The reader calls it, and after this work there is exactly one full stripper.
- **Rewrite stays at `Character` granularity.** `Array(source)` of `Character` is kept. Only the needle comparison changes: in-place element comparison instead of allocating `Array(text)` and an `Array` slice per call. The result gets `reserveCapacity`. Grapheme-cluster semantics are why the output can stay byte-identical: `"\r\n"` is one `Character` that is not `"\n"`, and a quote followed by a combining mark is not `"\""`. A UTF-8 or UTF-16 rewrite would change the output.
- **Suites keep thin private wrappers.** Wrappers named `swiftSources()`, `code(of:)`, `code(ofFileNamed:under:)`, `read(_:)`, `source(of:)` and so on keep their names, their assertions and their messages; only their bodies delegate to the reader. Call sites of the form `LSPSourceGatingTests.strippingCommentsAndStringLiterals(try X.read(url))`, where the argument is exactly one file's text, become `try RepositorySources.stripped(url)` or the suite's own `code(of:)`. Stripper calls on composed or sliced strings, not whole files, stay direct calls.
- **One accepted observable delta.** Walks that are unsorted today become path-sorted. Single-offender failure messages are unchanged. Offender lists built in walk order, where the old order was the filesystem's unspecified one, now come out in path order.
- **Non-Swift reads are not migrated.** Markdown, YAML and plist reads in these suites stay as they are. The reader can serve raw text of any repository path, but the ticket's subject is source reads.
- **No new pin for the absent `needs:` on the build jobs.** The ticket asks for `LintConfigurationTests` and `ReleaseWorkflowTests` to pass unchanged. A re-added `needs: test` makes CI slower but not wrong. The ci.yml comment carries the reason.

## Development Approach

- **Testing approach**: TDD for the stripper. Its contract test is written and green against the current implementation before the rewrite. Regular for the reader.
- Complete each task fully before moving to the next; `swift test` must pass before the next task.
- Every `xcodebuild` (none expected) would use `~/Library/Developer/Xcode/DerivedData/pisaka-build`.
- No brand names or references to other editors anywhere.
- **CRITICAL: every task MUST include new/updated tests**
- **CRITICAL: all tests must pass before starting next task**

## Implementation Steps

### Task 1: Baseline measurements and the stripper's contract test

**Files:**
- Create: `Tests/PisakaCoreTests/SourceStripperContractTests.swift`
- Modify: this plan file (Notes section)

- [x] On the unmodified tree, run `swift test 2>&1 | tee /tmp/ci-speed-before.log` and record in Notes:
  - the overall `Executed N tests` line;
  - the `Test Suite '<name>' passed … Executed … in X seconds` lines for `ChromeThemeSourceGatingTests`, `MarkdownPreviewSourceGatingTests`, `FoldingSourceGatingTests`, `LeetCodeAccountSourceGatingTests`, `ZoomSourceGatingTests`, `MenuShortcutUniquenessTests`, `GitHubSourceGatingTests`.
- [x] Record the three hand-break baseline messages. For each one, insert the line, run the filtered test, record the failure message text (the part after `failed - `; the `file:line:` prefix may move later, the message must not), then `git checkout -- <file>`:
  - Folding: insert `let autosave = 0` right before the final `#endif` of `Sources/Pisaka/FoldController.swift`. Run `swift test --filter FoldingSourceGatingTests/testTheFoldLayerNamesNoWriterGate`.
  - Markdown: insert `let localChanges = 0` right before the final `#endif` of `Sources/Pisaka/MarkdownPreviewController.swift`. Run `swift test --filter MarkdownPreviewSourceGatingTests/testTheFeatureNamesNoWriterGate`.
  - ChromeTheme: insert `let probe = Color.red` right before the final `#endif` of `Sources/Pisaka/TabStripView.swift`. Run `swift test --filter ChromeThemeSourceGatingTests/testNoGatedFileNamesASystemSemanticColor`.
- [x] Confirm `git status` is clean after the three restores.
- [x] Write `SourceStripperContractTests`, with fixtures as Swift raw-string literals (`#"""…"""#`), so no fixture file and no `exclude:` change. Each case asserts the exact expected output string. The cases:
  - `//` line comments, with the newline kept;
  - a `/* */` block comment and a nested `/* /* */ */` block comment spanning lines, with newlines kept and nothing else;
  - an ordinary literal with escaped quotes (`"a \"b\" c"`) removed whole;
  - a multi-line `"""` literal removed, with its newlines kept;
  - an interpolation `"x \(y) z"` dropped together with the literal around it;
  - `//` inside a literal not starting a comment;
  - the unterminated-literal bail-out: a line with a lone `"` returns to code at the newline, and the next line survives;
  - newlines kept through every construct, so line counts match the input.
- [x] Run `swift test --filter SourceStripperContractTests` green against the current, unmodified stripper, then run the full `swift test`.

### Task 2: Rewrite the stripper for speed, byte-identical

**Files:**
- Modify: `Tests/PisakaCoreTests/LSPSourceGatingTests.swift`
- Temporary (created and deleted inside this task): `Tests/PisakaCoreTests/StripperEquivalenceCheck.swift`

- [x] Before editing, copy the current `strippingCommentsAndStringLiterals` body verbatim into the temporary file as a private `legacyStrip(_:)`.
- [x] In the same temporary file, add one test that:
  - walks every `.swift` file under `Sources/`, `Tests/` and `Vendor/`, plus `Package.swift`, skipping any path containing `/.build/`;
  - asserts `LSPSourceGatingTests.strippingCommentsAndStringLiterals(text) == legacyStrip(text)` for each file;
  - prints the number of files compared.
- [x] Rewrite the stripper as decided above: same `State` enum, `Character` array kept, no per-call allocation in the needle check, `reserveCapacity` on the result. Behaviour stays exactly the same, including `\\` skipping two characters, including at end of input.
- [x] Run `swift test --filter StripperEquivalenceCheck` and record in Notes the command, the file count and the green result. Then delete `StripperEquivalenceCheck.swift`. It must not be committed, because two strippers must not coexist.
- [x] Run `swift test --filter SourceStripperContractTests` green, then the full `swift test`.

### Task 3: The shared reader

**Files:**
- Create: `Tests/PisakaCoreTests/Support/RepositorySources.swift`
- Create: `Tests/PisakaCoreTests/RepositorySourcesTests.swift`

- [x] Implement `RepositorySources` with the surface, key, lock, failure and mode rules stated in Design decisions.
- [x] Write the doc comment as its own inventory:
  - what is memoized: the walk, raw text and stripped text;
  - the key;
  - the `NSLock` held across compute, and why: at most once per process, and CLAUDE.md's two-threads-in-one-`Dictionary` warning;
  - that failures are not memoized;
  - per process, never on disk;
  - the two modes, with the rule for choosing between them;
  - why the comment-only scanner is applied by callers over raw text and is not a mode (the literal-keeping inventory check finds those readings by the call's spelling);
  - that it matches the class's conventions: stripped text by default, and a literal-keeping reading states its reason at its site.
- [x] Tests in `RepositorySourcesTests`:
  - `stripped(at:)` equals the stripper applied to `raw(at:)` for a real file (e.g. `Sources/PisakaCore/PisakaCore.swift`);
  - `raw(at:)` equals `String(contentsOf:)` of the same file;
  - asking 64 times through `DispatchQueue.concurrentPerform` for one file's stripped text gives identical results, and `readCount(of:)` and `stripCount(of:)` for that key are both exactly 1 afterwards. This holds whatever earlier tests in the process asked for, because "at most once" is the property;
  - `swiftFiles(under: "Sources")` is non-empty, path-sorted, contains only `.swift` files, and two calls return equal arrays;
  - a missing path throws from `raw(at:)` on two consecutive calls, so failures are not cached;
  - `url(_:)` resolves to an existing `Package.swift` at the root.
- [x] Run the full `swift test`.

### Task 4: Move the heavy suites to the reader

**Files:**
- Modify: `ChromeThemeSourceGatingTests.swift`, `ChromeThemeTests.swift`, `MarkdownPreviewSourceGatingTests.swift`, `FoldingSourceGatingTests.swift`, `ZoomSourceGatingTests.swift`, `LeetCodeAccountSourceGatingTests.swift`, `MenuShortcutUniquenessTests.swift`, `GitHubSourceGatingTests.swift`, all under `Tests/PisakaCoreTests/`

- [x] In each suite, the walker and read helpers delegate to `RepositorySources`, keeping their names, assertions and messages. Whole-file stripping call sites go through `RepositorySources.stripped`, either directly or through the suite's `code(of:)`.
- [x] Literal-keeping readings stay `GitHubSourceGatingTests.strippingComments(<raw text from the reader>)`, spelled in the test body as today.
- [x] `strippingComments(_:)` itself is unchanged.
- [x] In ChromeTheme, its `testTheHeaderNamesEveryLiteralKeepingReading` still finds the same set.
- [x] No gated set, rule count, message or doc-comment inventory is edited. Where a suite's doc comment describes how the suite reads (for example "reads `Sources/` through `#filePath`"), it is still true, because the reader derives the root from `#filePath`. Any sentence that a migrated helper's own name made untrue is corrected, and only that.
- [x] Run `swift test` for each migrated suite as it is done, then the full `swift test`. The test count equals Task 3's.

### Task 5: Move the remaining suites to the reader

**Files:**
- Modify: `BottomPanelSourceGatingTests.swift`, `DatabaseViewerSourceGatingTests.swift`, `DrawDirtyRectSourceGatingTests.swift`, `GitCLIArgumentSourceGatingTests.swift`, `LibGit2FetchSourceGatingTests.swift`, `LocalHistorySourceGatingTests.swift`, `LSPSourceGatingTests.swift`, `MainWindowFrameSourceGatingTests.swift`, `ReleaseMetadataTests.swift`, `SparkleSourceGatingTests.swift`, `WelcomeShortcutPinTests.swift`, all under `Tests/PisakaCoreTests/`

- [x] Same treatment as Task 4. Specific points:
  - `SparkleSourceGatingTests`' `try?` read keeps its "unreadable → empty" behaviour at the call site.
  - `ReleaseMetadataTests` moves only its Swift-source reads.
  - `WelcomeShortcutPinTests` and `GitCLIArgumentSourceGatingTests` keep the comment-only scanner over the reader's raw text.
- [x] Confirm by grep that no file under `Tests/PisakaCoreTests/` other than `Support/RepositorySources.swift` calls `FileManager.default.enumerator` over `Sources`, or `String(contentsOf:)` on a `Sources/` Swift file. Remaining `String(contentsOf:)` calls are non-Swift repository files (docs, YAML, plists) or fixtures.
- [x] Run the full `swift test`. Count unchanged since Task 3.

### Task 6: CI build jobs start independently

**Files:**
- Modify: `.github/workflows/ci.yml`

- [x] Remove `needs: test` from `build-macos` and from `build-ios`.
- [x] Add one comment block above `build-macos:` at job indentation, modelled on the lint job's comment. It says:
  - the build graph does not depend on the Core suite's verdict;
  - the run's result is wanted as early as the longest job allows (serialized, wall time was `test` plus this job);
  - the accepted cost is that a red `swift test` no longer saves these two runners' minutes;
  - `release.yml` keeps its `needs: test` because publishing must be gated on a green suite, which is a separate question from when feedback arrives.
- [x] Leave everything else in ci.yml untouched: concurrency, `timeout-minutes`, setup-xcode pins, XcodeGen URL and digest, the smoke-launch body.
- [x] Run `swift test --filter ReleaseWorkflowTests`, `swift test --filter LintConfigurationTests` and `swift test --filter XcodePin`, all green (XcodePin is a Support helper, not a test class, so that filter matches nothing; its consumers ReleaseWorkflowTests, LintConfigurationTests and DependencyPinTests ran green instead) with no edits to those suites.
- [x] Run `git diff --exit-code master -- .github/workflows/release.yml`. It must be empty.
- [x] Run the full `swift test`.

### Task 7: Verify acceptance criteria

- [x] Run `swift test 2>&1 | tee /tmp/ci-speed-after.log`; it must pass. Record in Notes:
  - the overall `Executed N tests` line; N equals Task 1's count plus the new tests in `SourceStripperContractTests` and `RepositorySourcesTests`;
  - the after-timings of the seven suites next to the before-timings. The five slowest together are expected well under a minute.
  - This is a recorded measurement, not an assertion.
- [x] Repeat the three hand-breaks from Task 1 exactly, and record that each failure message (text after `failed - `) is byte-identical to the baseline. Show one message in full in Notes. Restore each file with `git checkout --`, and confirm `git status` shows only this branch's intended changes.
- [x] Run `swiftlint --strict` (pinned 0.65.1, via `make lint`) from the repository root; it must be clean.
- [x] Confirm `ci.yml` has no `needs:` under `build-macos` or `build-ios`, and that `release.yml` is byte-identical to master.

### Task 8: Update documentation

**Files:**
- Modify: `CLAUDE.md`
- Check: `docs/RELEASING.md`

- [ ] In CLAUDE.md's Commands section, rewrite the CI sentence ("`swift test` first, then — only when it is green — the macOS job … in parallel, plus an independent `lint` job …"). The new sentence describes four independent jobs with no `needs:` between them: `swift test`; the macOS job (keep its parenthetical about `Package.resolved`, the app-layer bundle and the unsigned build); the unsigned iOS build (device arch, libgit2 linking); and `lint` (pinned SwiftLint 0.65.1, `--strict`).
- [ ] In CLAUDE.md's Tests section, add `RepositorySources` to the Support helper list in one clause: the once-per-process walk and raw/stripped text of repository files that every source-gating suite reads through.
- [ ] Check CLAUDE.md stays under 60,000 characters (`wc -c CLAUDE.md`; 56,552 before) and that `LintConfigurationTests` is green.
- [ ] Re-read every `ci.yml` mention in `docs/RELEASING.md`. Exploration found none that says the build jobs wait for `test`, so the file is expected to stay unchanged. Record the finding in Notes. A sentence that does state such an ordering is corrected; sentences that only list jobs stay.
- [ ] README.md is unaffected (no user-facing change). `docs/architecture/style-lint.md` is unaffected.
- [ ] Run the full `swift test` and `swiftlint --strict` one final time.

## Notes (filled in during execution)

- Baseline (Task 1): overall test count; seven per-suite timings.
  - Unmodified tree (`swift test 2>&1 | tee /tmp/ci-speed-before.log`, local arm64 machine): `Executed 7098 tests, with 0 failures (0 unexpected) in 270.003 (270.310) seconds`.
  - Per-suite before-timings:
    - `ChromeThemeSourceGatingTests`: Executed 75 tests … in 101.922 (101.927) seconds
    - `MarkdownPreviewSourceGatingTests`: Executed 13 tests … in 40.098 (40.099) seconds
    - `FoldingSourceGatingTests`: Executed 10 tests … in 41.586 (41.586) seconds
    - `LeetCodeAccountSourceGatingTests`: Executed 9 tests … in 13.617 (13.618) seconds
    - `ZoomSourceGatingTests`: Executed 10 tests … in 14.951 (14.952) seconds
    - `MenuShortcutUniquenessTests`: Executed 8 tests … in 8.194 (8.194) seconds
    - `GitHubSourceGatingTests`: Executed 19 tests … in 4.411 (4.412) seconds
  - With `SourceStripperContractTests` added (10 tests), the full suite is 7108 tests, green against the unmodified stripper.
- Hand-break baseline messages (Task 1) and after (Task 7).
  - Baseline (Task 1), text after `failed - ` (each file restored with `git checkout --`; `git status` clean afterwards):
    - Folding (`testTheFoldLayerNamesNoWriterGate`, `let autosave = 0` in `FoldController.swift`): `FoldController.swift must not name autosave: folding is a reader, like the symbol index. It writes nothing — not the buffer, not the session, not the disk — so there is nothing for a writer gate to order it against.`
    - Markdown (`testTheFeatureNamesNoWriterGate`, `let localChanges = 0` in `MarkdownPreviewController.swift`): `MarkdownPreviewController.swift must not name localChanges: the preview is a reader, like the symbol index.`
    - ChromeTheme (`testNoGatedFileNamesASystemSemanticColor`, `let probe = Color.red` in `TabStripView.swift`): `XCTAssertEqual failed: ("["TabStripView.swift: red"]") is not equal to ("[]") - a gated view must ask the palette for a role, never the system for a colour` (the part after `failed - ` is `a gated view must ask the palette for a role, never the system for a colour`; the offender list is `["TabStripView.swift: red"]`).
- Stripper equivalence (Task 2): command, file count, result.
  - `swift test --filter StripperEquivalenceCheck`: the temporary test compared 789 files (every `.swift` under `Sources/`, `Tests/` and `Vendor/`, plus `Package.swift`, skipping `/.build/`) and all matched the verbatim legacy stripper: `Executed 1 test, with 0 failures (0 unexpected)`. `StripperEquivalenceCheck.swift` was then deleted and is not committed.
  - After the rewrite, `SourceStripperContractTests` passed (10 tests, 0 failures) and the full `swift test` passed: `Executed 7108 tests, with 0 failures (0 unexpected) in 189.825 (190.133) seconds`, down from 270 s. Along the way: ChromeThemeSourceGatingTests 70.9 s (was 101.9 s), FoldingSourceGatingTests 25.0 s (was 41.6 s), MarkdownPreviewSourceGatingTests 28.6 s (was 40.1 s).
- Reader (Task 3): `RepositorySourcesTests` adds 6 tests; full `swift test`: `Executed 7114 tests, with 0 failures (0 unexpected) in 189.488 (189.793) seconds`. This is the count Tasks 4 and 5 must keep.
- Heavy suites (Task 4): all eight migrated; per-suite `swift test` green (ChromeThemeSourceGatingTests 75 tests in 34.4 s, MarkdownPreviewSourceGatingTests 13 in 17.0 s, FoldingSourceGatingTests 10 in 6.8 s, ZoomSourceGatingTests 10 in 3.1 s, LeetCodeAccountSourceGatingTests 9 in 3.9 s, MenuShortcutUniquenessTests 8 in 8.2 s, GitHubSourceGatingTests 19 in 2.5 s, ChromeThemeTests 11). `testTheHeaderNamesEveryLiteralKeepingReading` green, so the literal-keeping set is unchanged. Full `swift test`: `Executed 7114 tests, with 0 failures (0 unexpected) in 106.807 (107.107) seconds` — same count as Task 3. Doc-comment changes: the two `swiftSources()` comments (Zoom, ChromeTheme) that said the walk was "found relative to this file" now say it is walked by `RepositorySources`; `ChromeThemeTests.readCoreSource` became `readCoreCode` (it now returns stripped text). Markdown reads in ChromeTheme keep `Self.read`.
- Remaining suites (Task 5): all eleven migrated. Sparkle keeps `try?` → empty at its `code(of:)`; ReleaseMetadata moves only its `Package.swift` read; WelcomeShortcutPin and GitCLIArgument keep `GitHubSourceGatingTests.strippingComments(…)` over `RepositorySources.raw`. LSPSourceGatingTests' private `read(_:)` lost its last caller and was removed. The grep turned up two files outside the nineteen that read a `Sources/` Swift file directly, `CodeZoneCheckboxRuleTests` (a raw read) and `LintConfigurationTests` (raw marker scan); only their reads moved to `RepositorySources.raw`. LintConfigurationTests keeps its own `contentsOfDirectory` walk because it skips hidden entries and also walks `Tests/`. Afterwards the only `FileManager.default.enumerator` outside the reader is ChromeTheme's walk of `docs/`, and every remaining `String(contentsOf:)` reads docs, licenses, YAML, plists, workflows, grammar.js, query files or fixtures. Full `swift test`: `Executed 7114 tests, with 0 failures (0 unexpected) in 96.892 (97.190) seconds`, the same count as Task 3. `swiftlint --strict` (0.65.1) clean on the changed files.
- CI jobs (Task 6): `needs: test` removed from `build-macos` and `build-ios`, with the reason in one comment above `build-macos:`. ReleaseWorkflowTests (69) and LintConfigurationTests (29) green with no edits, and DependencyPinTests green too. `git diff --exit-code master -- .github/workflows/release.yml` is empty. Full `swift test`: `Executed 7114 tests, with 0 failures (0 unexpected) in 96.139 (96.435) seconds`.
- After timings (Task 7).
  - `swift test 2>&1 | tee /tmp/ci-speed-after.log` (same local arm64 machine): `Executed 7114 tests, with 0 failures (0 unexpected) in 96.657 (96.959) seconds` (was 270.003 s). 7114 = 7098 baseline + 10 `SourceStripperContractTests` + 6 `RepositorySourcesTests`.
  - Per-suite, before → after (recorded measurement, not an assertion):
    - `ChromeThemeSourceGatingTests`: 101.922 s → 34.727 s (75 tests)
    - `MarkdownPreviewSourceGatingTests`: 40.098 s → 15.675 s (13 tests)
    - `FoldingSourceGatingTests`: 41.586 s → 5.645 s (10 tests)
    - `LeetCodeAccountSourceGatingTests`: 13.617 s → 3.329 s (9 tests)
    - `ZoomSourceGatingTests`: 14.951 s → 1.904 s (10 tests)
    - `MenuShortcutUniquenessTests`: 8.194 s → 8.164 s (8 tests)
    - `GitHubSourceGatingTests`: 4.411 s → 1.254 s (19 tests)
  - The five slowest before (ChromeTheme, Folding, Markdown, Zoom, LeetCode) together: 212.2 s → 61.3 s. That is not "well under a minute": ChromeTheme alone keeps ~35 s and Markdown ~16 s. The per-test cost left in those suites is their own scanning, not file I/O or stripping, which now happen once per file. MenuShortcutUniqueness did not change, so its cost is not in reading.
  - Hand-breaks repeated exactly as in Task 1; each message after `failed - ` is byte-identical to the baseline. Folding in full: `FoldController.swift must not name autosave: folding is a reader, like the symbol index. It writes nothing — not the buffer, not the session, not the disk — so there is nothing for a writer gate to order it against.` Markdown: `MarkdownPreviewController.swift must not name localChanges: the preview is a reader, like the symbol index.` ChromeTheme: `a gated view must ask the palette for a role, never the system for a colour`, offender list `["TabStripView.swift: red"]`, same as before. Every file was restored with `git checkout --`, and `git status` was clean afterwards.
  - `make lint` (SwiftLint 0.65.1, `--strict`): `Found 0 violations, 0 serious in 784 files`.
  - `ci.yml` has no `needs:` key at all (build-macos, build-ios, test and lint all independent). `git diff --exit-code master -- .github/workflows/release.yml` is empty.
- RELEASING.md finding (Task 8).

## Post-Completion

- On the branch's first CI run, check that `test`, `build-macos`, `build-ios` and `lint` all start within the same minute, and note the run's total wall time against the 25–28 minute baseline.
