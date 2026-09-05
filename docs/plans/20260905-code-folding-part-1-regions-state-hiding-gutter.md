# Code folding, part 1 — regions, state, hiding, gutter, Fold/Unfold (macOS)

## Overview

Collapse a block behind its first line and expand it again: a chevron in the
gutter, a `…` placeholder at the end of the header line, `Fold` / `Unfold` with
shortcuts. Regions come from a language server (`textDocument/foldingRange`)
when one serves the file, and from a pure bracket-and-indentation scanner
otherwise. The buffer is never modified — hiding is glyph generation plus
line-break suppression, so every engine that works on UTF-16 offsets keeps
working on the full text. Fold state lives for the app run and is never written
to the session. macOS only.

## Context

### Files involved

Core (new): `Sources/PisakaCore/FoldRegion.swift`, `FoldRegionScanner.swift`,
`FoldState.swift`, `FoldShift.swift`.
Core (modified): `CodeIntelligence.swift` (the seam), `LSPProtocolTypes.swift`
(method name, params, response, both capability trees), `LSPSession.swift`
(budget + typed exchange), `LSPIntelligenceProvider.swift`, `SymbolIntelligenceProvider.swift`, `RoutingIntelligenceProvider.swift`
(budget + routing).
App, macOS (new): `Sources/Pisaka/FoldController.swift`, `Sources/Pisaka/FoldCommands.swift`.
App, macOS (modified): `BracketOverlayLayoutManager.swift` (hiding, the
typesetter, the placeholder), `LineNumberRulerView.swift` (chevron column +
numbering), `CodeEditorView.swift` (wiring, the reveal funnel, the selection
hook), `EditorSearchController.swift` (its one jump routed through the funnel),
`PisakaApp.swift` (one line adding the commands).
Tests (new): `FoldRegionScannerTests`, `FoldStateTests`, `FoldShiftTests`,
`FoldRegionDecodeTests`, `FoldRoutingTests`, `FoldingSourceGatingTests`.
Docs: new `docs/architecture/core-folding.md`; updates to `core-lsp.md`,
`core-intelligence.md`, `core-editorconfig.md`, `app-editor.md`,
`app-editor-overlays.md`, `CLAUDE.md`, `docs/FEATURES.md`, `README.md`.

### Existing patterns reused

- `BracketDepthScanner` (chunked `getCharacters` walk, shared stack) and
  `IndentLevelScanner` + `IndentUnitRule` (the one unit rule Enter uses) — the
  fallback scanner's two inputs. No second separator rule, no second unit rule:
  lines come from `TerminatedLines`.
- `DiagnosticShift` — the exact shape of the region/fold shift (before: moved;
  after: untouched; intersecting: dropped, with the same overflow guards and the
  same `[]`-on-inconsistent-input fallback).
- `EditorViewport` / `EditorViewportMemory` — the shape of the per-run memory
  (with one deliberate divergence, below).
- `SaveTransformPlan.remappedRange(_:)` — already exists and already moves the
  caret, the selection endpoints and the scroll anchor. Fold bounds join them.
- `BracketHighlightController` — the app-side shape of the fold controller: a
  cancellable debounce task plus a monotonic generation token captured before
  the hop.
- `RoutingIntelligenceProvider.withBudget` — the deadline race the fold question
  joins, unchanged.
- `Gate` (`Tests/PisakaCoreTests/Support/StubFileTree.swift`) and
  `ScriptedLSPTransport` — the racing and the wire fakes.

### Three corrections to the ticket's premises, found while reading

1. **Not every reveal goes through `EditorRevealState`, and the scroll sites are
   not where the ticket assumed.** Verified in the tree:
   - `reveal.reveal(...)` is called four times: twice in `PisakaApp.swift`
     (`activateSearchMatch(url:range:)`, `activateUsage(_:)` — Find in Files, Go
     to Definition inside the project, the Problems rows, the Usages rows and the
     symbol jump all funnel through these two) landing in
     `Coordinator.applyReveal`, and twice in `SourceViewerWindowController.swift`
     against that window's **own** `EditorRevealState`, which feeds the
     read-only out-of-project viewer and has no fold controller at all.
   - The find bar's next/previous match does **not** go through
     `EditorRevealState`: `EditorSearchController` has exactly **one**
     `scrollRangeToVisible` site — the private `select(_:)` helper
     (`EditorSearchController.swift:225`) that the navigation and the replace
     step call — not three.
   - `CodeEditorView.swift` has **two** `scrollRangeToVisible` sites: the one in
     `applyReveal` (line ~1992) and a second at line ~2211, the Tab-plan caret
     scroll after a raw-storage edit. That second one is **not a reveal**: it
     re-shows a caret the selection path has already produced and that the caret
     rule has already sanitized, so it is named as the one in-file non-reveal
     site with that reason rather than routed through the funnel.
   - Three further `scrollRangeToVisible` sites belong to text views that are not
     the editor and have no folds: `SourceViewerContent.swift:218`,
     `MergeView.swift:486`, `Sources/Pisaka/iOS/CodeEditorCoordinator_iOS.swift:316`.
   So the invariant this plan establishes — and that the gating suite pins by set
   equality — is one step lower than the ticket's and actually true: **every
   jump-to-a-range in the editor goes through one coordinator method,
   `Coordinator.revealRange(_:)`**, which applies the pure reveal rule before
   selecting and scrolling. Its callers are exactly two files:
   `CodeEditorView.swift` (`applyReveal`) and `EditorSearchController.swift`
   (`select(_:)`, through a hook the coordinator installs, so the search
   controller stops calling `setSelectedRange`/`scrollRangeToVisible` itself).
   The three non-editor text views and the two viewer `reveal.reveal(` sites are
   named exclusions with their reasons.
2. **The fold memory cannot be keyed by `OpenFile.id`.** `id` is a fresh `UUID`
   per `OpenFile`, so closing and reopening a file — which the acceptance
   criteria require to keep folds — produces a new id. `FoldStateMemory` is
   therefore keyed by a `String`: the canonical path for a url-backed file,
   `id.uuidString` for an unsaved buffer. It is **not** pruned on tab close (the
   deliberate divergence from `EditorViewportMemory.prune`), and is cleared
   wholesale on a folder switch.
3. **The fold ask does not have to wait for the diagnostics flush.** D2's sync is
   request-driven — the live buffer travels with the request through
   `LSPWorkspace.prepare` — so the fold controller runs its *own* debounce of the
   same 400 ms length rather than chaining onto `LSPDocumentSyncController`. Same
   length, same triggers, one fewer coupling.

### Dependencies

None new. Foundation only in Core; AppKit only in the app half.

## Development Approach

- **Testing approach**: Regular (code first, then tests) for the Core engines,
  which are pure and easiest to write against a written contract; the app half is
  untested by convention except through `FoldingSourceGatingTests`.
- Complete each task fully before moving to the next.
- **CRITICAL: every task MUST include new/updated tests.**
- **CRITICAL: `swift test` must pass before starting the next task.**
- Read the matching `docs/architecture/*.md` entry before touching a file, and
  update that entry in the documentation task.
- No product or brand name anywhere: code, comments, tests, docs, commits.

## Implementation Steps

### Task 1: The fold region value and the fallback scanner (Core)

**Files:**

- Create: `Sources/PisakaCore/FoldRegion.swift`
- Create: `Sources/PisakaCore/FoldRegionScanner.swift`
- Create: `Tests/PisakaCoreTests/FoldRegionScannerTests.swift`
- [x] `FoldRegion`: the UTF-16 `hiddenRange` (from the end of the first line's
    *content* to the end of the last line's *content*, so the header stays
    visible in full and the block's last line joins it), `headerLine` (the
    0-based line index for the gutter), and `kind: FoldRegionKind?` with the
    three closed cases `comment`, `imports`, `region` — absent meaning "no kind
    named", never a refusal. Ordering key: `headerLine`, then the longer region
    first. A region with an empty hidden range is not representable — the
    initializer refuses it, so "a chevron exists" and "there is something to
    hide" are one fact.
- [x] `FoldRegionScanner.scan(text:widths:)`, pure and Foundation-only:
    - bracket candidates from `BracketDepthScanner.scan(text:)` — every matched
      pair (`isUnmatched == false`) whose opener and closer sit on different
      lines;
    - indentation candidates from `IndentLevelScanner.runs(in:range:widths:)`
      over the whole text: a header line followed by lines whose level is
      deeper, ending at the first line back at the header's level or shallower;
      blank and whitespace-only lines inside the block belong to it and never
      end it, and trailing blank lines are trimmed off the end so the block ends
      on its last real line;
    - both require **two or more lines**;
    - two candidates sharing a `headerLine` merge and **the bracket one wins**;
    - no comment and no import regions (out of scope);
    - lines come from `TerminatedLines`, so LF/CR/CRLF/NEL/LS/PS are handled by
      use rather than by a second table.
- [x] The scan is one pass over the bracket tokens plus one levelled pass, both
    already chunked/bounded by their engines; it stays cheap enough for the main
    actor after a debounce, exactly as the rainbow scan is.
- [x] Tests: nested brackets; a single-line pair yielding nothing; an unmatched
    opener; crossed brackets; indentation blocks in a tab-indented and a
    space-indented file; blank lines inside and after a block; the two-line
    minimum on both sources; the merge rule (bracket wins) proven by a case
    where the two disagree about the end; each of the six line separators; an
    empty text; a text of one line.
- [x] Run `swift test` — must pass before Task 2.

### Task 2: Fold state, its two maintenance rules, the caret and reveal rules (Core)

**Files:**

- Create: `Sources/PisakaCore/FoldState.swift`
- Create: `Sources/PisakaCore/FoldShift.swift`
- Modify: `Sources/PisakaCore/SaveTransform.swift` (documentation only — the remap
  already exists)
- Create: `Tests/PisakaCoreTests/FoldStateTests.swift`,
  `Tests/PisakaCoreTests/FoldShiftTests.swift`
- [x] `FoldState`: the folded hidden ranges, kept sorted and non-overlapping.
    `fold(_:)`, `unfold(_:)`, `toggle(_:)` by region; `isFolded(_:)`;
    `hides(offset:)`; `folded(containing line:)`. Nested regions may both be
    folded — the outer's hidden range subsumes the inner's, which is the case
    the sort-and-merge normalization handles once rather than at each reader.
- [x] `FoldShift.updated(_:previousLineStarts:newLineStarts:editedRange:changeInLength:)`,
    modelled line for line on `DiagnosticShift`: before → unchanged, after →
    shifted by the delta, intersecting → **dropped** (i.e. that block unfolds).
    Same half-open comparisons, same overflow guards, same "any inconsistent
    input answers `[]`" fallback, and the same documented list of what is
    deliberately *not* checked.
- [x] `FoldState.reconciled(with candidates:)`: a folded range survives only if a
    candidate with the same `headerLine` exists, and takes that candidate's
    bounds; otherwise it unfolds. A server that recomputed a region one line
    shorter therefore leaves no phantom fold.
- [x] `FoldState.clamped(toLength:)` — `EditorViewport.clamped`'s rule applied to
    ranges: anything that cannot fit is dropped, never truncated into a lie.
- [x] `FoldState.remapped(through plan: SaveTransformPlan)` — fold bounds moved by
    `remappedRange(_:)`, the **same** remap that already moves the caret, each
    selection endpoint and the scroll anchor. Deliberately not the shift rule:
    an autosave that trims trailing whitespace inside a folded block must leave
    it folded.
- [x] `FoldCaretRule.caret(for proposed:previous:in state:)` — pure. A single
    caret (zero-length selection) may never rest strictly inside a hidden range:
    moving forward lands at the range's end, moving backward at its start, and a
    request with no direction (a click) lands at its start. A selection with
    length is returned untouched, so selecting across a whole folded block is
    allowed and includes the hidden text.
- [x] `FoldReveal.unfolding(_ range: NSRange, in state:)` — the state with every
    folded region intersecting `range` unfolded, nested regions included
    (unfolding an inner one that an outer still hides is not enough, so the rule
    unfolds every intersecting range in one pass).
- [x] `FoldStateMemory`: `[String: FoldState]` with `record(_:for:)`,
    `state(for:clampedToLength:)`, `forget(_:)` and `removeAll()`. Keyed by the
    string the app supplies (canonical path, or the tab id for an unsaved buffer
    — correction 2). **No `prune(keeping:)`**: the folds of a closed file must
    survive its reopening in the same run, and the doc comment says so beside
    `EditorViewportMemory`'s opposite choice.
- [x] Tests: fold/unfold/toggle incl. nested; shift before, after, intersecting
    and at both half-open edges; a zero-length insertion at a boundary; the
    overflow fallbacks; reconciliation (survives, moves, unfolds); the memory
    clamp against a shortened buffer; the save-transform remap moving a fold
    across a trailing-whitespace trim *inside* it and across an inserted final
    newline; the caret rule forward, backward, click and spanning selection; the
    reveal rule on two nested regions and on a range touching only the header
    line.
- [x] Run `swift test` — must pass before Task 3.

### Task 3: `textDocument/foldingRange` on the wire (Core, LSP)

**Files:**

- Modify: `Sources/PisakaCore/LSPProtocolTypes.swift`,
  `Sources/PisakaCore/LSPSession.swift`
- Create: `Tests/PisakaCoreTests/FoldRegionDecodeTests.swift`
- Modify: `Tests/PisakaCoreTests/LSPProtocolTypesTests.swift`,
  `LSPSessionTests.swift` (whatever the existing suites are named)
- [x] `LSPMethod.foldingRange = "textDocument/foldingRange"`.
- [x] `LSPFoldingRangeParams` (a `textDocument` identifier and nothing else).
- [x] `LSPFoldingRange`, decoded by a closed table: `startLine`, `endLine`,
    optional `startCharacter`, `endCharacter`, optional `kind`. A `kind` string
    the table does not know decodes as **absent**, not as a refusal — the
    specification leaves that field open. `LSPFoldingRangeResponse` folds `null`
    and an absent `result` into the same empty answer, drops one unreadable
    element while its siblings survive (the `publishDiagnostics` rule), and
    still throws on a top level that is neither `null` nor an array.
- [x] `LSPClientCapabilities`: add the `textDocument.foldingRange` node —
    `dynamicRegistration: false`, `lineFoldingOnly: false` (this editor folds to
    a character offset, so it accepts character-precise ranges),
    `foldingRangeKind.valueSet: ["comment", "imports", "region"]`, and
    `foldingRange.collapsedText: false` (no server-supplied placeholder text;
    the placeholder is always `…`). Closed and hand-written like the rest.
- [x] `LSPServerCapabilities.supportsFoldingRange`, read through the existing
    `isEnabled` collapse of `boolean | Options`.
- [x] `LSPSession.Budgets.foldingRange` and the typed exchange `foldingRange(_:)`.
    Budget: **1.5 s**, completion's number rather than a definition's three, and
    the doc comment states why — nobody asked for it, it fires after a typing
    pause, and an answer arriving after the next keystroke is not late but
    unwanted.
- [x] Tests: the full shape; the two optional characters absent and present; an
    unknown `kind`; `null`; a missing `result`; one malformed element among good
    ones; a non-array top level throwing; the capability tree's JSON asserted by
    key (the existing capability test's shape); the server capability read from
    `true`, from `{}` and from absence; the budget wired, through
    `ScriptedLSPTransport`.
- [x] Run `swift test` — must pass before Task 4.

### Task 4: One question, one answer — the seam and the routing (Core)

**Files:**

- Modify: `Sources/PisakaCore/CodeIntelligence.swift`,
  `LSPIntelligenceProvider.swift`, `SymbolIntelligenceProvider.swift`,
  `RoutingIntelligenceProvider.swift`
- Create: `Tests/PisakaCoreTests/FoldRoutingTests.swift`
- Modify: the existing `RoutingIntelligenceProviderTests`,
  `LSPIntelligenceProviderTests`
- [x] `FoldRegionRequest`: `fileURL: URL?`, `text: String`,
    `language: SyntaxLanguage?`, and `indentWidths: IndentLevelWidths`. The
    widths are carried rather than derived because the fallback scanner needs
    **the same unit `IndentUnitRule` already answered for Enter**, and no
    provider can see an `.editorconfig`; the app computes them through the one
    path the indentation tints already use, so there is no second unit rule
    anywhere.
- [x] `CodeIntelligenceProviding.foldRegions(for:) async -> [FoldRegion]`,
    defaulted to `[]` in the protocol extension beside `hover` and `references`,
    with the reason stated: both iOS surfaces have no folding and must not grow
    a call site.
- [x] `LSPIntelligenceProvider.foldRegions(for:)`: D2's empty-buffer guard, the
    language off the file name, `prepare` so the live buffer reaches the server,
    `supportsFoldingRange` before asking, `LSPPositionMap` on the way back,
    `stillHolds` before the answer is read. A range whose lines fall outside the
    buffer, or whose end precedes its start, is **dropped, never trapped on**. A
    folding range with no `endCharacter` covers to the end of `endLine`'s
    content; with no `startCharacter`, from the end of `startLine`'s content —
    which is exactly the hidden range this editor needs, and is why the
    character fields are optional in the first place.
- [x] `SymbolIntelligenceProvider.foldRegions(for:)`: `FoldRegionScanner.scan` and
    nothing else. It reads no index — the scanner needs none — and the doc
    comment says so, because "the index-backed provider" is the seam's name for
    it rather than a description of this one method.
- [x] `RoutingIntelligenceProvider.foldRegions(for:)`: `canServe` first (an
    unserved language costs a function call), then the same `withBudget` race,
    then the fallback — and an **empty server answer falls through**, the file's
    existing "an empty answer is not an answer" rule. The answer is therefore
    never a mixture of the two sources, and the router walks nothing.
    `Budgets.foldingRange = 1.5`, matching the session's.
- [x] Tests: an unserved language answering the fallback's output **byte for byte**
    (the equality assertion the existing suite makes for definitions); a served
    language answering the server's; a deadline expiry falling through; an empty
    server answer falling through; a non-empty server answer never mixed with
    scanner candidates; the out-of-range and end-before-start drops; the
    generation race staged with `Gate` so the stale answer publishes first and
    the assertion holds with or without the token.
- [x] Run `swift test` — must pass before Task 5.

### Task 5: Hiding, the typesetter and the placeholder (App, macOS)

**Files:**

- Modify: `Sources/Pisaka/BracketOverlayLayoutManager.swift`
- [ ] **Hiding is two halves, planned as both from the start** — not one
    mechanism with a fallback. In TextKit 1 the typesetter breaks paragraphs by
    the *characters in the string*, not by glyph properties, so a `.null` glyph
    on a line separator is expected **not** to remove the paragraph break:
    - **Half one**, glyph generation: override
      `setGlyphs(_:properties:characterIndexes:font:forGlyphRange:)` on the
      existing subclass and mark every character of every folded range —
      including its line separators — with `NSGlyphProperty.null`, so nothing
      inside the range is drawn or advances.
    - **Half two**, line breaking: an `NSATSTypesetter` subclass installed on
      the same layout manager, living in **the same file**
      (`BracketOverlayLayoutManager.swift`), whose
      `actionForControlCharacter(at:)` answers `.zeroAdvancementAction` for
      every separator character that falls inside a folded range and defers to
      `super` everywhere else. This is what actually makes the header line and
      the block's last line meet on one visual line.
    - **The spike** (first thing in this task, before the placeholder and before
      Task 6): build DEBUG, fold a multi-line brace block, and confirm which
      halves are load-bearing. Record the outcome in `app-editor-overlays.md`
      **either way** — including the case where half one alone turns out to
      suffice, which would be the surprising result and deserves the sentence.
      If half two is not needed, it is deleted rather than left inert, and the
      Task 9 gating rule for it is dropped with a note.
- [ ] In both halves the text storage is never touched: no edit is registered, undo
    never contains a fold, and Neon's temporary attributes, the matched-pair and
    search backgrounds, the diagnostic underlines and the indentation tints over
    hidden text are simply not drawn — **no code is added for any of them**.
- [ ] `setFoldedRanges(_:)`: store (both halves read the same stored set), then
    `invalidateGlyphs(forCharacterRange:changeInLength:0:actualCharacterRange:)`
    + `invalidateLayout` + `invalidateDisplay` over the **union of the symmetric
    difference** of the old and new sets only — never the whole file. Unchanged
    input is a no-op, because this is called on every view update.
- [ ] The placeholder: drawn in `drawBackground(forGlyphRange:at:)` beside the
    indentation tints and by the same technique — geometry read from this layout
    manager at draw time, never cached. A `…` in the editor font at the current
    zoom inside a rounded outline, positioned at the end of the header line's
    visible content, in `SyntaxTheme`'s secondary colour. Nothing is stored, so a
    zoom or a font change needs no bookkeeping.
- [ ] `placeholderRect(forFoldedRangeAt:)` — the one geometry answer the text view
    asks when deciding whether a click landed on a placeholder. It lives here
    because the rect is this manager's own.
- [ ] Tests: none here — this is view-layer drawing, untested by convention. Its
    rules are pinned by `FoldingSourceGatingTests` (Task 9) and verified by the
    manual DEBUG pass.
- [ ] Run `swift test` and `swiftlint --strict` — must pass before Task 6.

### Task 6: The gutter (App, macOS)

**Files:**

- Modify: `Sources/Pisaka/LineNumberRulerView.swift`
- [ ] A chevron column left of the line numbers, sized from the ruler font so it
    scales with the interface zoom like the existing columns. `chevron.down` in
    `secondaryLabelColor` on every candidate's header line, `chevron.right` in
    `labelColor` on a folded one, nothing on other lines. The column's width is
    added to `updateThickness()` beside `annotationColumnWidth` and
    `diagnosticColumnWidth`.
- [ ] `setFoldRegions(_:folded:)` — the ruler is *told* both sets and decides
    nothing about them; a changed set invalidates the ruler only.
- [ ] `drawHashMarksAndLabels(in:)`: the walk keeps incrementing `lineNumber` per
    line as it does today, but **skips drawing** every line whose start falls
    strictly inside a hidden range — so `12` is followed by `27`, the numbers
    stay honest and never overlap. The blame column and the diagnostic markers
    draw inside the same skipped branch and therefore follow with no code of
    their own.
- [ ] `mouseDown(with:)`: a click inside the chevron column resolves the line from
    the layout manager's fragment geometry, finds the candidate with that header
    line, and calls `onToggleFold?(region)`. A click anywhere else falls through
    to `super`, so the existing blame context menu is untouched.
- [ ] Tests: none here (view layer). Pinned by Task 9, verified by the manual pass.
- [ ] Run `swift test` and `swiftlint --strict` — must pass before Task 7.

### Task 7: The controller, the wiring and the reveal funnel (App, macOS)

**Files:**

- Create: `Sources/Pisaka/FoldController.swift`
- Modify: `Sources/Pisaka/CodeEditorView.swift`,
  `Sources/Pisaka/EditorSearchController.swift`
- [ ] `FoldController`, `@MainActor`, beside `BracketHighlightController` and
    `HoverController` and shaped like the first: it owns the debounced ask
    (400 ms, its own scheduler — correction 3), the monotonic generation token
    **captured synchronously before the hop**, the current candidate list, the
    live `FoldState`, the `FoldStateMemory`, and the invalidations it pushes to
    the layout manager and the ruler. It is a **reader**: it never raises the
    writer gate and is never gated by one.
- [ ] Triggers: a text change (debounced), a tab switch and a tab open
    (immediate), a language change, and an `.editorconfig` revision change (the
    widths move). Between an edit and the next answer the candidates in hand are
    **shifted** through `FoldShift`, so chevrons do not blink on every
    keystroke; a fresh answer goes through `FoldState.reconciled(with:)`.
- [ ] `CodeEditorView.Coordinator` wiring, and only wiring:
    - `textDidChange` → `folds.noteBufferChanged(...)`;
    - `bufferEdited(...)` → `folds.noteEdit(...)`, which shifts both the
      candidates and the state, beside the existing diagnostics shift and under
      the same `isSwappingBuffer` suppression;
    - `textViewDidChangeSelection` → the **one and only** place `FoldCaretRule`
      is applied, re-entrancy-guarded like the existing selection work;
    - `updateNSView`'s content-replaced branch → on `externallyReplaced`,
      `folds.forget(for:)` beside `forgetViewport(for:)` — a `reloadFromDisk`
      after a git operation, a Local History restore and the rename retarget all
      drop the folds and the memory entry with them, on exactly the signal that
      already drops the undo stack and the viewport;
    - `beginSaveTransformRewrite` / `endSaveTransformRewrite` → the plan's
      `remappedRange` applied to the fold bounds, never the shift rule;
    - the widths come from the existing `indentUnit(text:)` +
      `IndentLevelScanner.widths(...)` path, so `refreshIndentLevelWidths` gains
      a second consumer rather than a second opinion.
- [ ] **The reveal funnel** (correction 1), stated exactly as the tree is:
    - New `Coordinator.revealRange(_ range: NSRange)` in `CodeEditorView.swift`:
      applies `FoldReveal.unfolding(...)`, pushes the new state to the layout
      manager and the ruler, then sets the selection and scrolls. This is the
      one place a jump-to-a-range is performed in the editor.
    - `applyReveal` (`CodeEditorView.swift`, the landing point of both
      `reveal.reveal(` sites in `PisakaApp.swift`) calls it instead of doing the
      selection and scroll itself.
    - `EditorSearchController.select(_:)` — its **one**
      `setSelectedRange`/`scrollRangeToVisible` pair, the private helper the
      next/previous navigation and the replace step both call — calls it too,
      through a `revealRange` hook the coordinator installs on the controller it
      already owns (`CodeEditorView.swift:919`). After this task the search
      controller performs no selection and no scroll of its own.
    - **The one in-file non-reveal site**, named rather than routed: the Tab-plan
      caret scroll after a raw-storage edit (`CodeEditorView.swift`, ~line 2211).
      It re-shows a caret that `setSelectedRanges` has just produced and that the
      caret rule has already sanitized through
      `textViewDidChangeSelection`, so it can never target hidden text and
      routing it through the funnel would ask the reveal rule a question whose
      answer is always "nothing to unfold". The reason goes in a comment beside
      it and in `app-editor.md`.
    - **Named exclusions**, each a text view that is not the editor and has no
      fold state: `SourceViewerContent.swift` (the read-only out-of-project
      window), `MergeView.swift` (the merge editor's result pane) and
      `Sources/Pisaka/iOS/CodeEditorCoordinator_iOS.swift` (iOS, untouched by
      this ticket). The two `reveal.reveal(` sites in
      `SourceViewerWindowController.swift` drive that window's own
      `EditorRevealState` and are excluded by name for the same reason.
- [ ] The memory key: the canonical path for a url-backed file, the tab id for an
    unsaved buffer; recorded on switch-away and on close, restored on switch-in
    (clamped, then reconciled when the next candidates arrive), cleared
    wholesale on a folder switch. Nothing reaches
    `EditorSession`/`SessionController` — a relaunch starts unfolded.
- [ ] Tests: none here (view layer). The decisions it wires are all covered by
    Tasks 1–4; the wiring is pinned by Task 9.
- [ ] Run `swift test` and `swiftlint --strict` — must pass before Task 8.

### Task 8: Fold and Unfold (App, macOS)

**Files:**

- Create: `Sources/Pisaka/FoldCommands.swift`
- Modify: `Sources/Pisaka/CodeEditorView.swift` (`EditorTextView` entry points and
  the placeholder click), `Sources/Pisaka/PisakaApp.swift` (one line)
- [ ] `FoldCommands: Commands` in its own file, added to `PisakaApp`'s
    `.commands { }` by **one line**, in the Edit group beside Toggle Comment.
    *Fold* ⌘⌥←, *Unfold* ⌘⌥→ — verified against every existing
    `keyboardShortcut` in the app (the pair is unused: the app's ⌘⌥ shortcuts are
    ⌘⌥F alone) and against the text view's own key handling; if the verification
    finds a clash at implementation time, the plan's shortcut moves and the
    change is recorded in `README.md` and `docs/FEATURES.md`.
- [ ] The action reaches the active tab's editor coordinator through the same
    first-responder route ⌘D and Toggle Comment already use
    (`NSApp.keyWindow?.firstResponder as? EditorTextView`), beeping through
    `PlatformFeedback.warning()` when anything else holds focus.
- [ ] Semantics: *Fold* acts on the innermost **candidate** region containing the
    caret line, *Unfold* on the innermost **folded** one — both resolved by a
    pure `FoldState`/candidate query from Task 2, not by the view. *Fold* refuses
    (beeps) when a multi-line selection extends beyond the region. After *Fold*
    the caret sits at the start of the header line, by the caret rule rather than
    by a second rule here.
- [ ] `EditorTextView.mouseDown(with:)`: a click whose point falls in the layout
    manager's `placeholderRect` for a folded range unfolds that region and places
    the caret at its start, before `super.mouseDown` sees it. The pointer over
    the placeholder does not change, as specified.
- [ ] Tests: the command's *decisions* (innermost candidate, innermost folded, the
    refusal, the resulting caret) are Core queries and are tested in
    `FoldStateTests`; the routing is view-layer and pinned by Task 9.
- [ ] Run `swift test` and `swiftlint --strict` — must pass before Task 9.

### Task 9: `FoldingSourceGatingTests`

**Files:**

- Create: `Tests/PisakaCoreTests/FoldingSourceGatingTests.swift`
- [ ] Matching **comment- and literal-stripped** text throughout, read through
    `#filePath` with Foundation only, following `DatabaseViewerSourceGatingTests`'
    shape and carrying its whole inventory in doc comments.
- [ ] **Hiding lives in one file, both halves.** `NSGlyphProperty.null` / the
    glyph-generation override **and** the `NSATSTypesetter` subclass with its
    `actionForControlCharacter(at:)` appear in
    `BracketOverlayLayoutManager.swift` and in **no other file** under
    `Sources/`. (If the Task 5 spike proved half two unnecessary and it was
    deleted, this rule keeps its glyph half and the typesetter half is removed
    with the reason recorded in the suite's doc comment and in
    `app-editor-overlays.md`.)
- [ ] The fold commands appear in `FoldCommands.swift` alone; `PisakaApp.swift`
    names the type exactly once.
- [ ] **The reveal funnel, by set equality.** Three sets, each asserted by equality
    and each carrying its reason in the doc comment:
    - the files calling `Coordinator.revealRange(` is exactly
      `{CodeEditorView.swift, EditorSearchController.swift}`;
    - `FoldReveal` is named in exactly one file, `CodeEditorView.swift`;
    - the files calling `scrollRangeToVisible` on a text view under
      `Sources/Pisaka` is exactly `{CodeEditorView.swift, SourceViewerContent.swift,
      MergeView.swift, iOS/CodeEditorCoordinator_iOS.swift}` — the last three
      named exclusions (a read-only viewer, the merge result pane, iOS), and
      `CodeEditorView.swift` pinned to **exactly two** occurrences: the funnel's
      own and the Tab-plan caret scroll, the one in-file non-reveal site, with
      its reason. `EditorSearchController.swift` must have **zero**.
    - the files calling `reveal.reveal(` is exactly `{PisakaApp.swift,
      SourceViewerWindowController.swift}` — the first landing in the editor's
      funnel through `applyReveal`, the second driving the viewer window's own
      `EditorRevealState` and excluded by name.
- [ ] **The caret rule, by set equality too.** `FoldCaretRule` is named in exactly
    one file, `CodeEditorView.swift`; `MergeView.swift`,
    `SourceViewerContent.swift` and `Sources/Pisaka/iOS/CodeEditorCoordinator_iOS.swift`
    are the named non-callers, each with its reason (three text views that hold
    no fold state).
- [ ] No view file decides anything the state decides: `FoldState`'s mutating
    members are named only by `FoldController.swift`; no file under
    `Sources/Pisaka` spells the two-line minimum, the merge rule or the shift's
    three-way test.
- [ ] The app-side fold files are macOS-gated (`#if os(macOS)`), and no file under
    `Sources/Pisaka/iOS/` names any of them.
- [ ] The fold layer names no writer gate: neither `autosave` nor `localChanges`
    appears in `FoldController.swift` or `FoldCommands.swift` — a reader, like
    the index.
- [ ] Run `swift test` — must pass before Task 10.

### Task 10: Documentation

**Files:**

- Create: `docs/architecture/core-folding.md`
- Modify: `docs/architecture/core-lsp.md`, `core-intelligence.md`,
  `core-editorconfig.md`, `app-editor.md`, `app-editor-overlays.md`, `CLAUDE.md`,
  `docs/FEATURES.md`, `README.md`
- [ ] `core-folding.md`: a full entry per new file (`FoldRegion`,
    `FoldRegionScanner`, `FoldState`, `FoldShift`, `FoldStateMemory`, the caret
    rule, the reveal rule, `FoldController`, `FoldCommands`), and every decision
    above written out — the hidden range's two endpoints and why the header stays
    whole; the two sources and why an answer is never a mixture; the three
    corrections to the original premises, stated as decisions with their reasons
    (including the reveal funnel's true shape: one coordinator method, two
    caller files, one in-file non-reveal site, three excluded text views and the
    viewer's own `EditorRevealState`); the memory key and why it is not
    `OpenFile.id`; why the memory is not pruned on close while the viewport
    memory is; the save-transform remap versus the shift rule; the two halves of
    hiding — the `.null` glyphs and the typesetter's
    `.zeroAdvancementAction` — with the spike's recorded outcome, and the list of
    overlays that need no code because nothing is drawn over hidden text.
- [ ] `core-lsp.md`: **D38** — `textDocument/foldingRange` as the seventh
    question, the closed decode table, the open `kind` field read as absence, the
    drops, the budget and its reason, and the capability node.
- [ ] `core-intelligence.md`: the seam's sixth method with its default, the index
    provider's scanner-backed answer, the router's rule, and why the request
    carries the indent widths.
- [ ] `core-editorconfig.md`: fold bounds as the fourth thing
    `SaveTransformPlan.remappedRange` moves, beside the caret, the selection
    endpoints and the scroll anchor — and why an autosave must not unfold.
- [ ] `app-editor-overlays.md`: the two halves of hiding and which one the spike
    proved load-bearing, the placeholder, the gutter's chevron column and the
    numbering skip.
- [ ] `app-editor.md`: `FoldController` and the `CodeEditorView` wiring, including
    the reveal funnel with its exact caller set, its one named in-file non-reveal
    site and its three excluded text views.
- [ ] `CLAUDE.md`: the index lines for the new files under a new
    `docs/architecture/core-folding.md` heading, the app-side index lines, the
    `FoldingSourceGatingTests` entry in the Tests section, and **one**
    cross-cutting invariants paragraph — folding is a reader that modifies no
    buffer, hides by layout alone, keeps its state for the app run and never in
    the session, and applies its three rules (caret, reveal, shift) in one place
    each. Keep the file well under its size target; no per-file essays.
- [ ] `docs/FEATURES.md`: the macOS section entry, plus two known-limitations lines
    — no folding on iOS, and the minimap showing all lines regardless of folds
    (part 2).
- [ ] `README.md`: the feature line and the two shortcuts.
- [ ] Run `swift test` — the documentation suites must stay green.

### Task 11: Verify acceptance criteria

- [ ] `swift test` — full suite green.
- [ ] `swiftlint --strict` from the repository root — clean. Any measured lint
    ceiling that moves (`file_length` / `type_body_length` for
    `CodeEditorView.swift`, `BracketOverlayLayoutManager.swift`,
    `LineNumberRulerView.swift`, `PisakaApp.swift`) moves **by the measured
    amount only**, with its reason appended to the existing comment chain in
    `.swiftlint.yml`, and `LintConfigurationTests` updated to match per
    `style-lint.md`.
- [ ] `xcodegen generate`.
- [ ] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination
    'platform=macOS' build` — green.
- [ ] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination
    'platform=iOS Simulator,name=iPhone 17 Pro' build` — green (iOS is
    untouched; this is the proof).

## Post-Completion: mandatory manual DEBUG pass

Run the app from a DEBUG build and confirm, by eye, what no test can see:

1. **The collapsed line's geometry.** Fold a multi-line brace block: the header
   line and the closing bracket sit on one visual line with the `…` between them,
   with no leftover blank row and no clipped glyph. This is also where the Task 5
   spike's verdict is confirmed on real text rather than on one sample.
2. **The placeholder at two zoom levels.** ⌘+ and ⌘−: the `…` and its outline
   scale with the editor font and stay aligned to the header line's baseline.
3. **Caret behaviour at both boundaries.** Arrow forward into a folded block lands
   past it; arrow backward lands before it; a click on the placeholder lands at the
   block's start; a click on the hidden text's row is impossible; shift-select
   across a whole folded block selects the hidden text and copying it yields the
   full text.
4. **Gutter numbering.** Numbers skip the hidden lines (`12` then `27`), never
   overlap, and the blame column and diagnostic markers follow. Fold near the end
   of a file and scroll to the last line.
5. **Light and dark appearance.** The chevrons, the placeholder outline and the
   indentation tints read correctly in both, and switching appearance while a block
   is folded repaints without a reload.
6. **The two sources.** A file with a language server available shows comment and
   import chevrons; a SQL, Markdown or Makefile file — and the same language with
   no server — shows bracket and indentation chevrons.
7. **The lifecycle.** Fold, switch tabs and back — still folded. Close the file and
   reopen it in the same run — still folded. Relaunch — unfolded. Switch branches
   so the file is rewritten — unfolded. Autosave with trailing whitespace inside a
   folded block — still folded.
8. **The reveal funnel end to end.** Into a folded block: the find bar's ⌘G, a Find
   in Files row, Go to Definition, a Problems row and a Usages row each open the
   block before scrolling — and the Tab key under `indent_style = space` on a
   scrolled-away caret still jumps back to it, the one non-reveal scroll left in
   place.
