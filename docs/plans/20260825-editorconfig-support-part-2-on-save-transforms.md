# EditorConfig support, part 2: on-save transforms

## Overview

Part 1 shipped the resolution core (`EditorConfigGlob`, `EditorConfigFile`,
`EditorConfigResolver`, `EditorConfigModel`) and consumed exactly three
properties, for indentation only, under a stated principle: *existing content is
never reformatted*.

Part 2 consumes the three on-save properties — `trim_trailing_whitespace`,
`insert_final_newline` and `end_of_line` — and thereby introduces the one
deliberate exception to that principle: a **save** may rewrite whitespace and
line terminators, and only when the project's own `.editorconfig` asks for it. A
file whose effective configuration states none of the three is saved
byte-for-byte as it is today, on every path, on both platforms.

The work is one new pure engine in `PisakaCore` that answers "what does saving
this buffer change, and where do the caret, the selection and the scroll anchor
land afterwards", plus thin wiring that applies its answer through the editor so
the open buffer, the bytes on disk and the saved baseline agree — and the
amendment written into every document that states the old principle.

## Context

**Part 1's core, extended rather than reworked:**

- `Sources/PisakaCore/EditorConfigFile.swift` — `EditorConfigProperties` already
  carries every parsed key; it exposes typed accessors for the three
  indentation properties only. Three more accessors go here.
- `Sources/PisakaCore/EditorConfigModel.swift` — the synchronous per-file cache.
  Unchanged; the save path asks it exactly as the key handlers do.
- `Sources/PisakaCore/IndentEngine.swift` — `newlineIndentation(text:location:
  unit:selectionLength:)` hardcodes `"\n"`. It gains the terminator.
- `Sources/PisakaCore/TerminatedLines.swift` — **the single line splitter** for
  the whole project. The transform needs the same lines *with offsets*, which
  must be a projection of this splitter rather than a second one.
- `Sources/PisakaCore/LineStartIndex.swift` — the editor-wide separator set
  (LF/CR/CRLF/NEL/LS/PS). `end_of_line`'s vocabulary is a strict subset of it;
  the difference is this feature's one stated limit.

**Every save path that must transform:**

- `PisakaApp.save(id:)` (`Sources/Pisaka/PisakaApp.swift`) — ⌘S, the close
  prompt's Save, and both `runFile(url:)` / `testFile(url:)` pre-run saves, which
  already funnel through it. Also `PisakaApp.saveAs(id:)` for the untitled case.
- `AutosaveController` (`Sources/Pisaka/AutosaveController.swift`) — idle,
  tab-switch, focus-loss and termination triggers, all calling
  `WorkspaceModel.saveAllDirty()`.
- `RootView_iOS`'s close-confirmation Save — the one save iOS has.

**The machinery the transform must ride:**

- `CodeEditorView.Coordinator.insertConfiguredTab(in:)` is the existing template
  for a multi-range programmatic edit: one `shouldChangeText` /
  `beginEditing`…`endEditing` / `didChangeText` bracket, applied back-to-front,
  under `isApplyingProgrammaticEdit`. One undoable step, one change
  notification, and every observer (Neon highlighting, the gutter, blame,
  diagnostics, the symbol index and — through `reindexSymbols` —
  `LSPDocumentSyncController`) sees it as an ordinary edit.
- `EditorSearchController` is the template for the app→text-view seam: owned by
  `PisakaApp`, `attach(textView:)`ed from `makeNSView`, holding the view weakly.
- `CodeEditorCoordinator_iOS.applyEdit(in:range:replacement:selecting:)` is the
  iOS peer (`UITextView.replace(_:withText:)`, one undo action).
- `EditorViewport` / `EditorViewportMemory` hold the per-tab selection and the
  character-offset scroll anchor — the positions requirement 1 must remap.
- `WorkspaceModel.replaceText(_:for:)` bumps the text-replacement revision,
  which `CodeEditorView` reads as "this buffer was rewritten off screen" and
  answers by dropping that tab's undo stack and remembered viewport.

**Documents stating the principle that must be amended:**
`CLAUDE.md` (the "Indentation is EditorConfig-first" invariant),
`docs/architecture/core-editorconfig.md`, `docs/FEATURES.md` (the editor
section's "existing code is never reformatted" and the EditorConfig list),
`README.md`.

## Development Approach

- **Testing approach: TDD for the Core engine** (Task 2 especially — the
  acceptance criteria are written as a test list), regular for the app wiring.
- All decision logic lands in `PisakaCore` with unit tests; `Sources/Pisaka`
  stays thin wiring and is untested by convention.
- **CRITICAL: every task MUST include new/updated tests.**
- **CRITICAL: `swift test` must pass before starting the next task.**
- No product or brand names in code, comments or docs.

## Implementation Steps

### Task 1: The three on-save properties, and lines with offsets

**Intent.** Give the resolved property map typed answers for the three
properties this feature consumes, and give the transform a way to enumerate
lines *with ranges* without introducing a second definition of what a line is.

**Files:**
- Modify: `Sources/PisakaCore/EditorConfigFile.swift`
- Modify: `Sources/PisakaCore/TerminatedLines.swift`
- Modify: `Tests/PisakaCoreTests/EditorConfigFileTests.swift`
- Modify: `Tests/PisakaCoreTests/TerminatedLinesTests.swift`

- [x] Add `EditorConfigProperties.EndOfLine` (`lf`, `cr`, `crlf`) with the
      terminator string each names, and an `endOfLine` accessor answering `nil`
      for an absent or unrecognized value — the same "absent rather than an
      error" posture the existing accessors take for a bad `indent_size`.
- [x] Add `trimTrailingWhitespace` and `insertFinalNewline` accessors returning
      `Bool?`: exactly the literals `true` / `false` (values of known keys are
      already lowercased by the parser), everything else `nil`.
- [x] Add a range-carrying split to `TerminatedLines` (content range +
      terminator range per line, the CRLF pair never split), and make the
      existing `split(_:)` a **projection** of it, so the one-splitter invariant
      the file's doc comment rests on stays structural rather than coincidental.
- [x] Write tests: each `end_of_line` value and the unrecognized/absent cases;
      both booleans including the `unset` inheritance case; the range split
      against every separator in the editor's set, an unterminated final line,
      an empty text, and a fuzz check that the projection equals `split(_:)`.
- [x] Run `swift test` — must pass before Task 2.

### Task 2: `SaveTransform` — the pure engine

**Intent.** One engine owns the whole question: given a buffer, the resolved
properties and the positions that must survive, what does this save change, what
does the file become, and where do those positions move? The views apply its
output and compute nothing themselves. This is the file the acceptance criteria
are really about.

**Files:**
- Create: `Sources/PisakaCore/SaveTransform.swift`
- Create: `Tests/PisakaCoreTests/SaveTransformTests.swift`

- [x] Model the answer as a plan: an ordered, **non-overlapping** list of
      `(range in the original text, replacement)` edits — reusing
      `IndentReplacement`, as `IndentUnitRule` already does — plus the resulting
      text and the position remap. An empty plan is the "this save changes
      nothing" answer every no-configuration case must produce.
- [x] Compose the three transforms into that one list, with a stated internal
      order (terminator normalization, then trimming, then the final
      terminator), every edit expressed against the *original* offsets so the
      composition needs no intermediate buffers and the remap is exact:
      - `end_of_line`: every LF, CR and CRLF terminator that differs from the
        target is replaced by it. NEL/LS/PS are left alone — the property's
        vocabulary does not name them, and this is the feature's stated limit.
        Absent or unrecognized: no normalization at all.
      - `trim_trailing_whitespace = true`: the trailing run of spaces and tabs
        before each terminator (and at end of file) is deleted, **except on a
        spared line**. Lines are spared by the protected positions the caller
        passes — the caret, and each selection endpoint, of the buffer being
        saved when it is open in an editor. No protected positions ≡ trim in
        full.
      - `insert_final_newline = true`: a file not ending in a terminator gains
        exactly one — the configured `end_of_line` when set, otherwise the
        file's own last terminator, otherwise LF. `false` or absent does
        nothing, and an existing final terminator is never removed nor doubled.
        An empty buffer stays empty (there is no line to terminate).
- [x] Own the remap arithmetic here and nowhere else: an offset before every
      edit is unchanged; after an edit it shifts by that edit's net length; and
      an offset *inside* an edit is defined explicitly (clamped into the
      replacement) rather than left to chance. Ranges remap through their two
      ends.
- [x] Write the acceptance test list: trimming with spaces, tabs and mixed runs
      (including a line that is only whitespace, and the last line);
      the spared line, then the same buffer trimmed once the protected position
      has moved; final newline in each terminator flavor, absent under
      `false`/unset, never doubled, never removed, empty buffer untouched; each
      of the three `end_of_line` targets against pure-LF, pure-CRLF, pure-CR and
      mixed files; NEL/LS/PS surviving every combination; remapping across both
      shrinking (CRLF→LF, trims) and growing (LF→CRLF, appended terminator)
      edits with positions before, inside and after each edit site and at
      end-of-file; and idempotence of the composed transform (the plan for the
      transformed text is empty).
- [x] Pin the no-configuration case: an empty property map, and a map carrying
      only part 1's indentation properties, both produce an empty plan and a
      byte-identical text.
- [x] Run `swift test` — must pass before Task 3.

### Task 3: Enter splices the configured terminator

**Intent.** `end_of_line` is consumed "in full": it decides what already-written
terminators become on save *and* what a newly typed one is. Both platforms ask
the same engine, and a project without the property keeps splicing LF byte for
byte.

**Files:**
- Modify: `Sources/PisakaCore/IndentEngine.swift`
- Modify: `Tests/PisakaCoreTests/IndentEngineTests.swift`

- [x] Parameterize `newlineIndentation` with the terminator to splice
      (defaulting to LF, so every existing caller and test is unaffected), and
      make the returned cursor offset and the between-brackets split measure the
      terminator's real UTF-16 length rather than assuming one unit.
- [x] Write tests: the plain inherit-indentation case, the opener case with its
      consumed trailing whitespace, and the between-brackets split, each under a
      two-unit terminator, asserting the caret lands where it does under LF; and
      that the default argument reproduces today's output exactly.
- [x] Run `swift test` — must pass before Task 4.

### Task 4: macOS — one funnel, every save path

**Intent.** Every macOS save asks the engine first and writes what it answers,
and the displayed buffer receives the change as an ordinary, single-step,
undoable edit rather than being replaced behind the editor's back.

**Files:**
- Create: `Sources/Pisaka/SaveTransformController.swift`
- Modify: `Sources/Pisaka/PisakaApp.swift`
- Modify: `Sources/Pisaka/AutosaveController.swift`
- Modify: `Sources/Pisaka/CodeEditorView.swift`
- Create: `Tests/PisakaCoreTests/SaveTransformIntegrationTests.swift`

- [x] Add one app-side controller, shaped like `EditorSearchController`: owned
      by `PisakaApp`, attached from the editor's `makeNSView`, holding the text
      view weakly, with a single entry point — "prepare these buffers for a
      save". It resolves properties through the existing `EditorConfigModel`,
      asks `SaveTransform` for the plan, and applies it. It decides nothing the
      engine decides.
- [x] Apply **through the text view** whenever the editor still holds that
      buffer — which includes the tab-switch autosave, whose trigger fires
      before the view swaps — using the `insertConfiguredTab` bracket:
      `shouldChangeText`, `beginEditing`…`endEditing`, `didChangeText`, edits
      back-to-front, under the programmatic-edit guard. Restore the selection
      and the scroll anchor from the engine's remap; do not scroll the caret
      into view (a save must not move the reader's page).
- [x] Apply through the model for a buffer the editor no longer holds, which
      necessarily invalidates that tab's undo stack and remembered viewport
      exactly as every other off-screen rewrite does. Say so in the doc comment
      as a known, bounded cost rather than leaving it to be discovered.
- [x] Because the composed edit can span the whole buffer, re-seed blame and
      diagnostics for it rather than letting the incremental shifters run across
      a full-range replacement — the buffer-swap path's reasoning, applied to
      the one other edit that can be file-wide. The symbol index and the LSP push
      sync need nothing new: `textDidChange` already carries the post-transform
      text down that path.
- [x] Call the funnel from `PisakaApp.save(id:)` (after the writer-gate refusal,
      before the write, so run/test and the close prompt inherit it), from
      `saveAs(id:)` once the destination is known (the configuration that
      applies is the destination's), and from `AutosaveController` ahead of
      `saveAllDirty()` on the regular triggers and on both flush paths — wired
      as an injected closure so the controller keeps holding no policy.
- [x] Confirm by inspection and by doc comment that nothing else calls it: not
      open, not close, not tab switch, not a configuration change, and not the
      worktree writers (Replace All, git operations) that keep writing exactly
      what they write today.
- [x] Write a Core-level behavioral suite over `WorkspaceModel` + `StubFileTree`
      + `EditorConfigModel` staging a real `.editorconfig` tree: the transform
      applied to a dirty buffer and then saved leaves the tab **clean**, with the
      buffer, the saved baseline and the written bytes identical; the remapped
      selection and anchor match the engine; a second save writes nothing new;
      and a project with no `.editorconfig` writes byte-identical bytes and moves
      exactly the same revision tokens as it does today.
- [x] Run `swift test` — must pass before Task 5.

### Task 5: iOS — the one save, and Enter

**Intent.** Symmetry: the same engine, the same properties, the same bytes. iOS
has exactly one save (the close-confirmation Save) and one Enter path.

**Files:**
- Modify: `Sources/Pisaka/iOS/RootView_iOS.swift`
- Modify: `Sources/Pisaka/iOS/CodeEditorCoordinator_iOS.swift`

- [x] Ask the engine before the iOS save and write what it answers, resolving
      properties through the `EditorConfigModel` that screen already holds.
- [x] Pass the configured terminator into `IndentEngine.newlineIndentation` from
      the Return handler, beside the indent unit it already resolves — the
      dedent and auto-pair behavior otherwise untouched.
- [x] Extend the Task 4 behavioral suite with the iOS save's shape (the same
      Core chain, no editor attached: a buffer with no protected positions is
      trimmed in full), since the iOS view layer itself is untested by
      convention.
- [x] Run `swift test` — must pass before Task 6.

### Task 6: Documentation — state the amendment where the old rule is written

**Intent.** A reader of part 1's documents must not be able to conclude the
opposite of what part 2 does. The amendment is stated at every site that states
the principle, and says the same three things each time: which transforms, on
what single trigger, and what still never happens.

**Files:**
- Modify: `docs/architecture/core-editorconfig.md`
- Modify: `CLAUDE.md`
- Modify: `docs/FEATURES.md`
- Modify: `README.md`

- [ ] Write the full entries in `core-editorconfig.md`: `SaveTransform` (the
      composition order, the spared-line rule and why the aggressive autosave
      needs it, the NEL/LS/PS limit and why, the remap's exactness, idempotence),
      the property accessors, the range-carrying split and why it is a
      projection, and the app halves — the funnel, the through-the-editor rule,
      and the off-screen cost.
- [ ] Amend the "never rewritten" paragraph there and the matching invariant in
      `CLAUDE.md`: the layer is still a reader that takes no writer gate and adds
      no write, still reformats nothing on open, on close, on tab switch or on a
      configuration change, and still rewrites no indentation — and now performs
      exactly three transforms, on a save, when the project asks. Add the index
      lines for the new files.
- [ ] Update the user-facing docs (`docs/FEATURES.md` and `README.md`): the
      three new properties, the caret-line exemption and what it protects, the
      `end_of_line` normalization with its stated limit, that Enter splices the
      configured terminator, and that a save is the only thing that ever triggers
      any of it. Correct the standing "existing code is never reformatted"
      wording in the editor section rather than leaving it to contradict the
      EditorConfig section a few lines below.

### Task 7: Verify acceptance criteria

- [ ] `swift test` green.
- [ ] `swiftlint --strict` clean from the repository root.
- [ ] `xcodegen generate` and the macOS build
      (`xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' build`).
- [ ] The iOS build
      (`-destination 'platform=iOS Simulator,name=iPhone 17 Pro'`).
- [ ] Re-read the acceptance list in the ticket against the test names and
      confirm each line has a test behind it.

## Post-Completion (manual, for the user)

- Open a project with `.editorconfig` setting all three properties in a DEBUG
  build and confirm by hand: the caret line survives the idle autosave, ⌘Z after
  a save restores the pre-save buffer in one step, the scroll position does not
  jump, and the gutter/diagnostics/bracket overlays land on the post-transform
  text.
- Confirm a project *without* `.editorconfig` shows no diff churn after a
  session of ordinary editing.

## Out of scope (restated, so it is not drifted into)

- `charset`, `max_line_length` and every other property: still parsed, still
  carried, still not consumed.
- Any transform outside a save; no whole-project normalization command.
- Changes to part 1's resolution core beyond the three accessors.
- Other worktree writers (Replace All, git operations) keep writing exactly what
  they write today.
- Live pickup of `.editorconfig` edits on iOS stays part 1's stated limit.
