# Fix plan 01 — revmux round 01-initial

## Overview

Answers the six findings and the one pre-existing finding of revmux round
`01-initial` on task `code-zone-palette-and-the-one-chrome-value`. All seven are
`minor`; none changes a colour value. Five are confirmed statements that a
comment, a document or a test makes a claim the code does not support, and one
is a real behavioural inconsistency this branch introduced: four read-only code
panes read the same syntax table as the editor but keep their base foreground on
the platform colour, which agreed with the editor before this change and no
longer does.

Nothing in the palette itself is in question. Every value stays exactly as it
is.

## Validation Commands

```sh
swift test
xcodegen generate && xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' test
xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'generic/platform=iOS' build
swiftlint --strict
```

## Implementation Steps

### Task 1: The recorded reason for the changed wash names a symptom that cannot occur

**Finding:** `Sources/Pisaka/ChromePalette.swift:81`, confirmed, two sources.

The comment added on the `selectionInactive` row says the old value "left an
unfocused selection and the line the caret is on indistinguishable". Verified
against the tree: `ChromeColorRole.currentLine` is painted **nowhere** — its only
occurrences are its declaration, the palette row and this comment — and
`selectionInactive` has exactly one consumer, `Sources/Pisaka/ProjectTreeView.swift:868`,
`case .selectedUnfocused`, which is a **project-tree row in a window that is not
key**, not an editor text selection. The two roles have never shared a surface
and one of them has never been drawn at all. The value change is right and stays;
the reason recorded for it is fiction, and the next reader of the chrome sweep
would conclude the editor's selection already goes through `selectionInactive`.

- [x] Rewrite the comment on the `selectionInactive` row. Say what the change
      actually does: it is the wash of a **project-tree row selected while the
      window is not key**, its one consumer, and it was made a deliberate step
      stronger because the design states that value. State plainly that
      `currentLine` is at present painted by nothing, so the two were never
      drawn together — remove every claim about an editor selection.
- [x] Rewrite the doc comment of
      `ChromePaletteTests.testTheInactiveSelectionWashIsNotTheCurrentLineWash`
      the same way, and keep the test: the rule it states is about a future in
      which a current-line highlight is added and must not silently take the
      selection's wash. Say exactly that, including that the two roles are not
      drawn together today, so the test is not read as evidence of a defect that
      was fixed.
- [x] Correct the same sentence in `docs/architecture/core-theme.md` (the
      `ChromePalette.swift` entry, around lines 144-150).
- [x] **Sweep for the shape, not the site.** The defect is *a comment or document
      that asserts a user-visible symptom without a drawing site behind it*. Grep
      the branch's diff for every other sentence describing what a chrome role
      looks like on screen, and confirm each names a role with a real consumer.
      Fix every occurrence in this commit.
- [x] Test that would have caught it: add, to `ChromePaletteTests`, an assertion
      that `selectionInactive` has at least one consumer in `Sources/` and that
      the claim in its comment names that consumer — or, if that is not
      expressible, a comment on the row naming its one consumer by file, so a
      future reader checks a name rather than a symptom. State which of the two
      was chosen and why.

### Task 2: Four code panes read the syntax table and keep the platform base colour

**Findings:** `Sources/Pisaka/DiffView.swift:122`, `Sources/Pisaka/DiffView.swift:237`,
`Sources/Pisaka/SyntaxTheme.swift:351` — one defect reported by three agents,
all confirmed.

This branch moved the two editor text views off the platform label colour and
onto `SyntaxTheme.shared.color(for: .plain)`. Four other views attach a
highlighter over the *same* table and set only `.font`, never a base colour —
verified: `textColor` appears three times in the whole macOS layer and in none of
these files. `Sources/Pisaka/DiffView.swift:122`, `Sources/Pisaka/SourceViewerContent.swift:133`,
`Sources/Pisaka/iOS/DiffView_iOS.swift:87` and `Sources/Pisaka/iOS/MergeView_iOS.swift:311`.

Before this change the editor and these panes agreed, because the editor's
`.plain` fell back to the platform colour too. They now disagree: in dark
appearance the editor paints uncovered text `#dfe1e5` while a diff pane beside it
paints the same characters pure white, and a file with no grammar renders the
whole pane at the platform colour. **The inconsistency is this branch's own**,
and the plan's goal says every character in a file follows the table. The
ticket's out-of-scope list excludes the *chrome* sweep, not the code zone.

- [x] Set the base foreground from `SyntaxTheme.shared.color(for: .plain)` in all
      four views, beside the `.font` assignment each already makes. Comment each
      as what it is — the colour of a character no capture covers, read from the
      one table rather than left on the platform default.
- [x] **Sweep for the shape, not the site.** The defect is *a view that attaches
      the syntax highlighter over `SyntaxTheme` but never sets its own base
      foreground*. Find every such view by searching for the highlighter
      attachment rather than for `textColor`, since the defect is the absence of
      that word. Confirm the list is exactly these four plus the two editors
      already done, and name in the commit message what was searched for.
- [x] Two comments overstate the agreement today and must be re-read after the
      sweep: `DiffView.swift` ("mapping each capture … exactly like the editor")
      and `SourceViewerContent.swift:246-249` ("the same three lines the editor
      and the diff panes use, so a `.swiftinterface` reads exactly like a project
      file"). If the sweep makes them true, leave them; if any clause is still
      wider than the code, narrow it.
- [x] Test that would have caught it: an app-layer test asserting that every
      macOS view which attaches the syntax highlighter also sets a base
      foreground — a source-gating test over `Sources/Pisaka`, in the style of the
      repository's other gating suites, reading the files through `#filePath` and
      matching against comment- and literal-stripped text. Pin the set of such
      views by **set equality**, so a sixth pane added later is a red test rather
      than a silent regression.

### Task 3: A test claims to pin two call sites and can see neither

**Finding:** `Tests/PisakaAppTests/SyntaxThemeTests.swift:207`, confirmed.

`testUncoveredTextReadsThePlainRowInBothAppearances`'s doc comment says two sites
read the plain colour and that the test pins them so neither "can drift back onto
a platform label colour … without the suite noticing";
`docs/architecture/app-editor.md:28` restates it. The body only asserts that
`SyntaxTheme.shared.nsColor(for: .plain)` equals the expected row — which
`testEveryTokenKindResolvesToItsTabledValueInBothAppearances` already asserts by
looping `allCases`. Deleting the base-foreground assignment at
`Sources/Pisaka/CodeEditorView.swift:246`, or reverting the reset path at `:3598`,
leaves every suite green.

Verified: `applyBaseTypography(to:)` is `private`, so `@testable import` cannot
reach it — which is why the test was written against the expression instead.

- [ ] Make `applyBaseTypography(to:)` `internal` rather than `private`, with a
      doc comment saying why, in the same words the branch already uses for
      `SyntaxTheme.plainText`: the suite has to assert the site directly, because
      asserting the expression it contains pins nothing about the site.
- [ ] Rewrite the test to call `applyBaseTypography(to:)` on a fresh `NSTextView`
      and assert that view's `textColor` resolves to the `.plain` row in both
      appearances. That is the assertion the doc comment already claims.
- [ ] State honestly, in the test's doc comment, what is still not pinned — the
      no-grammar reset path at `:3598`, if it remains unreachable from the bundle
      — in the same shape as the preview-seam test three methods above, which is
      scrupulous about its own limit. If the reset path can be reached, pin it
      too and say so instead.
- [ ] Correct `docs/architecture/app-editor.md:28` to claim exactly what the test
      now pins, no more.
- [ ] **Sweep for the shape, not the site.** The defect is *a test whose doc
      comment claims coverage its body does not have*. Re-read every test doc
      comment this branch added — in `SyntaxThemeTests`, `ChromePaletteTests` and
      `MarkdownPreviewThemeTests` — and check each claim against the assertions
      below it. Fix every overstatement in this commit.

### Task 4: The preview pin's stated reach, and the guard that is actually missing

**Finding:** `docs/architecture/core-markdown-preview.md:704`, refined.

The document (transcribing the plan) says the new seam pin catches "any palette
edit made on one side only". It does not. `markdownPreviewTheme(prefersDark:)`
builds its result entirely from `SyntaxTheme.table` and `withCodeColors(_:)`
replaces the block wholesale, so `MarkdownPreviewTheme.light/.dark`'s own
`codeColors` never appear in the derived theme and the test never reads them.
Editing `SyntaxTheme.table` and the suite's restated row together — the correct
way to change the palette — leaves Core's copy stale with every gate green, which
is precisely the state the ticket opened by calling it a defect.

Nothing renders wrong today: on macOS the stale copy is a dead value. The defect
is the claim, and the absent guard behind
`Sources/PisakaCore/MarkdownPreviewTheme.swift:130`'s "The two copies now state
the same values".

- [ ] Add the guard rather than only narrowing the claim: an app-layer test
      asserting that `MarkdownPreviewTheme.light.codeColors` and `.dark.codeColors`
      equal, entry for entry over `SyntaxTokenKind.allCases`, the CSS strings of
      the editor table's rows for the matching appearance. It belongs in the app
      bundle because Core cannot see `SyntaxTheme`.
- [ ] Only then restate the honesty clause in
      `docs/architecture/core-markdown-preview.md` and in the test's own doc
      comment, to say what is true once the guard exists — the two copies are now
      compared, and what remains unpinnable is the derivation being deleted while
      both tables agree.
- [ ] **Sweep for the shape, not the site.** The defect is *a stated guarantee
      wider than the assertion behind it*. Check the other honesty clauses this
      branch wrote — in `MarkdownPreviewTheme.swift`, `SyntaxTheme.swift` and the
      three architecture documents — against the tests they name.

### Task 5: A doc comment that now contradicts the file beside it

**Finding:** pre-existing, `Sources/Pisaka/SyntaxTheme.swift:208`.

`markdownPreviewTheme(prefersDark:)`'s doc comment says
`MarkdownPreviewTheme.light`/`.dark` "keep only the chrome" and that "adding a
token kind reaches the preview with no second edit". Both clauses are false: each
theme carries a full fourteen-entry `codeColors` block — updating exactly those
was Task 3 of the original plan — and adding a case to `SyntaxTokenKind` now fails
at least two suites. The wording pre-dates this branch, but this branch writes the
opposite a few lines away and leaves the stale half on the one function a
maintainer reads when asking whether the Core tables matter.

- [ ] Rewrite both clauses to match what the code and the new tests state.
- [ ] Confirm no other doc comment in the branch's diff repeats either clause.

### Task 6: Gates

- [ ] `swift test` — green, with the count recorded.
- [ ] `xcodegen generate` then the macOS app-layer bundle — green, with the count
      recorded and the new tests named.
- [ ] `xcodebuild … -destination 'generic/platform=iOS' build` — succeeds (Task 2
      touches two iOS files).
- [ ] `swiftlint --strict` — clean.
- [ ] Re-read all seven findings against the diff and confirm each is answered at
      the mechanism it names, not at the example it uses.
