# "Commit…" in the Local Changes file context menu

## Overview

Add a **Commit…** item to a changed file's context menu in the Local Changes panel
(next to Revert), with JetBrains "Commit File" semantics: it opens the existing modal
commit dialog with **only that file preselected** — every other file unchecked. All the
existing machinery (per-line selection, amend, push, gates, staleness) then works
unchanged.

The orchestration is not duplicated: `PisakaApp.openCommitDialog()` gains a
`preselectingPath:` parameter (defaulting to `nil`), so the row item goes through
exactly the same gates as ⌘K and the header ✓ button (re-entry guard,
`revertInFlight()`, autosave flush, modal suspension, generation pinning). The
preselect itself is a pure, testable rule in `CommitDialogModel`, applied in the same
main-actor iteration that publishes the freshly loaded file list — behind the same
generation guards — so an intermediate "everything checked" state is never rendered.

## Context

Files involved:

- `Sources/PisakaCore/CommitDialogModel.swift` — `load(root:request:)`,
  `defaultSelection(for:)`, the publish block at the end of the `do` branch,
  `selectedPath`.
- `Sources/PisakaCore/CommitPlan.swift` — `CommitFileSelection` / `CheckboxState` /
  `isIncludedInCommit` (read only; already implement everything a preselect needs).
- `Sources/Pisaka/LocalChangesView.swift` — `LocalChangesView`, `ChangeNodeView`,
  `ChangedFileRow` (the `onRevert` route).
- `Sources/Pisaka/ContentView.swift` — the callback threading into
  `panelContent(.changes)`.
- `Sources/Pisaka/PisakaApp.swift` — `openCommitDialog()` (~line 738) and the
  `ContentView` wiring (~line 210–237).
- `Tests/PisakaCoreTests/CommitDialogModelTests.swift` —
  `StubGit`/`StubFiles`/`makeTextRepo`/`makeModel` helpers already exist.
- Docs: `CLAUDE.md`, `README.md`.

Related patterns:

- The `onRevert` callback route `PisakaApp → ContentView → LocalChangesView →
  ChangedFileRow` (and `ChangeNodeView` for the by-folder mode), with a no-op default so
  previews/tests compile.
- `CommitDialogModel.load`'s generation discipline: `loadGeneration` +
  `rootRequestGeneration` re-checked after every `await`, all published state assigned in
  one main-actor turn.
- `CommitFileSelection.isIncludedInCommit` as the single inclusion rule shared by
  `CommitPlan.build` and `CommitGate`'s `selectedFileCount`.

Dependencies: none. No new files, so no `xcodegen generate` is required.

## Development Approach

- **Testing approach**: Regular (code first, then tests) — the Core change is small and
  the existing test helpers cover the setup.
- Complete each task fully before moving to the next.
- Core logic under tests; the view layer stays thin and untested (repo convention).
- **CRITICAL: every task MUST include new/updated tests**
- **CRITICAL: all tests must pass before starting the next task**

## Implementation Steps

### Task 1: Preselect mechanics in `CommitDialogModel`

**Files:**

- Modify: `Sources/PisakaCore/CommitDialogModel.swift`
- Modify: `Tests/PisakaCoreTests/CommitDialogModelTests.swift`

- [x] Add an internal pure static `selections(for facts: [CommitFileFacts], preselecting
  path: String?) -> [CommitFileSelection]`: with `nil` every file goes through the
  existing `defaultSelection(for:)` (today's behaviour, one implementation of "fully
  checked"); with a path, the file whose `facts.path` equals it gets
  `defaultSelection(for:)` and every other file gets `CommitFileSelection(facts:,
  selectedUnits: [], isChecked: false)`. Document that the comparison is by
  `ChangedFile.path`, i.e. the **new** path for a rename — the same value the Local
  Changes row carries — and that a path absent from the fresh list simply leaves every
  file unselected (honest, and `CommitGate` then blocks with `.nothingSelected`) rather
  than falling back to selecting everything.
- [x] Add `preselectedPath: String? = nil` to `load(root:request:)`. Apply it in the
  existing publish block — the same main-actor iteration, after the `generation ==
  loadGeneration, rootGeneration == rootRequestGeneration` guard — so no intermediate
  "everything checked" list is ever published.
- [x] Set `selectedPath` to the preselected path when it is present in the freshly loaded
  list (so the right-hand panel shows the file the user asked to commit), falling back to
  `files.first?.path` otherwise — the current behaviour for the no-preselect and
  vanished-path cases.
- [x] Document on `load` that the preselect is applied over the *freshly loaded* list (the
  dialog runs its own `git status`), and that the rest of the pipeline needs no change:
  `commit()` rebuilds selections from fresh facts by path via `withFacts`, so an empty
  selection stays empty and `CommitStaleness` only inspects planned paths.
- [x] Write tests: (a) preselecting one path — only it reports `isIncludedInCommit`,
  `selectedFileCount == 1`, its `CheckboxState` is `.checked` and the others
  `.unchecked`, `selectedPath` is that path; (b) preselecting a **whole-only** file with
  no units (deleted or binary) — two-state `.checked` checkbox, included in the commit,
  `CommitPlan.build` emits an entry for it; (c) preselecting a path absent from the fresh
  list — nothing selected, `selectedFileCount == 0`, `block == .nothingSelected` (with a
  non-empty message and a complete identity so the gate reaches that check); (d)
  preselecting a **renamed** file by its new path selects it; (e) an unchanged assertion
  that plain `load` with no preselect still checks everything (the existing
  `testLoadReadsContextIdentityAndFilesWithEverythingCheckedByDefault` stays green).
- [x] Run `swift test` — must pass before Task 2.

### Task 2: View-layer wiring for the context-menu item

**Files:**

- Modify: `Sources/Pisaka/LocalChangesView.swift`
- Modify: `Sources/Pisaka/ContentView.swift`
- Modify: `Sources/Pisaka/PisakaApp.swift`

- [x] `LocalChangesView`: add `var onCommitFile: (ChangedFile) -> Void = { _ in }` (the
  `onRevert` shape, no-op default) and thread it into both the flat `ChangedFileRow` list
  and `ChangeNodeView` (and recursively through its children) as a `() -> Void`.
- [x] `ChangedFileRow`: add `let onCommitFile: () -> Void` and a `Button("Commit…",
  action: onCommitFile)` in the `.contextMenu`, placed above the destructive Revert item
  (after the conflicted-file "Resolve…" + `Divider()` block). No extra enablement
  condition is needed — a row exists only when a folder is open, which is exactly the
  header Commit button's condition, and `openCommitDialog` re-checks the project root and
  its gates anyway; state that in a comment.
- [x] `ContentView`: add `var onCommitFile: (ChangedFile) -> Void = { _ in }` and pass it
  into `LocalChangesView` in `panelContent(.changes)`, beside
  `onRevert`/`onOpenDiff`/`onResolveConflict`/`onCommit`.
- [x] `PisakaApp`: change `openCommitDialog()` to `openCommitDialog(preselectingPath:
  String? = nil)` and forward it as `commitDialog.load(root:request:preselectedPath:)`;
  every existing call site (⌘K menu item, `onOpenCommitDialog`) keeps calling it with no
  argument. Wire `onCommitFile: { file in openCommitDialog(preselectingPath: file.path) }`
  into `ContentView`.
- [x] Extend `openCommitDialog`'s doc comment: the preselect is the only difference
  between the row item and ⌘K/the ✓ button; the gates, the flush, the modal suspension and
  the generation pinning are shared verbatim, which is why the orchestration is
  parameterized rather than duplicated.
- [x] No Core tests are added here (view layer is untested by convention); re-run `swift
  test` to confirm nothing regressed.

### Task 3: Verify acceptance criteria

- [x] `swift test` — full suite green.
- [x] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS'
  CODE_SIGNING_ALLOWED=NO build` — macOS build passes (unsigned, as CI builds it).
- [x] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination
  'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build` — the Core signature change
  compiles for iOS too (CI gate; `CODE_SIGNING_ALLOWED=NO` is required — the device-arch
  build has no signing identity in this environment and would otherwise fail at the
  signing step).

### Task 4: Update documentation

- [x] `CLAUDE.md`: update the `CommitDialogModel` entry (the `preselectedPath` parameter,
  the "only this path stays checked" rule, why the preselect is applied in the publish
  turn behind the generation guards, and the vanished-path outcome), the
  `LocalChangesView` entry (the new `onCommitFile` callback and its context-menu item,
  threaded through `ChangeNodeView`), the `ContentView` entry (the newly threaded
  callback), and the `PisakaApp.openCommitDialog` entry (parameterized rather than
  duplicated).
- [x] `README.md`: add the Commit… context-menu item to the Local Changes bullet and note
  in the commit-dialog bullet that everything starts checked *except* when the dialog is
  opened from a file's Commit… item, where only that file is.

## Post-Completion (manual)

- Right-click a file in Local Changes → **Commit…** → the dialog shows only that file
  checked and commits only it; repeat in by-folder grouping mode.
- ⌘K and the header ✓ button still open the dialog with every file checked.
- Preselect a deleted/binary file: its checkbox is a plain checked box (never mixed) and
  it commits.
