# The language-server consent banner is drawn as the design's Banner card

## Overview

`LSPConsentBanner` (D15) is the last chrome surface still in its pre-design layout. Today it is a full-width `bgPanel` strip with a bottom `hairline` rule, a callout question over a caption paragraph, and two buttons. It also has a wrapping defect: the text column has no layout priority, so it shares the free width with the `Spacer` and wraps at about half the width it could use.

This work redraws the three questions as the design's Banner card. The three are the pinned download (TypeScript/JavaScript, Python, YAML), the Go build and the Rust download. The card sits in an inset band on the editor's ground. It has one short primary line of copy, plus a secondary line only where a fact requires one, and the text column takes the full width. A bitmap test in the app-layer bundle pins what the card draws.

Behaviour does not change. These all stay exactly as they are:

- when the banner appears;
- the two answers and what each records;
- the silent `.task` install of an already accepted server;
- the project-root gating;
- the absence of any dismiss or keyboard shortcut.

The design's Banner values are restated here as literals. The design file is not opened during this work.

- **Card:** filled with the panel ground and drawn with a 1-point hairline border. Corner radius 6, padding 14 vertical and 18 horizontal. Items sit in a horizontal row, vertically centred, with the action pushed to the trailing edge. The gap between icon, message and action is 16.
- **Message:** a 16-point accent icon and 13-point primary text, 10 apart.
- **Action:** the design draws its own 28-point accent button with a 12-point semibold label. The app keeps its shared `.chromePrimary` / `.chromeSecondary` styles instead. That difference is known and accepted.

## Context

- Files involved:
  - `Sources/Pisaka/LSPConsentBanner.swift`: the view, its three row builders, the `strip(_:)` helper and the static `size(_:)`. `LSPServerSettingsView.swift` also calls `size(_:)`, so it stays where it is with the same signature.
  - `Sources/Pisaka/ContentView.swift`: the hosting site in `textEditorZone`, between the breadcrumb and the find bar. Its comment changes only if it stops being truthful.
  - `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`:
    - rule thirty's caller sets, which name the file under both `chromePrimary` and `chromeSecondary`;
    - rule thirty-four's `glyphSizeExemptions`, which holds three `.containerFont` entries for `downloadRow(` / `goRow(` / `rustRow(` under the comment "the consent strip's three rows,";
    - the gated-file set near line 301.
  - `Tests/PisakaAppTests/HostedRender.swift`: the shared bitmap harness. It offers `matches(_:atX:y:)`, `extent(of:atX:)` and `color(atX:y:)`, and compares colours through role swatches.
  - New: `Tests/PisakaAppTests/LSPConsentCardLayoutTests.swift`.
  - Docs:
    - `docs/architecture/core-theme.md`: the consent-strip entry near line 614, and rule thirty-four's prose that lists files whose glyphs take their own scaled font;
    - `docs/architecture/core-provisioning.md`: the `LSPConsentBanner.swift` entry near line 697;
    - `docs/architecture/app-window.md`: read only to confirm it is still truthful.
- Related patterns:
  - `TerminalPanelInsetTests` and `ChromeThemedTextFieldLayoutTests`:
    - one `HostedRender` per state;
    - `.environment(\.interfaceMetrics, …)` and `.environment(\.chromeTheme, ChromeTheme(.dark))` on the root;
    - teardown closes the window;
    - many pixels are read off one bitmap.
  - `InterfaceMetrics.scaledFont(_:weight:)`: `.body` is 13 and `.subheadline` is 11.
  - `metrics.scaled(_:)` for every length. `ChromeGeometry.cornerRadiusMax` is 6 and `hairlineWidth` is 1.
  - `LeetCodeBrowserView.swift` already sizes a symbol with `.font(.system(size: metrics.scaled(N)))` on the `Image`'s own chain. Rule thirty-four accepts that form with no exemption entry.
- Dependencies: none. Nothing in `PisakaCore` changes, so the iOS build is not affected.

## Development Approach

- **Testing approach:** Regular. The view and its gating pins come first, then the bitmap test, then the hand mutation check against that test.
- Complete each task fully before moving to the next.
- Every colour is a role and every length goes through `metrics`.
- No font size is written as a number. Text uses `scaledFont(.body)` and `scaledFont(.subheadline)`. The icon's 16 is the one design literal, passed through `metrics.scaled`.
- No product or brand names in code, comments, docs, tests or commit messages. The app's own name is fine.
- Tests stay cheap: one hosted window per rendered state, many pixels read per bitmap, no screen-recording API.
- Build in the default DerivedData location (the `make` targets do), never inside the repository.
- **CRITICAL: every task MUST include new/updated tests**
- **CRITICAL: all tests must pass before starting next task**

## Implementation Steps

### Task 1: The card, its band, its copy and its gating pins

**Files:**
- Modify: `Sources/Pisaka/LSPConsentBanner.swift`
- Modify: `Tests/PisakaCoreTests/ChromeThemeSourceGatingTests.swift`

**Card view and band**

- [x] Factor the drawing into one shipped card view, `LSPConsentCard`, in the same file under `#if os(macOS)`. Give it internal access so the app-layer bundle can render it through `@testable import`.
  - It takes the leading symbol name, the primary line, an optional secondary line, the confirming action's title, and the two actions as closures.
  - It owns the two `Button`s: the confirming one `.chromePrimary`, the declining one `.chromeSecondary`, 8 apart.
  - It draws the whole band, so the bitmap test renders exactly what ships.
  - The banner's three branches each build this card from their prompt, and nothing else draws a question. It replaces `strip(_:)` and the three hand-built `HStack`s.
- [x] Draw the card:
  - a `bgPanel` fill in a `RoundedRectangle` of radius `metrics.scaled(ChromeGeometry.cornerRadiusMax)`;
  - over it, a `strokeBorder` in `hairline` of width `metrics.scaled(ChromeGeometry.hairlineWidth)`;
  - padding `metrics.scaled(14)` vertical and `metrics.scaled(18)` horizontal;
  - inside, an `HStack` with every item vertically centred: the message group (icon and text column, `metrics.scaled(10)` apart), then a `Spacer`, then the buttons, with `metrics.scaled(16)` between the message group and the actions.
- [x] Draw the band around the card:
  - full width, on a `bgEditor` ground, with `metrics.scaled(8)` padding on every side;
  - the card's own border replaces the old bottom rule, so no `Rectangle` rule and no `Divider()` remains.
- [x] Keep the empty case as it is. The body's outer `VStack(spacing: 0)` stays (never a `Group`, for the reason already documented there), so it renders nothing and costs no height when no prompt applies. Leave the silent `.task(id: Trigger…)` half untouched.

**Text column and icon**

- [x] Give the text column `.layoutPriority(1)` over the spacer.
  - Primary line: `scaledFont(.body)`, `textPrimary`.
  - Optional secondary line: `scaledFont(.subheadline)`, `textSecondary`, with `.fixedSize(horizontal: false, vertical: true)` so it wraps across the whole column.
  - Buttons: `.fixedSize()`, so they keep their fitting width and never wrap or truncate.
- [x] Draw the leading symbol in `accent`: `arrow.down.circle` for the two downloads, `hammer` for Go.
  - Size it on the `Image`'s own chain with `.font(.system(size: metrics.scaled(16)))`, the design's 16-point icon, as `LeetCodeBrowserView.swift` does.
  - No container font on the message group: a 16-point container font would be a size that nothing but the glyph uses. The primary and secondary lines set their own fonts.

**Copy**

- [x] Pinned downloads:
  - Primary line: `Download the \(displayName) language server (\(size)) for completion and Go to Definition?`. The size comes from `downloadByteCount`, which is the pending byte count.
  - Lengths: Python is about 82 characters and YAML about 80. TypeScript/JavaScript is the longest at about 98 characters, and still fits on one line at a 1,100-point editor width.
  - Secondary line: shown only when `prompt.runtimeNetworkNote` is present, printed verbatim. Its presence is the whole condition, with no per-server branch.
- [x] Rust:
  - Primary line: `Download \(displayName) \(version) (\(size)) for completion and Go to Definition?`, with the date version folded in.
  - No secondary line.
- [x] Go:
  - Primary line, kept short: `Build \(displayName) \(version) with your own Go toolchain?`.
  - Secondary line, carrying the toolchain path and the two narrowed claims: `The build runs as your own “go install” would with the Go at \(goExecutablePath), using and adding to your module and build caches; the result is installed only inside Pisaka's own folder.`
  - A long toolchain path therefore wraps the secondary line, never the primary one.
  - No sentence may claim that nothing outside the app's folder changes.
- [x] Rewrite the file's doc comments to describe the card and the new copy, not the old sentences. These must stay truthful:
  - the narrowed Go claim (`GOBIN` only; the caches are the user's), now with the path on the secondary line;
  - the date-as-version reason, now about the date folded into the line;
  - the verbatim printing of the runtime note;
  - why Rust's size is shown and the toolchain is not mentioned;
  - the unawaited `accept`;
  - the reason for having no `.defaultAction`, which now sits beside the buttons in the card.

**Gating pins**

- [x] Delete the three `LSPConsentBanner.swift` entries from `glyphSizeExemptions` (`downloadRow(` / `goRow(` / `rustRow(`) and their "the consent strip's three rows," comment outright, with no replacement.
  - The card's one glyph sizes itself on its own chain through `metrics`, which rule thirty-four accepts without an entry.
  - Confirm rule thirty-four is green with the file carrying no exemption.
- [x] Confirm the other rules naming the file still hold, and that their wording is still true:
  - rule thirty's caller sets still hold, because the file spells both shared styles;
  - rule seven (no arithmetic on a token) and rule twenty-four (no `Divider()`) both apply.
- [x] Run `swift test`; it must pass.
- [x] Run `swiftlint --strict`; it must be clean.

### Task 2: The bitmap test for the card's drawn contract

**Files:**
- Create: `Tests/PisakaAppTests/LSPConsentCardLayoutTests.swift`

**Suite setup**

- [x] Write a `@MainActor` XCTest suite. Give it a doc comment, in the style of `TerminalPanelInsetTests`, that states the design values it pins and how each is measured.
- [x] Render the shipped `LSPConsentCard` with representative content: the download arrow, a primary line, no secondary line, and no-op actions.
  - Inject `\.interfaceMetrics` and `\.chromeTheme` (`ChromeTheme(.dark)`) on the root.
  - Pin the card to the top of a window taller than the band, through `HostedRender`.
  - Use one window per rendered state, each closed in teardown.

**Ground, border, interior and corner (scale 1 and 1.8)**

- [x] Read these pixels off one render per scale:
  - the band's ground at half the inset, left of, above and below the card, is `bgEditor`;
  - a column through the card's leading padding has `hairline` at its top and bottom edges (`extent(of: .hairline, atX:)`), with the edge at the scaled 8-point inset from the band's top and leading edges;
  - just inside the border, the interior is `bgPanel`;
  - half a point in from the card's top-leading corner, which is outside the radius, the pixel is `bgEditor` and not `bgPanel`.
- [x] Check that the border is one hairline wide and no wider, measured on the left edge. At scale 1.8 it spans the scaled width within the usual 0.6-point tolerance.

**Text column width (scale 1)**

- [x] Render the card at a generous width. On that bitmap, take the card's interior rows: every pixel row strictly between the top and bottom `hairline` border rows. Measure:
  - the primary button's leading edge: in each interior row, the first `accent` pixel right of the card's horizontal middle; take the minimum across rows;
  - the primary line's trailing edge: in each interior row, the last non-`bgPanel` pixel left of that button edge; take the maximum across rows.
  - A single row cannot stand in for this: a row through the last character can carry no ink, which would underestimate the edge, wrap the line at the derived width even with the fix in place, and fail the test spuriously.
- [x] Derive a narrow width from those two measurements, never from hard-coded button widths. It leaves the line exactly enough room plus a small slack, so the line fits on one line only if the text column reaches the actions.
- [x] Render the card again at the narrow width. Assert that its height (the `hairline` extent in the leading-padding column) equals the generous render's height.
- [x] Run `make test-app` (the app-layer bundle; `xcodegen generate` runs first). It must pass.
- [x] Do the mutation check by hand:
  - remove `.layoutPriority(1)` from the text column;
  - run the new suite and confirm that the width test fails;
  - restore the line. The mutation is never committed.
  - Result (done, did NOT fail): with `.layoutPriority(1)` removed, and again set to -1, with and without a secondary line, the width test stayed green. The stack lays the spacer out after the text either way, so the line keeps its one line at the derived width. The suite gained a guard that the generous render is one line (as tall as a one-word card); a column capped at 400 points then fails it. Both findings are recorded in the suite's doc comment.

### Task 3: Documentation

**Files:**
- Modify: `docs/architecture/core-theme.md`
- Modify: `docs/architecture/core-provisioning.md`
- Modify only if no longer truthful: `docs/architecture/app-window.md`, the `Sources/Pisaka/ContentView.swift` comment

- [x] Rewrite `core-theme.md`'s consent-strip entry for the card. Name the design's Banner component as its source and restate its values as literals:
  - panel ground, 1-point hairline border, radius 6 (`cornerRadiusMax`), padding 14/18, gaps 16 and 10, 16-point accent icon, 13-point primary line;
  - the 8-point inset band on `bgEditor` that replaces the bottom rule;
  - text roles: `textPrimary` for the primary line, `textSecondary` for the secondary line, `accent` for the icon;
  - the shared `.chromePrimary` / `.chromeSecondary` buttons, 8 apart, with the design's 12-point semibold label recorded as the known, accepted chrome-wide difference;
  - the layout-priority fix and the new bitmap suite that pins it.
- [x] In rule thirty-four's prose, state that the file carries no glyph-size exemption: the card's glyph takes its own scaled font, like the files already listed there. If any other place in that doc names the strip's three row exemptions, remove the mention rather than restating it.
- [x] Update the `LSPConsentBanner.swift` entry in `core-provisioning.md`:
  - describe the card in place of the strip, and the new copy: one primary line, with a secondary line only for the YAML runtime note and for the Go build's toolchain path and two narrowed claims;
  - keep the D15 statement that the pending size and the runtime network note are printed where consent is given;
  - keep the no-dismiss, no-shortcut, project-root and `VStack`-not-`Group` paragraphs unchanged in substance.
- [x] Read `app-window.md`'s mentions of the consent banner and the `ContentView` hosting comment. Edit them only where they describe the old strip in a way that is now false. (Read: both still truthful — the empty case draws no layout and no divider — so neither was edited.)
- [x] Run `swift test` again; it must pass. The doc-reading suites (`LintConfigurationTests` and the theme suite's document rules) must stay green.

### Task 4: Verify acceptance criteria

- [ ] Run `swift test`: all suites green, including every `ChromeThemeSourceGatingTests` pin naming `LSPConsentBanner.swift`.
- [ ] Run `make test-app`: the app-layer bundle is green, including `LSPConsentCardLayoutTests`.
- [ ] Run `swiftlint --strict` from the repository root: clean.
- [ ] Run `make build`: the macOS Release build succeeds.
- [ ] The iOS build is not required, because no Core file changed. Confirm that with `git diff --stat`, and run `make build-ios` if anything under `Sources/PisakaCore` did change.
- [ ] Confirm by reading the diff that:
  - no `Divider()`, no hex literal and no numeric font size was introduced, other than the icon's `metrics.scaled(16)`;
  - no `.keyboardShortcut` was introduced;
  - no glyph-size exemption names `LSPConsentBanner.swift`;
  - `size(_:)` keeps its signature for `LSPServerSettingsView`.

### Task 5: Update documentation

- [ ] Leave `README.md` and `docs/FEATURES.md` as they are, unless they describe the banner's look or copy; if they do, correct them.
- [ ] Leave `CLAUDE.md` unchanged: the file index, the invariants and the gating-suite list are untouched by this work. Confirm it stays under its measured size limit.

## Post-Completion

- Live check in a Debug build, never Release:
  - open a project with an unanswered server;
  - view a `.py`, `.ts`, `.yaml`, `.go` and `.rs` file at an editor width of about 1,100 points;
  - each should show the card with its primary line on one line, and the YAML note and the Go secondary line should wrap across the full text column;
  - answering either button should remove the card exactly as before.
