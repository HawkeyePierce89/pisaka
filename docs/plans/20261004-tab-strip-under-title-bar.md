# The horizontal tab strip stops under the title bar, and the title bar draws no line

## Overview

With horizontal tabs, the main window shows two defects at its top edge. Both are already present on `master`.

1. The window's automatic title-bar separator draws a 1-point line across the whole window. It is black over the horizontal strip and grey over the vertical layout.
2. The active tab's `bgEditor` fill climbs through the transparent title bar to the window's top edge. The strip is the topmost view under the title bar, and the title bar is the window's top safe-area inset. A SwiftUI `.background(<ShapeStyle>)` extends into the safe area by default.

The design has:

- a 28-point title bar on `bgPanel`;
- the 32-point strip on `bgPanel` directly under it;
- the active tab filled in `bgEditor` inside the strip only;
- no line between the title bar and the strip.

A mutation that was built, captured and then reverted showed that two changes fix both defects:

- `window.titlebarSeparatorStyle = .none` in `MainWindowChrome.apply(to:title:)`;
- `ignoresSafeAreaEdges: []` on the strip's colour backgrounds.

This plan makes those two changes, pins each one so it cannot quietly come back, and documents them.

## Context

- Files involved:
  - `Sources/Pisaka/MainWindowChrome.swift`: `apply(to:title:)` sets four properties plus the centred label today.
  - `Sources/Pisaka/TabStripView.swift`, which has two colour backgrounds:
    - `TabStripView.body`: `.background(theme.color(.bgPanel))`;
    - `TabStripCell.body`: `.background(isActive ? theme.color(.bgEditor) : Color.clear)`.
  - `Tests/PisakaAppTests/MainWindowChromeTests.swift`
  - `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`:
    - rule nine, `testOnlyTheWindowChromeMakesATitleBarTransparent`;
    - rule sixteen, `testAnIndicatorStripsBottomRuleIsDrawnBehindItsTabs`, plus its helper `groundBackgroundPositions(in:)`;
    - the rule-count bookkeeping: `declaredRuleCount()`, the `spelled` table, `testBothSummariesSpellTheSuitesOwnRuleCount`, `testTheSuitesHeaderInventoriesEveryRule` and `testTheCanonicalListEnumeratesEveryRule`.
  - `docs/architecture/app-shell.md`: the `MainWindowChrome.swift` entry.
  - `docs/architecture/core-theme.md`: the horizontal tab strip entry (around "The horizontal tab strip — `TabStripView.swift`"), canonical rule 9, and the canonical list "The forty-six rules, each invisible to the compiler:".
  - `docs/architecture/app-window.md`: the `TabStripView.swift` entry.
  - `CLAUDE.md`: only the phrase "and its forty-six rules" in the chrome-theme invariant.
- Related patterns:
  - Repository-file gating rules match against `LSPSourceGatingTests.strippingCommentsAndStringLiterals(_:)` output and use the suite's `callRanges(_:in:)` and `balancedEnd(from:in:)` helpers. A wrapped argument list is therefore still the same call.
  - Rule forty-six's shape is a static matcher plus a self-check that feeds it inline snippets.
  - Every new rule needs four things, and existing tests enforce each one:
    - a `// MARK: - Rule <spelled>: <title>` marker;
    - a header bullet `/// - **<title>.**` placed in marker order;
    - an entry in the `spelled` table;
    - a numbered item in the canonical list of `core-theme.md`, plus the count sentences there and in `CLAUDE.md`.
- Dependencies: none.

## Development Approach

- **Testing approach**: Regular (code first, then tests), with each task's pin checked by hand mutation before the task is closed.
- Complete each task fully before moving to the next.
- The work lands on the existing branch `lsp-consent-banner-card`. Never create a new branch.
- No product or brand names anywhere: code, comments, docs, tests, commit messages.
- Every `xcodebuild` passes `-derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-build`. Never use a path inside the repository.
- No new source files, so no `xcodegen generate` is needed. Tests stay cheap: no new windows beyond those the suites already create, and no screen-recording API.
- Hand mutations are made, run and reverted within the task. They are never committed.
- **CRITICAL: every task MUST include new/updated tests**
- **CRITICAL: all tests must pass before starting next task**

## Implementation Steps

### Task 1: The title bar draws no separator

**Files:**
- Modify: `Sources/Pisaka/MainWindowChrome.swift`
- Modify: `Tests/PisakaAppTests/MainWindowChromeTests.swift`
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`

- [x] In `MainWindowChrome.apply(to:title:)`, set `window.titlebarSeparatorStyle = .none` as the fifth property, next to the transparency.
  - Add a comment saying why: the automatic separator draws a line the design does not have, black over the horizontal strip and grey over the vertical layout. The title bar and the strips below are meant to read as one `bgPanel` surface.
  - Update the doc comment on `apply`, which says rule nine pins the transparency setter, so it names the separator setter too.
- [x] Extend rule nine (`testOnlyTheWindowChromeMakesATitleBarTransparent`) so it pins `titlebarSeparatorStyle` the same way.
  - The set of files under `Sources/` whose stripped text contains the token must equal `["MainWindowChrome.swift"]`, checked in both directions.
  - Give it its own failure message.
  - Update the rule's doc comment and its header bullet body. The bullet title stays "The window's chrome is configured in one file", so the inventory check is unaffected.
- [x] Extend `MainWindowChromeTests` without adding a window:
  - In `testTheTitleBarIsTransparent`, assert that a freshly built window's `titlebarSeparatorStyle` is not `.none`, so the test cannot pass without the call, and that it is `.none` after `apply`.
  - In `testAttachingTheMarkerAppliesTheChromeToItsWindow`, assert that the marker path leaves it `.none` as well.
  - Correct the suite's doc comment, which still calls `apply` "two property assignments", so it names what `apply` sets now.
- [x] Hand mutation, not committed: remove the separator line from `apply` and confirm the app-bundle chrome test fails. Then add a dummy `titlebarSeparatorStyle` setter in another source file and confirm rule nine fails. Revert both.
- [x] Run `swift test` and the app-layer bundle (`xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-build test`). Both must pass before Task 2.

### Task 2: Nothing in the strip paints into the title bar, and rule forty-seven pins it

**Files:**
- Modify: `Sources/Pisaka/TabStripView.swift`
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`
- Modify: `docs/architecture/core-theme.md` (canonical list count sentence and new item 47 only; the prose entries are in Task 3)
- Modify: `CLAUDE.md` (the rule count word only)

- [x] In `TabStripView.swift`, confine both colour backgrounds to their own frames:
  - `.background(theme.color(.bgPanel), ignoresSafeAreaEdges: [])` on the strip;
  - `.background(isActive ? theme.color(.bgEditor) : Color.clear, ignoresSafeAreaEdges: [])` on the cell.
  - Add a comment at the strip's ground, and a short pointer to it at the cell. The comment says the strip sits directly under the transparent title bar, which is the window's top safe-area inset, so a default background would climb through it to the window's top edge.
  - Leave the height, the bottom-rule background (`.background(alignment: .bottom) { … }`, a view background that does not climb), the accent underline, the modifier order and the cell layout unchanged.
- [x] Add rule forty-seven to `ChromeThemeSourceGatingTests`, after rule forty-six, with the marker `// MARK: - Rule forty-seven: The tab strip's grounds stay inside the strip`.
  - Write a static matcher that takes stripped source text and returns the colour backgrounds missing the parameter. It finds every `.background(` call through `callRanges`, takes its balanced argument list and skips any list that opens with `alignment`. A list counts as a colour background when it names `theme.color(` or a `Color.` token, which covers the conditional form. Such a list must contain `ignoresSafeAreaEdges: []`, with whitespace folded so a wrapped list still matches.
  - The rule reads `TabStripView.swift` through the ordinary stripping scanner. It asserts that the matcher returns nothing, and that at least two colour backgrounds were seen, so the rule cannot go vacuous.
  - Write a self-check in rule forty-six's idiom that feeds the matcher inline snippets:
    - a bare colour background must be flagged;
    - a conditional colour background must be flagged;
    - a wrapped argument list missing the parameter must be flagged;
    - the confined forms must pass;
    - `.background(alignment: .bottom) { … }` must be ignored.
  - Give the rule a doc comment stating its reason: the window's title bar is transparent and is the top safe-area inset. A colour background extends into the safe area by default. The headless `HostedRender` has no title bar, so the climb cannot be seen off a bitmap and this rule is the only net. Name its horizon too: the rule reads this one file, and only arguments spelled as `theme.color(` or `Color.`.
- [x] Do the rule-count bookkeeping in the same task, because the existing checks fail until it is done:
  - add the header bullet `/// - **The tab strip's grounds stay inside the strip.**` with its reason, after rule forty-six's bullet;
  - add `47: "forty-seven"` to `spelled`;
  - in `core-theme.md`, change "The forty-six rules, each invisible to the compiler:" to "The forty-seven rules, …";
  - add item `47. **The tab strip's grounds stay inside the strip.**` before "Plus a **self-check**", with the reason and the horizon;
  - in `CLAUDE.md`, change "and its forty-six rules" to "and its forty-seven rules".
  - Confirm that rule sixteen still finds both grounds and the rule-before-ground order. The ground arguments still name `bgPanel` and `bgEditor`, and neither opens with `alignment`.
- [x] Hand mutation, not committed: remove one `ignoresSafeAreaEdges: []` from `TabStripView.swift` and confirm rule forty-seven fails. Revert.
- [x] Run `swift test`, the app-layer bundle and `swiftlint --strict` from the repository root. All must pass before Task 3.

### Task 3: Documentation

**Files:**
- Modify: `docs/architecture/app-shell.md`
- Modify: `docs/architecture/core-theme.md`
- Modify: `docs/architecture/app-window.md`
- Modify: `Sources/Pisaka/MainWindowChrome.swift` (file header comment only)

- [x] `app-shell.md`, `MainWindowChrome.swift` entry:
  - Change "four properties plus one label" to five properties, naming `titlebarSeparatorStyle = .none` and the reason for it.
  - Record the dated observation (2026-10-04): window captures of the Debug build at interface scale 1, dark appearance, showed one pure-black row under the title bar with horizontal tabs and a light-grey line with vertical tabs.
  - State that rule nine now pins both setters, and that `MainWindowChromeTests` asserts the separator on both the `apply` path and the marker path.
  - Add a matching short paragraph to the header comment of `MainWindowChrome.swift`.
- [x] `core-theme.md`:
  - Canonical item 9: name the separator setter beside the transparency.
  - Horizontal tab strip entry: record the safe-area climb. On 2026-10-04 the active tab's `bgEditor` fill ran through the title bar's 30 rows to the window's top edge. Cause: the strip is the topmost view under the transparent title bar, which is the top safe-area inset, and a SwiftUI shape-style background extends into it by default. Fix: `ignoresSafeAreaEdges: []` on both colour backgrounds, pinned by rule forty-seven.
  - Also write the design comparison where the strip's geometry is documented: a 28-point title bar on `bgPanel`, the 32-point strip (`ChromeGeometry.tabStripHeight`) on `bgPanel` directly under it, the active fill inside the strip only, and no line between the title bar and the strip.
- [x] `app-window.md`, `TabStripView.swift` entry: one or two sentences restating the confinement and pointing to `core-theme.md` for the reasoning.
- [x] Check that no other document still describes four properties or a separator line. Change another document only if it has stopped being truthful.
- [x] Run `swift test` (the documentation-reading checks) and `swiftlint --strict`. Both must pass.

### Task 4: Verify acceptance criteria

- [ ] Run `swift test`: green.
- [ ] Run the app-layer bundle: `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-build test`. Green.
- [ ] Run `swiftlint --strict` from the repository root: clean.
- [ ] Run the macOS Release build: `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' -configuration Release -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-build build`. It must succeed.
- [ ] Confirm the hand mutations from Tasks 1 and 2 were all reverted (`git diff` shows only the intended changes).

### Task 5: Update documentation

- [ ] README.md: no user-facing feature change, so no update is expected. Confirm and leave it unchanged.
- [ ] CLAUDE.md: only the rule count changed (Task 2). Confirm it is still under its size cap; `LintConfigurationTests` checks this.

## Post-Completion

Manual checks, done by the user in a Debug build only:

- Horizontal tabs: through the active tab, the title bar's rows are `bgPanel` and the `bgEditor` fill begins at the strip's top. No black row exists between the title bar and the content across the full window width.
- Vertical tabs: no line under the title bar. The title bar and the panels below read as one `bgPanel` surface.
- Check both appearances and at least one non-default interface scale.
