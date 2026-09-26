# Chrome theme, part five (e) — fix 02: the closure claim is false

## Overview

The acceptance review found one defect the two review rounds did not: this branch
adds a sentence to `docs/architecture/core-theme.md` claiming this part **closes
the macOS colour sweep**, and that claim is false.

`Sources/Pisaka/BracketOverlayLayoutManager.swift:652` paints the fold
placeholder from `NSColor.secondaryLabelColor`, and the doc comment immediately
above it calls that placeholder chrome in its own words: "the placeholder is
chrome standing in for text, not a token". It is a macOS app-layer file, it is
not in the gated set, and it is not one of the four stated exemptions. So a
chrome surface still paints from a platform semantic colour, and the sweep is not
closed.

The same paragraph makes the mistake visible: it describes the alert accessory as
"this document's verified counterexample to part five (d) having been the last",
and then declares finality again one part later — without the measurement that
would have disproved it. The wording came from the ticket, so this is the
ticket's error landing in a document, not an implementation slip.

Nothing about the code in this branch is wrong. What must change is one claim, and
the absence of anything that could have caught it.

## Validation Commands

```sh
swift test
xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' test
swiftlint --strict
```

Use a DerivedData path outside the repository for any local build.

## Implementation Steps

### Task 1: the claim comes down to what was measured

**File:** `docs/architecture/core-theme.md` (the part five (e) section, and
anywhere else the same claim is echoed).

- [x] Replace the closure claim with what is true: this part sweeps the two served document pages and the alert accessory, and it is **not** the last part.
- [x] Name the one surface that is known to remain, with its evidence: `BracketOverlayLayoutManager.swift`'s fold placeholder, painted from `NSColor.secondaryLabelColor`, which that file's own comment calls chrome standing in for text. Say that it is left for a part of its own because whether a placeholder standing in for text belongs to the chrome or to the code zone is a design question, and this sweep's stated refusal is to stop at a design question rather than decide it under another part's heading.
- [x] Keep the paragraph's existing observation that the alert accessory was the counterexample to part five (d) having been the last, and say plainly that the same claim was made again here and was again wrong — a document that records the mistake is what stops the next part repeating it.
- [x] **Sweep for the shape, not the site:** grep `docs/` and `CLAUDE.md` for every other sentence asserting that the colour sweep is finished, complete, closed or that some part is the last, and correct each in this commit. Grep for the constructs, not one literal phrase.

### Task 2: the guard that would have caught it

A claim of completeness must be checked against the measurement that decides it,
the way the suite already checks its own rule count against the two documents that
spell it. Without that, the next part can make the claim a third time.

- [ ] Add a gating rule pairing the two: collect the macOS app-layer files (excluding `Sources/Pisaka/iOS/`) that are outside `gatedFiles` and outside the four stated exemptions and that name a system semantic colour or a hex literal; if that set is non-empty, no document may claim the sweep is closed, finished or complete.
- [ ] Implement it so the failure message **names the files in the set**, so whoever trips it learns what is left rather than only that a sentence is banned.
- [ ] Seed the rule with today's answer: the set is `{BracketOverlayLayoutManager.swift}`, pinned by set equality, so both directions fail — a new un-swept surface appearing, and this one being swept without the rule being updated.
- [ ] Read the sources through the suite's usual comment- and literal-stripped scanner, so a doc comment merely *discussing* `.secondaryLabelColor` does not count as painting with it; state which scanner was chosen and why in the rule's doc comment.
- [ ] Extend `spelled` if the rule count moves, and update the count in `CLAUDE.md` and `core-theme.md` in the same task, or the existing count test fails.
- [ ] Test: verify by mutation that the rule is red both ways — with the closure claim restored into the document while the set is non-empty, and with a file added to or removed from the pinned set — then restore.

### Task 3: the gates

- [ ] `swift test`.
- [ ] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' test`, DerivedData outside the repository.
- [ ] `swiftlint --strict` from the repository root.
- [ ] Confirm no product or brand name entered any file this plan touched.
