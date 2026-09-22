# PisakaCore + Pisaka app (macOS) — the chrome theme

Design documentation for the chrome's design system: the four pure Core files
that name *what a chrome colour means*, *what a chrome measurement is*, *which
of the two value sets is in force* and *what a project-tree row is showing* —
plus the app-side palette, the two paths a colour reaches a view by, and the
repository-file suite that pins the whole rule. Read the relevant entry before
modifying that file, and update it when behavior changes.

## The shape of the feature, in one paragraph

Everything drawn *around* the code — tabs, gutters, trees, panels, bars — is
the **chrome**, and the chrome is drawn from a closed vocabulary rather than
from whatever colour a view reached for. `PisakaCore` names the meanings
(`ChromeColorRole`), the measurements (`ChromeGeometry`), the two value sets
(`ChromeAppearance`) and the one row rule that orders four simultaneously-true
facts (`TreeRowState`); it stays Foundation-only and therefore colour-free, the
`FileIconColor` precedent. The app layer holds exactly one table,
`ChromePalette`, whose exhaustive `switch` turns a role into a dark value, a
light value and one alpha, and offers that value along **two paths**: a SwiftUI
`\.chromeTheme` environment value carrying the resolved appearance, and an
AppKit bridge returning a *dynamic* `NSColor`. The theme is injected at exactly
the eight roots that already inject the interface scale. The sweep runs in
parts: the first restyled the horizontal tab strip, the line-number ruler and
the project tree rows; the second took the rest of the **editor pane's** own
chrome — the vertical tab column, the breadcrumb, the minimap's chrome and the
language-server consent strip — and corrected the gutter regression the first
part shipped. The running record is
["The surfaces restyled so far"](#the-surfaces-restyled-so-far) below; every
surface not named there is deliberately untouched, waiting for the sweep
described at the end of this document.
`ChromeThemeSourceGatingTests` (`swift test`) pins which files obey the rule and
`ChromePaletteTests` (app bundle) pins the values themselves.

The chrome theme is a **reader**: it takes no writer gate, is gated by none, and
adds no write of any kind. Its only persisted input is the existing
`SettingsStore.themePreference`; it writes nothing.

## Core

  - `ChromeColorRole.swift` — the closed role enumeration: a `public enum`,
    `String`-raw-valued, `CaseIterable`, `Hashable`, `Sendable`, **twenty-one**
    cases in six groups — backgrounds (`bgCanvas`, `bgPanel`, `bgEditor`,
    `bgPopover`), text (`textPrimary`, `textSecondary`, `onAccent`), lines and
    accent (`hairline`, `accent`, `accentTint`, `accentTintStrong`), row and
    line states (`hoverTint`, `selectionInactive`, `currentLine`,
    `bracketMatch`), status (`statusGreen`, `statusRed`, `statusYellow`) and
    diff and merge (the three backgrounds). A role names a **meaning**; it
    carries no colour at all, which is what keeps Core Foundation-only and
    portable, and is the same split `FileIconColor` already makes. **The set is
    closed on purpose.** The sweep that follows adds *views*, never roles: a
    surface that appears to need a twenty-second role has found a design
    question, and the answer is to reuse an existing role or to change the
    design — not to grow the table, which would end as one role per call site
    and no design system at all. Several roles are consequently still
    *unused*: the first part left ten of them so (`bgCanvas`, `bgPopover`,
    `onAccent`, `accentTint`, `currentLine`, `bracketMatch`, `statusGreen`,
    `diffAddedBackground`, `diffRemovedBackground`, `conflictBackground`); the
    second part spent two of those — `onAccent` on the consent strip's
    confirming action and `accentTint` on the minimap's viewport fill — and the
    third spent two more: `bgCanvas` on the window root, which is the surface
    the role was named for, and `statusGreen` on the pull-request indicator's
    checks mark, which completes the status trio. That leaves **six**.
    `bgPopover` waits for the popovers (the two switchers' among them, parts
    four to six); the three diff/merge grounds wait for the surfaces that mean
    them;
    and **`currentLine` and `bracketMatch` are deliberately still unused** — both
    belong to the *code* zone, whose overlays are temporary text attributes on the
    editor's own theme (`SyntaxTheme`), so spending them is a decision about where
    the chrome ends rather than a restyle. They are declared nonetheless, because
    the table is the design rather than an inventory of today's call sites. The raw values are the stable names the
    gating suite and the palette test speak; renaming one is a documentation
    change as much as a code change.
  - `ChromeGeometry.swift` — the chrome's measurements as unscaled point values:
    row height and horizontal padding, the tree's indent step, the maximum
    corner radius, the hairline width, five row/strip/bar heights (the tab
    strip, the vertical tab row, the dock tab row, the **sidebar header** and the
    bottom bar), the **header-or-bar horizontal inset**, the breadcrumb height,
    the bottom bar toggle's side and radius, and the accent indicator's
    thickness. The two insets are deliberately two values: `rowPaddingX` (8) is a
    row's padding *inside its own highlight*, `barPaddingX` (12) is a strip's
    inset *from the window edge* — one measurement drawn on the sidebar header
    and on the bottom bar, not a second spelling of the first. Two
    rules, both load-bearing. **Every token is scaled at its use site**, through
    `InterfaceMetrics.scaled(_:)`: nothing here is pre-scaled and no view
    multiplies a token by anything of its own, because the interface zoom's
    half-point rounding only composes correctly when it is applied once, at the
    end (`core-zoom.md`). **The one stated exception is `hairlineWidth` on an
    AppKit code-zoom surface** — today `LineNumberRulerView`, which draws the
    gutter's right-hand rule from the token unscaled. A hairline is one point by
    definition, the thinnest rule the chrome draws rather than a measurement that
    grows with the interface, and a code-zoom surface has no `InterfaceMetrics`
    to ask in the first place: the interface scale is a different zone from the
    one that ruler lives in. The next AppKit chrome surface follows this
    precedent rather than inventing a second answer. And **there is no font size
    here, and there will not be
    one**: the chrome's type scale already exists as `InterfaceTextStyle` —
    `.body` is 13, `.callout` 12 and `.subheadline` 11, exactly the three sizes
    the chrome draws with — reached through `InterfaceMetrics.font(_:)` /
    `scaledFont(_:)`. A second table of those numbers would be a second opinion
    about them, so `ChromeGeometry` carries none.
  - `ChromeAppearance.swift` — `dark` / `light`, and no third value: the palette
    holds one dark and one light entry per role, so this is the whole question a
    colour resolution has to answer. `resolved(_:systemPrefersDark:)` maps a
    `ThemePreference` onto it, the caller supplying the answer `.system` does not
    carry, which keeps the mapping total. It is the **third** instance of a
    signature this repository already spells twice —
    `MarkdownPreviewTheme.resolved(_:systemPrefersDark:)` and
    `LeetCodeStatementDocument.Theme.resolved(_:systemPrefersDark:)` — and is
    kept identical on purpose.
  - `TreeRowState.swift` — what a project-tree row is currently *showing*:
    `plain`, `hover`, `selectedFocused`, `selectedUnfocused`, `dropTarget`, and
    the one total function `state(isSelected:isWindowKey:isHovering:
    isDropTarget:)` that orders four facts that can all be true at once. The
    precedence, highest first: **drop target** (it answers the only question
    being asked while a drag is in flight, and hover is necessarily true at the
    same moment, so anything above it would hide it), then **selection** —
    focused or unfocused by whether the window is key, outranking hover so a
    selected row stays legible as selected while the pointer passes over it —
    then **hover**, then **plain**. The two derived definitions are the caller's
    to supply and this rule only orders them: **"selected" means the row's file
    is the currently active editor tab's file** (there is no click-to-select in
    the tree, and a folder is never selected), and **"focused" means the window
    is key**.

## App

### The palette — `ChromePalette.swift`

The one place a chrome colour is spelled, and the one file in the gated set
allowed to spell a hex literal at all.

`Entry` is one row of the table: a `dark` value, a `light` value and the `alpha`
**both** are drawn at — a single alpha rather than one per appearance, because
the translucent roles are *washes*, and a wash is the same wash over either
background; two alphas would be two opinions about one design decision. The
alpha is a `UInt8` defaulting to `0xFF`, the byte the design's eight-digit values
carry in their last position, so the table spells the design's numbers verbatim
(`0x22`, `0x33`, `0x0A`, `0x26`) rather than a fraction rounded away from them;
each accessor divides by 255 where it builds a colour (`Entry.opacity`).

`entry(for:)` is an **exhaustive `switch role` with no `default`**. That is the
point: a role added to Core without a pair here is a *compile* error, rather
than a colour silently falling back to something plausible. What no compiler can
see is a pair that is simply wrong — a digit transposed, a dark value written on
the light side, an alpha left at `1` on a wash — so `ChromePaletteTests` (app
bundle, since the palette lives in the app target) restates the whole table and
compares component by component; the duplication *is* the test.

**One row has changed since the table was first written.** `selectionInactive`
was `dark: 0x34363B, light: 0xF0F0F2` — byte for byte the pair `currentLine`
carries — and is now `dark: 0x3C3F46, light: 0xE2E2E7`, a deliberate step
stronger, because the design states that value. **No symptom was visible, and
the change must not be recorded as if one had been**: `selectionInactive` has
exactly one consumer — `ProjectTreeView.swift`'s `TreeRowBackground.role(for:)`,
`case .selectedUnfocused`, a project-tree row selected while its window is not
key, never an editor text selection — and `currentLine` is painted by *nothing
at all*, its only occurrences being its declaration, its palette row and the
comment on the row above it. The two have therefore never shared a surface, and
the only thing that looks different after the change is one tree row's
background. What `ChromePaletteTests` states —
`testTheInactiveSelectionWashIsNotTheCurrentLineWash`, asserted in both
appearances through `ChromeTheme` and through the concrete AppKit colours — is a
rule about the *future*: whoever adds a current-line highlight must not let it
arrive in the selection's own wash. It is written as the property rather than as
the new numbers, so it survives a later palette change; the restated row carries
the new pair beside it. A second assertion,
`testTheInactiveSelectionRowNamesTheFileThatPaintsIt`, keeps the row's comment
honest the only way a comment can be kept honest — it names a *file*, and the
test checks that the file still paints the role and that the comment still names
it. That is why the row's comment was rewritten from a symptom into a consumer:
a symptom is unfalsifiable prose, a file name is an assertion. Its **two halves
read different text**, because they ask different questions: the half about the
palette's own comment reads the palette **raw** (stripping would delete its
subject), while the half that finds the painting site reads every other file
**comment- and literal-stripped** and keys on the **construct that makes the role
a colour** — a role-producing `return`, or the role handed to a `color` call —
never on the bare name. Keyed on the bare name over raw text, as it first was, it
could not see the defect it is named for: deleting
`case .selectedUnfocused: return .selectionInactive` from `ProjectTreeView.swift`
while any prose in that file still spelled the role left the wash painted by
nothing and the suite green. Both changes are load-bearing — stripping alone
would still be satisfied by a live mention that paints nothing — and the pair was
checked by removing that one `case` under a surviving mention and watching the
test go red. `conflictBackground` was checked against the same design while this
row was being changed and was **already correct**
(`dark: 0xC9A35C, light: 0xA67C2E, alpha: 0x26`), so it is untouched. No gating
rule is added by any of this: `ChromeThemeSourceGatingTests`' rule count is
unchanged, as is the sentence in `CLAUDE.md` that mirrors it.

`textPrimary`, `textSecondary` and `accent` each carry a short comment
recording that the **code zone's own theme states the same values** — for its
body-text weight, its secondary weight and its label colour. That is two layers
agreeing about a weight, not duplication: the chrome palette must not gain a
syntax entry and the syntax table must not start reading a role. The
counterpart sentence is in `SyntaxTheme.swift` (`app-editor-overlays.md`), so a
reader arriving from either side finds it.

Three accessors, one table:

  - `nsColor(_ role:)` — the **AppKit bridge**: a *dynamic* `NSColor` built on
    `PlatformColor.dynamic(light:dark:alpha:)`, the primitive already in the
    tree (`SyntaxTheme`'s own colours are built the same way). This is why **no
    AppKit view in the chrome caches a resolved colour and none watches for a
    *colour* change by hand**: the Theme preference is applied as
    `.preferredColorScheme` at each SwiftUI window root, which sets that window's
    `NSAppearance`; every `NSView` inside inherits it, and a dynamic colour asked
    to draw under the new appearance answers the new value. A view that resolved
    a colour once into a stored property would freeze whichever appearance
    happened to be current, and would then need an observer to un-freeze it — two
    mechanisms where the platform already provides one. **That is a rule about the
    value, not about the drawing**: a dynamic colour resolves whenever the
    drawing happens, so a chrome view that asks for one every time it paints
    needs no cached value and no colour-specific observer of any kind. The
    chrome's AppKit surfaces divide by what they hand AppKit, not by what they
    need: the editor pane and the read-only viewer pane set a `backgroundColor`
    and let AppKit fill it; the gutter (`LineNumberRulerView`, which as an
    `NSRulerView` has no `backgroundColor` to set) and the minimap fill their
    own background inside their own drawing. The gutter overrides
    `viewDidChangeEffectiveAppearance()` nowhere, and it was **measured**
    recolouring live in both directions — the application built from this
    branch, the Theme preference following the system, the *system* appearance
    switched under the running window with no relaunch, the gutter strip and
    the editor pane strip beside it agreeing on the new colour and then on the
    old one again. `MinimapView` does carry such an override; whether it is
    required there or redundant **was not established** — it predates this
    sweep, nothing in this project executes an appearance change, and nothing
    measured that view. It stays until something does. Asserting either way
    would be an argument where the only evidence is about the gutter.
  - `nsColor(_ role:in:)` — the **concrete** `NSColor` of one appearance, for the
    sites that are not drawing (the palette test reads components) or that have
    already been handed an appearance to resolve against. Drawing code asks the
    dynamic form.
  - `color(_ role:in:)` — the SwiftUI `Color` of one appearance, composed from
    the same row rather than converted from an `NSColor`.

### The SwiftUI path — `ChromeTheme` + `ChromeThemeEnvironment.swift`

`ChromeTheme` is an `Equatable` value carrying the **resolved**
`ChromeAppearance` and one method, `color(_ role:)`. Carrying the appearance
rather than a set of dynamic colours is the whole reason a Theme change
recolours the chrome live: flipping the preference changes the environment
value, which invalidates every view that declared `@Environment(\.chromeTheme)`.
A theme holding dynamic colours would compare equal across the change and
nothing below it would redraw.

`ChromeThemeEnvironment.swift` is deliberately `InterfaceScaleEnvironment.swift`
modifier for modifier — the two are applied side by side at every root, and a
reader who has understood one has understood this one. It declares the
`EnvironmentKey` (resting default: the **dark** theme, so an unswept view or a
preview draws something legible rather than nothing), the `\.chromeTheme`
accessor, and `.chromeThemed(_:)`, a `ViewModifier` taking the observed
`SettingsStore` so a Preferences edit re-evaluates the root with no relaunch.
`ThemePreference.system` carries no appearance by itself, so the modifier reads
`@Environment(\.colorScheme)` — and that is the one case that reads it. Under
`.system` the root's `.preferredColorScheme(nil)` forces nothing, so the window
keeps following the system and `\.colorScheme` reports the system's own answer,
which is exactly what `.system` means. The two forced preferences resolve
without consulting it, so what `\.colorScheme` reports under them cannot change
the result — which is the whole argument, since a forced preference *does* set
the window's appearance and that appearance *does* propagate down to every view
in the window, the modifier included. `SettingsStore.chromeTheme(systemPrefersDark:)` exists for the
same reason `SettingsStore.interfaceMetrics` does: a root that applies
`.chromeThemed(self)` cannot read the value it just injected.

**The roots.** `.chromeThemed(_:)` is applied at exactly the eight roots that
already carry `.interfaceScaled(_:)`, and the gating suite asserts the two sets
are one by reading `ZoomSourceGatingTests.interfaceScaledRoots` rather than
restating it — the two modifiers answer the same question ("is this a SwiftUI
root?"), so a root that gains one and forgets the other must fail in exactly one
place. Applying the modifier below a root would not be wrong so much as
meaningless: the value is inherited by construction, sheets and popovers
included.

### The surfaces restyled so far

The sweep's running record. Each entry names the file, the path it took
(environment, AppKit bridge, or geometry/row state) and the document holding its
full entry; what is **not** listed here has not been swept.

#### Part one — the tab strip, the gutter, the tree rows

  - **The horizontal tab strip** — `TabStripView.swift`, the environment path.
    Full entry in `app-window.md`.
  - **The line-number ruler** — `LineNumberRulerView.swift` (plus one method in
    `CodeEditorView.swift`), the AppKit bridge path. Full entry in
    `app-editor-overlays.md`. The ruler has a second instance, in the read-only
    out-of-project definition window, and it carries the editor background with
    it: `SourceViewerContent.swift` paints its pane in `bgEditor` too, so the
    gutter and the text beside it agree there as well — and that is the only
    thing of that window which is themed, the rest of its chrome still awaiting
    the sweep.
  - **The project tree rows** — `ProjectTreeView.swift` and
    `ProjectTreeDraftField.swift`, the geometry and row-state path. Full entry in
    `app-window.md`. One row state is painted without a role of its own: a
    `dropTarget` row takes `accent` at **40 % opacity**, resolved at the two row
    sites through `TreeRowBackground.color(for:resolving:)`. The closed set names
    no drop wash, and the design's answer is a stronger reading of the accent
    rather than a twenty-second role: hover, selection and drop are all true at
    the moment a drag sits over a selected row (the pointer is inside it), so the
    drop treatment has to out-read `accentTintStrong`, which it does by being the
    same hue at a heavier wash. An `.opacity(_:)` on a role colour breaks neither
    gating rule — it spells no hex and names no system colour — and the mapping
    takes the theme as a role-to-colour *function* so no view file names the
    theme's type (rule five).

#### Part two — the editor pane's own chrome

The pane the code sits in, taken as one piece, because these four surfaces touch
each other: the column or strip on one side, the breadcrumb and the consent strip
stacked above, the minimap on the other side, and the gutter inside. A part that
restyled one of them alone would have shipped a boundary where two grounds
disagree.

  - **The gutter's corrected fill** — `LineNumberRulerView.swift`, the AppKit
    bridge path, and the one *regression* in the sweep so far rather than a new
    surface: part one gave the ruler a background of its own and filled the
    rectangle it was **handed**, which for an `NSRulerView` is the rectangle it
    was asked to redraw and regularly spans the whole editor pane — so the code
    and the minimap were painted out in `bgEditor`. The fill is now clamped by
    the pure `LineNumberRulerView.backgroundRect(in:ruleThickness:)`. Full entry,
    including why no gate in the pipeline could see it, in
    `app-editor-overlays.md`.
  - **The vertical tab column** — `TabListView.swift` and `TabRowView.swift`, the
    environment path. The column states the strip's vocabulary turned through a
    right angle: `bgPanel` ground, **no pane-edge rule at all** — its host is the
    `HSplitView` in `ContentView.editorSplit`, whose splitter already states the
    column/editor boundary, exactly as the gated `ProjectTreeView` beside it in
    the same split view leaves its own — the active row filled `bgEditor` with the
    `accentIndicator`-wide `accent` bar on its **leading** edge rather than
    underneath, `textPrimary` for the active label and `textSecondary` for the
    rest, `hoverTint` for an inactive row under the pointer — which the active row
    does not need, being the one row that is filled — and the monochrome
    `FileIcon` symbol. The two orientations stay two views on purpose: they state
    *different* chrome (a height and a rule under it, the strip's host being a
    `VStack` that draws nothing between its children, versus a width it is given
    and a boundary its splitter states for it), so neither can be a branch inside
    the other. The one thing they
    genuinely share — the trailing slot's three-claimant precedence (hover → close
    mark, else dirty → dot, else active → close mark) — is shared as **one view**,
    `TabStatusMark` in `TabStripView.swift`, so the two cannot drift into two
    rules. The strip's own rendering is unchanged by that extraction. Full entry
    in `app-window.md`.
  - **The breadcrumb** — `BreadcrumbBarView.swift`, the environment path, and the
    one surface of this part that needed a **file of its own**: it was a private
    view inside `ContentView.swift`, which is full of system semantic colours for
    surfaces later parts will reach, and gating rule one is per *file*. Lifting it
    out is what let it join the gated set now instead of waiting for its host. It
    is also the first gated surface that had to stay **both `.equatable()` and
    live**: the strip exists to keep a symlink-resolving path walk off the typing
    path, so it compares its inputs — but a view that compares only
    `(fileURL, projectRoot)` would hold yesterday's colours until the tab changed.
    The answer is two views in one file: a thin outer one reading
    `@Environment(\.chromeTheme)` and handing the inner, equatable one the
    resolved `ChromeAppearance` as a stored property beside `metrics`, with a
    hand-written `==` over the four so a later property cannot quietly drop one.
    The appearance is an **equality term, not a colour source** — the body still
    reads `theme.color(_:)` from the environment — which is why neither view names
    the theme's type and rule five is untouched. It draws `bgPanel`, its own bottom
    hairline (so its host's `Divider()` could go, as the tab strip's host already
    had none) and the path as **one** `Text` composed by `+`: the last segment
    `textPrimary`, every leading segment and every `›` separator `textSecondary`.
    One run rather than an `HStack` of labels because middle truncation over a
    single string is what keeps the file name visible in a narrow window. Full
    entry in `app-window.md`.
  - **The minimap's own chrome** — `MinimapView.swift`, the AppKit bridge path,
    and the surface that states the chrome/code boundary most sharply: its
    background is `bgEditor` (it sits beside the text and must agree with it) and
    its viewport indicator is `accentTint` filled, `accentTintStrong` stroked —
    each wash carrying its own opacity in the table, so the view composes no alpha
    of its own. The **runs are not chrome**: they are a rendering of the code, so
    they stay with `SyntaxTheme` for exactly the reason the syntax highlighting
    does, and `drawTokens`/`MinimapTokenizer` are untouched. Full entry in
    `app-editor-overlays.md`.
  - **The language-server consent strip** — `LSPConsentBanner.swift`, the
    environment path. One `strip(_:)` helper gives all three questions one ground
    (`bgPanel`) and one bottom rule (a `hairline` rectangle, not a `Divider()`,
    which would be drawn in the *system's* separator value and so disagree with
    the `hairline` rules beside it in either appearance). The
    question line is `textPrimary`; the explanatory caption and the runtime-network
    note are `textSecondary`, being the same kind of fact; the leading symbol is
    `accent`. The two actions are where the strip states the sweep's rule about
    **mixed looks**: the confirming one is drawn by one private helper — `accent`
    fill, `onAccent` label, `cornerRadiusMax`, padding off `rowPaddingX`, and
    `.buttonStyle(.plain)` — used by all three rows, and the declining one is a
    plain `textSecondary` label button, because a system-drawn button beside an
    accent-filled one is precisely the look this sweep removes. The weight of the
    two buttons is the only thing saying which is the offer, which is honest: both
    answers are non-destructive and reversible from Preferences. No keyboard
    shortcut is added — the reason in that file's own comment (a default button in
    the main window takes Return before the first responder, so every newline
    typed in the file behind the banner would start a download) still holds. Full
    entry in `core-provisioning.md`.

#### Part three — the window's ground, the sidebar's host, the dock and the bottom bar

The frame the swept panes sit in, taken as one piece for part two's reason: the
title bar above, the sidebar's host on one side, the dock below and the bar
under that all meet each other, and a part restyling one of them alone would
have shipped a boundary where two grounds disagree. It spends the two roles the
sweep had left waiting for a surface rather than for a decision — `bgCanvas` and
`statusGreen` — and adds two gating rules (nine and ten) and five files to the
gated set.

  - **The window's ground and its title bar** — `MainWindowChrome.swift`, a new
    file taking the AppKit bridge path through a marker rather than a view's
    body. The title bar is made transparent and the window's background colour
    set to `ChromePalette.nsColor(.bgPanel)`, the *dynamic* colour, so a Theme
    change repaints it with no appearance observer and no cached value; the
    title text and the window buttons are left to the framework, which draws
    them against the window's appearance the content root already sets. The
    ground is `bgPanel` while the content root paints `bgCanvas` on purpose: the
    title bar is the topmost of the window's panel *strips*, sitting directly on
    the tab strip and the sidebar header, and painting it the canvas value would
    draw a band one step off the two surfaces it touches. It is a **sibling** of
    `MainWindowFrameAutosave`, not a change to it — where the window sits and
    what colour it is are unrelated questions, and the frame marker's contract
    and its own gating suite are untouched. It is attached by *chaining* onto
    the frame marker's existing `.background(...)` line, because
    `PisakaApp.swift` sits exactly at its `file_length` ceiling. Full entry in
    `app-shell.md`.
  - **The window root** — `ContentView.swift`, the environment path, reached
    through a `chromeColor(_:)` **role-to-colour function** rather than a stored
    theme: a root cannot read the environment value it writes, so it resolves
    from `SettingsStore.chromeTheme(systemPrefersDark:)` — that seam's first
    consumer — and the function shape keeps the theme's *type* out of the file
    (rule five), part one's `TreeRowBackground.color(for:resolving:)` again. The
    body's root paints `bgCanvas`; the dock's panel slot `bgPanel` with **no
    rule of its own**; and the three empty-state sentences the root draws — "No
    problems", the usages invitation and "No file open" — `textSecondary`. Two
    of these are *regressions* fixed rather than new surfaces, in part two's
    gutter-fill sense: the empty states were platform-coloured text drawn
    outside any named surface, and the two dividers below were filling five
    points of window with the platform's `separatorColor`, which is a
    five-point-wide rule in a value nothing beside it shares.
  - **Both draggable dividers** — `ContentView.swift`. Each now fills `bgPanel`
    and overlays a **one-point** `hairline` rectangle along the edge nearer the
    editor: the dock divider's along its top, the preview divider's along its
    leading side. The five-point drag target, the `contentShape`, the
    hover/drag cursor sync and the whole drag gesture are verbatim — the change
    is what is drawn, not what is dragged. The divider *is* the dock's top
    edge, which is why the panel slot below draws no second rule: two hairlines
    five points apart read as a double rule.
  - **The bottom bar and its toggles** — `ContentView.swift`. The bar takes
    `bottomBarHeight`, a `barPaddingX` inset, a `bgPanel` ground and its own
    one-point `hairline` along its **top** edge, and the `Divider()` the body
    used to place above it is gone (part two's precedent: a `Divider()` is drawn
    in the system's separator value and disagrees with the `hairline` beside
    it). Keeping a rule there at all is a stated deviation from the design,
    which draws none: with the dock closed the editor's ground and the bar's are
    one value apart in the dark theme, so without it the bar would have no
    visible top edge. The **order is reversed** — the three widgets lead, then a
    `Spacer()`, then the six panel toggles and the completion switch — with
    14-point gaps between the widgets and 2 between the toggles, both bare local
    numbers scaled once, because deriving either from a token would couple this
    bar's spacing to a measurement that means something else (rule seven). All
    seven controls became **icon-only squares**: `bottomBarToggleSide` on a
    side, `bottomBarToggleRadius` of corner radius, the icon at `.body`, an
    `accentTintStrong` ground with an `accent` icon when active and no ground
    with a `textSecondary` icon when not. That visual decision is what rule ten
    exists for: the `Label(title, systemImage:)` they carried *was* each one's
    accessibility name, so every one of them now spells `.help(` and
    `.accessibilityLabel(` — nothing misrenders without them, and the only
    reader who notices is the one who cannot see the bar. Full entry in
    `app-window.md`.
  - **The sidebar's host and its header** — `ProjectTreeView.swift`, already
    gated for its rows since part one, so this part added the surface *around*
    them and no file to the set. Both branches of the body — the tree and the
    open-a-folder placeholder pane — draw `bgPanel`; the header is a fixed strip
    of `sidebarHeaderHeight` inset by `barPaddingX`, carrying the open folder's
    name uppercased in `textSecondary` at `.subheadline`/`.semibold` with half a
    point of tracking, a `Spacer()`, and the Refresh button at the trailing end
    with a `textSecondary` icon at `.body`; and the header draws its own bottom
    `hairline` in place of the `Divider()` that used to sit between it and the
    tree. The Refresh button is a **deliberate deviation** — the design draws
    the label alone, and a restyle does not remove a working control. Full entry
    in `app-window.md`.
  - **The bar's three widgets** — `ProjectSwitcherView.swift`,
    `BranchSwitcherView.swift` and `PullRequestIndicatorView.swift`, the
    environment path, each reading `\.chromeTheme` beside `\.interfaceMetrics`.
    The project switcher draws its name `textPrimary` at `.callout`, its folder
    glyph and a new trailing `chevron.down` `textSecondary`; the branch switcher
    draws name, glyph and caret all `textSecondary` at `.callout` and its
    failure line `statusRed`; the pull-request indicator is three elements — a
    leading `arrow.triangle.merge` (the Pull Requests toggle's glyph, now at the
    opposite end of the bar, so the old adjacency argument does not apply),
    `#N`, and a trailing checks mark whose four glyphs are coloured
    `statusGreen` / `statusRed` / `statusYellow` / `textSecondary`, the fourth
    being *no checks*, drawn as the neutral member of the `*.circle.fill` family
    its siblings already use. All three **drop their own paddings** so the bar's
    stated gaps and height are the measurements actually drawn, each keeping
    `.contentShape(Rectangle())` as its click target. Full entries in
    `app-window.md`.

**The caret both switchers gained is an addition, not a restyle**: neither drew
one before, and a control that opens a list should say so. It is recorded here
rather than passed off as a colour change.

**The placeholder pane's ground is a stated divergence.** The open-a-folder pane
draws `bgPanel`, not the window's `bgCanvas`. It reads as one of the places the
window ground shows through, but it is in fact the sidebar's own surface — drawn
by `ProjectTreeView` inside the sidebar's split slot, bounded by the same
divider as the tree it replaces — and a pane whose ground changed with whether a
folder happened to be open would read as a hole in the sidebar rather than as
the window behind it. `bgCanvas` is spent regardless: the window root paints it,
and it shows through at the no-file-open placeholder and the root's own empty
states.

**Inherited work, deliberately left for the popovers' part.** The two switchers'
popovers had their *colours* converted here, mechanically (`.secondary` →
`textSecondary`, `.primary` → `textPrimary`, `Color.accentColor` → `accent`,
`.red` → `statusRed`), with layout, fonts and behaviour untouched — not because
popovers belong to this part, but because gating rule one is per *file* and
these files obey it whole. What was **not** converted is their `Divider()`
calls. A `Divider()` names no colour, so no rule here can see one, and the fix
is not available yet: the ground under those rules is still the platform's
material, on which a `hairline` would be the mismatch rather than the cure. The
part that sweeps the popovers' ground takes the rules with it. Written down here
so that part finds the work rather than rediscovering it.

#### What is still waiting

The six dock panels, the dialogs and sheets, the separate
diff/merge/history/browser windows, the Preferences surfaces and the terminal.
Each follows the six-step guide at the end of this document, on its own, with
`gatedFiles` growing as part of the restyle rather than afterwards.

Two things inside surfaces part three *did* sweep are **deliberately deferred**
rather than forgotten: the bottom dock's own tab row, which is chrome the dock
panels draw and so belongs with them, and the caret readout beside it. Both wait
on a design decision rather than on a file — which is also why
`ChromeGeometry.dockTabRowHeight` stays declared and unspent: the token states
the measurement the row will draw at, and the table is the design rather than an
inventory of today's call sites. The switcher popovers' rules are inherited work
too; the part-three record above says where.

### The monochrome-icon decision

Every icon in the swept surfaces is drawn in `textSecondary`: the tab strip's
file icon, the vertical column's, the tree's folder and file icons, the draft
field's icon column. `FileIcon` answers a symbol **and** a semantic tint, and these surfaces
deliberately read only the symbol. A column of differently-tinted glyphs
competes for the eye with the one thing each surface actually has to say — the
accent underline on the active tab, the selection wash on the active file's row
— and a tinted icon inside a selected row's wash is two colours arguing. The
tint is not deleted: `FileIconColor` is untouched Core vocabulary and iOS still
paints it. What *is* deleted is the app layer's `color(for: FileIconColor) ->
Color`, whose only two readers were the two tree files that now draw
monochrome.

## The gating suite — `ChromeThemeSourceGatingTests`

In `ZoomSourceGatingTests`' mould: it reads `Sources/` through `#filePath` with
Foundation only, so it runs in `swift test` with no Xcode build, and it matches
against `LSPSourceGatingTests.strippingCommentsAndStringLiterals(_:)` output —
**comments and string literals stripped before anything is matched**. That is
load-bearing rather than tidy here: the gated files document their own rules at
length (the palette explains what a hex literal outside it would cost; the strip
names the accent colour it no longer uses in order to say so; the ruler spells
`textSecondary` in prose), so a raw `contains` would stay green while the code it
names was deleted.

The **gated set** — asserted by set equality in both directions, so a renamed or
deleted file fails rather than quietly losing its coverage:
`ChromePalette.swift`, `ChromeThemeEnvironment.swift`, `TabStripView.swift`,
`LineNumberRulerView.swift`, `ProjectTreeView.swift`,
`ProjectTreeDraftField.swift` — the first part's six — plus the second part's
five: `TabListView.swift`, `TabRowView.swift`, `BreadcrumbBarView.swift`,
`MinimapView.swift`, `LSPConsentBanner.swift` — plus the third part's five:
`MainWindowChrome.swift`, `ContentView.swift`, `ProjectSwitcherView.swift`,
`BranchSwitcherView.swift`, `PullRequestIndicatorView.swift`, **sixteen** in
all. `ProjectTreeView.swift` is not among the third part's additions because it
was already there: part three restyled the surface *around* the rows part one
had swept, and a file joins this set once. The draft field is in the set
although it is an editing affordance rather than a row: an inline draft
*replaces* a tree row on screen and must read identically to the row it stands in
for. `TabStripView.swift` covers `TabStatusMark` too, the slot view the two
orientations share, which is why that extraction did not add a seventh file.

The ten rules, each invisible to the compiler:

1. **No gated view names a system semantic colour.** A closed forbidden-token
   list — AppKit's semantic set (`labelColor`, `separatorColor`,
   `controlBackgroundColor`, the `system…` hues, …) plus SwiftUI's
   `accentColor`/`primary`/`secondary`/`tertiary` — and, for the **views** only,
   SwiftUI's named hues. They compile, they look plausible in whichever
   appearance the reviewer happens to be in, and they desert **the palette** —
   not the preference. A system semantic colour is itself dynamic, resolved
   against the window's `NSAppearance`, which is precisely what
   `.preferredColorScheme` at the window root sets, so it tracks the Theme
   preference exactly as a role does; what it carries is the platform's value
   rather than the table's, so a view naming one draws a step off the roles
   beside it in *either* appearance, which is the whole reason the roles exist. Two narrow carve-outs: the palette is exempt from the
   *hue* half alone, because `red`/`green`/`blue` are argument labels of
   `Color(.sRGB, red:green:blue:opacity:)`; and lines constructing a `FileIcon(`
   are dropped before matching, because `FileIconColor`'s cases collide with the
   hue names and a `FileIconColor` is the third exemption read from the other
   side. `clear` is deliberately allowed — it is the absence of a colour, and a
   row that paints nothing when it is in no state is saying exactly that.
2. **No hex literal outside the table.** A `0x[0-9A-Fa-f]{6}` match over the
   stripped source of every gated file, asserted by set equality against
   `["ChromePalette.swift"]` — in both directions, because a *second* speller is
   a colour nothing can re-theme and a palette that has stopped spelling any is a
   table that has stopped being one.
3. **The three exemptions stay exemptions**, disjoint from the gated set and
   still present in the tree: `SyntaxTheme.swift` (a token-kind colour table
   belongs to the *code* zone, which is the editor's own theme, not the chrome's
   design system), `TerminalTheme.swift` (an ANSI-16 palette is a protocol's
   vocabulary — the numbers mean what the escape sequences say, and a role cannot
   stand in for one) and `FileIcon.swift` (a Core semantic token iOS still
   paints, so it cannot move behind a macOS-only palette).
4. **The theme is injected at the interface scale's own roots**, read from
   `ZoomSourceGatingTests.interfaceScaledRoots` rather than restated (see above).
5. **No view constructs a theme inline.** `ChromeTheme(` appears only in
   `ChromeThemeEnvironment.swift`; the *type name* appears only there and in
   `ChromePalette.swift`, where it is declared. The two sets are checked
   separately because the wider one is the one a view would first join. A view
   building its own theme reads the preference once and then stops hearing about
   it.
6. **The gutter's fill still goes through its own rule.**
   `LineNumberRulerView.swift` spells `backgroundRect(` exactly twice — the rule
   and the one call site that spends it — and its `drawHashMarksAndLabels(in:)`
   may not fill the bare rectangle it was handed. That one line is the
   regression this part exists to fix: it paints the code and the minimap out in
   `bgEditor` while the seam's own tests, `swift test`, the app bundle and
   SwiftLint all stay green. A seam pins nothing its call site does not spend.
7. **No gated view derives a geometry value by arithmetic on a token.** A
   `ChromeGeometry` token on either side of an operator from a number — a
   padding written as half a row-padding token, say — is matched in both
   directions, `CGFloat(…)` around it included. Nothing misrenders: the cost is
   a coupling nothing names, so the day the other token moves this one moves
   with it. A surface's own measurement is a bare local number. A token combined
   with a *layout* value is deliberately not matched — `ruleThickness -
   hairlineWidth` composes a position out of a width the drawing code was
   handed, and inventing no second design value is the whole difference.
8. **The tab icon rule is spelled once.** `struct TabFileIcon` and the
   untitled-buffer fallback it carries — an `OpenFile` with no url asked about
   under its `displayName` — are declared in `TabStripView.swift` and nowhere
   else, both halves by set equality, because that fallback was pasted into both
   orientations once already. The paste had a second cost read from the other
   side: rule one drops every line naming `FileIcon(`, so each copy bought
   itself a line exempt from the no-system-colour check — which is why the gated
   files carrying such a line are themselves a counted set of three
   (`ProjectTreeView.swift`, `ProjectTreeDraftField.swift`,
   `TabStripView.swift`).
9. **The window's chrome is configured in one file.**
   `titlebarAppearsTransparent` is spelled in `MainWindowChrome.swift` and
   nowhere else under `Sources/`, by set equality in both directions. It is a
   property of the *window* rather than of a view tree, so whoever sets it last
   wins and two setters would compete silently — the title bar's ground decided
   by whichever marker reached the window first. The other direction matters
   just as much: the transparency is what reveals the window's background
   colour, so a *removed* setter hands the strip back to the framework's own
   material.
10. **Every bottom-bar toggle is identifiable without sight.** Inside
   `ContentView.swift`, the brace-matched bodies of `bottomBarButton(` and
   `completionToggleButton` each spell `.help(` and `.accessibilityLabel(`, and
   `bottomBarButton(` occurs exactly seven times — one declaration and one call
   per bottom dock panel. Part three made all seven controls icon-only, and the
   `Label(title, systemImage:)` they used to carry *was* each one's
   accessibility name; an `Image(systemName:)` supplies none, and `.help(` is a
   tooltip VoiceOver does not read as a name. So the visual decision silently
   turns named controls into unlabelled buttons: nothing misrenders, no other
   gate goes red, and the only reader who notices is the one who cannot see the
   bar. The bodies are read brace-matched, in rule six's idiom, so a `.help(`
   elsewhere in a fourteen-hundred-line file cannot satisfy it; the call count
   is pinned so a seventh dock panel is asked the question rather than shipping
   nameless.

Plus a **self-check** in the suite's own idiom: every gated file must actually
*name* a `ChromeColorRole`, or the checks above have gone vacuous — with one
exception, `ChromeThemeEnvironment.swift`, which carries the appearance down the
tree and paints nothing, so it names no role by construction while staying gated
for the two rules it *can* break.

And, beside the rules rather than among them, a **cross-file count**: the suite
counts its own numbered rule markers and asserts that both summaries of it — the
list above and `CLAUDE.md`'s chrome-theme invariant — spell that number in the
sentence naming it, and that the list above enumerates exactly that many items
in order. It gates no source file; it exists because both summaries had already
drifted, each correct on the day it was written, and a count that drifts tells a
reader the sweep is smaller than it is while omitting the newest rules. Same
shape as `LintConfigurationTests`' style-version pair: one source of truth, every
document spelling it checked against that.

The values themselves are pinned in the app bundle instead
(`ChromePaletteTests`), the palette being an app-target file.

## The sweep guide — moving the next surface onto the roles

Each further surface is restyled on its own, in the same six steps:

1. **Find its colour sites.** Every `Color`, `NSColor`, `.foregroundStyle`,
   `.background`, `setFill`, tint and `opacity(...)` wash in the file.
2. **Map each one to a role**, from the table in `ChromeColorRole.swift`. A
   background asks which *kind* of surface it is — canvas (the window's ground),
   panel (a dock, a side pane, a bar), editor or popover; text asks which of the
   two chrome weights it is, or `onAccent` when it is drawn on the accent itself;
   a wash asks which state it expresses.
3. **Move its numbers onto `ChromeGeometry`**, scaled at the use site through
   `metrics.scaled(_:)`. A number that is genuinely the surface's own — the
   tree's chevron column, say — stays local, in a type that says so; a number
   that is a *chrome* measurement (a row height, a padding, a hairline) is a
   token or it is a drift waiting to happen. The one exception to the scaling
   half is `hairlineWidth` on an **AppKit code-zoom surface**, which has no
   `InterfaceMetrics` to ask and draws it unscaled — one point being what a
   hairline is (see the `ChromeGeometry` entry above, and `LineNumberRulerView`,
   which set the precedent).
4. **Draw its text with `metrics.font(_:)` / `scaledFont(_:)`**, from
   `InterfaceTextStyle` — `.body` (13), `.callout` (12), `.subheadline` (11). Do
   not add a size to `ChromeGeometry`.
5. **Add the file to `ChromeThemeSourceGatingTests.gatedFiles`**, as part of
   restyling it rather than afterwards.
6. **Run `swift test`** (the gating suite) **and the app-layer bundle** (the
   palette values plus whatever app-side suite that surface has).

**When a surface seems to need a role that does not exist, it does not.** The
set is closed. Either an existing role means what the surface is trying to say —
which is usually the discovery, once the question is phrased as a meaning rather
than as a colour — or the surface's design is making a distinction the chrome
has decided not to make, and that is a design question to raise, not a table to
grow.

An AppKit surface takes the bridge (`ChromePalette.nsColor(_:)`, dynamic, no
caching, no colour observer); a SwiftUI
surface takes
`@Environment(\.chromeTheme)` and asks `theme.color(_:)`. A surface whose root
is a new window gains `.chromeThemed(settings)` beside `.interfaceScaled(...)` —
and rule four will say so if it does not.

**The no-product-names convention and the plan archive.** Every document, comment
and commit message in the live tree names what a thing *is* rather than the
competing tool it resembles; this sweep's own parts cleared the last references
the live tree held. `docs/plans/completed/` is **deliberately exempt**, file
names included: it is a historical record of what was decided and when, and
rewriting it would make the record disagree with the reviews, tickets and commit
messages that quote it. A sweep of the live tree that leaves the archive alone
is complete, not partial — raising the archive's remaining names is answered
here rather than re-opened.
