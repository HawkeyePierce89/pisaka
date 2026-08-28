# PisakaCore + Pisaka app (macOS) — the three zoom zones

Design documentation for the macOS zoom feature: the four pure Core files that
decide *which zone a gesture targets*, *what a legal scale is*, *how a
continuous gesture becomes discrete steps* and *what the interface scale means
in points* — plus the three app-side files that collect the facts those rules
consume. Read the relevant entry before modifying that file, and update it when
behavior changes.

## The shape of the feature, in one paragraph

macOS zoom is split into **three independently persisted zones** — `code`,
`terminal`, `interface` — and the target of every gesture is chosen by **where
the pointer is at that moment**, in any of the app's windows. The code zone
*is* the pre-existing `SettingsStore.fontSize`: there is deliberately no second
"code zoom" setting beside it, so the Preferences font-size row and a ⌘= over
the editor are two spellings of one value. The terminal zone is
`terminalFontSize` (default 13 — SwiftTerm's own — so nothing changes until the
user zooms it) and the interface zone is `interfaceScale` (default 1.0, a
multiplier), applied through the `\.interfaceMetrics` SwiftUI environment value
that every macOS chrome view reads for its fonts, paddings, frames, icon sizes
and row heights. Every *decision* is Core's and unit-tested; the app layer only
collects candidates under the pointer, runs one event monitor, offers three menu
items, and applies the three scales to views.

## Core

  - `ZoomZone.swift` — the vocabulary and the one pointer rule. `ZoomZone`
    (`code`/`terminal`/`interface`) is *what a gesture grows*, not where it
    happened; each zone is backed by exactly one persisted scale in
    `SettingsStore`. `ZoomSurfaceKind` has only **two** cases (`code`,
    `terminal`) on purpose: `interface` is the answer when nothing was hit,
    never a surface in its own right, so "an interface surface nested inside a
    code surface" is not representable and no hit-test walker has to decide what
    it would mean; `zone` is the one-way widening into `ZoomZone`.
    `ZoomSurfaceCandidate` is a `kind` plus a `depth` (the window's content view
    is 0, each child one deeper) — depth is what makes nesting decidable without
    the resolver knowing anything about views, so "a terminal inside the bottom
    panel's chrome" and "an editor inside a scroll view inside a split view" are
    just candidates at different depths. `ZoomPointerLocation` is
    `.insideApp([candidate])` or `.outsideApp`, the latter covering both "over
    another application's window" and "off every window" — reachable only by a
    menu key equivalent, which fires wherever the pointer is.
    `ZoomZone.resolve(pointer:focusedSurface:)` states four rules in order: the
    **deepest** candidate wins (depth is containment, so the innermost surface
    the pointer is actually over is the one the user means); **ties resolve to
    the first candidate in scan order** — two different kinds at the same depth
    over one point is not a layout this app produces, so rather than leave it
    undefined the caller's scan order (front-to-back within a window,
    `NSView.subviews` order for siblings) decides and the answer is at least
    stable and reproducible, which is why the implementation reduces with a
    strict `>` instead of `max(by:)` (that returns the *last* maximal element);
    no candidates → `.interface`, because chrome is everything that is not a
    code or terminal surface and "nothing matched" *is* the answer rather than a
    failure; `.outsideApp` → the key window's focused surface, and `.interface`
    when there is none. `ZoomZoneTests` covers every case plus the candidate
    shapes the app actually produces (editor nested in a scroll view inside a
    split view, terminal under the bottom panel's chrome, a marker inside a list
    row, the statement marker beside the editor, chrome around a surface staying
    interface).
  - `ZoomScaleRule.swift` — the arithmetic all three zones share: a range, a
    resting value and a step, as one value type rather than three sets of
    constants, because the zones differ only in their numbers while "clamp",
    "step" and "reset" are the same three operations everywhere — and the
    keyboard, the gesture path and the Preferences steppers must all produce
    values from one grid. `SettingsStore` owns the persisted values; this type
    owns what a legal value *is*. `clamp(_:)` brings a value into range and
    collapses a **non-finite** one to `defaultValue` rather than returning it:
    `min`/`max` propagate NaN (every comparison with it is false), so a NaN would
    survive the clamp and then make a clamp-in-`didSet` property's
    `clamped != value` (NaN != NaN) always true, recursing without bound — that
    guard predates this type, it is the editor font size's, moved here so all
    three zones inherit it. `clamp` deliberately does **not** snap to the grid:
    an arbitrary value from a slider, a stored preference or an older build stays
    where the user put it. `stepped(_:by:)` moves by whole steps, snapping to a
    grid **anchored at `defaultValue`** and computing the result from a whole
    step *index* rather than by repeatedly adding `step` to the running value —
    which is what makes the round trip exact: with `step` 0.1, adding and
    subtracting in sequence drifts (1.0 + 0.1 − 0.1 is not 1.0 in binary floating
    point) and the interface scale would never return to exactly 100%, while an
    index is recomputed from scratch every time and a final six-decimal `tidy`
    erases the representation error (so a scale reads back as 1.2 rather than
    1.2000000000000002 — in Preferences, in `UserDefaults`, and in the equality
    the round-trip property asserts). A value *off* the grid is snapped to the
    nearest grid point by the first step: a deliberate one-time correction, since
    the alternative is a grid per stored value and a reset that never lands.
    Three shipped rules, with their numbers' rationale: `.editorFont` (8…32,
    default 13, step 1 — the constants `SettingsStore` has always used, now
    stated once), `.terminalFont` (the same range and step, default 13 because
    that is `NSFont.systemFontSize`, what SwiftTerm already draws at, so a fresh
    install at 100% looks exactly as it does today) and `.interfaceScale`
    (0.8…2.0, default 1.0, step 0.1 — 0.8 because further down the chrome stops
    being hittable, 2.0 because beyond it the smallest usable window no longer
    fits an ordinary screen, and ten notches across the useful part of the
    range). `rule(for:)` is the single place the zone → rule mapping lives, so
    the app layer can step a zone without knowing which property backs it.
    `ZoomScaleRuleTests` pins the three rules' numbers, the mapping, clamping
    (incl. non-finite and not-snapping), stepping at both bounds, stepping by
    several at once equalling one at a time, walking the whole range one step at
    a time landing on both bounds *exactly*, the N-up-N-down round trip, a
    degenerate (zero or negative) `step` staying inert instead of dividing by
    zero into a NaN the clamp would turn into a silent reset, a non-finite step
    *count* doing the same from the other argument, and that
    interface steps read back as round numbers.
  - `ZoomGestureAccumulator.swift` — the bridge from a trackpad's fractions of a
    point to the *same* discrete grid the keyboard produces. Without it,
    scroll-zoom and ⌘= would drift apart and ⌘0 would be the only way back. It
    accumulates normalized fractions of a step and returns whole steps as they
    complete, keeping the sub-step remainder in `pending` so a slow drag feels
    continuous rather than dropping everything below the threshold on the floor.
    A value type with **no knowledge of `NSEvent`**: the app passes the raw delta
    plus a flag saying which flavor of scroll it was, and every decision — how
    many points make a step, how a wheel notch compares to a trackpad swipe, how
    sensitive a pinch is — lives here, tested. `Input` is `.scroll(delta:
    precise:)` or `.magnification(_:)`, with the **sign convention stated once**:
    positive means zoom in (on macOS a scroll upwards and a pinch outwards both
    report positive deltas, so the app hands the event's value straight through).
    `precise` distinguishes macOS's two scroll flavors — a trackpad or Magic
    Mouse sends *points* of travel in many small samples, an ordinary wheel sends
    *lines*, roughly one whole unit per detent — and choosing the divisor between
    them is this type's job, not the caller's, which only forwards
    `NSEvent.hasPreciseScrollingDeltas`. `Thresholds.standard` ships 24 precise
    points (about a third of a comfortable two-finger swipe, so a full swipe
    crosses two or three steps), 1 line (one detent is one step, which is what
    makes ⌃-wheel feel like the keyboard rather than like a slider) and 0.05
    magnification (deliberately the smallest: a pinch's whole comfortable travel
    is a magnification of about ±1, and a larger threshold would make the gesture
    reach two or three steps at full stretch and feel dead). **One line-based
    event is worth at most one step, however many lines it reports**: macOS
    applies scroll *acceleration* to that flavor, so a quick spin arrives as a
    single event reporting five or ten lines rather than as five or ten events
    reporting one, and a step here is a visible jump in font size — unclamped, a
    ⌘-wheel flick ran the editor to its ceiling in one gesture (the overrides
    this replaced stepped ±1 per event by construction, so the clamp is what
    keeps the port a port). The precise flavor is deliberately left unclamped:
    it reports many small samples per gesture and its magnitude *is* the travel,
    which is what makes a trackpad swipe feel continuous. The clamp reads
    finiteness first, because `min`/`max` answer their other argument for a
    `NaN` and would turn a poisoned delta into a whole step. Two further rules
    worth stating: **direction reversal drops the remainder** — a gesture that turns
    around starts from zero rather than first paying off the other direction's
    leftover, otherwise the first backwards step arrives either instantly or a
    whole threshold late, which reads as the gesture ignoring the user; steps
    already applied are never taken back, only the unspent fraction is discarded
    — and a **zero or non-finite delta is ignored entirely**, leaving `pending`
    alone, because a NaN folded in would poison every later sample and macOS does
    emit zero-delta scrolls at the momentum tail. `reset()` forgets the
    remainder; it is called at a gesture's end *and* when the pointer crosses
    into another zone mid-gesture, which are the same statement: a remainder only
    means anything within one continuous gesture over one zone, and carrying it
    across either boundary makes a later, unrelated flick step immediately. The
    whole-step extraction truncates towards zero with a `1e-9` tolerance, so N
    samples of exactly one threshold each yield exactly N steps (without it,
    `0.1 × 10` being 0.9999999999999999 would swallow the tenth step and leave a
    remainder that never spends), and guards the `Int` conversion so one absurd
    delta cannot trap. `ZoomGestureAccumulatorTests` covers N thresholds → N
    steps, many small samples reaching the same count, one large sample producing
    every step at once, sub-threshold deltas producing nothing but not being
    lost, zero/non-finite input (in *both* flavors, since only the line flavor's
    clamp can turn a `NaN` into a step), the accelerated-wheel clamp in both
    directions — including that it banks none of the surplus, and that the
    precise flavor is not clamped — mixed precise/line/pinch input in one unit,
    reset, both reversal rules, degenerate thresholds, and an absurd delta
    *saturating* at `Int.max`/`Int.min` rather than tripping `Int(_:)`'s overflow
    precondition — the one failure in this file that is a crash rather than a
    wrong number, and therefore the one worth an explicit test.
  - `InterfaceMetrics.swift` — the interface scale turned into concrete point
    sizes, so the whole view sweep is arithmetic-free. `InterfaceTextStyle` is
    the closed set of semantic styles the macOS chrome actually draws with, each
    carrying its **macOS** base point size (notably not iOS's — body is 13 here,
    17 there — which is why the type is documented as the macOS table even though
    it compiles everywhere); a scaled style is no longer `Font.caption`, it is
    "caption's size × the scale", so the sweep needs a number and stating them
    here keeps the 100% guarantee checkable in `swift test`. Adding a view that
    wants another style adds a case with its documented base size.
    `InterfaceMetrics(scale:)` clamps through `ZoomScaleRule.interfaceScale`, so
    a corrupt or non-finite value can never reach a layout, and `.unscaled` is
    the resting value the environment defaults to. `font(_:)` rounds to a **whole
    point** — rasterization is crispest on integral sizes, fractional sizes buy
    nothing at these magnitudes, and a whole number is what makes `scale == 1`
    return the base size *identically* rather than within a tolerance. `pt(_:)`
    rounds a layout metric to a **half point** instead: layout benefits from the
    finer grid (a 2 pt padding at 80% would otherwise jump to 2 or collapse to
    1), and a half point is exactly one device pixel on the Retina displays this
    app draws on. Zero stays zero, a non-zero metric never rounds away to nothing
    (a hairline separator must survive the bottom of the range), negatives scale
    symmetrically, and at scale 1 the value is returned untouched rather than
    round-tripped through the grid — so "nothing changes at 100%" holds for *any*
    metric, not only one already on the grid. Monotonicity rests on the input
    being on the half-point grid, which every layout constant in this app is; an
    off-grid metric can round up on its way down, which is a half point of noise
    and no reordering worth defending against. The code and terminal zones
    deliberately do **not** come through here: they are font sizes the user sets
    directly, and multiplying them by the interface scale would make two
    independent zones interact.
    `InterfaceMetricsTests` pins the base table (values *and* their ordering),
    the two "unchanged at 100%" guarantees — including every style at scale 1
    returning `basePointSize` *identically*, asserted against the table itself
    rather than against a restated copy of it — clamping, whole-point fonts
    (with the half-point cases that pin the rounding as **nearest**: without
    `19.5 → 20` and `16.5 → 17`, truncation would pass and every chrome font
    could silently lose a point across half the shipped grid),
    half-point metrics that never collapse, negatives, non-finite pass-through,
    monotonicity across the whole range, and that the extremes actually differ
    (monotonic-but-flat would satisfy the property and change nothing on screen).
    It also covers the **compositions the view sweep builds** rather than only
    their parts, which is where a sweep like this actually breaks: the Log's
    branch-graph gutter (`lanes × pt(14) + pt(6)`, with every lane's node dot
    fitting inside it and the dot staying inside its row and its lane at every
    scale), the `minWidth/idealWidth/maxWidth` triples the sweep scales
    independently keeping their ordering, the commit sheet's minimum width still
    holding both `HSplitView` panes' minimums, the Acknowledgements detail pane's
    remainder never shrinking as the scale grows, and the two values the license
    pane takes as *numbers* rather than through SwiftUI — it is a TextKit view,
    so its font and its `textContainerInset` are set on it and nothing else in
    the sweep reaches them: the size rests at `NSFont.smallSystemFontSize` (11)
    and the margin at 12, the same base as the header padding directly above it,
    and both must be strictly larger at the top of the range. A margin left
    behind while the text grows is the same island the sweep exists to remove,
    just a quieter one.

## The macOS app half

  - `ZoomSurface.swift` — who the pointer can be *over*, and the walk that finds
    them. `ZoomSurfaceProviding` is a `@MainActor` marker protocol on `NSView`
    with one read-only `zoomSurfaceKind` and no behavior: a view conforms in
    order to be **found**, not in order to act — everything a gesture does with
    the answer lives in `ZoomController`, every rule for turning answers into a
    zone lives in Core. Conformed to by the four code text views
    (`EditorTextView`, `DiffTextView`, `MergePaneTextView`,
    `SourceViewerTextView`), by `CodeScrollView` — the scroll view each of those
    four is the document of — by the three views that draw **beside** a text view
    rather than inside it — `LineNumberRulerView` (the editor's gutter *and* its
    blame column), `DiffGutterView` and `MinimapView` — by the custom completion popup's content view (`CompletionPanel.swift`) — by SwiftTerm's
    `TerminalView` — declared as an
    extension on the dependency's own class because that is the view the pointer
    is over, with `TerminalView` rather than `LocalProcessTerminalView` since the
    subclass inherits it and the base class draws the cells; the conformance
    carries no behavior, which is what makes extending a third-party class here
    harmless — and by `ZoomSurfaceMarkerView`. Nothing declares `.interface`.

    **The sibling rule is the one that is easy to get wrong.** A scroll view's
    ruler is a sibling of its text view, and the minimap is a sibling of the
    editor's whole scroll view, so neither is reachable by walking *into* the
    text view: without a conformance of its own, a pointer over the gutter, the
    blame column or the minimap produces **no candidate at all**, and "no
    candidates" means `.interface` — a ⌘= aimed at the editor would resize the
    entire application chrome. The rule to apply to anything new: *if it draws at
    the code font, it declares itself, wherever it sits in the hierarchy.*
    `ZoomSourceGatingTests` pins the resulting set by equality, in both
    directions, so a surface cannot be added or dropped without this doc being
    revisited.

    **Unreachable ≡ chrome is what bounds that rule**, and one view relies on it:
    the hover popover (`HoverPanel.swift`, `core-lsp.md`'s D26). It draws a type
    signature at the code font, directly over the text view, and declares no
    surface at all — because it sets `ignoresMouseEvents = true`, so a pointer
    that appears to be "on" it is in fact still over the editor and a gesture
    aimed there is a gesture over the code, which is the zone the user means. The
    sibling rule is about views the pointer *can* reach; a view it can never reach
    has no zone of its own to declare. `ZoomSourceGatingTests` pins both halves,
    since either one deleted alone leaves a panel that still compiles, still draws
    identically, and still passes the surface-set check above.
    The completion panel (`CompletionPanel.swift`) explicitly does **not** claim this exemption: it accepts clicks (to commit a row) and so must declare its `.code` surface to avoid being classified as interface.

    **The empty-region rule is its twin, and cost `CodeScrollView`.** A
    conformance answers only for the area the view actually *covers*, and all
    four code text views are content-sized — `minSize = .zero`,
    `autoresizingMask = []`, both resizable flags, an unbounded text container —
    so each one's frame is its laid-out text, not its pane. (`CodeEditorView`
    already relies on this, clamping its scroll offset with
    `max(0, textView.frame.height - clipView.bounds.height)`.) The pointer below
    the last line of a short file, or right of the longest line of a narrow one —
    the ordinary case, not a corner — was therefore over the pane but over no
    candidate, so the zone resolved to `.interface` and a ⌘= aimed at the code
    grew the chrome. `CodeScrollView` is an `NSScrollView` subclass declaring
    `.code`, used by all four panes: a strictly *shallower* candidate than its
    document view and its ruler, so the deepest-candidate rule is untouched
    (wherever one of those is hit it still wins, and all of them name the same
    zone). It is a subclass rather than an `extension NSScrollView` on purpose —
    the latter would have made the project tree and every settings list a code
    surface. `ZoomSourceGatingTests.testTheCodePanesScrollInsideTheCodeScrollView`
    pins it in both directions, because every one of those four files stays in
    the surface list above even after regressing to a plain `NSScrollView`.

    `ZoomSurfaceMarker` is the `NSViewRepresentable` for the surfaces that
    draw at the code font with no `NSTextView` behind them — the Find in Files
    result rows, the LeetCode statement's `WKWebView` body, and the commit
    dialog's unified diff and message editor (both drawn at `settings.fontSize`,
    so targeting the interface zone from them while the text under the pointer
    followed the code size would be the same incoherence): an empty,
    non-drawing, hit-test-transparent `NSView` placed *behind* the content with
    `.background(...)`, so it inherits exactly that content's frame and nothing
    else about it. Zero-cost is meant literally — it draws nothing, `hitTest`
    answers `nil` so it can never stand between the user and the row it marks,
    and it is out of the accessibility tree (an empty group element in a results
    list is noise to a screen reader); the pointer walk finds it by geometry, not
    through AppKit hit testing, so refusing hits costs the zoom nothing.
    `ZoomHitTest.pointerLocation(screenPoint:)` is the app-side half of the
    pointer rule: `NSWindow.windowNumber(at:belowWindowWithWindowNumber: 0)`
    answers with the frontmost window at that screen point **across every
    application**, which is the point — a window belonging to another app (or no
    window at all) gives a number this process does not own,
    `window(withWindowNumber:)` answers `nil`, and the location is `.outsideApp`;
    hit-testing our own windows in z-order by hand would get the
    cross-application half wrong. The point is converted screen → window →
    content view once, then `candidates(under:in:depth:)` walks recursively under
    two load-bearing rules: **a hidden view and its whole subtree are skipped**
    (the four bottom panels and the terminal's inactive tabs stay in the
    hierarchy while hidden, and a hidden terminal under the pointer would
    otherwise claim every gesture aimed at whatever replaced it), and
    **`bounds.intersection(visibleRect)`, not either alone** (`visibleRect` is
    the part a superview has not clipped away, so a text view scrolled far past
    the pointer — or one in a collapsed split pane — contains the point in its own
    `bounds` yet is not under the pointer at all; and AppKit returns that region
    in the receiver's coordinates *without* intersecting the receiver's own
    rectangle, so unintersected it is routinely larger than `bounds` and every
    unclipped surface would claim every pointer location, handing the
    deepest-candidate rule the deepest surface in the tree instead of the one
    under the pointer). Siblings are visited in `subviews` order, which is what
    Core's documented tie-break means by "scan order".
    `focusedSurfaceKind()` walks *up* the responder chain from the key window's
    first responder, so a focused text view answers for itself and a focused
    subview of SwiftTerm's terminal answers for the terminal; it is consulted
    only on the `.outsideApp` path, which only a menu shortcut can reach.
  - `ZoomController.swift` — the one place a zoom gesture arrives, whatever
    produced it. It owns three things and nothing else: one
    `ZoomGestureAccumulator` **per zone** (so a half-finished step in the editor
    never spends itself in the terminal), one local `NSEvent` monitor, and the
    answer to "which zone is the pointer over". Every number it applies comes
    from `SettingsStore.stepZoom/resetZoom`; the only thing this file decides is
    *what an `NSEvent` is*. **Why a monitor rather than per-view `scrollWheel`
    overrides**: the overrides it replaced (`CodeFontScroll.swift`, deleted with
    its four call sites) could only ever reach the views that carried them, which
    is exactly the two zones that already had a font of their own and neither of
    the two this feature adds — SwiftTerm's terminal view consumes scrolls to
    move its scrollback and a SwiftUI `List` consumes them to scroll, so a
    ⌃-scroll over the terminal or the project tree would never have surfaced at
    all. A local monitor sees the event before any view does, which is what makes
    all three zones reachable by the same gesture; *local* rather than global
    because a global one would need the Accessibility permission and would zoom
    the app while another one is front. `install()` is idempotent (a re-fired
    `.onAppear` for a reopened window must not install a second monitor that
    doubles every step) and `uninstall()` also forgets any in-flight gesture.
    `sample(for:)` is the one place `NSEvent` vocabulary is spoken: a **scroll**
    counts only while ⌘ or ⌃ is held (⌃-scroll is the macOS system zoom gesture
    and ⌘-scroll is what this app has always used, so both are honoured; an
    unmodified scroll passes through), every **pinch** counts with no modifier,
    and **momentum is swallowed but never zoomed** — it is the trackpad coasting
    after the fingers lifted, so letting it zoom would carry a flick two or three
    steps past where the user stopped while letting it through would scroll
    whatever is under the pointer instead. Everything recognized is swallowed on
    **every** path, including the ones that step nothing: a ⌘-held scroll leaking
    out as an ordinary scroll would scroll the editor while the user is zooming
    it. The zone is re-resolved per event, and crossing into a new zone resets
    the one being left.

    **The end of a gesture is read *outside* the modifier gate**, by
    `isGestureEnd(_:)` at the top of `handle(_:)` rather than inside
    `sample(for:)`. Releasing ⌘ before lifting the fingers is ordinary, and the
    `.ended` event that follows carries no modifier at all — read only inside the
    gated classification it would never arrive, stranding that gesture's
    remainder and its `activeZone` indefinitely so that a much later, unrelated
    flick stepped immediately, which is exactly what `reset()` exists to prevent.
    It is *observed* there rather than folded into the classification because the
    event must still be classified normally: an unmodified scroll's end phase is
    not ours, and swallowing it would deny the scroll view the phase it uses to
    finish the scroll and start momentum. A legacy mouse wheel reports both
    phases empty on every event and so never reports an end — which costs
    nothing, because a wheel detent is one whole line and therefore exactly one
    whole step, leaving no remainder between detents to strand.

    **Momentum belongs to the scroll that produced it, not to the modifiers held
    when it arrives**, and the same released-⌘ case is why. Momentum events are
    synthesized after the fingers have lifted and report the flags of *that*
    moment, so gating them like content events would drop the whole tail out of
    the classification the instant ⌘ came up and scroll the editor the user had
    just finished zooming — the leak the swallow exists to prevent, arriving by
    the other door. `handle(_:)` therefore keeps one flag, `momentumIsOurs`,
    written only by **content** events (a began/changed under ⌘/⌃ claims the
    momentum that will follow, an unmodified one disclaims it) and read by the
    momentum events, which are swallowed on the claim alone and clear it on their
    end phase. End phases write nothing: they carry no modifiers and so state no
    intent. **The flag is honoured in both directions**, and the second half is
    not decoration: a momentum tail the content events *disclaimed* is passed
    straight through whatever the flags say by then, because otherwise pressing
    ⌘ or ⌃ during an ordinary inertial scroll (reaching for ⌘S, or just resting
    a hand) dropped the rest of the tail into the gated classification, which
    swallows a modified scroll by design — the coast stopped dead mid-glide and
    nothing zoomed either, since a momentum event contributes no accumulator
    input. `stepZoomUnderPointer(by:)` and `resetZoomUnderPointer()`
    back the three View-menu items and resolve the zone **at invocation time from
    the pointer**, exactly as a gesture does — a key equivalent fires wherever
    the pointer happens to be, so ⌘= over the terminal grows the terminal even
    though the editor has the focus — and both end any in-flight gesture first,
    since a keyboard step belongs to no gesture and a gesture interrupted by one
    has no claim on its remainder.
  - `InterfaceScaleEnvironment.swift` — how the interface zone reaches the views:
    one environment value carrying `InterfaceMetrics`, injected at every SwiftUI
    root the app owns. The environment is the right vehicle for exactly the
    reason the sweep is wide — the scale has to reach a badge nested five
    containers deep inside a lazily-built commit row, and threading a parameter
    through every intermediate view would be a per-view API change the next new
    view would silently forget; an environment value is inherited by
    construction, including by sheets and popovers presented from a scaled root.
    Three rules the whole sweep obeys: **nothing computes the scale itself** (a
    view asks for `metrics.scaledFont(.caption)` or `metrics.scaled(8)`, and the
    arithmetic with its rounding lives in Core where it is unit-tested — the two
    helpers here exist only to hand SwiftUI its own `Font`/`CGFloat` over Core's
    platform-neutral `Double`s, and `scaledFont` is deliberately a *different
    name* from Core's `font(_:)` rather than an overload, because two functions
    differing only in return type resolve by context and a sweep this wide will
    eventually find an ambiguous one); **the default is the resting one** (a view
    the sweep has not reached, or a preview with no root modifier, reads
    `.unscaled` and draws exactly what it drew before this existed); and
    **code-font sites never come through here** — anything drawn at
    `settings.fontSize` (the Find in Files result rows, the commit dialog's
    unified diff, every editor pane) belongs to the code zone, and multiplying it
    by the interface scale would make two independent zones interact, which is
    the one thing the three-zone split exists to prevent. The `.interfaceScaled(
    _:)` modifier takes the `SettingsStore` and **observes** it, which is what
    makes a zoom gesture or a Preferences edit re-lay-out the window live;
    `SettingsStore.interfaceMetrics` exists for the *roots*, which cannot read
    the value they just injected (an environment write reaches descendants, not
    the view that made it) and so compute their own metrics from the same store.

### Where the environment is injected

Every SwiftUI root that receives the one shared `SettingsStore` applies
`.interfaceScaled(settings)`: the main window's `ContentView`, the `Settings`
scene (applied by `PisakaApp` at the scene rather than inside `SettingsView`, so
it reaches the settings form itself), and each `NSHostingController` root —
`DiffWindowContent`, `SourceViewerContent`, `ProjectSearchView`, `MergeView`,
`LeetCodeBrowserView` and `LocalHistoryView`.

The last one's content stays deliberately split across two
zones: the `DiffView` it hosts is code and stays on `settings.fontSize`, while
the revisions list, the footer and the empty-state sentence around it are chrome
and scale with the interface. It declares no zoom surface of its own —
`LocalHistorySourceGatingTests.testTheWindowDeclaresNoZoomSurfaceOfItsOwn` pins
that — because the only thing in it drawn at the code font is that `DiffView`,
which already declares one.

**A sheet inherits the environment of the view its `.sheet(…)` is attached to —
which is not the environment that view's *body* publishes.** Get that backwards
and the sheet renders at 100% over a window at 200%, which is exactly the
"island" the sweep exists to prevent, and it looks correct at the resting scale
where it would be reviewed. Three cases, and only the first needs nothing:

- **Inherits.** The commit dialog: `ContentView` attaches `.sheet` from its own
  body *before* `.interfaceScaled(settings)`, so the injection is genuinely its
  ancestor. Same for the Preferences sign-in sheet (the scene applies the scale
  around `SettingsView`) and for the sign-in sheet nested inside the Open
  Problem sheet.
- **Attached above the write.** `PisakaApp` presents the two LeetCode sheets at
  the scene, around `ContentView`, while `ContentView` injects the scale inside
  its own body. An environment value a child publishes cannot travel up to a
  presentation the parent attached — so `PisakaApp` applies
  `.interfaceScaled(settings)` to the sheet's content.
- **Attached after the write.** `LeetCodeBrowserView` applies the scale and
  *then* `.sheet(isPresented:)`; a later modifier in a chain wraps the
  environment write rather than descending from it, so that sheet's content
  carries its own injection too.

Those two extra call sites are pinned by
`ZoomSourceGatingTests.testTheSheetPresentersInjectTheScaleOnTheirContent`, by
set equality over the files with more than one injection — the roots test counts
*files* and cannot see a missing second call.

### What `swift test` can still see

The whole app half of this feature is view code and therefore untested by
convention — but several of its rules are exactly the kind `swift test` *can*
pin statically, in the `LSPSourceGatingTests`/`SparkleSourceGatingTests` mould.
`ZoomSourceGatingTests` reads `Sources/` through `#filePath` (reusing that
suite's Swift scanner, so **comments and string literals are stripped** — every
file involved documents its own zoom rules at length, and a raw `contains` would
pass while the code it describes was deleted) and asserts:

  - **`interfaceScale` is named only by the plumbing** — the rule, the metrics,
    the store and `InterfaceScaleEnvironment` — so the invariant CLAUDE.md
    states ("reaches views only as `InterfaceMetrics`, never multiplied inline")
    has a gate. A view writing `settings.interfaceScale * 8` compiles and looks
    right at 100%, which is when it would be reviewed.
  - **The set of files applying `.interfaceScaled(...)` equals the roots listed
    above**, by set equality in both directions. A new `NSHostingController`
    root that forgets it silently draws its whole window at the resting size —
    no error, no warning.
  - **The set of files injecting it a second time, on a presentation's own
    content, equals `{PisakaApp, LeetCodeBrowserView}`** — the two sheets the
    check above cannot see, because it counts files and both of those files
    already appear in it for their roots.
  - **The set of files declaring a zoom surface** (by conformance or by
    `ZoomSurfaceMarker`) equals the list under `ZoomSurface.swift`. This is the
    rule that has already gone wrong once, and the sibling trap makes it silent.
  - **The hover popover passes every mouse event through and declares no
    surface.** `ignoresMouseEvents = true` and the `canBecomeKey` override are one
    line each and invisible to every other check here: delete either and the panel
    compiles, draws identically and stays out of the surface set — it simply
    becomes a hit-test obstacle between the pointer and the code, which is the
    whole of what makes it chrome (D26).
    The completion panel explicitly refuses this exemption (it accepts clicks) and declares `.code`.
  - **Every code pane scrolls inside a `CodeScrollView`**, and no file outside
    the four builds one — the empty-region rule, which the check above cannot
    see: all four files stay in the surface set even while their panes' blank
    areas zoom the chrome.
  - **The Preferences terminal stepper reads its bounds and step from
    `ZoomScaleRule.terminalFont`** rather than restating them. `SettingsStoreTests`
    can only assert that the *store* accepts those bounds; whether the row
    presents them is a fact about a view, and hard-coding `in: 8...40, step: 2`
    there would compile and drift from the grid ⌘0 and the gestures land on.

## Known limits

**AppKit-drawn chrome is outside the interface zone by construction.** Context
menus, `DefinitionPicker`'s `NSMenu`, the completion popup `CompletionController`
drives, `NSAlert`/`PlatformAlert` dialogs, the open/save panels in `FilePanels`
and the Preferences window's own tab bar are drawn by the system, not by SwiftUI
views the environment can reach, so they stay at the system size at every scale.
This is a boundary, not a gap: nothing about `\.interfaceMetrics` can reach them
short of overriding the system's own menu and panel appearance.

The LeetCode statement pane is a `WKWebView`. Its body follows the **code** zone
through the CSS size `LeetCodeStatementDocument` builds from `settings.fontSize`
(which is why the pane carries a `ZoomSurfaceMarker(kind: .code)` — targeting
the interface zone while the text followed the code size would be incoherent),
and it does **not** follow the interface scale. The chrome around it does. This
is recorded under Known limitations in `docs/FEATURES.md`.
