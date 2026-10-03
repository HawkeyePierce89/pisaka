# Follow-ups from the design pass: five defects and the tail of small ones

## Overview

Close the five defects the design pass's acceptance review left open, plus the tail of minor items, in one branch. The five defects are:

- the title is not centred in the title bar;
- the Local Changes inline diff runs on the main actor and is rebuilt on every refresh;
- binary and oversized files are diffed inline as text;
- the caret column is recounted from the start of the line on every caret move;
- the commit dialog's memo tests exercise the uncached function.

Nothing the design pass drew changes, except where the window title sits.

Facts established while planning, which the tasks rely on:

- **The title.** This machine runs macOS 27.0.1 (build 26A434). On it, a titled window always draws its title at the leading edge: x = 82 in a 900-point window, midX 134.5. That holds for:
  - a bare titled `NSWindow`;
  - the same window with `.fullSizeContentView`, and with a transparent title bar;
  - every `toolbarStyle`;
  - an empty toolbar.

  A plain SwiftUI `WindowGroup` with no toolbar does the same. AppKit has no public property for the title's alignment. The doc comment's claim, "no toolbar ⇒ the framework centres it", is therefore false. Toolbars are not the cause. A label the app adds itself to the title bar view, constrained to its centre, measures midX 450.5 in a 900-point window and 600.5 after a resize to 1200. It survives a full-screen toggle.
- **The inline diff today.** `LocalChangesModel.loadSelectionDiff(token:)` runs `LineDiff.rows` and the working-copy read (`FileServicing.read`) on the main actor. It reads the HEAD side through the lossy `headContents`, so it has no binary check and no cap. No test today asserts that "an edit to the selected file refreshes its diff". This plan adds that test.
- **The HEAD blob identity.** Porcelain v2 status already carries `hH`, the object name of the file in HEAD. It is the only cheap signal that the HEAD side changed while status, path and working copy did not, for example after a partial commit of the selected file.
- **The caret column.** A boundary between two printable ASCII UTF-16 units (0x20–0x7E) is an extended-grapheme boundary in every context. An incremental count anchored at such a boundary was checked against the full `substring(lineStart, caret).count` over every (old, new) offset pair of strings containing:
  - combining marks;
  - surrogate pairs;
  - flag runs;
  - ZWJ emoji;
  - Hangul jamo;
  - Indic conjuncts;
  - a prepend character.

  It matched in all 1,593 incremental cases. Anchoring at `NSString.rangeOfComposedCharacterSequence` instead gave wrong counts for the prepend character U+0600, so that anchor is not used.
- **Glyph rule forty-six.** It already reads with the literal-keeping scanner. It already refuses the token `assetName` and glyph-name literals inside `Image(` and `NSImage(named:` arguments. Three things get past it:
  - the `rawValue` spelling;
  - the `.init(` spellings (`Image.init(`, `NSImage.init(named:`);
  - the image-resource loaders (`ImageResource(`, `NSImage(resource:`, `image(forResource:`).
- **Literal-keeping rules in the theme suite.** Its header still says "three" literal-keeping rules in two places, while the code has four.

## Context

- Files involved:
  - Window chrome: `Sources/Pisaka/MainWindowChrome.swift`, `Tests/PisakaAppTests/MainWindowChromeTests.swift`, `docs/architecture/app-shell.md`.
  - Local Changes: `Sources/PisakaCore/LocalChangesModel.swift`, `ChangedFile.swift`, `GitStatusParser.swift`, `ChangedFileGroups.swift`, new `Sources/PisakaCore/LocalChangesInlineDiff.swift`, `Sources/Pisaka/LocalChangesView.swift`, `Tests/PisakaCoreTests/LocalChangesModelTests.swift`, `GitStatusParserTests.swift`, `ChangedFileGroupsTests.swift`, new `LocalChangesInlineDiffTests.swift`, `Tests/PisakaAppTests/LocalChangesLayoutTests.swift`.
  - Caret: `Sources/PisakaCore/CaretReadout.swift`, `Sources/Pisaka/CodeEditorView.swift`, `Tests/PisakaCoreTests/CaretReadoutTests.swift`.
  - Commit dialog: `Sources/PisakaCore/CommitDialogModel.swift`, `PushPlan.swift`, `Sources/Pisaka/CommitDialogView.swift`, `CommitUnifiedDiffView.swift`, `Tests/PisakaCoreTests/CommitDialogModelTests.swift`, `Tests/PisakaAppTests/CommitDialogLayoutTests.swift`.
  - Bottom bar: `Sources/Pisaka/ContentView.swift` (BottomBar, BarToolTip, width probe), `ProjectSwitcherView.swift`, `BranchSwitcherView.swift`, `PullRequestIndicatorView.swift`, `TabListView.swift`, `Tests/PisakaAppTests/BottomBarToolTipTests.swift`, `TabColumnLayoutTests.swift`.
  - Gating: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`, `docs/architecture/core-theme.md`.
  - Log filter bar: `Sources/Pisaka/CommitLogView.swift`, `LogFilterBar.swift`, new `Tests/PisakaAppTests/LogRefreshControlsLayoutTests.swift`.
  - Find in Files: `Sources/PisakaCore/SearchScopeLine.swift`, `ProjectSearchModel.swift`, `Tests/PisakaCoreTests/SearchScopeLineTests.swift`.
  - Current line and diff wash: `Tests/PisakaAppTests/CurrentLineHighlightTests.swift`, `CommitUnifiedDiffWashTests.swift`, `HostedRender.swift`, `HostedRenderTests.swift`.
  - Docs: `docs/architecture/app-shell.md`, `app-window.md`, `app-git-views.md`, `app-editor.md`, `core-git-models.md`, `core-git.md`, `core-commit.md`, `core-editor.md`, `core-search.md`, `core-theme.md`, `CLAUDE.md` (index line only).
- Related patterns:
  - Off-main work follows `ProjectSearchModel` and `SymbolIndexModel`: a private serial queue, an `offMain { }` continuation helper, and `nonisolated static` pure helpers.
  - The generation token is captured synchronously before the hop and re-checked before publish.
  - "Unknown means re-read": a `nil` `FileStamp` forces the work (the `FileServicing.fileStamp` convention).
  - The commit dialog's blob classification is `GitBlobText.classify`, applied through `headBlob(of:root:)` and `readTextIfNotBinary(url:maxBytes:)`.
  - Charged work bounds follow `EditorConfigGlob`'s internal work counter seam. A step count read off an internal seam, never a clock.
  - Headless renders go through `HostedRender`: one render per state, cached swatches, no window or bitmap per call.
  - Gating suites match against comment-stripped text. The literal-keeping reading is `GitHubSourceGatingTests.strippingComments`, recorded in the suite header's "stated exceptions" paragraph.
- Dependencies: none new.

## Development Approach

- **Testing approach**: Regular (code first, then tests in the same task).
- Complete each task fully before moving to the next.
- Read each touched file's entry in `docs/architecture/` before changing it, and update it in the same task.
- Domain decisions live in `PisakaCore` with their own tests. The app layer only wires them. A layout that is a contract is measured through `HostedRender`.
- No product or brand names in code, comments, docs, tests or commit messages.
- Test helpers stay cheap per call:
  - no `NSWindow(`, `NSHostingView(` or bitmap capture inside a per-call, per-row or per-pixel path;
  - no test runs longer than a few seconds;
  - async tests use `Gate`/`waitFor` rendezvous, never sleeps.
- Build the app with the default DerivedData location (outside the repository), never `-derivedDataPath` inside it.
- Gates after every task:
  - `swift test`;
  - `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' test`;
  - `swiftlint --strict` from the repository root;
  - in tasks that touch Core, also `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'generic/platform=iOS' build`.
- **CRITICAL: every task MUST include new/updated tests**
- **CRITICAL: all tests must pass before starting next task**

## Implementation Steps

### Task 1: Centre the window title

**Files:**
- Modify: `Sources/Pisaka/MainWindowChrome.swift`
- Modify: `Tests/PisakaAppTests/MainWindowChromeTests.swift`
- Modify: `docs/architecture/app-shell.md`

- [x] In `MainWindowChrome.apply(to:title:)`:
  - Set `window.titleVisibility = .hidden` and keep setting `window.title`. The window menu, window switching and accessibility keep reading the title from there.
  - Install exactly one centred title label in the title bar view, which is the superview of `window.standardWindowButton(.closeButton)`.
  - The label is an `NSTextField(labelWithString:)`. It is found again by a fixed `NSUserInterfaceItemIdentifier`, so repeated `apply` calls update its `stringValue` and never add a second label.
  - Font: `NSFont.titleBarFont(ofSize: 0)`, the system title font at its system size, unscaled like the title it replaces.
  - Colour: `ChromePalette.nsColor(.textPrimary)`, a dynamic colour, so Theme changes repaint it without an observer.
  - Truncation: `.byTruncatingMiddle`. The label is not an accessibility element, because the window title already speaks.
  - Constraints: `centerX` and `centerY` equal to the title bar view's. Width at most the title bar's width minus twice the window buttons' trailing edge plus 8 points. A long title therefore truncates and stays centred, never under the window buttons.
  - If the close button or its superview is absent, `apply` does nothing more for the label. That covers windows without a title bar.
  - `titlebarAppearsTransparent` stays set only here, so rule nine stays green.
- [x] Rewrite the window-chrome file header's title paragraph with what was measured, and claim nothing beyond it:
  - Measured on macOS 27.0.1: the framework draws a title-bar title leading-aligned for every toolbar state — a bare titled window, every toolbar style, with and without a toolbar. The title starts at x = 82 in a 900-point window, and no public property moves it.
  - So the app hides the framework's title and draws its own label centred in the title bar view, on every supported release. The placement no longer depends on what the framework does. The `titleVisibility` line now says `.hidden` on purpose.
  - Name no other release and no release boundary.
  - Update `app-shell.md`'s `MainWindowChrome.swift` entry the same way, with the same measured claim and nothing more: the four properties it sets plus the label, and what the test now measures.
- [x] `MainWindowChromeTests`:
  - Replace the "visible with no toolbar" assertion with: system title hidden, `window.title` applied.
  - Add a placement test on **one window created once for the suite**, in `override class func setUp()` and closed in `override class func tearDown()`. Its style mask matches the app window's: titled, closable, miniaturizable, resizable, `.fullSizeContentView`.
  - Apply the chrome, lay out, find the label by its identifier, and convert its frame to window coordinates. Assert:
    - `|label.midX − window.width / 2| ≤ 1`;
    - the label lies vertically inside the title bar band;
    - its string is the applied title.
  - Resize the same window to a second width and assert the centre follows.
  - Assert that a second `apply` leaves exactly one label.
  - Keep the existing hosted-workspace title test, and make it read the label's string as well as `window.title`.
- [x] Run the gates. They must pass before Task 2.

### Task 2: Local Changes inline diff off the main actor, rebuilt only when the selected file changed

**Files:**
- Create: `Sources/PisakaCore/LocalChangesInlineDiff.swift`, `Tests/PisakaCoreTests/LocalChangesInlineDiffTests.swift`
- Modify: `Sources/PisakaCore/ChangedFile.swift`, `Sources/PisakaCore/GitStatusParser.swift`, `Sources/PisakaCore/LocalChangesModel.swift`, `Sources/Pisaka/LocalChangesView.swift`
- Modify: `Tests/PisakaCoreTests/GitStatusParserTests.swift`, `Tests/PisakaCoreTests/LocalChangesModelTests.swift`
- Modify: `docs/architecture/core-git.md`, `docs/architecture/core-git-models.md`, `docs/architecture/app-git-views.md`, `CLAUDE.md` (index name only)

- [x] `ChangedFile` gains `public let headObject: String?`, defaulted to `nil` in `init` so every existing construction compiles unchanged, iOS included.
  - `GitStatusParser` fills it from the `hH` field of ordinary (`1`) and rename (`2`) records. Untracked (`?`) and unmerged (`u`) records leave it `nil`.
  - Add parser tests for both record kinds and both `nil` kinds. Document the field in `core-git.md`.
- [x] New `LocalChangesInlineDiff` (Core, pure) holds `Fingerprint: Equatable`, built from the file's status, path, old path and head object, plus the working copy's `FileStamp?`.
  - `static func needsRebuild(published: Fingerprint?, current: Fingerprint) -> Bool` answers `true` in any of these cases:
    - nothing is published;
    - the fingerprints differ;
    - the current working-copy stamp is `nil` for a file that has a working side;
    - the head object is `nil` for a file that has a HEAD side.
  - A `nil` means unknown, and unknown means re-read.
  - It answers `false` only for an equal fingerprint whose stamps are known.
  - Tests cover each branch, including added, untracked and deleted files, which have one side only.
- [x] `LocalChangesModel.loadSelectionDiff(token:)`:
  1. Keeps the existing synchronous token capture.
  2. Computes the selected file's current fingerprint. `fileStamp` is a stat call and runs on the main actor.
  3. Returns without any read when `needsRebuild` is `false` and the published diff is for this file.
  4. Otherwise awaits the HEAD side. The git subprocess is already off the main actor.
  5. Runs the working-copy read and `LineDiff` inside a private serial-queue `offMain { }` block, through a `nonisolated static` helper, in `ProjectSearchModel`'s mould.
  6. Re-checks the token and publishes only on the main actor. `SelectionDiff` carries its fingerprint, and a superseded load still discards its result.
- [x] `rows(for:)`, which the diff window uses on double click, keeps its current behaviour.
- [x] `LocalChangesView` keeps reacting to `listRevision` and `selected` as today. The skip decision is the model's.
- [x] Tests (Core):
  - **Unchanged refresh does no work.** Refresh, load, then refresh and load again with the same stub status, the same head object and the same stamp. No HEAD read and no working-copy read happen on the second load, counted on the stubs, and the published value is unchanged.
  - **An edit to the selected file refreshes its diff.** Refresh and load, then change the stub's content and stamp, refresh, and load. The new rows are published. This is a new test; none exists today.
  - **A HEAD-only change refreshes.** A new head object with the same status and stamp rebuilds.
  - **A `nil` stamp always rebuilds.**
  - **The working-copy read runs off the main thread.** The stub records `Thread.isMainThread` under a lock, and the test asserts `false`.
  - **The existing superseded-load and pre-hop token tests stay green,** adapted to the new stubs.
  - Stubs that a `nonisolated` path reads must be fully configured before the load begins, and any recording they do is lock-protected.
- [x] Docs:
  - In `core-git-models.md`, document the ordering: token, then fingerprint, then skip-or-load, then off-main read and diff, then token re-check, then main-actor publish. Also the "unchanged" rule and why the head object is part of it (a partial commit of the selected file).
  - Document the same in `app-git-views.md`'s `LocalChangesView` entry.
  - Add `LocalChangesInlineDiff.swift` to `CLAUDE.md`'s `core-git-models.md` index line.
- [x] Run the gates. They must pass before Task 3.

### Task 3: Refuse binary and oversized files inline

**Files:**
- Modify: `Sources/PisakaCore/LocalChangesInlineDiff.swift`, `Sources/PisakaCore/LocalChangesModel.swift`, `Sources/Pisaka/LocalChangesView.swift`
- Modify: `Tests/PisakaCoreTests/LocalChangesInlineDiffTests.swift`, `Tests/PisakaCoreTests/LocalChangesModelTests.swift`, `Tests/PisakaAppTests/LocalChangesLayoutTests.swift`
- Modify: `docs/architecture/core-git-models.md`, `docs/architecture/app-git-views.md`

- [x] `LocalChangesInlineDiff.maxSideBytes = 1 << 20`, one named constant. Its reason, written beside it: it is the commit dialog's `maxSelectableFileBytes`, so a file whose hunks the commit dialog refuses to split is a file the panel refuses to diff inline. One threshold for "too large to read line by line" across the two git surfaces.
- [x] `Content` is the inline-diff state: `.rows([DiffRow])`, `.binary` or `.tooLarge`. `SelectionDiff` publishes `content` instead of `rows`.
- [x] `nonisolated static` classification. The cap is decided before any read wherever the size is known.
  - Working side: a stamp's `byteCount > maxSideBytes` gives `.tooLarge` without reading. Otherwise read with `readTextIfNotBinary(url:maxBytes:)`, where `nil` gives `.binary`. A symlink is its target text, and a deleted file is absent.
  - HEAD side: read only when the working side was not already refused. Use `headBlob(of:root:)`: data over the cap gives `.tooLarge`, otherwise `GitBlobText.classify`. Added and untracked files are absent.
  - When both sides are known, either side `.binary` gives `.binary`. Otherwise the rows come from `LineDiff` over the two texts.
  - A binary side is never turned into lines.
- [x] `LocalChangesView` shows a short centred placeholder in place of the rows: "Binary file" or "Too large to show inline". It uses the panel's existing placeholder style. Double click, Show Diff and ⌘D still open the diff window through `rows(for:)`, unchanged.
- [x] Tests (Core):
  - Classification for a binary HEAD side, a binary working side, an over-cap working side (no read happens, counted on the stub), an over-cap HEAD side, an exactly-at-cap text side, and text on both sides.
  - At the model level, a selected binary file publishes `.binary` and reads no text into rows.
- [x] Test (app): `LocalChangesLayoutTests` renders the panel once per placeholder state, one `HostedRender` each. It asserts the detail area draws `textSecondary` text where the rows would sit, and no diff-row wash.
- [x] Document the cap, its reason and the placeholder in `core-git-models.md` and `app-git-views.md`.
- [x] Run the gates. They must pass before Task 4.

### Task 4: Local Changes paths relative to the project, and the toolbar order pinned

**Files:**
- Modify: `Sources/PisakaCore/ChangedFileGroups.swift`, `Sources/PisakaCore/LocalChangesModel.swift`, `Sources/Pisaka/LocalChangesView.swift`
- Modify: `Tests/PisakaCoreTests/ChangedFileGroupsTests.swift`, `Tests/PisakaCoreTests/LocalChangesModelTests.swift`, `Tests/PisakaAppTests/LocalChangesLayoutTests.swift`
- Modify: `docs/architecture/core-git-models.md`, `docs/architecture/app-git-views.md`

- [x] `LocalChangesModel` publishes `projectPrefix`: the opened folder's path relative to the repository root, `""` when they are the same. It is derived through `CanonicalPath` from the requested folder and the resolved repository root, and set together with `root` on a successful refresh.
- [x] `ChangedFileGroups.group(_:rootName:projectPrefix:)`, with `projectPrefix` defaulting to `""`, so the current behaviour is the empty case.
  - Files under the prefix are grouped by their project-relative directory, and the root group carries the project's name.
  - Files outside the project folder stay repository-relative. Each group's label is the repository's name joined with its repository-relative directory, or the repository's name alone for repository-root files.
  - Outside groups sort after every project group.
- [x] `ChangedFileGroups.displayPath(_:projectPrefix:)` gives the detail header's text.
- [x] `ChangedFile.path` stays repository-relative for every git operation.
- [x] `LocalChangesView`:
  - `rootName` becomes the project folder's name.
  - Groups and the detail header use the project-relative forms.
- [x] Core tests:
  - The nested case: project `repo/app`, with files in `app/`, `app/Sources/` and `lib/` and at the repository root.
  - The same-folder case is unchanged.
  - The prefix through a symlinked spelling of the folder.
- [x] `LocalChangesLayoutTests` pins Revert before Refresh, off the same render. Find the elements labelled "Revert changes" and "Refresh changed files" in the hosting view's accessibility tree (`render.host`'s `accessibilityChildren()`, walked recursively). Convert their accessibility frames into the window. Assert Revert's minX is less than Refresh's, and that each lies inside ink clusters 1 and 2 respectively. (Done by glyph ink-shape matching against a reference render instead: the headless hosting view exposes no SwiftUI accessibility nodes; recorded in the suite header and app-git-views.md.)
- [x] Fix "project-relative" wording in the docs to match the new behaviour, including the outside-the-project rule.
- [x] Run the gates. They must pass before Task 5.

### Task 5: Count the caret column incrementally

**Files:**
- Modify: `Sources/PisakaCore/CaretReadout.swift`, `Sources/Pisaka/CodeEditorView.swift`
- Modify: `Tests/PisakaCoreTests/CaretReadoutTests.swift`
- Modify: `docs/architecture/core-editor.md`, `docs/architecture/app-editor.md`

- [x] Core:
  - `CaretReadout.ColumnMemo` holds `(lineStart, offset, column)`.
  - `CaretReadout.position(text:caretOffset:lineStarts:memo:editFloor:)` returns `(line, column, memo)`. `editFloor` is the lowest UTF-16 offset any edit touched since the memo was taken, or `nil` when there was none.
  - The existing `position(text:caretOffset:lineStarts:)` stays as the full count and is the reference the tests compare against.
- [x] The incremental path is taken only when all of these hold:
  - a memo exists;
  - the caret's line start equals the memo's `lineStart`;
  - `editFloor` is `nil` or at least the memo's offset, so `[lineStart, memo.offset)` is unchanged.
- [x] The incremental count:
  - Let `lo = min(old, new)`. Search back from `lo` for an anchor `a ≥ lineStart`, at most `CaretReadout.anchorLookback = 64` UTF-16 units.
  - `a` is either `lineStart` itself, or a position whose preceding and following units are both printable ASCII (0x20–0x7E). Such a boundary is a grapheme boundary in every context, so counts on either side of it add.
  - Then: column(a) = memo.column − count(a..old), and column(new) = column(a) + count(a..new).
  - If no anchor is found, fall back to the full count.
  - Any other case also falls back to the full count.
  - The anchor rule and its reason are written beside the constant.
- [x] An internal seam returns the UTF-16 units examined, the anchor search plus the units counted. It is the work count the tests charge.
- [x] App wiring:
  - The coordinator keeps `caretColumnMemo` and `caretEditFloor`.
  - The floor is lowered at the existing ruler `onEdit` callback site from the edited range's location.
  - `reportCaretPosition(of:)` passes both, stores the returned memo and clears the floor.
  - A buffer swap (the coordinator's file changes) drops the memo.
- [x] Tests. In every case the column equals the full count:
  - same line, moving forwards;
  - same line, moving backwards;
  - a different line;
  - an edit before the old offset (falls back);
  - typing at the caret, where the floor equals the old offset and the incremental path is taken;
  - a caret inside a surrogate pair, both as the old and as the new offset;
  - a caret inside a combining sequence, both as the old and as the new offset;
  - a sweep of every (old, new) pair over strings with combining marks, surrogate pairs, flags, ZWJ emoji, Hangul jamo and a prepend character.
- [x] Charged bound: on a 4,000,000-unit printable-ASCII line, a move from offset 2,000,000 to 2,000,005 reports work ≤ 5 + 64 + 2. The full-count path at the same caret reports work ≥ 2,000,000, which proves the seam counts the prefix when it is scanned.
- [x] Docs:
  - Correct `core-editor.md`'s "a caret move never rescans" claim, and the matching doc comment in `CaretReadout.swift`. State what is now true, and when the full count still runs: other lines, edits before the caret, lines without an ASCII anchor nearby.
  - Correct `app-editor.md`'s caret channel. The closure is `(UUID, (line: Int, column: Int))`, and the memo and floor live on the coordinator.
- [x] Run the gates. They must pass before Task 6.

### Task 6: Commit dialog memo tests, the push reason in the footer, stale commit-dialog docs

**Files:**
- Modify: `Sources/PisakaCore/CommitDialogModel.swift`, `Sources/PisakaCore/PushPlan.swift`, `Sources/Pisaka/CommitDialogView.swift`, `Sources/Pisaka/CommitUnifiedDiffView.swift`
- Modify: `Tests/PisakaCoreTests/CommitDialogModelTests.swift`, `Tests/PisakaAppTests/CommitDialogLayoutTests.swift`
- Modify: `docs/architecture/core-commit.md`, `docs/architecture/app-git-views.md`

- [x] Add an internal counter, `unifiedLinesComputations`, incremented inside `unifiedLines(for:)`. `unifiedLines` stays uncached and its doc keeps saying so, because that claim stays true. One test pins it: two direct reads count two.
- [x] Replace the two memo tests with tests on `unifiedDisplayRows(for:)`:
  - Repeated reads compute once.
  - `toggleFile` and `toggleUnit` leave the memo in place: no further computation, and the rows are equal.
  - A reload that changes the rows recomputes, and the new rows are the reloaded ones.
  - One test for every other assignment to `files` in the model, which drops the memo. Enumerate every `files` write site other than the two toggles, so a new write site that bypasses `didSet` fails.
  - Each test asserts the counter, not only equality.
- [x] Core: `CommitDialogModel.pushUnavailableMessage: String?` is the `PushPlan.unavailable` reason's message, and `nil` when the plan is available or there is no context. Test each of the three reasons and both `nil` cases.
- [x] View: whenever `pushUnavailableMessage` is non-`nil`, the footer shows it as one line of `.callout` `textSecondary` text after the Amend checkbox, before the spacer, tail-truncated. That is exactly when the Commit and Push button is disabled for a push-specific reason. The tooltip stays.
- [x] `CommitDialogLayoutTests` renders the dialog once with an unavailable push plan, one extra render. It asserts that the footer keeps its 64-point height, that the reason's text ink lies between the Amend checkbox and the Cancel button, and that the buttons keep their positions.
- [x] Stale text:
  - `CommitDialogModel`'s header: Amend only, plus the two commit buttons.
  - `CommitUnifiedDiffView`'s `isMutable` comment.
  - `PushPlan.swift`'s header about the former switch and checkbox.
  - `core-commit.md`'s memo paragraph: `unifiedDisplayRows` is memoized by path, invalidated by `files`' `didSet` and preserved across the two toggles; `unifiedLines` is uncached and read by the memo and the tests.
- [x] Run the gates. They must pass before Task 7.

### Task 7: One tooltip mechanism across the bottom bar

**Files:**
- Modify: `Sources/Pisaka/ContentView.swift`, `Sources/Pisaka/ProjectSwitcherView.swift`, `Sources/Pisaka/BranchSwitcherView.swift`, `Sources/Pisaka/PullRequestIndicatorView.swift`
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`, `Tests/PisakaAppTests/BottomBarToolTipTests.swift`
- Modify: `docs/architecture/core-theme.md`, `docs/architecture/app-window.md`

- [x] Make `BarToolTip` usable outside `ContentView.swift` (internal, not file-private). Replace `.help(...)` on the project, branch and pull-request widgets with `.background(BarToolTip(text: ...))`, keeping each text verbatim.
- [x] Each of the three widgets carries an `.accessibilityLabel`:
  - project and branch gain "Current project" and "Current branch", keeping their existing values;
  - the pull-request indicator keeps its label.
- [x] Rule ten (same number, same rule count) is extended from the two toggle idioms to the whole bar:
  - the `BottomBar` body and the three widget files each spell `BarToolTip(` and `.accessibilityLabel(`;
  - `.help(` is refused in all of them;
  - read on comment- and literal-stripped text.
- [x] Update the rule's header bullet and `core-theme.md`'s canonical entry. The rule count stays forty-six in the suite, `CLAUDE.md` and `core-theme.md`.
- [x] `BottomBarToolTipTests`:
  - The exact tooltip set grows by the project and branch widgets' texts as the fixture draws them.
  - The square-frame assertion stays for the toggles. The widget tooltip views are asserted to lie inside the bar's band.
  - The pull-request indicator is not drawn without a current-branch pull request, so its tooltip is pinned by rule ten alone. The suite header says so.
- [x] Accessibility hint decision: no hint is added. The toggles' former `.help` text was the panel title and the completion state, word for word their accessibility label and value, so a hint would make VoiceOver read the same words twice. Record that in `app-window.md`. Rule ten does not require a hint.
- [x] Run the gates. They must pass before Task 8.

### Task 8: Close the glyph rule's bypasses

**Files:**
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`
- Modify: `docs/architecture/core-theme.md`

- [x] Rule forty-six still reads with the literal-keeping scanner, because the subject is a literal. Extensions:
  - The load needles grow from `Image(` and `NSImage(named:` to also cover:
    - `Image.init(`
    - `NSImage.init(named:`
    - `ImageResource(`
    - `NSImage(resource:`
    - `image(forResource:`
  - `Image(systemName:`, `Image.init(systemName:` and `NSImage(systemSymbolName:` stay exempt as symbol loads.
  - An argument naming the token `rawValue` is refused alongside `assetName` and the glyph-name literals.
  - The helper's own two loads stay counted at exactly two.
- [x] The rule's matcher becomes a static function. A self-check test feeds it inline snippets of every bypass and requires each to be flagged: the raw value, a literal through each new spelling, and the resource loaders. It also requires the two symbol-load spellings to pass.
- [x] Update the suite header's rule bullet. In the "stated exceptions" paragraph, record the extended literal-keeping reading and its reason. Correct the two stale "three" counts of literal-keeping rules to "four". Update `core-theme.md`'s rule forty-six entry. The rule count stays forty-six.
- [x] Run the gates. They must pass before Task 9.

### Task 9: Log filter bar spinner slot and the window-width probe

**Files:**
- Modify: `Sources/Pisaka/CommitLogView.swift`, `Sources/Pisaka/ContentView.swift`, `Sources/Pisaka/TabListView.swift`
- Create: `Tests/PisakaAppTests/LogRefreshControlsLayoutTests.swift`
- Modify: `Tests/PisakaAppTests/TabColumnLayoutTests.swift`
- Modify: `docs/architecture/app-git-views.md`, `docs/architecture/app-window.md`

- [x] Extract `refreshControls` into an internal `CommitLogRefreshControls(isLoading:isEnabled:onRefresh:)` view. The spinner is always laid out and toggled with `.opacity(isLoading ? 1 : 0)` plus `.accessibilityHidden(!isLoading)`. Loading therefore never changes the trailing width `ViewThatFits` measures.
- [x] The new suite renders the controls once per state (two `HostedRender`s) and asserts equal `host.fittingSize.width`. It also asserts that the spinner's ink is absent when the controls are not loading.
- [x] Window-width probe. A small `TabColumnWidthProbe: ObservableObject` holds the published `TabColumnWidthRule.Bounds`.
  - It is held by `ContentView` in a plain `@State`, not `@StateObject`, so its publishes do not invalidate the root.
  - The root's existing `GeometryReader` background calls `probe.update(windowWidth:metrics:)`. That assigns only when the computed bounds differ, so above the threshold, where the maximum is the scaled 320, a resize publishes nothing.
  - The vertical-orientation branch wraps `TabListView` in a view that observes the probe and applies the frame.
  - `windowWidth` state is removed from the root.
- [x] Tests:
  - A plain unit test in the app bundle, with no view: two widths above the threshold publish once, and a width below it publishes new bounds.
  - `TabColumnLayoutTests` stays green.
- [x] Docs: the spinner slot in `app-git-views.md`, and the probe in `app-window.md`.
- [x] Run the gates. They must pass before Task 10.

### Task 10: Current-line invalidation, diff wash in light, the scope line's mask

**Files:**
- Modify: `Tests/PisakaAppTests/CurrentLineHighlightTests.swift`, `Tests/PisakaAppTests/HostedRender.swift`, `Tests/PisakaAppTests/HostedRenderTests.swift`, `Tests/PisakaAppTests/CommitUnifiedDiffWashTests.swift`
- Modify: `Sources/PisakaCore/SearchScopeLine.swift`, `Sources/PisakaCore/ProjectSearchModel.swift`, `Tests/PisakaCoreTests/SearchScopeLineTests.swift`
- Modify: `docs/architecture/app-editor-overlays.md`, `docs/architecture/core-search.md`

- [x] Current line: (the invalidation is read off each view's backing layer in one never-ordered borderless window: AppKit drops `needsDisplay` on a windowless view, and a windowed view's own getter reads `false` while its layer carries the flag — measured; recorded in the suite header and app-editor-overlays.md)
  - The harness's `select` goes through a real `CodeEditorView.Coordinator(text: .constant(text))` whose `textView` and `lineNumberRuler` are the harness's. It calls `updateCurrentLine(of:)` rather than restating the rule.
  - A new test moves the caret from line 0 to line 3. First it clears `needsDisplay` on the text view and the ruler. After the move it asserts:
    - `needsDisplay` is set on the text view;
    - `needsDisplay` is set on the ruler;
    - one render afterwards shows the old line with no tint and the new line tinted.
  - No `needsToDraw(_:)` assertion: that method is defined only while drawing and is unreliable outside `draw(_:)`.
  - One render per state, no window.
- [x] Diff wash:
  - `HostedRender`'s swatch key gains the appearance: `swatch(_:ground:appearance:)`, defaulting to dark. It is still rendered once per key.
  - `CommitUnifiedDiffWashTests` asserts the wash in light as well as dark, one render per appearance.
  - `HostedRenderTests`' no-extra-windows test covers a repeated light swatch.
- [x] Scope line:
  - `SearchScopeLine.text` shows the mask only when `ProjectSearchModel.maskPatterns(_:)` returns at least one pattern. That is the same splitting the search uses, from that one place, marked `nonisolated` if it is not already.
  - Tests: ",", " , ,", "*.swift, ", and an empty mask.
  - Document it in `core-search.md`.
- [x] Run the gates. They must pass before Task 11.

### Task 11: Verify acceptance criteria

- [x] Run `swift test`. (6011 tests, 0 failures)
- [x] Run `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' test`. (209 tests, 0 failures)
- [x] Run `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'generic/platform=iOS' build`.
- [x] Run `swiftlint --strict` from the repository root. (0 violations in 639 files)
- [x] Confirm the gating-rule count reads forty-six in `ChromeThemeSourceGatingTests`, `CLAUDE.md` and `core-theme.md`.
- [x] Confirm no new test helper creates a window, hosting view or bitmap inside a loop, and no test in the branch takes more than a few seconds (read the xcodebuild per-test durations). (every new window or bitmap is per-suite, per-state or swatch-cached; the slowest app test is 0.43 s and the slowest new Core test 0.06 s)

### Task 12: Update documentation

- [ ] Re-read every `docs/architecture/` entry touched above against the final code: `app-shell.md`, `app-window.md`, `app-git-views.md`, `app-editor.md`, `app-editor-overlays.md`, `core-git.md`, `core-git-models.md`, `core-commit.md`, `core-editor.md`, `core-search.md`, `core-theme.md`.
- [ ] `CLAUDE.md`: only the new index name `LocalChangesInlineDiff.swift`. It stays under its 60,000-character limit.
- [ ] `README.md` and `docs/FEATURES.md`: mention the inline diff's binary and too-large placeholders only if the Local Changes feature text there describes the inline diff.

## Post-Completion

- Launch the app on macOS 26 or later:
  - Confirm the title sits centred in the title bar, and stays centred through a resize and a full-screen round trip.
  - With Local Changes open and a large file selected, type in another file: no stutter.
  - Click a PNG in Local Changes and see "Binary file". Double click it and the diff window still opens.
