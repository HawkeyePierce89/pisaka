# Find in Files / Text Search bug fixes (team lead review)

## Overview

Three fixes to the search/replace feature added by the last commit (7d3880c):

1. `ProjectSearchModel.replaceAll` gains an `originGeneration:` parameter plus a synchronous pin at the call site (precedent: `LocalChangesModel.revert(_:originGeneration:)`).
2. `^`/`$` become line anchors (`.anchorsMatchLines`) — the VS Code/JetBrains behavior for editor find.
3. `replaceAll` works from a query snapshot captured together with `results` instead of reading the live `self.query`.

Plus a documentation task: update CLAUDE.md/README for the changed behavior and add a "known limits" paragraph recording the four accepted boundaries.

## Context

- Files involved:
  - `Sources/PisakaCore/ProjectSearchModel.swift` — `replaceAll` (line 469), `rootGeneration` (217), `prepareForSearch` (286), `search` (318-322), `currentRequestGeneration` (298)
  - `Sources/PisakaCore/TextSearch.swift` — `TextSearchEngine.regularExpression(for:)`, `replacement(forRange:...)`
  - `Sources/Pisaka/ProjectSearchView.swift` — `onReplaceAll` (46), `confirmReplaceAll` (374, with its `Task` hop at 412)
  - `Sources/Pisaka/PisakaApp.swift` — `onReplaceAll` closure (595), `replaceAllInProject` (626)
  - `Tests/PisakaCoreTests/ProjectSearchModelTests.swift`, `Tests/PisakaCoreTests/TextSearchTests.swift`
  - `CLAUDE.md`, `README.md`
- Related patterns:
  - `LocalChangesModel.revert(_ files:, originGeneration: Int? = nil)` — an `Int?` defaulting to `nil` (an unpinned call is never rejected), compared against `rootRequestGeneration`, bailing before any work.
  - `LocalChangesModel.prepareForFolderChange` / `ProjectSearchModel.prepareForSearch` — the token is captured synchronously in the same main-actor turn as the click, *before* any `Task` is created.
  - `ReplaceSummary.abandoned` — "the batch stopped early, the rest is untouched"; `isEmpty` is false in that case and the view states it in its own sentence.
- Dependencies: none new.

Scope note for fix 1 (why the edit reaches the view): the window the team lead describes is between the Replace All click and the start of the deferred `Task` in `ProjectSearchView.confirmReplaceAll` (line 412). `replaceAllInProject`'s synchronous prefix already runs *inside* that task, so a pin taken only there would not close the window. The capture has to happen in `confirmReplaceAll` before `Task {` and be threaded through `onReplaceAll` → `replaceAllInProject(template:originGeneration:)` → `replaceAll(template:originGeneration:)`.

## Development Approach

- **Testing approach**: TDD (failing test first, then code) — all three fixes have a precise observable statement.
- Complete each task fully (code + tests + green `swift test`) before moving to the next.
- Repository convention: all logic and all tests live in `PisakaCore`; `Sources/Pisaka` stays thin and untested (the view/app edits are covered indirectly through the changed Core API).
- **CRITICAL: every task MUST include new/updated tests**
- **CRITICAL: all tests must pass before starting the next task**

## Implementation Steps

### Task 1: replaceAll(template:originGeneration:) plus a synchronous call-site pin

**Files:**
- Modify: `Sources/PisakaCore/ProjectSearchModel.swift`
- Modify: `Sources/Pisaka/ProjectSearchView.swift`
- Modify: `Sources/Pisaka/PisakaApp.swift`
- Modify: `Tests/PisakaCoreTests/ProjectSearchModelTests.swift`

- [x] write the failing tests in `ProjectSearchModelTests`:
      `testReplaceAllRejectsAPinnedGenerationSupersededBeforeItStarted` (search project A → capture `currentRootGeneration` → `prepareForSearch(other folder)` + a successful search in the new project → `replaceAll(template:, originGeneration: stale)` returns `ReplaceSummary(abandoned: true)` and **no** stub file is rewritten),
      `testReplaceAllWithAMatchingPinnedGenerationRuns` (pin matches → the batch runs normally),
      `testReplaceAllWithoutAPinnedGenerationIsNeverRejected` (`originGeneration: nil` — the path existing tests and direct calls take)
- [x] add `public var currentRootGeneration: Int { rootGeneration }` next to `currentRequestGeneration`, documented as: this is the *project* token, the very one `replaceAll` guards on; pin this rather than the request token, which a query change bumps and which must not abort the batch
- [x] change the signature to `public func replaceAll(template: String, originGeneration: Int? = nil) async -> ReplaceSummary`; at the very top, before the `snapshot`/`token` capture: `if let originGeneration, originGeneration != rootGeneration { return ReplaceSummary(abandoned: true) }`
- [x] document `replaceAll`: the `LocalChangesModel.revert(_:originGeneration:)` precedent; why it returns `abandoned: true` with zeroed counts rather than an empty summary (the view then says "the batch stopped because the folder changed" instead of the misleading "no file matched"); why the `nil` default is never rejected
- [x] `ProjectSearchView`: change the type to `let onReplaceAll: (String, Int) async -> ReplaceSummary?`; in `confirmReplaceAll`, after the alert is confirmed and **before** `Task {`, capture `let origin = model.currentRootGeneration` and pass it as `onReplaceAll(template, origin)`; comment that the capture must precede the `Task` hop — that gap is exactly what this closes
- [x] `PisakaApp`: `replaceAllInProject(template:originGeneration:)` threads the pin into `projectSearch.replaceAll(template:originGeneration:)`; update the closure to `onReplaceAll: { template, origin in await replaceAllInProject(template: template, originGeneration: origin) }`
- [x] run `swift test` — must be green before Task 2

### Task 2: ^/$ as line anchors (.anchorsMatchLines)

**Files:**
- Modify: `Sources/PisakaCore/TextSearch.swift`
- Modify: `Tests/PisakaCoreTests/TextSearchTests.swift`

- [x] rewrite `testRegexReplacementKeepsAnchorsBoundToTheBuffer` for the new semantics and rename it (`testRegexReplacementKeepsAnchorsBoundToLineStartsNotTheMatchRange`): over `"xab\nab"` with pattern `^(a)b` there is exactly one match `{4,2}` which substitutes as `<a>`, while a stale mid-line range `{1,2}` fails to re-match and falls back to the raw template `<$1>` (preserving the `.withoutAnchoringBounds` coverage)
- [x] add failing tests: `^` matches at every line start (`^\w` over `"ab\ncd"` → two matches), `$` at every line end (`b$` over `"ab\nab"` → two matches), group substitution works for a match on the second line, and `.` still does **not** cross a line break (pinning that `.dotMatchesLineSeparators` is not enabled)
- [x] in `TextSearchEngine.regularExpression(for:)` build the options as `[.anchorsMatchLines]` and extend the doc comment: the product decision is that `^`/`$` in search are line boundaries (VS Code/JetBrains); the option lives in one place, so it applies identically to `matches(in:query:)` and to the anchored re-match in `replacement`; what does *not* change is that `.` never crosses a line break
- [x] update the doc comments on `replacement(for:)` / `replacement(forRange:...)`: `.withoutAnchoringBounds` now keeps `^`/`$` on the buffer's *line* boundaries rather than on the re-run range's edges (otherwise a mid-line match would re-anchor and substitute instead of falling back)
- [x] run `swift test` — green before Task 3

### Task 3: snapshot the query together with the results

**Files:**
- Modify: `Sources/PisakaCore/ProjectSearchModel.swift`
- Modify: `Tests/PisakaCoreTests/ProjectSearchModelTests.swift`

- [x] write the failing test `testReplaceAllUsesTheQueryThatProducedTheResultsNotTheLiveOne`: run a search, then externally assign `model.query = SearchQuery(pattern: "zzz")` (simulating an edited field with no re-search), then `replaceAll` — the file is rewritten (`filesChanged == 1`, correct `matchesReplaced`) instead of everything being skipped
- [x] add `private var resultsQuery = SearchQuery(pattern: "")`, assigned in `search` at the same point where `self.query` is published and `results` is cleared, and reset in `prepareForSearch` alongside `results`/`query`
- [x] `replaceAll` captures `let query = resultsQuery` instead of `self.query`
- [x] document it: `query` is the live, view-bound value; `resultsQuery` is the query that produced the current `results`, captured as its pair, so an edited-but-not-run field cannot turn the batch into "everything skipped" (a misleading summary, even though the staleness guard protects the data)
- [x] run `swift test` — green

### Task 4: Verify acceptance criteria

- [x] `swift test` — the full suite passes (1139 tests, 0 failures)
- [x] `xcodegen generate` (if the project is not generated yet)
- [x] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' build` — the view/app edits compile (** BUILD SUCCEEDED **)
- [x] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'generic/platform=iOS' build` — the double gate the repository convention requires: the changed Core files (`ProjectSearchModel`, `TextSearch`) compile into both destinations, so a fix cycle must not skip the iOS half (this is also the CI gate) (** BUILD SUCCEEDED **, unsigned)
- [x] confirm the new tests genuinely failed before the fixes (either by reverting each change in turn, or by recording it as the TDD steps ran) — each source change was reverted in turn with its tests kept: fix 1 (the `originGeneration` guard neutered) → `testReplaceAllRejectsAPinnedGenerationSupersededBeforeItStarted` fails, returning `abandoned: false` with the stub file rewritten; fix 2 (`TextSearch.swift` reverted) → `testRegexCaretMatchesAtEveryLineStart`, `testRegexDollarMatchesAtEveryLineEnd` and `testRegexReplacementKeepsAnchorsBoundToLineStartsNotTheMatchRange` fail; fix 3 (`resultsQuery` reverted) → `testReplaceAllUsesTheQueryThatProducedTheResultsNotTheLiveOne` fails

### Task 5: Update documentation

**Files:**
- Modify: `CLAUDE.md`
- Modify: `README.md`

- [x] CLAUDE.md, `TextSearch.swift` entry: replace the wording "`^`/`$` would bind to the *match's* edges instead of the buffer's" (around lines 849-859) with the line semantics — `.anchorsMatchLines` is on (the user expectation for editor find), `.withoutAnchoringBounds` keeps the anchors on the buffer's line boundaries rather than on the re-match range's edges; `.` still does not cross a line break
- [x] CLAUDE.md, `ProjectSearchModel.swift` entry: describe `replaceAll(template:originGeneration:)` (the `LocalChangesModel.revert` precedent, the capture *before* the `Task` hop in `confirmReplaceAll`, `abandoned: true` on a pin mismatch, `currentRootGeneration` as the project token as opposed to `currentRequestGeneration`) and the `resultsQuery` snapshot captured as the pair of `results`
- [x] CLAUDE.md: add a "Known limits (accepted boundaries of Find in Files / Text Search)" paragraph — (1) `reconcileBufferOpenedDuringWrite` ignores an `applyBufferText` refusal silently, unlike the buffer branch which records an error in the summary; (2) a non-UTF-8 file is classified differently depending on the `readTextIfNotBinary` implementation — the real `FileService` returns `nil` (skip) while the protocol extension's default throws from `read` (error); (3) the file mask is case-sensitive (`Glob` compares exactly, so `*.TS` does not match `*.ts`); (4) a whitespace-only pattern is rejected as `.emptyPattern` in regex mode too, so searching for spaces with a whitespace-only regular expression is not possible
- [x] README.md: add one sentence to the find bar / Find in Files section stating that in regex mode `^`/`$` are line boundaries (as in VS Code/JetBrains)
- [x] run `swift test` once more (documentation does not break the build, but the repository gate is a green suite) — 1139 tests, 0 failures

## Post-Completion (manual, outside automation)

- Check in the built app: ⌘⇧F → regex `^import` finds every such line; a Replace All issued before a folder switch is not applied to the new project.
