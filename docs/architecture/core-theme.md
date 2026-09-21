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
the eight roots that already inject the interface scale. Three surfaces are
restyled end to end in this part — the horizontal tab strip, the line-number
ruler and the project tree rows — and every other surface is deliberately
untouched, waiting for the sweep described at the end of this document.
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
    and no design system at all. Ten roles are consequently *unused* by the
    three surfaces restyled first (`bgCanvas`, `bgPopover`, `onAccent`,
    `accentTint`, `currentLine`, `bracketMatch`, `statusGreen`,
    `diffAddedBackground`, `diffRemovedBackground`, `conflictBackground`); they
    are declared nonetheless, because the table is the design rather than an
    inventory of today's call sites. The raw values are the stable names the
    gating suite and the palette test speak; renaming one is a documentation
    change as much as a code change.
  - `ChromeGeometry.swift` — the chrome's measurements as unscaled point values:
    row height and horizontal padding, the tree's indent step, the maximum
    corner radius, the hairline width, four row/strip/bar heights, the bottom
    bar toggle's side and radius, and the accent indicator's thickness. Two
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

Three accessors, one table:

  - `nsColor(_ role:)` — the **AppKit bridge**: a *dynamic* `NSColor` built on
    `PlatformColor.dynamic(light:dark:alpha:)`, the primitive already in the
    tree (`SyntaxTheme`'s own colours are built the same way). This is why **no
    AppKit view in the chrome caches a resolved colour and none observes an
    appearance change by hand**: the Theme preference is applied as
    `.preferredColorScheme` at each SwiftUI window root, which sets that window's
    `NSAppearance`; every `NSView` inside inherits it, and a dynamic colour asked
    to draw under the new appearance answers the new value. A view that resolved
    a colour once into a stored property would freeze whichever appearance
    happened to be current, and would then need an observer to un-freeze it — two
    mechanisms where the platform already provides one.
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

### The three surfaces restyled here

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

### The monochrome-icon decision

Every icon in the three swept surfaces is drawn in `textSecondary`: the tab
strip's file icon, the tree's folder and file icons, the draft field's icon
column. `FileIcon` answers a symbol **and** a semantic tint, and these surfaces
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
`ProjectTreeDraftField.swift`. The draft field is in the set although it is an
editing affordance rather than a row: an inline draft *replaces* a tree row on
screen and must read identically to the row it stands in for.

The five rules, each invisible to the compiler:

1. **No gated view names a system semantic colour.** A closed forbidden-token
   list — AppKit's semantic set (`labelColor`, `separatorColor`,
   `controlBackgroundColor`, the `system…` hues, …) plus SwiftUI's
   `accentColor`/`primary`/`secondary`/`tertiary` — and, for the **views** only,
   SwiftUI's named hues. They compile, they look plausible in whichever
   appearance the reviewer happens to be in, and they desert the palette the
   moment the Theme preference disagrees with the system one, which is the whole
   reason the roles exist. Two narrow carve-outs: the palette is exempt from the
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

Plus a **self-check** in the suite's own idiom: every gated file must actually
*name* a `ChromeColorRole`, or the checks above have gone vacuous — with one
exception, `ChromeThemeEnvironment.swift`, which carries the appearance down the
tree and paints nothing, so it names no role by construction while staying gated
for the two rules it *can* break.

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
caching, no appearance observer); a SwiftUI surface takes
`@Environment(\.chromeTheme)` and asks `theme.color(_:)`. A surface whose root
is a new window gains `.chromeThemed(settings)` beside `.interfaceScaled(...)` —
and rule four will say so if it does not.
