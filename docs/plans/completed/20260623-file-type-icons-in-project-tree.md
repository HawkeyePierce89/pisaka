# File-type icons in the project tree

## Overview

Replace the single generic `doc` icon in the left project tree with
file-type-specific SF Symbols, tinted by a color derived from the file type.
All mapping logic lives in a new pure, testable `FileIcon` type in `PisakaCore`;
the `Pisaka` view layer stays thin, mapping the semantic color token to a
concrete SwiftUI `Color` and rendering the icon.

## Context

- Files involved:
  - Create: `Sources/PisakaCore/FileIcon.swift` — `FileIcon` struct + `FileIconColor` enum, with `init(for: DirectoryEntry)` resolution logic.
  - Create: `Tests/PisakaCoreTests/FileIconTests.swift` — unit tests for the mapping.
  - Modify: `Sources/Pisaka/ProjectTreeView.swift` — render the resolved icon in `FileRowView` and the directory label; add a private `FileIconColor → Color` helper.
- Related patterns:
  - `DirectoryEntry` (in `FileService.swift`) is the input: `url`, `isDirectory`, computed `name`. Resolution uses `entry.isDirectory`, `entry.name` (special names), and `entry.url.pathExtension`.
  - `PisakaCore` is pure (no SwiftUI/AppKit). Color stays a semantic enum so the library has no UI dependency.
  - Existing views use `Label(name, systemImage:)`; the change swaps to an explicit `Image(systemName:)` + `.foregroundColor(token)` next to the name.
- Dependencies: Apple SDK only (SwiftUI, AppKit, Foundation), macOS 13+. No external packages.

## Development Approach

- **Testing approach**: TDD-friendly — `FileIcon` is pure logic, so write the mapping and its tests together before wiring the view.
- Complete each task fully before moving to the next.
- **CRITICAL: every code task includes new/updated tests.**
- **CRITICAL: the full `swift test` suite must pass before starting the next task.**

## Implementation Steps

### Task 1: Add `FileIcon` mapping in PisakaCore

**Files:**
- Create: `Sources/PisakaCore/FileIcon.swift`

- [x] Define `public enum FileIconColor { case orange, yellow, blue, green, purple, red, pink, gray, accent }` (Equatable).
- [x] Define `public struct FileIcon: Equatable { public let symbolName: String; public let color: FileIconColor }`.
- [x] Implement `public init(for entry: DirectoryEntry)` with resolution order: (1) directory → `"folder"`/`.accent`; (2) special-cased file names matched case-insensitively (`Package.swift`, `LICENSE`, `.gitignore`/`.gitattributes`, `Makefile`, `Dockerfile`); (3) lowercased `url.pathExtension` lookup against the extension→icon map (~25+ types per the spec table); (4) fallback → `"doc"`/`.gray`.
- [x] Implement the extension map and special-name map as private lookups; lowercase the extension and the name before matching.

### Task 2: Test the `FileIcon` mapping

**Files:**
- Create: `Tests/PisakaCoreTests/FileIconTests.swift`

- [x] Known extensions map to their expected non-default symbol/color (cover a representative set: swift, js, ts, json, yml, md, py, sh, css, png, zip, txt, etc.).
- [x] Matching is case-insensitive (`FOO.SWIFT` resolves like `foo.swift`).
- [x] Special-cased names resolve correctly and beat the extension rule (e.g. `Package.swift` ≠ the plain Swift icon).
- [x] Unknown extension and no-extension files fall back to `"doc"`/`.gray`.
- [x] A directory entry resolves to `"folder"`/`.accent` regardless of name (including a directory named `something.swift`).
- [x] run `swift test` — must pass before Task 3.

### Task 3: Render file-type icons in `ProjectTreeView`

**Files:**
- Modify: `Sources/Pisaka/ProjectTreeView.swift`

- [x] Add a private helper mapping `FileIconColor → SwiftUI Color` (`.accent` → `.accentColor`, others to their named `Color`).
- [x] In `FileRowView`, replace `Label(name, systemImage: "doc")` with an `HStack` of `Image(systemName:)` (`.foregroundColor(token)`) + name `Text`, driven by `FileIcon(for: entry)`. Pass the `DirectoryEntry` (or its resolved `FileIcon`) into the row instead of just `name`.
- [x] In the directory label, render the icon from `FileIcon(for:)` for the directory entry (folder icon, accent tint) rather than the hard-coded `systemImage: "folder"`. Preserve the root node which is constructed from a `URL`, not a `DirectoryEntry` — construct an equivalent `DirectoryEntry(url:isDirectory: true)` or use the folder icon directly.
- [x] Keep `lineLimit(1)`, `truncationMode(.middle)`, hover background, tap gesture, and padding behavior unchanged. No domain logic added to the view.
- [x] run `swift test` — must pass (UI is untested by design; confirms PisakaCore + build integrity via the test build).

### Task 4: Verify acceptance criteria

- [x] run `swift build` — compiles cleanly.
- [x] run `swift test` — full suite passes.
- [x] confirm `FileIcon` test coverage spans directory, special-name, extension, case-insensitive, and fallback cases.

### Task 5: Update documentation

- [x] Update `CLAUDE.md` Architecture section: add `FileIcon.swift` to the `PisakaCore` list and note `ProjectTreeView` now renders type-specific icons via `FileIcon(for:)`.
- [x] Update `README.md` if the project-tree icon behavior is user-facing enough to mention.
