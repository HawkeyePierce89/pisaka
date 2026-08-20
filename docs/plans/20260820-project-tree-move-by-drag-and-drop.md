# Project tree: move files and folders by drag and drop

## Overview

Add intra-tree drag and drop to the macOS project tree: any row except the
project root can be dragged onto a folder row (or the root row), which moves
the entry on disk and carries open tabs, the symbol index and the tree along.
All drop-validity and destination logic lands in one new pure `PisakaCore`
engine (`MoveDropRule`); the disk/tab/index choreography is the *existing*
rename sequence in `PisakaApp`, generalized so rename and move share one
ordering-sensitive path instead of two copies of it. The view layer only wires
the gesture to the engine.

## Context

- Files involved:
  - Create: `Sources/PisakaCore/MoveDropRule.swift` — the one drop engine.
  - Create: `Tests/PisakaCoreTests/MoveDropRuleTests.swift`.
  - Modify: `Sources/Pisaka/ProjectTreeView.swift` — drag source on every non-root
    row, drop target on folder/root rows, drop highlight, `onMove` callback.
  - Modify: `Sources/Pisaka/ContentView.swift` (~line 163, ~line 479) — thread
    `onMove` `PisakaApp → ContentView → ProjectTreeView`.
  - Modify: `Sources/Pisaka/PisakaApp.swift` — `renameItem(at:)` (~line 2977)
    generalized into a shared `performMove(from:to:)`; new `moveItem(at:into:)`;
    wiring at the `ContentView(` call (~line 673).
  - Modify: `Tests/PisakaCoreTests/WorkspaceModelTests.swift` — cross-directory
    `planRename` coverage (a folder move retargeting nested tabs).
  - Docs: `CLAUDE.md` (one index line), `docs/architecture/core-workspace.md`
    (the new Core file's entry), `docs/architecture/app-window.md` (the tree's
    drag/drop contract), `docs/architecture/app-shell.md` (the now-shared
    move/rename choreography, near its lines 209 / 491 / 576).
- Related patterns:
  - `CanonicalPath.canonical(_:)` / `relativeComponents(of:under:)` — the "same
    file?" / "inside this dir?" primitives, incl. the `/private` caveat.
  - `WorkspaceModel.planRename(from:to:)` / `applyRenamePlan(_:)` — prefix-based
    tab retarget, captured *before* the move, applied *after* it succeeds.
  - `FileServiceError` as a `LocalizedError` surfaced through
    `reportFileOperationFailure(_:)` (`NSAlert(error:)` + `PlatformFeedback.warning()`).
  - `TreeRowLayout` — the one place the tree's row geometry/highlight colors live.
  - `StubFileTree` (in-memory `FileServicing`) for the disk-fact tests; real temp
    dirs + `symlink` for the canonical cases, as `WorkspaceModelTests` already does.
- Dependencies: none new. macOS-only view code; Core stays Foundation-only.

## Development Approach

- **Testing approach**: Regular (code first, then tests) for the Core engine —
  written together with its tests in the same task, suite green before moving on.
- The view layer is untested by convention; its gate is the macOS/iOS builds.
- Complete each task fully before the next; `swift test` must be green at every
  task boundary.
- **CRITICAL: every task MUST include new/updated tests**
- **CRITICAL: all tests must pass before starting next task**

### Design decisions fixed up front

- **Two entry points, one engine.** `MoveDropRule.structuralDecision(source:into:)`
  is disk-free (canonical rules only) and answers the drag-hover question;
  `MoveDropRule.decision(source:into:fileService:)` adds the two disk facts
  (existence, name collision) and answers the drop question. Both return the same
  `MoveDropDecision` (`.move(destination:)` / `.refuse(MoveDropRefusal)`), so
  there is one vocabulary and one destination rule.
- **`MoveDropRefusal` is a `LocalizedError`** so a refused drop reports through
  the *existing* failure-alert path with no new alert code; `unchangedLocation`
  (the drop-onto-current-parent no-op) is marked silent and reports nothing.
- **Highlight fidelity.** The row highlights only on `.move`; a same-parent,
  self, descendant, collision or missing target does not light up. The full
  (disk-touching) decision is computed once per row entry and memoized on the
  shared drag session keyed by (source, target), so pointer movement inside a row
  costs no directory listings.
- **Payload.** The drag registers an `NSItemProvider` under a private type
  identifier (no `public.file-url`), so the tree neither offers file drags to
  Finder nor accepts foreign drops; the authoritative source URL is read from the
  shared drag session, which only the tree's own `.onDrag` sets.
- **Destination is `<target as the user spelled it>/<source's last component>`** —
  spelled paths stored, canonical paths compared, per the project's path rule.

## Implementation Steps

### Task 1: Core drop engine `MoveDropRule`

**Files:**
- Create: `Sources/PisakaCore/MoveDropRule.swift`
- Create: `Tests/PisakaCoreTests/MoveDropRuleTests.swift`

- [ ] Add `public enum MoveDropRefusal: Error, LocalizedError, Equatable` with
      `unchangedLocation`, `ontoItself`, `intoOwnDescendant`,
      `nameTaken(name:folder:)`, `sourceMissing(name:)`, `targetMissing(name:)`;
      an `isSilent` flag true only for `unchangedLocation`; `errorDescription`
      texts that name the entry (and the folder for a collision) and never quote
      `FileManager`'s own wording.
- [ ] Add `public enum MoveDropDecision: Equatable { case move(destination: URL);
      case refuse(MoveDropRefusal) }`.
- [ ] Add `MoveDropRule.structuralDecision(source:into:)`: canonical
      identity/ancestry through `CanonicalPath` — self → `ontoItself`, target
      inside source → `intoOwnDescendant`, target ≡ source's parent →
      `unchangedLocation`, otherwise `.move` with the spelled destination.
- [ ] Add `MoveDropRule.decision(source:into:fileService:)`: run the structural
      rules first, then list the target folder (a throw → `targetMissing`) for the
      name collision, and confirm the source still exists by listing its parent
      (absent → `sourceMissing`).
- [ ] Document in the file's header: why identity/ancestry is canonical and not
      textual; that a symlink row pointing at the target folder is refused as
      `ontoItself` (conservative, consistent with `planRename`); and that
      `FileService.move`'s own `alreadyExists` remains the backstop for a
      case-insensitive-volume collision the exact-name check cannot see.
- [ ] Write tests: destination shape (never renames); the parent no-op; self and
      one- and multi-level descendant refusals; refusals through *symlinked
      spellings* of self/parent/descendant using real temp dirs; the `/private`
      spelling; collision refusal (and no false collision when the only match is
      the source itself under a different parent); missing source; missing target;
      that a file dropped into an unrelated folder yields `.move`.
- [ ] Run `swift test` — must pass before task 2.

### Task 2: Share the rename choreography with move (app shell)

**Files:**
- Modify: `Sources/Pisaka/PisakaApp.swift`
- Modify: `Tests/PisakaCoreTests/WorkspaceModelTests.swift`

- [ ] Extract from `renameItem(at:)` a private `performMove(from:to:)` carrying
      the whole ordering-sensitive sequence unchanged: `planRename` *before* the
      move, the `retargetedURLs` capture beside it, `fileService.move`,
      `applyRenamePlan`, `forgetIndexedBuffer` per retargeted URL,
      `bumpTreeRevision()`, `notifyIndexOfProjectFileChanges()`, and
      `reportFileOperationFailure(_:)` on throw. Move the ordering comments onto it.
- [ ] Rewrite `renameItem(at:)` to keep only its prompt/validation and then call
      `performMove(from:to:)` — no second copy of the sequence.
- [ ] Add `moveItem(at:into:)`: `revertInFlight()` gate first, then
      `MoveDropRule.decision(source:into:fileService:)`; `.move` →
      `performMove`; `.refuse` → nothing at all when silent, otherwise
      `reportFileOperationFailure(refusal)`.
- [ ] Wire `onMove: { moveItem(at: $0, into: $1) }` into the `ContentView(` call.
- [ ] Add `WorkspaceModelTests` coverage that `planRename`/`applyRenamePlan`
      handle a *cross-directory* folder move (nested tabs retargeted, tab identity,
      dirty state and viewport preserved; an unrelated tab untouched).
- [ ] Run `swift test` — must pass before task 3.

### Task 3: Drag and drop in the tree view

**Files:**
- Modify: `Sources/Pisaka/ProjectTreeView.swift`
- Modify: `Sources/Pisaka/ContentView.swift`

- [ ] Add `var onMove: (URL, URL) -> Void = { _, _ in }` to `ProjectTreeView` and
      `ContentView`, threaded to `DirectoryNodeView`/`FileRowView` like the other
      row callbacks.
- [ ] Add a private reference-type drag session held by `ProjectTreeView`
      (`@StateObject`, deliberately no `@Published` so starting a drag re-renders
      nothing), storing the dragged source URL and the memoized decision for the
      current (source, target) pair; threaded down the recursive node the same way.
- [ ] Add `.onDrag` to `FileRowView` and to `FolderDisclosureRow` (skipped for the
      root row): set the session's source, return an `NSItemProvider` under the
      private type identifier. Keep the existing `.onTapGesture`, `.onHover` and
      `.contextMenu` on both row kinds untouched and in the same order.
- [ ] Add a private `DropDelegate` used by folder rows *and* the root row:
      `validateDrop` requires the private identifier, a session source and a
      `.move` decision (full decision, memoized); `dropEntered`/`dropExited` drive a
      per-row `isDropTarget` `@State`; `performDrop` calls `onMove(source, folder)`
      and clears the session.
- [ ] Draw the drop highlight from a new `TreeRowLayout.dropHighlight` constant
      (stronger than the hover highlight), applied where the hover background is,
      so the two treatments cannot drift apart; nothing new names `interfaceScale`
      and no zoom surface is declared.
- [ ] Run `swift test` (unchanged, must stay green) and build the macOS app
      (`xcodegen generate` + `xcodebuild … -destination 'platform=macOS' build`).

### Task 4: Verify acceptance criteria

- [ ] `swift test` fully green, including the gating suites
      (`ZoomSourceGatingTests`, `LSPSourceGatingTests`, `SparkleSourceGatingTests`).
- [ ] macOS **Release** build green:
      `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -configuration Release
      -destination 'platform=macOS' build`.
- [ ] iOS build green:
      `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka
      -destination 'generic/platform=iOS' build` — confirming nothing leaked into
      shared/Core code that breaks iOS.
- [ ] Re-read `renameItem` and `moveItem` to confirm a single `performMove` body
      and that the refusal path writes nothing (no `bumpTreeRevision`, no plan
      applied).

### Task 5: Update documentation

- [ ] `CLAUDE.md`: one index line for `MoveDropRule.swift` under the
      `core-workspace.md` group.
- [ ] `docs/architecture/core-workspace.md`: full entry for `MoveDropRule` — the
      two entry points, every refusal, why matching is canonical, the symlink and
      case-insensitive-collision notes.
- [ ] `docs/architecture/app-window.md`: extend the `ProjectTreeView` entry with
      the drag/drop contract — who is draggable, who is a target, the private
      payload identifier, the memoized validation, the drop highlight beside the
      hover one, and the explicit statement that the row toggle, its accessibility
      re-declaration, the hover highlight and the context menus are unchanged.
- [ ] `docs/architecture/app-shell.md`: record that rename and move now share
      `performMove(from:to:)` (plan before, apply after) and that `moveItem`
      consults `MoveDropRule` behind the writer gate, reporting non-silent
      refusals through the existing failure alert.

## Post-Completion (manual, by the user)

- Run the app: drag a folder containing open tabs into another folder — tabs keep
  content, dirty state, undo stack and viewport, and show the new path; the tree
  shows the entry in its new place with no manual collapse/expand.
- Drag onto the project root row; drag onto the current parent (nothing happens);
  drag onto a descendant and onto a colliding name (no highlight / clear message).
- Confirm right-click menus, click-to-toggle and hover highlighting are unchanged.
