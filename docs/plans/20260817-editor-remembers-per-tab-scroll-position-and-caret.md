# Editor remembers per-tab scroll position and caret across tab switches

## Overview

The macOS editor reuses one `NSTextView` across every tab. `CodeEditorView.updateNSView`
detects a tab switch (`switchedFile`), replaces the whole buffer with the incoming
file's text, and nothing anywhere records where the outgoing tab was. The reader
returns to the top of the file with the caret at offset 0.

This adds a per-file *viewport memory* that lives in the coordinator for the app run,
exactly beside the per-file undo managers it mirrors: the outgoing tab's selection and
its first visible character offset are captured before the buffer swap, and restored
synchronously in the same update that installs the incoming file's contents. The scroll
anchor is a **character offset**, not a point, so a code-zoom change between visits
cannot produce a wrong position. All the rules (clamping to the new buffer length,
what the memory keeps and forgets) are pure and live in `PisakaCore` with tests; the
AppKit reads/writes stay thin in `CodeEditorView.Coordinator`.

## Context

- Files involved:
  - Create: `Sources/PisakaCore/EditorViewport.swift` — the value type + the memory store.
  - Create: `Tests/PisakaCoreTests/EditorViewportTests.swift`.
  - Modify: `Sources/Pisaka/CodeEditorView.swift` — `updateNSView` ordering, new
    `Coordinator` capture/restore glue, pruning.
  - Modify: `docs/architecture/core-editor.md`, `docs/architecture/app-editor.md`, `CLAUDE.md`.
- Related patterns:
  - Per-file undo managers: `Coordinator.undoManagers` + `undoManager(for:)` +
    `pruneUndoManagers(keeping:)` (`CodeEditorView.swift:1504-1521`) — the viewport memory
    is keyed by the same `fileID` and pruned by the same `openFileIDs` set on the same call.
  - `noteExternalTextRevision(_:for:)` (`CodeEditorView.swift:1533`) — the existing detector
    for "this background tab's buffer was replaced out from under it", already used to drop
    the stale undo stack at `CodeEditorView.swift:464`. The viewport entry is dropped by the
    same signal.
  - `applyReveal(_:fileID:)` (`CodeEditorView.swift:1098`) — the Find in Files /
    go-to-definition one-shot reveal, consumed by token at the end of `updateNSView`.
  - `scrollEditor(to:)` (`CodeEditorView.swift:1457`) — already clamps a document-space top
    offset to `max(0, textView.frame.height - clipView.bounds.height)` and reflects the
    scroll, which is the "never past the end of the document" requirement for free.
- Dependencies: none new.
- Notable constraint: `textView.layoutManager?.allowsNonContiguousLayout = true`
  (`CodeEditorView.swift:242`), so laying out is lazy — the restore must explicitly ensure
  layout for the anchor before asking for its rect, which is what lets the restore stay
  synchronous (no `DispatchQueue.main.async` hop that a fast second switch could race).

## Development Approach

- **Testing approach**: Regular (code first, then tests) for Core; the view layer is
  untested by convention (`Sources/Pisaka` ships no tests).
- Complete each task fully before moving to the next.
- Core stays Foundation-only; no AppKit type crosses into `PisakaCore`.
- **CRITICAL: every task MUST include new/updated tests**
- **CRITICAL: all tests must pass before starting the next task**

## Implementation Steps

### Task 1: Core viewport value type and memory

**Files:**
- Create: `Sources/PisakaCore/EditorViewport.swift`
- Create: `Tests/PisakaCoreTests/EditorViewportTests.swift`

- [ ] Add `public struct EditorViewport: Equatable`: `selection: NSRange` (the caret or
      the selected range, UTF-16) and `topCharacterOffset: Int` (the UTF-16 offset of the
      first character visible at the top of the viewport). Document *why* the scroll anchor
      is a character offset and not a point: the document geometry is not stable between
      visits (code zoom, an edit from another path), so points do not survive a round trip.
- [ ] Add `func clamped(toLength length: Int) -> EditorViewport`: `topCharacterOffset`
      clamped into `0...length`; `selection.location` clamped into `0...length` with the
      length truncated to `length - location` (truncate, never intersect — the same reasoning
      the reveal path already documents: a caret sitting exactly at the buffer end must stay
      there, not jump to `{0, 0}`); a `NSNotFound`/negative location collapses to `{0, 0}`.
- [ ] Add `public struct EditorViewportMemory` holding `[UUID: EditorViewport]` with
      `record(_:for:)`, `forget(_:)`, `prune(keeping openFileIDs: Set<UUID>)` and
      `viewport(for:clampedToLength:) -> EditorViewport?` (nil when nothing was recorded —
      that is the "shown for the first time keeps today's behavior" rule, expressed once).
- [ ] Write tests: an unrecorded id answers nil; a recorded one round-trips; `forget` and
      `prune` drop entries (and `prune` keeps the still-open ones); clamping covers a caret
      past the new end, a selection straddling the new end, a caret exactly at the end, a
      `NSNotFound` location, an anchor past the new end, and length 0 (empty buffer).
- [ ] Run `swift test` — must pass before Task 2.

### Task 2: Coordinator capture/restore glue

**Files:**
- Modify: `Sources/Pisaka/CodeEditorView.swift`

- [ ] Add `private var viewports = EditorViewportMemory()` to `Coordinator`.
- [ ] Add `func captureViewport() -> EditorViewport?`: read `textView.selectedRange()`, and
      resolve the top visible character by asking the layout manager for the glyph at the
      clip view's `documentVisibleRect` top-left (accounting for `textContainerOrigin`) and
      converting it to a character index. Return nil when the text view/scroll view/layout
      manager is unavailable.
- [ ] Add `func recordViewport(for fileID: UUID)` / `func forgetViewport(for fileID: UUID)`
      writing into the memory, and extend the existing prune call site to prune the memory
      too — rename `pruneUndoManagers(keeping:)` to `prunePerFileState(keeping:)`, since it
      already prunes `externalTextRevisions` as well and now prunes a third dictionary; update
      its doc comment and the one call site.
- [ ] Add `func restoreViewport(for fileID: UUID)`: fetch the entry clamped to the live
      `textStorage.length`; return if there is none. Apply `setSelectedRange` first, then
      `layoutManager.ensureLayout(forCharacterRange:)` up to the anchor and take
      `boundingRect(forGlyphRange:in:)` for it, and scroll through the existing
      `scrollEditor(to:)` (which clamps to the document's real end) with the container inset
      added back. Everything synchronous — document in the comment that the explicit
      `ensureLayout` is what replaces the reveal path's `DispatchQueue.main.async` hop, and
      why a hop is not acceptable here (a fast second tab switch would land the restore in
      the wrong buffer).
- [ ] Handle the end-of-buffer edge the Core clamp deliberately allows: when the clamped
      anchor equals `textStorage.length` (a shrunk buffer, or an empty file), the glyph range
      at that offset is empty and `boundingRect(forGlyphRange:in:)` answers a zero/garbage
      rect — take the document end instead, from the layout manager's
      `extraLineFragmentRect` when it is in use or the last character's line fragment
      otherwise, and let the existing `scrollEditor(to:)` clamp remain the final guard. The
      same offset needs no special case for `setSelectedRange`: a caret at `length` is legal.
- [ ] Add `func hasPendingReveal(_ request: EditorRevealState.Request?, fileID: UUID) -> Bool`
      — the same guards `applyReveal` uses (non-nil, token not yet applied, matching file),
      without consuming anything, so `updateNSView` can let an explicit reveal win.
- [ ] No Core tests here (view layer, untested by convention); the Task 1 suite must still
      pass — run `swift test`.

### Task 3: Wire capture and restore into the update sequence

**Files:**
- Modify: `Sources/Pisaka/CodeEditorView.swift`

- [ ] In `updateNSView`, capture the previous `context.coordinator.fileID` before it is
      overwritten and, when `switchedFile` and a previous id exists, record its viewport
      **before** anything touches the buffer — i.e. above the `textView.string = text` swap.
      Comment the ordering constraint the way the neighbouring steps are commented.
- [ ] Keep the record *before* `prunePerFileState(keeping: openFileIDs)`, so closing the
      displayed tab records and then immediately discards it — closed tabs retain nothing.
- [ ] When `externallyReplaced` is true for the incoming file, `forgetViewport(for: fileID)`
      in the same branch that clears the undo stack, so a Replace All / post-revert reload /
      merge apply that rewrote a background tab yields a plain top-of-file state rather than
      a viewport describing text that no longer exists.
- [ ] Compute `hasPendingReveal(...)` before the restore, and restore the viewport only when
      `switchedFile` and no reveal is pending for this file — placed immediately before the
      existing `applyReveal` call, i.e. after the highlighter/minimap/bracket/search/blame
      reconciliation, so the scroll's bounds notification refreshes geometry that is already
      correct for the incoming file.
- [ ] Run `swift test` (must stay green) and build the macOS app:
      `xcodegen generate && xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' build`.

### Task 4: Verify acceptance criteria

- [ ] Run the full suite: `swift test` — all green.
- [ ] Build macOS Release the way CI does:
      `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' -configuration Release build`.
- [ ] Build iOS to confirm nothing macOS-only leaked into shared code:
      `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'generic/platform=iOS' build`.
- [ ] Re-read the changed `updateNSView` block and confirm the documented order still holds:
      capture → prune → buffer swap → per-file reconciliation → restore → reveal.

### Task 5: Update documentation

- [ ] `docs/architecture/core-editor.md`: add the `EditorViewport.swift` entry — the value
      type, the clamp rules and why truncation rather than intersection, the memory's
      record/forget/prune contract, and why the anchor is a character offset.
- [ ] `docs/architecture/app-editor.md`: extend the `CodeEditorView` entry with the viewport
      capture/restore step in the order-sensitive `updateNSView` sequence, its pairing with
      the per-file undo managers (same key, same prune, same `externalTextRevision` drop),
      the synchronous-restore rationale (`ensureLayout` instead of a main-loop hop), the
      anchor-at-buffer-end special case (why an empty glyph range cannot give the scroll
      offset), and the explicit reveal-wins rule; note the `pruneUndoManagers` →
      `prunePerFileState` rename.
- [ ] `CLAUDE.md`: one index line for `EditorViewport.swift` under the `core-editor.md`
      section. No new invariant paragraph — this is view-layer state under an existing rule.

## Post-Completion Manual Verification (requires running the app)

- Open file A, scroll to the bottom, switch to B, switch back: A shows the same place with
  the caret where it was left; bouncing between the two tabs keeps both places.
- Edit A, switch away and back: the post-edit position is preserved and ⌘Z behaves as before.
- Run a project Replace All that rewrites a background tab, then switch to it: valid,
  in-bounds state, no exception (top of file is the accepted outcome).
- Activate a Find in Files result in an already-open background tab: it scrolls to the match,
  not to the remembered position.
- Close a tab and reopen the same file: it starts at the top.
- Change the editor font size between two visits to the same tab: no crash, position sane.
- Switch away from a tab sitting at the very end of a file, and from an empty file, then back:
  the view lands at the document end / top with no stray offset.
