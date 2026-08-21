# A custom completion popup: preselected first row, Enter inserts, Tab replaces

## Overview

Replace `NSTextView`'s native completion popup on macOS with the editor's own
floating panel, built in the `HoverPanel` mould but *pointer-reachable*. The
first row is preselected on open, Enter commits with today's insertion
semantics, Tab commits replacing the whole identifier under the caret, Up/Down
move the selection (clamped, no wrap), Esc dismisses, a click on a row commits
it. Nothing is written into the buffer until a commit — the preview writes the
native popup forced are gone entirely, which is what makes preselection
affordable in the first place.

The trigger surface is untouched: same debounce, same as-you-type and explicit
entry points, same provider order, no re-ranking. Only the *presentation* and
the *commit trigger* change; the insertion path (edit plan, D4 auto-import
resolve, programmatic-edit bracket, one undo group) is reused rather than
forked.

## Context

Files involved:

- `Sources/PisakaCore/IdentifierScanner.swift` — gains the Tab range, next to
  the boundary rule it already owns.
- `Sources/PisakaCore/CompletionPopup.swift` (new) — selection state machine +
  row/badge values.
- `Sources/Pisaka/CompletionPanel.swift` (new) — the `NSPanel` + row list.
- `Sources/Pisaka/CompletionController.swift` — presentation and commit move
  here; the delegate-shaped machinery retires.
- `Sources/Pisaka/CodeEditorView.swift` — `Coordinator` wiring, `EditorTextView`
  key handling, the dismissal set.
- `Tests/PisakaCoreTests/` — new `CompletionPopupTests`, extended
  `IdentifierScannerTests`, updated `ZoomSourceGatingTests`.
- Docs: `docs/architecture/app-editor.md`, `core-intelligence.md`,
  `core-zoom.md`, `CLAUDE.md`, `docs/FEATURES.md`, `README.md`.

Related patterns:

- `HoverPanel`/`HoverController` — borderless non-activating child panel,
  idempotent dismissal, one generation token, appearance matched to the parent
  window, code drawn at `SettingsStore.fontSize`.
- `FileIcon` — the Core precedent for "SF Symbol name + semantic color token"
  decided in Core and merely rendered by the view layer (`FileIconColor` is
  already mapped to real colors in the view layer).
- `ZoomSurface.swift` / `ZoomHitTest` — the pointer walk starts at the frontmost
  window at the pointer, so a panel that accepts mouse events *is* the window
  walked, and anything drawn at the code font there must declare a surface.

Dependencies: none new.

## Design decisions this plan fixes

1. **The panel is a zoom surface, not an exemption.** It accepts clicks (a row
   commits), so `HoverPanel`'s "unreachable ≡ chrome" exemption does not apply
   and is not claimed. Its content view conforms to `ZoomSurfaceProviding` with
   `.code`, `CompletionPanel.swift` joins `zoomSurfaceDeclarers` by set
   equality, and `core-zoom.md` gains the entry. The panel never sets
   `ignoresMouseEvents`; it refuses key/main status so typing keeps going to the
   editor.

2. **Selection clamps at both ends.** Down on the last row and Up on the first
   are no-ops. No wrap-around: the popup is opened by typing, and a held Down
   key silently landing back on row 1 is the surprise the ticket asks to avoid.
   Every new candidate list selects row 0.

3. **Two commit ranges, one boundary rule.**
   `IdentifierScanner.completionPrefixRange(in:at:)` is Enter's range (today's
   semantics, unchanged). Tab's range is a new
   `IdentifierScanner.completionReplaceRange(in:at:)` in the *same* file — the
   prefix range extended forward over the run of identifier-continuation scalars
   at the caret. It lives there, not in a new file, because the forward walk
   needs the same scalar helpers; a second identifier definition is exactly what
   the ticket forbids. With no suffix the two ranges are equal, so Tab ≡ Enter.

4. **Commit reuses the existing insertion, in one undo group.** For an item with
   no edits (tree-sitter, keyword, buffer word) the commit is one
   `insertText(_:replacementRange:)` over the commit range, inside the
   `noteProgrammaticEdit` bracket. For an item with edits the existing
   `plan(for:over:replacing:in:)` + `apply(_:in:)` path runs unchanged over the
   typed word — so an auto-import still lands and a `(`-ending candidate still
   gets no auto-pair — and Tab additionally deletes the suffix, in the same undo
   group, *after* the plan, verifying the suffix text still stands at the caret;
   if it does not, Tab degrades to Enter rather than deleting something else.
   `scheduleFollowUp` (D4's late resolve) is untouched.

5. **The native path is retired, not left dangling.** `EditorTextView` overrides
   `complete(_:)` to route AppKit's stock ⌥⎋/F5 and the Find menu's "Complete"
   into the same `requestCompletions()` the ⌃Space path uses, so no AppKit popup
   can ever appear. The delegate
   `textView(_:completions:forPartialWordRange:indexOfSelectedItem:)`, the
   `insertCompletion(…)` and `rangeForUserCompletion` overrides,
   `CompletionController.insert(…)`, `isServingPopup` and `preview` all go —
   `preview` because no preview write can exist any more, which also removes the
   `CompletionEdit.shifted` "preview length" case from the live commit path
   (Core keeps it: the D4 follow-up still needs it).

6. **Rows.** `CompletionRow` (Core) = the row's text (`displayText`, the deduped
   snapshot key) + a `CompletionBadge` (SF Symbol name + `FileIconColor`,
   reusing the existing semantic color token the view layer already maps). Badge
   source: the item's `SymbolKind` when it has one; otherwise a keyword mark if
   the text is in `LanguageKeywords.keywords(for:)` for the buffer's language,
   else a plain-word mark. This distinguishes keywords from buffer words with no
   change to `CompletionItem` or the pipeline — the same knowledge the provider
   used to *make* the keyword is public in Core.

7. **Dismissal set** (all funnelled through one idempotent
   `CompletionController.dismiss()`): Esc (in `cancelOperation`, ahead of the
   find bar), a commit, a click outside the panel (a local `NSEvent` monitor
   installed only while visible, `ZoomController`'s precedent), first-responder
   loss (`textDidEndEditing`), window resign key, a caret move that leaves the
   word the list answers (`textViewDidChangeSelection`), any `update(…)` early
   return that clears the snapshot (word ended, marked text, selection, feature
   off), a new answer with no candidates, a scroll (the clip-view bounds change
   that already dismisses hover), a code-font change (the same `updateNSView`
   branch that already dismisses hover), tab/file switch (`clearCompletions`),
   and teardown.

8. **Staleness.** The panel is shown only from `apply(…)`, behind the guards
   that already exist there — the generation token captured before the debounce,
   plus the re-read caret, focus, marked-text, exact-prefix and same-member
   checks. A late list therefore refuses to show rather than showing over a
   changed buffer. On commit the controller re-reads the buffer and re-derives
   the commit range from the *live* caret, so a row committed against a buffer
   that moved is either re-expressed by `CompletionEditPlan` or refused by it.

## Development Approach

- **Testing approach**: Regular (code first, then tests) for the app layer; Core
  types get their tests in the same task and the suite must be green before the
  next task starts.
- The macOS view layer stays untested by convention; the rules it carries that
  the compiler cannot see are pinned by the repository-file suites
  (`ZoomSourceGatingTests`).
- **CRITICAL: every task ships new/updated tests.**
- **CRITICAL: `swift test` is green before the next task begins.**

## Implementation Steps

### Task 1: The Tab range, in the scanner that owns the boundary rule

**Files:**
- Modify: `Sources/PisakaCore/IdentifierScanner.swift`
- Modify: `Tests/PisakaCoreTests/IdentifierScannerTests.swift`

Add `completionReplaceRange(in:at:)`: the whole identifier the caret sits in —
`completionPrefixRange`'s answer, extended forward over identifier-continuation
scalars. Document that it is Tab's range and that Enter's is the prefix range,
that the two are equal when there is no suffix, and that it never crosses a `.`
(the forward walk stops at any non-continuation scalar), so a member completion
replaces only the member. Offsets are clamped and scalar-aligned exactly as the
rest of the file does.

- [ ] implement `completionReplaceRange(in:at:)` with its doc comment
- [ ] tests: no suffix (equals the prefix range); `CREATE|_typo`; caret at the
      start of a word; empty prefix with a suffix (`worker.|foo`); member
      position; a trimmed head (`9foo|bar`); a caret past a `.`; out-of-range and
      mid-surrogate offsets; end of buffer
- [ ] run `swift test` — must pass before Task 2

### Task 2: The popup's Core decisions — selection and rows

**Files:**
- Create: `Sources/PisakaCore/CompletionPopup.swift`
- Create: `Tests/PisakaCoreTests/CompletionPopupTests.swift`
- Modify: `CLAUDE.md` (one index line under `core-intelligence.md`)

Three pure value types plus one builder:

- `CompletionPopupSelection` — the count and the selected index;
  `moveUp`/`moveDown` clamp at both ends; `select(_:)` ignores an out-of-range
  index; an empty list has no selection. Constructing it for a new list selects
  row 0.
- `CompletionRowSource` — `.symbol(SymbolKind)`, `.keyword`, `.word`.
- `CompletionBadge` — SF Symbol name + `FileIconColor`, one per source, with a
  short mark for keyword and word.
- `CompletionRow.rows(for:language:)` — `[CompletionItem]` + the buffer's
  language → `[CompletionRow]`, preserving the provider's order, keyed on
  `displayText`, building the keyword set once.

State in the doc comment that this file ranks nothing and filters nothing: it
receives the provider's order and renders it.

- [ ] implement the types and the builder with their doc comments
- [ ] tests: initial selection, clamping at both ends, empty list, `select(_:)`
      bounds, a re-listed narrower set selecting row 0; badges for every
      `SymbolKind` (asserted over `SymbolKind.allCases` so a new kind fails
      here); keyword vs. word with a language, with `nil`, and for a language in
      `languagesWithoutKeywords`; row order and `displayText` preserved
- [ ] add the CLAUDE.md index line
- [ ] run `swift test` — must pass before Task 3

### Task 3: The panel

**Files:**
- Create: `Sources/Pisaka/CompletionPanel.swift`
- Modify: `Tests/PisakaCoreTests/ZoomSourceGatingTests.swift`

A borderless, non-activating `NSPanel` in `HoverPanel`'s mould — child of the
editor's window, appearance matched to the parent, `isReleasedWhenClosed =
false`, excluded from the windows menu, floating level, idempotent `dismiss()`
guarded by its own `isShown` flag rather than the panel's visibility — with the
opposite mouse policy: it accepts clicks, so `ignoresMouseEvents` is *not* set,
`canBecomeKey`/`canBecomeMain` stay `false`, and its content view conforms to
`ZoomSurfaceProviding` with `.code`.

Content: a scrolling row list (rows beyond the visible cap scroll; the provider
caps the list at 30), each row the candidate text in the editor's monospaced
font at the code size, plus the badge symbol at the interface metrics; the
selected row draws the selection fill and is scrolled to visible. Width is
measured from the widest row and capped; placement is below the anchor rect,
flipped above when there is no room, clamped horizontally — the same rule
`HoverPanel` uses, kept private here rather than shared (a shared placement
helper is a deliberate non-goal of this ticket). A single click on a row calls
the commit callback; `acceptsFirstMouse` is true so the first click into a
non-key panel counts.

- [ ] implement the panel: window configuration, row rendering, selection
      drawing/scrolling, placement, click-to-commit callback
- [ ] declare the `.code` zoom surface on the content view
- [ ] add `CompletionPanel.swift` to `zoomSurfaceDeclarers` in
      `ZoomSourceGatingTests` and extend that suite's assertion that the panel
      does **not** claim the hover popover's chrome exemption (it must not
      contain `ignoresMouseEvents = true`) while still refusing key status
- [ ] run `swift test` — must pass before Task 4

### Task 4: The controller drives the panel and owns the commit

**Files:**
- Modify: `Sources/Pisaka/CompletionController.swift`

`apply(…)` ends with `panel.show(rows:selection:anchoredTo:…)` — the anchor is
`firstRect(forCharacterRange:)` of the typed word — instead of
`textView.complete(nil)`, behind the guards it already applies. The controller
gains: `isVisible`, `moveSelection(_:)`, `commit(_ mode: .insert | .replace)`,
`dismiss()`, and the two font inputs (`syncAppearance(codeFontSize:metrics:)`,
mirroring the hover controller).

`commit(_:)` re-reads the live buffer and caret, derives the range from
`IdentifierScanner` per mode, and then takes the *existing* path: the edit plan
where the item carries edits (plus Tab's verified suffix deletion in the same
undo group), one `insertText(_:replacementRange:)` otherwise, both inside the
`noteProgrammaticEdit` bracket and one undo group, dismissing first so the
insertion's `textDidChange` cannot re-open anything. `scheduleFollowUp` keeps
its D4 role.

Retire: the `completions(forPartialWordRange:in:)` delegate answer,
`insert(_:forPartialWordRange:isFinal:in:)`, `isServingPopup`, `preview`, and
the run-loop hop in `setEnabled(false)` (which becomes a plain `dismiss()`,
because nothing is written to the buffer any more). Rewrite the class's doc
comment and every comment that describes the AppKit shapes that no longer exist
— the "list is strings" and preview paragraphs in particular.

- [ ] rewire `apply(…)` to show the panel; keep every existing staleness guard
- [ ] add the selection/commit/dismiss API and the commit implementation
- [ ] retire the delegate-shaped machinery and rewrite the documentation
- [ ] run `swift test` — must pass before Task 5

### Task 5: Keys, wiring and the dismissal set

**Files:**
- Modify: `Sources/Pisaka/CodeEditorView.swift`

`EditorTextView` gains one `onCompletionKey: (NSEvent) -> Bool` hook consulted
at the top of `keyDown(with:)`, before `super` and before the input context, so
Enter inserts no newline and Tab no tab character while the popup is up. It
claims only unmodified Return/Enter, Tab, Up and Down, and only while the popup
is visible, the view is editable and there is no marked text; everything else
falls through untouched. Esc is claimed in `cancelOperation(_:)` ahead of the
find bar. `complete(_:)` is overridden to route into `requestCompletions()`.
The `insertCompletion`/`rangeForUserCompletion` overrides and
`onCompletionInsertion` go away with the native path.

The `Coordinator` forwards the dismissal set listed in decision 7 — including
the caret-left-the-word test in `textViewDidChangeSelection`, the scroll and
font-change dismissals beside the hover ones, `textDidEndEditing`, window
resign, and `teardown()`.

- [ ] add the key hook, the Esc precedence and the `complete(_:)` override
- [ ] wire the coordinator: show/dismiss forwarding, font inputs, the full
      dismissal set, teardown
- [ ] remove the retired overrides and coordinator methods
- [ ] run `swift test` — must pass before Task 6

### Task 6: Verify acceptance criteria

- [ ] `swift test` fully green
- [ ] `xcodegen generate` and `xcodebuild -project Pisaka.xcodeproj -scheme
      Pisaka -destination 'platform=macOS' -configuration Release build`
- [ ] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination
      'generic/platform=iOS' build` (iOS untouched — no file under
      `Sources/Pisaka/iOS/` is modified by this plan)
- [ ] confirm by inspection that no `Sources/Pisaka/iOS/` file and no Core
      ranking/filtering code was changed

### Task 7: Update documentation

- [ ] `docs/architecture/app-editor.md` — rewrite the `CompletionController`
      entry (panel, selection, the two commit ranges, the dismissal set, the
      staleness guards) and add the `CompletionPanel.swift` entry
- [ ] `docs/architecture/core-intelligence.md` — the `CompletionPopup.swift`
      entry and the `completionReplaceRange` half of the `IdentifierScanner`
      entry
- [ ] `docs/architecture/core-zoom.md` — the completion panel as a declared
      `.code` surface, and why it is not the hover popover's exemption
- [ ] `CLAUDE.md` — the index line for the new Core file, the app index lines
      for `CompletionPanel.swift`, and the completion-candidate invariant's
      wording where it names the native popup
- [ ] `docs/FEATURES.md` + `README.md` — the popup's new behavior (preselected
      first row, Enter inserts, Tab replaces the whole identifier, arrows, Esc,
      click, kind badges)

## Post-Completion Manual Verification

Run in a DEBUG build; these cannot be automated in `swift test`.

- Typing `CRE` in a `.sql` file opens the popup with the first row highlighted;
  Enter inserts it; typing more letters narrows the list with the first row
  still selected; Esc closes it and typing continues normally.
- With the caret at `CREATE|_typo`, Tab replaces the whole identifier and Enter
  replaces only the typed prefix.
- An LSP auto-import candidate (Swift/TS) still inserts its import, and one ⌘Z
  reverts both; a candidate ending in `(` gains no auto-paired `)`.
- Arrowing through the list never dirties the tab (no dot in the tab), never
  adds an undo step and never triggers autosave.
- With the popup closed, Enter/Tab/arrows/Esc behave as before; ⌃Space, the Find
  menu's "Complete", ⌥⎋ and F5 all open the new panel and never AppKit's.
- ⌘-scroll and ⌘+/⌘− with the pointer over the popup zoom the *code*, not the
  chrome (the popup dismisses on the font change).
- The iOS completion strip is unchanged in the simulator.
