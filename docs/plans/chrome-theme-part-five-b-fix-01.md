# Chrome theme, part five (b) — fix 01: the review round's findings

## Overview

Answers revmux round `01-initial` on task
`chrome-theme-part-five-b-commit-dialog-merge-editor-windows`: four sources, none
degraded, six findings, all minor and all confirmed by verification. Every one was
re-derived in the tree before this plan was written.

One is executable code: a chrome glyph that stopped following the interface zoom
when this branch removed the container font it was inheriting. Four are documents
that name a function this branch deleted, or pin a set the suite no longer holds.
One is a comment in the iOS layer pointing at a type this branch removed.

Nothing here gates a merge. It is fixed now because two of the three classes strike
the mechanism this repository uses to stay honest: the architecture entry
`CLAUDE.md` tells the next reader to consult before editing a file, and the
canonical rule list that is supposed to describe the suite beside it.

**The sweep is already done and its result is part of this plan.** The defect in
Task 1 is not "one icon lost its font" but "a chrome glyph whose size came from a
container font that is no longer there". Every `Image(systemName:` in the gated set
was checked: seventeen glyphs across eight files, of which four carry no `.font`
of their own. Three of those four are correct — the merge editor's two chevrons take
`.callout` from `ChromeSecondaryButtonStyle`, and the shared checkbox's glyph is
sized by a `.frame` through the interface metrics. The fourth is the finding. Task 1
must confirm this rather than trust it, and the rule it adds is what keeps the next
glyph from arriving unsized.

## Validation Commands

```sh
swift test
xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-p5b-fix01 test
xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' \
  -configuration Release -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-p5b-fix01 build
xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'generic/platform=iOS' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-p5b-fix01 build
swiftlint --strict
```

Derived data never goes inside the repository working tree.

## Context

Files involved:
- `Sources/Pisaka/CommitDialogView.swift` — `CommitFileRow`'s body, the file-type
  glyph at ~line 530.
- `Sources/Pisaka/iOS/MergeView_iOS.swift` — the comment above `MergeColors_iOS`
  at ~line 175.
- `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift` — one new rule, one
  new cross-check, and the count bookkeeping.
- `docs/architecture/core-theme.md` — the pane-ground caller list (~1161), rule
  eleven's entry (~1543), rule twenty-six's entry (~1724) and the shared field's
  `Callers:` paragraph (~945–952).
- `docs/architecture/app-editor.md` (~1028), `docs/architecture/app-git-views.md`
  (~376, ~491, ~741), `docs/architecture/app-editor-overlays.md` (~615, ~734–740).
- `CLAUDE.md` — only if a rule count changes.

Related patterns:
- A chrome measurement lives in one zone. `metrics.scaled(_:)` and
  `metrics.scaledFont(_:)` are the interface zone; `settings.fontSize` is the code
  zone. A glyph with no font at all is in neither, which is the defect.
- The suite pins a set and names its exceptions rather than trying to express a
  general rule it cannot. `roleNamingExemptions` and `colorExemptions` are the
  precedent for the shape Task 1 uses.
- A document that must agree with the suite is checked against the suite, not
  maintained by hand: `testBothSummariesSpellTheSuitesOwnRuleCount` and
  `testTheCanonicalListEnumeratesEveryRule` already read `core-theme.md` and
  `CLAUDE.md` from the tests. Task 3 extends that idea to a pinned file set.
- Pinning a string's **absence** across a tree is an established shape here:
  `ReleaseWorkflowTests` asserts the Gatekeeper-workaround strings appear nowhere.
  Task 2 uses it for a deleted function's name.
- Gating rules read comment- and literal-stripped text and match multi-line calls
  with a brace-matched body (`matchedBody(after:in:)`) or a whitespace-tolerant
  pattern, never a contiguous substring. Identifier bans and presence checks go
  through `LSPSourceGatingTests.containsToken(_:in:)`.

Dependencies: none new.

## Development Approach

- Testing approach: regular, except the gating work. Each new or changed rule is
  first shown red against a deliberately broken local edit, then reverted and shown
  green. A rule that cannot be made red is not a rule.
- Complete each task fully before moving to the next; `swift test` must pass before
  the next task starts. A task touching app files also builds the macOS app.
- Read each file's `docs/architecture/` entry before modifying it.
- No new colour role, no new exemption to the colour rules, no new font size —
  neither in `ChromeGeometry` nor in a per-file layout table, which is the same
  thing under another name.
- No task takes a screen capture, and no task depends on a human opening a window,
  a sheet, a menu or a popover.
- No product or brand names in code, comments, documentation or commit messages.
- Documents are corrected to say what the tree now does. Where a sentence was
  historically true, say when it stopped being true rather than deleting the
  history.
- CRITICAL: every task includes new or updated tests.

## Implementation Steps

### Task 1: A chrome glyph carries its own size

**Files:**
- Modify: `Sources/Pisaka/CommitDialogView.swift`
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`

The defect: on `master`, `CommitFileRow`'s `HStack` carried
`.font(metrics.scaledFont(.body))` and the file-type `Image(systemName:)` inherited
it. This branch removed the container font and gave explicit fonts to the name, the
directory and the status letter only. No ancestor supplies one — not `fileList`,
not the `LazyVStack`, not the dialog's root, not `.interfaceScaled`. The glyph
therefore draws at the system default at every interface scale, so at 150% and 200%
the checkbox, name, path and status letter grow while it stands still. The row's own
doc comment claims it grows with the interface scale.

- [x] Give the file-type glyph its own `.font(metrics.scaledFont(.callout))`,
      matching `ChangedFileRow` in `LocalChangesView.swift`, which is the row this
      one is modelled on and which sizes its icon explicitly for this reason.
      Note in a comment that the size is the row's own, not an inherited one.
- [x] Re-run the sweep rather than trusting this plan's copy of it: list every
      `Image(systemName:` in the gated set and classify each as sized by its own
      `.font(`, sized by its own `.frame(` through `metrics`, or sized by an
      enclosing style or container that sets a scaled font. Report any glyph this
      plan's Overview did not account for and fix it the same way.
      (Done over the whole gated set: 25 glyphs without a size of their own.
      Three were real defects — this row's glyph and the Pull Requests panel's
      message and wait-ending strip glyphs, now `.subheadline` like the message
      text beside them. The other 22 are sized from outside and pinned, and the
      rule re-checks what sizes each: 17 by a container font, 2 by the font at
      the draft icon column's use sites, 2 by the secondary button style. The
      unified diff's per-line checkbox is pinned as deliberately on neither
      scale.)
- [x] **Rule thirty-four: every chrome glyph is sized in the interface zone.**
      For each gated file, every `Image(systemName:` either carries `.font(` or
      `.frame(` naming `metrics` within its own chained modifiers, or is named in a
      pinned exemption set with the reason it needs none. Seed the exemption set
      with exactly the glyphs the sweep justifies: the merge editor's two
      conflict chevrons (sized by `ChromeSecondaryButtonStyle`'s `.callout`) and the
      shared field's leading glyph (sized by `ChromeControlBox`'s own font). The
      shared checkbox's glyph is **not** an exemption: it sizes itself by frame.
      Match with a brace-matched or whitespace-tolerant walk, never a contiguous
      substring — a modifier chain wraps across lines routinely in this tree.
- [x] Mutation-verify: remove the font added above and confirm the rule goes red;
      remove one exemption entry and confirm the rule goes red; restore both and
      confirm green. Confirm `git status` is clean afterwards.
- [x] Record the rule in `core-theme.md`'s canonical list and update the rule count
      wherever it is spelled — the suite's doc comment, `core-theme.md` and
      `CLAUDE.md`. The existing count self-checks read all three.
- [x] Run `swift test` and the macOS build. Both must pass.

### Task 2: No document names the function this branch deleted

**Files:**
- Modify: `docs/architecture/core-theme.md`
- Modify: `docs/architecture/app-editor.md`
- Modify: `docs/architecture/app-git-views.md`
- Modify: `docs/architecture/app-editor-overlays.md`
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`

The defect: `CodeEditorView.applyEditorBackground(scrollView:textView:)` no longer
exists — `makeNSView` calls `CodePaneGround.apply(scrollView:textView:)` directly.
Five live passages still name it, three of them written by this branch:

1. `core-theme.md:1161` lists the fourth `CodePaneGround` caller as
   `CodeEditorView.applyEditorBackground`.
2. `app-editor.md:1028` says `applyEditorBackground` "no longer sets … privately:
   it calls `CodePaneGround.apply`".
3. `app-git-views.md:741` lists `CodeEditorView.applyEditorBackground` among the
   four callers.
4. `app-editor-overlays.md:615` describes "one private
   `applyEditorBackground(scrollView:textView:)`, the only colour that file spells".
5. `app-editor-overlays.md:734–740` says three things that are now false: that the
   editor's pane takes `bgEditor` from `applyEditorBackground`; that the source
   viewer "applies the same role to the same three views in its own `makeNSView`"
   (it goes through `CodePaneGround`); and that the rest of that window's chrome
   "waits for the sweep" (it was swept in part five (b), and its ground is
   `EscClosableWindow`'s `bgPanel`).

The archived plan under `docs/plans/completed/` also names the function. **Leave it
alone**: it is a record of what was planned, it offered both shapes, and rewriting
history to match the outcome is how a plan archive stops being evidence.

- [x] At the three sites in `core-theme.md`, `app-editor.md` and `app-git-views.md`,
      name `CodeEditorView.makeNSView` as the caller instead.
- [x] Rewrite `app-editor-overlays.md:615` and `:734–740` so both the editor and the
      source viewer are described as going through
      `CodePaneGround.apply(scrollView:textView:)`, and drop the "waits for the
      sweep" sentence, which part five (b) settled.
- [x] Add a clause pinning the **absence**: `applyEditorBackground` is named nowhere
      under `docs/architecture/`. Exclude `docs/plans/` from the scan and say in the
      comment why the archive is outside it. Put the clause with rule thirty-one,
      which owns the pane ground, rather than opening a rule for it.
- [x] Add the positive half beside it: the caller files the documents enumerate for
      `CodePaneGround` equal the set rule thirty-one already pins. One source of
      truth, checked against the prose that claims to describe it.
- [x] Mutation-verify both clauses: re-introduce the old name in one document and
      confirm red; drop one caller from a document's list and confirm red; revert
      and confirm green, with a clean `git status`.
- [x] Run `swift test`. It must pass.

### Task 3: The canonical rule list agrees with the suite it describes

**Files:**
- Modify: `docs/architecture/core-theme.md`
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`

Two entries drifted from the sets they describe:

- **Rule twenty-six** (~1724). The suite's `sharedFieldConstructors` now holds five
  callers plus the defining file, and its failure message says "five callers". The
  canonical entry still lists four. The same document's part five (b) section
  already says "now five", so the file contradicts itself. The shared field's
  `Callers:` paragraph (~945–952) also still stops at `BranchSwitcherView.swift`,
  and the new query-toggle one-name clause under this rule is described nowhere.
- **Rule eleven** (~1543). The suite replaced
  `("LogFilterBar.swift", ["private func dateBound("])` with
  `("ChromeControls.swift", ["struct ChromeCheckbox"])`, because that label now
  lives in the shared checkbox. The entry still counts `dateBound(…)` and never
  mentions `ChromeCheckbox`. The sentence is phrased as history ("part four (b)
  named its own"), so correct it by saying what changed and when, not by deleting
  the record.

- [x] Add `CommitDialogView.swift` (the message box) to rule twenty-six's set in the
      canonical list and to the shared field's `Callers:` paragraph.
- [x] Add one sentence describing the query-toggle one-name clause under rule
      twenty-six.
- [x] In rule eleven's entry, say that since part five (b) the date bound's label is
      counted in `ChromeCheckbox` (`ChromeControls.swift`) rather than in
      `dateBound(…)`.
- [x] Add the cross-check that would have caught both: for the pinned file sets the
      canonical list enumerates, the `.swift` names it spells equal the set the
      suite actually holds. Start with rule twenty-six's `sharedFieldConstructors`
      and rule eleven's `headerBuilderFiles` — the two that drifted — and say in the
      comment which sets are covered and which are not yet, so the next reader knows
      the check's reach rather than assuming it is total.
- [x] Mutation-verify: drop one file from the canonical list's rule twenty-six set
      and confirm red; add a file the suite does not hold and confirm red; revert and
      confirm green, with a clean `git status`.
- [x] Run `swift test`. It must pass.

### Task 4: Two passages this branch made false

**Files:**
- Modify: `docs/architecture/app-git-views.md`
- Modify: `Sources/Pisaka/iOS/MergeView_iOS.swift`

- [x] `app-git-views.md:376` still says "nothing else in the dialog is on the chrome
      roles yet", and `:491` still says "the dialog around the panel is untouched".
      Both became false with this branch and both contradict the chrome paragraph
      later in the same entry. Remove the obsolete scope claims and let that
      paragraph describe the dialog as it now is.
- [x] `MergeView_iOS.swift:175` reads "mirroring the macOS `MergeColors` tones".
      `MergeColors` is deleted and the macOS wash is now
      `ChromeColorRole.mergeWashRole(for:)` — `conflictBackground` for ours, theirs
      and unresolved, `diffAddedBackground` for resolved. Reword the comment to say
      the iOS tones are the macOS merge wash **as it stood before part five (b)**,
      which is both true and informative, rather than dropping the cross-reference.
- [x] The doc comment on `MergeLineKind_iOS` just above says the vocabulary is
      view-layer "so Core stays colour-free". Core now carries a public
      `MergeLineKind` with the same five cases. Say why iOS still keeps its own —
      or, if there is no reason beyond nobody having swept iOS, say that and leave
      it for the iOS part. Do **not** change the iOS code in this fix round: iOS is
      out of the part's scope and an untested change there buys nothing.
- [x] No new test: both items are prose. Confirm the existing `swift test` stays
      green, since the suite reads these documents.

### Task 5: Verify the gates

- [x] Run every command in **Validation Commands**. All must pass. Report exact
      counts: the Core test total, the app-bundle total, the SwiftLint violation
      count and file count, and both build verdicts.
      (Core: 5771 tests, 0 failures. App bundle: 122 tests, 0 failures.
      SwiftLint --strict: 0 violations in 589 files. macOS Release build and
      generic iOS build: BUILD SUCCEEDED.)
- [x] Confirm the rule count agrees in all three places it is spelled — the suite's
      own marker count, `core-theme.md`'s canonical list and `CLAUDE.md`'s chrome
      invariant sentence.
      (Thirty-four in all three; the two count self-checks passed in `swift test`.)
- [x] Confirm `git status --porcelain` is empty.

## Post-Completion

For the acceptance review, needing a human and a running app:

- Open the commit dialog at 150% and 200% interface scale and confirm the file-type
  glyph now grows with the checkbox, the name and the status letter beside it.
