# Chrome theme part 2 — review fixes, round 02

## Overview

Answers the two findings of revmux round `02-after-fix` on the task
`chrome-theme-part-2-gutter-regression-and-editor-pane-chrome`, both `minor`,
neither gating. The record is
`.revmux/tasks/chrome-theme-part-2-gutter-regression-and-editor-pane-chrome/02-after-fix/report.md`.

Both are prose: a canonical list that no longer matches the suite it describes,
and a paragraph whose stated rule is contradicted by the behaviour of the very
surface it names. No executable code is wrong. Nothing here changes what any
surface looks like.

**One of the two was settled by running the application**, and the measurement
is given in Task 2 so the document can state what was observed rather than what
was assumed. Do not re-argue it from documentation.

## Development Approach

- Complete each task fully before moving to the next.
- **CRITICAL: all tests must pass before starting the next task.**
- Task 1 carries the test that would have caught it. Task 2 is prose about
  platform behaviour that no gate in this project executes; it carries no test
  and says so.
- Core gate: `swift test`. App gate: `xcodebuild -project Pisaka.xcodeproj
  -scheme Pisaka -destination 'platform=macOS' test`. Style gate:
  `swiftlint --strict` from the repository root.
- Builds and test runs write nothing into the repository tree: pass
  `-derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-chrome-theme-2`.
- No product or brand names anywhere — code, comments, docs or commit messages.
  `docs/plans/completed/` is the one deliberate exemption, already recorded.
- **Before committing each fix, sweep for the shape rather than the site.** Both
  findings are a claim restated in several files; fixing only the quoted one
  leaves the others standing. Each task names the files the previous round's own
  commits touched, but grep for the claim rather than trusting that list.

## Validation Commands

```sh
swift test
xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-chrome-theme-2 test
swiftlint --strict
```

## Implementation Steps

### Task 1: Make the gating suite's rule count true in both documents

**Finding:** `docs/architecture/core-theme.md:376`, minor, confidence 90.
`ChromeThemeSourceGatingTests` now declares eight numbered rules — the three
added by the previous fix round are marked `// MARK: - Rule six/seven/eight` at
`Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift:295`, `:378` and
`:424`. Neither canonical summary came along: `core-theme.md:376` still opens
"The five rules, each invisible to the compiler:" and enumerates five, and
`CLAUDE.md:737` says "its six rules" — it was updated in the previous round to
add the gutter-fill rule alone, against a suite that had already reached eight.

That previous commit's own task was "a count or a list in `CLAUDE.md` that
mirrors a set the branch changed", so this is the same defect one level up: a
count that drifted from the set it names, in a repository whose habit is to
assert exact counts by set equality. The substance of each rule is documented
somewhere — rule seven in the `ChromeGeometry` entry and in
`ChromeGeometry.swift`'s own first rule, rule six in `core-theme.md`'s gutter
passage, rule eight in `app-window.md` — so no rule is genuinely undiscoverable.
What is wrong is that the one list a reader consults to learn what the suite
enforces names five of eight.

**Fix:** correct both counts and enumerate all eight in the canonical list, then
pin the pair so it cannot drift again.

**Files:**
  - Modify: `docs/architecture/core-theme.md`, `CLAUDE.md`
  - Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`

  - [x] Write the failing test first: a cross-file pair in the pattern
        `LintConfigurationTests` already uses for the style version spelled in
        two files. The suite states its own rule count once, as a declared
        constant or as a count of its rule markers, and the test asserts that
        `core-theme.md` and `CLAUDE.md` both spell that same number in the
        sentence naming it. Confirm it is red against the current five and six
        before correcting them.
  - [x] Correct `core-theme.md`'s canonical list: all eight rules, each in the
        one sentence that says what it forbids, in the suite's own order.
  - [x] Correct `CLAUDE.md`'s count in the same commit.
  - [x] **Sweep for the shape:** every count or enumeration in `core-theme.md`,
        `app-window.md`, `app-editor-overlays.md` and `CLAUDE.md` that mirrors a
        set this branch changed — the gated-file count, the role count, the
        swept-surface list, the exemption list. Check each against the code and
        fix every one that is wrong, in this commit.
  - [x] run `swift test` and the app-layer bundle — must pass before Task 2

### Task 2: State what the appearance change actually does, as observed

**Finding:** `docs/architecture/core-theme.md:162`, minor, confidence 80. The
previous round added one paragraph to five files —
`docs/architecture/core-theme.md:156-164`,
`Sources/Pisaka/ChromePalette.swift:105-111`,
`Sources/Pisaka/MinimapView.swift:26-33`,
`docs/architecture/app-editor-overlays.md:860-869` and `CLAUDE.md:731-733`. It
states a rule — a view that paints its whole content in `draw(_:)` rather than
handing AppKit a `backgroundColor` must override
`viewDidChangeEffectiveAppearance()` — and then classifies the chrome's surfaces
by it, saying the minimap is the one such view and that "the gutter, the editor
pane and the read-only viewer pane each hand AppKit a colour and so need none".

**The classification is false about the gutter.** `LineNumberRulerView` hands
AppKit nothing: it calls `ChromePalette.nsColor(.bgEditor).setFill()` and fills
`backgroundRect(in:ruleThickness:)` inside `drawHashMarksAndLabels(in:)`, and
the file spells neither `backgroundColor` nor `viewDidChangeEffectiveAppearance`
anywhere — `NSRulerView` has no `backgroundColor` to hand over. That is the same
shape the document ascribes to the minimap. The two panes named beside it are
classified correctly.

**The premise was settled by measurement, not by argument.** The application was
built from this branch, launched with the theme preference set to follow the
system, and the *system* appearance was switched while it ran, with no relaunch.
The dominant colour of a 50×500 point strip of the gutter and of a 200×500 point
strip of the editor pane beside it, sampled from a window capture:

| | dark | switched to light | switched back to dark |
|---|---|---|---|
| gutter | `#36393E` | `#FFFFFF` | `#36393E` |
| editor pane | `#36393E` | `#FFFFFF` | `#36393E` |

(The values are the display's rendering of the palette's sRGB entries, which is
why they are not the literal hex of `bgEditor`; what matters is that the two
strips agree and that both changed.) So a self-painting chrome view with **no**
`viewDidChangeEffectiveAppearance` override recoloured live, in both directions.
The paragraph's rule is therefore not true as stated.

**Fix:** the document says what is observed. The minimap's override is
**pre-existing on `master`, was not added by this branch, and is not removed
here** — nothing in this project executes it and nothing measured it, so
removing it would be a change made on an argument rather than on evidence.

**Files:**
  - Modify: `docs/architecture/core-theme.md`,
    `docs/architecture/app-editor-overlays.md`, `CLAUDE.md`
  - Modify: `Sources/Pisaka/ChromePalette.swift`, `Sources/Pisaka/MinimapView.swift`

  - [x] Replace the stated rule with the observation: a dynamic colour resolves
        whenever drawing happens, and a chrome view drawing one needs no cached
        value and no colour-specific observer. Say that the gutter, which paints
        its own background and overrides nothing, was measured recolouring live
        in both directions when the appearance changed under it.
  - [x] Remove the classification that calls the gutter a view that "hands
        AppKit a colour". Either drop the three-surface bucketing entirely or
        state it by what each surface actually does — the editor pane and the
        viewer pane set a `backgroundColor`; the gutter and the minimap paint
        their own.
  - [x] Say plainly what is *not* known: whether the minimap's override is
        required or redundant was not established, it predates this branch, and
        it stays until something measures it. A document that admits this is
        correct; one that asserts either way is not.
  - [x] **Sweep for the shape:** grep for the claim's wording across `Sources/`,
        `docs/` and `CLAUDE.md` — the previous round put it in five files and a
        fix landing in fewer leaves the rest contradicting the tree. Fix every
        occurrence in this commit.
  - [x] No test: no gate in this project executes an appearance change, which is
        exactly why the claim went unchecked. Say so in the commit message
        rather than inventing a test that restates the prose.
  - [x] run `swift test` and the app-layer bundle — must pass before Task 3

### Task 3: Run the gates

  - [x] `swift test` — green
  - [x] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-chrome-theme-2 test` — green
  - [x] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'generic/platform=iOS' -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-chrome-theme-2 build` — the iOS target still builds
  - [x] `swiftlint --strict` from the repository root — clean
  - [x] Confirm Task 1's cross-file rule fails when either document's count is
        changed by one, then revert. A pair that cannot be made to fail is
        pinning nothing.
  - [x] Confirm nothing was written into the repository tree
