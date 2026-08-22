# Inline naming: fix the two focus defects and close out the review findings

## Overview

The inline-naming draft (PR #29) passed twelve live-review behaviours and failed
two, both about focus. This ticket fixes those two, plus the documentation and
hygiene findings that came with them. The feature's contract does not change:
validation composition, the collision rule, the commit paths and the menu wiring
stay exactly as they are, except where a finding below names them.

Two decisions this plan makes up front, because everything else follows from
them:

**A. The dismissing click is not swallowed.** A mouse-down outside the draft
cancels it *and* proceeds to its ordinary effect — the folder toggles, the file
opens, the context menu opens for the row it was pressed on. This is what Finder
does (a click outside an inline rename ends the rename and selects/opens what was
clicked) and what Zed does; a swallow-the-first-click rule would make the user
click twice for one intent. The cancellation is a SwiftUI state change, which
invalidates layout for the *next* display pass, so the click AppKit dispatches
immediately after the monitor returns still hit-tests the geometry the user was
looking at — the row that shifts up after the draft disappears is not the row
that gets the click.

**B. The region the click is tested against is a real view, not a computed
rectangle.** The draft is a SwiftUI `VStack` (icon column + `NSTextField` +
reason line); only the field is an `NSView`, so hit-testing "inside the draft"
against the field's frame would miss the icon and the reason line, and
reconstructing the draft's rect from SwiftUI's `.global` space would mean
guessing at flipped-coordinate conversions. So the draft grows one invisible
`NSViewRepresentable` in its `.background` — SwiftUI sizes a background to its
primary view, so that view's `bounds` *is* the draft's rectangle, by
construction. That view owns the local `NSEvent` monitor and answers
inside/outside by converting the event point into its own coordinates. It
hit-tests to `nil`, so it intercepts nothing.

## Context

- Files involved:
  - `Sources/Pisaka/ProjectTreeDraftField.swift` — the draft field (282 lines,
    no doc comments today); gets the monitor, the focus fix, the height fix and
    its contracts.
  - `Sources/Pisaka/ProjectTreeView.swift` — header comment, three `draft!`
    sites, the empty context menu on drafted rows, `color(for:)` /
    `TreeRowLayout` visibility.
  - `Sources/Pisaka/PisakaApp.swift` — stale doc comments on `newFile(in:name:)`,
    `newFolder(in:name:)`, `renameItem(at:newName:)`.
  - `Sources/PisakaCore/FileName.swift` — wrong `initialRenameSelection` doc
    comment.
  - `Sources/PisakaCore/TreeDraftDismissRule.swift` — new (the pure click rule).
  - `Tests/PisakaCoreTests/TreeDraftDismissRuleTests.swift` — new.
  - `docs/architecture/app-window.md` — damaged paragraph, re-wrap, the new focus
    rule.
  - `docs/architecture/core-workspace.md`, `CLAUDE.md` — index/entry for the new
    Core file.
- Related patterns:
  - `Sources/Pisaka/ZoomController.swift` — the repo's one blessed
    local-`NSEvent`-monitor shape: `addLocalMonitorForEvents`, token stored,
    `MainActor.assumeIsolated` in the closure, explicit uninstall. The new
    monitor copies its lifetime discipline but is installed per draft, not per
    app run.
  - `Sources/Pisaka/FilePanels.swift` `promptFieldHeight(of:)` — the retired
    dialog's height-from-content calculation; the inline field needs the same
    idea in `NSViewRepresentable` shape.
  - `Sources/PisakaCore/MoveDropRule.swift` — the tree's other pure decision
    rule, and the model for where the new one lives and how it is documented.
- Dependencies: none. macOS-only, all under the existing `#if os(macOS)`.

## Development Approach

- **Testing approach**: Regular (code first, then tests). The only new testable
  rule is the Core click decision; the rest is view wiring, which stays untested
  by convention (`swift test` cannot see AppKit focus or an `NSEvent` monitor).
- Complete each task fully before the next; `swift test` and `swiftlint --strict`
  must be clean at the end of every task.
- Read the file's entry in `docs/architecture/` before touching it, and update
  that entry in the same task when behaviour changes.
- No new in-file `swiftlint:disable` markers (`LintConfigurationTests` counts
  them).

## Implementation Steps

### Task 1: The pure click rule in Core

**Files:**
- Create: `Sources/PisakaCore/TreeDraftDismissRule.swift`
- Create: `Tests/PisakaCoreTests/TreeDraftDismissRuleTests.swift`
- Modify: `docs/architecture/core-workspace.md`, `CLAUDE.md`

Intent: state, once and testably, what a mouse-down means to an open draft, so
the view layer holds no policy — only the AppKit facts (which window, which
point, which rect).

- [x] add `TreeDraftDismissRule.decision(clickedWindowIsDraftWindow:point:draftBounds:)`
      returning a two-case `TreeDraftClickDecision` (`ignore` / `cancel`), with
      the contract documented in full: a click in another window is always
      `ignore` (that window's business — Find in Files, a diff window, an
      alert); a click inside the draft's bounds is `ignore` (caret placement and
      drag-selection are ordinary edits); anything else in the draft's own window
      is `cancel`; `cancel` **never** means "swallow the event" (decision A
      above) — the rule decides the draft's fate, not the click's; edge semantics
      are `CGRect.contains` (half-open, so the bottom/right edge is outside), and
      an empty or null rect is `cancel` because a draft with no measured area
      cannot own a click
- [x] write tests covering: other window ignored regardless of point; inside →
      ignore; outside on each of the four sides → cancel; the two contains-edge
      cases; empty and `.null` bounds → cancel
- [x] add the one-line index entry in `CLAUDE.md` beside `MoveDropRule.swift` and
      the full entry in `docs/architecture/core-workspace.md`
- [x] run `swift test` — must pass before Task 2

### Task 2: Mouse-down outside the draft cancels it

**Files:**
- Modify: `Sources/Pisaka/ProjectTreeDraftField.swift`

Intent: fix defect 1. A tree row is a plain SwiftUI view that never takes first
responder, so `controlTextDidEndEditing` cannot hear a click on one. A local
`.leftMouseDown` / `.rightMouseDown` monitor, alive only while a draft is, hears
every click before any view does.

- [x] add a small `NSViewRepresentable` (the draft's dismiss region) whose
      `NSView` subclass installs the local monitor in `viewDidMoveToWindow`
      (window non-nil) and removes it when the window goes away and in
      `dismantleNSView` — so the monitor's lifetime is exactly the draft's, and
      no monitor can outlive it or double up (one draft at a time is already the
      tree's invariant)
- [x] make the region view invisible and non-interactive: `hitTest` returns
      `nil`, no drawing, and it declares no size of its own so it cannot
      influence the draft's layout
- [x] attach it as the outermost `.background` of `TreeNameFieldView`'s `VStack`,
      after the padding, so its `bounds` covers icon column, field and reason
      line together (decision B) — the acceptance criterion "clicking the icon or
      the reason line does not cancel" then holds by construction rather than by
      a measured inset
- [x] in the monitor: ignore events whose `event.window` is not the region's
      window, convert `locationInWindow` into the region's coordinates, ask
      `TreeDraftDismissRule`, invoke `onCancel` on `cancel`, and **always return
      the event unchanged** so the click proceeds (decision A: the folder still
      toggles, the file still opens, the right-clicked row still gets its menu —
      Finder-like)
- [x] follow `ZoomController`'s monitor discipline: store the token, `[weak
      self]`, and `MainActor.assumeIsolated` in the closure with the same
      one-line reason
- [x] keep `controlTextDidEndEditing` and its teardown-flag discrimination
      exactly as they are — it remains the fallback for anything that genuinely
      moves first responder (Tab-away, a control that takes focus), and the two
      paths are idempotent because both end at `draft = nil`
- [x] no new tests: the policy is Task 1's and already tested; this is view
      wiring (untested by convention). Run `swift test` and `swiftlint --strict`
      — must be clean

### Task 3: Deterministic focus acquisition

**Files:**
- Modify: `Sources/Pisaka/ProjectTreeDraftField.swift`

Intent: fix defect 2. `makeNSView`'s single `DispatchQueue.main.async` guard
silently gives up when the field is not yet in a window, and the draft opens
deaf.

- [x] delete the `DispatchQueue.main.async` focus block from `makeNSView`;
      instead have `CustomTextField` acquire focus in `viewDidMoveToWindow` — the
      symmetric hook to the `viewWillMove(toWindow:)` the class already
      overrides, and the moment AppKit guarantees a window exists (it fires for
      the whole subtree when an ancestor joins a window, so the late-attachment
      path the guard used to lose is covered)
- [x] carry the initial selection range on the field, computed once by
      `makeNSView` from `initialRenameSelection(in:isDirectory:)`, and apply it
      to the field editor exactly once, immediately after focus is first taken;
      clear it afterwards so a second `viewDidMoveToWindow` (window change,
      re-attachment) can never re-select or clobber a selection the user has
      since changed
- [x] guard acquisition with a one-shot flag plus the existing teardown flag, so
      a draft replaced by a second command cannot have a stale request steal
      focus back
- [x] cover the one path a hook cannot: if `makeFirstResponder` refuses, retry
      once on the next runloop turn, re-checking that the field is still in a
      window and not tearing down — bounded, one attempt, no polling
- [x] no new tests (AppKit focus is invisible to `swift test`). Run `swift test`
      and `swiftlint --strict` — must be clean

### Task 4: The field fits its wrapped text; the reason line aligns by construction

**Files:**
- Modify: `Sources/Pisaka/ProjectTreeDraftField.swift`

Intent: a long relative path currently wraps and the first line renders
vertically clipped to about half its height. The field **wraps** (as the retired
dialog did — a deep path is the reason relative-path create exists, so it must be
readable in full), and the row grows to fit.

- [x] configure the field for wrapping the way `FilePanels.promptName` does
      (`usesSingleLineMode = false`, wrapping cell, no scrolling, no line cap,
      `.byWordWrapping`)
- [x] implement `sizeThatFits(_:nsView:context:)` on the representable, returning
      the height the cell needs at the proposed width, clamped to at least one
      line and at most the same six-line ceiling the dialog uses; handle an
      unspecified/infinite proposed width by falling back to the field's current
      width
- [x] keep this height calculation local rather than sharing `FilePanels`': the
      dialog's is bound to its fixed 400pt accessory width and to an
      `NSLayoutConstraint` it mutates, while the inline field's width is whatever
      the tree pane gives it — state that in the doc comment and cross-reference
      the dialog's version
- [x] replace `metrics.scaled(16) // icon is approx 16` in `reasonGutter`: put
      the reason line in an `HStack` led by the *same* `iconColumn` view rendered
      hidden, so the reason's inset is the icon column's real width by
      construction (and stays zero for a rename draft, which has no icon column)
      — no new literal, and `TreeRowLayout` gains nothing it does not need
- [x] no new tests (view layout). Run `swift test` and `swiftlint --strict` —
      must be clean

### Task 5: Tree-view hygiene — force-unwraps and the empty context menu

**Files:**
- Modify: `Sources/Pisaka/ProjectTreeView.swift`

- [x] at all three `draft!` sites (the create child row, the folder label rename,
      the file row rename) build the draft from the payload the `if case` already
      bound instead of force-unwrapping the optional
- [x] add a small `@ViewBuilder` helper that attaches `.contextMenu` only when
      the row is not drafted, and use it on both row kinds, so a right-click on
      the drafted row does nothing instead of flashing an empty panel; note in
      the helper's comment that the flag flips at most twice per draft, so the
      identity change it causes costs nothing
- [x] decide the visibility question deliberately and record it: `color(for:)`
      and `TreeRowLayout` stay internal because both project-tree view files
      legitimately need them and the alternative (a SwiftUI extension in Core) is
      barred; extend `color(for:)`'s doc comment to say it belongs to the project
      tree's view layer and name both readers
- [x] no new tests (view layer). Run `swift test` and `swiftlint --strict` — must
      be clean

### Task 6: The documentation the findings name

**Files:**
- Modify: `Sources/Pisaka/ProjectTreeDraftField.swift`,
  `Sources/Pisaka/ProjectTreeView.swift`, `Sources/Pisaka/PisakaApp.swift`,
  `Sources/PisakaCore/FileName.swift`, `docs/architecture/app-window.md`

- [ ] document `ProjectTreeDraftField.swift` end to end — the file and its five
      types: the layer split (no business logic here; every rule comes from
      `FileName`), the validation composition order (blank → validator →
      single-component collision), the three-way end-editing test and **why a
      responder read cannot work** (the notification fires during
      `resignFirstResponder`, before the new responder is installed), the new
      mouse-down monitor with its lifetime and the two decisions A and B above,
      the focus-acquisition rule (window hook, one-shot selection, the single
      bounded retry), and the wrapping/height rule
- [ ] rewrite `newFile(in:name:)`, `newFolder(in:name:)` and
      `renameItem(at:newName:)` doc comments in `PisakaApp.swift` for the inline
      flow: no prompt, no OK button — the view validates live and refuses commit
      with a beep, and the parse/name guards here are post-commit
      defense-in-depth behind that live validation over the same one Core rule
- [ ] rewrite `ProjectTreeView.swift`'s header comment: file operations are
      inline drafts, not dialogs, and the callbacks are `(URL, String)` carrying
      the accepted text
- [ ] write the real contract for `initialRenameSelection` in `FileName.swift`
      (the copy-pasted collision sentence is simply wrong): what is preselected
      is the name minus its extension under `URL.deletingPathExtension`
      semantics — the whole string for a directory, for a dotfile with no second
      dot, for a name with no dot and for one whose dot is trailing; the last dot
      is the split point otherwise
- [ ] repair `docs/architecture/app-window.md`: restore the `ProjectTreeView`
      entry's lost closing sentence about the callbacks only requesting the
      operation while `PisakaApp` does the disk I/O and bumps `treeRevision`,
      re-join the orphaned `DirectoryNodeView` fragment to it, move the
      `ProjectTreeDraftField.swift` bullet after the completed entry, and re-wrap
      both new mega-paragraphs to the file's ~76 column prose style
- [ ] extend that same doc with the focus rule this ticket introduces (a local
      mouse-down monitor alive only while a draft is; same window only; outside
      the draft's own region cancels silently and the click still lands;
      `controlTextDidEndEditing` remains the fallback with its teardown flag; app
      deactivation preserves the draft because a local monitor sees no other
      app's events), the wrapping/height rule, and fix the stale "a private
      `FileIconColor` → SwiftUI `Color` helper" wording
- [ ] run `swift test` and `swiftlint --strict` — must be clean

### Task 7: Verify acceptance criteria

- [ ] `swift test` — full suite green
- [ ] `swiftlint --strict` from the repository root against the committed config,
      clean, with no new in-file disable markers
- [ ] `xcodegen generate` and the macOS build (`xcodebuild -project
      Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' build`)
- [ ] the iOS build (`xcodebuild -project Pisaka.xcodeproj -scheme Pisaka
      -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build`) —
      untouched by this work, but the gate stays the gate
- [ ] confirm no `docs/architecture/` entry named above is left stale and that
      `app-window.md` reads as continuous prose

## Post-Completion (manual, in the running app)

Not agent-automatable — these are the live reproductions the review used:

- With a create draft and a rename draft open in turn, left-click: another folder
  row, another file row, a tab in the tab list, the editor pane, the bottom bar.
  Each cancels silently, creates/renames nothing, and the next keystroke does not
  reach the tree.
- Right-click another row: the draft cancels and that row's menu opens.
- Click inside the field, on the draft's icon, and on the reason line: nothing
  cancels; caret placement and drag-selection work.
- ⌘Tab away and back: the draft and its text survive. Esc, Enter-commit,
  Enter-refusal-with-beep and the disk-failure path behave as before.
- Repeatedly open a draft on the project root row, on a nested collapsed folder
  (expansion + draft in one command), and as a rename, including right after the
  editor held focus: the first keystroke always lands in the field, and the
  rename preselection applies once.
- Type/paste `backend/src/dialogs/very-long-dialogs.service.spec.ts` into a
  create draft: every wrapped line is fully legible and the row grows to fit.

## Out of scope

iOS and the remaining `FilePanels` surfaces; tree-wide keyboard navigation and
making rows first-responder-capable; drag-and-drop; the bottom-edge auto-scroll
boundary case; and any restructuring of the validation composition, the collision
rule, the commit paths or the menu wiring beyond the findings above.
