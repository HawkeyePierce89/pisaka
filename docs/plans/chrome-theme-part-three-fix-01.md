# Chrome theme part three — fixes from review round 01-initial

## Overview

Answers every finding of the first review round on this branch (`01-initial`,
profile `comprehensive`, four sources, none degraded): six findings, all minor,
plus one pre-existing item whose *omission* this change is responsible for. All
seven are accepted and fixed here; none is worked around.

Two are behavioural (an accessibility regression in the two bar widgets, and a
test suite that cannot see the attachment it exists to guard), one removes a
tautological assertion, and four are documentation claims this change either
made false or left contradicting itself.

## Validation Commands

```sh
swift test
xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-chrome-part-three test
swiftlint --strict
```

Never pass a derived-data path inside the repository.

## Implementation Steps

### Task 1: The two switcher widgets announce their decorative symbols

**Finding** (`Sources/Pisaka/ProjectSwitcherView.swift:44`, minor, confidence 85):
part three replaced `Label(currentLabel, systemImage:)` with an `HStack` of
`Image(systemName:)` + `Text` + a new `chevron.down` in both switchers. A
`Label`'s icon is not announced, but a `Button`'s children are combined — so
both decorative symbols now fold their own names into each button's
accessibility name. This is the repository's own documented mechanism, not a
guess: `ProjectTreeView.swift` hides exactly such symbols with
`.accessibilityHidden(true)`, and `app-window.md:752-758` records the observed
announcement "chevron.right, folder fill, Sources". The third widget converted
in the same change, `PullRequestIndicatorView`, carries an explicit
`.accessibilityLabel`/`.accessibilityValue`; the two switchers are the outlier.

- [x] `ProjectSwitcherView.swift`: mark the `folder` symbol and the new
      `chevron.down` `.accessibilityHidden(true)`, in `ProjectTreeView`'s
      documented idiom, so the button's name is the project label alone.
- [x] `BranchSwitcherView.swift`: the same for `arrow.triangle.branch` and its
      `chevron.down`.
- [x] Record in one short comment per file why the symbols are hidden, naming
      the combining behaviour rather than restating the fix.
- [x] **Correct the contradicting rationale.** `core-theme.md`'s rule-ten
      paragraph (around line 661) and the matching doc comment in
      `ChromeThemeSourceGatingTests` both assert that "an `Image(systemName:)`
      supplies none" — no accessibility name. That cannot be true beside part
      one's recorded observation, which quotes an announcement built from two
      symbol names. Part one's is the one backed by a measurement, so correct
      both sentences: an unhidden SF Symbol folds *its own* name in, which is
      why an icon-only control needs an explicit `.accessibilityLabel` (the
      requirement rule ten states is unchanged — only its reason was wrong) and
      why a decorative symbol beside a name is hidden.
- [x] **The test that would have caught it**: extend gating rule ten to the
      three bottom-bar widget files. Each must either spell an explicit
      `.accessibilityLabel(` on its button, or hide every decorative
      `Image(systemName:)` it draws — assert it by counting, in the suite's own
      `occurrences(of:in:)` idiom, that each file's `Image(systemName:)` count
      is matched by its `.accessibilityHidden(true)` count, with the
      explicit-label file named as the stated exception. Keep the rule's
      existing half for `ContentView.swift` intact, and if the rule's text
      changes shape, keep its `// MARK:` marker, `core-theme.md`'s canonical
      list and `CLAUDE.md`'s count sentence in agreement — the suite checks all
      three against each other.
- [x] Run `swift test` and the app-layer bundle.

### Task 2: The window-chrome suite cannot see the attachment it guards

**Finding** (`Tests/PisakaAppTests/MainWindowChromeTests.swift:34`, minor,
confidence 95, verdict confirmed): both property tests call
`MainWindowChrome.apply(to:)` directly, so deleting either the scene's
`.background(MainWindowChrome())` or the call inside
`MainWindowChromeView.viewDidMoveToWindow()` leaves the whole new suite and
every source gate green while the shipped window keeps its platform title bar.
The project's rule is that a behavioural change ships with the test that catches
its absence; this suite does not.

- [x] Add a test driving the **attachment path** rather than the static method:
      build a real `NSWindow`, assert it is opaque and un-themed first (the
      suite's own existing discipline), then attach a `MainWindowChromeView` to
      the window's content view so `viewDidMoveToWindow()` runs, and assert the
      window came out with the transparent title bar and the panel ground. A
      test that passes without the call in the view is not the test asked for.
- [x] Add a gating rule (or extend rule nine, whichever keeps the suite's
      numbering honest) pinning the scene's **one** attachment site:
      `MainWindowChrome(` is spelled exactly once in `Sources/`, in
      `PisakaApp.swift`, and the frame-persistence marker's own site is
      unchanged beside it. Deleting the attachment must turn a gate red.
- [x] (rule count unchanged — rule nine gained a second test, not a new marker) If the rule count moves, update `core-theme.md`'s canonical list and
      `CLAUDE.md`'s invariant sentence in this same task.
- [x] Run `swift test` and the app-layer bundle.

### Task 3: The marker's accessibility assertion is a tautology

**Finding** (`Tests/PisakaAppTests/MainWindowChromeTests.swift:84`, minor,
confidence 90, verdict confirmed): `XCTAssertFalse(view.isAccessibilityElement())`
cannot fail — a plain `NSView` already answers `false`, so deleting
`setAccessibilityElement(false)` from `MainWindowChromeView.init()` leaves the
assertion green and the stated rule unguarded. The repository's own review
standard names a tautological test as a defect worth reporting.

- [x] Remove the assertion rather than dress it up, and say in the test's
      comment what was learned: AppKit's default already answers `false`, so the
      initialiser's line is belt-and-braces and this suite cannot pin it. The
      `hitTest` half of the same test is real and stays exactly as it is.
- [x] Leave `setAccessibilityElement(false)` in the source — it mirrors the
      frame marker's own idiom — but do not claim a test covers it.
- [x] Run the app-layer bundle.

### Task 4: The canvas sentence is false for two of the three surfaces it names

**Finding** (`Sources/Pisaka/ContentView.swift:411`, minor, confidence 95, three
sources): the justification for spending `bgCanvas` — "it shows through wherever
no surface paints over it: the no-file-open placeholder and the root's own empty
states" — is repeated at `ContentView.swift:411-412`,
`MainWindowChrome.swift:15-16`, `app-window.md:132-133` and
`app-shell.md:1511-1512`, and `core-theme.md:429-431` and `:505-507` enumerate
the three sentences meant. Only "No file open" sits over the canvas: the other
two render inside `panelContent(_:)`, and this same change paints the panel slot
`bgPanel` directly under them (`ContentView.swift:561`), both filling it through
`.frame(maxWidth: .infinity, maxHeight: .infinity)`. The role still has its
consumer, so the sweep's accounting is unchanged — what is wrong is the claim,
and the next part reads it to learn which ground its surfaces sit on.

- [x] Correct all six sites to say what is true: `bgCanvas` is the window root's
      ground, visible behind the no-file-open placeholder; the dock's two empty
      states sit on the dock's own `bgPanel`, which the panel slot paints under
      them.
- [x] Say it once and cross-reference it, rather than restating a six-way claim
      that has now been wrong once. The canonical statement is `core-theme.md`'s
      part-three window-ground entry; the other five sites name it and point
      there.
- [x] No test: this is prose about which ground a sentence sits on, and the only
      mechanizable form would pin the sentence to itself. Said so in the
      canonical entry itself, so a reader finds the reason where the claim is.
- [x] Run `swift test` (the documents are read by the gating suites' count
      rules). Green: 5728 tests, 0 failures; `swiftlint --strict` clean.

### Task 5: Two per-file entries went stale, and one document contradicts itself

**Findings** (`docs/architecture/core-github.md:1583` and
`docs/architecture/app-window.md:142`, both minor, confidence 85 and 90):

1. `PullRequestIndicatorView.swift` changed substantially — three elements
   instead of two, `noChecks` moved from `arrow.triangle.pull` to `circle`, all
   four colours became roles, its paddings dropped, and it reads
   `\.chromeTheme` — while its entry in `core-github.md` still opens "Beside the
   branch switcher: `#N` plus the checks state" and closes "Chrome, sized
   through `\.interfaceMetrics`". `BranchSwitcherView.swift` gained a caret,
   lost its paddings and moved onto roles while its entry at
   `app-git-views.md:98` was untouched. The behaviour *is* recorded — in
   `app-window.md`'s part-three paragraph — so these two entries now disagree
   with the part's own record. `CLAUDE.md`'s rule is to update a file's entry in
   the doc named beside it.
2. `app-window.md:142` still argues that "two **adjacent** dock buttons drawn
   with one symbol are indistinguishable at a glance, which `ContentView` says
   in a comment beside it" — but `ContentView` no longer says it (the word
   `adjacen` appears nowhere in the file), and `app-window.md:203`, sixty lines
   below, states the opposite: the two sit at opposite ends of the bar, so the
   adjacency argument no longer applies. The document contradicts itself and
   attributes a quotation to a comment this change rewrote.

- [ ] Bring the `core-github.md` and `app-git-views.md` entries in line with the
      code — either directly or by a precise cross-reference to the part-three
      record — so no reader has to guess which document is current.
- [ ] Fix `app-window.md:142`: drop the superseded adjacency argument and the
      false attribution, and let the part-three paragraph carry the current
      reason.
- [ ] **The pre-existing item this change is responsible for omitting**: a third
      platform-coloured `Divider()` survives in the now-gated `ContentView.swift`
      at line 1141 — the rule under the find bar. It is not this change's code,
      and gating rule one cannot see it (a `Divider()` names no colour), but the
      branch recorded the switcher popovers' dividers as inherited work in three
      places and left this one recorded nowhere. Add it to `core-theme.md`'s
      part-three inherited-work note beside them, naming the file, the line's
      surface (the find bar) and the part that will sweep it.
- [ ] Run `swift test`.

### Task 6: Gates

- [ ] `swift test` green.
- [ ] The app-layer bundle green on a macOS destination, derived data under
      `~/Library/Developer/Xcode/DerivedData/pisaka-chrome-part-three`.
- [ ] `swiftlint --strict` clean from the repository root.
- [ ] Confirm the gating suite's rule count still agrees with `core-theme.md`'s
      canonical list and `CLAUDE.md`'s invariant sentence.
