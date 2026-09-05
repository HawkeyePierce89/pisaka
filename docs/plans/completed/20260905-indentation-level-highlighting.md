# Indentation-level highlighting in the code editor (macOS)

## Overview

Paint the leading whitespace of every line in the macOS code editor, one
indentation unit at a time, in a translucent tint that cycles with the unit's
level, so nesting reads at a glance and a mis-nested line stands out without
reading the code. The split of a line's indentation into levelled runs is a new
pure `PisakaCore` engine; the painting is a background-pass override in the
editor's existing `NSLayoutManager` subclass; the feature is on by default and
switched off by one Preferences toggle. iOS gets the shared setting and no
surface.

## Context

Files involved:

- Core (new): `Sources/PisakaCore/IndentLevelScanner.swift`
- Core (modified): `Sources/PisakaCore/TerminatedLines.swift`,
  `IndentUnitRule.swift`, `EditorConfigModel.swift`, `SettingsStore.swift`
- App, macOS (modified): `Sources/Pisaka/BracketOverlayLayoutManager.swift`,
  `BracketHighlightController.swift`, `CodeEditorView.swift`,
  `ContentView.swift`, `SettingsView.swift`, `SyntaxTheme.swift`,
  `Platform/PlatformColor.swift`
- Tests: `Tests/PisakaCoreTests/IndentLevelScannerTests.swift` (new),
  `TerminatedLinesTests.swift`, `EditorConfigModelTests.swift`,
  `SettingsStoreTests.swift`
- Docs: `docs/architecture/core-editor.md`, `core-diff-merge.md`,
  `app-editor-overlays.md`, `core-services.md`, `core-editorconfig.md`,
  `app-ios.md`, `docs/FEATURES.md`, `README.md`, `CLAUDE.md`

Related patterns the work rests on:

- `IndentUnitRule.unit(config:inferred:)` already decides what one indentation
  level is (configuration first, content inference second); this feature reads
  that same answer and must not restate it — including its `defaultSpaceWidth`,
  which the painter's fallback reads rather than re-spelling as a literal.
- `BracketOverlayLayoutManager` is installed by `CodeEditorView.makeNSView`
  alone, and `CodeEditorView` is constructed by `ContentView` alone — so "only
  the main editor paints levels" is true by construction, with no filter needed
  in the diff panes, the merge editor, the source viewer or the minimap.
- `completionEnabled` is the precedent for a preference reaching the editor:
  read once where the view is built, passed down as a plain value, forwarded by
  the coordinator, applied in both `makeNSView` and `updateNSView`. The editor
  never observes the store.
- `BracketHighlightController` already owns the one debounced,
  generation-guarded, cache-keyed text-change path in the editor; the unit
  recompute rides that path rather than growing a second debounce.
- `EditorConfigModel` is a **plain final class, not `ObservableObject`** and not
  observed by the editor. Its invalidation reaches the editor only indirectly:
  an on-disk `.editorconfig` change arrives through FSEvents, which calls
  `editorConfig.noteProjectFilesChanged()` and bumps
  `WorkspaceModel.treeRevision`, and *that* `@Published` bump re-renders the
  content view and so runs `updateNSView`. This plan states that dependency
  explicitly and does not rely on it alone (see Task 5).

Note for the reviewer: nothing in `PisakaApp.swift` changes.

## Development Approach

- **Testing approach**: Regular (code first, then tests) for the Core engine and
  the two Core additions; the view layer stays untested by convention.
- Complete each task fully — including its tests and a green `swift test` —
  before starting the next.
- Domain logic in `PisakaCore`, Foundation only, `NSString` + UTF-16 offsets;
  the app side is thin glue under `#if os(macOS)`.
- Read the matching `docs/architecture/*.md` entry before touching a file;
  documentation is updated in the final task.
- No product or brand name anywhere in code, comments, tests, docs or commit
  messages.
- **CRITICAL: every task that changes Core ships new/updated tests, and all
  tests must pass before the next task starts.**

## Implementation Steps

### Task 1: The levelled-run engine in Core

Intent: one pure answer to "which parts of this text's leading whitespace are
which indentation level", so the view layer decides nothing about levels.

The engine takes the text as an `NSString`, a character range, a unit width and
a tab width in columns, and answers the ordered runs — a UTF-16 range and a
zero-based level — for every line the range intersects. Line boundaries come
from the editor's existing separator set, not a second rule: extend
`TerminatedLines` with a bounded primitive (`ranges(in:range:)`) that expands
the given range to whole lines through `lineRange(for:)` and enumerates only
that span, and make today's whole-text `ranges(_:)` a call to it over the full
range, so there stays exactly one traversal that decides where a line ends.
Bounding it is what keeps a draw off a whole-file scan.

Rules the engine owns:

- Leading whitespace is spaces and tabs only, the same two characters
  `IndentEngine` already treats as indentation. A space advances the column by
  one; a tab advances it to the next multiple of the tab width.
- A run ends at the first character whose column crosses into a new unit, and
  its level is the level of the column it started at — so one tab is always one
  block even when it crosses several unit boundaries (levels may then skip,
  which is honest: the column really did).
- The whitespace remaining when the line's content starts is emitted as one
  more, shorter run at the next level (six spaces at a unit width of four → a
  full block at level 0 and a short one at level 1). There is no error level and
  no special treatment of misalignment.
- A line with no leading whitespace and an empty line yield nothing; a
  whitespace-only line is levelled like an indent of its width (its content
  range holds only whitespace, so the same walk answers it).
- Runs are never clipped to the requested range: a range starting or ending
  mid-indent still answers those lines' whole, correctly levelled runs. The
  painter clips by drawing.
- A unit width or tab width of zero or less answers no runs — never a trap,
  never a loop.

The same file also owns the pure derivation of the two widths from what the
editor already decided, so the view never invents them: given the unit string
`IndentUnitRule` answered and the configuration's `tab_width`, a tab unit is as
wide as the stated `tab_width` and, when unstated, **as wide as
`IndentUnitRule.defaultSpaceWidth` — read from the rule, never restated as a
literal, so the painter's fallback and Enter's cannot drift apart** (that
constant is already `internal` in `PisakaCore`, which is the access the engine
needs; widen it only if a test or the app layer turns out to need it). A space
unit is as wide as its own spaces; the tab width is the stated one, or the unit
width when unstated — which is what makes a tab-indented file paint one block
per tab.

**Files:**

- Create: `Sources/PisakaCore/IndentLevelScanner.swift`
- Modify: `Sources/PisakaCore/TerminatedLines.swift`,
  `Sources/PisakaCore/IndentUnitRule.swift` (access only, if needed)
- Create: `Tests/PisakaCoreTests/IndentLevelScannerTests.swift`
- Modify: `Tests/PisakaCoreTests/TerminatedLinesTests.swift`

- [x] add the bounded line primitive to `TerminatedLines` and reduce the
      whole-text form to it, with its doc comment stating the expansion
- [x] write the engine: the run/level value type, the width derivation reading
      `IndentUnitRule.defaultSpaceWidth`, and the levelled walk
- [x] test the engine for spaces only, tabs only, tabs and spaces mixed with
      tab-stop arithmetic, a partial trailing unit, an empty line, a
      whitespace-only line, every separator in the editor's set including CRLF
      as one terminator, a range starting mid-indent, a range ending mid-indent,
      a range spanning several lines, and zero/negative widths yielding no runs
- [x] test the width derivation: tab unit with and without a stated `tab_width`
      (the unstated case asserted against `IndentUnitRule.defaultSpaceWidth`,
      not against a literal), space unit with and without one
- [x] test the bounded line primitive against the whole-text form (same answer
      over the full range; whole lines for a mid-line range)
- [x] run `swift test` — must pass before Task 2

### Task 2: The preference and the configuration revision, in Core

Intent: give the feature a persisted switch that defaults to on, and give the
editor a way to notice that `.editorconfig` answers changed without re-inferring
on every keystroke.

`SettingsStore` gains one published `Bool` under a stable key, written back
through `didSet` like its neighbours and read with `completionEnabled`'s exact
absent-key discipline: `object(forKey:)` so an absent key and a wrong-typed
value both read as **on**, never as off. One flag, not one per platform — iOS
simply shows no surface for it in this ticket.

`EditorConfigModel` gains a monotonic revision that both of its wholesale
invalidations bump, so a reader holding a cached answer can tell in one integer
comparison that its answer is stale. It stays a reader and stays a plain class;
nothing else about it changes.

**Files:**

- Modify: `Sources/PisakaCore/SettingsStore.swift`,
  `Sources/PisakaCore/EditorConfigModel.swift`
- Modify: `Tests/PisakaCoreTests/SettingsStoreTests.swift`,
  `Tests/PisakaCoreTests/EditorConfigModelTests.swift`

- [x] add the preference (key, published property, load with the absent-key
      rule)
- [x] add the revision counter to the configuration model's two invalidation
      points
- [x] test the default on a fresh store, an absent key reading as on, a
      wrong-typed stored value reading as on, and the round trip across a fresh
      store
- [x] test that both invalidations bump the revision and that a same-root
      re-assignment does not
- [x] run `swift test` — must pass before Task 3

### Task 3: The palette, its translucency, and the brand-name housekeeping

Intent: four appearance-aware tints that everything drawn on top of them stays
readable through — and a `SyntaxTheme.swift` that names no product at all.

Add a four-colour palette to `SyntaxTheme` beside the bracket palette, each
entry with a light and a dark variant and a translucency low enough that the
text, the selection, the matched-pair background and both search-match
backgrounds all remain legible over it, with a `level → colour` accessor cycling
by `level mod count` and folding a negative level back into range, mirroring the
bracket accessor. Because the colour shim builds opaque colours only, give it an
alpha-carrying form of the dynamic constructor, applied inside the
per-appearance resolution so the colour stays dynamic.

Housekeeping folded in here — **all three product-naming comments in the file,
not one**, since the repository rule is that no brand name appears anywhere:

- the bracket-palette doc comment the ticket names,
- the `matchedPairBackground` comment (around line 74), which names two
  products,
- the token-table comment (around line 183), which names one.

Each is rewritten to say the same thing about the colour choice — what it is,
what it must stay distinguishable from, why — without naming any product.

**Files:**

- Modify: `Sources/Pisaka/SyntaxTheme.swift`,
  `Sources/Pisaka/Platform/PlatformColor.swift`

- [x] add the alpha-carrying dynamic colour form to the shim
- [x] add the level palette and its cycling accessor (plus the `NSColor`
      spelling the layout manager calls, beside the existing ones)
- [x] rewrite the bracket-palette, matched-pair-background and token-table doc
      comments without any product name
- [x] grep the whole file for any remaining product name and confirm none is
      left
- [x] run `swift test` — must pass before Task 4

### Task 4: Painting, in the editor's layout manager

Intent: draw the blocks under everything the layout manager already draws,
without touching the temporary-attribute machinery.

`BracketOverlayLayoutManager` gains the state (enabled, unit width, tab width)
and an override of the background-drawing pass that paints the level blocks
**first** and then calls `super`, so the matched-pair background, the
search-match backgrounds and the selection all land on top. Temporary attributes
are not involved at all — the existing backgrounds are one attribute key per
character and a second writer of that key would collide with a search match
sitting on whitespace — and the syntax-styling layer is untouched.

Geometry is read at draw time: the drawn glyph range becomes a character range,
the engine is asked for the runs of the lines it intersects, and each run's x
extent comes from the layout manager's own bounding rect for that run while its
y extent comes from the enclosing line-fragment rect, so consecutive lines at
one level read as a single column with no gaps and a font-size change needs no
bookkeeping at all. The buffer is read through the text storage's mutable-string
handle rather than by bridging its `string`, so a draw copies nothing; the
engine's range is the drawn one, so a draw never walks the whole file. A
disabled feature, a degenerate width or an absent text storage draws nothing and
calls `super` unchanged.

The setter that hands over the flag and the two widths invalidates the visible
area when any of the three changes, so a change repaints without a reload.

**Files:**

- Modify: `Sources/Pisaka/BracketOverlayLayoutManager.swift`

- [x] add the painting state and its setter, invalidating on a change
- [x] override the background pass: blocks first, then `super`; document the
      ordering and why temporary attributes stay out of it
- [x] run `swift test` — must pass before Task 5

### Task 5: The widths and the flag reaching the editor

Intent: the painter is *given* everything it draws from; it asks the store
nothing and infers nothing on a draw.

The coordinator computes the two widths from
`IndentUnitRule.unit(config:inferred:)` plus the configuration's `tab_width`,
through the Core derivation from Task 1, and pushes them to the layout manager.
Because the content inference walks the whole buffer, the recompute must not sit
on the SwiftUI update path: it rides the editor's existing debounced text-change
path — the one that re-runs the rainbow bracket scan — by way of a hook the
bracket controller calls when a scan is applied, which also covers the immediate
path a tab switch takes.

A configuration invalidation is caught by comparing the revision from Task 2.
**Two things matter about that comparison and both are stated here.** First, its
trigger on the update path is indirect: `EditorConfigModel` is a plain class the
editor does not observe, so an on-disk `.editorconfig` change reaches
`updateNSView` only because the same FSEvents turn that calls
`noteProjectFilesChanged()` also bumps `WorkspaceModel.treeRevision`, whose
`@Published` change re-renders the content view. Second — precisely because that
path is indirect and could be quiet — the revision is compared in the
**scan-applied hook as well**: one integer against the last one seen, on a path
that already runs on every debounced edit and every tab switch. A stale width
therefore never outlives the next edit or tab switch even if no re-render
arrives.

The recompute is skipped while the feature is off and forced once when it is
switched back on, so a user who turned it off pays nothing for it.

The flag itself travels `completionEnabled`'s route exactly: an undefaulted
plain value on the editor view, passed from the content view in one line,
forwarded by the coordinator, applied in `makeNSView` and re-applied in
`updateNSView`, so turning it off stops the painting in every open tab at once
and turning it on brings it back without a reload.

**Files:**

- Modify: `Sources/Pisaka/CodeEditorView.swift`,
  `Sources/Pisaka/BracketHighlightController.swift`,
  `Sources/Pisaka/ContentView.swift`

- [x] add the scan-applied hook to the bracket controller (one debounce, one
      generation token — no second one)
- [x] add the coordinator's width computation, its cache, and its triggers: the
      debounced text change, the tab switch, and the configuration revision
      compared **both** in the scan-applied hook and on the update path
- [x] add the undefaulted flag to the editor view, forward it from the
      coordinator to the layout manager in both the build and the update path,
      and pass it from the content view in one line
- [x] run `swift test` — must pass before Task 6

### Task 6: The Preferences toggle

Intent: one switch, where the editor's other switch already is.

Add a toggle worded around highlighting indentation levels to the editor
settings form, immediately beside the completion toggle, bound straight through
to the store with no local state, so the surface and the preference cannot
disagree. No iOS surface is added.

**Files:**

- Modify: `Sources/Pisaka/SettingsView.swift`

- [x] add the toggle beside the completion toggle, bound straight to the store
- [x] run `swift test` — must pass before Task 7

### Task 7: Verify acceptance criteria

- [x] `swift test` green
- [x] `swiftlint --strict` from the repository root clean (0 violations in 500
      files; no measured ceiling had to move, so nothing was recorded in
      `.swiftlint.yml` or `LintConfigurationTests`)
- [x] `xcodegen generate` succeeds
- [x] macOS build green (`xcodebuild -project Pisaka.xcodeproj -scheme Pisaka
      -destination 'platform=macOS' build`)
- [x] iOS Simulator build green (`-destination 'platform=iOS
      Simulator,name=iPhone 17 Pro'`)
- [x] confirm `PisakaApp.swift` is unchanged and `ContentView.swift` grew by
      exactly the one line that passes the flag
- [x] confirm no product or brand name appears in the diff

### Task 8: Update documentation

- [x] `docs/architecture/core-editor.md` — **only** the new engine's entry: the
      two widths, the run rule, the tab-stop arithmetic, the trailing partial
      unit, the unclipped answer, the degenerate-width refusal, and that the
      fallback width is read from `IndentUnitRule.defaultSpaceWidth`
- [x] `docs/architecture/core-diff-merge.md` — update the `TerminatedLines`
      entry (which lives there, not in `core-editor.md`) for the bounded
      primitive and why it is *the* primitive the whole-text form projects from
- [x] `docs/architecture/app-editor-overlays.md` — the painting rule and its
      ordering (blocks first, then `super`; temporary attributes never involved;
      geometry at draw time; the widths arrive from the coordinator), in both
      the layout-manager and the bracket-controller entries, **including** the
      stated freshness dependency: the configuration model is not observed, the
      update path fires only through the workspace tree revision, and the
      revision is therefore also compared in the scan-applied hook
- [x] `docs/architecture/core-services.md` — the new preference in the
      `SettingsStore` entry, with the absent-key rule
- [x] `docs/architecture/core-editorconfig.md` — the configuration model's
      revision and who reads it
- [x] `docs/architecture/app-ios.md` — the shim's alpha-carrying colour form
- [x] `docs/FEATURES.md` — a paragraph in the macOS section, and a line in the
      known limitations that iOS has no painting
- [x] `README.md` — a mention in the feature list
- [x] `CLAUDE.md` — one index line for the new Core file under the
      editor-engines doc

## Post-Completion (manual, on a running build)

- Open a Swift, a Python and a YAML file with default settings: indented lines
  show level-cycled tints.
- Open a tab-indented file (a Makefile, a Go file): one block per tab.
- Open a file under an `.editorconfig` stating `indent_size = 2` whose content
  would infer four: two-space blocks.
- Check an empty line (nothing), a whitespace-only line (its width), and a line
  with a partial trailing unit (a shorter block).
- Select text over painted whitespace, run a search matching whitespace, and put
  the caret beside a matched bracket next to an indent: all three draw over the
  tint, and the syntax colours are identical with the feature on and off.
- Zoom the code font up and down: the blocks stay on the whitespace at every
  step.
- Toggle the preference off and on with several tabs open: painting stops and
  resumes everywhere at once; relaunch and confirm the preference survived.
