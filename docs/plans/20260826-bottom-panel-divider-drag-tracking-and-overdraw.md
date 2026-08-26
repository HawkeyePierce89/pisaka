# Bottom panel divider: one-to-one drag tracking and no overdraw of the bottom bar

## Overview

The divider between the editor and the bottom dock panel is unusable: it
oscillates instead of following the pointer, and the panel can be drawn on top
of the bottom toggle bar. Both are fixed here — the drag is re-measured in a
coordinate space that does not move with the divider, the height arithmetic
moves into a small pure Core engine that also reserves room for the editor, the
panel's *inner* minimum heights are removed so nothing inside the fixed-height
slot can outgrow it, the column is clipped as a hard guarantee, and the resize
cursor is made to survive the whole drag.

## Context

### Root cause 1 — jitter (verified)

`ContentView.panelDivider(maxHeight:)` (`Sources/Pisaka/ContentView.swift:369`)
attaches a plain `DragGesture()`, whose default coordinate space is `.local` —
the divider's own space. The divider moves as a direct consequence of the drag:
pointer up 10pt → `panelHeight` grows 10pt → the divider is re-laid-out 10pt
higher → in its *new* local space the pointer sits back at the start location →
`value.translation.height` returns to ~0 → the height snaps back to the
drag-start base → the divider drops → the next mouse event repeats it. The
existing `panelDragStartHeight` capture prevents frame-to-frame *compounding*
but cannot fix a translation that is measured against a moving origin. The
divider never tracks the pointer, so the pointer drifts away from it.

Fix: measure in a space that is stationary for the duration of the drag — a
named coordinate space published on the `VStack` inside `mainArea`'s
`GeometryReader`, which holds the editor, the divider and the panel and whose
own frame does not change while dragging. `.global` (the window) would also
work; the named container space is preferred because it stays correct if the
window root ever gains chrome above `mainArea`. `minimumDistance: 0` is set at
the same time so the drag does not begin with an already-accumulated 10pt jump
(today's default `minimumDistance` makes the very first `onChanged` carry a
≥10pt translation against a base captured in that same call).

### Root cause 2 — overdraw from the outer column (verified)

`mainArea`'s panel branch lays out
`VStack { editorSplit.frame(maxHeight: .infinity); panelDivider; panelContent.frame(height:) }`
inside a `GeometryReader`, with no clipping. `editorSplit` carries
`.frame(minWidth: metrics.scaled(640), minHeight: metrics.scaled(400))`
(`Sources/Pisaka/ContentView.swift:616`), so the editor *refuses* to render
shorter than 400pt × interface scale. Meanwhile `clampedPanelHeight` (`:398`)
clamps the panel only against `[scaled(120), max(scaled(120), geo.height / 2)]`
— it never asks whether the editor's minimum, the divider and the panel
actually fit. When `editorMinimum + divider + panelHeight > geo.size.height`
the `VStack` overflows its `GeometryReader` bounds and, with nothing clipping
it, the panel paints over the bottom toggle bar. This happens transiently
during the oscillation and legitimately in a small window at a large interface
zoom (the scaled 120pt floor alone can exceed half the available height).

A second, quieter defect in the same place: because the `GeometryReader` erases
its children's minimum sizes, the `minHeight: scaled(400)` on `editorSplit`
does *not* reach the window as a minimum content size while a panel is shown —
it only does so in the no-panel branch. So the 400pt floor is currently both
the cause of the overflow and not doing the job it was written for.

### Root cause 3 — overdraw from *inside* the panel slot (verified, new)

`panelContent(_:)` renders each panel into a fixed `.frame(height:)` slot, yet
three of its four branches carry a `minHeight` of their own:

- `.log` — `CommitLogView(...).frame(minHeight: metrics.scaled(160))`
  (`Sources/Pisaka/ContentView.swift:425`)
- `.changes` — `.frame(minHeight: metrics.scaled(120))` (`:441`)
- `.problems` — `.frame(minHeight: metrics.scaled(120))` (`:444`)
- `.terminal` — none

The rule's floor is `scaled(120)`. For the Log panel the inner minimum is 160,
so at *any* dragged height between 120 and 160 the content refuses the slot's
proposal, the fixed-height frame centers the oversized child, and it spills
both over the divider above and over the bottom toggle bar below — in a large
window, with the editor nowhere near its minimum. This is the exact bleed in
the bug report's screenshot, which shows the Log panel. Fixing only the
column's arithmetic would leave it.

**Decision: one floor, in Core; the three inner `minHeight` modifiers are
deleted.** Reasoning, recorded in the code comment and in the docs:

- A minimum *inside* a fixed-height slot can never be satisfied by the layout.
  The slot's height is decided by the rule; a child that demands more cannot
  make the slot grow, so the only outcome available to it is to overflow. The
  guarantee in requirement 2 has to hold for whatever is in the slot, which
  means nothing in the slot may state a minimum.
- The degenerate case makes this unconditional rather than a tuning question.
  The rule deliberately shrinks the panel *below* its floor when the available
  space cannot hold floor + divider + editor reservation. No per-panel minimum
  — 160, 120, or any other number — can be honored on that path, so a
  per-panel floor would still need these modifiers deleted and would only buy a
  second, larger-in-one-case drag floor.
- The stated clamp semantics are "min 120pt, interface-scaled". Making the
  floor per-panel (160 for Log) would change that stated contract for one
  panel; a single floor keeps it exactly as specified and gives the height one
  authority.
- Nothing is lost at 120: all three panels are scrollable lists/tables,
  `.changes` and `.problems` already sit at exactly this floor, and `.terminal`
  states no minimum at all.

### Mechanism for requirement 2 (recorded in the docs) — three parts

- **Tighter clamp (the behavior).** The panel's upper bound becomes
  `min(available / 2, available - divider - editorMinimum)`, and the editor's
  `minHeight` moves off `editorSplit` onto the window body root — where it
  actually becomes the window's minimum content height in *both* branches —
  leaving the split free to shrink inside the column. `editorMinimum` is a
  separate, smaller reservation (`scaled(120)`) whose only job is "the editor
  keeps a few lines when the panel is greedy"; it is deliberately not the
  window minimum, because reusing 400 here would collapse the panel to nothing
  in any window near its own floor.
- **No minimum inside the slot (the precondition).** The three `minHeight`
  modifiers above are removed, so the slot's height is the only height its
  content has.
- **Clipping (the guarantee).** The column additionally gets `.clipped()`, so
  no arithmetic slip, intrinsic-minimum surprise (the editor zone's own fixed
  strips: breadcrumb, tab strip, consent banner, find bar) or future layout
  edit can ever paint outside `mainArea`. The clamp decides what the layout
  *should* do; the clip makes "never over the bar" unconditional. All three are
  needed: the clip alone would silently hide panel content, the clamp alone
  rests on every child honoring its proposal — which the Log panel
  demonstrably did not.

### Root cause 4 — cursor

`.onHover { hovering in if hovering { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }`
is unbalanced by construction: it pops on any exit, including an exit that was
never preceded by a push, and it knows nothing about the drag, so a fast drag
that outruns the 5pt strip flips the cursor back to the arrow mid-resize. Fix:
a single "is a resize cursor currently pushed by this view" flag driven by
`hovering || dragging`, pushed and popped exactly once per transition, with
`.onDisappear` releasing it if the panel is hidden while the cursor is pushed.

### Files involved

- Create: `Sources/PisakaCore/BottomPanelHeightRule.swift`
- Create: `Tests/PisakaCoreTests/BottomPanelHeightRuleTests.swift`
- Modify: `Sources/Pisaka/ContentView.swift` (`panelHeight` state, `body`,
  `mainArea`, `panelDivider`, `clampedPanelHeight` removal, `panelContent`
  branches, `editorSplit` frame)
- Modify: `docs/architecture/core-services.md`,
  `docs/architecture/app-window.md`, `CLAUDE.md`

### Related patterns

- `ZoomScaleRule.swift` — the precedent for "a tiny value type that owns what a
  legal value is", including its non-finite guard; the new rule follows its
  shape (Foundation-only, `Double`, `Equatable`/`Sendable`, unit-tested).
- `BottomPanel.swift` + `BottomPanelTests.swift` — the sibling this rule sits
  beside; documented in `docs/architecture/core-services.md`.
- `InterfaceMetrics.pt(_:)` / the app-side `metrics.scaled(_:)` — the view
  scales the constants and hands the rule plain numbers; Core stays
  scale-agnostic.
- Pure-engine + thin-glue: no `NSCursor`, no `CGFloat`-only APIs and no view
  state in Core.

### Dependencies

None. No new packages, no `Package.resolved` change, no pin change.

## Development Approach

- **Testing approach**: TDD for the Core rule (it is pure arithmetic with a
  named degenerate case); regular for the view glue, which is untested by
  repository convention.
- Complete each task fully before moving to the next.
- The view layer keeps only event wiring and the coordinate-space choice; every
  number and every clamp decision comes from the Core rule.
- **CRITICAL: every task MUST include new/updated tests** (the view-only and
  documentation tasks re-run the suite as their gate — Core has no view tests
  by convention).
- **CRITICAL: all tests must pass before starting the next task.**
- No product or brand names in any code, comment, doc or commit message written
  by this change; the comments and doc paragraphs this change rewrites must
  drop the comparisons they carry today (`ContentView.swift:239` is one).
  Comments this change does not touch stay out of scope.

## Implementation Steps

### Task 1: The Core height rule

**Files:**
- Create: `Sources/PisakaCore/BottomPanelHeightRule.swift`
- Create: `Tests/PisakaCoreTests/BottomPanelHeightRuleTests.swift`

- [ ] write `BottomPanelHeightRuleTests` first, covering: one-to-one mapping
      inside the bounds (a translation of N maps to exactly N points of height
      change, in both directions); the lower bound (floor); the upper bound at
      half the available height; the editor-reservation bound binding *before*
      half in a short area; the degenerate case where the floor exceeds what
      the reservation leaves (result shrinks to the fitting height, is never
      negative and never exceeds the available space); `available` of zero,
      negative and non-finite; a non-finite proposed height; and a sweep over a
      grid of available heights and proposals asserting the invariants
      `height + divider + editorMinimum <= available` whenever `available` is
      large enough to hold them, and `height <= available` always
- [ ] add one test that pins the single-floor decision: the rule's result is
      never influenced by anything but `floor`, `dividerHeight` and
      `editorMinimum` — specifically, that in the degenerate case the returned
      height is *below* `floor`, which is why no view below the rule may state
      a minimum of its own (the test's doc comment names the deleted
      `panelContent` modifiers as what it guards)
- [ ] add `BottomPanelHeightRule`: a `Sendable`, `Equatable` value type over
      `floor`, `dividerHeight` and `editorMinimum` (all `Double`, all already
      interface-scaled by the caller), with `upperBound(available:)`,
      `height(proposed:available:)` and
      `height(base:dragTranslation:available:)` (the drag form is
      `height(proposed: base - dragTranslation, available:)` — dragging up is a
      negative translation and grows the panel)
- [ ] make the degenerate case explicit in the type: when the upper bound falls
      below the floor the rule returns the upper bound (shrink), never the
      floor, and never a value the available space cannot hold; guard
      non-finite inputs the way `ZoomScaleRule.clamp` does rather than letting
      NaN survive a `min`/`max`
- [ ] document the type with the reasoning above (why the editor reservation is
      not the window minimum; why the clamp is the behavior, the absence of
      inner minimums the precondition, and clipping the guarantee; why the
      floor is one number for every panel), with no comparisons to other
      products
- [ ] run `swift test` — must pass before Task 2

### Task 2: Make the drag track the pointer and stop the overflow

**Files:**
- Modify: `Sources/Pisaka/ContentView.swift`

- [ ] publish a named coordinate space on the `VStack` inside `mainArea`'s
      `GeometryReader` (a private constant for the name) and change
      `panelDivider`'s gesture to
      `DragGesture(minimumDistance: 0, coordinateSpace: .named(…))`
- [ ] replace the two `clampedPanelHeight` helpers with a computed
      `panelHeightRule` built from `metrics.scaled(120)` (floor),
      `metrics.scaled(5)` (divider) and `metrics.scaled(120)` (editor
      reservation), and route both the drag and the rendered
      `panelContent(...).frame(height:)` through it with
      `available: geo.size.height`
- [ ] delete the three `.frame(minHeight:)` modifiers inside `panelContent(_:)`
      — `.log`'s `metrics.scaled(160)` (`:425`), `.changes`'s
      `metrics.scaled(120)` (`:441`) and `.problems`'s `metrics.scaled(120)`
      (`:444`) — so nothing in the fixed-height slot can outgrow it; rewrite
      the `.log` branch's comment, which explains the now-deleted minimum, to
      state instead that the slot's height is the rule's and that panel content
      states no minimum of its own
- [ ] keep the drag-start base capture (it is still what makes the cumulative
      translation absolute) and keep the divider's 5pt scaled height and fill
      unchanged
- [ ] move `minHeight: metrics.scaled(400)` off `editorSplit` onto the window
      body root so the window minimum applies in both branches, leave
      `minWidth: metrics.scaled(640)` where it belongs, and let `editorSplit`
      inside the panel column shrink to what the rule reserved
- [ ] add `.clipped()` to the panel column so the panel can never paint outside
      `mainArea`, and confirm by inspection that the surfaces which must escape
      the window content are separate windows (the completion panel, the hover
      popover, context menus) and so are unaffected
- [ ] rewrite the `panelHeight` state comment (`:238`, which carries a product
      comparison today) and the `body` / `mainArea` layout comments to describe
      the new coordinate-space and overdraw reasoning, dropping those
      comparisons
- [ ] run `swift test` — must pass before Task 3

### Task 3: Keep the resize cursor honest for the whole drag

**Files:**
- Modify: `Sources/Pisaka/ContentView.swift`

- [ ] add the two pieces of divider state (hovering, dragging) plus a single
      "this view has a cursor pushed" flag, and one private helper that pushes
      or pops exactly once per transition of `hovering || dragging`
- [ ] drive the helper from `.onHover`, from the gesture's `onChanged` (set
      dragging on the first change) and from `onEnded` (clear it), so the
      resize cursor persists through a drag that outruns the strip and the
      arrow returns when both are false
- [ ] release a pushed cursor from `.onDisappear`, so hiding the panel while
      the pointer is on the divider cannot leak a pushed cursor
- [ ] run `swift test` — must pass before Task 4

### Task 4: Verify acceptance criteria

- [ ] `swift test` — full suite green
- [ ] `swiftlint --strict` from the repository root — clean
- [ ] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' build`
      (run `xcodegen generate` first if the project file is absent) — green
- [ ] `xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build`
      — green (this change is macOS-only; the iOS build is the no-regression
      gate)
- [ ] grep `Sources/Pisaka/ContentView.swift` for any surviving
      `frame(minHeight:` inside `panelContent(_:)` — there must be none
- [ ] grep the files this change touched for product/brand names and confirm
      the rewritten comments and paragraphs carry none

### Task 5: Update documentation

- [ ] `docs/architecture/core-services.md` — full entry for
      `BottomPanelHeightRule.swift` beside `BottomPanel.swift`: the three
      constants and who scales them, the two upper bounds and which one binds
      when, the degenerate case, why the floor is a single number rather than
      per-panel, and why the rule is Core rather than view glue
- [ ] `docs/architecture/app-window.md` — rewrite the panel-height paragraph:
      why the drag is measured in the container's named coordinate space and
      what the local space did instead, `minimumDistance: 0`, the three-part
      overdraw mechanism (tighter clamp + no minimum inside the slot + clip)
      and why all three, that panel content states no minimum of its own and
      the reason a minimum inside a fixed-height slot can only overflow, the
      window minimum moving to the body root, and the cursor push/pop pairing;
      the rewritten text drops the product comparisons it carries today
- [ ] `CLAUDE.md` — one index line for `BottomPanelHeightRule.swift` under the
      `core-services.md` list; no other growth of that file
- [ ] `README.md` / `docs/FEATURES.md` — no change (no user-facing feature
      change; this is a defect fix), confirm and note it
- [ ] `swift test` and `swiftlint --strict` once more after the doc edits

## Post-Completion (manual, by the user)

- Drag the divider up and down in each panel (Terminal, Git/Log, Changes,
  Problems) at 100%, 150% and 200% interface zoom: the edge follows the pointer
  one-to-one with no jitter, and the pointer stays on the divider.
- With the Log panel open in a large window, drag the divider down to the
  floor: the list shrinks with the slot and never spills over the divider or
  the bottom bar (this is the screenshot's case).
- Drag fast enough to outrun the strip: the resize cursor stays for the whole
  drag and the arrow returns afterwards.
- Shrink the window and raise the interface zoom until the panel floor cannot
  fit: the panel shrinks and never appears over the bottom toggle bar.
- Switch panels and hide/show: the height survives.
