# Pisaka app (macOS) — code editor & find/search views

Design documentation moved verbatim from the root `CLAUDE.md` (which now holds only a one-line-per-file index). Each entry records a file's contract, invariants and the reasoning behind non-obvious decisions — read the relevant entry before modifying that file, and update it when behavior changes.

  - `CodeEditorView.swift` — `NSViewRepresentable` wrapping `NSTextView` (built
    explicitly as TextKit 1 via `NSTextView(usingTextLayoutManager: false)` for
    Neon compatibility). Derives the active `SyntaxLanguage` from the file name,
    attaches a Neon `TextViewHighlighter` for the resolved
    `LanguageConfiguration`, and swaps/rebuilds it on tab (`fileID`) change. The
    highlighter is detached *before* a wholesale buffer swap so the outgoing
    grammar can't asynchronously repaint the incoming file (a stale
    cross-language race), then rebuilt for the new content. The attribute
    provider maps a tree-sitter capture name → `SyntaxTokenKind(captureName:)`
    (Core) → `SyntaxTheme` color; the configuration's `languageProvider` resolves
    injected sub-languages (Markdown's `markdown_inline`, fenced code blocks,
    embedded HTML/YAML) via `SyntaxLanguageConfiguration`. No detected language →
    plain text, no highlighter attached. Soft-wrapping is disabled (long lines
    scroll horizontally) so document space equals logical-line space, which keeps
    the logical-line-indexed minimap aligned with the document and viewport rect
    without forcing full TextKit layout. `makeNSView` returns a container holding
    the editor's `NSScrollView` plus a fixed-width `MinimapView` on the right; the
    scroll view also gets a `LineNumberRulerView` as its `verticalRulerView`
    (`hasVerticalRuler`/`rulersVisible = true`) for the line-number gutter, which
    reserves space inside the scroll view on its left and so does not affect the
    minimap's side-by-side layout.
    Editor → minimap: the clip view posts `boundsDidChangeNotification`; the
    flipped clip-view bounds origin is converted to the geometry's top-down
    convention and pushed as the minimap's `scrollOffset` (the view derives the
    content slide itself via `geometry.minimapScrollTop(forScrollOffset:)`).
    Minimap → editor: the minimap's `onScroll` callback maps the cursor y through
    `geometry.scrollOffset(forMinimapCenterY:)`, scrolls the
    clip view (back into AppKit coordinates), and the rect follows via the same
    bounds notification (closed loop). The minimap's `onScrollToOffset` callback
    (mouse-wheel path) reports an already-resolved absolute document offset, which
    the coordinator applies via the same `scrollEditor(to:)`. It owns the fixed
    `minimapLineHeight`
    (`= 3`) constant, feeds the `MinimapTokenizer` on edits/`fileID`/language
    change, and in `refreshGeometry` rebuilds `MinimapGeometry` from current
    document/viewport/minimap heights plus `contentHeight = lineCount *
    minimapLineHeight` on resize; observers are removed in `dismantleNSView` to
    avoid leaks across tab switches.
    Auto-indent is wired in the `Coordinator` via `PisakaCore.IndentEngine` (all
    indent math is pure and lives there; this is thin, untested view glue). On
    Enter, `textView(_:doCommandBySelector:)` intercepts `insertNewline:`, reads
    `textView.string` + the selected range, computes the `unit`
    (`IndentUnitRule.unit(config:inferred:)` over what the view's
    `editorConfig` model says about `fileURL` and what `inferIndentUnit` says
    about the buffer — the config's half wins, the inference fills the rest,
    `core-editorconfig.md`) and the edit (`newlineIndentation`), inserts it via
    `insertText(_:replacementRange:)`, moves the caret to `location +
    cursorOffset`, and returns `true` to suppress the default. On a closing
    bracket, `textView(_:shouldChangeTextIn:replacementString:)` detects a single
    `}`/`)`/`]` on a whitespace-only line prefix and, via `dedentOnClosing`,
    rewrites the leading-whitespace range and the bracket together in one
    `insertText(_:replacementRange:)` (one undoable edit), returning `false` to
    suppress the default insertion (mutating and returning `true` would proceed
    against a now-stale `affectedCharRange`).
    **Tab** is intercepted in the same `doCommandBy` switch
    (`#selector(NSResponder.insertTab(_:))`) and asks
    `IndentUnitRule.tabInsertion(config:inferred:)`, which is stricter than the
    unit rule: it answers a literal tab unless `.editorconfig` says
    `indent_style = space` outright. On that answer the handler returns
    **`false`**, so AppKit's own `insertTab` runs and the key behaves
    byte-for-byte as it did before the config layer existed — every insertion
    point, stock undo grouping, stock field-editor semantics. The completion popup
    wins ahead of all of this: `keyDown` routes Tab through `onCompletionKey` and
    returns *before* `super.keyDown`, so with the popup open Tab commits the
    selected row and never reaches `doCommandBy` at all. The stricter question —
    `indentStyle == .space` — is also asked **before the buffer is touched**:
    `textView.string` bridges a mutable `NSTextStorage` and so copies the whole
    buffer, and `IndentEngine.inferIndentUnit` then walks every line of that copy,
    which is the same per-keystroke main-thread cost `textDidChange` reads the
    buffer once to avoid — and in the no-configuration case the stricter rule
    throws the result away. On the spaces
    answer it fans out: *all* of `textView.selectedRanges` (not just
    `selectedRange()` — the middle-drag column selection makes several
    zero-width carets a first-class state, and replacing only one would silently
    collapse the selection) go through `IndentUnitRule.tabInsertionPlan`, whose
    sorted, non-overlapping replacements are applied **back-to-front** — later
    ranges first, so earlier offsets stay valid — inside one
    `shouldChangeText(inRanges:replacementStrings:)` /
    `textStorage.beginEditing()` … `endEditing()` / `didChangeText()` bracket
    (one undoable step, one change notification), followed by `setSelectedRanges`
    with the plan's carets. A `shouldChangeText` **refusal** returns `false`, not
    `true` — a refused edit is not a handled key, and eating it would leave Tab
    doing nothing at all — and the spaces are written as an `NSAttributedString`
    carrying `textView.typingAttributes`, since the raw storage path this fan-out
    needs would otherwise inherit the adjacent text's attributes (and, with no
    adjacent text, no font at all) where every other programmatic edit here gets
    them for free from `insertText(_:replacementRange:)`. That same raw-storage
    path is why the handler **bails on `hasMarkedText()`** before it asks
    anything: `insertText(_:replacementRange:)` commits or discards an in-flight
    IME composition and tells the input context about it, while
    `replaceCharacters` moves the composition's characters out from under a
    `markedRange` that is left pointing at them — so the next composition update
    writes at an offset that no longer describes anything. Returning `false`
    hands the key to AppKit's own `insertTab`, which is what Tab did before the
    feature existed; it is the guard `handleCompletionKey` already takes, for the
    same reason.
    The existing `isApplyingProgrammaticEdit` guard wraps
    the *whole* bracket rather than just the storage mutation, because the
    single-range case reaches the single-range delegate callback where the
    auto-pair interceptor acts on one-character insertions. `insertBacktab` is
    untouched. The config itself arrives as `var editorConfig:
    EditorConfigModel` — a plain, **undefaulted** property beside `symbolIndex`
    (a default would be a second live disk reader built for a view nobody
    constructs), owned by `PisakaApp`, deliberately *not* observed because it
    publishes nothing, and held **weakly** by the coordinator like `symbolIndex`:
    a deallocated one answers empty properties, which is exactly the "no
    configuration applies" case, so the editor degrades to the content inference
    rather than misbehaving. Enter and Tab both read it through one private
    helper, so they can never disagree about the unit — they differ only in
    *whether* it is used. Enter reads a **second** private helper of its own,
    `newlineTerminator()` (`endOfLine?.terminator ?? "\n"`), the terminator it
    splices: `end_of_line` is consumed in full, so a newly typed terminator and a
    normalized one can never disagree, and a project stating no `end_of_line`
    splices LF byte for byte as before (`core-editorconfig.md`). The iOS
    coordinator holds the identical pair.
    A third app-owned model arrives here for saves: `var saveTransform:
    SaveTransformController?`. Unlike `editorConfig` it is **optional and
    defaulted** — `nil` in previews and tests transforms nothing — and equally
    not observed. The view only *attaches* it (`makeNSView`), handing over the
    text view and the coordinator so a rewrite of the shown buffer can go through
    the live view instead of behind it; with more than one window open the last
    editor built wins, and a buffer shown in the other window is rewritten through
    the model instead. The `Coordinator` conforms to `SaveTransformEditor` for
    that: `displayedFileID` (read, never cached — the tab-switch autosave fires
    from `$selectedID` *before* `updateNSView` swaps the buffer, so it still names
    the outgoing file, which is exactly the one being saved), `scrollAnchorOffset`
    / `scrollAnchor(to:)`, and the three-step bracket
    `beginSaveTransformRewrite()` → `resetIncrementalReadersForSaveTransform()` →
    `endSaveTransformRewrite()`. The split is load-bearing: the two guards go up
    first because `shouldChangeText` re-invokes the auto-pair interceptor
    synchronously, while the blame column and this document's diagnostics are
    dropped only once that call has *permitted* the edit — `endEditing` coalesces
    the small replacements into one edited range that can be the whole file, so
    both readers take the buffer-swap treatment rather than the incremental
    shift, but discarding them for a rewrite that never happened would leave the
    gutter and the underlines empty with no change notification to re-publish
    them. `invalidateDiagnosticPaint()` is deliberately **not** called, unlike on
    a real buffer swap: no `textView.string` assignment happened, so the temporary
    attributes over the untouched text are still there and forgetting the cache
    would make the clearing repaint a no-op. All programmatic edits go through
    `insertText(_:replacementRange:)` so the per-file undo manager records them as
    ordinary single-step-undoable edits. The one edit that *cannot* go through it
    is `updateNSView`'s wholesale `textView.string = text` swap, which is why that
    branch clears the file's undo stack (`textView.undoManager?.removeAllActions()`)
    whenever the contents were replaced **without** a tab switch — a project-wide
    Replace All landing in an open tab (`ProjectSearchModel.replaceAll` →
    `applyBufferText` → `WorkspaceModel.replaceText`), a post-revert
    `reloadFromDisk`, a merge apply, or an on-save transform applied to a buffer no
    editor holds (`SaveTransformController`'s off-screen path — the fallback the
    funnel takes when the file is not the displayed one, `core-editorconfig.md`).
    Assigning `string` registers no undo action
    of its own, yet every action already recorded names a range in the *pre-swap*
    text, so a following ⌘Z would replay an unrelated older edit at coordinates the
    new contents no longer share: silently corrupting the buffer when the range
    still fits, and raising an out-of-range exception from the text storage when
    the new text is shorter. A *tab switch* is deliberately excluded — there the
    incoming file's own manager is installed alongside its own contents, the very
    pairing the per-file managers exist to preserve — **unless that file's buffer
    was replaced while it sat off screen**, which is not a corner case but the
    ordinary shape of every replacement above: each reaches an open tab that is not
    the displayed one — the first three reach *every* matching tab, the save
    transform reaches whichever one is being written — and a background tab gets no
    `updateNSView` of its own, so by the time the user selects it the swap is
    indistinguishable from a plain tab switch and the `!switchedFile` test alone
    would let the stale stack survive (⌘Z on a Replace All'd background tab then
    corrupts it, or traps when the replacement shortened the file). The
    discriminator is Core's per-file `WorkspaceModel.textReplacementRevisions`
    token, bumped by `replaceText(_:for:)`/`reloadFromDisk(id:)` and **not** by the
    typing path `updateText(_:for:)`: `ContentView` passes the selected file's
    value in as `externalTextRevision`, and the coordinator's
    `noteExternalTextRevision(_:for:)` compares it against what it last saw for
    that same `fileID` (a first display records without reporting a change — there
    is no stack to drop yet), so the clear is keyed to the *file* rather than to
    whichever view happened to be on screen when the replacement landed. Because
    `insertText` re-invokes
    `shouldChangeTextIn` synchronously, both interceptors set an
    `isApplyingProgrammaticEdit` re-entry flag around the programmatic
    `insertText` and bail (return `true`, letting the edit through) while it is
    set — otherwise a dedent whose replacement is a no-op (a closing bracket at
    column 0 under an *unindented* opener yields a zero-length range and empty
    replacement, so the re-entrant call re-passes the guard) would recurse until
    the stack overflows.
    Auto-close brackets/quotes is wired in the same `Coordinator` via
    `PisakaCore.AutoPairEngine` (again pure-engine + thin view glue). In
    `textView(_:shouldChangeTextIn:replacementString:)` a single-character
    `replacementString` is first run through `AutoPairEngine.action(text:
    selectedRange: affectedCharRange, typed:)` (after the
    `isApplyingProgrammaticEdit` bail): `.wrap` replaces the selection with
    `open + selection + close` and selects the wrapped inner range; `.insertPair`
    inserts `typed + close` and drops the caret between them; `.typeOver` steps
    the caret one past the existing closer without inserting; `.passthrough` lets
    the keystroke proceed — except a single closing bracket falls through to the
    existing `dedentOnClosing` path (so auto-pair `.typeOver` is checked *before*
    the dedent for a closer, and only `.passthrough` reaches the dedent). Each
    auto-pair edit goes through one `insertText(_:replacementRange:)` bracketed by
    the shared `isApplyingProgrammaticEdit` flag (one undo step; the flag, renamed
    from `isApplyingIndentEdit`, now gates *both* the indent and auto-pair
    programmatic edits). In `textView(_:doCommandBy:)`, `deleteBackward(_:)` is
    intercepted: on an empty selection where `AutoPairEngine.shouldDeletePair(
    text:location:)` is true, the two-character empty pair is deleted in one
    guarded `insertText("", replacementRange:)` (`return true`); otherwise
    `return false` for the default delete (the `insertNewline(_:)` interception is
    unchanged).
    Column selection via middle-mouse drag follows the pure-engine + thin-glue
    split, via `PisakaCore.ColumnSelectionEngine` and three `EditorTextView` overrides:
    `otherMouseDown`/`otherMouseDragged`/`otherMouseUp` over a stored anchor point.
    Because `NSTextView` ignores `otherMouseDown`, no modal tracking loop is needed —
    AppKit delivers the drag/up events natively. Dragging past the view edges calls
    `autoscroll(with:)`, which does not disturb the view-coordinate anchor; dragging
    past `Self.clickSlop` (2 pt) starts a live selection via `setSelectedRanges`
    with `stillSelecting: true` (which AppKit requires for a drag in progress), and
    the release finalizes it with `stillSelecting: false`. A middle click without
    meaningful movement collapses to a single caret at the anchor (via
    `characterIndexForInsertion(at:)`) and focuses the editor if unfocused.
    The probe rect handed to `glyphRange(forBoundingRect:in:)` is widened to the
    container and inflated out of degeneracy (at least 1 pt each dimension) —
    load-bearing, because a purely horizontal single-line drag has zero height
    and a purely vertical drag zero width, and a degenerate rect can enumerate
    no fragments at all, silently freezing the selection behind the non-empty
    guard; the left/right edge offsets are still probed from the *un-inflated*
    bounds, so the inflation never widens the selected columns.
    The native Option-drag and ⌘⌥-drag rectangular selections, plain click/drag
    selection, and the ⌘-click go-to-definition gesture are untouched.
    Duplicate line/selection (Cmd+D) follows the same pure-engine + thin-glue
    split, via `PisakaCore.DuplicateEngine`. The `EditorTextView` subclass carries
    an `onDuplicate: ((NSTextView) -> Bool)?` callback (an optional closure the
    representable installs, wired in `makeNSView` to the coordinator's
    `duplicateSelection(in:)`, captured **weakly** — see the retain-cycle note
    below) and overrides `performKeyEquivalent(with:)`, firing
    only on a *clean* Cmd+D: `charactersIgnoringModifiers?.lowercased() == "d"`
    **and** `modifierFlags.intersection([.command, .shift, .option, .control]) ==
    [.command]`, so Cmd+Shift+D and other combinations fall through to `super`
    rather than being swallowed. It additionally requires the view to be
    `isEditable` and its window's `firstResponder`, because
    `performKeyEquivalent` is dispatched down the *whole* window's view tree
    rather than to the focused view alone — without that check Cmd+D would
    duplicate into the editor while the user is typing in the embedded terminal or
    the project tree — **and** requires `!hasMarkedText()`, because a key
    equivalent is dispatched by `NSWindow` *before* `keyDown:`/the input context
    (unlike the `doCommandBy:`/`shouldChangeTextIn:` interceptors, which run only
    after it), so it can fire mid-IME-composition: marked text lives in the text
    storage, so the duplication would copy the *uncommitted* composition as
    ordinary text and leave the marked range pointing at a region the insertion
    moved. All four conditions are load-bearing; dropping any one reintroduces a
    concrete misfire. `Coordinator.duplicateSelection(in:)` reads the live
    `textView.string`/`selectedRange()`, calls `DuplicateEngine.duplicate`, applies
    the result with a single `insertText(edit.text, replacementRange: NSRange(
    location: edit.insertionLocation, length: 0))` (a zero-length replacement, so
    the per-file undo manager records the whole duplication as *one* undoable
    step), then installs `edit.selectedRange`. It is bracketed by the shared
    `isApplyingProgrammaticEdit` flag for the same mandatory reason as the indent
    and auto-pair edits: `insertText` re-invokes `shouldChangeTextIn`
    synchronously and the auto-pair interceptor fires on any single-character
    replacement, so duplicating a one-character *selection* holding a lone `(`
    would otherwise fall into auto-pair and insert `()`. The line path can emit a
    single character too — duplicating an *empty* line inserts just `"\n"` — so
    the guard covers both paths unconditionally. The closure `makeNSView` installs into
    `onDuplicate` captures the coordinator **weakly**: the coordinator holds the
    text view weakly, but Neon's `TextViewHighlighter` — which the coordinator owns
    strongly — keeps a strong `textView`, so a strong capture would close the cycle
    coordinator → highlighter → text view → closure → coordinator and leak the
    editor, its text storage and its per-file undo managers on every teardown.
    `DiffView`'s read-only panes and
    `MergeView`'s panes — including its *editable* result pane (`MergePaneTextView`,
    `isEditable = true`), so "untouched" here means "does not use `EditorTextView`",
    not "is read-only" — are deliberately untouched.
    Shared font size, and the code zoom surface: `CodeEditorView` takes a
    `fontSize: Double` (threaded from `settings` via `ContentView`); `makeNSView`
    sets the text view's `font` to `.monospacedSystemFont(ofSize:weight:.regular)`
    at that size, and `updateNSView` re-applies it when `fontSize` changes (tracked
    by the coordinator's `appliedFontSize`), then re-derives the gutter (the
    `LineNumberRulerView` reads `textView.font?.pointSize`, so a redraw +
    `ruleThickness` recompute) and `refreshGeometry` (so the line-height-dependent
    minimap geometry and viewport rect stay correct). There is **no
    `onStepFontSize` callback and no `scrollWheel(with:)` override** any more:
    `CodeFontScroll.swift` and the four overrides that used it are gone, replaced
    by the app's one `NSEvent` monitor (`ZoomController`), which had to own the
    gesture because per-view overrides could never reach the terminal or the
    chrome — the two zones the feature added. What the editor contributes instead
    is a *declaration*: `EditorTextView: ZoomSurfaceProviding` with
    `zoomSurfaceKind = .code`, so the pointer walk can find it. So do
    `LineNumberRulerView` and `MinimapView`, which draw beside the text view rather
    than inside it (a ruler is the scroll view's `verticalRulerView`, the minimap a
    sibling of the scroll view) and would otherwise produce no candidate at all,
    sending a gesture over the gutter or the minimap to the interface zone. The
    whole rule is in `docs/architecture/core-zoom.md`. `DiffView`/`MergeView` take
    the same `fontSize` and apply it uniformly across their panes (so rows stay
    aligned).
    Completion on/off (T-4) follows that same shape exactly: `completionEnabled:
    Bool` is a **plain value**, undefaulted like `fontSize` beside it, threaded
    from `settings.completionEnabled` by
    `ContentView` — which already observes the store — and *not* a second
    observed object. The undefaulting is deliberate and is the one place this
    differs from the optional/no-op conveniences around it: the only possible
    default is `true`, so a second editor host added later would compile clean and
    offer completions to a user who turned them off — a silent regression of the
    whole feature that nothing in the repo can catch, since `swift test` compiles
    Core alone and the view layer is untested by convention. Requiring the
    argument makes it a compile error instead.
    Indentation-level highlighting travels that identical route — a second plain,
    undefaulted `indentLevelHighlightingEnabled: Bool`, for the same
    compile-error-instead-of-silent-default reason — and the coordinator is its
    only reader: the layout manager is *told* (`app-editor-overlays.md` carries the
    painting and freshness rules). Two orderings inside this file are load-bearing
    and are stated at both call sites. The apply must run **after** `editorConfig`
    is bound, because it is what derives the widths and must be able to ask
    `.editorconfig` rather than fall back to the content inference for one update;
    and in `updateNSView` it must additionally run **after** `syncBlame`, which is
    what records `fileURL` — the URL `.editorconfig` is resolved against.
    `updateBrackets`' immediate rescan on a tab switch has by then already
    recomputed once, against the file being *left*, so the widths cache keys on the
    URL it used as well as on the configuration revision and the text; the apply
    here is what notices and derives again inside the same update. Without the URL
    in that key nothing else would move for a buffer that is only read, and the
    outgoing file's unit would be re-asserted for the rest of the session.
    The store is observed once, where the view is built, and the
    flag travels with the update that observation already causes; making this
    view observe anything itself would add a per-keystroke re-render path to the
    one view in the app that must not have one. It is applied in `makeNSView`
    (beside `attachCompletion`, so an editor built while the preference is
    already off never asks the provider even once) and re-applied
    unconditionally near the top of `updateNSView`, before the buffer/blame/index
    reconciliation — the controller ignores an unchanged value, and a *change* to
    `false` cancels what is pending and dismisses a live popup, which should
    happen before the rest of the update runs. The coordinator's
    `setCompletionEnabled(_:)` is a thin forwarder rather than a stored flag:
    `CompletionController` owns the state and is the only thing that can act on a
    change.
    Bracket highlighting (both mechanics — the caret's matched pair and the
    rainbow by depth) is wired in the same `Coordinator`, again pure-engine +
    thin view glue: `makeNSView` installs a `BracketOverlayLayoutManager` on the
    freshly created `EditorTextView` with `textView.textContainer?
    .replaceLayoutManager(_:)` — the documented API for exactly this job, which
    moves the container (and through it the storage and the text view) onto the
    new manager and preserves the whole storage↔container↔view graph, so **not one
    other line of `makeNSView` changes** (in particular `allowsNonContiguousLayout`
    is set through `textView.layoutManager` *after* the swap, so it lands on the
    new manager — keep that ordering when editing; a debug `assert` pins the
    install). A hand-built TextKit 1 stack was the fallback and was *not* needed;
    it would have required the `Coordinator` to hold the `NSTextStorage` strongly,
    since `NSTextView` does not retain its storage (ownership runs storage →
    layoutManager → textContainer → textView, the other way). Everything
    downstream resolves the layout manager dynamically rather than caching it —
    the gutter reads `textView.layoutManager` per draw and Neon's
    `LayoutManagerSystemInterface` resolves it at write time — so both find the
    subclass. The coordinator owns a `BracketHighlightController` and four
    triggers: the *text storage's* `didProcessEditingNotification` filtered on
    `.editedCharacters` (the `LineNumberRulerView` precedent — it carries the
    edited range, covers programmatic edits, and being a notification coexists
    with Neon owning the storage `delegate`; attribute-only edits are ignored so
    Neon's styling and the overlays can't drive each other in a loop) →
    `noteEdit(in:)` + a debounced rescan; `textViewDidChangeSelection(_:)` →
    `updateSelection` (no rescan — the buffer is unchanged); the existing
    `clipViewBoundsChanged` *and* `syncableFrameChanged` → `refreshVisible()` (no
    rescan; the frame path is also what paints the first time, since no layout
    exists when `makeNSView` seeds the scan); and `updateNSView` → an `immediate`
    update on a `fileID` change / buffer swap (waiting out the debounce there
    would leave the previous file's colors on screen). `teardown()` removes the
    observer and resets the controller (cancelling any pending scan).
    Unlike Neon's styling, the overlays are **language-independent**: the
    controller is driven from `makeNSView`/`updateNSView`/the edit observer with no
    `SyntaxLanguage` involved, so an `Untitled` buffer or an unknown extension still
    gets rainbow brackets and pair highlighting. That also means the plain-text
    branch's full-range `setTemporaryAttributes([:], …)` clear (which exists to wipe
    a previous highlighter's colors) no longer clears *everything* — it routes
    through the override, so `super` clears and the overlays are re-merged on top,
    which is the intended outcome. `DiffView`/`MergeView` are deliberately untouched
    — they keep the plain `NSLayoutManager`.
    The find bar is wired through the same pure-engine + thin-glue split: the view
    takes `@ObservedObject search: EditorSearchState` and `reveal:
    EditorRevealState` (both window-scoped and owned by `PisakaApp`, both defaulted
    so previews compile), `makeNSView` attaches the coordinator's
    `EditorSearchController` and registers it as the state's executor,
    `updateNSView` re-runs the search — *forced* on a tab switch / wholesale buffer
    swap, since the pattern is unchanged but its matches are not, and otherwise a
    no-op through the controller's applied-query comparison — and `teardown()`
    resets the controller and unregisters it. Edits re-run the search through the
    existing `bracketTextStorageDidProcessEditing` observer (after `noteEdit`, which
    already cleared the backgrounds), via the controller's `setNeedsRefresh()`.
    `EditorTextView` gains `onCancelSearch: (() -> Bool)?` and overrides
    `cancelOperation(_:)` so Esc in the editor closes an open bar (captured
    **weakly**, like `onDuplicate`, for the same retain-cycle reason), and the
    auto-pair interceptor additionally checks `searchController.isApplyingEdit`
    alongside its own `isApplyingProgrammaticEdit` — a replacement whose text is a
    single `(` would otherwise be auto-closed into `()`. `applyReveal(_:fileID:)`
    consumes a pending Find in Files activation, deliberately **after** the buffer
    swap in `updateNSView`: when the activation *opened* the file, that same update
    is the one installing its contents, so selecting earlier would land the range in
    the previous tab's text. It is one-shot by `token` (not by value — activating the
    same match twice is a legitimate second request), ignores a request whose
    `fileID` is not this tab's, and clamps the range to the live buffer — by
    **truncating the length**, not by intersecting: a range whose location is
    exactly the buffer end shares no unit with the document, and
    `NSIntersectionRange` answers `{0, 0}` for that, which would scroll to the top
    of the file instead of leaving the caret at the end.
    The gutter's git-blame column is wired through two more inputs — `fileURL:
    URL?` (what `BlameController` blames; a `nil` untitled buffer disables the
    context-menu item) and `diskRevision: Int = 0`
    (`WorkspaceModel.diskRevision(for:)`, whose change means the on-disk content
    this buffer stands for moved — one of the reload triggers, alongside a tab
    switch, a buffer replacement and a *path* change; see `BlameController`, whose
    third documented inaccuracy is the repository changing under an unmoved file),
    both defaulted so a default-constructed view still compiles and both threaded
    from `ContentView.editorZone` as `file.url` / `model.diskRevision(for: file.id)`
    with the existing parameter order untouched. `makeNSView` attaches the
    coordinator's `BlameController` to the ruler and wires `ruler.onToggleAnnotate`
    to it through a **weakly** captured coordinator (the `onDuplicate`/
    `onCancelSearch` retain-cycle rule), then records the displayed file with one
    `syncBlame` — nothing loads there, since annotate starts off for every tab and
    is only turned on from the context menu. `updateNSView` calls
    `beginBufferSwap()` **before** `textView.string = text` on a content
    replacement — that assignment posts a single full-range edit notification the
    ruler would otherwise run `BlameShift` over, shifting annotations across a
    whole-document replacement — and `syncBlame(...)` *after* the swap, so the array
    is sized against the line count the swap's notification has just rebuilt.
    `teardown()` calls `reset()`.
    **Code intelligence** is wired here too, through two more inputs — a
    `SymbolIndexController` (not observed: it publishes nothing, and the index model
    behind it republishes after every chunk of a walk, which must stay off this
    view's update path) and `onGoToDefinition`, bound to the very
    `PisakaApp.activateSearchMatch(url:range:)` a Find in Files result goes through,
    so opening the tab stays the app's job and a definition in the *current* file
    takes the same route (one code path for the caret move and the scroll). Both are
    defaulted so a default-constructed view still compiles, and
    `navigateToDefinition` is re-assigned on **every** update, because it captures
    the scene's state and a stale one would open tabs through a torn-down
    workspace. `makeNSView` binds three new `EditorTextView` closures — a ⌘-click's
    `onGoToDefinition`, the completion request's `onRequestCompletions`, and
    `onCompletionInsertion` — all with the same **weak** coordinator capture the
    `onDuplicate`/`onCancelSearch` rule requires, and attaches the coordinator's
    `CompletionController` to the text view (nothing is computed there: candidates
    are asked for on the first keystroke or an explicit ⌃Space, never for a tab that
    was only looked at). The shown file is re-indexed from its **buffer** text
    immediately in `makeNSView` and on a `switchedFile`/`contentReplaced` update —
    the tab being looked at must have symbols before the user finishes reading it,
    and the disk walk may not have reached that file (or may never reach one outside
    the opened folder) — while `textDidChange` goes through the controller's 400 ms
    debounce; scheduling *both* on a switch would re-parse the file twice per
    settled burst of typing. `textDidChange` also refreshes the completion
    candidates behind their own shorter debounce, whose gates (bare caret, no marked
    text, and either two typed characters *or* a member position — see
    `CompletionController`) mean an ordinary keystroke outside an identifier
    costs one prefix scan and no task — but **not while
    `isApplyingProgrammaticEdit` is up**. AppKit's own completion insertion fires
    this notification synchronously (once per arrow-key preview as well as for the
    accepted word), so refreshing there would schedule a request for the word just
    completed and re-open the popup over it a debounce later; the iOS strip avoids
    the same treadmill by clearing after an insertion. Auto-pair, the indented
    newline and ⌘D take the same path and are equally not typing.
    `updateCompletions` passes the highlighter's own `language` (the one
    `updateHighlighter` owns), so the keywords offered are always the ones being
    highlighted and a plain-text buffer passes `nil` and gets none. The snapshot the
    guard leaves standing is inert: `completions(forPartialWordRange:in:)`
    re-validates it against the live buffer, and a popup only ever opens from
    `apply` or ⌃Space. The coordinator's `goToDefinition(in:at:)` is
    the **single** entry point behind both ⌘-click and ⌃⌘J, so the two cannot
    disagree about what an identifier is or how a jump is made: `IdentifierScanner`
    names the word, the provider (re-read from the controller per call, never
    stored, so no answer comes from the state a folder was opened in) ranks the
    candidates, and the count picks the surface — beep, jump, or `DefinitionPicker`
    anchored on the asked-about range. **The buffer travels with the question**
    (phase 2a's D2): the request is built with `text: textView.string`, because an
    LSP provider has to tell the server the current text before it can ask about an
    offset in it, and this is the one macOS path that reaches one. Leaving the
    defaulted field to default here would not fail to compile — it would quietly ask
    about offset *N* in an empty document, which is why the LSP provider treats
    "empty text, non-zero offset" as unanswerable rather than clamping. **The
    folder is pinned too**, as `symbolIndex.currentRootGeneration` captured
    synchronously before the `Task` and re-checked when the candidates come back —
    the generation-token rule applied where an answer is *read* rather than where it
    is computed. Both providers already refuse to answer for a folder the user has
    left (the index is cleared by `prepareForFolderChange`; the LSP workspace's
    `stillHolds(_:)` drops a response whose root no longer matches), but neither
    gate reaches past its own `return`: the candidates cross one more main-actor hop
    to get here, ⌘⇧O registers a switch in a single synchronous turn, and a switch
    landing inside that hop would leave this task opening a file from the previous
    project — the one outcome all of those gates exist to prevent. Superseded means
    *silence*, not a beep: the user asked for a different folder, and a warning sound
    for an answer they are no longer waiting on is noise. Where a
    chosen candidate *lands* is the coordinator's `navigate(to:)`, and the fork is
    the candidate's own `isOutsideProjectRoot` — the provider knows the project
    root, this view does not: an in-root target goes through today's
    `navigateToDefinition`, an out-of-root one through
    `viewDefinitionOutsideProject` to the read-only source viewer window (D3, see
    `app-window.md`). It is one place precisely so the single-candidate jump and the
    picker's choice cannot disagree, and every tree-sitter candidate takes the first
    branch, since the index only ever walks the opened folder. `CodeEditorView`
    exposes the second destination as its own `onViewDefinitionOutsideProject`
    closure rather than as a flag on `onGoToDefinition`, because the two are
    different app-level operations — one opens a tab through `WorkspaceModel`, the
    other opens a window that has no model behind it at all. The completions
    delegate
    (`textView(_:completions:forPartialWordRange:indexOfSelectedItem:)`) serves the
    controller's snapshot, **ignoring AppKit's `words`** (the spell checker's
    guesses: this is a code editor, and dictionary words beside project symbols
    would bury the latter) and forcing `indexOfSelectedItem` to `-1`. That last one
    is **mandatory, not cosmetic**: AppKit's stock `0` does not merely highlight a
    row, it makes `complete(_:)` call `insertCompletion(…, isFinal: false)` for it,
    so the popup *writes its top candidate into the buffer* before the user chooses
    anything — once per 150 ms typing pause, each time pushed into `WorkspaceModel`
    by `textDidChange` (dirtying the tab, so an idle autosave can write it to the
    file) and each time registering its own undo step. `-1` opens the same popup
    with nothing selected and nothing inserted; arrow keys or the mouse choose and
    Return inserts, which is the contract README states. `noteCompletionInsertion`
    raising `isApplyingProgrammaticEdit` around AppKit's insertion is **mandatory,
    not defensive**: the insertion goes through the same edit path typing does, so a
    completion ending in `(` would otherwise be auto-closed by `AutoPairEngine` and
    one whose replaced range starts a line could trip the dedent rewrite.
    `teardown()` additionally calls `completion.reset()`, so a torn-down tab can
    neither serve a closed file's identifiers nor open a popup over the tab that
    replaced it — and `updateNSView` calls the same thing through
    `clearCompletions()` on `switchedFile || contentReplaced`, because a tab
    *switch* reuses this view rather than tearing it down. The snapshot is matched
    only against the text of the partial word it answers, so without that the
    stock completion bindings (⌥⎋, F5) on the same word in the incoming file would
    be served the outgoing file's list — ranked with the wrong file as "current",
    so the declarations actually on screen are missing or demoted. The iOS editor
    clears its strip on the identical condition. On `EditorTextView` itself:
    `keyDown(with:)` claims a *clean* ⌃Space (no ⌘/⇧/⌥, editable, no marked text)
    and routes it to `completeAtCaret()`. That binding lives here rather than on the
    Find menu item — the only shortcut in the app that does — because a menu key
    equivalent is claimed **app-wide** and is offered the keystroke before the key
    window's first responder, and ⌃Space is the one shortcut the app wants that
    carries no ⌘: as a menu binding it swallowed ⌃Space out of a focused embedded
    terminal, which needs it as NUL (readline's and Emacs' `set-mark`), beeping
    instead once `completeAtCaret()`'s first-responder cast failed — and only once a
    tab was open, since a disabled item does not claim its equivalent. It bails on
    marked text for the same reason ⌘D does. `rangeForUserCompletion` is overridden
    to return Core's completion-prefix range (AppKit's stock implementation walks
    back over a broader word class and reporting the whole dotted expression is the
    classic reason a popup offers nothing; a non-empty selection is left to `super`);
    `insertCompletion(_:forPartialWordRange:movement:isFinal:)` brackets `super`
    with the flag, which is what keeps undo AppKit's — one ordinary step on the
    active per-file undo manager — and lowers it in a `defer` so an exception cannot
    leave the interceptors disabled for the session. Its **one addition** is
    `onInsertCompletion`, asked first: an LSP item may carry edits of its own — the
    `import` line that makes the symbol resolve, or a replacement range the server
    chose rather than the one the client typed (D4) — and those have to be applied
    *as written*, which `super` cannot do because it only knows the word. It answers
    `false` for every tree-sitter item, for most LSP ones, and for every preview of a
    highlighted row, so the stock path stays the path;
    `goToDefinitionAtCaret()` uses
    the selection's **start**, so the command behaves the same whether the user
    placed a caret in a name or double-clicked it — and `findUsagesAtCaret()`
    (⌃⌘U) and `renameAtCaret()` (⌃⌘R) are its two siblings, resolved the same way
    and reached the same way, as the key window's first responder; and `mouseDown(with:)` claims
    only a plain, single Command-click. **Command-*drag* must still select**, and
    AppKit gives no way to learn that from the mouse-down alone (`super.mouseDown`
    runs its own modal tracking loop until the button comes up, so a `mouseUp`
    override is never reached during a drag-select), so the following events are
    peeked at: a mouse-up within a small slop radius is the click, while the first
    real movement hands the *original* event back to `super`, whose tracking loop
    anchors on it and picks the drag up from the current position. ⌘⇧-click
    (extend) and ⌘⌥-click (rectangular) stay AppKit's. **The claimed click still
    behaves like a click**: `super.mouseDown` cannot be called on the resolve path
    — its tracking loop would block on a mouse-up already taken off the queue — so
    the two things it would have done are done by hand instead, the view taking
    first responder and the caret moving to the clicked offset. Without them a
    ⌘-click that resolves nothing (whitespace, punctuation, a keyword — the
    coordinator just beeps) is swallowed whole and the click has no effect at all,
    and a ⌘-click into an editor that is not yet focused jumps without ever
    focusing it.
    **The three code-intelligence commands also live on a context menu, and the
    click is the whole reason they do.** `menu(for:)` *appends to* `super`'s menu —
    so Cut/Copy/Paste, Look Up, Services and the substitution submenus all survive —
    adding a separator plus Go to Definition, Find Usages and Rename…, each acting
    on the identifier under the **click** rather than under the caret. A
    right-click does not move the insertion point, so a menu built from
    `selectedRange()` would answer about wherever the caret was last left, which is
    exactly the wrong word and silently so; the resolved offset is therefore
    stashed at menu-build time and re-read when an item fires (kept as an *offset*
    rather than a resolved word, so the identifier is read from the buffer as it is
    when the item runs). What `super` hands back is not promised to be a fresh
    menu — `NSTextView` builds one from a template it shares across every
    instance — so the tagged additions are **removed and re-made** on each
    right-click rather than skipped when they are already there. Appending
    unconditionally would grow a reused menu by four items per click; *skipping* a
    reused menu would be the worse bug, because the items it already carries are
    targeted at whichever text view built them, and a second editor would then run
    Find Usages and Rename against the first one's buffer. Rebuilding is right
    under both behaviours and costs three items. Enablement stays AppKit's:
    `autoenablesItems` is left alone (turning it off for our three would turn it off
    for every stock item too), and **both** validation entry points answer it —
    `validateMenuItem(_:)` and `validateUserInterfaceItem(_:)`, each deferring to
    one private predicate so the two cannot disagree about the same click. That is
    not belt-and-braces: `NSTextView` conforms to `NSMenuItemValidation`, and a menu
    validating an `NSMenuItem` asks a target that implements `validateMenuItem(_:)`
    and never falls through to `validateUserInterfaceItem(_:)`, so overriding only
    the latter would leave all three items permanently enabled on a right-click that
    resolved no name — and silently inert, since the handlers guard on the same
    question. `validateUserInterfaceItem(_:)` is kept for every other validating
    client, and both defer to `super` for everything else, including any command
    reaching this view through the responder chain.
    **One place turns a caret into a question**, shared by both commands so they
    can never disagree about what a name is or where the question is asked:
    `IdentifierScanner` decides — the same rule Go to Definition, completion and the
    textual scan use — and the *first* character of the resolved word is what
    travels, so the answer does not depend on where inside a name the caret stood.
    The live buffer travels with it (D2), because the seam may reach a server and a
    server must be told the text before it can be asked about an offset in it. The
    coordinator hands the result to the app as a `UsagesRequest` — *both* commands,
    including rename, because the read half of a rename asks exactly the same four
    things and the new name does not exist yet at that point; the dialog, the writer
    gate and the Local History capture are all the app's (`app-shell.md`). Nothing
    resolved is a **beep**, exactly as a ⌘-click on whitespace is: the command did
    not happen, and an alert for a misplaced caret would be worse than the caret.
    Every other rename refusal — no server, a server with no rename capability, an
    answer with no edits — belongs to the app for the same reason.
    **Per-tab viewport memory** (the caret and the scroll position surviving a tab
    switch) is the third thing keyed by `fileID` in the coordinator, alongside the
    per-file undo managers it deliberately mirrors: `private var viewports =
    EditorViewportMemory()` (Core — the value type, the clamp rules and why the
    anchor is a *character offset* rather than a point are in `core-editor.md`).
    It exists because one `NSTextView` serves every tab, so the `textView.string =
    text` swap above destroys the outgoing tab's position; nothing else in the app
    records it. Three coordinator methods are the whole AppKit half.
    `captureViewport()` reads `textView.selectedRange()` and resolves the top
    visible character by handing the clip view's `documentVisibleRect` top-left to
    `NSTextView.characterIndexForInsertion(at:)`; it answers `nil` only when the
    views are gone (a torn-down tab), and an empty buffer anchors at 0. **That hit
    test is deliberately not the layout manager's** `glyphIndex(for:in:)` →
    `characterIndexForGlyph(at:)` pair: the latter raises past the last glyph, the
    only bounds guard available for it is `NSLayoutManager.numberOfGlyphs`, and
    that property forces glyph generation for the *entire* document — an O(file
    size) main-thread cost on every single tab switch, which is precisely what
    `allowsNonContiguousLayout = true` is set to avoid. `characterIndexForInsertion(
    at:)` takes the point in the text view's own coordinates (which
    `documentVisibleRect` already is, so no `textContainerOrigin` correction),
    answers a character index directly, and clamps rather than raising, so it needs
    no guard at all. `recordViewport(for:)`/`forgetViewport(for:)` write the memory,
    and `restoreViewport(for:)` reads it back clamped to the live
    `textStorage.length`, applies `setSelectedRange` and hands the top offset to
    `scrollAnchor(to:)` — its scroll half, split out because the save transform
    needs exactly that and nothing else (it has already put the *remapped*
    selection back through the text view, and must move the page only far enough
    to keep the same character on the top line after an edit that may have deleted
    characters above it). `scrollAnchor(to:)` owns the layout-manager/text-container
    guard and its own `min(max(anchor, 0), length - 1)` clamp, so an offset that
    outran a shrunken buffer resolves to the last line rather than to nothing, and
    scrolls through the existing `scrollEditor(to:)` — which already clamps a document-space top offset
    to `max(0, textView.frame.height - clipView.bounds.height)`, so "never past the
    end of the document" is the final guard for free. That clamp needs one
    correction, though: the anchor's own `y` is exact (everything above it has just
    been laid out) while `textView.frame.height` is still an *estimate* for what
    sits below it, so a tab left within the last screenful of its file would be
    clamped short by the size of that error — measured at ~220pt, a dozen-odd
    lines, on a 3000-line file left at the bottom. The restore therefore finishes
    the layout when, and only when, the clamp is about to bind. That test is
    self-limiting: the clamp binds only near the end of the document, where
    everything above the anchor is laid out already, so it costs the remaining tail
    rather than the file. **The restore is
    synchronous**, unlike `applyReveal`'s one-turn `DispatchQueue.main.async` hop,
    and the difference is not stylistic: a restore deferred to the next main-loop
    turn would run after a *second* tab switch had already swapped the buffer again,
    scrolling the newly shown file to the previous file's offset. What makes
    synchronous work is an explicit `layoutManager.ensureLayout(forCharacterRange:)`
    from the start of the document up to the anchor before `boundingRect(
    forGlyphRange:in:)` is asked for it — the layout manager runs with
    `allowsNonContiguousLayout = true`, so the incoming text is not laid out yet at
    this point in `updateNSView` and the anchor's *position* (which depends on every
    preceding line's height) would otherwise be an estimate. **That `ensureLayout`
    is the feature's one real cost and it is not free**: the layout runs from
    offset 0 to the anchor, and again on every switch back (the buffer swap
    invalidates layout), so it is bounded by how deep into the file the tab was
    left — negligible for ordinary source files, and order half a second for a
    multi-megabyte file left scrolled near its end. Accepted knowingly: the only
    alternative is the non-contiguous *estimate*, which lands the restore on the
    wrong line, and there is no third way to get an exact document-space `y`
    without laying out what is above it. There is **no end-of-buffer special
    case**, because Core's clamp guarantees the anchor names a character that
    exists (`0...max(0, length - 1)`; an earlier revision admitted `length` and
    paid for it with three view-layer branches, one of which read a *pre-layout*
    `extraLineFragmentRect` and scrolled to a fraction of the intended offset).
    Only the empty buffer is special, and only as an early `scrollEditor(to: 0)`.
    `setSelectedRange` needs no case either: a caret at `length` is legal, which is
    why the selection clamp still admits it. **"Nothing recorded" is a state the
    restore has to write, not skip**: a first visit, a closed-and-reopened tab and
    a tab whose text was replaced from outside all arrive with no entry, and the
    intended outcome for all three is the top of the file — but assigning
    `textView.string` leaves the caret at the **end** of the incoming contents and
    the clip view at the *outgoing* tab's scroll offset, so `restoreViewport(for:)`
    sets `{0, 0}` and scrolls to 0 explicitly on the `nil` branch. The ordering in `updateNSView` is
    load-bearing at every step, and reads **capture → prune → buffer swap →
    per-file reconciliation → restore → reveal**: the outgoing tab's viewport is
    recorded first, above the swap (afterwards there is nothing left to read), and
    deliberately *before* `prunePerFileState(keeping: openFileIDs)` rather than
    after — closing the displayed tab records its position and the prune
    immediately discards it again, since the id is no longer in `openFileIDs`, so a
    closed tab retains nothing and reopening the file starts at the top, whereas
    recording afterwards would leave that entry alive for the app run. The restore
    runs *last*, on a `switchedFile` update only (an ordinary keystroke must leave
    the user's own scrolling alone) and after the highlighter/minimap/bracket/
    search/blame reconciliation, so the bounds notification the scroll posts
    refreshes geometry that already describes the incoming file. **An explicit
    reveal outranks the memory**: activating a Find in Files result or a
    go-to-definition in an already-open background tab is a switch too and must land
    on the match, so `hasPendingReveal(_:fileID:)` suppresses the restore, leaving
    `applyReveal` below to do its usual one-shot work. Both of them route through
    one private `pendingRevealRange(_:fileID:)` — **the single place the reveal's
    admission rule lives**, deliberately, because two copies of it drift: the
    predicate needs the *range* guards too, not just the token/`fileID` pair, or a
    result row that pre-dates an edit shrinking the file counts as "pending",
    suppresses the restore, and is then declined inside `applyReveal`'s hop —
    leaving the tab at whatever offset the reused text view happened to carry over
    from the outgoing file. `applyReveal` still consumes the token whether or not a
    range came back (a standing request is applied exactly once; an unusable range
    is a dead request, not one to retry on every later update) and still re-clamps
    inside the hop, since a whole main-loop turn passes and nothing promises the
    text did not shrink in between. The memory is dropped on exactly the signal
    that drops the undo stack, in the same branch and for the same reason: when
    `noteExternalTextRevision(_:for:)` reports this file's buffer was replaced while
    it sat off screen (a project Replace All, a post-revert `reloadFromDisk`, a merge
    apply, an off-screen save transform), the recorded selection and anchor name
    characters the incoming text
    never had, so `forgetViewport(for:)` runs and the restore finds nothing and
    writes the top-of-file state, exactly as on a first visit.
    `pruneUndoManagers(keeping:)` is renamed
    `prunePerFileState(keeping:)` accordingly: it already pruned
    `externalTextRevisions` as well as the undo managers, and now prunes a third
    dictionary, so the name naming only one of the three had stopped being true.
    **The hover popover's wiring lives here, and only its wiring** (`core-lsp.md`'s
    D25/D26; the controller and the panel have their own entries below).
    `EditorTextView` gains the tracking area hover is driven by, installed in
    `updateTrackingAreas` and *replaced* rather than accumulated, since AppKit runs
    that method on every resize. `.inVisibleRect` is what scopes it to the visible
    rect **and keeps it there** — AppKit resizes such an area itself as the view
    scrolls inside its clip view, so the passed rect is ignored and there is no
    scroll-position staleness to manage — and `.activeInKeyWindow` scopes it to the
    window the user is working in, the only one a popover may appear over. `super`
    is called first so every tracking area `NSTextView` installs for its own cursor
    and link handling survives, and `mouseExited` is answered **only for this
    area** (`event.trackingArea === hoverTrackingArea`): treating a cursor-rect
    exit as ours would dismiss a popover the pointer never left. The two events
    reach the coordinator through `onPointerMoved`/`onPointerExited`, weakly
    captured for the same retain-cycle reason as every other closure on this view —
    a deallocated coordinator simply shows no popover.
    `interfaceMetrics` is a new stored property on the representable, **a plain
    value beside `fontSize`** and undefaulted for that property's reason. The two
    are deliberately different zones travelling together: the popover draws code at
    `fontSize` (the code zone, untouched) and prose at these metrics (the interface
    zone), and the raw interface scale is never named here — an
    `NSViewRepresentable` cannot read `@Environment` for an AppKit window it creates
    itself, and multiplying anything inline is exactly what `ZoomSourceGatingTests`
    exists to catch. `syncHover(codeFontSize:metrics:)` forwards both on every
    `updateNSView`, cheaply and unconditionally, because the controller only stores
    them and they are read when the *next* answer is drawn.
    Six of the popover's dismissal triggers are observations this file already
    owned, and each is dismissed at the existing call site rather than by a second
    observer: the text storage's `didProcessEditing` (any edit — programmatic ones
    included, which is why it is the storage's notification and not
    `textDidChange`), `textViewDidChangeSelection`, the clip view's
    `boundsDidChangeNotification` (a scroll moves the text out from under a
    popover anchored in *screen* coordinates — reusing the observation the minimap
    already installs, because two observers of one notification eventually
    disagree about what a scroll is), its `frameDidChangeNotification`
    (`syncableFrameChanged`), the buffer-swap branch of `updateNSView`,
    which invalidates a popover describing an offset in the text it just replaced,
    and the **font-change branch of `updateNSView`**, which is a reflow of the same
    kind: the anchored line moves and the popover's code is drawn at the old size.
    The last two are the dismissals the pointer cannot stand in for — the
    "moving the pointer an inch takes it down anyway" argument that lets
    `syncHover(codeFontSize:metrics:)` merely *store* its two values fails for
    ⌘+/⌘−, which involves no mouse movement at all, and for ⌘-scroll, whose event
    `ZoomController`'s monitor consumes so the clip view never posts a bounds
    change — and it fails identically for a *frame* change, which is a reflow with
    the pointer perfectly still: a window resized from the keyboard or the zoom
    button, the bottom panel toggled, the sidebar dragged. Frame and bounds are
    two notifications rather than one because they are two different questions
    (the minimap's geometry needs both, and only one of them is a scroll), so the
    dismissal is stated on both.
    `teardown` calls `hover.reset()` beside `completion.reset()`, so a closed tab
    cannot leave a floating annotation of its file on screen.
    Diagnostics ride this file's existing machinery at every point, with two new
    inputs beside the ones above: an optional `lspSync:
    LSPDocumentSyncController?` and an optional `diagnostics: DiagnosticsModel?`
    (both defaulted nil so previews compile; the app owns both). **The sync
    forwards inside `Coordinator.reindexSymbols`** — the one method all four
    index triggers already funnel through (tab switch, buffer replacement, and
    the two *retargets* below) — calling the sync controller's
    `noteBufferOpened`/`noteBufferChanged` immediately beside the index
    controller's same-named call, which is what guarantees the symbol index and
    the LSP server are always told about the same buffer in the same order and
    can never disagree about which buffer is current; an untitled buffer is
    skipped by the existing guard, since there is no URL to file it under.
    The **retarget triggers** cover the two ways a displayed buffer's
    coordinates change while its id and text stay put, both of which would
    otherwise leave every surface dark until the user happened to type or
    switch: a new **URL** (Save As giving an untitled buffer its first path; a
    project-tree rename/move retargeting through `applyRenamePlan` after the
    move's `forgetIndexedBuffer` already `didClose`d the old URL and cleared its
    diagnostics via D33), and a new **root** (`projectRoot`, compared against a
    value seeded in `makeNSView` so a fresh view does not re-read as one) — the
    first Open Folder of a run carrying tabs, whose buffers were never synced
    because every earlier trigger ran with no root. Background retargeted tabs
    stay lazy: they sync on their first switch like any other background
    buffer.
    **Edits** flow through the ruler's `onEdit` closure (captured weakly per the
    retain-cycle rule), whose pre/post line-start tables this class maintained
    for blame anyway: the coordinator's `bufferEdited` hands them straight to
    `diagnostics.noteEdit(...)` — Core's shift runs on geometry nobody
    re-derived — then clears the underline temporary attributes over the edited
    span converted back to *pre-edit* coordinates (`didProcessEditing`
    precedes the layout managers' notification, the mirror of
    `bracketHighlight.noteEdit`'s arithmetic) while deferring the repaint itself,
    which would otherwise write post-edit coordinates TextKit shifts again.
    A buffer swap (`contentReplaced`) splits two ways, decided beside
    `beginBlameBufferSwap()` before the assignment posts its full-range edit
    notification: a *plain tab switch* (the incoming text is the file's own,
    untouched off screen) **keeps** the outgoing document's set — the store is
    keyed by URL so background documents survive the view swap, and dropping
    would strand them behind D2's identical-text fast path, which never makes a
    push-only server re-publish — while a genuine replacement (the displayed
    buffer swapped, or this file rewritten off screen by Replace All /
    `reloadFromDisk` / merge apply, which `externalTextRevision` reports) calls
    `beginDiagnosticsBufferSwap(clearing:)` → `noteBufferReplaced(url:)` and
    drops the replaced document's set outright (D32). The URL is handed in —
    the view's `fileURL`, i.e. the *incoming* file on a switch — because the
    coordinator's recorded URL still names the outgoing one there, and clearing
    it would destroy the innocent bystander's set while leaving the rewritten
    file's stale entry standing. Either way the full-range edit itself never
    reaches
    `bufferEdited`'s shift (`isSwappingBuffer` guards it): for a kept set it
    would drop every entry, and for a cleared one there is nothing to shift.
    Model changes arrive through one Combine subscription taken in
    `attachDiagnostics(model:)` (re-attachment identity-checked, torn down in
    `teardown`); each publishes into `scheduleDiagnosticOverlaysRefresh`, a
    coalescing hop onto the next main-loop turn that ends in
    `refreshDiagnosticOverlays` pushing the active document's runs (range +
    severity) into `setDiagnosticRuns(_:)` and recomputing the gutter column from
    `worstSeverityPerLine` against the ruler's own line geometry — one method
    covering all three feeds (model change, edit, tab switch/buffer swap),
    because each must paint whatever the incoming file's store entry now holds:
    all-`nil` when a replacement just cleared it, the retained set after a plain
    switch back to a diagnosed background file.
    **The folding wiring is wiring and nothing else** (the feature is documented in
    `core-folding.md`). `attachFolding(textView:ruler:)` binds the controller to
    both views and installs its `source` closure — provider, file URL, language and
    the indentation widths, all *read* at the moment a question is asked rather than
    captured, for `HoverController.Source`'s reason. `syncFolds(text:immediate:)` is
    the one trigger funnel: `immediate` on a tab switch, a tab open or a retarget
    (which also restores the incoming file's remembered folds), debounced on an
    ordinary edit. `syncFoldInputs(alreadyAsked:)` re-asks when the buffer's
    language or the `.editorconfig` revision moved and does nothing at all
    otherwise, since it runs on every SwiftUI update; the revision is compared here
    rather than ridden on the indentation painting's cache, because that cache
    exists only while the preference is on and folding does not ask the user's
    permission to know where a block ends. The edit path hands
    `FoldController.noteEdit` the same previous/new line-start tables, edited range
    and length delta the diagnostics shift already gets, so nothing re-derives
    geometry the coordinator holds. `recordFolds()` on the switch away,
    `forgetFolds(url:fileID:)` beside `forgetViewport(for:)` on the same
    text-replaced signal, `forgetAllFolds()` on a folder switch, and
    `folds.reset()` in teardown.
    **The memory key is `Coordinator.foldMemoryKey(url:fileID:)`**: the canonical
    path of a url-backed file (`standardizedFileURL` then
    `resolvingSymlinksInPath()`, `SourceViewerWindowController`'s spelling), the tab
    id's `uuidString` otherwise. Deliberately **not `OpenFile.id`**, which is a
    fresh `UUID` per open — closing and reopening a file would lose its folds, which
    is exactly what the memory exists to keep for the run. It is a `static` method
    as well as a property because it has to be asked about the *incoming* file at
    one moment: `updateNSView`'s content-replaced branch runs before `syncBlame`
    re-records the URL, so the property still names the outgoing one there. One
    spelling, two callers.
    **The caret hook**: `applyFoldCaretRule(previous:)` is the one place
    `FoldCaretRule` is applied — from `textViewDidChangeSelection` (carrying the
    previous selection, which is the *direction* the rule reads) and from the fold
    gesture (carrying `NSNotFound`, since nothing moved and the caret should land
    beside the placeholder). A re-entrancy flag keeps the corrective selection from
    being re-inspected as a user move, in `isApplyingProgrammaticEdit`'s shape.
    **The two commands and the two clicks.** `foldAtCaret()` / `unfoldAtCaret()`
    answer `FoldCommands`' menu items and return `false` for it to beep on; which
    block each acts on is `FoldCommandRule`'s decision, asked with **the gutter's own
    line table**, so the command and the chevrons can never disagree about which line
    the caret is on. *Fold* then puts the caret at the start of the header line — the
    one line the collapsed block still shows — through an ordinary
    `setSelectedRange`, so that move runs through the caret rule like every other
    rather than through a second rule. `toggleFold(_:)` is the gutter chevron's
    gesture. `unfoldPlaceholder(at:in:)` is the `…` click, tested against
    `placeholderRect(forFoldedRangeAt:)` — the box that was *drawn*, not arithmetic
    over the point — and `false` there means "not mine", so the click proceeds as an
    ordinary one. `EditorTextView.mouseDown(with:)` asks it before anything else
    looks at the event, because `super.mouseDown` would otherwise run its tracking
    loop and place a caret inside text that has no position on screen; only a plain
    single click is claimed (a modified one is a selection gesture, a double click is
    the stock word selection), and the pointer is deliberately left as the I-beam
    over the placeholder, since the `…` stands in for text.
    **The reveal funnel is `revealRange(_:)`**, and it is the one method in the
    editor that jumps to a range: it applies `FoldReveal.unfolding(_:in:)` first,
    then selects, then scrolls. Its callers are exactly two files —
    `applyReveal` in this one (where every `EditorRevealState` request from the
    scene lands: Find in Files, Go to Definition inside the project, the Problems
    rows, the Usages rows and the symbol jump) and `EditorSearchController.select(_:)`
    through the `revealRange` hook `attachSearch` installs, which is why the find
    bar no longer selects or scrolls for itself. This file holds exactly **two**
    `scrollRangeToVisible` calls: the funnel's own and the Tab plan's caret scroll
    after a raw-storage edit, and the second is named as **not a reveal** — it
    re-shows a caret the selection path just produced and the caret rule has already
    sanitized, on a line that is visible by construction. Three further text views in
    the app scroll and are excluded because they hold no fold state at all:
    `SourceViewerContent` (the read-only out-of-project viewer), `MergeView`'s result
    pane and the iOS coordinator. `FoldReveal` and `FoldCaretRule` are each named in
    this file alone, and `FoldingSourceGatingTests` pins all of it by set equality.
  - `LSPDocumentSyncController.swift` (macOS) — the diagnostics channel's push
    sync (D30), and the reason a server ever re-diagnoses anything after its first
    look: D2's flush is request-driven, diagnostics are pushed unasked, so every
    open buffer of a served language must be handed to its server without being
    asked about. It is `SymbolIndexController`'s exact idiom — an `@MainActor`
    map of per-URL cancellable `Task`s over a 400 ms debounce, deliberately that
    class's length because both readers fire from the same triggers at the same
    shape of cost (one whole-file notification per settled burst per edited file)
    — and it decides only *when*: everything about *what* a sync means lives in
    Core (`LSPWorkspace.prepare`, `DiagnosticsModel`'s acceptance gate) and is
    tested there; this file is thin untested glue like the rest of `Sources/Pisaka`.
    `noteBufferChanged(url:text:language:)` debounces per URL (a newer task for
    the same file cancels the older one — a burst flushes once);
    `noteBufferOpened(...)` bypasses it, because the file being looked at must be
    diagnosed before the user finishes reading it, and supersedes only *this*
    file's pending debounce — the file switched away from keeps its timer, which
    is the one chance its last keystrokes have of reaching the server;
    `noteBufferClosed(url:)` cancels in-flight work for the closed tab (telling
    the *server* stays `lspWorkspace.didClose`'s job beside it); `reset()` drops
    every pending debounce for a folder change. Each task pins
    `model.currentRevision(for:)` **synchronously before its first hop** — the
    generation-token rule, applied where an answer's acceptance will be judged —
    then awaits `prepare(url:language:text:forceFlush: true)` and reports
    `noteSynced(url:version:revision:)` on success. **Successors chain on their
    predecessor**: a new schedule captures the map entry it evicts and its task
    awaits that handle's completion — report included — before preparing, with
    cancellation checkpoints on both sides of the wait. The ordering is
    load-bearing because two tasks released from one shared await (the
    per-document flush wait chief among them) otherwise resume in unspecified
    order, so their reports can land newest-pin-first; a wholesale rewrite of the
    *displayed* tab is exactly two such schedules (`reindexReloadedBuffer`'s and
    the editor's content-replaced branch) with no third trigger behind them, and
    a record left naming the evicted task's older pin would fail every later
    push at the gate's revision half — the document blank until the user touches
    it. Chaining makes the final record always the last sender's. An
    evicted task's report is therefore deliberately *not* cancellation-gated:
    skipping it would leave bookkeeping describing less than what the server
    provably holds, and the stale revision pin turns any mismatch into D32's
    sanctioned trade — rejected until the next trigger re-syncs. **A
    *discarded* schedule is the other half and reports nothing.**
    `noteBufferClosed`/`reset()` carry no successor and run beside the model
    call that forgets the document outright (`noteDocumentClosed`,
    `prepareForFolderChange`), so there is no record left for a report to keep
    truthful — a task still inside `prepare` when one of them lands sends its
    notification to completion, but its report would only re-create the record
    the close just pruned: an entry for a document no tab shows that nothing
    prunes again, and one that gates the file's *next* life against this one's
    version instead of from zero (`DiagnosticsModel.noteDocumentClosed`'s stated
    invariant, and the same blank-until-touched failure chaining exists to
    prevent, on the one path chaining cannot cover — a close and a reopen inside
    one flush are unchained by construction). The verdict rides a small
    reference-typed box per schedule, set by those two paths alone, so it dies
    with its map entry; a per-URL counter would have to outlive every close
    forever to stay readable, which is the unbounded map the flag exists to
    prevent. The flag is the one thing
    this layer adds to D2's flush: a completion/hover/definition prepare may already
    have delivered the same text (its push then dying at the gate, version past
    the record), and an unforced landing would send nothing for a push-only server
    to answer — the forced republish is what keeps the burst ending in a push the
    model accepts (core-lsp.md, D30). A `nil` prepare — no server,
    unavailable, outside the root, folder moved, pipe gone — does nothing at all,
    silently: D7's uniform-`nil` discipline covers this layer's one unprompted act
    too, and nothing on this path raises or takes the writer gate (D10). The
    language gate up front is `canServe`, policy-only: asking it starts nothing,
    so a consent-pending or unavailable server simply schedules no work.
  - `CompletionPanel.swift` — a custom borderless, non-activating `NSPanel` replacing AppKit's native completion popup, built in `HoverPanel`'s mould but pointer-reachable. It accepts clicks (a row commits), so `ignoresMouseEvents` is false, but `canBecomeKey` / `canBecomeMain` stay false so typing keeps going to the editor. Its content view conforms to `ZoomSurfaceProviding` with `.code` because it is walked by the pointer and drawn at code size. It contains a scrolling row list (at most 30 drawn at once) where each row is the candidate text plus a badge symbol. The *drawn* count is bounded not just by the provider's list cap but by the room the anchor's screen actually has below or above the anchor — at a zoomed code font thirty rows outrun the screen, and rows past the cap stay reachable through the scroll view rather than offscreen (a five-row floor keeps a cramped screen from degenerating into an empty panel). Width is measured from the widest row; placement is below the anchor rect (flipped above when there is no room) and clamped horizontally. Each row is drawn as a **single line**: an LSP item's display text is what the server inserts, which legitimately carries newlines (`services:\n  `), so the panel projects it to its first line plus an ellipsis — drawing verbatim would paint over following rows and desync the visual list from click hit-testing, which divides the row height evenly. The projection is display-only: the committed text and every key built on `displayText` stay the full string. Its outside-click monitor does not merely hide the panel: it fires `onOutsideClick`, wired to the *controller's* `dismiss()` — a panel-level hide alone would leave `pendingTask` and the offered list alive, free to re-present over whatever word the click landed on.
  - `CompletionController.swift` — feeds the `CompletionPanel` from the asynchronous code-intelligence seam. The work is inverted: candidates are computed ahead of time behind a debounce (150 ms) and only then is the panel shown via `apply(…)`. Staleness guards ensure a late list refuses to show over a changed buffer: the generation token, plus the re-read caret, focus (`firstResponder` **and** key window — `NSWindow.firstResponder` is not cleared when its window stops being key, and nothing else would take down a panel shown over a background window), marked-text, exact-prefix and same-member checks all ensure the answer is still current.
    The prefix/member re-checks compare *text*, never the location, so an answer computed for one word must not open over another. A caret move that **leaves** the served word therefore retires anything still in flight — the visible case runs through `update(…)`'s location gate, and the hidden case (nothing shown yet, debounce or LSP round trip outstanding) reaches the narrow `invalidatePendingRequest()` — task cancelled, generation bumped, nothing else. It deliberately stops short of `forgetList()`: this path also carries every post-commit caret move, and D4's late auto-import scheduled by that commit must survive it (the same reason `windowDidResignKey` and `textDidEndEditing` gate on visibility). A caret move that **stays inside** the served word (same word start) supersedes nothing at all: `update` returns before its cancellation block, so the debounced narrowing answer and the standing rows' prefetched resolves stay alive — killing them would strand the panel on its stale list until the next keystroke and degrade a later deferred-row commit's import into a second undo group — while `apply`'s text/member/focus re-checks make a late arrival harmless wherever the caret ended up.
    Selection state clamps at both ends (no wrap-around), and an empty list has no selection.
    **Two commit ranges:** Enter's range (`completionPrefixRange`) inserts using today's semantics. Tab's range (`completionReplaceRange`) replaces the whole identifier under the caret, extending the prefix range forward over the continuation scalars. The two ranges are identical with no suffix.
    **Commit** re-reads the live buffer and caret, derives the commit range from `IdentifierScanner` per mode, and runs one `insertText` (for simple items) or the `CompletionEditPlan` (for items with edits, e.g. auto-imports), inside `noteProgrammaticEdit` and a single undo group. Tab verified suffix deletion happens in this same group. The popup is dismissed first so the insertion's `textDidChange` cannot re-open anything.
    **The commit staleness rule is the same word *start*, not the same word *text***: `update` keeps the previous list serving while a fresh answer debounces, so Enter/Tab routinely lands when the live word is longer or shorter than the snapshot's prefix — refusing then would hand the key through as a newline/tab mid-word. What invalidates the list is a *moved* word: any caret relocation fails `update`'s own location gate and takes the popup down before a key can be claimed, so `commit` matches that same location gate (making "still visible" ≡ "committable") and derives every range — including the plan path's typed word — from the live buffer. An LSP item whose edits were computed for a different spelling of the word is re-expressed or refused by `CompletionEditPlan` as usual; a plan rejected for no longer covering the live word degrades to the plain insertion of the row's display string.
    **The dismissal set:** all funnelled through one idempotent `dismiss()`. Triggers include: Esc (in `cancelOperation`), a commit, a click outside the panel (the panel's local `NSEvent` monitor, forwarded through `onOutsideClick` so the controller's dismissal — not a bare hide — runs), first-responder loss (`textDidEndEditing`), window resign key, a caret move that leaves the word (`textViewDidChangeSelection`, which asks with `caretMove: true` so a bare caret move only ever invalidates — a keystroke or ⌃Space that has moved onto the far side of a typed `.` drops the stale snapshot and still asks), any `update(…)` early return that clears the snapshot, an answer with no candidates, a scroll while the panel is visible, a code-font change, a tab/file switch, and teardown. The scroll is routed through `clipViewDidScroll()` rather than dismissed outright, for two reasons. First, it is gated on visibility because `dismiss()` tears down the D4 state too — the late auto-import resolve of a row committed moments ago must survive scrolls and window resigns when nothing is shown. Second, it distinguishes a *user* scroll (panel down) from the text view's own insertion-point autoscroll — a keystroke past the right edge of an unwrapped line, an Enter at the bottom edge, an arrow along a long word — which must keep the list up and narrowing: each `present` records the `bufferVersion` and caret it anchored to, and a bounds change arriving with either moved is self-driven, so the same rows are re-presented at the live anchor instead of dismissing. Frame changes are deliberately not wired: they fire for ordinary typing that grows the document, and dismissing there would cancel each such keystroke's narrowing request.
    The controller syncs both font inputs, mirroring the hover controller (`syncAppearance(codeFontSize:metrics:)`): the row text draws at the code size, while the badge column, the width cap and the measured row inset are interface chrome and scale through `InterfaceMetrics.pt` — the anchor gap and the row height's padding stay raw, the first as a fixed anchor offset in `DiffView`'s class, the second because it belongs to the code font's cell.
  - `HoverController.swift` — turns "the pointer has been sitting on this
    identifier" into a hover request and its answer into a popover
    (`core-lsp.md`'s D25). Built in the `CompletionController` mould because it has
    the same shape of problem — an asynchronous seam behind an event that fires per
    pixel of mouse movement — so the same three devices do the same jobs. **One
    cancellable dwell task**, sleeping `HoverContent.dwellDelay` (Core's constant,
    never a literal here), which is what makes moving the pointer across a file
    cost nothing: every move supersedes the previous task before it has woken.
    **One monotonic generation token**, captured synchronously *before* the hop, so
    an answer whose token is stale is dropped and never shown. **One panel**,
    reused and dismissed idempotently.
    `pointerMoved(to:in:)` has exactly three outcomes: the pointer is over
    something that is not a word (dismiss), it is still inside the range the
    current answer covers (**do nothing at all** — the popover on screen already
    describes it, and this is the whole re-ask suppressor), or it is over a new
    identifier (bump the token, cancel the dwell, take the panel down, and start
    again). `IdentifierScanner` is the gate and the anchor both, so hover, ⌘-click
    and completion can never disagree about what a word is, and whitespace,
    punctuation and the empty region past a line's end never reach the provider —
    except where D34 widens it, below: punctuation inside a diagnostic's span is
    asked about, at the union's start.
    The anchor is deliberately also set for a request that turns out to have **no**
    answer, so a server that knows nothing about an identifier is asked once per
    visit rather than once per mouse-moved event — but it is set **after** the
    `Source` is read, not before. The anchor means "this word has been asked
    about"; claiming it for a question that is never asked (no provider at all —
    a preview, or an editor whose index controller has gone) would leave the
    identifier suppressed with nothing on screen, and the pointer would have to
    leave the word and come back before anything could happen.
    **"Still inside" is asked of the identifier, not only of the offset**, and the
    second half is not decoration: `IdentifierScanner` resolves the identifier
    *ending* at an offset as well as the one containing it, so the pointer sitting
    on the `.` of `worker.name`, on a `(`, or on the space after a name resolves to
    that name while lying **outside** its range. Testing the offset alone would
    therefore take the popover down and re-ask on every pixel of jitter at exactly
    the positions a pointer comes to rest on. Containment of the resolved range
    inside the anchor answers both cases, and keeps a server range wider than the
    identifier (a qualified name, an operator expression) doing what it is for:
    moving within it re-asks nothing.
    **Asking requires the offset to be inside the identifier — or inside a
    diagnostic**, which is D34's one widening of this rule. The
    ending-at probe is wanted only for the suppression test; once there is nothing
    on screen to keep, a match the offset lies *outside* of is dismissed instead of
    asked about — so the space after a name and the `.` of `worker.name` never reach
    the provider as questions about the word before them, *unless* they lie in
    diagnosed text, where the pointer rests on something the popover can speak about
    whether or not it is over a word. It is also what keeps the
    offset the question carries and the range the answer is anchored to talking
    about the same thing, which matters because the servers disagree at exactly
    those positions (sourcekit-lsp resolves at the preceding token, gopls' node
    lookup is `[Pos, End)`).
    **The empty region past a line's end is refused a step earlier, and it has to
    be.** A character's laid-out rectangle is not as narrow as it looks — a line's
    trailing separator is drawn spanning the **whole remainder of its line
    fragment** — so a pointer resting inches to the right of the text resolves to
    that separator and the ending-at probe answers the line's last word. The
    ask-side guard alone cannot fix this, because the popover for that word may
    already be up: the `.` after a name and the newline after one sit at *the very
    same offset relative to it*, so the suppression test cannot tell them apart and
    would keep the answer on screen while the pointer sweeps the blank half of the
    line. `characterIndex(at:in:)` therefore answers `nil` for a line separator
    outright (`LineStartIndex.isLineSeparator`, so "where a line ends" means what it
    means to the gutter, the minimap and TextKit), which makes both tests agree and
    turns the blank region into an ordinary dismissal.
    The buffer is read through the text storage's own `NSMutableString` rather than
    `textView.string`, which bridges — and therefore **copies the whole document**
    — every time it is named. Every other `textView.string` in the editor sits
    behind a debounce or an explicit command; this one runs per mouse-moved event,
    and on a large file the copy alone is the stutter. Read-only and synchronously
    on the main actor, so no edit can interleave.
    For the same reason the request itself is built **inside the dwell task, after
    the sleep**, not beside the scan: eager construction would pay the full-document
    bridge for every identifier a pointer sweeps across, on the main thread, for a
    question most of those sweeps never live long enough to ask (and that a language
    with no server, or a server with no `hoverProvider`, would drop immediately). It
    is no less faithful to D2's "the live buffer travels with the request", because
    every character edit calls `dismiss()` and cancels the task — the text cannot
    change under the offset while the dwell sleeps.
    **Resolving the character under the pointer is not one line, and that is the
    point.** `characterIndexForInsertion(at:)` — what ⌘-click and the viewport
    memory use — answers the nearest *insertion point*, which past the end of a
    line is that line's last character, and a popover describing a symbol the
    pointer is a hand's width away from is worse than no popover. So its answer is
    **verified**: the character is accepted only when its own laid-out rectangle
    contains the point, and two candidates are tried (the index and the one before
    it) because an insertion point is a boundary — a pointer in the right half of a
    glyph reports the index after it. Both halves of every glyph therefore resolve
    to the glyph. A **line separator is no character** here, checked before the
    rectangle test: a trailing newline's rectangle spans the rest of its line
    fragment, so a point far to the right of the text really is inside it, and
    answering it would hand the gate above an offset the re-ask suppressor accepts
    (see the paragraph on the blank region). The obvious spelling — `glyphIndex(for:in:)` guarded against
    `numberOfGlyphs` — is rejected on cost: it forces glyph generation for the
    **entire document** on every mouse-moved event, the exact thing
    `allowsNonContiguousLayout` exists to avoid (see `restoreViewport`).
    `Source` is read *at the moment a question is asked* rather than stored — the
    provider especially, since `SymbolIndexController` hands out the model's latest
    snapshot and a held reference would answer from the state a folder was opened
    in (`updateCompletions`' rule). The index's `currentRootGeneration` is pinned
    before the hop and re-checked after it, so an answer for a folder the user has
    since left is discarded rather than drawn over the new one — the same
    main-actor-hop closure both definition call sites make.
    **`dismiss()` is idempotent and safe against a dismissal racing an in-flight
    answer**: bumping the generation is what makes the second guarantee, since a
    provider call landing after it returns finds a stale token and publishes
    nothing. Every trigger funnels here — the pointer leaving the anchor range or
    the text view, a scroll, a text edit, a selection change, a tab or file switch,
    the window resigning key, and teardown — and the first two are this file's
    while the rest are wired at `CodeEditorView`'s existing observations (see its
    entry). The key-window observation is registered once in `attach(textView:)`
    rather than per request, for *any* window's notification, because a window
    resigning key means the user is somewhere else entirely and an annotation of a
    buffer they are no longer looking at is stale by definition; `present`
    re-checks `isKeyWindow` anyway, so an answer arriving a dwell after focus was
    lost floats over nothing.
    **Silent throughout**: no server, no capability, no answer, a timeout, a stale
    document are all "no popover", with no beep and no alert. Unlike ⌘-click,
    nobody asked for this, and a warning sound for an answer the user never
    requested is noise. Thin, untested view glue: every decision it acts on — what
    a word is, whether there is an answer, what it looks like, how much of it fits
    — is Core's, and this class owns exactly two facts of its own: where the
    pointer is, and whether the answer on screen still describes it.
    D34 extends the same pipeline to diagnostic messages rather than adding a
    second surface. `Source` gains one lookup, `diagnosticsAtOffset(fileURL,
    offset)` — read *at the moment the question is asked*, like everything else in
    the source, and captured into the dwell task so a push landing mid-dwell
    cannot rewrite what the popover is about to say. The ask gate widens from
    "the offset is inside an identifier" to "inside an identifier **or inside a
    diagnostic range**" (D34's reason: a squiggle can cover punctuation no scanner
    names a word), while every dismissal rule, the generation token and the silent
    failure stay byte-for-byte what they were — a pointer moving off both the word
    and the squiggle dismisses exactly as before. The anchor becomes the **union**
    of the ranges hit (identifier span extended over them when there is one), so
    the re-ask suppressor holds across the whole diagnosed span instead of tearing
    the popover down per pixel of jitter — and the suppressor's containment test
    reads a **zero-length** anchor as containing its own offset, because
    `NSLocationInRange` contains nothing in an empty range and a server's
    "expected `}`" at a position produces exactly one (the same reading
    `DiagnosticStore.diagnostics(at:)` and `DiagnosticRun.merged` already give
    it); off an identifier the question carries
    the union's *start* rather than the pointer's own offset, because servers
    resolve tokens and a diagnostic begins at the construct it complains about.
    The answer is merged through Core's `Diagnostic.hoverContent(for:merging:)` —
    messages above the type answer when there is one, alone when there is not,
    nothing when both are empty — and presented by the *same* panel as the same
    `HoverContent` type it always drew; the server's own range stays the honest
    span when it answered, and a diagnostics-only answer anchors to the union set
    at ask time.
  - `HoverPanel.swift` — the popover itself: a borderless, non-activating `NSPanel`
    drawing a `HoverContent` beside the identifier the pointer rests on.
    **The pointer cannot reach it, and that is the whole design** (`core-lsp.md`'s
    D26). `ignoresMouseEvents = true` is one line and buys three properties at
    once: every click, ⌘-click, drag-selection and context menu passes straight
    through to the code beneath, so a pointer that appears to move "onto" the
    popover is still over the text view and simply updates or dismisses the answer;
    it is **chrome rather than a code surface** under `ZoomSurface.swift`'s
    "unreachable ≡ chrome" rule, so nothing here conforms to `ZoomSurfaceProviding`
    even though the panel draws code at the code zone's font directly over the
    editor — a zoom gesture aimed at where it appears to be is a gesture over the
    code, which is the zone the user means; and **it cannot scroll**, which is why
    Core truncates by line count instead, since a scrollable popover would need the
    pointer inside it and would undo all three at once. That one line is invisible
    to every other check in the repository, so
    `ZoomSourceGatingTests.testTheHoverPanelPassesEveryMouseEventThroughToTheCode`
    pins it — and the no-surface half — statically, over comment- and
    literal-stripped source like its siblings.
    `canBecomeKey`/`canBecomeMain` are overridden to `false` rather than left to
    the style mask: a borderless panel is already refused key status by AppKit
    today, and the override states the requirement instead of depending on that.
    Nothing in the popover is interactive, so key status would buy nothing and
    would cost the editor its first responder mid-typing.
    The panel is built on first use and **reused for the lifetime of the editor** —
    a hover is shown and dismissed constantly, and a fresh `NSPanel` per dwell is a
    window-server round trip per identifier. It is added as a **child window** of
    the editor's window so it travels with it, orders out with it and cannot
    outlive it; `dismiss()` detaches, and every `show` is preceded by one, so the
    parent guard is what keeps a parentless preview from pretending it has one.
    **Its appearance is taken from the parent window on every show**, and that is
    not the belt-and-braces it looks like: this is the app's one plain-AppKit
    window, and SwiftUI's `.preferredColorScheme` — which is how the Theme
    preference is applied — sets the appearance on the window it is attached to
    rather than on `NSApp` (`TerminalSessionsModel` records the same fact for the
    terminal), and a child window does not inherit it. Unmatched, Theme = Light on
    a dark system draws a dark popover over a light editor. The border hairline is
    repainted in that appearance at the same moment for the second half of the same
    reason: a `CGColor` is resolved once at assignment, so a colour set on the
    layer at creation survives every later appearance change as a light line around
    a dark popover — an `NSColor` is only dynamic while it is still an `NSColor`.
    `dismiss()` is idempotent, because dismissal arrives from a dozen unrelated
    places and several of them routinely fire when nothing is on screen — and it
    returns early when this object has not put a popover up, which is what makes it
    *free* as well as safe: the controller dismisses on every mouse-moved event over
    whitespace or punctuation, and an `orderOut` of an already-hidden window is a
    window-server round trip per pixel of pointer movement.
    That early return reads **its own `isShown` flag rather than the panel's
    `isVisible`**, and the difference is a real popover coming back from the dead:
    the panel is `hidesOnDeactivate` *and* a child window, so AppKit orders it out
    behind this object's back when the app deactivates or the parent is
    miniaturized — and orders it back in on reactivation. Inferring shown-ness from
    visibility lets a `dismiss()` arriving inside that window do nothing at all,
    leaving a live child window AppKit later restores: a stale answer about a buffer
    that has since scrolled, with the pointer nowhere near it. The flag is set in
    `show`, cleared in `dismiss`, and costs exactly what the visibility read did.
    `isReleasedWhenClosed` is cleared because this object owns the panel through a
    strong property and `NSWindow`'s default is to release itself on `close()`. It
    is
    `.transient`, `.ignoresCycle`, excluded from the Windows menu, immovable and
    not restored across launches: a transient annotation of the editor, not a
    window the user owns.
    Drawing is one `NSAttributedString` with **per-segment paragraph styles**,
    because the two kinds want opposite line-breaking: prose wraps (a paragraph is
    meant to be read at whatever width there is) and code truncates (a wrapped
    signature invents indentation the language never had). Code segments use
    `monospacedSystemFont` at the editor's own `SettingsStore.fontSize`, passed
    through untouched — a signature drawn at any other size reads as a different
    file — while prose uses the system font at `InterfaceMetrics.font(.body)`, so
    the two zoom zones stay independent *inside one popover*, exactly as they do
    everywhere else. When Core says the content was cut, a trailing ellipsis line
    is appended in the prose font. The content is drawn in an `NSTextField` label
    rather than a text view: it draws an attributed string, measures itself, and —
    being non-editable and non-selectable — carries none of a text view's input
    machinery into a window that ignores mouse events anyway.
    `maximumWidth` (520 pt, interface-scaled) is a **cap rather than a fit**: a
    one-line generic signature can be hundreds of characters wide, and a popover as
    wide as the screen is unreadable long before it is informative. The **height is
    capped too**, at the anchor screen's visible frame, and Core's caps do
    not make that redundant: `HoverContent.maximumLineCount` counts *logical* lines
    and prose wraps, so a server that stores a doc comment as a few long unwrapped
    paragraphs passes the cap and still measures taller than the display. (Core's
    `maximumLineLength` is not a substitute either — it exists to bound the *work*
    this measurement does, not the height it reports.) The panel
    draws from the top of its frame down, so an unclamped one is placed with its
    bottom on the screen edge and its **first line — the signature — above the top
    of the screen**, which is precisely the outcome the placement rule below exists
    to avoid. So the answer is cut at the end, which is the end already meant to
    go — but `fitted(_:…)` cuts it **in Core, by line, and never by the frame**.
    Clamping the frame would cut wrapped prose mid-glyph and, because the ellipsis
    is the *last* line of the string, would take the truncation marker with it,
    leaving a popover that looks complete while its tail is gone; the one guarantee
    this feature makes about a long answer is that a cut is *marked*, so the cut has
    to happen where the marker is applied — `HoverContent.truncated(toLineCount:)`,
    the same function that enforces the twenty-line cap. Each pass estimates the
    line count that fits from the ratio the last measurement gave and re-measures
    the string it will actually draw (marker included), so it converges in a couple
    of iterations over at most twenty lines, and is paid only on the overflow path.
    The floor is one line: an answer that overflows even at a single line is a
    screen too short for a popover at all (`minimumHeight`), and the head clipped
    beats nothing. Placement is below the anchor line by default and flipped above it when the popover would
    run off the bottom — a menu's rule, and the one a user reading downward expects
    — but only when the flipped position is genuinely better, since on a screen too
    short either way hanging below at least keeps the first line, which is the
    signature. The horizontal position is **clamped rather than flipped**: a
    popover pushed left to stay on screen still points at the right line, while one
    flipped to the other side of the identifier would not.
    Which screen those two rules measure against is found by **containing the
    anchor's origin, not by intersecting the anchor**, because the anchor is
    routinely *empty*: a server that sent no range leaves the answer on a
    zero-length one (`LSPIntelligenceProvider.anchorRange`'s last resort), and
    `firstRect(forCharacterRange:)` answers a zero-width rect for it —
    `NSRect.intersects` is false whenever either rect is empty, so an intersection
    test would silently fall back to the main screen for exactly those answers and
    clamp the height against one display while anchoring on another. Thin, untested
    view glue; this file owns fonts, padding and geometry, and nothing else.
  - `LSPProcessTransport.swift` — the real `LSPTransport`: one language-server
    process, three pipes, and no opinion whatsoever about what the bytes mean. The
    entire macOS half of the LSP client, written in `GitCLIService`'s idiom for the
    same reason — Core owns framing, correlation, budgets and position mapping and is
    unit-tested without an Xcode installation anywhere in sight, so this file owns
    `Process`, is untested by repository convention, and is kept small enough to read
    in one sitting. **It never interprets a message and never restarts anything**: a
    crashed server is reported by `incomingBytes` *finishing*, and deciding what that
    means (`core-lsp.md`'s D7) is `LSPWorkspace`'s job, the only thing that knows how
    many times it has already happened. **The stream publishes raw chunks, not
    payloads** — `LSPSession` already owns the one `LSPFraming.Decoder`, and a second
    one here would frame already-framed bytes, so `availableData` goes straight
    through, exactly as `LSPTransport` documents. `@unchecked Sendable` over an
    `NSLock` (the `ScriptedLSPTransport` arrangement): `send` comes from the session's
    actor, reads arrive on `FileHandle`'s own queue, and `terminate()` can come from
    either plus `deinit`; the lock is never held across a stream yield or a subprocess
    wait.
    Four things are load-bearing. **`SIGPIPE` would kill the app, not the write.** A
    server that crashes between two `didChange`s leaves a pipe with no reader, and
    the default disposition of `SIGPIPE` terminates the *writing* process — Pisaka.
    The write end is therefore put in `F_SETNOSIGPIPE` mode, per file descriptor
    rather than by ignoring the signal process-wide, so `write(2)` returns `EPIPE`,
    `FileHandle` throws it, and the failure joins the ordinary death path. This is the
    one thing on the whole transport that could take the app down, and it is invisible
    until a server crashes at exactly the wrong moment. **A failed write is reported
    as EOF, because there is nobody to report it to**: `send` returns as soon as the
    bytes are queued (the protocol says so — waiting would park the session's actor
    behind a pipe a busy server has not drained, and a `didChange` carrying a large
    file exceeds the buffer), so a write that fails afterwards finishes the byte
    stream instead of throwing, which is the one signal the session already knows how
    to act on; `notRunning` is thrown only for a send after the transport has stopped.
    **`weak self` in the readability handler is load-bearing twice**: a `FileHandle`
    retains its handler, the handle is retained by the pipe and the pipe by the
    transport, so a strong capture is a cycle — `deinit` would never run and the
    `deinit`-kills-the-process guarantee would silently evaporate — and it also makes
    "a transport nobody references stops reading" true, matching the session's own
    contract. The `terminationHandler` is the backstop for the EOF that never comes (a
    server whose child inherited stdout), which otherwise leaves a crash unnoticed and
    every request falling back until the folder is closed. **stderr is drained and
    discarded**, and draining is not optional: a server that logs steadily would
    otherwise fill the pipe buffer and block *writing a log line*, wedging itself
    behind output nobody reads.
    The environment is inherited wholesale and never *replaced* (`GitCLIService.run`'s
    reasoning: a language server resolves its toolchain, caches and build system out
    of `PATH`/`HOME`/`DEVELOPER_DIR`, and assigning the environment to add one
    variable would take all of that away). A description's
    `LSPServerDescription.environment` is therefore **merged over** the inherited set
    and applied only when it is non-empty, so every server but gopls leaves
    `process.environment` unassigned exactly as before — the inheritance stays the
    real one rather than a copy this process took of it. gopls is the one server that
    needs the overlay, and needs it on the ordinary launch path rather than in some
    corner: it takes no `go` path, resolves the toolchain itself with
    `exec.LookPath("go")` for every `go list`/`go env` it runs, and a Finder-launched
    app inherits `launchd`'s `PATH` (`/usr/bin:/bin:/usr/sbin:/sbin`), which holds
    neither `/usr/local/go/bin` nor Homebrew's prefixes nor any version-manager shim
    directory. Without the overlay it starts cleanly and answers *nothing* — the one
    failure `RoutingIntelligenceProvider` cannot see, since an empty answer and a file
    that declares nothing are the same value at that seam — while Settings reports the
    server installed. `stop()` is idempotent: stop reading, close
    stdin — which gives a server that reads to EOF a chance to exit on its own, as
    sourcekit-lsp does — `SIGTERM`, then `SIGKILL` after a 2 s grace.
    **The stdin close goes through the write queue**, not the calling
    thread: `send` only *queues* a write, and `LSPSession.shutdown()` queues the
    `exit` notification and then calls `terminate()` in the same turn, so closing the
    descriptor directly would race that write and usually win — dropping, on the
    ordinary quit path, the one notification that lets a server end with status 0.
    The signals are unaffected; they are sent immediately either way. Reaping runs on a *concurrent*
    reap queue, so two servers torn down on a folder switch do not wait for each
    other. `pid > 0` guards the one genuinely dangerous mistake here: `kill(0, …)`
    signals the whole process group, i.e. Pisaka itself — the same check
    `TerminalSession.terminate()` makes. `make(for:root:)` is what
    `LSPWorkspace.transportFactory` is handed, and it **throws** rather than returning
    `nil` when the executable cannot be found, because the workspace already treats a
    throwing factory exactly like a crash — one spent restart, then silence — and a
    machine with no Xcode must not retry a process launch once per keystroke. It also
    **never waits for the toolchain lookup**: a tool nothing has resolved yet throws
    `notReady`, which costs no restart budget, rather than stalling the main thread
    inside the launch turn (`LSPToolchain`).
  - `LSPToolchain.swift` — where a language server's executable actually is on
    *this* machine, in exactly one shell-out: `xcrun --find <name>`. Resolution is the
    app's job because Core cannot run `xcrun` (D9), and hard-coding
    `/Applications/Xcode.app/…/sourcekit-lsp` would break the moment someone runs
    `xcode-select`, installs a beta alongside a release, or exports `DEVELOPER_DIR`.
    **Nothing is bundled and nothing is downloaded**: no Xcode means `xcrun --find`
    answers nothing, this answers `.missing`, the transport factory throws
    `launchFailed`,
    and `LSPWorkspace` spends one restart on it — which is why the answer is cached
    **including the negative one** (`[String: String?]`, so a recorded "not found" is
    distinguishable from "not looked up yet"), or a machine with no toolchain would
    fork `xcrun` once per keystroke forever. The cache is per app run, not per folder:
    `DEVELOPER_DIR` is read from the environment the app was launched with and cannot
    change under a running process, so someone who runs `xcode-select` mid-session
    gets the old toolchain until the next launch — stated rather than papered over,
    since the alternative is invalidation logic for an event nobody has ever hit.
    **Nothing here blocks its caller**, and that is the whole shape of the API: the
    one caller is a `@MainActor` transport factory called inside the launch turn, so
    a `waitUntilExit` reachable from there is a main-thread stall of however long a
    cold `xcrun` takes — the one thing D7's "answer from tree-sitter and start the
    server behind it" arrangement exists to prevent. `resolution(for:)` therefore
    answers only from what is already recorded, and a tool nobody has looked up yet
    is `.pending`: the factory throws `LSPTransportError.notReady`, that request falls
    back, **no restart budget is spent** (nothing was attempted), and the background
    lookup this starts makes every later request a dictionary hit. `prewarm(_:)` runs
    the same lookups at app startup, so in practice `.pending` is only ever reached by
    a request that beat it; `startResolution(of:)` de-duplicates in-flight lookups, so
    a request racing the prewarm joins it instead of forking a second `xcrun`.
    `.executable(path:)`
    is checked for existence and the executable bit here rather than being handed to
    `Process` to fail on, so both launch kinds report "not on this machine" the same
    way and the workspace sees one failure shape. Run through `/usr/bin/xcrun`
    directly rather than `/usr/bin/env xcrun`, because this is a fixed system path and
    going through `env` would let a `PATH` entry decide which `xcrun` resolves the
    toolchain; the environment is inherited untouched, which is precisely how
    `DEVELOPER_DIR` is honoured — `xcrun` reads it itself. stdin is `/dev/null` and
    both pipes are drained before `waitUntilExit`, for `GitCLIService.runBlocking`'s
    deadlock reason; stderr is captured and dropped, since "unable to find utility" is
    an ordinary answer here and not something to show anyone (D7: no alerts, ever).
  - `LSPGoToolchainService.swift` — the same question as `LSPToolchain` for a
    toolchain `xcrun` knows nothing about, plus the one thing this app ever
    *builds*: where `go` and `gopls` are on **this** Mac (D18), and what
    `go install` means here (D20). Both Core seams
    (`LSPGoToolchainDiscovering`, `LSPGoModuleInstalling`) are implemented in one
    file, unlike 2b's `LSPDownloadService`/`LSPArchiveUnpacker` pair, because they
    are not two technologies — both are "run the user's `go` and read what it
    says", and splitting them would duplicate the process plumbing to keep two
    short functions apart. Untested by convention, like every seam of this shape,
    so it is kept to the decisions it actually makes.
    **The search order is the decision.** The inherited `PATH` first, because a
    Pisaka started from a terminal should use the `go` that terminal would have
    run; then three well-known directories (`/usr/local/go/bin` and Homebrew's two
    prefixes — three `stat`s, covering the official installer and both
    architectures), because a Finder-launched app inherits `launchd`'s `PATH` and
    that contains no `go` on any machine; then the **login shell last**, because
    it is the only step that costs a subprocess and the only one that can find a
    version-manager shim (`asdf`, `mise`, `goenv`). It is asked for `$PATH` rather
    than `command -v go`, so a shell *function* named `go` answers with something
    this file then fails to `stat` instead of producing a launch error minutes
    later; `-l` and not `-i`, so the profile files where `PATH` is assembled are
    read and the rc files where a prompt framework might print or block are not.
    That `PATH` is asked for by running **`/usr/bin/env` and reading the `PATH=`
    line**, not by interpolating `"$PATH"`: `$SHELL` is whatever the user chose,
    and in fish `PATH` is a *list* variable whose quoted expansion is
    space-separated, so `printf %s "$PATH"` hands back one string that
    `pathEntries` — which splits on `:`, as `PATH` is defined — reads as a single
    bogus directory. `env` prints the exported environment, where `PATH` is
    colon-separated in every shell. **Every branch reports a `PATH` that contains
    the `go` it found**, and everything that runs a `go` afterwards runs under it:
    this service's own children (`go env` and the install, via `childEnvironment()`)
    and — through `LSPGoToolchainReport.found`'s `searchPath` — the gopls the app
    registers. The login-shell branch reports the shell's `PATH`, and it is the half
    without which *that* step buys nothing: a version-manager `go` is a shim that
    re-execs `asdf`/`mise`/`goenv` off `PATH`, so running it back under launchd's
    four directories fails, `go env` exits non-zero, and the search reports "no
    toolchain" on exactly the machines the step was added for. The well-known-directory
    branch is the one that has to *build* a `PATH` rather than report one — three
    `stat`s found that `go`, not an environment — so it prepends the directory it
    found to the inherited entries (prepended, and the duplicate dropped, so the
    toolchain the report names and the toolchain the server resolves stay the same
    one). Only reporting the login-shell case, as the first cut did, is what left
    every mainstream install — the official `/usr/local/go/bin`, both Homebrew
    prefixes — registering a gopls that could not find a `go`.
    `GOBIN`/`GOPATH` come from `go env` rather than the environment, because both
    can be set by `go env -w`'s config file and `GOPATH` has a default (`~/go`)
    that is never in the environment at all. **A `go` that cannot answer `go env`
    is reported as no toolchain**, not as one with an unknown `GOBIN`: it will not
    build anything either, and reporting it present would offer an Install that
    cannot work. The whole answer is cached per app run **including the negative
    one** (`LSPToolchain`'s discipline and reason), resolved off the main thread,
    and deadlined — 5 s for the login shell, 10 s for `go env` — because on a Mac
    with no Go at all this runs at every launch.
    The install sets two variables — `GOBIN`, pointed at the staging directory the
    model owns, and the `PATH` the toolchain was found under; everything else is
    inherited untouched,
    which is the whole of "nothing global is touched" — nothing is written to the
    user's shell profile and their `GOMODCACHE`,
    `GOPROXY` and proxy settings all keep working. It runs *from* the staging
    tree, which is inside no module, so nothing depends on the app's launch
    directory not being a Go module. Its deadline is 30 minutes: the model keeps
    the row `.installing` and refuses Remove until this returns, so a build that
    never finishes is not a slow install but a dead one for the rest of the app
    run — far above any real duration, and far below "never", which is the only
    number it competes with. The failure sentence a Settings row shows is the last
    **three** lines of stderr rather than one, because `go`'s actual reason is
    regularly the line above the last (`# golang.org/x/tools/gopls` heads a
    block). Both pipes are drained on their own queues before the exit is waited
    for (`GitCLIService.runBlocking`'s deadlock rule, a real volume here rather
    than a theoretical one — `go build` writes a line per package), stdin is
    `/dev/null`, and teardown is `SIGTERM`→`SIGKILL`.
    **Every child is registered, not just the install's**, so `terminateNow()`
    ends a login shell mid-`PATH`-print as well as a build; the app's terminate
    observer calls it beside `LSPWorkspace.terminateNow()`. It is idempotent and
    **permanent** — a torn-down service refuses to launch anything else — which
    closes the window between the observer firing and a `.go` tab open landing on
    `prepareForOpening`. `ChildProcess.adopt` closes the window *before* the
    `Process` exists, and `wasCancelled` is re-checked **after** `run()` to close
    the one between them: a `cancel()` landing there finds a process that has not
    started, returns without signalling, and the next statement launches it — the
    exact window a quit during a first-launch build falls into, and one
    `terminateNow()` cannot repair afterwards because it has already emptied the
    registry. **Teardown signals the child's process group, not its pid**, and that
    is the one place this departs from `LSPProcessTransport.stop()`: a language
    server is one process, while a `go` compiling gopls is a parent with a compiler
    and a linker beneath it, and Unix does not end a child when its parent dies —
    `terminate()`/`kill(pid, …)` alone would leave that tree re-parented to
    `launchd`, still compiling and still writing into the user's build cache after
    the app quit, which a `pgrep -f 'gopls|go install'` would not even show. The
    negative pid is safe because Foundation launches every child as its own
    process-group leader, and it is checked (`getpgid(pid) == pid`) rather than
    assumed, so a Foundation that stopped doing that narrows the signal back to the
    single process instead of widening it to a group containing Pisaka. The group
    `SIGKILL` is sent whether or not the parent missed its grace period, because a
    `go` that honoured `SIGTERM` promptly still leaves behind what it had already
    spawned. The release check (`pgrep -f 'gopls|go install'` empty after a quit) is
    what all of that is written against.
  - `LSPRustToolchainService.swift` — the same question again for a third
    toolchain: where `cargo` and any existing `rust-analyzer` are on **this** Mac
    (D23). **One seam and no second one**, which is the whole difference from the
    Go file: rust-analyzer publishes official prebuilt binaries, so installing it
    is `LSPInstallEngine.install(_:)` over the pinned manifest component and the
    download/unpack pair 2b already has (D21), and nothing here installs, downloads
    or writes. It reads directory entries and runs two programs with `--version`.
    Untested by repository convention, like every seam of this shape, so it is kept
    to the decisions it actually makes.
    **The search itself is no longer here.** It was `LSPGoToolchainService
    .locateGo`'s order re-stated a second time, and when `gh` needed the same
    three steps it was lifted verbatim into `ExecutableLocator
    .locate(_:wellKnownDirectories:runningProgram:)` — one answer to "where is a
    program somebody else installed", with `GitHubSourceGatingTests` counting its
    definitions and its callers (`core-github.md`). What stays in this file is
    which directories are well-known (`wellKnownCargoDirectories`), the
    `--version` probes below, and the fact that the locator's one subprocess runs
    through *this service's* registered, deadlined `run` — so a quit during
    discovery leaves no login shell behind. The order it applies, and why: the
    inherited `PATH` first
    (a Pisaka started from a terminal should use the `cargo` that terminal would
    have run); then `~/.cargo/bin` and Homebrew's two prefixes — `~/.cargo/bin`
    leading, because rustup puts both `cargo` and the `rust-analyzer` proxy there
    and rustup is how nearly everyone has Rust, which is why the common case (a
    rustup user who already has rust-analyzer) costs no subprocess at all; then the
    **login shell last**, asked for `$PATH` rather than `command -v`, because it is
    the only step that costs a subprocess and the only one that can find a
    version-manager shim. Every branch reports a `PATH` that contains the `cargo`
    it found, the well-known-directory branch building one by prepending the
    directory it found (`ExecutableLocator.Found` carries both halves, which is
    the reason it is a pair rather than a path) — that `PATH` is what Core hands
    the server as its
    `environment` overlay (D23), and rust-analyzer resolves `cargo` by name off
    `PATH` exactly as gopls resolves `go`, so a `searchPath` that merely said "the
    app's own environment was enough to *find* it" would be true and useless.
    **A `cargo` that cannot answer `cargo --version` is reported as no toolchain**,
    for the `go env` rule's reason: the one thing this report decides is whether
    rust-analyzer may be offered and run, and reporting a broken one present would
    offer a 13 MB download that installs a server answering nothing. **The probe is
    applied to a discovered rust-analyzer too**, and that is this file's own
    finding rather than symmetry: rustup installs a `rust-analyzer` *proxy* into
    `~/.cargo/bin` whether or not the component behind it was ever added, so on the
    single most common Rust setup an unprobed search finds an executable file that
    exits non-zero with "not installed for the toolchain" the instant anything asks
    it anything — a Settings row reading "installed (found on this Mac)" over Rust
    files silently answering from the tree-sitter index. Both probes run under the
    `PATH` that found the `cargo` and inherit everything else (`RUSTUP_HOME`,
    `CARGO_HOME`, `RUSTUP_TOOLCHAIN`, proxy settings), so the probe's answer is the
    answer for the real thing rather than for a program run in an environment
    nothing else uses. The cost is one subprocess, and only on machines that have a
    candidate.
    **And because that dead proxy is the common candidate rather than an exotic
    one, a rust-analyzer that fails the probe is stepped over rather than ending
    the search**: `locateRustAnalyzer` walks *every* executable of that name on the
    list (`ExecutableLocator.executables(named:in:)`, de-duplicated there so the
    same file is never probed twice) and takes the first that answers. Stopping at the first executable file
    would hide a working Homebrew rust-analyzer behind a rustup proxy whose
    component was never added, and offer a download of a server the machine already
    has. `cargo` deliberately does *not* do this: the server resolves `cargo` by
    name off the same `PATH`, so the first one there is the one that will run
    either way, and reporting no toolchain is the honest answer for that
    environment — whereas a rust-analyzer path is handed to `.executable(path:)`
    directly, which makes picking a later one a decision this app is free to make.
    The whole answer is cached per app run **including the negative one**
    (`LSPToolchain`'s discipline and reason, with more force: this runs at every
    launch of every Mac that has no Rust, which is most of them), held as a `Task`
    so two callers arriving before the first answer await one search, resolved off
    the main thread on its own queue, and deadlined — 5 s for the login shell, 10 s
    for a `--version`. A timeout is not an error here; it is one more way of
    finding no toolchain.
    **Every child is registered**, so `terminateNow()` leaves no login shell
    behind, and cancellation is what that registry is really for here: the login
    shell is the only child that can outlive a quit, since a profile slow enough to
    hang is exactly why it has a deadline. A child killed by `cancel()` throws
    `.cancelled` rather than reporting its non-zero status, so a quit cannot become
    a cached "no Rust toolchain" for a run that no longer exists.
  - `DefinitionPicker.swift` — the "which one did you mean?" surface of Go to
    Definition: an `NSMenu` popped up under the identifier, one item per candidate
    (plan Decision 3). A menu rather than a custom `NSPanel` because AppKit gives
    arrow-key navigation, type-select, Esc dismissal and screen-edge flipping for
    free, with no window controller to own, position or tear down across a tab
    switch; the cosmetic price is that a row is one string, which is exactly what
    `DefinitionCandidate.displayLabel` is for, so both platforms show the same text
    and this file decides nothing about it. `autoenablesItems = false` because the
    items are model-driven — without it AppKit would ask a validator that does not
    exist and grey every row out. The anchor is the bottom-left of the identifier's
    glyph bounds, asked of the layout manager (rather than
    `firstRect(forCharacterRange:)`, which answers in *screen* coordinates and would
    have to be converted back) and offset by the text container's origin, which is
    non-zero here because the gutter is a ruler view; the range is clamped first,
    since it was computed against the buffer as it was when the question was asked.
    The action receiver is held across the modal call with `withExtendedLifetime`,
    and that is mandatory rather than defensive: `NSMenuItem.target` is a *weak*
    reference, and ARC may release a local at its last use — which here is the
    assignment inside the item loop, before `popUp(positioning:at:in:)` is even
    called. An optimized build could therefore show a menu whose every row points
    at a deallocated target and silently does nothing when chosen. Wrapping the
    modal call (it tracks modally and returns only once the menu is gone) is what
    keeps the target alive for exactly as long as it can be messaged.
  - `FoldController.swift` (macOS) — the editor's fold owner: it asks the
    intelligence seam where the shown file's collapsible blocks are, holds the
    answer and what is folded of it, and pushes both halves at the two views that
    draw them — the layout manager (which hides the text) and the gutter (which
    draws the chevrons and skips the hidden lines). Every *decision* it wires is
    pure and lives in Core (`core-folding.md`); this class owns only the
    scheduling, the AppKit references and the invalidations, so it is thin
    view-layer code, untested like the rest of `Sources/Pisaka` and pinned by
    `FoldingSourceGatingTests`.
    **Shaped like `BracketHighlightController`**: a cancellable debounce task plus a
    monotonic generation token captured *synchronously* before the hop, so an answer
    a tab switch or a further edit superseded discards itself instead of drawing the
    previous file's chevrons — and the memory key is compared too, so an answer
    cannot land on a file it was not asked about even if the counter happened to
    agree. The debounce is **400 ms and its own**, not a chain onto
    `LSPDocumentSyncController`: document sync for this question is request-driven
    (D2 — the live buffer travels with the request through `LSPWorkspace.prepare`),
    so there is nothing to wait for and one fewer coupling to maintain.
    **Between two answers the candidates are shifted, never re-asked**: one edit runs
    both the candidate list and the folded state through `FoldShift`, so a chevron
    stays beside the block it names while the user types above it instead of blinking
    out on every keystroke; a fresh answer replaces the candidates wholesale and is
    reconciled with the folded state by header line. Every write funnels through
    `apply(_:)`, whose one `publish()` tells the layout manager, the ruler and the
    memory together — three call sites would let the chevrons, the hidden glyphs and
    the remembered state fall one frame apart, and both views treat unchanged input
    as a no-op so it is cheap to call unconditionally. `fold(_:)`/`unfold(_:)` exist
    beside `toggleFold(_:)` because *Fold* on an already-folded block must leave it
    folded rather than spring it open, which a toggle would do the moment the command
    is held down. `remap(through:)` moves the bounds through a save's plan (never
    `FoldShift` — see `core-editorconfig.md`). The layout manager is resolved
    dynamically for `BracketHighlightController`'s reason: `replaceLayoutManager` can
    swap it under the text view, and a stale reference would hide text in a manager
    nothing draws from. **A reader**: it takes no writer gate, is gated by none,
    writes no file, registers no edit and never touches the text storage — and
    nothing it holds is persisted, the fold memory dying with the app run.
  - `FoldCommands.swift` (macOS) — the Edit menu's *Fold* (⌘⌥←) and *Unfold*
    (⌘⌥→), in a `CommandGroup(after: .pasteboard)` beside Toggle Comment. **The
    whole menu surface of folding is this file**, and `PisakaApp` names the type
    exactly once. The items carry no state: like ⌘D and Toggle Comment they reach
    whatever editor holds the focus through the **first responder**
    (`NSApp.keyWindow?.firstResponder as? EditorTextView`, plus `isEditable` and
    `!hasMarkedText()` — a read-only viewer is not this command's editor, and a
    keystroke arriving mid-composition belongs to the input method), which is the
    only honest answer with several windows open or the terminal focused. **One
    beep, two reasons**: a focus that is not an editor and an editor answering
    `false` (no collapsible block at the caret, no folded block at the caret, or a
    selection reaching past the block) are the same event to the person pressing the
    key — nothing happened. Which block a press acts on is `FoldCommandRule`'s
    decision and is made in Core.
  - `EditorSearchState.swift` — the find/replace bar's observable state (macOS):
    `isVisible`, `isReplaceExpanded`, `pattern`, `template`, the three toggles
    (`caseSensitive`/`wholeWord`/`isRegex`), the published-back `matchCount`/
    `currentIndex`/`errorText`, a monotonic `focusRequest` token, and the commands
    `open()` (⌘F — shows *and* bumps `focusRequest`, so a repeat press re-focuses
    and selects rather than doing nothing), `openReplace()` (⌘⌥F), and `close()`
    (Esc). **Window-scoped and owned by `PisakaApp`, not by the editor**: the bar's
    contents and toggles survive a tab switch (JetBrains/VS Code behavior), so the
    state cannot live in `CodeEditorView`'s coordinator, which is rebuilt with the
    view. It holds no `NSTextView`, no ranges and no engine call — everything
    *executed* goes through the `EditorSearchActions` protocol
    (`findNext`/`findPrevious`/`replaceCurrent`/`replaceAll`/`clearHighlight`),
    whose sole conformer is the controller and which is held **weakly**: the
    coordinator owns the controller for the lifetime of the text view while the
    state outlives every tab, so a strong reference would pin a torn-down editor.
    `unregister` only clears the reference when it is still the registered one, so a
    torn-down editor cannot unregister the editor that replaced it, and `close()`
    tells the controller directly rather than waiting for a SwiftUI pass (there may
    be no editor update scheduled; the controller's own `isVisible` check keeps both
    paths idempotent). `updateResults` drops unchanged values — the controller
    re-runs on every keystroke and every editor update, and each `@Published` write
    invalidates `ContentView` → `updateNSView` → another refresh, so skipping the
    no-op write is what makes that loop settle after one pass.
  - `EditorSearchController.swift` — the execution side of the find bar: it runs
    `TextSearchEngine` against the live buffer, keeps the current match near the
    caret (`currentIndex(forCaretAt:in:)` from the selection — the *current-match*
    resolver, deliberately not the `index(nearestTo:in:forward:)` navigation one,
    whose zero-length exclusion would make Replace edit the match after the
    selected one; so an edit, a toggle
    or a widened pattern leaves the user looking at the same place in the file) —
    including on a **plain caret move**, via `selectionChanged()` wired into the
    coordinator's `textViewDidChangeSelection` beside
    `BracketHighlightController.updateSelection`. That one is not cosmetic:
    `replaceCurrent()` re-runs first and `run(query:)` re-derives `currentIndex`
    from the live caret, so without it a click elsewhere in the file would leave
    the `n/m` counter and the orange current-match highlight naming the match the
    last run chose while Replace edited whichever match the caret had since moved
    to — an edit landing where the user was not looking. It re-derives from the
    existing match list with **no re-scan** (a caret move changes nothing the scan
    depends on), drops an unchanged index, and is skipped while `isApplyingEdit`
    is set (mid-edit the list is stale and both callers re-run right after),
    pushes ranges into `BracketOverlayLayoutManager.setSearchRanges(_:current:)` —
    **the on-screen ones only**, `BracketHighlightController.refreshVisible()`'s
    rule and for a sharper reason. The *scan* is whole-buffer (the `n/m` counter
    and ⌘G's wraparound both need every match), but each painted range costs an
    `addTemporaryAttributes` call, and a one-character query in a megabyte-scale
    file matches six figures of times: pushing the whole list measured at ~230 ms
    per repaint for 180 000 matches in a 1.1 MB buffer, paid on *every* keystroke
    in the bar and again on every caret move that changes the bracket pair (since
    `setPairRanges` repaints the same backgrounds) — so the un-clipped version
    failed the "typing in a large file with the bar open stays responsive"
    criterion outright, and for an ordinary literal query rather than for the
    heavy regex the no-debounce note below records as the headroom. So
    `applyHighlight` binary-searches the match array down to the visible character
    range (matching on "ends after the range start", so a match straddling the top
    edge is included) and hands over that slice plus the current match, which is
    passed separately and deliberately *not* clipped — navigation scrolls it into
    view before repainting, and the layout manager paints a `current` outside the
    set on top regardless. `refreshVisibleHighlight()` re-pushes on scroll and
    resize with no re-scan (wired into the coordinator's `clipViewBoundsChanged`
    /`syncableFrameChanged` beside `bracketHighlight.refreshVisible()`), which is
    what paints newly revealed matches. It also
    navigates — resolving which match ⌘G means (the selection's *end* going forward
    and its *start* going back, so it steps off the current match in both
    directions) and handing that range to the coordinator's `revealRange` funnel,
    which unfolds what the range reaches, selects and scrolls. The controller
    itself neither selects nor scrolls any more, and an unhooked one navigates to
    nothing; the two `setSelectedRange` calls left in the replace commands are
    caret placements after an edit, not jumps (`core-folding.md`) —
    and applies the two replace commands. `replaceCurrent`
    re-runs first (results may pre-date an edit, and replacing a stale range would
    overwrite text the user never matched), then does one
    `insertText(_:replacementRange:)` under `isApplyingEdit` — one ordinary undo
    step — and advances; `replaceAll` walks `replacePlan`'s strictly last-to-first
    edits against an in-memory `NSMutableString` of the *spanned* range and
    installs the whole batch with **one** `insertText(_:replacementRange:)`
    (inside a `beginUndoGrouping`/`endUndoGrouping` pair on the *per-file* undo
    manager, so **one ⌘Z reverses the whole replacement** and the edit can't
    coalesce into the user's preceding typing). Applying the plan edit-by-edit
    *through the text view* would instead cost a full TextKit cycle per match — a
    storage tail memmove, an undo registration, the gutter's `LineStartIndex
    .updated` suffix shift, `BracketHighlightController.noteEdit`'s token trim —
    i.e. O(buffer × matches) on the main thread with **nothing capping the match
    count** (unlike the project search's 10 000), so the same one-character query
    in a megabyte-scale file that forces the visible-only highlight rule above
    would hang the app for minutes with no way to cancel. The replaced range is
    the span from the first replacement to the last rather than the whole
    document, so a few clustered matches still cost a small edit and only a
    file-spanning batch relayouts everything; the caret is left just past the
    first (document-order) replacement, where the per-edit walk left it. Counters
    are published through `DispatchQueue.main.async` because the common caller is a
    refresh driven by `updateNSView`, i.e. from within a SwiftUI view update, where
    a direct `@Published` write draws the "Publishing changes from within view
    updates" warning and can re-enter the update. `setNeedsRefresh()` coalesces the
    text-edit trigger onto the next main-loop turn: that notification fires *before*
    the storage notifies its layout managers, so painting fresh post-edit
    backgrounds inside it would have them shifted straight off their characters —
    the mirror image of the pre-edit coordinate problem `clearBackgrounds` documents
    — and it is explicitly *not* a debounce (no timer, the re-run still lands in the
    same run-loop iteration, before anything is drawn). **The no-debounce decision
    is recorded in the type's doc comment as deliberate, not an oversight**: the
    search re-runs *synchronously* on every field/toggle change and every text edit,
    unlike `MinimapTokenizer` and `BracketHighlightController` which both debounce,
    because the work is one `NSString.range(of:options:range:)` pass over a single
    open file — a memory scan, cheap enough per keystroke that coalescing would buy
    nothing while costing the bar its immediacy (a counter that lags the field reads
    as broken). The **known headroom** is a heavy regular expression (catastrophic
    backtracking, or simply an expensive pattern) over a megabyte-scale file; if it
    is ever reported the fix is the `MinimapTokenizer` shape — a short debounce plus
    a monotonic generation token so a superseded run discards itself — and it is
    deliberately not pre-built, because that debounce would otherwise be paid by
    every ordinary literal search. Contrast `ProjectSearchView`, which *is*
    debounced (~300 ms) for the opposite reason: one keystroke there costs a whole
    directory traversal plus a read of every surviving file.
  - `SearchBarView.swift` — the bar itself (macOS, thin): the query field, the
    `Aa`/`ab`/`.*` toggles, a `3/17` counter (blanked on error, and on a *trimmed*
    empty field — `TextSearchEngine` throws `.emptyPattern` for a whitespace-only
    pattern too, so no search ran and "No results" would state an answer nothing
    computed), ▲/▼ prev/next, a
    button expanding the replace row (replace field + `Replace` / `Replace All`),
    and red reason text on an `.invalidRegex`. `.onSubmit` → next, `.onExitCommand`
    → `search.close()`, and a `@FocusState` driven by `focusRequest` with a field-
    editor select-all so a repeated ⌘F focuses the field with its text selected.
    That select-all resolves the field editor through **this bar's own window**
    (captured by a small private `WindowAccessor` `NSViewRepresentable`, since
    SwiftUI exposes no window on macOS 13) and only while that window is key —
    *not* through `NSApp.keyWindow`. ⌘F is an app-wide `CommandMenu` item, so it
    fires with the Find in Files window key too, and that window's shared field
    editor is an `NSTextView` with `isFieldEditor == true`: a key-window read
    passes the guard and selects the *project-search* query instead, where the
    user's next keystroke silently replaces the whole thing. Doing nothing in
    that case is the right answer — the bar still opens and asks for focus, it
    just does not reach into a window it does not own. (The `isFieldEditor` check
    remains, and remains load-bearing for its own separate reason: the deferred
    block is not ordered after SwiftUI's focus pass, so the responder it finds may
    still be the code editor's `NSTextView`, where `selectAll` would select the
    whole document.)
  - `EditorRevealState.swift` — a one-shot "show me *this* range of *this* tab"
    request, produced when a Find in Files result row is activated. Window-scoped
    and owned by `PisakaApp` for the same reason as `EditorSearchState`: activating
    a match may **open** the file, so the request has to be recorded before the
    `CodeEditorView` that will honour it exists. `Request` carries `fileID`, `range`
    and a monotonic `token`; the editor records the token it last applied, so a view
    update triggered by anything else (a keystroke, a font change) does not
    re-select the range and yank the caret back.
  - `ProjectSearchView.swift` — the Find in Files window's contents (⌘⇧F): the
    query field + `Aa`/`ab`/`.*` toggles + file-mask field + Find/Replace switch
    (with the replace field), results grouped by file with per-match preview lines
    (the match highlighted inside the clipped line `MatchPreview` carries), a
    "results truncated" note at the cap, `.preferredColorScheme` and the shared
    `SettingsStore` font as in the diff/merge windows. Thin and untested: every
    decision — which files are walked, what matches, what a replacement expands to,
    which files a batch skipped — belongs to `ProjectSearchModel`, and activation
    plus Replace All are handed back to `PisakaApp` through closures (the app owns
    the open-file path and the disk-writer coordination, neither of which a view may
    reach into). The `root` is a *closure* read at search time, not a captured
    value, because the window outlives a folder switch. The search is **debounced by
    `searchDebounceDelay` (0.3 s)** — the deliberate opposite of the editor bar's
    no-debounce decision, and required because one keystroke here costs a traversal
    plus a read of every surviving file — with the pending dispatch owned by a
    `@StateObject SearchDebounce` so the timer survives the view struct being
    rebuilt on every keystroke, and the model's generation token superseding
    whatever the debounce still let through (pinned synchronously before the `Task`
    hop, the `LocalChangesModel` rule). That delay is also why nothing *acts* on
    the rows while they are stale: a computed `resultsMatchControls`
    (`model.query`/`fileMask` — recorded at the *start* of a search, having just
    cleared `results`, so a run still streaming its rows already reads as current —
    against the query the controls describe) is false for the whole window between
    a keystroke and its search reaching the model, and it both disables Replace All
    and makes Enter dispatch the pending search instead of activating a result.
    Without it "type and press Enter" opens a hit from the *previous* query, and a
    Replace All clicked in that window rewrites the project for it — the
    confirmation names counts, not the pattern, so nothing would give the mistake
    away. The same predicate decides what the empty-results placeholder is allowed
    to *say*: "No results" is an **answer**, so it is only shown once the empty
    list is one this project's own controls produced, and otherwise the
    placeholder reads "Press Return to search." That covers both states where no
    search has run — inside the debounce window, and after a folder switch, where
    `prepareForSearch` cleared the previous project's rows (and, with them, the
    query that produced them, which is what makes `resultsMatchControls` false
    here at all rather than leaving the window claiming an answer for a project it
    never walked). Replace All confirms through an `NSAlert`
    naming the file/match counts — and, when `model.truncated`, saying so: the
    batch replaces exactly the captured matches, so at the cap it leaves the rest
    of the project half-replaced, and the confirmation is the only point where
    that can still be declined (neither `results` nor `ReplaceSummary` carries a
    truncation signal, so afterwards a partial batch reads as complete). It then
    shows the summary and re-searches
    automatically (`results` describes pre-replacement text by construction).
  - `ProjectSearchWindowController.swift` — owns the single, non-modal Find in
    Files window: the `DiffWindowController` shape (a retained `EscClosableWindow`
    hosting a SwiftUI root through an `NSHostingController`, released on close by a
    per-window delegate held alongside, since `NSWindow.delegate` is `weak`) with
    one deliberate difference — there is exactly **one** window. A diff is *about* a
    file, so several make sense; a project search is about the project, so a repeat
    ⌘⇧F focuses the existing window rather than stacking duplicates over one shared
    `ProjectSearchModel` (two windows would fight over its single query and result
    list). An existing window has its root view *replaced* rather than reused, so a
    window left open across a folder switch picks the new root up on the next ⌘⇧F.
    `closeAll()` is wired into the app's `willTerminateNotification` observer
    alongside the diff/merge controllers.
