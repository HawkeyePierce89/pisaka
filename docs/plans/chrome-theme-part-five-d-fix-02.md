# Chrome theme, part five (d) — fix round 02

## Overview

revmux round `02-after-fix` came back with **nothing** (profile `final`, sources
2/2, no degradation). This plan answers the **acceptance review** instead, which
found what a major-only round does not report. Every item below was verified in
this session — five of them by mutation against the suite, one by a standalone
probe that measured the real AppKit result — and nothing here rests on reading
alone.

Nothing in this plan changes behaviour except where an item says the branch
already changed it and should not have (Tasks 1 and 2).

**One thing is deliberately left undecided and must be recorded, not fixed.**
Rule twenty-four's menu half rests on a premise the probe in Task 1 disproves:
it assumes a `Section` replaces the platform's separator with something the
theme reaches. It does not — it emits *more* platform separators. Whether
`Section` is the right menu idiom anywhere in this repository is a question about
a convention two earlier parts established, and it is the user's to answer. This
plan narrows the rule for the one shape it measured and writes the question down.
**Do not rewrite the convention, do not touch the repository's other
`Section`-separated menus, and do not restate the question as settled.**

## Validation Commands

```sh
swift test
xcodegen generate
xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-part5d-fix02 test
swiftlint --strict
xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' \
  -configuration Release -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-part5d-fix02 build
xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'generic/platform=iOS' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/pisaka-part5d-fix02 build
```

Never pass a `-derivedDataPath` inside the repository.

## Implementation Steps

### Task 1: The problem-catalog menu gained three separator lines

`Sources/Pisaka/LeetCodeOpenProblemSheet.swift:292` and `:304` replaced one
`Divider()` in `LeetCodeCommands` with two `Section { }` groups. A standalone
SwiftUI probe, built and run against the real AppKit menu, measured what each
shape actually produces inside a `Commands` builder — item arrays read after
`NSMenu.update()`, heights read from `NSMenu.size`:

```
Section { A; B }; Section { C }     seps=4  height=126.0  [|SEP|,A,B,|SEP|,|SEP|,C,|SEP|]
A; B; Section { C }                 seps=2  height=104.0  [A,B,|SEP|,C,|SEP|]
Section { A; B }; C                 seps=2  height=104.0  [|SEP|,A,B,|SEP|,C]
A; B; Divider(); C                  seps=1  height= 93.0  [A,B,|SEP|,C]
```

AppKit neither hides the leading and trailing separators nor collapses the two
adjacent ones: the 33-point difference is three separator rows laid out and
drawn. So the menu now shows a line above its first item, two lines between the
groups and a line below its last, where it showed one line between the groups.
That is a visible change the sweep was not allowed to make, and it was made by a
change whose purpose was to *keep* the separator.

- [x] Restore the menu's previous shape: exactly one separator, between the two
      groups. The measurements above say only `Divider()` does that inside a
      `Commands` builder, so `LeetCodeCommands` goes back to it.
- [x] Rule twenty-four must then permit it, **narrowly and with its reason
      stated**: a `Divider()` inside a `Commands`/`CommandMenu` builder is a main
      menu separator, drawn by AppKit inside a menu where no chrome role reaches
      it, and the rule's own premise — that a `Section` avoids the platform
      separator — is false there. Scope the exception to that shape and to this
      file, pin it by set equality like every other exception, and say in the
      comment what was measured (the four shapes, the heights) so the next reader
      does not re-derive it.
- [x] **Enumerate what you touched.** List every `Commands`/`CommandMenu` builder
      in the repository and every gated file among them; the exception must cover
      exactly the ones that need it and no more. `PisakaApp.swift` is not gated,
      so it needs nothing.
- [x] Correct the comment at `:290-292`. Its present claim — "the menu's
      separator in this repository — never a `Divider()`" — is false in two
      directions: `PisakaApp.swift` spells `Divider()` in five menu builders
      (lines 1334, 1391, 1451, 1494, 1503), and `Section` does not replace the
      platform separator. Say what is true.
- [x] Correct `CLAUDE.md`'s "no gated file spells `Divider()` and every menu
      separates with `Section`". The first half stays true with the new
      exception stated; the second half is false and must go or be narrowed.
- [x] **Record the open question** in `docs/architecture/core-theme.md`, in the
      open-questions list, not as a decision: a `Section` inside a menu builder
      emits a separator on each side of the group, so the repository's other
      `Section`-separated menus (`SearchHistoryMenu.swift`,
      `ProjectTreeView.swift`, `LocalChangesView.swift`, `DatabaseViewerView.swift`)
      may be drawing edge separators nobody asked for. State the probe's numbers,
      state that those menus were **not** measured and **not** changed, and leave
      the question open.
- [x] **The test that would have caught it.** No token rule can measure a
      rendered menu, and say so rather than inventing one. What *is* assertable
      and must be added: `LeetCodeCommands`' separator is pinned by shape — the
      file spells exactly one `Divider()` inside its commands body and no
      `Section` there — so a future silent swap back moves the pin.
- [x] Show that pin red against the two-`Section` shape, then green. Confirm the
      tree is clean.
- [x] Run `swift test` and the macOS build. Both must pass.
      `MenuShortcutUniquenessTests` must stay green.

### Task 2: The browser lost the context menu below its rows, and the empty-area selection clear

`master:Sources/Pisaka/LeetCodeBrowserView.swift:300-303` put the menu on the
whole table:

```swift
.contextMenu(forSelectionType: Row.ID.self) { ids in
    Button("Open") { open(slug: ids.first ?? selection) }
} primaryAction: { ids in
    open(slug: ids.first)
}
```

The `?? selection` branch existed precisely because `ids` is empty when the
right-click lands off a row, so a right-click on the empty area below the list
still offered *Open* for the current selection. HEAD attaches
`.contextMenu { Button("Open", action: onOpen) }` to each row
(`LeetCodeBrowserView.swift:638-640`), so the area below the last row now has no
menu at all. `Table(rows, selection: $selection)` also cleared the selection on a
click in that empty area; nothing does now.

- [x] Restore both: a right-click below the rows offers *Open* for the current
      selection (and offers nothing when there is no selection), and a plain
      click there clears the selection. Keep the per-row menu as it is.
- [x] Do not reintroduce a platform table, and do not add a second definition of
      what Open does — the row's `onOpen` and the explicit button must still
      reach one call site.
- [x] **The test that would have caught it** is not a token rule either: what is
      assertable is that the row list's container spells a `.contextMenu` of its
      own. Add that to rule twenty's browser entry alongside the row's, or say
      why it cannot be pinned and leave it to the Post-Completion check.
- [x] Run `swift test` and the macOS build. Both must pass.

### Task 3: Rule twenty's browser entry does not hold two of the four things it claims

`Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift:1867-1875`. The comment
claims "one combined element carrying the selected trait and a named Open
action, its Premium lock spoken by name". `required` is checked by `spellsCall`,
which finds the modifier *name* anywhere in the body and reads no argument.
Measured in this session by mutation, with the suite as the oracle:

| mutation | result |
|---|---|
| delete `.accessibilityElement(children: .combine)` from the row | **GREEN — not held** |
| `.accessibilityAddTraits(isSelected ? .isSelected : [])` → `.accessibilityAddTraits([])` | **GREEN — not held** |
| `.accessibilityAction(named: "Open", onOpen)` → `.accessibilityAction { onOpen() }` | RED — held |

`accessibilityElement` and `isSelected` are spelled nowhere in the suite outside
that `required` literal. The third mutation is red only because
`.accessibilityAction {` has no `(` for `spellsCall` to find — held by an
accident of syntax, not by design, and worth saying so.

- [ ] Make the rule hold what its comment says, within the convention: a rule
      pins a set by equality or asserts the presence or absence of a token,
      optionally inside a brace-matched body. It must not resolve a type,
      evaluate a conditional or decide which branch runs. So assert the tokens
      that name the claims — the combining call, the selected trait, the action's
      name — inside the row struct's own brace-matched body, exactly as they are
      spelled.
- [ ] Any claim that cannot be expressed that way must be **removed from the
      comment**, not left standing. A comment promising what the matcher cannot
      see is the defect this task exists for.
- [ ] **Sweep for the shape, not the site.** Every `ControlBuilder` entry whose
      comment names a property its `required` list cannot see is the same defect.
      Read all of them against their matchers and fix every one, or state that the
      search found none beyond the two in Task 4.
- [ ] **Mutations, each red before green:** the three in the table above, plus
      one for each claim the repaired rule newly holds.
- [ ] Run `swift test`. It must pass.

### Task 4: Two rule-twenty entries say "each" where the matcher asks for one, and rule forty-one claims more than it holds

- [ ] `:1858-1863` (`DatabaseViewerView`'s `footer`) and `:1877-1885`
      (`LeetCodeDescriptionView`'s `header(`) both say the controls are "each
      named outright" while `required: [".accessibilityLabel("]` is satisfied by
      one label anywhere in the builder. `footer` holds two labelled chevrons
      ("Previous page", "Next page"); `header(` holds two ("Hide the problem
      description", "Open this problem on leetcode.com"). Deleting either of each
      pair keeps the rule green. Either count the labels per builder — which is a
      count, and assertable — or drop the word "each". The pre-existing entries'
      prose says only that an icon-only control spells `.accessibilityLabel(`,
      which is what the matcher does; keep that wording where it is honest.
- [ ] Rule forty-one's `% 2` clause reads `.background` through
      `#"\.\s*background(?![A-Za-z0-9_])"#`, which cannot reach
      `.listRowBackground(`. Measured: a `.listRowBackground(index % 2 == 0 ? … : …)`
      added to the console leaves the suite **GREEN**. Either widen the clause to
      the modifiers that can carry a row fill — named explicitly, as a set, so the
      list is readable — or state the limit honestly in the comment and in
      `core-theme.md:2536-2547`, which today names only the named-variable case.
      The token ban (`alternatingRowBackgrounds`, `isTinted`, `isMultiple`) is
      total across the fifty-eight files and stays as the real defence.
- [ ] Fix the wording slip in the same rule: `:4212` and `core-theme.md:2542` say
      "its **brace**-matched argument list" where the matcher balances on `(`.
- [ ] **Mutations, each red before green:** deleting one label from each of the
      two builders named above; and, if the clause was widened, the
      `.listRowBackground` parity fill that is green today.
- [ ] Run `swift test`. It must pass.

### Task 5: The verdict test re-derives the implementation instead of pinning it

`Tests/PisakaCoreTests/ChromeRoleMappingTests.swift:174-177`:

```swift
let expected: ChromeColorRole = verdict == .accepted && matched != false
    ? .statusGreen : .statusRed
```

That is `ChromeColorRole.swift:190` transcribed, so the loop cannot fail for any
change to the rule it names — the expectation moves with the implementation. All
eight siblings in the same file pin a literal table and assert
`Set(expected.keys) == Set(allCases)`; this one does not, so the file's header
claim — amended on this branch — that every answer is pinned verbatim over
`allCases` is false for it. The four trailing literal assertions cover four of
the thirty verdict × match combinations.

- [ ] Pin it the way its siblings are pinned: a literal table over every
      `LeetCodeVerdict` × {`nil`, `true`, `false`}, with the key set asserted
      equal to the full product, so a tenth verdict case fails the test until
      someone writes down what colour it is.
- [ ] **Sweep for the shape, not the site.** Any other test in the repository
      whose `expected` is the implementation's own expression is the same
      tautology. Grep for it and fix every one, or state that the search found
      none.
- [ ] **The test that would have caught it** is the mutation: change
      `ChromeColorRole.verdictRole`'s rule (for instance drop the
      `matchedExpected != false` term) and confirm the repaired test is red where
      the present one is green. Demonstrate both.
- [ ] Run `swift test`. It must pass.

### Task 6: A geometry token now sizes two surfaces it does not name

`ChromeGeometry.menuFieldHeight` is documented at `ChromeGeometry.swift:183-187`
as "The shared **menu field's** height", = 26. Before this branch its two callers
were both `ChromeMenuField` (`SettingsView.swift:234`,
`NewPullRequestSheet.swift:115`). This branch added four, of which two are
`ChromeThemedTextField`:

- `Sources/Pisaka/LeetCodeBrowserView.swift:205` (the query field)
- `Sources/Pisaka/LeetCodeOpenProblemSheet.swift:173` (the problem input)

Every other text field in the repository that pins a height uses a token local to
its own surface: `SearchLayout.queryFieldHeight` = 33 (three sites in
`ProjectSearchView.swift`), `FilterBarLayout.controlHeight` = 22 (five sites in
`LogFilterBar.swift`). `LeetCodeBrowserView.swift` already declares
`LeetCodeBrowserLayout` on this very branch, with five such tokens, and does not
use it here. The consequence is the coupling rule seven exists to prevent,
arriving by a different route: changing the menu field's height silently resizes
two unrelated text fields, and nothing names the connection.

- [ ] Give each text field a height from its own surface's layout enum, leaving
      `menuFieldHeight` to the menu fields it is named for. Keep the rendered
      height the same unless the surface's own number differs for a stated reason.
- [ ] **Enumerate what you touched.** List every `menuFieldHeight` caller
      afterwards and confirm each one is a `ChromeMenuField`.
- [ ] **The test that would have caught it:** pin `menuFieldHeight`'s callers by
      set equality, as the shared control shapes' callers already are.
- [ ] Show the pin red with a text field borrowing the token again, then green.
- [ ] Run `swift test` and the macOS build. Both must pass.

### Task 7: Prose that contradicts the tree

Each of these was verified by reading both sides. None is a code defect; all of
them would mislead the next reader, which is the same class as fix round 01's
inverted layering comments.

- [ ] `docs/architecture/core-theme.md:1599` calls these "the last seven unswept
      macOS chrome views", and `:1807` then says "whatever macOS chrome view is
      still ungated" remains — the two cannot both be true. A verified
      counterexample: `Sources/Pisaka/FilePanels.swift:149` sets
      `reason.textColor = .systemRed` on the project tree's inline-naming refusal
      sentence, and that file appears nowhere in the suite. Replace the claim
      with what is true and name the counterexample.
- [ ] `CLAUDE.md`'s new clause says "no `isGood` and no case-label table in a
      view". The **colour** tables moved to Core; case-label tables remain and are
      legitimately pinned by count — `LeetCodeBrowserRow.statusCell` and
      `LeetCodeBrowserView.title(for:)` twice, nine labels in all, which
      `core-theme.md:2463-2467` states correctly. Narrow the summary line to what
      moved.
- [ ] The same clause's "no alternating row fill (a table reads by selection and
      hover)" is imprecise for the database grid, which this branch's own
      documentation says has no row selection: hover is its only row state. Say
      that.
- [ ] `Sources/Pisaka/LeetCodeDescriptionView.swift:227-230`,
      `core-theme.md:1777-1780` and `core-leetcode.md:1774-1776` all say the
      statement pane's resize handle "takes `ContentView.panelDivider`'s shape: a
      transparent hit area with a centred `hairline`". The handle is that;
      `ContentView.panelDivider` (`ContentView.swift:626-637`) is not — it is an
      opaque `chromeColor(.bgPanel)` fill with a **top**-aligned hairline overlay.
      Describe the handle without miscasting what it is compared to.
- [ ] `Sources/PisakaCore/ChromeGeometry.swift:188` calls `spinnerSide` "the small
      control size it replaces". One of the twenty sites,
      `CommitDialogView.swift:146`, was a bare `ProgressView()` with no
      `.controlSize(.small)` — so it halves rather than staying put. The shrink is
      geometry and in remit; the claim of uniformity is what is wrong.
- [ ] `ChromeThemeSourceGatingTests.swift` around `:2218` says "which is the rule
      this states for all three" while `cursorPushingFunctions` now holds four
      entries, `syncResizeHandleCursor` having joined. Fix the number.
- [ ] **Sweep for the shape, not the site.** Grep the added and changed doc and
      comment lines of this branch for any other count written as a word or digit
      and check each against the set it describes.
- [ ] Run `swift test`. It must pass — the documentation checks read these files.

### Task 8: Gates

- [ ] `swift test` — must pass, with no fewer tests than this branch's 5786.
- [ ] `xcodegen generate`, then the app bundle test command above — must pass
      (122 tests).
- [ ] `swiftlint --strict` — zero violations.
- [ ] macOS Release build and iOS build — both must succeed.
- [ ] Confirm nothing regressed: fifty-eight gated files, twenty-one roles,
      `currentLine` and `bracketMatch` still unspent, twenty `ChromeSpinner`
      constructions each carrying exactly one accessibility marker, and the rule
      count consistent across the suite's markers, its header, `core-theme.md`
      and `CLAUDE.md` — whatever that count becomes if a rule gains a clause.

## Post-Completion

Not automatable; needs a running app and a person.

- Open the problem-catalog menu and confirm one separator between the two groups,
  none above the first item and none below the last.
- Right-click the empty area below the browser's rows: *Open* is offered for the
  current selection, and a plain click there clears the selection.
- With System Settings → Appearance → *Show scroll bars: Always*, open the browser
  and confirm the column header stays aligned with the rows it names. The header
  sits outside the scroll view, so a legacy scroller narrows the rows' container
  and not the header's — **suspected, never confirmed**.
- Open the database viewer's sidebar and confirm whether the Tables and Views
  section headers could be collapsed before this branch and still can. The
  `.sidebar` list style supplied that control and `.plain` does not —
  **suspected, never confirmed**.
