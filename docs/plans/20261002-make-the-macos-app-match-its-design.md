# Make the macOS app match its design: one pass over every surface found off

## Overview

A side-by-side check against the design found surfaces that still differ from it:
- wrong glyphs and glyph sizes in the bottom bar, and toggle tooltips that never appear;
- pieces the design draws that the app lacks: the caret readout, the centred window title, the current-line highlight;
- one-off button styles where shared ones exist;
- the Log panel, Local Changes, the commit dialog, Find in Files and Settings laid out differently from the design.

This plan closes all of it in one pass. Every value below is the ticket's own. All sizes are points at interface scale 1.0 and scale exactly as the existing chrome does, except where a task places a measurement in the code zone. Colours are the existing chrome roles, with no new role and no palette value change, except the terminal ground in Task 7.

Decisions made at plan time, so nothing is decided at run time:
- **Glyph provenance.** The glyphs are a new bundled-asset entry. Its `revision` is the full sha256 of the export's `MANIFEST.txt` (`648676f7c95b82ffc54b7f49612108e0258d2e939a924dd713afa367351f2514`). Its provenance record is `Resources/DesignGlyphs/VENDORED.md`. That folder is not listed in `project.yml`'s resources, so it is never bundled. `Vendor/` stays exactly the four tree-sitter grammar packages: `LicenseCoverageTests` treats every `Vendor/` origin as a vendored grammar with its own LICENSE and a 40-hex upstream commit, and this export has neither.
- **Glyph table.** The glyph names live in a new Foundation-only Core enum, `DesignGlyph` (raw value = asset name). It replaces `BottomPanel.systemImage` and is the one name table every surface reads.
- **Encoding.** `FileService` reads and writes UTF-8 only and records no encoding. So the readout's encoding is a single Core constant that `FileService` exposes (`UTF-8`). No per-file field is added.
- **Column counting.** The editor has no existing column counter. The column is the count of grapheme clusters (Swift `Character`s) from the line start to the caret, plus one. A tab counts as one character.
- **Language name.** A file with no `SyntaxLanguage` shows `Plain Text`.
- **Pull-request checks glyph.** Passing checks draw `check` in `statusGreen`; failing checks draw `x` in `statusRed`. A pending or absent state keeps today's SF Symbol, resized to 12. The Pull Requests panel is out of scope and is not changed.
- **Gutter fold glyph.** The gutter is a code-zone surface, so "11" is its size at the default editor font size. It scales with the code font, not the interface scale.
- **Local Changes grouping.** There is one level of grouping: one folder row per distinct parent directory, sorted by path. Root-level files sit under a row showing the project folder name. Every folder starts expanded.
- **Find in Files scope line.** It reads `In: <project> · Exclude: ignored files`. With a file mask set, it reads `In: <project> · Files: <mask> · Exclude: ignored files`.
- **Settings wording.** The rows are labelled "Appearance" (today's Theme row) and "Tab placement" (Top = horizontal, Side = vertical). The editor font family is stored as an optional family name; `nil` means today's system monospaced font.
- **Commit dialog actions.** Clicking the author name still opens the existing author editor. ⌘Return stays on Commit.

## Context

- Files involved (macOS app, `Sources/Pisaka/`):
  - `Assets.xcassets` and a new `Glyphs/` folder inside it
  - `ContentView.swift`, `ProjectSwitcherView.swift`, `BranchSwitcherView.swift`, `PullRequestIndicatorView.swift`
  - `MainWindowChrome.swift`, `PisakaApp.swift`
  - `TabListView.swift`, `TabRowView.swift`, `TabStripView.swift`, `BreadcrumbBarView.swift`, `ProjectTreeView.swift`
  - `LineNumberRulerView.swift`, `BracketOverlayLayoutManager.swift`, `CodeEditorView.swift`
  - `LSPConsentBanner.swift`, `TerminalPanelView.swift`, `TerminalTheme.swift`, `TerminalSession.swift`
  - `CommitLogView.swift`, `LogFilterBar.swift`, `LocalChangesView.swift`, `DiffView.swift`
  - `CommitDialogView.swift`, `CommitUnifiedDiffView.swift`
  - `ProjectSearchView.swift`, `SearchBarView.swift`, `ChromeControls.swift`, `SettingsView.swift`
  - the code-zone font sites: `DiffView`, `MergeView`, `SourceViewerContent`, `CompletionPanel`, `HoverPanel`, `CommitDialogView`, `CommitUnifiedDiffView`, `ProjectSearchView`, `BracketOverlayLayoutManager`
  - a new shared glyph helper file
- Core (`Sources/PisakaCore/`):
  - modified: `BottomPanel.swift`, `SyntaxLanguage.swift`, `FileService.swift`, `SettingsStore.swift`, `CommitDiffUnits.swift`, `ChromeColorRole.swift` (doc comment only), `LicenseNotice.swift` (doc only, if needed)
  - new: `DesignGlyph.swift`, `FileGlyph.swift`, `CaretReadout.swift`, `CurrentLineRule.swift`, `RelativeCommitDate.swift`, `MainWindowTitle.swift`, `TabColumnWidthRule.swift`, `ChangedFileGroups.swift`, `UnifiedDiffDisplayRows.swift`, `SearchScopeLine.swift`
- Resources:
  - `Resources/Licenses/` (new licence text plus a manifest entry)
  - `Resources/DesignGlyphs/VENDORED.md` (new; a provenance record only, not in `project.yml`'s resources, so not bundled)
- Tests:
  - Core: `LicenseCoverageTests`, `BottomPanelTests`, `ChromeThemeSourceGatingTests`, `ZoomSourceGatingTests`, `SettingsStoreTests`, a new `DesignGlyphAssetTests`, and one new Core suite per new Core file
  - app: `ChromePaletteTests`, `TerminalThemeTests`, and new suites in `Tests/PisakaAppTests/`
- Docs: `docs/architecture/core-theme.md`, `app-window.md`, `app-editor.md`, `app-editor-overlays.md`, `app-git-views.md`, `app-terminal.md`, `app-shell.md`, `core-editor.md`, `core-git-models.md`, `core-commit.md`, `core-search.md`, `core-services.md`, `core-zoom.md`, `core-provisioning.md` (consent banner), and CLAUDE.md's index and rule counts.
- Facts found while exploring (master `c812e23e`):
  - `HostedRender` (`Tests/PisakaAppTests/HostedRender.swift`) and `BottomDockLayoutTests`' harness are the two headless measuring patterns.
  - `ChromeThemeSourceGatingTests` gates 60 files with 45 rules. Two other places restate that count, and tests check both: CLAUDE.md ("and its forty-five rules") and `core-theme.md:2356`. "sixty" also appears at `core-theme.md:2124/2175/2275`.
  - Rule 10 counts `Image(systemName:` against `.accessibilityHidden(true)` in the two switchers. Rule 34 requires every chrome glyph to be sized through `metrics`. Rule 37 pins `ChromeMenuField` callers. Rule 44 is the terminal exemption.
  - `ZoomSourceGatingTests`:
    - only `interfaceScaleOwners` may name `interfaceScale`;
    - every font-size `ChromeStepper` in `SettingsView` names its `ZoomScaleRule`;
    - `zoomSurfaceDeclarers` lists every code-font surface.
  - `currentLine` is one of the two unspent roles. `ChromePaletteTests` already holds a rule waiting for it.
  - The asset catalog sets `ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOLS: NO`, so images load by string name. Any imageset under `Sources/Pisaka/Assets.xcassets` is picked up with no `project.yml` change.
  - `LocalChangesModel.groupingMode` is also read by iOS. It stays for iOS; the macOS view stops reading it.
  - `LocalHistoryView` already embeds `DiffView` inline.
  - `SettingsStore` reads `UserDefaults.standard`, so a `-settings.<key> <value>` launch argument lands in the volatile argument domain without writing the user's defaults. Today this works only for string-valued keys. The four numeric reads (`fontSize`, `terminalFontSize`, `interfaceScale`, `markdownPreviewFraction`) are `defaults.object(forKey:) as? Double`, but an argument-domain value arrives as a `String`, so `-settings.interfaceScale 1.8` is silently ignored. Task 14 fixes this, and the Post-Completion live check depends on that fix.
- Dependencies: none new. The glyph PDFs are copied from `~/Documents/pisaka-design-export/icons/`, which is outside the repository. Nothing is downloaded.

## Development Approach

- **Testing approach**: Regular (code first, then tests). For every layout fix: reproduce it in a headless harness, then fix it, then assert.
- Complete each task fully before moving to the next. Each task ends with `swift test`, `swiftlint --strict` and the app-layer bundle green.
- Placement rules:
  - Every decision that can live in Core lives there with tests. SwiftUI and AppKit glue only wires triggers to engines.
  - Every glyph is drawn through the one helper from Task 1.
  - Every chrome measurement goes through `metrics`. Code-zone measurements follow the code font.
- When a gating rule is added or changed, update its suite header inventory and every restated count:
  - CLAUDE.md's "forty-five rules" phrase;
  - `core-theme.md`'s canonical list;
  - its "sixty" mentions, if the gated set changes.
- Accessibility labels and values stay as they are, unless a task removes the control that carries them.
- No product or brand names in code, comments, docs or commit messages. The icon set's name appears only in the licence text and its acknowledgements entry.
- DerivedData always goes outside the repository (`~/Library/Developer/Xcode/DerivedData/pisaka-<purpose>`).
- **Headless rendering must never create a window per sample.** On 2026-10-02 the Task 2 bar suite brought the whole machine's WindowServer down: `HostedRender.matches` builds a fresh `NSWindow` (and so a WindowServer drawing context) inside `swatch(_:ground:)` on every call, and the suite called it once per pixel across a strip — thousands of windows in two minutes, then a watchdog kill of WindowServer. Every app-layer test in this plan follows these rules:
  - `HostedRender`'s reference colours (`swatch`) are computed once per `(role, ground)` and cached for the test process; no sampling helper creates a window, a hosting view or a bitmap per pixel or per row;
  - a test renders its subject once per state and then reads pixels out of that one bitmap;
  - any loop that does create AppKit objects runs inside `autoreleasepool`, and every window a test opens is closed in teardown;
  - a suite that cannot settle within a few seconds is redesigned (host a smaller view), never left to run.
- **CRITICAL: every task MUST include new/updated tests**
- **CRITICAL: all tests must pass before starting next task**

## Implementation Steps

### Task 1: The design's glyphs ship as template vector assets, with their licence and one drawing helper

**Files:**
- Create: `Sources/Pisaka/Assets.xcassets/Glyphs/Contents.json` and one `<name>.imageset/` per glyph (24 of them)
- Create: `Sources/PisakaCore/DesignGlyph.swift`, `Resources/DesignGlyphs/VENDORED.md`, `Resources/Licenses/design-glyphs.txt`
- Create: `Sources/Pisaka/DesignGlyphImage.swift` (the SwiftUI view and the AppKit tinted-image helper)
- Create: `Tests/PisakaCoreTests/DesignGlyphAssetTests.swift`, `Tests/PisakaCoreTests/DesignGlyphTests.swift`
- Modify: `Resources/Licenses/licenses.json`, `Tests/PisakaCoreTests/LicenseCoverageTests.swift`, `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`

- [x] Copy exactly these 24 PDFs from `~/Documents/pisaka-design-export/icons/` into one imageset each:
  - `package`, `git-branch`, `chevron-down`, `chevron-right`, `git-pull-request`, `check`, `terminal`, `file-warning`
  - `git-compare`, `list-checks`, `search`, `git-pull-request-arrow`, `folder`, `folder-open`, `file-code`, `file-text`
  - `database`, `x`, `user-round`, `undo-2`, `refresh-cw`, `case-sensitive`, `whole-word`, `regex`

  Each imageset's `Contents.json` sets `"template-rendering-intent": "template"` and `"preserves-vector-representation": true`. While copying, verify each file's sha256 against its prefix in `MANIFEST.txt`.
- [x] Add `DesignGlyph` to Core: a `String`-backed `CaseIterable` enum with one case per glyph, whose raw value is the asset name. Give it a `nativeSize: Double` column holding each glyph's point size from the manifest (`package` 11, `chevron-down` 11, `refresh-cw` 13, …). Core stays Foundation-only.
- [x] Add the shared helper in the app layer:
  - a SwiftUI `DesignGlyphImage(_ glyph:, slot:, role:)`. It draws the template image at `nativeSize × interface scale`, centred in a `slot × interface scale` square, never stretched, tinted by the role, and `accessibilityHidden(true)`;
  - an AppKit helper that returns the same glyph as an `NSImage` at a given point size and tint, for drawing in AppKit views. Per rule 25, the caller resolves the tint inside the drawing appearance.
- [x] Copy `LICENSE.txt` verbatim to `Resources/Licenses/design-glyphs.txt`. Add a `licenses.json` entry with:
  - id `design-glyphs`, and the icon set's name in `name`;
  - origin `Sources/Pisaka/Assets.xcassets/Glyphs`, version `null`;
  - revision = the MANIFEST sha256 above, spdx `ISC AND MIT`.

  Write `Resources/DesignGlyphs/VENDORED.md`. Do not add the folder to `project.yml`: it is a record, not a resource. It records:
  - the export source and date, and the glyphs taken, with their manifest prefixes and sizes;
  - that the revision is the manifest's digest, because the export carries no upstream commit;
  - which of the shipped glyphs fall under the MIT notice;
  - the by-hand update procedure.
- [x] Extend `LicenseCoverageTests` with a fourth origin shape, the asset-catalog glyph folder:
  - `testEveryEntryHasARemoteVendoredOrBundledOrigin` accepts exactly the origin `Sources/Pisaka/Assets.xcassets/Glyphs` as the fourth shape, and its message names four shapes. The `Vendor/` tests are unchanged and still select only the four grammars.
  - Directory listing check: that one entry must acknowledge every imageset in the glyph folder.
  - Provenance check: the entry's revision must equal the digest recorded in `Resources/DesignGlyphs/VENDORED.md`, and its `version` must agree with that record (`null`).
  - Update the suite's doc comment inventory.
- [x] `DesignGlyphAssetTests` (reads files through `#filePath`; Foundation and Core `SHA256` only):
  - the set of imagesets equals `DesignGlyph.allCases`;
  - each PDF's sha256 prefix equals a table pinned in the suite;
  - each `Contents.json` carries the template intent and preserved vector data;
  - each `nativeSize` equals the manifest size recorded in `Resources/DesignGlyphs/VENDORED.md`.
- [x] Add a new `ChromeThemeSourceGatingTests` rule: design glyphs are drawn only through the helper. No macOS source outside the helper file may contain an `Image("` or `NSImage(named:` that names a glyph; `AppIcon` stays exempt. Add the helper file to the gated set. Teach rules 10 and 34 that a `DesignGlyphImage(` counts as a sized, accessibility-hidden glyph. Bump every restated rule and file count.
- [x] Run `xcodegen generate`, `swift test`, `swiftlint --strict` and the app-layer bundle (must pass).

### Task 2: The bottom bar draws the design's glyphs at the design's sizes

**Files:**
- Modify: `Sources/PisakaCore/BottomPanel.swift`, `Tests/PisakaCoreTests/BottomPanelTests.swift`
- Modify: `Sources/Pisaka/ContentView.swift`, `ProjectSwitcherView.swift`, `BranchSwitcherView.swift`, `PullRequestIndicatorView.swift`
- Modify: the checks-summary type in Core (add the indicator's glyph column)
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift` (rule 10's glyph counting)
- Create: `Tests/PisakaAppTests/BottomBarLayoutTests.swift`

- [x] Replace `BottomPanel.systemImage` with `BottomPanel.glyph: DesignGlyph`:
  - Terminal → `terminal`
  - Log → `list-checks`
  - Local Changes → `git-compare`
  - Problems → `file-warning`
  - Usages → `search`
  - Pull Requests → `git-pull-request-arrow`

  It stays the one table the bar reads. Update `BottomPanelTests` (six unique glyphs) and the doc comment.
- [x] Left group: 14 between widgets, 4 inside each.
  - Project switcher: `package` 12 in `textSecondary`, then the project name at 12 regular in `textPrimary`, then `chevron-down` 10 in `textSecondary`. Remove the old folder glyph and large chevron.
  - Branch switcher: `git-branch` 12, then the branch name at 12 regular in `textSecondary`, then `chevron-down` 10.
  - Pull-request indicator: `git-pull-request` 12, then `#number` at 12 in `textSecondary`, then the checks glyph at 12. Passing draws `check` in `statusGreen`; failing draws `x` in `statusRed`. Any other state keeps today's symbol, sized 12. The choice is a Core column on the checks summary, with tests. The Pull Requests panel's own column is not changed.
  - 12-point text is the `callout` style.
- [x] Right group: gap 2. Each toggle is 22×22 with radius 4 and shows its panel's glyph at 13.
  - The active toggle draws `accent` on `accentTint`, replacing `accentTintStrong`.
  - Inactive toggles draw `textSecondary`.
  - The completion toggle keeps its SF Symbols, sized to 13, with the same active and inactive colours.
- [x] Keep rule 10's structure: `allCases`, `.help(` and `.accessibilityLabel(`, and switchers whose glyphs are all hidden from accessibility. Update its glyph counting for `DesignGlyphImage(`.
- [x] First, make `HostedRender.swatch(_:ground:)` cached per `(role, ground)` so that repeated `matches`/`extent` calls create no further windows, and add an app-layer test that calls `matches` thousands of times for one role and asserts the number of windows the app holds afterwards is no greater than before plus one (count `NSApp.windows` with their window numbers, after an `autoreleasepool` drain). Rework the bar suite's pixel scans to read one captured bitmap.
- [x] Headless tests on `ContentView`'s bar, using the `BottomDockLayoutTests` harness pattern, at scale 1.0 and 1.8:
  - widget gaps of 14 and toggle gaps of 2;
  - 22-point toggle squares;
  - the active toggle's ground samples as `accentTint`.

  Measure through probes or the bitmap. If a test-only seam is unavoidable, state why in the suite header.
- [x] Run the gates (must pass).

### Task 3: The bottom bar's tooltips actually appear

**Files:**
- Modify: `Sources/Pisaka/ContentView.swift`, plus whatever files the diagnosis names (e.g. `PisakaApp.swift`, `MainWindowChrome.swift`, `ZoomController.swift`)
- Create or modify: an app-layer suite pinning the chosen mechanism
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift` (rule 10, if the mechanism changes)

- [x] Reproduce headlessly: host the bar in a titled window, as the dock harness does, and inspect what a toggle registers for its tooltip. Find why `.help` never shows. Candidate causes:
  - the bar's `.zIndex(1)` layering;
  - the transparent title bar;
  - the hit-transparent background views;
  - the window never becoming key in that state.

  Record the cause in `app-window.md`.
- [x] If the cause can be fixed so that `.help` shows, fix it at the cause; that fix then covers every `.help` in the window. Otherwise, give each panel toggle and the completion toggle an AppKit backing view and set its `toolTip`:
  - a panel toggle shows `panel.title`;
  - the completion toggle shows `Code completion: On` or `Code completion: Off`.

  Accessibility labels and values do not change.
- [x] Pin it:
  - an app-layer test asserts that every toggle exposes its tooltip text through the chosen mechanism. For the AppKit path, a walk of the view hierarchy finds a view with that `toolTip`;
  - update rule 10 so it requires the mechanism actually used.
- [x] Run the gates (must pass).

### Task 4: The caret readout

**Files:**
- Create: `Sources/PisakaCore/CaretReadout.swift`, `Tests/PisakaCoreTests/CaretReadoutTests.swift`
- Modify: `Sources/PisakaCore/SyntaxLanguage.swift` (`displayName`), `Sources/PisakaCore/FileService.swift` (the encoding name constant), `Tests/PisakaCoreTests/SyntaxLanguageTests.swift`
- Modify: `Sources/Pisaka/CodeEditorView.swift` (publish the caret offset), `Sources/Pisaka/ContentView.swift`

- [x] Add `SyntaxLanguage.displayName` with these values:
  - Swift, JavaScript, TypeScript, JSON, Markdown, Python, Go, Rust, HTML, CSS
  - YAML, Dockerfile, Dotenv, Gitignore, SQL, EditorConfig, Shell

  `FileService` exposes the name of the one encoding it reads with: `UTF-8`.
- [x] Add `CaretReadout.text(text: NSString, caretOffset: Int, language: SyntaxLanguage?, encodingName: String) -> String`. It produces `Ln <line>, Col <column> · <encoding> · <language>`:
  - line is 1-based, with lines split by `LineStartIndex` (all six separators);
  - column is 1-based, counted in grapheme clusters from the line start;
  - language is `Plain Text` when there is none;
  - an offset beyond the text clamps to the end.
- [x] On every selection change, the editor's coordinator publishes the caret's UTF-16 offset for the focused tab only. It uses the selection's caret end, so a selection still shows the caret. The readout sits after the toggles with a 10-point gap, at 11 regular (`subheadline`) in `textSecondary`. It is empty when no text tab is focused, for example a database viewer tab or no tab at all.
- [x] Tests:
  - ASCII, CRLF, NEL/LS/PS, emoji and combining-mark columns;
  - first line and last line;
  - a caret at the end of a line with no terminator;
  - every `displayName`;
  - an app-layer check that the readout lands 10 points after the last toggle.
- [x] Remove "caret readout" from `core-theme.md`'s waiting items.
- [x] Run the gates (must pass).

### Task 5: Centred window title and the vertical tab column

**Files:**
- Create: `Sources/PisakaCore/MainWindowTitle.swift`, `Sources/PisakaCore/TabColumnWidthRule.swift` and their tests
- Modify: `Sources/Pisaka/MainWindowChrome.swift`, `PisakaApp.swift` (wiring), `ContentView.swift`, `TabListView.swift`, `TabRowView.swift`
- Modify: `Tests/PisakaAppTests/MainWindowChromeTests.swift`; create `Tests/PisakaAppTests/TabColumnLayoutTests.swift`

- [x] `MainWindowTitle.text(projectRoot:focusedFileName:)` returns:
  - `<project folder name> — <file name>`;
  - just the project name when no file is focused;
  - the app's existing default when no project is open.

  `MainWindowChrome` applies it and stays the only configurer; rule 9 stays green. The title is visible and centred, and the title bar stays transparent.
- [x] Vertical tab column:
  - default width 220;
  - no top padding: the first row sits flush under the title bar;
  - rows 28 high, each with a one-point `hairline` rule along its bottom;
  - the selected row's ground does not change.

  `TabColumnWidthRule` returns the scaled minimum and ideal width, and a maximum of `min(scaled maximum, window width / 3)`. The view reads the window width once from its geometry.
- [x] Tests:
  - Core: the title strings, and the width rule at scale 1.0 and 1.8 against narrow and wide windows;
  - app-layer: the window title text, the first row's top offset of 0 under the title bar, row height 28, and the hairline sampled at each row's bottom.
- [x] Run the gates (must pass).

### Task 6: The current-line highlight

**Files:**
- Create: `Sources/PisakaCore/CurrentLineRule.swift`, `Tests/PisakaCoreTests/CurrentLineRuleTests.swift`
- Modify: `Sources/Pisaka/BracketOverlayLayoutManager.swift`, `LineNumberRulerView.swift`, `CodeEditorView.swift`, `Sources/PisakaCore/ChromeColorRole.swift` (doc: `currentLine` spent), `Tests/PisakaAppTests/ChromePaletteTests.swift`
- Create: `Tests/PisakaAppTests/CurrentLineHighlightTests.swift`

- [x] `CurrentLineRule.highlightedLine(selection:lineStarts:)` returns the UTF-16 range of the line holding the caret. It returns `nil` when the selection spans more than one line; a selection within one line still highlights.
- [x] In the layout manager's background pass, after the indent-level pass and before `super`, paint that line full width in `currentLine`. Paint the same line's band in the gutter ruler. Redraw on selection change. Resolve both colours inside the drawing appearance (rule 25).
- [x] Mark `currentLine` as spent in `ChromeColorRole`'s comment and in `core-theme.md`, and enable `ChromePaletteTests`' waiting rule.
- [x] Tests:
  - Core rule cases: caret only, a single-line selection, a multi-line selection, the last line, and an empty document;
  - app-layer (`EditorLayoutHarness`): the caret line's text area and gutter sample as `currentLine`, a neighbouring line does not, and a multi-line selection paints no tint.
- [x] Run the gates (must pass).

### Task 7: Consent banner buttons and the terminal panel

**Files:**
- Modify: `Sources/Pisaka/LSPConsentBanner.swift`, `TerminalPanelView.swift`, `TerminalTheme.swift` / `TerminalSession.swift`
- Modify: `Tests/PisakaAppTests/TerminalThemeTests.swift`, `ChromeThemeSourceGatingTests` (rule 30's callers and rule 44, if their text changes)

- [x] The banner's accept button uses `.chromePrimary` and its decline button `.chromeSecondary`. Delete `acceptButton` and `declineButton`, and rewrite the banner's `core-theme.md` entry.
- [x] The terminal view sits inside its panel with a 14-point inset on the left and right, scaled with the interface. The terminal's ground is `bgPanel`, the role the dock slot paints. Per rule 44's exemption, it is resolved for the current appearance and handed to the terminal as a concrete colour. The inset is painted the same colour, so the panel reads as one surface.
- [x] Tests:
  - `TerminalThemeTests` asserts the background equals the resolved `bgPanel` in both appearances;
  - an app-layer test measures the 14-point inset at scale 1.0 and 1.8;
  - rule 30's caller list covers the banner's buttons.
- [x] Run the gates (must pass).

### Task 8: File and folder glyphs in the tree, tabs, breadcrumb and gutter

**Files:**
- Create: `Sources/PisakaCore/FileGlyph.swift`, `Tests/PisakaCoreTests/FileGlyphTests.swift`
- Modify: `Sources/Pisaka/ProjectTreeView.swift`, `TabRowView.swift`, `TabStripView.swift` (`TabFileIcon`, `TabStatusMark`), `BreadcrumbBarView.swift`, `LineNumberRulerView.swift`
- Modify: `Tests/PisakaAppTests/GutterFoldTests.swift`, `ChromeThemeSourceGatingTests` (rule 8, the tab icon rule)

- [x] `FileGlyph.forFile(named:) -> DesignGlyph` returns one of three answers:
  - `database` when `DatabaseFileRule.isDatabaseFile(named:)`;
  - `file-text` for no `SyntaxLanguage`, and for `markdown`, `gitignore`, `dotenv` and `editorconfig`;
  - `file-code` for every other language.

  `FileGlyph.forFolder(expanded:)` returns `folder-open` or `folder`. `FileIcon` is not changed, for iOS.
- [x] Project tree:
  - a folder row draws its disclosure chevron at 12 (`chevron-down` when expanded, `chevron-right` when collapsed; no rotation), then its folder glyph at 14;
  - a file row draws its file glyph at 14;
  - all glyphs are `textSecondary`.
- [x] Tabs, horizontal and vertical: the file glyph at 13, and the close glyph is `x` at 12.
- [x] Breadcrumb: separators are `chevron-right` at 10.
- [x] Gutter fold control:
  - `chevron-down` for an expanded block and `chevron-right` for a collapsed one;
  - drawn at `11 × codeFontSize / SettingsStore.defaultFontSize` (code zone), centred in the existing fold column;
  - the click target does not change.
- [x] Tests:
  - `FileGlyphTests` covers every `SyntaxLanguage` case through `allCases`, the database extensions, unknown files and folders;
  - `GutterFoldTests` covers the glyph slot at two code font sizes;
  - app-layer tree row rendering finds a glyph in the 12- and 14-point slots at scale 1.0 and 1.8.
- [x] Run the gates (must pass).

### Task 9: Log panel

**Files:**
- Create: `Sources/PisakaCore/RelativeCommitDate.swift`, `Tests/PisakaCoreTests/RelativeCommitDateTests.swift`
- Modify: `Sources/Pisaka/CommitLogView.swift`, `LogFilterBar.swift`, `ChromeThemeSourceGatingTests` (rules 20/21, if they name the header)

- [x] Remove the "History" header row. The refresh button (with its label and help) and the loading spinner move to the trailing end of the filter strip.
- [x] Columns, in order: the graph gutter (unchanged, leading), then Message, Author, Date, Hash. The hash is last, monospaced, in `textSecondary`. The column header follows the same order.
- [x] `RelativeCommitDate.text(for:now:calendar:locale:)`:
  - `just now` under a minute;
  - `Nm ago` under an hour;
  - `Nh ago` under 24 hours on the same day;
  - `Yesterday` on the previous calendar day;
  - `N days ago` for 2–6 days;
  - a short date beyond that (`MMM d`, plus `, yyyy` in another year), formatted with the injected locale.

  It parses the raw `%aI` string and returns that raw string when parsing fails. The row's tooltip is the exact date and time.
- [x] Tests:
  - every boundary, with fixed `now`, calendar, time zone and the `en_US_POSIX` locale;
  - midnight crossings;
  - future dates;
  - unparsable input.
- [x] Run the gates (must pass).

### Task 10: Local Changes panel

**Files:**
- Create: `Sources/PisakaCore/ChangedFileGroups.swift`, `Tests/PisakaCoreTests/ChangedFileGroupsTests.swift`
- Modify: `Sources/Pisaka/LocalChangesView.swift`, `ChromeThemeSourceGatingTests` (rules 17/20/35, where they name the removed toggle or row shape)
- Create: `Tests/PisakaAppTests/LocalChangesLayoutTests.swift`

- [ ] Toolbar at the leading edge:
  1. "Commit…" in `.chromePrimary`;
  2. the revert icon button (`undo-2`, 15);
  3. the refresh icon button (`refresh-cw`, 15).

  Each keeps its help and accessibility label. Remove the list/tree segmented control from the macOS view. `groupingMode` stays in Core for iOS.
- [ ] `ChangedFileGroups.group(_ files:, rootName:)` returns one group per parent directory, sorted by path, with files sorted by name. Root-level files go under a group labelled `rootName`.
  - The list defaults to 320 wide.
  - A folder row shows the disclosure chevron, the folder glyph and the path. Folders start expanded.
  - A file row is indented beneath its folder and shows the checkbox, then the status letter (M/A/D/R/C/U in its status colour), then the name.
- [ ] To the right of the list, embed `DiffView` for the selected file, headed by its project-relative path:
  - rows come from `localChanges.rows(for:)`, ordered by a generation token captured before the hop, so a superseded selection never publishes;
  - with no selection, show an empty state;
  - double-click and ⌘D still open the diff window.
- [ ] Tests:
  - grouping: nested paths, root files, renames, and stable ordering;
  - app-layer: the list's default width of 320, the toolbar order, and the status letter left of the name.
- [ ] Run the gates (must pass).

### Task 11: Commit dialog layout and footer

**Files:**
- Modify: `Sources/Pisaka/CommitDialogView.swift`, `ChromeThemeSourceGatingTests` (rules 30/33, for the new rows and buttons)
- Modify: `Sources/PisakaCore/CommitDialogModel.swift` only if commit-and-push needs a new entry point (with tests)
- Create: `Tests/PisakaAppTests/CommitDialogLayoutTests.swift`

- [ ] From top to bottom:
  1. the "Commit Changes" header, 44 high (`dialogEdgeStripHeight`);
  2. the commit message box: full width, 20 padding around it, about 68 high, in the code font as today;
  3. the file list, 260 wide, beside the diff;
  4. the 64-high footer.
- [ ] File rows show the checkbox, then the status letter, then the name over its folder.
- [ ] Footer:
  - left: the `user-round` glyph at 13, then the author name (clicking it opens the existing author editor), then the Amend checkbox;
  - right: Cancel (secondary), Commit (secondary, ⌘Return), and Commit and Push (primary).

  Remove the "Push after commit" checkbox. Commit and Push commits and then runs the existing push plan. It is disabled in exactly the cases where push was unavailable before, and its tooltip is the push target text (`pushText`). Amend's committer and its "keeps the original author" note stay in the author's tooltip.
- [ ] Tests:
  - app-layer, at scale 1.0 and 1.8: header height 44, message box padding 20, list width 260, footer height 64, and the button order with Commit and Push as the primary;
  - Core: tests for any model change.
- [ ] Run the gates (must pass).

### Task 12: The unified diff's header lines and tinted text

**Files:**
- Create: `Sources/PisakaCore/UnifiedDiffDisplayRows.swift`, `Tests/PisakaCoreTests/UnifiedDiffDisplayRowsTests.swift`
- Modify: `Sources/Pisaka/CommitUnifiedDiffView.swift`, `Tests/PisakaAppTests/CommitUnifiedDiffWashTests.swift`, `ChromeThemeSourceGatingTests` (rule 19)

- [ ] `UnifiedDiffDisplayRows.rows(for:)` returns, per file, `--- a/<path>` and `+++ b/<path>` header rows (`/dev/null` for an added or deleted file). Each hunk then gets an `@@ -a,b +c,d @@` row followed by its lines.
  - `CommitDiffUnits` and `PartialCommitBuilder` are not changed.
  - Header rows carry no checkbox and cannot be selected.
- [ ] Added lines' text draws in `statusGreen` and removed lines' text in `statusRed`, on top of their existing washes. Context text keeps the plain code colour, and the two line-number columns stay. This closes open question 7 in `core-theme.md`.
- [ ] Tests:
  - Core: hunk header numbers for added, removed, mixed and multiple hunks, and for new or deleted files;
  - app-layer: extend the wash suite to sample tinted text pixels on added and removed rows, with header rows present.
- [ ] Run the gates (must pass).

### Task 13: Find in Files and the find bar's toggles

**Files:**
- Create: `Sources/PisakaCore/SearchScopeLine.swift`, `Tests/PisakaCoreTests/SearchScopeLineTests.swift`
- Modify: `Sources/Pisaka/ProjectSearchView.swift`, `SearchBarView.swift`, `ChromeControls.swift` (`ChromeQueryToggle` takes a glyph)
- Create: `Tests/PisakaAppTests/ProjectSearchLayoutTests.swift`

- [ ] Each file's group header shows the file glyph (`FileGlyph`), the project-relative path in `textSecondary`, and `N matches` (`1 match` for one) at the trailing edge. Match lines sit directly beneath, indented 34, each with its hit highlighted as today.
- [ ] Under the fields, show the scope line from `SearchScopeLine.text(projectName:fileMask:)` in `callout` `textSecondary`. The file-mask field stays.
- [ ] Replace All sits at the trailing end of the replace field's row.
- [ ] `ChromeQueryToggle` draws a `DesignGlyph` at 16 (`case-sensitive`, `whole-word` and `regex`) in both Find in Files and the in-editor find bar. Help and accessibility stay.
- [ ] Tests:
  - Core: the scope line with a mask, without one, and with an empty mask;
  - app-layer, at scale 1.0 and 1.8: the 34-point match indent, Replace All's trailing position, and the toggle glyph slots.
- [ ] Run the gates (must pass).

### Task 14: Settings and the editor font family

**Files:**
- Modify: `Sources/PisakaCore/SettingsStore.swift`, `Tests/PisakaCoreTests/SettingsStoreTests.swift`
- Create: `Sources/Pisaka/EditorFont.swift` (the one resolver of the code font)
- Modify: `Sources/Pisaka/SettingsView.swift`, and every code-zone font site: `CodeEditorView`, `DiffView`, `MergeView`, `SourceViewerContent`, `CompletionPanel`, `HoverPanel`, `CommitDialogView`, `CommitUnifiedDiffView`, `ProjectSearchView`, `BracketOverlayLayoutManager`, `LineNumberRulerView`, `MinimapView` (wherever the editor font is built today; confirm by grepping for `monospacedSystemFont`)
- Modify: `Tests/PisakaCoreTests/ZoomSourceGatingTests.swift` (the interface-scale stepper pair, `SettingsView` in `interfaceScaleOwners`, and a new rule that only `EditorFont` and the terminal build a monospaced system font), `ChromeThemeSourceGatingTests` (rule 37's pinned callers)

- [ ] `SettingsStore.editorFontFamily: String?` is persisted under `settings.editorFontFamily`, defaults to `nil`, and treats an empty string as `nil`. Tests cover the default, round-trip, clearing and the launch-argument override.
- [ ] Every numeric `SettingsStore` read also accepts the argument-domain string form. This covers `fontSize`, `terminalFontSize`, `interfaceScale` and `markdownPreviewFraction`, plus any other `Double`/`Int` key the store reads (there is none today).
  - A stored number reads exactly as today.
  - A `String` that parses as a finite `Double` is used, through the same clamp as today.
  - An absent or unparsable value falls back exactly as today.
  - One small private helper does the read for all four keys. Reading never writes anything back to the defaults.

  Tests: for each key, a string value placed in a volatile argument domain (`setVolatileDomain(_:forName: UserDefaults.argumentDomain)` on a suite-backed `UserDefaults`) is honoured. One more test checks that an unparsable string falls back to the default.
- [ ] `EditorFont.font(size:family:)` returns the named family when it is installed and fixed-pitch, and otherwise today's system monospaced font. Every code-zone site builds its font through it and updates live when the setting changes. The terminal keeps its own font.
- [ ] The General tab, in this order:
  1. Appearance (System / Light / Dark);
  2. Tab placement (Top / Side);
  3. Editor font: a `ChromeMenuField` listing installed fixed-pitch families (from `NSFontManager`), with "System Monospaced" first, then the size stepper;
  4. Interface zoom: a `ChromeStepper` over `$settings.interfaceScale` with `ZoomScaleRule.interfaceScale`, formatted as a percentage;
  5. Terminal font size;
  6. Completion;
  7. Indent guides.
- [ ] Tests:
  - the Core store tests;
  - the zoom gating updates;
  - an app-layer test that `EditorFont` falls back for an unknown family and honours an installed fixed-pitch one.
- [ ] Run the gates (must pass).

### Task 15: Departures recorded and the documentation sweep

**Files:**
- Modify: `docs/architecture/core-theme.md` and every architecture doc named in Context

- [ ] Write each deliberate departure into `core-theme.md`'s departures:
  - the Log's richer filters and ref badges;
  - the terminal's session strip;
  - Find in Files' orange current match (already recorded; confirm);
  - blame behind its per-file toggle;
  - the unified diff's two line-number columns;
  - the dock's six tabs and single close button (already recorded; confirm).
- [ ] Every changed and new file has an entry describing its new behaviour, in the doc CLAUDE.md names for it. Add the new Core files to CLAUDE.md's index lines. Grep the docs and make sure no sentence still describes:
  - the old glyphs, the History row or the list/tree toggle;
  - the push checkbox or the label-only query toggles;
  - an unspent `currentLine`, or the deferred caret readout.
- [ ] Run `swift test`; `LintConfigurationTests` keeps CLAUDE.md under 60,000 characters (must pass).

### Task 16: Verify acceptance criteria

- [ ] `swift test` passes.
- [ ] `swiftlint --strict` from the repository root is clean.
- [ ] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' test` passes, with DerivedData outside the repository.
- [ ] The macOS Release build and the iOS build (`generic/platform=iOS`) succeed.
- [ ] Gating counts and inventories agree across the suites, `core-theme.md` and CLAUDE.md.

### Task 17: Update documentation

- [ ] README.md and `docs/FEATURES.md`: mention the caret readout, the editor font family setting, the inline diff in Local Changes, and Commit and Push.
- [ ] CLAUDE.md, kept under the size bound:
  - the index names for the new files, and the rule and file counts;
  - the new glyph asset class under Conventions: licence, pin suite, and provenance in `Resources/DesignGlyphs/VENDORED.md`, which is not bundled;
  - the `Vendor/` paragraph still names the four grammar packages and nothing else;
  - the `Resources/` paragraph names the unbundled `DesignGlyphs/` record.

## Post-Completion

Manual live check, not automated:
- Use a Debug build with DerivedData outside the repository.
- Capture windows only with `screencapture -l <windowID>`.
- Pass settings as launch arguments (`-settings.interfaceScale 1.8`, and so on); never write them to defaults. Numeric arguments take effect only because of Task 14's string-form reads.
- Check at interface scale 1.0 and 1.8.

What to check:
- Every numbered item of the ticket is visible.
- Each bottom-bar toggle shows its tooltip within the system delay.
- The glyphs ship on iOS too, because the asset catalog is shared, even though iOS draws none of them. This is accepted and not addressed here.
