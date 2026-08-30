# Rename Refactoring + Find Usages

## Overview

Two macOS-only code-intelligence commands built on the existing LSP investment:

- **Find Usages** — every reference to the identifier under the caret, listed in
  a new bottom dock panel; a row opens the file and reveals the occurrence. The
  language server answers first; where none serves the language (or it has
  nothing to say) an honest **textual** whole-word scan answers instead, and the
  panel says the results are textual.
- **Rename** — the symbol under the caret renamed project-wide through the
  server's `WorkspaceEdit`, applied atomically inside the app's writer bracket
  with a "Before Rename" Local History capture. **No fallback**: no server, no
  rename.

Every decision lives in `PisakaCore` (Foundation-only, unit-tested); the view
layer stays thin and macOS-gated. iOS compiles unchanged.

## Context

### Files involved

Core (new):

- `Sources/PisakaCore/UsageResult.swift` — the usages row/answer value types +
  hygiene (cap, dedup, ordering).
- `Sources/PisakaCore/TextualUsageScanner.swift` — the pure whole-word scan.
- `Sources/PisakaCore/FindUsagesModel.swift` — the panel's model (generation
  discipline, LSP-then-textual flow).
- `Sources/PisakaCore/RenameEditPlan.swift` — `WorkspaceEdit` → pure per-file
  plan, verification, refusals.

Core (modified): `LSPProtocolTypes.swift`, `LSPSession.swift`,
`LSPIntelligenceProvider.swift`, `RoutingIntelligenceProvider.swift`,
`CodeIntelligence.swift`, `BottomPanel.swift`, `LocalHistorySnapshot.swift`.

App, macOS (new): `Sources/Pisaka/UsagesPanelView.swift`.

App, macOS (modified): `PisakaApp.swift` (menus, shortcuts, the seventh gated
operation, the rename dialog), `CodeEditorView.swift` (the editor context menu +
the two caret entry points), `ContentView.swift` (the new panel slot).

Tests: new suites for each new Core file; updates to `BottomPanelTests`,
`LocalHistorySourceGatingTests`, `LSPProtocolTypesTests`/session tests,
`RoutingIntelligenceProviderTests`, `LocalHistorySnapshot` tests.
`ScriptedLSPTransport` and `StubFileTree` are the fakes to reach for.

### Related patterns

- `hover` — the defaulted seam method and the deliberate no-fallback precedent
  (D25).
- `LSPServerCapabilities.isEnabled` — the `boolean | options` collapse.
- `LSPWorkspace.prepare` + `stillHolds` + `LSPPositionMap` — the established
  request shape.
- `ProjectSearchModel` — generation tokens, caps, `offMain`, staleness re-check
  before a write.
- `ProblemsPanelView` + `DiagnosticStore.FileRows` — the bottom-panel row/group
  shape and `activateSearchMatch(url:range:)` callback.
- `SaveTransformController.applyRestore` — apply through the live text view,
  fall back to `WorkspaceModel.replaceText`.
- `replaceAllInProject` — the canonical writer bracket: `autosave.suspend()` +
  `localChanges.beginRevert()` synchronously, `defer` to balance,
  `await captureBeforeOperation(...)` as the first await, resync afterwards.
- `FilePanels.promptName(title:defaultValue:validator:)` — the validating name
  dialog.

### Decisions this plan settles

1. **Where the textual fallback runs.** *Not* in `RoutingIntelligenceProvider`:
   its fallback is the symbol index, which has no project-wide textual answer.
   The seam's `references` behaves like `hover` — LSP or nothing — and
   `FindUsagesModel` runs the textual scan itself over `ProjectFileWalk` +
   `FileServicing`, which it already owns. This keeps a project walk out of the
   provider chain.
2. **Shortcuts.** Find Usages `Ctrl+Cmd+U`; Rename `Ctrl+Cmd+R`; Show/Hide the
   Usages panel `Cmd+Shift+U`. All three are free today (`Cmd+R`/`Cmd+U` are Run
   File / Run Test and are untouched).
3. **Cap.** 2 000 usages, with a truncation note in the panel header. Rationale:
   an identifier with more usages than that is not a list anyone reads, and the
   Find in Files 10 000 cap is sized for arbitrary patterns across a project,
   not one name.
4. **Rename availability.** The menu item is enabled whenever a tab is open. On
   invocation the command pre-checks `canServe(language)` (free, policy-only)
   and beeps *without showing the sheet* when it is false. A server that turns
   out to advertise no `renameProvider`, or answers with no edits, beeps after
   the request. No alert, no banner — the fallback vocabulary of this layer.
5. **Background tabs and undo.** `SaveTransformController` holds exactly one
   text view (the displayed tab), so only that tab's rename lands as one
   undoable step; every other open tab is rewritten through
   `WorkspaceModel.replaceText` and loses its own undo stack, exactly as an
   off-screen save transform does. This is stated in the docs, not hidden.
6. **Verification order inside the bracket.** Capture first (the invariant is
   "first await inside the bracket"), then the whole-plan staleness
   verification, then all writes or none. An aborted rename leaves a harmless
   extra snapshot behind; retention prunes it.
7. **Post-apply bookkeeping.** The usages panel is **cleared** when its results
   name the renamed identifier — not re-run. A re-run would spend a project walk
   (or a server round trip) on a question nobody asked, and every row it produced
   would name the old name.

## Development Approach

- **Testing approach**: Regular (code first, then tests) — matching the
  repository's existing suites.
- Complete each task fully before moving to the next.
- **CRITICAL: every task MUST include new/updated tests.**
- **CRITICAL: `swift test` must pass before starting the next task.**
- Async tests stage races through a causal rendezvous (`Gate`, `waitFor`), never
  timed delays or `Task.yield()` spins.
- No product or brand names anywhere — code, comments, tests, docs, commit
  messages.
- Core stays Foundation-only; all new UI is inside `#if os(macOS)`.

## Implementation Steps

### Task 1: Protocol types and session requests

**Files:**

- Modify: `Sources/PisakaCore/LSPProtocolTypes.swift`,
  `Sources/PisakaCore/LSPSession.swift`
- Modify: `Tests/PisakaCoreTests/LSPProtocolTypesTests.swift`,
  `Tests/PisakaCoreTests/LSPSessionTests.swift`

- [x] Add `textDocument/references` and `textDocument/rename` to `LSPMethod`.
- [x] Decode `referencesProvider` and `renameProvider` into
  `LSPServerCapabilities` (`supportsReferences`, `supportsRename`) through the
  existing `isEnabled` collapse; keep the tree closed and the initializer's
  defaults `false`.
- [x] Add the request params: a references param carrying
  `context.includeDeclaration` (send `true` — the declaration is a usage the
  user expects to see), and a rename param carrying `newName`.
- [x] Add the response types: `[LSPLocation]` (with `null`/absent folded to
  empty, as the other responses do) and `LSPWorkspaceEdit` decoding **both**
  spellings — `changes` (uri → `[LSPTextEdit]`) and `documentChanges` (array of
  `{ textDocument: {uri, version}, edits }`), leniently, keeping the optional
  document `version` when present and ignoring create/rename/delete file
  operations rather than failing the decode.
- [x] Add `references(_:)` and `rename(_:)` to `LSPSession` in the established
  shape (encode params, `request` with a budget, `decode`), each on the
  definition budget.
- [x] Extend `LSPSession.Budgets` with the two new spans and document why they
  share definition's number (both are explicit user commands, not pointer
  dwell).
- [x] Write tests: the capability decode for both wire spellings (`true`, `{}`,
  `false`, absent, `null`); both `WorkspaceEdit` spellings including a
  mixed/unknown-operation document-changes array; the two session round trips
  through `ScriptedLSPTransport`, including a `null` result and a server error.
- [x] Run `swift test` — must pass before Task 2.

### Task 2: The seam, the LSP provider, and the router

**Files:**

- Modify: `Sources/PisakaCore/CodeIntelligence.swift`,
  `Sources/PisakaCore/LSPIntelligenceProvider.swift`,
  `Sources/PisakaCore/RoutingIntelligenceProvider.swift`
- Modify: `Tests/PisakaCoreTests/RoutingIntelligenceProviderTests.swift`,
  `Tests/PisakaCoreTests/LSPIntelligenceProviderTests.swift`

- [x] Add to `CodeIntelligenceProviding`, both defaulted (`hover`'s precedent,
  so partial conformers keep compiling): `references(for:) async ->
  [UsageResult]` defaulting to `[]`, and `renameEdits(for:) async ->
  RenameAnswer?` defaulting to `nil`. Add the two request value types
  (`UsagesRequest`, `RenameRequest`), each carrying the live buffer, the file
  URL, the offset and the identifier; `RenameRequest` also the new name.
- [x] Add `canRename(_ language:) async -> Bool` to `LSPIntelligenceSource`
  (policy-only, `canServe`'s shape) so the app can refuse before it shows a
  sheet.
- [x] Implement both in `LSPIntelligenceProvider`, step for step as
  `definitions(for:)`: the D2 empty-buffer guard, the language off the file
  name, `prepare` so the buffer reaches the server, the capability read after
  `prepare`, `LSPPositionMap` in and out, `stillHolds` before the answer is
  read. Map every location to a `UsageResult` reusing `definitions`' per-file
  text cache, the editor's own line numbering (`LineStartIndex` via
  `TextSearchEngine.lineNumber`), the buffer beating the disk for the requesting
  file, and the canonical-components relative path.
- [x] Route in `RoutingIntelligenceProvider`: both questions are `canServe`-gated
  and budget-raced, and **neither falls through** — hover's rule, for hover's
  reason (an index cannot enumerate references, and a textual rename that looks
  right until it corrupts a same-named symbol is the worst possible answer).
  Document that the *textual* usages answer is a model-level decision, not a
  provider fallback.
- [x] Write tests: an unserved language never enters the LSP stack (equality
  against the untouched fallback output, as the existing suite does); a
  timed-out/empty/no-capability references answer yields `[]` and a rename
  answer yields `nil`; the position round trip through a file with a non-ASCII
  line; a target URI that is not a file URL is dropped silently.
- [x] Run `swift test` — must pass before Task 3.

### Task 3: Usage results — value types, hygiene, and the textual scanner

**Files:**

- Create: `Sources/PisakaCore/UsageResult.swift`,
  `Sources/PisakaCore/TextualUsageScanner.swift`
- Create: `Tests/PisakaCoreTests/UsageResultTests.swift`,
  `Tests/PisakaCoreTests/TextualUsageScannerTests.swift`

- [x] `UsageResult`: file URL, buffer range, one-based line, relative path, a
  single-line preview with the match range inside it (`MatchPreview`'s shape),
  and whether it came from a textual scan. Plus a `UsagesAnswer` carrying the
  identifier, the rows, the provenance (semantic / textual) and a truncation
  flag.
- [x] Hygiene, pure and tested: dedup by `(canonical file, range)`; ordering —
  the requesting file first, then relative path, then buffer offset; the 2 000
  cap applied after ordering with the truncation flag set when it bites.
- [x] `TextualUsageScanner`: whole-word occurrences of an identifier in one
  text, boundaries decided by
  `IdentifierScanner.isIdentifierStart`/`isIdentifierContinuation` (not a regex
  — an identifier may contain characters a pattern would have to escape),
  returning ranges plus previews. Guard the empty and non-identifier query.
- [x] Write tests: boundary cases (`foo` inside `foobar`, `_foo`, `foo_`,
  `foo.bar`, Unicode identifiers, a match at offset 0 and at end of buffer),
  CRLF and the editor's full separator set for line numbers, dedup across a
  symlink-ish duplicate path, ordering with the requesting file in the middle of
  the alphabet, the cap and its flag.
- [x] Run `swift test` — must pass before Task 4.

### Task 4: `FindUsagesModel` and the panel case

**Files:**

- Create: `Sources/PisakaCore/FindUsagesModel.swift`,
  `Tests/PisakaCoreTests/FindUsagesModelTests.swift`
- Modify: `Sources/PisakaCore/BottomPanel.swift`,
  `Tests/PisakaCoreTests/BottomPanelTests.swift`

- [x] Add `case usages` to `BottomPanel`; update `BottomPanelTests` for the new
  case (the `toggled(_:selecting:)` rule is unchanged).
- [x] `FindUsagesModel` (`@MainActor`, `ObservableObject`, over an injected
  `FileServicing` and a provider closure): published identifier, rows grouped
  for the panel, provenance, truncation, `isSearching` and an empty-state
  reason.
- [x] The flow: ask the provider's `references`; on an empty answer run the
  textual scan over `ProjectFileWalk.collectFiles(root:maskPatterns: [],
  fileService:)` off the main actor in chunks, honoring gitignore and the same
  per-file byte cap the project search uses (`readTextIfNotBinary`), reading an
  open buffer's text in preference to the disk copy where one exists (the
  `openBuffers` closure `ProjectSearchModel` already establishes).
- [x] Generation discipline: a request token captured **synchronously** before
  the hop, re-checked after *every* await; a newer query discards an older
  answer rather than publishing over it. A separate project token bumped on
  folder change (`prepareForFolderChange`'s shape), so a folder switch mid-walk
  abandons the walk.
- [x] `clearIfNaming(_ identifier:)` for the post-rename bookkeeping
  (decision 7).
- [x] Write tests: the semantic path publishes the provider's rows with semantic
  provenance; an empty provider answer falls to the textual scan and publishes
  textual provenance; a superseded query never publishes (staged with `Gate`,
  asserted by polling a sink, no timed delays); a folder switch mid-walk
  abandons; the cap and the truncation flag reach the published state;
  `clearIfNaming` clears on a match and leaves other results alone.
- [x] Run `swift test` — must pass before Task 5.

### Task 5: The rename edit plan

**Files:**

- Create: `Sources/PisakaCore/RenameEditPlan.swift`,
  `Tests/PisakaCoreTests/RenameEditPlanTests.swift`
- Modify: `Sources/PisakaCore/LocalHistorySnapshot.swift`,
  `Tests/PisakaCoreTests/LocalHistorySnapshotTests.swift`

- [x] Add `case rename` to `LocalHistoryEvent` with tag `rename` and title
  `Before Rename`; the tag is on-disk data, so the round trip through
  `LocalHistoryLayout`'s name codec gets a test.
- [x] `RenameEditPlan.make(from:root:texts:)`: a `LSPWorkspaceEdit` plus the text
  of each named file becomes an ordered list of per-file plans. Each file's edits
  are mapped to buffer ranges through `LSPPositionMap`, sorted ascending, and
  each carries `expectedText` — the text the range currently holds.
- [x] Refusals, each a named reason and each all-or-nothing: overlapping ranges
  in one file; a file outside the project root (canonical comparison —
  `LSPWorkspace` and the servers disagree about `/private`, and `CanonicalPath`
  is the arbiter); a URI that is not a file URL; a range that cannot be mapped;
  a file whose text could not be read.
- [x] `verify(against:)`: given the current text of each file (the open buffer
  where one exists, the disk copy otherwise), every range must still hold its
  `expectedText`. Any mismatch answers with the offending file — the whole
  rename aborts, never a partial application.
- [x] `applied(to:)` per file: the resulting text, produced by applying the
  ascending edits in reverse (the `SaveTransformPlan` shape), plus the remap
  needed to keep a caret sane in the displayed tab.
- [x] Write tests: construction from `changes` and from `documentChanges`
  producing identical plans; overlap refusal; out-of-root refusal (including the
  `/private` spelling); multi-edit single-file ordering; verification success,
  verification failure naming the right file, and verification against a buffer
  that differs from disk; the applied text for a file with several edits and a
  CRLF line ending.
- [x] Run `swift test` — must pass before Task 6.

### Task 6: Entry points and the usages panel (macOS)

**Files:**

- Create: `Sources/Pisaka/UsagesPanelView.swift`
- Modify: `Sources/Pisaka/CodeEditorView.swift`,
  `Sources/Pisaka/PisakaApp.swift`, `Sources/Pisaka/ContentView.swift`
- Modify: `Tests/PisakaCoreTests/LocalHistorySourceGatingTests.swift` (only if a
  set it pins moves), `Tests/PisakaCoreTests/ZoomSourceGatingTests.swift`,
  `Tests/PisakaCoreTests/BottomPanelSourceGatingTests.swift`

- [x] `EditorTextView`: two caret entry points beside `goToDefinitionAtCaret()` —
  `findUsagesAtCaret()` and `renameAtCaret()` — both resolving the word through
  `IdentifierScanner` from the selection's start, both beeping when nothing
  resolves.
- [x] An editor context menu (`menu(for:)` on `EditorTextView`, the
  `LineNumberRulerView` precedent): the stock menu plus Go to Definition, Find
  Usages and Rename, each disabled when the click resolves no identifier.
- [x] Find menu items with the shortcuts decision 2 fixes, routed through the key
  window's first responder exactly as `goToDefinitionAtCaret()` is; a View-menu
  toggle for the Usages panel.
- [x] `UsagesPanelView` in `ProblemsPanelView`'s shape: a header naming the
  identifier, the count, the truncation note and — when the answer was textual —
  a plain "textual matches" label; rows grouped by file with the line number and
  preview; activation calls back into `activateSearchMatch(url:range:)`. Chrome:
  `\.interfaceMetrics` throughout, **no** zoom surface, no minimum height (the
  bottom-panel gating rules).
- [x] Wire the panel into `ContentView`'s panel slot and the bottom bar beside
  Problems.
- [x] A row whose file/range no longer matches when activated degrades to opening
  the file with no reveal (clamp the range against the buffer as it then is) —
  never a crash, never a reveal of the wrong span.
- [x] Write/extend tests: the source-gating suites stay green and their pinned
  sets are updated only if the new views genuinely change one; a Core test for
  the row-activation clamp rule (put the clamp in Core, not the view).
- [x] Run `swift test` — must pass before Task 7.

### Task 7: Rename as the seventh gated operation (macOS)

**Files:**

- Modify: `Sources/Pisaka/PisakaApp.swift`,
  `Sources/Pisaka/SaveTransformController.swift` (only if the displayed-tab
  apply needs an entry point beside `applyRestore`)
- Modify: `Tests/PisakaCoreTests/LocalHistorySourceGatingTests.swift`

- [x] The command: resolve the identifier, pre-check `canRename` and beep without
  a sheet when it is false, then `FilePanels.promptName` prefilled with the old
  name, validating with `IdentifierScanner.isIdentifier(_:)` and "must differ
  from the current name" as the two inline reasons.
- [x] The request runs **outside** the bracket (it is a read), then the plan is
  built from the answer and the texts in hand.
- [x] The apply, as the seventh gated operation: `autosave.suspend()` +
  `localChanges.beginRevert()` raised **synchronously** before the first await
  and balanced by `defer`; `await captureBeforeOperation(.rename, buffers:
  openBufferTexts(), targets: <every file the plan touches>)` as the **first
  await inside the bracket**; then the whole-plan verification; then, only if it
  passed, the writes.
- [x] Writes: the displayed tab through the live text view as one undoable step
  (the `SaveTransformController` application path); every other open tab through
  `WorkspaceModel.replaceText` plus the buffer-replaced notification, which costs
  that tab its undo stack (decision 5); every file no tab holds through
  `FileServicing.write`.
- [x] Afterwards: `refreshLocalChanges()`, `model.bumpTreeRevision()`,
  `notifyIndexOfProjectFileChanges()`, and `reindexReloadedBuffer` for every
  rewritten tab — the same resync `replaceAllInProject` runs. Then
  `usages.clearIfNaming(oldName)`.
- [x] A failed verification aborts before any write, with an alert naming the
  stale file, and leaves every file untouched.
- [x] Update `LocalHistorySourceGatingTests`: six becomes **seven** for both
  bracket halves and the capture count, and the alternation assertion must still
  hold.
- [x] Write tests: the Core-side rename orchestration (plan → verify → per-file
  outcomes) exercised through `StubFileTree` with an injected buffer set,
  including the abort path leaving every file byte-identical; the gating suite's
  new counts.
- [x] Run `swift test` — must pass before Task 8.

### Task 8: Verify acceptance criteria

- [x] `swift test` — the full suite green.
- [x] `swiftlint --strict` from the repository root — clean.
- [x] `xcodegen generate` then the macOS build (`xcodebuild -project
  Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' build`).
- [x] The iOS build (`-destination 'platform=iOS Simulator,name=iPhone 17 Pro'`)
  — unchanged and green; no new file reachable from the iOS layer.
- [x] Confirm the new Core files import Foundation only (`CrossPlatformAuditTests`
  stays green) and every new app file is inside `#if os(macOS)`.
- [x] Confirm every new decision path named in the acceptance criteria has a
  test: capability decode, both request/response mappings, the whole-word rule
  and caps, ordering/dedup, both `WorkspaceEdit` spellings, overlap and
  out-of-root refusal, staleness verification, and the panel's generation
  discipline.

### Task 9: Update documentation

- [x] `CLAUDE.md`: index lines for the four new Core files and the new app view;
  update the writer-gate invariant from six gated operations to seven; note the
  usages panel beside the Problems panel in the app-window index.
- [x] `docs/architecture/core-lsp.md`: full entries for the new session requests
  and capability fields; a new decision recording **rename has no fallback** with
  hover's (D25) reasoning, and one recording that the textual usages answer is a
  *model* decision rather than a provider fallback. Record there too that the
  decoded document `version` is not compared: the per-range `expectedText`
  verification is the stronger check that honors it.
- [x] `docs/architecture/core-intelligence.md`: `UsageResult`,
  `TextualUsageScanner`, `FindUsagesModel` — the hygiene rules, the cap and its
  number, the generation discipline.
- [x] `docs/architecture/core-local-history.md`: the `rename` event and the
  seventh capture site.
- [x] `docs/architecture/app-window.md`: the usages panel entry;
  `docs/architecture/app-editor.md`: the editor context menu and the two caret
  entry points.
- [x] `README.md`: three shortcut rows (Ctrl+Cmd+U, Ctrl+Cmd+R, Cmd+Shift+U).
- [x] `docs/FEATURES.md`: a section stating honestly that (a) textual matches are
  whole-word matches and not semantic references, (b) rename is unavailable
  without a language server, and (c) **only the tab on screen when the rename is
  applied gets an undoable step — every other open tab is rewritten in place and
  loses its undo stack, and files no tab holds change on disk with no undo at
  all; a rename is therefore not undoable as a unit, and Local History's "Before
  Rename" revisions (one per touched file) are the recovery story**
  (decision 5).
- [x] Record the out-of-scope follow-ups where the docs already keep such notes:
  an iOS textual usages fallback, a rename preview, `prepareRename`, and
  cross-file undo.

## Post-Completion (manual, outside the agent's checkboxes)

- Open a served project (Swift/Go/Rust/TS), Find Usages on a symbol, click a row
  — it opens and reveals.
- Do the same in a language with no server — the panel lists whole-word matches
  and says they are textual.
- Rename a symbol with a dirty tab open and a closed file affected; confirm the
  dirty tab keeps its edits, the closed file changed on disk, and Local History
  holds a "Before Rename" revision for each.
- Stage a staleness conflict (edit a file behind the app between the server's
  answer and the apply) and confirm the abort leaves every file untouched.
