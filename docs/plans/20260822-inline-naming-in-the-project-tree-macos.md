# Inline naming in the project tree (macOS)

## Overview

Replace the three `FilePanels.promptName` dialogs behind New File / New Folder /
Rename with an in-tree editable draft row (Zed/Finder style). The view collects
the name; Core gains two small tested rules (the Rename field's initial
selection range, and the live collision check); the `PisakaApp` handlers keep
every gate, disk write, tab retargeting and refresh they perform today and
simply take the accepted text through reshaped callbacks. Nothing about what
gets created or moved changes. The writer gate is asked when the command is
chosen (same alert, same moment as today), not only at commit.

## Context

- Files involved:
  - Modify: `Sources/PisakaCore/FileName.swift` — two new rules + one new
    `EntryPathIssue` case.
  - Modify: `Tests/PisakaCoreTests/FileNameTests.swift`.
  - Create: `Sources/Pisaka/ProjectTreeDraftField.swift` (`#if os(macOS)`) —
    the AppKit-backed inline name field + reason line.
  - Modify: `Sources/Pisaka/ProjectTreeView.swift`,
    `Sources/Pisaka/ContentView.swift`, `Sources/Pisaka/PisakaApp.swift`.
  - Docs: `docs/architecture/app-window.md`, `docs/architecture/app-git-views.md`,
    `docs/architecture/app-shell.md`, `docs/architecture/core-workspace.md`;
    `CLAUDE.md` gets exactly one index line (a file is added).
- Related patterns:
  - `PromptNameDelegate`'s Enter interception and blank-is-incomplete rule
    (`FilePanels.swift`).
  - `SearchBarView.takeFocus`'s deferred first-responder handling.
  - `MoveDropRule`'s exact-name collision comparison.
  - `revertInFlight()` (PisakaApp.swift:3127), which beeps and alerts as its
    refusal side effect.
- Dependencies: none external.

## Development Approach

- **Testing approach**: Regular (code first, then tests) — the Core rules land
  together with their tests in Task 1, suite green before moving on.
- The view layer is untested by convention; its gate is the macOS/iOS builds
  plus `swiftlint --strict`.
- Complete each task fully before the next; `swift test` must be green at every
  task boundary.
- **CRITICAL: every task MUST include new/updated tests**
- **CRITICAL: all tests must pass before starting next task**

## Key decisions

- **Focus mechanism and the three-way end-editing test.** The draft field is an
  `NSViewRepresentable` hosting an `NSTextField`. Enter/Esc are intercepted via
  `control(_:textView:doCommandBy:)` (same pattern as `PromptNameDelegate`). A
  finishing flag set synchronously by commit/Esc stops the end-editing they
  cause from re-canceling. Why a flag and not a responder read:
  `controlTextDidEndEditing` is posted from inside the field editor's
  `resignFirstResponder`, i.e. during `NSWindow.makeFirstResponder(_:)` and
  BEFORE the new responder is installed — so at notification time a genuine
  click elsewhere in the window still shows the field or its editor as first
  responder, and no read of the window's first responder can distinguish
  click-away from teardown. The discriminator is instead a deterministic
  teardown flag: the hosted NSView subclass sets it in
  `viewWillMove(toWindow:)` when `newWindow == nil`, and the representable's
  `dismantleNSView(_:coordinator:)` sets it too — both run before AppKit ends
  editing, which is what makes the discrimination deterministic rather than a
  best-effort responder read. `controlTextDidEndEditing` is then decided by
  this three-way test:
  1. finishing flag set → ignore;
  2. teardown flag set, or `field.window == nil` → teardown, ignore entirely —
     the draft's fate is decided solely by the tree's own state rules
     (revision survival / target gone / project switch), never by an AppKit
     teardown notification;
  3. otherwise → user focus loss within the window, cancel silently.

  Teardown paths that can actually reach case 2: the `.id(root)` swap on
  project switch (moot — the draft is dropped by the projectRoot rule anyway),
  the enclosing folder of a create-draft collapsing (`configuration.content`
  removed), and a drafted rename entry vanishing from its parent's reloaded
  listing (the row leaves the `ForEach`; the target-gone rule drops the draft).
  Ordinary `treeRevision` bumps do not tear the field down:
  `DirectoryEntry.id` is the url, so the drafted rename row keeps its identity,
  and the create-draft row renders from the target node itself, before the
  `ForEach`. Window resign-key (⌘Tab) never fires end-editing at all — the
  field editor stays installed — which is what keeps case 3 an exclusively
  in-window signal.

- **Writer gate at command time.** A new `mayBeginFileOperation: () -> Bool`
  callback on `ProjectTreeView` (default `{ true }`) is wired through
  `ContentView` to `{ !revertInFlight() }`. Because `revertInFlight()` beeps
  and shows the "Git operation in progress" alert as its refusal side effect,
  calling it inside every New File / New Folder / Rename context-menu action
  reproduces today's behaviour exactly: during a revert/merge/branch-switch the
  alert appears immediately, at the moment the command is chosen, and no draft
  opens. The commit-time guards in the three handlers stay as defense-in-depth.

- **Layer split.** Core gets only pure decisions —
  `initialRenameSelection(in:isDirectory:) -> NSRange` (UTF-16 range over the
  name; dotfile, no-extension, trailing-dot, empty and any folder select whole;
  otherwise up to the LAST dot — `URL.deletingPathExtension` semantics, what
  Finder selects — e.g. `archive.tar.gz` selects `archive.tar`, and single-dot
  `a.b` selects `a`) and `liveCollisionIssue(finalComponent:siblingNames:excluding:)
  -> EntryPathIssue?` (exact `==` match against names already listed — the same
  comparison `MoveDropRule.decision` makes at ProjectTreeView.swift:207 — with
  `excluding` carrying the rename source's own name). A new `.nameTaken(String)`
  case carries the reason ("\"X\" already exists in this folder."). The view
  keeps which row is drafted (`private enum TreeEditDraft`), the typed text,
  reason display, expansion and scroll — no Core type is manufactured for view
  state.

- **Live collision check is single-component only.** The caller runs the check
  only when the trimmed input contains no `/` — one component. For a
  multi-component create the final component lands in a folder the tree has not
  listed (an intermediate the draft would create), so no siblings are passed
  and no `.nameTaken` is reported; the wording ("already exists in this
  folder") is only ever true under this restriction. Rename is always
  single-component by grammar. Siblings come from listings already in hand
  (target folder's loaded children; the entry's own parent listing) — no new
  disk reads, and skipped silently when no listing is available.

- **Invalid rendering.** Both treatments together: the field draws its text red
  (`.systemRed`) while an issue is displayed and restores label colour for
  blank or valid input, and the red reason line wraps under it (row height
  grows).

- **Drafted rows lose their row gestures.** A create-draft row installs none by
  construction (it is not a real row). While a *rename* draft is open on a row,
  `FolderDisclosureRow` suppresses its tap-to-expand, drag source (via the
  existing `projectTreeDragSource(isEnabled:)` opt-out branch), drop delegate,
  context menu and the combined-element button trait/expansion action (so
  VoiceOver reaches the embedded text field instead of actuating expansion);
  `FileRowView` suppresses tap-to-open, drag source and context menu. Hover
  highlight stays. Caret placement and text selection are therefore never
  competing with expansion, open, drag or menus.

- **`FilePanels.promptName` and `PromptNameDelegate` stay**: `newBranch()` and
  `createBranchFromRemote(_:)` (PisakaApp.swift:2544/2527) still use them. They
  stop being called by the three tree commands, which the docs will state.

## Implementation Steps

### Task 1: Core rules in FileName.swift with tests

**Files:**
- Modify: `Sources/PisakaCore/FileName.swift`
- Modify: `Tests/PisakaCoreTests/FileNameTests.swift`

- [x] Add `.nameTaken(String)` to `EntryPathIssue` with message "\"X\" already
      exists in this folder." (wording beside the other reasons)
- [x] Add `initialRenameSelection(in name: String, isDirectory: Bool) ->
      NSRange`: whole range for empty, dotfile (leading dot), no dot after
      position 0, trailing dot (empty extension), or directory; else
      0..<(last-dot index)
- [x] Add `liveCollisionIssue(finalComponent:siblingNames:excluding:) ->
      EntryPathIssue?`: exact-case match against `siblingNames`, skipping
      `excluding`; nil otherwise. Document on both rules that the *caller*
      invokes collision only for single-component input (a multi-component
      create lands its final component in a folder the tree has not listed)
- [x] Tests: selection edges — `file.swift` → 0..<4, `.gitignore` whole,
      `archive.tar.gz` → `archive.tar` (last-dot rule,
      `URL.deletingPathExtension` semantics), `a.b` → `a` (single-dot case
      pinned), `Makefile` whole (no extension), `Sources` as directory whole,
      `foo.` whole (trailing dot = empty extension), `.env` as directory whole,
      `""` zero-length whole; collision — hit reported with `.nameTaken`,
      case-differing sibling NOT reported (exact-match rule, same comparison
      `MoveDropRule` makes), self excluded via `excluding`, substring
      near-match not reported; message text pinned
- [x] run swift test - must pass before task 2

### Task 2: The draft field component (new macOS-only file)

**Files:**
- Create: `Sources/Pisaka/ProjectTreeDraftField.swift`

- [x] `TreeNameFieldView`: leading gutter/icon column drawn from the existing
      `TreeRowLayout` constants (folder draft = chevron-column slot + folder
      icon; file draft = gutter + icon resolved from the typed final component,
      generic while blank), the `NSTextField` representable, and below it the
      small red reason `Text` that wraps (`lineLimit(nil)`), so the row height
      grows naturally
- [x] Representable: becomes first responder on appearance (one deferred
      main-loop turn, `SearchBarView.takeFocus` pattern) and applies the
      preselected UTF-16 range to the field editor
- [x] Teardown signal: the hosted NSView subclass overrides
      `viewWillMove(toWindow:)` to set the teardown flag when `newWindow ==
      nil`; `dismantleNSView(_:coordinator:)` sets it as well; both run before
      AppKit ends editing, so the flag — not a responder read —
      deterministically separates teardown from click-away
- [x] Validation composition mirrors `PromptNameDelegate.revalidate`, in order:
      blank → incomplete (no reason, Enter refused, normal colour); then the
      caller-chosen validator (`validateRelativeEntryPath` for creates,
      `validateSingleEntryName` for rename) → its `.message`; then — **only
      when the trimmed input contains no `/`** — the live collision check over
      caller-supplied sibling names → `.nameTaken`; else committable. Issue
      state updates on every keystroke: the delegate reports `(text, issue)` up
      to SwiftUI for the reason line and sets the field's own treatment —
      `.systemRed` text while an issue shows, label colour for blank or valid
      input
- [x] Keys: newline-family commands commit-if-valid else beep
      (`PlatformFeedback.warning()`) and refuse; `cancelOperation:` cancels;
      `controlTextDidEndEditing` decided by the three-way test (finishing flag
      → ignore; teardown flag or `field.window == nil` → teardown, ignore;
      otherwise user focus loss → cancel silently)
- [x] Accessibility: the field carries an accessibility label naming the
      operation ("New File name" / "New Folder name" / rename-of-X); ordinary
      rows untouched
- [x] No new unit-testable logic lives here (view layer untested by convention;
      all decisions are Task 1 Core calls) — run swift test and xcodebuild
      (macOS + iOS) - must pass before task 3

### Task 3: Create-draft flow end-to-end

**Files:**
- Modify: `Sources/Pisaka/ProjectTreeView.swift`
- Modify: `Sources/Pisaka/ContentView.swift`
- Modify: `Sources/Pisaka/PisakaApp.swift`

- [x] `ProjectTreeView` holds `@State private var draft: TreeEditDraft?`
      (private Equatable enum: `.create(parent:isFolder:)` /
      `.rename(entry:)`); threaded down as a value + setter closures; a second
      command replaces the first
- [x] New `mayBeginFileOperation: () -> Bool` callback (default `{ true }`);
      every New File / New Folder menu action guards it *before* setting the
      draft — during a revert the same alert fires at the same moment as today
      and no draft opens; wired through `ContentView` to `{ !revertInFlight() }`
- [x] Folder context menus: actions set `.create` instead of calling callbacks;
      labels lose their ellipses (`New File`, `New Folder`)
- [x] Target node observes the draft targeting itself: expands if collapsed
      (the existing `onChange(of: isExpanded)` path loads children), renders
      the draft row as the literal first child *before* the `ForEach` with
      identical indent/padding/gutter/icon column; constant anchor id +
      root-level `ScrollViewReader` scrolls it into view; installs no
      tap/drag/drop/menu (it is not a real row)
- [x] Commit calls reshaped `onNewFile: (URL, String) -> Void` /
      `onNewFolder: (URL, String) -> Void` (raw text passed untrimmed) then
      clears the draft; Esc/focus-loss clear it without calling anything; disk
      failure reporting stays entirely app-side and dismisses the draft either
      way
- [x] Draft survives `treeRevision` bumps (nothing clears it there); dropped
      when the target folder's reload fails as missing (the node reports
      targeted-gone up), and on `projectRoot` change
- [x] Siblings for the collision check come from the target node's loaded
      children listing; a nil listing skips the check silently
- [x] `PisakaApp.newFile(in:name:)` / `newFolder(in:name:)`: drop the
      `promptName` call, keep writer-gate guard (defense-in-depth now),
      `parseRelativeEntryPath` defense-in-depth, `ensureDirectory`, create,
      open-in-tab, bump, failed-create refresh — bodies otherwise
      byte-identical
- [x] Existing suite stays green; xcodebuild both destinations - must pass
      before task 4

### Task 4: Rename draft flow

**Files:**
- Modify: `Sources/Pisaka/ProjectTreeView.swift`,
  `Sources/Pisaka/ContentView.swift`, `Sources/Pisaka/PisakaApp.swift`

- [x] File-row and folder-row menus show `Rename` (no ellipsis); action guards
      `mayBeginFileOperation` first, then sets `.rename(entry:)`
- [x] Label swap: while drafted, `FileRowView`'s name and `DirectoryNodeView`'s
      folder-label closure render `TreeNameFieldView` instead of the `Text` —
      pre-filled with `entry.name`, preselection from Core
      `initialRenameSelection(in:entry.isDirectory)`
- [x] While a row is drafted its tap (expand/open), drag source (via the
      existing `projectTreeDragSource(isEnabled:)` opt-out), drop delegate and
      context menu are suppressed, and the folder row drops its combined-element
      button trait and expansion action so VoiceOver reaches the embedded text
      field; hover highlight stays — caret placement and selection never
      compete with row gestures
- [x] Siblings come from the parent node's listing already in hand; collision
      excludes the entry's own current name (always single-component input
      here), so Enter on the unchanged name stays the silent no-op (app-side
      guard unchanged)
- [x] Parent node drops the draft when a reload loses the drafted entry's url
      from `children`
- [x] `onRename: (URL, String) -> Void`; `PisakaApp.renameItem(at:name:)`
      drops `promptName`, keeps trim, unchanged-name guard, `isValidFileName` +
      `isExcludedEntryName` guards, `performMove(from:to:)`
- [x] Menu ellipsis removal completed everywhere (folder rows and file rows);
      run swift test, swiftlint --strict, both builds - must pass before task 5

### Task 5: Documentation

**Files:**
- Modify: `docs/architecture/app-window.md`,
  `docs/architecture/app-git-views.md`, `docs/architecture/app-shell.md`,
  `docs/architecture/core-workspace.md`, `CLAUDE.md`

- [ ] app-window.md ProjectTreeView entry: the inline flow, the writer gate
      asked at command time (and kept at commit), the focus-loss rule
      (in-window end-editing cancels; window resign-key does not; the
      deterministic teardown flag — not a responder read — separates teardown
      from click-away), revision survival, gesture suppression on drafted rows,
      scroll/expansion, menu labels, layer split; a new entry for
      `ProjectTreeDraftField.swift`
- [ ] app-git-views.md FilePanels entry: `promptName` now serves only the two
      branch prompts (not dead code — stated)
- [ ] app-shell.md: New File/Folder/Rename orchestration now takes accepted
      text via callbacks; call-site list updated
- [ ] core-workspace.md FileName entry: the two new rules and the
      single-component restriction on the collision check
- [ ] CLAUDE.md: exactly one index line for `ProjectTreeDraftField.swift` under
      the app-window group; nothing else grows

### Task 6: Verify acceptance criteria

- [ ] run full test suite: `swift test` passes (including new FileNameTests
      cases)
- [ ] run linter: `swiftlint --strict` clean from repository root
- [ ] xcodebuild macOS build succeeds; xcodebuild iOS build succeeds

Post-completion manual checks (not automatable here): ⌘Tab away/back preserves
the draft and its typed text; click elsewhere cancels silently; during a revert
the alert fires when the menu command is chosen and no draft opens; VoiceOver
announces the draft field as a text field; caret placement inside a drafted
rename row does not toggle expansion or open the file; multi-component relative
path creates intermediates and refuses clobbering.
