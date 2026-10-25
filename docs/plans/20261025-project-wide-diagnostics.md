# Project-wide diagnostics: closed files in the Problems panel, severity marks in the project tree (macOS)

## Overview

Language servers already push diagnostics about files no tab holds. gopls and
rust-analyzer report on the whole workspace unasked, and pyright does too once it is
told to. Today the workspace throws these reports away, and closing a tab deletes
everything known about its file. This plan keeps those reports.

- **A second, positional lane.** A report for a document the workspace does not hold
  lands in the store as a positional entry: the server's own line and character
  positions, with no buffer offsets.
- **Closing keeps the set.** Closing the last tab drops only that buffer's bookkeeping;
  the file's diagnostics stay.
- **Editor surfaces see mapped entries only.** The squiggles, gutter, hover, edit shift
  and Next/Previous Problem never see a positional entry, and this is enforced by type.
- **The Problems panel becomes the project's list.** It lists closed files too, and
  activating a closed file's row opens the file and reveals the position mapped onto
  the buffer just opened.
- **pyright reports on the workspace.** It gains one setting.
- **The tree shows severity.** A pure Core lookup, published by the diagnostics model,
  gives each tree row the worst severity under it. The tree paints a 6 pt dot on the
  row's glyph in the chrome's one severity colour.
- **Two leftovers from the previous tree ticket.** The tree's Refresh button also
  refreshes git status, and a wrong comment is corrected.

## Context

- Files involved (Core):
  - `Sources/PisakaCore/Diagnostic.swift`
  - `Sources/PisakaCore/DiagnosticStore.swift`
  - `Sources/PisakaCore/DiagnosticsModel.swift`
  - `Sources/PisakaCore/LSPWorkspace.swift` (`route(_:from:)`, `LSPDiagnosticEvent`,
    `prepareForFolderChange(root:)`)
  - `Sources/PisakaCore/LSPProvisioningManifest.swift`
    (`LSPDownloadableServer.configuration`)
  - `Sources/PisakaCore/TreeGitStatus.swift` (the accessibility composition)
  - `Sources/PisakaCore/LocalChangesModel.swift` (comment only)
  - new `Sources/PisakaCore/TreeDiagnostics.swift`
  - `Sources/PisakaCore/LSPPositionMap.swift` and `Sources/PisakaCore/CanonicalPath.swift`
    (read only)
- Files involved (app, macOS):
  - `Sources/Pisaka/ProblemsPanelView.swift`
  - `Sources/Pisaka/ProblemCommands.swift`
  - `Sources/Pisaka/ProjectTreeView.swift`
  - `Sources/Pisaka/ContentView.swift`
  - `Sources/Pisaka/PisakaApp.swift`
  - `Sources/Pisaka/CodeEditorView.swift` (only if a call site needs the mapped accessor)
- Tests:
  - `Tests/PisakaCoreTests/DiagnosticStoreTests.swift`
  - `Tests/PisakaCoreTests/DiagnosticsModelTests.swift`
  - `Tests/PisakaCoreTests/LSPDiagnosticsRoutingTests.swift`
  - `Tests/PisakaCoreTests/TreeGitStatusTests.swift` (accessibility composition)
  - new `Tests/PisakaCoreTests/TreeDiagnosticsTests.swift`
  - `Tests/PisakaCoreTests/LSPProvisioningManifestTests.swift`
  - `Tests/PisakaCoreTests/LSPProvisioningModelTests.swift` (must stay green)
  - `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift` (rule fifteen's reader set)
  - new `Tests/PisakaAppTests/TreeDiagnosticMarkTests.swift`
  - `Tests/PisakaAppTests/TreeGitStatusColourTests.swift`, `TreeRowGlyphLayoutTests.swift`
    and `TreeIndentGuideLayoutTests.swift` (must stay green)
- Docs: `docs/architecture/core-lsp.md`, `docs/architecture/core-provisioning.md`,
  `docs/architecture/app-window.md`, `docs/architecture/core-theme.md`,
  `docs/architecture/core-git-models.md` (the `projectPrefix` wording),
  `docs/FEATURES.md`, `CLAUDE.md`
- Related patterns:
  - `TreeGitStatus`: root spellings resolved once at build, then a lexical key and one
    dictionary read per row, with a probe-count seam.
  - `PisakaApp.activateUsage(_:)`: open the file, read the opened buffer, ask Core for
    the range, reveal.
  - `ChromeColorRole.diagnosticRole(for:)`: the one severity-to-role answer.
  - `LSPDownloadableServer.yaml.configuration`: the precedent for server settings.
  - `HostedRender` with one render per state, as in `TreeGitStatusColourTests`.
  - `Gate` / `waitFor` for async staging.
- Dependencies: none new. No new required-reason API, palette value, role or gating rule.

## Decisions settled here (resolving the ticket's open edges)

- **The two kinds are a type, not a placeholder.** A store entry's payload is an enum:
  mapped `[Diagnostic]` or positional `[PositionalDiagnostic]`. `PositionalDiagnostic`
  is a new value in `Diagnostic.swift` carrying the server's `LSPRange`, severity,
  message, source and file URL. The entry exposes an optional `mapped` accessor, `nil`
  for a positional entry. Every editor-facing reader goes through it:
  - `diagnostics(in:)`, `diagnostics(at:in:)` and `worstSeverityPerLine`;
  - the model's `noteEdit` shift and `apply(shift:to:)`;
  - `ProblemCommands`' Next/Previous Problem.

  A positional entry is therefore unreachable from those readers by type. The panel
  rows, the counts and the tree lookup read severity and position, which both kinds
  carry.
- **One ordering key for both kinds.** `Diagnostic.OrderingKey` compares, in this
  order: file path, start line, start column, severity worst-first, end line, end
  column, message, source. This keeps today's shape, where severity outranks the span.
  - A positional diagnostic fills the position fields with the server's positions
    verbatim.
  - A mapped one fills them with (its `line`, start offset) as the start and (its
    `line`, end offset) as the end. Within one buffer, offsets order exactly as columns
    do, and keys are only ever compared within one file's entry, which is a single kind.

  Hover's order and the existing mapped panel order are unchanged by this. The same
  diagnostics in either kind produce the same row sequence.
- **Panel rows carry a reveal target.** `DiagnosticStore.Row` replaces `range` with a
  Hashable target: buffer offsets (mapped) or an `LSPRange` (positional). It keeps the
  zero-based `line`, which is the server's start line for a positional row. A pure Core
  helper on `Row` answers the range to reveal against a given buffer text:
  - a positional target goes through `LSPPositionMap.range(for:in:)`, with its
    clamping, so a position past the end lands at the end;
  - a mapped target is clamped into the text's length, so an in-range range is
    returned unchanged.

  The panel's activation callback becomes `(URL, Row)`. The app opens the file through
  `openFile(url:)`, reads the opened tab's text, asks the helper and reveals, mirroring
  `activateUsage`. It never beeps and never traps.
- **What the positional lane accepts.** The held-document lane in `route` is left
  exactly as it is. When the document lookup misses, the report is forwarded as
  `.positional` only when all of the following hold:
  - the URL is a `file:` URL;
  - the pushing key has a live session;
  - the key's root equals the current root's key;
  - the URL lies under the current root.

  The current root's canonical key and its two lexical spellings (standardized and
  canonical path components) are computed once in `prepareForFolderChange(root:)`. Each
  check above is then a dictionary read or a lexical component compare, with no
  file-system call per push. Only after the checks pass are the params decoded.

  The "under the root" condition is an addition to the ticket's list. It makes A4's
  "under the project root" true at the source, so the panel needs no new filter and
  never offers to open a dependency file through `openFile`. A report for a document
  that another server holds is still dropped, as today.
- **A wholesale buffer replacement drops only a mapped entry.**
  `noteBufferReplaced(url:)` keeps a positional entry. Opening a file is a content
  replacement, so this is what lets the panel and the tree keep showing a positional
  record until the first mapped report replaces it, as A2 requires.

  A **mapped** set kept from a closed tab is dropped on reopen exactly as today: its
  offsets describe a buffer that is being replaced. The file then shows nothing until
  the next push.

  `noteDocumentClosed(url:)` drops the sync record, the revision and any held push, and
  no longer touches the store.
- **The model owns the project root.** `prepareForFolderChange()` becomes
  `prepareForFolderChange(root:)`. The app already calls it on every folder switch,
  including the first open. It records the root and resolves the root's standardized
  and canonical spellings once, then clears synchronously as today. The tree lookup is
  built from the store plus those two cached spellings, with no file-system call per
  build. With no root, the lookup is empty.
- **Publishing without re-rendering the tree per keystroke.** `ContentView`
  deliberately does not observe `DiagnosticsModel`, because the store republishes on
  every keystroke's shift, and that must stay so.
  - The model owns a small `@MainActor` `ObservableObject` holder. It publishes the
    lookup and assigns a new value **only when it differs** from the current one.
  - The lookup is rebuilt on every store mutation, from the store's `didSet`.
  - The tree reads the holder's value through a thin observing wrapper placed in
    `ContentView.swift`. No new app file is added, so the gating suites' pinned file
    sets stay as they are.
  - `ProjectTreeView` takes the lookup as a value, `.empty` by default, beside
    `gitStatus`.
- **The mark reaches the role without a severity case label.** The lookup answers
  `TreeDiagnosticMark` (`error`, `warning`, `none`). It carries:
  - a `severity: DiagnosticSeverity?` accessor (`.error`, `.warning`, `nil`);
  - a `spokenName` ("has errors", "has warnings", `nil`).

  The tree calls `ChromeColorRole.diagnosticRole(for:)` with that severity and never
  switches over a severity itself, so rule fifteen's case-label clause holds. Only rule
  fifteen's reader set changes, to three files. The rule count stays fifty-one, so the
  number-to-word table, the header inventory count and `core-theme.md`'s count are
  unchanged; only rule fifteen's wording names the third reader.
- **Accessibility is composed in Core.** `TreeGitState.accessibilityValue` gains a
  non-defaulted diagnostic-mark parameter. Its output:
  - a file row: the git word and the diagnostics word, joined by ", ", or `""` when
    neither exists;
  - a folder row: the expansion word, then each word that exists.

  The parameter is non-defaulted from Task 5 on, so Task 5 also updates
  `ProjectTreeView`'s two call sites to pass `.none`, keeping the app target compiling;
  Task 8 replaces those `.none` arguments with each row's real mark. Headless SwiftUI
  builds no accessibility nodes (as `LocalChangesLayoutTests` documents), so the
  ticket's app-bundle accessibility criterion is met by the Core composition tests. The
  bitmap test covers the drawing.
- **pyright's setting, as the pinned bundle actually reads it.** These facts were read
  from the published pyright 1.1.411 bundle:
  - Pisaka advertises `workspace.configuration: false`, so pyright never pulls.
  - It stores the `workspace/didChangeConfiguration` payload and reads
    `python.analysis` out of it by dotted path, i.e. as nested objects.
  - When an analysis section is present at all, pyright sets `autoSearchPaths` to the
    section's value, which is false when the key is absent. Without the section it
    defaults to true.

  The value is therefore
  `{"python": {"analysis": {"diagnosticMode": "workspace", "autoSearchPaths": true}}}`.
  The second key keeps pyright's import resolution exactly as it is today. Every other
  key pyright reads from that section falls back to the same value either way. That is
  the only addition to the ticket's "exactly one setting", and it exists so the
  handshake changes nothing else. The per-section pull answer is built from the same
  object (section `python`), as the session already does.
- **The pyright documented limit, corrected.** Pyright's built-in excludes **do** cover
  virtual environments. When the project's own configuration names no `exclude`,
  pyright auto-excludes `**/node_modules`, `**/__pycache__` and `**/.*`, plus any
  directory holding `bin/activate`, `Scripts/activate`, `pyvenv.cfg` or `conda-meta`.
  The accurate limit is this: a project whose own pyright configuration lists its own
  `exclude` loses those defaults, so an unlisted environment directory is analysed and
  reported too. The docs state that version.
- **Refresh.** `ProjectTreeView` gains an `onRefreshGitStatus` callback, a no-op by
  default. The header button calls it right after `model.bumpTreeRevision()`.
  `ContentView` threads it through, and `PisakaApp` wires it to
  `refreshLocalChanges()`, which pins the request generation synchronously.

## Development Approach

- **Testing approach**: TDD for the Core pieces (store kinds, ordering, model lanes,
  routing, lookup, pyright setting). Regular for the app wiring, with the app tests in
  the same task.
- Complete each task fully before moving to the next. The app target must compile at
  the end of every task that changes a Core API it uses.
- No brand names and no references to other editors anywhere: code, comments, docs,
  commits.
- Paths are stored as spelled and matched canonically, with no new canonicalisation
  spelling. The lookup and the positional lane match lexically against root spellings
  resolved once.
- Generation discipline: the folder-change clear and the lookup reset happen
  synchronously in the same main-actor turn. Nothing is published from a superseded
  refresh.
- Readers only: neither the panel, the tree, the lookup nor the model raises or
  consults the writer gate.
- App-layer tests render a handful of times, one render per state and never per sample.
- Every `xcodebuild` uses
  `-derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-build` and
  `DEVELOPER_DIR=/Applications/Xcode_26.3.app/Contents/Developer`. If the pinned Xcode
  is absent, the installed one is used and that is recorded. Run `xcodegen generate`
  after adding any file.
- **CRITICAL: every task MUST include new/updated tests**
- **CRITICAL: all tests must pass before starting next task**

## Implementation Steps

### Task 1: The store's two kinds; editor queries read mapped entries only

**Files:**
- Modify: `Sources/PisakaCore/Diagnostic.swift`
- Modify: `Sources/PisakaCore/DiagnosticStore.swift`
- Modify: `Sources/PisakaCore/DiagnosticsModel.swift` (the read-only queries and
  `noteEdit`'s guard only)
- Modify: `Sources/Pisaka/ProblemCommands.swift`
- Modify: `Tests/PisakaCoreTests/DiagnosticStoreTests.swift`,
  `Tests/PisakaCoreTests/DiagnosticsModelTests.swift`,
  `Tests/PisakaCoreTests/LSPDiagnosticsRoutingTests.swift` (mechanical accessor updates)

- [x] Add `PositionalDiagnostic` (Equatable, Hashable, Sendable): the server's
  `LSPRange`, severity, message, source and file URL. Add a factory from an
  `LSPDiagnostic`, using the same `DiagnosticSeverity(lspValue:)` conversion as the
  mapped factory.
- [x] Make the entry payload an enum (mapped / positional), keeping `serverKey`
  provenance on every entry:
  - add the optional `mapped` accessor;
  - add a positional `replace` beside the existing mapped one;
  - `apply(shift:to:)` installs only onto a mapped entry;
  - replace `clear(url:)` with a mapped-only clear, which removes the entry only when
    it is mapped;
  - `clear(serverKey:)` and `clearAll()` remove both kinds;
  - `counts` spans both kinds.
- [x] `diagnostics(at:in:)`, `worstSeverityPerLine`, the model's `diagnostics(in:)` and
  `noteEdit`'s early-return guard read `mapped` only. `ProblemCommands` reads
  `store.entry(for:)?.mapped`.
- [x] Tests:
  - a positional entry installs, and an empty positional report installs an empty
    entry;
  - for a positional entry, `diagnostics(in:)` and `diagnostics(at:in:)` return
    nothing, and the per-line worst severity is all `nil`;
  - a shift does not touch a positional entry;
  - the mapped-only clear leaves a positional entry and removes a mapped one;
  - server clear and `clearAll` remove positional entries;
  - counts include positional errors and warnings and exclude information and hints.
- [x] Run `swift test` and build the macOS app target. Both must pass before Task 2. (Xcode_26.3 absent locally; built with the installed Xcode 27.1.)

### Task 2: One ordering for both kinds; panel rows carry a reveal target; closed-row activation

**Files:**
- Modify: `Sources/PisakaCore/Diagnostic.swift` (`OrderingKey`)
- Modify: `Sources/PisakaCore/DiagnosticStore.swift` (`Row`, `rows(relativeTo:)`)
- Modify: `Sources/Pisaka/ProblemsPanelView.swift`
- Modify: `Sources/Pisaka/ContentView.swift`
- Modify: `Sources/Pisaka/PisakaApp.swift`
- Modify: `Tests/PisakaCoreTests/DiagnosticStoreTests.swift`

- [x] Rework `OrderingKey` as in Decisions: path, then start line, start column,
  severity worst-first, end line, end column, message, source. Positional diagnostics
  use the server's positions; mapped ones use (line, start offset) and (line, end
  offset). Rewrite its doc comment to state the single total order.
- [x] `Row` keeps `severity`, `message` and the zero-based `line`, and replaces `range`
  with a Hashable reveal target (offsets / `LSPRange`). Add an initializer for each
  kind.
  - `rows(relativeTo:)` sorts positional entries with the same key and collapses
    identical rows exactly as today.
  - Add the pure reveal-range helper: positional goes through
    `LSPPositionMap.range(for:in:)`; mapped is clamped to the text length.
- [x] `ProblemsPanelView`'s callback becomes `(URL, DiagnosticStore.Row)`, with the doc
  comment updated. `ContentView.onActivateProblem` changes type to match.
- [x] `PisakaApp` gets an `activateProblem(url:row:)` shaped like `activateUsage`:
  `openFile(url:)`, then the tab's id and text, then the helper, then
  `reveal.reveal(fileID:range:)`. A missing tab returns silently.
- [x] Tests:
  - a closed file's rows carry the server's line;
  - a positional entry and a mapped entry describing the same diagnostics yield the
    same row order, including same-line ties broken by column, then severity, then
    span;
  - mapped panel order and hover order are unchanged; existing tests stay green;
  - the reveal helper maps a positional row onto a buffer, clamps a line past the end
    to the end and a character past its line to the line's end, and returns an
    in-range mapped range unchanged;
  - header counts span closed files.
- [x] Run `swift test` and build the macOS app target. Both must pass before Task 3. (Xcode_26.3 absent locally; built with the installed Xcode. PisakaApp grew four lines net, so the file_length / type_body_length ceilings moved to the measured 1975 / 1968, recorded in .swiftlint.yml, LintConfigurationTests and style-lint.md.)

### Task 3: The model's positional lane and the close-keeps-the-set lifecycle

**Files:**
- Modify: `Sources/PisakaCore/LSPWorkspace.swift` (the `LSPDiagnosticEvent` enum only)
- Modify: `Sources/PisakaCore/DiagnosticsModel.swift`
- Modify: `Tests/PisakaCoreTests/DiagnosticsModelTests.swift`

- [x] Add `case positional(url:serverID:root:diagnostics: [PositionalDiagnostic])` to
  `LSPDiagnosticEvent`, with a doc comment naming the second lane.
- [x] `receive(.positional)`:
  - dropped when a sync record exists for the document;
  - otherwise replaces the entry wholesale, with no gate and no hold, under the same
    `ServerKey` provenance;
  - existing holds are untouched.
- [x] `noteDocumentClosed(url:)` drops the sync record, revision and hold, and keeps the
  store entry. `noteBufferReplaced(url:)` drops only a mapped entry.
  `.cleared(.server)` and `prepareForFolderChange` clear both kinds.
- [x] Rewrite the type's doc comment where it says the maps and the store are bounded
  by the open tabs. The bookkeeping still is; the store is bounded by what the servers
  report about the current folder.
- [x] Tests:
  - a positional report is accepted with no sync record and replaces the entry;
  - a positional report is dropped when a sync record exists;
  - an empty positional report installs an empty entry;
  - a later mapped report, synced and accepted, replaces a positional entry;
  - `noteBufferReplaced` keeps a positional entry, and keeps dropping a mapped one;
  - closing the last tab keeps the set and drops the sync record and the revision: a
    following mapped report for that URL is held as a first report, and
    `currentRevision` is zero;
  - server clear and folder change remove positional entries.
- [x] Run `swift test`. It must pass before Task 4. (Task 2's `Row.revealRange(in:)` tripped `FoldingSourceGatingTests`' reveal-funnel regex from `PisakaApp`; renamed to `Row.rangeToReveal(in:)`, a different name rather than a new exclusion. macOS app target also built with the installed Xcode, Xcode_26.3 being absent.)

### Task 4: The workspace forwards reports for unheld documents

**Files:**
- Modify: `Sources/PisakaCore/LSPWorkspace.swift`
- Modify: `Tests/PisakaCoreTests/LSPDiagnosticsRoutingTests.swift`

- [x] In `prepareForFolderChange(root:)`, cache the current root's canonical key and
  its two lexical spellings.
- [x] In `route`, when the document lookup misses, apply the positional checks from
  Decisions in this order:
  1. a file URL;
  2. a live session for the key;
  3. the cached root key matches;
  4. the URL lies under one of the cached spellings, compared lexically;
  5. decode the params.

  Then emit `.positional` with the server's positions verbatim. The held-document
  branch and its order are untouched. Update the type's and `route`'s doc comments: D31
  gains the positional case, and the new lane is cited as D46.
- [x] Tests:
  - rewrite `testAPushForAnUnopenedURIIsDropped` so that a URI under the current root
    that no server holds arrives as one `.positional` event with the server's
    positions;
  - a URI outside the root is dropped;
  - an unheld URI pushed after a folder change (the straggler shape) is dropped;
  - a held document still arrives `.published` with buffer offsets;
  - a document held by another server is still dropped;
  - an empty report for an unheld URI arrives as an empty positional event;
  - a full-composition test, workspace to model: an unheld push lands in the store as
    positional, then `shutdownAll()` clears it.
- [x] Run `swift test`. It must pass before Task 5.

### Task 5: The tree lookup (Core, pure)

**Files:**
- Create: `Sources/PisakaCore/TreeDiagnostics.swift`
- Modify: `Sources/PisakaCore/TreeGitStatus.swift` (accessibility composition)
- Modify: `Sources/Pisaka/ProjectTreeView.swift` (the two `accessibilityValue` call
  sites only, passing `.none`)
- Create: `Tests/PisakaCoreTests/TreeDiagnosticsTests.swift`
- Modify: `Tests/PisakaCoreTests/TreeGitStatusTests.swift`

- [x] Add `TreeDiagnosticMark` (`error`, `warning`, `none`; Comparable so that error
  outranks warning, which outranks none), with its `severity` and `spokenName`
  accessors.
- [x] Add `TreeDiagnostics` (Equatable, Sendable, with an `.empty` value):
  - it is built from the store and the root's two spellings;
  - for each entry of either kind, it takes the worst severity: error → `error`,
    warning → `warning`, information or hint only → nothing recorded;
  - the entry's standardized path is made relative to the first matching spelling,
    lexically; an entry under no spelling is skipped;
  - the relative key and every ancestor, up to and including the root's empty key, keep
    the strongest mark;
  - equality is synthesized over the spellings and that table, which is a pure function
    of the per-file worst severities;
  - the per-row query is a lexical key plus one dictionary read; an internal
    `resolve(_:)` returns the mark with a probe count.
- [x] `TreeGitState.accessibilityValue` takes the mark as a non-defaulted parameter and
  composes as described in Decisions.
- [x] Update `ProjectTreeView`'s two `accessibilityValue` call sites (the folder row and
  the file row) to pass `.none`, so the app target keeps compiling with no behaviour
  change. Task 8 replaces these arguments with each row's real mark.
- [x] Tests, one per rule:
  - a file takes the worst of its own diagnostics, either kind;
  - a folder takes the worst of all its descendants, transitively, several levels deep;
  - error outranks warning;
  - information and hints give `none`;
  - a diagnosed file outside the root contributes nothing;
  - a project opened through a symlink marks its rows through the canonical spelling;
  - an equal lookup results from a `DiagnosticShift` that moves offsets inside a
    flagged file without changing its worst severity, staged as a real shift and then
    compared;
  - an empty store or `.empty` answers `none` everywhere;
  - the probe count is at most one, whether the store holds 10 diagnosed files or
    10,000;
  - the accessibility composition covers both row kinds and every combination of git
    word, diagnostics word and none.
- [x] Run `xcodegen generate`, `swift test` and build the macOS app target. Both must
  pass before Task 6. (The pinned Xcode 26.3 is absent here; the macOS build ran with the installed Xcode and succeeded.)

### Task 6: The model publishes the lookup

**Files:**
- Modify: `Sources/PisakaCore/DiagnosticsModel.swift`
- Modify: `Sources/Pisaka/PisakaApp.swift` (the `prepareForFolderChange(root:)` call)
- Modify: `Tests/PisakaCoreTests/DiagnosticsModelTests.swift` and the other callers of
  `prepareForFolderChange()`

- [x] `prepareForFolderChange(root:)` records the root and resolves its two spellings
  once, then clears synchronously as today.
- [x] Add the main-actor holder object, owned by the model, that publishes the lookup
  and assigns only on inequality. The store's `didSet` rebuilds the lookup and hands it
  to the holder. With no root, the lookup is `.empty`.
- [x] `PisakaApp` passes the new root at the existing call site, which only runs on a
  switch.
- [x] Tests:
  - an accepted mapped push and a positional report each publish a lookup marking the
    file and its folders;
  - a keystroke shift that keeps the worst severity does not change the holder's value;
    count the holder's `objectWillChange` emissions, which stay zero across the shift;
  - a folder change resets the lookup to empty synchronously, before any hop;
  - a server clear removes its marks;
  - with no root, the lookup is empty.
- [x] Run `swift test` and build the macOS app target. Both must pass before Task 7. (The pinned Xcode 26.3 is absent here; the macOS build ran with the installed Xcode and succeeded.)

### Task 7: pyright reports on the workspace

**Files:**
- Modify: `Sources/PisakaCore/LSPProvisioningManifest.swift`
- Modify: `Tests/PisakaCoreTests/LSPProvisioningManifestTests.swift`

- [ ] `.python`'s configuration becomes
  `{"python": {"analysis": {"diagnosticMode": "workspace", "autoSearchPaths": true}}}`.
  The doc comment records the bundle facts from Decisions: no pull because the
  capability is advertised false, the nested read of the pushed payload, and why
  `autoSearchPaths` is stated. TypeScript stays `nil`, and the YAML value is unchanged.
- [ ] Rename and rewrite the pyright description test so it pins that exact value:
  - TypeScript's configuration is still `nil`; YAML's tests are unchanged;
  - the sourcekit-lsp, gopls and rust-analyzer descriptions still carry no
    configuration (add an assertion if none exists);
  - `LSPProvisioningModelTests` stays green.
- [ ] Run `swift test`. It must pass before Task 8.

### Task 8: Painting the dot in the tree; Refresh; the comment fix

**Files:**
- Modify: `Sources/Pisaka/ProjectTreeView.swift`
- Modify: `Sources/Pisaka/ContentView.swift`
- Modify: `Sources/Pisaka/PisakaApp.swift`
- Modify: `Sources/PisakaCore/LocalChangesModel.swift` (comment only)
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`
- Create: `Tests/PisakaAppTests/TreeDiagnosticMarkTests.swift`

- [ ] Add `diagnosticDotSize: Double = 6` to `TreeRowLayout`. `ProjectTreeView` takes
  `diagnostics: TreeDiagnostics = .empty` and passes it down the recursion beside
  `gitStatus`.
- [ ] Each folder and file row asks for its mark once. When the mark's `severity` is
  non-nil, the row's glyph gets a bottom-trailing overlay: a circle
  `metrics.scaled(TreeRowLayout.diagnosticDotSize)` across, filled with
  `theme.color(ChromeColorRole.diagnosticRole(for: severity))`, hidden from
  accessibility.
  - The draft-hosting row keeps its glyph, and therefore its dot.
  - The name colour, background, indent guide and glyph tone are untouched.
  - No arithmetic on a token, no opacity, and no severity case label.
- [ ] Replace the `.none` arguments Task 5 put at the two `accessibilityValue` call
  sites with each row's real mark.
- [ ] `ContentView` feeds the lookup through the thin observing wrapper, kept in
  `ContentView.swift`, and still does not observe `DiagnosticsModel`.
- [ ] Refresh: add `onRefreshGitStatus`, called after `bumpTreeRevision()`; thread it
  through `ContentView`; wire it in `PisakaApp` to `refreshLocalChanges()`.
- [ ] Fix the `projectPrefix` comment: the lookup builds its keys on the main actor,
  inside the model's refresh, and the function is `nonisolated` only because the
  lookup's initialiser is non-isolated code.
- [ ] Rule fifteen: the reader set becomes `LineNumberRulerView.swift`,
  `ProblemsPanelView.swift` and `ProjectTreeView.swift`. Update the assertion message
  and the doc comment to name the tree as the third reader. The rule count and the
  gated-file set are unchanged.
- [ ] App test, with one window per scale and four renders in total. Build a project
  whose root holds:
  - an error file;
  - a warning file;
  - a clean file;
  - a collapsed folder holding a warning file;
  - a collapsed clean folder.

  Render at scale 1 and 1.8, with and without the lookup. Assert:
  - `statusRed` appears in the bottom-trailing quarter of the error file's glyph slot
    and of the root folder's;
  - `statusYellow` appears for the warning file and the warning folder;
  - the clean rows' glyph slots are identical to the render without the lookup;
  - the dot's extent grows with the scale.
- [ ] Keep `TreeGitStatusColourTests`, `TreeRowGlyphLayoutTests`,
  `TreeIndentGuideLayoutTests`, `ChromeThemeSourceGatingTests` and
  `ZoomSourceGatingTests` green. If an existing glyph-identity sample now overlaps a
  dot, give that fixture no diagnostics; do not move the dot.
- [ ] Run `xcodegen generate`, `swift test` and the app-layer bundle. Both must pass
  before Task 9.

### Task 9: Verify acceptance criteria

- [ ] Run `swift test`.
- [ ] Run `DEVELOPER_DIR=/Applications/Xcode_26.3.app/Contents/Developer xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-build test`.
- [ ] Run the iOS build: the same command with `-destination 'generic/platform=iOS'`
  and `build`.
- [ ] Run `swiftlint --strict` from the repository root.
- [ ] Walk the ticket's Core and app acceptance lists against the tests, and record
  which test covers each item.

### Task 10: Update documentation

- [ ] `core-lsp.md`:
  - amend D31 with the positional case;
  - add **D46**, covering the second lane and its conditions, close-keeps-the-set, a
    replacement drops only a mapped entry, editor surfaces see mapped only, the
    per-server expectation table, and the stale-after-outside-edit limit;
  - update the Diagnostics heading's decision range;
  - update the `Diagnostic`, `DiagnosticStore`, `DiagnosticsModel` and `LSPWorkspace`
    entries;
  - add a full `TreeDiagnostics.swift` entry: the marks, aggregation, spellings,
    equality, cost bound and the holder.

  The per-server expectation table:

  | server | closed files |
  |---|---|
  | gopls | whole workspace (compiler diagnostics for every loaded package; analysis may be limited to packages with open files) |
  | rust-analyzer | whole workspace from `cargo check` on save; its own native diagnostics are open-files-only |
  | pyright | whole workspace, through the setting |
  | typescript-language-server | open files only |
  | sourcekit-lsp | open files only |
  | yaml-language-server | open files only |

- [ ] `core-provisioning.md`: the pyright setting beside the YAML precedent, with the
  bundle facts and the corrected exclude limit.
- [ ] `app-window.md`: the tree's dot, the accessibility words, the Refresh button's
  second call, and the reader posture. The Problems panel's closed-file rows and their
  activation go where the panel is documented.
- [ ] `core-theme.md`: rule fifteen's canonical-list item and the severity role's
  readers name the tree.
- [ ] `core-git-models.md`: the `projectPrefix` wording, if restated there.
- [ ] `CLAUDE.md`:
  - add `TreeDiagnostics.swift` to the `core-lsp.md` index line;
  - change "D1–D10 + D17–D45" to "D1–D10 + D17–D46" in both places;
  - correct the language-servers invariant with one clause: reports about files no tab
    holds land positionally (D46) and are shown by the panel and the tree, never by the
    editor surfaces;
  - name the tree's diagnostics lookup beside its git lookup in the readers invariant;
  - stay under 60,000 characters (now about 56,300).
- [ ] `docs/FEATURES.md`'s Diagnostics paragraph:
  - drop "every open file's findings";
  - describe closed-file rows and their activation, and the tree dots on files and
    folders;
  - state the per-server expectation and the two limits: a stale mark after an outside
    edit, and a project-level pyright `exclude` dropping the environment defaults.

  Also update the tree's Refresh sentence.
- [ ] Run `swift test` again, because the doc-reading suites (`LintConfigurationTests`,
  the gating suites) must stay green.

## Post-Completion

Manual checks at acceptance (observations to record, not gates):

- A Go or Rust project shows marks on closed files after the first save.
- A Python project shows workspace-wide marks.
- A TypeScript project marks only files that have been open.
- A closed file's panel row opens the file at the right line.
- The tree does not visibly repaint while typing in a file with errors.
- After a `git commit` in the terminal, pressing Refresh updates the name colours.
