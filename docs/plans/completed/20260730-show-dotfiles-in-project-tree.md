# Show dotfiles in the project tree (except service entries)

## Overview

`FileService.contentsOfDirectory(at:)` currently filters out every entry whose name starts with `.`, so a `.gitignore` created through the tree's context menu never appears in the UI and cannot be opened, renamed, or deleted. Move to VS Code-style behavior: dotfiles are visible, and only an explicit set of service entries (`.git`, `.DS_Store`) is hidden, expressed as a single constant in `FileService`. As a consequence, the explicit `.mocharc*` probing in `PisakaApp.projectTestEvidence()` becomes redundant and is removed (behavior is unchanged — those names now arrive through the normal listing).

## Context

- Files involved:
  - `Sources/PisakaCore/FileService.swift` — the listing filter (lines ~110-130) and its doc comment
  - `Tests/PisakaCoreTests/FileServiceTests.swift` — `testContentsOfDirectoryFiltersHiddenEntries` (lines 84-98)
  - `Sources/Pisaka/PisakaApp.swift` — `testDotfileSignals` + `projectTestEvidence()` (lines ~288-327)
  - `CLAUDE.md` — lines ~61-62 (the filtering rule) and ~1187 (the `.mocharc*` probing note)
- Related patterns:
  - Tests use `@testable import PisakaCore`, so an `internal static let` constant is reachable from tests without widening the public API
  - `TestCommand` detects mocha via `rootEntryNames.contains(where: { $0.hasPrefix(".mocharc") })` — a prefix check, so every variant (`.mocharc.yml`, `.mocharc.cjs`, …) is picked up from the normal listing
  - `FileIcon` already special-cases `.gitignore` — no change needed there
  - Sorting caveat (deliberate, recorded so the test comment does not overstate it): the sort is directories-first, then `localizedCaseInsensitiveCompare`. That comparator gives punctuation a low collation weight, so the expected order does **not** rest on "a leading dot sorts before letters" — it rests on the first *letters* differing (`.github` before `src` because `g < s`; `.gitignore` before `visible.txt` because `g < v`). This is stable for the chosen fixture; the test comment must state the `g < s` / `g < v` reasoning and must not claim dot-first ordering, which is locale-dependent.
- Dependencies: none; the change stays Foundation-only
- Pre-check already run while drafting: `grep -rn 'hasPrefix(".")' Sources/ Tests/` returns exactly one filtering site — `Sources/PisakaCore/FileService.swift:120`. The other hits (`ScopedFileAccess`, `GitRefName`, `RemoteHost`) are unrelated. The sweep is repeated as a step in Task 1 to confirm nothing is left behind after the edit.

## Development Approach

- **Testing approach**: TDD (test first) — the repo convention
- Logic stays in `PisakaCore`; the view layer is touched minimally (removing the now-dead probing + doc comments)
- No user-facing "show hidden files" toggle — out of scope
- **CRITICAL: every task MUST include new/updated tests**
- **CRITICAL: all tests must pass before starting next task**

## Implementation Steps

### Task 1: Listing shows dotfiles, hides only service entries

**Files:**
- Modify: `Tests/PisakaCoreTests/FileServiceTests.swift`
- Modify: `Sources/PisakaCore/FileService.swift`

- [x] run `grep -rn 'hasPrefix(".")' Sources/ Tests/` and confirm the hidden-entry rule lives only in `FileService.swift:120` (expected: the only filtering hit; `ScopedFileAccess`/`GitRefName`/`RemoteHost` hits are unrelated). If any other site duplicates the rule (iOS layer, tree view), note it and fix it in this task too
- [x] rewrite `testContentsOfDirectoryFiltersHiddenEntries` for the new behavior: in a temporary directory create the files `visible.txt`, `.gitignore`, `.DS_Store` and the directories `.github`, `.git`, `src`; expect the names `[".github", "src", ".gitignore", "visible.txt"]` — directories first, then files — so the visible dot-*directory* case (the common `.github` scenario, exercising the "directory + not in the exclusion set" branch) is covered alongside the visible dot-*file* and the hidden `.git`/`.DS_Store` (renamed to `testContentsOfDirectoryShowsDotfilesButHidesServiceEntries`, since the old name no longer describes the behavior)
- [x] in the test's comment, justify the expected order by the first differing *letters* under `localizedCaseInsensitiveCompare` (`.github` before `src` via `g < s`; `.gitignore` before `visible.txt` via `g < v`); do **not** write that a leading dot sorts first — punctuation weight in that comparator is locale-dependent and is not what this expectation relies on
- [x] run `swift test` and confirm the test fails for the expected reason (got `["src", "visible.txt"]` — both the visible dotfile and the visible dot-directory were filtered out), recording the red phase
- [x] add an explicit constant to `FileService`: `static let excludedEntryNames: Set<String> = [".git", ".DS_Store"]` with a short comment on its purpose (service entries, exact-name comparison)
- [x] in `contentsOfDirectory(at:)` replace the `hasPrefix(".")` condition with `!Self.excludedEntryNames.contains(child.lastPathComponent)`; leave sorting, `DirectoryEntry`, and the empty/missing-directory handling untouched
- [x] update the `contentsOfDirectory(at:)` doc comment: dotfiles are visible, only entries in `excludedEntryNames` are hidden (exact-name comparison), sorting unchanged
- [x] re-run `grep -rn 'hasPrefix(".")' Sources/` to confirm no filtering site remains
- [x] run `swift test` — the whole suite is green (including `testContentsOfDirectoryReturnsEmptyForEmptyDirectory` and `testContentsOfDirectoryThrowsForMissingDirectory`) — 765 tests, 0 failures

### Task 2: Remove the now-redundant .mocharc* probing in PisakaApp

**Files:**
- Modify: `Sources/Pisaka/PisakaApp.swift`

- [x] delete the `testDotfileSignals` constant and the probing loop in `projectTestEvidence()` (`.mocharc*` names now come from `contentsOfDirectory`)
- [x] update the `projectTestEvidence()` and `testManifestNames` doc comments: drop the references to "`contentsOfDirectory` omits hidden entries" and to `testDotfileSignals`; evidence = root entry names from the listing + manifest contents from `testManifestNames`
- [x] confirm the existing `TestCommandTests` (mocha detection via the `.mocharc` prefix in `rootEntryNames`) stay valid and cover the resolver behavior; if there is no `.mocharc.yml` case, add one (added `testMochaSelectedForYAMLConfigVariant`)
- [x] run `swift test` — green (766 tests, 0 failures)
- [x] build the macOS target (`xcodegen generate` if needed + `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' build`) to confirm the deletion compiles — BUILD SUCCEEDED

### Task 3: Update documentation

**Files:**
- Modify: `CLAUDE.md`

- [x] update the `FileService.contentsOfDirectory(at:)` description (~line 61): instead of "hidden entries (name starts with `.`) filtered out" — dotfiles are visible, only the explicit `excludedEntryNames` set (`.git`, `.DS_Store`) is hidden, compared by exact name; sorting unchanged
- [x] update the `projectTestEvidence()` description (~line 1187): drop the mention of separate `.mocharc*` probing, record that dotfile signals now come from the normal listing
- [x] sweep with `grep -n "hidden entries\|dotfile\|mocharc" CLAUDE.md` and fix any remaining inconsistencies (remaining hits — `FileName` accepting dotfiles, `TestCommand`'s `.mocharc*` root-entry signal — are still accurate)
- [x] run `swift test` — green (766 tests, 0 failures)

### Task 4: Verify acceptance criteria

- [x] run the full suite: `swift test` — all tests pass (766 tests, 0 failures)
- [x] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' build` — BUILD SUCCEEDED
- [x] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'generic/platform=iOS' build` — BUILD SUCCEEDED (the iOS layer uses the same listing)
- [x] confirm `PisakaCore` stayed Foundation-only (no new imports) and the public API was not widened beyond what is needed — imports across `Sources/PisakaCore/` are only `Foundation` and the pre-existing `CoreGraphics` (`MinimapGeometry`); `excludedEntryNames` is an `internal static let`, reachable from tests via `@testable import` without widening the public API

## Post-Completion (manual)

- Manual check in the app: open a folder → create `.gitignore` via the tree context menu → the file appears immediately (through `treeRevision`), opens, renames, deletes; the `FileIcon` special case is picked up
- Verify `.git` and `.DS_Store` are not visible at the root level nor in nested directories, while `.github` expands like any other directory
