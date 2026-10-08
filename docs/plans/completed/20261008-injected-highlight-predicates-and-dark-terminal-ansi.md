# Injected-language highlighting honours predicates; dark terminal ANSI-16 tuned for its bgPanel ground

## Overview

This plan fixes two release-visible defects. They are independent: each is its own commit series and they share no step.

**Part A — injected shell code is painted in one flat colour.** When a shell block is highlighted through a tree-sitter injection, every child of `command` gets the `constant` colour. Two injections show it:
- Make recipes, which go `(shell_text)`/`(shell_command)` → `bash`
- Markdown ```` ```sh ```` fences

The cause is that the bash query's predicate `((command (_) @constant) (#match? @constant "^-"))` is ignored on that path. The plan:
- pin the failing link with a throwaway harness;
- fix it in Pisaka's own injection/highlight path, or by bumping the Neon pin if a release already carries the fix, and never by patching a remote package;
- add an app-layer test that runs the shipped bash query through the injection path;
- document the cause, the fix and which injections it covers.

**Part B — the dark terminal's colours are unreadable on its actual ground.** `TerminalTheme.darkANSIColors` is SwiftTerm's default set, tuned for black. The terminal's ground is now `bgPanel` dark `0x2B2D30` (`ChromePalette.swift` L55). The ticket quotes `0x1E1F22`, but that is `bgCanvas`, the ground before "The terminal's ground and inset" moved it.

On the real ground:
- Eight entries fall below 4.5:1: ANSI 1 (1.55), 2 (4.25), 4 (1.08), 5 (2.33), 8 (3.96), 9 (2.85), 12 (1.60) and 13 (3.59).
- ANSI 3 measures 4.54, right on the floor.

The plan brightens those eight, and nudges ANSI 3 for margin, without shifting any hue. It also rewrites the doc comments, adds the dark-ground floor test, closes the open item in `core-theme.md`, and corrects the stale `0x1E1F22` mentions in the docs.

## Context

**Files involved (Part A):**
- `Sources/Pisaka/SyntaxLanguageConfiguration.swift`
- The six sites that build a `TextViewHighlighter` with a `languageProvider` (from `grep -rn languageProvider Sources/Pisaka`):
  - `Sources/Pisaka/CodeEditorView.swift` (~L3728)
  - `Sources/Pisaka/SourceViewerContent.swift` (~L269)
  - `Sources/Pisaka/DiffView.swift` (~L270)
  - `Sources/Pisaka/iOS/DiffView_iOS.swift` (~L196)
  - `Sources/Pisaka/iOS/MergeView_iOS.swift` (~L432)
  - `Sources/Pisaka/iOS/CodeEditorCoordinator_iOS.swift` (~L965)
- `Vendor/TreeSitterMake/queries/injections.scm` (read only)
- `docs/architecture/app-editor-overlays.md`
- New: `Tests/PisakaAppTests/InjectedHighlightPredicateTests.swift`
- New fixtures under `Tests/PisakaAppTests/Fixtures/`

**Files involved (Part B):**
- `Sources/Pisaka/TerminalTheme.swift`
- `Tests/PisakaAppTests/TerminalThemeTests.swift`
- `docs/architecture/core-theme.md`, in four places:
  - part five (h), around L2429–L2475;
  - the closing *What is still waiting* paragraph, around L2841;
  - "The terminal's ground and inset", around L2760;
  - the rule-44 text, around L3751, which is checked but not changed.
- `docs/architecture/app-terminal.md`: the ANSI paragraph around L78, which quotes `0x1E1F22`.

**Exploration notes for Part A.** The pinned Neon is 484d6fb, and its `TreeSitterClient.highlightsProvider` has two paths:
- `asyncValue` runs `executeQuery` (L340–348), which ends in `matches.resolve(with: .init(textProvider:))`. That step evaluates `#match?`.
- `syncValue` (L356–363) returns `layerTree.executeQuery(.highlights, in: set).highlights()` with no `.resolve(with:)`. Predicates are skipped, so the bash `^-` filter passes every child of `command`.

Two things are still open and are what the harness must establish:
- whether the sync path is what paints injected ranges;
- why a standalone `.sh` file still renders correctly.

One possibility is that the async path repaints root-layer ranges but not sublayer ranges. The ticket's other candidates stay on the list until the harness rules them out:
- the ranges the sublayer is queried over;
- which `Query` object the sublayer carries;
- the capture ordering in `highlights()`.

**Patterns to follow:**
- `ShellSymbolQueryTests` and `MakeSymbolQueryTests` show how to execute a shipped query headlessly in the app bundle, with fixtures read through `#filePath`.
- `TerminalThemeTests.testEveryLightANSIEntryClearsTheFloorOnTheLightGround` does its own luminance arithmetic.
- The light ANSI set's documented contrasts are the model for recording the new dark values.

**Dependencies:**
- No new dependency.
- If the Neon pin must move, it changes only through `project.yml`, with `Package.resolved` regenerated. `DependencyPinTests` must stay green, and the SwiftTreeSitter branch-pin rationale in `project.yml` must be re-checked.

## Development Approach

- **Testing approach: TDD for both parts.**
  - Part A: the injection test is written first and must fail on master.
  - Part B: the dark floor test is written first and must fail on the current SwiftTerm defaults.
- Complete each task fully before moving to the next.
- Part A and Part B are separate commit series. Architecture docs are updated in the same commit as the behaviour they describe.
- The Part A fix lives in the app layer and changes no grammar or query.
- No new `ChromeColorRole`; the role set stays at 22.
- **CRITICAL: every task MUST include new/updated tests**
- **CRITICAL: all tests must pass before starting next task**

## Implementation Steps

### Task 1: Pin the root cause of Part A with a throwaway harness

**Files:**
- Create: a scratch SwiftPM package outside the repository, in the session scratchpad and not committed

- [x] Build a throwaway executable package that depends on:
  - Neon and SwiftTreeSitter at the exact revisions in `Package.resolved`;
  - `tree-sitter-bash` and `tree-sitter-markdown` at their pins;
  - `Vendor/TreeSitterMake` as a path dependency.
- [x] Parse a Makefile fixture that mirrors the repository `Makefile`'s `@command -v swiftlint …` and `echo "…"` recipe lines. Use a root `LanguageLayer` for Make whose injection provider resolves `bash`.
- [x] Dump the highlight captures per range three ways:
  - (a) unresolved, `executeQuery(.highlights, in:).highlights()`, as Neon's `syncValue` does;
  - (b) resolved, `.resolve(with: textProvider).highlights()`, as `asyncValue` does;
  - (c) from a standalone bash layer over the same text.
- [x] Repeat the three dumps for a Markdown ```` ```sh ```` fence.
- [x] Trace `TextSystemStyler`/`highlightsProvider` to settle what Neon's `TextViewHighlighter` actually requests for a sublayer range: the sync path or the async one.
- [x] Check upstream Neon `main` and its tags for a commit that resolves predicates on the sync path. Record whether a pin bump is available and what it costs: the SwiftTreeSitter branch pin and `DependencyPinTests`.
- [x] Write the pinned cause into the progress log: the exact failing link, the evidence, and the decision between a pin bump and a Pisaka-side workaround.
- [x] Change no repository code in this task. `swift test` stays green.

### Task 2: Failing app-layer test for predicates through the injection path

**Files:**
- Create: `Tests/PisakaAppTests/InjectedHighlightPredicateTests.swift`
- Create: `Tests/PisakaAppTests/Fixtures/injected-shell.mk`
- Create: `Tests/PisakaAppTests/Fixtures/injected-shell.md`
- Create: `Tests/PisakaAppTests/Fixtures/injected-shell.sh` (the same lines, standalone)

- [x] Write the fixtures. Each carries `@command -v swiftlint …`, an `echo "…"` with a quoted string, and a `-flag` argument. The Markdown fixture wraps these lines in a ```` ```sh ```` fence, and the `.sh` file holds them bare.
- [x] Obtain highlights the way the editor does: through the editor's own entry point, built from `SyntaxLanguageConfiguration.configuration(for:)` and `configuration(forInjectionName:)`, and along the highlight path Task 1 identified. That way the test fails for the real cause, not for a reimplementation of it.
- [x] For both the Makefile and the Markdown fence, assert that:
  - the quoted string's range carries no `constant` capture (it is `string`);
  - `command` is not `constant`;
  - `-v` is `constant`.
- [x] Assert that the injected capture set over the shell lines equals the standalone `.sh` capture set, once ranges are offset to the block.
- [x] Run the app bundle and confirm the new test fails on master for the reason Task 1 pinned.
- [x] Add a doc comment saying why only the app bundle can see this: Core does not link tree-sitter.

### Task 3: Fix the injection highlight path so predicates are always resolved

**Files:** chosen by Task 1's outcome, either:
- Modify: `project.yml` + `Pisaka.xcworkspace/.../Package.resolved` (pin bump), or
- Modify: `Sources/Pisaka/SyntaxLanguageConfiguration.swift` and/or the six highlighter call sites (workaround).

- [x] If an upstream Neon/SwiftTreeSitterLayer release carries the fix, bump the pin (not applicable — Task 1 found no release carrying it; workaround taken):
  - change it in `project.yml`;
  - run `xcodegen generate` and regenerate `Package.resolved` through resolution, never by hand;
  - re-verify the SwiftTreeSitter branch-pin rationale comment;
  - keep `DependencyPinTests` and `LicenseCoverageTests` green.
- [x] Otherwise, add a documented Pisaka-side workaround that makes every highlight request resolve predicates against the buffer's text provider. Two possible shapes:
  - a highlights provider, or a `TextViewHighlighter` construction, that routes through the resolving path;
  - re-filtering the matches through `.resolve(with:)`.
- [x] Whichever shape the workaround takes, it must:
  - work for any predicate-carrying query (`#match?`, `#eq?`, `#any-of?` …), not just this bash pattern;
  - be shared by all six highlighter sites through one helper, not copied six times — this covers `MergeView_iOS` and `CodeEditorCoordinator_iOS` as well as the four other sites;
  - patch or copy no remote package.
- [x] If the fix introduces a new app file, give it an index entry in CLAUDE.md under `app-editor-overlays.md` and keep CLAUDE.md under 60,000 characters.
- [x] Run the Task 2 test; it must now pass.
- [x] Add a regression assertion that a standalone `.sh` file still produces the capture set it produced before the fix.
- [x] Run `swift test`, the app bundle and `swiftlint --strict`; all must pass.

### Task 4: Enumerate injection reach and document Part A

**Files:**
- Modify: `docs/architecture/app-editor-overlays.md` (the `SyntaxLanguageConfiguration` / `configuration(forInjectionName:)` entry)
- Modify: `Vendor/TreeSitterMake/VENDORED.md` or `docs/architecture/core-services.md`, only if the Make verification recipe changes
- Modify: `Tests/PisakaAppTests/InjectedHighlightPredicateTests.swift`

- [x] Enumerate every injection Pisaka resolves today:
  - Markdown → `markdown_inline` and the fenced languages;
  - Make → bash;
  - HTML → JavaScript/CSS;
  - the injections queries shipped by the JavaScript, Swift and Rust grammars, noting each name for which `configuration(forInjectionName:)` returns nil.
- [x] For each resolved target, state whether its highlights query carries predicates.
- [x] Record in the entry:
  - the cause Task 1 pinned;
  - the Task 3 fix (pin bump or workaround) and the reason for it;
  - `InjectedHighlightPredicateTests` as the test that pins it.
- [x] Extend the Task 2 test with one assertion for each other predicate-carrying injected target the enumeration finds — for example, a JavaScript or CSS `#match?` pattern inside HTML, if such a target exists.
- [x] Run the app bundle and `swift test`; both must pass. Commit Part A.

### Task 5: Failing dark-ground floor test for the terminal ANSI-16 set

**Files:**
- Modify: `Tests/PisakaAppTests/TerminalThemeTests.swift`

- [x] Add `testEveryDarkANSIEntryButBlackClearsTheFloorOnTheDarkGround`, mirroring the light test:
  - Compute with the suite's own `luminance` arithmetic.
  - Read the ground from `ChromePalette.nsColor(.bgPanel, in: .dark)`, never from a literal.
  - Skip index 0, with a separate assertion that ANSI 0 is exactly `0x000000`, the one stated exception.
  - Use a floor of 4.5:1.
- [x] Add an assertion that pins the exact sixteen dark values. Together with `testEachAppearanceInstallsItsOwnANSISet`, this proves that dark → light → dark restores the new array.
- [x] Update the suite's doc comment, which is its inventory, to name the dark floor and its ground.
- [x] Run the app bundle and confirm the new test fails on the current SwiftTerm defaults. Measured against `bgPanel` dark `0x2B2D30`:

| Entry | Current value | Contrast on `0x2B2D30` |
|---|---|---|
| ANSI 1 | `0x990001` | 1.55 |
| ANSI 2 | `0x00A603` | 4.25 |
| ANSI 3 | `0x999900` | 4.54 (on the floor) |
| ANSI 4 | `0x0300B2` | 1.08 |
| ANSI 5 | `0xB200B2` | 2.33 |
| ANSI 8 | `0x8A898A` | 3.96 |
| ANSI 9 | `0xE50001` | 2.85 |
| ANSI 12 | `0x0700FE` | 1.60 |
| ANSI 13 | `0xE500E5` | 3.59 |

### Task 6: Re-tune darkANSIColors and document Part B

**Files:**
- Modify: `Sources/Pisaka/TerminalTheme.swift`
- Modify: `docs/architecture/core-theme.md`
- Modify: `docs/architecture/app-terminal.md`

- [x] Brighten the eight failing entries. Also brighten ANSI 3: 4.54 sits within rounding of the floor, and the test reads the palette's resolved colour rather than a literal, so that margin is fragile.
  - Every new value keeps SwiftTerm's own hue angle and only increases brightness: red 0°, green ≈121°, yellow 60°, blue 240°, magenta 300°, and ANSI 8 keeps its slight 300° grey tint.
  - Every bright entry stays brighter than its normal partner (1/9, 2/10, 3/11, 4/12, 5/13, 0/8 vs 7).
  - Contrasts are measured with WCAG relative luminance against `0x2B2D30`:

| Entry | Old value | New value | Contrast | Hue |
|---|---|---|---|---|
| ANSI 1 | `0x990001` | `0xFF6B6B` | 4.98 | 0° |
| ANSI 2 | `0x00A603` | `0x00B803` | 5.17 | 121° |
| ANSI 3 | `0x999900` | `0xA0A000` | 4.95 | 60° |
| ANSI 4 | `0x0300B2` | `0x9393FF` | 5.17 | 240° |
| ANSI 5 | `0xB200B2` | `0xE070E0` | 4.97 | 300° |
| ANSI 8 | `0x8A898A` | `0x9E9D9E` | 5.11 | 300° (grey) |
| ANSI 9 | `0xE50001` | `0xFF8C8C` | 6.17 | 0° |
| ANSI 12 | `0x0700FE` | `0xAAAAFF` | 6.51 | 240° |
| ANSI 13 | `0xE500E5` | `0xFF8CFF` | 6.87 | 300° |

- [x] Leave the other seven entries verbatim; each already clears on `0x2B2D30`:
  - ANSI 0: black, the stated exception;
  - ANSI 6: 4.62;
  - ANSI 7: 7.51;
  - ANSI 10: 7.12;
  - ANSI 11: 10.22;
  - ANSI 14: 8.77;
  - ANSI 15: 10.96.

  No per-entry exception is needed, so the floor is uniformly 4.5:1 (WCAG AA for normal text), matching the light set.
- [x] Spell entries with `rgb8(…)`, keep sixteen entries per array, and keep every `0x` literal inside the two arrays, so rule 44 of `ChromeThemeSourceGatingTests` stays green.
- [x] Rewrite the doc comments in `TerminalTheme.swift`:
  - The `darkANSIColors` comment says what the set now is: SwiftTerm's hues, with nine entries brightened to clear 4.5:1 on `bgPanel` dark `0x2B2D30`. It also explains that unconditional installation requires only a fixed set, not SwiftTerm's.
  - The type-level comment ("installs SwiftTerm's values verbatim") and the `apply(to:appearance:)` comment ("dark reinstalls SwiftTerm's own values") are updated to match.
- [x] Update `core-theme.md`:
  - Close the open item in part five (h) and in the closing *What is still waiting* paragraph.
  - Record the nine new values with their measured contrasts and the uniform 4.5:1 floor.
  - Name the new test.
- [x] Correct the stale ground in both docs. In `core-theme.md`'s closing paragraph and in `app-terminal.md`'s ANSI paragraph, replace the `0x1E1F22` mentions and the contrasts quoted on it. State that the terminal's ground is `bgPanel` dark `0x2B2D30`. Part five (h)'s historical table row, which already says "since moved to `bgPanel`", stays as a record.
- [x] Update `app-terminal.md`'s ANSI paragraph to the new values.
- [x] Run the following; all must pass:
  - Task 5's tests;
  - `ChromeThemeSourceGatingTests` and `LintConfigurationTests` in `swift test`;
  - the full app bundle (green except the 8 pre-existing scale-1.8 layout failures in BottomBarLayoutTests, BottomBarToolTipTests, ChromePopoverLayoutTests and CommitDialogLayoutTests, which fail identically on HEAD without this change, as already noted in Task 4);
  - `swiftlint --strict`.
- [x] Commit Part B.

### Task 7: Verify acceptance criteria

- [x] Run `swift test`. (6161 tests, 0 failures)
- [x] Run `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' test`. (272 tests; only the 8 pre-existing scale-1.8 layout assertion failures in BottomBarLayoutTests, BottomBarToolTipTests, ChromePopoverLayoutTests and CommitDialogLayoutTests, unchanged from HEAD before this work)
- [x] Run `swiftlint --strict` from the repository root. (0 violations)
- [x] Build Release macOS: `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' -configuration Release build`.
- [x] Build iOS: `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'generic/platform=iOS' build`.
- [x] Confirm the new tests cover the Make and Markdown injection paths, every dark ANSI entry, and every new or changed app-layer branch.

### Task 8: Update documentation

- [x] `README.md` / `docs/FEATURES.md`: no user-facing feature change is expected. Confirm that nothing there restates the old terminal colours or the injection behaviour. (confirmed: neither mentions the ANSI values, the terminal ground or injected highlighting)
- [x] CLAUDE.md: add an index entry only if Task 3 introduced a new app file, and keep the file under 60,000 characters (`LintConfigurationTests`). (`PredicateResolvingHighlighter.swift` already indexed under `app-editor-overlays.md`; 51,716 characters, `LintConfigurationTests` green)

## Post-Completion

Manual checks that need a running app and screenshots:
- **Repository `Makefile` in a DEBUG build:** `@command -v swiftlint …` shows `@` as an operator, `command` plain, `-v` in the constant colour, and the quoted string in `echo "…"` green. Take a screenshot. The first word of each recipe line after the first stays plain where a `.sh` file paints it `function` — the combined-layer limit recorded in `app-editor-overlays.md`, not a regression.
- **Markdown ```` ```sh ```` fence:** it renders identically to a standalone `.sh` file containing the same lines. Take a screenshot of both.
- **Dark terminal:** in the dark theme with the terminal open, run `ls -G` and `git status` in a repository with changes. Directory and branch names in blue must be readable. Take a screenshot to compare against the current build.
- **Appearance round trip:** switch dark → light → dark and confirm the terminal restores the new dark set.
