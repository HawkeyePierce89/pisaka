# Create files/folders by relative path in the project tree

## Overview

The tree's New File / New Folder dialogs accept a single name only: `centrifugo/config.json` is rejected by `isValidFileName` (which forbids `/`). Move to VS Code behavior — a relative path of any depth creates the missing intermediate folders and the target entry in one shot; existing intermediates are silently reused.

Layering stays as in the repo: all decisions are pure and live in `PisakaCore` (a path parser + a `FileServicing.ensureDirectory(at:)` operation with a typed error), while `PisakaApp` stays thin orchestration. Rename is untouched (a path in rename means a move — a separate feature).

## Context

- Files involved:
  - `Sources/PisakaCore/FileName.swift` — `isValidFileName`; new `parseRelativeEntryPath(_:)` lands beside it
  - `Sources/PisakaCore/FileService.swift` — `FileServicing` protocol + defaulted extension, `FileServiceError`, `excludedEntryNames` / `isExcludedEntryName`, `createFile`/`createDirectory`
  - `Sources/Pisaka/PisakaApp.swift` — `newFile(in:)` (~955-969), `newFolder(in:)` (~973-986), `reportInvalidName` (~1067-1075), `reportReservedName` (~1081-1089), `revertInFlight()`
  - `Sources/Pisaka/iOS/SecurityScopedBookmarks.swift` — `SecurityScopedFileService` decorator (~133-165), which forwards every `FileServicing` method through `withScope`
  - `Tests/PisakaCoreTests/FileNameTests.swift`, `Tests/PisakaCoreTests/FileServiceTests.swift`
  - `CLAUDE.md`, `README.md`
- Related patterns:
  - New protocol methods are defaulted in the `FileServicing` extension to `throw FileServiceError.unsupported`, so the read/write-only test stubs keep compiling (precedent: `createFile`/`createDirectory`/`move`/`removeItem`)
  - `FileServiceError` conforms to `LocalizedError` with human text so `NSAlert(error:)` shows a real message instead of the raw-enum fallback (precedent: `.alreadyExists`)
  - `FileService.excludedEntryNames` (`.git`, `.DS_Store`) is the single source of truth for hidden service entries; `isExcludedEntryName(_:)` is its *exact-name* predicate used by the listing
  - `FileService` tests exercise the real `FileManager` through `FileManager.default.temporaryDirectory` + `defer { try? removeItem }`
  - iOS has no tree create/rename UI (`RootView_iOS` only calls `model.newFile()` for an Untitled buffer), so the view work is macOS-only; the iOS decorator still gets the forwarding for consistency
- Dependencies: none — Foundation only

## Design decisions (fixed before implementation)

- `parseRelativeEntryPath(_ path: String) -> [String]?` — trims the whole input, tolerates exactly one trailing `/`, splits on `/` **without** omitting empty subsequences, trims each component, and returns `nil` when: the result is empty, any component is empty *after trimming* (covers `a//b`, a leading `/`, and a whitespace-only component `a/ /b`), any component fails `isValidFileName` (covers `.`, `..`, NUL), or any component is a reserved service name.
- **Reserved components are matched case-insensitively** (`x/.GIT/y` → `nil`). Rationale: on a case-insensitive volume (APFS default) `.GIT` resolves to an existing `.git`, so `ensureDirectory` would silently reuse the hidden repo directory and the created file would be invisible in the tree. The listing predicate `isExcludedEntryName(_:)` stays *exact-match* (git/Finder write exact names, and hiding a user's `.Git` folder from the tree would be wrong); the case-insensitive rule is a separate, stricter create-time predicate: a new `public static func isReservedCreateName(_ name: String) -> Bool` on `FileService`, comparing against the same `excludedEntryNames` set with `caseInsensitiveCompare`. One set, two documented predicates — no duplicated list.
- `FileServiceError.notADirectory(name: String)` carries the offending component so `errorDescription` reads `"centrifugo" already exists and is not a folder.`
- `ensureDirectory(at:)` recurses **upward** first (existing dir → return, existing non-dir → throw `.notADirectory`, missing → ensure parent then create), so a file on the path is detected before any directory is written. Directories already created when a later step fails are **not** rolled back (`mkdir -p` / VS Code semantics). A **symlink to a directory** on the path is reused, not refused: the existence/type probe dereferences it, so the chain continues into the link's target — deliberate, matching `mkdir -p`, and recorded in the doc comment so it doesn't read as an oversight.
- macOS create flow: parse → on `nil` show the updated `reportInvalidName` → `ensureDirectory` on the parent chain (skipped entirely for a single component) → existing `createFile` / `createDirectory` on the final component → open the tab (New File only) → `bumpTreeRevision()` only on full success. `revertInFlight()` gate unchanged. The final entry must not exist (`.alreadyExists` — "never clobber" preserved); intermediates are tolerated.
- `reportReservedName` stays for `renameItem` only (rename keeps single-name, exact-match semantics — it is a move, out of scope); a reserved component in a create path is reported through the updated invalid-name text, which now explains the per-component rule: non-empty, not `.`/`..`, not a reserved name such as `.git`/`.DS_Store` (in any casing).
- iOS `SecurityScopedFileService` **forwards** `ensureDirectory(at:)` through `withScope` (rather than inheriting the `.unsupported` default), matching every other mutating method on that decorator.

## Development Approach

- **Testing approach**: TDD (test first) — repo convention; each new test must be seen failing for the expected reason before the code lands
- Complete each task fully before moving to the next
- All logic in `PisakaCore` (Foundation-only); `Pisaka` stays thin orchestration
- **CRITICAL: every task MUST include new/updated tests**
- **CRITICAL: all tests must pass before starting the next task**

## Implementation Steps

### Task 1: Core — case-insensitive reserved-name predicate

**Files:**
- Modify: `Sources/PisakaCore/FileService.swift`
- Modify: `Tests/PisakaCoreTests/FileServiceTests.swift`

- [x] write failing tests for `FileService.isReservedCreateName(_:)`: `true` for `.git`, `.GIT`, `.Git`, `.DS_Store`, `.ds_store`; `false` for `.gitignore`, `.github`, `git`, `""`
- [x] add a test asserting `isExcludedEntryName(_:)` is *still* exact-match (`.GIT` → `false`), pinning the two predicates apart
- [x] run the tests and confirm they fail for the expected reason (symbol not found), not an unrelated error
- [x] implement `isReservedCreateName(_:)` beside `isExcludedEntryName(_:)`, over the same `excludedEntryNames` set with `caseInsensitiveCompare`, documenting why create-time validation is stricter than the listing (case-insensitive volumes would let `.GIT` resolve onto an existing `.git`)
- [x] run `swift test` — must pass before Task 2

### Task 2: Core — relative path parser

**Files:**
- Modify: `Sources/PisakaCore/FileName.swift`
- Modify: `Tests/PisakaCoreTests/FileNameTests.swift`

- [x] write failing tests for `parseRelativeEntryPath(_:)` in `FileNameTests`: depth > 1 (`a/b/c.json` → `["a","b","c.json"]`); single name with no slash (backwards compat, `file.txt` → `["file.txt"]`); one tolerated trailing slash (`a/b/` → `["a","b"]`); leading slash (`/a/b` → `nil`); `a//b` → `nil`; two trailing slashes (`a//` → `nil`); whitespace-only component (`a/ /b` → `nil`, and `a/\t/b` → `nil`) — the seam between per-component trimming and the empty-component rule; `.` and `..` as a component (`a/../b`, `a/./b`, bare `..`) → `nil`; `.git`/`.DS_Store` in the middle and at the end (`x/.git/y`, `x/.DS_Store`) → `nil`; case-insensitive reserved component (`x/.GIT/y` → `nil`, plus `x/.Ds_Store` → `nil`); per-component trimming (` a / b.txt ` → `["a","b.txt"]`); empty and whitespace-only input → `nil`; NUL in a component → `nil`
- [x] run the tests and confirm they fail for the expected reason
- [x] implement `parseRelativeEntryPath(_:)` in `FileName.swift` beside `isValidFileName`, using `FileService.isReservedCreateName(_:)` for the reserved check, with a doc comment stating the tolerated-trailing-slash rule, the per-component trim, and each `nil` reason (noting that a component trimming down to empty is rejected by the empty-component rule)
- [x] leave `isValidFileName` unchanged (still single-name semantics; rename keeps using it)
- [x] run `swift test` — must pass before Task 3

### Task 3: Core — `ensureDirectory` + `.notADirectory`

**Files:**
- Modify: `Sources/PisakaCore/FileService.swift`
- Modify: `Tests/PisakaCoreTests/FileServiceTests.swift`

- [x] write failing tests in `FileServiceTests`: create a chain from scratch (`root/a/b/c` — all three exist and are directories afterwards); partially existing chain (`root/a` pre-exists → `b/c` created, `a` untouched); fully existing chain is a no-op (no throw, nothing changed); a **file** at an intermediate level → throws `FileServiceError.notADirectory` **and** nothing new appears on disk (assert the deeper components do not exist); a file at the *final* level → `.notADirectory`; `errorDescription` of `.notADirectory` is non-empty and names the offending component
- [x] run the tests and confirm they fail for the expected reason
- [x] add `case notADirectory(name: String)` to `FileServiceError` with `errorDescription` `"\(name)" already exists and is not a folder.`
- [x] add `func ensureDirectory(at url: URL) throws` to the `FileServicing` protocol and default it in the extension to `throw FileServiceError.unsupported` (so existing stubs keep compiling)
- [x] implement `FileService.ensureDirectory(at:)`: existing directory → return; existing non-directory → throw `.notADirectory(name: url.lastPathComponent)`; otherwise ensure the parent first (guarding against the root fixed point where `parent.path == url.path`) then `createDirectory(withIntermediateDirectories: false)`
- [x] doc-comment the semantics on `ensureDirectory(at:)`: the check-before-write ordering, the no-rollback (`mkdir -p`) behavior, and that a **symlink to a directory** on the path is *reused* (the existence probe dereferences it, so the chain continues into the target) — intentional, matching `mkdir -p`, not an oversight
- [x] run `swift test` — must pass before Task 4

### Task 4: macOS view — path-aware New File / New Folder

**Files:**
- Modify: `Sources/Pisaka/PisakaApp.swift`

- [x] rewrite `newFile(in:)`: keep the `revertInFlight()` gate and `promptName`; replace the trim + `isValidFileName` + `isExcludedEntryName` guards with `parseRelativeEntryPath(rawName)`, reporting `reportInvalidName(rawName)` on `nil`; build the destination by appending every component to `directory`; when there is more than one component call `fileService.ensureDirectory(at:)` on the parent chain first; then `createFile`, `openFile(url:)`, `bumpTreeRevision()` — all inside the existing `do/catch` so any step's failure goes through `reportFileOperationFailure` with no `treeRevision` bump
- [x] rewrite `newFolder(in:)` the same way, ending in `createDirectory` on the final component (never clobbering it) and no tab open
- [x] update `reportInvalidName`'s text: a slash is now a path separator, so explain the per-component rule (each component must be non-empty, not `.` or `..`, and not a reserved name such as `.git`/`.DS_Store` in any casing)
- [x] leave `renameItem` and `reportReservedName` unchanged (rename keeps single-name semantics)
- [x] update the doc comments on both create functions to describe the path behavior
- [x] run `swift test` (Core unchanged but must stay green) and `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' build` (running `xcodegen generate` first if the project file is stale) — must pass before Task 5

### Task 5: iOS — forward `ensureDirectory` through the security scope

**Files:**
- Modify: `Sources/Pisaka/iOS/SecurityScopedBookmarks.swift`

- [x] add `func ensureDirectory(at url: URL) throws { try withScope(url) { try base.ensureDirectory(at: url) } }` to `SecurityScopedFileService`, beside `createDirectory`, with a one-line comment recording that the decorator forwards rather than inheriting the `.unsupported` default
- [x] run `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'generic/platform=iOS' build` — must pass before Task 6

### Task 6: Verify acceptance criteria

- [x] run the full suite: `swift test` — all green
- [x] run `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' build`
- [x] run `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'generic/platform=iOS' build`
- [x] confirm every acceptance test from Tasks 1-3 exists and covers the listed cases (predicate: casing variants, exact-match listing pinned; parser: depth, trailing slash, leading slash, `a//b`, whitespace-only component `a/ /b`, `.`/`..`, `.git`/`.DS_Store` mid- and end-path, `x/.GIT/y`, trimming, single name; `ensureDirectory`: from scratch, partial, no-op, file on the path with nothing written, non-empty `errorDescription`)
- [x] confirm the `ensureDirectory` doc comment records the symlink-to-directory reuse and the no-rollback semantics
- [x] no linter is configured in this repo (`swift test` + the two `xcodebuild` gates are CI's full set, per `.github/workflows/ci.yml`) — confirm nothing else is required

### Task 7: Update documentation

**Files:**
- Modify: `CLAUDE.md`
- Modify: `README.md`

- [x] `CLAUDE.md` — `FileService.swift` bullet: document `ensureDirectory(at:)` (chain with intermediates, existing directory is a no-op, a symlink-to-directory on the path is reused per `mkdir -p`, no rollback on a late failure, defaulted to `.unsupported` in the protocol extension), the new `FileServiceError.notADirectory(name:)` case with its human `errorDescription`, and the two predicates over one `excludedEntryNames` set: exact-match `isExcludedEntryName(_:)` for the listing vs case-insensitive `isReservedCreateName(_:)` for create-path validation (and why — a case-insensitive volume resolves `.GIT` onto an existing `.git`)
- [x] `CLAUDE.md` — `FileName.swift` bullet: document `parseRelativeEntryPath(_:)` (split, one tolerated trailing slash, per-component trim, every `nil` reason including a component that trims to empty, and the `isReservedCreateName` reuse that stops `x/.git/y` and `x/.GIT/y`)
- [x] `CLAUDE.md` — `PisakaApp.swift` block: update the New File / New Folder create-flow description (path parsing, `ensureDirectory` on the parent chain, never-clobber on the final entry, `treeRevision` bumped only on full success, the updated invalid-name message, `reportReservedName` now rename-only)
- [x] `CLAUDE.md` — `SecurityScopedBookmarks.swift`/iOS note: record that the decorator forwards `ensureDirectory` through the scope
- [x] `README.md` — project-tree section (~76-92): New File… / New Folder… accept a relative path (`centrifugo/config.json`), missing intermediate folders are created, existing ones reused, the final entry is never overwritten, and a file sitting on the path is refused with a clear message

## Post-Completion (manual verification by the user)

- `centrifugo/config.json` via New File creates the folder + file, opens the file in a tab, and the tree refreshes in place
- entering the same path again fails with the `.alreadyExists` message
- with `centrifugo` existing as a *file*, the path is refused with the `"centrifugo" already exists and is not a folder.` alert and nothing is created
- `a/b/c/` via New Folder creates the whole chain
- `x/.GIT/y` is refused by the validator (nothing written inside the repo's `.git`)
