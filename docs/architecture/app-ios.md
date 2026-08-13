# Pisaka app — platform shims & iOS layer

Design documentation moved verbatim from the root `CLAUDE.md` (which now holds only a one-line-per-file index). Each entry records a file's contract, invariants and the reasoning behind non-obvious decisions — read the relevant entry before modifying that file, and update it when behavior changes.

- **`Pisaka`** (the app target, `Sources/Pisaka/`) — a thin SwiftUI/AppKit
  (macOS) and SwiftUI/UIKit (iOS) layer. Views hold no domain logic; they
  observe `WorkspaceModel`/`LocalChangesModel`/`CommitLogModel`/`MergeModel`. The
  **macOS** files described below are all wrapped in `#if os(macOS)`; the
  **iOS** counterparts live in `Sources/Pisaka/iOS/` (each mirrors a macOS
  view), and a small platform-shim layer in `Sources/Pisaka/Platform/` bridges
  the per-platform APIs:
  - `Platform/PlatformColor.swift` — `PlatformColor` typealias (`NSColor` on
    macOS, `UIColor` on iOS) + `init(rgb:)` / `dynamic(light:dark:)` so
    `SyntaxTheme` resolves appearance-aware colors on both platforms (macOS output
    stays byte-identical — `PlatformColor == NSColor`). The diff-background
    palettes stay per-platform and are *not* routed through this bridge —
    `DiffColors` (raw `NSColor`) on macOS, a parallel `DiffColors_iOS` (raw
    `UIColor`) on iOS — using the system semantic colors directly.
  - `Platform/PlatformFeedback.swift` — `warning()` (beep on macOS, error haptic
    on iOS), the single reroute for every former `NSSound.beep()` call site, plus
    `light()` for "the action ran but found nothing" — a Go to Definition on a
    name the index does not know. Two cues rather than one because iOS *has* the
    gradation and an error notification haptic (three sharp taps) reads as a
    problem to act on; macOS has no stock equivalent and keeps the beep for both,
    so the split costs nothing there.
  - `Platform/PlatformAlert.swift` — `presentMessage` over `NSAlert` /
    `UIAlertController`.
  - `Platform/PlatformRoute.swift` — `RoutePresentation` (separate window on
    macOS; sheet / navigation push on iOS, compact-vs-regular aware).
  - `Platform/LicenseCatalogLoader.swift` — the bundled-license reader shared by
    both Acknowledgements screens (one-shot `static let` cache, reads
    `Licenses/licenses.json` + every `.txt` beside it, all decisions in Core's
    `LicenseCatalog`). Documented in full in `app-shell.md`, since nothing in it
    is platform-specific.
  - `Platform/LicenseTextView.swift` — the scrolling, selectable pane both
    Acknowledgements screens render a license text in (`UITextView` here,
    `NSTextView` in an `NSScrollView` on macOS). TextKit rather than
    `ScrollView { Text(…) }` so the 66 KB libgit2 text lays out lazily instead of
    whole on the main thread; full entry in `app-shell.md`.
  - `Platform/SymbolQueryCatalog.swift` — loads and caches the compiled
    `symbols.scm` query per language: the symbol index's counterpart to
    `SyntaxLanguageConfiguration`, which does the same for the *highlight*
    queries, and structurally a copy of it for the same three reasons. **Cached**,
    because compiling a query is the expensive part (`ts_query_new` parses the
    whole `.scm` and builds the pattern automata) while the index asks per *file*.
    **Not `@MainActor`**, because `SymbolExtractor` runs on `SymbolIndexModel`'s
    private serial queue — so the cache is `NSLock`-guarded, and the lock is held
    only across the dictionary read/write and never across a compile, which is why
    a non-recursive lock cannot deadlock (a racing compile may happen twice; both
    results are valid and the last write wins). **`nil` on any failure**, so a
    packaging or compilation problem degrades that language to "no symbols" rather
    than crashing. Failures are remembered in an `unavailable` set, or a project
    full of `.py` files would re-read and re-compile a broken query thousands of
    times. Lives in the non-gated `Platform/` layer because both destinations
    index: `Resources/Queries` is a folder reference, so the directory lands as
    `Queries/<language>/symbols.scm` under `Contents/Resources` on macOS and at the
    `.app` root on iOS, and `Bundle.main` resolves it identically. In **DEBUG only**
    a missing file and a compile error trip separate `assertionFailure`s naming the
    language — the runtime check `swift test` cannot make (verifying a query
    compiles needs SwiftTreeSitter, which Core does not link), so a developer in a
    debug build hits it on the first file of that type instead of silently indexing
    nothing forever. A grammar that failed to *load* stays silent, because the
    highlighting path already owns and reports that cause. A language Core declares
    unindexable ships no query by design and must not assert.
  - `Platform/SymbolExtractor.swift` — turns a file's text into the `[Symbol]`
    array the index stores: the one piece of the feature that cannot live in
    `PisakaCore`, because it is the only piece that needs tree-sitter. **Not an
    actor and not `@MainActor`** — a caseless enum with one `@Sendable nonisolated
    static func symbols(in:language:fileURL:)`, the
    `MinimapTokenizer.computeModel` shape. (`@Sendable` because the function is
    handed over as a bare reference to `SymbolIndexModel.extractSymbols`, whose
    parameter is `@Sendable`; without it the conversion is an unchecked one the
    compiler warns about at both `@main` sites.)
    `SymbolIndexModel` calls it only from inside its own private serial queue (the
    seam is deliberately synchronous — plan Decision 7, recorded in
    `core-intelligence.md`), so that queue *is* the serialization and an actor here
    would add a second hop and a second ordering authority. The thread-safety
    contract that makes it sound is `computeModel`'s: **every call builds its own
    `Parser` and its own query cursor** — tree-sitter parsers and cursors are not
    safe to share — while the compiled `Query` and the `Language` come from the
    lock-guarded caches (`SymbolQueryCatalog`, `SyntaxLanguageConfiguration`) and
    are only *read*. It walks **matches, not captures**, because the optional
    `@container` capture is paired with the kind capture inside one pattern and a
    flat capture stream would lose which type a method belongs to. **Predicates are
    resolved** (`match.allowed(in:)`), unlike the minimap's highlight pass: exactly
    one query needs it — an HTML `id` attribute is structurally identical to every
    other attribute, so without evaluating `(#match? @_attribute "^[iI][dD]$")`
    every `class=`
    and `href=` value would be indexed as an anchor — and `SymbolQueryTests` pins
    that HTML is the only query with a predicate, so a second one is reviewed
    rather than silently relying on this. Captured ranges are whitespace-trimmed on
    **both** the text and the range (a Markdown heading's `inline` node carries the
    space after the `#` and the trailing newline), so a jump still lands on the
    name's first character. The same narrowing drops the **leading `#` of a
    JavaScript/TypeScript `private_property_identifier`**, the one captured node
    whose text is not just the name (the grammar spans the sigil and offers no
    inner node to capture): stored verbatim, `#count` is not merely ugly but
    *unreachable*, because `IdentifierScanner` never produces a name containing
    `#` — a ⌘-click on it resolves `count` and misses, and the completion bucket is
    keyed on `'#'` where no typed prefix can land. It is matched by *node type*,
    not by "the text starts with `#`", so a Markdown heading or a CSS `#id` that
    legitimately begins with one is untouched; the convention it restores is the
    one every query already states — the symbol is the name, never the sigil
    (CSS captures `card`, not `.card`; YAML the anchor name, not `&name`).
    The 1-based line comes from `LineStartIndex.offsets`
    computed *once per file* and only when the file actually declares something,
    then binary-searched per symbol. `fileURL` is carried into each `Symbol`
    unchanged — `SymbolIndex` owns canonicalization. Unknown captures and empty
    names are dropped, and returning `[]` is the documented degradation covering a
    missing query, a query that failed to compile, a grammar that failed to load
    and a parse that produced no tree.
  - `Platform/SymbolIndexController.swift` — schedules the index's incremental
    work: the buffer re-index behind a keystroke debounce and the project refresh
    behind an FSEvents debounce, both the `BracketHighlightController` idiom (a
    cancellable `Task.sleep`, superseded by the next call). Thin glue by design —
    every decision about *what* a re-index or refresh does (generations, stamp
    gating, buffer-over-disk precedence) lives in `SymbolIndexModel` and is tested
    there; this class decides only *when*, so it is untested view-layer code like
    the rest of `Sources/Pisaka`. **Two deliberately different intervals:** 400 ms
    for a buffer edit — longer than the bracket scan's 100 ms or the minimap's
    150 ms, because this re-parses the whole file *and* republishes the index, and
    the price of getting it wrong is a completion list one word behind (which
    nobody sees) versus a full parse per keystroke (which everybody feels); and
    500 ms for the watcher, *on top of* the 1 s coalescing `ProjectWatcher` already
    applies, because a build or an `npm i` produces bursts that outlive the
    watcher's own window. A tab open or switch (`noteBufferOpened`) bypasses the
    debounce entirely — the file being looked at must have symbols before the user
    finishes reading it, and a tab switch is not a burst. **The pending re-indexes
    are held per file** (`bufferTasks`, keyed by URL) rather than in one slot, and
    that is a correctness rule, not bookkeeping: with a single slot, the immediate
    re-index a tab switch issues would cancel the *outgoing* file's still-sleeping
    debounce — the only thing that would ever publish those keystrokes. Nothing
    else picks them up, because that file is already buffer-sourced, so a refresh
    neither re-extracts nor removes it and the entry stays frozen at its last
    parse until the tab is re-selected or closed. A newer re-index of the *same*
    file still supersedes the older one, which is all the debounce ever needed.
    Each task clears its own entry when it finishes — safely, because every
    replacement cancels the task it evicts, so a task that reaches the clear is
    still the one the entry names — leaving the dictionary bounded by the number
    of files being typed in at once. `noteBufferClosed` cancels this file's
    pending re-index *before* calling `forgetBuffer`, which would otherwise
    re-mark the file buffer-sourced a moment later and pin the index to text no
    editor holds — and the cancel bites whether the work is still sleeping out the
    debounce or already inside the extractor, because `reindexBuffer` re-checks
    cancellation after its parse (the reasoning is written there, in
    `core-intelligence.md`); keying by URL is what keeps it from being collateral
    damage to another tab. It then files `reindexFromDisk` under that same key,
    immediately rather than debounced (one file, and a close is not a burst): that
    is the half of the hand-off that actually re-reads the file, and nothing else
    would, since a close writes nothing for a watcher to see and a standalone file
    with no folder open has no project refresh at all. Sharing the key is what
    makes a tab reopened mid-read cancel the hand-off and let its own immediate
    re-index win. The keys are standardized rather than canonical — every
    caller hands over the URL its tab already holds, and `SymbolIndex.fileKey(for:)`
    resolves symlinks, a file-system round trip this would otherwise pay on the
    main actor on every keystroke to tell apart spellings no tab produces. Nothing here is gated on the
    autosave/revert bracket, deliberately: the index is a *reader*, so a refresh
    landing mid-revert costs at worst one stale entry the next refresh corrects.
    `reset()` drops both debounces and is called in the same main-actor turn as
    `prepareForFolderChange(root:)` — the generation token already discards what
    they would publish, so this only avoids doing the work first. Exposes
    `provider` (read from the model each time, so no caller answers from the state
    a folder was opened in) as the seam the editor surfaces ask through, rather than
    handing views the model itself: a view that could reach the model could also
    drive the index, and the model republishes after every chunk, which must stay
    off a view's update path. The one other thing forwarded is
    `currentRootGeneration`, the model's *project* token, which both definition
    surfaces pin before their `Task` hop and re-check when the candidates arrive —
    see `core-intelligence.md` for why the providers' own staleness gates cannot
    close that last hop themselves. Forwarding it is not "driving the index": it is
    a token, it moves only when the app registers a folder switch, and reading it
    cannot make this class do anything. That `provider` is also **the seam phase 2a's LSP
    layer reaches the editor through**, without a single view signature changing:
    `installProvider(_:)` records a composed provider that `provider` then hands out
    in the model's place, and the macOS app calls it once at construction with a
    `RoutingIntelligenceProvider` built around *exactly* `model.provider` — so
    replacing the seam adds a source of answers rather than taking one away, and
    `CodeEditorView`/`CompletionController` go on reading `symbolIndex.provider` and
    cannot tell which of the two answered. It is deliberately not an `init`
    parameter: the routing provider needs `model.provider`, which needs the model,
    which needs this controller to exist first. iOS installs nothing, so there
    `provider` stays literally the index. Lives in `Platform/` because both
    destinations drive both halves; the project refresh is *watcher*-driven only on
    macOS, while on iOS it is driven by the app's own working-tree rewrites.
  - `iOS/PisakaApp_iOS.swift` — the iOS `@main` App (the macOS `@main` is gated
    out under one-`@main`-per-platform `#if`). It also constructs the
    `SymbolIndexModel` + `SymbolIndexController` pair, the same way the macOS app
    does and from the same synchronous `SymbolExtractor.symbols(in:language:
    fileURL:)` function reference — reading through the **scoped** service, so the
    index's traversal runs under the opened folder's security-scope grant, over the
    same open-buffer snapshot closure shape. Both are plain stored properties, never
    `@StateObject`, for the reason the macOS app records: the model republishes its
    index after *every chunk* of a walk, and subscribing this scene's `body` to that
    would rebuild the whole root view dozens of times while a project is indexed,
    for a value no view reads. iOS has **no file-system watcher**, so nothing
    refreshes on a genuinely *external* change (Files.app, a share extension) —
    stated rather than worked around; the index moves forward on folder open, tab
    open, buffer edits, and the working-tree rewrites the app performs itself
    (`RootView_iOS.notifyIndexOfProjectFileChanges`).
    It also composes the **LeetCode** stack (LC-1; the layer's entry is in
    `core-leetcode.md`) inline rather than through a `makeLeetCode` factory —
    `ContentView`'s need for a default value has no iOS counterpart — but from the
    *same* three cross-platform seams (`LeetCodeURLSessionTransport`,
    `LeetCodeKeychainStore`, `LeetCodeSupportDirectory.cacheLayout`), with one
    platform difference: the file service is the **scoped** one, since a picked
    solutions folder is only writable inside its grant while the container cache
    simply finds no covering scope and falls through. `SettingsStore` moved into
    `init` for the macOS app's reason — the folder has to be readable before the
    model is built, so `isSignedIn` and `solutionsFolder` are right from the first
    frame — and the model is a plain stored property, never `@StateObject`, for the
    same reason the index pair is.
  - `iOS/RootView_iOS.swift` — adaptive root: `NavigationSplitView` (iPad/regular
    width: project-tree sidebar + editor detail) vs `NavigationStack`
    (iPhone/compact: tree → pushed editor), plus the Local Changes / Git Log /
    Merge sheet routes and the revert/apply-merge orchestration (the iOS peer of
    `PisakaApp`, minus the autosave/project-tree gates iOS lacks). It also owns the
    `BranchSwitcherModel` (constructed alongside `localChanges`/`commitLog`,
    refreshed on folder open and after a successful switch/create) and hosts the
    `BranchSwitcherView_iOS` in the toolbar/nav; its switch/create/checkout-remote
    orchestration mirrors the iOS revert path's gates (autosave pause / tree lock),
    tab resync (`reloadFromDisk` for a clean tab, `reconcileSavedBaseline`+beep for an
    edited one), and generation-pinned Local Changes / Log refresh
    (`prepareForFolderChange` / `prepareForRefresh`). `checkoutRemote(_:
    originGeneration:)` is the git-DWIM peer of `PisakaApp.checkoutRemote` and a mirror
    of `switchBranch` (calling `branchSwitcher.checkoutRemote`, same snapshot/resync/
    `finishBranchOperation`); the toolbar threads `onCheckoutRemote` into
    `BranchSwitcherView_iOS` capturing `currentRefreshGeneration` synchronously before
    the `Task` hop, and the widget's dirty-tree confirmation routes a *remote* checkout
    here (not `switchBranch`, which would detach HEAD). A `credentialsRequired`
    outcome from a remote-start create directs the user to the Settings PAT screen.
    It is also where the **symbol index** meets the folder lifecycle and where Go to
    Definition is routed. The model/controller pair arrives from `PisakaApp_iOS` as
    plain `let`s, never `@ObservedObject` (the model republishes after every chunk of
    a walk and nothing here reads it — observing would rebuild the whole root per
    chunk); the editor surfaces ask through `symbolIndex.provider`. The folder switch
    is registered by `synchronizeSymbolIndex(forRoot:)`
    (`prepareForFolderChange(root:)` + `symbolIndexController.reset()` synchronously,
    then a pinned `rebuild`), called from **two** places on purpose. The picker path
    (`handlePicked`) calls it in the same main-actor turn as the open, for the same
    reason the branch widget is registered there rather than left to its `onChange`:
    that observer runs in a *later* SwiftUI update cycle, so bumping the index's
    project token only there would leave a window in which an outstanding Go to
    Definition resumes after the folder committed but before the token moved, passes
    `CodeEditorCoordinator_iOS`'s `currentRootGeneration` re-check, and presents a
    declaration from the project the user just left — the exact hop that guard exists
    to close. `onChange(of: model.projectRoot)` calls it too, and that copy is not
    redundant: the launch-time bookmark restore publishes `projectRoot` without going
    through the picker, and an index that only existed after a manual pick would
    leave go-to-definition dead on every relaunch. Calling it twice for one switch is
    therefore the normal case and stays cheap by construction —
    `prepareForFolderChange` is a no-op for a root the model already holds and the
    generation it returns is what says so, so the second call neither cancels the
    controller's two debounces nor spawns a second walk. Closing the folder (`nil`)
    still prepares, which clears the index — a symbol pointing into a folder the app
    can no longer read is worse than no symbol — it just has nothing to walk. `requestClose` (and both branches of
    the dirty-close dialog) hands a tab's entry back to disk through
    `forgetIndexedBuffer`, a no-op while any tab still shows the file, so a cancelled
    close and the same file reached through two tabs leave the buffer mark alone —
    the iOS peer of `PisakaApp.forgetIndexedBuffer`. **The three git resyncs
    force-close tabs and so route through it too** (`revert`, `applyMerge`,
    `resyncOpenTabsAfterCheckout`, capturing the URL before `close(id:force:)`),
    exactly as their macOS peers do and for the reason stated there: a buffer-sourced
    entry is exempt from both halves of a refresh, so a file a branch switch deleted
    would go on answering lookups for the rest of the session. The *success* side of
    those same three resyncs — a tab whose buffer `reloadFromDisk` replaced with the
    rewritten file — routes through `reindexReloadedBuffer(id:url:)`, the iOS peer of
    `PisakaApp`'s and load-bearing for the same reason: the entry is still
    buffer-sourced, so the refresh below declines to touch it, and only the
    *selected* tab re-indexes itself from its live `CodeEditorView_iOS`; a background
    tab would keep answering out of the previous revision until selected or closed.
    Those same three
    operations end with `notifyIndexOfProjectFileChanges()`, the iOS peer of
    `PisakaApp`'s: iOS has no file-system watcher, so *nothing* about a working-tree
    rewrite reaches the index by itself, and a branch switch would otherwise leave Go
    to Definition and completion answering out of the **previous branch** for the
    rest of the session, with no user-reachable correction short of closing and
    reopening the folder. These are the moments the app itself knows about, which is
    what lets them stand in for the watcher iOS lacks; the genuinely out-of-band edit
    (Files.app, another app's share extension) stays uncovered and stays a stated
    Phase 1 limit. A `@StateObject
    DefinitionRoute_iOS` (rather than the plain `@State` a `MergeModel` gets, because
    this one is also *read* here) is given an `openFile` closure capturing only
    `model` — anything read from the view struct would be frozen at installation
    time, so the one thing that depends on the current layout, pushing the editor on
    compact width, is handled by an `onChange(of: definitionRoute.reveal)` observer
    instead. More than one candidate is presented as a `.confirmationDialog` rather
    than a sheet: the list is short, already ranked, and its rows are the same
    `displayLabel` strings the macOS `NSMenu` shows.
    **LeetCode** (LC-1; full entry in `core-leetcode.md`) is wired here the way the
    macOS window wires it, adjusted for iOS's navigation: `leetCode` is a plain
    `let` (never observed at the root), `LeetCodeFolder_iOS.publish` and one
    unawaited `refreshUserStatus()` run in the launch `.task`, and the statement is
    a `.task(id:)` keyed on **(selected tab path, LeetCode folder)** — the folder
    read from `settings`, which this view observes, rather than from the model,
    which it does not. `editorArea` was split into itself plus `tabbedEditor` so the
    regular-width pane can be an unconditional `HStack` sibling that renders *itself*
    away, never a conditional wrapping the editor (which would tear down the
    `UITextView`, its undo stack and its scroll position on every LeetCode tab
    selection); the compact-width sheet is attached at the **root**, not on the
    pushed editor screen, so a tab switch behind it cannot tear it down mid-read.
    LC-2 hands both of those call sites — the sheet and the pane — two more values
    for the judge section: `workspace` as a plain, **non-observed** `let` (an
    `@ObservedObject` would re-render it on every keystroke in the file being
    solved) and `activeFileURL` travelling separately for exactly that reason,
    since the selection is what re-runs `prepare` and only an observing view can
    supply it. The section itself is written once, into
    `LeetCodeDescriptionContent_iOS`, so the sheet and the pane get it from the
    same place and cannot drift.
    The entry point is an item in the existing "+" toolbar menu rather than a fifth
    toolbar button — an iPhone navigation bar is already carrying the branch widget
    and four items, and "open a LeetCode problem" is the same *kind* of action as
    the three opens above it. `openLeetCodeProblem` mirrors `PisakaApp`'s: the
    sentence goes to the screen, an alert is kept for the tab open alone, and
    the tree revision is bumped only when the file landed inside the open project,
    because opening a problem never changes the project root. That one alert goes
    through the root-level `rootAlert` (the type formerly named `BranchAlert`,
    renamed when it gained its second caller) and **not** `PlatformAlert`: the
    LeetCode sheet is dismissed one line before it, and `PlatformAlert` walks the
    `presentedViewController` chain, so it would hand the alert to a controller
    UIKit is tearing down and the presentation would simply be dropped — the same
    reason the branch failures already sit there.
  - `iOS/BranchSwitcherView_iOS.swift` — the iOS branch-switcher widget: the
    current branch shown in the toolbar/nav, tapped to a sheet/popover with the
    Local/Remote list (current marked), a filter field, and a "New Branch…" item. A
    remote-branch row is a two-item `Menu` — "Checkout" (git DWIM via
    `tapCheckoutRemote` → `onCheckoutRemote`) and "New Branch from '\(shortName)'…"
    (the existing create flow via `beginCreate`, pre-filled name; in Part A iOS fetch
    is unavailable → offer create-from-local or cancel; in Part B a real HTTPS fetch
    runs, needing a PAT for a private repo). The outer `BranchSwitcherView_iOS` wires
    `onCheckoutRemote` into `BranchListSheet_iOS` as `{ branch in isPresented = false;
    onCheckoutRemote(branch) }` so the sheet dismisses before the handler runs (the
    `onSwitch`/`onCreateBranch` pattern). The dirty-tree confirmation is routed by an
    enum-typed `DirtyCheckoutTarget` (`.local(BranchRef)`/`.remote(BranchRef)`)
    replacing the old single `dirtySwitchTarget`: `tapLocal` sets `.local` on a dirty
    tree, `tapCheckoutRemote` sets `.remote` (no `isCurrent` guard — a remote ref is
    never current), and the single `.confirmationDialog`'s "Switch" button routes
    `.local → onSwitch`, `.remote → onCheckoutRemote` — so a confirmed *remote*
    checkout goes through the DWIM path, not `onSwitch` (which would run `git checkout
    origin/foo` → detached HEAD). Thin `@ObservedObject
    BranchSwitcherModel` view (untested, logic in Core).
  - `iOS/CodeEditorView_iOS.swift` / `iOS/CodeEditorCoordinator_iOS.swift` — the
    `UITextView`-backed editor mirroring `CodeEditorView`: Neon highlighting,
    `IndentEngine`/`AutoPairEngine` wired through `UITextViewDelegate` with the
    same programmatic-edit re-entry guard and single-undo discipline; pinch-to-
    zoom font stepping (the iOS analog of macOS Cmd+scroll). No gutter/minimap on
    iOS (deferred).
    It is also the iOS host of both **code-intelligence** surfaces, with the
    representable threading `fileURL`, the `SymbolIndexController`, the
    `DefinitionRoute_iOS` and the route's pending `reveal` into the coordinator
    (the controller and the route are held **weakly** there — the app owns both for
    its whole lifetime, and a deallocated one means "no re-index"/"no jump", which
    is what a preview gets; `reveal` is passed as a *value* so a candidate-list
    change cannot rebuild the editor).
    **Re-index triggers:** `makeUIView` and a `switchedFile`/`contentReplaced`
    update call `reindexSymbols(immediate: true)` — on iOS a tab open is one of the
    few moments the index moves forward at all, and the file may sit outside the
    walked folder (a standalone document pick) where nothing else would reach it —
    while `textViewDidChange` goes through the controller's 400 ms debounce. A
    buffer swap also clears the strip, whose candidates answer a word in the
    *outgoing* buffer. `applyReveal` runs **last** in `updateUIView`, so it acts on
    the buffer that update just installed, and defers the selection by one main-loop
    turn because TextKit has not laid out a wholesale replacement yet; the range is
    clamped to the live buffer and a `token` makes a standing request apply exactly
    once. On that same hop it calls `DefinitionRoute_iOS.consumeReveal(token:)` —
    the token guard alone dies with the coordinator, so the request has to be
    retired at the route or a popped-and-re-entered editor re-applies it; the route
    is captured *strongly* for the hop precisely because the teardown case is the
    one the clear exists for, and the clear happens on the hop rather than in
    `updateUIView`, where mutating observed state is a SwiftUI violation. The clamp
    **truncates the length** instead of calling `NSIntersectionRange`: a range whose
    location is exactly the buffer end shares no unit with the document, and
    intersection answers `{0, 0}` for that — scrolling to the top of the file rather
    than leaving the caret where the (stale) range pointed. **Definition** is
    offered through
    `textView(_:editMenuForTextIn:suggestedActions:)`, which appends one "Go to
    Definition" action when the text under the selection is an identifier and
    carries the suggested actions through explicitly so Cut/Copy/Paste keep working
    beside it. The lookup happens **on tap, not while building the menu**, and that
    is a shape constraint rather than a preference: UIKit builds the menu
    synchronously while presenting it, `CodeIntelligenceProviding` is async, and
    pre-computing a lookup per selection change (the inversion the macOS completion
    controller uses) would put a provider call behind every tap in the buffer to
    save one menu row. The answer is handed to `DefinitionRoute_iOS`, which decides
    between a jump, a choice list and a haptic — unless
    `symbolIndex.currentRootGeneration`, pinned synchronously before the `Task`, has
    moved by the time it comes back, which is the macOS coordinator's guard carried
    over verbatim: the index refuses to answer for a folder the user has left, but
    the candidates cross one more main-actor hop to reach the route, and a folder
    change (a picker open, a bookmark restore, or closing the folder) landing inside
    that hop would present a declaration from the previous project. Silently, no
    haptic — the user asked for a different folder. **Completion** is recomputed on
    every text change *and* every selection change (a caret move invalidates the
    strip as surely as a keystroke — the word it answers is no longer the word being
    typed), behind a 150 ms debounce and a generation token, gated on a bare caret,
    no `markedTextRange` (marked text is uncommitted input the input method still
    owns) and at least two typed characters — **or a member position**
    (`IdentifierScanner.memberContext(in:at:)`), asked before the length gate and
    bypassing it, since the typed `.` is itself the request; the request then
    carries the member context and the file's `language` (the keyword source, `nil`
    meaning no keywords rather than some default language's). The caret is re-read
    *after* the await
    for the same reason macOS does it, and it carries the same second half macOS
    carries: matching the live partial word is not enough at **any** prefix length,
    because a member-only list and an ordinary list answer the same typed
    characters with different candidate *sets*, so the caret must still be in the
    same member state — **receiver and all** — the rows were computed for
    (`memberContext(…).map(\.receiver) == member.map(\.receiver)`, `map` rather
    than `?.` so "not a member position" cannot flatten into "a member position
    with an unnamed receiver"). The empty prefix makes that most obvious — it
    compares equal to the also-empty partial word anywhere there is no word at all,
    so any other dot in the buffer would inherit the previous one's list — but
    `worker.na`'s member-only list is just as wrong over an unrelated `na`, which is
    why the compare is not nested in the zero-length case. `showCompletions(_:answering:in:)` records that
    member position as `answeredMember` so the *insertion* guard can make the same
    comparison; it calls
    `reloadInputViews()` only when the strip's **presence** changes, not per
    candidate list, because it visibly re-lays the keyboard and per keystroke would
    read as a flicker; an empty list removes the bar rather than showing an empty
    one. `tearDownCompletions(in:)` pairs the same call with its own detach — the
    accessory view is cached by the *responder*, so clearing the property alone can
    leave the strip on screen over the incoming file, the one outcome that method
    exists to prevent. Insertion goes through the coordinator's existing `applyEdit`, so it is one
    undo step and passes the programmatic-edit guard — a candidate ending in `(`
    cannot fall into `AutoPairEngine` and collect a closer it never asked for — and
    it recomputes the prefix range at tap time rather than trusting the one the
    provider answered (the strip is a live view, and a tap can land after another
    keystroke has moved the word it answers), re-checking it with **the same
    matcher the candidates were chosen by**, `FuzzyMatch.matches(_:query:)`. That
    is a correctness rule rather than a refinement: the provider offers
    case-insensitive prefix *and* subsequence matches (`arr` still offers
    `ArrayBuffer` just ranked below `arrayCount`, and `arrBuf` offers it too), so
    any narrower guard — the `hasPrefix` test this replaced — would let the user
    tap a perfectly valid row and have nothing at all happen, with no feedback
    explaining it. That matcher test is the *second* guard. The first is the same
    member-state compare the post-await re-check makes, made here at every prefix
    length too: the position the rows answered is remembered as `answeredMember`
    (recorded by `showCompletions(_:answering:in:)` alongside the rows it is
    showing, cleared by an empty list and by `tearDownCompletions(in:)`), and its
    **receiver** — not merely "some dot is here" — must equal the live one. Only
    then is a **zero-length** range accepted, as the bare typed `.`, where there is
    no typed text to match against and the empty range at the caret is already the
    right insertion point; everywhere else a zero-length range means the word the
    tap answered has moved, and the tap is dropped. All of this matters
    because a caret move does not clear the strip synchronously:
    `textViewDidChangeSelection` schedules the same 150 ms debounce a keystroke
    does, so for that window the previous receiver's rows are still on screen — and
    without the compare a tap in it inserts a member of `Worker` at the `other.`
    caret, or one of `worker.na`'s members over an unrelated `na` that happens to
    fuzzy-match. It
    then clears the strip: `applyEdit` fires
    `textViewDidChange` synchronously, and offering longer names the instant a
    choice was made is how a completion strip turns into a treadmill.
    `dismantleUIView` tears the strip down alongside the highlighter, since an
    accessory view is attached to the *responder* and nothing else would drop it.
  - `iOS/CompletionBar_iOS.swift` — the iOS completion surface: a QuickType-style
    horizontally scrolling row of candidate buttons installed as the editor's
    `inputAccessoryView` (plan Decision 1). **A strip and not a popup**, because a
    floating list anchored to the caret is the macOS answer for a pointer: on a
    phone the caret is under a finger, above a keyboard, near a magnifier loupe, and
    a popup there would sit on top of the very code being read while fighting the
    keyboard for the same space. The strip never covers text, never steals a
    keystroke, and behaves identically with the on-screen and a hardware keyboard,
    so iPad and iPhone share one surface. **Plain UIKit rather than a hosted SwiftUI
    view**, because an input accessory is attached to the responder rather than to a
    hierarchy SwiftUI manages, and hosting would mean owning a
    `UIHostingController` whose lifecycle no parent controller drives. Fixed height
    reported through `intrinsicContentSize` with `allowsSelfSizing = false`, so a
    long candidate cannot grow the bar and push the keyboard down mid-sentence;
    monospaced button titles, because a candidate is code and a proportional font
    makes `l`/`1`/`I` ambiguous in exactly the list where the user is choosing
    between similar names. `setItems` returns early on an unchanged list, so a
    debounce that re-answers the same prefix does not reset the scroll position out
    from under a reaching thumb. Thin glue: the words and their order arrive already
    ranked and capped from `SymbolIntelligenceProvider`, and the coordinator — not
    this view — decides what range a tapped word replaces.
  - `iOS/DefinitionRoute_iOS.swift` — the navigation half of Go to Definition on
    iOS: the peer of the macOS `activateSearchMatch` + `EditorRevealState` pair,
    collapsed into one object because iOS has neither a menu bar to drive the jump
    nor a window-scoped state container to route it through. **The text view does
    not navigate itself** — opening (or re-selecting) the declaration's tab is the
    *root view's* job, since it owns the `WorkspaceModel`, the compact-width stack
    and the security scope the read happens under, while the editor coordinator
    knows only an offset and can only ask. So this reference type sits between them,
    the shape `DiffRoute_iOS`/`MergeRoute_iOS` already establish, held by
    `RootView_iOS` (which installs `openFile` and presents the dialog). It carries
    `choices` — the >1-candidate list, `Identifiable` by *position in the ranked
    list* rather than by anything derived from the symbol, because two overloads can
    share a name, a file *and* a line and a `ForEach` over colliding ids would drop
    rows the provider deliberately kept — and `reveal`, the one-shot, token-guarded
    "select this range in this tab" request, verbatim the macOS
    `EditorRevealState.Request` contract and for the same reason: activating a
    definition may *open* the file, so the editor that will show it does not exist
    yet when the jump is decided. Comparing the token rather than the value is what
    makes jumping to the same declaration twice a legitimate second request.
    `consumeReveal(token:)` retires a request the editor applied, and it is
    **required rather than tidy**: the coordinator's `appliedRevealToken` dies with
    the coordinator, and on compact width the editor lives in a
    `navigationDestination` the user can pop and re-enter, which builds a fresh one
    starting from `0` — a request left standing here would then be applied a second
    time, yanking the caret on a screen opened for an unrelated reason. The token
    guard on the clear keeps a *newer* jump, issued between the editor's deferred
    application and the call, from being thrown away.
    `present(_:)` turns the count into an outcome — zero is deliberately quiet (a
    light `PlatformFeedback` haptic, no alert: the user tapped a word the index does
    not know, which is an ordinary outcome of asking), one navigates, several open
    the dialog — and a `navigate` whose `openFile` answers `nil` (the index named a
    file deleted or moved since the last walk) warns instead. Row text is
    `DefinitionCandidate.displayLabel`, so both platforms show the same string.
  - `iOS/FilePicker_iOS.swift` / `iOS/SecurityScopedBookmarks.swift` — document-
    picker folder/file open + the `SecurityScopedFileService` decorator that
    brackets every `FileService` op with the registered scope's access grant;
    bookmark persistence via Core's `BookmarkStore`/`ScopedFileAccess`. Every
    mutating method is *forwarded* through `withScope` rather than left to inherit
    the protocol extension's default — including `ensureDirectory(at:)`, so a whole
    created chain lands under the covering scope's grant (iOS has no tree
    create/rename UI yet, so this is consistency, not a live call site). The two
    *metadata* readers are forwarded for the same reason, and there the default is
    not merely inconsistent but wrong in effect: `fileByteCount(at:)` and
    `fileStamp(at:)` both default to `nil`, which every caller reads as "unknown,
    so do the work" — the oversize check in `readTextIfNotBinary` would then decode
    a whole file into memory before measuring it, and the symbol index's stamp gate
    would re-read and re-parse the entire project on every refresh — which iOS does
    run, after each working-tree rewrite the app performs.
    A third non-mutating reader is forwarded for a *different* reason:
    `isExecutableFile(at:)` has no default at all (it is the install engine's
    `.gzip` gate — see `core-workspace.md`), so the compiler requires it here, and
    forwarding it through `withScope` is what keeps it honest — outside an active
    grant `access(2)` answers "no such file", which the gate would read as a good
    executable that arrived unrunnable. Nothing on iOS installs a language server,
    so the call site is macOS's alone; the forwarding is what stops the decorator
    from being the one conformer that answers a gate wrongly.
    `SecurityScopedFileService` also conforms to `SecurityScopeProviding` (a small
    `AnyObject` protocol vending `withSecurityScope(covering:_:)`): `LibGit2Service`
    touches the working tree/index directly via `FileManager`/libgit2 rather than
    through `FileServicing`, so it can't rely on the decorator's per-op bracketing —
    it instead takes a `SecurityScopeProviding` and runs every git operation under
    the covering registered scope's grant (without it, on a real device every git
    operation — Local Changes / Log / revert / merge staging — would fail outside an
    active scope). The registry (`scopedURLs`) is `NSLock`-guarded and the service is
    `@unchecked Sendable` because it is read from `LibGit2Service`'s serial git queue
    while mutated on the main actor (folder open/close); `FileAccessController`
    releases the previous root's scope (`unregister`) before registering a new folder
    so stale grants don't accumulate. The "which registered scope covers this target"
    decision is the pure, tested `ScopedFileAccess.path(_:isWithin:)` in Core (an
    empty root scopes nothing). The iOS folder-open path (`RootView_iOS.handlePicked`)
    also synchronously registers the switch with `LocalChangesModel`/`CommitLogModel`
    (`prepareForFolderChange`/`prepareForRefresh` + a generation-pinned refresh),
    mirroring `PisakaApp.openFolder`, so an in-flight revert can't keep mutating the
    repo the user just left.
  - `iOS/TabStrip_iOS.swift` / `iOS/SettingsView_iOS.swift` — the open-tabs strip/
    switcher (form picked by Core's `TabLayout.presentation`) and the Preferences
    sheet bound to `SettingsStore`. `SettingsView_iOS` also carries the Personal
    Access Token section (Part B): enter / save / delete a PAT by remote host via the
    `KeychainCredentialStore`, the destination the branch-create flow directs the
    user to on a `credentialsRequired` outcome. It also carries the **LeetCode**
    section (LC-1, full entry in `core-leetcode.md`): the account row (Sign In…
    raising the login cover, Sign Out always through
    `LeetCodeWebSession.signOut(model:)` so the cookies go with the Keychain item),
    the solutions folder with Change… (the document picker, adopted as a
    security-scoped bookmark by `LeetCodeFolder_iOS.adopt`) and a "Use Default"
    button shown only while an override is in force, and the default-language
    picker bound straight to `settings.leetCodeLanguage`. It observes the
    `LeetCodeModel` itself — unlike `RootView_iOS`, which holds it unobserved — and
    takes the `SecurityScopedFileService` so a picked folder is registered for this
    session while its bookmark covers the next. Its last section is "About", a
    single `NavigationLink` to `AcknowledgementsView_iOS` — a push rather than
    another sheet, the `Form` already sitting in a `NavigationStack`, and the
    peer of the macOS Preferences "Acknowledgements" tab.
  - `iOS/AcknowledgementsView_iOS.swift` — the iOS Acknowledgements screen: a
    `List` of dependencies (name + SPDX) pushing `LicenseTextView_iOS`, the
    detail screen carrying that entry's identity (name, SPDX, version/revision,
    origin) and the full license text. Two levels rather than the macOS split
    view because that is what a phone has room for; everything else matches the
    macOS peer, deliberately — the text is the shared `LicenseTextView`, rendered
    **whole** (never truncated or reflowed: the copyright lines and the
    permission notice are the obligation). Because that view owns its own
    scrolling (which is what lets TextKit lay out lazily), the detail screen pins
    the identity header above it rather than putting both in one `ScrollView`,
    and gives the pane an explicit `.frame(maxWidth: .infinity, maxHeight:
    .infinity)`: without a greedy frame the `VStack` falls back to
    `UITextView.sizeThatFits`, which reports the *content* height (tens of
    thousands of points for libgit2), and a child laid out taller than the screen
    has its own scrolling neutralized — the silent truncation the whole pane
    exists to prevent. The macOS peer needs no such frame, `NSScrollView` having
    no intrinsic size. The loader's `documents`/`failureDescription` are read
    through *computed* properties rather than stored ones, because a
    `NavigationLink`'s destination is built when the Preferences form's body runs
    — a stored property would read the whole `Licenses/` directory off disk for a
    screen that may never be opened, and the loader's cache makes the repeated
    lookup free;
    `version` is omitted when `nil` instead of rendered blank, `revision` is
    always shown in full, `origin` is a `Link` exactly when Core's
    `LicenseNotice.originURL` is non-nil (the `https://` remotes) — the same rule
    the macOS screen asks, kept in Core so the two cannot drift —
    and `LicenseCatalogLoader.failureDescription` replaces the list when the
    bundle is broken so "no dependencies" is never the silent reading. Thin view,
    untested; the logic is Core's `LicenseCatalog` (`core-services.md`).
  - `iOS/LibGit2Service.swift` — the iOS `GitServicing` implemented as a **direct
    C binding** against libgit2 (the in-process peer of the macOS
    `GitCLIService`), producing the *same* Core value types the CLI parsers do
    (`ChangedFile`/`FileStatus`/`Commit`/`GitError`/`PartialRevertError`): the
    Local Changes surface (`repositoryRoot`/`changedFiles`/`headContents`/`blob`/
    `revert` with the same per-`FileStatus` edge cases), the Log surface
    (`commits`/`references`/`commitChanges`/`fileContents`), and the conflict
    surface (`stage`/`stageRemoval`). It deliberately does **not** implement
    `blame(fileURL:)` — the annotation column is a macOS-gutter feature and iOS has
    no gutter — inheriting the protocol extension's `[]` default. The
    branch-switcher surface is likewise a
    direct libgit2 binding: `currentBranch` (via `git_repository_head` /
    `git_reference_*` — unborn/detached → `nil`), `checkout` (`git_checkout_tree` +
    `git_repository_set_head`, a `GIT_ECONFLICT` → `GitError.checkoutFailed` with the
    conflicting paths), and `createAndCheckout` (`git_branch_create` from the start
    ref's commit + checkout). `fetch(remote:root:)` performs a real HTTPS network
    fetch (Part B) via `git_remote_lookup` + `git_remote_fetch` over the built-in
    Apple TLS backend (no new dependency): a credentials callback wired into
    `git_fetch_options` supplies `GIT_CREDENTIAL_USERPASS_PLAINTEXT` (the host's
    `GitCredentials.username(...)` + the stored PAT as the password); with no token
    for the host it throws `GitError.credentialsRequired(host:)`, and a non-HTTPS
    `origin` (no host from `RemoteHost.host(...)`) surfaces a clear "HTTPS origin
    required" error. SSH remotes are unsupported on iOS (libgit2's SSH transport is
    exec-based — no subprocess on iOS), so the network path is HTTPS-only. It holds a
    `CredentialStore` (the `KeychainCredentialStore`) for the callback, and runs all
    calls on the service's serial queue under the security scope like the rest of the
    libgit2 code.
  - `iOS/KeychainCredentialStore.swift` — the iOS view-layer `CredentialStore`
    (Core protocol) implemented over the `Security` framework (Keychain): save /
    lookup / delete a Personal Access Token keyed by remote host (a generic-password
    item), no new dependencies. Thin IO (untested), the pure host-selection logic
    lives in Core's `GitCredentials`.
  - `iOS/LocalChangesView_iOS.swift` / `iOS/DiffView_iOS.swift` /
    `iOS/DiffRoute_iOS.swift` — the Local Changes list + two-`UITextView`
    side-by-side diff, presented as sheets / pushed screens.
  - `iOS/CommitLogView_iOS.swift` / `iOS/CommitGraphView_iOS.swift` /
    `iOS/LogFilterBar_iOS.swift` — the Git Log list with the branch-graph gutter
    (UIKit over `CommitGraphLayout`) and the filter/search bar.
  - `iOS/MergeView_iOS.swift` / `iOS/MergeRoute_iOS.swift` — the adaptive 3-pane
    conflict resolver (side-by-side on regular width, stacked on compact).
