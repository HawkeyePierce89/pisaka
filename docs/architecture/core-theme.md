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
part shipped; the third took the frame those panes sit in (the window's ground,
the sidebar's host, the dock and the bottom bar); and part four (a) gave the
dock its own tab row and moved the Problems, Usages and Terminal panels onto the
roles; part four (b) finished the dock with the Log (its filter bar and graph
gutter), Local Changes and Pull Requests panels, plus the side-by-side diff pane
and the unified diff's wash. The running record is
["The surfaces restyled so far"](#the-surfaces-restyled-so-far) below; every
surface not named there is deliberately untouched, waiting for the sweep
described at the end of this document.
`ChromeThemeSourceGatingTests` (`swift test`) pins which files obey the rule,
`ChromeThemeTests` (`swift test`) pins the Core vocabulary itself — the role set,
the geometry tokens, the appearance resolution, the tree row's states and
`diagnosticRole(for:)` — `ChromeRoleMappingTests` (`swift test`, since part four
(b)) pins the per-feature answers beside it — the changed-file status's letter,
word and role, the pull-request checks' glyph, words and role, and the diff
wash and marker — verbatim over `allCases`, and `ChromePaletteTests` (app
bundle) pins the values themselves.

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
    checks mark, which completes the status trio. That left **six**, and
    part four (a) spent none — its four surfaces are drawn wholly from roles
    already in use. Part four (b) spent the two diff grounds —
    `diffAddedBackground` and `diffRemovedBackground`, on the side-by-side diff
    pane and the unified diff's rows — which left **four**: `bgPopover`,
    `currentLine`, `bracketMatch` and `conflictBackground`. Part five (a) spends
    the fourth — `bgPopover` on the completion panel, the hover popover, the two
    bottom-bar popovers and the Log calendar — which leaves **three**:
    `currentLine`, `bracketMatch` and `conflictBackground`. Part five (b)
    spends `conflictBackground` on the merge panes, through
    `mergeWashRole(for:)`, which leaves **two**: `currentLine` and
    `bracketMatch`. **Both are deliberately still unused** — both
    belong to the *code* zone, whose overlays are temporary text attributes on the
    editor's own theme (`SyntaxTheme`), so spending them is a decision about where
    the chrome ends rather than a restyle. They are declared nonetheless, because
    the table is the design rather than an inventory of today's call sites. The raw values are the stable names the
    gating suite and the palette test speak; renaming one is a documentation
    change as much as a code change.
    **`diagnosticRole(for:)` — the chrome's one severity answer**, moved here in
    part four (a) from `LineNumberRulerView`, unchanged in its four answers:
    error → `statusRed`, warning → `statusYellow`, information → `accent` (the
    chrome has exactly one blue, and a notice is what the accent is for), hint →
    `textSecondary` (a hint is a remark rather than a condition, drawn in the
    tone of the line numbers beside it). It is total over the closed
    `DiagnosticSeverity` set and deliberately **not** `SyntaxTheme`'s table: the
    squiggle under the text is the code zone and stays on
    `SyntaxTheme.diagnosticColor(for:)` alone. Two surfaces read this one — the
    gutter's severity dot and the Problems panel's header badges and row glyphs —
    and neither keeps a table of its own. Both types already lived in Core, so
    the move cost nothing and let the Core gate see the mapping for the first
    time: `ChromeThemeTests` pins the four answers verbatim and that they are
    pairwise distinct roles, while the app bundle's `GutterFoldTests` keeps the
    half only it can see — the four *resolved* colours pairwise distinct under
    both appearances. Gating rule fifteen keeps a second table from coming back.
    **Three more one-answer mappings** joined it in part four (b), each in the
    same extension, each total over a closed Core set, each pinned verbatim over
    `allCases` by `ChromeRoleMappingTests` (`ChromeThemeTests` pins only the part's
two new geometry tokens) and each with its readers pinned by a gating
    rule (seventeen to nineteen): `changedFileRole(for: FileStatus)` — added
    `statusGreen`, modified and renamed `statusYellow`, deleted and conflicted
    `statusRed`, untracked `textSecondary` — beside `FileStatus.letter` and
    `spokenName` (`core-git.md`), so the letter carries the identity and the
    colour the weight; `checksRole(for:)` over `GitHubChecksSummary` (noChecks
    `textSecondary`, pending `statusYellow`, failure `statusRed`, success
    `statusGreen`) and over `GitHubCheckBucket` (pass `statusGreen`, fail
    `statusRed`, pending `statusYellow`, skipping and cancel `textSecondary`),
    beside the summary's `symbolName`/`spokenWords` and the bucket's `spokenWords`
    alone — the job row draws a dot, not a glyph (`core-github.md`); and the
    diff wash — `diffWashRole(for: DiffRowKind, side: DiffSide)` (unchanged
    nil; on the old side removed and modified `diffRemovedBackground`, added
    nil, the plain filler row; on the new side added and modified
    `diffAddedBackground`, removed nil), `diffWashRole(for: UnifiedDiffLine.Kind)`
    (context nil, removed and added their grounds) and
    `diffMarkerRole(for:side:)` (`statusRed` on the old side for removed and
    modified, `statusGreen` on the new side for added and modified, nil
    otherwise). `DiffSide` is Core's one diff-side type (`core-diff-merge.md`).
    **Part five (b) added the fourth, the merge wash** —
    `mergeWashRole(for: MergeLineKind) -> ChromeColorRole?` over the vocabulary
    that moved into Core verbatim from `MergeView.swift` (`core-diff-merge.md`):
    `ours`, `theirs` and `conflictUnresolved` map to `conflictBackground`,
    `conflictResolved` to `diffAddedBackground`, `plain` to nil. **One wash, not
    two**: the design draws the differing lines of the two read-only panes and
    the unresolved region of the result pane identically, and it is the *pane*
    — ours, result, theirs, each titled — that tells them apart, so a second
    conflict colour would be a distinction the layout already makes. The view
    derives which line is which kind; Core owns the vocabulary and the mapping.
    Its tests (`ChromeRoleMappingTests`) are the merge wash's first of any kind:
    every case's answer over `allCases`, and exactly the three conflicted kinds
    reaching `conflictBackground`. Rule twenty-nine pins its one reader,
    `MergeView.swift`.
  - `ChromeGeometry.swift` — the chrome's measurements as unscaled point values:
    row height and horizontal padding, the tree's indent step, the maximum
    corner radius, the hairline width, five row/strip/bar heights (the tab
    strip, the vertical tab row, the dock tab row, the **sidebar header** and the
    bottom bar), the **header-or-bar horizontal inset**, the breadcrumb height,
    the bottom bar toggle's side and radius, since part four (a) a dock panel's
    **header strip** — `panelHeaderHeight` (28) and its inset
    `panelHeaderPaddingX` (14) — and the dock tab row's two insets,
    `dockTabRowPaddingX` (10, the row from the dock's edge) and
    `dockTabLabelPaddingX` (10, a tab's box around its label, the width the
    accent indicator spans), and the accent indicator's
    thickness. The insets are deliberately distinct tokens: `rowPaddingX` (8) is a
    row's padding *inside its own highlight*, `barPaddingX` (12) is a strip's
    inset *from the window edge* — one measurement drawn on the sidebar header
    and on the bottom bar, not a second spelling of the first — and the two dock
    tab insets are two measurements that happen to share a value today, so
    neither is spelled as the other. Part four (b) added a chrome **push
    button's** two: `buttonPaddingX` (10), its horizontal padding, shared by the
    Local Changes toolbar's Commit and the pull-request rows' buttons — a third
    measurement equal in value to the two dock tab insets and deliberately not
    spelled as either — and `buttonCornerRadius` (5). `cornerRadiusMax`'s own
    comment states the rule rather than a list: a chrome surface's corners are
    square or the maximum, and each small control's radius is a token of its own,
    never one computed from it (a list of them fell behind twice). `dockTabRowHeight`, declared ahead of its
    surface since part one, is spent since part four (a). Part five (a) added
    the shared field's and the secondary button's five (see the sweep guide), and
    part five (b) three more: `dialogEdgeStripHeight` (44 — the commit dialog's
    header and the merge window's status strip, one measurement on two edges),
    `checkboxSide` (14) and `checkboxCornerRadius` (3), the shared checkbox's box.
    The checkbox's *glyph* is deliberately not a token: exactly one definition
    draws it, so it is a named private constant in `ChromeControls.swift`. Two
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
the change must not be recorded as if one had been**: `selectionInactive` had,
when it changed, exactly one consumer — `ProjectTreeView.swift`'s
`TreeRowBackground.role(for:)`, `case .selectedUnfocused`, a project-tree row
selected while its window is not key, never an editor text selection; part five
(b)'s commit dialog file row paints the same state by *calling* that mapping, not
by naming the role, so the consumer is still one —
and `currentLine` is painted by *nothing
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

### The fourth exemption — `CommitGraphPalette.swift`

The branch graph's lane colours, macOS-gated, and the chrome's **fourth stated
colour exemption** beside `SyntaxTheme`, `TerminalTheme` and `FileIcon` (rule
three). A lane colour is an **identity token, not a chrome meaning** — "this line
is the same branch as that one" — which is the ANSI-16 argument read through a
graph: pressing a lane into `statusRed` or `accent` would make a branch read as an
error or a selection, exactly the misuse the closed role vocabulary exists to
prevent. The design's own two lane colours cannot stand in either: two hues cannot
tell several concurrent branches apart, which is the gutter's whole job.

The table is `ChromePalette`'s shape: an exhaustive `switch` over eight `Lane`
identities with no `default`, each a light/dark `Entry` — blue 0x007AFF /
0x0A84FF, green 0x28CD41 / 0x32D74B, orange 0xFF9500 / 0xFF9F0A, purple 0xAF52DE /
0xBF5AF2, red 0xFF3B30 / 0xFF453A, teal 0x30B0C7 / 0x40C8E0, pink 0xFF2D55 /
0xFF375F, yellow 0xFFCC00 / 0xFFD60A. `nsColor(forLane:)` answers a **dynamic**
`NSColor` through `PlatformColor.dynamic(light:dark:)`, resolved at draw time, so
the gutter caches nothing and watches for no appearance change; the index wraps
modulo eight, negative indices included, as the old palette did.
`CommitGraphView.swift`, its one reader, spells no colour at all and is gated;
this file is exempt, and rule three's disjointness assertion is what refuses the
two sets meeting at that seam. `CommitGraphPaletteTests` (app bundle) restates the
values, asserts each set of eight pairwise distinct, resolves the dynamic colour
under both appearances and pins the wrap at -1 and 8.

**The eight hues are today's system values, carried over deliberately**, so
moving the gutter off the system colours changes nothing visually. Nobody chose
them against the design's ground; **choosing hues that sit on it is an open design
question**, recorded here and in the file's own comment rather than decided by
this table.

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
    draw a band one step off the two surfaces it touches. **Where `bgCanvas` is
    actually seen is the no-file-open placeholder, and nowhere else**: the
    dock's two empty-state sentences — "No problems" and the usages invitation —
    read as canvas but are drawn inside `panelContent(_:)`, which this part
    paints `bgPanel` directly under, each sentence filling that slot through
    `.frame(maxWidth: .infinity, maxHeight: .infinity)`. The role still has its
    consumer — the window root paints it — so the sweep's accounting is
    unchanged; what it does not have is three places it shows through. This is
    the **canonical** statement of the pair: `ContentView.swift`,
    `MainWindowChrome.swift`, `app-window.md`, `app-shell.md` and the
    placeholder-pane paragraph below each name it and point here, rather than
    restating a claim that was wrong in five places at once. No test pins it:
    it is prose about which ground a sentence sits on, and the only mechanizable
    form would pin the sentence to itself. It is a **sibling** of
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

**Both switchers hide their symbols from the announcement.** Replacing a
`Label(title, systemImage:)` with an `HStack` of symbol and text moves each
glyph *into* the button's own accessibility name, because a `Button` combines
its children — part one measured the same mechanism on a tree row
("chevron.right, folder fill, Sources", `app-window.md`). So every
`Image(systemName:)` both switchers draw, the two new carets included, carries
`.accessibilityHidden(true)` in `ProjectTreeView`'s idiom, leaving each button
named by its label alone. The third widget needs none: it states an explicit
`.accessibilityLabel` and `.accessibilityValue`. Rule ten pins all three, by
two readings rather than one: the two switchers by counting their hidden symbols
against the symbols they draw, the third by the presence of that explicit label —
the value beside it is the widget's own decision and nothing asserts it.

**Hiding a glyph is a debt when the glyph was the state.** Two of the symbols
the sweep silenced were not decoration: `ProjectSwitcherView`'s popover row
draws `row.isCurrent ? "checkmark" : "folder"` and `BranchSwitcherView`'s local
row a `checkmark` for the checked-out branch, and the only other carrier of that
state is the `accent` on the row's text, which is no more readable without sight
than the glyph that was hidden. So both rows now **speak** it, as an
accessibility *value* ("Current project" / "Current branch") on the combined
element the `Button` makes — the row's name stays its label, only the state is
added — and the comment beside each hidden symbol says it is hidden *because the
state it showed is now spoken*, not because it is decoration. The remote-branch
row needs nothing and says so in a comment: its glyph does not vary with
`isCurrent`, so it carries no state to owe back. The rule the sweep reads is the
construct, not these two sites: **a symbol in these files whose name or colour is
chosen by a condition is state**, and every such state needs a spoken carrier; a
symbol that is the same in every state is decoration and stays hidden and
silent. Rule ten gained the matching second half, and the reason it needed one is
that counting alone went green on the change that removed the information —
the count cannot tell a checkmark from a folder, and does not pretend to.

**The placeholder pane's ground is a stated divergence.** The open-a-folder pane
draws `bgPanel`, not the window's `bgCanvas`. It reads as one of the places the
window ground shows through, but it is in fact the sidebar's own surface — drawn
by `ProjectTreeView` inside the sidebar's split slot, bounded by the same
divider as the tree it replaces — and a pane whose ground changed with whether a
folder happened to be open would read as a hole in the sidebar rather than as
the window behind it. `bgCanvas` is spent regardless: the window root paints it,
and it is seen at the no-file-open placeholder (the part-three window-ground
entry above carries where it is, and is not, seen).

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

A **third** such rule survives in a file part three *did* gate:
`ContentView.swift`'s `Divider()` under the find/replace bar, drawn between
`SearchBarView` and the editor. It is inherited code rather than this part's,
and gating rule one cannot see it for the same reason as the two above — a
`Divider()` names no colour — but its surroundings differ: the ground on either
side of it is the editor zone's, not a popover's material, so the fix is
available the moment the find bar itself is swept. The part that converts
`SearchBarView.swift` takes this rule with it; recorded here beside the
popovers' two so all three are found in one place.

#### Part four (a) — the dock's own tab row, and the Problems, Usages and Terminal panels

The dock's interior, begun: part three drew the dock's *frame* (the slot's
ground, the divider above it, the bar below) and deferred the row that names
what the dock is showing, because that row is chrome the panels draw and so
belongs with them. This part draws it, moves three panels' interiors onto the
roles, and moves the severity mapping into Core. **No palette value changes and
no new role is spent**; `ChromeGeometry` gains four tokens and spends two it
already declared (`dockTabRowHeight`, `accentIndicator`). Four files join the
gated set — one of them, the row, new — and the suite grows from eleven rules to
fifteen, then to sixteen with the review round's fix below.

  - **The dock's tab row** — `DockTabRow.swift`, a new file on the environment
    path, spending `textPrimary`, `textSecondary`, `accent` and `hairline`. Its
    contract: one row across the top of the dock, drawn **once**, from
    `ContentView.panelContent(_:)`, above whichever panel is showing — inside the
    fixed-height slot, so the slot's pinned frame, its top alignment, the clip,
    the divider and `BottomPanelHeightRule` are all untouched and the row states
    no minimum height anywhere. The tabs are `BottomPanel.allCases` in the bar's
    own order, each named by `BottomPanel.title`; the row is
    `dockTabRowHeight` tall, inset by `dockTabRowPaddingX`, has **no ground of
    its own** (the slot already paints `bgPanel`) and draws its own one-point
    `hairline` along its bottom edge — **behind** the tabs, not over them. The
    first cut drew it as an overlay, which painted over the lower point of the
    selected tab's two-point accent strip; the review round moved it behind, so
    the strip interrupts the rule for the tab's width, and fixed the same
    construct in `TabStripView.swift`, where the overlay also covered the active
    tab's `bgEditor` fill and defeated the comment explaining why the rule sat
    where it did. Gating rule sixteen pins both. A tab is a plain button whose label is the
    title at `.callout` — `textPrimary` when selected, `textSecondary` otherwise,
    **regular weight in both states**, because a label that turned semibold would
    widen and shift every tab after it on each click — padded by
    `dockTabLabelPaddingX`, above an `accentIndicator`-thick strip spanning the
    tab: `accent` when selected, `Color.clear` otherwise, so the tab's height
    never changes with selection. A click asks Core's
    `BottomPanel.tabActivation(_:tab:)` and hands a `.show` answer to the bar's
    own funnel, `onTogglePanel` — which is also what creates the first terminal
    session, so the scene file was not touched; the showing tab answers
    `.alreadyShowing` and does nothing. **A tab selects and never collapses**;
    collapsing is the bar's toggle's and the close action's, and the close
    action hands the showing panel to the same funnel, which collapses it. Each
    tab speaks its name as its label and its selection as its value ("Selected" /
    "Not selected"); the strip that *draws* the selection is hidden, and the
    icon-only close action is named outright ("Close panel", tooltip and label
    both). Gating rules twelve and thirteen pin the reachability and the
    accessibility. Full entry in `app-window.md`.
  - **The Problems panel** — `ProblemsPanelView.swift`, the environment path.
    The header is a `panelHeaderHeight` strip inset by `panelHeaderPaddingX`,
    drawing its own bottom `hairline` in place of the `Divider()` the stack used
    to place under it; the title is `.body` semibold in `textPrimary`. Header
    badges and row glyphs take `ChromeColorRole.diagnosticRole(for:)`; the
    file-group header draws its icon `textSecondary` and its path
    `textPrimary`; a row draws its message `textPrimary` and its `:line`
    `textSecondary`; the hover wash is `hoverTint` (it was the platform accent at
    15 %); row and group insets spend `rowPaddingX`; the placeholder is
    `textSecondary`. Full entry in `app-window.md`.
  - **The Usages panel** — `UsagesPanelView.swift`, the environment path, in
    Problems' shape: the same header strip and hairline, the identifier at
    `.callout` monospaced in `textPrimary`, the provenance note and the count in
    `textSecondary`, the same file-group header and hover wash, the line number
    `textSecondary`, and the preview's hit `textPrimary` semibold between
    `textSecondary` context. Full entry in `app-window.md`.
  - **The Terminal panel's host** — `TerminalPanelView.swift`, the environment
    path. **The session strip is this panel's header strip**: it spends
    `panelHeaderHeight` where it used to spell a bare 28 and draws its own bottom
    `hairline` in place of its `Divider()`. The selected session tab is an
    `accentTintStrong` wash (it was the platform's selected-control colour)
    clipped at `cornerRadiusMax`, the chrome's one radius; titles are
    `textPrimary` selected and `textSecondary` otherwise; the `+` and `xmark`
    glyphs state `textSecondary` explicitly, because a borderless button would
    otherwise tint them itself. The no-session placeholder draws `bgPanel`
    rather than the platform's text background. The hosted terminal views, their
    container and the terminal palette are **untouched**: they are the terminal
    zone, not chrome. Full entry in `app-terminal.md`.

**Six tabs, not seven.** The design draws a seventh tab naming a panel this
application does not have. A tab that does nothing when clicked is a defect, not
a placeholder, so it is left out; the six are exactly `BottomPanel`'s cases.

**One name per panel, as one Core table.** `BottomPanel.title` answers
"Terminal", "Log", "Local Changes", "Problems", "Usages" and "Pull Requests",
and both the tab row and the bar's toggles read it (`bottomBarButton` lost its
`title:` parameter, and in the review round its `systemImage:` one too — the
glyph is `BottomPanel.systemImage`, the same table's second column, and the bar
builds its six toggles from `allCases`, so neither strip keeps a second list), so a tab and a tooltip cannot disagree — which is how "Git"
and "Changes" became "Log" and "Local Changes" on the bar. The View menu's item
titles ("Show Git Log" and its siblings) are **deliberately left alone**: menu
titles belong to the part that sweeps menus. The scene file's line ceiling is
*not* the reason — editing a string literal in place adds no line.

**Close alone.** The design draws minimise and close; on a dock with one state
the two would perform the same action, so only close is drawn, as an `xmark`.

**The font tiers.** The chrome's three sizes are assigned by *tier*, not by
rounding an old size to the nearest one: **13** (`.body`) for primary text — a
panel's title (`.headline` before, the same 13 points under the chrome's own
style name, now semibold `.body`), a row's message, a file group's path; **12**
(`.callout`) for secondary metadata — a dock tab's label, a severity badge's
count, the identifier, the empty-state sentence; **11** (`.subheadline`) for
column headings and monospaced details — a terminal session's title, the
provenance note and the count, the line numbers. Every size already on the
scale stays. **A discrepancy is reported rather than resolved silently**: the
ticket counted two off-scale labels to move (Usages' two 10-point `.caption`
labels, now `.subheadline`), and the files carried three more — Problems'
`:line` and Usages' line number, both `.caption` monospaced, which take
`.subheadline` monospaced as monospaced details, and the terminal session tab's
close glyph at a bare 8-point bold, which takes `.subheadline` bold so it
matches the label beside it. All five moved.

**One severity answer, and which surface reads which table.** Two tables, one
per zone, and no third: the **chrome** marks — the gutter's severity dot and the
Problems panel's badges and row glyphs — read
`ChromeColorRole.diagnosticRole(for:)` (the `ChromeColorRole.swift` entry
above), and the **code** mark — the squiggle under the text — reads
`SyntaxTheme.diagnosticColor(for:)`. Before this part the panel read
`SyntaxTheme`'s table under a comment calling it "three surfaces, one palette"
while the gutter had already moved to roles, so the claim was false the day the
gutter moved; the panel now names no `SyntaxTheme` at all, and rule fifteen pins
that, the reader set and the absence of any severity case label outside the
panel's one glyph table.

#### Part four (b) — the Log, Local Changes and Pull Requests panels, and the two diffs

The dock's interior, finished. Seven surfaces move onto the roles — the **Log
panel**, its **filter bar** and its **graph gutter**, the **Local Changes panel**,
the **Pull Requests panel**, the **side-by-side diff pane** and the **unified
diff's wash** — and seven files join the gated set (`CommitLogView.swift`,
`CommitGraphView.swift`, `LogFilterBar.swift`, `LocalChangesView.swift`,
`DiffView.swift`, `CommitUnifiedDiffView.swift`, `PullRequestsPanelView.swift`),
taking it from twenty to twenty-seven; the suite grows from sixteen rules to
twenty (and, with the fix round's filter-bar and resize-cursor rules, to
twenty-two). **No palette value changes and no role is added.** Two roles are spent,
the diff grounds `diffAddedBackground` and `diffRemovedBackground`, leaving four
unspent. `ChromeGeometry` gains `buttonPaddingX` (10) and `buttonCornerRadius`
(5).

**Four new Core answers**, each replacing tables that existed in more than one
copy (the `ChromeColorRole.swift` entry above has the values): the changed-file
status colour `changedFileRole(for:)` with its letter and spoken name
(`FileStatus.letter`/`spokenName`) — read by the Local Changes panel, the Log's
detail pane and the commit dialog, where two identical tables used to live
(the dialog calling one of them); the
checks colour `checksRole(for:)` with the checks glyph and words
(`symbolName`/`spokenWords` on `GitHubChecksSummary` and `GitHubCheckBucket`) —
read by the panel and the bottom-bar indicator; and the diff wash
`diffWashRole(for:side:)` / `diffWashRole(for:)` with its marker
`diffMarkerRole(for:side:)` — read by the two diff surfaces, over Core's one
`DiffSide`, which replaced the app's `DiffTextView.Side` outright. Rules
seventeen to nineteen pin each answer's readers and forbid a case-label table in
a view; rule twenty pins the three panels' accessibility.

**The lane palette is the fourth exemption** (`CommitGraphPalette.swift`, above):
a lane colour is an identity token, not a chrome meaning. Its eight hues are
today's system values carried over so the gutter changes nothing visually;
choosing hues that sit on the design's ground is an open design question.

  - **The Log panel** — `CommitLogView.swift`, the environment path. The header
    strip is the Problems panel's; a new static, non-interactive column-header
    row (Hash / Message / Author / Date, 24 pt) reads the rows' own widths; rows
    are 25 pt, 12 pt inset, 16 pt column gap; washes `accentTintStrong` /
    `hoverTint`, ref badges `accent` on `accentTint`; the date keeps its short
    date+time format. The graph column is `max(40, lanes × 14 + 6)` pt, scaled,
    40 being a named minimum. The three `Divider()`s are the surface's own
    hairlines — including the list/detail divide, which is therefore a hairline
    with a drag strip rather than an `HSplitView`. Full entry in
    `app-git-views.md`.
  - **The graph gutter** — `CommitGraphView.swift`, AppKit, reading
    `CommitGraphPalette` and spelling no colour; 2 pt lines, a 6 pt dot, 14 pt
    lanes. Full entry in `app-git-views.md`.
  - **The filter bar** — `LogFilterBar.swift`, the environment path: one
    `panelHeaderHeight` strip on `bgPanel` keeping every control, each in a 22 pt
    box (4 pt radius, `bgEditor`, a `hairline` border that becomes a two-point
    `accent` one on focus). Full entry in `app-git-views.md`.
  - **The Local Changes panel** — `LocalChangesView.swift`, the environment
    path, keeping its single-list structure: a 32 pt toolbar whose Commit is the
    primary button, a hand-drawn folder header, a drawn checkbox, the two
    context-menu `Divider()`s become `Section`s rendering the same separators.
    Full entry in `app-git-views.md`.
  - **The Pull Requests panel** — `PullRequestsPanelView.swift`, the environment
    path: 40 pt rows with primary and secondary buttons, the checks glyph and job
    dots from Core, review decisions as bordered capsules; the indicator beside
    the branch switcher, already gated, now reads the same Core answers. Full
    entry in `core-github.md`.
  - **The side-by-side diff pane** — `DiffView.swift`, the AppKit bridge: the row
    wash and marker are Core's answers resolved through `ChromePalette.nsColor(_:)`,
    the filler row carries no wash, gutter numbers are `textSecondary`, and the
    divider between the panes is a plain view filled with `hairline` at
    `hairlineWidth` **unscaled**, under the token's stated code-zoom exception.
    The characters keep `SyntaxTheme`. Full entry in `app-git-views.md`.
   - **The unified diff** — `CommitUnifiedDiffView.swift`, the environment path:
     the row wash through `diffWashRole(for: UnifiedDiffLine.Kind)`, the checkbox
     `accent`/`textSecondary`, line numbers `textSecondary`. Gated in full; the
     commit dialog around it is untouched except for reading the status answer.
     Full entry in `app-git-views.md`.

#### Part five (a) — the popovers and the search surfaces

The sweep's first floating surfaces and its two search surfaces: the completion
panel and the hover popover, the find/replace bar above the editor, the Find in
Files window and its window controller, the recent-searches menu, and the two
bottom-bar popovers plus the Log calendar. It spends `bgPopover`, leaving three
roles unspent (`currentLine`, `bracketMatch`, `conflictBackground`), and takes
the gated set from twenty-seven to thirty-four. Seven files join the set:
`ChromeControls.swift` (new, holding the shared field shape and the secondary
button), `CompletionPanel.swift`, `HoverPanel.swift`, `SearchBarView.swift`,
`SearchHistoryMenu.swift`, `ProjectSearchView.swift` and
`ProjectSearchWindowController.swift` — the last, `ProjectSearchWindowController`,
is the seventh the ticket lists as six but counts as seven (27 + 7 = 34 already
assumes it: it paints the Find in Files window's own ground `bgPanel` through
`ChromePalette.nsColor(_:)`, so a live resize never shows the system window
colour). The suite grows from twenty-two rules to twenty-seven.

**`ChromeControls.swift` — the shared field shape, the query toggle and the secondary button.**
`ChromeControlBox` has a `bgEditor` ground, a one-point `hairline` border,
`accent` at `fieldFocusedBorderWidth` while focused, and `fieldCornerRadius`,
taking its horizontal inset as a parameter and stating no height so the container
decides (22 in the filter strip, 33 in Find in Files). `ChromeThemedTextField`
is a plain `TextField` with `textPrimary` content, a `textSecondary` placeholder,
an optional leading glyph hidden from accessibility, and a spoken label, focus
coming in as a `FocusState` binding plus the value it equals — taking a
text-style parameter defaulting to `.callout` (so the Log filter bar's pixels stay
as they are) and an inner gap defaulting to `6`, with Find in Files' three
fields and the branch switcher's filter passing `.body`. `ChromeQueryToggle` is
the one query-mode toggle (label, `isOn` binding, help text), drawing the label
at `subheadline` semibold monospaced — `accent` on `accentTint` while on,
`textPrimary` with no ground while off — with the spoken name, tooltip and
on/off value both surfaces already had. `ChromeSecondaryButtonStyle`
is 28 high (`secondaryButtonHeight`), with a one-point `hairline` border, radius
`buttonCornerRadius`, padding `secondaryButtonPaddingX` and a `callout` label in
`textPrimary`. Everything is scaled through `InterfaceMetrics` and colours come
from `\.chromeTheme`. Part five (b) adds `ChromePrimaryButtonStyle` (`.chromePrimary`: the
secondary's geometry, a `callout` semibold `onAccent` label on an `accent`
ground, dimming as the secondary does) and `ChromeCheckbox`, lifted from Local
Changes' revert checkbox: a three-case state (on/off/mixed, with an initializer
from Core's `CheckboxState`), a spoken label, an optional trailing `callout`
title inside the click target, a `checkboxSide` square at `checkboxCornerRadius`
(off: `hairline` border; on: `accent` + `onAccent` check; mixed: the same ground
+ an `onAccent` dash), the box hidden from accessibility and the control
speaking "On"/"Off"/"Mixed", dimmed when disabled. The glyph is 10 points, a
named private constant (`ChromeCheckboxLayout.glyphSide`): the design's check
inside the 14-point box, taken over Local Changes' former private 8, so the
revert checkbox's check grew two points. Its first callers are the revert
checkbox (the private builder and its three `LocalChangesLayout` numbers
deleted) and the Log filter bar's two date bounds, which replaced a platform
`Toggle`. Callers: `LogFilterBar.swift` (its text fields and its
three boxed system controls — the branch menu and the two date bounds — through
the box at 22 high and its own inset, plus the box as the filter-field baseline
with its private `controlBox`/`filterField` and the `FilterBarLayout` entries
`controlRadius`/`focusBorderWidth` deleted), `SearchBarView.swift` (the query and
replace fields) and `ProjectSearchView.swift` (the query row, the replace row and
the file-mask field) and `BranchSwitcherView.swift` (the popover's filter field,
via the themed field with its own `FocusState`) and — since part five (b) —
`CommitDialogView.swift` (the message box, through the box alone around its
`TextEditor`). The Log bar's doc comment says
the shape is shared. Tokens are in `ChromeGeometry`: `fieldCornerRadius` 4,
`fieldFocusedBorderWidth` 2, `fieldPaddingX` 10, `secondaryButtonHeight` 28,
`secondaryButtonPaddingX` 14, each distinct and none derived.

**The three SwiftUI popovers get one answer, with no branch.** The Log
calendar, the branch switcher and the project switcher each carry `bgPopover` on
their content as a background, with no `presentationBackground` and no
`#available` branch. Each file says in one line that the popover's arrow keeps
the system material because the content background cannot reach it.
`presentationBackground` is an open question for the part that sweeps sheets and
dialogs: the modifier is documented to apply there and a sheet is big enough for
the difference to matter, so it was not shipped here as an unverified branch.

**The completion panel — `CompletionPanel.swift`, the AppKit bridge.** The
vibrancy background (`NSVisualEffectView` `.popover`) is replaced by a flat
`bgPopover` layer fill: a one-point `hairline` border, corner radius
`cornerRadiusMax` scaled with `metrics.pt(_:)` where `InterfaceMetrics` is known
(in `show(...)` beside the sizing, not in `makePanel()`; the border width stays
unscaled as the hairline exception and the radius is a plain number outside the
appearance block), the window's shadow kept. In `match(_:to:)` both layer colours
are set only inside `appearance.performAsCurrentDrawingAppearance`:
`borderColor` from `ChromePalette.nsColor(.hairline)` and `backgroundColor` from
`ChromePalette.nsColor(.bgPopover)`, with the existing comment extended to say
the background is a `CGColor` too. Row text is `textPrimary`, the selected row
has an `accent` ground and `onAccent` text, the badge is monochrome
(`textSecondary` on an ordinary row, `onAccent` on the selected one), and the
private `color(for:)` hue table is deleted. The badge's colour leaves Core:
`CompletionPopup.Badge` loses its `color` stored property, its initializer
parameter and every table entry's colour; `init(symbolName:)` and
`init(source:)` remain; `FileIconColor` stays for `FileIcon`.

**The hover popover — `HoverPanel.swift`, the AppKit bridge.** The same flat
`bgPopover` fill on the same terms (hairline, `cornerRadiusMax` scaled with
`metrics.pt(_:)` where `InterfaceMetrics` is known — `show(...)` beside the
sizing, border staying unscaled as the hairline exception, plain number outside
the appearance block — shadow, both layer colours only inside the
drawing-appearance block, the block's comment updated). Prose is `textSecondary`,
code segments `textPrimary`, the truncation marker `textSecondary`; the doc
comment states the chrome has two text tones. `ignoresMouseEvents`, the absence
of a zoom surface and the exclusion from the window cycle stay unchanged.

**The find/replace bar — `SearchBarView.swift`, the environment path.** The bar
has a `bgPanel` ground and draws its own one-point `hairline` along its bottom
edge; the `Divider()` under it in `ContentView` is removed, leaving a one-line
comment in the style of the one at ~line 403. The query and replace fields use
the shared themed field (Find in Files' three and the branch switcher's filter
now pass `.body`; the bar keeps the field's `.callout` default and its `6`-point
gap default); the system rounded-border style is gone. Colours: the match
counter and the labels are `textSecondary`, the inline regex error is
`statusRed`, the three query-mode toggles are the shared `ChromeQueryToggle` —
`subheadline` semibold monospaced, `accent` on `accentTint` while on,
`textPrimary` with no ground while off — the navigation/close/disclosure glyphs
take roles, Replace and Replace All use the shared secondary button style, and
`.caption` becomes `.subheadline`. Accessibility: each toggle has a spoken name,
a `.help` tooltip and an on/off `.accessibilityValue`; Previous, Next, Close
and the replace disclosure have a spoken name and a tooltip, and their symbols
are hidden; the fields speak their names.

**The recent-searches menu — `SearchHistoryMenu.swift`, the environment path.**
The trigger glyph becomes `textSecondary` and is hidden from accessibility; the
menu keeps a spoken name. The menu's rows and its *Clear History* button are
grouped into two `Section`s whose boundary draws the separator — no `Divider()`
remains and no comment pins an exception.

**The Find in Files window — `ProjectSearchView.swift` (environment) and
`ProjectSearchWindowController.swift` (AppKit bridge).** The SwiftUI root is
`bgPanel`; the window controller paints the window's own background through
`ChromePalette.nsColor(.bgPanel)`, the standard title bar and its style mask
unchanged. Design values: content body padding 16 at the top and on both sides,
0 at the bottom, gap 12; query row 33 high in the shared field with the shared
`ChromeQueryToggle` triple at its trailing end (gap 10), each toggle at
`subheadline` semibold monospaced — `accent` on `accentTint` while on,
`textPrimary` with no ground while off; replace row the shared field gap 8 then
Replace All in the secondary button style; scope line `callout` in
`textSecondary`; results gap 8; group header 24 high padding 8 a 14-point icon
the path in `callout` and the count in `subheadline` all in `textSecondary`;
match row padding 8 on the right and 34 on the left, no fixed height — its height
is the content's, at the code font (`settings.fontSize`) so it never overflows,
and `.contentShape` comes after the paddings so the insets are the click target;
footer 32 high with its own top `hairline` padding 16 and the summary in
`callout` `textSecondary`; the file-mask field is also the shared field; the
`Divider()` between the header and the results is replaced by a `hairline` rule
the content draws. Numbers with no `ChromeGeometry` home live in a private layout
enum in this file; existing tokens are reused where they fit. The group header
icon stays monochrome `textSecondary`. The match row keeps its zones and is the
example rule twenty-seven pins: the preview text stays on the code font in
`SyntaxTheme`'s plain colour and the highlight keeps the editor's current-match
background, the line number stays on the code font and takes `textSecondary`, the
row keeps its `ZoomSurfaceMarker(kind: .code)`, nothing sized by the code font is
multiplied by the interface scale and nothing sized by the interface reads
`settings.fontSize`, no selection state is added, and the regex/validation error
is `statusRed`. Accessibility: the fields, the toggles (name, tooltip, value)
and Replace All are named, and decorative symbols are hidden.

**The two bottom-bar popovers get their ground and lose their dividers —
`BranchSwitcherView.swift` and `ProjectSwitcherView.swift` (environment).** Both
popovers' content is drawn on `bgPopover` with a content background, no
`presentationBackground` and no `#available` branch, each file saying in one line
that the arrow keeps the system material. Each `Divider()` becomes a one-point
`hairline` rule the content draws. The branch switcher's filter field uses the
shared themed field; doc comments on `theme` and `popoverContent` that explained
why the dividers had to stay are rewritten to say what is true now, with no
sentence describing the old material ground or the kept dividers.

**Four departures from the design, in the repository's favour.**
1. A match preview line is code — it stays on the code font and in
`SyntaxTheme`'s plain colour.
2. The highlight stays the editor's — the match highlight inside a preview keeps
the editor's own current-match background.
3. No selection is added to the match list — `accentTintStrong` goes unused on
that surface, because this part changes no behaviour (settled in Q&A).
4. The Find in Files window keeps the standard system title bar, per requirement
7 — the design's 28-point title strip and its 12-point `textSecondary` title are
not drawn, and `MainWindowChrome.swift` stays the only file that makes a title
bar transparent. The line number beside a preview line stays on the code font as
the preview does; its colour becomes `textSecondary`, the role the editor's own
gutter numbers use, so the number takes its size from the code zone and its
colour from a role, like the gutter it mirrors — today it used `.secondary`, a
system colour a gated file may not spell.

**Five new gating rules (twenty-three to twenty-seven), and the count
bookkeeping.** The suite's header lists twenty-seven, `spelled` is 27, the
canonical list opens with "The twenty-seven rules, each invisible to the
compiler:" and `CLAUDE.md` mirrors it. Rule twenty-three pins the popover
surface: the gated files naming `bgPopover` equal `{CompletionPanel.swift,
HoverPanel.swift, BranchSwitcherView.swift, ProjectSwitcherView.swift,
LogFilterBar.swift}` and every gated file presenting a popover (`.popover(`) or
declaring an `NSPanel` is in that set, with no `NSVisualEffectView`, `.material`
or `presentationBackground` in any gated file. Rule twenty-four pins that no
gated file spells `Divider()` at all — a menu's separator is a `Section`
boundary, and every gated file that builds a `Menu` spells `Section` (by set
equality, so a fourth menu file is added deliberately). Rule twenty-five pins
AppKit layer colours: in `CompletionPanel.swift` and `HoverPanel.swift` every
`borderColor` and `backgroundColor` assignment lies inside a brace-matched
`performAsCurrentDrawingAppearance` body, the border naming `hairline` and the
background `bgPopover`, with at least one of each per file. Rule twenty-six
pins one field shape and one query toggle: no gated file spells the
rounded-border style, the set of files constructing the shared field or box
equals `{LogFilterBar.swift, SearchBarView.swift, ProjectSearchView.swift,
BranchSwitcherView.swift}` plus `ChromeControls.swift`, and the set constructing
the shared query toggle equals `{SearchBarView.swift, ProjectSearchView.swift}`
with no gated file outside `ChromeControls.swift` declaring a toggle builder.
Rule twenty-seven pins that each measurement follows its own zone: the Find in
Files match row carries no fixed `.frame(height:` and is sized by the code font
(`settings.fontSize`), matched over its brace-matched body so a multi-line call
cannot slip past, and each `cornerRadius` assignment in `CompletionPanel.swift`
and `HoverPanel.swift` names `metrics` on the same statement. Rule twenty's
table is extended to the two search surfaces' toggles and buttons.

**Fix 01 — the acceptance review's five corrections, stated as corrections to
this part rather than as a new part.** The match row carries no fixed height and
is sized by its code-font content (the `metrics.scaled(rowHeight)` frame is gone,
`SearchLayout.rowHeight` deleted, `.contentShape` after the paddings, the header's
`24`-point `headerHeight` staying interface-scaled by design and saying so).
The two query-mode toggle copies become one `ChromeQueryToggle` in
`ChromeControls.swift` (`subheadline` semibold monospaced, `accent`/`accentTint`
on, `textPrimary` off, with help and on/off accessibility value), both surfaces
call it and both private builders and `SearchLayout.toggleFontSize` are gone.
`ChromeThemedTextField` gains a text-style parameter defaulting to `.callout`
(and its inner `6`-point gap the same), Find in Files' three fields and the
branch switcher's filter pass `.body`. Both AppKit popovers set their corner
radius scaled with `metrics.pt(cornerRadiusMax)` where `InterfaceMetrics` is
known, beside the sizing, with the border width staying unscaled as the hairline
exception and the radius outside the appearance block. `SearchHistoryMenu` groups
its rows into two `Section`s and `Divider()` is gone everywhere — rule
twenty-four becomes exception-free with a non-vacuity clause over `Section`, and
the duplicated "the popover's arrow keeps the system material" sentence in
`BranchSwitcherView.swift`/`ProjectSwitcherView.swift` loses its second copy.
Rule twenty-seven is the zone rule that would have caught the first and fourth
of these.

#### Part five (b) — the commit dialog, the merge editor and the four separate windows

The last family of window surfaces: the commit dialog (its file list, message
box, author line, footer and author editor sheet), the three-pane merge editor,
the four secondary windows that host code — diff, merge, Local History and the
out-of-project source viewer — and `EscClosableWindow`, the subclass all six
secondary windows are built from. It spends `conflictBackground`, leaving two
roles unspent (`currentLine`, `bracketMatch`, both code zone), and takes the
gated set from thirty-four to **forty-four**. Ten files join:
`CommitDialogView.swift` (`CommitFileRow` and `AuthorEditorView` live in it),
`MergeView.swift`, `MergeWindowController.swift`, `DiffWindowContent.swift`,
`DiffWindowController.swift`, `SourceViewerContent.swift`,
`SourceViewerWindowController.swift`, `LocalHistoryView.swift`,
`LocalHistoryWindowController.swift` and `EscClosableWindow.swift`. The four new
controllers, `ProjectSearchWindowController.swift` (whose one role left with its
window ground) and `SourceViewerContent.swift` (whose one colour is now the
shared pane ground) join `roleNamingExemptions`: they name no role, and stay
gated for rules one and two and for the window-ground and pane-ground rules,
which are exactly the rules they can break. The suite grows from twenty-seven
rules to thirty-five — eight new rules: six from the part itself
(twenty-eight to thirty-three), rule thirty-four from the first review round and
rule thirty-five from the third.

**Decisions.**

1. **The merge wash is one wash** — `mergeWashRole(for:)`, stated in the Core
   section above: `conflictBackground` for ours, theirs and an unresolved
   region, `diffAddedBackground` for a resolved one, nothing for a plain line;
   the panes, not a second colour, tell ours from theirs from result.
   `MergePaneTextView.drawBackground(in:)` fills `ChromePalette.nsColor(role)`
   and takes no `performAsCurrentDrawingAppearance`: a dynamic `NSColor` filled
   at draw time resolves at that moment. The view's private `MergeLineKind` and
   `MergeColors` table are gone.
2. **A code pane's ground goes through one definition** —
   `CodePaneGround.apply(scrollView:textView:)` in `DiffView.swift`, beside
   `DiffDividerView`: the text view, the scroll view and its clip view all
   `bgEditor`, because the editor's gutter (`LineNumberRulerView`) fills itself
   with `bgEditor` and an editor pane on the system text background shows a
   lighter band beside it; the other panes take the same ground so every code
   pane matches — `DiffGutterView` fills nothing, so what shows behind it is the
   ground this helper sets, and the merge panes have no ruler at all. **Four callers**:
   `SourceViewerContent`, `DiffView.makePane`, the merge panes'
   `MergeThreePaneView.makePane`, and
   `CodeEditorView.makeNSView` — the editor is the *corrected* fourth: it
   already set the same three backgrounds privately (through a helper of its
   own, deleted in part five (b) when `makeNSView` began calling
   `CodePaneGround.apply` directly), and leaving that copy would have
   made "one definition" false on the day it was written.
   `CodeEditorView.swift` stays outside the gated set but inside the rule's
   reach. The clause (rule thirty-one) covers **every** view `backgroundColor`
   assignment rather than deciding which receiver is a code pane: outside
   `CodePaneGround`'s body only five sites are allowed, pinned by file and count
   with their reasons — among them `CompletionPanel.swift` and `HoverPanel.swift`,
   whose `panel.backgroundColor = .clear` on an `NSPanel` must stay (a borderless
   panel has to be clear for its own rounded layer to draw). The
   merge container's dividers are `DiffDividerView`s too (the `NSBox` separators
   deleted), `dividerWidth` the hairline token unscaled for the reason
   `DiffContainerView` states.
3. **A secondary window's ground is set in the subclass** —
   `EscClosableWindow`'s designated initializer sets
   `backgroundColor = ChromePalette.nsColor(.bgPanel)`, which covers both
   construction paths (`NSWindow(contentViewController:)` is a convenience
   initializer that goes through it; the merge controller passes a rectangle).
   A window's ground is a property of the window rather than of whichever
   controller builds it, and two setters compete silently; this is the sibling
   of `MainWindowChrome.swift`'s rule for the main window. Find in Files'
   controller lost its own assignment (its live-resize rationale moved into the
   subclass's comment), and the problem browser's window
   (`LeetCodeBrowserWindowController`) gains `bgPanel` with the rest — the
   intended consequence of one ground for every secondary window, ahead of its
   view's own sweep.
4. **One primary button and one checkbox**, in `ChromeControls.swift` beside the
   secondary style (entry above). `ChromePrimaryButtonStyle` is the secondary's
   geometry with a `callout` semibold `onAccent` label on an `accent` ground.
   `ChromeCheckbox` is **lifted, not written**: Local Changes' revert checkbox
   already drew exactly the required shape from three private numbers, so the
   shape was lifted from it (as part five (a) lifted the field from the Log
   filter bar), the revert checkbox became a caller and its numbers were
   deleted, leaving no second copy. **The glyph is 10 points, not 8**: 10 is the
   design's check inside the 14-point box; Local Changes' 8 was a private
   choice for one caller, made before the shape was shared and never checked
   against the drawing. One shape serving five callers takes one value, and the
   drawing wins — the revert checkbox's check grew two points, said beside the
   constant. The mixed-state dash uses the same width. Callers: the commit
   dialog (file rows, Amend, Push after commit), Local Changes' revert checkbox
   and the Log filter bar's two date bounds, which replaced a platform `Toggle`.
5. **The rule-matching convention**, which this part's eight rules (the six
   above plus the review rounds' thirty-four and thirty-five) follow and
   state at each site. Every identifier ban and presence check matches through
   `LSPSourceGatingTests.containsToken(_:in:)`, never a bare `contains` — a
   substring match is wrong both ways, and a `Toggle(` ban under `contains`
   would be red on day one against `ChromeQueryToggle(`. A leading-dot member
   (`.toggleStyle(`, `.chromePrimary`, `.accessibilityValue(`) is matched as its
   bare identifier, because the boundary check rejects a dotted needle after an
   identifier character. A key path is matched with its backslash
   (`\.chromeTheme`), so a root's own `settings.chromeTheme(` is not a hit. A
   clause that must use a pattern — an assignment's shape, a receiver's kind, a
   modifier's argument — says why. And **a root's region is the whole
   brace-matched struct**, not its `body`: the regression rule thirty-two exists
   for is an `@Environment(\.chromeTheme)` *stored property* added to a root,
   which sits outside `body`, so a clause over `body` alone would be vacuous on
   exactly that mistake. `RevisionRow`, a child view at file scope, reads the
   environment there; `MergeThreePaneView` and `SourceViewerPane` are
   `NSViewRepresentable`s with no `@Environment` at all — their colours are
   dynamic `NSColor`s from `ChromePalette` and `CodePaneGround`.
6. **The alpha clause targets roles.** `MinimapView.swift` applies an alpha to a
   syntax-table colour — code zone — so the rule forbids an alpha chained onto a
   *role's* colour across the gated set, plus the `withAlphaComponent` token
   outright in this part's ten files.

**The commit dialog — `CommitDialogView.swift`.** A 44-point `bgPanel` header
strip (`dialogEdgeStripHeight`) closed by a `hairline` rule, carrying "Commit
Changes"; the file-count and diff-path headers are pane headers
(`panelHeaderHeight`, `bgPanel`, `hairline` bottom rule, `textSecondary`); the
dialog stands on `bgPanel` and the diff preview on `bgEditor`; its three
`Divider()`s are `hairline` rules. The file row is two lines — name in
`textPrimary` at `.body`, directory in `textSecondary` at `.caption` — with no
fixed height, the file icon at its own `.callout` (rule thirty-four), coloured
by `changedFileRole(for:)` and hidden from accessibility, the status letter `.callout` semibold monospaced keeping its
spoken value, and a three-state `ChromeCheckbox` labelled "Include <name> in the
commit". Its background is `TreeRowState.state(…)`'s precedence painted
through the tree's own `TreeRowBackground.color(for:resolving:)` — called, not
copied, so the dialog cannot keep the old roles the day the tree's answer
changes: `accentTintStrong` selected in a key window, `selectionInactive`
selected in one that is not, `hoverTint` under the pointer. The message box is the shared `ChromeControlBox` (focus from a
`@FocusState`, `fieldPaddingX`, hidden scroll background so `bgEditor` shows,
`textPrimary` content), keeping its code-zone height and `ZoomSurfaceMarker`.
The author line's labels and amend note are `textSecondary`, the signature
`textPrimary` or `statusRed` when incomplete; Amend and Push after commit are
checkboxes, the push hint `textSecondary`, the status sentence `statusRed` for
an error and `textSecondary` otherwise; a `hairline` rule sits above a footer
sized by its content; Cancel is `.chromeSecondary`, Commit `.chromePrimary`,
shortcuts and disabled rules unchanged. The author editor sheet stands on
`bgPanel` with its title in `textPrimary`, caption in `textSecondary`, Save
`.chromePrimary` and Cancel `.chromeSecondary`. It joins rule twenty-six's
shared-field callers (now five).

**The merge editor — `MergeView.swift` and `MergeWindowController.swift`.** The
root resolves colours through a private `chromeColor(_:)`; nothing inside the
root struct reads `\.chromeTheme`, and `MergeThreePaneView` stays at file scope
— an `NSViewRepresentable` reading no environment, its colours dynamic `NSColor`s.
The toolbar is a status strip: `dialogEdgeStripHeight`, `bgPanel`, a `hairline`
bottom rule, "Conflict n of m" and the status at `.callout` (`statusGreen` when
fully resolved, `textSecondary` otherwise), both chevrons `.chromeSecondary`
with a spoken label ("Previous conflict"/"Next conflict") and a tooltip, the
four take-side buttons `.chromeSecondary`, Apply `.chromePrimary` keeping ⌘↩ and
its disabled rule, and the vertical `Divider()` a vertical `hairline` rule whose
16-point height lives in the private `MergeViewLayout` (one surface's number).
The pane header is `panelHeaderHeight` (was 22), `bgPanel`, a `hairline` bottom
rule, titles in `textPrimary` at the dock's panel-header size, vertical
`hairline` rules between them. Errors are `statusRed`, loading
`textSecondary`; all six `Divider()`s are `hairline` rules. The AppKit half is
decisions 1 and 2.

**The diff window, the source viewer and Local History.** `DiffWindowContent`'s
root takes `textSecondary` for "Loading…" through a private `chromeColor(_:)`;
the side-by-side pane inside it was swept in part four (b). The source viewer's
pane goes through `CodePaneGround`. `LocalHistoryView`'s root has a private
`chromeColor(_:)`; the revisions list is inset with a hidden scroll background
and `bgPanel` row backgrounds — except the selected row, which yields its
background (`Color.clear`) so the platform's selection shows, since on macOS a
row background is drawn over the selection box (rule thirty-five);
the empty-state and "Select a revision" texts are `textSecondary`; the footer's
`Divider()` is a `hairline` rule; Restore is `.chromeSecondary` with its
plan-driven enablement. `RevisionRow`, at file scope, reads `\.chromeTheme` as a
child: title `textPrimary`, time line `textSecondary`. The four controllers
construct `EscClosableWindow` and set no ground (decision 3).

**Two part five (a) corrections.** The Find in Files match-row comment that said
the line number "stays `.secondary`" now says `textSecondary`, which is what the
code does; and the whole-word toggle speaks one name, "Whole word", on both
search surfaces.

**Departures from the design, in the repository's favour.**
1. **The file row's states.** The design's single mock draws the selected row in
   `accentTint` and cannot show a non-key window or a hover; the established
   precedence (`TreeRowState`) wins, so the selected row is `accentTintStrong`.
2. **The message box's padding** is the shared field's 10, not the design's 12 —
   a two-point difference in one drawing is not worth a second measurement.
3. **The dialog title** is `.headline` semibold (13); the design's 14 has no
   place on the chrome's scale.
4. **The sheet's corners are the system's.** A sheet's frame is drawn by the
   system; clipping the content to `cornerRadiusMax` would only expose the
   sheet's own ground at the corners, so the content does not clip, and the
   file says so.
5. **"Edit…"** on the author line is a `.plain` button with an `accent` label,
   not `.buttonStyle(.link)`, a platform style rule thirty forbids.
6. **The unified diff's per-line checkbox keeps its SF Symbol glyph — an open
   question.** It sits inside a code-font row; the shared checkbox is
   interface-scaled, and putting it in a code-zoom row is the mixed-zone
   mistake rule twenty-seven exists to catch. Rule thirty bans platform toggles,
   and the glyph is neither. Whether that row's checkbox should be a code-zone
   shape of its own is a design question.
7. **The unified diff's added and removed text keeps the code zone's plain
   colour — an open question.** The design tints a changed line's text as well
   as its ground; the row is code, drawn in `SyntaxTheme`'s plain colour on the
   role wash, and a tinted *text* would be a chrome colour on code, which is
   the zone question rather than a restyle.

**Six new gating rules (twenty-eight to thirty-three)** — the window ground in
the subclass, the merge wash as Core's one answer, one primary button / one
secondary / one checkbox, one code-pane ground, the window root's theme
resolution, and the commit dialog's rows and controls — each listed in the
canonical list below, each shown red against a deliberate regression before it
was committed. Rule twenty-seven's multi-line `.frame(… height:` walk is now a
shared helper both it and rule thirty-three read.

**Rule thirty-four, from the review round** — every chrome glyph sized in the
interface zone. This part's file row lost the container font its file-type glyph
inherited (the name, directory and status letter each gained a font of their
own; the glyph did not), so it drew at the system default and stood still at
150% and 200% while the row grew around it. The glyph now carries `.callout`
itself, as Local Changes' row does. The sweep behind the rule read every
`Image(systemName:` in the gated set, not only this part's files: two more
glyphs were unsized the same way — the Pull Requests panel's message and
wait-ending strip glyphs, now `.subheadline` like the message beside them —
and twenty-one are sized by something outside their own chain, each pinned by
declaration with what sizes it (seventeen by a container font, two by the font
at their declaration's use sites, two by the shared secondary button style),
plus the unified diff's per-line checkbox,
pinned as deliberately on neither scale (decision 6 above). The third review
round closed the rule's two holes: its contiguous `Image(systemName:` search
skipped a wrapped `Image(` outright, and it accepted a metrics `.frame(` as a
size, which took the switcher popovers' three icon-column glyphs out of the
container-font re-check. The glyphs are now found through the suite's one
whitespace-tolerant call matcher, which every call-shaped search in the suite
that takes arguments goes through, and a frame counts only beside
`.resizable()`. The three glyphs are pinned by their rows as container-font
glyphs, bringing the glyphs sized by a container font from seventeen to twenty.

**Rule thirty-five, from the third review round** — a selectable list yields its
selected row's background. The revisions list gave every row an unconditional
`bgPanel` background, and on macOS a row background is drawn over the selection
box, so the revision Restore acts on was indistinguishable from the rest. Its
comment cited Find in Files as the precedent, but that list binds no selection.
The selected row now takes `Color.clear`. The sweep behind the rule found three
selectable `List`s in the app (`LocalHistoryView`, `AcknowledgementsView`,
`DatabaseViewerView`) and three `listRowBackground` sites (the revisions list's
and Find in Files' two); only the revisions list is both.

#### What is still waiting

The dock is finished, the popovers and search surfaces are swept, and so are the
commit dialog, the merge editor and every secondary window's ground. After them:
the remaining sheets and dialogs, the problem browser's own view (its window
already stands on `bgPanel`), the Preferences surfaces and the terminal's own
palette. Each follows the six-step guide at the end of this document, on its
own, with `gatedFiles` growing as part of the restyle rather than afterwards.

The dock's tab row is **no longer deferred** — part four (a) drew it, and
`ChromeGeometry.dockTabRowHeight` is spent. The popovers are **no longer
deferred** — part five (a) drew them on `bgPopover` and replaced their
`Divider()` calls with `hairline` rules, and `ChromeGeometry.fieldCornerRadius`
and `secondaryButtonHeight` are spent on the shared field. What stays deferred
inside surfaces already swept is the **caret readout** beside the bar, which
waits on a design decision rather than on a file, the **lane hues**, and the
unified diff's **per-line checkbox glyph** and **changed-line text tint** (part
five (b)'s departures six and seven), all open design questions. Two roles
remain unspent — `currentLine` and `bracketMatch`, both code zone — after
thirty-seven surfaces, the same two and the same count
`ChromeColorRole.swift`'s own doc comment states.

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
`BranchSwitcherView.swift`, `PullRequestIndicatorView.swift` — plus part four
(a)'s `DockTabRow.swift`, `ProblemsPanelView.swift`, `UsagesPanelView.swift` and
`TerminalPanelView.swift`, **twenty** in all. Part four (b), part five (a) and part five (b) add seven, seven and ten more, each named in its own section above — **forty-four** in all today. `ProjectTreeView.swift` is not among the third part's additions because it
was already there: part three restyled the surface *around* the rows part one
had swept, and a file joins this set once. The draft field is in the set
although it is an editing affordance rather than a row: an inline draft
*replaces* a tree row on screen and must read identically to the row it stands in
for. `TabStripView.swift` covers `TabStatusMark` too, the slot view the two
orientations share, which is why that extraction did not add a seventh file.

The thirty-five rules, each invisible to the compiler:

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
3. **The four exemptions stay exemptions**, disjoint from the gated set and
   still present in the tree: `SyntaxTheme.swift` (a token-kind colour table
   belongs to the *code* zone, which is the editor's own theme, not the chrome's
   design system), `TerminalTheme.swift` (an ANSI-16 palette is a protocol's
   vocabulary — the numbers mean what the escape sequences say, and a role cannot
   stand in for one), `FileIcon.swift` (a Core semantic token iOS still
   paints, so it cannot move behind a macOS-only palette) and, since part four
   (b), `CommitGraphPalette.swift` (a lane colour is an identity token — "this
   line is the same branch as that one" — not a chrome meaning; its eight hues
   are the former system values carried over as light/dark pairs and pinned by
   `CommitGraphPaletteTests`). `CommitGraphView.swift`, which asks that table
   for every lane and spells no colour itself, is *gated*, so the two sets
   meeting at that seam is exactly what the disjointness assertion refuses.
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
   files carrying such a line are themselves a counted set of seven
   (`ProjectTreeView.swift`, `ProjectTreeDraftField.swift`,
   `TabStripView.swift`, since part four (a) `ProblemsPanelView.swift` and
   `UsagesPanelView.swift`, whose one exempted line each is the file-group
   header's `let icon = FileIcon(…)` binding, read for its symbol alone — the
   glyph is drawn in `textSecondary` on a line rule one still scans — and since
   part four (b) `CommitLogView.swift` and `LocalChangesView.swift`, whose
   changed-file rows and folder headers carry the same binding).
9. **The window's chrome is configured in one file.**
   `titlebarAppearsTransparent` is spelled in `MainWindowChrome.swift` and
   nowhere else under `Sources/`, by set equality in both directions. It is a
   property of the *window* rather than of a view tree, so whoever sets it last
   wins and two setters would compete silently — the title bar's ground decided
   by whichever marker reached the window first. The other direction matters
   just as much: the transparency is what reveals the window's background
   colour, so a *removed* setter hands the strip back to the framework's own
   material. The rule has a **second half**, because a unique setter says
   nothing about whether anything ever reaches the window: `MainWindowChrome(`
   is pinned to `PisakaApp.swift` at exactly one occurrence, the scene's own
   attachment, alongside the frame marker sharing that line — delete the
   attachment and every other rule here stays green while the shipped window
   keeps its platform title bar.
10. **Every bottom-bar control is identifiable without sight.** Inside
   `ContentView.swift`, the brace-matched bodies of `bottomBarButton(` and
   `completionToggleButton` each spell `.help(` and `.accessibilityLabel(`, and
   `bottomBarButton(` occurs exactly twice — one declaration and one call inside
   `panelToggles`, which `bottomBar` draws, which builds the toggles from
   `BottomPanel.allCases` and names no panel case in its body, so the bar keeps
   no second list of panels beside the one the dock's tab row reads
   (`BottomPanelTests` pins the order; this rule pins who reads it). Part three made all seven controls icon-only, and the
   `Label(title, systemImage:)` they used to carry *was* each one's
   accessibility name; an unhidden `Image(systemName:)` supplies a name of its
   own instead — the *symbol's* — and `.help(` is a tooltip VoiceOver does not
   read as a name. So the visual decision silently renames named controls after
   their glyphs: nothing misrenders, no other gate goes red, and the only reader
   who notices is the one who cannot see the bar. The bodies are read
   brace-matched, in rule six's idiom, so a `.help(` elsewhere in a
   fourteen-hundred-line file cannot satisfy it; the call count is pinned so a
   seventh dock panel arrives through the one builder whose name the rule
   already requires, rather than as a hand-written call shipping nameless. The
   **same rule read from the other side** covers the bar's three widgets: a
   `Button` combines its children, so each symbol a widget draws folds its name
   into the button's — part one measured exactly that on a tree row
   ("chevron.right, folder fill, Sources"). `ProjectSwitcherView.swift` and
   `BranchSwitcherView.swift` must therefore hide every decorative symbol they
   draw, asserted by counting `Image(systemName:` against
   `.accessibilityHidden(true)` in each file, with
   `PullRequestIndicatorView.swift` the stated exception because it names itself
   outright with an explicit `.accessibilityLabel(`. That count has a **second
   half**, because it went green on the change that broke the thing it exists
   for: two of the hidden symbols were the row's *state* (the current project's
   and the checked-out branch's checkmark), and hiding those satisfies the count
   while leaving every row announcing the same words. So each of the two files
   must additionally spell an `.accessibilityValue(` — the carrier a hidden glyph
   owes back. What the rule does **not** see is stated with it: it cannot tell
   which symbol encoded state, so a value on some other row would satisfy it; it
   pins the shape of the regression, and the rest is the reviewer's, under the
   sweep's own sentence — a symbol whose name or colour varies with a value is
   state.
11. **Every label the bottom bar draws stays on one line.** Part three gave the
   bar `frame(height:)` on `ChromeGeometry.bottomBarHeight`, where its height
   used to come from the padding around its content. A flexible `Text` in a
   fixed-height frame does not make room for itself: a label long enough to wrap
   — a deep project folder, and above all a branch name, the one string here
   nobody chooses for its length — is laid out in two lines and drawn in one and
   a half, clipped by the frame rather than growing it. So each of the three
   files that draw a `Text` inside the bar — `ProjectSwitcherView.swift`,
   `BranchSwitcherView.swift` and `PullRequestIndicatorView.swift` — must spell
   `.lineLimit(1)`, the two switchers with a truncation mode beside it, the same
   answer their own popover rows already give. The honest limit is stated with
   the rule, as rule ten states its own: a source rule cannot see a layout. It
   sees the line that prevents this one, and cannot tell which `Text` in the file
   carries it, so a bar label that lost the limit while a popover row kept one
   would satisfy it. What it pins is that the construct is known here at all —
   which is exactly what the bar did not have, the limit being absent from all
   three. Part four (a) added its four fixed-height surfaces to the list, the
   same shape one strip up: the dock's tab row, whose labels sit in
   `ChromeGeometry.dockTabRowHeight`, and the Problems, Usages and Terminal
   panels, whose headers sit in `panelHeaderHeight` — frames that cannot grow
   either, so the rule now reads as "every label a fixed-height chrome strip
   draws". **The rule takes two forms since review round 01.** The whole-file
   `contains` stays for the three widgets and the dock's tab row, where the
   strip is the file's view. For the three panels it was satisfied by an older
   occurrence — each already spelled `.lineLimit(1)` on master (a file-group
   path, the identifier, a session title), so deleting the limit from a new
   header label left the suite green, and a file-level `contains` is satisfied
   by any older occurrence in the file. Those files now name their header-strip
   builders (Problems' `header` and `severityBadge(…)`, Usages' `header`,
   Terminal's `tab(for:)`), and inside each brace-matched body — rule ten's
   reading — the count of `.lineLimit(1)` must equal the count of `Text(`; a
   renamed builder fails loudly. Part four (b) named its own: the Log's
   `header` and its column-header row's `label(_:)`, the filter bar's
   `filterField(…)` and `dateBound(…)` (the branch picker's menu items are menu
   rows, not strip labels), Local Changes' `toolbar`, and the Pull Requests
   panel's `header` and row `summaryLine`. Two of those have since moved.
   Part five (a) deleted the private `filterField(…)` when the bar's fields
   became the shared field, dropping that builder from the rule. Part five (b)
   moved the date bound's label into the shared checkbox's trailing title, so
   since then that label is counted in `ChromeCheckbox`
   (`ChromeControls.swift`) rather than in `dateBound(…)`, and `LogFilterBar.swift`
   is no longer among the rule's files. The rule's files are therefore
   `ProblemsPanelView.swift`, `UsagesPanelView.swift`, `TerminalPanelView.swift`,
   `CommitLogView.swift`, `ChromeControls.swift`, `LocalChangesView.swift` and
   `PullRequestsPanelView.swift` — a list the suite checks against its own
   set, so it cannot drift again silently. What the counted form still cannot
   see: a `Text` built outside the named builders, or a limit spelled once on a
   container rather than on each label.
12. **The dock's tab row is configured in one place.** `DockTabRow` is drawn
   once, above whichever panel is showing, from `ContentView.panelContent(_:)` —
   the one place every panel passes through, inside the fixed-height slot. Swift's
   `internal` cannot stop a panel file from naming it, and a second call site
   compiles and looks deliberate: a panel drawing its own copy stacks a second
   row in the slot. So reachability is pinned over stripped source: the set of
   files naming the `DockTabRow` token equals `{DockTabRow.swift,
   ContentView.swift}`, the window root constructs it (`DockTabRow(`) exactly
   once and inside `panelContent(`'s brace-matched body, and none of the six
   hosted panel files names the type.
13. **Every dock tab and the close action are identifiable without sight.**
   Rule ten read one strip up. A tab's selection is drawn as an accent strip — a
   shape, not a word — so the brace-matched body of `DockTabRow`'s
   `tabButton(` must spell `.accessibilityLabel(` (the table's name, not whatever
   the label's children fold together), `.accessibilityValue(` (the selection,
   spoken) and `.accessibilityHidden(true)` (the strip that draws it). The close
   action is an icon-only `xmark`, the case rule ten exists for, so
   `closeButton`'s body must spell `.help(` and `.accessibilityLabel(`. Both
   builders are named in the test, so renaming either fails loudly rather than
   leaving the rule to pass over a body it can no longer find.
14. **The dock's swept surfaces draw their own rules.** Each file in the suite's
   named `dockRuleOwners` list — `DockTabRow.swift`, `ProblemsPanelView.swift`,
   `UsagesPanelView.swift`, `TerminalPanelView.swift` and, since part four (b),
   `CommitLogView.swift`, `LocalChangesView.swift`, `PullRequestsPanelView.swift`,
   `DiffView.swift` and `LogFilterBar.swift` — spells no `Divider(` in stripped
   source, and the AppKit diff pane spells no `NSBox`, the same platform
   separator in AppKit's spelling;
   a separating line is a one-point `hairline` rectangle overlaid on the edge the
   surface owns, the breadcrumb's and the bar's precedent. A platform separator
   is wrong here for rule one's reason read through a view: `Divider()` draws the
   system's separator colour, a step off the `hairline` role beside it in either
   appearance, and it is a line *between* two views that neither owns. A named
   list rather than the whole gated set: the files outside the dock were swept
   under their own parts.
15. **The severity mapping is Core's one answer.**
   `ChromeColorRole.diagnosticRole(for:)` decides which role a diagnostic
   severity is drawn in, and the regression this rule prevents is a second
   severity table reappearing in a view — it compiles, draws four plausible
   colours and drifts from the gutter's the first time either is touched. Over
   stripped source: no app file declares `func diagnosticRole`; the set of app
   files spelling `diagnosticRole(for:` equals `{LineNumberRulerView.swift,
   ProblemsPanelView.swift}`, the two known readers; and
   `ProblemsPanelView.swift` names no `SyntaxTheme`, whose severity table is the
   squiggle's and the code zone's alone; and — the clause that catches the table
   by its shape rather than its name, added in the review round because a local
   `switch` returning roles satisfied the other three — no gated file spells a
   severity case label: `case` followed on the same line by `.error`,
   `.warning`, `.information` or `.hint`, or `DiagnosticSeverity.` qualifying
   any of the four. One label is enough to fail, so a mapping covering three of
   the four behind a `default` is caught too. The one exemption is
   `ProblemsPanelView.swift`'s `severitySymbol`, a glyph table (which SF Symbol,
   no colour), named by its declaration and cut out before matching; its body
   must name no `theme`, `ChromeColorRole` or `Color`. Stated limit: the clause
   sees a `switch`'s labels, not a dictionary literal keyed by the same values,
   a chain of `==` comparisons, or a `case` list continued past its first line.
16. **An indicator strip's bottom rule is drawn behind its tabs.** Each file in
   the suite's named `indicatorStripFiles` list — `TabStripView.swift` and
   `DockTabRow.swift` — draws an accent indicator on the strip's own bottom edge
   and a one-point `hairline` along that same edge, and over stripped source
   spells no `.overlay(alignment: .bottom)` whose brace-matched body names
   `hairline`, while at least one `.background(alignment: .bottom)` body does (so
   a strip that lost its rule altogether cannot pass). An overlay covers its
   whole content, so an overlaid rule painted over the lower point of the
   selected tab's two-point indicator — and, in the tab strip, cut the active
   tab's `bgEditor` fill off from the editor it is meant to merge into. A bottom
   overlay drawing the *accent* itself (the strip's cell does) is the indicator,
   not the rule, and stays allowed. Named rather than the whole gated set, rule
   fourteen's shape: a third strip with a bottom-edge indicator joins the list as
   part of being drawn.
17. **The changed-file status mapping is Core's one answer.** `FileStatus.letter`
   and `ChromeColorRole.changedFileRole(for:)` decide what a status is drawn as;
   before part four (b) the mapping was written out twice, byte for byte (the
   Log's detail pane and Local Changes, whose helpers the commit dialog called),
   and the rule prevents a third table and the drift two copies invite rather
   than repairing a drift that had happened. Rule
   fifteen's shape over stripped source: no app file declares `func
   changedFileRole` or a `letter` table (`var letter` / `func letter`); the app
   files spelling `changedFileRole(for:` equal `{CommitLogView.swift,
   LocalChangesView.swift, CommitDialogView.swift}` — the commit dialog is a
   reader although not yet gated; and no gated file spells a status case label
   (`case` followed on the same line by `.renamed`, `.untracked` or
   `.conflicted`) or a `FileStatus.`-qualified case. Stated limit: `.added`,
   `.modified` and `.deleted` are also the diff kinds' case names, which the
   diff surfaces legitimately switch over, so those three are not matched bare;
   a status table must name one of the other three to be caught, and one is
   enough.
18. **The checks-state mapping is Core's one answer.** The glyph, words and
   role of a checks summary and of a job bucket are Core's
   (`symbolName`/`spokenWords`, `ChromeColorRole.checksRole(for:)`). No app file
   declares `func checksRole`; the app files spelling `checksRole(for:` equal
   `{PullRequestIndicatorView.swift, PullRequestsPanelView.swift}`; and no gated
   file spells a case label naming `.noChecks`, `.pending`, `.failure`,
   `.success`, `.pass`, `.fail`, `.skipping` or `.cancel`, or a
   `GitHubChecksSummary.`/`GitHubCheckBucket.`-qualified one. Stated limit: rule
   fifteen's — a dictionary literal, an `==` chain, a `case` list continued past
   its first line.
19. **The diff row wash is Core's one answer, and a macOS diff side is one
   type.** No app file but the palette names `diffAddedBackground` /
   `diffRemovedBackground`; none declares `func diffWashRole` / `func
   diffMarkerRole`; the app files spelling `diffWashRole(for:` equal
   `{DiffView.swift, CommitUnifiedDiffView.swift}`, and neither spells
   `withAlphaComponent(` or `.opacity(` — the wash's alpha is the palette's.
   The side clause: neither reader declares an `enum Side`, and no file under
   `Sources/Pisaka` outside `Sources/Pisaka/iOS/` spells `DiffTextView.Side`, so
   a new macOS caller cannot bring the old type back. Both limits are in the
   rule's own message: the iOS diff view's private `Side` has no chrome palette
   to read and is not gated, and Core's private `ThreeWayMerge.Side` names merge
   sides, not diff sides — the clause never reads `Sources/PisakaCore`.
20. **The three panels' controls are identifiable without sight.** Rule ten
   read over the Log, Local Changes and Pull Requests panels, by a named builder
   list per file (a declaration, narrowed through a path where the builder is a
   type's `body`): each icon-only control's builder spells
   `.accessibilityLabel(`; the checks glyph, the status letter, the checkbox and
   the disclosure chevrons spell `.accessibilityValue(`; and inside a labelled
   control's body every `Image(systemName:` carries an
   `.accessibilityHidden(true)` of its own — in the postfix modifier chain on
   the image, or in the chain on a container brace-enclosing it. The
   checks glyph is the one entry exempt from the last clause, the image being
   the element itself. A renamed builder fails loudly. The binding is the rule:
   its first shape searched all the text after each image, so in `endingStrip`
   the dismiss glyph's modifier satisfied the warning glyph before it, and
   removing the warning's own modifier stayed green. Stated limit: a container
   hidden by a modifier outside the builder's own text is not seen, and fails
   rather than passes.
21. **The Log's filter bar fits the window it lives in.** The requirement,
   stated in `LogFilterBar.swift`'s doc comment: at the main window's minimum
   width, at every interface scale, every control in the bar is reachable and
   nothing is clipped. Over stripped source, the file spells no
   `.frame(width:` — a width there is `minWidth`/`idealWidth`/`maxWidth` — and
   it spells `ScrollView(.horizontal`, the branch that keeps the row reachable
   once its minimums no longer compose. The defect shipped once: fixed widths
   made the row ≈1000 points at scale 1 against a 640-point window, and the
   panel column clipped the branch menu, the message search, the Log header's
   refresh button and the rows' date column. Stated limit: neither half proves
   the layout; each is the half that went missing.
22. **A pushed resize cursor does not outlive its view.** In every gated file,
   each function whose body pushes an `NSCursor` is called from inside an
   `.onDisappear {` block in the same file, and no `.push()` sits outside such a
   function. A hand-rolled divider balances its push from `onHover(false)` and
   the drag's `onEnded`; neither arrives when the divider leaves the tree with
   the pointer on it or mid-drag — the Log's list/detail divide goes when the
   model clears its selection or the dock switches tabs — and `NSCursor`'s stack
   is global, so the cursor stays pushed after the flag that would have popped
   it is gone. The set of pushing functions is pinned by equality (the Log
   divide's and the two `ContentView` dividers'), so a scanner that stopped
   finding them fails rather than going vacuous. Stated limit: the rule sees the
   call, not that the handler clears the hover and drag state before it — a
   handler calling the sync with both still set pops nothing.
23. **A popover surface names `bgPopover`.** The gated files naming `bgPopover`
   equal `{CompletionPanel.swift, HoverPanel.swift, BranchSwitcherView.swift,
   ProjectSwitcherView.swift, LogFilterBar.swift}`; every gated file presenting a
   popover (`.popover(`) or declaring an `NSPanel` is in that set, which is what
   lets the rule see a sixth popover appearing on a system material; and no gated
   file spells `NSVisualEffectView`, a `.material` assignment or
   `presentationBackground`. The five popovers' content is drawn on `bgPopover`
   as a background, with no availability branch, and each file says in one line
   that the arrow keeps the system material because the content background cannot
   reach it.
24. **No gated file spells `Divider()`; a menu separates with `Section`.** No
    gated file spells `Divider(`, and every gated file that builds a `Menu`
    spells `Section` at least once. The gated menu files equal
    `{SearchHistoryMenu.swift, ProjectTreeView.swift, LocalChangesView.swift}`,
    pinned by set equality so a fourth file is added deliberately. The `Section`
    boundary draws the separator a swept surface draws as its own one-point
    `hairline` on the edge it owns.
25. **AppKit layer colours are set only inside the drawing appearance.** In
   `CompletionPanel.swift` and `HoverPanel.swift`, every layer `borderColor`
   assignment and every layer `backgroundColor` assignment lies inside a
   brace-matched `performAsCurrentDrawingAppearance` body; a body containing a
   `borderColor` assignment names `hairline` and a body containing a
   `backgroundColor` assignment names `bgPopover`; each file has at least one of
   each, so the rule cannot pass vacuously; matching tolerates whitespace around
   `.` and `=`.
26. **One field shape and one query toggle.** No gated file spells the
    rounded-border style: `.textFieldStyle(` followed by `.roundedBorder` across
    any whitespace, or `RoundedBorderTextFieldStyle`. The set of files
    constructing the shared field or box equals `{LogFilterBar.swift,
    SearchBarView.swift, ProjectSearchView.swift, BranchSwitcherView.swift,
    CommitDialogView.swift}` (the last since part five (b), its message box),
    plus `ChromeControls.swift`, where the box is composed into the field. The
    shared box has a `bgEditor` ground, a one-point `hairline` border and
    `accent` at the focused width while focused, and takes its horizontal inset
    as a parameter with no height; the themed field is a plain `TextField` over
    it and takes a text-style parameter defaulting to `.callout` plus its inner
    gap defaulting to `6`. The shared query toggle is `ChromeQueryToggle` in
    `ChromeControls.swift`; the set constructing it equals
    `{SearchBarView.swift, ProjectSearchView.swift}`, and no gated file outside
    `ChromeControls.swift` declares a toggle builder. Because the toggle speaks
    its `help` as its accessibility label, the two rows must also speak one name
    per mode — each caller's `help:` literals are exactly "Match case", "Whole
    word", "Regular expression", in that order, read from comment-stripped text
    with literals kept, since the names under test are the literals. This
    entry's file set and the shared field's `Callers:` paragraph are both
    checked against the suite's own set, since both once stopped a caller
    short.
27. **Each measurement follows its own zone.** The Find in Files match row
   carries no fixed `.frame(height:` and is sized by the code font
   (`settings.fontSize`), matched over its brace-matched body so a multi-line
   call cannot slip past; each `cornerRadius` assignment in
   `CompletionPanel.swift` and `HoverPanel.swift` names `metrics` on the same
   statement, so the radius is scaled with the interface. Both clauses carry a
   non-vacuity check — the row's body must be found and must name
   `settings.fontSize`, and each panel must have at least one `cornerRadius`
   assignment.
28. **A secondary window's ground is set in the window subclass.** The files
    constructing `EscClosableWindow` (a call: the token then its argument list)
    equal the six secondary-window controllers, by set equality; none of them
    assigns `backgroundColor` (a whitespace-tolerant assignment pattern, since the
    clause is about an assignment's shape); and the subclass's brace-matched
    designated initializer assigns `backgroundColor` and names `bgPanel`.
29. **The merge wash is Core's one answer.** The `mergeWashRole` token is read
    by `MergeView.swift` alone among the app files; no app file other than
    `ChromePalette.swift` spells `conflictBackground`, `currentLine` or
    `bracketMatch`; no gated file chains `.withAlphaComponent`/`.opacity` onto a
    role's colour (`nsColor(…)`, `.color(…)` or `chromeColor(…)`, brace-matched,
    line breaks allowed — `MinimapView.swift`'s alpha on a syntax-table colour is
    code zone and outside the rule); part five (b)'s ten files spell
    `withAlphaComponent` nowhere; and `MergeView.swift` spells no
    `performAsCurrentDrawingAppearance`.
30. **One primary button, one secondary, one checkbox.** No gated file spells the
    tokens `Toggle`, `toggleStyle` (bare, because `containsToken` rejects a dotted
    needle after an identifier character; the token match is also what keeps
    `ChromeQueryToggle(` from being a hit), `BorderedButtonStyle`,
    `BorderedProminentButtonStyle`, `LinkButtonStyle` or `DefaultButtonStyle`;
    no `.buttonStyle(` argument names `bordered`, `borderedProminent`, `link` or
    `automatic` (scoped to the argument; `plain` and `borderless` stay allowed);
    the files spelling `chromePrimary`, `chromeSecondary` and `ChromeCheckbox`
    are pinned by set equality, the defining file included; no gated file but
    `ChromeControls.swift` declares a checkbox or checkmark measurement; and in
    each of part five (b)'s ten files the `Button` count equals the
    `buttonStyle` count, each file's number stated.
31. **A code pane's ground goes through one definition.** `CodePaneGround.apply(`
    is called in exactly `CodeEditorView.swift`, `SourceViewerContent.swift`,
    `DiffView.swift` and `MergeView.swift`; the rule is **total and resolves no
    types**: across the gated set plus `CodeEditorView.swift`, every
    `backgroundColor` assignment that is not a layer's (`layer.`/`layer?.`, rule
    twenty-five's) lies inside `CodePaneGround`'s brace-matched body or is one of
    five sites pinned by file **and count** — so a second assignment in a pinned
    file fails too — each pin carrying its reason: `EscClosableWindow.swift`, the
    secondary window's ground (rule twenty-eight); `MainWindowChrome.swift`, the
    main window's ground, owned by the window-chrome rule;
    `CompletionPanel.swift` and `HoverPanel.swift`, `.clear` on a borderless
    `NSPanel`, which must stay clear for its own rounded layer to draw and is not
    a code pane; `ProjectSearchView.swift`, a text attribute's background rather
    than a view's. What it no longer claims: it does not identify which object is
    a code pane, because it no longer needs to — it forbids the assignment
    outright outside the sanctioned sites. The earlier form resolved each
    receiver's declared type, and a clip view bound from a pane's property, an
    unwrapped alias and a misread name suffix each walked past it. No gated file
    spells `NSBox`, and `MergeView.swift` spells `DiffDividerView`. The prose
    is held to the same set: every architecture passage enumerating the
    callers — this entry, decision 2 of part five (b) and `app-git-views.md`'s
    `DiffView.swift` entry — names exactly those four files, and the editor's
    deleted private helper is named nowhere under `docs/architecture/`
    (`docs/plans/` is outside the scan: an archive records what was planned).
32. **A window root resolves the theme the root way.** The files declaring
    `func chromeColor` equal `{ContentView, ProjectSearchView, DiffWindowContent,
    MergeView, LocalHistoryView}`; for every gated interface-scaled root, the
    root struct's **whole** brace-matched declaration (not its `body`, since the
    regression is a stored `@Environment(\.chromeTheme)` property) spells no
    `\.chromeTheme`. `SourceViewerContent` is a root that paints no SwiftUI
    colour, its one colour being the AppKit pane ground.
33. **The commit dialog's rows and controls.** `CommitFileRow`'s body applies no
    `.frame(… height:` (the multi-line-aware walk shared with rule
    twenty-seven) and names `TreeRowBackground`, the tree's one state-to-colour
    mapping, while no gated file but `ProjectTreeView.swift` (the mapping's own)
    spells `accentTintStrong`, `selectionInactive` or `hoverTint` inside a
    `switch` whose cases name `selectedFocused` or `selectedUnfocused` — a copied
    table is the regression, and the rule once pinned exactly that copy in
    place; `ChromeCheckbox`'s body spells `accessibilityValue`; and each
    of the merge status strip's two chevrons sits in a button whose modifier
    chain carries `accessibilityLabel`.
34. **Every chrome glyph is sized in the interface zone.** Every
    `Image(systemName:` in a gated file — found through the suite's
    whitespace-tolerant call matcher, so `Image(` with `systemName:` on the next
    line is the same glyph — carries, among its own top-level modifiers, a
    `.font(` whose argument list names `metrics`, or a `.frame(` naming
    `metrics` on a chain that is also `.resizable()`. **A frame alone does not
    size a glyph**: a symbol that is not resizable draws at its font's size
    whatever frame it is given, the frame reserving layout space only. Anything
    else sits in a declaration pinned in `glyphSizeExemptions` with the exact count
    of glyphs it sizes from outside *and what sizes them*, which the rule
    re-checks: a container font (some enclosing block's chain sets `.font(`
    through `metrics`), a use-site font (every use of the declaration is under
    one — the tree draft's icon column), a button style (the enclosing button's
    chain names `chromeSecondary` — the merge strip's chevrons), or
    deliberately off both scales (the unified diff's per-line checkbox, a code
    row's fixed geometry). Re-checking the source is the half that matters: an
    exemption that only counted its glyphs would stay green through the very
    regression — a removed container font — that the rule was written for. The
    shared checkbox's glyph needs no entry; it is resizable and sizes itself by
    frame. The switcher popovers' three row glyphs (`branchRow`,
    `remoteBranchRow`, `projectRow`) carry a metrics `.frame(width:)` that is a
    16-point icon column for alignment, not a size, so they are pinned as
    container-font glyphs and the row `HStack`'s body font is re-checked.
35. **A selectable list yields its selected row's background.** The rule
    **pins the background expression by set equality** and does not read the
    conditional. For every `List` construction in a gated file whose argument
    list names `selection:` — found through the suite's whitespace-tolerant
    call matcher, so a paren on the next line is still a construction — the
    text of every `listRowBackground` argument in its content closure
    (argument list read brace-matched, whitespace runs collapsed) is compared
    with `selectableListBackgrounds`: file name → one entry per selectable
    list, each entry that list's background expressions in source order. The
    comparison runs in both directions, so an unpinned selectable list fails,
    a pin with no list behind it fails, and any changed expression fails —
    a nested conditional, swapped branches, a negated comparison, a condition
    on something other than row identity and a reformat beyond whitespace
    alike. The last is deliberate: the rule cannot read the expression, so it refuses to guess,
    and a person confirms the selected row still yields its background before
    updating the pin. Today the pin holds one list, `LocalHistoryView.swift`'s,
    whose one background is `snapshot.fileName == selection.wrappedValue ?
    Color.clear : chromeColor(.bgPanel)`. On macOS a row background is drawn
    over the platform's selection box, so an unconditional one hides the
    selection outright — the Local History revisions list shipped that way,
    and its selected row is the one Restore applies.

Plus a **self-check** in the suite's own idiom: every gated file must actually
*name* a `ChromeColorRole`, or the checks above have gone vacuous — with eight
exceptions, each naming no role by construction while staying gated for the
rules it *can* break: `ChromeThemeEnvironment.swift`, which carries the
appearance down the tree and paints nothing, and `CommitGraphView.swift`, which
draws only lanes in `CommitGraphPalette`'s colours (both gated for rules one and
two); the five window controllers — `DiffWindowController.swift`,
`MergeWindowController.swift`, `SourceViewerWindowController.swift`,
`LocalHistoryWindowController.swift` and `ProjectSearchWindowController.swift` —
which name no role since the window's ground moved into `EscClosableWindow`
(gated for rules one and two and the window-ground rule, a system colour or a
second, competing ground being what a controller can commit); and
`SourceViewerContent.swift`, whose one colour was the pane's ground and now
comes from `CodePaneGround` (gated for rules one and two and the code-pane
ground rule).

And, beside the rules rather than among them, a **cross-file count**: the suite
counts its own numbered rule markers and asserts that both summaries of it — the
list above and `CLAUDE.md`'s chrome-theme invariant — spell that number in the
sentence naming it, that the list above enumerates exactly that many items
in order, and that the suite's own header inventory — the doc comment
`CLAUDE.md` sends readers to — carries one bolded bullet per rule. The header
was added to the check after it had ended at rule thirty-four with thirty-five
declared: nothing read it while both documents were checked. It gates no source file; it exists because both summaries had already
drifted, each correct on the day it was written, and a count that drifts tells a
reader the sweep is smaller than it is while omitting the newest rules. Same
shape as `LintConfigurationTests`' style-version pair: one source of truth, every
document spelling it checked against that.


And, also beside the rules, **what a rule in this suite may do** — the
convention every new rule is written to, because the rules that broke it are
the ones that failed. A rule pins a **set** by equality (`gatedFiles`,
`colorExemptions`, `diffWashReaders`, `sharedFieldConstructors`), or asserts
the **presence or absence of a token** through `containsToken`, or takes a
**brace-matched body** and does one of those two inside it. It does not
resolve types, evaluate conditionals or decide which of two branches runs.

The evidence is three consecutive review rounds. Each found that a rule
attempting expression analysis did not catch the regression it named: rule
thirty-one resolved which receiver was a code pane and missed bindings,
unwrapped aliases and every name its suffix test did not expect; rule
thirty-four decided what sizes a glyph from the modifier chain around it and
counted a frame that sizes nothing; rule thirty-five searched a
`listRowBackground` argument for two tokens and passed the reversed
conditional. Over the same rounds no set-equality or token rule here failed.
Those three attempts are **the precedents not to copy**. Two of the rules
have since been reduced to the first shape: thirty-one is a total ban on the
assignment with its sanctioned sites pinned by file and count, and thirty-five
pins every selectable list's `listRowBackground` expression by set equality and
no longer reads the conditional at all, so any changed expression fails and a
person re-confirms it. Thirty-four stays the one rule still reading a modifier
chain, narrowed rather than extended. No fourth shape is permitted and no rule
is excepted from the three.

The consequence, stated plainly: a property that cannot be expressed this way
is **not pinned by this suite at all**. It belongs in the app-layer bundle
(`Tests/PisakaAppTests`), which can construct the view and ask it, or in the
acceptance review's own reading — never in a rule that claims more than it
holds, since a rule that is believed and does not hold is worse than none.

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
    token or it is a drift waiting to happen. Part five (a) added five more:
    `fieldCornerRadius` (4), `fieldFocusedBorderWidth` (2), `fieldPaddingX` (10),
    `secondaryButtonHeight` (28) and `secondaryButtonPaddingX` (14) — each a
    distinct token with its own comment, none derived from another. Part five
    (b) added three: `dialogEdgeStripHeight` (44), `checkboxSide` (14) and
    `checkboxCornerRadius` (3). A number belonging to one *shared shape* — the
    checkbox's 10-point glyph — stays a named private constant in the shape's
    file, with its reason. The one exception to the scaling
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
