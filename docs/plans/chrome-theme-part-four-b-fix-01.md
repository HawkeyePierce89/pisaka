# Chrome theme, part four (b) — fix round 01

## Overview

This plan answers revmux round `01-initial` on the branch
`chrome-theme-part-four-b-log-local-changes-pull-requests`: eleven findings, one
major and ten minor, all four sources reporting and none degraded. Every finding
was re-derived by hand before being accepted here.

The major one is a real regression: the Log's filter bar became a single row of
controls that cannot shrink, so below roughly 1000 points of window width the
filters are clipped and become unreachable. The rest are a dead public Core
member kept alive by its own test, two gating-suite weaknesses, and six recorded
statements that are no longer true.

Two findings named the same dead member from different angles and are answered
once, in Task 3.

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

### Task 1: The filter bar must fit the window it lives in

**Files:** `Sources/Pisaka/LogFilterBar.swift`,
`Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`,
`docs/architecture/app-git-views.md`

The defect, as the review stated it — `LogFilterBar.swift:82`, major, confirmed
by three of the four sources and re-derived here:

> The bar used to have two rows, with controls capped only by `maxWidth` (ref
> ≤200, author ≤140, path ≤160, search ≤220), so they could shrink. It is now a
> single `HStack` of controls that cannot shrink: author is `.frame(width: 140)`,
> path is `width: 160`, search is `width: 220`, and the ref menu and both date
> pickers are `.fixedSize()`. With the gaps, the trailing spacer and the two
> insets, the row's minimum comes to roughly 950–1000 points at interface scale
> 1, and about 1500 at 150%. The main window's minimum width is
> `metrics.scaled(640)` (`ContentView.swift:441`). Between those two figures the
> `HStack` lays out wider than its container, the panel column clips it, and the
> branch menu and the message search — and the Log header's refresh button and
> the commit rows' date column — become unreachable.

- [x] **State the requirement first, in the file's own doc comment**: at the
      window's minimum width, at every interface scale, every control in the
      filter bar is reachable and nothing is clipped. The design's 28-point
      single row is the shape at a comfortable width, not a floor the window is
      obliged to provide.
- [x] **Make the row fit.** The design's widths become the *preferred* widths,
      not fixed ones:
  - the author, path and search fields take `maxWidth` at the design's figures
    with a stated minimum each, so they compress before anything clips;
  - the branch menu and the two date bounds stop forcing their intrinsic width —
    a date bound's label truncates rather than pushing the row wider;
  - the trailing spacer keeps its minimum but may collapse.
- [x] **Below the floor those minimums compose, the row scrolls horizontally**
      rather than clipping. A horizontal scroll view inside the 28-point strip,
      with no visible scroller furniture, so the strip's height, ground and
      bottom hairline are unchanged. Every control stays reachable at 640 points
      and at 150% interface scale.
- [x] **The strip's height, padding, gap, control height, radius, border and
      focus border are unchanged.** This task changes how the row distributes
      width and nothing else. No control is added, removed or reordered, and no
      filter's behaviour changes.
- [x] **The test that would have caught it.** Add a gating rule to
      `ChromeThemeSourceGatingTests`: no control in `LogFilterBar.swift` states a
      fixed `.frame(width:` — width is expressed as `maxWidth`/`minWidth` only —
      and the row is inside a horizontal scroll view. A fixed width in that file
      is the defect, textually visible, and this is the only gate in the pipeline
      that can see it. Give the rule its number, its doc comment and its message,
      and extend the suite's rule count, the `spelled` table, `core-theme.md`'s
      canonical list and `CLAUDE.md`'s count sentence with it.
- [x] **Show the rule bites**: restore a fixed `.frame(width:` on one field, run
      `swift test --filter ChromeThemeSourceGatingTests`, confirm red, restore,
      confirm green, and confirm `git status` shows no source change.
- [x] **Record the resolved behaviour** in `app-git-views.md`'s `LogFilterBar`
      entry: the preferred widths, the floor, and that the row scrolls below it.
- [x] Run `swift test` — must pass before Task 2.

### Task 2: The divide's resize cursor must not outlive its view

**Files:** `Sources/Pisaka/CommitLogView.swift`,
`docs/architecture/app-git-views.md`

The defect, as the review stated it — `CommitLogView.swift:171`, minor:

> The hand-rolled divide pushes `NSCursor.resizeLeftRight` from hover and drag
> state and pops it only from `syncDivideCursor()`, which runs on
> `onHover(false)` or the drag's `onEnded`. The `divideCursorPushed` comment and
> `app-git-views.md:743` both promise that every push has exactly one pop. The
> strip exists only while `model.selected != nil`; the model clears `selected`
> on its refresh paths, and switching dock tabs destroys the panel and its
> `@State`. If either happens while the pointer is on the strip, or mid-drag,
> the pop may never reach a view that has left the tree — the resize cursor
> stays pushed and the flag that would balance it is gone. Mid-drag,
> `detailDragStartWidth` also stays set, so the next drag starts from a stale
> width.

- [ ] **Balance the push on disappearance.** When the divide's view leaves the
      tree, pop the cursor if this view pushed it and clear the drag's start
      width. The promise in the comment and in the document becomes true for
      every way the view can go away, not only for the two callbacks.
- [ ] **Say why the hand-rolled split exists** in the same doc comment, if it is
      not already stated: the system divider cannot be drawn in a role, which is
      what the dock's own-hairline rule requires.
- [ ] **The test that would have caught it**: an app-layer test is not available
      for a SwiftUI lifetime callback, so pin it textually instead — the gating
      suite asserts that every `NSCursor` push site in the gated files has a pop
      reachable from a disappearance handler in the same file. If that cannot be
      expressed honestly over stripped text, say so in the doc comment and pin
      the narrower thing that can be: the file declares an `onDisappear` that
      names the push flag.
- [ ] **Show it bites**, as Task 1 does.
- [ ] **Correct `app-git-views.md:743`** so the promise names the disappearance
      path too.
- [ ] Run `swift test` — must pass before Task 3.

### Task 3: A public Core member with no reader, and the documents that describe it as live

**Files:** `Sources/PisakaCore/GitHubPullRequest.swift`,
`docs/architecture/core-github.md`,
`Tests/PisakaCoreTests/ChromeRoleMappingTests.swift`

Two findings named this from different angles; it is answered once. As the
review stated it — `GitHubPullRequest.swift:114`, minor, three sources:

> `GitHubCheckBucket.symbolName`'s doc comment reads "The SF Symbol an expanded
> job row draws for this bucket", but `PullRequestsPanelView.checkRow(_:)` draws
> a `Circle()` and never reads it. The only reader anywhere is
> `ChromeRoleMappingTests`. `core-github.md` around lines 1162–1164 lists its
> five answers as if something drew them. The result is a public surface kept
> alive only by its test, and a design note that misleads anyone deciding
> whether they can rely on it or remove it.

Re-derived here: the dot is the documented design — the plan and `core-github.md`
both specify a 6-point dot in the bucket's role with the bucket's words spoken as
the accessibility value — so the dot stays and the unread member goes.

- [ ] **Delete `GitHubCheckBucket.symbolName`.** `GitHubChecksSummary.symbolName`
      is untouched: the pull-request row's checks glyph does read it.
- [ ] **Drop its pins** from `ChromeRoleMappingTests`. Every other answer stays
      pinned.
- [ ] **Correct `core-github.md`** so it no longer lists five bucket glyphs as a
      live answer, and says what the job row actually draws.
- [ ] **The test that would have caught it** is the rule that a public Core
      answer has a production reader. If the suite has no such rule, state in the
      commit and in `core-github.md` that this one was found by review rather
      than by a gate, and do not invent a rule that would fail on the many
      legitimate Core members a view does not read.
- [ ] Run `swift test` — must pass before Task 4.

### Task 4: Two gating rules that do not bite what they name

**Files:** `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`,
`docs/architecture/core-theme.md`, `docs/architecture/core-git.md`

Three findings, all in the suite. This is the class this project treats as
load-bearing: a rule that is green while the code it names is broken.

- [ ] **The symbol-hiding check accepts a later image's modifier**
      (`ChromeThemeSourceGatingTests.swift:1568`, minor). As stated:

  > For each image, the test searches all of the remaining builder text for
  > `.accessibilityHidden(true)`. In `endingStrip`, removing that modifier from
  > the warning image leaves the later dismiss image's modifier in the searched
  > text. The test stays green while the warning symbol becomes an extra
  > accessibility announcement.

  Bind each image to its own modifier rather than to any later one in the
  builder — the match must fall inside that image's own modifier chain, ending
  at the next `Image(systemName:` or the builder's end, whichever comes first.
- [ ] **Show it bites on the case that defeated it**: remove
      `.accessibilityHidden(true)` from the *warning* image in `endingStrip`
      specifically — the site with a later image still carrying one — and
      confirm red, then restore and confirm green.
- [ ] **Rule seventeen's recorded rationale is false**
      (`ChromeThemeSourceGatingTests.swift:1264`, minor, two sources). As stated:

  > The claim that three view tables "had already drifted" appears in four
  > places: rule seventeen's doc comment, `core-theme.md:1161`,
  > `core-theme.md:807` and `core-git.md:153`. On master there were exactly two
  > tables and they matched case for case; `CommitDialogView` had no table of its
  > own, it called `LocalChangesView`'s internal helpers. The ticket itself says
  > "written out twice, byte for byte".

  Correct all four sites to what was actually true: two identical tables plus a
  third view calling one of them, and the rule prevents a *third* table and the
  drift two copies invite, rather than repairing a drift that had happened.
  **A recorded reason that is not true is worse than none — it is what the next
  reader will believe.**
- [ ] **The suite's header list has no bullets for rules seventeen to twenty**
      (`ChromeThemeSourceGatingTests.swift:19`, minor). Add one bullet per new
      rule — the changed-file status mapping, the checks-state mapping, the diff
      wash with `DiffSide`, and the three panels' accessibility — plus whichever
      rules Tasks 1 and 2 add. The suite's own comment warns that the rules it
      omits are the newest ones, which is exactly what happened.
- [ ] **Sweep for the shape, not the site.** Before committing: search the suite
      for every other rule whose match is "somewhere later in the text" rather
      than "inside the construct it names", and for every other count sentence
      that this part's four new rules and four exemptions made stale. Fix what
      the search finds in the same commit.
- [ ] Run `swift test` — must pass before Task 5.

### Task 5: Six recorded statements that are no longer true

**Files:** `Sources/Pisaka/MinimapView.swift`,
`docs/architecture/app-terminal.md`, `docs/architecture/core-theme.md`,
`docs/architecture/core-github.md`, `docs/architecture/app-ios.md`,
`docs/FEATURES.md`

- [ ] **Two sites still say the suite has three exemptions**
      (minor). `MinimapView.swift:42` says "`SyntaxTheme.swift` is one of the
      three exemptions" and `app-terminal.md:267` says "`TerminalTheme`, one of
      the chrome suite's three exemptions". `colorExemptions` now holds four.
      Correct both, and search for any other site stating that count.
- [ ] **The documents name the wrong suite for the new pins**
      (`core-theme.md:101`, minor, two sources). `core-theme.md:100–101` and
      `core-github.md:1170` say `ChromeThemeTests` pins the part four (b)
      mappings. It pins only the two new geometry tokens; every mapping is
      pinned in the new `ChromeRoleMappingTests`, which no architecture document
      names. Correct both sentences and give the new suite an entry where the
      other suites are described.
- [ ] **`app-ios.md:16` states the opposite of what the code does**
      (minor). It says the diff-background palettes are "*not* routed through
      this bridge — on macOS the chrome roles … through `ChromePalette`", but
      `ChromePalette.nsColor(_:)` is implemented as `PlatformColor.dynamic(...)`
      (`ChromePalette.swift:140`), so on macOS the wash *is* routed through it.
      Only the iOS half of the sentence is still true. Rewrite it to say what is
      true of each platform.
- [ ] **`FEATURES.md` describes the old macOS Local Changes row**
      (`docs/FEATURES.md:900`, minor). Line 900–901 says each file shows "a type
      icon tinted by its git status"; line 985 says a conflicted file "shows a
      purple \"C\" badge". On macOS the row now draws a monochrome secondary
      glyph and a conflicted file's letter is the red status role. The iOS view
      still tints and still uses purple, and neither sentence says which platform
      it means. Say which is which.
- [ ] **The test that would have caught it** does not exist and is not worth
      inventing: no gate reads `FEATURES.md` or a prose sentence in an
      architecture document for agreement with a colour. Say so plainly in the
      commit message rather than adding a rule that cannot hold.
- [ ] Run `swift test` — must pass before Task 6.

### Task 6: Run the gates

- [ ] `swift test` — report the count.
- [ ] The app-layer bundle — report the count.
- [ ] `swiftlint --strict` from the repository root — must be clean.
- [ ] The macOS Release build and the iOS build — both must succeed.
- [ ] Confirm the tree is clean and no mutation was left behind.
- [ ] Confirm the suite's rule count, its gated-file count and its exemption
      count agree across the suite, `core-theme.md` and `CLAUDE.md`.
