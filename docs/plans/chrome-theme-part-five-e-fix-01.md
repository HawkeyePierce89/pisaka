# Chrome theme, part five (e) — fixes for revmux round 01-initial

## Overview

This plan answers revmux round `01-initial` on task
`chrome-theme-part-five-e-served-document-pages`. That round came back with five
minor findings and no major or critical ones; a sixth item it filed as
*immaterial* is reinstated here, because the test it names is weaker than its own
doc comment and that is a defect by this repository's own convention.

Four of the six are statements that became false when part five (e) landed: a
comment or a design entry still describing the behaviour the change replaced. In
this repository that is not cosmetic — the whole source-gating suite exists
because prose drifts from what it claims to describe, and a rule or a comment
weaker than its own sentence is treated as a defect. The remaining two are a call
site that answers a question in a roundabout way its sibling answers directly,
and the weak test.

Nothing here changes what the app draws, with one exception that changes only
*how* a Bool is computed, not its value.

## Validation Commands

```sh
swift test
xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' test
swiftlint --strict
```

Use a DerivedData path outside the repository for any local build
(`~/Library/Developer/Xcode/DerivedData/pisaka-<purpose>`).

## Implementation Steps

### Task 1: the pane asks the appearance directly, as its sibling does

**Finding:** `Sources/Pisaka/MarkdownPreviewPane.swift:72`, minor, confirmed.
`appearanceKey` works out `prefersDark` by building a whole
`MarkdownPreviewTheme.resolved(...)` — a value carrying Core's restated chrome and
a 28-entry code-colour dictionary — and comparing it to `.dark`, only to throw
everything but the Bool away. The sibling served-page call site,
`LeetCodeDescriptionView.swift:345`, asks `ChromeAppearance.resolved(...)`
directly, so the two answer one question two ways. It also makes
`core-leetcode.md:1828`'s claim false as written: that line says no macOS app file
spells `Theme.resolved(`, and `MarkdownPreviewTheme.resolved(` contains exactly
that spelling — which matters because this suite's rules match tokens as
substrings over stripped text.

- [x] Compute `prefersDark` from `ChromeAppearance.resolved(settings.themePreference, systemPrefersDark: colorScheme == .dark) == .dark`, so the two served-page call sites ask the same question the same way and no macOS file spells `Theme.resolved(` at all.
- [x] Confirm the resulting Bool is identical for all three `ThemePreference` values in both system appearances; this is a refactor of the computation, not a behaviour change.
- [x] **Sweep for the shape, not the site:** search the macOS app layer for any other place that builds a themed value only to compare it against a case, and fix each occurrence in this commit.
- [x] Test: assert that no macOS app-layer file spells `Theme.resolved(` — as a token over the stripped text, so the `MarkdownPreviewTheme.` prefix cannot hide inside it. Put it in the gating suite beside rule forty-two, which is what `core-leetcode.md:1828` is about.
- [x] Run `swift test`; it must pass before Task 2.

### Task 2: clause (b)'s promise comes down to what it checks

**Finding:** `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift:197`,
minor, filed immaterial by the round and reinstated here as the prose half of the
finding above. Clause (b)'s doc, the suite summary, `CLAUDE.md` and
`core-theme.md` all say macOS never reads Core's restated block. That is false:
`SyntaxTheme.swift:230` starts from `MarkdownPreviewTheme.dark`/`.light`, which
carry `DocumentPageChrome.light`/`.dark`. Clause (b) bans two `resolved(`
spellings and cannot see the fallback arriving through
`MarkdownPreviewTheme.light`/`.dark` or a bare `DocumentPageChrome.light`/`.dark`.

The fix is to state the truth rather than to widen the ban until it matches an
absolute sentence. What is actually true, and what the change guarantees, is
about **drawing**, not reading: Core's restated chrome is a starting value on
macOS and is replaced from the palette before any page is built, so none of it
reaches a served page. Clause (a) is the rule that catches the realistic
regression and it stays exactly as it is.

- [x] Reword clause (b)'s doc comment, the suite's header inventory line, the sentence in `CLAUDE.md` and the one in `core-theme.md` so each says that no served page *draws* Core's restated chrome — it is replaced from the palette before the page is built — rather than that macOS never reads it.
- [x] Name in clause (b)'s doc comment the two paths by which the restated block legitimately does reach macOS (`MarkdownPreviewTheme.light`/`.dark` as the value `withChrome(_:)` overwrites, and `SyntaxTheme`'s starting point), so the next reader does not take the clause for a wider guarantee than it gives.
- [x] Leave clause (b)'s token list as it is, and say in the comment why it is a narrow ban and not the whole guarantee: the whole guarantee is clause (a).
- [x] Test: keep every existing clause green, and confirm by mutation that clause (a) still fails when the pane's `withChrome(...)` is removed.
- [x] Run `swift test`; it must pass before Task 3.

### Task 3: the stylesheet test sees the rule it names

**Finding:** `Tests/PisakaCoreTests/MarkdownPreviewPageTests.swift:200`, minor,
filed immaterial by the round and reinstated here. The test's doc comment promises
to catch a table silently losing its grid, and it cannot: it asserts only that the
whole stylesheet contains `var(--border)` somewhere, and that substring also
appears in the heading rule (line 64), the `hr` rule (90) and the blockquote rule
(96). Deleting the `th, td` border on line 280 — the single rule the whole
`tableBorder` collapse is about — leaves the assertion green.

- [x] Assert the table-cell rule specifically: find the `th, td` block and assert *its* body reads `var(--border)`, rather than searching the whole stylesheet for the substring.
- [x] Keep the existing negative assertion that `var(--table-border)` appears nowhere.
- [x] **Sweep for the shape, not the site:** any other assertion in this suite that reads a whole-file `contains` where it means "this rule declares this property" gets the same treatment in this commit.
- [x] Test: verify the new assertion is red when the `th, td` border declaration is deleted and green when it is restored, and say so in the doc comment so the next reader knows it was checked rather than assumed.
- [x] Run `swift test`; it must pass before Task 4.

### Task 4: clause (c)'s doc stops citing an example that does not exist

**Finding:** `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift:4497`,
minor, confirmed. Clause (c)'s doc comment says "a doc comment quoting a value (as
`DocumentPageChrome.swift`'s does) is not counted". No comment in that file quotes
a hex value — all twelve matches are the string literals. So the only example
given for why the comments-only scanner matters does not exist, and nothing in the
tree exercises the comment-exclusion half: if the stripping were dropped, the
pinned counts of 28 and 12 would stay green today.

- [ ] Correct the doc comment so it no longer cites a comment that is not there.
- [ ] Decide and state which of the two the clause needs, and do that one rather than both: either the comment-exclusion half is genuinely load-bearing here, in which case give it something to exercise, or it is inherited from the scanner and nothing in this file depends on it, in which case say that plainly instead of illustrating it with an invented case.
- [ ] Test: whichever was chosen, the suite must be able to tell the difference — if the exclusion is kept as load-bearing, a case in the tree must make the counts move when the stripping is removed; if it is documented as inherited, no test is added and the comment says why none is.
- [ ] Run `swift test`; it must pass before Task 5.

### Task 5: the three stale statements

Three statements became false when part five (e) landed. Each is a separate file
and none is a code change.

**Finding A:** `Sources/Pisaka/LeetCodeDescriptionView.swift:89`, minor, refined.
The `theme` property's doc comment says "The statement page itself is not chrome
and stays unthemed here — the served document carries its own colours", while
line 344 of the same file passes `ChromePalette.documentPageChrome(in:)` as that
page's theme.

**Finding B:** `docs/architecture/app-editor-overlays.md:1048`, minor, confirmed.
The `SyntaxTheme.swift` entry says the colours go over "through
`withCodeColors(_:)` — Core's chrome survives, this file supplies the code
palette". On macOS none of Core's chrome survives now. This file is **not in the
change's diff at all**, which is the point: the change made a document elsewhere
wrong.

**Finding C:** `Sources/PisakaCore/LeetCodeStatementDocument.swift:19`, minor,
confirmed. The header says "`Theme.resolved(_:systemPrefersDark:)` is that one
mapping, kept here so both platforms make it identically". Both halves are false:
macOS no longer calls it, and it is no longer defined in this file — `Theme` is a
typealias and `resolved` delegates to `ChromeAppearance.resolved`.

- [ ] Fix A: say where the page's colours now come from, and keep the true half — the header, the collapsed strip, the rules and the resize handle draw from the roles.
- [ ] Fix B: rewrite the entry to say what happens now — this file supplies the code palette, and the pane replaces the chrome from the palette, so Core's restated chrome does not reach the page on macOS.
- [ ] Fix C: say that the mapping is `ChromeAppearance.resolved`, that `Theme` is the shared `DocumentPageChrome`, and that iOS is its remaining caller.
- [ ] **Sweep for the shape, not the site:** grep the repository for every other sentence asserting that the served pages carry their own colours, that Core's chrome survives into the preview, or that both platforms share the statement's resolution, and fix each in this commit. Grep for the constructs, not the literal phrases — a sentence wrapped across a line break survives a search for the phrase.
- [ ] Test: this task's surface is prose, so the check is the sweep above plus the suite's own count and inventory tests; state in the commit message which files the sweep touched and that it was run.
- [ ] Run `swift test`; it must pass before Task 6.

### Task 6: the gates

- [ ] `swift test`.
- [ ] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' test`, DerivedData outside the repository.
- [ ] `swiftlint --strict` from the repository root.
- [ ] Unsigned macOS Release and iOS (`generic/platform=iOS`) builds, as CI runs them.
- [ ] Confirm no product or brand name entered any file this plan touched.
