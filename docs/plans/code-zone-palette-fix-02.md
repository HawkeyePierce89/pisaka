# Fix plan 02 — revmux round 02-after-fix

## Overview

Answers the four findings and the two `immaterial` entries of revmux round
`02-after-fix`. All are `minor` and all are confirmed. One is a real surface the
previous sweep missed; one is a false mechanism this branch propagated to roughly
ten sites; two are claims a test or a doc comment makes that its own body does
not support; and two are consequences of how the previous round's fixes were
built and archived.

No colour value changes. Nothing in the palette is in question.

## Validation Commands

```sh
swift test
xcodegen generate && xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' test
xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'generic/platform=iOS' build
swiftlint --strict
```

## Implementation Steps

### Task 1: The sweep missed the macOS merge editor, and the rule cannot see it

**Finding:** `Sources/Pisaka/MergeView.swift:276`, confirmed, three sources,
confidence 99. Plus the `immaterial` entry at
`Tests/PisakaAppTests/SyntaxBaseForegroundGatingTests.swift:90`, folded in here
because it is the same rule.

Verified against the tree: `MergeView.swift` contains no `textColor`, no
`foregroundColor` and no `TextViewHighlighter(`. Its `MergePaneTextView` sets
only `.font` and declares `let zoomSurfaceKind: ZoomSurfaceKind = .code`
(`MergeView.swift:583`), so by the project's own rule it *is* the code zone. Its
three panes therefore draw at the platform default — pure white in dark — while
the editor behind the window draws `#dfe1e5`, **and while the iOS merge resolver,
which this branch did sweep, draws `#dfe1e5` too**. One feature, two platforms,
two answers.

`SyntaxBaseForegroundGatingTests` keys its sets on `TextViewHighlighter(`, so
this pane is outside both pinned sets by construction — while
`docs/architecture/app-editor.md` opens the paragraph with "**The rule is the
whole zone's, not the editor's.**" The rule as stated is wider than the rule as
implemented.

The `immaterial` entry is the second half of the same weakness: `fileNames(containing:)`
collects `url.lastPathComponent` into a `Set`, so the suite establishes only that
each named file contains *at least one* attachment and *at least one* assignment.
A second highlighter-backed pane added inside `DiffView.swift` — which already
declares two code surfaces, at `:287` and `:370` — would never be noticed.

- [x] Give `MergePaneTextView` its base foreground from
      `SyntaxTheme.shared.color(for: .plain)`, beside the `.font` assignment it
      already makes.
- [x] Decide `Sources/Pisaka/CommitUnifiedDiffView.swift` explicitly. It renders
      diff lines of file content at the code font under
      `ZoomSurfaceMarker(kind: .code)`, but through SwiftUI `Text` rather than a
      text view, so its foreground is SwiftUI's default rather than a `textColor`.
      Either give it the theme's plain row through `.foregroundStyle`, or record
      it as a named exemption with its reason. **Silence is not an option**: if it
      is exempt, the exemption is named in the gating suite so a reader finds it.
- [x] **Re-key the rule on what makes a surface the code zone, not on how it
      happens to be highlighted.** The defect construct is *a surface that
      declares itself the code zone and shows file content, but takes its
      foreground from the platform rather than from the theme's plain row*. Pin
      the set of code-zone surfaces by set equality against the tree, and name as
      explicit exemptions, each with its reason, the code-zone surfaces that have
      no base foreground to set because they paint their own content — the gutter,
      the minimap and the completion panel. Adding a seventh code surface must be
      a red test, whichever way it highlights.
- [x] Fix the granularity while re-keying: count **sites**, not files, so a second
      pane inside a file that already passes cannot ride in on its neighbour.
- [x] **Sweep for the shape, not the site.** The construct above is the search.
      Run it over `Sources/Pisaka` and confirm the resulting set is exactly what
      the suite pins, on both platforms. Name in the commit message what was
      searched for and why it is a better key than the highlighter call.
- [x] Re-read `docs/architecture/app-editor.md`'s "the rule is the whole zone's"
      paragraph and its enumeration, and make the two agree — by widening the
      enumeration, not by narrowing the sentence.

### Task 2: A false mechanism, propagated to roughly ten sites

**Finding:** `Sources/Pisaka/SyntaxTheme.swift:365`, confirmed, three sources,
confidence 98.

The branch states, in about ten places, that a system semantic colour is refused
here because it "follows the *system* appearance and would ignore the app's own
Theme preference". The repository states the opposite mechanism in files this
change did not touch: `ChromePalette.swift:117-121` explains that the preference
is applied as `.preferredColorScheme` at each window root, **which sets that
window's `NSAppearance`, inherited by every `NSView` inside it**;
`HoverPanel.swift` and `TerminalPanelView.swift` say the same from their side.
`.labelColor` is itself a dynamic colour resolved against the current appearance —
the same signal `PlatformColor.dynamic(light:dark:)` reads.

The finding's disproof is decisive and should be preserved in whatever replaces
the sentence: if `.labelColor` tracked the system appearance while the editor
pane's background tracked the preference, then with Theme = Dark and system =
Light the shipped v1.0 would have drawn black text on a dark pane — a defect
nobody has reported. Both resolve off the same appearance.

**The rule is right and stays. Only its stated reason is wrong.** What the change
actually fixes is a **value** mismatch: `.labelColor` is pure black/white, the
palette's plain row is `#1d1d1f`/`#dfe1e5`, so uncovered text sat a step off the
table in a window that was already in the correct appearance.

- [x] Replace the reason at every site the branch introduced it — the list in the
      finding names ten, but find them by searching rather than by copying the
      list. The replacement says what is true: the platform colour is not the
      design's value, so a character no capture covers would sit a step off the
      table beside every character that is covered.
- [x] Correct the same over-claim where it **pre-exists**, in
      `docs/architecture/core-theme.md` ("they desert the palette the moment the
      Theme preference disagrees with the system one") and in the rationale of
      `ChromeThemeSourceGatingTests`' rule one. Fixing the copies while leaving
      the original is the worst outcome: the next reader finds the false version
      and treats the corrected ones as the mistake.
- [x] Do **not** weaken either rule while correcting its reason — neither the
      chrome gating rule nor `SyntaxThemeTests.testNoTokenKindResolvesToASystemSemanticColour`
      changes what it asserts. Only the prose changes.
- [x] **Sweep for the shape, not the site.** The construct is *a sentence
      explaining a rule by a mechanism the repository elsewhere contradicts*.
      Having corrected these, check that no remaining sentence in the branch
      explains a colour decision by appearance-tracking rather than by value.

### Task 3: A doc sentence that the same commit corrected forty lines below

**Finding:** `Sources/Pisaka/SyntaxTheme.swift:38`, confirmed.

`nsColor(for:)`'s doc says the AppKit call sites "keep the same dynamic
`NSColor`s as before". After this change they keep none — all fourteen rows were
replaced. The parallel sentence on `table` *was* edited in this very commit,
precisely to drop its "as before" clause; the identical clause forty lines above
was left standing, on the function every AppKit attribute provider calls.

- [x] Correct the sentence.
- [x] **Sweep for the shape, not the site.** The construct is *a doc comment
      asserting continuity with a previous state across a change that ended it*.
      Search the branch's diff for every remaining "as before", "unchanged",
      "still the same" and equivalent, and check each against what the branch did.

### Task 4: A test that counts a comment as a painting site

**Finding:** `Tests/PisakaAppTests/ChromePaletteTests.swift:228`, confirmed,
two sources, confidence 99.

`testTheInactiveSelectionRowNamesTheFileThatPaintsIt` collects a consumer on
`text.contains(".selectionInactive")` over **raw**, un-stripped source. Any
occurrence counts — a doc comment, a disabled branch, a string. Its own failure
message claims to detect "selectionInactive is painted by nothing", and
`core-theme.md` restates it as "the test checks that the file still paints the
role".

The named defect that stays green: delete
`case .selectedUnfocused: return .selectionInactive` from `ProjectTreeView.swift`
while any prose in that file still spells the role. The role is then painted
nowhere and every assertion passes.

This test was introduced by the previous fix round, and it is the second test on
this branch to claim coverage its body does not have.

- [x] Make the painting half read comment- and literal-stripped text, the way
      every other gating suite in the repository does, while keeping the raw read
      for the half that checks the palette's own comment — the two halves ask
      different questions and need different inputs. Say that in the doc comment.
- [x] Better, if it is expressible: key the painting half on the assignment
      construct rather than on the bare role name, so the test fails when the
      `case` goes even if the role is named elsewhere in that file.
- [x] Prove it: confirm the test goes red when that one `case` line is removed
      while a mention of the role remains in the file, and record that check.
- [x] **Sweep for the shape, not the site.** The construct is *a source-scanning
      assertion that reads raw text where it needs stripped text*. Check every
      scanning test this branch added or touched, including
      `SyntaxBaseForegroundGatingTests`, for the same confusion.

### Task 5: The archived plan points at a file that was deleted

**Finding:** `immaterial` entry at
`docs/plans/completed/20260922-code-zone-palette-and-the-one-chrome-value.md:13`.

The correction header at the top of the completed plan ends "…and the correction
is `docs/plans/code-zone-palette-fix-01.md`, Task 1." That file was archived and
then deleted from the tree by design — fix plans do not reach the default branch
— so the archived plan, which is the permanent record and *does* reach it, cites
a path that will never exist there.

- [ ] Rewrite the reference so it stands on its own: state the correction itself
      rather than pointing at a deleted document, and name the review round it
      came from instead of a file path.
- [ ] Check the archived plan for any other reference to a fix plan by path, and
      for any reference to a file this branch removed.

### Task 6: Gates

- [ ] `swift test` — green, count recorded.
- [ ] `xcodegen generate` then the macOS app-layer bundle — green, count recorded,
      the re-keyed gating suite named.
- [ ] `xcodebuild … -destination 'generic/platform=iOS' build` — succeeds.
- [ ] `swiftlint --strict` — clean.
- [ ] Re-read all six items against the diff and confirm each is answered at the
      mechanism it names, not at the example it uses.
