# EditorConfig support, part 1: resolution core + indentation properties

## Overview

Teach Pisaka to honor `.editorconfig`. Part 1 ships the complete resolution
engine in `PisakaCore` — the file format parser, EditorConfig's own glob
dialect, the hierarchy walk and the merge — and consumes exactly three
properties: `indent_style`, `indent_size`, `tab_width`. Every other property is
parsed and carried but not acted on (part 2 consumes the on-save ones).

Two editor behaviors change, both only when a config actually applies: the
indentation unit Enter's auto-indent uses, and what the Tab key inserts. With
no applicable config, both are byte-for-byte what they are today — the existing
content-based inference (`IndentEngine.inferIndentUnit`) stays the fallback and
its tests stay untouched.

Per the answered question, the unit is derived **hybridly**: `indent_style`
(when present) decides tabs vs. spaces, `indent_size`/`tab_width` decides the
width, and each missing half falls back to what the content inference says for
that half.

## Context

Files involved:
  - Core, new: `Sources/PisakaCore/EditorConfigGlob.swift`,
    `EditorConfigFile.swift`, `EditorConfigResolver.swift`,
    `EditorConfigModel.swift`, `IndentUnitRule.swift`
  - Core, read/unchanged: `IndentEngine.swift` (the fallback inference and both
    edit computations stay exactly as they are), `FileService.swift`
    (`FileServicing` seam), `CanonicalPath.swift` (containment test),
    `GitignoreMatcher.swift` (style precedent only — deliberately not reused)
  - macOS wiring: `Sources/Pisaka/PisakaApp.swift` (model ownership; the
    `projectWatcher.start(root:onChange:)` call around line 1740),
    `Sources/Pisaka/ContentView.swift` (line 663, the `CodeEditorView`
    construction), `Sources/Pisaka/CodeEditorView.swift` (`doCommandBy` around
    line 1713, `insertIndentedNewline` at line 1747; the column-selection
    `setSelectedRanges` path at line 2722 is what makes multi-insertion-point
    Tab a live case)
  - iOS wiring: `Sources/Pisaka/iOS/PisakaApp_iOS.swift` (owns
    `SecurityScopedFileService`), `Sources/Pisaka/iOS/RootView_iOS.swift` (line
    458 editor construction, `synchronizeSymbolIndex(forRoot:)`,
    `notifyIndexOfProjectFileChanges()` at line 1226),
    `Sources/Pisaka/iOS/CodeEditorCoordinator_iOS.swift` (`shouldChangeTextIn`
    around line 620, `insertIndentedNewline` at line 644)
  - Tests: new suites in `Tests/PisakaCoreTests/`, using the existing
    `Support/StubFileTree.swift`
  - Docs: new `docs/architecture/core-editorconfig.md`; updates to
    `docs/architecture/core-editor.md`, `app-editor.md`, `app-shell.md`,
    `app-ios.md`, `CLAUDE.md`, `docs/FEATURES.md`, `README.md`

Related patterns:
  - Pure engine + thin glue: every decision in Core with unit tests, the views
    only wire keys (repository invariant).
  - A Core model the app owns as a plain stored reference because it publishes
    nothing — `SymbolIndexController`/`symbolIndex` precedent in `PisakaApp` and
    `RootView_iOS`, and the "plain value, not a second observed object" note on
    `CodeEditorView.completionEnabled`.
  - Reader, not writer: like the symbol index, this layer only reads files, so
    it neither raises the disk-writer gate nor is gated by it.
  - `StubFileTree` for `FileServicing`-backed Core tests.

Dependencies: none. Foundation only; no new package, no regex engine — the glob
is a compiled-token matcher like `GitignoreMatcher`.

## Development Approach

  - **Testing approach**: Regular (code first, then tests), matching the
    repository's existing suites.
  - Complete each task fully before moving to the next.
  - **CRITICAL: every task MUST include new/updated tests.**
  - **CRITICAL: all tests must pass (`swift test`) before starting the next
    task.**
  - Keep `.swiftlint.yml` untouched: the pinned thresholds are asserted by
    `LintConfigurationTests`, so new code must fit under them (140-line
    functions, complexity 22, 140-column lines) — split the matcher rather than
    raise a ceiling.
  - No fixture files on disk: an actual `.editorconfig` committed under `Tests/`
    would also apply to this repository in every editor and every tool that
    reads the format. Sample configs are inline string constants fed to
    `StubFileTree` in-memory trees; "fixture-based" is honored by modelling the
    case *contents* on the official EditorConfig core test suite (each glob
    construct, the hierarchy cases, the parser edge cases), naming each test
    after the case it mirrors.
  - No product or brand names anywhere in code, comments or docs.

## Implementation Steps

### Task 1: The glob dialect

**Files:**
  - Create: `Sources/PisakaCore/EditorConfigGlob.swift`
  - Create: `Tests/PisakaCoreTests/EditorConfigGlobTests.swift`
  - [x] Implement `public struct EditorConfigGlob` compiling a section pattern
        once into tokens and answering `matches(relativePath: String) -> Bool`,
        where the path is `/`-separated and relative to the directory holding
        the `.editorconfig`. Pattern preprocessing follows the spec: a pattern
        with no unescaped `/` matches at any depth (as if written `**/pattern`);
        otherwise it is anchored to that directory and a leading `/` is dropped.
  - [x] Implement the token vocabulary and the recursive, backtracking match:
        `*` (any run except `/`), `**` (any run *including* `/`, and — unlike
        `GitignoreMatcher` — not required to be a whole path component), `?`
        (one character, `/` excluded), `[abc]`/`[a-z]`/`[!abc]` classes (an
        unclosed `[` is literal), `{a,b}` alternation with arbitrary nesting, a
        brace group with neither a comma nor `..` treated as literal text
        (`{single}`, `{}`), `{num1..num2}` integer ranges matching any integer
        in range including negative bounds and a matched leading `-`, and `\`
        escaping the next character. Document, on the type, that `?` excluding
        `/` is a deliberate choice where the reference implementations disagree.
  - [x] Enforce the spec's size floor as the cap: a core must accept section
        names up to and including 1024 characters, so a longer section name
        never matches.
  - [x] Write `EditorConfigGlobTests` covering each construct separately,
        mirroring the official core suite's glob cases: star vs. slash, `**`
        across directories, `?`, classes and negated classes, literal brace
        groups, nested braces, numeric ranges (including negatives and a
        non-integer that must not match), escapes, the 1024-character boundary
        (accepted at the limit, ignored beyond it), and the "no slash ⇒ any
        depth" vs. "slash ⇒ anchored" split.
  - [x] Run `swift test` — must pass before Task 2.

### Task 2: The file format parser and the property map

**Files:**
  - Create: `Sources/PisakaCore/EditorConfigFile.swift`
  - Create: `Tests/PisakaCoreTests/EditorConfigFileTests.swift`
  - [x] Implement `public struct EditorConfigFile` parsing one file's text into
        `isRoot` plus an ordered `[Section]` (each a compiled `EditorConfigGlob`
        and its ordered key/value pairs). Rules: `root = true` honored only in
        the preamble before the first section and compared case-insensitively;
      **comments are line comments only** — a `#` or `;` starts a comment only
      as the first non-whitespace character of a line, and one appearing
      anywhere else is ordinary text belonging to the value, per the current
      spec's explicit prohibition of inline comments (so `foo = a ;)` has the
      value `a ;)`); keys are trimmed and lowercased; values are trimmed and
      lowercased for the known property set, carried verbatim otherwise; a
      section header is the text between `[` and the last `]` on the line; a
      duplicate key inside one section is last-wins; a key longer than 1024 or a
      value longer than 4096 characters is ignored (the spec's required
      acceptance floors are the cap); any malformed line is skipped without
      failing the rest of the file.
  - [x] Implement `public struct EditorConfigProperties`: the full merged map
        (unknown properties carried, never dropped), plus `subscript(key:)` and
        the typed accessors this ticket consumes — `indentStyle`
        (`.tab`/`.space`, `nil` when absent or unrecognized), `indentSize`
        (`.tab` or `.width(Int)`, positive integers only), `tabWidth` (explicit,
        else the numeric `indent_size` per the spec's default) and `indentWidth`
        (numeric `indent_size`; `indent_size = tab` → the explicit `tab_width`;
        no `indent_size` → `tab_width` when set; `nil` otherwise).
  - [x] Write `EditorConfigFileTests` for the parser edge cases from the
        official suite — a whole-line `#` and `;` comment (with leading
        whitespace), a `;`/`#` inside a value being kept verbatim including the
        spec's own `foo = a ;)` case and a `#` with no preceding space,
        whitespace around keys and values, a value containing `=`, a key at and
        beyond 1024 characters and a value at and beyond 4096, a header with no
        closing bracket, a `root = true` after the first section being ignored,
        case-insensitivity of keys and of known values — and for every accessor,
        including the `indent_size = tab` → `tab_width` coupling and rejection
        of `0`/negative/non-numeric sizes.
  - [x] Run `swift test` — must pass before Task 3.

### Task 3: The hierarchy resolver

**Files:**
  - Create: `Sources/PisakaCore/EditorConfigResolver.swift`
  - Create: `Tests/PisakaCoreTests/EditorConfigResolverTests.swift`
  - [ ] Implement `public enum EditorConfigResolver` with
        `resolve(fileURL:projectRoot:fileService:) -> EditorConfigProperties`:
        establish that the file lives under the root (containment tested through
        `CanonicalPath`, the repository's "inside this dir?" rule), then build
        the directory chain from the file's *own* spelling so section globs
        match the path as the user wrote it, and return empty properties for a
        `nil` root or a file outside it (an untitled buffer, an out-of-project
        definition window).
  - [ ] Walk from the file's directory upward reading `.editorconfig` through
        `FileServicing` (an unreadable or absent file is simply skipped),
        stopping after the first file declaring `root = true` — and never above
        the project root, whose own file is the last one considered whatever it
        declares.
  - [ ] Merge outermost-first: within each file, every section whose glob
        matches applies in document order, overwriting per property, so closer
        files and later sections win. A value of `unset` (case-insensitive)
        removes the property instead of setting it.
  - [ ] Write `EditorConfigResolverTests` over `StubFileTree`: nested configs
        overriding per property, `root = true` stopping the walk, a config above
        the project root never read, later-section-wins inside one file, `unset`
        clearing an inherited property, unknown properties surviving the merge,
        a file outside the root and a `nil` root both resolving to empty, and an
        unreadable `.editorconfig` degrading to "no properties from that file"
        rather than failing the walk.
  - [ ] Run `swift test` — must pass before Task 4.

### Task 4: The cached, invalidatable model

**Files:**
  - Create: `Sources/PisakaCore/EditorConfigModel.swift`
  - Create: `Tests/PisakaCoreTests/EditorConfigModelTests.swift`
  - [ ] Implement `@MainActor public final class EditorConfigModel`, holding the
        `FileServicing` seam, the current project root and a per-file cache of
        resolved properties. `properties(for fileURL: URL?) ->
        EditorConfigProperties` answers synchronously (the Enter/Tab handlers
        are synchronous) and resolves on a miss.
  - [ ] Implement the two invalidation entry points as the pure Core rule:
        `noteProjectRoot(_:)` — a different root (including `nil`) clears the
        whole cache before anything can be served, so a config from a previously
        open project is never returned — and `noteProjectFilesChanged()`, which
        clears the cache wholesale (a resolution is a handful of small reads; a
        per-path filter would be more machinery than the work it saves).
  - [ ] Document on the type that this layer is a **reader**, like the symbol
        index: it never takes the disk-writer gate and is never gated by it.
  - [ ] Write `EditorConfigModelTests`: a resolved answer served from cache
        without a second read (assert against `StubFileTree`'s read log), an
        edited `.editorconfig` picked up after `noteProjectFilesChanged()`, a
        root switch clearing entries from the previous project, a `nil` root
        answering empty, and repeated queries for different files under one
        root.
  - [ ] Run `swift test` — must pass before Task 5.

### Task 5: The indentation rules

**Files:**
  - Create: `Sources/PisakaCore/IndentUnitRule.swift`
  - Create: `Tests/PisakaCoreTests/IndentUnitRuleTests.swift`
  - [ ] Implement `public enum IndentUnitRule` with `unit(config:inferred:) ->
        String`, the hybrid rule: `indent_style = tab` → a tab; `indent_style =
        space` → spaces of the configured width, falling back to the inferred
        width when the config gives none and to four spaces when the inference
        itself yields a tab; no `indent_style` → a configured width re-widens a
        space inference and leaves a tab inference a tab; no applicable property
        at all → `inferred`, returned unchanged.
  - [ ] Implement `tabInsertion(config:inferred:) -> String`: the effective unit
        only when the config says `indent_style = space`, a literal tab in every
        other case — so a project with no config keeps inserting a tab exactly
        as today, and the content inference alone never turns Tab into spaces.
  - [ ] Implement the multi-insertion-point arithmetic as a pure rule too, so
        the view stays wiring: `tabInsertionPlan(ranges:insertion:)` takes the
        selection's ranges (each a caret or a range, as the column-selection
        gesture leaves them) and the insertion string, and returns the ordered
        replacements plus the resulting carets — every range replaced by the
        insertion, each resulting caret at the end of its own insertion, shifted
        by the net length change of every earlier range. Overlapping or
        unordered input is normalized (sorted, empty input answers no edits).
  - [ ] Leave `IndentEngine` untouched: it keeps taking `unit` as a parameter
        and its existing tests keep passing unmodified.
  - [ ] Write `IndentUnitRuleTests` for the full matrix — both styles, width
        from `indent_size`, width from `tab_width`, `indent_size = tab` with and
        without `tab_width`, each half-specified case against both a
        tab-inferred and a space-inferred file, and empty properties returning
        the inference and a literal tab respectively — plus the plan cases: one
        caret, one non-empty range, several carets on consecutive lines (the
        column-selection shape), several non-empty ranges, and the resulting
        caret offsets checked against a text the test applies the plan to.
  - [ ] Run `swift test` — must pass before Task 6.

### Task 6: macOS wiring

**Files:**
  - Modify: `Sources/Pisaka/PisakaApp.swift`
  - Modify: `Sources/Pisaka/ContentView.swift`
  - Modify: `Sources/Pisaka/CodeEditorView.swift`
  - [ ] Own one `EditorConfigModel` in `PisakaApp` as a plain stored reference
        (it publishes nothing — the `symbolIndexController` precedent), built
        over the existing `FileService()`, and pass it through `ContentView`
        into `CodeEditorView` as a plain, undefaulted property beside
        `symbolIndex`.
  - [ ] Invalidate from the two places that already exist: `noteProjectRoot(_:)`
        where the folder is opened/switched, and `noteProjectFilesChanged()` in
        the `projectWatcher.start(root:onChange:)` callback beside the tree bump
        and the index refresh — which is what makes a live `.editorconfig` edit
        take effect without reopening the project.
  - [ ] Feed `insertIndentedNewline` the rule's unit:
        `IndentUnitRule.unit(config: editorConfig.properties(for: fileURL),
        inferred: IndentEngine.inferIndentUnit(text: nsText))`, leaving the rest
        of the handler and the dedent path untouched.
  - [ ] Handle `#selector(NSResponder.insertTab(_:))` in `doCommandBy`,
        returning `false` whenever `IndentUnitRule.tabInsertion` says a tab so
        AppKit's own insertion keeps today's behavior exactly — including at
        every insertion point. When it says spaces, **keep multi-insertion-point
        parity**: native `insertTab` inserts at *all* of
        `textView.selectedRanges`, and the column-selection gesture makes
        several zero-width carets a first-class state, so a single
        `insertText(_:replacementRange: selectedRange())` would silently
        collapse the selection to one caret. Feed all of
        `textView.selectedRanges` through `IndentUnitRule.tabInsertionPlan`,
        then apply the replacements **back-to-front** inside one
        `shouldChangeText(inRanges:replacementStrings:)` /
        `textStorage.beginEditing()` … `endEditing()` / `didChangeText()`
        bracket (one undoable step), install the plan's carets with
        `setSelectedRanges`, and keep the existing `isApplyingProgrammaticEdit`
        guard around the whole thing. `insertBacktab` stays untouched.
  - [ ] Verify the parity claim by exercising it in a Core test rather than by
        eyeballing the view: the plan's edits applied to a sample text
        reproduce, for the single-range case, exactly what one replacement would
        have produced, and, for the multi-caret case, one insertion per caret
        with all carets preserved.
  - [ ] Run `swift test` — must pass before Task 7.

### Task 7: iOS wiring

**Files:**
  - Modify: `Sources/Pisaka/iOS/PisakaApp_iOS.swift`
  - Modify: `Sources/Pisaka/iOS/RootView_iOS.swift`
  - Modify: `Sources/Pisaka/iOS/CodeEditorView_iOS.swift`
  - Modify: `Sources/Pisaka/iOS/CodeEditorCoordinator_iOS.swift`
  - [ ] Build the `EditorConfigModel` over the existing
        `SecurityScopedFileService` in `PisakaApp_iOS`, hand it to
        `RootView_iOS`, and pass it into `CodeEditorView_iOS` (which also starts
        receiving `projectRoot`, as the macOS editor already does) and on to the
        coordinator.
  - [ ] Invalidate on the natural boundaries iOS already has, mirroring how the
        symbol index compensates for the missing watcher: the root switch in
        `.onChange(of: model.projectRoot)` beside
        `synchronizeSymbolIndex(forRoot:)`, and
        `notifyIndexOfProjectFileChanges()` for the in-process worktree
        rewrites. An out-of-band edit stays a stated limit.
  - [ ] Feed the coordinator's `insertIndentedNewline` the same rule-derived
        unit as macOS.
  - [ ] Handle a `"\t"` replacement in `shouldChangeTextIn`: apply the rule's
        spaces through the existing `applyEdit` and suppress the default when
        the rule says spaces; let it through unchanged when it says a tab.
        `UITextView` has a single `selectedRange`, so no fan-out is needed here
        — the one range still goes through `tabInsertionPlan` so both platforms
        share the rule.
  - [ ] Run `swift test` — must pass before Task 8.

### Task 8: Verify acceptance criteria

  - [ ] `swift test` — the whole suite green, with the pre-existing
        `IndentEngineTests` unmodified.
  - [ ] `swiftlint --strict` from the repository root — clean, with
        `.swiftlint.yml` unchanged.
  - [ ] `xcodegen generate` then `xcodebuild -project Pisaka.xcodeproj -scheme
        Pisaka -destination 'platform=macOS' build`.
  - [ ] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination
        'platform=iOS Simulator,name=iPhone 17 Pro' build`.
  - [ ] Confirm by test inventory that each acceptance case has a named test:
        the glob dialect construct by construct, hierarchy precedence with
        `root` and `unset`, parser edge cases (comments line-only, the size
        floors), a `indent_style = space` / `indent_size = 2` config beating a
        tab-indented file's own inference for both Enter and Tab (and the
        reverse for `indent_style = tab`), and the multi-caret Tab plan.

### Task 9: Update documentation

**Files:**
  - Create: `docs/architecture/core-editorconfig.md`
  - Modify: `CLAUDE.md`, `docs/architecture/core-editor.md`,
    `docs/architecture/app-editor.md`, `docs/architecture/app-shell.md`,
    `docs/architecture/app-ios.md`, `docs/FEATURES.md`, `README.md`
  - [ ] Write `core-editorconfig.md` with a full entry per new file, recording
        the decisions: the project-root stop as a deliberate spec deviation,
        uniform on both platforms, because iOS security-scoped access cannot
        read above the granted folder; why the dialect is separate from
        `GitignoreMatcher` (`**` is not component-bound, brace alternation and
        numeric ranges exist, `!` and trailing-slash semantics do not); the
        `?`-excludes-`/` choice; that comments are line-only and the 1024/4096
        acceptance floors are the cap; the hybrid unit rule and the different,
        stricter rule for Tab, plus why Tab fans out over every insertion point;
        wholesale cache invalidation and the never-serve-a-previous-project
        guarantee; and that the layer is a reader that rewrites nothing — no
        reformatting on open, on save or on config change.
  - [ ] Add one index line per new Core file to `CLAUDE.md` under a new
        `docs/architecture/core-editorconfig.md` heading, plus a short
        cross-cutting note that the indentation unit is EditorConfig-first and
        inference-second and that the layer takes no writer gate.
  - [ ] Update the changed files' existing entries: `IndentEngine` in
        `core-editor.md` (its `unit` parameter now comes from `IndentUnitRule`),
        `CodeEditorView` in `app-editor.md` (the new Tab handler, its
        multi-insertion-point fan-out, and the config lookup), `PisakaApp` in
        `app-shell.md` (ownership and the watcher-driven invalidation), and the
        iOS editor entries in `app-ios.md`.
  - [ ] Update `docs/FEATURES.md` (the auto-indent bullet around line 153 and
        the iOS section) and `README.md`'s one-line editor summary with
        EditorConfig support and its stated limits: which three properties are
        honored, that everything else is read but not acted on yet, the
        project-root stop, no reformatting of existing content, and no live
        pickup of edits on iOS.
  - [ ] `swift test` and `swiftlint --strict` once more, since
        `LintConfigurationTests`/`ReleaseMetadataTests`-style suites read
        repository files.

## Post-Completion (manual, outside the agent's checkboxes)

  - Run the macOS app, open a project, and confirm that editing a
    `.editorconfig` changes the unit for subsequently typed edits without
    reopening the project.
  - With `indent_style = space`, make a column selection with the middle-button
    drag and press Tab — confirm every caret gets its spaces and the multi-caret
    selection survives, matching what a literal tab does today.
  - Confirm on an iPad with a hardware keyboard that Tab inserts the configured
    spaces under `indent_style = space` and a literal tab without a config.
