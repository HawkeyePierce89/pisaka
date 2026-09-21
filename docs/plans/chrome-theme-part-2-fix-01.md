# Chrome theme part 2 — review fixes, round 01

## Overview

Answers the eight findings of revmux round `01-initial` on the task
`chrome-theme-part-2-gutter-regression-and-editor-pane-chrome`, all of them
`minor`, none of them gating. The record is
`.revmux/tasks/chrome-theme-part-2-gutter-regression-and-editor-pane-chrome/01-initial/report.md`.

Three of the eight are the same class of defect that let this branch's own
regression ship: a gate that does not exist, and documents that now say
something false to whoever reads them next. The rest are a locally derived
design value, a rule spelled twice, a duplicated pane rule, and a document
naming the wrong host.

Nothing here changes what any surface looks like except Task 5, which removes
one duplicated hairline.

## Development Approach

- Complete each task fully before moving to the next.
- **CRITICAL: every task that changes executable code MUST carry the test that
  would have caught the defect.** Two tasks here are documentation alone and
  carry none; each says so in its own text.
- **CRITICAL: all tests must pass before starting the next task.**
- Core gate: `swift test`. App gate: `xcodebuild -project Pisaka.xcodeproj
  -scheme Pisaka -destination 'platform=macOS' test`. Style gate:
  `swiftlint --strict` from the repository root.
- Builds and test runs write nothing into the repository tree: pass
  `-derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-chrome-theme-2`.
- No product or brand names anywhere — code, comments, docs or commit messages.
  `docs/plans/completed/` is the one deliberate exemption (a historical record);
  the reason is stated in `docs/architecture/core-theme.md`'s sweep guide.
- **Before committing each fix, sweep for the shape rather than the site.** Name
  the defect as a construct and grep for that construct across the repository,
  fixing every occurrence in the same commit. Three of these findings are about
  a claim restated in two places; fixing only the quoted one leaves the other.

## Validation Commands

```sh
swift test
xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-chrome-theme-2 test
swiftlint --strict
```

## Implementation Steps

### Task 1: Pin the gutter fill's call site, not only its seam

**Finding:** `Sources/Pisaka/LineNumberRulerView.swift:837`, minor, confidence 80.
`LineNumberRulerBackgroundTests` pins the pure rule
`backgroundRect(in:ruleThickness:)` and nothing pins that
`drawHashMarksAndLabels` still *uses* it. Changing line 837 back to
`rect.fill()` — the exact regression this branch exists to fix, which painted
the editor pane out in `bgEditor` and left the editor showing no code at all —
leaves all five new tests passing, `swift test` passing, the app bundle passing
and SwiftLint clean. The ticket's acceptance clause is therefore met only for a
widening *inside* the seam, which is the less likely of the two edits: the seam
carries a long doc comment naming the regression, while the call site is one
unremarkable line in a sixty-line drawing method.

**Fix:** a source-gating rule in the pattern the repository already uses for a
call site the compiler cannot see — `FoldingSourceGatingTests`' reveal-funnel
rule is the closest precedent: one definition, a counted set of callers.

**Files:**
  - Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`
  - Modify (only if the rule needs a stable token to match): `Sources/Pisaka/LineNumberRulerView.swift`

  - [x] Write the failing test first: a rule asserting that
        `LineNumberRulerView.swift` spells `backgroundRect(` exactly twice — the
        `static func` declaration and its one call — and that the file's
        `drawHashMarksAndLabels` body contains no bare `rect.fill(`. Match
        against comment- and literal-stripped text through
        `LSPSourceGatingTests.strippingCommentsAndStringLiterals(_:)`, as every
        other repository-file suite in this project does; a raw `contains` stays
        green when the thing it names is deleted from live code and left in a
        comment.
  - [x] Confirm it fails: temporarily restore `rect.fill()` at the call site,
        watch the new rule go red, then revert.
  - [x] Add the rule to `ChromeThemeSourceGatingTests` beside its five existing
        ones, with a doc comment naming the regression it exists to prevent and
        why the seam test alone cannot see it. **The suite's own self-check and
        its count of rules, if it states one, must be updated with it.**
  - [x] Sweep for the shape: any other chrome surface whose correctness now
        rests on a pure seam being *called* rather than merely existing. If the
        minimap or the consent strip has acquired one, pin it the same way in
        the same commit; if none has, say so in the commit message.
  - [x] run `swift test` and the app-layer bundle — must pass before Task 2

### Task 2: Make `CLAUDE.md`'s chrome invariant true again

**Finding:** `CLAUDE.md:734`, minor, confidence 90. Line 734 still reads
"`ChromeThemeSourceGatingTests` pins which files obey the rule (six, by set
equality)" while `gatedFiles` now holds eleven entries, and line 740 still reads
"Three surfaces are swept so far — the tab strip, the line-number ruler, the
project tree rows" while this branch swept four more: the vertical tab column,
the breadcrumb, the minimap's chrome and the consent strip. The index entries at
lines 417–418 were updated by the same branch, so the omission is in the
invariant paragraph alone. `CLAUDE.md` is loaded into every agent session, so an
agent picking up the follow-up sweep reads it, believes those surfaces are still
unswept, and either redoes them or reasons about `gatedFiles` from a count that
is off by five.

**Files:**
  - Modify: `CLAUDE.md`

  - [x] Correct both sentences: the gated-file count and the swept-surface list,
        naming the surfaces this part added.
  - [x] Read the whole chrome invariant paragraph against what the code now does
        and correct anything else in it the branch falsified — the role count,
        the exemptions, the two injection paths and the hairline exception are
        each a claim that must still hold.
  - [x] **Sweep for the shape:** a count or a list in `CLAUDE.md` that mirrors a
        set the branch changed. Check every invariant paragraph this branch's
        diff touched code for, not only the chrome one, and fix each in this
        commit.
  - [x] No test: `CLAUDE.md`'s prose is not read by any suite. Say so in the
        commit message rather than inventing one.
  - [x] run `swift test` — must pass before Task 3

### Task 3: Correct `core-theme.md`'s ledger of unspent roles

**Finding:** `docs/architecture/core-theme.md:61`, minor, confidence 85. The
paragraph says "`bgCanvas` and `bgPopover` wait for the window ground and the
popovers; **the three status hues** and the three diff/merge grounds wait for
the surfaces that mean them". Only `statusGreen` is unused: `statusRed` is drawn
at `Sources/Pisaka/ProjectTreeDraftField.swift:135` and `:626` and at
`Sources/Pisaka/LineNumberRulerView.swift:787`, and `statusYellow` at
`LineNumberRulerView.swift:788`. The same paragraph contradicts itself four
lines earlier, where the list of what part one left unused names `statusGreen`
alone. The claim about the three diff/merge grounds is correct — all three are
genuinely unused.

This paragraph is the sweep's running ledger of which roles are still unspent,
so a later part reading it would think the diagnostic markers and the draft
field's error state still wait to be restyled when they already draw from the
roles.

**Files:**
  - Modify: `docs/architecture/core-theme.md`

  - [x] Correct the sentence to name only the roles that are genuinely unused,
        and resolve the contradiction with the paragraph four lines above it.
  - [x] Verify each role's claim against the code before writing it: grep
        `Sources/` for every `ChromeColorRole` case and let the answer decide
        the sentence, rather than editing the two the finding quoted.
  - [x] Record the decision taken on this branch's review: the completed-plan
        archive under `docs/plans/completed/` is **deliberately exempt** from the
        no-product-names convention, being a historical record of what was
        decided and when. State it where the convention is stated, so the next
        review does not raise it again as an open question.
  - [x] No test: this is prose no suite reads. Say so in the commit message.
  - [x] run `swift test` — must pass before Task 4

### Task 4: Stop the minimap's comment denying the callback it relies on

**Finding:** `Sources/Pisaka/MinimapView.swift:24`, minor, confidence 95, raised
by the adversarial lens. The new comment says nothing observes an appearance
change because the dynamic colour resolves itself. The class still overrides
`viewDidChangeEffectiveAppearance()` at lines 115–119 and sets
`needsDisplay = true`. A dynamic colour resolves correctly only when drawing
occurs, and that callback is what schedules the drawing — so the override is
required and the comment invites a maintainer to delete it. The same inaccurate
claim is repeated in `docs/architecture/app-editor-overlays.md`.

**Files:**
  - Modify: `Sources/Pisaka/MinimapView.swift`
  - Modify: `docs/architecture/app-editor-overlays.md`

  - [x] Rewrite the comment to say what is actually true: the dynamic colour
        needs no cached value and no colour-specific observer, *and* the view
        must still be told to redraw when the effective appearance changes,
        which is what the override does.
  - [x] Fix the same claim in `app-editor-overlays.md`. **Both halves in one
        commit** — a fix that lands only at the site the finding quoted is the
        failure mode this plan's approach section names.
  - [x] **Sweep for the shape:** every place in this branch's diff that argues
        "nothing observes an appearance change" about an AppKit surface. The
        gutter and the editor pane make the same argument; confirm for each
        whether an appearance-change override exists beside it, and correct the
        prose wherever the two disagree.
  - [x] No test: a comment cannot be asserted. The protection is that the
        override itself is exercised by the app bundle if any suite touches it;
        do not add a test that merely restates the comment.
  - [x] run `swift test` and the app-layer bundle — must pass before Task 5

### Task 5: Let the splitter own the tab column's trailing edge

**Finding:** `Sources/Pisaka/TabListView.swift:16`, minor, confidence 75,
raised by two agents and refined by the verifier. The column draws its own
`hairline` on its trailing edge, justified in the doc comment as "a rule the
*host* drew would sit between the two and undo that" — the argument the
horizontal strip makes about its bottom rule. That argument does not transfer:
the column's host is not a `VStack` but the `HSplitView` in
`ContentView.editorSplit`, so AppKit draws a splitter divider at the
column/editor boundary whatever the column does — `app-window.md:303` already
budgets those dividers into the window's minimum width. The result is two
adjacent rules at that boundary, where the tree/column boundary immediately left
of it has one: `ProjectTreeView`, gated in part one and sitting in the same
split view, draws no pane-edge rule and relies on the splitter. The comment's
"an active row filled in `bgEditor` can merge into the editor beside it" cannot
happen in an `HSplitView` at all.

**Fix:** remove the column's own trailing hairline and its doc-comment
justification, matching `ProjectTreeView`'s treatment in the same container. The
verifier noted the second half of the original finding — that the overlay also
crosses the active row — is inherited from the horizontal strip's own shape and
is **not** introduced here; do not change the strip.

**Files:**
  - Modify: `Sources/Pisaka/TabListView.swift`
  - Modify: `docs/architecture/app-window.md`

  - [x] Remove the trailing hairline overlay and rewrite the doc comment to say
        why the column draws no pane-edge rule: the splitter already states that
        boundary, and the pane beside it in the same container states it the
        same way.
  - [x] Update the `TabListView` entry in `app-window.md` to match.
  - [x] **Sweep for the shape:** any other pane inside `editorSplit` that draws
        its own edge rule against a splitter. Fix each in this commit.
  - [x] Confirm by eye, by the headless capture procedure Task 7 of the original
        plan established: the column/editor boundary now shows one rule, and the
        tree/column boundary is unchanged. If no window can be obtained, say so
        plainly rather than claiming the check.
  - [x] run `swift test` and the app-layer bundle — must pass before Task 6

### Task 6: Stop the consent strip deriving a geometry token by arithmetic

**Finding:** `Sources/Pisaka/LSPConsentBanner.swift:196` and `:214`, minor,
confidence 90, raised by two agents. Both buttons pad vertically with
`metrics.scaled(ChromeGeometry.rowPaddingX / 2)`. `ChromeGeometry.swift`'s first
rule states the constraint literally: every token is scaled at its use site, and
no view multiplies one of these numbers by anything itself. These are the only
two sites in `Sources/` where a `ChromeGeometry` token appears in an arithmetic
expression, so the branch introduces the pattern rather than following one.

Nothing misrenders today and the rule's stated rationale about rounding is not
violated — `rowPaddingX` is a `Double`, so the division is exact and the scale is
still applied once. The defect is that a chrome view now derives a design value
locally, which is what the rule exists to prevent, and that it silently couples
two unrelated dimensions: a future change to `rowPaddingX`, a *horizontal*
row-padding token, would move the consent buttons' vertical padding with it with
nothing naming that relationship.

**Fix:** a bare local number, which the sweep guide already permits for a
surface's own measurements and which the same two lines already use for their
outer padding.

**Files:**
  - Modify: `Sources/Pisaka/LSPConsentBanner.swift`
  - Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`

  - [x] Write the failing test first: a gating rule that no gated file spells a
        `ChromeGeometry` token inside an arithmetic expression, matched against
        comment- and literal-stripped text. Confirm it is red against the two
        current lines before fixing them.
  - [x] Replace both expressions with the surface's own bare number, scaled once
        at the use site.
  - [x] **Sweep for the shape:** `ChromeGeometry\.[a-zA-Z]+\s*[*/+-]` across
        `Sources/`. Every hit is the same defect; fix them all here.
  - [x] run `swift test` and the app-layer bundle — must pass before Task 7

### Task 7: Spell the tab icon rule once

**Finding:** `Sources/Pisaka/TabRowView.swift:84`, minor, confidence 90.
`TabRowView.iconSymbolName` is byte-for-byte the same computed property and the
same five-line doc comment as `TabStripCell.iconSymbolName`, differing only in
the words "row's" and "tab's". Both resolve the same non-obvious rule: an
`OpenFile` with no `url` is asked about under its `displayName`, so `FileIcon`'s
own unknown-name fallback answers instead of a second guess. This is the one
thing in the diff that contradicts the argument the same commit makes —
`TabStatusMark` was lifted out of `TabStripCell` precisely because two spellings
of one rule drift the moment either is touched.

It has a second cost: `ChromeThemeSourceGatingTests.iconFreeLines` drops every
line containing `FileIcon(` from rule one's scan, so the paste adds a second
gated file carrying a line exempt from the no-system-colour check.

The bare `FileIcon(for: DirectoryEntry(url:…))` call is spelled inline at a
dozen sites across the repository and is the house pattern; the duplicated part
worth naming is the `OpenFile`-specific `url ?? displayName` fallback, not the
`FileIcon` call.

**Files:**
  - Modify: `Sources/Pisaka/TabStripView.swift`, `Sources/Pisaka/TabRowView.swift`
  - Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`
  - Modify: `docs/architecture/app-window.md`

  - [x] Lift the shared rule to one spelling, beside `TabStatusMark` and for the
        same stated reason, and have both orientations use it. Carry the doc
        comment to the one definition; neither call site restates it.
  - [x] Confirm both orientations render unchanged (by construction: the one
        view reproduces both call sites byte-for-byte — the same symbol rule at
        the same scaled size in the same role; no headless window was obtained,
        so this is not an eye check).
  - [x] Write the test that would have caught it: extend the gating suite so the
        rule is spelled in exactly one file, by count, in the pattern the suite
        already uses for its other one-definition rules. This is also what
        removes the second `iconFreeLines` exemption.
  - [x] Update the `TabStripView`/`TabRowView` entries in `app-window.md`.
  - [x] run `swift test` and the app-layer bundle — must pass before Task 8

### Task 8: Name the breadcrumb's real host in `app-window.md`

**Finding:** `docs/architecture/app-window.md:17`, minor, confidence 80. The
rewritten line puts the breadcrumb in the `if let file` branch of
`textEditorZone(for:onScrolled:)`. That member has no `if let file` branch at
all — it takes the file as a parameter — and its own doc comment says the
opposite of the document: "Everything a `.text` tab shows **below the
breadcrumb**: the consent banner, the find bar and the editor itself." The real
host is `ContentView.editorZone` at `ContentView.swift:972`. The listed contents
are also stale: the tab-kind routing and the preview split now sit between the
breadcrumb and the editor.

The mis-attribution predates the branch — the same line named the old view in
the same wrong host — but this change rewrote that exact sentence and carried
the error forward, so a reader following the new file name lands in the wrong
member.

**Files:**
  - Modify: `docs/architecture/app-window.md`

  - [x] Name `editorZone` as the host and list what it actually holds now,
        reading the member rather than the old sentence.
  - [x] **Sweep for the shape:** every sentence in `app-window.md` naming a
        `ContentView` member as a host. Check each against the member it names
        and correct the ones that are wrong, in this commit.
  - [x] No test: no suite reads this document's prose. Say so in the commit
        message.
  - [x] run `swift test` — must pass before Task 9

### Task 9: Run the gates

  - [ ] `swift test` — green
  - [ ] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-chrome-theme-2 test` — green
  - [ ] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'generic/platform=iOS' -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-chrome-theme-2 build` — the iOS target still builds
  - [ ] `swiftlint --strict` from the repository root — clean
  - [ ] Confirm each new gating rule fails when the defect it names is restored,
        then revert: the call-site rule against `rect.fill()`, the arithmetic
        rule against the divided token, the one-spelling rule against a second
        copy. A rule that cannot be made to fail is pinning nothing.
  - [ ] Confirm nothing was written into the repository tree
