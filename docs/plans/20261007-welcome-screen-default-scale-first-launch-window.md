# Welcome screen, 150% default interface scale, large first-launch window (macOS)

## Overview

Three changes ship together in one PR:

1. The interface zone's resting scale changes from 1.0 to 1.5. The guarantee that scale 1.0 draws exactly as today stays.
2. A main window with no saved frame opens centred, at about 75% of the active screen's visible frame. A pure Core rule decides this.
3. A Welcome screen replaces the tree + editor split when no folder is open and no tab is open. It has four parts: a header (icon, name, version), an actions column, a recent-projects column, and a footer of key shortcuts. Every footer entry is a command that is enabled with no folder open. Every decision the screen depends on lives in Core.

The empty-state captions stay in the states the Welcome screen does not own:

- "Click to open a folder" still shows in the tree when files are open without a folder.
- "No file open" still shows in the editor when a folder is open with no tab.

The Welcome state no longer reaches either caption, because the whole split is replaced. iOS is untouched.

## Context

- Zoom and scale: `Sources/PisakaCore/ZoomScaleRule.swift`, `InterfaceMetrics.swift`, `SettingsStore.swift`, `Sources/Pisaka/SettingsView.swift`, `docs/architecture/core-zoom.md`, `Tests/PisakaCoreTests/InterfaceMetricsTests.swift`, `SettingsStoreTests.swift`.
  - SettingsView has the Interface zoom stepper. There is no separate Preferences reset button, so "the reset" means ⌘0 over the chrome and `SettingsStore`'s per-zone reset.
- Window frame: `Sources/Pisaka/MainWindowFrameAutosave.swift`, `MainWindowFrameSourceGatingTests`, `docs/architecture/app-shell.md`.
  - `MainWindowFramePersistence.restore` returns early when the `MainWindowFrame` key is missing. The first-launch frame goes there.
- Window layout, in `Sources/Pisaka/ContentView.swift`:
  - `mainArea` / `editorSplit`.
  - The window floor, `.frame(minWidth: metrics.scaled(640), minHeight: metrics.scaled(400))`.
  - The "No file open" branch.
  - The `bgCanvas` window-ground comment.
- Tree placeholder: `Sources/Pisaka/ProjectTreeView.swift`.
- Menu commands in `Sources/Pisaka/PisakaApp.swift`:

  | Menu title | Calls | Chord |
  |---|---|---|
  | New File | `model.newFile()` | ⌘N |
  | Open… | `openFile()` | ⌘O |
  | Open Folder… | `openFolder()` | ⇧⌘O |
  | `Button(bottomPanel == .terminal ? "Hide Terminal" : "Show Terminal")` | — | ⇧⌘T |
  | Zoom In (first item) | — | ⌘= |
  | Zoom In (second item) | — | ⌘+ |
  | Zoom Out | — | ⌘- |
  | Reset Zoom | — | ⌘0 |

  - Two commands carry `.disabled(model.projectRoot == nil)`, Find in Files among them.
  - `recentProjectRows()` and `onOpenRecentProject: { openFolder(url: $0) }`.
- LeetCode menu in `Sources/Pisaka/LeetCodeOpenProblemSheet.swift`: "Open Problem…" (⌥⌘P) and "Browse Problems…" (⇧⌘B). Both are gated on nothing.
- Recents: `Sources/PisakaCore/RecentProject.swift`. `RecentProject.rows` is in MRU order and already excludes missing folders.
- Keyboard selection precedent: `Sources/PisakaCore/PopoverSelection.swift`.
- Theme and glyphs:
  - `ChromeColorRole.swift`, `ChromePalette.swift`, `DesignGlyph.swift`, `DesignGlyphImage.swift`, and the assets in `Assets.xcassets/Glyphs/`.
  - `Resources/DesignGlyphs/VENDORED.md` records eight untaken glyphs, `plus` among them. The export is at `~/Documents/pisaka-design-export/icons/`.
  - `DesignGlyphAssetTests`, `LicenseCoverageTests`.
- Gating suites:
  - `ChromeThemeSourceGatingTests` pins its file set by set equality, with "sixty-two" written in its header, in `core-theme.md` and in CLAUDE.md.
  - `ZoomSourceGatingTests`: the Welcome view sits under ContentView's existing interface root.
  - `MenuShortcutUniquenessTests`.
- Fixed frames that overflow a 1440×900 screen at 1.5:
  - Commit dialog (`CommitDialogView.swift`): min 1350×840, ideal 1500×960.
  - LeetCode login sheet (`LeetCodeLoginView.swift`): ideal 1140×1170.
  - Every other scaled frame fits, including the window floor at 960×600.
- App-layer bitmap tests: `Tests/PisakaAppTests` with `HostedRender`.
- Docs: `app-window.md`, `core-zoom.md`, `core-theme.md`, `core-services.md`, `app-shell.md`, and CLAUDE.md (about 51.4k characters; the limit is 60,000).
- Dependencies: none new.

## Development Approach

- **Testing approach**: Regular (code first, then tests). Core rules are unit-tested in `swift test`.
- Complete each task fully before moving to the next.
- Every decision lives in `PisakaCore`, and the app layer only wires it up. Read a file's `docs/architecture/` entry before editing it, and update that entry in the same task.
- Gating suites match against comment- and literal-stripped text, or against comment-stripped text with literals kept where the rule's subject is a literal; that exception is stated in the suite's doc comment. They prefer set equality, and their doc-comment inventories are updated.
- **CRITICAL: every task MUST include new/updated tests**
- **CRITICAL: all tests must pass before starting next task**

## Implementation Steps

### Task 1: Interface scale defaults to 1.5

**Files:**
- Modify: `Sources/PisakaCore/ZoomScaleRule.swift`, `Sources/PisakaCore/SettingsStore.swift` (doc comments), `Sources/Pisaka/SettingsView.swift` (comment wording), `docs/architecture/core-zoom.md`
- Modify: `Tests/PisakaCoreTests/InterfaceMetricsTests.swift`, `Tests/PisakaCoreTests/SettingsStoreTests.swift`, and any other test pinning the 1.0 default (grep `interfaceScale.defaultValue`)

- [x] Set `ZoomScaleRule.interfaceScale` to `defaultValue: 1.5`. Range 0.8–2.0 and step 0.1 stay. Rewrite the doc comment to say three things:
  - 1.5 is the resting value.
  - 1.0 is "unscaled", and `InterfaceMetrics.unscaled` still returns every base size identically.
  - The step grid still contains 1.0.
- [x] Keep `InterfaceMetrics.unscaled` and the environment default at 1.0. Only the store's missing-key fallback and the reset resolve to 1.5.
- [x] In `core-zoom.md`, reword the "unchanged at 100%" guarantees as "at scale 1.0", and record why the default was reversed deliberately.
- [x] Tests:
  - The default is 1.5.
  - `InterfaceMetrics(scale: 1.0) == .unscaled`, and every base size at 1.0 is identical.
  - A missing key reads 1.5.
  - A stored 1.0 (or any other stored value) is preserved.
  - The interface reset returns 1.5; the code and terminal resets still return 13.
  - From 1.5, five steps down land exactly on 1.0, and five steps back up land exactly on 1.5.
- [x] Run `swift test`; it must pass.

### Task 2: Surfaces that overflow at 1.5 fit the screen

**Files:**
- Create: `Sources/PisakaCore/ScaledFrameFitRule.swift`, `Tests/PisakaCoreTests/ScaledFrameFitRuleTests.swift`
- Modify: `Sources/Pisaka/CommitDialogView.swift`, `Sources/Pisaka/LeetCodeLoginView.swift`, and the app-layer commit dialog layout test if it pins the ideal size

- [x] Re-audit every `metrics.scaled(N)` min, ideal and fixed frame (macOS) at 1.5 against a 1440×900 screen (visible area ≈ 1440×875). Record the audit table in `core-zoom.md`.
- [x] Add a pure rule. It takes a scaled min, a scaled ideal and the available size, and returns a min/ideal pair:
  - Both values are capped to the available size.
  - The min never exceeds the ideal.
  - At 1.0 on an ordinary screen, the input comes back unchanged.
- [x] Apply the rule in the two sheets, using the visible frame of the main window's screen and falling back to `NSScreen.main`.
- [x] Tests:
  - A size that fits comes back unchanged.
  - Each axis is capped separately.
  - The min never exceeds the ideal.
  - At 1.0, a 1440×900 screen gives back the input.
  - Both offenders at 1.5 come back inside 1440×875.
- [x] Run `swift test` and the app test bundle; both must pass. (`swift test` green, 6100 tests. App bundle: 236/244 pass. The 8 failures are scale-1.8 bitmap assertions in BottomBarLayout, BottomBarToolTip, ChromePopoverLayout and CommitDialogLayout. They fail identically at 0367c7f, before any of this branch's work, so they come from the host and not from this change.)

### Task 3: First-launch window frame rule

**Files:**
- Create: `Sources/PisakaCore/MainWindowInitialFrameRule.swift`, `Tests/PisakaCoreTests/MainWindowInitialFrameRuleTests.swift`
- Modify: `Sources/Pisaka/MainWindowFrameAutosave.swift`, `Sources/Pisaka/ContentView.swift` (pass the scaled content minimum to the marker), `Tests/PisakaCoreTests/MainWindowFrameSourceGatingTests.swift`, `docs/architecture/app-shell.md`

- [x] Add a pure rule: visible frame + minimum frame size → frame.
  - The size is 75% of the visible frame on each axis.
  - It is raised to the minimum, then capped to the visible frame.
  - The frame is centred in the visible frame and keeps the visible frame's origin.
- [x] Apply it in `restore` only when the key is missing:
  - Convert the content minimum to a frame size with `frameRect(forContentRect:)`.
  - Ask the rule, passing `(window.screen ?? NSScreen.main).visibleFrame`.
  - Call `setFrame` with the result.
  - A saved descriptor always wins. Both restore calls apply the same answer, and observation still starts after the second one.
- [x] Tests:
  - A 1440×875 visible frame gives 1080×656, centred.
  - A large minimum is raised to, then capped by the visible frame.
  - A non-zero origin is respected.
  - A zero-size visible frame is handled.
- [x] Extend `MainWindowFrameSourceGatingTests`: the rule is called only on the missing-key path, and the stored descriptor is applied first. Update its inventory.
- [x] Update the `app-shell.md` entry.
- [x] Run `swift test`; it must pass. (6115 tests green; swiftlint --strict clean; macOS Debug build succeeds. The content minimum reaches the marker through `MainWindowFrameAutosave(settings:)` and `ContentView.windowFloor`, on PisakaApp's existing chained line, because that file is at its `file_length` ceiling.)

### Task 4: Core Welcome screen model and shortcut pins

**Files:**
- Create: `Sources/PisakaCore/WelcomeScreen.swift`, `Tests/PisakaCoreTests/WelcomeScreenTests.swift`, `Tests/PisakaCoreTests/WelcomeShortcutPinTests.swift`

- [ ] `WelcomeScreen.shows(projectRoot: URL?, openFileCount: Int) -> Bool` is true exactly when both are empty.
- [ ] `WelcomeScreen.recents(_ rows: [RecentProject], cap: Int = 10) -> [RecentProject]`:
  - Keeps the MRU order.
  - Drops an `isCurrent` row defensively.
  - Truncates to the cap.
  - An empty result means "show the hint".
- [ ] A closed `WelcomeAction` enum. Each case has a display title, a `menuTitle` (the literal the pin looks for), a `DesignGlyph` and a chord:

  | Case | Display title | `menuTitle` | Glyph | Chord |
  |---|---|---|---|---|
  | openFolder | Open Folder… | Open Folder… | `folderOpen` | ⇧⌘O |
  | openFile | Open File… | Open… | `fileText` | ⌘O |
  | newFile | New File | New File | `plus` (Task 5) | ⌘N |
  | openLeetCodeProblem | Open LeetCode Problem… | Open Problem… | `fileCode` | ⌥⌘P |

- [ ] A closed `WelcomeFooterEntry` enum. Every entry names a command that is enabled with no folder open. Each case has a label and one or more chords, and each chord carries its own `menuTitle`:

  | Case | Label | Chord → `menuTitle` |
  |---|---|---|
  | terminal | Show Terminal | ⇧⌘T → "Show Terminal" |
  | browseProblems | Browse Problems… | ⇧⌘B → "Browse Problems…" |
  | zoom | Zoom | ⌘+ → "Zoom In"; ⌘− → "Zoom Out"; ⌘0 → "Reset Zoom" |

  The zoom entry is drawn as one entry, "Zoom ⌘+ ⌘− ⌘0".
- [ ] A small `WelcomeChord` value: a key character plus a modifier set. Its display string uses the macOS canonical modifier order ⌃⌥⇧⌘, and the minus key displays as "−".
- [ ] Keyboard selection runs over the flattened list (actions, then recents) and reuses `PopoverSelection`. Activating index `i` resolves to an action or a recent URL.
- [ ] Tests in `WelcomeScreenTests`:
  - The rule's four combinations.
  - The cap and its order.
  - The `isCurrent` drop.
  - The empty-hint case.
  - The chord display strings, including "Zoom ⌘+ ⌘− ⌘0".
  - The index → target mapping.
- [ ] `WelcomeShortcutPinTests` is a repository-file suite that scans `Sources/Pisaka` with comments stripped and literals kept. Its doc comment states that literal-keeping exception and the matching rule below.
  - Matching rule: a "menu Button" is a `Button(` call whose argument text, up to its balanced closing parenthesis, contains the title as a string literal (`"Show Terminal"` inside a ternary counts). Its shortcut is the first `.keyboardShortcut("<key>", modifiers: <set>)` in that Button's modifier chain, before the next `Button(`.
  - For every (title, chord) pinned by `WelcomeAction` and `WelcomeFooterEntry`: exactly one menu Button whose argument contains the title carries that chord. The chord also occurs on no Button whose argument does not contain the title.
    - Example: Zoom In's ⌘+ matches the second "Zoom In" item only. The ⌘= item is ignored, and neither is mistaken for the other.
  - Closed folder-required table:
    - The test states, as a literal set, every menu title whose Button chain carries `.disabled(model.projectRoot == nil)`, Find in Files among them.
    - A scan of the sources must produce exactly that set, by set equality.
    - Assert that no footer entry's titles and no action's `menuTitle` are in it.
    - So a footer that advertises a dead command fails, and so does a newly folder-gated command that is not recorded in the table.
- [ ] Run `swift test`; it must pass.

### Task 5: Vendor the `plus` design glyph

**Files:**
- Create: `Sources/Pisaka/Assets.xcassets/Glyphs/plus.imageset/` (`plus.pdf` + `Contents.json` matching its neighbours)
- Modify: `Sources/PisakaCore/DesignGlyph.swift`, `Resources/DesignGlyphs/VENDORED.md`, `Tests/PisakaCoreTests/DesignGlyphAssetTests.swift`

- [ ] Copy `plus.pdf` from the export byte for byte, after checking its sha256 prefix against the export's `MANIFEST.txt`.
- [ ] Add `case plus` to `DesignGlyph`.
- [ ] Update `VENDORED.md`:
  - Add the glyph's row.
  - Change "Twenty-four" to "Twenty-five".
  - Drop `plus` from the left-behind glyphs, so eight becomes seven.
- [ ] Update the pinned prefix table. The manifest digest and the licence revision are unchanged, because this is the same export.
- [ ] Run the geometry check (a 24×24 box, no coordinate outside it), then `swift test`; it must pass.

### Task 6: Welcome view and window wiring

**Files:**
- Create: `Sources/Pisaka/WelcomeView.swift`
- Modify: `Sources/Pisaka/ContentView.swift`, `Sources/Pisaka/PisakaApp.swift`, `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift` (and its per-file tables if they apply)

- [ ] `WelcomeView` (macOS) has four parts:
  - Header: the app icon, "Pisaka", and `CFBundleShortVersionString`.
  - Actions column: each row has a `DesignGlyphImage`, the display title, and the chord display string right-aligned.
  - Recents column: the folder name in `textPrimary`, with the path below it in `textSecondary`, middle-truncated. When the list is empty, the column shows the hint "Open a folder to get started — it will appear here next time".
  - Footer: the three `WelcomeFooterEntry` entries, labels and chord strings rendered from Core, so the zoom entry reads "Zoom ⌘+ ⌘− ⌘0". The footer is informational only, with no second command implementation.
- [ ] Layout:
  - Centred, with a capped content width.
  - A two-column `ViewThatFits` that falls back to a stacked layout, all inside a `ScrollView`.
  - Sizes only through `metrics`.
  - Colours only through roles: `bgCanvas`/`bgPanel`, `hoverTint`, `accentTint`, `hairline`, `textPrimary`/`textSecondary`.
  - Glyphs only through `DesignGlyph`.
  - No `Divider()`, no system semantic colours, no SF Symbols.
- [ ] Keyboard:
  - The view takes focus when it appears.
  - ↑/↓ move the Core selection, and Tab moves between the columns.
  - Return activates the selected row, so Return on a recent row opens it.
  - Every row is a real button with an accessibility label.
- [ ] Wiring: ContentView receives the closures PisakaApp already owns:

  | ContentView input | PisakaApp code |
  |---|---|
  | `onOpenFolder` | `openFolder()` |
  | `onOpenFile` | `openFile()` |
  | `onNewFile` | `model.newFile()` |
  | `onOpenLeetCodeProblem` | `leetCodeSheet = .openProblem` |
  | `recentProjects` | `recentProjectRows()` |
  | `onOpenRecentProject` | `openFolder(url:)` |

- [ ] When `WelcomeScreen.shows` holds, `WelcomeView` replaces `editorSplit`, both inside and outside `BottomDockColumn`. The bottom bar stays.
- [ ] Correct the comments on `bgCanvas` and on the tree and editor captions to say which state still reaches each.
- [ ] Add `WelcomeView.swift` to `gatedFiles`, and change "sixty-two" to "sixty-three" in the suite header, `core-theme.md` and CLAUDE.md. Add it to any per-file tables the rules require. Confirm `ZoomSourceGatingTests` stays green.
- [ ] Run `swift test` and `swiftlint --strict`; both must pass.

### Task 7: App-layer layout test for the Welcome screen

**Files:**
- Create: `Tests/PisakaAppTests/WelcomeLayoutTests.swift`

- [ ] Render `WelcomeView` through `HostedRender` at scales 0.8, 1.5 and 2.0, both at the window's content minimum and at a large size.
- [ ] Assert:
  - Nothing is drawn outside the frame.
  - At the minimum, the columns stack or scroll rather than overlap.
  - With empty recents, the hint is present.
- [ ] Run the app test bundle; it must pass.

### Task 8: Verify acceptance criteria

- [ ] Run `swift test`.
- [ ] Run `xcodegen generate`, then `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' test`.
- [ ] Run `swiftlint --strict` from the repository root.
- [ ] Build macOS Release: `xcodebuild … -destination 'platform=macOS' -configuration Release build`.
- [ ] Build iOS: `-destination 'generic/platform=iOS'`.
- [ ] Check that the new Core rules are fully covered by their tests (80%+ on the new files).

### Task 9: Update documentation

- [ ] CLAUDE.md:
  - Index `WelcomeScreen.swift` and `MainWindowInitialFrameRule.swift` under `core-services.md`.
  - Index `ScaledFrameFitRule.swift` under `core-zoom.md`.
  - Index `WelcomeView.swift` under `app-window.md`.
  - Add `WelcomeShortcutPinTests` to the repository-file suite list.
  - Change "sixty-two" to "sixty-three".
  - Stay under 60,000 characters.
- [ ] Write full entries:
  - `app-window.md`: `WelcomeView`, the Welcome/workspace switch, and the caption states that remain.
  - `core-services.md`: `WelcomeScreen`, including the footer rule ("enabled with no folder open", the closed folder-required table and the pin's matching rule), and the initial frame rule.
  - `core-zoom.md`: the new default, the fit rule and the 1.5 audit.
  - `core-theme.md`: the gated list.
  - `app-shell.md`: the frame autosave fallback.
- [ ] Update README.md and `docs/FEATURES.md`: the Welcome screen and the 150% default.

## Post-Completion (manual)

- Fresh install: `defaults delete` the app's domain, then launch. Expect a centred window at about 75% of the screen, at 150%, showing the Welcome screen with the empty-recents hint.
- Open a folder, close it, quit and relaunch. The folder appears under Recent, and one click reopens it.
- Each action row matches its menu item, and Return on a recent row opens it. Each footer chord works with no folder open.
- Preferences shows 150% on a fresh install, ⌘0 over the chrome returns 150%, and a stored 1.0 survives an upgrade. At 100%, the chrome matches master.
