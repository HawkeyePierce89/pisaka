# PisakaCore + Pisaka app (macOS) — code folding

Design documentation for code folding, part 1: the regions, the state, the
hiding, the gutter and the two menu commands. Each entry records a file's
contract, invariants and the reasoning behind non-obvious decisions — read the
relevant entry before modifying that file, and update it when behavior changes.

## The shape of the feature, in one paragraph

Collapse a block behind its first line and expand it again: a chevron in the
gutter, a `…` placeholder at the end of the header line, *Fold* (⌘⌥←) and
*Unfold* (⌘⌥→) in the Edit menu. **The buffer is never modified.** Hiding is
glyph generation plus line-break suppression, so every engine in the repository
that works on UTF-16 offsets — the search, the bracket scan, blame, diagnostics,
the indentation tints, the on-save transform — keeps working on the full text
and needed no fold-aware line. Where the blocks *are* comes from a language
server (`textDocument/foldingRange`) when one serves the file and from a pure
bracket-and-indentation scanner otherwise; **an answer is never a mixture** of
the two. What is folded lives in a per-file memory owned by the editor view — the
viewport memory's lifetime — and is never written to the session. macOS only: iOS has no gutter chevron, no layout-manager
subclass and no menu surface, and the seam method is defaulted so neither iOS
surface grew a call site for a question it would throw away.

Every *decision* is pure and lives in `PisakaCore` — where a block is
(`FoldRegionScanner`, or a server), what is folded (`FoldState`), what an edit
does to it (`FoldShift`), what a save does to it (`FoldState.remapped`), where
the caret may rest (`FoldCaretRule`), what a jump opens (`FoldReveal`), which
block a command acts on (`FoldCommandRule`) — while the app layer owns only the
scheduling, the AppKit references, the drawing and the invalidations.

## Core

### `FoldRegion.swift` — what a foldable block *is*

`FoldRegionKind` is the closed three-case table (`comment`, `imports`,
`region`) `textDocument/foldingRange` names in its own `FoldingRangeKind`. The
specification leaves that field **open**, so a word outside the table is read as
**absent rather than as a refusal**: a block whose kind nothing here names is
still a perfectly good block. Nothing in part 1 branches on the kind at all — it
is carried because dropping a fact the wire already stated would only have to be
undone later. The fallback scanner never names one: brackets and indentation say
where a block is, never what it is.

`FoldRegion` is two facts and nothing else: the `hiddenRange` (UTF-16, into the
whole buffer) and the `headerLine` that keeps the chevron, plus the optional
`kind`.

**The hidden range's two endpoints, and why the header stays whole.** It starts
at the end of the header line's *content* and ends at the end of the last line's
*content*. So the first line stays visible **in full**, trailing `{` included —
the very thing that says a block follows — and the block's last line joins it,
closer and all, behind the placeholder. The header's own line separator is
*inside* the hidden range, which is exactly what makes the following text land
on the header's row when the range is hidden: a separator that is hidden causes
no line break (`FoldingTypesetter`, below). An alternative that hid whole lines
would either lose the `{` or leave the closing `}` on a row of its own; this pair
of endpoints is the one that collapses to a single visual line.

**An empty hidden range is not representable.** The initializer is failable and
refuses one, along with a negative offset and a negative header line, so "the
gutter draws a chevron here" and "there is something behind it to hide" are one
fact rather than two that can disagree.

**`Comparable` is the one ordering key** every producer sorts by and every
consumer reads back: header line ascending, then the **longer** region first,
then the earlier one, so the order is total. The longer-first tiebreak is what
makes the outermost region on a line the first of that line's candidates (the
merge rule reads it straight through) and what makes the **innermost** region the
*last* of a nested chain (`FoldCommandRule` reads it the other way round). One
key, never a second notion of "smaller".

### `FoldRegionScanner.swift` — the fallback answer

Pure and Foundation-only, in `BracketDepthScanner`/`IndentLevelScanner`'s shape,
counting UTF-16 units over an `NSString` the caller already holds. It decides
where a block *is*, never what it *means*, so every region it answers carries no
`kind`. This is the answer for every file no language server serves — on most
projects, most files.

**Two sources, one answer.**

- *Brackets.* Every matched pair `BracketDepthScanner` reports
  (`isUnmatched == false`) whose opener and closer sit on different lines. The
  pairing is **re-derived from that scanner's own output** rather than re-scanned,
  so exactly one place in the repository decides which `}` closes which `{` — the
  treatment of crossed and orphaned brackets included, which this engine must not
  hold a second opinion about. A closer arriving on an empty stack cannot happen
  by that scanner's construction and is *skipped* rather than trapped on, so a
  future change over there degrades to a missing chevron instead of a crash. Line
  numbers come from a binary search over the line table, so the half stays
  `O(b log n)` rather than walking the lines once per bracket.
- *Indentation.* A line followed by lines indented deeper, ending at the first
  line back at the header's level or shallower. Levels come from
  `IndentLevelScanner` driven by the `IndentLevelWidths` the caller was handed —
  the same widths the indentation painting uses and, one step back, the same unit
  `IndentUnitRule` already answered for Enter. **Nothing here re-derives an
  indentation unit.** Widths that cannot describe an indentation (either of them
  zero or less) answer the bracket half alone — `IndentLevelScanner`'s own rule,
  applied by asking it rather than by restating it.

**The rules it owns.** Both sources require **two or more lines** (a block that
hides nothing is not a block, which `FoldRegion`'s initializer states one level
down). Blank and whitespace-only lines *inside* an indentation block belong to it
and never end it, while blank lines *after* it are trimmed off — so a block ends
on its last real line and folding it never swallows the empty line separating it
from what follows. Both of those are one rule in one place: each open header
closes at the last **non-blank** line seen before the shallower line that ended
it. Two candidates sharing a header line **merge into one** — one line, one
chevron — and **the bracket candidate wins**, because a brace says where a block
ends while indentation only guesses; between two of the same source the longer
wins, which is `FoldRegion`'s ordering key again. No comment and no import
regions: naming a block needs a grammar and this engine has none.

**Cost.** One pass over the bracket tokens plus one levelled pass — both already
chunked or bounded by the engines that produce them — plus a linear merge. The
blankness of a line is read off the levelled runs rather than by a second
character walk (`IndentLevelScanner` stops at the first character that is neither
space nor tab, so a line whose runs reach the end of its content had nothing else
on it), and the runs come back ascending, so one cursor walks them alongside the
lines instead of asking per line. That is the same order of work the rainbow
bracket scan already does on every debounce, which is what makes it cheap enough
to run right after one.

`FoldRegionScannerTests` covers nested brackets, a single-line pair yielding
nothing, an unmatched bracket, the indentation block with interior blank lines
and trailing ones, the bracket-wins merge, degenerate widths, CRLF/CR/NEL text
and an empty buffer.

### `FoldState.swift` — what is folded, and five rules about it

`FoldState` stores **both halves**: the folded `regions` (in `FoldRegion`'s own
order, no duplicates) and the merged `hiddenRanges` they cover (ascending,
non-overlapping, **touching spans joined**). The reason is nesting: an outer
region's hidden range subsumes an inner one's, so "which regions are folded" and
"which offsets are hidden" are genuinely two questions. Keeping the inner region
is what lets unfolding the outer one leave it folded; merging the coverage once,
here, is what keeps the caret rule, the gutter and the layout manager from
re-deriving the same overlap arithmetic and disagreeing about it. Touching spans
are joined because two hidden spans that meet leave nothing visible between them.

Three mutations (`fold`, `unfold`, `toggle`) and three questions. `unfold`
removes the **exact** region, never whatever else covers it. `isFolded` compares
bounds *and* header line — a region the scanner recomputed one line shorter is a
different region, which `reconciled(with:)` settles rather than this guessing at
it. `hides(offset:)` is **strict**: a hidden range's two endpoints are positions
the caret may legitimately occupy (the first is where the placeholder is drawn,
the second is where the text after the block resumes), and only what lies between
them has no on-screen position at all. `folded(containing:)` answers in the
header's sense — a region *is* at the line that stays visible for it — and when
two folded regions share a header line the longer wins, because that is the one
whose placeholder is drawn. It is the **one** question the gutter asks about a
header line: the chevron's direction is drawn from it and a chevron click is
resolved through it, falling back to the candidate map only when nothing on that
line is folded. Reading the map first would hand a click on a collapsed chevron
the *longest candidate* while ⌘⌥← had folded the *innermost* — folding the outer
block instead of opening what the chevron says is closed (`app-editor-overlays.md`).

`hiddenRange(collapsingLineStartingAt:)` is the **layout's** question rather than
the caret's, and the reason it is not `hides(offset:)` read a second way. A line
loses its own row exactly when the separator that would have broken it is hidden —
the typesetter zero-advances every separator *inside* a hidden range, its first
unit included — so the test is on the code unit immediately before the line's
start and is **inclusive** of the range's own start, where the header's separator
sits. Asking `hides(offset: lineStart)` instead is right only while every hidden
range ends mid-line, which is the fallback scanner's shape but not a server's: one
naming `endCharacter: 0` ends a range exactly at a line start, and that line —
already laid out on the header's row — would be called visible and drawn a second
gutter number on top of the header's. The covering range is returned rather than a
`Bool` so the gutter can skip a whole collapsed run in one step instead of one
hidden line at a time (see the ruler, below).

**The three maintenance rules**, each in one place:

- `reconciled(with candidates:)` — a folded region survives only if a candidate
  with the **same header line** exists, and then takes that candidate's bounds. So
  a source that recomputed a block one line shorter leaves a fold hiding the right
  text rather than a phantom hiding one line too many, and a fold whose header
  line no candidate names springs open: the block it described is gone. The header
  line is the anchor because it is the one thing the two sources agree on — the
  line the user pressed the chevron on. Bounds move whenever the block's last line
  does; the header only moves when the text above it does, and `FoldShift` has
  renumbered it by then. **When a header line carries more than one candidate the
  closest in length wins.** The fallback scanner merges them and never offers two,
  but a server may report a block and a nested one opening on the same line
  (`list.forEach(function (x) {`) and ⌘⌥← deliberately collapses the *innermost*
  of those; re-anchoring to the longest would silently grow that fold to the outer
  block on the very next answer, hiding code nobody asked to collapse. Ties keep
  `FoldRegion`'s own order, so a header line with a single candidate behaves
  exactly as it always did.
- `clamped(toLength:)` — `EditorViewport.clamped(toLength:)`'s rule applied to
  ranges: a region that cannot fit is **dropped, never truncated**. A truncated
  fold would hide a span nobody computed — half a block, ending mid-line — which
  is a lie the layout would then draw. Dropping it merely shows the code.
- `remapped(through plan:)` — see the save rule below. Its per-region half is
  `FoldRegion.remapped(_:through:)`, because **both** lists a fold owner holds go
  through it: the folded state *and* the candidate list a chevron is drawn from.
  The candidates are not bookkeeping — the edit shift is suppressed for a save
  rewrite, so nothing else would move them until the next answer lands a debounce
  later, and a chevron clicked in that window would fold bounds measured against
  the pre-save text.

`FoldStateTests` covers fold/unfold/toggle including nested regions, the strict
`hides`, the coverage merge, reconciliation by header line, clamping, and the
memory's record/restore/forget/remap/removeAll.

#### The save rule versus the shift rule

Fold bounds are moved through a save by **`SaveTransformPlan.remappedRange(_:)`**
— the same function that already moves the caret, each selection endpoint and the
scroll anchor, so nothing about a save can move them apart (`core-editorconfig.md`
carries the plan's own entry). It is deliberately **not** `FoldShift`'s three-way
rule: a save that trims trailing whitespace *inside* a folded block **intersects**
it, and the shift rule drops what it intersects — which would spring every
collapsed block open on an unattended autosave tick. A save rewrites what it was
asked to rewrite and moves what it moved; it restructures nothing, so remapping is
exactly right and shifting is not. Header lines are carried **unchanged**, and
that is sound because none of the three transforms changes how many separators
precede a given line: `end_of_line` rewrites separators in place, trimming deletes
only whitespace within a line, and the final newline is appended at the very end
of the buffer. A region whose remapped range comes out empty is dropped, since an
empty hidden range is not representable.

#### `FoldCaretRule` — where a caret may rest

A **single caret** (a zero-length selection) may never sit strictly inside hidden
text: there is no glyph there to draw it beside, so it would either vanish or be
drawn at a lie. The rule is **directional**, because the two answers mean opposite
things to the person pressing the key: moving forward into a folded block lands
*past* it, moving backward lands *before* it, so one arrow press steps over the
whole block and the next does not step back into it. `previous` supplies the
direction and nothing else; a request carrying none — a click, a programmatic
selection, a fold gesture, or a `previous` equal to `proposed` because nothing
moved — passes `NSNotFound` and lands at the hidden range's **start**, beside the
placeholder. A selection **with length** is returned untouched: selecting across a
collapsed block includes the hidden text, which is what makes copying it yield the
whole block — the behaviour "the buffer is never modified" promises.

**Every path that can hide text asks the rule**, and one of them has no gesture
behind it: a freshly landed answer is re-anchored by `reconciled(with:)`, which
takes the *candidate's* bounds and can therefore report the same block one line
longer, growing the hidden range over a caret that never moved. The controller
publishes to two views and posts no selection, so it reports the change instead —
`FoldController.didGrowHiddenText`, wired in `attachFolding` to the one method
that applies the rule (`app-editor.md`). The report is any change rather than a
measured growth, and it carries no direction, for the fold gesture's reason:
nothing moved the caret, the text under it stopped having a position.

#### `FoldReveal` — what a jump opens

`unfolding(_:in:)` returns the state with **every** folded region the range
reaches unfolded, nested ones included in one pass: unfolding only the innermost
would leave the text hidden by the outer one still covering it, so a reveal that
opened one fold would still land on nothing. The overlap test is
`range.location < hiddenEnd && rangeEnd > hidden.location` and deliberately not
`NSIntersectionRange`: a zero-length range — a caret reveal — shares no unit with
anything and would never intersect, while this test unfolds exactly when that
caret sits strictly inside. A range that only touches the header line's own text
ends at or before the hidden range's start and unfolds nothing, which is right: it
is already visible.

#### `FoldStateMemory` — the per-file, per-run store

`[String: FoldState]` with `record(_:for:)`, `state(for:clampedToLength:)`,
`forget(_:)`, `remap(_:through:)` and `removeAll()`.

**The key is a `String`, not `OpenFile.id`.** `id` is a fresh `UUID` per
`OpenFile`, so closing and reopening a file — which must keep its folds within a
run — would produce a new id and lose them. The app supplies the canonical path
for a url-backed file and the tab id's `uuidString` for an unsaved buffer, so the
key is the *file*, not the tab.

**There is deliberately no `prune(keeping:)`**, which is the one divergence from
`EditorViewportMemory`: a viewport is where you were reading and is meaningless
once you left, while a fold is a statement about the file's structure the user
made on purpose. Closing a tab must not discard it. The store is cleared wholesale
on a **folder switch** (a different project is a different set of files), one
entry is dropped when that file's text was replaced out from under a background
tab (the remembered folds describe a buffer that no longer exists), one entry is
**moved** when the thing that replaced it was a save (`remap(_:through:)`, below),
and the whole
store goes with the editor that owns it: **nothing here is ever written to the
session.** That last part is `EditorViewportMemory`'s lifetime exactly — the app
holds one memory per code editor — so dismantling that view empties it: closing
the **last** text tab and selecting a **database-viewer tab** each put a different
surface where the editor was. The divergence above is about `prune(keeping:)`
alone, and it is what makes closing one tab of several, then reopening that file,
find its folds again.
`record` stores an *empty* state rather than removing the entry, so "I unfolded
everything" survives a tab switch as itself.

**`remap(_:through:)` is the save rule reaching a file nobody is looking at.** A
save that catches a tab no editor is showing rewrites it through
`WorkspaceModel.replaceText(_:for:)` (`core-editorconfig.md`), which is the same
replacement signal a Replace All, a revert or a merge apply raises — and those
*do* invalidate what was folded. A save does not: it moves text without
restructuring it, so that file's entry takes the plan's remap exactly as the shown
buffer's live state does. Without it an unattended autosave trimming whitespace
would open every fold in the background tab it caught, which is the one outcome
choosing the plan's remap over `FoldShift` exists to prevent — the same rule, on
the same reasoning, applied to the half of the answer that is not on screen. A key
the store has never been told about is left **absent** rather than gaining an empty
entry, which would claim "unfolded everything" for a file nobody has opened.

#### `FoldCommandRule` — which block a command acts on

Both commands ask the same shape of question — "the innermost region the caret is
in" — of two different sets: *Fold* of the **candidates**, *Unfold* of the
**folded** ones. Keeping that one containment test here rather than once per
command in the view is what stops the keyboard and the gutter from disagreeing
about which block the caret is in.

**Containment is the block's whole extent, header line included**: a caret is
inside a region when it sits on the header line *or* strictly past the hidden
range's start and no further than its end (that last offset being the end of the
block's final line, which is still the block). A caret on the line *after* the
block is outside it. **Innermost is the last in `FoldRegion`'s own order** — only
a nested chain can contain one caret, and within one the innermost sorts last.
Containment is tested against the selection's **start**, because that is where the
caret is and both commands are about the caret.

*Fold* carries **one refusal**: a selection whose end reaches past the block is a
statement about more text than the block holds, and collapsing it would hide part
of what the user selected while leaving the rest on screen. Nothing guesses at a
bigger region to fold instead — the answer is "no", not a different block. A
zero-length selection has no end to reach past and never refuses. *Unfold* has no
refusal of its own: opening a block can never hide anything.

### `FoldShift.swift` — one edit, applied to both lists

`DiagnosticShift` applied to fold regions, line for line and on purpose: the two
answer the same question about the same kind of value (a UTF-16 span plus the line
it is numbered by, maintained between two authored answers), and a second, subtly
different three-way test is exactly the kind of divergence that produces a one-off
bug in one of them only. So the rule is the same rule — a region **entirely
before** the edit is untouched byte for byte, one **entirely after** is shifted by
`changeInLength` and renumbered from `newLineStarts`, and one whose hidden range
**intersects** the touched span is **dropped**, which for the folded state means
that block unfolds.

Dropping is the honest answer: the edit changed the text the fold was hiding, and
nobody knows where the block ends until the scanner or the server says. Typing
*inside* a folded block is only reachable through a reveal, which unfolds it
first; typing on the header line is the ordinary case this rule is written for,
and it opens the block rather than hiding the character just typed.

Both comparisons are **half-open**, and that is load-bearing at both edges for the
diagnostics' reasons: a region ending exactly at the edit's location covers only
characters the edit did not touch, and one starting exactly at the pre-edit end
covers only characters it did not remove. Because a hidden range starts at the end
of its header line's content, typing anywhere on the header line — including at
its very end, one character before a `{`, the commonest edit there is — is an
insertion at or before the region's start, and the block survives shifted. That is
why the test is `>=` rather than `>`.

A shifted survivor's header line is recomputed from `newLineStarts` (from the
shifted range's **start**, which is on the header line by construction), so it
lands on the line the *editor* says it is on now — the line the gutter draws its
chevron beside. An untouched survivor keeps its stored header line: nothing before
the edit moved, so re-deriving it could only launder a divergence. Unlike the
diagnostics', **both numberings here are the editor's own** (`LineStartIndex`),
never LSP's: a region arriving from `textDocument/foldingRange` is mapped into
buffer offsets and renumbered against the editor's table before it ever reaches
this function, so D1's separator divergence is settled upstream and cannot
reappear as a drifting chevron.

**Any inconsistent input returns `[]`** — the honest "nothing folded", never a
drifted set. The checks are spelled out on the function: a line-start array empty
or not anchored at `0` on either side, a negative edited location or length, an
`oldEnd` before `loc` or overflowing, any region whose end or shifted bounds
overflow, and a shifted region `FoldRegion`'s initializer refuses (handled and
unreachable, deliberately: the failable initializer is answered honestly rather
than force-unwrapped). One bad entry poisons the whole answer on purpose:
everything springs open, the next scan re-offers every chevron, and nothing is
left hiding text at coordinates nobody can justify. What is deliberately *not*
checked is the same pair `DiagnosticShift` leaves alone — an edit wholly past the
end of the previous text, or a survivor landing past the new buffer's length —
because line-start tables carry no buffer length and the only caller cannot
produce either.

A second overload applies the same rule to a whole `FoldState` (the coverage is
derived from the regions, so there is nothing else to shift). `FoldShiftTests`
covers before/after/intersecting, the two half-open edges, renumbering, the
overflow guards and every fallback trigger.

## The seam and the wire

### The sixth seam method

`CodeIntelligenceProviding.foldRegions(for: FoldRegionRequest) async ->
[FoldRegion]`, defaulted to `[]`. `FoldRegionRequest` carries `fileURL` (`nil`
for a url-less buffer), the buffer's **live** `text` (D2: document sync is
request-driven, so the text travels with the question, and it is also the text the
fallback scans — one coordinate space for both answers), the `language`, and the
`indentWidths`.

**The widths are carried rather than derived**, because there is exactly one
indentation-unit rule and it is not a provider's: the width Enter appends comes
from `IndentUnitRule` (`.editorconfig` first, inference second), and no provider
can see an `.editorconfig` — they hold a text and a URL, not the walk. So the app
computes the widths through the one path the indentation tints already use and
hands them over, and the scanner measures a block with the same unit the editor
types with. A provider deriving its own would be a second opinion about
indentation, which this codebase does not have. The LSP provider ignores them: it
asks a server that has its own idea of where a block ends.

This is **the one question in the seam about a document rather than a position** —
no caret, no identifier, no offset — because a chevron per header line is a
property of the file, not of wherever the user happens to be standing. The
default is `hover`'s reason read one way further: folding is macOS-only, so
neither iOS surface has anything to hang an answer on.

The two providers answer the same contract, and the LSP one is held to it
rather than trusted with it: the handshake says `lineFoldingOnly: false`, so a
server's `endCharacter` is used verbatim — that is what the flag buys, a closing
token joining the header's row — but its `startCharacter` is **floored at the
header line's content end**. A server naming the start of the folded *node*
(column 0 of an import group's first item, the `//` of a comment run, the `{` of
a block) would otherwise hide the header line's own text, and "the header line
stays visible in full" is not a preference here: it is what makes a chevron point
at something readable, what keeps `FoldCaretRule` from ejecting a caret clicked
into that text, and what makes `FoldReveal`'s "a range that only touches the
header's text unfolds nothing" true. The scanner gets the same range by
construction; the floor is what makes the server's answer say it too.

The full seam contract, and where this sits among the six questions, is in
`core-intelligence.md`; the wire half, the capability node and the budget are
**D38** in `core-lsp.md`.

### The routing

`RoutingIntelligenceProvider.foldRegions(for:)` is the file's **ordinary** shape,
which is worth saying because the three questions before it are not: hover and
rename end at the server, and references has a second answer that is a *model's*.
Folding has a real second answer of its own — the pure scanner, over the text
already in the request — so every rule in that file applies unaltered, **"an empty
answer is not an answer" included**. `canServe(language)` is asked first (a `nil`
language already means "this buffer has no language", the one state no server can
be asked about and the one the scanner answers perfectly well), the LSP attempt
runs inside `withBudget`, and an expired or empty answer falls through to
`SymbolIntelligenceProvider`, whose whole implementation is one call to
`FoldRegionScanner.scan`.

**An answer is never a mixture.** Whichever source answers, answers the whole
file: merging a server's comment regions into the scanner's bracket ones would
produce two chevrons on one line under two different notions of where a block
ends, with no rule able to say which is right. `FoldRoutingTests` pins that an
unserved language answers the fallback's output **byte for byte**, that a served
one prefers the server, and that an empty server answer falls through.

## App (macOS)

### `FoldController.swift` — the fold owner

`@MainActor`, beside `BracketHighlightController` and `HoverController`, and
shaped like the first of them deliberately: a cancellable debounce task plus a
**monotonic generation token captured synchronously before the hop**, so an answer
a tab switch or a further edit superseded discards itself instead of drawing the
previous file's chevrons. The *key* is compared too, so an answer cannot land on a
file it was not asked about even if the counter happened to agree.

**The debounce is 400 ms and its own**, not a chain onto `LSPDocumentSyncController`:
document sync for this question is request-driven (D2 — the live buffer travels
with the request through `LSPWorkspace.prepare`), so there is nothing to wait for.
Same length, same triggers, one fewer coupling.

`Source` is `HoverController.Source`'s shape and for its reason — a folder switch
swaps the provider and the root under a live editor, so the four inputs (provider,
file URL, language, widths) are *read* at the moment a question is asked rather
than captured in a closure. **Read behind the debounce, not in front of it**:
deriving the widths is a full-buffer pass (`IndentEngine.inferIndentUnit`) over one
more whole-buffer `textView.string` copy, and doing it before the sleep would
charge every keystroke for the question the debounce exists to ask once. Nothing
is lost by waiting — a newer ask would have bumped the token first, so the buffer
those inputs describe is still the text the question carries.

**Triggers.** A text change asks behind the debounce; a tab switch, a tab open or
a retarget records the outgoing file's folds, restores the incoming one's
(clamped to the incoming buffer here, reconciled against the real candidates when
the answer lands — the two halves of making a remembered fold safe, in the order
the information arrives) and asks **at once**, because waiting out the debounce
would leave the previous file's chevrons on screen; a language change or an
`.editorconfig` revision bump asks at once too, since both move where blocks are.

**Between two answers the candidates are shifted, never re-asked.** One edit runs
both the candidate list *and* the folded state through `FoldShift`, so a chevron
stays beside the block it names while the user types above it instead of blinking
out on every keystroke. A fresh answer replaces the candidates wholesale and is
reconciled with the folded state by header line.

**Every write funnels through `apply(_:)`**, which is also the only place the two
views and the memory are told (one `publish()` rather than three call sites,
because the chevrons, the hidden glyphs and the remembered state answer the same
question and must never be one frame apart; both views treat unchanged input as a
no-op, so it is cheap to call unconditionally). `fold(_:)` and `unfold(_:)` exist
beside `toggleFold(_:)` because *Fold* on an already-folded block must leave it
folded rather than spring it open, which a toggle would do the moment the command
is held down. `remap(through:)` is the save path, and it moves the **candidates**
alongside the state and publishes unconditionally rather than through `apply(_:)`,
whose no-change guard would otherwise skip the push whenever nothing was folded.
`forget(key:)` publishes unconditionally for the same reason: the common case for
a buffer replaced out from under a tab is that nothing was folded in it, and
skipping the push there leaves the gutter drawing chevrons for text that no longer
exists. `remapRemembered(key:through:)` is `remap(through:)`'s off-screen half and
publishes **nothing**, because nothing on screen changed: a save that caught a tab
no editor is showing has no live state and no candidate list to move — that file's
whole fold answer is its memory entry, asked again from scratch when it is next
shown. `forgetAll()` drops the **key** with the entries, because the coordinator
clears the memory before it records the outgoing tab and before the incoming
buffer is announced — leaving the key behind would let either `recordCurrent()`
write the previous project's file straight back into the store just emptied, which
is "cleared wholesale" in the doc and one stale entry per switch in fact.
The layout manager is resolved
**dynamically** (`textView?.layoutManager as? BracketOverlayLayoutManager`) for
`BracketHighlightController`'s reason: `replaceLayoutManager` can swap it under the
text view, and a stale reference would hide text in a manager nothing draws from.

**A reader.** It never raises the writer gate and is never gated by one; it writes
no file, registers no edit and does not touch the text storage at all.

### `FoldCommands.swift` — the whole menu surface

*Fold* (⌘⌥←) and *Unfold* (⌘⌥→) in a `CommandGroup(after: .pasteboard)`, beside
Toggle Comment — the group they belong to is "things done to the code in front of
you", not "things done to the file". `PisakaApp` names `FoldCommands` exactly
once, and this is the only file where a fold command is spelled.

The items carry no state and are wired to nothing: like ⌘D and Toggle Comment they
reach whatever editor holds the focus through the **first responder**
(`NSApp.keyWindow?.firstResponder as? EditorTextView`, further requiring
`isEditable` and `!hasMarkedText()` — a read-only viewer is not this command's
editor, and a keystroke arriving mid-composition belongs to the input method).
That is what keeps them correct with several windows open and with the terminal or
the project tree focused.

**One beep, two reasons.** The editor answers whether it folded anything, and a
`false` — no collapsible block at the caret, no folded block at the caret, or a
selection reaching past the block — beeps exactly as a focus that is not an editor
does. To the person pressing the key those are the same event: nothing happened.
The shortcut pair was verified free against every `keyboardShortcut` in the app
(⌘⌥F, Find in Files, is the only other ⌘⌥ one) and against the text view's own key
handling, which claims no arrow key with ⌘⌥ held.

### Hiding, the placeholder and the gutter

Both live in files documented in `app-editor-overlays.md`:
`BracketOverlayLayoutManager.swift` (the two halves of hiding — the `.null` glyph
pass and `FoldingTypesetter` — plus the `…` placeholder and the one geometry
answer the text view hit-tests against) and `LineNumberRulerView.swift` (the
chevron column, the numbering skip and the chevron click).

### The `CodeEditorView` wiring and the reveal funnel

The coordinator's half — the triggers, the memory key, the caret hook, the two
command entry points, the placeholder click and **the reveal funnel** — is
documented in `app-editor.md`.

## The reveal funnel, and its true shape

**Every jump-to-a-range in the editor goes through one coordinator method,
`Coordinator.revealRange(_:)`**, which applies `FoldReveal` before it selects and
scrolls. Revealing text that has no on-screen position lands the reader somewhere
arbitrary, and a new `scrollRangeToVisible` beside a `setSelectedRange` compiles,
runs and scrolls to a line that is not drawn — which is why the shape is pinned by
set equality rather than by convention.

The shape found in the tree, and now enforced:

- **Two caller files.** `CodeEditorView.swift` (`applyReveal`, where the app's
  `EditorRevealState` requests land) and `EditorSearchController.swift`
  (`select(_:)`, through a hook the coordinator installs — the find bar's one jump,
  which used to `setSelectedRange`/`scrollRangeToVisible` for itself).
- **One in-file non-reveal site.** `CodeEditorView.swift` holds exactly two
  `scrollRangeToVisible` calls: the funnel's own, and the Tab plan's caret scroll
  after a raw-storage edit. The second is **not** a reveal — it re-shows a caret
  the selection path just produced and the caret rule has already sanitized — so it
  is named with that reason rather than routed.
- **Three excluded text views**, none of which holds fold state:
  `SourceViewerContent.swift` (the read-only out-of-project viewer),
  `MergeView.swift` (the merge result pane) and
  `iOS/CodeEditorCoordinator_iOS.swift` (the platform folding does not ship to).
- **Two `reveal.reveal(` posters**: `PisakaApp.swift`, whose two sites
  (`activateSearchMatch(url:range:)` and `activateUsage(_:)` — Find in Files, Go to
  Definition inside the project, the Problems rows, the Usages rows and the symbol
  jump all funnel through them) land in `applyReveal`; and
  `SourceViewerWindowController.swift`, which drives **that window's own**
  `EditorRevealState` and has no fold controller at all.

`FoldReveal` and `FoldCaretRule` are each named in `CodeEditorView.swift` alone.

## `FoldingSourceGatingTests`

A repository-file suite in `DatabaseViewerSourceGatingTests`' shape: it reads
`Sources/` through `#filePath` with Foundation only and matches against
**comment- and literal-stripped** text (`LSPSourceGatingTests`' Swift scanner).
That is load-bearing rather than tidy — every file it reads states its own rules
in prose and most of them quote the very tokens matched (the controller's doc
comment names `FoldShift`, the ruler's names `FoldRegionScanner`, the layout
manager's names `GlyphProperty.null`), so a raw `contains` would stay green on a
comment describing a deleted call site.

What it pins, and why the compiler cannot:

1. **Hiding lives in one file, both halves.** `GlyphProperty.null` and
   `NSATSTypesetter`/`.zeroAdvancementAction` appear in
   `BracketOverlayLayoutManager.swift` and nowhere else. Either half in a second
   file is a second opinion about what is hidden; both compile perfectly alone, and
   the failure is a drawing artefact no assertion can see.
2. **The fold commands live in `FoldCommands.swift` alone**, and `PisakaApp.swift`
   names `FoldCommands` exactly once.
3. **The reveal funnel, by set equality** — the four sets listed in the section
   above, plus the two counted sites (`CodeEditorView.swift` exactly two
   `scrollRangeToVisible`, `EditorSearchController.swift` exactly zero).
4. **The caret rule, by set equality too**: `FoldCaretRule` in
   `CodeEditorView.swift` alone, with `MergeView.swift`,
   `SourceViewerContent.swift` and the iOS coordinator asserted as named
   non-callers.
5. **No view file decides what the state decides**: `FoldState`'s mutating members
   are spelled in `FoldController.swift` alone, and no view re-derives the
   two-line minimum, the bracket-wins merge or the shift's three-way test.
6. **The app-side fold files are macOS-gated** (`#if os(macOS)`), and no file
   under `Sources/Pisaka/iOS/` names anything in the feature.
7. **The fold layer names no writer gate**: neither `autosave` nor `localChanges`
   appears in it. Naming one would compile perfectly and turn a debounced
   background question into a gate the editor waits behind — the rule the symbol
   index lives under, for the same reason.

## Known limits

- **iOS has no folding at all.** The seam method is defaulted, both hiding halves
  and the gutter column are AppKit, and there is no menu surface to hang the two
  commands on.
- **The minimap draws every line, folded or not.** It renders from the text, not
  from the layout, so a collapsed block still occupies its full height there.
  Part 2's work.
- **`kind` is carried and never read.** Comment and import regions from a server
  are ordinary regions here; nothing folds all comments or all imports yet.
- **Nothing is persisted.** Folds die with the editor view by design (see the
  memory's own entry above); a relaunch, a branch switch that rewrites the file,
  or any edit intersecting a folded block opens it.
