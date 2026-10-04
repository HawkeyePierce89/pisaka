# Fix plan 03: the strip's ground paints the title bar again; only the tab's fill stays inside the strip

## Overview

This plan answers the acceptance check of the title-bar work on the branch
`lsp-consent-banner-card` (plan `docs/plans/completed/20261004-tab-strip-under-title-bar.md`).
Every gate is green, both hand mutations fail as pinned, and the window is wrong in a
new way. Measured off window captures of the Debug build on 2026-10-04 (interface
scale 1, dark appearance, horizontal tabs, the window active):

**The title bar is two-toned.** Above the sidebar its rows read `bgPanel`
(`0x2B2D30`, captured as `323538`); above the editor column they read `bgCanvas`
(`0x1E1F22`, captured as `252729`) — the `ContentView` root's ground, which extends
into the title bar's safe area like any SwiftUI background. Before that plan the tab
strip's own `bgPanel` ground extended into the title bar too and covered the canvas
there, exactly as the sidebar's ground still does above the sidebar and the tab
column's does with vertical tabs; confining the strip's ground
(`ignoresSafeAreaEdges: []`) uncovered the canvas. The black separator row is gone
and the active tab's `bgEditor` fill now starts at the strip's top — both fixes stand.

So the strip's ground goes back to painting the title bar above the editor column,
deliberately and documented, and **only the active cell's fill stays confined**.
Rule forty-seven is re-scoped to say exactly that, in both directions: the cell's
fill must carry `ignoresSafeAreaEdges: []`, and the strip's ground must not.

## Validation Commands

```sh
swift test
xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-build test
swiftlint --strict
xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -configuration Release -destination 'platform=macOS' -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-build build
```

Derived data lives in that one folder and nowhere else; never inside the repository.
No product or brand names in code, comments, documents or commit messages. No
screen-recording API in any test. Hand mutations are run and reverted inside the task,
never committed. The work stays on the current branch; never create a new branch.

## Implementation Steps

### Task 1: The strip's ground paints the title bar; the tab's fill does not

**Files:**
- Modify: `Sources/Pisaka/TabStripView.swift`
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`
- Modify: `docs/architecture/core-theme.md`
- Modify: `docs/architecture/app-window.md`
- Modify: `docs/architecture/app-shell.md`

- [x] In `TabStripView.body`, the strip's ground becomes
      `.background(theme.color(.bgPanel))` again — no `ignoresSafeAreaEdges`. Replace
      its comment: the strip is the topmost view of the editor column under the
      transparent title bar, which is the window's top safe-area inset; the ground
      deliberately extends into it, because the `ContentView` root's ground is
      `bgCanvas` and would otherwise show there, two-toning the title bar against the
      sidebar's `bgPanel` (seen on 2026-10-04 with the ground confined). The sidebar
      and the vertical tab column paint the title bar the same way. The active cell's
      fill is the one that must not climb (see there).
- [x] In `TabStripCell.body`, the fill stays
      `.background(isActive ? theme.color(.bgEditor) : Color.clear, ignoresSafeAreaEdges: [])`;
      its comment says it is confined because a default background would climb
      through the title bar to the window's top edge, while the strip's ground above
      it is meant to.
- [x] Re-scope rule forty-seven in `ChromeThemeSourceGatingTests`, keeping its number,
      marker and the four bookkeeping places (header bullet, `spelled`, the canonical
      list item in `core-theme.md`, the count in `CLAUDE.md`, which does not change):
      - New title, used identically in the `// MARK:` marker, the header bullet and
        canonical item 47: **The tab's fill stays inside the strip; the strip's ground
        paints the title bar.**
      - The matcher splits the stripped text of `TabStripView.swift` at the
        `struct TabStripCell` declaration. Every colour background **after** it (the
        existing `unconfinedColourBackgrounds` logic) must carry
        `ignoresSafeAreaEdges: []`; every colour background **before** it must **not**
        carry `ignoresSafeAreaEdges` at all, so a confined strip ground fails the rule
        as loudly as an unconfined cell fill. Both halves must see at least one colour
        background, so neither can go vacuous.
      - The self-check feeds the matcher inline snippets for both halves: a confined
        ground before the declaration is flagged, an unconfined fill after it is
        flagged, the real file's shape passes, and `.background(alignment:)` is still
        ignored on both sides.
      - The rule's doc comment states the reason for each half and the horizon: this
        one file, arguments spelled `theme.color(` or `Color.`.
- [x] Hand mutations, not committed, each reverted before the next: (a) add
      `ignoresSafeAreaEdges: []` to the strip's ground — rule forty-seven must fail;
      (b) remove it from the cell's fill — rule forty-seven must fail. Record both
      outcomes in the commit message.
- [x] Documentation, each place made truthful again:
      - `core-theme.md`: canonical item 47 (title and reason); the horizontal tab
        strip entry — replace "both colour backgrounds confined" with the division
        above, and record the 2026-10-04 observation that confining the ground
        two-toned the title bar (`bgCanvas` above the editor column against `bgPanel`
        above the sidebar), which is why the ground paints the title bar on purpose.
        Keep the design comparison (title bar 28 on `bgPanel`, strip 32 on `bgPanel`,
        active fill inside the strip, no line).
      - `app-window.md`, `TabStripView.swift` entry: the same division in one or two
        sentences.
      - `app-shell.md`, `MainWindowChrome.swift` entry: wherever it says the strip's
        grounds are confined, say the fill is confined and the ground paints the title
        bar; the separator paragraph is unchanged.
      - `CLAUDE.md` is not touched (the count stays forty-seven).
- [x] Run `swift test`, the app-layer bundle and `swiftlint --strict`; all green.
- [x] Commit.

### Task 2: Final gates and a read of the branch diff

**Files:** none new.

- [ ] Run all four validation commands; record the counts in the commit message.
- [ ] `git diff 290f24a3..HEAD --stat` and read the diff of `TabStripView.swift`
      and the gating suite once more against the overview: no stray change, no product
      or brand name, every comment truthful about what is now pinned, `CLAUDE.md`
      unchanged.
- [ ] Commit if anything changed.
