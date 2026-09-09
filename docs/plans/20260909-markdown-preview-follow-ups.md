# Markdown preview follow-ups: heading anchors, the ⌘⇧P collision, in-place font-size updates

## Overview

Three self-contained debts recorded when the Markdown preview landed (PR #64) are
closed: the renderer emits no heading `id`, so an intra-document `#fragment` lands
nowhere; ⌘⇧P is bound to both View → *Markdown Preview* and LeetCode →
*Open Problem…*; and every code-zoom step reloads the whole shell. None of the
three touches the feature's shape, its reader rule, the CSP, the app-scheme
vocabulary, the handler or the parser. All decisions stay in Core; `preview.js`
gains exactly one setter and decides nothing.

## Context

- Files involved:
  - `Sources/PisakaCore/MarkdownRenderer.swift` — headings gain an `id`; the slug
    rule is threaded through the block walk.
  - `Sources/PisakaCore/MarkdownHeadingSlug.swift` (new) — the pure GFM slug rule
    plus the per-document duplicate allocator.
  - `Sources/PisakaCore/MarkdownPreviewPage.swift` — the third entry point's
    source, and the two size values factored so the shell and the setter cannot
    disagree.
  - `Sources/PisakaCore/MarkdownPreviewModel.swift` — the appearance comparison
    split into theme and font size.
  - `Sources/PisakaCore/MarkdownPreviewAsset.swift` — one doc comment that states
    "the renderer emits no `id`" as a reason.
  - `Resources/MarkdownPreview/preview.js` — `setFontSize`, and the
    `scrollToAnchor` comment that says no `id` exists.
  - `Sources/Pisaka/LeetCodeOpenProblemSheet.swift` — *Open Problem…* moves to
    ⌘⌥P; the collision comment goes.
  - Tests: `MarkdownRendererTests`, `MarkdownLinkRuleTests`,
    `MarkdownPreviewPageTests`, `MarkdownPreviewModelTests`,
    `MarkdownPreviewSourceGatingTests`, `MarkdownPreviewAssetPinTests`,
    `Tests/PisakaCoreTests/Support/ScriptedMarkdownSeams.swift`.
  - Docs: `docs/architecture/core-markdown-preview.md`,
    `docs/architecture/app-shell.md`, `docs/architecture/core-leetcode.md`,
    `docs/FEATURES.md`, `README.md`, `CLAUDE.md`.
- Related patterns: the renderer's "one escape, applied once";
  `MarkdownPreviewPage`'s "the argument crosses as a value the page cannot end the
  call with"; the model's generation token and its early returns on unchanged
  facts; the gating suites' comment-and-literal-stripped matching;
  `ScriptedMarkdownPageSink` decoding a call's argument rather than matching
  source text.
- Dependencies: none. No new package, no new resource file, no CSP or scheme
  change.

## Notes carried from the ticket

- The ticket says ⌘⌥F is the app's only ⌘⌥ chord. It is not — code folding uses
  ⌘⌥← / ⌘⌥→ and ⌘⌥⇧← / ⌘⌥⇧→ — but **⌘⌥P itself is free**, so the decision stands
  unchanged; only the sentence written into the docs is corrected.
- The ticket asks for the new entry point's "argument" as one number. The shell
  writes **two** size properties and derives `--code-font-size` as one point below
  the body size; putting that subtraction into `preview.js` would make the page
  decide something. So the source composes **two numeric arguments** (body size,
  code size), both produced by the one Core helper the shell's `:root` block also
  uses — the page appends `px` and sets the two properties, nothing else. This is
  the plan's one deliberate departure from the ticket's literal wording; the
  safety property it was written for (a number cannot end the call and start a
  statement) is preserved for both.

## Development Approach

- **Testing approach**: Regular (code first, then tests), except the slug rule and
  the link-rule round trip, which are cheap to state first and are written as
  tests alongside the function.
- Complete each task fully before moving to the next; `swift test` must be green
  at the end of every task.
- **CRITICAL: every task MUST include new/updated tests.**
- **CRITICAL: all tests must pass before starting the next task.**
- Local builds use a derived-data path outside the repository
  (`~/Library/Developer/Xcode/DerivedData/pisaka-mdfollowups`).

## Implementation Steps

### Task 1: Heading anchors

**Files:**
- Create: `Sources/PisakaCore/MarkdownHeadingSlug.swift`
- Modify: `Sources/PisakaCore/MarkdownRenderer.swift`,
  `Sources/PisakaCore/MarkdownPreviewAsset.swift` (one doc comment),
  `Resources/MarkdownPreview/preview.js` (the `scrollToAnchor` comment),
  `Sources/PisakaCore/MarkdownPreviewPage.swift` (the `scrollToAnchorSource` doc
  comment)
- Modify tests: `Tests/PisakaCoreTests/MarkdownRendererTests.swift`,
  `Tests/PisakaCoreTests/MarkdownLinkRuleTests.swift`,
  `Tests/PisakaCoreTests/MarkdownPreviewSourceGatingTests.swift` (the Core file
  list)
- Create tests: `Tests/PisakaCoreTests/MarkdownHeadingSlugTests.swift`

- [x] Write `MarkdownHeadingSlug` in Core: one pure `slug(forText:)` — lowercased,
      every character that is not a letter, a digit, a space or a hyphen removed
      (a tab is removed, not folded to a hyphen; state that), spaces turned into
      hyphens, an empty result answering `nil` — plus a small `mutating` allocator
      value that suffixes `-1`, `-2`, … per repeat of a slug in document order.
      Document why the rule lives beside the renderer and why the allocator is a
      value threaded through the walk rather than static state.
- [x] Thread the allocator through `MarkdownRenderer.body(for:context:)` and every
      nested path (`renderNested`, `renderItems`, table rows) as `inout`, so a
      heading inside a blockquote or a list item gets an `id` on the same terms as
      a top-level one, and document order is the allocation order.
      `plainText(_:)` — the flattening `alt` already uses — is the heading's text;
      nothing else in the tree gains an `id`.
- [x] Emit the attribute through the existing `attribute(_:_:)` escape (nothing
      bypasses the one escape), with a heading whose text is empty carrying no
      `id` at all.
- [x] Update the three comments that state "the renderer emits no `id`" as a
      reason: `MarkdownPreviewAsset.fileURL(forTarget:documentURL:)` (a
      *cross-file* fragment is still dropped, and now for its own reason — the
      link opens that file in the editor),
      `MarkdownPreviewPage.scrollToAnchorSource(anchor:)`, and `preview.js`'s
      `scrollToAnchor` comment. `preview.js` gains no code in this task.
- [x] Tests for the rule itself: lowercasing, punctuation removal, spaces, a
      heading with inline markup, a heading that is only punctuation or only
      whitespace (no id, stated), duplicates in document order (`x`, `x-1`,
      `x-2`), and that a slug that already ends in `-1` does not collide silently.
- [x] Tests for the renderer: headings at every level carry their id; the two
      existing assertions (`<h6>t</h6>`, the `data-line` case) updated to the new
      markup; a heading nested in a blockquote and one in a list item carry ids; a
      heading whose children are an image alone slugs its alt text.
- [x] The round trip, end to end in `swift test`: render a document whose body has
      a heading and a link `[x](#…)` to it, read the `href` the renderer emitted,
      resolve it against `MarkdownPreviewPage.shellURL` the way the web view does,
      feed the result to `MarkdownLinkRule.decision(for:context:)`, and assert
      `.anchor(f)` where `f` equals the `id` the same render put on that heading —
      for the plain case, the punctuation case and the duplicate case (the second
      link reaching the second heading).
- [x] Add `MarkdownHeadingSlug.swift` to
      `MarkdownPreviewSourceGatingTests.coreFileNames` so the suite's file-set
      rule covers it.
- [x] Run `swift test` — must be green before Task 2.

### Task 2: The ⌘⇧P collision

**Files:**
- Modify: `Sources/Pisaka/LeetCodeOpenProblemSheet.swift`

- [ ] Move LeetCode → *Open Problem…* to
      `.keyboardShortcut("p", modifiers: [.command, .option])` and rewrite the
      comment above it: ⌘⌥P is free, ⌘⇧P now names one command, and the reason the
      two were ever shared is not restated as a live condition.
- [ ] Confirm no other site spells the LeetCode chord in code (`Sources/` grep for
      `keyboardShortcut("p"`), and that ⌘⌥P collides with nothing — the app's
      other ⌘⌥ chords are ⌘⌥F and the four folding arrow chords.
- [ ] Tests: this is a SwiftUI menu declaration, which is untested by convention,
      so the gate here is the documentation task and a build. Run `swift test`
      (unchanged, must stay green); the two chords themselves are exercised by
      hand in the Post-Completion checks.

### Task 3: Font size changes in place

**Files:**
- Modify: `Sources/PisakaCore/MarkdownPreviewPage.swift`,
  `Sources/PisakaCore/MarkdownPreviewModel.swift`,
  `Resources/MarkdownPreview/preview.js`
- Modify tests: `Tests/PisakaCoreTests/MarkdownPreviewPageTests.swift`,
  `Tests/PisakaCoreTests/MarkdownPreviewModelTests.swift`,
  `Tests/PisakaCoreTests/Support/ScriptedMarkdownSeams.swift`,
  `Tests/PisakaCoreTests/MarkdownPreviewAssetPinTests.swift`,
  `Tests/PisakaCoreTests/MarkdownPreviewSourceGatingTests.swift`

- [ ] Factor the shell's two size values out of
      `customProperties(theme:fontSize:)` into one Core helper (the clamp plus the
      one-point code offset), and have both the `:root` block and the new source
      read it — so a reloaded shell and an in-place step can never disagree about
      what a size is.
- [ ] Add `MarkdownPreviewPage.fontSizeUpdateSource(fontSize:)` composing
      `window.PisakaPreview.setFontSize(<body>, <code>);` — both interpolated as
      numbers, neither escaped as a string, documented as the third and last entry
      point.
- [ ] Add `setFontSize` to `preview.js`: set `--font-size` and `--code-font-size`
      on `document.documentElement`, appending the unit and nothing else, and
      expose it on the namespace object beside the other three. Its comment states
      that the values are Core's and that the page performs no arithmetic on them.
- [ ] Split `MarkdownPreviewModel.updateAppearance(theme:fontSize:)` in two:
      unchanged appearance sends nothing; no shell installed yet, or a theme
      change (with or without a size change), takes today's reload path **byte for
      byte** — `lastBody = nil`, the pending-line restore, `reloadShell`,
      `publishBody()`; a font-size-only change records the new appearance and
      sends the one evaluated source, touching neither `lastBody`, the pending
      line, the tree nor the parser. Document why the in-place path needs no
      scroll restore (the document is not replaced) and why the shell still embeds
      the size it was composed with.
- [ ] Extend `ScriptedMarkdownPageSink` with a `setFontSize` accessor decoding
      both numeric arguments in order, alongside
      `bodies`/`scrolledLines`/`scrolledAnchors`.
- [ ] Page tests: the source's exact shape, both arguments numeric (no quotes,
      decodable as numbers), the clamp applied, the code size one point below the
      body size, and the same values as the shell composed for the same input.
- [ ] Model tests with the scripted seams: a font-size-only change records exactly
      one evaluated source, no shell reload and no parse; a theme-only change
      still reloads, re-renders from the last tree and does not parse; a change of
      both records exactly one reload and no `setFontSize`; an unchanged
      appearance records nothing; and a font-size step after a scroll leaves the
      scroll memory alone (no `scrollToLine` is re-sent).
- [ ] Update `MarkdownPreviewAssetPinTests`: the reached-member set becomes the
      five Core actually calls, with `fontSizeUpdateSource` added to the sources
      the set is read out of, so the script must define and expose `setFontSize`.
- [ ] Extend
      `MarkdownPreviewSourceGatingTests.testThePageIsServedAndUpdatedInPlace()`:
      the new entry point is an `evaluate`, not a load — pin that Core's
      `reloadShell` call sites stay the two that exist (the appearance reload and
      the page-death recovery), so a size step cannot grow a third one, and that
      the app layer still composes none of the three sources.
- [ ] Run `swift test` — must be green before Task 4.

### Task 4: Verify the acceptance criteria

- [ ] `swift test` green.
- [ ] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination
      'platform=macOS' test` green (`PisakaAppTests`), with `-derivedDataPath
      ~/Library/Developer/Xcode/DerivedData/pisaka-mdfollowups`.
- [ ] `swiftlint --strict` clean from the repository root.
- [ ] macOS and iOS builds green, same derived-data path outside the repository.

### Task 5: Update documentation

**Files:**
- Modify: `docs/architecture/core-markdown-preview.md`,
  `docs/architecture/app-shell.md`, `docs/architecture/core-leetcode.md`,
  `docs/FEATURES.md`, `README.md`, `CLAUDE.md`

- [ ] `core-markdown-preview.md`: add the slug rule to the decision list (its own
      decision, stating the flattening, the character classes, the duplicate
      suffix and the empty-heading answer, and that the renderer is its only
      caller); extend M7 so the reload rule names its two halves — a theme change
      reloads and re-renders from the last tree, a size change is one call into
      the document already loaded; drop the collision paragraph from M8; add the
      file entry for `MarkdownHeadingSlug.swift` and update the
      `MarkdownRenderer.swift`, `MarkdownPreviewPage.swift` and
      `MarkdownPreviewModel.swift` entries; remove "no heading anchors" from
      Stated limits; delete the "What is still owed" section (its ⌘⇧P entry
      removed rather than struck through, the settled app-bundle note going with
      it), leaving no empty heading behind.
- [ ] `docs/FEATURES.md`: the preview bullet drops the shared-chord sentence; the
      Known-limitations entry drops "no heading anchors — so an intra-document
      `#section` link lands nowhere" and the shared-chord sentence, and gains
      nothing else; the LeetCode *Open Problem…* row becomes Cmd+Option+P with no
      cross-reference to the preview.
- [ ] `README.md`: the preview bullet keeps Cmd+Shift+P; the shortcut table's
      Cmd+Shift+P row names the preview alone and a Cmd+Option+P row names *Open a
      LeetCode problem*, placed with the other Cmd+Option rows.
- [ ] `docs/architecture/app-shell.md`: the View-menu paragraph drops the
      shared-chord sentence, and the LeetCode menu inventory names ⌘⌥P.
- [ ] `docs/architecture/core-leetcode.md`: update the chord wherever the LeetCode
      menu's *Open Problem…* is named (the two ⌘⇧P mentions there are about a *tab
      switch*, not the menu item — leave those, and re-read them before editing).
- [ ] `CLAUDE.md`: the Markdown-preview invariant paragraph names the reload rule
      ("only a theme or code-font change reloads the shell") — correct it to the
      two halves, in one sentence, without growing the paragraph.
- [ ] Re-run `swift test` (`LintConfigurationTests` and the doc-reading suites)
      and `swiftlint --strict`.

## Post-Completion Checks (manual)

- In a Markdown document, `[x](#a-heading)` scrolls the preview to that heading;
  two identical headings get distinct ids and the second link reaches the second
  heading.
- ⌘⇧P toggles the preview on a Markdown tab and does nothing else; ⌘⌥P opens the
  LeetCode *Open Problem…* sheet on any tab, including a Markdown one.
- Stepping the code zoom with the pointer over the preview changes the text and
  code size with no visible reload, no lost scroll position and no diagram
  re-render; switching the theme still reloads and lands back on the same line.
