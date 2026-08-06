# Fix: Infinite refetch loop when switching branch in Git Log

## Overview

The branch picker in `LogFilterBar` holds a mirrored `@State` (`refChoice`) with
`.onChange { applyFilter() }`. When the model publishes a new `filter`,
`.onChange(of: filter)` → `seedFromFilter()` programmatically writes `refChoice`,
which is indistinguishable from a user selection and triggers `applyFilter()`
again → new refetch → new publish. Two interleaved async chains drive `filter`
between `.all` and `.ref(master)` in antiphase, so the dedup guard
(`newFilter == requestedFilter`) misses on every cycle and the spinner spins
forever.

The fix removes the mirrored branch state: the picker is bound to a computed
`Binding<String>` that reads the branch directly from `filter` (via a pure
helper) and writes only through the apply path. The "seed → applyFilter" edge for
the branch disappears — no loop forms.

The pure branch-resolution logic (refSelection + known refs → displayed ref) is
extracted into `PisakaCore.LogFilter` as a testable helper (project convention:
all domain logic and tests live in Core; the view layer stays thin and untested).

## Context

- Files:
  - Modify: `Sources/PisakaCore/LogFilter.swift` — add a pure branch-resolution helper.
  - Modify: `Sources/Pisaka/LogFilterBar.swift` — remove the mirrored `@State`, introduce a computed Binding, reuse the helper. ← main fix.
  - Modify: `Tests/PisakaCoreTests/LogFilterTests.swift` — tests for the helper.
  - Not touched: `CommitLogView.swift`, `CommitLogModel.swift` — the generation guard and apply path are correct; only the source of the branch value changes.
- Related patterns: pure logic in Core + thin view layer (like `LogFilter.gitArguments()`/`search`); computed `Binding` get/set over the model (like `LocalChangesView`/`DiffPane`).
- Caveat (out of scope): the same latent pattern exists in the date pickers (`.onChange(of: date) { applyFilter() }` + seed writes `since/until`). After the branch fix the model is stable, the date seed writes the same values → `onChange` stays silent, no loop. If date-toggle flicker surfaces later, it's curable with the same Binding technique. author/path use `.onSubmit` and don't echo — left untouched.

## Development Approach

- **Testing approach**: Regular (code first, then tests) for the Core helper; the view layer stays untested per project convention.
- Complete each task fully before moving to the next.
- **CRITICAL: the behavioral change in Core (new helper) ships with tests.**
- **CRITICAL: the full test suite is green before the next task.**

## Implementation Steps

### Task 1: Pure branch-resolution helper in LogFilter (Core)

**Files:**
- Modify: `Sources/PisakaCore/LogFilter.swift`
- Modify: `Tests/PisakaCoreTests/LogFilterTests.swift`

- [x] Add a public pure method on `LogFilter`, e.g. `func resolvedRef(amongKnown references: [String]) -> String?`: for `.all` return `nil`; for `.ref(name)` return `name` if `references.contains(name)`, else `nil` (an unknown/dangling ref degrades to "all"). `nil` means "all refs" — the view maps it onto its own sentinel tag. Document the behavior in the doc comment (mirrors the current `seedFromFilter`/get logic).
- [x] Tests in `LogFilterTests.swift`: `.all` → `nil`; `.ref` present in `references` → the name; `.ref` absent → `nil`; empty `references` → `nil`.
- [x] `swift test` — must pass before Task 2.

### Task 2: Remove the mirrored branch `@State` in LogFilterBar (loop fix)

**Files:**
- Modify: `Sources/Pisaka/LogFilterBar.swift`

- [x] Remove `@State private var refChoice` (line 33).
- [x] Add a computed `refSelectionBinding: Binding<String>`:
  - get: `filter.resolvedRef(amongKnown: references)` → `nil` maps to `Self.allRefsTag`, a name maps to itself.
  - set: `{ newRef in applyFilter(refOverride: newRef) }`.
- [x] In `refPicker` (lines 76–92): replace `selection: $refChoice` with `selection: refSelectionBinding`; remove `.onChange(of: refChoice) { _ in applyFilter() }`.
- [x] In `applyFilter` (line 184) add a parameter `refOverride: String? = nil`; compute the selected ref as `refOverride ?? currentRef`, where `currentRef` is the same resolution as in get (via the same `filter.resolvedRef(...)` → `allRefsTag` mapping), so an apply from author/path/date preserves the current branch instead of resetting it to `.all`.
- [x] In `seedFromFilter` (line 160) remove the block that writes `refChoice` (`switch filter.refSelection { ... }`); leave the rest (author/path/since/until/search) unchanged.
- [x] `swift build` succeeds; full `swift test` green (Core tests not regressed).

### Task 3: Verify acceptance criteria

- [x] `swift build` — compiles with no errors/warnings in the touched files.
- [x] `swift test` — full suite green.

### Task 4: Update documentation

- [x] Update the `LogFilterBar.swift` and `LogFilter` descriptions in `CLAUDE.md`: the branch picker now reflects `model.filter` via a computed Binding (no mirrored `@State`), selection flows only through the apply path; mention the new pure helper `resolvedRef(amongKnown:)` in Core. README untouched (no user-facing feature/shortcut changes).

## Post-Completion

- Manual check: open a git repo → ⌘⇧L → switch branch in the picker → exactly one refetch, spinner stops, displayed branch stable (does not flip to "All"); changing author/path/date preserves the selected branch; switching folder shows "All".
