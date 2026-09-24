# Chrome theme, part five (b): the commit dialog, the merge editor and the four separate windows

## Overview

This part moves the last family of window surfaces onto the chrome's role vocabulary:

- the commit dialog: its file list, message box, author line, footer and author editor sheet;
- the three-pane merge editor;
- the four secondary windows that host code: diff, merge, Local History and the out-of-project source viewer;
- `EscClosableWindow`, the window subclass all six secondary windows are built from.

It spends `conflictBackground`, which leaves two roles unspent, `currentLine` and
`bracketMatch`. Both belong to the code zone's line overlays. Ten files join the gated
set (34 → 44). Six new rules take the suite from twenty-seven to thirty-three.

The ten files: `CommitDialogView.swift` (the file list, `CommitFileRow` and
`AuthorEditorView` live in it), `MergeView.swift`, `MergeWindowController.swift`,
`DiffWindowContent.swift`, `DiffWindowController.swift`, `SourceViewerContent.swift`,
`SourceViewerWindowController.swift`, `LocalHistoryView.swift`,
`LocalHistoryWindowController.swift` and `EscClosableWindow.swift`.

**Decisions this plan makes where the ticket is silent or the repository differs.** Each
one is recorded in `core-theme.md`:

1. **The editor becomes the fourth pane-ground caller.**
   `CodeEditorView.applyEditorBackground(scrollView:textView:)` (`CodeEditorView.swift`
   ~557) already sets the same three backgrounds privately. If it stayed, "one
   definition" would be false on day one. It becomes a call into the shared definition,
   which gives four call sites, not three. `CodeEditorView.swift` still stays out of the
   gated set.
2. **The checkbox is lifted, not written.** `LocalChangesView.swift` (already gated)
   draws exactly the shape requirement 7 describes, from private
   `LocalChangesLayout.checkboxSide` (14), `checkboxRadius` (3) and `checkmarkSide` (8).
   The shared checkbox is lifted from it, the way part five (a) lifted the field from the
   Log filter bar. The revert checkbox becomes the fifth caller and its private numbers
   are deleted, so no second copy survives.
3. **The checkbox glyph is 10 points, the design's value, not Local Changes' 8.** One
   shape now serves five callers, so it takes one value. The design draws the check at 10
   inside the same 14-point box. The 8 was a private number chosen for the one revert
   checkbox before a shared shape existed and was never checked against a drawing. The
   shared shape follows the drawing it is lifted to match. The cost is that the revert
   checkbox's check grows by two points, which is stated in `ChromeControls.swift` beside
   the constant. The value is a named private constant in `ChromeControls.swift`, not a
   `ChromeGeometry` token: exactly one definition draws it, and the ticket names the two
   new checkbox tokens (side and radius) and no third. The mixed-state dash uses the same
   width.
4. **The unified diff's per-line checkbox is not swept.** It is an SF Symbol inside a
   code-font row. The shared checkbox is interface-scaled, and putting it in a code-zoom
   row would be the mixed-zone mistake rule twenty-seven exists to catch. The new rule
   bans platform toggles (the `Toggle` and `toggleStyle` tokens), and this glyph is
   neither. It keeps its glyph, and `core-theme.md` records it as an open question.
5. **The commit dialog gains its header strip.** Today the dialog has no header. It
   gains a 44-point `bgPanel` strip closed by a `hairline` rule, carrying the title
   "Commit Changes" at `.headline` semibold in `textPrimary`. The design's 14 has no
   place on the chrome's scale.
6. **The dialog's corners are the system sheet's.** A sheet's frame is drawn by the
   system. Clipping the content to `cornerRadiusMax` would only expose the sheet's own
   ground at the corners. The content therefore does not clip, and the file says so.
7. **Two small substitutions for styles the new rule forbids.**
   - The author line's "Edit…" uses `.buttonStyle(.link)`, a platform style the new
     rule forbids. It becomes a `.plain` button with an `accent` label.
   - The merge toolbar's vertical `Divider().frame(height: 16)` becomes a vertical
     `hairline` rule. Its 16 goes into a private layout enum, not `ChromeGeometry`,
     because only one surface uses it.
8. **The problem browser's window changes colour.** Once the ground moves into the
   subclass, the problem browser's window (`LeetCodeBrowserWindowController`) also gets
   `bgPanel`. Its view is swept in part five (d). This is the intended consequence of
   "every secondary window gets the same ground".
9. **The alpha clause targets roles, not all colours.** `MinimapView.swift` (gated)
   applies `withAlphaComponent(0.6)` to a syntax-table colour, which is code zone, not a
   role. So "no gated file hand-writes an alpha on a colour" is enforced as "on a role's
   colour" across the gated set, plus a ban on the `withAlphaComponent` token outright in
   this part's ten files. The rule's comment names the minimap's case.
10. **The pane-ground clause is about a code pane, not about every `backgroundColor`.**
    `CompletionPanel.swift` (~156) and `HoverPanel.swift` (~218) set
    `panel.backgroundColor = .clear` on an `NSPanel` and must keep doing so: a borderless
    panel has to be clear for its own rounded layer to draw. They are not code panes, so
    the clause does not reach them. The clause is scoped to what it is about, a code
    pane's ground, and not widened into a file exclusion list.

## Context

**Files involved**

- Core:
  - `Sources/PisakaCore/ChromeColorRole.swift`: `mergeWashRole(for:)`, plus the doc
    comment listing unspent roles.
  - `Sources/PisakaCore/ChromeGeometry.swift`: three new tokens.
  - New: `Sources/PisakaCore/MergeLineKind.swift`.
- App, joining the gated set:
  - `CommitDialogView.swift`, `MergeView.swift`, `MergeWindowController.swift`
  - `DiffWindowContent.swift`, `DiffWindowController.swift`
  - `SourceViewerContent.swift`, `SourceViewerWindowController.swift`
  - `LocalHistoryView.swift`, `LocalHistoryWindowController.swift`
  - `EscClosableWindow.swift`
- App files that are already gated, or not gated, and are touched only where a
  requirement names them:
  - `ChromeControls.swift`
  - `DiffView.swift`: the shared pane ground, beside `DiffDividerView`.
  - `LocalChangesView.swift`
  - `LogFilterBar.swift`
  - `ProjectSearchWindowController.swift`
  - `ProjectSearchView.swift` and `SearchBarView.swift`: the two part five (a)
    corrections.
  - `CodeEditorView.swift`: not gated.
- Tests:
  - `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`
  - `Tests/PisakaCoreTests/ChromeThemeTests.swift`
  - New: `Tests/PisakaCoreTests/MergeWashRoleTests.swift`, or the existing role-mapping
    test file if one holds `diffWashRole`'s tests.
  - Read only, must stay green: `ZoomSourceGatingTests`, `InterfaceMetricsTests`,
    `LSPSourceGatingTests` (its `containsToken(_:in:)` is reused).
- Docs:
  - `docs/architecture/core-theme.md`, `app-git-views.md`, `app-window.md`,
    `core-local-history.md`, `app-editor.md`, `core-diff-merge.md`
  - `CLAUDE.md`

**Related patterns**

- **Core's one answer.** Follow the shape of `ChromeColorRole.diffWashRole(for:)` and
  `changedFileRole(for:)`: a static function over a closed Core enum that returns a role
  (optional where "no wash" is an answer). Its readers are pinned by set equality, as
  `diffWashReaders` is.
- **The window root's colours.** A root resolves its colours through a private
  `chromeColor(_:)` over `settings.chromeTheme(systemPrefersDark:)`, as
  `ContentView.swift` ~391 and `ProjectSearchView.swift` ~96 do. A child struct declared
  at file scope in the same file reads `@Environment(\.chromeTheme)`. Today no root in
  scope nests a child view inside its own braces (`MergeThreePaneView`, `RevisionRow`
  and `SourceViewerPane` are all file-scope). Rule thirty-two keeps it that way.
- **AppKit colour.** `ChromePalette.nsColor(_:)` returns a dynamic colour.
  - Filled in a draw method or set on a view, it needs no appearance bracket.
  - `performAsCurrentDrawingAppearance` is for layer `CGColor`s only (rule
    twenty-five).
- **Themed list.** Follow `ProjectSearchView.swift` ~299–320: `.listStyle(.inset)`,
  `.scrollContentBackground(.hidden)`, a `bgPanel` `listRowBackground`, and platform
  selection.
- **Numbers.** A number used by one surface goes in a private layout enum in that file.
  A shared measurement becomes a `ChromeGeometry` token, never derived from another
  token. A number that belongs to one shared shape stays a named private constant in the
  shape's file, with its reason (decision 3).
- **Rule matching.**
  - Gating rules read comment- and literal-stripped text.
  - **Every identifier ban and every identifier presence check matches through
    `LSPSourceGatingTests.containsToken(_:in:)`, never a bare `String.contains`.** The
    suite already does this at four sites. A substring match is wrong in both directions
    here. The `Toggle(` ban under `contains` is red on day one, because
    `ChromeQueryToggle(` carries it and is spelled in `SearchBarView.swift`,
    `ProjectSearchView.swift` and `ChromeControls.swift`, all gated. `containsToken`
    rejects that on the preceding identifier character.
  - A leading-dot member (`.toggleStyle(`, `.chromePrimary`, `.accessibilityValue(`) is
    matched as its bare identifier token (`toggleStyle`, `chromePrimary`,
    `accessibilityValue`). `containsToken`'s boundary check would reject the dotted
    needle whenever the dot follows an identifier character, as in `view.toggleStyle(`.
    The comment at each such clause says so.
  - A key path is matched with its backslash, as in
    `containsToken("\\.chromeTheme", …)`, so that `settings.chromeTheme(` in a root's
    own resolver is not a hit and `.chromeThemed(` is rejected on the trailing
    character.
  - A clause that must use a pattern rather than a token (an assignment's shape, a
    modifier's arguments) says why in its comment.
  - Multi-line modifiers are matched with brace-matched bodies
    (`matchedBody(after:in:)` / `matchedBodies(after:in:)`) or whitespace-tolerant
    patterns, never contiguous substrings.
  - Rule twenty-seven's `.frame(… height:` walk is the precedent for a "no fixed height"
    clause. Factor it into a shared helper rather than copying it.

**Dependencies:** none new.

## Development Approach

- **Testing approach:** regular (code first, then tests). The exception is Task 8, where
  every new rule is first shown red against a deliberate local regression, then green,
  and the tree is confirmed clean with `git status`.
- **Order of work:** complete each task before the next. A task that restyles a file
  adds it to `gatedFiles` in the same task, so rules one and two cover it immediately.
- **Architecture entries:** read each file's `docs/architecture/` entry before modifying
  it.
- **No new role, no new exemption, no new font size.** Chrome text uses
  `InterfaceTextStyle` `.body`/`.headline` (13), `.callout` (12), `.subheadline` (11)
  and, where requirement 10 names it, `.caption` (10). Anything that seems to need more
  comes back as a design question.
- **No relayout.** The merge editor keeps its toolbar-on-top arrangement. The commit
  dialog keeps its split and bottom section. The only structural additions are the ones
  the requirements name: the dialog's header strip and the file row's second text line.
- **No product or brand names** anywhere.
- **Derived data:** local `xcodebuild` uses
  `-derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-<purpose>`, never a path
  inside the repository.
- **Unattended verification only:**
  - No task takes a screen capture.
  - No task depends on a human opening a window, sheet or menu.
  - Anything only a running window can confirm belongs to Post-Completion.
- **CRITICAL:** every task includes new or updated tests.
- **CRITICAL:** `swift test` passes before the next task starts. A task that touches app
  files also builds the macOS app.

## Implementation Steps

### Task 1: Core: the merge line vocabulary, its wash, and the new geometry tokens

**Files:**
- Create: `Sources/PisakaCore/MergeLineKind.swift`
- Modify: `Sources/PisakaCore/ChromeColorRole.swift`
- Modify: `Sources/PisakaCore/ChromeGeometry.swift`
- Modify: `Tests/PisakaCoreTests/ChromeThemeTests.swift`
- Create or modify: the role-mapping test file (see Context)

- [x] Move the view's private `MergeLineKind` into Core verbatim as a public,
  `Sendable`, `CaseIterable` enum with the cases `plain`, `ours`, `theirs`,
  `conflictUnresolved` and `conflictResolved`. The doc comment says the view *derives*
  which line is which kind; Core owns only the vocabulary and the mapping.
- [x] Add `ChromeColorRole.mergeWashRole(for: MergeLineKind) -> ChromeColorRole?`:
  - `ours`, `theirs` and `conflictUnresolved` map to `conflictBackground`;
  - `conflictResolved` maps to `diffAddedBackground`;
  - `plain` maps to `nil`.
- [x] The doc comment on `mergeWashRole(for:)` states why there is one wash rather than
  two. The design draws the differing lines of the read-only panes and the unresolved
  region of the result pane identically, and the panes are what tell them apart.
- [x] Update the type's doc comment: the merge panes spend `conflictBackground`, and the
  two roles left unspent are `currentLine` and `bracketMatch`, both code zone.
- [x] Add three `ChromeGeometry` tokens, each with a one-line comment and none derived
  from another:
  - `dialogEdgeStripHeight` = 44 (the commit dialog's header and the merge window's
    status strip);
  - `checkboxSide` = 14;
  - `checkboxCornerRadius` = 3.
- [x] Extend `testGeometryTokensCarryTheirTableValues` and the set-equality inventory in
  `testGeometryDeclaresExactlyTheseTokensAndNoFontSize`.
- [x] Write tests for `mergeWashRole(for:)`: every case of `MergeLineKind.allCases` has
  its expected answer, and exactly the three conflicted kinds reach
  `conflictBackground`. This is the merge wash's first test of any kind.
- [x] Add the index line for `MergeLineKind.swift` to `CLAUDE.md` under
  `core-diff-merge.md`, and a short entry in that doc.
- [x] Run `swift test`. It must pass.

### Task 2: One window ground, set in the subclass

**Files:**
- Modify: `Sources/Pisaka/EscClosableWindow.swift`
- Modify: `Sources/Pisaka/ProjectSearchWindowController.swift`
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`

- [x] Override `EscClosableWindow`'s designated initializer
  `init(contentRect:styleMask:backing:defer:)`: call super, then set
  `backgroundColor = ChromePalette.nsColor(.bgPanel)`.
  - `NSWindow(contentViewController:)` is a convenience initializer that goes through
    the designated one. So this one line covers the five controllers that pass a view
    controller and the merge controller that passes a rectangle.
  - The doc comment says why the ground lives here: a window's ground is a property of
    the window, and two setters compete silently. This is the sibling of
    `MainWindowChrome.swift`'s rule.
  - Update the comment's list of users to all six controllers.
- [x] Remove `window.backgroundColor = …` from `ProjectSearchWindowController.swift`
  (~58) and move its live-resize rationale into the subclass's comment.
- [x] Add five files to `gatedFiles`: `EscClosableWindow.swift`,
  `DiffWindowController.swift`, `MergeWindowController.swift`,
  `SourceViewerWindowController.swift` and `LocalHistoryWindowController.swift`.
- [x] Add the four new controllers **and** `ProjectSearchWindowController.swift` to
  `roleNamingExemptions`. After this change none of them names a role. The comment says
  they are gated for rules one and two and for the window-ground rule (Task 8), which
  are exactly the rules they can break.
- [x] Run `swift test` and the macOS build. Both must pass.

### Task 3: One code-pane ground, one pane divider, and the merge wash through Core

**Files:**
- Modify: `Sources/Pisaka/DiffView.swift`
- Modify: `Sources/Pisaka/SourceViewerContent.swift`
- Modify: `Sources/Pisaka/CodeEditorView.swift`
- Modify: `Sources/Pisaka/MergeView.swift` (AppKit half only)
- Modify: `Sources/Pisaka/DiffWindowContent.swift`
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`

- [x] Add one definition in `DiffView.swift` beside `DiffDividerView`:
  `CodePaneGround.apply(scrollView:textView:)`.
  - It sets the text view, the scroll view and that scroll view's clip view to
    `ChromePalette.nsColor(.bgEditor)`.
  - Its comment carries the source viewer's existing rationale: the gutter fills itself
    with `bgEditor`, so a pane on the system text background shows a lighter band. It
    also names its four callers.
- [x] Route the four callers through it:
  - `SourceViewerContent.swift`, replacing its three assignments (~111–113);
  - `DiffView.makePane`;
  - the merge panes' `makePane`;
  - `CodeEditorView.applyEditorBackground`: its body becomes the call, or the call
    replaces the function.
- [x] `MergeContainerView` builds its dividers from `DiffDividerView` instead of `NSBox`
  separators. Its `dividerWidth` reads `ChromeGeometry.hairlineWidth` unscaled, for the
  reason `DiffContainerView` states. Delete the `NSBox` code.
- [x] `MergePaneTextView.drawBackground(in:)` fills with `ChromePalette.nsColor(role)`,
  where the role comes from `ChromeColorRole.mergeWashRole(for:)` and `nil` means no
  fill.
  - Delete the private `MergeLineKind` and `MergeColors`.
  - Do not add `performAsCurrentDrawingAppearance`. One line says why: a dynamic
    `NSColor` filled at draw time resolves at that moment.
- [x] `DiffWindowContent` root: the "Loading…" text takes `textSecondary` through a
  private `chromeColor(_:)`, in the root shape.
- [x] Add `SourceViewerContent.swift` and `DiffWindowContent.swift` to `gatedFiles`. (`SourceViewerContent.swift` joins `roleNamingExemptions`: its only colour was the pane ground, now `CodePaneGround`.)
- [x] Run `swift test` (rules one and two over the new files) and the macOS build. Both
  must pass.

### Task 4: The shared primary button and checkbox; the revert checkbox and the Log date toggle as first callers

**Files:**
- Modify: `Sources/Pisaka/ChromeControls.swift`
- Modify: `Sources/Pisaka/LocalChangesView.swift`
- Modify: `Sources/Pisaka/LogFilterBar.swift`
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`

- [ ] Add `ChromePrimaryButtonStyle` plus `.chromePrimary`:
  - label: `callout` semibold in `onAccent` on an `accent` ground;
  - geometry: `buttonCornerRadius`, `secondaryButtonHeight` and
    `secondaryButtonPaddingX`, all scaled through `InterfaceMetrics`;
  - disabled and pressed: dims exactly as the secondary style does.
- [ ] Add `ChromeCheckbox`, lifted from `LocalChangesView`'s revert checkbox:
  - It takes a three-case state (on, off, mixed), an action, a spoken label, and an
    optional trailing text label for the Amend and Push rows.
  - Geometry: a `checkboxSide` square with `checkboxCornerRadius`, both from the shared
    tokens.
  - Off: a `hairline` border and no ground. On: an `accent` ground with an `onAccent`
    check. Mixed: the same ground with an `onAccent` dash. This is a glyph decision, not
    a new role.
  - The glyph is 10 points (decision 3), held in one named private constant (for
    example `ChromeCheckboxLayout.glyphSide = 10`) and scaled through
    `InterfaceMetrics`. Its comment says which value this is and why the other was not
    taken: 10 is the design's check inside the 14-point box; Local Changes' former 8 was
    a private choice for one caller, made before the shape was shared and never checked
    against the drawing. With one shape serving five callers, the drawing wins, and the
    revert checkbox's check grows two points. The dash uses the same width.
  - The box is hidden from accessibility. The control carries `.accessibilityLabel` plus
    `.accessibilityValue` ("On", "Off" or "Mixed").
  - It honours `isEnabled` by dimming.
- [ ] `LocalChangesView` draws its revert checkbox through `ChromeCheckbox`. Delete
  `LocalChangesLayout.checkboxSide`, `checkboxRadius` and `checkmarkSide` and the private
  builder (~491–510, ~572–576). Keep its label ("Include <name> in revert") and its help
  text.
- [ ] `LogFilterBar.dateBound` (~365–371) replaces `Toggle(…).toggleStyle(.checkbox)`
  with `ChromeCheckbox` plus its label, inside the same control box. The label, colour
  and layout are otherwise unchanged. This is the one already-gated file the new toggle
  ban would otherwise find red on day one. The token scan confirms that the only other
  `Toggle` spellings in gated files today are in comments, which the stripped text drops.
- [ ] Run `swift test` and the macOS build. Both must pass. `LocalChangesView`'s and
  `LogFilterBar`'s existing rules (rules nineteen and twenty-one, and the panel-controls
  rule) must stay green unchanged, or be re-pointed deliberately with the reason stated.

### Task 5: The commit dialog

**Files:**
- Modify: `Sources/Pisaka/CommitDialogView.swift`
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`

- [ ] **Header and panes.**
  - Add the header strip (decision 5): `dialogEdgeStripHeight`, `bgPanel`, a `hairline`
    bottom rule, and "Commit Changes" at `.headline` semibold in `textPrimary`. A comment
    says the design's 14 is not on the chrome's scale.
  - The file-count header and the diff path header become pane headers:
    `panelHeaderHeight`, `bgPanel`, a `hairline` bottom rule, and `textSecondary` text.
  - The dialog's ground is `bgPanel`. The system sheet keeps its corners (decision 6).
  - The diff preview stands on `bgEditor`.
  - Each of the three `Divider()`s becomes a `hairline` rule in the same direction and
    thickness.
- [ ] **File row.**
  - Two text lines: the name in `textPrimary` at `.body`, then the directory in
    `textSecondary` at `.caption`.
  - No fixed height: the row is sized by its content and padding.
  - The file-type icon is coloured by `changedFileRole(for:)` and hidden from
    accessibility by its own `.accessibilityHidden(true)`.
  - The status letter moves to `.callout` semibold monospaced (the one correction) and
    keeps its spoken value.
  - The per-file toggle becomes `ChromeCheckbox` with all three states, labelled
    "Include <name> in the commit".
  - Row background, in precedence order:
    - selected in a key window: `accentTintStrong`;
    - selected in a window that is not key: `selectionInactive`;
    - pointer inside: `hoverTint`.
  - Use `TreeRowState.state(…)` if it fits without contortion. Otherwise use the same
    three roles in the same order.
  - A comment states that the design's single mock draws `accentTint` and cannot show
    the other two states, so the established precedence wins.
- [ ] **Message box.** Wrap the `TextEditor` in `ChromeControlBox`:
  - focus driven by a `@FocusState`, with `fieldPaddingX`;
  - `.scrollContentBackground(.hidden)` so `bgEditor` shows through;
  - content in `textPrimary`;
  - the code-zone height and the `ZoomSurfaceMarker` kept as they are.
  - A comment says the design's 12 points of padding is taken as the shared 10, because
    a two-point difference in one drawing is not worth a second measurement.
- [ ] **Author line and footer.**
  - "Author:"/"Committer:" and the amend note in `textSecondary`.
  - The signature in `textPrimary`, or `statusRed` when incomplete.
  - "Edit…" as a `.plain` button with an `accent` label (decision 7).
  - Amend and "Push after commit" become `ChromeCheckbox` with their labels. The push
    hint is `textSecondary`.
  - The status sentence is `statusRed` for an error and `textSecondary` otherwise.
  - Cancel uses `.chromeSecondary` and Commit uses `.chromePrimary`. The keyboard
    shortcuts and disabled rules are unchanged.
  - A `hairline` rule sits above the footer, which is sized by its content.
- [ ] **Author editor sheet.**
  - Title in `textPrimary`, caption in `textSecondary`, `bgPanel` ground.
  - Save uses `.chromePrimary` and Cancel uses `.chromeSecondary`.
- [ ] Add `CommitDialogView.swift` to `gatedFiles`. Add it to rule twenty-six's
  `sharedFieldConstructors`, and change that assertion's message from "four callers" to
  five.
- [ ] `InterfaceMetricsTests`' commit-dialog composition must stay green; the sheet's
  minimum sizes are unchanged.
- [ ] Run `swift test` and the macOS build. Both must pass.

### Task 6: The merge editor's SwiftUI half

**Files:**
- Modify: `Sources/Pisaka/MergeView.swift`
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`

- [ ] Add a private `chromeColor(_:)` to the root `MergeView`, in the root shape.
  Nothing inside the root struct's declaration reads `\.chromeTheme`: not its body and
  not a stored property. `MergeThreePaneView` stays at file scope, and so does any new
  child view.
- [ ] **Status strip** (today's toolbar):
  - `dialogEdgeStripHeight` high, `bgPanel`, a `hairline` bottom rule.
  - The "Conflict n of m" and status sentences are `.callout`. The status is
    `statusGreen` when fully resolved and `textSecondary` otherwise.
  - Both chevrons use `.chromeSecondary` and carry `.accessibilityLabel` ("Previous
    conflict"/"Next conflict") plus `.help`.
  - The four take-side buttons use `.chromeSecondary`. Apply uses `.chromePrimary` and
    keeps its ⌘↩ shortcut and disabled rule.
  - The vertical `Divider()` becomes a vertical `hairline` rule (decision 7).
- [ ] **Pane header:** `panelHeaderHeight` (was 22), `bgPanel`, a `hairline` bottom rule,
  titles in `textPrimary` at the size the dock's panel headers use, and vertical
  `hairline` rules between them.
- [ ] Error text is `statusRed` and the loading text is `textSecondary`.
- [ ] Replace all six `Divider()`s with `hairline` rules.
- [ ] Add `MergeView.swift` to `gatedFiles`.
- [ ] Run `swift test` and the macOS build. Both must pass.

### Task 7: The Local History window, and the two part five (a) corrections

**Files:**
- Modify: `Sources/Pisaka/LocalHistoryView.swift`
- Modify: `Sources/Pisaka/ProjectSearchView.swift`
- Modify: `Sources/Pisaka/SearchBarView.swift`
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`

- [ ] **Local History root and list.**
  - A private `chromeColor(_:)` on the root. Nothing inside the root struct's
    declaration reads `\.chromeTheme`.
  - The revisions list follows the Find in Files precedent: inset style,
    `.scrollContentBackground(.hidden)`, `bgPanel` row backgrounds, and platform
    selection.
  - The empty-state and "Select a revision" texts are `textSecondary`.
  - The `Divider()` above the footer becomes a `hairline` rule.
  - Restore uses `.chromeSecondary` and keeps its plan-driven enablement.
- [ ] **`RevisionRow`**, at file scope, reads `\.chromeTheme` as a child: the title in
  `textPrimary`, the time line in `textSecondary`.
- [ ] Add `LocalHistoryView.swift` to `gatedFiles`. The set is now 44.
- [ ] Fix the `ProjectSearchView.swift` match-row comment (~374) that says the line
  number "stays `.secondary`". It takes `textSecondary`.
- [ ] Give the whole-word toggle one spoken name, "Whole word", in both
  `SearchBarView.swift` and `ProjectSearchView.swift`.
- [ ] Run `swift test` and the macOS build. Both must pass.

### Task 8: Six new gating rules, each shown red first

**Files:**
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`

Every identifier clause below matches through `LSPSourceGatingTests.containsToken(_:in:)`.
Where a clause uses a pattern instead, its comment says why.

- [ ] **Rule twenty-eight: a secondary window's ground is set in the window subclass.**
  - The files constructing `EscClosableWindow` (token) are pinned by set equality: the
    six controllers.
  - None of them assigns `backgroundColor`. This is a whitespace-tolerant assignment
    pattern, because the clause is about an assignment's shape and not an identifier's
    presence; the comment says so.
  - `EscClosableWindow.swift`'s brace-matched designated-init body assigns
    `backgroundColor` and names the `bgPanel` token.
- [ ] **Rule twenty-nine: the merge wash is Core's one answer.**
  - The `mergeWashRole` token is read by `MergeView.swift` alone.
  - No app file other than `ChromePalette.swift` spells the tokens
    `conflictBackground`, `currentLine` or `bracketMatch` (acceptance criterion 8).
  - No gated file applies an alpha to a role's colour: `nsColor(…)` or `.color(…)`
    chained into `withAlphaComponent(` or `.opacity(`, tolerant of line breaks. This is
    a pattern over a brace-matched call followed by a chained member, and the comment
    says why a token cannot express it.
  - This part's ten files spell the `withAlphaComponent` token nowhere.
  - `MergeView.swift` spells no `performAsCurrentDrawingAppearance` token.
  - The comment names `MinimapView`'s code-zone alpha as outside the rule (decision 9).
- [ ] **Rule thirty: one primary button, one secondary, one checkbox.**
  - No gated file spells the tokens `Toggle` or `toggleStyle`. The comment says two
    things. First, `toggleStyle` is matched without its leading dot, because
    `containsToken` would reject `.toggleStyle(` after an identifier character. Second,
    the token match is what keeps `ChromeQueryToggle(` in `SearchBarView.swift`,
    `ProjectSearchView.swift` and `ChromeControls.swift` from being a hit; a bare
    `contains` would be red on day one.
  - No gated file spells the tokens `BorderedButtonStyle`,
    `BorderedProminentButtonStyle`, `LinkButtonStyle` or `DefaultButtonStyle`.
  - Within the brace-matched argument of every `.buttonStyle(` application, none of the
    tokens `bordered`, `borderedProminent`, `link` or `automatic` appears. The comment
    says why this is scoped to the argument: a bare `link` token file-wide would hit
    unrelated identifiers. `plain` and `borderless` stay allowed, because they are the
    icon-button idiom throughout the gated set.
  - Callers are pinned by set equality, by token:
    - `chromePrimary`: `CommitDialogView`, `MergeView`;
    - `chromeSecondary`: `SearchBarView`, `ProjectSearchView`, `CommitDialogView`,
      `MergeView`, `LocalHistoryView`;
    - `ChromeCheckbox`: `CommitDialogView`, `LogFilterBar`, `LocalChangesView`, plus the
      defining file.
  - No gated file other than `ChromeControls.swift` declares a checkbox side, radius or
    glyph size of its own.
  - In each of this part's ten files, every `Button` construction is styled. The check
    counts `Button` tokens against `buttonStyle` applications, and each file's expected
    pair is stated.
- [ ] **Rule thirty-one: a code pane's ground goes through one definition.**
  - The `CodePaneGround` call `CodePaneGround.apply(` is found, by token, in exactly
    `CodeEditorView.swift`, `SourceViewerContent.swift`, `DiffView.swift` and
    `MergeView.swift`.
  - The pane-ground clause is scoped to **a code pane's ground**, meaning the text view,
    its scroll view and that scroll view's clip view. Across the gated set plus
    `CodeEditorView.swift` (a caller, though not gated), no `backgroundColor` assignment
    whose receiver is a code pane appears outside `CodePaneGround`'s brace-matched body.
    A receiver is a code pane when it is an expression ending in a text view, a scroll
    view or a scroll view's `contentView`, or when it is a bare `backgroundColor =`
    inside a type declared as an `NSTextView`, `NSScrollView` or `NSClipView` subclass.
    The receiver classification is a pattern, and the comment says why: the clause is
    about which object is being painted, which a token cannot see.
  - The comment names what is deliberately outside the clause and why, as a matter of
    what a pane's ground goes through rather than as a list of exempt files:
    - `CompletionPanel.swift` and `HoverPanel.swift` set `panel.backgroundColor = .clear`
      on an `NSPanel`, and must: a borderless panel has to be clear for its own rounded
      layer to draw. A panel is not a code pane.
    - Window grounds are rule twenty-eight's.
    - Layer `backgroundColor`s take a `CGColor` and are rule twenty-five's.
  - No gated file spells the `NSBox` token.
  - `MergeView.swift` spells the `DiffDividerView` token.
- [ ] **Rule thirty-two: a window root resolves the theme the root way.**
  - The files declaring a private `chromeColor` (token) are pinned by set equality:
    `ContentView`, `ProjectSearchView`, `DiffWindowContent`, `MergeView` and
    `LocalHistoryView`.
  - For every gated file in `ZoomSourceGatingTests.interfaceScaledRoots`, the matched
    region is the **root struct's whole brace-matched declaration**, not its `var body`.
    That region spells no `\.chromeTheme`, matched as
    `containsToken("\\.chromeTheme", …)` so the root's own `settings.chromeTheme(` is
    not a hit. The comment says why the region is the struct: the regression this rule
    exists for is an `@Environment(\.chromeTheme)` stored property added to a root, and
    that property sits in the struct's braces, outside `body`. A clause matched against
    `body` alone would be vacuous on exactly that mistake. Child views read the
    environment from file scope.
  - The comment names `SourceViewerContent` as a root that paints no SwiftUI colour: its
    one colour is the AppKit pane ground.
- [ ] **Rule thirty-three: the commit dialog's rows and controls.**
  - `CommitFileRow`'s brace-matched body has no `.frame(… height:`. Use the
    multi-line-aware walk factored out of rule twenty-seven into a shared helper, and
    re-point rule twenty-seven to it.
  - That body names the tokens `accentTintStrong`, `selectionInactive` and `hoverTint`.
  - `ChromeCheckbox`'s body spells the `accessibilityValue` token (bare, for the
    leading-dot reason stated in rule thirty).
  - In `MergeView.swift`'s status strip, each chevron carries an `accessibilityLabel`
    token.
- [ ] Extend the `spelled` table to thirty-three. Update the suite's doc-comment summary
  with the six rules.
- [ ] Mutation-verify every rule. For each clause, introduce the regression it exists
  for, confirm it is red, then revert:
  - a controller setting `backgroundColor`;
  - a colour table with `withAlphaComponent` in the merge view;
  - a `performAsCurrentDrawingAppearance` wrap;
  - a `Toggle(` and a `.toggleStyle(` in a gated file, and a `.buttonStyle(.link)`;
  - an unstyled `Button` in one of the ten files;
  - a `scrollView.backgroundColor = …` in the merge pane's `makePane`, outside
    `CodePaneGround`. Also confirm that the two panels' `.clear` assignments keep the
    rule green as the tree stands;
  - an `NSBox`;
  - an `@Environment(\.chromeTheme) private var theme` **stored property added to
    `MergeView`'s root struct**, not a read inside `body`;
  - `.frame(\n    height:` in `CommitFileRow`;
  - a removed chevron label.
- [ ] Confirm `git status` is clean apart from the intended changes.
- [ ] Run `swift test`. It must pass.

### Task 9: Verify acceptance criteria

- [ ] Run `swift test`. It must pass.
- [ ] Run `xcodegen generate`, then run the app bundle with
  `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-part5b test`.
  It must pass.
- [ ] Run `swiftlint --strict` from the repository root. It must report zero violations.
- [ ] Build macOS Release (`-configuration Release`) and iOS (`generic/platform=iOS`),
  both with derived data outside the repository.
- [ ] Grep-confirm the remaining acceptance points:
  - `gatedFiles` holds 44 files;
  - no gated file spells `Divider(`;
  - `conflictBackground` is read only through `mergeWashRole`;
  - `currentLine` and `bracketMatch` have no reader outside the palette.

### Task 10: Documentation

- [ ] Update `docs/architecture/core-theme.md`:
  - **Decisions:**
    - the merge wash mapping, and why one wash rather than two;
    - the pane-ground rule and its four call sites, with the editor as the corrected
      fourth, plus why the clause is scoped to a code pane (the two panels' `.clear`);
    - the window-ground rule, and why it lives in the subclass;
    - the primary button and the checkbox, including the checkbox's lift from Local
      Changes and the glyph's 10-over-8 decision;
    - the rule-matching convention: identifier clauses through `containsToken`,
      leading-dot members as bare tokens, and the root region being the whole struct.
  - **Departures from the design:**
    - the row states;
    - the message box's padding;
    - the dialog title's size;
    - the sheet's corners;
    - "Edit…";
    - the unified diff's per-line glyph (an open question);
    - the unified diff's added and removed text tint (an open question).
  - **The canonical list:** "The thirty-three rules, each invisible to the compiler:",
    with rules twenty-eight to thirty-three added. Update the surfaces-swept list.
- [ ] Update the per-surface entries:
  - `app-git-views.md`: `CommitDialogView`, `MergeView`, `MergeWindowController`,
    `EscClosableWindow`, `DiffView`, `LocalChangesView` (including the grown check),
    `LogFilterBar`;
  - `app-window.md`: the diff window and the source viewer;
  - `core-local-history.md`: the window and its view;
  - `app-editor.md`: `CodeEditorView`'s pane ground, the whole-word name and the Find in
    Files controller.
- [ ] Update `CLAUDE.md`'s chrome invariant:
  - "and its thirty-three rules" and forty-four gated files;
  - part five (b)'s surfaces added to the swept list;
  - `conflictBackground` spent, leaving two roles unspent, `currentLine` and
    `bracketMatch`, both code zone;
  - the `MergeLineKind.swift` index line added in Task 1.
- [ ] Run `swift test` once more, because the rule-count and canonical-list self-checks
  read these documents.

## Post-Completion

These items need a human and a running app, so they belong to the acceptance review:

- Open the commit dialog, a merge window, a diff window, a Local History window and a
  source viewer in both appearances, and switch the Theme preference while each is open.
  Confirm that the grounds, hairlines, washes, checkboxes and buttons follow.
- Check the commit file row at 200% interface scale for clipping.
- Check the problem browser window's new `bgPanel` ground under its not-yet-swept view
  (decision 8).
- Check that the revert checkbox's 10-point check reads well in the Local Changes panel
  (decision 3).
