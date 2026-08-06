# Fix: Git Log commit detail pane lags one commit behind

## Overview
In Git Log, selecting commit N shows the previous commit's files in the detail
pane (`CommitDetailPane`) — a one-behind lag — and a double-click then opens an
empty diff (`git show` pulls a file from the stale list). The cause is the
deprecated handler `.onChange(of: commit) { _ in loadChanges() }`, which discards
the new value passed in, while `loadChanges()` reads `self.commit`, which at that
moment still holds the value from the previous render. The targeted fix: pass the
value `onChange` provides into the loader instead of reading `self.commit`.

## Context
- Files involved: `Sources/Pisaka/CommitLogView.swift`, type `CommitDetailPane`
  (lines ~357–424).
- Current code:
  - `body`: `.onAppear(perform: loadChanges)` + `.onChange(of: commit) { _ in loadChanges() }`
  - `loadChanges()`: contains `let requested = commit` (reads self).
- Related patterns: the generation token (`loadGeneration`) stays as-is — it
  guards against a slow-load race, not against the one-behind on `onChange`
  (separate problems). After the fix both mechanisms work together.
- Adjacent views are unaffected (confirmed per the description): Local Changes
  (`@Published` list, no per-item stale-self load) and the diff windows
  (`DiffWindowContent` holds a fixed `load`); their `onChange` handlers are tied
  to `projectRoot` / are idempotent.
- Dependencies: none.

## Out of scope (YAGNI)
- Do not touch `PisakaCore` / domain logic — the fix is purely in the view layer.
- Do not introduce the `.id(selected.id)` call-site alternative — the targeted
  fix is smaller and keeps the pane reused.
- No new files or abstractions.

## Development Approach
- **Testing approach**: Regular (view fix). Per the project convention
  (CLAUDE.md), the UI layer is intentionally thin and not covered by unit tests;
  the fix changes no domain logic, so there are no new tests — instead we verify
  the existing suite stays green and the project builds.
- The project convention ("every behavioral change comes with PisakaCore tests")
  does not apply here, because only a SwiftUI view changes with no new logic in
  Core — this is stated explicitly in the plan.
- Complete each task fully before moving to the next.

## Implementation Steps

### Task 1: Pass the new commit value into CommitDetailPane's file loader

**Files:**
- Modify: `Sources/Pisaka/CommitLogView.swift` (type `CommitDetailPane`)

- [x] In `body`, replace `.onAppear(perform: loadChanges)` with
  `.onAppear { loadChanges(for: commit) }` (on the first render `self.commit` is
  correct).
- [x] In `body`, replace `.onChange(of: commit) { _ in loadChanges() }` with a
  form that uses the new value passed in: `.onChange(of: commit) { loadChanges(for: $0) }`.
- [x] Rename `private func loadChanges()` → `private func loadChanges(for requested: Commit)`;
  remove the `let requested = commit` line and use the `requested` parameter. The
  rest of the body (bump `loadGeneration`, synchronous clearing of
  `files`/`selectedFile`, `Task { await model.changes(for: requested) }` +
  generation guard) stays unchanged.
- [x] Confirm `loadChanges` is no longer called without an argument (the only
  call sites are `onAppear` / `onChange`).

### Task 2: Verify build and the existing test suite

- [x] `swift build` — compiles with no errors/warnings from the changed code.
- [x] `swift test` — the entire existing PisakaCore suite is green (domain logic
  unchanged).

## Post-Completion (manual verification)
- Run `swift run Pisaka`, open Git Log, click through several commits in a row:
  the detail pane immediately shows the selected commit's files (no one-behind
  lag).
- Double-click a file of the selected commit — it opens a non-empty diff
  (`git show` commit-vs-parent for that same commit).
