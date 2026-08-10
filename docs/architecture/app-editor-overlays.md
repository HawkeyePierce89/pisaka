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
    1-based line numbers in the editor's gutter (TextKit 1). In
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
    changes at runtime (the Preferences Stepper, Cmd+scroll). Pairing the width with
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
    axis matches `MinimapGeometry`'s top-down convention with no conversion). Each
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
