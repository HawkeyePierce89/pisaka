# Open file path from project root — breadcrumb bar above the editor

## Overview

A thin VS Code-style bar above the editor showing the open file's path relative to the project root (`backend › src › dialogs › dialogs.service.ts`). All segment-computation logic lives in a new pure `PisakaCore/DisplayPath.swift`; the canonical "file is inside the root" matching reuses the exact semantics of `WorkspaceModel.fileID(forURL:)`/`planRename` through a helper extracted into a shared place (single source of truth). The view is a thin bar in `ContentView.editorZone` (macOS), which covers both tab layouts at once.

## Context

- Files involved:
  - Create: `Sources/PisakaCore/CanonicalPath.swift` — the shared canonical helper (precedent: `ShellQuote.swift`, extracted out of `RunCommand`/`TestCommand` for shared use).
  - Create: `Sources/PisakaCore/DisplayPath.swift` — breadcrumb segment computation.
  - Create: `Tests/PisakaCoreTests/CanonicalPathTests.swift`, `Tests/PisakaCoreTests/DisplayPathTests.swift`.
  - Modify: `Sources/PisakaCore/WorkspaceModel.swift` — private `canonicalURL(_:)` (line ~558) and `relativeComponents(of:under:)` (line ~310) delegate to `CanonicalPath`; behavior unchanged.
  - Modify: `Sources/Pisaka/ContentView.swift` — `editorZone` (line ~317).
  - Modify: `CLAUDE.md`, `README.md`.
- Related patterns:
  - `TerminalLaunch.workingDirectory(projectRoot:home:)` — `home` is passed in as a parameter from the view layer, so Core stays pure and testable; `DisplayPath.components` does the same.
  - `entryMatch(fileURL:operation:)` in `WorkspaceModel` — the "canonical match, with a lexical fallback" semantics; `DisplayPath` uses the same pair of probes.
  - `OpenFile.displayName` (`url?.lastPathComponent ?? "Untitled"`) — the Untitled literal `DisplayPath` must stay paired with.
  - `ProjectWatcher.canonical(_:)` — the *opposite* case, and the reason the new doc comment must be explicit: there `resolvingSymlinksInPath()` was rejected in favour of `realpath(3)` because FSEvents delivers realpath-spelled paths, so the `/private` stripping broke the comparison against a one-sided value.
  - Tests use `@testable import PisakaCore`, so `CanonicalPath` can stay `internal` (no public API expansion).
- Dependencies: none new.

## Design decisions (fixed up front, so they are not decided ad hoc)

- **Single source of truth**: `enum CanonicalPath` (internal, Foundation-only) with two functions:
  - `canonical(_ url: URL) -> URL` — `url.standardizedFileURL.resolvingSymlinksInPath()` (exactly the current `WorkspaceModel.canonicalURL`);
  - `relativeComponents(of:under:) -> [String]?` — the strictly-under prefix check over component arrays (exactly the current private helper).

  After the move `WorkspaceModel` calls into them and keeps *no* copies of its own — two matchers drifting apart becomes impossible by construction.
- **`canonical(_:)` doc comment must state the `/private` caveat explicitly.** `resolvingSymlinksInPath()` resolves ordinary symlinks but deliberately *strips* a `/private` prefix, mapping `/private/tmp` back to `/tmp` — the quirk that made `ProjectWatcher` use `realpath(3)` instead. Here it is **harmless**, because both sides of every comparison (the tab url and the project root / operation url) go through the *same* transform, so a firmlinked path is spelled the same way on both sides and still matches; what matters is consistency, not true realpath. The comment says so in as many words, with the explicit warning: do **not** "fix" this to `realpath(3)` — that would make `DisplayPath`/`CanonicalPath` disagree with the urls `WorkspaceModel` has been matching all along (`fileID(forURL:)`, `open(url:)`, `entryMatch`), which is exactly the drift this extraction exists to prevent. `ProjectWatcher` keeps `realpath` because *its* comparison is one-sided (FSEvents supplies an already-realpath-spelled path it cannot re-transform).
- **`DisplayPath.components(fileURL: URL?, projectRoot: URL?, home: URL) -> [String]`**:
  1. `fileURL == nil` → `["Untitled"]` (matching `OpenFile.displayName`, so the bar does not flicker when switching to an Untitled tab). This duplicates the literal in `OpenFile.displayName`, so a test pins the two together (see Task 2) rather than a shared constant — the pairing is what matters, and a test catches a rename where a constant would just move the coupling.
  2. root open and the file strictly under it → the suffix relative to the root (without the root's own name, including the file name). The probe is canonical first (`CanonicalPath.canonical` on both sides), falling back to lexical (`standardizedFileURL` on both sides), like `entryMatch`;
  3. otherwise — the absolute path: if the file is strictly under `home` (same two probes) → `["~"] + suffix`, else the path components **without the leading `/` component** (breadcrumb segments are always names, so joining with ` › ` never yields `/ › Volumes › …`).
- **View**: no new file — a private `@ViewBuilder pathBar(for:)` in `ContentView`, inserted into the `if let file` branch inside `editorZone` (`VStack(spacing: 0) { pathBar; Divider(); CodeEditorView(...) }`). This covers both layouts (`.vertical` and `.horizontal`, where the bar ends up under the tab strip), and the "No file open" branch stays without a bar.
- Clickable segments, copying the path, the window proxy icon, and an iOS version of the bar are **out of scope** (follow-up).

## Development Approach

- **Testing approach**: TDD (tests written first, run and failing for the expected reason, then the code).
- Complete each task fully before moving to the next.
- **CRITICAL: every task MUST include new/updated tests**
- **CRITICAL: all tests must pass before starting next task** (`swift test`)

## Implementation Steps

### Task 1: Extract canonical matching into a shared Core helper

**Files:**
- Create: `Sources/PisakaCore/CanonicalPath.swift`
- Create: `Tests/PisakaCoreTests/CanonicalPathTests.swift`
- Modify: `Sources/PisakaCore/WorkspaceModel.swift`

- [x] write `CanonicalPathTests` first: `canonical(_:)` standardizes (`/a/./b`, `/a/b/../c`) and resolves symlinks (via a real symlink in a temporary directory); `relativeComponents` — a nested path yields the suffix, equal arrays yield `nil` (strictly-under), a non-prefix yields `nil`, a shorter path yields `nil`
- [x] add a test pinning the *consistency* the `/private` caveat rests on: for a temp-dir path under `/private/…`, a root and a file put through `canonical(_:)` on **both** sides still match via `relativeComponents` (i.e. the prefix stripping is harmless because it is applied symmetrically)
- [x] run `swift test` — confirm it fails for the expected reason (no `CanonicalPath` type)
- [x] create `Sources/PisakaCore/CanonicalPath.swift`: `enum CanonicalPath` (internal, `import Foundation`) with `canonical(_:)` and `relativeComponents(of:under:)`
- [x] write the doc comments: this is the single source of truth for "same file / inside this root"; and on `canonical(_:)` specifically — `resolvingSymlinksInPath()` strips a `/private` prefix (`/private/tmp` → `/tmp`), which is harmless here because *both* sides of every comparison go through this same transform, so do **not** replace it with `realpath(3)` (the `ProjectWatcher` choice, correct there only because FSEvents supplies a one-sided already-realpath-spelled path) — doing so would desynchronize this helper from the urls `WorkspaceModel.fileID(forURL:)`/`open(url:)`/`entryMatch` match against
- [x] rewrite `WorkspaceModel.canonicalURL(_:)` and `relativeComponents(of:under:)` as delegation to `CanonicalPath` (thin wrappers or direct call sites — semantics unchanged)
- [x] `swift test` — the whole suite, including the existing `WorkspaceModelTests` (rename/delete symlink cases), must be green

### Task 2: `DisplayPath` — breadcrumb segment computation

**Files:**
- Create: `Sources/PisakaCore/DisplayPath.swift`
- Create: `Tests/PisakaCoreTests/DisplayPathTests.swift`

- [x] write `DisplayPathTests` first, covering: a file inside the root → relative segments without the root's name, with the file name; a file at the root itself → `["main.ts"]`; a file outside the root (root open) → absolute segments with `~` abbreviation; a file outside home → absolute segments with no abbreviation and no leading `/`; `projectRoot == nil` → absolute segments; `fileURL == nil` → `["Untitled"]`; a path with `.`/`..` requiring standardization; symlink cases on a real temporary directory — (a) a root opened through a symlink with the file spelled canonically, (b) a file opened through a symlink to the root — both resolving relative to the root
- [x] add the Untitled pairing test: `DisplayPath.components(fileURL: nil, projectRoot: <any>, home: <any>) == [OpenFile(url: nil).displayName]` — so a rename of the `displayName` fallback is caught by the test rather than by the user
- [x] add a single-source-of-truth test: for a set of (tab url, projectRoot) pairs, consistency between `DisplayPath` and `WorkspaceModel` — a tab that `model.fileID(forURL:)` finds via a differently-spelled path yields a non-empty relative path in `DisplayPath`, and vice versa (so matcher drift is caught)
- [x] run `swift test` — failing for the expected reason (no `DisplayPath` type)
- [x] implement `Sources/PisakaCore/DisplayPath.swift`: `public enum DisplayPath { public static func components(fileURL: URL?, projectRoot: URL?, home: URL) -> [String] }` per the Design decisions, Foundation-only, built on `CanonicalPath`
- [x] `swift test` — green

### Task 3: The bar above the editor (macOS)

**Files:**
- Modify: `Sources/Pisaka/ContentView.swift`

- [x] add a private `@ViewBuilder func pathBar(for file: OpenFile) -> some View`: `Text(DisplayPath.components(fileURL: file.url, projectRoot: model.projectRoot, home: FileManager.default.homeDirectoryForCurrentUser).joined(separator: " › "))` with `.font(.caption)`, `.foregroundStyle(.secondary)`, `.lineLimit(1)`, `.truncationMode(.middle)`, horizontal padding, `.frame(maxWidth: .infinity, alignment: .leading)` and a fixed row height (so the height does not jump)
- [x] insert into the `if let file` branch of `editorZone`: `VStack(spacing: 0) { pathBar(for: file); Divider(); CodeEditorView(...) }`; leave the "No file open" branch untouched (bar hidden when no file is open)
- [x] tests: this view-layer change contains no logic — run the existing Core suite (`swift test`) as a regression gate; this task adds no new Core tests (all logic is covered in Task 2)
- [x] `xcodegen generate` is not required (no new files in the app target); build macOS: `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' build`

### Task 4: Verify acceptance criteria

- [x] `swift test` — full suite green (881 tests, 0 failures)
- [x] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' build` — green (** BUILD SUCCEEDED **)
- [x] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'generic/platform=iOS' build` — green (the Core helper is shared; there is no iOS bar). Run unsigned (`CODE_SIGNING_ALLOWED=NO`) as CI does, since the device slice has no signing identity here
- [x] verify `PisakaCore` gained no imports beyond Foundation (the new files import Foundation only) — `CanonicalPath.swift` and `DisplayPath.swift` each declare exactly `import Foundation`

### Task 5: Update documentation

- [x] `CLAUDE.md`: add `DisplayPath.swift` and `CanonicalPath.swift` to the Core list with their rules — including the fate of `relativeComponents`/`canonicalURL` (where they now live and why it is the single source of truth), the `/private` caveat and the "don't switch to `realpath`" note next to the existing `ProjectWatcher` explanation of why that file goes the other way, and the `OpenFile.displayName` pairing pinned by a test; extend the `ContentView` description with the path bar above the editor in both tab layouts
- [x] `README.md`: mention the project-root-relative path above the editor in the Features section
- [x] record the follow-ups (clickable segments, copying the path, an iOS bar) in CLAUDE.md/README as explicitly out of scope

## Post-Completion (manual, outside the automated checkboxes)

- Manual check on macOS: open `backend/src/dialogs/dialogs.service.ts` — `backend › src › dialogs › dialogs.service.ts` shows above the code; switching tabs updates the bar; Untitled shows "Untitled"; in a narrow window the truncation is in the middle and the row height does not jump; in the horizontal tab layout the bar sits under the tab strip.
