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
wash and marker — verbatim over `allCases`, `ChromePaletteTests` (app
bundle) pins the values themselves, and `TreeRowBackgroundTests` (app bundle,
since part five (g)) pins the project tree's state-to-role mapping and that it
composes no alpha.

The chrome theme is a **reader**: it takes no writer gate, is gated by none, and
adds no write of any kind. Its only persisted input is the existing
`SettingsStore.themePreference`; it writes nothing.

## Core

  - `ChromeColorRole.swift` — the closed role enumeration: a `public enum`,
    `String`-raw-valued, `CaseIterable`, `Hashable`, `Sendable`, **twenty-two**
    cases in six groups — backgrounds (`bgCanvas`, `bgPanel`, `bgEditor`,
    `bgPopover`), text (`textPrimary`, `textSecondary`, `onAccent`), lines and
    accent (`hairline`, `accent`, `accentTint`, `accentTintStrong`), row and
    line states (`hoverTint`, `dropTargetTint`, `selectionInactive`,
    `currentLine`, `bracketMatch`), status (`statusGreen`, `statusRed`, `statusYellow`) and
    diff and merge (the three backgrounds). A role names a **meaning**; it
    carries no colour at all, which is what keeps Core Foundation-only and
    portable, and is the same split `FileIconColor` already makes. **The set is
    closed against call sites.** The sweep adds *views*, not roles: a surface
    that appears to need a role of its own has found a design question, and the
    answer is to reuse an existing role or to change the design — not to grow
    the table, which would end as one role per call site and no design system at
    all. The set has grown **once**, in part five (g), and for the other reason:
    the design states three strengths of the accent wash and the table carried
    two, so `dropTargetTint` is a value the design already stated, not a call
    site's request. A role whose only justification is a call site is still a
    case for the refusal. Several roles are consequently still
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
    `bracketMatch`. The current-line highlight then spends `currentLine` — the
    full-width band the layout manager paints under the caret's line and its
    continuation in the gutter (see *The current-line highlight*, below) — which
    leaves **one**: `bracketMatch`, deliberately still unused, because it
    belongs to the *code* zone, whose matched-pair overlay is a temporary text
    attribute on the editor's own theme (`SyntaxTheme`), so spending it is a
    decision about where the chrome ends rather than a restyle. It is declared
    nonetheless, because the table is the design rather than an inventory of
    today's call sites. The raw values are the stable names the
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
    (context nil, removed and added their grounds), `diffTextRole(for:
    UnifiedDiffLine.Kind)` (context nil, removed `statusRed`, added
    `statusGreen` — the unified diff's text tint, drawn on top of the wash) and
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
    `DocumentPageChrome.resolved(_:systemPrefersDark:)` (which
    `LeetCodeStatementDocument.Theme` aliases since part five (e), and which now
    delegates to this one) — and is
    kept identical on purpose.
  - `DocumentPageChrome.swift` — the chrome of a **served document page**, as
    CSS colour strings: the one value both served pages take since part five
    (e) — the Markdown preview (`MarkdownPreviewTheme.chrome`) and the problem
    statement (`LeetCodeStatementDocument.Theme`, a typealias for it). Six colour
    fields and `colorScheme`, and **every colour field is a role**:
    `role(for: Field)` is the whole mapping, and `init(appearance:value:)` fills
    a value from it through a `(ChromeColorRole) -> String` the app supplies, so a
    page never names a colour of its own — only which role each of its meanings
    takes. Seven page meanings map onto six existing roles, no new one:

    | Page meaning | Role | dark | light |
    |---|---|---|---|
    | `background` (the page) | `bgEditor` | `#2f3136` | `#ffffff` |
    | `text` | `textPrimary` | `#dfe1e5` | `#1d1d1f` |
    | `secondaryText` | `textSecondary` | `#a0a3aa` | `#6e6e73` |
    | `link` | `accent` | `#4f8dff` | `#2f6fe0` |
    | `codeBackground` (`pre`, `code`, a table's header row) | `bgCanvas` | `#1e1f22` | `#f5f5f7` |
    | `border` (and the former `tableBorder`) | `hairline` | `#393b40` | `#d1d1d6` |

    `colorScheme` is `"dark"` or `"light"`, taken from the appearance — CSS
    `color-scheme`, not a colour.
    **The page ground is `bgEditor`; a code block is `bgCanvas`.** The roles' own
    definitions decide it: `bgCanvas` is the window's ground, behind everything
    that has no surface of its own, and a served page *has* one — it sits beside
    the editor and reads as the same paper — while a fenced block is a recess
    showing the window ground beneath it. `bgCanvas` for the page was rejected
    (the page would become the window ground, and in light the code blocks would
    be the brightest thing on screen), and so was `bgPanel` for code: **a code
    block draws no border on either page** — `preview.css`'s `pre` rule sets
    only background, radius and padding, and the statement stylesheet the same —
    so the difference between the two grounds is the only thing separating a
    block from the page, and in dark `#2b2d30` against `#2f3136` would make it
    effectively invisible. The two grounds must therefore stay distinguishable
    (`DocumentPageChromeTests` asserts the six roles pairwise distinct and the
    two grounds apart), and **only a change that adds a border to a code block
    may revisit the pair**.
    **The shape is fallback plus derivation**, the code half's
    `withCodeColors(_:)` precedent. `light`/`.dark` restate the palette's
    entries for the six roles — the fallback iOS reads (it has no palette) and a
    Core test can check (`DocumentPageChromeTests`: the role table pinned
    exactly, the fill routing each field through its own role, the restated
    blocks lowercase six-digit hex). macOS replaces them **wholesale** with
    `ChromePalette.documentPageChrome(in:)`, so no restated string survives
    there. Two app-bundle tests, deliberately separate: `ChromePaletteTests`'
    `testTheDocumentPageChromeCarriesThePaletteInBothAppearances` pins the
    derivation against the palette in both appearances, and
    `testCoresRestatedDocumentPageChromeEqualsThePalettesDerivation` pins Core's
    restated blocks equal to it — a second test because the derivation replaces
    Core's block and the first therefore cannot see it. Changing a palette value
    changes both served pages on macOS with no other edit; the second test then
    fails until Core's fallback follows, which is the intended second safety net
    rather than a second edit the screen needs.
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
  - `DesignGlyph.swift` — the design's glyphs as one name table: a `String`-raw
    `CaseIterable` enum, twenty-five cases, whose **raw value is the asset
    name** in `Sources/Pisaka/Assets.xcassets/Glyphs/` (`assetName` returns it),
    and nothing else: the enum is a **name table only**. Every asset is a
    24-unit box at the icon set's native coordinates, so a glyph's drawn size
    is always the drawing surface's, stated at the call site in points at
    interface scale 1.0. The former per-glyph native-size column is gone: it
    recorded each media box as the previous export stated it, and once every
    glyph sits
    in the same 24-unit box — and the design draws one glyph at several sizes —
    a per-glyph size means nothing. Foundation-only, colour-free:
    it names a picture, and the role it is tinted with is the drawing site's.
    `DesignGlyphTests` pins the names only; `DesignGlyphAssetTests` holds
    the case set equal to the catalog's imagesets by set equality, each PDF to
    the export manifest's sha256 prefix, each imageset to the template intent
    and preserved vector data, every row of the size column
    `Resources/DesignGlyphs/VENDORED.md` records to exactly 24, every shipped
    PDF's media box to `[0 0 24 24]` — any other page box too, and every box
    and rotation written inline, an unreadable one failing, and every key read
    with comments as whitespace and name escapes decoded, whitespace being
    PDF's six bytes rather than Unicode's, the stream's `/Length` and
    `/Filter` each declared exactly once among its dictionary's own outer
    entries and no `/DecodeParms`, `/F`, `/FFilter` or `/FDecodeParms` among
    them — a predictor or an external file would make the drawn bytes differ
    from the inflate the check reads — read as key–value pairs so a name standing as another entry's
    value is not a key, a nested dictionary's keys not counting, the `stream` and
    `obj` keywords found only as whole tokens outside comments, strings and
    names, the filter name and the closing `endstream` read as whole tokens
    too, a literal string that never closes failing — with every path
    coordinate of its one decoded content stream inside that box, and `project.yml`'s asset
    symbols to off, which rule forty-six relies on. The one helper that draws them
    is `DesignGlyphImage.swift`, under "The design's glyphs" below.
  - `FileGlyph.swift` — which design glyph stands for a file or a folder on the
    macOS chrome. `forFile(named:)` has three answers: `database` when
    `DatabaseFileRule` recognises the name (asked first, so a `.db` file is not
    text), `file-text` for a name no `SyntaxLanguage` claims and for Markdown,
    `.gitignore`, `.env` and `.editorconfig`, and `file-code` for every other
    language — the language switch is exhaustive, so a new language is a compile
    error until it is placed. `forFolder(expanded:)` answers `folder-open` or
    `folder`. It reads the two rules that already own the question rather than a
    third extension table, and `FileIcon` is untouched for iOS.
    `FileGlyphTests` walks every `SyntaxLanguage` through a sample table held
    equal to `allCases`, plus the database extensions, unknown names and folders.
  - `PopoverPlacement.swift` — where the bottom bar's popover and its submenu
    go, as pure static functions over `CGRect` in the **window root's
    top-left, y-down space** (the space a SwiftUI named coordinate space at the
    root reports; no screen coordinate is involved, because the popover is
    drawn inside the window). `popover(widget:barTop:window:width:maxHeight:gap:)`
    answers a `PopoverAnchoring` — leading x, bottom y, available height. The
    popover opens **upward**, left-aligned to its widget: x is the widget's
    `minX`, shifted left to `window.maxX - width` when the widget sits nearer
    the right edge than `width`, and never below `window.minX` (a window
    narrower than the popover pins it there); the bottom is `gap` above the
    bar's top; the available height is `min(maxHeight, bottom - window.minY)`,
    never negative, so a short window caps the container and the List shrinks
    instead of anything drawing outside the window.
    `submenu(popover:anchorRowTop:size:window:gap:)` answers the submenu's
    frame: `gap` right of the popover with its top at the anchor row's top,
    **flipped** to `gap` on the popover's left when it does not fit on the right,
    then clamped inside the window on both axes — shifted up when its bottom
    would pass the window's bottom, never above the top. `PopoverPlacementTests`
    pins the ordinary case, the right-edge shift, the narrow window, the short
    window, and the submenu's fit, flip and upward clamp, on literal frames.
  - `PopoverSelection.swift` — the keyboard selection over a popover's rows: a
    row count and an optional selected index. `init(count:)` selects the first
    row, or nothing at zero; `movedDown()`/`movedUp()` clamp at both ends with
    **no wrap**; `reset(count:)` returns to the first row and is what every
    filter change does; `selecting(_:)` jumps to a row, clamped, and is what
    the Welcome screen's column switch uses. The submenu uses the same type over
    its own rows. `PopoverSelectionTests` pins the init, the empty count, both
    clamps, the clamped jump and the reset, including a reset to a smaller count.
  - `PopoverKeyRule.swift` — **every** decision about which key does what in
    the popover, as one pure `action(for:state:)` over three closed types:
    `PopoverKey` (`up`, `down`, `return`, `escape`, `left`, `right`, `other`),
    `PopoverKeyState` (`submenuOpen`, `hasSelection`, `selectedHasSubmenu`) and
    `PopoverKeyAction` (`moveUp`, `moveDown`, `activate`, `openSubmenu`,
    `closeSubmenu`, `dismiss`, `passThrough`). The full table:

    | key | submenu open | submenu closed |
    |---|---|---|
    | ↑ / ↓ | `moveUp` / `moveDown` with a selection, else `passThrough` | the same |
    | Return | `activate` with a selection, else `passThrough` | `openSubmenu` on a row with a submenu, `activate` on any other selected row, `passThrough` with none |
    | → | `passThrough` | `openSubmenu` on a row with a submenu, else `passThrough` |
    | ← | `closeSubmenu` | `passThrough` |
    | Esc | `closeSubmenu` (the submenu alone) | `dismiss` |
    | `other` | `passThrough` | `passThrough` |

    `selectedHasSubmenu` is ignored with the submenu open, and
    `selectedHasSubmenu` without `hasSelection` is impossible and read as no
    selection. **`other` always passes through**, which is what keeps typing
    reaching the filter field: the field holds the text focus throughout, and
    the keys the popover owns are taken off the event stream before it, not
    routed through it. `PopoverKeyRuleTests` enumerates all 7 × 8 = 56 (key,
    state) pairs against one literal table held equal to that product by set
    equality, plus named assertions for `other` in every state, the
    meaningless ← and →, Esc's two answers, Return opening rather than
    activating, and the impossible combination.

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
(`0x22`, `0x33`, `0x0A`, `0x26`, `0x66`) rather than a fraction rounded away from them;
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
and `currentLine` was then painted by *nothing
at all*, its only occurrences being its declaration, its palette row and the
comment on the row above it. The two had therefore never shared a surface, and
the only thing that looked different after the change was one tree row's
background. What `ChromePaletteTests` states —
`testTheInactiveSelectionWashIsNotTheCurrentLineWash`, asserted in both
appearances through `ChromeTheme` and through the concrete AppKit colours — is a
rule about what was then the *future* and is now spent: the current-line
highlight (see *The current-line highlight*) must not arrive in the selection's
own wash, and the assertion is what keeps it from doing so. It is written as the property rather than as
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

**One row has been added since.** `dropTargetTint` (part five (g)) is the
accent's own hues, `dark: 0x4F8DFF, light: 0x2F6FE0`, at `0x66` (102 ÷ 255 =
0.4) — the third strength of the accent wash, above `accentTintStrong`. Its one
consumer is `ProjectTreeView.swift`'s `TreeRowBackground.role(for:)`, `case
.dropTarget`. `testTheDropTargetWashIsTheAccentAtAThirdStrength` asserts in
both appearances that it has `accent`'s RGB, an alpha strictly between
`accentTintStrong`'s and `accent`'s, and exactly `0x66`.

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
    *colour* change by hand** (the terminal, a host that stores concrete
    colours, is the stated exception — see the next bullet): the Theme preference is applied as
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
    dynamic form — with the terminal as the stated exception (part five (h)):
    SwiftTerm stores the colours it is given and never re-resolves them, so
    `TerminalTheme` is handed concrete colours resolved by appearance and
    re-applies them on every appearance change.
  - `color(_ role:in:)` — the SwiftUI `Color` of one appearance, composed from
    the same row rather than converted from an `NSColor`.

Since part five (e) the table has a **CSS reading** as well, for the two served
pages. `cssHex(_:in:)` formats one role's entry of one appearance as lowercase
`#rrggbb` — `#rrggbbaa` when the row's alpha is not `0xFF` — and is defined in
this file alone (gating rule forty-two, clause (d)), so a hex string for a role
is spelled one way. `documentPageChrome(in:)` is the one derivation both pages
take: `DocumentPageChrome(appearance:value:)` filled through `cssHex`, the role
mapping staying Core's. Its two callers, `MarkdownPreviewPane.swift` and
`LeetCodeDescriptionView.swift`, are pinned by set equality (clause (a)).

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
    Full entry in `app-window.md`. **Against the design**, the window's top edge
    reads: a 28-point title bar on `bgPanel`, the 32-point strip
    (`ChromeGeometry.tabStripHeight`) on `bgPanel` directly under it, the active
    tab filled in `bgEditor` inside the strip only, and no line between the title
    bar and the strip. Three defects broke that, all observed on 2026-10-04
    off window captures of the Debug build. The line was the window's automatic
    title-bar separator, now set to `.none` by `MainWindowChrome` and pinned by
    rule nine. The second was a **safe-area climb**: the active tab's `bgEditor`
    fill ran through the title bar's 30 rows to the window's top edge. The strip
    is the topmost view of the editor column under the transparent title bar,
    which is the window's top safe-area inset, and a SwiftUI shape-style
    `.background(_:)` extends into the safe area by default. The active cell's
    fill therefore passes `ignoresSafeAreaEdges: []`, which confines it to its
    own frame. The third came from confining the strip's `bgPanel` ground the
    same way: the title bar turned **two-toned** — `bgPanel` above the sidebar,
    whose ground still extends into it, against `bgCanvas` above the editor
    column, the `ContentView` root's ground showing through where the strip's
    no longer covered it. So the division is deliberate: **the strip's ground
    keeps the default and paints the title bar** above the editor column,
    exactly as the sidebar's ground does above the sidebar and the tab column's
    does with vertical tabs, and **only the active cell's fill stays inside the
    strip**. The bottom rule, a view background
    (`.background(alignment: .bottom) { … }`), does not climb and is unchanged.
    Rule forty-seven pins both halves, and is the only net: the headless
    `HostedRender` has no title bar, so neither the climb nor the two-toning can
    be seen off a bitmap.
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
    `app-window.md`. Every row state answers with a role or with nothing, through
    the one mapping `TreeRowBackground.color(for:resolving:)` that both row kinds
    read: a `dropTarget` row takes `dropTargetTint` (since part five (g); it was
    `accent` at a composed 40 % before), and only `plain` paints nothing. Hover,
    selection and drop are all true at the moment a drag sits over a selected row
    (the pointer is inside it), so the drop treatment has to out-read
    `accentTintStrong`, which it does by being the same hue at a heavier wash —
    a strength the palette now carries, so the mapping composes no alpha.
    `TreeRowBackgroundTests` pins the mapping and that it composes none, and the
    mapping takes the theme as a role-to-colour *function* so no view file names
    the theme's type (rule five).

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
    the pure `LineNumberRulerView.backgroundRect(in:bounds:ruleThickness:)`. Full entry,
    including why no gate in the pipeline could see it, in
    `app-editor-overlays.md`.
  - **The vertical tab column** — `TabListView.swift` and `TabRowView.swift`, the
    environment path. The column states the strip's vocabulary turned through a
    right angle: `bgPanel` ground, **no pane-edge rule at all** — its host is the
    `HSplitView` in `ContentView.editorSplit`, whose splitter already states the
    column/editor boundary, exactly as the gated `ProjectTreeView` beside it in
    the same split view leaves its own — a one-point `hairline` rule along every
    row's bottom, the active row's ground **unchanged** (no fill; the design's
    column marks it only by the `accentIndicator`-wide `accent` bar on its
    **leading** edge rather than underneath), `textPrimary` for the active label
    and `textSecondary` for the rest, `hoverTint` for an inactive row under the
    pointer only, and the monochrome `FileIcon` symbol. The two orientations stay two views on purpose: they state
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
  - **The language-server consent bar** — `LSPConsentBanner.swift`, the
    environment path, drawn by one shipped view, `LSPConsentBar`, that all three
    questions build and that nothing else in the file bypasses. The values, as
    literals: a **full-width** `bgPanel` ground, edge to edge, padded 14
    vertically and 18 horizontally, with a 1-point `hairline` rule
    (`hairlineWidth`, a filled `Rectangle`) along its bottom separating it from
    the editor — exactly as the breadcrumb bar and the find bar end, and no
    `Divider()` (a divider is drawn in the *system's* separator value and would
    disagree with the `hairline` rules beside it in either appearance). Inside,
    one vertically centred row — a 16-point `accent` icon, the text column 10
    beyond it, then a spacer of at least 16 and the actions at the trailing
    edge. No radius, no border, no inset band and no `bgEditor`.
    **A deliberate deviation from the design's Banner component.** That
    component is a bordered card with radius 6; an earlier pass drew it as such,
    floating in an 8-point `bgEditor` band, and between two full-width bars with
    bottom rules — the breadcrumb above, the editor below — it read on screen on
    2026-10-04 as a misplaced block (the line-number gutter's overpaint, since
    fixed in `LineNumberRulerView`, made its left edge look 48 points in as
    well). The component's inner geometry is kept, and the card stays the
    design's answer should a floating placement ever appear.
    The primary line is the body size (13) in `textPrimary`; the optional
    secondary line — present only for the YAML runtime-network note and the Go
    build's toolchain path — is the subheadline size in `textSecondary` and
    wraps across the whole column; the icon is `accent`. Every length goes
    through `metrics.scaled(_:)` and the icon's 16 is the one design literal,
    sized on the `Image`'s own chain. The two actions are the shared styles, as
    everywhere else in the chrome, 8 apart: the confirming one `.chromePrimary`
    and the declining one `.chromeSecondary`, both at their fitting width so
    they never wrap or truncate. The design draws its own 28-point accent button
    with a 12-point semibold label; the bar keeps the shared styles instead, the
    same known and accepted chrome-wide difference as every other surface's
    buttons, because a one-off pair beside the styles every other surface uses
    is itself the mixed look this sweep removes (the strip's two private helpers
    went for that reason in the design pass); rule thirty's caller sets name the
    file under both styles. The weight of the two buttons is the only thing
    saying which is the offer, which is honest: both answers are
    non-destructive and reversible from Preferences. No keyboard shortcut is
    added — the reason in that file's own comment (a default button in the main
    window takes Return before the first responder, so every newline typed in
    the file below the bar would start a download) still holds.
    **The text column carries no layout priority**: a hand mutation showed a
    raised priority on it changed nothing drawn, so it went, and the suite pins
    the drawn width instead. `LSPConsentBarLayoutTests` (the
    app-layer bundle) pins the drawn contract off a bitmap at scales 1 and 1.8 —
    `bgPanel` half a point in from the top-leading corner (nothing is inset) and
    at the middle, the bottom rule one scaled hairline tall with its `maxY` at
    the scaled 14 + 28 + 14 plus that hairline, spanning the full width, and the
    window's ground below it — and, at scale 1, that the primary line keeps one
    line at a width derived from its own measured ink and the primary button's
    measured edge, plus a guard that the generous render is itself one line; and
    that a wrapped secondary line reaches past three quarters of the column
    toward the actions. A column capped at 400 points fails both width tests.
    Full entry in `core-provisioning.md`.

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
    actually seen is the no-file-open placeholder and the Welcome screen, which
    replaces the whole split and paints it itself (*The Welcome screen*, below),
    and nowhere else**: the
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
    with a `textSecondary` icon when not (since the design pass: the panel's
    design glyph at 13 on an `accentTint` ground — see the design-pass bar
    entry below). That visual decision is what rule ten
    exists for: the `Label(title, systemImage:)` they carried *was* each one's
    accessibility name, so every one of them now spells a tooltip and
    `.accessibilityLabel(` (since the design pass the tooltip is `BarToolTip(`,
    an AppKit `toolTip`, and `.help(` — which never showed — is refused) — nothing misrenders without them, and the only
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
  - **The design pass's bar.** The widgets' and toggles' SF Symbols became the
    design's glyphs, drawn through `DesignGlyphImage`: `package` 12 /
    `git-branch` 12 / `git-pull-request` 12 leading each widget and
    `chevron-down` 10 trailing both switchers; the indicator's checks mark is
    `check` in `statusGreen` or `x` in `statusRed` for a verdict
    (`GitHubChecksSummary.indicatorGlyph`, a Core column) and today's symbol at
    12 otherwise; each toggle shows `BottomPanel.glyph` at 13 in its 22-point
    square, and the active toggle's ground is `accentTint`, no longer
    `accentTintStrong` — the completion switch's too. The Pull Requests panel's
    rows keep `symbolName`. `BottomBarLayoutTests` measures the result.

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
added — and the comment beside each hidden symbol said it was hidden *because the
state it showed is now spoken*, not because it was decoration. The remote-branch
row needed nothing and said so in a comment: its glyph did not vary with
`isCurrent`, so it carried no state to owe back. (Those symbols and comments are
gone with the in-window component: the current row's state is handed as an
accessibility value to the shared row piece, whose `.check` hides itself through
`DesignGlyphImage` and needs no comment, and the remote row's trailing chevron
never varies with `isCurrent`, its accessibility hint being its only
annotation.) The rule the sweep reads is the
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
and it is seen at the no-file-open placeholder and the Welcome screen (the part-three window-ground
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
    fixed-height slot, so the slot's pinned frame, its top alignment, the bar's cover,
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
    `dockTabLabelPaddingX`. The padded title alone sizes the tab; the
    `accentIndicator`-thick strip is a bottom overlay that takes its width from
    the title and so can never ask for width of its own (a stacked strip that
    accepted any width made every tab greedy and spread the row;
    `app-window.md`, `DockTabRowLayoutTests`): `accent` when selected,
    `Color.clear` otherwise, so the tab's height never changes with selection. A click asks Core's
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
    container and the terminal's ANSI-16 arrays are **untouched**: the ANSI-16
    is the terminal zone, not chrome. The terminal's four chrome colours —
    ground, text, caret, selection — were swept later, in part five (h). Full
    entry in `app-terminal.md`.

**Six tabs, not seven.** The design draws a seventh tab naming a panel this
application does not have. A tab that does nothing when clicked is a defect, not
a placeholder, so it is left out; the six are exactly `BottomPanel`'s cases.

**One name per panel, as one Core table.** `BottomPanel.title` answers
"Terminal", "Log", "Local Changes", "Problems", "Usages" and "Pull Requests",
and both the tab row and the bar's toggles read it (`bottomBarButton` lost its
`title:` parameter, and in the review round its `systemImage:` one too — the
glyph was `BottomPanel.systemImage`, the same table's second column — since the
design pass `BottomPanel.glyph`, a `DesignGlyph` — and the bar
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

  - **The Log panel** — `CommitLogView.swift`, the environment path. Since the
    design pass it draws no title row: the refresh controls sit at the filter
    strip's trailing end. A static, non-interactive column-header row
    (Message / Author / Date / Hash, 24 pt) reads the rows' own widths; rows
    are 25 pt, 12 pt inset, 16 pt column gap; washes `accentTintStrong` /
    `hoverTint`, ref badges `accent` on `accentTint`; the date is relative
    (`RelativeCommitDate`), the exact date and time its tooltip. The graph column is `max(40, lanes × 14 + 6)` pt, scaled,
    40 being a named minimum. The three `Divider()`s are the surface's own
    hairlines — including the list/detail divide, which is therefore a hairline
    with a drag strip rather than an `HSplitView`. Full entry in
    `app-git-views.md`. The database viewer's sidebar divide has since taken the
    same shape — a hand-drawn hairline with a drag strip rather than a platform
    divider (`core-database-viewer.md`); its `VSplitView` divider stays the named
    open departure.
  - **The graph gutter** — `CommitGraphView.swift`, AppKit, reading
    `CommitGraphPalette` and spelling no colour; 2 pt lines, a 6 pt dot, 14 pt
    lanes. Full entry in `app-git-views.md`.
  - **The filter bar** — `LogFilterBar.swift`, the environment path: one
    `panelHeaderHeight` strip on `bgPanel` keeping every control, each in a 22 pt
    box (4 pt radius, `bgEditor`, a `hairline` border that becomes a two-point
    `accent` one on focus). Full entry in `app-git-views.md`.
  - **The Local Changes panel** — `LocalChangesView.swift`, the environment
    path. Since the design pass: a 36 pt toolbar leading with Commit… in the
    shared `.chromePrimary`, then the `undo-2` and `refresh-cw` design glyphs at
    15; a 320 pt list of hand-drawn folder rows (the design's chevron and folder
    glyph, `textSecondary`) over checkbox / status letter / name file rows; a
    `hairline` divider to the inline `DiffView`. The context-menu `Divider()`s
    are `Section`s rendering the same separators. Full entry in
    `app-git-views.md`.
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
     the row wash through `diffWashRole(for: UnifiedDiffLine.Kind)`, an added or
     removed line's text through `diffTextRole(for:)` (`statusGreen`/`statusRed`,
     context text keeping `SyntaxTheme`'s plain colour), the file and hunk header
     rows `textSecondary`, the checkbox `accent`/`textSecondary`, line numbers
     `textSecondary`. A changed line's
     wash spans the whole pane: the horizontal scroll axis proposes no width, so
     a row's own fill resolved to its text's width, and the content is now as
     wide as the larger of the pane's measured visible width and the widest
     realized row's natural width, every row filling it —
     `CommitUnifiedDiffWashTests` (app-layer bundle) samples the washes at the
     trailing edge, before and after scrolling an overflowing diff. Gated in
     full; the commit dialog around it is untouched except for reading the
     status answer. Full entry in `app-git-views.md`.

#### Part five (a) — the popovers and the search surfaces

The sweep's first floating surfaces and its two search surfaces: the completion
panel and the hover popover, the find/replace bar above the editor, the Find in
Files window and its window controller, the recent-searches menu, and the two
bottom-bar popovers plus the Log calendar. It spends `bgPopover`, leaving three
roles unspent at the time (`currentLine`, `bracketMatch`, `conflictBackground`), and takes
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
taking its horizontal inset as a parameter and an **optional height from its
caller**: given one (unscaled, scaled by the box like its padding), the box frames
itself at exactly that height and draws its ground and border on that frame, the
content vertically centred — 22 in the Log filter strip (its three fields and its
two date bounds), 33 in Find in Files' three fields, 26 in the two LeetCode
inputs; given none, it is sized by its content and is never greedy, which is what
the in-editor find bar, the branch switcher's filter, the commit dialog's author
fields, the two pull-request sheets' fields and the grid's cell editor get.
`ChromeThemedTextField` threads the height through both initialisers as
`height:`. **Why the height is stated to the box.** Those callers used to frame
the height *outside* the field, which only added transparent room around a box
that still hugged its text line — a one-line box, its border lost under the
platform's focus ring. The box cannot instead fill whatever height it is offered:
a stack's spare room reaches it exactly as a caller's fixed frame does, so a
filling box grew the find bar above the editor from about 29 points to about 239.
Only the caller knows which of the two it means, so the caller says it.
`ChromeThemedTextFieldLayoutTests` (app bundle) renders a field given 33 points
and samples its `bgEditor` ground and `hairline` border above and below the text
line, and hosts an unheighted field above a flexible view in a tall window and
holds it to one text line — the find bar to its tallest control, the field's
line or the query toggle's fixed 22-point square since the toggles draw a
16-point glyph — both at interface scale 1 and 1.8. **The platform's
focus ring is suppressed** on the inner field (`.focusEffectDisabled()`), so the
box's `accent` border is the one focus indication; the platform draws that ring
only on a key window with real first-responder focus, which the headless bundle
cannot reliably reach, so that half is pinned by gating rule forty-five and the
live check. `ChromeThemedTextField`
is a plain `TextField` with `textPrimary` content, an optional leading glyph
hidden from accessibility, and a spoken name — drawn as a `textSecondary`
placeholder while the field is empty when built with `title:`, never drawn when
built with `spokenName:` (the grid's cell editor alone, pinned by set equality),
focus
coming in as a `FocusState` binding plus the value it equals — taking a
text-style parameter defaulting to `.callout` (so the Log filter bar's pixels stay
as they are) and an inner gap defaulting to `6`, with Find in Files' three
fields and the branch switcher's filter passing `.body`. `ChromeQueryToggle` is
the one query-mode toggle (glyph, `isOn` binding, help text), drawing the mode's
design glyph through `DesignGlyphImage` at 16 in a 16-point slot padded 3 — the
design's size; the asset is the 24-unit box every glyph shares — `accent` on `accentTint` while on,
`textPrimary` with no ground while off (it drew an `Aa`/`ab`/`.*` label at
`subheadline` semibold monospaced until the design-match pass), with the spoken
name, tooltip and on/off value both surfaces already had. `ChromeSecondaryButtonStyle`
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
two boxed system controls — the two date bounds — through the box at 22 high and
its own inset — the branch menu was a third until part five (c) lifted it into
the shared `ChromeMenuField`, which composes the box inside its own definition,
so the Log bar no longer builds one for it — plus the box as the filter-field baseline
with its private `controlBox`/`filterField` and the `FilterBarLayout` entries
`controlRadius`/`focusBorderWidth` deleted), `SearchBarView.swift` (the query and
replace fields) and `ProjectSearchView.swift` (the query row, the replace row and
the file-mask field) and `BranchSwitcherView.swift` (the popover's filter field,
via the themed field with its own `FocusState`) and — since part five (b) —
`CommitDialogView.swift` (the message box, through the box alone around its
`TextEditor`) and — since part five (c) — `NewPullRequestSheet.swift` and
`PullRequestMergeSheet.swift` (each sheet's title or subject through the themed
field, and its body through the box alone around its `TextEditor`, the commit
dialog's shape) and — since part five (d) — `DatabaseViewerView.swift` (the
grid's cell editor, through the themed field's `spokenName:` initializer over
the grid's own focus state — the column's name spoken, never drawn), `LeetCodeBrowserView.swift` (the browser's query,
through the themed field with the magnifying-glass glyph),
`LeetCodeOpenProblemSheet.swift` (the sheet's problem input, through the themed
field over its own focus state) and `LeetCodeJudgeView.swift` (the test-case
box, through the box alone around its `TextEditor`, the commit dialog's shape). The Log bar's doc comment says
the shape is shared. Tokens are in `ChromeGeometry`: `fieldCornerRadius` 4,
`fieldFocusedBorderWidth` 2, `fieldPaddingX` 10, `secondaryButtonHeight` 28,
`secondaryButtonPaddingX` 14, each distinct and none derived.

**The three SwiftUI popovers get one answer, with no branch.** The Log
calendar, the branch switcher and the project switcher each carried `bgPopover`
on their content as a background, with no `presentationBackground` and no
`#available` branch. The two switchers have since left the system popover
altogether for the in-window component (*The bottom bar's popover component*,
below), which draws no arrow; the Log calendar keeps this answer, and its file
says in one line why its arrow is not on `bgPopover`.
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
the mode's design glyph at 16 since the design-match pass, `accent` on
`accentTint` while on, `textPrimary` with no ground while off — the navigation/close/disclosure glyphs
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
`ChromeQueryToggle` triple at its trailing end (gap 10), each toggle its
mode's design glyph at 16 — `accent` on `accentTint` while on, `textPrimary`
with no ground while off; replace row the shared field gap 8 then Replace All
in the secondary button style at the row's trailing end; the file-mask row, then
the scope line (`SearchScopeLine`) in `callout` `textSecondary`; results gap 8;
group header 24 high padding 16 the file's `FileGlyph` at 14 in a 14 slot, gap 6,
so the path starts at 36, two points past the 34-point match indent, the path in `callout` and `N matches` in
`subheadline` all in `textSecondary` (padding 8 and a 14-point `doc` symbol
before the design-match pass, inside a `List` whose own inset the window's
`ScrollView` no longer has);
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
popovers' content was drawn on `bgPopover` with a content background, no
`presentationBackground` and no `#available` branch. Each `Divider()` became a
one-point `hairline` rule the content draws. (Superseded: both now draw on
`ChromePopover`, an in-window surface with no arrow — *The bottom bar's popover
component*, below.) The branch switcher's filter field uses the
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
surface: the gated files naming `bgPopover` equalled `{CompletionPanel.swift,
HoverPanel.swift, BranchSwitcherView.swift, ProjectSwitcherView.swift,
LogFilterBar.swift}` at this part (today the two switchers' place is taken by
`ChromePopover.swift`; the canonical list carries the current set) and every gated file presenting a popover (`.popover(`) or
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
and `HoverPanel.swift` names `metrics` on the same statement. Part five (c)
adds a third clause: every `.frame(` in `CommitDialogView.swift`'s
`private var messageBox` body names `messageLineHeight` and none names
`metrics` — the message box is counted in lines of the code font it draws at.
Rule twenty's table is extended to the two search surfaces' toggles and buttons.

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
the duplicated sentence about the popover's arrow in
`BranchSwitcherView.swift`/`ProjectSwitcherView.swift` loses its second copy (both
copies are gone since the switchers moved onto the in-window component).
Rule twenty-seven is the zone rule that would have caught the first and fourth
of these.

#### Part five (b) — the commit dialog, the merge editor and the four separate windows

The last family of window surfaces: the commit dialog (its file list, message
box, author line, footer and author editor sheet), the three-pane merge editor,
the four secondary windows that host code — diff, merge, Local History and the
out-of-project source viewer — and `EscClosableWindow`, the subclass all six
secondary windows are built from. It spends `conflictBackground`, leaving two
roles unspent at the time (`currentLine`, `bracketMatch`, both code zone), and takes the
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
   dialog (file rows, Amend — and Push after commit until the design pass
   made pushing a button), Local Changes' revert checkbox
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
`textPrimary` content), keeping its `ZoomSurfaceMarker`; part five (c) counts
its height in lines of the code font (4 to 7 of `messageLineHeight`), where it
had been a fixed 70–120 points that followed no zone at all.
The author line's labels and amend note are `textSecondary`, the signature
`textPrimary` or `statusRed` when incomplete; Amend and Push after commit are
checkboxes, the push hint `textSecondary`, the status sentence `statusRed` for
an error and `textSecondary` otherwise; a `hairline` rule sits above a footer
sized by its content; Cancel is `.chromeSecondary`, Commit `.chromePrimary`,
shortcuts and disabled rules unchanged. The author editor sheet stands on
`bgPanel` with its title in `textPrimary`, caption in `textSecondary`, Save
`.chromePrimary` and Cancel `.chromeSecondary`. (**Since the design pass** the
dialog reads top to bottom: header, the message box at full width 20 from every
edge and four code-font lines high, a fixed 260 pt file list beside the diff, a
status strip only when there is something to say, and a 64 pt footer — the
`user-round` design glyph at 13 and the author name as one `.plain` button
opening the editor, its role, signature and amend note moved into its tooltip;
Amend; then Cancel and Commit in `.chromeSecondary` and Commit and Push, the one
`.chromePrimary`. The "Push after commit" checkbox and the "Edit…" link are
gone, and the file row reads checkbox, status letter, name over folder with no
file icon. Full entry in `app-git-views.md`.) It joins rule twenty-six's
shared-field callers (now five). Part five (c) replaces its platform `Form` with
two stacked `ChromeThemedTextField`s ("Name", "Email") at `.body`, focused
through a private enum, 360 wide as before.

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
   not `.buttonStyle(.link)`, a platform style rule thirty forbids. (The design
   pass folded it into the footer's author control, still a `.plain` button.)
6. **The unified diff's per-line checkbox keeps its SF Symbol glyph — an open
   question.** It sits inside a code-font row; the shared checkbox is
   interface-scaled, and putting it in a code-zoom row is the mixed-zone
   mistake rule twenty-seven exists to catch. Rule thirty bans platform toggles,
   and the glyph is neither. Whether that row's checkbox should be a code-zone
   shape of its own is a design question.
7. **The unified diff's added and removed text — closed by the design pass.**
   This was left open: the design tints a changed line's text as well as its
   ground, and a tinted *text* is a chrome colour on code. The design pass
   settled it the design's way: an added line's text draws in `statusGreen` and
   a removed line's in `statusRed` on top of the wash, through Core's
   `diffTextRole(for:)`; context text keeps `SyntaxTheme`'s plain colour, and
   the two line-number columns stay.

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

#### Part five (c) — Preferences, the language-server settings, Acknowledgements and the two pull-request sheets

The settings surfaces: the Preferences window (its host, its tab bar and all
four pages — General, Language Servers, the problem-catalog tab and
Acknowledgements), the licence text pane behind Acknowledgements, and the
create and merge pull-request sheets. It spends **no new colour role** —
`currentLine` and `bracketMatch` stayed unspent then — and adds **controls** instead:
the design draws a replacement for every platform form control these files
used, and those replacements live in `ChromeControls.swift`. Seven files join
the gated set, taking it from forty-four to **fifty-one**: `SettingsView.swift`,
`LSPServerSettingsView.swift`, `LSPInstalledLicenses.swift`,
`AcknowledgementsView.swift`, `Platform/LicenseTextView.swift`,
`NewPullRequestSheet.swift` and `PullRequestMergeSheet.swift`. Two rules are
added (thirty-six and thirty-seven, the suite growing from thirty-five to
thirty-seven); rules sixteen, twenty, twenty-four, twenty-six, twenty-seven and
thirty gain clauses, rules thirty-one and thirty-five gain pins, and rule
eighteen's case-label clause is rewritten from "no gated file matches" to a
per-file count (`sharedSpellingCaseLabels`), because `LSPServerSettingsView.swift`
joins the gated set spelling two `case .pending:` labels that name the
toolchain search's first state, not a checks state. Twenty-one
geometry tokens are added to `ChromeGeometry`.

**The five shapes — four new, one lifted.** Each lives in `ChromeControls.swift`,
reads `\.interfaceMetrics` and `\.chromeTheme`, takes every measurement from a
token scaled through `metrics.scaled(_:)`, and owes its accessibility inside its
own body (rule twenty).

- `ChromeSegmentedControl` — a `segmentedControlHeight` (26) box: `bgEditor`
  ground, one-point `hairline` border at `cornerRadiusMax`,
  `segmentedControlInset` (2) padding, segments `segmentGap` (2) apart. Each
  segment is a plain button of `segmentHeight` (22) with `segmentPaddingX` (12)
  around a `callout` title; the selected one is an `accentTintStrong` fill at
  `fieldCornerRadius` under `textPrimary`, the others no ground under
  `textSecondary`. The control speaks its label and the selected title; each
  segment speaks its selection.
- `ChromeStepper` — a `stepperHeight` (24) box on `bgEditor` with a `hairline`
  border at `fieldCornerRadius`, `stepperPaddingX` (8), holding minus, the value
  (`callout`, `textPrimary`, monospaced digits) and plus, `stepperPartGap` (10)
  apart. Every step — the glyph buttons and the adjustable action alike — goes
  through the `ZoomScaleRule`'s `stepped(_:by:)`, so the grid and the clamp are
  the rule's; a glyph whose step would not move the value is disabled. The
  glyphs are `.subheadline` in `textSecondary`, hidden from accessibility, and
  each button is named "Decrease …"/"Increase …".
- `ChromeSwitch` — a `switchWidth` × `switchHeight` (36 × 20) capsule track,
  `accent` on and `hairline` off, with a `switchKnobSide` (16) `onAccent` knob
  inset by `switchInset` (2). It dims when disabled and speaks its label and
  "On"/"Off".
- `ChromeSettingsTabBar` — a `settingsTabBarHeight` (36) strip on `bgPanel`,
  inset by `settingsTabBarPaddingX` (16), tabs `settingsTabGap` (4) apart, each a
  plain button with `settingsTabLabelPaddingX` (10) around a `callout` semibold
  label (`textPrimary` active, `textSecondary` otherwise); the active tab carries
  an `accent` indicator of `accentIndicator` thickness across its full width,
  and the strip's `hairline` bottom rule is drawn **behind** the tabs but in
  front of the strip's own ground — applied before it, which the part shipped
  the other way round and its review round corrected (rule sixteen). Each tab speaks its selection as a value.
- `ChromeMenuField` — **lifted, not invented**: the "existing menu idiom" was
  drawn as a dropdown in exactly one place, the Log filter bar's branch menu (a
  `ChromeControlBox`, a borderless indicator-less `Menu`, a chevron), and that
  menu wrapped an inline `Picker` the new ban finds red. So the Log bar is swept
  and becomes the first caller; the menu's items are plain `Button`s with the
  chosen one labelled by a checkmark, the label the current title (`callout`,
  `textPrimary`, one line) beside a `textSecondary` `.subheadline` chevron —
  both inside the `Menu`'s own label, so clicking the arrow opens the menu (the
  lift carried the Log bar's sibling chevron, which opened nothing, until the
  part's review round; rule thirty-seven). The
  caller supplies the width limits and, as `height:`, the height, which reaches
  the shared box the way the text field's does — an outside `.frame(height:)`
  left the box one label high, out of line with the fixed-height text fields
  beside it (`ChromeThemedTextFieldLayoutTests` measures both). One definition, three
  callers — the Log bar, the catalog tab's default language, the create sheet's
  base branch — the way the checkbox was lifted in part five (b).

The settings pages' own measurements are tokens too: `settingsPagePadding` (28),
`settingsRowSpacing` (22), `settingsLabelColumnWidth` (180) and
`settingsLabelGap` (16), read by `SettingsView.swift`'s private `SettingsRow` and
`SettingsPage` and — the padding — by `LSPServerSettingsView.swift`.

**Why a switch is not a checkbox.** Two meanings, two shapes, and neither is
folded into the other: a standing preference that is on or off is a switch
(General's two flags); one selection among many — an option of one action, a
row in a list — is a checkbox. So "Draft" on the create sheet stays
`ChromeCheckbox`, the shape Amend and Push have in the commit dialog: it is an
option of that one Create, not a preference that outlives it.

**The picker rule and its two answers.** A choice over a small set known when
the app is built — the tab placement, the theme, the merge methods — is a
segmented control; a choice over a set read at run time — branches, languages —
is a menu field. The merge methods are a filtered subset, but of the closed
three-case `GitHubMergeMethod`, so the most the control can ever lay out is
known at build time; `plan.showsMethodPicker` already hides a one-method
control. Rule thirty-seven is the rule's whole expression: it cannot read a
set's size, so it pins each shape's callers by set and each caller's
constructions by count. Until part five (c)'s review round it pinned the sets
alone, and a shape change moved a file between sets only when the file spelled
one shape; `SettingsView.swift` spells both, so one of its segmented controls
could have become a menu field with the gate green. The counts close that.

**`menuFieldHeight` sizes the menu fields alone.** Part five (d) framed two
`ChromeThemedTextField`s at it — the problem browser's query field and the
open-problem sheet's input — because each sits beside a menu field and 26 lines
them up. That couples an unrelated text field to the menu field's height with
nothing naming the connection: rule seven's coupling, arriving by reuse rather
than arithmetic. Each text field now takes its height from its own surface's
layout enum (`LeetCodeBrowserLayout.queryFieldHeight`,
`OpenProblemSheetLayout.inputHeight`, both 26, so nothing renders differently),
the way `SearchLayout.queryFieldHeight` and `FilterBarLayout.controlHeight` size
the other pinned-height fields. Rule thirty-seven pins the token's spellings per
file by count over every source file — the declaration plus four `height:`
arguments, each a `ChromeMenuField`'s (`SettingsView.swift`, `NewPullRequestSheet.swift`,
`LeetCodeBrowserView.swift`, `LeetCodeOpenProblemSheet.swift`; `SettingsView.swift`
spells it twice, once per menu field) — and checks each
count against that file's pinned menu field constructions. What a spelling
sizes is not something a token rule can see; that is checked by reading.

**Why the settings tab bar is not the dock's.** Both draw one pattern — an
accent indicator under the selected label, `accentIndicator` on both, the rule
behind the tabs — but the settings bar has no close action, a different height
(36 against `dockTabRowHeight`) and a different inset, and the two are measured
by two designs; sharing tokens would move one whenever the other is retuned.
`ChromeGeometry`'s doc comment says the same.

Decisions this part made where the ticket was silent or the repository
differed:

1. **The `Divider()` sites were not where the ticket put them.**
   `LSPInstalledLicenses.swift` has no view and no `Divider()`; all three
   language-server dividers were in `LSPServerSettingsView.swift` (the
   separator between server rows and the two around the toolchain rows), and the
   fourth in `AcknowledgementsView.swift`. The count of four was right; each is
   now a `hairline` rule at `hairlineWidth`.
2. **`LSPInstalledLicenses.swift` is gated but paints nothing.** A
   Foundation-only enum returning documents, it joins `roleNamingExemptions` on
   `ChromeThemeEnvironment.swift`'s footing, gated for rules one and two.
3. **A fifth shape is lifted: the menu field**, from the Log bar, as above.
4. **Two already-gated files failed the new ban and were swept here**, the ban
   not weakened for them: `CommitDialogView.swift`'s `AuthorEditorView` (a
   `Form` of two fields, now two stacked `ChromeThemedTextField`s, "Name" and
   "Email", with their own `@FocusState`) and the Log bar's inline `Picker`
   (decision 3).
5. **Draft stays a checkbox**; the two preference toggles in General become
   switches.
6. **The merge method is a segmented control although its segments are
   filtered**; the binding stays `GitHubMergeMethod?`, each option's value
   `Optional(method)`.
7. **The Preferences pages share one size.** A `TabView` sized the window to its
   widest tab. The host frames every page at the one size Acknowledgements
   already needed, `metrics.scaled(640)` × `metrics.scaled(420)`, under the
   36-point tab bar, so switching tabs does not resize the window. The size
   lives in `SettingsView.swift`'s private `SettingsLayout` with the arithmetic
   `InterfaceMetricsTests` pins unchanged; the old per-page widths (340 General,
   460 catalog, 480×300 Language Servers) are gone. Only the selected page is
   built now, unlike `TabView`'s eager build, so the two comments that relied on
   the eager build were corrected (`AcknowledgementsView.documents` and the
   catalog tab's `onAppear` note, L27), and Acknowledgements' list selection
   resets on each visit.
8. **The page padding and the four settings-page measurements are
   `ChromeGeometry` tokens**; Language Servers' padding moves from 20 to the
   page's 28.
9. **The menu field's height is `menuFieldHeight` = 26**, equal to the segmented
   control's but a token of its own, since two shapes are two measurements (the
   argument `barPaddingX` makes). No surface draws both: the design draws no menu
   field on a settings page, and the fields this part draws sit on the catalog
   page and the create sheet, neither of which carries a segmented control. 26 is
   chosen to agree with the segmented control should a page ever draw both — an
   earlier wording of this decision, and of both tokens' comments, said the two
   lined up in one settings row, which no surface did. The Log bar keeps framing
   its field at `FilterBarLayout.controlHeight`.
10. **The stepper's eleven-point glyphs are `.subheadline`**, the chrome's 11; a
    glyph's size is a font, and `ChromeGeometry` carries none.
11. **An armable merge refusal reads as a warning.** The create plan's refusal
    and every merge refusal the reader cannot wait out are `statusRed`; the one a
    reader can knowingly sit through (checks still running, the one behind
    *Merge when checks pass*) is `statusYellow`, read from the refusal's own
    `isArmable` — no view table.
12. **The licence text stands on `bgEditor` under a `bgPanel` header with a
    `hairline` between them**, the commit dialog's diff-preview shape. The ground
    is painted by SwiftUI behind the representable (`drawsBackground = false`
    stays); an AppKit `backgroundColor` would be rule thirty-one's.
13. **`LicenseTextView.swift` is shared with iOS, and its iOS half is not
    swept.** Its `backgroundColor = .clear` is a sixth pin in rule thirty-one,
    with its reason; its `textColor = .label` is a UIKit name rule one's list
    does not carry, recorded below as an open question rather than an exemption.
14. **The origin link is a button**: a `.plain` button with an `accent` label
    calling `@Environment(\.openURL)`, since `Link` draws the platform's link
    colour — part five (b)'s "Edit…" treatment.
15. **Three platform pieces stay**, stated as open questions below: the small
    `ProgressView` spinners, `HSplitView`'s divider and the Acknowledgements
    list's platform selection.

**Every departure from the drawing**, stated:

- **The fourth tab.** The drawing's tab bar has no problem-catalog tab; the
  code's fourth tab is drawn in the same shape, under its own title.
- **The 640 × 420 page.** The drawing sizes each page to its content; every page
  here takes the one size Acknowledgements needs (decision 7).
- **The menu field's height.** The drawing gives none; 26 is chosen to agree
  with the segmented control should a page ever draw both (decision 9).
- **The `.subheadline` glyph.** The drawing's 11-point stepper glyph is the
  chrome's `.subheadline` (decision 10).
- **Language Servers' padding.** 28, the page's, where the page drew 20
  (decision 8).

The surfaces in detail: General is two `ChromeSegmentedControl`s (tab
orientation, theme), two `ChromeStepper`s (editor and terminal font size, over
`ZoomScaleRule.editorFont`/`.terminalFont`, `ZoomSourceGatingTests` reading the
stepper's grid from the rule) and two `ChromeSwitch`es; each row is a
`SettingsRow` whose label column is `callout` `textSecondary`, wrapping rather
than clipped, hidden from accessibility where the control speaks the row's
label itself. The catalog tab's rows and account buttons are in
`core-leetcode.md`, Language Servers' in `core-provisioning.md`, Acknowledgements'
and the licence pane's in `app-shell.md`, the sheets' in `core-github.md`. The
commit dialog's message box is also counted in lines of the code font here (4 to
7 of `messageLineHeight`, where it had been a fixed 70–120 points — four exactly
since the design pass, about the design's 68), pinned by rule twenty-seven.

**Open questions**, deliberately left:

- **The tab-placement wording.** The drawing rewords the tab-orientation row;
  the code's words are kept verbatim.
- **The spinners.** `ProgressView` stays in Language Servers and both sheets;
  the ticket names no replacement. (Closed by part five (d): every gated site is
  the shared `ChromeSpinner`.)
- **`HSplitView`'s divider** in Acknowledgements stays the platform's, as it
  already is in three gated files.
- **The iOS half's `.label`** in `LicenseTextView.swift`: a UIKit semantic
  colour on a platform outside the chrome theme, which rule one's list does not
  carry.
- **The Acknowledgements list's platform selection**: the list draws no row
  background (rule thirty-five), so the selection box is the platform's.

#### Part five (d) — the database viewer, its SQL console and the problem-catalog surfaces

Seven more macOS chrome views — the last this series of parts had named at the
time, and **not** the last unswept ones, though this part was written up as if
they were: part five (e)'s alert accessory was the verified counterexample, and
after it part five (f)'s fold placeholder a second. The database viewer tab and its SQL
console, and the problem-catalog browser window, the statement pane, the judge
section, the open-problem sheet (with the menu-bar commands in the same file) and
the sign-in sheet. It spends **no new colour role** — `ChromeColorRole` stays at
twenty-one cases, `currentLine` and `bracketMatch` stayed unspent then — and adds three
Core colour answers and one shared control, the spinner, with two geometry
tokens. Seven files join the gated set, taking it from fifty-one to
**fifty-eight**: `DatabaseViewerView.swift`, `DatabaseConsoleView.swift`,
`LeetCodeBrowserView.swift`, `LeetCodeDescriptionView.swift`,
`LeetCodeOpenProblemSheet.swift`, `LeetCodeJudgeView.swift` and
`LeetCodeLoginView.swift`. Four rules are added (thirty-eight to forty-one, the
suite growing from thirty-seven to forty-one), and rules twenty, twenty-two,
twenty-four, twenty-six, thirty, thirty-two, thirty-four, thirty-five and
thirty-seven gain pins wherever a new file falls under them.

**The spinner — `ChromeSpinner`.** Every `ProgressView` in a macOS gated file
became the shared spinner: the five in the new files and fifteen in files
already gated (the Log 2, the commit dialog, Find in Files, the Pull Requests
panel 3, the two pull-request sheets 3, Language Servers 3, Local History,
Usages) — **twenty sites**. It is drawn, not a platform control: an open arc
(three quarters of a circle, one turn a second) stroked in `textSecondary` and
turned by the clock through a `TimelineView`, `spinnerSide` (16, the small control size most
of the replaced sites asked for — not all: the commit dialog's loading state was
a bare regular-size `ProgressView()` and so halved) square with a `spinnerLineWidth` (2) stroke, both `ChromeGeometry`
tokens scaled through the metrics, neither derived from the other. A spinner
reports activity, not selection, which is why it is not `accent`. Under Reduce
Motion it draws still, and it follows the setting as it is *now*: the
timeline's schedule pauses on the reduce-motion value itself, so switching the
setting on stills a turning spinner and switching it off turns a still one. Its
first shape latched a `@State` flag in `onAppear` and fed it to a value-scoped
`.animation`; a spinner that appeared under Reduce Motion then stayed still for
its whole life once the setting was switched off, because the flag never changed
again — rule twenty's body clause (no `onAppear`, no `@State`, the reduce-motion
property as the `TimelineView`'s `paused:` value) names that regression. One
parameter, `isTurning` (default `true`), joins that value with an `||`: the Log's
refresh controls keep their spinner laid out at zero opacity while idle and pass
`false`, so the invisible arc's schedule is paused rather than redrawing every
frame. Its accessibility is a **call-site contract**: a spinner
speaks either its activity or nothing, decided where it is constructed, never
both and never neither. A spinner whose neighbour already names the activity —
a sentence or caption beside it — is `.accessibilityHidden(true)`, so VoiceOver
reads the sentence once rather than the sentence and then a second, vaguer
one; a spinner standing alone carries `.accessibilityLabel(…)` in the site's
own words. The type has **no label parameter and no default label** — a default
would be exactly the duplicate the contract avoids — and carries
`.updatesFrequently` in its body, inert when the site hides it. The shape
follows part five (c)'s for exactly this case: `SettingsView.swift`'s
`.accessibilityHidden(controlSpeaksLabel)` on a label column whose control
speaks for itself, and `ChromeControls.swift`'s hidden decorative glyphs. Each
site was classified from the tree, and the classification is pinned per file
(rule forty): of the twenty, twelve are labelled and eight hidden. The
"Loading…"/"Searching…" lines in the Log, Find in Files, Usages and the problem
browser are the empty list's alone, so the spinner beside a *populated* list
has no neighbour and is labelled, as are the commit dialog's, Local History's,
the Pull Requests header's, the two sheets' write spinners, the database
footer's and the console's; the armed wait, "Reading checks…", the merge
settings line, Language Servers' three rows, the judge's "Running…"/
"Submitting…" and the open-problem sheet's fetching line stand beside theirs
and are hidden.

**The three Core answers.** `ChromeColorRole.difficultyRole(for:)` (easy
`statusGreen`, medium `statusYellow`, hard `statusRed`),
`problemStatusRole(for:)` (solved `statusGreen`, attempted `statusYellow`,
not started `textSecondary`) and `verdictRole(for:matchedExpected:)` —
`statusGreen` for `.accepted` unless `matchedExpected == false`, `statusRed`
otherwise. The verdict's "good" rule moved to Core **with** its colour: the
judge's `verdict(_:isGood:)` became `verdict(_:role:)`, the run passing its
`matchedExpected` and the submit `nil`. Each answer has one reader (rule
thirty-nine) and is tested total over its cases in `ChromeRoleMappingTests`.

Decisions this part made where the ticket was silent or the repository
differed:

1. **Twenty-two `Divider()` sites, in six files, not five.** The viewer 7, the
   console 6, the browser 3, the statement pane 3, the sign-in sheet 2, and one
   in the open-problem sheet's file inside `LeetCodeCommands`; the judge section
   has none. Every surface divider is now the surface's own `hairline` rule at
   `hairlineWidth`. The commands' one is a menu separator and **stays a
   `Divider()`** — fix round 02 restored it after the first attempt, two
   `Section { }` groups, turned out to hold four separator items in the menu's
   structure where one had been (the measurement is under rule twenty-four); it is that rule's one stated
   exception.
2. **Two `Picker`s, not one.** The browser's filter bar and the open-problem
   sheet both pick the solution language over
   `LeetCodeSolutionFile.offerableLanguages`; both became `ChromeMenuField`,
   the answer part five (c) gave the catalog settings tab for the same list.
3. **The six filter toggles are `ChromeCheckbox`es.** Difficulty and status are
   set-membership filters — each case independently in or out, an empty set
   meaning everything — an option of one action rather than a single choice or
   a standing preference, so the picker rule answers checkbox. The bindings are
   unchanged.
4. **The fields.** The browser's query (with the magnifying-glass glyph) and the
   open-problem sheet's input are `ChromeThemedTextField`, each over a private
   focus enum; the grid's cell editor is `ChromeThemedTextField` over the grid's
   own `$focus`/`.editor(coordinate)`, built with `spokenName:` so the column's
   name is spoken and never drawn in an empty field (grey is how the grid draws
   NULL), its
   `.onSubmit`/Escape handling staying on the outer view; the judge's test-case
   `TextEditor` is wrapped in `ChromeControlBox` (the commit dialog's message
   box shape) and its `separatorColor` stroke is gone; the console's input is a
   pane between two hairlines, not a field — on `bgEditor` with
   `.scrollContentBackground(.hidden)`, unboxed.
5. **The database grid has no row selection, and none was added.** A grid row
   and a console result row take `hoverTint` under the pointer through one
   modifier, `GridRowHover` (the console reuses the viewer's); the grid's one
   selection-like state, the focused cell, draws `accentTintStrong`; the
   console's rows have hover only. The zebra (`isTinted` and its `isMultiple`
   expression) is **deleted** from both, and no wash role replaces it: the
   design's tables read by selection and hover, and a twenty-second role for an
   alternation the design does not draw would be a role of its own (rule
   forty-one).
6. **The browser's rows follow `CommitRow`.** The platform `Table` became
   `ScrollView` + `ScrollViewReader` + `LazyVStack` under a `bgPanel` header row
   ("#", "Title", "Difficulty", "Status") with its rule drawn over the ground and
   under the titles. Each row is
   the file-scope `LeetCodeBrowserRow`, sized by a scaled `minHeight` from the
   private `LeetCodeBrowserLayout` enum of bare numbers; selection is
   `accentTintStrong` whether or not the window is key, hover `hoverTint`. The
   `Table`'s per-column drag resize is **not carried** — the design's panel has
   none: the number, difficulty and status columns take fixed widths scaled from
   the old ideal widths (56 / 88 / 96) and the title column the rest. Keyboard:
   the list is one focusable container, `onMoveCommand` moves the selection and
   the `ScrollViewReader` keeps it visible, and Return opens through a
   zero-sized shortcut button enabled only while the list holds focus (the
   viewer's `returnOpensTheFocusedCell` idiom);
   single tap selects, double tap opens, the context menu offers Open, and the
   explicit Open button stays. Below the last row — where the rows' container is
   stretched to the viewport and a clear, hit-testable background sits behind
   the rows — a right-click offers Open for the current selection (nothing
   when there is none) and a plain click clears the selection, as the platform
   table did; every Open still reaches the one `open(slug:)`. Accessibility: each row is one combined element
   carrying `.isSelected` and a named "Open" action, and the lock glyph speaks
   "LeetCode Premium".
7. **The viewer's error banner** is a `bgPanel` strip with a `hairline` bottom
   rule drawn over the ground and under the sentence; its `exclamationmark.triangle.fill` mark and its sentence
   are both `statusRed`, and the orange wash is deleted. The console's message
   slot takes the same mark and colour.
8. **The spinner is drawn, not a platform control**, as above; the three
   `.progressViewStyle(.circular)` went with their views.
9. **The statement pane's resize handle** (a 5-point `separatorColor` fill) is
   a transparent 5-point hit area with a centred `hairline` at `hairlineWidth`.
   It is not `ContentView.panelDivider`'s shape, which is an opaque `bgPanel`
   fill with a top-aligned hairline: that divider *is* the dock's top edge,
   while the handle sits between two surfaces and draws only the rule. Its cursor function joins rule twenty-two's
   pinned set.
10. **The tables-and-views sidebar.** `.listStyle(.sidebar)` draws the
    platform's translucent material, so the list is `.plain` with
    `.scrollContentBackground(.hidden)` on `bgPanel`; the section headers are
    `Section { } header: { }` in `textSecondary`; the platform draws the
    selection and no row background is set, so rule thirty-five pins `[[]]`.
    The key glyph takes its own scaled font and keeps its help.
11. **`VSplitView`'s divider stays**, carried with `HSplitView`'s as one open
    question.
12. **The browser is a window root**, so rule thirty-two applies: it resolves
    colours through a private `chromeColor(_:)` over
    `settings.chromeTheme(systemPrefersDark:)`, its root struct reads no
    `\.chromeTheme`, and its rows are a file-scope child struct reading the
    environment. The roots declaring `chromeColor` grow from five to six.
13. **Only the colour tables moved to Core.** The browser's two title switches
    and the status column's glyph choice (words and a glyph, not a colour) stay
    in the view; rule thirty-nine pins the browser's case-label count, rule
    eighteen's mechanism, so a colour switch added later moves the count.
14. **The verdict's "good" rule moved with its colour** (above).
15. **Medium difficulty is `statusYellow`.** There is no orange role, and
    attempted takes the same role.
16. **Styled buttons get a table with two numbers per file.** Menu items and a
    confirmation dialog's buttons cannot take a button style — the cell menu's
    Copy and Set to NULL, the browser's context-menu Open, `LeetCodeCommands`'
    five items, the console's dialog Run and Cancel — so part five (d)'s table
    states each file's `Button` count and its `.buttonStyle(` count (rule
    thirty).
17. **Named icon-only controls.** The statement pane's three icon-only buttons
    (hide, open on the site, show) and the grid footer's two paging chevrons
    ("Previous page" / "Next page", `.plain`, their `.disabled(… ||
    model.isWriteInFlight)` terms verbatim) carry `.accessibilityLabel` and hide
    their scaled glyphs, and join rule twenty's builders.
18. **The page inside the statement pane stays unthemed.** The pane — header,
    collapsed strip, dividers, resize handle — is chrome and is swept; the served
    statement document is not, and keeps its own stylesheet. (Superseded by part
    five (e), which themes the served page from the palette.) The sign-in sheet's
    web page is the site's own; only its header and footer are chrome.

The surfaces in detail: the viewer pane stands on `bgPanel` and the grid on
`bgEditor`; every value text is `textPrimary` and every secondary text
`textSecondary`; a NULL cell keeps its italic and takes `textSecondary` (its
doc comment no longer says "tertiary"), and `refusedCellOpacity` stays a view
opacity. The grid's header row is `bgPanel` with the sort chevron
`textSecondary` and its rule over the ground, under the titles; its column separators are vertical
`hairline` rules. The console's toolbar and status bar are `bgPanel`, its "SQL"
caption and footer sentence `textSecondary`, Run `.chromeSecondary` with ⌘↩ and
`isRunDisabled` unchanged; its result header matches the grid's, and its
confirmation dialog is untouched. The browser's filter bar holds the shared
field, the menu field at `menuFieldHeight`, the six checkboxes, a vertical
hairline and Open (`.chromeSecondary`), its message `statusRed`; the signed-out
offer and footer text are `textSecondary`, the error `statusRed`, Sign In… and
Refresh `.chromeSecondary`. The statement pane's header and collapsed strip are
`bgPanel` with the title `textPrimary`; the judge's Run and Submit are
`.chromeSecondary`, its info badge `textSecondary`, scaled and still labelled,
and every failure line `statusRed`. The open-problem sheet is on `bgPanel`,
Open `.chromePrimary` and Sign In…/Cancel `.chromeSecondary` with shortcuts and
the disabled rule unchanged, the refusal `statusRed`, its visible "Language"
caption hidden from accessibility since the menu field speaks the name; the
sign-in sheet's header and footer are `bgPanel`, Cancel `.chromeSecondary`.
Every label, sentence, shortcut, disabled rule and generation-token capture is
verbatim; nothing about the viewer's two writes or the gate they consult
changed.

**Open questions**, deliberately left:

- **`VSplitView`/`HSplitView`'s dividers** stay the platform's.
- **The platform focus ring** on the grid's focused cell and on the browser's
  focusable row list.
- **The two served documents' palette**: the statement page and the sign-in
  page are not chrome; the pane around the first is.
- **The terminal's ANSI-16** stays `TerminalTheme`'s, as before (its four
  chrome colours were since swept, part five (h)).

The spinner question part five (c) left open is **closed**.

The `Section`-separator question part five (d) left open is **closed**, by a
measurement on screen. Five menus, built by three of the four
`menuSectionFiles`, were measured in the running app while open — three context
menus in `ProjectTreeView.swift`, one in `LocalChangesView.swift` and the `Menu`
popup in `SearchHistoryMenu.swift` — each menu's window captured by its own
window id, its height read from the window bounds and its item list read
through accessibility. The project tree's file context menu, three `Section`s
(Run | Rename, Delete | Local History), draws two separators, both between
groups, at 128 pt; the folder context menu, two `Section`s (New File, New Folder
| Rename, Delete), draws one, between the groups, at 117 pt; the root context
menu, one `Section` (New File, New Folder), draws none at 58 pt, where edge
separators would put it near 80 pt; the Local Changes row context menu for a
modified file, two `Section`s (Show Diff, Jump to Source, Commit… | Revert),
draws one, between the groups, at 117 pt; and the recent-searches popup, two
`Section`s (one recorded pattern | Clear History), draws one, between the
groups, at 69 pt. The arithmetic agrees across all five: about 23.5 pt per
item, about 11 pt per drawn separator and about 11 pt of padding. The history
popup shows structure and drawing apart: its accessibility item list holds six
items for two buttons — a separator item before the first group, two adjacent
ones between the groups and one after the last — so the separator items exist
in the menu's structure, and AppKit hides the leading, trailing and adjacent
ones when it draws a popup or a context menu. The fourth file,
`DatabaseViewerView.swift`, had nothing to measure: its cell context menu (Copy,
Set to NULL) spells no `Section` of its own, as rule twenty-four already says.
The limit is the method's: five menus on one machine, read at the heights the
window bounds report. The convention the earlier parts established stands,
confirmed rather than assumed: a menu's separator is a `Section` boundary.

#### Part five (e) — the two served document pages and the alert accessory

Three surfaces: the **Markdown preview page**, the **problem statement page** —
both served web documents that kept a colour family of their own (fourteen and
twelve chrome hex literals in Core) — and the **alert accessory** in
`FilePanels.swift`, the text prompt's refusal sentence, which set `.systemRed`
and was this document's verified counterexample to part five (d) having been the
last. **This part was not the last either.** It was first written up as the
part closing the macOS colour sweep — the same claim part five (d) made, made
again one part later without the measurement that would have disproved it, and
again wrong: `BracketOverlayLayoutManager.swift` then still painted the fold
placeholder from `NSColor.secondaryLabelColor`, and that file's own comment
called the placeholder "chrome standing in for text, not a token". So the claim
was made twice and was twice false, and the fold placeholder is the surface
that made the second one wrong. It is recorded here because a document that
keeps the mistake is what stops the next part repeating it (the surface itself
was swept in part five (f), below), and rule forty-three is what now reads such
a claim against the tree.
**No new role**:
`ChromeColorRole` stays at twenty-one, and `currentLine` and `bracketMatch` stayed
the two unspent then. One Core value is added, `DocumentPageChrome` (its entry
above, with the role table), plus the palette's CSS reading. One file joins the
gated set, taking it from fifty-eight to **fifty-nine**: `FilePanels.swift`,
whose line now reads `ChromePalette.nsColor(.statusRed)` — the dynamic colour,
never the resolved `nsColor(_:in:)` — and whose `NSFont.smallSystemFontSize`
stays, with a comment saying why: an alert is a platform surface the app does
not scale, and the accessory matches the alert's own small system size. The two
pages add no gated file: `LeetCodeDescriptionView.swift` was already gated (part
five (d) swept the statement pane), and `MarkdownPreviewPane.swift` draws nothing
of its own — a served page's colours reach it as CSS strings, not as views — so
both are pinned instead as the derivation's two callers by rule forty-two, which
is added (the suite growing from forty-one to forty-two).

**Both pages take the palette.** The preview composes
`.withChrome(ChromePalette.documentPageChrome(in:))` onto the code palette it
already derived, and the statement pane hands the same derivation to
`LeetCodeStatementDocument` directly. Core's restated block is drawn on no
macOS page — it is a starting value there, replaced from the palette before the
page is built; iOS draws it, and because it now states these same values the iOS
statement page moves the same way with no iOS file edited.

**What moved.** The page is the editor's paper, a code block recesses to the
window ground, and both pages now match the window they sit in. *Light barely
moves*: page, text and secondary text are unchanged; link `#0066cc` →
`#2f6fe0`, code `#f2f2f7` → `#f5f5f7`, border `#d2d2d7` → `#d1d1d6`, table
border `#c7c7cc` → `#d1d1d6`. *Dark moves on purpose*, the page rising to the
editor ground and code recessing to the window ground: page `#1e1e1e` →
`#2f3136`, code `#2a2a2e` → `#1e1f22`, text `#e8e8ed` → `#dfe1e5`, secondary
text `#9a9aa0` → `#a0a3aa`, link `#6bb3ff` → `#4f8dff`, border `#3a3a3e` →
`#393b40`, table border `#4a4a4e` → `#393b40`. **The table header row inverts
with the code ground**: `th` reads `--code-background`, so in dark it goes from
raised (`#2a2a2e` on `#1e1e1e`) to recessed (`#1e1f22` on `#2f3136`) — still told
apart by its ground, the direction of the difference flipped exactly as it is
for code blocks.

**`tableBorder` collapses into `border`, which is `hairline`.** The preview's
separate grid colour existed because a weight reading as structure between cells
would read as a scar across a paragraph. The answer, in four parts:

1. **The closed vocabulary requires it; it is not a preference.** The
   vocabulary names exactly one line colour and no role for a stronger
   separator, so a served page may not draw a line stronger than the one every
   other swept surface draws.
2. **The measured cost.** Dark: the grid goes from `#4a4a4e` on a `#1e1e1e` page
   to `#393b40` on a `#2f3136` page — a strong grid becomes exactly as subtle as
   every other hairline in the app. Light: from `#c7c7cc` on white to `#d1d1d6`
   on white.
3. **Why the line is the one place the collapse is felt.** A code block's ground
   may be subtle because it is a large filled area; a one-pixel line may not be.
   So `codeBackground` moving is invisible and the rule line moving is not.
4. **The remedy, if it reads badly on screen**, is a change to `hairline`
   itself, which moves every swept surface — never a page-local override and
   never a new role.

`MarkdownPreviewPage` no longer emits `--table-border`, and `preview.css`'s
table-cell rule reads `var(--border)` (`core-markdown-preview.md`).

**The acceptance line on hex literals**, "no hex literal in Core outside
`SHA256.swift`", cannot hold literally — the code half's 28 are out of scope and
the chrome fallback must be restated — so it is read as three conditions, all
pinned by rule forty-two's clause (c): every CSS hex literal in Core sits in one
of exactly two restated blocks, `MarkdownPreviewTheme.swift`'s code half (28) and
`DocumentPageChrome.swift` (12); a test pins each block equal to its app-side
table; and `LeetCodeStatementDocument.swift` spells none.

#### Part five (f) — the fold placeholder

One surface: the **fold placeholder**, the `…` and its rounded outline drawn
where a collapsed block was, in `BracketOverlayLayoutManager.swift` — the
surface that made part five (e)'s closing claim wrong. It painted the glyph from
`NSColor.secondaryLabelColor` and the outline from the same colour at a composed
half alpha.

**The glyph is `textSecondary`.** Three reasons, the last deciding. The role's
definition: `textSecondary` is the chrome's quieter text, and the placeholder is
text the chrome draws, not text the buffer holds. The code zone cannot hold it:
`SyntaxTheme`'s table is keyed by `SyntaxTokenKind`, and nothing in the buffer
says `…`, so there is no token to colour it by. And **the chevron settles the
tie**: the gutter's fold chevron already draws the same fact — *this block is
folded* — in `textSecondary`, so the placeholder taking the same role makes the
two agree by construction rather than by two values happening to match. The
palette bridge is appearance-aware exactly as the platform colour was (a dynamic
colour resolves at draw time under `.aqua` and `.darkAqua`), so there is still
no second table.

**The outline is `hairline`, at its own value.** `hairline` is the chrome's one
answer for a rounded container's one-point border — the shared field, the
secondary button, the off checkbox, the segmented control, the stepper and the
off switch track in `ChromeControls.swift` all draw theirs with it — and it is
already quieter than the glyph, which is all the former half alpha was for. So
the composed `withAlphaComponent(0.5)` is gone, and the stroke is
`ChromeGeometry.hairlineWidth`, **unscaled**, following the ruler's gutter
hairline precedent (the token's own doc comment points there) rather than
restating it. The half-point inset stays a bare local `0.5` — rule seven forbids
writing it as `hairlineWidth / 2`.

**Two zone statements, no exceptions.** The placeholder is drawn at the
**code** font, because it stands in the document's own text flow, and
`placeholderRect(forFoldedRangeAt:)`'s inset, gap and height are measured from
that font — the code zone's measurements, not the chrome's point tokens. Both are
said at their sites, so a later rule keyed on gated-set membership meets a stated
reason rather than a silent number. Geometry is unchanged.

**Spent seams.** Both colours reach the draw through `internal` seams, in the
ruler's `numberAttributes` pattern: `placeholderAttributes` (the code font plus
the dynamic `textSecondary`) and `placeholderOutlineColor`; the ruler gains the
matching `foldChevronColor`, which `drawFoldChevron` now reads instead of its
local palette call. The app-layer `GutterFoldTests` asserts, under both
appearances, that the glyph resolves to the palette's `textSecondary` and not
`secondaryLabelColor`, that the outline resolves to `hairline` and not
`secondaryLabelColor` at half alpha, and that the glyph equals the chevron — a
value frozen at construction would pass one appearance and fail the other. That
the draws **spend** those seams is **rule six's second clause** (below), not a
new rule. Mutation-checked, not assumed: swapping `placeholderAttributes`'
colour for `secondaryLabelColor`, `placeholderOutlineColor` for another role, or
`foldChevronColor` for another role each turned the app test red; re-inlining an
equivalent attribute dictionary in `paintFoldPlaceholders`, and separately
restoring the chevron's local palette call, each turned rule six red; each was
restored.

**No new role**: `ChromeColorRole` stays at twenty-one, `currentLine` and
`bracketMatch` stayed the two unspent then, and nothing in Core changes. One file joins
the gated set, taking it from fifty-nine to **sixty**:
`BracketOverlayLayoutManager.swift`, and `unsweptColorSurfaces` empties. The
suite's rule count stays forty-three.

**Measured before drafting, rule by rule.** With the file added to `gatedFiles`
in a scratch worktree, the glyph switched to the palette and the unswept set
emptied, the whole suite passed — rule one (no system semantic colour), the
hex-literal rule, rule seven (no arithmetic on a geometry token), rule
twenty-seven (each measurement follows its own zone; its clauses are per-file,
none keyed on membership), the chrome-glyph sizing rule (the file builds no
symbol image), the severity rule (the file's `nsDiagnosticColor` is the code
zone's `SyntaxTheme`, outside the rule), the layer-colour rule, the
every-gated-file-names-a-role self-check and rule forty-three. The one finding
was **rule twenty-nine**: its alpha clause sees an alpha chained directly onto
`nsColor(`, `.color(` or `chromeColor(` only, so the placeholder's local
`color.withAlphaComponent(0.5)` passed while breaking what the rule says, and so
does `ProjectTreeView.swift`'s drop-target `resolving(.accent).opacity(0.4)`.
This part removes its own instance and records the gap on rule twenty-nine's
entry; it does not change the rule and does not touch the tree (the drop-target
was left waiting, and is settled in part five (g), below).

**Rule forty-three, bounded.** It was verified live by mutation with the set
empty: an `_ = NSColor.systemRed` added to `DefinitionPicker.swift` (ungated, not
exempt) turned it red naming that file, and green again once restored. Its entry
now states the bound its measurement has always had.

**The sweep is closed, and what that does not mean.** With this part the macOS
colour sweep is closed, in one sense only: every macOS chrome surface draws
from the roles, which rule forty-three's live half measures rather than asserts.
It does **not** mean the theme is finished. The open questions stay open and
stay named under *What is still waiting*: the terminal's own palette (its four
chrome colours since swept, part five (h)), the lane hues, the unified diff's per-line checkbox glyph. (The caret readout and the
changed-line text tint were waiting here too; both are now drawn — see the
bottom bar's caret readout below, and part five (b)'s departure seven.)

#### Part five (g) — the project tree's drop-target wash

One surface, and one conflict settled: the project tree painted a drop-target
row with `resolving(.accent).opacity(0.4)`, an alpha composed at the use site,
which breaks rule twenty-nine ("a wash's alpha is the palette's") while slipping
past its alpha clause, and the closed role set named no drop wash. Part five (f)
measured it and left it waiting, because moving it onto `accentTint` (`0x22`)
or `accentTintStrong` (`0x33`) would visibly change the highlight.

**The table gives, by one row.** The design states three strengths of the
accent wash — a marked surface, a selected row and a drop target — and the
palette carried two. A value the design already states is not a call site's
request, so the third becomes a role, `dropTargetTint`, in the row-and-line
states group after `hoverTint`: the accent's own hues, `0x4F8DFF` dark and
`0x2F6FE0` light, at alpha `0x66` — 102 ÷ 255, exactly 0.4, so **no pixel
changes**. `ChromeColorRole` goes from twenty-one to **twenty-two** cases;
`currentLine` and `bracketMatch` stayed the two unspent then; the set stays closed
against call sites. The gated set stays at **sixty** files and the suite at
**forty-three** rules.

**The tree composes no alpha.** `TreeRowBackground.role(for:)` answers
`.dropTargetTint` for `.dropTarget`, so only `.plain` answers `nil`, and
`color(for:resolving:)` lost its special case: the state's role where there is
one, `Color.clear` otherwise.

**Pinned three ways.** The palette suite's expected table gains the row, and a
relation test beside the inactive-selection one asserts in both appearances
that `dropTargetTint` has `accent`'s RGB, an alpha strictly between
`accentTintStrong`'s and `accent`'s, and exactly `0x66`. A new app-layer suite,
`TreeRowBackgroundTests`, pins the state-to-role mapping and that the mapping
composes no alpha (a recording resolver is asked exactly the state's role once,
and its colour comes back unchanged; for `.plain` it is never asked). And rule
twenty-nine's alpha clause now sees the helper-call form, at depth one —
mutation-checked against `ProjectTreeView.swift`, red with the old line restored
and green after (its entry, below). **The gap that remains** is the
local-variable form, which needs data flow.

#### Part five (h) — the terminal's four chrome colours

One surface, the terminal pane, and one boundary redrawn. `TerminalTheme.swift`
was exempt from the suite whole, because "an ANSI-16 palette is a protocol's
vocabulary". **The boundary is drawn where the exemption's own reason puts
it**: that reason is true of the two sixteen-entry arrays and of nothing else
in the file. The other four colours of each palette — the ground, the default
text, the caret and the selection — are chrome, and they become roles:

| Terminal colour | Role | Dark | Light |
|---|---|---|---|
| ground | `bgCanvas`, since moved to `bgPanel` (below) | `0x1E1F22` | `0xF5F5F7` |
| default text | `textPrimary` | `0xDFE1E5` | `0x1D1D1F` |
| caret | `accent` | `0x4F8DFF` | `0x2F6FE0` |
| selection | `accentTintStrong` | accent hues at alpha `0x33` | accent hues at alpha `0x33` |

**Pixels change on purpose.** The dark ground goes from black to `0x1E1F22` and
the dark text from SwiftTerm's `#8A8A8A` to `0xDFE1E5`, taking its contrast from
6.1:1 to 12.6:1; the light ground goes from white to `0xF5F5F7` and the light
text from `#1E1E1E` to `0x1D1D1F`. The caret and the selection were the system
accent's `selectedContentBackgroundColor` and `selectedTextBackgroundColor`;
they are now `accent` and `accentTintStrong`, and **no terminal colour follows
the system accent any more**. The text under a block caret stays the resolved
ground, readable against the saturated `accent`.

**Three light ANSI entries darkened**, each keeping its hue, because the new
light ground is not white: ANSI 8 `0x757575` → `0x707070` (it measured 4.2:1 on
`0xF5F5F7`), ANSI 11 `0x9A7000` → `0x926A00` (4.1:1) and ANSI 14 `0x00808F` →
`0x007C8B` (4.3:1). The light array's floor is now stated as **at least 4.5:1
against `0xF5F5F7`**, the ground it was measured on. The dark array stays
SwiftTerm's sixteen defaults verbatim — no longer "so the dark theme looks
exactly as before", but because it is the terminal's own vocabulary and the one
thing the file still spells for itself.

**The stated exception: a host that stores concrete colours is handed concrete
colours.** Everywhere else in the AppKit chrome the rule is that a view asks
for a *dynamic* colour and caches nothing (`ChromePalette`'s AppKit bridge,
above). SwiftTerm cannot honour it: it stores its own `SwiftTerm.Color` structs
and plain `NSColor`s for the caret and selection, and never re-resolves them.
So `TerminalTheme` resolves the four roles at apply time through the concrete
accessor `nsColor(_:in:)`, under the `ChromeAppearance` matched from the
hosting `NSAppearance` (`.darkAqua` → `.dark`, anything else → `.light`), and
the existing re-apply on every appearance change is what keeps the stored
colours current. The `performAsCurrentDrawingAppearance` resolver, which
existed only to resolve dynamic system colours, is gone. `ThemeKey` still
fingerprints the four resolved colours' 16-bit components — ground, text,
caret, selection — and its reason narrows to determinism: comparing components
keeps the skip-if-unchanged guard (and the OSC 4/10/11/12 state it protects on
a tab switch) exact.

**The accent observer is removed.** `TerminalSessionsModel` subscribed to
`systemColorsDidChangeNotification` only because an accent change altered the
caret and selection without altering the appearance; with neither following
the accent, the subscription, its `init`, its `deinit` removal and their doc
comments went with it.

**An open item, named rather than tuned.** The dark ANSI-16 set was tuned for
black, and on `0x1E1F22` its weakest entries measure ANSI 4 at 1.3:1, ANSI 1 at
1.8:1 and ANSI 12 at 1.9:1 — each *worse* than on the black it was tuned for
(1.6:1, 2.3:1 and 2.4:1 there), so the new ground costs these entries
contrast and nothing is fixed. Tuning the set is listed under *What is still
waiting*.

**Pinned twice.** Rule forty-four (below) narrows the exemption in `swift
test`: outside the two arrays the file spells no `0x` literal, constructs no
`NSColor` and no colour beyond its two converters, names no system colour or
named-hue member such as `NSColor.magenta` (its
`.…Color` members pinned by set equality), it names the four role tokens, and
each array holds sixteen entries. The arrays are found through a new helper,
`matchedBracketBodyRange(after:in:)`, beside the brace-matching one, because an
array literal has no braces of its own. A new app-layer suite,
`TerminalThemeTests`, asserts under both appearances and both high-contrast variants that
`key(for:)` equals the
palette's four roles' components by its own arithmetic (×65535, rounded — not
the theme's converter, so the comparison is not a tautology), that every light
ANSI entry clears 4.5:1 against the light `bgCanvas`, that each appearance
installs its own array, and that both arrays have sixteen entries.

**No new role**: `ChromeColorRole` stays at twenty-two, `currentLine` and
`bracketMatch` stayed the two unspent then, and nothing in Core changes. The gated set
stays at **sixty** files — `TerminalTheme.swift` stays one of the four
exemptions, now narrowed — and the suite goes from forty-three rules to
**forty-four**.

#### The design's glyphs — one helper, one name table

The design draws its icons from a set of its own, not from SF Symbols, so its
glyphs ship as **template vector assets**: twenty-four PDFs from the design
export, one imageset each under `Sources/Pisaka/Assets.xcassets/Glyphs/`, every
one marked `template-rendering-intent: template` (so it takes the tint it is
handed) and `preserves-vector-representation: true` (so it stays sharp at every
interface scale). Their names live in one Foundation-only Core enum,
`DesignGlyph` — raw value = asset name, and no size: every asset is a 24-unit
box, and the size a glyph is drawn at is the surface's — and that enum is the
one name table every surface reads. The previous export (2026-10-02) wrote each
media box as the drawn extent rounded down to an integer while the geometry kept
its fractional size, and the renderer clips to the box, so right and bottom
edges were cut off; `DesignGlyphAssetTests`' geometry check, which decodes every
shipped PDF and bounds each path coordinate inside its 24×24 box, now pins that
defect class.

They are drawn through **one helper**, `DesignGlyphImage.swift`, and nowhere
else:

- `DesignGlyphImage(_ glyph:, size:, slot:, role:)`, the SwiftUI half, draws the
  template `.resizable()` and fitted (never stretched) at `size × interface
  scale` — `size` required, with no default, since only the surface knows
  it — centred in a
  `slot × interface scale` square, tinted by the role out of the injected
  theme, and `accessibilityHidden(true)`: a glyph is a control's picture, never
  its name.
- `DesignGlyphDrawing.image(_:pointSize:tint:)`, the AppKit half, returns the
  glyph as an `NSImage` fitted into a square and filled with the tint at draw
  time. The caller resolves the tint inside its own drawing appearance, on rule
  twenty-five's footing.

The helper joins the gated set, taking it from sixty to **sixty-one**, and is
the tenth file exempt from the role-naming self-check, because it paints the
role its caller names and spells none itself. The suite goes from forty-five
rules to **forty-six**: rule forty-six holds that no macOS source but the helper
loads an image by a glyph's name, and rules ten and thirty-four learn that a
`DesignGlyphImage(` is a sized, accessibility-hidden glyph — thirty-four
re-checking the helper's own `Image(` for both. Provenance — the export, the
manifest digest the acknowledgement records as its revision, which glyphs fall
under the MIT notice, and the by-hand update procedure — is in
`Resources/DesignGlyphs/VENDORED.md`, a record `project.yml` does not bundle;
`DesignGlyphAssetTests` and `LicenseCoverageTests` hold the catalog, the record,
the enum and the `licenses.json` entry to one another. The run-time half the Core gate
cannot see is `DesignGlyphImageTests` in the app bundle: every glyph loads from
the compiled catalog as a template, the AppKit half fills its square with the
tint and nothing else, and the SwiftUI half occupies its slot at scales 1.0 and
1.8 and draws the glyph centred, at its size, in its role.

#### The bottom bar's popover component — `ChromePopover.swift` + `ChromePopoverPresenter.swift`

The project switcher and the branch switcher are **one design component**, so
they are one view: both popovers, and the remote row's submenu, are a
`ChromePopover`. It opens **upward** from its widget, left-aligned to it,
`popoverBarGap` (4) above the bar, clamped inside the window, with **no arrow
and no material** — a flat `bgPopover` fill at `cornerRadiusMax`, a `hairline`
stroke at `hairlineWidth` (both reused, neither a token of its own) and a
`bgCanvas` shadow at y `popoverShadowOffsetY` (8) whose SwiftUI radius is
`popoverShadowBlur / 2` — the design states a blur of 24, and a blur of `b` is
drawn by a Gaussian radius of `b / 2`, a unit change spelled once in
`shadowRadius(forBlur:)`.

**`ChromePopover.swift` — the container and its pieces.** Three slots: a
**Head** (fixed, `popoverHeadPaddingBottom` 4 under it and a `hairline` rule
along its bottom), a **List** (`popoverListPaddingBottom` 6 under it, clipped,
the only part that scrolls) and a **Foot** (fixed, a `hairline` rule along its
top). **The Foot and its rule are drawn only when the caller passes one** — an
optional Foot, `nil` drawing neither — and the Head is optional the same way,
because the submenu has none; the branch list's Foot is its error line and
nothing otherwise, and the Head and List keep their identity across the Foot
coming and going, so the focused field stays focused. The width is
`popoverWidth` (300) scaled; the height hugs the content up to a `maxHeight`
the host hands in — the placement's available height, already capped at
`popoverMaxHeight` (360). A plain `VStack` under a `frame(maxHeight:)` cannot
hug (the frame takes the proposal and a `ScrollView` is greedy), so a small
layout reports the hugging height and gives the List alone whatever the fixed
slots leave, the List being a `ViewThatFits` over its plain rows and the same
rows in a `ScrollView`. **The summed height never exceeds `maxHeight`**, even
when the fixed slots alone would: they take their ideal in display order, each
capped by what the slots before it left (a long wrapping error in the Foot, or
a window too short for the Head and Foot together, is cut by the container's
clip rather than drawn outside the window), and the List takes what remains.
While it scrolls, the List keeps the keyboard
selection in view: the caller hands the selected row's id to
`scrolling(to:)`, and every registered row carries its id through
`chromePopoverRowAnchor`. The pieces, every literal a token scaled at the use
site:

- `ChromePopoverRow` — `popoverRowHeight` 28, `popoverRowPaddingX` 12,
  `popoverRowGap` 6, a `popoverRowGlyphSlot` 16 leading slot holding an
  optional design glyph at 14 or nothing; the title in `.body` and
  `textPrimary`, one line, truncated in the middle; `isCurrent` draws the title
  in `accent` and `.check` in the slot; an optional trailing `chevronRight` (12)
  in `textSecondary`, `textPrimary` while hovered or selected. The ground is
  `accentTintStrong` selected, `hoverTint` hovered, clear otherwise —
  **selection wins**. One accessibility element named by its title, with an
  optional value (a current row's state) and an optional hint (the remote row's
  submenu).
- `ChromePopoverProjectRow` — `popoverProjectRowHeight` 36, the same slot,
  padding and ground rules; the name in `.body` (`accent` when current) over the
  path in `.subheadline` and `textSecondary`, one line, truncated in the middle,
  `popoverProjectRowLineGap` 1 between them.
- `ChromePopoverSectionHeader` — `.subheadline` semibold in `textSecondary`,
  padded `popoverSectionHeaderPaddingTop` 12, `popoverSectionHeaderPaddingX` 12
  and `popoverSectionHeaderPaddingBottom` 4.
- `ChromePopoverMessage` — `.subheadline`, padded `popoverMessagePaddingY` 8 and
  `popoverMessagePaddingX` 12, in a role the caller names (`textSecondary` for
  an empty state, `statusRed` for the error).
- `ChromePopoverFieldBlock` — any field stretched to the inner width with
  `popoverFieldBlockPadding` 8 on every side. The branch popover's filter is
  `ChromeThemedTextField`, which gained an optional `designGlyph:` leading slot
  (`DesignGlyphImage` at 14 in `textSecondary`) beside its existing `glyph:`.
  The branch popover passes it `height: popoverFieldHeight` 32 — a 13-point
  line inside 8 points of vertical padding, without which the shared box hugs
  its text line — and `spacing: popoverFieldGlyphGap` 8 between the search
  glyph and the text; the horizontal padding stays the shared `fieldPaddingX`
  10. Both are unscaled tokens the box and the stack scale, and
  `ChromePopoverLayoutTests` measures the field's drawn height off the branch
  bitmap at scale 1.0 and 1.8. The field requests the focus after it is mounted
  in the window — a request made during the overlay's appearance pass is lost —
  and holds it until dismiss hands it back; `ChromePopoverPresenterTests` asserts
  the field editor holds the first responder once open and not after dismiss.

The file joins the gated set (sixty-one to **sixty-two**) and is now rule
twenty-three's one reader of `bgPopover` for the bar: the two switcher files
name none and present nothing themselves.

**`ChromePopoverPresenter.swift` — open state, host overlay, monitors.** The
popover is an **in-window SwiftUI overlay**, `ChromePopoverHost`, mounted once
in `ContentView.body` inside the root's `chromeTheme`/`interfaceMetrics`
injections (so it adds no injection root) and above the bar's `.zIndex(1)` —
**not a child panel**, because an overlay is inside the window by construction
and moves with it, re-places itself on a resize through the root's
`GeometryReader`, needs no screen-coordinate conversion, and never takes key
status from the main window, so the field inside it keeps the text focus and
"closes when the window resigns key" stays one notification. The root declares
a named coordinate space; the widgets, the bar's top edge and the rows report
their frames in it, and the host asks `PopoverPlacement.popover(...)` with
`popoverWidth`, `popoverMaxHeight` and `popoverBarGap` scaled, drawing the
content bottom-leading at the answer with the available height as its
`maxHeight`. An open submenu is a Head-less `ChromePopover` of two rows, its
height known from the row tokens and the List padding, placed by
`PopoverPlacement.submenu(...)` with `popoverSubmenuGap` scaled. Its anchor
row's top is **live**: a row-top report for the row the open submenu hangs from
updates the submenu, so a resize or a popover height change that moves the row
moves the submenu with it. Only the
drawn surfaces hit-test; the root's AppKit stand-in (flipped, `hitTest` →
`nil`) only supplies the window and converts an event's point.

`ChromePopoverPresenter` (`@MainActor` `ObservableObject`, carried by an
optional environment value — absent where `BottomBar` is hosted alone, where a
widget's button then presents nothing) holds the open id, the anchor frame, the
content, the bar's top, the rows the content registers in display order (an
action row is an ordinary entry; a remote row carries its submenu's rows), the
main `PopoverSelection`, the optional submenu with its own selection, and the
drawn frames. `present(id:anchor:content:)` toggles when the same id is open;
`setRows(_:)` resets the selection to the first row and closes a submenu, and
each content re-registers on appear and on every filter change. **Every
activation dismisses everything before its closure runs**; the current
branch's and current project's rows only dismiss.

Two local `NSEvent` monitors and one observer are installed on present and
removed on dismiss, scoped to the root's window. The **mouse** monitor
(left, right, other mouse-down) dismisses on a press outside the popover, the
submenu and the anchor widget — a press on the widget is left to the widget's
toggle — and always returns the event, so the click that dismisses still lands
and nothing is dimmed or blocked. The **key** monitor holds **no key logic**:
it maps the key code (126 `up`, 125 `down`, 36/76 `return`, 53 `escape`, 123
`left`, 124 `right`; anything else, and any of these with ⌘, ⌃ or ⌥, `other`),
builds `PopoverKeyState`, asks `PopoverKeyRule`, and executes the answer
against the submenu's selection while one is open, the main one otherwise, or
the presenter's API; `passThrough` returns the event unconsumed and every other
action consumes it — except while the focused field holds marked text, when
an input method composing in it owns Return and the arrows until it commits.
`NSWindow.didResignKeyNotification` for that window dismisses.

**The focus goes back on dismiss.** The overlay lives in the main window, so
the filter field focused on appear takes the window's first responder from the
editor, and removing the field gives nothing back on its own. `present` records
what held the focus (a field editor's owning control, never the field editor),
and `dismiss` restores it only while a field editor the popover took still holds
the focus — the project popover takes none and changes nothing, and a click
outside still lands after the restore and moves the focus where it was aimed.
The presenter is not in the gated set: it names no colour role.

Tests: the Core rules are `PopoverPlacementTests`, `PopoverSelectionTests` and
`PopoverKeyRuleTests` (`swift test`); `ChromeThemeTests` holds every new token
in the inventory's set equality and values. In the app bundle,
`ChromePopoverPresenterTests` pins the key-code mapping, the toggle, a
replacement leaving no old rows, selection or submenu, the selection and
submenu wiring, activation dismissing first, both popovers' row registration
and every row's callback, the branch rows registering again when branches
arrive and when HEAD alone moves, the focus hand-back, and the host reporting
the submenu's frame where it draws it (the frame the mouse monitor reads) and
following its anchor row when the row moves;
`ChromePopoverLayoutTests` renders the branch popover (with its Foot) and the
project popover at scale 1.0 and 1.8, plus the branch popover once under a cap
shorter than its content — five renders, five windows — and measures the
capped container's height with both rules still drawn, and the 300-point width between the stroke columns, the
field block's 8-point padding above and below, the 28- and 36-point selected
grounds, the 1-point Head and Foot rules, and the section header's height. One
unwindowed fitting-size check, outside the five, holds the container at its cap
when the Head and Foot alone are taller than it.

#### The Welcome screen

`WelcomeView.swift` (`app-window.md`) joins the gated set, taking it from
sixty-two to **sixty-three**, and spends no new role and no new token. The
screen paints `bgCanvas` itself — it replaces the whole split, so it is now the
second place the window ground is seen, beside the no-file-open placeholder
(reached only with a folder open and no tab). Its two column cards are `bgPanel`
inside a `hairline` outline of `hairlineWidth`, scaled. A row's ground is
`accentTint` when the keyboard selection is on it, otherwise `hoverTint` under
the pointer, otherwise clear, so selection wins. Names, titles and footer
chords are `textPrimary`; paths, captions, glyphs, footer labels and the
empty-recents hint are `textSecondary`. Glyphs come only from `DesignGlyph`
through `DesignGlyphImage`, with `plus` vendored for New File. There is no
`Divider()`, no system semantic colour and no SF Symbol. Its sizes are the
file's own `WelcomeLayout` constants plus `ChromeGeometry`'s row tokens, every
one scaled at the use site. `WelcomeLayoutTests` (app bundle) renders it at 0.8,
1.5 and 2.0.

#### The bottom bar's caret readout

`BottomBar` draws `CaretReadout`'s `Ln <line>, Col <column> · <encoding> ·
<language>` after its toggles, 10 points (a bare local number, scaled once,
like the bar's other gaps) past the completion switch, at `subheadline` (11
regular) in `textSecondary`, one line and never truncated. With no text tab
focused — a database viewer tab, or no tab — the bar is handed an empty string
and draws nothing, the gap included, so the toggles end at the bar's padding
exactly as before. `BottomBarLayoutTests` measures the gap at scale 1.0 and 1.8
against the text's own side bearing, rendered alone. Where the string comes
from is `app-window.md`'s (`CaretReadoutModel`) and `app-editor.md`'s
(`onCaretMoved`).

#### The current-line highlight

The editor washes the caret's line in `currentLine`, full width, and continues
the band into the gutter. Which line is `CurrentLineRule`'s answer
(`core-editor.md`): the line holding the caret, a selection within one line
still highlighting, a selection spanning lines highlighting nothing. The
coordinator asks it on every selection change and on every view update, over
the whole selection (a column selection across lines is a multi-line one) and
the ruler's own line-start table, and hands the answer to the layout manager,
which redraws only the band the wash leaves and the band it lands on. The text
side paints in `drawBackground`, after the indentation levels and before
`super`, so the matched pair, the search matches and the selection all land on
top of it; the gutter reads the same answer and geometry off the layout manager
and paints its band over `bgEditor`, under the hairline and the numbers. Both
fills are dynamic colours resolved inside the drawing pass, rule twenty-five's
footing, so an appearance switch repaints them untold. Rule twenty-nine holds
the files spelling `currentLine` to the palette and these two painters, by set
equality; Until this highlight `currentLine` was one of the two unspent roles; the parts
above that say so record their own moment. `ChromePaletteTests` keeps the wash distinct from
`selectionInactive`; `CurrentLineHighlightTests` samples the band in both
halves, on the caret's line and not its neighbour, and none under a multi-line
selection.

#### The terminal's ground and inset

The design sets the terminal into its panel rather than edge to edge: a
14-point margin on the left and right, at interface scale 1.0 and scaling with
the interface (the margin is chrome, so zooming the terminal changes its rows
and columns and leaves the margin where it is). The terminal's ground moves
from part five (h)'s `bgCanvas` to **`bgPanel`** — `0x2B2D30` dark, `0xECECEF`
light — the role the dock slot paints, and `TerminalPanelInset` paints the
margin the same role, so the slot, the margin and the terminal read as one
surface. Nothing about the exemption changes: `TerminalTheme` still resolves the
role concretely for the matched appearance under rule forty-four, which now
requires `.bgPanel` where it required `.bgCanvas`. The new light ground is
darker, so the light ANSI-16 floor of 4.5:1 is now measured against
`0xECECEF`, and four entries were darkened along their own hues to hold it:
ANSI 8 `0x707070` → `0x6A6A6A` (it measured 4.2:1), ANSI 11 `0x926A00` →
`0x8A6400` (4.2:1), ANSI 13 `0xA83BB5` → `0xA63AB3` (4.50:1, on the floor) and
ANSI 14 `0x007C8B` → `0x007583` (4.2:1). `TerminalThemeTests` pins the ground
on a live view in both appearances and the floor on the new ground;
`TerminalPanelInsetTests` measures the margin at scale 1.0 and 1.8 and samples
it as `bgPanel`.

#### The design pass's departures

The design pass matched every surface it found off, and drew six things other
than the design does, each deliberately and in the repository's favour. Each is
recorded where its surface is described, and gathered here:

1. **The Log keeps its richer filters and its ref badges.** The design's filter
   strip is sparser than `LogFilterBar`'s branch, author, path, message and
   date-range filters, and its commit rows draw no ref badges. Both are working
   features the drawing simply does not show; removing them would remove
   behaviour, not restyle it. The badges keep `accent` on `accentTint` (part
   four (b)).
2. **The terminal keeps its session strip.** The design draws one terminal; the
   app runs several sessions per project, and the strip is how one is chosen,
   added and closed. It stays the panel's header strip (part four (a)).
3. **Find in Files' current match stays orange.** The match ⌘G steps to is
   `SyntaxTheme`'s saturated orange over the warm yellow of every other match —
   one family, so it still reads as a match, but unmistakably the current one.
   The design draws no distinct current match; losing it would lose the only
   cue for where ⌘G landed (`app-editor-overlays.md`).
4. **Blame stays behind its per-file toggle.** The design draws the gutter's
   blame column; the app draws it only when "Annotate with Git Blame" is turned
   on for that file. Annotate starts off for every tab, because a blame is a
   `git` run per file and a column of authors is noise while editing
   (`app-editor.md`, `app-editor-overlays.md`).
5. **The unified diff keeps two line-number columns.** The design draws one;
   the commit dialog's diff shows the old and the new line numbers side by side,
   so a removed line and an added line each say where they were and where they
   land (part five (b)'s departure seven).
6. **The dock draws six tabs and a single close button.** The design's seventh
   tab names a panel this application does not have, and its minimise and close
   would perform the same action on a dock with one state (*Six tabs, not
   seven* and *Close alone*, part four (a)).

#### What is still waiting

The dock is finished, the popovers and search surfaces are swept, and so are the
commit dialog, the merge editor, every secondary window's ground, Preferences,
the two pull-request sheets, the database viewer and its console, the
problem-catalog surfaces, the two served document pages, the alert accessory,
the fold placeholder, the project tree's drop-target wash (part five (g)) and
the terminal's four chrome colours (part five (h)). No macOS surface is known to paint outside the roles —
that is the bounded closure stated at the end of part five (f), and rule
forty-three's live half is what would say otherwise the moment an ungated,
non-exempt macOS file started to.

The dock's tab row is **no longer deferred** — part four (a) drew it, and
`ChromeGeometry.dockTabRowHeight` is spent. The popovers are **no longer
deferred** — part five (a) drew them on `bgPopover` and replaced their
`Divider()` calls with `hairline` rules, and `ChromeGeometry.fieldCornerRadius`
and `secondaryButtonHeight` are spent on the shared field. The **caret
readout** is **no longer deferred**: it sits after the bar's toggles (see *The
bottom bar's caret readout*, below). The unified diff's **changed-line text tint** is
**no longer deferred** either: the design pass drew it (part five (b)'s
departure seven). What stays deferred: the **lane hues**, and the unified
diff's **per-line checkbox glyph** (part five (b)'s departure six), both open
design questions. The terminal's own palette is **no longer
deferred** — part five (h) moved its four chrome colours onto the roles — but
one item takes its place: **tuning the dark ANSI-16 set**, whose weakest
entries (ANSI 4 at 1.3:1, ANSI 1 at 1.8:1, ANSI 12 at 1.9:1) are worse on
`0x1E1F22` than on the black they were tuned for. Each follows the six-step guide at the end of
this document, on its own. One role remains unspent — `bracketMatch`, code
zone — after the current-line highlight spent `currentLine`, the same one role
`ChromeColorRole.swift`'s own doc comment names.

### The monochrome-icon decision

Every icon in the swept surfaces is drawn in `textSecondary`: the tab strip's
file glyph, the vertical column's, the tree's folder and file glyphs, the draft
field's icon column. Since part eight those four draw `FileGlyph`'s design
glyphs, which carry no tint at all; the panels still reading `FileIcon` answer a
symbol **and** a semantic tint, and deliberately read only the symbol. A column of differently-tinted glyphs
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
**comments and string literals stripped before almost every match**. Four
rules read `GitHubSourceGatingTests.strippingComments(_:)` instead, literals
kept, because each one's subject is a literal — the query-toggle names, the
merge editor's chevron symbols, clause (c)'s CSS hex and the design-glyph
rule's load names — and the suite's
header names them, held to the code by a self-check. The stripping is
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
`TerminalPanelView.swift`, **twenty** in all. Part four (b), part five (a), part five (b), part five (c), part five (d), part five (e) and part five (f) add seven, seven, ten, seven, seven, one and one more, each named in its own section above — sixty — the design glyphs' helper, `DesignGlyphImage.swift`, one more — sixty-one — the bottom bar's popover component, `ChromePopover.swift`, one more — sixty-two — and the Welcome screen, `WelcomeView.swift`, one more: **sixty-three** in all today. `ProjectTreeView.swift` is not among the third part's additions because it
was already there: part three restyled the surface *around* the rows part one
had swept, and a file joins this set once. The draft field is in the set
although it is an editing affordance rather than a row: an inline draft
*replaces* a tree row on screen and must read identically to the row it stands in
for. `TabStripView.swift` covers `TabStatusMark` too, the slot view the two
orientations share, which is why that extraction did not add a seventh file.

The forty-seven rules, each invisible to the compiler:

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
   stand in for one; since part five (h) that exemption covers its two
   sixteen-entry arrays and nothing else, the file's four chrome colours being
   roles pinned by rule forty-four), `FileIcon.swift` (a Core semantic token iOS still
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
   **Second clause** (part five (f)), the same principle for the two other
   colour seams the app-layer suite reads: in `BracketOverlayLayoutManager.swift`
   the body of `paintFoldPlaceholders` names `placeholderAttributes` and
   `placeholderOutlineColor` and none of `ChromePalette`, `NSColor`,
   `foregroundColor` or `withAlphaComponent`, and in the ruler `drawFoldChevron`
   names `foldChevronColor` and not `ChromePalette` — so the three spent seams
   (the gutter fill, the placeholder, the chevron) are audited in one place. A
   missing body fails asking for the rule to be re-pointed. Mutation-checked:
   re-inlining an equivalent attribute dictionary in the draw, and separately
   restoring the chevron's local palette call, each turned it red.
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
   files carrying such a line are themselves a counted set, three today. Since
   part eight the fallback is `file.url?.lastPathComponent ?? file.displayName`
   handed to `FileGlyph`, matched whitespace-free, and the tree, its draft field
   and `TabStripView.swift` construct no `FileIcon` at all and left the set.
   What stays: since part four (a) `ProblemsPanelView.swift` and
   `UsagesPanelView.swift`, whose one exempted line each is the file-group
   header's `let icon = FileIcon(…)` binding, read for its symbol alone — the
   glyph is drawn in `textSecondary` on a line rule one still scans — and since
   part four (b) `CommitLogView.swift`, whose changed-file row carries the same
   binding. `LocalChangesView.swift` carried it too until the design pass, when
   its file rows stopped drawing a file glyph and its folder rows took
   `FileGlyph`'s, and it left the set; so did `CommitDialogView.swift`, whose
   file row (in the set since part five (b)) the same pass reduced to checkbox,
   status letter and name.
9. **The window's chrome is configured in one file.**
   `titlebarAppearsTransparent` and `titlebarSeparatorStyle` are each spelled in
   `MainWindowChrome.swift` and nowhere else under `Sources/`, by set equality in
   both directions, each with its own failure message. Each is a property of the
   *window* rather than of a view tree, so whoever sets it last wins and two
   setters would compete silently — the title bar's ground, or its line, decided
   by whichever marker reached the window first. The other direction matters
   just as much: the transparency is what reveals the window's background
   colour, so a *removed* setter hands the strip back to the framework's own
   material, and a removed separator setter brings back the one-point line the
   design does not have. The rule has a **second half**, because a unique setter says
   nothing about whether anything ever reaches the window: `MainWindowChrome(`
   is pinned to `PisakaApp.swift` at exactly one occurrence, the scene's own
   attachment, alongside the frame marker sharing that line — delete the
   attachment and every other rule here stays green while the shipped window
   keeps its platform title bar.
10. **Every bottom-bar control is identifiable without sight.** Inside
   `ContentView.swift`, the brace-matched bodies of `bottomBarButton(` and
   `completionToggleButton` each spell `BarToolTip(` — the AppKit `toolTip`
   that replaced `.help`, which never showed on these toggles in the shipped
   window (`app-window.md` records the diagnosis) — and `.accessibilityLabel(`,
   and neither spells `.help(`; the **whole bar** owes the same pair and the
   same refusal — the brace-matched `BottomBar` struct and each of the three
   widget files (`ProjectSwitcherView.swift`, `BranchSwitcherView.swift`,
   `PullRequestIndicatorView.swift`, read whole) must spell `BarToolTip(` and
   `.accessibilityLabel(` and none may spell `.help(` — so the bar keeps one
   tooltip mechanism, and no accessibility hint is required (the toggles'
   former `.help` texts were word for word their label and value); and
   `bottomBarButton(` occurs exactly twice — one declaration and one call inside
   `panelToggles`, which `bottomBar` draws, which builds the toggles from
   `BottomPanel.allCases` and names no panel case in its body, so the bar keeps
   no second list of panels beside the one the dock's tab row reads
   (`BottomPanelTests` pins the order; this rule pins who reads it). Part three made all seven controls icon-only, and the
   `Label(title, systemImage:)` they used to carry *was* each one's
   accessibility name; an unhidden `Image(systemName:)` supplies a name of its
   own instead — the *symbol's* — and a tooltip is not a name VoiceOver
   reads. So the visual decision silently renames named controls after
   their glyphs: nothing misrenders, no other gate goes red, and the only reader
   who notices is the one who cannot see the bar. The bodies are read
   brace-matched, in rule six's idiom, so a `BarToolTip(` elsewhere in a
   fifteen-hundred-line file cannot satisfy it; the call count is pinned so a
   seventh dock panel arrives through the one builder whose name the rule
   already requires, rather than as a hand-written call shipping nameless. The
   **same rule read from the other side** covers the bar's three widgets: a
   `Button` combines its children, so each symbol a widget draws folds its name
   into the button's — part one measured exactly that on a tree row
   ("chevron.right, folder fill, Sources"). `ProjectSwitcherView.swift` and
   `BranchSwitcherView.swift` must therefore hide every decorative symbol they
   draw, asserted by counting `Image(systemName:` against
   `.accessibilityHidden(true)` in each file — a `DesignGlyphImage(`, which every
   bar widget's own glyph and, since the in-window component, every popover row's
   glyph now is, hides itself and so counts on both sides — with
   `PullRequestIndicatorView.swift` the stated exception because it names itself
   outright with an explicit `.accessibilityLabel(`. That count has a **second
   half**, because it went green on the change that broke the thing it exists
   for: two of the hidden symbols were the row's *state* (the current project's
   and the checked-out branch's checkmark — today `.check` in a
   `ChromePopoverRow`'s or `ChromePopoverProjectRow`'s slot), and hiding those
   satisfies the count while leaving every row announcing the same words. The
   "Current project" / "Current branch" value each popover hands its current
   row is what the files now spell. So each of the two files
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
   panel's `header` and row `summaryLine`. Three of those have since moved.
   Part five (a) deleted the private `filterField(…)` when the bar's fields
   became the shared field, dropping that builder from the rule. Part five (b)
   moved the date bound's label into the shared checkbox's trailing title, so
   since then that label is counted in `ChromeCheckbox`
   (`ChromeControls.swift`) rather than in `dateBound(…)`, and `LogFilterBar.swift`
   is no longer among the rule's files. The design pass removed the Log's
   `header` strip altogether — its refresh controls sit at the filter strip's
   trailing end and draw no `Text` — so the Log's entry names the column
   header's `label(_:)` alone. The rule's files are therefore
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
16. **An indicator strip's bottom rule is drawn behind its tabs.** Each entry in
   the suite's named `indicatorStripFiles` list — `TabStripView.swift`,
   `DockTabRow.swift` and, since part five (c), `ChromeControls.swift`'s
   `struct ChromeSettingsTabBar`, read inside that declaration's brace-matched
   body alone so another shared shape's bottom background in the same file
   cannot satisfy the strip's — draws an accent indicator on the strip's own bottom edge
   and a one-point `hairline` along that same edge, and over stripped source
   spells no `.overlay(alignment: .bottom)` whose brace-matched body names
   `hairline`, while at least one `.background(alignment: .bottom)` body does (so
   a strip that lost its rule altogether cannot pass). An overlay covers its
   whole content, so an overlaid rule painted over the lower point of the
   selected tab's two-point indicator — and, in the tab strip, cut the active
   tab's `bgEditor` fill off from the editor it is meant to merge into. A bottom
   overlay drawing the *accent* itself (the strip's cell does) is the indicator,
   not the rule, and stays allowed. Named rather than the whole gated set, rule
   fourteen's shape: a further strip with a bottom-edge indicator joins the list
   as part of being drawn, as the Preferences tab bar did. **Since part five
   (c)'s review round the rule is also ordered**: inside the same body, the first
   `.background(alignment: .bottom)` naming `hairline` comes *before* every plain
   `.background(` whose arguments name a background role (`bgCanvas`, `bgPanel`,
   `bgEditor`, `bgPopover`) — two token positions compared inside one matched
   body. SwiftUI draws each later `.background` further back, so a rule applied
   after an opaque ground lands behind the fill: a rule that exists, is drawn with
   the right modifier, and is invisible. Part five (c) shipped exactly that on the
   Preferences tab bar, over a page of the same `bgPanel`, so bar and page ran
   together; `TabStripView` had the right order and says why in its own comment.
   A strip drawing no ground on itself satisfies the clause vacuously —
   `DockTabRow` is that case, its ground being the dock slot's.
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
   (`symbolName`/`indicatorGlyph`/`spokenWords`, `ChromeColorRole.checksRole(for:)`). No app file
   declares `func checksRole`; the app files spelling `checksRole(for:` equal
   `{PullRequestIndicatorView.swift, PullRequestsPanelView.swift}`; and no gated
   file spells a case label naming `.noChecks`, `.pending`, `.failure`,
   `.success`, `.pass`, `.fail`, `.skipping` or `.cancel`, or a
   `GitHubChecksSummary.`/`GitHubCheckBucket.`-qualified one — except where a
   label shares the spelling but names another type's case, pinned per file by
   its exact count (`LSPServerSettingsView.swift`: 2, the Go and Rust rows'
   `case .pending:`, the toolchain search's first state), so a third label is
   still red. Stated limit: rule fifteen's — a dictionary literal, an `==`
   chain, a `case` list continued past its first line.
19. **The diff row wash is Core's one answer, and a macOS diff side is one
   type.** No app file but the palette names `diffAddedBackground` /
   `diffRemovedBackground`; none declares `func diffWashRole` / `func
   diffMarkerRole`; the app files spelling `diffWashRole(for:` equal
   `{DiffView.swift, CommitUnifiedDiffView.swift}`, and neither spells
   `withAlphaComponent(` or `.opacity(` — the wash's alpha is the palette's.
   The text tint the same way: none declares `func diffTextRole`, and the app
   files spelling `diffTextRole(for:` equal `{CommitUnifiedDiffView.swift}`.
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
   rather than passes. Part five (c) extends the builder list to the shared
   settings shapes in `ChromeControls.swift`, each owing its accessibility in
   its own body: `ChromeSegmentedControl` (label and value), `ChromeStepper`
   (label, value and `.accessibilityAdjustableAction(`), its `stepButton(`
   (label, with each glyph hidden on its own chain — a hide moved to the
   enclosing `HStack` is the later-sibling regression and is red),
   `ChromeSwitch` (label and value), `ChromeSettingsTabBar` (each tab's value)
   and `ChromeMenuField` (label and value, its chevron hidden). Stated limit:
   a single segment's own value is not pinned — the control's value already
   speaks the selected title, so deleting one segment's stays green. Part five
   (d) adds the database footer (the two paging buttons' labels, `footer`,
   counted: exactly three `.accessibilityLabel(` — the two chevrons' and the
   spinner's — through the builder's optional `labelCount`, since `required`
   is satisfied by one label anywhere and fix round 02 measured that deleting
   either chevron's stayed green) and
   its hidden `pagingGlyph(`, the database sidebar's `sidebarHeader` (the Hide
   button) and `collapsedSidebarStrip` (the Show button, the only way back) —
   each counted at exactly one label, since each holds exactly one control —
   and their hidden `sidebarGlyph(`, the problem browser's `LeetCodeBrowserRow` body
   (`.accessibilityElement(children: .combine)` for the one combined element,
   `.accessibilityAddTraits(isSelected ? .isSelected` for the selected trait,
   `.accessibilityAction(named:` for a named action, `.accessibilityLabel(` for
   the spoken lock with no `.accessibilityHidden(` anywhere in the body — the
   entry's one `forbidden` token — and `.contextMenu {` for the row's own Open;
   fix round 02 spelled the first three through their arguments after
   mutation showed the bare modifier names let a deleted combine and an emptied
   trait set stay green; the action's *name* is a string literal the stripped
   text cannot read, so "Open" is not held, only that the action is named) and its `problemList` container (`.contextMenu {` and
   `.onTapGesture {` for the area below the last row — fix round 02 restored the
   platform table's right-click Open for the selection and its click-to-clear
   there, which the row-only menu had silently dropped; whether the menu
   *appears* is the Post-Completion check, the container spelling one is what a
   token rule can see; a needle may end on a trailing closure's brace for
   exactly this), and the statement
   pane's `header(` (exactly two labels) and `collapsedStrip` (exactly one) —
   counted for the same reason, the entry saying each of the three buttons is
   named — and their shared hidden `iconGlyph(`. It
   also adds a **spinner clause, checked at the constructions rather than in
   the type's body**: every `ChromeSpinner(` call's trailing modifier chain (the
   lines after the call that begin with `.`, read from stripped text, nothing
   parsed) spells exactly one of `.accessibilityLabel(` or
   `.accessibilityHidden(true)` — never neither, never both; the hidden marker
   is that literal, never the call prefix, so `.accessibilityHidden(false)` and
   a conditional `.accessibilityHidden(someFlag)` count as no marker and fail
   as "neither" (the prefix match this replaced stayed green on both, each
   shown red at `LeetCodeJudgeView.swift`'s spinner before the fix was
   committed). The type carries no
   default label because a default would be the very duplicate a hidden site
   avoids; the contract follows `SettingsView.swift`'s hidden label column and
   `ChromeControls.swift`'s hidden glyphs. Rule forty pins how many of each
   every file holds.
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
   model clears its selection or the dock switches tabs, the database viewer's
   sidebar divide when its tab closes or its sidebar folds, Local Changes' divider
   when the list empties or the dock switches tabs — and `NSCursor`'s stack
   is global, so the cursor stays pushed after the flag that would have popped
   it is gone. The set of pushing functions is pinned by equality (the Log
   divide's, the two `ContentView` dividers', — since part five (d) — the
   statement pane's resize handle, `syncResizeHandleCursor`, the database
   viewer's sidebar divide, `syncSidebarDivideCursor`, and — since the design
   pass — Local Changes' list/diff divider, `syncDividerCursor`), so a scanner that stopped
   finding them fails rather than going vacuous. Stated limit: the rule sees the
   call, not that the handler clears the hover and drag state before it — a
   handler calling the sync with both still set pops nothing.
23. **A popover surface names `bgPopover`.** The gated files naming `bgPopover`
   equal `{CompletionPanel.swift, HoverPanel.swift, LogFilterBar.swift,
   ChromePopover.swift}`; every gated file presenting a popover (`.popover(`) or
   declaring an `NSPanel` is in that set, which is what lets the rule see a new
   popover appearing on a system material; and no gated file spells
   `NSVisualEffectView`, a `.material` assignment or `presentationBackground`.
   The two switcher files left the set when both bar popovers moved onto the
   in-window component: they present nothing themselves and name no
   `bgPopover`, so `ChromePopover.swift` is their surface's one reader. The
   Log calendar is the one remaining SwiftUI `.popover(`; its content is drawn
   on `bgPopover` as a background, with no availability branch, and
   `LogFilterBar.swift` says in one line why its arrow is not.
24. **No gated file spells `Divider()`; a menu separates with `Section`.** No
    gated file spells `Divider(`, and every gated file that builds a `Menu`
    spells `Section` at least once. Two sets are pinned by equality: the gated
    files building a `Menu` (`menuFiles`: `ChromeControls.swift`,
    `SearchHistoryMenu.swift`, `ProjectTreeView.swift`,
    `LocalChangesView.swift`, `DatabaseViewerView.swift`,
    `LeetCodeBrowserView.swift`; `BranchSwitcherView.swift` left it when a
    remote row's `Menu` became the component's own submenu) and the subset that also separates with
    `Section` (`menuSectionFiles`: `SearchHistoryMenu.swift`,
    `ProjectTreeView.swift`, `LocalChangesView.swift`,
    `DatabaseViewerView.swift`), so a new `Menu` is added deliberately, with or
    without a separator. The viewer is in the second set by the rule's own
    reading rather than by a separator: its cell menu (Copy, Set to NULL) has
    none, and the `Section` it spells is the sidebar list's (Tables, Views);
    the computed set pairs any `Section` with any menu in the same file, so it
    is pinned in both, deliberately. The browser's row context menu (Open)
    needs no separator. Part five (d) removed twenty-one more `Divider()`s
    (decision 1 of its section) and kept the twenty-second, the one inside
    `LeetCodeCommands`: **the rule's one exception**, pinned by set equality
    (`commandsDividerBodies`, one entry). A main menu built inside a
    `Commands`/`CommandMenu` builder is drawn by AppKit where no chrome role
    reaches it, and there the rule's premise — that a `Section` stands in for
    the platform's separator — is false in that menu's structure. A standalone probe against the real
    AppKit menu (item arrays read after `NSMenu.update()`, heights from
    `NSMenu.size`) measured the same three items in four shapes:
    `Section { A; B }; Section { C }` held four separator items at 126 pt (above the
    first item, two adjacent between the groups, below the last);
    `A; B; Section { C }` and `Section { A; B }; C` two each at 104 pt;
    `A; B; Divider(); C` one at 93 pt. That probe was a structural
    measurement, not a screen capture, and nothing it saw was drawn on a
    screen. Five in-window menus built by three of the four
    `menuSectionFiles` were measured on screen, and there AppKit hides the
    edge and adjacent separator items (the numbers are in part five (d)'s
    closure). Whether the menu bar draws what a `Commands` menu's structure
    holds was not measured then and is not measured now — the stated limit of
    both measurements — so the `LeetCodeCommands` exception stands on the
    structural numbers as before, neither strengthened nor weakened. Two Swift
    sites still state the premise without that qualifier: the comment above
    the Open Problem button in `LeetCodeOpenProblemSheet.swift` and the doc
    comment on `commandsDividerBodies` in `ChromeThemeSourceGatingTests.swift`.
    Both describe the structural reading of a `Commands` menu and were left
    as written. So `LeetCodeCommands`' body is pinned by
    shape — exactly one `Divider()`, no `Section` — and the rest of its file is
    held to the ordinary rule. Every other `Commands` builder is in an ungated
    file (`PisakaApp.swift`, which spells `Divider()` five times across three
    menu builders — the Save group, View and Find — and `FoldCommands.swift`, which spells none). No token rule can measure a
    rendered menu; the shape pin is what a suite can see. `LogFilterBar.swift` left the first set in part five
    (c) — its branch menu is now the shared `ChromeMenuField`, whose one `Menu`
    lives in `ChromeControls.swift`, which joined in its place. Part five (c)
    removed four more `Divider()`s: three in `LSPServerSettingsView.swift`
    (between server rows and around the toolchain rows) and one in
    `AcknowledgementsView.swift` (under the detail header). The `Section`
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
    CommitDialogView.swift, NewPullRequestSheet.swift,
    PullRequestMergeSheet.swift, DatabaseViewerView.swift,
    LeetCodeBrowserView.swift, LeetCodeOpenProblemSheet.swift,
    LeetCodeJudgeView.swift}` (the commit dialog
    since part five (b), its message box; the two pull-request sheets since
    part five (c); the database grid's cell editor, the problem browser's
    query, the open-problem sheet's input and the judge's test-case box since
    part five (d)), plus `ChromeControls.swift`, where the box is composed into the field. The
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
    word", "Regular expression", in that order, each paired with its one
    `glyph:` (`.caseSensitive`, `.wholeWord`, `.regex`), read from
    comment-stripped text with literals kept, since the names under test are
    the literals. This
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
   assignment. Part five (c) adds a third: every `.frame(` in
   `CommitDialogView.swift`'s `private var messageBox` body (found through the
   call matcher, so a wrapped call counts) names `messageLineHeight` and none
   names `metrics` — the message box is counted in lines of the code font it
   draws at, and at least one such frame must exist.
28. **A secondary window's ground is set in the window subclass.** The files
    constructing `EscClosableWindow` (a call: the token then its argument list)
    equal the six secondary-window controllers, by set equality; none of them
    assigns `backgroundColor` (a whitespace-tolerant assignment pattern, since the
    clause is about an assignment's shape); and the subclass's brace-matched
    designated initializer assigns `backgroundColor` and names `bgPanel`.
29. **The merge wash is Core's one answer.** The `mergeWashRole` token is read
    by `MergeView.swift` alone among the app files; no app file other than
    `ChromePalette.swift` spells `conflictBackground` or `bracketMatch`; the app
    files spelling `currentLine` are exactly `ChromePalette.swift`,
    `BracketOverlayLayoutManager.swift` and `LineNumberRulerView.swift` (the
    current-line highlight's two painters), by set equality; no gated file chains `.withAlphaComponent`/`.opacity` onto a
    role's colour (`nsColor(…)`, `.color(…)` or `chromeColor(…)`, brace-matched,
    line breaks allowed — `MinimapView.swift`'s alpha on a syntax-table colour is
    code zone and outside the rule); part five (b)'s ten files spell
    `withAlphaComponent` nowhere; and `MergeView.swift` spells no
    `performAsCurrentDrawingAppearance`. Since part five (g) the alpha clause
    has a second form: an `.opacity`/`.withAlphaComponent` chained onto **any**
    call is red when that call's own balanced argument list spells a role case —
    a raw value from `ChromeColorRole.allCases`, after a leading dot or
    qualified as `ChromeColorRole.accent`, matched as a token at nesting depth
    one, not inside a nested call — which catches the
    helper-call form (`resolving(.accent).opacity(…)`) the first form could not
    see. **The depth-one scope is deliberate**: `ChromeControls.swift`'s two
    button-dimming chains, `.background(RoundedRectangle(…).fill(theme.color(.accent)))`
    followed by `.opacity(isEnabled ? … : 0.5)`, are view modifiers fading a
    whole button, not an alpha on a role's colour, and in both the role sits in
    a nested call. The first form stays as it was, because it also catches a
    role passed as a variable (`theme.color(role).opacity`). **Mutation-checked,
    not assumed**: restoring `if state == .dropTarget { return
    resolving(.accent).opacity(0.4) }` into `ProjectTreeView.swift`'s
    `color(for:resolving:)` turned the rule red naming `ProjectTreeView.swift`
    ("chains .opacity onto resolving(…), which spells a role"), and green again
    once restored. **The one gap that remains is the local-variable form** (the
    fold placeholder's former `color.withAlphaComponent(0.5)`, removed in part
    five (f) rather than caught): following a value through a `let` needs data
    flow, which a text scan does not have.
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
    each of part five (b)'s ten files and part five (c)'s seven the `Button`
    count equals the `buttonStyle` count, each file's number stated
    (`SettingsView.swift` 3 — Sign In… and Sign Out are both spelled, one built
    at a time, plus Change… — `LSPServerSettingsView.swift` 6,
    `AcknowledgementsView.swift` 1, the two pull-request sheets 2 each,
    `LSPInstalledLicenses.swift` and `LicenseTextView.swift` 0). Part five (d)'s
    seven files state **two numbers each**, since menu items and a
    confirmation dialog's buttons cannot take a style: `DatabaseViewerView.swift`
    8 buttons, 6 styled (the sidebar's Hide and Show styled with the rest; the
    cell menu's Copy and Set to NULL unstyleable),
    `DatabaseConsoleView.swift` 3/1 (the dialog's Run and Cancel),
    `LeetCodeBrowserView.swift` 6/4 (the row's context-menu Open and the list's,
    below the last row),
    `LeetCodeDescriptionView.swift` 3/3 (`.plain`), `LeetCodeJudgeView.swift`
    2/2, `LeetCodeOpenProblemSheet.swift` 8/3 (`LeetCodeCommands`' five menu
    items) and `LeetCodeLoginView.swift` 1/1. The same part adds the
    open-problem sheet to `chromePrimary`'s callers; the console, the browser,
    the judge, the sheet and the sign-in sheet to `chromeSecondary`'s; and the
    browser to `ChromeCheckbox`'s. The design pass adds the consent banner and
    then Local Changes, whose toolbar Commit… left its hand-drawn accent button
    for the shared style, to `chromePrimary`'s callers.
31. **A code pane's ground goes through one definition.** `CodePaneGround.apply(`
    is called in exactly `CodeEditorView.swift`, `SourceViewerContent.swift`,
    `DiffView.swift` and `MergeView.swift`; the rule is **total and resolves no
    types**: across the gated set plus `CodeEditorView.swift`, every
    `backgroundColor` assignment that is not a layer's (`layer.`/`layer?.`, rule
    twenty-five's) lies inside `CodePaneGround`'s brace-matched body or is one of
    six sites pinned by file **and count** — so a second assignment in a pinned
    file fails too — each pin carrying its reason: `EscClosableWindow.swift`, the
    secondary window's ground (rule twenty-eight); `MainWindowChrome.swift`, the
    main window's ground, owned by the window-chrome rule;
    `CompletionPanel.swift` and `HoverPanel.swift`, `.clear` on a borderless
    `NSPanel`, which must stay clear for its own rounded layer to draw and is not
    a code pane; `ProjectSearchView.swift`, a text attribute's background rather
    than a view's; `LicenseTextView.swift` (since part five (c)), the unswept iOS
    half's `.clear` on a `UITextView` so the screen's ground shows through — not
    a code pane, and the macOS half assigns none, its `bgEditor` being painted
    by the SwiftUI caller. What it no longer claims: it does not identify which object is
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
    MergeView, LocalHistoryView, LeetCodeBrowserView}` (the problem browser,
    since part five (d), whose rows are a file-scope child struct reading the
    environment); for every gated interface-scaled root, the
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
    frame. The switcher popovers' rows carry no exemption: since both moved
    onto `ChromePopover`'s pieces they draw design glyphs through
    `DesignGlyphImage`, sized by construction, and the three container-font
    entries that pinned their old SF Symbol icon column (`branchRow`,
    `remoteBranchRow`, `projectRow`) are gone.
    `LSPConsentBanner.swift` carries no exemption either: the consent bar's
    one glyph takes its own scaled font on its own chain.
    Part five (d)'s seven files add no exemption: every glyph they draw — the
    banner and message marks, the key and lock glyphs, the sort and paging
    chevrons, the two signed-out offers' glyph, the statement pane's icons, the
    judge's info badge — takes its own scaled font. The spinner draws no symbol at all (an
    arc on a `Circle`), so it needs none either.
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
    updating the pin. Today the pin holds two lists: `LocalHistoryView.swift`'s,
    whose one background is `snapshot.fileName == selection.wrappedValue ?
    Color.clear : chromeColor(.bgPanel)`, and — since part five (c) —
    `AcknowledgementsView.swift`'s, pinned with an **empty** list of
    backgrounds: it sets no row background at all, so nothing paints over the
    platform's selection, and a `listRowBackground` added there is red — and,
    since part five (d), `DatabaseViewerView.swift`'s tables-and-views sidebar,
    pinned `[[]]` on the same footing. On macOS a row background is drawn
    over the platform's selection box, so an unconditional one hides the
    selection outright — the Local History revisions list shipped that way,
    and its selected row is the one Restore applies.
36. **No gated file builds a platform form control.** No gated file spells the
    tokens `Form`, `Picker`, `pickerStyle`, `Stepper`, `Toggle`, `TabView` or
    `tabItem` (matched through `containsToken`, so `ChromeStepper(` is not a
    `Stepper` and `ChromeQueryToggle(` not a `Toggle`; `pickerStyle` and
    `tabItem` bare for the leading-dot reason). Each draws in the platform's
    colours and metrics, and the chrome draws a replacement for every one in
    `ChromeControls.swift`. Two already-gated surfaces were swept to make it
    green: the commit dialog's author editor (`Form`, now two stacked shared
    fields) and the Log bar's branch menu (an inline `Picker`, now the shared
    menu field's first caller). `Toggle` overlaps rule thirty on purpose, so
    the family is listed whole in one place.
37. **A picker's shape follows its set, and each settings shape has its pinned
    callers.** A small set known at build time is a segmented control, a set
    read at run time a menu field; a standing preference is a switch, an option
    of one action a checkbox. The files spelling each shape are pinned by set
    equality, the defining file included: `ChromeSegmentedControl` —
    `ChromeControls.swift`, `SettingsView.swift`, `PullRequestMergeSheet.swift`;
    `ChromeMenuField` — `ChromeControls.swift`, `LogFilterBar.swift`,
    `SettingsView.swift`, `NewPullRequestSheet.swift`,
    `LeetCodeBrowserView.swift`, `LeetCodeOpenProblemSheet.swift`; `ChromeStepper`,
    `ChromeSwitch` and `ChromeSettingsTabBar` — `ChromeControls.swift` and
    `SettingsView.swift`. Each caller's constructions are pinned by count
    besides, matched through `callRanges(_:in:)` so a wrapped call counts —
    rule thirty's shape applied to these five: `SettingsView.swift` two
    segmented controls, two menu fields (LeetCode's default language and the
    editor font family), three steppers (editor font size, interface zoom,
    terminal font size), two switches and one tab bar; `PullRequestMergeSheet.swift` one segmented control;
    `LogFilterBar.swift`, `NewPullRequestSheet.swift`,
    `LeetCodeBrowserView.swift` and `LeetCodeOpenProblemSheet.swift` one menu
    field each;
    the defining file none. The rule cannot read a set's size, so the sets and
    the counts together are its whole expression: a segmented base-branch
    list, or a switch where a checkbox belongs, moves a file between sets or
    changes a count and fails. The counts arrived in the part's review round:
    the sets alone missed a shape change inside a file already spelling both
    shapes, which `SettingsView.swift` is.
    The menu field's shape is pinned whole besides: inside `struct
    ChromeMenuField`'s matched body its one `Image(` — the chevron — lies in the
    body matched after the `Menu`'s `label:`, hidden from accessibility there.
    The part lifted the field with the chevron a sibling of the `Menu`, which
    draws the same and opens nothing when the arrow is clicked; its review
    round moved it into the label.
38. **No gated file builds a platform table.** No gated file spells the
    tokens `Table` or `TableColumn` (through `containsToken`, so `LazyVStack`
    and identifiers merely holding "Table" are not hits), and
    `LeetCodeBrowserView.swift` spells `LazyVStack`. A `Table`'s header,
    grounds, alternation and selection box are the platform's, which is the
    wall rule thirty-six names for the form controls; the problem-catalog
    browser was the last gated one, and its rows are now the chrome's own.
39. **The problem catalog's three colour mappings are Core's one answer
    each.** No app file declares `func difficultyRole`, `func
    problemStatusRole` or `func verdictRole`; the app files spelling
    `difficultyRole(for:` and `problemStatusRole(for:` equal
    `LeetCodeBrowserView.swift`, and those spelling `verdictRole(for:` equal
    `LeetCodeJudgeView.swift`; no gated file spells `isGood` or `isAccepted`
    (the verdict's "good" rule moved to Core with its colour); and the
    difficulty and status case labels are pinned by count per gated file —
    the browser's nine (its two title switches and the status glyph switch,
    words and a glyph rather than a colour), zero elsewhere — with rule
    eighteen's stated limit. The iOS browser keeps its own colour table and is
    not gated.
40. **One spinner.** No gated file spells `ProgressView` or
    `progressViewStyle`; the files spelling `ChromeSpinner` equal the
    classified callers plus `ChromeControls.swift`, by set equality; and each
    caller's pair — how many of its constructions carry
    `.accessibilityLabel(` and how many `.accessibilityHidden(true)`, read from each
    construction's trailing modifier chain with rule twenty's clause — equals
    its row of `spinnerClassification`, the pairs summing to twenty. A site
    swapping one marker for the other, dropping both, or appearing anew moves a
    number.
41. **No alternating row fill.** No gated file spells
    `alternatingRowBackgrounds`, `isMultiple` or `isTinted`. The design's
    tables read by selection and hover; the database grid's and the console's
    zebras are deleted, and the platform's own alternation left with the
    `Table` (rule thirty-eight). A second clause reads the ordinary spelling,
    `index % 2 == 0`, inside a matched body only: no row-fill modifier's own
    text — its parenthesis-matched argument list and its trailing closure —
    spells `% 2`; `%` is not banned across the gated files. The row-fill
    modifiers are a named set, `rowFillModifiers`: `.background` and
    `.listRowBackground`. Until fix round 02 the clause read `.background`
    alone, and a `.listRowBackground(index % 2 == 0 ? … : …)` added to the
    console stayed green; it is red now. Stated limits: a parity computed
    elsewhere and handed over as a name (`.background(fill)`) is not seen, and
    neither is a modifier outside the set — the token ban, total across the
    gated files, stays the real defence. Shown red against
    `.background(index % 2 == 0 ? … : …)` in the console's result rows, in both
    the argument and the trailing-closure spelling, before it was committed.
42. **A served page's chrome is the palette's.** Four clauses. (a) The app
    files spelling `ChromePalette.documentPageChrome(` equal
    `{MarkdownPreviewPane.swift, LeetCodeDescriptionView.swift}` by set
    equality, so deleting either wiring fails. (b) No macOS app file outside
    `Sources/Pisaka/iOS/` spells `LeetCodeStatementDocument.Theme.resolved(` or
    `DocumentPageChrome.resolved(`: macOS never resolves Core's fallback
    into a page. That is a narrow ban, not the whole guarantee: the restated
    block does reach macOS — as the chrome `MarkdownPreviewTheme.light`/`.dark`
    carry for `withChrome(_:)` to overwrite, and as `SyntaxTheme`'s starting
    point — and what holds is that no served page *draws* it, because it is
    replaced from the palette before the page is built, which clause (a)
    guarantees. (c) The
    Core files spelling a CSS hex literal equal the two restated blocks, each
    count pinned — `MarkdownPreviewTheme.swift`'s code half (28) and
    `DocumentPageChrome.swift` (12) — and `LeetCodeStatementDocument.swift`
    spells none. (d) `func cssHex(` is defined in `ChromePalette.swift` alone.
    Clause (c) reads the comments-only scanner, literals kept, because a CSS
    hex literal *is* a string literal — one of the suite's four literal-keeping
    readings, named in its header.
43. **No document calls the sweep closed while a surface remains.** The macOS
    app files outside `Sources/Pisaka/iOS/`, outside `gatedFiles` and outside
    the four exemptions that name a system semantic colour, a SwiftUI hue or a
    `0xRRGGBB` literal equal `unsweptColorSurfaces` by set equality — `{}`
    since part five (f) swept the fold placeholder — so a measured surface
    missing from the set fails, and so does a set member no longer measured;
    the failure names the files. **Its bound**: this live half's measurement
    skips gated and exempt files, so it guards only the macOS app files that
    are **neither gated nor exempt**, failing when one of them starts painting
    outside the roles; a file that has joined the gated set is guarded by rules
    one and two instead — rule one for a system semantic colour or a SwiftUI
    hue, rule two for a `0xRRGGBB` literal. Verified by mutation with the set empty: an
    `_ = NSColor.systemRed` in `DefinitionPicker.swift` (ungated, not exempt)
    turned it red naming that file, green again once restored. **The document
    half is dormant** while the set is empty and wakes only when the live half
    measures a surface — dormant, not dead. While the set is non-empty, no Markdown
    file under `docs/` (except `docs/plans/`, whose tickets quote the claim to
    retract it) and not `CLAUDE.md` may call the colour sweep closed,
    finished or complete, or a part the last — matched as constructs,
    lower-cased over whitespace-collapsed text, not as one literal sentence.
    Sources read through the ordinary scanner, because the subject is what a
    file paints with and a doc comment discussing `.secondaryLabelColor`
    paints nothing; a colour-channel argument label (`green:` in
    `PlatformColor.swift`'s sRGB initializer) is removed before the hue check,
    since it names no colour. Part five (d) and part five (e) each made the
    claim and neither was true; this is the measurement that would have said so.
44. **The terminal's exemption shelters its two ANSI arrays and nothing else.**
    `TerminalTheme.swift` stays in the four exemptions, but the exemption's
    reason is true of its `darkANSIColors` and `lightANSIColors` alone. With
    both array bodies carved out, the rest of the file (ordinary scanner) spells
    no `0x` literal of any width — stricter than rule two's six digits, on
    purpose — constructs no `NSColor` at all, calls `rgb8(` nowhere but its
    definition and builds a `Color(` only inside `rgb8` and `terminalColor`, and
    names no token of rule one's semantic list, none of `CGColor`, `black`,
    `white`, `clear` or the greys, no `.system…` hue, and no named hue spelled
    as a member — rule one's hues plus `magenta`, matched only after a `.`
    because the converters' `red`/`green`/`blue` name channels — so
    `NSColor.red` or `.magenta` fails; the `.…Color` members
    it reaches are pinned by set equality, so `.controlAccentColor` fails; it
    must name each of `.bgPanel`, `.textPrimary`, `.accent`
    and `.accentTintStrong`; and each array holds exactly sixteen top-level
    `rgb8(` entries. The presence check is what catches a restored
    `.selectedTextBackgroundColor` selection: that token is also SwiftTerm's
    view property, so it is deliberately not on rule one's list, and restoring
    it removes `.accentTintStrong` from the file. The arrays are found through
    `matchedBracketBodyRange(after:in:)`, beside the brace-matching helper,
    because an array literal has no braces and the first `{` after either
    declaration belongs to a later function body; it searches for the `[` after
    the `=`, past the type annotation's own. Either array going missing fails
    loudly, naming the file and the declaration. Verified by mutation: the
    caret put back to `NSColor.selectedContentBackgroundColor` turned it red
    with three failures — "TerminalTheme.swift names a system colour outside
    its ANSI arrays: selectedContentBackgroundColor", "TerminalTheme.swift: the
    `.…Color` members outside its ANSI arrays changed — a new one is a system
    colour or a new sink" and "TerminalTheme.swift no longer names the role
    .accent — its four chrome colours are roles" — and green again once
    restored.
45. **The shared field suppresses the platform's focus ring.** Inside
    `ChromeThemedTextField`'s declaration (ordinary scanner), the inner
    `TextField(` construction's modifier chain — up to the end of its enclosing
    block — applies `focusEffectDisabled`. One modifier fixes every caller, so the
    rule reads the declaration alone and sweeps no other file for bare
    `TextField(` constructions. The ring compiles, and only a key window with real
    first-responder focus shows it, which the headless app bundle cannot reliably
    reach — so this rule and the live check are the only nets for it.
46. **Design glyphs are drawn only through the helper.** Every macOS source
    under `Sources/Pisaka/` (the iOS directory aside) other than
    `DesignGlyphImage.swift` is read through the comments-only scanner, literals
    kept — the name an image is loaded by *is* a literal, and a resource's name
    is the same literal — and no load in it may name a glyph. A load is
    `Image(` or `NSImage(named:`, each also spelled through `.init(`, or one of
    the resource loaders `ImageResource(`, `NSImage(resource:` and
    `image(forResource:`; naming a glyph is a string literal equal to a
    `DesignGlyph` raw value, or the token `assetName` or `rawValue`. The symbol
    loads — `Image(systemName:`, `Image.init(systemName:` and
    `NSImage(systemSymbolName:` — are different calls and are not matched;
    `AppIcon` is not a glyph and stays exempt. The matcher is a static function,
    `glyphLoadsNamingAGlyph(in:)`, and a self-check
    (`testTheGlyphRuleFlagsEveryLoadSpelling`) feeds it an inline snippet of
    every bypass — the raw value, a literal through each spelling, the resource
    loaders — requiring each to be flagged and the symbol loads to pass. The helper must itself load by `assetName` exactly twice, once per
    half, so the rule cannot read nothing. A glyph loaded inline compiles and
    draws — untinted by the theme, or announced by its asset name. The rule
    **relies on asset symbols staying off**: a generated accessor is a glyph
    load with no call the matcher reads, so `DesignGlyphAssetTests` pins
    `ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOLS: NO` in `project.yml` — once,
    and no active line setting it or
    `ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS` to anything
    else. **Its horizon is the argument list**: a glyph name passed through a
    local variable, or interpolated into a string, passes. That is the
    local-variable form, named rather than fixed — following a value through a
    `let` needs data flow — and the matcher is deliberately not widened.
47. **The tab's fill stays inside the strip; the strip's ground paints the title bar.**
    `TabStripView.swift` is split at `struct TabStripCell`. Every colour
    background after the declaration — the active cell's `bgEditor` fill — must
    carry `ignoresSafeAreaEdges: []`; every one before it — the strip's
    `bgPanel` ground — must not spell `ignoresSafeAreaEdges` at all. The strip is
    the topmost view of the editor column under the window's title bar, which is
    transparent and is therefore the window's top safe-area inset, and a SwiftUI
    colour background extends into the safe area by default. Unconfined, the
    active fill climbed through the title bar to the window's top edge;
    confined, the strip's ground left the `ContentView` root's `bgCanvas`
    showing above the editor column, two-toning the title bar against the
    sidebar's `bgPanel` (both seen on 2026-10-04). So a confined ground fails the
    rule as loudly as an unconfined fill. The reading, `groundRuleReading(of:)`,
    collects each half's colour backgrounds through `colourBackgrounds(in:)`,
    which reads every `.background(` through `callRanges`, skips a list opening
    with `alignment` (a view background, which does not climb) and counts a list
    naming `theme.color(` or a `Color.` token, whitespace folded. Each half must
    show at least one colour background, so neither can go vacuous, and a
    self-check (`testTheGroundRuleFlagsEveryMisScopedBackground`) feeds inline
    snippets for both halves: a confined or otherwise scoped ground before the
    declaration is flagged, a bare, conditional or wrapped fill after it is
    flagged, the real file's shape passes, `.background(alignment:)` and a
    non-`Color` background are ignored on both sides, and a file without the
    declaration is refused. The headless `HostedRender` has no title bar, so
    neither the climb nor the two-toning can be seen off a bitmap and this rule
    is the only net. **Its horizon**: this one file, and only arguments spelled
    as `theme.color(` or `Color.`.

Plus a **self-check** in the suite's own idiom: every gated file must actually
*name* a `ChromeColorRole`, or the checks above have gone vacuous — with ten
exceptions, each naming no role by construction while staying gated for the
rules it *can* break: `DesignGlyphImage.swift`, which paints the role its caller
names (gated for rules one and two and rule forty-six), `ChromeThemeEnvironment.swift`, which carries the
appearance down the tree and paints nothing, `LSPInstalledLicenses.swift`
(since part five (c)), a Foundation-only enum that returns the installed licence
documents and has no view, and `CommitGraphView.swift`, which draws only lanes
in `CommitGraphPalette`'s colours (all three gated for rules one and two); the
five window controllers — `DiffWindowController.swift`,
`MergeWindowController.swift`, `SourceViewerWindowController.swift`,
`LocalHistoryWindowController.swift` and `ProjectSearchWindowController.swift` —
which name no role since the window's ground moved into `EscClosableWindow`
(gated for rules one and two and the window-ground rule, a system colour or a
second, competing ground being what a controller can commit); and
`SourceViewerContent.swift`, whose one colour was the pane's ground and now
comes from `CodePaneGround` (gated for rules one and two and the code-pane
ground rule).

A second **self-check** holds the header's stated-exceptions paragraph to the
code (`testTheHeaderNamesEveryLiteralKeepingReading`, added in part five (h)).
The `test…` names that paragraph spells must equal, by set equality, the test
functions whose code calls `GitHubSourceGatingTests.strippingComments(_:)`, the
literal-keeping scanner. The code is read with comments and literals stripped, so
a doc comment that mentions the scanner, and the check's own needle, both drop
out. A rule switching scanners in either direction fails here, and so does a
rule renamed without its header entry. It gates no source file. It exists
because `CLAUDE.md` calls each suite's doc comment the record of its
literal-keeping readings, and a record nothing reads drifts the way both rule
summaries already had.

And, beside the rules rather than among them, a **cross-file count**: the suite
counts its own numbered rule markers and asserts that both summaries of it — the
list above and `CLAUDE.md`'s chrome-theme invariant — spell that number in the
sentence naming it, that the list above enumerates exactly that many items
in order, and that the suite's own header inventory — the doc comment
`CLAUDE.md` sends readers to — carries one bolded bullet per rule, titled as
that rule's marker and in the markers' order. The header check compares the two
ordered title lists whole (lower-cased, backticks and a trailing full stop
dropped), so a swapped pair, a dropped rule's bullet or a bullet for a rule that
no longer exists each fails where a count would pass; the markers were reworded
to the bullets' titles to make that comparison possible. The header
was added to the check after it had ended at rule thirty-four with thirty-five
declared: nothing read it while both documents were checked. It gates no source file; it exists because both summaries had already
drifted, each correct on the day it was written, and a count that drifts tells a
reader the sweep is smaller than it is while omitting the newest rules. Same
shape as `LintConfigurationTests`' style-version pair: one source of truth, every
document spelling it checked against that.

Beside it, a **restated-count check**: the list above restates some pins'
numbers, and those drifted exactly as the count once did — rule thirty's part
five (d) sentence kept the database viewer's 6/4 after the pin became 8/6 (and
the problem browser's 5/4 after 6/4), and rule twenty's builder list kept
omitting the viewer's three sidebar builders. The suite now generates both from
the pins: every `partFiveDButtonCounts` entry must appear in rule thirty as
`` `name` b/s `` or `` `name` b buttons, s styled ``, and every builder
`panelControlBuilders` holds for a part five (d) file must be named, backticked,
in rule twenty. Stated reach: rule twenty's `labelCount`s are prose ("exactly
one") and are not read, only the builders' names, and only for part five (d)'s
files, the earlier parts' builders being described by kind rather than listed;
rule thirty's part five (c) numbers are phrased per group and are not held. The
check gates no source file and is not a rule, so the count above is unchanged.


And, also beside the rules, **what a rule in this suite may do** — the
convention every new rule is written to, because the rules that broke it are
the ones that failed. A rule pins a **set** by equality (`gatedFiles`,
`colorExemptions`, `diffWashReaders`, `sharedFieldConstructors`), or asserts
the **presence or absence of a token** through `containsToken`, or takes a
**brace- or bracket-matched body** and does one of those two inside it, or in
the text left once it is cut out (rule forty-four). It does not
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
chain, narrowed rather than extended. Thirty-four is the third shape — a
balanced region per link, then a token assertion inside it — which is why the
next sentence's second half holds. No fourth shape is permitted and no rule
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
set is closed against call sites. It has grown once, in part five (g), because
the design states a value the table did not carry — a third strength of the
accent wash — and a role whose only justification is a call site is still a
case for this refusal. Either an existing role means what the surface is trying to say —
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
