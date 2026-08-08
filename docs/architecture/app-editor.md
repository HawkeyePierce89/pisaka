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
    an `onDuplicate: ((NSTextView) -> Bool)?` callback (modeled on
    `onStepFontSize`, wired in `makeNSView` to the coordinator's
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
    Shared font size: `CodeEditorView` takes a `fontSize: Double` plus an
    `onStepFontSize: (Double) -> Void` callback (both threaded from
    `settings`/`settings.stepFontSize(by:)` via `ContentView`); `makeNSView` sets
    the text view's `font` to `.monospacedSystemFont(ofSize:weight:.regular)` at
    that size, and `updateNSView` re-applies it when `fontSize` changes (tracked by
    the coordinator's `appliedFontSize`), then re-derives the gutter (the
    `LineNumberRulerView` reads `textView.font?.pointSize`, so a redraw +
    `ruleThickness` recompute) and `refreshGeometry` (so the line-height-dependent
    minimap geometry and viewport rect stay correct). Cmd+scroll: the editor
    `NSTextView` subclass overrides `scrollWheel(with:)` and, via a shared
    `handleCommandScrollFontStep` helper, steps `settings.fontSize` (through
    `onStepFontSize`, clamped in the store) in the sign of `scrollingDeltaY` when
    `event.modifierFlags.contains(.command)` — consuming the event (no `super`,
    no normal scroll) — else falls through to `super`. The handler lives on the
    editor text view, not `MinimapView`, so it never conflicts with the minimap
    wheel handler or the diff synced-scroll. `DiffView`/`MergeView` take the same
    `fontSize` and apply it uniformly across their panes (so rows stay aligned).
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
    "empty text, non-zero offset" as unanswerable rather than clamping. Where a
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
    (D4). The snapshot therefore keeps whole `CompletionItem`s keyed by the text they
    insert (first wins on a duplicate, matching the provider's own dedup rule), so
    `insert(_:forPartialWordRange:isFinal:in:)` can find the item behind the string.
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
    **Deferred items are prefetched, and a late one re-applies the whole edit set.**
    `prefetchResolves` fires one task per deferred item the moment the list is shown
    (one per item rather than one for the batch, so a single slow resolve holds back
    neither the others nor the follow-up path that awaits one). If the user commits
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
    screen.
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
    The environment is inherited wholesale and never assigned (`GitCLIService.run`'s
    reasoning: a language server resolves its toolchain, caches and build system out
    of `PATH`/`HOME`/`DEVELOPER_DIR`, and replacing the environment to add one
    variable would take all of that away). `stop()` is idempotent: stop reading, close
    stdin — which gives a server that reads to EOF a chance to exit on its own, as
    sourcekit-lsp does — `SIGTERM`, then `SIGKILL` after a 2 s grace on a *concurrent*
    reap queue, so two servers torn down on a folder switch do not wait for each
    other. `pid > 0` guards the one genuinely dangerous mistake here: `kill(0, …)`
    signals the whole process group, i.e. Pisaka itself — the same check
    `TerminalSession.terminate()` makes. `make(for:root:)` is what
    `LSPWorkspace.transportFactory` is handed, and it **throws** rather than returning
    `nil` when the executable cannot be found, because the workspace already treats a
    throwing factory exactly like a crash — one spent restart, then silence — and a
    machine with no Xcode must not retry a process launch once per keystroke.
  - `LSPToolchain.swift` — where a language server's executable actually is on
    *this* machine, in exactly one shell-out: `xcrun --find <name>`. Resolution is the
    app's job because Core cannot run `xcrun` (D9), and hard-coding
    `/Applications/Xcode.app/…/sourcekit-lsp` would break the moment someone runs
    `xcode-select`, installs a beta alongside a release, or exports `DEVELOPER_DIR`.
    **Nothing is bundled and nothing is downloaded**: no Xcode means `xcrun --find`
    answers nothing, this answers `nil`, the transport factory throws `launchFailed`,
    and `LSPWorkspace` spends one restart on it — which is why the answer is cached
    **including the negative one** (`[String: String?]`, so a recorded "not found" is
    distinguishable from "not looked up yet"), or a machine with no toolchain would
    fork `xcrun` once per keystroke forever. The cache is per app run, not per folder:
    `DEVELOPER_DIR` is read from the environment the app was launched with and cannot
    change under a running process, so someone who runs `xcode-select` mid-session
    gets the old toolchain until the next launch — stated rather than papered over,
    since the alternative is invalidation logic for an event nobody has ever hit.
    Blocking and deliberately so: making it `async` would push a `Task` hop into the
    workspace's transport factory, which is synchronous precisely because launching a
    process is something the main-actor turn that decided to launch it can just do.
    `prewarm(_:)` moves the first lookup to a background queue at app startup so the
    first ⌘-click in a cold project does not pay for it inside the launch turn —
    purely an optimisation, since correctness does not depend on it. `.executable(path:)`
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
