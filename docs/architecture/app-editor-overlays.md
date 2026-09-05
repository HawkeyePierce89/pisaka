# Pisaka app (macOS) — editor overlays: brackets, blame, gutter, minimap, themes

Design documentation moved verbatim from the root `CLAUDE.md` (which now holds only a one-line-per-file index). Each entry records a file's contract, invariants and the reasoning behind non-obvious decisions — read the relevant entry before modifying that file, and update it when behavior changes.

  - `BracketOverlayLayoutManager.swift` — the editor's `NSLayoutManager` subclass
    (macOS, `@MainActor`) carrying every editor overlay: the rainbow
    foreground colors (`BracketDepthScanner`), the background behind the
    caret's matched pair (`BracketMatchEngine`), and the search bar's match
    backgrounds (`EditorSearchController` over `TextSearchEngine` — the ordinary
    matches plus the "current" one in its own color). **Why temporary attributes**:
    all of them are drawing state, not document content — temporary attributes
    live on the layout manager rather than in the text storage, so applying them
    registers no text edit (nothing lands in the per-file undo manager and the
    SwiftUI binding never sees a change), and it is the same surface Neon styles
    through, so the two mechanisms share one channel instead of fighting over the
    storage's attributes. **Why interception rather than an attribute provider**:
    Neon's `LayoutManagerSystemInterface.applyStyles` writes *only* through
    `setTemporaryAttributes(_:forCharacterRange:)` and **clears** the range before
    each write, so any color applied out of band is wiped the next time Neon
    validates that range (a scroll, an edit, a re-parse); and the colors can't come
    from Neon's own `attributeProvider` either, because a bracket has to be a
    *token* for that to fire and several grammars (JSON most visibly) don't
    capture brackets at all. So `setTemporaryAttributes(_:forCharacterRange:)` is
    overridden to call `super` and then mix the intersecting overlays back in with
    `addTemporaryAttributes` — a *merge*, so Neon's syntax colors in the same range
    are preserved, never replaced — under a re-entrancy flag (a subclass recursing
    on its own writes would be an unbounded loop, not a glitch). `setRainbowRuns(_:)`
    replaces the cached runs (visible range only, sorted by location, which is what
    lets the per-write intersection binary-search instead of scanning). The three
    *background* caches — `pairRanges`, `searchRanges` (ascending by location and
    non-overlapping, what `TextSearchEngine.matches` returns, so the per-write
    intersection binary-searches them too) and `currentSearchRange` — are written
    by `setPairRanges(_:)` and `setSearchRanges(_:current:)`, and **every one of
    them paints through a single private `paintBackgrounds(clippedTo:clampingTo:)`
    — the only place in the class that adds a temporary `.backgroundColor`.** It
    walks the three caches in one fixed order, pair → matches → current, so a
    later write wins: the current match sits on top of an ordinary match, which
    sits on top of the caret's pair highlight. Because that order lives in *one
    loop body* shared by both paint paths — the state setters (through the private
    `repaintBackgrounds(clearing:clampingTo:)`, which removes `.backgroundColor`
    over the previously painted ranges and then repaints the whole buffer) and
    Neon's per-write repaint (`applyOverlays(in:)`, which calls the same painter
    clipped to the styled range after the rainbow loop) — it is physically
    impossible for the two to disagree, so the highlight cannot change color
    depending on whether a scroll, a re-parse, or a ⌘G painted it last. **No other
    method may call `addTemporaryAttributes(.backgroundColor)` directly**, and the
    blanket `removeTemporaryAttribute(.backgroundColor,…)` clear is what makes
    that invariant load-bearing rather than stylistic: it is safe *only* because
    nothing else in the editor sets a temporary `.backgroundColor` (Neon's
    provider returns a foreground only and the selection highlight is drawn by the
    text view), so a second owner of that key would have its styling silently
    erased. `repaintBackgrounds` spends a **bounded** number of AppKit calls on
    that clear-and-invalidate, not one per range: the removal covers the bounding
    span of the previously painted ranges and the invalidation the bounding span of
    (cleared ∪ repainted), each one call. That is not micro-tuning — a search over
    a large file highlights *every* match in it, and the setters run on every
    keystroke in the find bar *and* every caret move (`setPairRanges` from the
    selection-change notification), so a per-range walk cost three AppKit calls per
    match per event. Clearing the gaps between matches along with the matches is
    safe for exactly the sole-writer reason above, and the repaint immediately
    after restores whatever should still be painted. Both setters additionally
    early-out when the state they are handed is unchanged, which is safe because
    the caches and the temporary attributes are only ever changed together (the
    edit path resets both through `clearBackgrounds`, and Neon's per-write clear is
    followed synchronously by `applyOverlays` repainting from the caches).
    `clearRainbow(in:storageLength:)` drops `.foregroundColor` over an edited
    range ahead of the rescan (a character that was a bracket a keystroke ago may not
    be one now; removing Neon's colors there too is harmless since Neon revalidates
    exactly the edited range anyway) and trims the cached runs from the edit point
    *onward*, because an insertion/deletion shifts every later location. Every
    range is clamped so a stale cached run can't raise — but the extent is a
    **parameter**, not `textStorage.length`, and that is load-bearing for the two
    edit-path clears. They run inside `didProcessEditingNotification`, which the
    storage posts *before* it notifies its layout managers: the temporary attributes
    are still in **pre-edit** coordinates while `textStorage.length` already reports
    the **post-edit** length. Clamping against the latter silently drops a range
    sitting beyond it, and the shift then slides that character — background and all
    — back into a valid index, stranding a highlight the controller no longer tracks,
    so nothing ever removes it (reachable by putting the caret before an opening
    bracket whose closer is the buffer's last character and pressing Backspace).
    `clearBackgrounds(storageLength:)` is therefore the edit-path spelling of
    "reset *both* background caches" — the caret's pair and the search matches —
    and both edit-path clears take the pre-edit length. Both are dropped rather
    than shifted because both are recomputed immediately afterwards anyway: the
    pair by the selection-change notification that follows, the search highlight
    by `EditorSearchController`'s re-run on the same edit (deferred one main-loop
    turn — see its `setNeedsRefresh()`).
    Diagnostics are the **fourth cache**, `diagnosticRuns:
    [(range: NSRange, severity: DiagnosticSeverity)]`, and they deliberately do
    not join the background family: squiggles paint through the
    `.underlineStyle`/`.underlineColor` temporary keys instead, so they cannot
    fight any of the three `.backgroundColor` writers or the rainbow's
    `.foregroundColor` — the class's "sole writer of `.backgroundColor`" rule
    stays intact with no new exception to remember, and Neon's per-write clear of
    styled ranges cannot erase them either because `applyOverlays(in:)`
    repaints them from the cache in the same pass it repaints everything else.
    The style itself is a marker as well as an attribute:
    `diagnosticUnderlineStyle = [.single, .patternDot]`, whose dotted pattern
    nothing else in this text view ever sets, is the unambiguous "this underline
    is ours" bit `drawUnderline` tests before replacing AppKit's straight line.
    `setDiagnosticRuns(_:)` replaces wholesale and repaints; its input goes
    through **Core's** `DiagnosticRun.merged(_:)` (`core-lsp.md`, `Diagnostic.swift`),
    which resolves overlaps *per character*
    into non-overlapping segments each carrying the most serious severity covering
    it (an error inside a warning makes its own stretch red without repainting the
    rest) and coalesces adjacent equal-severity segments back together. Resolved at
    this single write boundary
    rather than at draw time because the cache is what every later intersection
    binary-searches, and a small sorted non-overlapping array keeps those searches
    exact (`firstDiagnosticIndex(endingAfter:)`, the rainbow runs' device); the
    algorithm itself lives in Core because it is pure and this repository keeps pure
    decisions where `swift test` can see them — the view half only strokes what it
    is handed. A **zero-length** run widens to one unit there rather than vanishing:
    servers emit empty ranges, and every other surface shows them (the gutter marks
    the line, hover's `diagnostics(at:)` rule is written for exactly that shape, the
    panel lists it), so dropping them here alone would leave a line flagged in the
    gutter with nothing under it.
    `invalidateDiagnosticPaint()` is the third mutator and the one a *swap*
    needs: assigning the text view's whole `string` makes TextKit drop every
    temporary attribute over the replaced characters, so nothing is painted
    afterwards — but the cache still describes the outgoing document, and
    `setDiagnosticRuns` treats an unchanged set as a no-op. Two files carrying
    the same error at the same offset (the same bad `import` on line 1) merge to
    byte-identical runs, and the switch would land on an unpainted buffer whose
    gutter still shows the severity dots, since the ruler draws from its own
    array which the swap does not wipe. `updateNSView` therefore calls it on
    **every** content replacement — including the plain tab switch where the
    outgoing document's *store entry* deliberately survives, because what
    survives there is the model's set, not this view's paint. It removes no
    attribute (the swap already removed them all), so it clears the cache and
    `stalePaintStart` together rather than widening anything.
    `clearDiagnostics(in:storageLength:)` follows `clearRainbow`'s pre-edit-
    coordinate contract exactly — the storage posts its edit notification before
    notifying layout managers, so the cached ranges are still pre-edit while
    `storageLength` already is not, and the extent is therefore a parameter — but
    it *drops* rather than shifts: the coordinator has already run Core's
    `DiagnosticShift.updated(...)` over the same edit by the time this fires, so
    shifting here too would apply the rule twice to whatever survives. Dropping a
    cache entry does not drop its attribute — TextKit shifts the underline along
    with the characters — so the truncation records where it cut (`stalePaintStart`)
    and the next `setDiagnosticRuns` widens its clear from that character to the
    end of the buffer, removing what no cache entry any longer describes. What it
    records is floored at **the edit's own location**, and that floor is the whole
    correctness of the scheme: the dropped run's start is a *pre-edit* offset while
    the clear is measured in *post-edit* space, so a deletion — which shifts the
    surviving tail of a dropped run left, below that start — would otherwise clear
    from above the residue and leave the squiggle painted under undiagnosed text,
    with the recorded value already consumed and no later push computing a span
    that covers it. Nothing can shift below the edit's location, because everything
    from there to the edit's end is cleared outright, so the floor is exact rather
    than merely generous; the `min` against the dropped start still matters for a
    run straddling the edit, whose head survives *unmoved* at a lower offset. Without
    this, an edit intersecting a squiggle would leave an orphaned dotted underline
    attribute in the storage for the rest of the session (invisible today —
    `drawUnderline` draws nothing on a cache miss — but a lie waiting for a future
    reader of those keys).
    The zigzag is drawn by overriding `drawUnderline(forGlyphRange:...)`: AppKit
    has no wavy pattern (`NSUnderlineStyle` offers solid/dash/dot only), so when
    the passed style carries our marker bit the override strokes a small sine-ish
    polyline along the fragment's descent in the run's `SyntaxTheme` color instead
    of calling `super`, and anything else falls through untouched. A glyph
    fragment straddling two adjacent merged runs asks `worstSeverity(in:)` — the
    same worst-wins rule the merge applies inside a stretch, extended across its
    edge — and a fragment under no cached run draws nothing (the attribute came
    from someone else, or the cache moved on; both self-correct on the next
    push).
    The one thing this class draws that is **not** a temporary attribute is the
    **indentation-level painting**: a tint behind each unit of a line's leading
    whitespace, cycled by that unit's level. `setIndentLevelPainting(enabled:widths:)`
    hands over the whole of its state — the flag plus the two column widths
    (`IndentLevelWidths`) — from `CodeEditorView.Coordinator`; **this class derives
    neither width and reads no setting**, so the block Enter appends and the block
    painted under it cannot come from two different rules. A change to any of the
    three invalidates the *visible* area — `textView.setNeedsDisplay(visibleRect)`,
    so the invalidation is the size of the viewport rather than of the file — which
    is what makes toggling the preference, switching into a
    tab with a different unit, or an `.editorconfig` edit repaint without a reload;
    the blocks are **drawn, not stored**, so there is nothing to clear and no
    character range to compute, and asking the *view* is what keeps the coordinate
    space honest: `glyphRange(forBoundingRect:in:)` takes a **text-container** rect,
    so handing it the view's own `visibleRect` would be the wrong space twice over
    (offset by `textContainerOrigin`, and cut to the horizontally scrolled x-slice —
    which is precisely where a scrolled-right viewport keeps its leading
    whitespace). `BracketHighlightController.visibleCharacterRange` corrects both
    because it needs the range itself; this one does not;
    unchanged state is a deliberate no-op, since the setter is called on every view
    update and an unconditional invalidation would redraw the viewport on every
    keystroke. Off, a degenerate width (zero or less, which is also how an
    uncomputed width arrives) or an absent text storage draws nothing and leaves
    the pass byte-for-byte what it was.
    **The ordering is blocks first, then `super`**, in an override of
    `drawBackground(forGlyphRange:at:)`: `super` is what paints the `.backgroundColor`
    temporary attributes — the caret's matched pair and both search-match
    backgrounds — and the selection is drawn after this pass entirely, so painting
    the blocks *before* `super` puts every one of those on top of the tint, which is
    the only arrangement in which a search match landing on indentation stays
    visible. **Why temporary attributes stay out of it**: the obvious alternative, a
    `.backgroundColor` over each run, would make this class a second writer of the
    one key `paintBackgrounds` is documented as the sole writer of, and the two
    would collide over exactly the characters that matter — a search match sitting
    on whitespace would either lose its highlight or erase the tint depending on who
    wrote last. Drawing is not an attribute, so the two mechanisms never meet, and
    Neon's syntax styling is untouched for the same reason: this path writes no
    attribute at all. **Geometry is read at draw time and never cached**: the drawn
    glyph range becomes a character range, `IndentLevelScanner.runs(in:range:widths:)`
    answers the runs of the lines it intersects (so a draw never walks the whole
    file, and the buffer is read through the storage's `mutableString` handle rather
    than by bridging `string`, so a draw copies no text), each run's x extent is this
    layout manager's own bounding rect for it and its y extent the enclosing
    line-fragment rect — taking the height from the fragment is what makes
    consecutive lines at one level read as a single unbroken column, and it is why a
    font-size change needs no bookkeeping at all. The engine answers whole lines
    **unclipped**, so a run starting above the viewport is simply drawn where it is
    and clipped by the context. The level → color resolution is
    `SyntaxTheme.nsIndentLevelColor(forLevel:)` — the honest level in, `level % N`
    over a translucent four-hue palette out, the same "semantics in Core, color in
    the view" split the rainbow palette follows.
    **Folding is the one thing in this file that is not an overlay**, and it is
    two halves that live here together because they must agree about exactly which
    characters are hidden. *Half one* is the glyph pass: `setGlyphs(…)` **adds**
    `NSLayoutManager.GlyphProperty.null` to every character of every folded range,
    line separators included, so nothing inside it is drawn and nothing inside it
    advances. **Added, never assigned over**: `GlyphProperty` is an option set, and
    `.controlCharacter` — the bit on exactly the separators half two must be asked
    about — is carried in on the incoming properties. Overwriting it is what would
    make half two unreachable, so half one preserves it. The incoming buffer is `const`, so the properties are copied, the copy
    edited and `super` handed the copy — the glyphs and the character indexes travel
    through untouched, which is what keeps every UTF-16 offset meaning the same thing
    folded and unfolded. Nothing is copied at all when there is no fold or when no
    character in the batch is hidden: glyph generation runs on every edit and this
    override must cost a file with no folds nothing.     *Half two* is
    `FoldingTypesetter`, an `NSATSTypesetter` subclass answering
    `.zeroAdvancementAction` for every separator **inside** a folded range. **Half two
    is there because in TextKit 1 line breaking is the typesetter's decision, read
    off the characters rather than off the glyph properties**: a `.null` glyph on a
    separator still *ends its line*, so the glyph pass alone would draw a folded
    block as a run of empty rows rather than as nothing at all. **Measured in
    `PisakaAppTests/FoldLayoutTests.testFoldHidesTextAndCollapsesLines` against the
    real TextKit 1 stack (headless `NSTextView` + `BracketOverlayLayoutManager`
    via `EditorLayoutHarness`)**: folding the bracket block
    `header {\n    body1\n    body2\n}\nfooter` (hidden `"\n    body1\n    body2\n"`,
    3 separators) asserts (a) every hidden character carries
    `GlyphProperty.null`, (b) header `header {` and closer `}` share one line
    fragment, (c) fragment count drops from 5 to 2 (baseline minus hidden-separator
    count), and (d) unfolding restores 5. With the typesetter half neutralised
    (a harness-local replacement of the manager's `typesetter` with a plain
    `NSATSTypesetter` after `setFoldedRanges`), (a) still passes but (c) fails —
    fragments are 3 not 2, the visible newline after the block occupies its own
    fragment as a blank row — confirming half two is load-bearing. The `insert`
    preserving `.controlCharacter` is what keeps it reachable: an assignment would
    strip that bit and silence half two by construction. Both halves stay, and
    `FoldingSourceGatingTests` pins them in this one file. Both halves read one `FoldedRanges` — a small
    reference box holding the sorted, non-overlapping set `FoldState.hiddenRanges`
    hands over. It exists because the layout manager is `@MainActor` and the
    typesetter is not (TextKit asks its question straight out of the line-breaking
    loop), so the shared set lives in neither of them; every write happens on the
    main thread from `setFoldedRanges(_:clampingInvalidationTo:)`, every read happens during layout on that
    same thread, and nothing else holds a reference. Sortedness is the whole
    precondition of `hides(_:)`, which binary-searches rather than scans — glyph
    generation asks it once per character. Every character outside a folded range
    defers to `super`, so tabs, ordinary newlines and the container break are
    untouched.
    `setFoldedRanges(_:clampingInvalidationTo:)` stores the set and then invalidates
    **the union of the
    symmetric difference** of the old and the new one — the ranges that stopped
    being hidden plus the ones that started — never the whole file, so folding one
    block near the end of a large file does not re-generate every glyph above it;
    glyphs first, then layout, then display, in that order because each is decided
    by the half before it. Unchanged input is a **no-op**, since the coordinator
    calls this on every view update. The **extent the invalidation is clamped to**
    is a parameter for `clearBackgrounds(storageLength:)`'s reason, and one caller
    passes it: `FoldController.noteEdit` reaches here from inside
    `didProcessEditingNotification`, which the storage posts *before* it notifies
    its layout managers, so `textStorage.length` already reports the post-edit
    length while this manager is still in pre-edit coordinates. A shifted hidden
    range running to the end of the file would then be invalidated one delta past
    the extent this manager believes in — at best superseded a moment later, at
    worst an out-of-range raise on an ordinary keystroke. The pre-edit length keeps
    the invalidation in the same space as the glyphs it invalidates; everything
    beyond it is text the storage's own notification covers. `nil` ≡ this manager's
    current storage length, which is right for every other caller. **The text storage is never touched**: no edit
    is registered, nothing lands in the undo manager and the SwiftUI binding never
    sees a change — which is also why not one existing overlay needed a line of
    fold-aware code. Neon's syntax colors, the matched pair, the search backgrounds,
    the diagnostic underlines and the indentation tints simply have no glyph to land
    on inside a hidden range.
    **The placeholder** is the `…` drawn where the hidden text would have been,
    painted in `drawBackground(forGlyphRange:at:)` beside the indentation tints and
    measured by `placeholderRect(forFoldedRangeAt:)` — the one geometry answer the
    text view asks for rather than computes, because the rect is this manager's own:
    the x is where the first hidden glyph was laid out (and because that glyph
    advances nothing, that is exactly the end of the header line's visible content),
    while the y and the height come from the enclosing line fragment, so the box
    lines up with the row whatever the font does. Nothing is cached, for the
    indentation tints' reason: a zoom, a font change or an appearance switch needs no
    bookkeeping, the next draw simply measures again. The font is read off the text
    view (the zoom changes it and nothing here would be told) and the color is
    `secondaryLabelColor` — the placeholder is chrome standing in for text, not a
    token, and the platform color is appearance-aware, so light and dark need no
    second table. Only ranges whose start the drawn glyphs reach are painted.
    **`numberOfGlyphs` is deliberately never read** in the measurement, which is why
    its bound is `offset < storageLength` rather than a `min(…, numberOfGlyphs - 1)`
    clamp: `offset` names the first hidden character of a non-empty range, so it
    always addresses a character — and therefore a glyph — that exists, while that
    clamp would force glyph generation for the **whole document** (the cost
    `allowsNonContiguousLayout` exists to avoid, stated on `HoverController` and
    `captureViewport`) on every draw and every click while anything at all is
    folded. The hit-testing caller bounds itself to the visible range for the same
    reason. The whole feature is documented in `core-folding.md`.
  - `BracketHighlightController.swift` — the macOS `@MainActor` owner of the
    bracket overlays: it holds the cached `[BracketToken]` for the current buffer
    behind a (`fileID`, text length, edit epoch) cache key with a ~100 ms debounce
    and a
    monotonic generation token (the `MinimapTokenizer` precedent — a request
    matching the cache key still *cancels* a pending scan for a different key, the
    A→B→A tab dance), turns both engines' answers into layout-manager writes, and
    is thin view-layer code (untested, all the decisions being in Core). The scan
    stays **on the main actor** — unlike the minimap's tree-sitter parse — purely
    because of `BracketDepthScanner`'s chunked `getCharacters` read: the pass is a
    plain memory walk, so even a megabyte-scale file is imperceptible after the
    debounce, and the token array is never read across actors. The cache key
    deliberately **diverges** from the `MinimapTokenizer` precedent by *not* being a
    content hash: its `text` is always `NSTextStorage.string`, a lazily-bridged
    `NSString`, and `String.hashValue` on one transcodes the whole buffer — measured
    at ~57 ms for a 1.7 MB file, against ~1 ms for a native `String` of the same
    content and well under a millisecond for the bracket scan the key exists to
    avoid. It was also computed *eagerly, before the debounce*, on both the edit and
    the `updateNSView` path (which re-runs every keystroke, since the editor binding
    republishes `openFiles`), so no debounce could coalesce it — two full traversals
    per keystroke, breaking the "typing in a megabyte-scale file doesn't lag"
    criterion outright. `editEpoch` (bumped by `noteEdit`, which observes *every*
    character edit including programmatic ones and buffer swaps) distinguishes
    buffers exactly as well in O(1), with the text length carried alongside as a free
    backstop. `MinimapTokenizer` still has the hash-keyed shape and the same cost.
    `refreshVisible()`
    computes the visible character range (`glyphRange(forBoundingRect:in:)` →
    `characterRange(forGlyphRange:)`, x pinned across the full content width like
    `LineNumberRulerView`, so a horizontal scroll can't drop a bracket whose row is
    on screen), binary-searches the token array down to that slice, resolves
    `SyntaxTheme.nsBracketColor(forDepth:)` / `nsUnmatchedBracketColor` and hands
    the runs to `setRainbowRuns` — the scan is whole-document (depth at the top of
    the screen depends on every bracket above it) but the *attributes* are applied
    to the visible range only, and scrolling re-runs this without a rescan.
    `updateSelection(_:)` runs `BracketMatchEngine.pair(text:selectedRange:)` →
    `setPairRanges([open, close])`, `nil` → clear.
    `noteEdit(in:changeInLength:postEditLength:)` (the text-storage
    edit observer) does four things, each load-bearing: it drops the cached tokens
    from the edit point *onward* (an insertion/deletion shifts every later
    location) and `clearRainbow`s the edited range — converted to **pre-edit**
    coordinates first, since the storage reports `editedRange` post-edit while the
    attributes are still pre-edit, so an insertion of *k* at *L* resolves to `(L, 0)`
    (nothing existed there to clear, and inserted text inherits no temporary
    attributes), a deletion of *k* to `(L, k)`, and a same-length replacement to
    itself; it bumps `editEpoch`; it **clears `cacheKey`**,
    without which an edit that restores the previously cached text (a typo plus
    Backspace inside the 100 ms debounce, an undo, an auto-paired insert
    immediately deleted) would take `update`'s equal-key early return — cancelling
    the pending rescan and never scheduling another, leaving every bracket past the
    edit point uncolored for the rest of the session (this is the one place the
    `MinimapTokenizer` precedent does *not* carry over, because that class only ever
    replaces `model` together with its key, so its equal-key branch is always safe);
    and it clears **every** background overlay — the caret's pair and the search
    matches (`clearBackgrounds(storageLength:)`) — which is only correct
    *here* because `NSTextStorage.processEditing()` posts the notification before it
    notifies its layout managers, so the remembered ranges have not yet been shifted
    by the edit — clearing later, once the caret moved off the pair, would remove
    `.backgroundColor` at pre-shift coordinates and strand the highlight on whatever
    the edit pushed it onto. The following selection-change notification re-adds the
    pair at its new location, and the search highlight is restored by
    `EditorSearchController`'s re-run on the same edit. `reset()` cancels the pending
    task and drops the cache. The layout manager is resolved dynamically
    (`textView.layoutManager as? BracketOverlayLayoutManager`) for the same reason
    the gutter and Neon do, and a text view without it simply has the overlays
    disabled rather than crashing.
    One hook hangs off the applied scan: `onScanApplied`, called every time a scan
    has actually been applied — after the debounce on an ordinary edit, and
    synchronously on the immediate path a tab switch takes. It exists so the
    editor's *second* per-edit computation, the indentation-level widths (whose
    content half is `IndentEngine.inferIndentUnit(text:)`, a walk of the whole
    buffer), rides this class's one debounce and one generation token instead of
    growing a second pair of its own; a scan a newer request superseded never
    reaches `applyScan`, so the hook never fires for a buffer that is no longer on
    screen. Nothing here reads what the hook does — the coordinator sets it, weakly
    captured per `CodeEditorView`'s retain-cycle rule.
    **The freshness dependency the hook also covers, stated because it is
    indirect.** The coordinator recomputes the widths when the buffer changed *or*
    when `EditorConfigModel.revision` moved. That model is a plain class the editor
    does **not** observe: an on-disk `.editorconfig` edit reaches `updateNSView`
    only because the same FSEvents turn that calls `noteProjectFilesChanged()` also
    bumps `WorkspaceModel.treeRevision`, whose `@Published` change re-renders the
    content view. Because that path is indirect and could go quiet, the revision is
    compared **in the scan-applied hook as well** — one integer against the last one
    seen, on a path that already runs on every debounced edit and every tab switch —
    so a stale width never outlives the next edit or tab switch even when no
    re-render arrives. While the preference is off the recompute is skipped
    entirely and the cache cleared, so switching it back on finds nothing cached and
    computes once, on the turn the toggle flipped.
    **The cache's third key is the shown file, and it is the one the other two
    cannot stand in for.** `.editorconfig` answers *per file*, so a tab switch and
    a rename that moves a file into a different section (`foo.txt` → `foo.py`)
    both change the applicable properties while the revision and the text stand
    still. The switch is worse than it looks: the hook above fires from
    `updateBrackets`' immediate rescan, which `updateNSView` runs **before**
    `syncBlame` — and `syncBlame` is what records the coordinator's `fileURL`. So
    the recompute a tab switch triggers resolves the configuration against the
    file being *left*. Keying the cache on that URL too is what lets the
    preference's own re-apply — placed after both `syncBlame` and the
    `editorConfig` binding for exactly this reason (`app-editor.md`) — notice and
    derive again inside the same update. Without it nothing else in the key would
    move for a buffer that is only read, and the outgoing file's unit would be
    re-asserted until the next keystroke or FSEvents batch.
  - `BlameController.swift` — the macOS `@MainActor` owner of the gutter's git-blame
    annotation column (inside `#if os(macOS)`, modeled on
    `BracketHighlightController`): a **weak** ruler reference, its own
    `GitCLIService()`, `enabledFileIDs: Set<UUID>`, per-file last-seen disk
    revisions, and a monotonic `generation`; `attach(ruler:)`,
    `toggle(fileID:fileURL:)`, `sync(fileID:fileURL:diskRevision:contentReplaced:)`,
    `beginBufferSwap()` and `reset()`. Thin, untested view-layer code per repo
    convention — every decision that can be tested is pure and in Core
    (`BlameParser` for the output, `BlameShift` for the edit-driven shift the ruler
    applies); this class only schedules the load, guards it against supersession,
    and pushes the array into the ruler. `sync` reloads **only for an enabled file**
    and only when the shown file changed, **its path changed**, its buffer was
    wholesale-replaced, or its
    `diskRevision` differs from the last value seen for it (save, autosave, Save As,
    post-revert reload, merge apply,
    branch checkout). The path test is not redundant with the other three: a
    project-tree rename retargets the tab through `WorkspaceModel.applyRenamePlan`,
    which assigns `url` **alone** — `text`/`savedText` untouched, so no `savedText`
    assigner runs and no `diskRevision` bump follows — leaving id, buffer and token
    all unchanged while the blamed path ceased to exist; without it the column kept
    a blame taken at the old path until some unrelated later save happened to bump
    the revision. The rule is that the reload decision depends on every input the
    *result* depends on. An enabled file with nothing changed returns after recording
    the token, while a file annotate is *not* on for (or one with no url) **clears**
    the column when one is installed — which is what makes the per-tab toggle work,
    since switching to an un-annotated tab must empty the column rather than leave
    the previous file's annotations painted over it. A load
    captures the generation and drops its result if a newer request (a tab switch, a
    further save, a toggle-off, teardown) moved on. That token guards the *result*
    but not the *execution*, so it is paired with a **one-in-flight rule**
    (`isLoading` + a single newest-wins `pending` request): `blame --porcelain` is
    the slowest git command in the app and the only one issued automatically — an
    annotated file reloads on every autosave — so on a large file with deep
    history, where one blame outlasts the 2 s autosave window, unguarded issuing
    would queue subprocesses on `blameQueue` faster than they drain, burning a core
    on answers discarded on arrival while the column lags by the whole backlog
    rather than by one load. At most one blame runs and one waits; a held request
    carries the generation it was stamped with, so a toggle-off or teardown drops
    it instead of re-annotating a file the user switched off. A per-file annotation cache is
    deliberately not built: a reload is one short async subprocess, and reloading is
    also what keeps a tab correct after it was saved or checked out while off
    screen. **Errors are swallowed** — a file outside a repository, an untracked
    file, a missing `git` all leave the column empty with no alert and no beep;
    annotate is an inspection affordance, not an operation the user asked to
    succeed. "Empty" there means an *empty array is installed*, not that the install
    is skipped: the file is still enabled, so the ruler must stay in the annotating
    state its menu reports ("Close Annotations"), and an all-`nil` array draws
    nothing and contributes no width. **Three accepted inaccuracies, stated on the type as one rule: the column
    describes the file *on disk*, as it was when the load was issued.**
    `blame(fileURL:)` is a worktree blame, so an
    annotation always answers "who last changed this line in the file as git saw it
    then", and reality moves out from under that answer three ways — the buffer
    running ahead of the file (a, b) or the repository changing beneath an unmoved
    file (c). (a) A **dirty,
    never-saved buffer**: the load is laid out for the *saved* bytes while
    `BlameShift` only shifts annotations for edits made **after** it, so the column
    can be **offset by whole lines until the next autosave** (the ruler places the
    result through `BlameAlignment.aligned`, which always yields exactly one entry
    per displayed line, so a shorter or longer result is bounded into an offset
    rather than a trap). The window is short
    and closes with no user action — `AutosaveController` fires after 2 s of idle,
    on a tab switch and on focus loss, each bumping `WorkspaceModel.diskRevisions`,
    which reaches `sync` and recomputes. The alternatives are worse than the
    symptom, which is why neither is built: `git blame --contents -` would blame a
    file git has never seen (every unsaved line comes back uncommitted anyway, so
    the machinery buys a fraction of a second), and *saving on toggle* would make a
    read-only inspection command write the user's file. (b) **Typing while a load is
    in flight** is the same class of inaccuracy, likewise self-healing on the next
    save: `generation` guards against superseded loads and file switches and
    *deliberately not* against edits made while a load runs — cancelling on every
    keystroke would mean a file being typed in never gets a column at all. (c) **The
    repository changing while the file does not**: a `git commit`/`stash`/`pull`/
    `rebase` in the embedded terminal changes what blame answers without touching
    the buffer or its saved bytes, so no token moves and no reload is issued —
    freshly committed lines keep drawing blank until a tab switch or a toggle
    off/on. Unlike (a) and (b) this does **not** self-heal on a timer, and it is
    recorded rather than fixed because no signal exists to key it on: `treeRevision`
    is the only ambient change notification and `TreeRefreshFilter` deliberately
    drops everything under the opened root's `.git` — the rule that keeps a terminal
    `git status` from flickering the tree, whose cost is not worth re-introducing
    for an inspection affordance.
    `enabledFileIDs` is **deliberately never pruned on tab close** (documented on
    the property so it is not re-derived as an oversight), for three reasons: a
    `UUID` is never reused — `WorkspaceModel.open(url:)` mints a fresh id even for a
    file that was open and closed — so a stale entry can never match a live tab, and
    a closed-and-reopened file starts with annotate off either way, i.e. pruning
    changes nothing observable; the cost is 16 bytes per annotated tab, bounded by
    "tabs annotated during this editor's lifetime" and dropped wholesale in
    `reset()`; and pruning is not free in the way it looks, since the controller is
    handed a `fileID` per `sync` and never the open-tab list, so an
    intersection-based prune would mean threading `Set(model.openFiles.map(\.id))`
    from `ContentView` on every body evaluation — a fresh set per keystroke, since
    the editor binding republishes `openFiles` — plus a new view parameter, to
    reclaim bytes. This deliberately **differs from `WorkspaceModel.removeFile`**,
    which *does* prune `textReplacementRevisions`/`diskRevisions`: those are
    app-lifetime `@Published` dictionaries in Core pruned inside the very method
    that learns about the close, one line at a site that already has the
    information — neither of which the view-layer set has. **Out of scope**
    (follow-ups): an iOS variant (there is no gutter there), a commit-detail popup
    on clicking an annotation, "annotate previous revision", jumping from an
    annotation into the Git Log, and a date-format setting.
  - `LineNumberRulerView.swift` — `NSRulerView` subclass drawing right-aligned,
    1-based line numbers in the editor's gutter (TextKit 1). It also declares
    itself a **code** zoom surface (`ZoomSurfaceProviding`, `zoomSurfaceKind =
    .code`, no behavior). A ruler is the scroll view's `verticalRulerView` and so
    a *sibling* of the text view, not a subview: the pointer walk cannot reach it
    through the editor, and without the conformance a gesture over the gutter or
    the blame column would find no candidate at all and resize the whole
    application chrome (`docs/architecture/core-zoom.md`). In
    `drawHashMarksAndLabels` it enumerates only the layout manager's *visible*
    line fragments (so scrolling a large file stays O(visible lines)), binary-
    searching a cache of per-line UTF-16 start offsets to seed the first visible
    number in O(log n) and aligning each label to its fragment's vertical center;
    the trailing empty line is drawn from `extraLineFragmentRect` when the
    document ends in a separator. The cache comes from Core's `LineStartIndex`
    (so the gutter and minimap agree on line counts for every standard
    separator). It observes the clip view's bounds/frame and the text view's
    frame to redraw on scroll/resize, and the *text storage's*
    `didProcessEditingNotification` (which carries the edited range, unlike
    `NSText.didChange`, and coexists with Neon owning the storage *delegate*) to
    update the offset cache *incrementally* per character edit via
    `LineStartIndex.updated` — so typing in a large file scans the edit, not the
    whole buffer; attribute-only edits are ignored, and a wholesale buffer swap
    arrives as one full-range edit notification that rebuilds the cache (the same
    full rebuild the initial `textContentChanged()` does). It sizes `ruleThickness` to the widest
    line number and follows the editor's monospaced font (at a smaller size) plus
    `secondaryLabelColor` for light/dark. A pure view concern, so it lives in
    `Pisaka`, not `PisakaCore`.
    It also hosts the git-blame **annotation column**, drawn to the *left* of the
    numbers inside the same ruler, in the same `drawHashMarksAndLabels` pass, with
    the same `rulerFont` and `NSColor.secondaryLabelColor`. State:
    the `[BlameLine?]` array for the *displayed* file, a `hash → label` **string**
    memo, an `isAnnotating` flag and a `canAnnotate` flag (set by
    `BlameController.sync` from the file's URL — false for an untitled buffer,
    which names no file to
    blame). `setAnnotations(_:)` places the array onto the buffer's line starts
    through Core's `BlameAlignment.aligned` (**not** by indexing it directly — see
    that entry: git numbers LF-delimited lines while the gutter also splits on a
    lone CR/NEL/LS/PS, and the naive indexing shifted every annotation past such a
    character onto the wrong line, permanently), rebuilds the memo, then calls
    `updateThickness()` + `needsDisplay`; `clearAnnotations()` drops both and hides
    the column (it is also the pre-buffer-swap call). That mapping is also what
    makes a **disk-shaped array safe to index by buffer line**: a worktree blame
    can be shorter or longer than what is displayed (`BlameController`'s accepted
    dirty-buffer inaccuracy), so it is bounded into an offset instead of a trap,
    and it establishes the `annotations.count == lineCount` invariant `BlameShift`
    then maintains. A label
    is `"<author> <short date>"` with the author capped at 20 characters and the
    date formatted **once per commit** from the ISO string (falling back to its
    leading `yyyy-MM-dd` when parsing fails); `nil` and uncommitted lines draw
    nothing, and git's `Not Committed Yet` is deliberately not memoized (it would
    widen the column for labels that are never drawn). **The column width is
    memoized against the font size it was measured at** (`annotationWidth:
    (fontSize, width)?`, dropped in `setAnnotations`/`clearAnnotations`), which is
    the one piece of state the memo deliberately does *not* hold: a label string is
    font-independent, its rendered width is not, and the shared editor font size
    changes at runtime (the Preferences Stepper, a code-zone zoom). Pairing the width with
    its size is what keeps a runtime font change correct without
    `editorFontChanged()` having to remember to invalidate anything — the next
    `updateThickness()` simply sees a different `pointSize` and re-measures. It is
    not a micro-optimization: `updateThickness()` is called from `lineMapDidChange`,
    i.e. on **every keystroke**, and the measurement is one
    `NSString.size(withAttributes:)` *per distinct commit*, so the uncached version
    put milliseconds on the typing path (a long-lived file has hundreds of distinct
    commits, not the "dozens" the first cut assumed) for a width that provably did
    not move — both of its inputs change only at the three choke points above. With
    annotate off the column contributes 0 and the gutter is
    byte-identical to before the feature. `lineMapDidChange` captures the previous
    line starts, computes the new ones as before, and — when annotations are present
    — feeds both plus `editedRange`/`changeInLength` through `BlameShift.updated`,
    so the column tracks the edit instead of sliding onto neighbouring lines.
    `menu(for:)` is overridden to return a one-item menu — "Annotate with Git Blame"
    / "Close Annotations" per `isAnnotating`, disabled when `canAnnotate` is false,
    which requires `menu.autoenablesItems = false` (AppKit otherwise re-derives
    enablement from the responder chain and overrides the explicit `isEnabled`) —
    firing an `onToggleAnnotate` closure that `CodeEditorView` wires to a **weakly**
    captured coordinator, the retain-cycle rule documented on
    `onDuplicate`/`onCancelSearch`. `isAnnotating` is raised **synchronously** by
    `beginAnnotating()`, which `BlameController.load` calls before the subprocess
    runs, rather than only when `setAnnotations` installs the array: annotate is on
    from the moment the user chooses it, the menu title is derived from this flag,
    and a load takes seconds on a large file — so without it the item would read
    "Annotate with Git Blame" for that whole window while choosing it took the
    already-enabled branch and turned annotate *off*. Nothing is drawn any earlier
    (the memo is still empty, so the column contributes no width and
    `drawAnnotation` finds no entry); only the reported state moves.
    The ruler also hosts a narrow fixed-width **diagnostic severity marker**
    column, drawn between the blame column and the numbers in the same
    `drawHashMarksAndLabels` pass. `setDiagnosticSeverities(_:)` takes
    `DiagnosticsModel.worstSeverityPerLine(url:lineCount:lineStarts:)`'s array
    wholesale and keeps the blame column's `count == lineCount` invariant at the
    setter — an array of any other length is **refused outright**, never padded or
    truncated into a lie about which lines are clean (the store already sizes the
    answer, so a mismatch means the geometry moved under the read, and the column
    already on screen is the better of the two wrong answers) — so the
    draw loop indexes it by line number with no bounds arithmetic of its own; an
    unchanged array is a no-op (this fires on every diagnostics-model mutation
    and every keystroke-driven repaint), and thickness is deliberately *not*
    touched because the column's width does not depend on its contents. That
    constancy is the entry's one trade, spelled out where it is decided:
    `diagnosticColumnWidth` contributes a **constant** cell plus gap for a given
    font size whether or not any diagnostic exists, because the alternative —
    width 0 while clean, like blame's — would make the whole editor text jump
    horizontally the moment a server first reports and again when it goes
    all-clear. Blame could stay conditional because *the user* turns it on and
    off; diagnostics arrive on their own schedule and must not move the page when
    they do. Both inputs derive from `rulerFont`, so markers scale with code zoom
    like the numbers beside them (`zoomSurfaceKind == .code` unchanged), and are
    re-measured by the same `editorFontChanged()` path. A line carrying the worst
    severity draws one dot in that severity's `SyntaxTheme` color; clean lines
    draw nothing. The same edit notification feeds Core's shift through the new
    `onEdit` closure — previous/post line-start tables, edited range and length
    delta, exactly `DiagnosticShift.updated`'s inputs, so the diagnostics channel
    never re-derives geometry this class already computed — captured **weakly**
    per the file's retain-cycle rule alongside `onToggleAnnotate`.
    **The fold chevron column** sits between the diagnostic markers and the
    numbers: `chevron.down` on the header line of every fold candidate,
    `chevron.right` on a folded one (louder — `labelColor` against the open one's
    `secondaryLabelColor` — because it is the only sign left in the gutter that a
    block is hidden), and nothing on any other line, the column being blank rather
    than absent. **Either set can put a chevron on a line**, not the candidate map
    alone: a tab switch restores the incoming file's folded state and publishes it
    with an empty candidate list, which the answer only fills a provider round trip
    later, so drawing from the candidates alone would leave a restored fold's text
    hidden with an empty gutter beside it — for up to the folding budget on a
    served file — which is the one thing this column exists not to do. The click
    guard reads both for the same reason: a chevron that is drawn must be
    clickable. Its width is derived from `rulerFont` and from nothing else, so it
    scales with code zoom like the numbers and the severity dots and needs no
    thickness recomputation when the fold sets change; the image is configured at
    draw time, so a zoom, a font change and a light/dark switch each need no
    bookkeeping at all, and a chevron (which is not square) is centered inside its
    square cell rather than stretched. **The ruler is *told* both sets and decides
    neither**: `setFoldRegions(_:folded:)` takes the candidates and the `FoldState`
    together — together, because a chevron's *direction* is decided by the two and a
    line's number is drawn or skipped by the folded set alone, so handing them over
    separately would let the ruler paint one frame in which a chevron points at a
    block the numbering does not believe in. It also builds the header-line →
    candidate map in `FoldRegion`'s own `Comparable` order, so a header line with one
    candidate — the only shape the fallback scanner ever offers, since it merges
    the rest — has exactly one entry.
    **The numbering skips hidden lines and keeps counting.** A line whose
    *preceding separator* is hidden draws nothing at all: it has no row of its own
    (its glyphs are null and that separator advances nothing, so it shares the
    header's fragment), and drawing it would stack a second number, a second blame
    label and a second severity dot on the header's row. The question is
    `FoldState.hiddenRange(collapsingLineStartingAt:)` and deliberately not
    `hides(offset:)` — see `core-folding.md` for why the two are different
    questions even though no producer currently makes the range that separates
    them.
    The **whole collapsed run is skipped in one step**, not a line at a time:
    hidden characters keep their glyphs, so `glyphRange(forBoundingRect:)` hands
    back a character range spanning every folded line, and stepping through them
    would make each redraw — every scroll tick, every keystroke — cost the folded
    block rather than the visible page. The resumed line's number is re-read from
    the cached line starts (O(log n)), so `12` is still followed by `27` — the
    honest answer about what the next *visible* line is — and the blame column and
    the diagnostic markers follow the numbers for free, because they are drawn from
    the same walk (`drawVisibleLine(_:…)`, lifted out of it so the skip reads as
    the one decision it is).
    `mouseDown(with:)` takes the text view's placeholder-click gate first —
    `clickCount == 1` and no modifier — so a modified click stays a selection
    gesture and a double click stays the stock ruler behavior, both falling through
    to `super`. The click-count half is what keeps a double click from folding on
    the first `mouseDown` and unfolding on the second, which reads as the chevron
    doing nothing at all. Past that it resolves a click inside the chevron column
    to **the region the chevron was drawn for** — `FoldState.folded(containing:)` first, the candidate map
    only when that answers nothing — and reports it through `onToggleFold` (weakly
    captured, like the other two closures). The order is load-bearing on a header line
    carrying more than one candidate, which a server can report (a block and a nested
    one opening on the same line) even though the scanner cannot: the chevron draws
    collapsed as soon as *any* of them is folded, ⌘⌥← deliberately folds the
    *innermost*, and the map holds the *longest* — so reading the map alone would fold
    the outer block on a chevron that is showing "collapsed" instead of opening what is
    folded. Asking what is folded first is the same question the draw asks, so the click
    undoes exactly what the chevron reports. The extent guard is the buffer's length and
    never `numberOfGlyphs`, which would force whole-document glyph generation on a gutter
    click; `glyphIndex(for:in:)` generates what it needs to answer and no more.
    Everything else falls through to `super`, so the blame context
    menu and every ruler behavior above it are untouched. Deciding *which* blocks are
    foldable and which are folded is `FoldRegionScanner`'s and `FoldState`'s
    (`core-folding.md`); all this view does is draw a chevron, skip a hidden line and
    name the region a click landed on.
  - `MinimapTokenizer.swift` — produces a `MinimapModel` (from `PisakaCore`) by
    parsing the *whole* text with SwiftTreeSitter into a per-UTF-16-unit
    `[SyntaxTokenKind]` (mapping each highlight capture through
    `SyntaxTokenKind(captureName:)`), then handing it to
    `MinimapModel.build(text:kinds:)` for the pure line/run grouping. This is the
    minimap's own parse, deliberately separate from Neon's visible-range styling.
    Re-parses are debounced (150ms) and skipped when the (file id, text hash,
    language) triple is unchanged; the heavy parse runs off the main actor with a
    generation token guarding against a stale background result. A cache hit also
    cancels any still-in-flight parse for a *different* key (and bumps the
    generation) so a slow background parse can't land its overview onto a file the
    user has since switched away from and back to. `nil` language ⇒ `.empty`
    (minimap draws nothing), mirroring the plain-text path. Color is *not* stored
    — resolved at draw time so the minimap follows the system appearance.
  - `MinimapView.swift` — `MinimapView: NSView` (`isFlipped == true`, so its y
    axis matches `MinimapGeometry`'s top-down convention with no conversion), and
    a **code** zoom surface for `LineNumberRulerView`'s reason: it is a sibling of
    the editor's scroll view inside `EditorContainerView`, so a gesture over the
    strip would otherwise target the interface zone even though what it is over is
    a rendering of the code at the code zone's size. Its own `scrollWheel`
    (below) is unaffected — the zoom monitor swallows modified scrolls before any
    view sees them, and passes unmodified ones straight through. Each
    document line gets a *fixed* row of height `minimapLineHeight` (`gap = rowHeight
    > 2 ? 1 : 0`, `barHeight = max(rowHeight - gap, 1)`); per line `y = line *
    rowHeight - minimapScrollTop + gap/2`, so the rendered content *slides* by the
    `minimapScrollTop` it derives from `geometry.minimapScrollTop(forScrollOffset:
    scrollOffset)` (the same source the viewport rectangle uses, so bars and rect
    never disagree). Only the visible slice is iterated: the first/last visible
    line are derived from `minimapScrollTop`/`bounds.height` up front (so a redraw
    near the bottom of a huge file stays O(visible rows), not O(lineCount)), with
    per-row guards (`continue` when `y + barHeight < 0`, `break` when
    `y > bounds.height`) as a backstop. Within
    a row it draws small colored rectangles (~1pt/char, clipped to the minimap
    width, `color.withAlphaComponent(0.6)`) for each non-whitespace run. Draws the
    semi-transparent viewport rectangle overlay from `viewportRect(forScrollOffset:)`
    (already panel-space). `mouseDown`/`mouseDragged` map the cursor y through
    `scrollOffset(forMinimapCenterY:)` and report the target
    offset via an `onScroll` callback (serving both click-to-jump and drag).
    `scrollWheel(with:)` maps the event's `scrollingDeltaY` (negated — wheel-up is
    positive, but the minimap is top-down so up must *decrease* the offset)
    through `geometry.scrollOffset(byMinimapDelta:from:)` to an absolute document
    offset and reports it via a separate `onScrollToOffset` callback. Colors
    are resolved through `SyntaxTheme.shared` at draw time, so it redraws correctly
    on light/dark appearance change and on resize.
  - `SyntaxLanguageConfiguration.swift` — registry mapping `SyntaxLanguage` →
    Neon `LanguageConfiguration` (grammar + bundled `highlights.scm` queries),
    lazily cached; returns `nil` on load failure. TypeScript composes the
    JavaScript highlight queries in as a base layer (the TS grammar's bundled
    `highlights.scm` carries only TS-specific captures), and
    `configuration(forInjectionName:)` resolves injected sub-languages including
    Markdown's `markdown_inline`. `.dockerfile`/`.dotenv`/`.gitignore` are three
    plain one-line branches (`LanguageConfiguration(tree_sitter_x(), name:
    "Dockerfile"/"Dotenv"/"Gitignore")`) with **no** sub-language injections and
    **no** explicit `bundleName:` — all three resource bundles come out as
    `TreeSitter<name>_TreeSitter<name>`, the default derivation, including the two
    *local* packages (verified against the built `Pisaka.app`), so the
    `markdown_inline` override stays the only one. `.go` is a fourth such branch
    (`LanguageConfiguration(tree_sitter_go(), name: "Go")`): upstream's package
    and target are both named `TreeSitterGo`, so its bundle is
    `TreeSitterGo_TreeSitterGo` — the default derivation `name:` already expects —
    and it needs no `bundleName:` either. Its `highlights.scm` is the one place a
    capture-name gap showed up: tree-sitter-go spells escape sequences `@escape`
    rather than `@string.escape`, which resolved to `.plain` until
    `SyntaxTokenKind.nameMap` gained the entry, so every `\n` in a Go string
    rendered default-colored. `.rust` is a fifth
    (`LanguageConfiguration(tree_sitter_rust(), name: "Rust")`), by the same
    derivation: upstream's package and target are both `TreeSitterRust`, so its
    bundle is `TreeSitterRust_TreeSitterRust` and it needs no `bundleName:`
    either. Its `highlights.scm` is the counter-case to Go's, and worth recording
    as one: all **21** of its capture names already resolve to a non-`.plain`
    kind, so `SyntaxTokenKind.nameMap` needed no entry at all — and one of the 21
    is `escape`, which resolves only *because* the Go work added
    `"escape": .string`. Without that earlier fix every `\n` in a Rust string
    would have rendered default-colored, so the reason this grammar needed no map
    change is itself a fact about the previous one. The 21 names are pinned by
    hand in `SyntaxTokenKindTests` (the dockerfile/Go precedent, since the query
    is not in this repository), asserting each expected kind, that none is
    `.plain`, and the count — so a table that loses a row fails rather than
    passing quietly. The dockerfile header declares
    a non-`const` `TSLanguage *` return with no `void` parameter list, which
    needed no cast — it imports as `OpaquePointer!` like every other grammar.
  - `SyntaxTheme.swift` — built-in (not user-configurable) `SyntaxTokenKind →
    NSColor` table with light/dark variants following the system appearance;
    exposes `nsColor(for:)` (a dynamic, appearance-aware `NSColor`, falling back
    to `.labelColor` for `.plain`/unmapped kinds) for the attribute provider. It
    also owns the bracket-highlighting palette, all through `PlatformColor
    .dynamic(light:dark:)` so the iOS variant (a follow-up) comes for free:
    `bracketDepthColors` (five cycling hues — gold, purple, blue, teal, green —
    each far enough from its neighbours to tell apart at a glance and from the
    punctuation gray brackets would otherwise take), `bracketColor(forDepth:)`
    (`depth % count`, a negative depth folding back into range rather than
    trapping — `BracketDepthScanner` reports an honest depth and the *view* cycles
    it), `unmatchedBracketColor` (red, deliberately not the `.string` red: an
    unmatched bracket is an error marker), and `matchedPairBackground` (opaque and
    neutral — every rainbow color must stay readable on it and it must not be
    mistaken for the selection highlight). Two more, in the same shape, back the
    editor's search bar: `searchMatchBackground` (a warm yellow behind every match
    but the current one — deliberately far from the blue-gray
    `matchedPairBackground` and from the accent-colored selection, so a match
    sitting on a bracket pair and a match inside the selection both stay
    recognizable as matches) and `currentSearchMatchBackground` (a saturated
    orange for the match ⌘G steps to — the same family, so it still reads as one
    of the matches, but unmistakably the highlighted one at a glance). On macOS a
    `nsBracketColor(forDepth:)` / `nsUnmatchedBracketColor` /
    `nsMatchedPairBackground` / `nsSearchMatchBackground` /
    `nsCurrentSearchMatchBackground` set mirrors
    `nsColor(for:)` for the temporary-attribute call sites. Being dynamic colors,
    a light/dark or forced-theme switch recolors the brackets and the search
    highlight at draw time for free.
    The diagnostics work adds four severity colors to the same table —
    `diagnosticError/warning/information/hint`, all through
    `PlatformColor.dynamic(light:dark:)`, with `diagnosticColor(for:)` and an
    `nsDiagnosticColor(for:)` accessor mirroring the bracket set's shape — because
    three surfaces (squiggle, gutter dot, panel icon) must draw one severity
    identically and Core stays color-free by rule. The values are chosen against
    the existing palette rather than picked: error is a rose-leaning red
    (`#C01C5A`/`#FF7B85`) deliberately distinct from both `unmatchedBracketColor`
    and the `.string` red, so a red string and a red squiggle are never confused;
    warning amber (`#A05E00`/`#E2B03C`) stays far from `searchMatchBackground`'s
    warm yellow, so a match sitting on a warning underline still reads as two
    separate marks; information (`#45718B`/`#79B8DA`) and hint
    (`#77808C`/`#6E7681`) are muted on purpose — present, legible, and
    unmistakably not complaints. Being dynamic like everything else in this file,
    they recolor at draw time on appearance change for free.
    The indentation-level work adds a **fifth palette in the same shape and one
    new form of the primitive**: `indentLevelColors` (four cycling hues — blue,
    purple, teal, gold — the bracket palette's own minus one, so the two nesting
    features never disagree about which hue means "one deeper"),
    `indentLevelColor(forLevel:)` (`level % count`, a negative level folding back
    rather than trapping, exactly as `bracketColor(forDepth:)` does, because
    `IndentLevelScanner` reports an honest level and the *view* cycles it), and
    the macOS `nsIndentLevelColor(forLevel:)` mirror. Four hues rather than five
    because this nesting is read one column beside the next, so a shorter cycle
    keeps adjacent levels further apart in hue. These entries are the one set
    **not** built through `PlatformColor.dynamic(light:dark:)` but through its new
    alpha-carrying form `dynamic(light:dark:alpha:)` at `levelBackgroundAlpha`,
    and the translucency is a constraint rather than a decoration: the blocks are
    painted *under* the glyphs, the selection, `matchedPairBackground` and both
    search backgrounds, so every one of those has to stay legible on top of a
    tint — which is a third clause on `matchedPairBackground`'s own opacity, now
    that it can sit over an indent block as well as beside one.
