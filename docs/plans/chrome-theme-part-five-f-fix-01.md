# Chrome theme, part five (f) — fix 01

## Overview

Answers revmux round `01-initial` on task `chrome-theme-part-five-f-fold-placeholder`
(4 of 4 sources, not degraded, one kept finding at confidence 95 confirmed by two
agents, plus one finding synthesis dropped that this session reinstated after
re-deriving it in the tree).

Both findings are prose defects in the chrome gating suite and the two summaries:
sentences describing what a rule guards that no longer match what it measures.
That is the exact class part five (f) added rule forty-three for, one level down,
so shipping either would be the branch contradicting its own subject.

Task 3 is the structural half, found while checking whether a test was warranted:
the `0xRRGGBB` pattern is spelled twice, so the handoff the documents describe is
true by coincidence rather than by construction.

Nothing here touches the fold placeholder, its colours, its seams or its geometry.

## Validation Commands

```sh
swift test
xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-apptest test
swiftlint --strict
```

## Implementation Steps

### Task 1: Rule forty-three's scanner example names a file that no longer carries it

`Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift:4761`

Rule forty-three's doc comment justifies reading sources through the ordinary
(comment- and literal-stripping) scanner with an example: "a doc comment
discussing `.secondaryLabelColor` — `BracketOverlayLayoutManager.swift` has one,
and the gated files document their own rules the same way — paints nothing."

The example is dead twice over after this branch. `BracketOverlayLayoutManager.swift`
now contains **zero** occurrences of `secondaryLabel` (measured: the draw's call is
gone and its doc comment was rewritten), and the file is now in `gatedFiles`, so
rule forty-three's own walk skips it and it could not illustrate what that walk
reads even if the comment were still there. A reader checking why the ordinary
scanner was chosen is sent to an example that does not exist.

- [x] Remove the file reference, keeping the reason. The generic half is true and
      is what the sentence is for: the gated files document their own rules in
      comments that paint nothing. Do **not** substitute another file name.
- [x] No test is added, and this is the reason, stated in the comment or the commit
      message rather than left implicit: the fix removes the decay surface instead of
      guarding it. A doc comment that names no file has no example to go stale, so
      there is nothing for a test to pin. `core-theme.md`'s matching sentence already
      states the reason without naming a file and needs no change — confirm that and
      leave it alone.

### Task 2: The documented handoff names one rule where the measurement needs two

`Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift:4712`,
`docs/architecture/core-theme.md` (rule forty-three's entry), `CLAUDE.md:783`

Rule forty-three measures three triggers: a system semantic colour, a SwiftUI hue,
and a `0xRRGGBB` literal. Rule one covers the first two. The hex literal is **rule
two**'s (`testOnlyThePaletteSpellsAHexColorLiteral`). So the bound this branch added
— correct in saying the live half guards only files neither gated nor exempt — hands
a newly gated file to "rule one" alone, which is incomplete: a gated file that starts
spelling `0xRRGGBB` fails rule two, not rule one. Nothing is unguarded; the defect is
that a reader following the documented handoff checks the wrong rule for the hex case.

`core-theme.md` also contradicts itself across ten lines: its rule forty-three entry
opens by naming all three triggers and then hands the gated case to one rule.

- [x] Say **rules one and two** at each of the three sites, naming which half each
      takes (semantic colour and hue; hex literal).
- [x] **Leave `ChromeThemeSourceGatingTests.swift:4749` exactly as it is.** It reads
      "a gated file *painting a system colour* is rule one's failure" — scoped to
      system colours, so it is already true. Changing it would be churn, and widening
      it to mention hex would make a sentence about one case describe two. State in
      the commit message that this site was checked and deliberately not changed, so
      a later reader does not read the asymmetry as an oversight.
- [x] Re-read each edited sentence against the measurement it describes, not against
      the other sentences. Two of the three sit inside passages that already enumerate
      the triggers correctly; the fix is to make the handoff agree with that
      enumeration, not to re-word the enumeration.

### Task 3: One `0xRRGGBB` declaration, so the handoff holds by construction

`Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift:459` and `:4767`

Rule forty-three shares rule one's `forbiddenSemanticColors` and `forbiddenHues`
statics, so those two triggers cannot drift apart from what rule one catches. The
hex trigger does not: rule two builds `0x[0-9A-Fa-f]{6}` at line 459 and rule
forty-three builds the same pattern again at line 4767, as two separate literals.

That is what makes Task 2's corrected sentence true only by coincidence. Widen rule
forty-three's copy — to eight digits, say — without touching rule two's, and a gated
file spelling the new form is caught by **neither**: rule forty-three skips gated
files by construction, and rule two's narrower pattern does not match. The documents
would still promise a handoff that no longer exists.

- [x] Hoist the `0xRRGGBB` pattern to one declaration both rules read, with a doc
      comment saying why it is shared: the gated half and the ungated half of the same
      question must ask it in the same words, or the handoff the documents describe
      becomes false silently.
- [x] **Leave line 4649 alone.** It is `#[0-9A-Fa-f]{6}` — CSS hex, rule forty-two's
      served-page vocabulary — a different question that must not be folded into this
      one. Say so at the shared declaration so nobody merges them later.
- [x] This is the test for Task 2's defect, and say so where it lands: the prose could
      be corrected and drift again, while one declaration cannot disagree with itself.
      Verify by mutation, not by assumption: widen the shared pattern, confirm both
      rule two and rule forty-three change behaviour together, restore, and record
      what was seen.

### Task 4: Gates

- [ ] `swift test` — green, and report the test count.
- [ ] The app-layer bundle — green, and report the count.
- [ ] `swiftlint --strict` — clean.
- [ ] Confirm the rule count is still forty-three and both summaries still agree with
      it: no rule was added, removed or retitled by any task above.
