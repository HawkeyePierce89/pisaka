# Chrome theme, part five (c) — fix 02: one reference that will dangle on the default branch

## Overview

revmux round `02-after-fix` came back with **nothing**: two sources, neither
degraded, zero findings. This plan answers one item the round did not raise and
could not — it is about what the branch looks like *after* it is squashed, which no
reviewer of the branch can see.

`docs/architecture/core-zoom.md` explains why the stepper's two halves are checked
separately and dates the change as "Until **fix 01 of part five (c)** the clause
asked for `stepped` anywhere in the stepper's whole body". That fix plan was
deliberately removed from the branch, exactly as every fix plan in this sweep is, so
the default branch carries only the part's own plan. A reader who goes looking for
"fix 01 of part five (c)" finds nothing at all.

The house phrasing already exists and does not have this problem:
`core-theme.md` dates the same kind of change as "the review round" and "the first
review round", naming the *event* rather than an artifact that is thrown away.

This is one sentence. It is worth a round because this repository's discipline rests
on the architecture documents being true for the next reader, and `CLAUDE.md` sends
that reader to them before touching a file.

## Validation Commands

```sh
swift test
xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-p5c-fix02 test
xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' \
  -configuration Release -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-p5c-fix02 build
xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'generic/platform=iOS' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-p5c-fix02 build
swiftlint --strict
```

Derived data never goes inside the repository working tree.

## Context

Files involved:
- `docs/architecture/core-zoom.md` (~522), the sentence naming the fix plan.
- Read only, as the phrasing to match: `docs/architecture/core-theme.md`, which
  dates earlier changes as "the review round" / "the first review round".

Related patterns:
- A fix plan is a working artifact: ralphex archives it, the branch drops it, and
  the squash merge means it never reaches the default branch. Prose therefore dates
  a change by the **review round** that prompted it, never by the plan file.
- The part's own plan does survive, at
  `docs/plans/completed/20260925-chrome-theme-part-five-c-preferences-and-pr-sheets.md`,
  so referring to *that* is fine.

Dependencies: none new.

## Development Approach

- Documentation only. No source file, no test, no rule changes.
- Sweep for the shape, not the site: the same mistake could have been made anywhere
  this branch wrote prose.
- No product or brand names.
- No task takes a screen capture or depends on a human opening a window.
- `swift test` must still pass, because the count and canonical-list self-checks
  read these documents.

## Implementation Steps

### Task 1: Date the change by its review round, not by a discarded plan

**Files:**
- Modify: `docs/architecture/core-zoom.md`

- [x] Reword the sentence at ~522 so it dates the change by the review round rather
      than by the fix plan's file name, matching how `core-theme.md` already phrases
      the same kind of note. The substance stays: before that round the clause asked
      for `stepped` anywhere in the stepper's whole body, which `adjust(_:)` alone
      satisfied while the glyph buttons could have drifted to arithmetic of their
      own.
- [x] **Sweep the whole branch's prose for the same shape**, not just this site:
      every passage this branch added or edited that names a fix plan, a plan file
      that the branch drops, or any `docs/plans/` path that will not exist on the
      default branch after the squash. Check `docs/architecture/*.md` and
      `CLAUDE.md`. Report what the sweep found, including "nothing else", rather
      than reporting only what was changed.
- [x] Confirm that references to the part's **own** plan, which does survive, are
      left alone — the rule is about artifacts that are discarded, not about all
      plan references.
- [x] No new test: this is prose, and no rule can see a reference that dangles only
      after a squash. Say that in the commit message rather than inventing a check
      that would not hold.
- [x] Run `swift test`. It must pass.

### Task 2: Verify the gates

- [ ] Run every command in **Validation Commands**. All must pass. Report exact
      counts: the Core test total, the app-bundle total, the SwiftLint violation and
      file counts, and both build verdicts.
- [ ] Confirm the rule count and the gated-file count still agree in all four places
      they are spelled.
- [ ] Confirm `git status --porcelain` is empty.

## Post-Completion

Nothing. This part's outstanding visual checks are already listed by the part's own
plan and by fix 01's, and they are unchanged by a documentation edit.
