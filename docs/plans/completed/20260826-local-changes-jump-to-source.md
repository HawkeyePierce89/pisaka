# Local Changes: Jump to Source (context menu + Cmd+Down)

## Overview

A changed-file row in the Local Changes panel can be diffed, committed and reverted,
but not opened. This adds a **Jump to Source** context-menu item to every
non-deleted changed-file row and a **Cmd+Down** shortcut that does the same for the
selected row while the panel owns keyboard focus. Both route through the existing
`onOpenFile` handler the project tree already uses, and the keystroke is a second
case in the focus anchor the Show Diff / Cmd+D change introduced — not a second
anchor and not a second event monitor.

The decision ("may this row jump, and where?") is added to the pure row-activation
rules already living on `LocalChangesModel`; the view stays a dispatcher.

## Context

- Files involved:
  - `Sources/PisakaCore/LocalChangesModel.swift` — the `// MARK: - Row activation`
    block (`RowActivation`, `activation(for:)`, `shortcutActivation(selected:)`,
    `offersShowDiff(for:)`) gains the jump rules.
  - `Tests/PisakaCoreTests/LocalChangesModelTests.swift` — the
    `// MARK: - pure helpers: row activation` section gains the new cases.
  - `Sources/Pisaka/LocalChangesView.swift` — `ChangedFileRow`'s `.contextMenu`,
    the `onOpenFile` thread through `LocalChangesView` → `ChangeNodeView` → row,
    and `LocalChangesFocusAnchor` / `LocalChangesFocusAnchorView`.
  - `Sources/Pisaka/ContentView.swift` — line ~430, the `LocalChangesView(...)`
    construction; `ContentView` already holds `onOpenFile: (URL) -> Void` (line 166)
    for the project tree, so nothing new is threaded from `PisakaApp`.
  - `docs/architecture/core-git-models.md` (the row-activation paragraph, ~line 78),
    `docs/architecture/app-git-views.md` (the `ChangedFileRow`/focus-anchor entry,
    ~lines 495–545), `docs/FEATURES.md` (the Local Changes bullet at ~line 631 and
    the Cmd+D bullet at ~line 246), `README.md` (shortcut table, ~line 89).

- Related patterns:
  - `PisakaApp.openFile(url:)` → `WorkspaceModel.open(url:)`, wired into
    `ContentView` as `onOpenFile: { openFile(url: $0) }` (PisakaApp.swift:798). It
    beeps on failure. **Not touched.**
  - The existing gate in `LocalChangesFocusAnchorView.performKeyEquivalent`:
    `charactersIgnoringModifiers?.lowercased() == "d"` +
    `modifierFlags.intersection([.command, .shift, .option, .control]) == [.command]`
    + `window?.firstResponder === self`.
  - `LocalChangesModel.revertedURLs(for:root:)` — the precedent for resolving a
    repo-relative `ChangedFile.path` against a root in Core.

- Dependencies: none. macOS-only surface; no iOS file is touched.

## Decisions recorded up front

1. **A deleted row hides the item rather than disabling it.** This menu already
   has that precedent: "Show Diff" is *omitted* for a conflicted row (replaced by
   "Resolve…") instead of being shown greyed out. A permanently dead row in a
   four-item menu is noise; the absent item says the same thing.

2. **The jump resolves against `model.root`, not `projectRoot`.** `ChangedFile.path`
   is repository-root-relative and the opened folder may be a subdirectory of the
   repository; `LocalChangesView.url(for:)` uses `projectRoot` only for icon
   resolution and would resolve to a nonexistent path in that case. The Core helper
   therefore takes the root explicitly, as `revertedURLs(for:root:)` does.

3. **Focus handoff belongs to the keystroke only.** After a successful Cmd+Down the
   anchor hands first responder to the window's editor text view (the open path
   never does this itself — verified: neither `openFile(url:)` nor the Find in
   Files / Go to Definition reveal path calls `makeFirstResponder`). The
   context-menu item does *not* move focus, matching every existing item in this
   menu (Show Diff, Resolve…, Commit…), which is pointer-driven activation and
   leaves keyboard focus where the user put it.

4. **Only the character test differs from the Cmd+D gate.** An arrow event carries
   `.function` and `.numericPad` in `modifierFlags` and a function-key scalar in
   `charactersIgnoringModifiers`. The existing mask comparison is an
   `intersection([.command, .shift, .option, .control])`, which already masks those
   two flags out — so it is reused verbatim and *only* the character comparison
   changes, to `NSDownArrowFunctionKey`. This is stated in a comment so the next
   reader does not "fix" it into a `deviceIndependentFlagsMask` equality that would
   never match an arrow key.

## Development Approach

- **Testing approach**: Regular (Core code first, then its tests) — the view layer
  is untested by project convention, so all new tests are `PisakaCore` tests.
- Complete each task fully before moving to the next.
- **CRITICAL: every task that changes Core MUST include new/updated tests.**
- **CRITICAL: `swift test` must pass before starting the next task.**
- No brand or product names anywhere in code, comments, docs or commit messages.

## Implementation Steps

### Task 1: The pure jump decision in Core

**Files:**
- Modify: `Sources/PisakaCore/LocalChangesModel.swift`
- Modify: `Tests/PisakaCoreTests/LocalChangesModelTests.swift`

- [x] In the `// MARK: - Row activation` block, add
      `public static func offersJumpToSource(for status: FileStatus) -> Bool`,
      returning `status != .deleted`, with a doc comment stating *why* (a deleted
      file has no worktree source; the item is omitted rather than disabled, and
      that this matches `offersShowDiff(for:)`'s omission precedent).
- [x] Add `public static func jumpToSourceURL(for file: ChangedFile, root: URL) -> URL?`
      returning `nil` when `offersJumpToSource(for: file.status)` is false and
      `root.appendingPathComponent(file.path)` otherwise. Document that a renamed
      file jumps to its *new* path (`file.path`), never `oldPath`, which no longer
      exists on disk, and that `root` is the repository top level for the same
      reason `revertedURLs(for:root:)` takes one.
- [x] Add `public static func shortcutJumpToSourceURL(selected: ChangedFile?, root: URL?) -> URL?`
      returning `nil` when either is `nil` — the keystroke is consumed by the
      focused panel and does nothing, the same deliberate no-op
      `shortcutActivation(selected:)` documents — and delegating otherwise.
- [x] Tests in the `// MARK: - pure helpers: row activation` section:
      `offersJumpToSource` for **every** `FileStatus` case (true for modified,
      added, renamed, untracked, conflicted; false for deleted), driven off
      `FileStatus.allCases` the way `testOffersShowDiffForEveryStatusExceptConflicted`
      is, so a new status cannot be silently missed.
- [x] Tests: `jumpToSourceURL` returns the root-joined path for a non-deleted file,
      `nil` for a deleted one, and the *new* path for a renamed file that also
      carries an `oldPath`.
- [x] Tests: `shortcutJumpToSourceURL` with `selected: nil`, with `root: nil`, with
      a deleted selection (all `nil`), and with an ordinary selection (the URL).
- [x] Run `swift test` — must pass before Task 2.

### Task 2: The context-menu item and its wiring

**Files:**
- Modify: `Sources/Pisaka/LocalChangesView.swift`
- Modify: `Sources/Pisaka/ContentView.swift`

- [x] Add `var onJumpToSource: (ChangedFile) -> Void = { _ in }` to
      `LocalChangesView`, defaulted to a no-op like its sibling callbacks so
      previews compile, and thread it through `ChangeNodeView` (recursively) to
      `ChangedFileRow` exactly as `onOpenDiff`/`onCommitFile` are threaded.
- [x] In `ChangedFileRow.contextMenu`, insert
      `if LocalChangesModel.offersJumpToSource(for: status) { Button("Jump to Source", action: onJumpToSource) }`
      immediately after the Show Diff / Resolve… branch and before "Commit…", so
      the order stays non-destructive items first, "Revert" last.
- [x] In `ContentView`'s `LocalChangesView(...)` construction, pass
      `onJumpToSource: { jumpToSource($0) }` where `jumpToSource` is a small private
      helper on `ContentView` that resolves
      `LocalChangesModel.jumpToSourceURL(for:root:)` against `localChanges.root` and
      calls the existing `onOpenFile` — no new callback from `PisakaApp`, no second
      open path. A `nil` URL (no root yet) does nothing.
- [x] Build the macOS target (`xcodebuild -project Pisaka.xcodeproj -scheme Pisaka
      -destination 'platform=macOS' build`) — must succeed before Task 3.

### Task 3: Cmd+Down in the focus anchor, with the editor focus handoff

**Files:**
- Modify: `Sources/Pisaka/LocalChangesView.swift`

- [x] Give `LocalChangesFocusAnchor` and `LocalChangesFocusAnchorView` two new
      inputs — `repositoryRoot: URL?` (passed `model.root`) and
      `onOpenFile: (URL) -> Void` — mirroring how `selectedFile`/`onOpenDiff` are
      already stored and refreshed in `updateNSView`.
- [x] Add the Cmd+Down case to `performKeyEquivalent(with:)`, structured as a second
      gate beside the Cmd+D one (extract each into a small private
      `handleShowDiff(_:)` / `handleJumpToSource(_:)` returning `Bool` if that reads
      better than one long guard chain). The character test is
      `event.charactersIgnoringModifiers == String(UnicodeScalar(NSDownArrowFunctionKey)!)`;
      the modifier test and the `window?.firstResponder === self` test are the
      existing ones unchanged. Anything else still falls through to `super`.
- [x] On a passing gate, resolve
      `LocalChangesModel.shortcutJumpToSourceURL(selected: selectedFile, root: repositoryRoot)`.
      `nil` (no selection, a deleted row, or no root) returns `true` — consumed,
      silent, no beep. A URL calls `onOpenFile(url)` and then hands focus to the
      editor.
- [x] Add the focus handoff as one small private method on the anchor view: walk the
      window's content view for the first `EditorTextView` descendant and
      `makeFirstResponder` it, dispatched asynchronously on the main queue so the
      tab SwiftUI is about to build exists by then. Finding nothing (no folder open,
      or the open failed — which already beeps in `openFile(url:)`) leaves focus
      where it is. Document both the async hop and the not-found case in the method's
      doc comment, plus the one honest limitation: the handoff cannot see whether the
      open succeeded, so a failed open with another tab already showing focuses that
      tab's editor — the beep is the failure signal.
- [x] Update the anchor's type-level doc comment: it now intercepts two keys, and the
      Cmd+D comment about "the same gate shape as `EditorTextView`" gains the arrow-key
      note from Decision 4.
- [x] Run `swiftlint --strict` from the repository root — must be clean before Task 4.

### Task 4: Documentation

**Files:**
- Modify: `docs/architecture/core-git-models.md`
- Modify: `docs/architecture/app-git-views.md`
- Modify: `docs/FEATURES.md`
- Modify: `README.md`

- [x] `core-git-models.md`: extend the row-activation paragraph with the three new
      static rules — `offersJumpToSource(for:)` (false for `.deleted`, and why),
      `jumpToSourceURL(for:root:)` (repository root, the renamed-file new-path rule)
      and `shortcutJumpToSourceURL(selected:root:)` (`nil` = consumed no-op) — and
      say that these too are the single routing point, shared by the context-menu
      item and Cmd+Down.
- [x] `app-git-views.md`: in the `LocalChangesView` entry, record the fourth
      context-menu item and the new menu order (Show Diff / Resolve…, Jump to Source,
      Commit…, Revert), the `onJumpToSource` thread and that it lands on the *same*
      `onOpenFile` the project tree uses; then in the focus-anchor paragraph, the
      second `performKeyEquivalent` case, why only the character comparison differs
      for an arrow key, and the editor focus handoff with its async hop, its
      not-found case and the pointer-vs-keyboard asymmetry from Decision 3.
- [x] `docs/FEATURES.md`: extend the Local Changes bullet (~line 631) with Jump to
      Source and Cmd+Down — including that a deleted file offers neither, that a
      conflicted file jumps normally to its marker-carrying worktree copy, that an
      empty selection is a silent no-op, and that a successful jump moves keyboard
      focus into the editor. Add the same one-clause mention to the Cmd+D bullet
      (~line 254) so the panel's two keys are described together.
- [x] `README.md`: add one shortcut-table row —
      `| Cmd+Down | Jump to Source when Local Changes has focus |` — placed next to
      the Cmd+D row. It fits the existing one-line format without bloating it.
- [x] Confirm no brand or product name was introduced by any of the above (do not
      touch the pre-existing ones elsewhere in these files — out of scope).

### Task 5: Verify acceptance criteria

- [x] `swift test` — green.
- [x] `swiftlint --strict` from the repository root — clean.
- [x] `xcodegen generate` then
      `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' build`
      — green.
- [x] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'generic/platform=iOS' build`
      — green (nothing iOS changed; this is the regression gate).
- [x] Re-read the acceptance criteria and confirm each is met by code, not by
      intention: every `FileStatus` covered by a Core test, the no-selection case
      covered, and no decision in the view that Core does not carry.

## Post-Completion (manual, by the author)

- In a DEBUG build: right-click a modified row → "Jump to Source" opens the file;
  a deleted row shows no such item; a conflicted row shows it and opens the
  marker-carrying file.
- With the panel focused and a row selected, Cmd+Down opens the file and the caret
  lands in the editor; Cmd+D still opens the diff; a deleted row and an empty
  selection do nothing and do not beep.
- In the editor, Cmd+Down still moves the caret to the end of the document, and
  Cmd+Shift+Down still extends the selection there.
