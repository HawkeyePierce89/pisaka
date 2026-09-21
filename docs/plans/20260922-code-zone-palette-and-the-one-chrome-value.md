# The code zone's palette, and the one chrome value that disagrees with it

## Overview

Replace the editor's syntax colour table with the project's own palette — fourteen
entries (thirteen token kinds plus plain text), both appearances, written out as
values with no derivation between the two. Stop plain and unmapped text from
resolving to a system semantic colour, so the code zone follows the app's Theme
preference like the chrome around it. Restate the same fourteen entries in the
domain layer's Markdown-preview theme, the copy that exists so the preview has a
complete theme to test and fall back on, and pin the run-time derivation that
carries the editor's table to the page. And change the one chrome value the design
and the palette disagree about: `selectionInactive`, today byte-identical to
`currentLine`.

This is a values change. No table moves layers, no colour is resolved anywhere new,
and the code-zone and chrome tables stay two separate tables — with the equalities
between them stated in both, so a later reader reads agreement rather than
duplication.

## Context

### Files involved

- `Sources/Pisaka/SyntaxTheme.swift` — `SyntaxTheme.table` (13 entries today),
  `color(for:)` whose fallback is `.labelColor` / `.label`, and
  `markdownPreviewTheme(prefersDark:)` (line 221), the derivation that hands the
  editor's palette to the preview page. The bracket, indent, search and diagnostic
  palettes in the same file are out of scope and must not move.
- `Sources/PisakaCore/MarkdownPreviewTheme.swift` — `light` / `dark`, each with a
  14-entry `codeColors` dictionary restating the old palette. The chrome fields
  (`background`, `text`, `secondaryText`, `link`, `codeBackground`, `border`,
  `tableBorder`) are explicitly out of scope.
- `Sources/Pisaka/ChromePalette.swift` — lines 72–73 give `selectionInactive` and
  `currentLine` the identical pair `dark: 0x34363B, light: 0xF0F0F2`. Verified:
  `conflictBackground` is already `dark: 0xC9A35C, light: 0xA67C2E, alpha: 0x26`,
  i.e. exactly the ticket's values, so it is left alone and the plan records that.
- `Sources/Pisaka/CodeEditorView.swift` (~line 3584) and
  `Sources/Pisaka/iOS/CodeEditorCoordinator_iOS.swift` (~line 943) — the
  no-grammar reset path, which writes `textView.textColor ?? .labelColor` /
  `?? .label` over the whole storage.
- `Sources/Pisaka/CodeEditorView.swift` (~line 387) and
  `Sources/Pisaka/iOS/CodeEditorView_iOS.swift` (~line 126) — the two text-view
  configuration blocks. Verified: neither assigns `textColor` today, so runs no
  capture covers keep the system label colour. This is the second half of the
  plain-text requirement, per the answered question in the progress log.

### Verified facts that shape the plan

- The syntax table's values are pinned by **no** test today — only
  `SyntaxTokenKindTests` (capture-name → kind) and the source-gating suites name
  `SyntaxTheme`. A value-level pin has to be written, in the app-layer bundle,
  because `SyntaxTheme` is view-layer and `swift test` cannot see it.
- `markdownPreviewTheme(prefersDark:)` is `internal`, inside `#if os(macOS)`, so
  `@testable import Pisaka` reaches it; `cssColorString(for:)` formats
  `#%02x%02x%02x`, i.e. lowercase `#rrggbb` — the same spelling the ticket's table
  uses, so the seam pin compares strings with no normalization.
- The derivation is pinned by **nothing** today. Until this ticket, Core's restated
  `codeColors` differed from the editor's table, so a broken derivation showed up
  on screen as old-versus-new colours. Task 3 removes that accident, which is why
  Task 3 also adds the pin. Stated honestly: the pin catches a wrong, partial or
  wrongly-appearance-resolved derivation, and — the case that matters over time —
  any future palette edit made on one side only, which is exactly when a stopped
  derivation would become visible again. It cannot, by construction, catch the
  derivation being deleted while the two tables happen to agree; nothing that reads
  values can, and the plan says so rather than implying a stronger guarantee.
- `MarkdownPreviewThemeTests` pins the preview theme's code colours *structurally* —
  totality over `SyntaxTokenKind.allCases`, and light ≠ dark for every kind. Both
  survive the new values (checked row by row) and must keep passing unloosened.
- `MarkdownPreviewPageTests` reads the emitted CSS custom properties back out of
  `MarkdownPreviewTheme.light`, so it follows the new values with no edit.
- `ChromePaletteTests` restates the whole chrome table literally, including the row
  being changed. There is no pairwise-distinctness rule in it yet, so the new wash
  rule is a clean addition rather than an exemption to unwind.
- `SyntaxTheme.swift` is one of the three files `ChromeThemeSourceGatingTests`
  exempts from the chrome rules (it is the code zone's own theme). Dropping
  `.labelColor` from it is therefore an improvement the gating suite does not
  require and does not forbid; adding `.dynamic(...)` entries is likewise fine.
- `SyntaxTokenKind` is a closed `CaseIterable` enum, and the table becomes total
  over it. There is therefore no unmapped kind to call `color(for:)` with: the
  fallback constant has to be asserted directly, which is why it is declared
  `internal` rather than `private`, and the totality assertion beside it is what
  states the fallback is unreachable in the product.
- Three value pairs in the new palette are numerically equal to chrome roles: body
  text `#dfe1e5`/`#1d1d1f` = `textPrimary` (used by `variable`, `parameter`,
  `plain`), secondary text `#a0a3aa`/`#6e6e73` = `textSecondary` (`operator`,
  `punctuation`), and — a third the ticket's prose does not enumerate but which the
  values state — `#4f8dff`/`#2f6fe0` = `accent` (`label`). The plan states each
  equality that actually holds, rather than a count.

### Related patterns

- `ChromePaletteTests`' "the duplication *is* the test": the table restated in the
  suite and compared component by component, resolved under both `NSAppearance`s
  through `performAsCurrentDrawingAppearance`. The new syntax-theme suite follows
  it, helper for helper — and the restated table is what makes the seam pin a real
  assertion rather than a tautology against the production table.
- `PlatformColor.dynamic(light:dark:alpha:)` is the one construction used by every
  colour in `SyntaxTheme`; nothing new is introduced.

## Development Approach

- **Testing approach**: Regular (values first, then the pins that hold them), except
  Task 4 where the two new rule-shaped assertions are written before the values
  they constrain.
- Complete each task fully before moving to the next.
- **CRITICAL: every task MUST include new/updated tests.**
- **CRITICAL: all tests must pass before starting the next task.**
- `swift test` covers Task 3's Core half; the app-layer bundle (`xcodegen generate`
  then `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination
  'platform=macOS' test`) covers Tasks 1, 2, 3's seam pin and 4. A new file in
  `Tests/PisakaAppTests/` needs `xcodegen generate` before the bundle sees it.
- No brand or product names in any code, comment, document, plan text or commit
  message.
- Every value in this plan is transcribed from the ticket; no external source is
  consulted for a colour or a name.

## Implementation Steps

### Task 1: The editor's colour table

**Files:**
- Modify: `Sources/Pisaka/SyntaxTheme.swift`
- Create: `Tests/PisakaAppTests/SyntaxThemeTests.swift`

- [x] Replace every row of `SyntaxTheme.table` with the ticket's values, and add
      the fourteenth row for `.plain`. Each row stays a literal
      `.dynamic(light: 0x…, dark: 0x…)` pair — fourteen rows, no row expressed in
      terms of another, no shared constant for a repeated value:
      `.keyword` light `0x8250B0` dark `0xB48EAD`;
      `.string` light `0x4F7942` dark `0x9DB97B`;
      `.comment` light `0x8A8A90` dark `0x6B6E76`;
      `.number` light `0xA5652D` dark `0xC9976C`;
      `.type` light `0x2B6A83` dark `0x6A9FB5`;
      `.function` light `0x2F5FA8` dark `0x7AA6DA`;
      `.variable` light `0x1D1D1F` dark `0xDFE1E5`;
      `.constant` light `0xA5652D` dark `0xC9976C`;
      `.operator` light `0x6E6E73` dark `0xA0A3AA`;
      `.punctuation` light `0x6E6E73` dark `0xA0A3AA`;
      `.property` light `0x2F6B63` dark `0x7FA8A0`;
      `.parameter` light `0x1D1D1F` dark `0xDFE1E5`;
      `.label` light `0x2F6FE0` dark `0x4F8DFF`;
      `.plain` light `0x1D1D1F` dark `0xDFE1E5`.
- [x] Rewrite the table's doc comment. It must say (a) that the palette is the
      project's own, muted and low-contrast, chosen against the surfaces around the
      code rather than after any platform convention — replacing the current
      sentence about following the platform's conventional presentation; (b) why
      each repetition is deliberate, one clause per repetition (a constant reads as
      the literal it is; operators and punctuation are the same class of mark; a
      parameter is an ordinary identifier; variable, parameter and plain all sit at
      the body-text weight because colouring an ordinary identifier competes with
      the hues that carry meaning); (c) that the fourteen rows are fourteen answers
      to fourteen questions and must not be collapsed into shared constants,
      because a future divergence would then be an edit in two places.
- [x] Add, in the same doc comment, the two-layers sentence: three of these value
      pairs are numerically equal to chrome roles — the body-text weight
      (`textPrimary`), the secondary-text weight (`textSecondary`) and the accent
      (`label`) — and that equality is **two layers agreeing about a weight, not
      duplication to be factored out**. State that the code zone owns its own
      theme, reads no chrome role, and that the chrome palette carries no syntax
      entry; unifying the two tables is explicitly not wanted.
- [x] Replace `color(for:)`'s `.labelColor` / `.label` fallback with an **internal**
      (not `private`) static `plainText` dynamic colour (light `0x1D1D1F`, dark
      `0xDFE1E5`). Its doc comment says it answers the *same* question `.plain`
      does — "text that carries no meaning" — which is why this one value is
      spelled twice rather than fourteen times; that a system semantic colour is
      forbidden here for the reason it is forbidden in the chrome (it follows the
      *system* appearance and would ignore the app's own Theme preference); and
      that it is `internal` because the suite has to assert it directly — the enum
      is closed and the table total, so no call to `color(for:)` can reach it.
      Remove the now-dead `#if os(macOS)` / `#else` branch in that method.
- [x] Update `color(for:)`'s own doc comment: `.plain` now has a real entry, and the
      fallback is unreachable while the table is total.
- [x] Create `Tests/PisakaAppTests/SyntaxThemeTests.swift` (macOS-gated,
      `@testable import Pisaka`), modelled on `ChromePaletteTests`: restate all
      fourteen rows as an `[SyntaxTokenKind: (dark: UInt32, light: UInt32)]` table;
      assert the restated set equals `SyntaxTokenKind.allCases`; assert each kind's
      colour resolves component-for-component to its row under `.darkAqua` and
      `.aqua`, using the same `performAsCurrentDrawingAppearance` +
      `usingColorSpace(.sRGB)` helpers; assert every entry is fully opaque.
- [x] In the same suite, add the first new rule-shaped test: **no token kind
      resolves to a system semantic colour in either appearance.** Resolve each kind
      under each appearance and assert it differs from `NSColor.labelColor`,
      `.secondaryLabelColor`, `.tertiaryLabelColor` and `.textColor` resolved under
      that same appearance. The doc comment must name the defect the rule exists
      for — a system colour follows the system appearance and so ignores the app's
      Theme preference — and say that the rule is about the property, not about
      today's numbers, so it survives a later palette change.
- [x] Add a test that `SyntaxTheme.plainText` itself resolves to the `.plain` row in
      both appearances, and assert beside it — in the same test, so the two
      sentences are read together — that `SyntaxTheme.table` is total over
      `SyntaxTokenKind.allCases`, which is what makes the fallback unreachable in
      the product. The doc comment must say exactly that: the constant is asserted
      directly because no call can reach it, and the totality assertion is the
      statement of why.
- [x] Run `xcodegen generate`, then the app-layer bundle — must pass before Task 2.

### Task 2: Every character in a file follows the table

**Files:**
- Modify: `Sources/Pisaka/CodeEditorView.swift`
- Modify: `Sources/Pisaka/iOS/CodeEditorView_iOS.swift`
- Modify: `Sources/Pisaka/iOS/CodeEditorCoordinator_iOS.swift`
- Modify: `Tests/PisakaAppTests/SyntaxThemeTests.swift`

- [x] In the macOS text-view configuration block, set the base foreground from
      `SyntaxTheme.shared.color(for: .plain)` beside the existing font assignment.
      Comment it as what it is: the colour of a character no capture covers, which
      is the same question `.plain` answers, so it is read from the theme rather
      than left on the text view's system-label default.
- [x] Do the same in the iOS text-view configuration block.
- [x] In the macOS no-grammar reset path, replace `textView.textColor ??
      .labelColor` with `SyntaxTheme.shared.color(for: .plain)`; in the iOS
      coordinator's equivalent, replace `textView.textColor ?? .label` the same
      way. No new resolution point is introduced — both read the one table.
- [x] Extend the doc comment of each reset path to say the restored colour is the
      theme's plain entry, not the platform's label colour.
- [x] Add an app-layer test that the value the macOS editor uses for uncovered
      text — `SyntaxTheme.shared.color(for: .plain)` — is the table's `.plain` row
      in both appearances, so the two sites cannot drift back onto a system colour
      without the suite noticing.
- [x] Run the app-layer bundle **and** an iOS build (`xcodebuild -project
      Pisaka.xcodeproj -scheme Pisaka -destination 'generic/platform=iOS' build`) —
      both must pass before Task 3.

### Task 3: The domain layer's preview theme, and the seam that carries the editor's

**Files:**
- Modify: `Sources/PisakaCore/MarkdownPreviewTheme.swift`
- Modify: `Tests/PisakaCoreTests/MarkdownPreviewThemeTests.swift`
- Modify: `Tests/PisakaAppTests/SyntaxThemeTests.swift`

- [x] Replace `light.codeColors` with the fourteen light values as lowercase
      `#rrggbb` strings: keyword `#8250b0`, string `#4f7942`, comment `#8a8a90`,
      number `#a5652d`, type `#2b6a83`, function `#2f5fa8`, variable `#1d1d1f`,
      constant `#a5652d`, operator `#6e6e73`, punctuation `#6e6e73`, property
      `#2f6b63`, parameter `#1d1d1f`, label `#2f6fe0`, plain `#1d1d1f`.
- [x] Replace `dark.codeColors` with the fourteen dark values: keyword `#b48ead`,
      string `#9db97b`, comment `#6b6e76`, number `#c9976c`, type `#6a9fb5`,
      function `#7aa6da`, variable `#dfe1e5`, constant `#c9976c`, operator
      `#a0a3aa`, punctuation `#a0a3aa`, property `#7fa8a0`, parameter `#dfe1e5`,
      label `#4f8dff`, plain `#dfe1e5`.
- [x] Leave every chrome field of both themes untouched, and say so in the doc
      comment beside each `codeColors` block: these are the editor palette's
      variants, restated only so the domain layer has a complete theme to test and
      fall back on; the app overwrites them from the editor's table at run time
      through `withCodeColors(_:)`, which is the mechanism that must keep working
      and must not be reimplemented.
- [x] Add a Core test asserting that the two `codeColors` tables are non-empty,
      total over `SyntaxTokenKind.allCases`, and that every value matches `#`
      followed by six lowercase hex digits — so a restatement can never drift into
      a shape the page cannot emit. Keep `testBothThemesAreTotalOverTokenKinds` and
      `testLightAndDarkDifferInEveryColourField` exactly as they are; neither may be
      loosened.
- [x] Add, in `SyntaxThemeTests`, the seam pin the two equal tables now need: for
      each of `prefersDark: true` and `false`, assert that
      `SyntaxTheme.shared.markdownPreviewTheme(prefersDark:)` carries, for **every**
      `SyntaxTokenKind`, a `codeColors` entry equal to the CSS string of that kind's
      row in the suite's own restated table — read as `codeColors[kind]` through
      `XCTUnwrap`, not through `color(for:)`, so a missing entry fails instead of
      falling through to the theme's body-text colour. Build the expected string by
      formatting the restated row (`#%02x%02x%02x`, lowercase), so the assertion is
      against the ticket's values rather than against `SyntaxTheme.table`.
- [x] Give that test a doc comment stating what it pins and what it does not: it is
      the only check that the editor's palette actually reaches the page — a wrong,
      partial or wrongly-appearance-resolved derivation fails here, and so does any
      later palette edit made on one side only, which is precisely the situation in
      which a stopped derivation would otherwise become visible on screen. It cannot
      catch the derivation being deleted while both tables happen to agree; before
      this ticket the two tables disagreed and the screen was that check, and this
      is the assertion that replaces it.
- [x] Also assert in that test that the derived theme's chrome fields still equal the
      base theme's for that appearance — the derivation overwrites code colours and
      nothing else — so a future edit cannot quietly widen it into the shared
      document chrome this ticket puts out of scope.
- [x] Run `swift test` **and** the app-layer bundle — both must pass before Task 4.

### Task 4: The one chrome value

**Files:**
- Modify: `Tests/PisakaAppTests/ChromePaletteTests.swift`
- Modify: `Sources/Pisaka/ChromePalette.swift`

- [ ] Write the second new rule-shaped test first, in `ChromePaletteTests`: **the
      inactive-selection wash is not equal to the current-line wash**, asserted in
      both appearances through `ChromeTheme` and through the concrete AppKit
      colours. Its doc comment must state the rule rather than the numbers — an
      unfocused selection and the line the caret is on are two different facts, and
      a reader who cannot tell them apart has lost one of them — so it survives a
      later palette change. Confirm it fails against today's values.
- [ ] Change `ChromePalette`'s `selectionInactive` row to
      `Entry(dark: 0x3C3F46, light: 0xE2E2E7)`, leaving `currentLine` at
      `dark: 0x34363B, light: 0xF0F0F2`. Add a comment on the row recording this as
      a **change**: the wash was previously identical to the current-line highlight
      and is now a deliberate step stronger, so the two states read apart.
- [ ] Update the restated row in `ChromePaletteTests.expected` to
      `.selectionInactive: (0x3C3F46, 0xE2E2E7, 0xFF)`.
- [ ] Leave `conflictBackground` unchanged: it already carries
      `dark: 0xC9A35C, light: 0xA67C2E, alpha: 0x26`, which is exactly the ticket's
      value — verified at `Sources/Pisaka/ChromePalette.swift:84` and in the suite's
      restated row. Record that check as done in the commit message.
- [ ] Add a short comment on `ChromePalette`'s `textPrimary`, `textSecondary` and
      `accent` rows noting that the code zone's own theme states the same values for
      its body-text weight, its secondary weight and its label colour, and that this
      is two layers agreeing — the chrome palette must not gain a syntax entry, and
      the syntax table must not start reading a role. The sentence in
      `SyntaxTheme.swift` is its counterpart; a reader arriving from either side
      finds it.
- [ ] Run the app-layer bundle — must pass before Task 5.

### Task 5: Update the design documents

**Files:**
- Modify: `docs/architecture/app-editor-overlays.md`
- Modify: `docs/architecture/core-theme.md`
- Modify: `docs/architecture/core-markdown-preview.md`
- Modify: `docs/architecture/app-editor.md`
- Modify: `docs/architecture/app-ios.md`

- [ ] `app-editor-overlays.md`, the `SyntaxTheme.swift` entry: replace the
      "following the system appearance / falling back to `.labelColor` for
      `.plain`/unmapped kinds" statement — it becomes false. Record the palette's
      intent, the fourteenth entry, the repetitions and why none may be collapsed,
      the plain-text fallback that is now a value of its own (and why it is
      `internal`), and the three numeric equalities with chrome roles as agreement
      rather than duplication. Note the new `SyntaxThemeTests` and the three rules
      it pins — no system semantic colour, the fallback's value with the totality
      that makes it unreachable, and the preview seam.
- [ ] `core-theme.md`, the `ChromePalette.swift` entry: record `selectionInactive`
      as changed — what it was, what it is, and that the change exists because it
      was indistinguishable from `currentLine`. Record the new
      inactive-selection-vs-current-line test and note that `conflictBackground` was
      checked and already correct. Do not disturb the gating suite's rule count or
      the sentence in `CLAUDE.md` that mirrors it — no chrome gating rule is added.
- [ ] `core-markdown-preview.md`, the `MarkdownPreviewTheme.swift` entry: record
      that the restated code tables now carry the editor's new palette, that the
      run-time derivation through `withCodeColors(_:)` is unchanged and is still the
      copy that reaches the page, and — the fact this ticket creates — that the two
      copies now agree, so the screen no longer reports a broken derivation and
      `SyntaxThemeTests`' seam pin is what reports it instead. State plainly what
      that pin can and cannot see. Record that the preview's chrome is deliberately
      untouched because it is shared with the other document surface in the window.
- [ ] `app-editor.md` (`CodeEditorView.swift`) and `app-ios.md`
      (`CodeEditorView_iOS.swift` / `CodeEditorCoordinator_iOS.swift`): record that
      the text view's base foreground now comes from the theme's plain entry, so a
      character no capture covers follows the app's Theme preference rather than the
      system appearance.
- [ ] Confirm `CLAUDE.md` needs no edit: no file changes layer, no invariant
      changes, no new index line. State that conclusion explicitly rather than
      leaving it implicit.

### Task 6: Verify acceptance criteria

- [ ] `swift test` — the whole domain suite green.
- [ ] `xcodegen generate` then `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka
      -destination 'platform=macOS' test` — the app-layer bundle green, including
      both new suites and all three new rules.
- [ ] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination
      'generic/platform=iOS' build` — the iOS editor change compiles.
- [ ] `swiftlint --strict` from the repository root — clean.
- [ ] Re-read the acceptance list against the diff and confirm each item, naming the
      file or test that satisfies it: no token kind left on the old scheme; plain
      and unmapped text off any system colour; the preview's derivation intact and
      now pinned; the domain theme stating the palette on its own; the two washes
      distinct; no chrome role read by the code zone and no syntax entry in the
      chrome palette.

## Post-Completion (manual, by the reviewer)

- Open a source file in each appearance and confirm the palette reads as one design
  with the chrome around it.
- Set the Theme preference to disagree with the system appearance and confirm plain
  text and an unhighlighted file follow the preference.
- Open a Markdown file with a fenced code block beside its preview and confirm the
  same code is coloured the same on both sides.
- Click away from the editor and confirm an unfocused selection is distinguishable
  from the current-line highlight, in both appearances.
