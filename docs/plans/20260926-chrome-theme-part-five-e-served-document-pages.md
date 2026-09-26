# Chrome theme, part five (e): the two served document pages and the alert accessory

## Overview

This part closes the macOS colour sweep. Two served web pages still have a colour family of their own:

- the Markdown preview (`MarkdownPreviewTheme`, 14 chrome hex literals);
- the problem statement (`LeetCodeStatementDocument.Theme`, 12 chrome hex literals).

One alert accessory, `FilePanels.swift:149`, still uses `.systemRed`.

After this change both pages take their chrome from one shared Core value, `DocumentPageChrome`. Core restates that value as a fallback a test can check. At run time the app replaces it wholesale with a value derived from `ChromePalette`. The preview's code half already works this way through `withCodeColors(_:)`, and the code half itself is not touched. The alert accessory joins the gated set and takes `statusRed` through the palette's dynamic AppKit path. No twenty-second role is added.

### Decisions fixed by this plan (transcribed, not referenced)

Seven page meanings map onto six existing roles:

| Page meaning | Role | dark | light |
|---|---|---|---|
| background (the page) | `bgEditor` | `#2f3136` | `#ffffff` |
| text | `textPrimary` | `#dfe1e5` | `#1d1d1f` |
| secondaryText | `textSecondary` | `#a0a3aa` | `#6e6e73` |
| link | `accent` | `#4f8dff` | `#2f6fe0` |
| codeBackground | `bgCanvas` | `#1e1f22` | `#f5f5f7` |
| border (and the former tableBorder) | `hairline` | `#393b40` | `#d1d1d6` |

**The page ground is `bgEditor`; a code block is `bgCanvas`.**

- The roles' own definitions decide this. `bgCanvas` is "the window's own ground, behind everything that has no surface of its own".
- A served page has a surface of its own. It sits beside the editor and reads as the same paper, so it takes `bgEditor`.
- A fenced code block is a recess that shows the window ground beneath it, so it takes `bgCanvas`.

**Rejected alternatives:**

- `bgCanvas` for the page: the page would become the window ground, and in light the code blocks would be the brightest thing on screen.
- `bgPanel` for code:
  - A `pre` has no border on either page. `preview.css`'s `pre` rule sets only background, radius and padding, and the statement stylesheet does the same.
  - So the difference between the two grounds is the only thing that separates a code block from the page.
  - In dark, `#2b2d30` against `#2f3136` would make fenced blocks effectively invisible.

**Record this in the docs:** a code block has no border, which is why the two grounds must stay distinguishable. A later change that adds a border may revisit the choice; nothing else may.

**`tableBorder` collapses into `border`, which is `hairline`.** The deleted test's reason gets an answer in four parts. Task 2 puts this answer in the replacing test's doc comment, and Task 6 puts it in core-theme.md's part five (e):

1. **The closed vocabulary requires the collapse; it is not a preference.**
   - The vocabulary names exactly one line colour, and there is no role for a stronger separator.
   - So a served page may not draw a line stronger than the one every other swept surface draws.
2. **The measured cost, as values:**
   - Dark: the table grid goes from `#4a4a4e` on a `#1e1e1e` page to `#393b40` on a `#2f3136` page. A strong grid becomes exactly as subtle as every other hairline in the app.
   - Light: from `#c7c7cc` on white to `#d1d1d6` on white.
3. **Why this is the one place the collapse is felt.**
   - A code block's ground may be subtle because it is a large filled area. A one-pixel line may not be.
   - So `codeBackground` moving is invisible, and the rule line moving is not.
4. **The remedy if it reads badly on screen** is a change to `hairline` itself, which affects every swept surface. It is never a page-local override and never a twenty-second role.

**`colorScheme` stays.** It is `"dark"` or `"light"`, taken from the appearance, and is not a colour.

### What moves on screen

**Light barely moves.** Page, text and secondary text are unchanged. The rest:

- Link: `#0066cc` → `#2f6fe0`
- Code: `#f2f2f7` → `#f5f5f7`
- Border: `#d2d2d7` → `#d1d1d6`
- Table border: `#c7c7cc` → `#d1d1d6` (see the collapse's measured cost above)

**Dark moves on purpose.** The page rises to the editor ground and code recesses to the window ground:

- Page: `#1e1e1e` → `#2f3136`
- Code: `#2a2a2e` → `#1e1f22`
- Text: `#e8e8ed` → `#dfe1e5`
- Secondary text: `#9a9aa0` → `#a0a3aa`
- Link: `#6bb3ff` → `#4f8dff`
- Border: `#3a3a3e` → `#393b40`
- Table border: `#4a4a4e` → `#393b40` (see the collapse's measured cost above)

**The table header row inverts along with the code ground.**

- `th` reads `--code-background`.
- In dark it goes from raised (`#2a2a2e` on `#1e1e1e`) to recessed (`#1e1f22` on `#2f3136`).
- The header row is still told apart by its ground; the direction of that difference flips, as it does for code blocks.

**iOS.** The iOS statement page reads Core's restated block, which now states these same values, so it moves the same way. No file under `Sources/Pisaka/iOS/` is edited.

### Reading of the acceptance line on hex literals

The line "no hex literal in PisakaCore outside SHA256.swift" cannot hold literally:

- The ticket keeps the 28 code-half literals out of scope.
- Requirements 2 and 7 require Core to restate the chrome block.

This plan reads it as three conditions, and the new gating rule pins the counts:

- Every CSS hex literal in Core is in one of exactly two restated blocks: `MarkdownPreviewTheme.swift`'s code half (28) and `DocumentPageChrome.swift` (12).
- A test pins each block equal to its app-side table.
- `LeetCodeStatementDocument.swift` spells none.

"Changing one palette value changes both served pages with no other edit" holds for what macOS draws. As with the code half, the restatement test then fails until Core's fallback is updated. That failure is the intended second safety net. It is not a second edit the screen needs.

### Facts about `preview.css`

- **No pin.** `preview.css` has no byte-count or SHA-256 pin. `Resources/MarkdownPreview/VENDORED.md` records it as "written here", and only the two vendored bundles are pinned. Do not add a pin for it or update one.
- **An existing invariant stays true.** `VENDORED.md` already states that `preview.css` has "no colour of its own: every colour is" a custom property. Replacing `var(--table-border)` with `var(--border)` keeps that true. Cite this invariant where it matters; do not restate it anywhere new.

## Context

**Files involved:**

- Core, created: `Sources/PisakaCore/DocumentPageChrome.swift`
- Core, modified: `MarkdownPreviewTheme.swift`, `LeetCodeStatementDocument.swift`, `MarkdownPreviewPage.swift`
- Resources: `Resources/MarkdownPreview/preview.css` (the table-cell rule only; no pin exists or is added)
- macOS app layer: `ChromePalette.swift`, `MarkdownPreviewPane.swift`, `LeetCodeDescriptionView.swift`, `FilePanels.swift`, `SyntaxTheme.swift` (doc comment only)
- Core tests: `Tests/PisakaCoreTests/{MarkdownPreviewThemeTests, MarkdownPreviewPageTests, LeetCodeStatementDocumentTests, ChromeThemeSourceGatingTests}.swift`, plus a new `DocumentPageChromeTests.swift`
- App-layer tests: `Tests/PisakaAppTests/{ChromePaletteTests, SyntaxThemeTests}.swift`
- Docs: `CLAUDE.md`, `docs/architecture/{core-theme, core-markdown-preview, core-leetcode}.md`

**Related patterns:**

- `withCodeColors(_:)`, together with the pair of tests `SyntaxThemeTests.testThePreviewThemeCarriesTheEditorsPaletteInBothAppearances` and `testTheDomainLayersRestatedCodeColoursEqualTheEditorTable`. This is the precedent for two separate tests.
- `ChromeAppearance.resolved(_:systemPrefersDark:)`.
- `ChromePalette.nsColor(_:)`, the dynamic AppKit path.
- `GitHubSourceGatingTests.strippingComments(_:)`, the comments-only scanner for a rule whose subject is a string literal.

**Dependencies:** none new.

## Development Approach

- **Testing approach:** Regular (code first, then tests in the same task).
- Complete each task fully before moving to the next.
- `PisakaCore` stays Foundation-only. The role mapping is a Core decision; the app layer only formats values and wires calls.
- A new Core file needs `xcodegen generate` before the app-layer bundle builds. Local builds use a DerivedData path outside the repository.
- No product or brand names in code, comments, docs or commit messages.
- **CRITICAL: every task MUST include new/updated tests**
- **CRITICAL: all tests must pass before starting next task**

## Implementation Steps

### Task 1: Core — the one document-page chrome value

**Files:**
- Create: `Sources/PisakaCore/DocumentPageChrome.swift`
- Create: `Tests/PisakaCoreTests/DocumentPageChromeTests.swift`

- [x] Add a public `DocumentPageChrome` (Equatable, Sendable) with:
  - six colour fields: `background`, `text`, `secondaryText`, `link`, `codeBackground`, `border`, plus `colorScheme`;
  - a public memberwise init;
  - a closed `Field` enum (CaseIterable) and `static func role(for: Field) -> ChromeColorRole`, carrying the table above;
  - `init(appearance: ChromeAppearance, value: (ChromeColorRole) -> String)`, which fills every field from its role and sets `colorScheme` from the appearance;
  - `static let light` and `static let dark`, which restate the palette's values from the table above as lowercase `#rrggbb` strings;
  - `static func resolved(_ preference: ThemePreference, systemPrefersDark: Bool)`.
- [x] Write a doc comment that says:
  - This is the one chrome source both served pages take.
  - The `light`/`dark` blocks are a fallback: iOS reads them, and a Core test can assert them.
  - macOS replaces them wholesale with values from the palette.
  - A code block has no border, so its ground role must stay distinguishable from the page's. Only a change that adds a border may revisit that pair.
  - There is one line colour, `hairline`, because the vocabulary names one (point it to core-theme.md's part five (e) for the full reasoning).
- [x] Write tests:
  - the role table, pinned exactly, field by field;
  - the six roles are distinct, and in particular the page-ground role differs from the code-ground role;
  - `init(appearance:value:)` routes each field through its own role, checked with a closure that echoes the role's raw value;
  - `colorScheme` follows the appearance;
  - light ≠ dark on every colour field;
  - `resolved` covers all three preferences.
- [x] Run `swift test`; it must pass before Task 2.

### Task 2: Core — both themes carry the shared chrome; tableBorder collapses

**Files:**
- Modify: `Sources/PisakaCore/MarkdownPreviewTheme.swift`, `Sources/PisakaCore/LeetCodeStatementDocument.swift`, `Sources/PisakaCore/MarkdownPreviewPage.swift`, `Resources/MarkdownPreview/preview.css`
- Modify: `Tests/PisakaCoreTests/MarkdownPreviewThemeTests.swift`, `MarkdownPreviewPageTests.swift`, `LeetCodeStatementDocumentTests.swift`, and `MarkdownPreviewModelTests.swift` only if field paths need updating

- [ ] `MarkdownPreviewTheme`:
  - Its chrome becomes one stored `chrome: DocumentPageChrome`, and `tableBorder` is removed.
  - `.light` and `.dark` take `DocumentPageChrome.light` and `.dark`, so the preview theme spells no chrome literal of its own.
  - Add `withChrome(_:)`, the chrome counterpart of `withCodeColors(_:)`. It replaces the chrome wholesale and leaves `codeColors` untouched.
  - `withCodeColors(_:)` behaves exactly as before. `color(for:)`'s fallback reads `chrome.text`.
  - Update the doc comments: the chrome is now shared by construction, not by assertion. The long restatement paragraph gains the chrome half's pair of tests (Task 3).
- [ ] `LeetCodeStatementDocument.Theme`:
  - Becomes `public typealias Theme = DocumentPageChrome`. It is not a second table, and the statement file spells no hex literal.
  - `html(...)` and the stylesheet are unchanged apart from field access.
  - The doc comment says the statement page and the preview share one chrome source.
- [ ] `MarkdownPreviewPage` stops emitting `--table-border`.
- [ ] In `preview.css`, the table-cell rule reads `var(--border)`.
  - Add no pin (there is none), and do not add or update anything in `VENDORED.md`.
  - The stylesheet's existing "no colour of its own" invariant still holds.
- [ ] Tests:
  - Delete `testTheTwoBorderColoursAreDistinct`. Its reason was "border and tableBorder are two fields because a table draws a grid of them; if they were ever collapsed to one value the distinction would be gone without anything else changing".
  - Replace it with a test asserting that the theme has exactly one line colour: the table grid and the rule both read `chrome.border`, and the page emits no second line property.
  - The replacing test's doc comment must answer the deleted reason with all four points from the Overview:
    1. The collapse is required by the closed vocabulary, which names one line colour and has no stronger-separator role. A served page may not draw a line stronger than every other swept surface draws.
    2. The measured cost: dark `#4a4a4e` on `#1e1e1e` → `#393b40` on `#2f3136`; light `#c7c7cc` on white → `#d1d1d6` on white.
    3. The rule line is the one place the collapse is felt: a large filled ground may be subtle, a one-pixel line may not.
    4. The remedy if it reads badly is a change to `hairline`, affecting every swept surface. It is never a page-local override and never a twenty-second role.
  - Remove the `tableBorder` lines from the appearance-difference test and the `withCodeColors` test.
  - `withChrome(_:)` replaces every chrome field and leaves `codeColors` identical.
  - `withCodeColors(_:)` leaves `chrome` identical.
  - The preview page emits `--border` and no `--table-border`.
  - A Core test reads `preview.css` and asserts that no `var(--table-border)` remains.
  - Existing statement-document tests stay green. One new test asserts the statement's light/dark theme equals `DocumentPageChrome.light`/`.dark`.
- [ ] Run `swift test`; it must pass before Task 3.

### Task 3: App — the palette's CSS reading and the one derivation

**Files:**
- Modify: `Sources/Pisaka/ChromePalette.swift`, `Sources/Pisaka/MarkdownPreviewPane.swift`, `Sources/Pisaka/LeetCodeDescriptionView.swift`, `Sources/Pisaka/SyntaxTheme.swift` (comment only)
- Modify: `Tests/PisakaAppTests/ChromePaletteTests.swift`, `Tests/PisakaAppTests/SyntaxThemeTests.swift`

- [ ] `ChromePalette`:
  - Add `static func cssHex(_ role: ChromeColorRole, in appearance: ChromeAppearance) -> String`.
    - It returns lowercase `#rrggbb`, or `#rrggbbaa` when the entry's alpha is not `0xFF`.
    - It is the only place a colour is formatted into a string.
  - Add `static func documentPageChrome(in appearance: ChromeAppearance) -> DocumentPageChrome`, built as `DocumentPageChrome(appearance:) { cssHex($0, in: appearance) }`.
  - The exhaustive switch is not touched.
- [ ] Wire the two macOS sites:
  - `MarkdownPreviewPane` composes `SyntaxTheme.shared.markdownPreviewTheme(prefersDark:).withChrome(ChromePalette.documentPageChrome(in:))` with the matching appearance.
  - `LeetCodeDescriptionView` passes `ChromePalette.documentPageChrome(in: ChromeAppearance.resolved(settings.themePreference, systemPrefersDark: colorScheme == .dark))` instead of `LeetCodeStatementDocument.Theme.resolved(...)`.
  - `SyntaxTheme.markdownPreviewTheme(prefersDark:)` stays code-half only and reads no role. Update its comment: the pane replaces the chrome from the palette; Core's block does not survive there.
- [ ] Test 1, the derivation carries the palette in both appearances:
  - For each appearance and each `Field`, the value from `documentPageChrome(in:)` equals the palette entry's integer for `role(for:)`, formatted independently inside the test.
  - Spot-check `cssHex` against known entries, including one translucent role for the 8-digit form.
- [ ] Test 2, a separate test: Core's restated `DocumentPageChrome.light`/`.dark` equal `ChromePalette.documentPageChrome(in: .light/.dark)`. It is separate because the derivation replaces Core's block wholesale, so Test 1 cannot see that block.
- [ ] Update `SyntaxThemeTests`' derived-theme test: drop the `tableBorder` line and compare `chrome`.
- [ ] Run `xcodegen generate`, then the app-layer bundle and `swift test`; both must pass before Task 4.

### Task 4: FilePanels joins the gated set

**Files:**
- Modify: `Sources/Pisaka/FilePanels.swift`
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`

- [ ] Change the line to `reason.textColor = ChromePalette.nsColor(.statusRed)`. This is the dynamic colour, never the resolved `nsColor(_:in:)`.
- [ ] Beside line 148, add a comment stating why `NSFont.smallSystemFontSize` stays:
  - An alert is a platform surface the app does not scale.
  - The accessory deliberately matches the alert's own small system size.
- [ ] Add `"FilePanels.swift"` to `gatedFiles` under a "Part five (e)" comment. The existing set-equality checks then cover it in both directions.
- [ ] Run the full gating suite.
  - If `FilePanels.swift` trips an existing rule, fix it within that rule's intent.
  - If a rule cannot be satisfied without a new role or an exemption, stop and report.
- [ ] Run `swift test`; it must pass before Task 5.

### Task 5: Gating rule forty-two — a served page's chrome is the palette's

**Files:**
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`

- [ ] Add `// MARK: - Rule forty-two: a served page's chrome is the palette's`, with a matching bold bullet in the header inventory, in marker order. The rule has four clauses:
  - (a) The set of app files spelling `ChromePalette.documentPageChrome(` equals exactly `{MarkdownPreviewPane.swift, LeetCodeDescriptionView.swift}`. Deleting the app-side wiring fails here.
  - (b) No macOS app file outside `Sources/Pisaka/iOS/` spells `LeetCodeStatementDocument.Theme.resolved(` or `DocumentPageChrome.resolved(`. macOS never reads Core's fallback.
  - (c) The set of Core files spelling a CSS hex literal (`#[0-9A-Fa-f]{6}`) equals exactly `{MarkdownPreviewTheme.swift, DocumentPageChrome.swift}`, with the counts pinned at 28 and 12. `LeetCodeStatementDocument.swift` spells none.
  - (d) `cssHex(` is defined only in `ChromePalette.swift`.
- [ ] Clause (c) uses the comments-only scanner (`GitHubSourceGatingTests.strippingComments`), because its subject is a string literal. Doc-comment it as the fifth stated exception, in the same terms as the other four.
- [ ] Extend `spelled` with `42: "forty-two"`.
- [ ] Update the docs the count test reads in this same task, or `testBothSummariesSpellTheSuitesOwnRuleCount` fails. Task 6 carries the full prose.
- [ ] Run `swift test` and the app-layer bundle; both must pass before Task 6.

### Task 6: Documentation

**Files:**
- Modify: `docs/architecture/core-theme.md`, `docs/architecture/core-markdown-preview.md`, `docs/architecture/core-leetcode.md`, `CLAUDE.md`, `Sources/Pisaka/LeetCodeDescriptionView.swift` (comment only), `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift` (comment only)

- [ ] `core-theme.md`:
  - A new `DocumentPageChrome.swift` entry covering:
    - the role table;
    - the reasoning for the ground pair, with the no-border condition;
    - the fallback-plus-derivation shape and its two tests.
  - A note on `ChromePalette`'s `cssHex` and `documentPageChrome`.
  - A part five (e) section covering:
    - the three surfaces;
    - the full list of what moved (the header-row inversion included), with the reason: the page is the editor's paper, code recesses to the window ground, and both pages now match the window they sit in;
    - the `tableBorder` collapse, with all four points: the vocabulary requires it; the measured values in both appearances; why the line is the one place it is felt while the code ground is not; and that the remedy is a `hairline` change across every swept surface, never a page-local override or a twenty-second role.
  - Rule forty-two in the canonical list, which now opens "The forty-two rules, each invisible to the compiler:".
  - The gated file count, fifty-eight → fifty-nine.
  - The swept-surface count updated.
  - The unspent roles unchanged: `currentLine` and `bracketMatch`.
- [ ] `core-markdown-preview.md`:
  - `MarkdownPreviewTheme`: `chrome` and `withChrome(_:)`; `tableBorder` is gone.
  - `MarkdownPreviewPage`: no `--table-border`. The stylesheet's table-cell rule reads `--border`. Cite `VENDORED.md`'s existing "no colour of its own" invariant; do not restate it.
  - `MarkdownPreviewPane`: composes the palette's chrome.
- [ ] `core-leetcode.md`:
  - `LeetCodeStatementDocument`: `Theme` is the shared chrome.
  - `LeetCodeDescriptionView`: takes the palette derivation; remove the "served page stays unthemed" remark.
  - iOS reads the restated block and moves with it.
- [ ] `CLAUDE.md`:
  - Add an index line for `DocumentPageChrome.swift` under `core-theme.md`.
  - The chrome invariant sentence: fifty-nine files and forty-two rules, the new rule named briefly, and part five (e) appended to the swept-surface list with the updated count and the same two unspent roles.
  - The Tests section's paragraph on stated exceptions: four → five, naming rule forty-two's clause (c).
  - Add no per-file essays.
- [ ] Update the `gatedFiles` comment for `LeetCodeDescriptionView.swift` to drop "(the served page itself stays unthemed)".
- [ ] Run `swift test`; it must pass. This task's test coverage is the count and inventory checks.

### Task 7: Verify acceptance criteria

- [ ] Run `swift test`.
- [ ] Run `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' test`, with DerivedData outside the repository.
- [ ] Run `swiftlint --strict` from the repository root.
- [ ] Build macOS Release and iOS (`generic/platform=iOS`), both unsigned, as CI does.
- [ ] Grep checks:
  - Core for `#[0-9A-Fa-f]{6}`: only the two restated blocks match.
  - The macOS app layer for `0x[0-9A-Fa-f]{6}`: only `ChromePalette.swift` and the four exemptions match.
  - `.system[A-Z]` colours: nothing matches outside the exemptions and `Sources/Pisaka/iOS/`.
- [ ] Confirm the two safety nets are separate, then revert both mutations:
  - Changing one value in `DocumentPageChrome.light` fails only the restatement test.
  - Replacing the pane's `withChrome(...)` call with the bare theme fails rule forty-two (a).
