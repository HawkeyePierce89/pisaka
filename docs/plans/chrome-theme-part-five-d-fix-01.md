# Chrome theme, part five (d) — fix round 01

## Overview

This plan answers **revmux round `01-initial`** on branch `chrome-theme-part-five-d`
(task `chrome-theme-part-five-d`, profile `comprehensive`, sources 4/4, no
degradation). The round returned four confirmed findings, all `minor`, plus two
it judged immaterial. Three of the four are fixed here, the fourth is fixed
together with one ride-along promoted from the immaterial list because it is the
same class of defect.

One immaterial finding is **deliberately not acted on**: rule thirty-nine bans
`isAccepted` in every gated file, which is broader than the regression it guards
(a view re-deriving the good/bad verdict rule). No gated file spells it today, so
the ban costs nothing now, and narrowing it would weaken a rule for a
hypothetical. Left as it is on purpose — do not change it, and do not add a note
about it.

Nothing in this plan changes behaviour except where a finding says the branch
already changed it and should not have (Task 2).

## Validation Commands

```sh
swift test
xcodegen generate
xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-part5d-fix01 test
swiftlint --strict
xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' \
  -configuration Release -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-part5d-fix01 build
xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'generic/platform=iOS' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-part5d-fix01 build
```

Never pass a `-derivedDataPath` inside the repository.

## Implementation Steps

### Task 1: The spinner stops for good when Reduce Motion is switched off under it

**Finding:** `Sources/Pisaka/ChromeControls.swift:596-606`, confirmed by
`adversarial` and `arch+quality`, confidence 90.

> The rotation animation is keyed only on `isTurning`, which is set to `true`
> once in `onAppear` and never changes afterwards. A spinner that appears with
> Reduce Motion on draws still, which is correct. If Reduce Motion is then turned
> off while the same spinner is still shown (a long language-server install, a Log
> load, an armed merge wait), the rotation target changes but `isTurning` does
> not. The value-scoped `.animation` therefore never fires, and the spinner stays
> frozen until it leaves the view tree. This contradicts the doc comment's promise
> that the spinner turns unless Reduce Motion is on, and it affects every spinner
> site. The reverse switch, off to on, stops the spinner correctly.

- [x] Fix the mechanism, not the symptom: the rotation must be a function of the
      accessibility setting as it is *now*, not of a one-shot `@State` latched in
      `onAppear`. Drive the animation from the reduce-motion environment value
      itself, so a change in either direction re-evaluates the body and the
      animation starts or stops accordingly. `onAppear` must not be what starts
      the turning.
- [x] Keep the still drawing under Reduce Motion exactly as it is, and keep the
      `.updatesFrequently` trait.
- [x] Re-read the doc comment against the new code and make it state what the code
      does — including which direction of the switch does what.
- [x] **Sweep for the shape, not the site.** Grep the repository for every other
      place that latches a `@State` in `onAppear` and then feeds it to a
      value-scoped `.animation`, and for any other animation whose start is
      conditioned on an accessibility setting read once. Fix every occurrence in
      this same commit, or state in the commit message that the search found none.
- [x] **The test that would have caught it.** A unit test cannot observe a SwiftUI
      animation, so the guard is structural and goes in
      `ChromeThemeSourceGatingTests`: inside `ChromeSpinner`'s own brace-matched
      declaration, assert that `onAppear` is absent and that the reduce-motion
      property the body reads is named inside the `.animation(` call's
      brace-matched argument list. Both are presence/absence assertions inside a
      matched body — the suite's convention — and neither resolves a type,
      evaluates a conditional or decides which branch runs. Extend the rule's
      comment to say what regression it names.
- [x] Show the new clause **red** first, against the code as it is now, then green
      after the fix. Confirm the tree is clean afterwards.
- [x] Run `swift test` and the macOS build. Both must pass.

### Task 2: The cell editor must not draw the column's name inside the field

**Finding:** `Sources/Pisaka/DatabaseViewerView.swift:525-537`, confirmed by
`arch+quality` and `bugs+impl`, confidence 80.

> `cellEditor` passes `title: columnName(at: coordinate.column)` to
> `ChromeThemedTextField`. That component uses `title` both as the accessibility
> label and as a visible placeholder, drawn in `textSecondary` whenever the text is
> empty (`ChromeControls.swift:71-78`). The old editor was `TextField("", …)` and
> showed no placeholder. Editing a NULL cell (which deliberately starts with an
> empty draft) or an empty-string cell now shows the column name, e.g. "email",
> greyed inside the field. That looks like a dimmed stored value, and grey is how
> the grid draws NULL. Nothing wrong is stored, since Return commits the empty
> draft. But this is an unstated visible change in the one place where the viewer
> guards against NULL-versus-text confusion.

This is a behaviour change the sweep was not allowed to make, and it lands in the
worst possible place: a grey word inside the cell editor is indistinguishable from
how the grid renders NULL.

- [x] The cell editor must speak the column's name to assistive technology and
      draw **nothing** in an empty field, as it did before this branch. Give the
      shared field a way to carry a spoken name that is not also drawn, rather
      than passing an empty title and adding a separate `.accessibilityLabel` at
      the call site — the shape owes its own accessibility, which is why it takes
      the name at all.
- [x] **Enumerate what you touched.** The shared field's other callers must be
      unaffected: list every `ChromeThemedTextField(` construction in the tree and
      confirm each one still draws the placeholder it drew before this task, and
      that each still speaks a name. A caller that legitimately wants the name
      drawn keeps it drawn.
- [x] Correct the `cellEditor` doc comment and the matching sentence in
      `docs/architecture/core-database-viewer.md`: they say the field is "speaking
      the column's name", which describes only the accessibility half and is what
      let the visible half through review.
- [x] **The test that would have caught it.** In `ChromeThemeSourceGatingTests`,
      pin by set equality which `ChromeThemedTextField(` callers pass a drawn
      placeholder and which pass a spoken-only name, so moving a caller from one
      to the other fails until the pin moves with it. Name the grid's cell editor
      as the spoken-only one and say why in the comment.
- [x] Show the pin **red** by restoring the drawn title at the cell editor, then
      green. Confirm the tree is clean afterwards.
- [x] Run `swift test` and the macOS build. Both must pass. The viewer's two write
      paths, its write-gate consultations and its `isWriteInFlight` disable terms
      must be untouched — confirm by diffing them, not by assuming.

### Task 3: Three comments state the opposite of what the code does

**Finding:** `Sources/Pisaka/DatabaseViewerView.swift:400-401`, confirmed by
`docs+tests`, confidence 80.

> The header row applies `.background(alignment: .bottom) { hairline(horizontal:
> true) }` and then `.background(theme.color(.bgPanel))`. Each later `.background`
> goes further back, so from back to front the layers are bgPanel, the hairline,
> then the header content. The comment above says: "The rule is drawn behind the
> ground, never over it, so the strip's own fill cannot paint across it." That
> contradicts itself: a rule drawn behind the ground would be painted over by the
> fill, which is the failure the sentence says is avoided. The code is right; the
> hairline is over the ground and behind the content. The same wrong sentence
> appears word for word at `DatabaseConsoleView.swift:251`, and the `errorBanner`
> doc at `DatabaseViewerView.swift:161` has the same inversion. A maintainer who
> trusts these comments and swaps the two `.background` calls would hide the rule
> under the fill.

The code is correct at all three sites. Only the prose is wrong, and it is wrong
in the direction that would make the next reader break it.

- [ ] Rewrite the three sentences to say what the layers actually are: the ground
      goes on last and therefore sits furthest back, the hairline is applied before
      it and therefore lands over the ground and under the content. State the
      consequence the ordering buys, and state it in the direction the code
      implements.
- [ ] **Sweep for the shape, not the site.** This sentence is a construct, not
      three strings: grep the whole repository — every part of this sweep, not just
      the files this branch touched — for any comment claiming a rule, hairline or
      indicator is drawn *behind* or *under* the ground, and for any comment about
      `.background` ordering. Judge each hit against its own code and fix every
      inverted one in this same commit. Parts one through five (c) wrote comments
      about this same ordering; some are right and must be left alone. Grep for the
      pattern rather than the literal sentence — a sentence wrapped across a line
      break survives a search for the sentence.
- [ ] Check the same claim in `docs/architecture/core-theme.md`: if the canonical
      rule sixteen entry or the part five (d) section states the ordering
      backwards, fix it there too.
- [ ] **The test that would have caught it.** There is none, and say so in the
      commit message rather than inventing one: no assertion in this suite reads
      what a sentence means, and the existing ordering rule already pins the code,
      which is why the code is right and only the prose drifted. The guard for this
      class is the repository-wide sweep above.
- [ ] Run `swift test`. It must pass.

### Task 4: The spinner marker rule accepts any argument, and the alternating-fill rule misses the ordinary spelling

**Finding:** `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift:2021`,
confirmed by `adversarial`, `bugs+impl` and `docs+tests`, confidence 99.

> `spinnerMarkers(in:)` treats a construction as hidden whenever its modifier
> chain contains `.accessibilityHidden(`, whatever the argument
> (`spellsCall(".accessibilityHidden(", in: chain)`). So
> `ChromeSpinner().accessibilityHidden(false)` counts as hidden, and so does a
> conditional like `.accessibilityHidden(someFlag)`. Both pass rule twenty's
> exactly-one-marker clause and rule forty's per-file pair. When the value is
> false, the spinner is still an accessibility element and has no label. That is
> the "never neither — an unnamed element" case the rule says it forbids. The goal,
> the `ChromeSpinner` doc and `core-theme.md` all state the contract as
> `.accessibilityHidden(true)`. The sibling check `isHiddenByItsOwnChain` in the
> same suite already matches that literal. The stripped text keeps `true`, since it
> is not a string literal, so an exact check is possible. As written, the test stays
> green with the very defect it names.

This is the class three rounds of part five (b) were spent on: a rule weaker than
its own comment. The suite already has the right idiom one screen away.

- [ ] Match `.accessibilityHidden(true)` exactly where the contract says exactly
      that, following `isHiddenByItsOwnChain`, which already does. A conditional or
      a `false` must fail.
- [ ] **Sweep for the shape, not the site.** Every other clause in this suite that
      asserts a modifier by its call prefix while its own comment names a specific
      argument is the same defect. Grep the suite for `spellsCall(` and
      `containsToken(` uses whose comment promises a value, check each against
      what it actually matches, and fix every one in this same commit — or state
      that the search found none.
- [ ] **Ride-along, promoted from the round's immaterial list** (same class, same
      file, confirmed by three agents at confidence 85): rule forty-one bans
      `alternatingRowBackgrounds`, `isTinted` and `isMultiple`, but a zebra written
      the ordinary way, `index % 2 == 0`, sails straight through. Tighten it
      **narrowly**: look for the alternating expression inside a `.background(`
      call's brace-matched argument, which is the "inside a matched body" form the
      convention allows, rather than banning `%` across fifty-eight files. If that
      cannot be expressed without either over-reaching or resolving what an
      expression means, **leave rule forty-one exactly as it is and say so in the
      commit message** — a leaky check replaced by a different leaky check is not
      an improvement, and the convention forbids a rule that has to interpret.
- [ ] **The test that would have caught it** is the mutation the round's absence
      proves was never run. Add to the suite's mutation record and demonstrate each
      as red before green:
  - `ChromeSpinner().accessibilityHidden(false)` at a pinned site;
  - `ChromeSpinner().accessibilityHidden(someFlag)` at a pinned site;
  - if rule forty-one was tightened, a `.background(index % 2 == 0 ? … : …)` in the
    console.
- [ ] Re-read every count the two rules carry: the per-file spinner pairs must still
      sum to twenty, and the rule count must still read forty-one in the markers,
      the header, `core-theme.md` and `CLAUDE.md`.
- [ ] Confirm the tree is clean apart from the intended changes.
- [ ] Run `swift test`. It must pass.

### Task 5: Gates

- [ ] `swift test` — must pass, with no fewer tests than the 5784 this branch had.
- [ ] `xcodegen generate`, then the app bundle test command above — must pass
      (122 tests on this branch).
- [ ] `swiftlint --strict` from the repository root — zero violations.
- [ ] macOS Release build and iOS build — both must succeed.
- [ ] Confirm no acceptance point of the main plan regressed: fifty-eight gated
      files, twenty-one roles, `currentLine` and `bracketMatch` still unspent,
      forty-one rules consistent across the four places that count them, and every
      `ChromeSpinner(` construction carrying exactly one marker.
