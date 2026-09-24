# Chrome theme, part five (b) — fix 02: the third round's findings

## Overview

Answers revmux round `03-final` on task
`chrome-theme-part-five-b-commit-dialog-merge-editor-windows`: four sources, none
degraded, ten findings — one major, nine minor — all confirmed by verification and
all re-derived in the tree before this plan was written.

The major is a visible defect: the Local History window's revisions list shows no
selection at all, so the user cannot see which revision *Restore* will apply. It
was confirmed **live**, not from documentation — a standalone probe built the same
two list shapes side by side and captured them: the shipped shape highlights
nothing, the proposed one highlights the selected row.

Three of the minors are worse than their severity suggests, because they are about
the gate rather than the code. Rules thirty-one and thirty-four cannot catch the
regressions they were written for. A rule that cannot go red is not a weak
guarantee, it is the absence of one wearing the costume of a guarantee — and this
branch is about to put them in `master` as if they were real.

**One of them is the third appearance of a single class of blindness.** Part four
(b)'s rule twenty-one was blind to `.frame(\n height:)`. Part five (a) rewrote it
with brace matching. Rule thirty-four now searches for the contiguous text
`Image(systemName:` and is blind to `Image(\n  systemName:)`. Fixing the third
instance alone guarantees a fourth, so Task 3 fixes the class: **thirteen** call-shaped
searches in the suite match by contiguous text, and the ones whose call takes
arguments go through one shared whitespace-tolerant helper.

The remaining findings are a copied colour table and five passages of prose that
the branch made untrue.

## Validation Commands

```sh
swift test
xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-p5b-fix02 test
xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' \
  -configuration Release -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-p5b-fix02 build
xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'generic/platform=iOS' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-p5b-fix02 build
swiftlint --strict
```

Derived data never goes inside the repository working tree.

## Context

Files involved:
- `Sources/Pisaka/LocalHistoryView.swift` — the revisions `List` (~159–167).
- `Sources/Pisaka/CommitDialogView.swift` — `CommitFileRow.background` (~568).
- `Sources/Pisaka/ProjectTreeView.swift` — `TreeRowBackground`, read only.
- `Sources/Pisaka/BranchSwitcherView.swift` (~195, ~237),
  `Sources/Pisaka/ProjectSwitcherView.swift` (~157) — three frame-sized glyphs.
- `Sources/Pisaka/DiffView.swift` — `CodePaneGround`'s doc comment (~543–547).
- `Sources/PisakaCore/ChromeGeometry.swift` — `cornerRadiusMax`'s comment (~42).
- `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift` — rules thirty-one,
  thirty-three, thirty-four, one new rule, and the shared matching helper.
- `docs/architecture/core-theme.md` (~166, ~1144–1145, ~1207, ~1221, ~1853),
  `docs/architecture/app-git-views.md` (~529, ~741),
  `docs/architecture/core-local-history.md`.

Related patterns:
- A mapping with one owner is *called*, never restated. `TreeRowBackground
  .color(for:resolving:)` is the tree row's one state→role answer, exactly as
  `diffWashRole(for:)` and `changedFileRole(for:)` are Core's.
- The suite pins a set and names its exceptions. An exception must be **re-checked**
  against the reason it was granted, or it is a hole with a comment on it.
- A gating rule matches a call with a brace-matched body
  (`matchedBody(after:in:)`) or a whitespace-tolerant pattern, never a contiguous
  substring; identifier bans go through `LSPSourceGatingTests.containsToken(_:in:)`.
- On macOS a `listRowBackground` is drawn over the row's selection box. The
  documented shape for a selectable list is to return `Color.clear` for the
  selected row.

Dependencies: none new.

## Development Approach

- Testing approach: regular, except the gating work. Each new or changed rule is
  first shown red against a deliberately broken local edit, then reverted and shown
  green. **A rule that cannot be made red is not a rule** — and in this round three
  shipped in exactly that state, so this plan's mutations are the point of it, not
  its paperwork.
- Complete each task fully before the next; `swift test` must pass before the next
  task starts. A task touching app files also builds the macOS app.
- Read each file's `docs/architecture/` entry before modifying it.
- No new colour role, no new exemption to the colour rules, no new font size.
- No task takes a screen capture, and no task depends on a human opening a window,
  a sheet, a menu or a popover.
- No product or brand names in code, comments, documentation or commit messages.
- Where a rule is widened and the widening exposes existing code, **fix the code or
  pin it with its reason** — never narrow the rule back until it passes.
- CRITICAL: every task includes new or updated tests.

## Implementation Steps

### Task 1: The revisions list shows its selection

**Files:**
- Modify: `Sources/Pisaka/LocalHistoryView.swift`
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`
- Modify: `docs/architecture/core-local-history.md`, `docs/architecture/core-theme.md`

The defect: `List(browser.revisions, id: \.fileName, selection: selection)` gives
every row an unconditional `.listRowBackground(chromeColor(.bgPanel))`. On macOS
that background is drawn over the selection box AppKit draws for the row, so the
selected revision is indistinguishable from the others. *Restore* acts on that row,
so the one thing the list must show is the one thing it does not.

The comment beside it cites Find in Files as the precedent. That list is a plain
`List { }` with **no** `selection:` binding, so the precedent does not carry. Both
`core-local-history.md` and `core-theme.md` describe this list as leaving "platform
selection" alone, which is the opposite of what the code does.

- [x] Make the row background conditional: `Color.clear` for the selected row,
      `chromeColor(.bgPanel)` for the rest. Replace the Find in Files comment with
      the real reason — a row background is drawn over the selection box, so a
      selectable list must yield its selected row's background.
- [x] Sweep for the shape, not the site: every `List` in the gated set that binds
      `selection:`. There are three `listRowBackground` sites in the macOS tree
      today and only this list binds selection, but confirm that rather than
      trusting it, and report anything this plan did not account for.
- [x] **Rule thirty-five: a selectable list yields its selected row's background.**
      For each gated file, a `List` whose construction names `selection:` must not
      apply an unconditional `listRowBackground`: the background expression must
      name the selection it is conditioned on, or be absent. Match the `List(`
      construction through the shared helper from Task 3 (not a contiguous string),
      and take the background's argument as a brace-matched body.
- [x] Mutation-verify: make the background unconditional again and confirm red;
      restore and confirm green, with a clean `git status`.
- [x] Correct both documents to say the selected row yields its background so the
      platform's selection shows, rather than "platform selection" left alone.
- [x] Run `swift test` and the macOS build. Both must pass.

### Task 2: Rule thirty-one recognizes a code pane by its type, not its name

**Files:**
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`

The defect: `codePaneGroundAssignments(in:)` counts a `backgroundColor` receiver as
a code pane only when its last name segment, lowercased, ends in `textview` or
`scrollview`, or is a scroll view's `contentView`. The files the rule guards use
none of those names: `DiffView.swift` has `leftText`/`rightText` and
`leftScroll`/`rightScroll`; `MergeView.swift` has
`oursScroll`/`resultScroll`/`theirsScroll`, a `let scrolls: [NSScrollView]` and a
`for scroll in scrolls`. So `coordinator.leftText?.backgroundColor = …` or
`scroll.backgroundColor = …` passes the rule — and that is precisely the competing
second ground the rule exists to forbid.

- [x] Decide a receiver is a code pane by the **type it is declared with**, not by
      how it is spelled: an identifier declared in the same file as `NSTextView`,
      `NSScrollView`, `NSClipView` or a subclass of one (`DiffTextView`,
      `MergePaneTextView`), including a tuple binding from a factory returning
      those, and including the element bound by a `for x in` over an array of them.
      Keep the existing suffix test as a fallback so an unnamed receiver is still
      caught.
- [x] Flag a subscripted receiver (`scrolls[i].backgroundColor = …`) rather than
      silently passing it: if the rule cannot resolve the element's type, it fails
      loudly and asks for the assignment to be written plainly. A rule that cannot
      decide must not decide in favour of the code.
- [x] Mutation-verify with the **real names**, not with a name the old test would
      have caught: add `coordinator.leftText?.backgroundColor = ChromePalette
      .nsColor(.bgPanel)` to `DiffView.swift` and confirm red; add
      `scroll.backgroundColor = …` inside `MergeView.swift`'s loop and confirm red;
      revert both and confirm green, with a clean `git status`.
- [x] Record in the rule's comment what the old test missed and why the type-based
      test replaces it, so the next reader does not re-introduce the name test as a
      simplification.
- [x] Run `swift test`. It must pass.

### Task 3: One whitespace-tolerant call matcher, and rule thirty-four's two holes

**Files:**
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`
- Modify: `Sources/Pisaka/BranchSwitcherView.swift`, `Sources/Pisaka/ProjectSwitcherView.swift`
  (only if Task 3's re-classification demands it — see below)
- Modify: `docs/architecture/core-theme.md`

Two defects in one rule, plus the class behind the first:

1. `unsizedGlyphs(in:)` searches for the contiguous text `Image(systemName:`, so a
   multiline `Image(\n    systemName: …)` is skipped entirely. If such a glyph
   loses its size the count does not change and the gate stays green.
2. It treats a glyph as self-sized when its chain carries `.font(` **or** `.frame(`
   naming `metrics`. An `Image(systemName:)` that is not `.resizable()` draws at
   its font's size whatever frame it is given — the frame only reserves layout
   space. `BranchSwitcherView.swift:195`, `:237` and `ProjectSwitcherView.swift:157`
   are exactly that shape: a metrics frame, no font, no `resizable`. They follow
   the interface zoom only because of the enclosing `HStack`'s scaled font, and the
   rule never re-checks that container font because the frame took them out of the
   unsized set. Delete the container font and the rule stays green while three
   glyphs fall to the system default.

- [x] Add one shared helper that finds a call by its identifier and open paren,
      **tolerating whitespace and newlines between them**, returning the same
      ranges the contiguous search returns today.
- [x] Re-point every call-shaped search in the suite whose call **takes arguments**
      to that helper. There are thirteen contiguous call-shaped searches; the
      zero-argument forms (`Divider(`, `ChromeTheme(`) may stay as they are, with a
      one-line note at each saying why a wrapped form is not a real shape there.
      List in the commit message which searches were re-pointed and which were not.
- [x] Accept `.frame(` as sizing a glyph **only when the same chain also carries
      `.resizable()`**. Otherwise the glyph is unsized and must either take its own
      `.font(` or be pinned as a `containerFont` exemption — the category that is
      re-checked against the container actually setting a scaled font.
- [x] Re-classify the three frame-sized glyphs that this change exposes. They are
      sized by their container's font by design (the frame is a 16-point icon
      column for alignment), so they belong in the `containerFont` category, **not**
      in a new exemption and **not** given a font each. If the re-check finds a
      container that does not set a scaled font, that is a fourth real defect: fix
      it and say so.
- [x] Mutation-verify all three clauses: write one glyph in the multiline form and
      strip its size, confirm red; give a glyph a metrics `.frame(` without
      `.resizable()` and no font, confirm red; remove the container font above a
      `containerFont`-exempt glyph, confirm red. Revert each and confirm green,
      with a clean `git status`.
- [x] Update rule thirty-four's canonical wording in `core-theme.md` to say what
      now counts as sizing, and that a frame alone does not.
- [x] Run `swift test` and the macOS build. Both must pass.

### Task 4: The commit row calls the tree's mapping instead of copying it

**Files:**
- Modify: `Sources/Pisaka/CommitDialogView.swift`
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`
- Modify: `Sources/Pisaka/ChromePalette.swift`, `docs/architecture/core-theme.md`

The defect: `CommitFileRow.background` computes a `TreeRowState` and then switches
over it itself — `.selectedFocused → accentTintStrong`, `.selectedUnfocused →
selectionInactive`, `.hover → hoverTint`, the rest clear. `TreeRowBackground` in
`ProjectTreeView.swift` is documented as the one mapping from a `TreeRowState` to
its background, and both tree row kinds call it. The row's own comment claims it
paints "the established precedence the tree already paints" while copying the
table, so the day the tree's mapping changes the dialog keeps the old roles and
nothing fails. Rule thirty-three currently pins the copy in place.

- [x] Replace the switch with `TreeRowBackground.color(for:resolving:)`, widening
      that type's access only as far as the call needs.
- [x] Re-point rule thirty-three: instead of requiring the three role tokens in
      `CommitFileRow`'s body, require that the body names `TreeRowBackground`, and
      that no gated file other than the mapping's own file spells those three
      role tokens in a row-state switch.
- [x] Mutation-verify: restore the copied switch and confirm the re-pointed rule
      goes red; revert and confirm green, with a clean `git status`.
- [x] Drop the commit row from `ChromePalette.swift`'s `selectionInactive` consumer
      comment and from the matching sentence in `core-theme.md`: after this change
      the row spends the role through the tree's mapping, not by naming it.
- [x] Run `swift test` and the macOS build. Both must pass.

### Task 5: Five passages the branch made untrue

**Files:**
- Modify: `Sources/Pisaka/DiffView.swift`, `Sources/PisakaCore/ChromeGeometry.swift`
- Modify: `docs/architecture/core-theme.md`, `docs/architecture/app-git-views.md`

- [x] `DiffView.swift:543–547` — `CodePaneGround`'s comment says the role is
      `bgEditor` because "the gutter beside every such pane (`LineNumberRulerView`,
      `DiffGutterView`) fills itself with it". `DiffGutterView` fills nothing: it
      overrides only `drawHashMarksAndLabels`, so what sits behind it is the scroll
      view's ground — which this helper sets, so in the diff pane the cause runs the
      other way. The three merge panes have no ruler at all. Narrow the reason to
      `LineNumberRulerView` and say the other panes take the same ground so every
      code pane matches. Mirror the correction at `core-theme.md` (~1160) and
      `app-git-views.md` (~741).
- [x] `core-theme.md:1221` and `app-git-views.md:529` say `MergeThreePaneView`,
      `RevisionRow` and `SourceViewerPane` "read the environment from file scope".
      Only `RevisionRow` does. The other two are `NSViewRepresentable`s with no
      `@Environment` at all — their colours are dynamic `NSColor`s from
      `ChromePalette` and `CodePaneGround`. Name only `RevisionRow`, and say what
      the other two actually do.
- [x] `core-theme.md:1144–1145` says the suite grows "from twenty-seven rules to
      thirty-three", and `:1207` says "this part's six rules". The suite declares
      thirty-four and the branch added seven. Correct both, naming which rules came
      from the review rounds.
- [x] `core-theme.md:1853` says every gated file names a role "with two exceptions".
      The suite now exempts eight — the five window controllers and
      `SourceViewerContent.swift` joined the two. Name all eight and why each is
      exempt yet still gated.
- [x] `ChromeGeometry.swift:42` — `cornerRadiusMax`'s comment says the only smaller
      radii are `bottomBarToggleRadius` and `buttonCornerRadius`. `fieldCornerRadius`
      (part five (a)) and `checkboxCornerRadius` (this part) are both missing, and
      `core-theme.md:166` carries the same sentence beside a paragraph that
      introduces the second of them. Either list all four or reword it as "each
      small control's radius is a token of its own"; prefer the reword, since the
      list has now fallen behind twice.
- [x] No new test: all five are prose. Confirm `swift test` stays green — the
      count and canonical-list self-checks read these documents.

### Task 6: Verify the gates

- [ ] Run every command in **Validation Commands**. All must pass. Report exact
      counts: the Core test total, the app-bundle total, the SwiftLint violation and
      file counts, and both build verdicts.
- [ ] Confirm the rule count agrees in all three places it is spelled — the suite's
      own markers, `core-theme.md`'s canonical list and `CLAUDE.md`'s chrome
      invariant.
- [ ] Confirm `git status --porcelain` is empty.

## Post-Completion

For the acceptance review, needing a human and a running app:

- Open the Local History window (⌘⇧H) and click a revision: the row must be visibly
  selected, and it must be the row *Restore* acts on.
- Check the branch and project switcher popovers at 150% and 200% interface scale:
  the three re-classified glyphs must still grow with the text beside them.
