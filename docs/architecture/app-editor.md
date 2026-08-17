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
    (`inferIndentUnit`) and the edit (`newlineIndentation`), inserts it via
    `insertText(_:replacementRange:)`, moves the caret to `location +
    cursorOffset`, and returns `true` to suppress the default. On a closing
    bracket, `textView(_:shouldChangeTextIn:replacementString:)` detects a single
    `}`/`)`/`]` on a whitespace-only line prefix and, via `dedentOnClosing`,
    rewrites the leading-whitespace range and the bracket together in one
    `insertText(_:replacementRange:)` (one undoable edit), returning `false` to
    suppress the default insertion (mutating and returning `true` would proceed
    against a now-stale `affectedCharRange`). All programmatic edits go through
    `insertText(_:replacementRange:)` so the per-file undo manager records them as
    ordinary single-step-undoable edits. The one edit that *cannot* go through it
    is `updateNSView`'s wholesale `textView.string = text` swap, which is why that
    branch clears the file's undo stack (`textView.undoManager?.removeAllActions()`)
    whenever the contents were replaced **without** a tab switch — a project-wide
    Replace All landing in an open tab (`ProjectSearchModel.replaceAll` →
    `applyBufferText` → `WorkspaceModel.replaceText`), a post-revert
    `reloadFromDisk`, or a merge apply. Assigning `string` registers no undo action
    of its own, yet every action already recorded names a range in the *pre-swap*
    text, so a following ⌘Z would replay an unrelated older edit at coordinates the
    new contents no longer share: silently corrupting the buffer when the range
    still fits, and raising an out-of-range exception from the text storage when
    the new text is shorter. A *tab switch* is deliberately excluded — there the
    incoming file's own manager is installed alongside its own contents, the very
    pairing the per-file managers exist to preserve — **unless that file's buffer
    was replaced while it sat off screen**, which is not a corner case but the
    ordinary shape of all three replacements above: each reaches *every* matching
    open tab, not just the displayed one, and a background tab gets no
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
    placed a caret in a name or double-clicked it; and `mouseDown(with:)` claims
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
    `textStorage.length`, applies `setSelectedRange` and scrolls through the
    existing `scrollEditor(to:)` — which already clamps a document-space top offset
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
    apply), the recorded selection and anchor name characters the incoming text
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
    Four of the popover's dismissal triggers are observations this file already
    owned, and each is dismissed at the existing call site rather than by a second
    observer: the text storage's `didProcessEditing` (any edit — programmatic ones
    included, which is why it is the storage's notification and not
    `textDidChange`), `textViewDidChangeSelection`, the clip view's
    `boundsDidChangeNotification` (a scroll moves the text out from under a
    popover anchored in *screen* coordinates — reusing the observation the minimap
    already installs, because two observers of one notification eventually
    disagree about what a scroll is), and the buffer-swap branch of `updateNSView`,
    which invalidates a popover describing an offset in the text it just replaced.
    `teardown` calls `hover.reset()` beside `completion.reset()`, so a closed tab
    cannot leave a floating annotation of its file on screen.
  - `CompletionController.swift` — feeds AppKit's built-in completion popup from
    the *asynchronous* code-intelligence seam. **The whole problem it exists to
    solve is a mismatch of shapes:**
    `textView(_:completions:forPartialWordRange:indexOfSelectedItem:)` is
    synchronous — AppKit asks for the list while it is already putting the popup on
    screen — while `CodeIntelligenceProviding` is async, because a phase-2 LSP
    provider has to await a socket. So the work is inverted: candidates are computed
    ahead of time behind a debounce, stored *together with the prefix they answer*,
    and only then is the text view asked to `complete(nil)`; the delegate call that
    follows touches nothing asynchronous. Nothing about the seam is compromised —
    the provider is still awaited, one turn earlier than AppKit would like. Storing
    the prefix with the items is the only thing that makes an asynchronously-computed
    list safe to hand to a synchronous delegate: by the time AppKit asks, the user
    may have typed another character, and offering completions for the previous word
    is worse than offering none, so a mismatch returns `[]` — not an error but the
    ordinary "typed one more character" state, which dismisses the popup until the
    debounce fires again with a list that does match. The requested range is
    validated against the live buffer before it is read, since a session that
    outlived a shrinking edit would otherwise index out of bounds. Debounce (150 ms,
    the minimap tokenizer's rather than the index's 400 ms — this asks a question of
    a snapshot already in memory, so the cost is a prefix scan and a sort) and a
    monotonic generation token follow the `BracketHighlightController` idiom.
    `update(provider:fileURL:language:explicit:)` builds the request on the main
    actor from
    the live buffer — the text goes *into* the request rather than being read after
    the hop, so the harvested words are the ones on screen when the user paused —
    and refuses in three cases: marked text (uncommitted IME input, the ⌘D guard's
    reasoning), a non-empty selection (about to be replaced, not extended), and a
    prefix under two characters. That minimum is the single most-complained-of
    behavior of as-you-type completion, so `explicit` (⌃Space / the menu item)
    bypasses both it and the debounce — the user asked. `language` is threaded
    through from the coordinator for the keyword source and nothing else; `nil` (an
    unclassifiable buffer) means no keywords rather than some default language's.
    **Two triggers, not one.** The second is a *member position* —
    `IdentifierScanner.memberContext(in:at:)` non-`nil`, i.e. a caret after
    `receiver.` — asked **before** the length gate and bypassing it entirely,
    because the `.` is itself the request and waiting for two more characters would
    defeat the point; the member context's own `prefixRange` is what the request
    carries, so it and `completionPrefixRange` agree by construction rather than by
    a second scan. A snapshot's prefix may therefore be the **empty string**, and
    both places that re-check a snapshot are written to survive that. `apply` re-reads
    the caret
    *after* the await (a click, an arrow key or an undo during the debounce moves
    the popup's anchor to a word these items do not answer), opens nothing on an
    empty result (an empty popup is strictly worse than no popup), and requires the
    text view to still be the window's first responder, or `complete(nil)` would put
    a floating list over whatever the user *is* typing in. Dropping the old
    `range.length > 0` re-check was not enough on its own, and the extra condition
    is load-bearing: an empty prefix compares **equal** to the (also empty) partial
    word at a caret sitting in open space, after a `(`, or at the start of a line,
    so the ordinary "is this still the word these items answer" test passes
    everywhere and a member list would survive exactly the caret move it exists to
    catch. Both re-checks therefore additionally demand that the caret still be in
    the **same member state** the items were computed for — the same receiver, or
    no member position on either side — and they demand it at **every** prefix
    length rather than only at zero. The empty prefix is only the loudest case: a
    member list and an ordinary list answer the same characters with different
    candidate *sets* (no keywords, no non-member symbols after a dot), so
    `worker.na`'s member-only list is just as wrong served over an unrelated `na`
    as the bare dot's list is served in open space. The comparison is
    `memberContext(…).map(\.receiver)` on both sides rather than `?.receiver`: the
    receiver is itself optional — a bracketed one (`f().`) names no type — and
    optional chaining would flatten "not a member position" into "a member position
    with an unnamed receiver" and let the two serve each other's lists. Only the
    receiver is compared, not the whole `MemberContext` carried on `Snapshot`; its
    `prefixRange` is position-dependent by construction. The *serving* side
    (`completions(forPartialWordRange:in:)`) is where this matters most: ⌥⎋/F5
    reaches the delegate **without** going through `update(…)`, and a caret move
    alone never refreshes the snapshot, so the weaker test would hand `Worker.`'s
    member list to a caret since moved after `other.`, and a stock ⌥⎋ in open space
    the previous dot's members. `rangeForUserCompletion`, `insertCompletion` and the
    programmatic-edit bracket are untouched: an empty range at the caret is already
    the correct insertion range for a member completion. Thin glue otherwise:
    `IdentifierScanner` says what is being typed and `SymbolIntelligenceProvider`
    ranks and caps the answers, so this class decides only *when* to ask and whether
    the answer is still current.
    **Phase 2a: the list is strings, but the answers are items.** AppKit's popup
    shows strings and hands one back when a row is committed, while an LSP answer is
    more than its text — it may carry the `import` line that makes the symbol resolve
    (D4). The snapshot therefore keeps whole `CompletionItem`s keyed by the string
    the popup shows (first wins on a duplicate), so
    `insert(_:forPartialWordRange:isFinal:in:)` can find the item behind
    the string. That key is deliberately **not** the provider's: it deduped by the
    *inserted* text, so two items that insert differently but read the same
    survive there and collapse here. This is the one place the popup's list is
    narrower than the provider's answer, and it has to be — a row the user cannot
    tell apart is not a choice. The consequence is a rule rather than a caveat:
    everything else keyed by the same string (`prefetchResolves`, and through it
    `resolved`/`resolveTasks`) is fed from *this* deduped list, never from the
    provider's, so an item the snapshot dropped can never file edits under a
    surviving row's key and have them committed in its place.
    **The string is the item's `displayText`, and it is the key in all three
    tables** — the snapshot (`texts`/`items`), the prefetched resolves
    (`resolved`/`resolveTasks`) and `scheduleFollowUp`'s `word`. It has to be:
    AppKit hands a committed row back *by string*, so keying by anything the popup
    does not show makes the item unfindable. In the follow-up it is doing double
    duty — the resolve key *and* what now literally stands in the buffer after
    AppKit's own insertion, which is exactly what `plan(for:over:replacing:in:)`
    needs. For everything but a member item whose server rewrote the typed dot,
    `displayText` **is** `text`, so this changes nothing on the tree-sitter path.
    Previewing and inserting that string verbatim is safe only because of the
    head-dropping rule Core enforces
    (`CompletionEdit.displayText(forTypedWordStartingAt:in:)`, in `core-lsp.md`):
    it may only drop a head that re-writes what already stands in the buffer, so
    under `greeter.` the row reads `greet` and both the preview and the
    rejected-plan fallback still compose `greeter.greet`. The counter-case is
    the reason the rule is not "show something shorter": an optional receiver's
    `?.greet` over the same range keeps its full spelling, because `?` is not
    standing there. And the LSP `label` is never this string — `greet(name:
    String)` inserted by the fallback path would corrupt the buffer.
    **No key may be the typed word**, and that is a provider obligation rather
    than something this class can check: AppKit routes Esc back through
    `insert(_:forPartialWordRange:isFinal:)` spelled as the typed word and with
    `isFinal: true`, and `EditorTextView.insertCompletion` has already dropped
    `movement`, so a snapshot that answers to that string commits the row instead
    of cancelling — applying its `import` and moving the caret, on the keystroke
    that means "never mind". `LSPIntelligenceProvider.publish` therefore drops an
    item whose *display* string equals the typed word, not only one whose inserted
    text does (`core-lsp.md`); the miss on this branch was a fully typed member,
    where the two spellings differ by exactly the dropped head.
    It answers `true` — "handled here" — only for the D4 case, and `false`
    everywhere else, which leaves AppKit's stock insertion to do the job it already
    does correctly. Everything about *which* edits and in what order is
    `CompletionEditPlan`'s; this class supplies the live buffer, the undo group and
    the text view. Four things are load-bearing.
    **AppKit writes the buffer before the user has chosen anything.** Arrowing
    through the popup calls `insertCompletion(…, isFinal: false)` for each row, so by
    the time the final call arrives, the typed word an item's edits are expressed
    against has already been replaced — and `CompletionEditPlan`'s staleness gate,
    doing its job, would refuse every auto-import picked with the arrow keys. So the
    controller remembers the last `preview` (every one of those writes passes through
    it) and Core gained `CompletionEdit.shifted(afterReplacingTypedWord:withLength:)`
    to re-express an edit over it. A non-final call is *always* `false`: it is a
    preview, not a commitment, and rewriting the file's imports once per arrow key
    would be indefensible.
    **Per edit, not per span.** `EditorSearchController.replaceAll` rewrites the
    whole spanned range in one `insertText` because it has up to 180 000 matches and
    cannot afford an edit cycle each; a completion has two or three, and its span
    reaches from the `import` line to the caret — the whole file — so the same trick
    would re-parse and re-highlight everything to insert two words. The plan's
    last-to-first ordering exists precisely so the edits can be applied one at a time
    with no offset arithmetic; the explicit `beginUndoGrouping` pair is what still
    makes them a single ⌘Z and what keeps them from coalescing into the user's
    preceding typing.
    **The top of the list is prefetched, and a late one re-applies the whole edit set.**
    `prefetchResolves` fires one task per deferred item the moment the list is shown
    (one per item rather than one for the batch, so a single slow resolve holds back
    neither the others nor the follow-up path that awaits one) — but only
    `prefetchResolveLimit` (5) of them. The bound is not tuning: LSP's only wire
    signal that a server kept something back is `data`, and sourcekit-lsp attaches
    `data` to **every** item it sends, so "prefetch everything deferred" is 30
    type-checking round trips per 150 ms debounce, on every keystroke, each batch
    cancelled by the next — sustained load on the very server the next completion is
    waiting on, for a feature that fires approximately never. The rows a user commits
    are the ones at the top of a list they can see (the popup's selection starts on
    the first), so the rest are resolved only if one is actually chosen:
    `scheduleFollowUp` starts the round trip itself when there is none in flight,
    which lands the import on D4's own stated race — a second undo step — rather than
    losing it. That is also why `resolveSource` (the provider the current list came
    from) is *not* cleared with the list: `update` forgets the list before the new
    answer arrives, and the old snapshot keeps serving the popup in between, so an
    item committed in that window must still be able to ask. **An empty resolve
    is not an answer**: `resolveEdits` returns `[]` for a timeout, a dead session and
    a superseded handle alike, so the commit path falls back to the edits the item
    was *published* with rather than reading `[]` as "this item turned out to have
    none" — which would have thrown away a server-chosen range wider than the typed
    prefix and left those characters standing in the buffer. A resolve that
    genuinely adds nothing loses nothing either way: it answers the same edits the
    item already carried. If the user commits
    before a resolve lands, `scheduleFollowUp` applies the edits when they arrive as a
    second undo step — the whole set, not just the `additionalTextEdits`: shifted over
    the insertion that already happened, the *primary* edit replaces the inserted text
    with itself (or widens to what the server meant), so one code path serves both the
    ordinary commit and the follow-up and `caretOffset` comes out right in both. D4's
    stated condition — the buffer untouched since the insertion — is a whole-string
    comparison read at the top of that task, which runs a main-actor turn *after*
    `insertCompletion` returned and so has a real "before" to compare against. The
    follow-up is outside AppKit's `insertCompletion` bracket, so it raises the
    programmatic-edit flag itself through `noteProgrammaticEdit`.
    **A caret move cancels nothing, because it supersedes nothing.** `forgetList()`
    — which drops the previews, the prefetched resolves and any pending follow-up —
    has exactly two callers, `update` (a keystroke) and `reset` (a tab teardown),
    and both are the events that really do end a list's life. The list is re-validated
    against the word under the caret when the delegate is asked, and an item's edits
    against the text they were computed over when one is committed, so cancelling a
    prefetch on a caret move would only throw away the resolve for a list still on
    screen. A resolve started late by `scheduleFollowUp` is filed in the same
    `resolveTasks` table, so it is cancelled by the same two events.
    **T-4: the whole thing has an off switch, and it is enforced twice.**
    `isEnabled` (`private`, default `true`) mirrors
    `SettingsStore.completionEnabled` — see `core-services.md` for the flag, and
    `app-window.md` for the bottom-bar surface — forwarded here by
    `CodeEditorView.updateNSView` through the coordinator. Two enforcement points
    rather than one, because the two paths into this class are genuinely
    different: at the **entry** of `update(…)`, which returns after clearing the
    snapshot and forgetting the list and *before* the request is built or a task
    spawned — so while completion is off a keystroke costs no debounce, no
    provider call and no resolve prefetch, rather than computing a result that is
    then discarded — and again at the top of
    `completions(forPartialWordRange:in:)`, which answers `[]`. The second covers
    the paths that never pass through `update(…)`: AppKit's stock ⌥⎋ and F5 reach
    the delegate directly, exactly as the member-state re-check above documents,
    so a gate only at the request entry would leave the switch silently partial.
    It is stated there rather than left to the `guard let snapshot` below it —
    which today answers `[]` too, since nothing can populate a snapshot while off
    — because that is a non-local proof about three other methods, and "off
    answers nothing" is the rule this switch *is*.
    `setEnabled(_:)` ignores an unchanged value (the forwarding
    runs on every SwiftUI update), and turning it *off* is not merely a gate
    raised for future keystrokes: it `reset()`s — cancelling the pending
    debounce/provider task, bumping the generation, dropping the snapshot and
    every prefetched or in-flight resolve — and then, **only if a popup is
    up**, asks the text view to `complete(nil)`. That re-query reaches the
    delegate, which now answers `[]`, and an empty answer is what dismisses a
    popup that is already on screen. "Is up" is `isServingPopup`, **what the
    delegate last actually served** in the editor the user is typing in: the
    answer AppKit builds the list from, so a non-empty return opens or keeps one,
    `[]` closes it, a final `insert(…)` (the accepted row *and* the Esc restore,
    which AppKit routes through the same call) ends the session and `reset()`
    gives up the claim. It is maintained in a thin wrapper over the delegate body
    rather than at that body's six exits, so the two cannot disagree, and it is an
    *upper* bound — AppKit can also close the list without telling us (a click
    outside, a window resigning key) — never a claim that no popup is up.
    The **snapshot is not that question**, and asking it was the original bug: it
    is stored by `apply(…)` *before* its own focus/caret guards and is not dropped
    when a popup closes, so it routinely outlives — or never had — a visible list,
    and `complete(nil)` on an invocation that finds no completions makes AppKit
    *beep*. Every "type a word, dismiss the list, switch completion off" would
    have sounded an unexplained alert. The focus half is load-bearing for a second
    reason: without it `setEnabled(false)` would break the very rule `apply(…)`
    states, reaching AppKit's completion machinery on a text view the user is not
    typing in.
    **Focus is two questions, not one**, and asking only the obvious one gets the
    Preferences case exactly backwards: `NSWindow.firstResponder` is *not* cleared
    when its window stops being key, so an editor in a background window — which
    is every open editor while the Preferences window is up — still answers
    `firstResponder === textView` and would pass a responder-only test. `isKeyWindow`
    is therefore asked alongside it, and costs nothing real: a completion popup can
    only be on screen in the key window, so the narrower test skips no dismissal.
    (The unwrap is written out rather than
    chained through the optional, because `nil === nil` is `true` and would let a
    controller with no text view pass.)
    **The re-query is deferred by one run-loop turn**, because `setEnabled(_:)` is
    called from `updateNSView`: dismissing a live popup makes AppKit restore the
    typed word through `insertCompletion(…isFinal:)`, a real buffer edit that fires
    `textDidChange`, which writes the SwiftUI text binding — observed state mutated
    from inside a view update, the hazard `CodeEditorCoordinator_iOS.applyReveal`
    hops out of for the same reason. The hop is `EditorSearchController.setNeedsRefresh`'s
    (same run-loop iteration, nothing drawn in between) and re-asks every condition,
    since the toggle may have been flipped back and the editor may have lost focus,
    gained marked text or been torn down before it lands.
    Nothing in the intelligence stack is stopped: no LSP session
    is shut down, the registry is untouched, the symbol index keeps walking and
    refreshing, and go-to-definition — which asks the same provider — is entirely
    unaffected. The decision that off is *total* (and that the auto-popup-only
    variant was rejected rather than overlooked) is recorded in
    `core-services.md`.
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
    punctuation and the empty region past a line's end never reach the provider.
    The anchor is deliberately also set for a request that turns out to have **no**
    answer, so a server that knows nothing about an identifier is asked once per
    visit rather than once per mouse-moved event.
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
    The buffer is read through the text storage's own `NSMutableString` rather than
    `textView.string`, which bridges — and therefore **copies the whole document**
    — every time it is named. Every other `textView.string` in the editor sits
    behind a debounce or an explicit command; this one runs per mouse-moved event,
    and on a large file the copy alone is the stutter. Read-only and synchronously
    on the main actor, so no edit can interleave.
    **Resolving the character under the pointer is not one line, and that is the
    point.** `characterIndexForInsertion(at:)` — what ⌘-click and the viewport
    memory use — answers the nearest *insertion point*, which past the end of a
    line is that line's last character, and a popover describing a symbol the
    pointer is a hand's width away from is worse than no popover. So its answer is
    **verified**: the character is accepted only when its own laid-out rectangle
    contains the point, and two candidates are tried (the index and the one before
    it) because an insertion point is a boundary — a pointer in the right half of a
    glyph reports the index after it. Both halves of every glyph therefore resolve
    to the glyph, and neither half of the empty space past a line resolves to
    anything. The obvious spelling — `glyphIndex(for:in:)` guarded against
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
    outlive it, re-attached only when the parent actually changed (`addChildWindow`
    on the current parent re-orders the whole child list on every dwell).
    `dismiss()` is idempotent, because dismissal arrives from a dozen unrelated
    places and several of them routinely fire when nothing is on screen — and it
    returns early when the panel is not on screen, which is what makes it *free* as
    well as safe: the controller dismisses on every mouse-moved event over
    whitespace or punctuation, and an `orderOut` of an already-hidden window is a
    window-server round trip per pixel of pointer movement.
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
    capped too**, at the anchor screen's visible frame, and Core's line cap does
    not make that redundant: `HoverContent.maximumLineCount` counts *logical* lines
    and prose wraps, so a server that stores a doc comment as a few long unwrapped
    paragraphs passes the cap and still measures taller than the display. The panel
    draws from the top of its frame down, so an unclamped one is placed with its
    bottom on the screen edge and its **first line — the signature — above the top
    of the screen**, which is precisely the outcome the placement rule below exists
    to avoid. Clamping the height cuts the tail instead, which is the end already
    meant to go. Placement is below the anchor line by default and flipped above it when the popover would
    run off the bottom — a menu's rule, and the one a user reading downward expects
    — but only when the flipped position is genuinely better, since on a screen too
    short either way hanging below at least keeps the first line, which is the
    signature. The horizontal position is **clamped rather than flipped**: a
    popover pushed left to stay on screen still points at the right line, while one
    flipped to the other side of the identifier would not. Thin, untested view
    glue; this file owns fonts, padding and geometry, and nothing else.
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
    **The search order is `LSPGoToolchainService.locateGo`'s**, and the one
    difference is which directories are well-known: the inherited `PATH` first
    (a Pisaka started from a terminal should use the `cargo` that terminal would
    have run); then `~/.cargo/bin` and Homebrew's two prefixes — `~/.cargo/bin`
    leading, because rustup puts both `cargo` and the `rust-analyzer` proxy there
    and rustup is how nearly everyone has Rust, which is why the common case (a
    rustup user who already has rust-analyzer) costs no subprocess at all; then the
    **login shell last**, asked for `$PATH` rather than `command -v`, because it is
    the only step that costs a subprocess and the only one that can find a
    version-manager shim. Every branch reports a `PATH` that contains the `cargo`
    it found, the well-known-directory branch building one by prepending the
    directory it found — that `PATH` is what Core hands the server as its
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
    list (`executables(named:in:)`, de-duplicated so the same file is never probed
    twice) and takes the first that answers. Stopping at the first executable file
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
    navigates (`setSelectedRange` + `scrollRangeToVisible`, taking the selection's
    *end* going forward and its *start* going back so ⌘G steps off the current match
    in both directions), and applies the two replace commands. `replaceCurrent`
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
