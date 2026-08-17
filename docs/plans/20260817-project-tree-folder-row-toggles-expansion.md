# Project tree: the whole folder row toggles expansion

## Overview

In the macOS project tree, only the ~10pt disclosure chevron toggles a directory
today; the icon, the name and the blank space to its right are inert on a left
click. Make the entire folder row one click target that toggles expansion, and
give folder rows the same hover highlight file rows already have, so both row
kinds read and behave alike.

The chosen shape (decided in plan Q&A): keep `DirectoryNodeView` built on
`DisclosureGroup`, but drive it with a private `DisclosureGroupStyle` that draws
its own chevron and the label as **one full-width row** carrying a single tap
gesture and the hover highlight, rendering `configuration.content` only while
expanded. Because the style owns the chevron, there is no separate chevron
button that could fire a second toggle — "one click, one state change" holds by
construction rather than by careful gesture masking. The documented contract
("directories are `DisclosureGroup`s") stays true.

This is a pure view-layer interaction change. No pure rule falls out of it, so
nothing new lands in `PisakaCore`; the view layer is untested by convention, so
the gate is the full `swift test` suite staying green (including the source
gating suites) plus a successful macOS build.

## Context

- Files involved:
  - Modify: `Sources/Pisaka/ProjectTreeView.swift` — the whole change: a new
    private `DisclosureGroupStyle` (+ its private row view), applied to the
    `DisclosureGroup` in `DirectoryNodeView`.
  - Modify: `docs/architecture/app-window.md` — the `ProjectTreeView.swift`
    entry (lines ~339–393): record the full-row click target, the hover
    highlight, and the custom style.
- Related patterns:
  - `FileRowView` (same file, lines 302–355) is the reference for the hover
    treatment: `.padding(.horizontal, metrics.scaled(6))` +
    `.padding(.vertical, metrics.scaled(3))`, `.frame(maxWidth: .infinity,
    alignment: .leading)`, `.background(isHovering ?
    Color.accentColor.opacity(0.15) : Color.clear)`, `.contentShape(Rectangle())`,
    `.onHover { isHovering = $0 }`.
  - Today's folder label (lines 215–238) already carries `.frame(maxWidth:
    .infinity, alignment: .leading)` + `.contentShape(Rectangle())` under its
    `.contextMenu` — that pair is what makes the blank space right of the name a
    right-click target. It is load-bearing and must survive the change.
  - Interface zoom: every size in the tree goes through
    `@Environment(\.interfaceMetrics)` (`metrics.scaled(_:)` /
    `metrics.scaledFont(_:)`). The new chevron column and the row's padding must
    do the same. Nothing here names `interfaceScale` or declares a zoom surface,
    so `ZoomSourceGatingTests`' set-equality assertions stay untouched — the
    suite running green is the check.
  - `DisclosureGroupStyleConfiguration` exposes `.label`, `.content`,
    `.isExpanded` and the projected binding `configuration.$isExpanded` — the
    style's `makeBody` toggles through that binding.
- Dependencies: none. macOS-only, all inside the file's existing `#if os(macOS)`.

## Development Approach

- **Testing approach**: Regular (code first). There is no Core logic to add —
  the change is entirely SwiftUI interaction wiring, and `Sources/Pisaka` is
  untested by repo convention (`CLAUDE.md`: "views only wire triggers to
  engines and are untested"). Accordingly no new `PisakaCoreTests` suite is
  created; each task instead re-runs the full existing suite, which includes the
  repository-file and source-gating suites that *can* see view-layer rules.
- If any decision turns out to be expressible as a pure rule (it is not expected
  to — there is no arithmetic here beyond metrics scaling that already exists),
  it belongs in `PisakaCore` with unit tests rather than in the view.
- Complete each task fully before moving to the next; the suite must be green
  before starting the next task.

## Implementation Steps

### Task 1: Make the folder row one click target with a custom disclosure style

**Files:**
- Modify: `Sources/Pisaka/ProjectTreeView.swift`

Introduce, in this same file (no new file — this is one private style, not a new
component), a `private struct FolderDisclosureStyle: DisclosureGroupStyle` whose
`makeBody` is a `VStack(alignment: .leading, spacing: 0)` of a private row view
and, **only when `configuration.isExpanded`**, `configuration.content`. The row
must be a separate private `View` struct (taking
`DisclosureGroupStyleConfiguration`) rather than inline in `makeBody`, because it
needs its own `@State isHovering` and `@Environment(\.interfaceMetrics)`.

The row is an `HStack(spacing: metrics.scaled(4))` of:

- the chevron, drawn by the style itself: `Image(systemName: "chevron.right")`
  rotated 90° when expanded, `.foregroundStyle(.secondary)`, sized through
  `metrics.scaledFont(.caption)` and pinned to a fixed `metrics.scaled(12)`-wide
  column so labels line up across siblings regardless of chevron glyph metrics;
- `configuration.label`.

The row then gets exactly `FileRowView`'s treatment — the same horizontal /
vertical padding, `.frame(maxWidth: .infinity, alignment: .leading)`,
`.background(isHovering ? Color.accentColor.opacity(0.15) : Color.clear)`,
`.contentShape(Rectangle())`, `.onHover { isHovering = $0 }` — plus a single
`.onTapGesture { configuration.isExpanded.toggle() }` covering the whole row.
Toggle with a plain assignment — do **not** wrap it in `withAnimation`:
animating a deep nested subtree's insertion is a regression risk the ticket does
not ask for.

**The label keeps its full-width frame, its content shape and its context menu.**
In `DirectoryNodeView`, apply `.disclosureGroupStyle(FolderDisclosureStyle())`
and leave the `label:` closure as it is today — icon + `Text(name)` `HStack`,
`.font(metrics.scaledFont(.body))`, `.lineLimit(1)`, `.truncationMode(.middle)`,
`.frame(maxWidth: .infinity, alignment: .leading)`, `.contentShape(Rectangle())`
and `.contextMenu { … }`. This is deliberate and is the one correction over an
earlier draft: those two modifiers are what stretch the label across the row's
remaining width and make its blank trailing space a right-click target, so
stripping them would silently shrink the context-menu surface to the icon+name.
They cost nothing here — a child's `contentShape` adds no gesture, so a left
click on the label still falls through to the row's `.onTapGesture`, and
`.contextMenu` handles the right button only, so opening the menu never toggles.
The label sits inside the row's own `maxWidth: .infinity` frame, so the hover
highlight covers the chevron column too, matching a file row edge to edge.

Indentation must not visibly change. The default macOS style silently indents
`content` under the label; a custom style does not, so the style applies a
leading inset to `configuration.content` equal to the chevron column plus the row
spacing (`metrics.scaled(12) + metrics.scaled(4)`), while `DirectoryNodeView`'s
existing `.padding(.leading, metrics.scaled(12))` on each child row stays as it
is. Net nesting indent lands within a couple of points of today's.

Everything else in `DirectoryNodeView` — `startsExpanded`, the lazy
`loadChildren()` on `onChange(of: isExpanded)` / `onAppear`, the `treeRevision`
re-read and collapsed-node cache drop, the beep-and-stay-retryable failure path
— is untouched, so a row-body expansion loads children through the identical
code path a chevron click uses.

- [x] add the private disclosure style + its private row view (own chevron,
      full-row tap toggle, `FileRowView`'s hover highlight and padding, content
      rendered only while expanded and inset to preserve today's nesting)
- [x] apply the style in `DirectoryNodeView`, leaving the label's full-width
      frame, content shape and context menu exactly as they are
- [x] confirm no behavior in `DirectoryNodeView`'s state handling changed
      (lazy first load, cached children, `treeRevision`, error path) — the diff
      adds exactly one line inside `DirectoryNodeView`, the style modifier
- [x] no new Core tests: this task adds no Core logic (view layer is untested by
      convention) — instead re-run `swift test` in full and confirm it is green,
      including `ZoomSourceGatingTests` (2917 tests, 0 failures)
- [x] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination
      'platform=macOS' build` succeeds

### Task 2: Update the architecture documentation

**Files:**
- Modify: `docs/architecture/app-window.md`
- Modify: `Sources/Pisaka/ProjectTreeView.swift` (doc comments only)

Record the observable change where the tree's contract lives. In
`app-window.md`'s `ProjectTreeView.swift` entry, amend the "Directories are
`DisclosureGroup`s" sentence: they still are, but through a private
`DisclosureGroupStyle` that renders chevron + label as one full-width row — the
whole row toggles expansion (the chevron is drawn by the style, so there is
exactly one toggle path), the row carries the same hover highlight as a file row,
and the right-click context menu stays on the label, which keeps its full-width
frame and content shape so the blank space right of the name still opens it.
State that the style renders `configuration.content` only while expanded and
re-supplies the content indent the default style used to add, so lazy loading and
nesting are unchanged. Mirror the same facts in the file's own header /
`DirectoryNodeView` doc comments.

- [ ] update the `ProjectTreeView.swift` entry in `docs/architecture/app-window.md`
- [ ] update the doc comments on `ProjectTreeView` / `DirectoryNodeView` and add
      one on the new style explaining why it exists (single toggle path +
      full-row hit area/highlight) and why the label keeps its full-width frame
      and content shape (the context-menu surface)
- [ ] no test changes needed (documentation only) — re-run `swift test` to
      confirm the suite is still green

### Task 3: Verify acceptance criteria

- [ ] `swift test` — full suite passes
- [ ] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination
      'platform=macOS' build` succeeds
- [ ] re-read the diff against the ticket: file rows untouched, iOS untouched,
      no selection/keyboard/drag changes, no row-height changes beyond the hover
      highlight, every new size scaled through `metrics`, and the label's
      `.frame(maxWidth: .infinity, alignment: .leading)` + `.contentShape` still
      present under its `.contextMenu`

## Post-Completion (manual, in the running app)

- Click a folder's name, its icon, and the blank space right of the name: each
  toggles expansion once; the chevron alone still does the same.
- Hover a folder row and a file row: identical highlight treatment.
- Right-click a folder row (root and nested) **on the name and on the blank
  space right of it**: the menu opens in both places, expansion state does not
  change; New File… / New Folder… (+ Rename… / Delete off-root) work.
- Expand a never-opened directory by clicking its name: children load; a
  directory made unreadable beeps and re-expands successfully after the
  permission is restored.
- With ⌘+/⌘− interface zoom applied, the folder row's font, chevron, padding and
  nesting indent scale along with the rest of the chrome.
