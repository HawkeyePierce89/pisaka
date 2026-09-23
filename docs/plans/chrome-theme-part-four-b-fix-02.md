# Chrome theme, part four (b) — fix round 02

## Overview

This plan answers the acceptance review's one finding. revmux round
`02-after-fix` came back clean; this defect was found afterwards, by mutating
the rule that round 01's fix had just added and watching it stay green.

Gating rule twenty-one forbids a fixed width in `LogFilterBar.swift` by asking
whether the stripped source contains the literal `".frame(width:"`. That is a
**contiguous** substring, and the file's own style writes `.frame(` across
several lines, because every width site now carries a `minWidth`/`idealWidth`/
`maxWidth` triple. Replacing one of those keys with `width:` inside an existing
multi-line call restores the exact defect the rule was written to prevent — a
control that cannot shrink — and the rule does not see it. Verified by hand:
after that edit, `grep -c "\.frame(width:" Sources/Pisaka/LogFilterBar.swift`
answers `0` and `swift test --filter ChromeThemeSourceGatingTests` is green.

The likeliest way this regression returns is precisely that edit, since the
wrapped calls are what a maintainer would be editing.

A sweep of the suite's other eight absence checks found no second instance: each
of the others matches a single token or a declaration nobody wraps
(`Divider(`, `func diagnosticRole`, `func changedFileRole`, `func checksRole`,
`DiffTextView.Side`, the two alpha spellings). Rule twenty-one is the only one
whose subject the file already writes across lines. Do not widen the others.

## Validation Commands

```sh
swift test
xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-part4b test
swiftlint --strict
xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' \
  -configuration Release -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-part4b build
xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'generic/platform=iOS' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-part4b build
```

Build products must live outside the repository. Never pass a `-derivedDataPath`
inside the working tree.

## Tasks

### Task 1: Rule twenty-one must see a wrapped fixed width

**Files:** `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`

- [x] **Match `width:` as a `.frame(`'s first argument whatever the whitespace
      between them**, rather than as a contiguous substring — a regular
      expression over the stripped source, allowing any run of whitespace and
      newlines after the opening parenthesis. `minWidth:`, `idealWidth:` and
      `maxWidth:` must still pass: the boundary is that the key is exactly
      `width`, not that it ends in it.
- [x] **Say in the rule's doc comment why the spelling matters**: the file writes
      every width site as a multi-line `.frame(` carrying three keys, so the
      regression this rule exists to catch arrives as one of those keys being
      changed, not as a fresh single-line call. A contiguous match saw only the
      historical spelling.
- [x] **The mutation that proves it**, and it is the one that defeated the old
      rule: inside `searchField`'s existing multi-line `.frame(`, replace
      `minWidth:` with `width:`; run
      `swift test --filter ChromeThemeSourceGatingTests`; confirm it is now red;
      restore; confirm green; confirm `git status` shows no source change.
- [x] **Confirm the rule still passes on the file as it stands**, with all three
      width keys in place — a regex that also matched `maxWidth:` would fail the
      branch outright, so this is not a formality.
- [x] **Change nothing else.** No other rule is widened, no source file is
      touched, and the rule's number, its place in the suite's count, and the
      count sentences in `core-theme.md` and `CLAUDE.md` all stay as they are.
- [x] Run `swift test` — must pass before Task 2.

### Task 2: Run the gates

- [ ] `swift test` — report the count.
- [ ] The app-layer bundle — report the count.
- [ ] `swiftlint --strict` from the repository root — must be clean.
- [ ] The macOS Release build and the iOS build — both must succeed.
- [ ] Confirm the tree is clean and no mutation was left behind.
