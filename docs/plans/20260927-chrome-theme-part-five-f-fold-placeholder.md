# Chrome theme, part five (f): the fold placeholder

## Overview

Draw the fold placeholder (the `…` standing where a collapsed block was) from the chrome palette instead of `NSColor.secondaryLabelColor`, and close the macOS colour sweep with the claim stated once and bounded.

- The glyph takes `textSecondary`, the role the fold chevron already draws the same fact with.
- The rounded outline takes `hairline` at its own value. The composed `withAlphaComponent(0.5)` goes away, and the line width becomes `ChromeGeometry.hairlineWidth`, unscaled, citing the ruler's existing precedent rather than restating it.
- Both colours become assertable headlessly through seams that the draw actually spends. The chevron gains the matching seam so the test can prove the two renderings agree.
- That the draw spends those seams is pinned as a **second clause of chrome rule six** (the gutter's fill still goes through its own rule), not as a new rule and not in another suite.
- `BracketOverlayLayoutManager.swift` joins the gated set (fifty-nine to sixty) and `unsweptColorSurfaces` empties. Rule forty-three stays at full strength, and its live half is described within its measured bound.
- Rule twenty-nine's blindness to the local-variable and helper-call alpha forms is recorded as a named known gap. `ProjectTreeView.swift`'s drop-target alpha is named as a measured item waiting for a part of its own. Neither is fixed here.

No new role and no Core change. `ChromeColorRole` stays at twenty-one, with `currentLine` and `bracketMatch` the two unspent. The chrome suite's declared rule count (forty-three) does not change.

### What was measured before drafting (requirement 4)

The file was added to `gatedFiles` in a scratch worktree, with the glyph colour switched to the palette and `unsweptColorSurfaces` emptied. The whole `ChromeThemeSourceGatingTests` suite passed, including:

- rule one (no system semantic colour)
- the hex-literal rule
- rule seven (no geometry token derived by arithmetic)
- rule twenty-seven (each measurement follows its own zone: its clauses are per-file, none keyed on membership)
- the chrome-glyph sizing rule (the file builds no symbol image)
- the severity rule (the file's `nsDiagnosticColor` is the code zone's `SyntaxTheme`, outside the rule)
- the layer-colour rule
- the every-gated-file-names-a-role self-check
- rule forty-three

The one finding is rule twenty-nine. Its alpha clause only matches an alpha chained directly onto `nsColor(`, `.color(` or `chromeColor(`. So `color.withAlphaComponent(0.5)` on a local passes while breaking what the rule's comment says, and so does `ProjectTreeView.swift:936` (`resolving(.accent).opacity(0.4)`). This part removes its own instance and records the gap.

The two legitimate departures, the code font and the font-measured inset, gap and height, trip no rule. They are nonetheless stated at their sites as zone statements (see Task 1), so a later rule keyed on membership meets a stated reason rather than a silent number.

One constraint follows from rule seven, the geometry-arithmetic rule. The outline's half-point inset must stay a bare local number (`insetBy(dx: 0.5, dy: 0.5)`) and must never be written as `ChromeGeometry.hairlineWidth / 2`.

## Context

Files involved:
- `Sources/Pisaka/BracketOverlayLayoutManager.swift`: the placeholder draw (`paintFoldPlaceholders`), `placeholderRect(forFoldedRangeAt:)`, `editorFont`
- `Sources/Pisaka/LineNumberRulerView.swift`:
  - `numberAttributes` (the precedent seam)
  - `drawFoldChevron` (a local `ChromePalette.nsColor(.textSecondary)`)
  - the unscaled-hairline precedent comment in `drawHashMarksAndLabels` (~819–824), which ends "The next AppKit chrome surface follows this precedent rather than inventing a second answer"
- `Tests/PisakaAppTests/GutterFoldTests.swift`: `testRulerResolvesItsColoursFromThePaletteInBothAppearances`, the test to mirror, plus the colour helpers
- `Tests/PisakaAppTests/EditorLayoutHarness.swift`: the headless TextKit 1 stack with a `BracketOverlayLayoutManager`
- `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`:
  - `gatedFiles`
  - rule six's `testTheGutterFillGoesThroughItsOwnRule` (the home of the new clause)
  - rule twenty-nine's doc comment
  - `unsweptColorSurfaces` and rule forty-three's doc comments
- `docs/architecture/app-editor-overlays.md`: the overlay entry, including the placeholder paragraph (~line 331–342); the ruler entry for the chevron seam
- `docs/architecture/core-theme.md`:
  - the new part's section after part five (e)
  - part five (e)'s paragraph (~1905–1920) and part five (d)'s opening (~1679)
  - *What is still waiting* (~1988–2019)
  - the gated-set paragraph (~2057)
  - rule six (~2111), rule twenty-nine (~2559) and rule forty-three (~2800)
- `CLAUDE.md`: the colour-invariant paragraph (~743 "fifty-nine", ~780 "today the fold placeholder's…", ~788 "Fifty-five surfaces", the unspent-roles sentence, "the rest is the follow-up sweep", and the rule-list clause describing the gutter's fill)

Related patterns:
- `numberAttributes`: an `internal` computed seam holding the dynamic palette colour, spent by the draw.
- Rule six, `testTheGutterFillGoesThroughItsOwnRule`: a seam pins nothing its call site does not spend. That call site was this sweep's one regression.
- The `hairlineWidth`-unscaled precedent at `LineNumberRulerView.swift:819–824`, the site the token's own doc comment points at.

Dependencies: none.

## Development Approach

- **Testing approach**: regular (code first, then tests). Each task verifies by **mutation** where the ticket asks for it, and records the verification in the test's own doc comment.
- Complete each task fully before moving to the next.
- No product or brand names anywhere: code, comments, documents or commit messages.
- Local builds use `~/Library/Developer/Xcode/DerivedData/pisaka-<purpose>`, never a derived-data path inside the repository.
- Do not widen, weaken or except any rule. If a rule cannot accept the file, stop and report.
- **CRITICAL: every task MUST include new/updated tests.**
- **CRITICAL: all tests must pass before starting the next task.**

## Implementation Steps

### Task 1: The placeholder draws from the palette through a spent seam

**Files:**
- Modify: `Sources/Pisaka/BracketOverlayLayoutManager.swift`
- Modify: `Sources/Pisaka/LineNumberRulerView.swift`

- [ ] Add an `internal` computed `placeholderAttributes` to `BracketOverlayLayoutManager`: `[.font: editorFont, .foregroundColor: ChromePalette.nsColor(.textSecondary)]`. Use the **dynamic** form, never `nsColor(_:in:)`. Its doc comment mirrors `numberAttributes`: it is `internal` because the app-layer suite reads it, and the dynamic colour answers under both appearances without the manager being told which.
- [ ] Add an `internal` computed `placeholderOutlineColor` returning `ChromePalette.nsColor(.hairline)`. Document it as the chrome's one answer for a rounded container's one-point border (the shared field, secondary button, off checkbox, segmented control, stepper and off switch track in `ChromeControls.swift`). It stays quieter than the glyph, which is what the former half alpha was for.
- [ ] Rewrite `paintFoldPlaceholders` so it **spends both seams**:
  - build the text from `placeholderAttributes`
  - stroke with `placeholderOutlineColor.setStroke()`
  - set `outline.lineWidth = CGFloat(ChromeGeometry.hairlineWidth)`, unscaled. The comment is **one clause** naming the precedent it follows, `LineNumberRulerView.swift`'s gutter hairline, and stops there. Do not restate the four-line reason: two copies of one reason are two things to keep in agreement.
  - keep `insetBy(dx: 0.5, dy: 0.5)` as a bare local number (rule seven)
  - leave no `NSColor`, `ChromePalette`, `.foregroundColor` or `withAlphaComponent` in the method body itself
- [ ] Replace the doc comment that justified `secondaryLabelColor` by answering it:
  - The bridge is appearance-aware too. A dynamic colour resolves at draw time under `.aqua` and `.darkAqua`, so there is still no second table.
  - The stronger reason: the gutter chevron draws the same fact (*this block is folded*) from the same role, so the two agree by construction.
  - The code zone cannot hold `…`: its table is keyed by `SyntaxTokenKind`, and nothing in the buffer says `…`.
- [ ] State the two zone departures at their sites, as zone statements and not as exceptions:
  - on the seam's `.font` (and `editorFont`): the placeholder is drawn at the **code** font because it stands in the document's own text flow
  - in `placeholderRect(forFoldedRangeAt:)`: the inset, gap and height are measured **from that font**, which is the code zone's measurement, not the chrome's point tokens
  - geometry values are unchanged
- [ ] In `LineNumberRulerView.swift`, add an `internal` computed `foldChevronColor` returning `ChromePalette.nsColor(.textSecondary)`. Make `drawFoldChevron` spend it instead of its local palette call. Document it as the seam the placeholder is compared against.
- [ ] Build the macOS scheme and run `swift test`. No Core test changes are expected yet, but the full suite must pass.

### Task 2: The app-layer test: glyph, outline and chevron, under both appearances

**Files:**
- Modify: `Tests/PisakaAppTests/GutterFoldTests.swift`, or create `Tests/PisakaAppTests/FoldPlaceholderColourTests.swift` alongside it, whichever keeps the helpers single. Do not duplicate `resolved`, `components` or `assertSameColour`; if a second file needs them, lift them to a shared internal helper.

- [ ] Add a placeholder test mirroring `testRulerResolvesItsColoursFromThePaletteInBothAppearances`. For `.aqua` and `.darkAqua`, assert:
  - `placeholderAttributes[.foregroundColor]` resolves to the palette's `textSecondary`
  - it is **not** `NSColor.secondaryLabelColor`
  - `placeholderOutlineColor` resolves to the palette's `hairline`
  - the outline is not `secondaryLabelColor` at 0.5 alpha, the colour it drew with before
- [ ] Assert that the placeholder's glyph colour equals the ruler's `foldChevronColor` under both appearances. This agreement is the part's whole point. State in the doc comment that a value frozen at construction would pass one appearance and fail the other.
- [ ] Mutation-check each of the following and restore after each. Record in the test's doc comment that this was checked by doing it, not assumed:
  - (a) replace the palette call in `placeholderAttributes` with `NSColor.secondaryLabelColor`: the test goes red
  - (b) change `placeholderOutlineColor` to another role: red
  - (c) change `foldChevronColor` to another role: red
- [ ] Run the app bundle and confirm it passes: `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-test test`

### Task 3: The draw spends the seams, as rule six's second clause

**Files:**
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`

- [ ] Grow rule six (`testTheGutterFillGoesThroughItsOwnRule`) with a **second clause** in the same test method. It is not a new rule, so the declared count stays forty-three. Keep the rule's marker title unchanged, so the canonical-list and summary-count tests stay green. The clause checks the stripped source:
  - the body of `paintFoldPlaceholders` in `BracketOverlayLayoutManager.swift` names `placeholderAttributes` and `placeholderOutlineColor`
  - it names none of `ChromePalette`, `NSColor`, `foregroundColor`, `withAlphaComponent`
  - `drawFoldChevron` in the ruler names `foldChevronColor` and not `ChromePalette`
  - each missing body fails with a "re-point this rule rather than losing it" message, in the first clause's idiom
- [ ] Extend rule six's doc comment: the principle "a seam pins nothing its call site does not spend" now has three spent seams, the gutter fill, the placeholder and the chevron. A later reader auditing which seams must be spent finds all three here.
- [ ] Mutation-check: re-inline an equivalent attribute dictionary in the draw, and separately restore the chevron's local palette call. Confirm the clause goes red each time, then restore. Record this in rule six's doc comment.
- [ ] Run `swift test`. It must pass.

### Task 4: The gated set grows to sixty; the unswept set empties; rule twenty-nine's gap is named

**Files:**
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`

- [ ] Add `BracketOverlayLayoutManager.swift` to `gatedFiles` with a comment naming part five (f).
- [ ] Empty `unsweptColorSurfaces` (`[]`). Rewrite its doc comment, stating the bound:
  - The set is empty today. The fold placeholder left it in part five (f).
  - The **live half** of rule forty-three is the set-equality check between the measured surfaces and this set. Its measurement skips gated and exempt files, so it guards only the macOS app files that are **neither gated nor exempt**. It fails when one of those starts painting outside the roles.
  - A file that has joined the gated set is guarded by rule one instead, not by rule forty-three.
  - The **document half** is dormant while the set is empty. It wakes up again only when the live half measures a surface.
  - A dormant half is not a dead rule.
  - Do not write that it fails the moment *any* new unswept surface appears.
- [ ] Update rule forty-three's doc comment with the same bound. Its history reads in the past tense: part five (d) and part five (e) each made the claim, and neither was true.
- [ ] Add a **named known gap** to rule twenty-nine's doc comment. The alpha clause sees an alpha chained directly onto `nsColor(`, `.color(` or `chromeColor(` only, so it misses:
  - the local-variable form (the fold placeholder's former `color.withAlphaComponent(0.5)`, removed in part five (f))
  - the helper-call form (`ProjectTreeView.swift`'s drop-target `resolving(.accent).opacity(0.4)`, which passes today)
  - The rule is not strengthened here, and `core-theme.md` names the surface under *What is still waiting*. Do not change the rule's regex and do not touch `ProjectTreeView.swift`.
- [ ] Mutation-verify rule forty-three:
  - temporarily introduce a semantic colour (e.g. `.systemRed`) into an ungated, non-exempt macOS chrome file
  - confirm the test fails and its message names that file
  - restore the file
  - record the verification (file used, message seen) in the rule's doc comment
- [ ] Confirm by running the suite that every membership-keyed rule passes for the new member, with no rule changed beyond the set and comment edits above.
- [ ] Run `swift test`. It must pass.

### Task 5: Documentation

**Files:**
- Modify: `docs/architecture/app-editor-overlays.md`
- Modify: `docs/architecture/core-theme.md`
- Modify: `CLAUDE.md`

- [ ] **`app-editor-overlays.md`, overlay entry**:
  - the placeholder's colours: glyph `textSecondary`, outline `hairline` at `hairlineWidth` unscaled (following the ruler's precedent), no composed alpha
  - the two seams, and that the draw spends them (rule six)
  - the chevron agreement
  - the code-font and font-measured geometry as the code zone's measurements
- [ ] **`app-editor-overlays.md`, ruler entry**: add `foldChevronColor`.
- [ ] **`core-theme.md`, new section *Part five (f): the fold placeholder***:
  - the decision and its three reasons: the role's definition, the code zone's table has no token for `…`, and the chevron settles the tie
  - the outline's `hairline` and why
  - no new role; the gated set goes from fifty-nine to sixty
  - the measured rule-by-rule result from the Overview
  - rule six's second clause
  - rule twenty-nine's recorded gap
  - the mutation verifications
- [ ] **`core-theme.md`, the sweep claim**: say **once** that the macOS colour sweep is closed, meaning every macOS chrome surface draws from the roles. In the same place, say what closed does **not** mean: the theme still has open questions, and they stay named (the terminal's own palette, the caret readout, the lane hues, the unified diff's per-line checkbox glyph and changed-line text tint, and now the tree's drop-target alpha). No sentence may read as "the theme is finished".
- [ ] **`core-theme.md`, part five (e)'s paragraph and part five (d)'s opening**: reconcile both so neither reads as a present-tense statement about what remains. Keep the facts that the claim was made twice and was twice false, and that this surface is what made the second one wrong.
- [ ] **`core-theme.md`, *What is still waiting***:
  - drop the placeholder as a remaining surface
  - add `ProjectTreeView.swift`'s drop-target (`resolving(.accent).opacity(0.4)`) as a measured item for a part of its own. State why it is not fixed here: `accentTint` carries alpha `0x22` and `accentTintStrong` `0x33` against the `0.4` in use, so a role swap is a visible change to the drop-target highlight and is another surface's design question.
  - keep the other deferred items
  - update the surface count (fifty-five to fifty-six) and the unspent-roles sentence (still `currentLine` and `bracketMatch`)
- [ ] **`core-theme.md`, gated-set paragraph**: add part five (f)'s one file, **sixty** in all.
- [ ] **`core-theme.md`, rule six's entry**: grows with the second clause (the placeholder's two seams and the chevron's, each spent by its draw). Its title is unchanged.
- [ ] **`core-theme.md`, rule twenty-nine's entry**: add the known gap.
- [ ] **`core-theme.md`, rule forty-three's entry**:
  - the set is now `{}`
  - the live half and its bound: files neither gated nor exempt; a newly gated file falls to rule one
  - the dormant document half
  - the mutation verification
- [ ] **`CLAUDE.md`**:
  - "fifty-nine" becomes "sixty"
  - the rule-forty-three clause loses "today the fold placeholder's `BracketOverlayLayoutManager.swift`". It states that the set is empty and that the live half still guards the ungated, non-exempt macOS files.
  - the rule-six clause (the gutter's fill) notes that the placeholder's and chevron's seams are spent too
  - "Fifty-five surfaces" becomes "Fifty-six", with part five (f)'s fold placeholder appended to the list, spending no new role
  - add the one bounded closure sentence, consistent with `core-theme.md`
  - keep "forty-three rules" unchanged
  - index and invariant text only; no essays
- [ ] Run `swift test`. `testBothSummariesSpellTheSuitesOwnRuleCount` and the canonical-list tests must stay green.

### Task 6: Verify acceptance criteria

- [ ] Grep the stripped `BracketOverlayLayoutManager.swift`: no platform semantic colour and no hex literal; its colour statements reach the palette.
- [ ] Grep all docs and `CLAUDE.md` for any sentence claiming the theme itself is finished, and for any claim that rule forty-three guards gated files. Expect none of either.
- [ ] `swift test`: green.
- [ ] App-layer bundle: `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-test test`: green.
- [ ] `swiftlint --strict` from the repository root: clean.
- [ ] macOS build: `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' -configuration Release -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-build build`.
- [ ] iOS build: `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'generic/platform=iOS' -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-ios build`.

### Task 7: Update documentation

- [ ] README.md: no user-facing change (the placeholder's colour shifts slightly; no feature or shortcut changes), so there is nothing to update. Confirm.
- [ ] CLAUDE.md: already updated in Task 5. Re-read the colour-invariant paragraph once to confirm the counts agree: sixty gated, fifty-six surfaces, forty-three rules, two unspent roles.

## Post-Completion

Manual verification:
- In a running build, fold a block under both light and dark appearance. Confirm that the `…` and the gutter chevron read as the same grey, and that the outline reads quieter than the glyph. If the outline reads badly, the remedy is a change to `hairline` itself, never a local override.
