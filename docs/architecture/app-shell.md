# Pisaka app (macOS) — PisakaApp orchestration, watcher, autosave & session controllers

Design documentation moved verbatim from the root `CLAUDE.md` (which now holds only a one-line-per-file index). Each entry records a file's contract, invariants and the reasoning behind non-obvious decisions — read the relevant entry before modifying that file, and update it when behavior changes.

  - `PisakaApp.swift` — `@main` App, menu commands and shortcuts
    (Cmd+N/O, Cmd+Shift+O for "Open Folder…", Cmd+S/W), and the save/close and
    folder/file-open orchestration that ties the model to the file panels. The
    Terminal, Git Log, Local Changes, Problems, Usages and Pull Requests are all
    *bottom
    dock
    panels* sharing one dock: it owns a
    single `@State private var bottomPanel: BottomPanel? = nil` (`nil` = no panel,
    passed as a binding to `ContentView`, which draws the always-visible
    Terminal/Git/Changes/Problems/Usages/Pull Requests bar) and six View-menu commands — "Show/Hide Git Log"
    (Cmd+Shift+L), "Show/Hide Terminal" (Cmd+Shift+T), "Show/Hide Local Changes"
    (**Cmd+Shift+C**, moved off Cmd+Shift+G — the macOS standard for "Find
    Previous", which the Find menu below claims), "Show/Hide Problems"
    (**Cmd+Shift+M**, the language servers' published diagnostics) and "Show/Hide
    Usages" (**Cmd+Shift+U**, the last Find Usages answer — showing the panel
    *fetches nothing*, because a panel that re-ran the previous query on every open
    would spend a project walk on a question nobody re-asked) and "Show/Hide Pull
    Requests" (**Cmd+Shift+R**, which — unlike Usages — *does* read on open, from
    the panel view's own `.onAppear` rather than from this file: `gh`'s answer
    goes stale on GitHub's clock and the feature refuses to poll, so opening the
    panel is the read, `core-github.md`), their labels reflecting the
    active state —
    all routed through one shared `togglePanel(_:)` handler (also wired to the
    bottom bar via `ContentView`'s `onTogglePanel` so a button and its matching menu
    command behave identically). `togglePanel(.terminal)` creates the first session
    (`terminalSessions.newSession(projectRoot: model.projectRoot)`) when none exists
    yet, then applies the pure `BottomPanel.toggled(bottomPanel, selecting:)` to flip
    the shown panel. It also exposes the Run File feature: a `CommandMenu("Run")`
    with a "Run File" item bound to ⌘R (`.keyboardShortcut("r", modifiers:
    .command)`) — enabled only when the selected tab has a `url` whose name passes
    `RunCommand.canRun`, running that url — and a `runFile(url:)` handler (also wired
    to `ProjectTreeView`'s file-row "Run" item via the `onRun` callback threaded
    through `ContentView`). `runFile(url:)` resolves the command with
    `RunCommand.command(forFileName:absolutePath:)` — on `nil` (unrunnable type) it
    beeps (`PlatformFeedback.warning()`) and shows `presentCantRun()`
    (`PlatformAlert.presentMessage` "Can't run files of this type.") — saves the
    file's open tab first when it is dirty (`model.fileID(forURL:)` +
    `model.isDirty(for:)` → the existing `save(id:)`) but *only* after refusing
    via `revertInFlight()` (the save is an uncoordinated disk write that would
    race an in-flight revert's off-main `git checkout`, so it is gated like the
    project-tree file ops) and aborting the whole run if that save fails (so it
    never runs stale on-disk contents that no longer match the editor), computes the working
    directory via `RunCommand.workingDirectory(projectRoot: model.projectRoot,
    fileURL:)`, shows the terminal panel (`bottomPanel = .terminal`), and calls
    `terminalSessions.runFile(url:command:workingDirectory:title: "Run: \(url
    .lastPathComponent)")`. The Run menu also holds a "Run Test" item bound to ⌘U
    (`.keyboardShortcut("u", modifiers: .command)`) — enabled only when
    `canTestSelectedFile` (`TestCommand.isTestFile` on the selected tab's url) —
    and a `testFile(url:)` handler (wired to `ProjectTreeView`'s file-row
    "Run Test" item via the `onRunTest` callback threaded through `ContentView`).
    `testFile(url:)` mirrors `runFile`: it assembles a `ProjectTestEvidence` via a
    private `projectTestEvidence()` — lists `projectRoot` through `fileService`
    (empty evidence when no folder is open — the listing already carries the
    dotfile signals like `.mocharc*`, since only `.git`/`.DS_Store` are hidden, so
    no separate probing is needed), and reads the one runner-selecting manifest
    whose *contents* matter (`package.json` — the JS/TS vitest/jest/mocha substring check; every
    other runner is chosen by an entry's presence, not its contents), with
    directory-/file-read failures swallowed — resolves the command via
    `TestCommand.command(forFileName:absolutePath:evidence:)`, on `.runnerUndetected`
    beeps + alerts "Couldn't detect a test runner for this project.", and on
    `.command` runs the same tail as `runFile` (`revertInFlight()` gate, save the
    dirty buffer aborting on failure, `bottomPanel = .terminal`,
    `terminalSessions.testFile(..., title: "Test: \(url.lastPathComponent)")`).
    It also exposes the whole search feature. A `CommandMenu("Find")` holds five
    items — "Find…" (⌘F → `search.open()`), "Replace…" (⌘⌥F →
    `search.openReplace()`), "Find Next" (⌘G), "Find Previous" (⌘⇧G, the shortcut
    "Show/Hide Local Changes" vacated for it), all four `.disabled(model.selectedID
    == nil)` since they act on the open editor, and "Find in Files…" (⌘⇧F →
    `openProjectSearch()`, `.disabled(model.projectRoot == nil)` because the search
    *is* a walk of the opened folder). It owns the window-scoped `@StateObject
    search = EditorSearchState()` (threaded into `ContentView` → `CodeEditorView`;
    the bar's contents survive a tab switch, which is why it cannot live in the
    editor's coordinator) and `@StateObject reveal = EditorRevealState()`, plus the
    `@StateObject projectSearch: ProjectSearchModel` and a `private let
    projectSearchWindows = ProjectSearchWindowController()` whose `closeAll()` joins
    the diff/merge controllers in the `willTerminateNotification` observer — as does
    `private let leetCodeBrowserWindows = LeetCodeBrowserWindowController()`, the
    single ⌘⇧B problem-browser window (`core-leetcode.md`), held the same way and
    for the same reason — and `private let localHistoryWindows =
    LocalHistoryWindowController()`, the single ⌘⇧H revisions window, a third of
    the same shape. Beside them sit `private let localHistory: LocalHistoryModel`
    and `private let localHistoryBrowser: LocalHistoryBrowserModel` — plain
    stored `let`s, the `commitDialog` arrangement: the capture model publishes
    nothing and the browser is observed by its own window rather than by this
    one, so neither belongs in a `StateObject` the main window re-renders on
    (`core-local-history.md`). The
    project-search model is the reason `PisakaApp` has an `init()` at all: its two
    buffer closures are `let`s taken at construction and must close over the *very*
    `WorkspaceModel` the app publishes (Core deliberately keeps no reference to the
    workspace), which a property initializer cannot reach — so `init()` builds the
    workspace — with `viewerTabsEnabled: true`, the one place in the repository
    that turns the database viewer's routing on (`core-database-viewer.md`) —
    wraps both in `StateObject`, and every other stored property keeps
    its inline default. `DatabaseViewerTabs`, the viewer's per-tab connection
    owner, is a third `StateObject` built in the same `init()` (it follows the
    workspace's `$openFiles`) and injected as an `.environmentObject`. It is
    handed its two write closures separately, from the scene's start-once
    `.onAppear` block: `databaseViewers.start(isWriteBlocked:didWrite:)` wires the
    disk-writer gate as a *question* (`localChanges.isReverting`, read directly
    rather than through `revertInFlight()`, which beeps and runs a modal alert on
    top of the viewer's own banner — two notices for one refusal) and the
    generation-pinned `refreshLocalChanges()` a committed cell edit owes the
    panel. `performMove` — the one body the tree's rename and drag-and-drop move
    share — additionally calls `databaseViewers.retarget(id:url:)` for every tab
    the rename plan retargeted: a viewer tab's model holds the path its *write*
    opens read-write, and `applyRenamePlan` moves the tab without telling it. The
    connection is deliberately left alone there, because a rename moves the name
    and not the inode (`core-database-viewer.md`).
    `PullRequestCoordinator` is a fourth `StateObject`, injected on the same
    modifier and wired in the same start-once block —
    `pullRequests.start(root:branchSwitcher:isWriteBlocked:runBracket:confirmCheckout:didWrite:)`
    — for the viewer's reason and one more: `runBracket` is the scene's *whole*
    involvement in the eighth and ninth gated operations (it hands
    `runBranchOperation(_:_:_:)` over as a closure, and the coordinator names the
    event at each of its three call sites — `.pullRequest` for the checkout,
    `.branch` for the post-merge tail's switch, `.pull` for its
    `pull --ff-only`), `confirmCheckout` is the same dirty-tree warning
    `switchBranch` and `checkoutRemote` ask, and `didWrite` is what none of the
    other seven need, because `gh pr checkout` moves the branch from outside
    `BranchSwitcherModel` and the widget has to be told to re-read it. The
    terminate observer calls `pullRequests.terminateNow()` beside the language
    servers' own; everything else about the feature — its transport, its refresh
    triggers, its three bracket sites, the merge and the post-merge tail's order
    — lives in `PullRequestCoordinator.swift` (`core-github.md`).
    `openBuffers` returns every titled **text** tab's text (dirty
    or not — what the user sees is what gets searched; a file absent from the
    snapshot goes down the on-disk branch, and a url-less "Untitled" buffer names
    no file so it is left out) and `applyBufferText` writes a replacement back through
    `model.updateText`, so a replaced open file goes through the editor rather than
    being written under it (autosave then persists it like any other edit). `openFolder()` calls `projectSearch.prepareForSearch(root:)`
    *synchronously* alongside the Local Changes / Log registrations (there is no
    "close folder" action, so this is the only call site); no refresh `Task` is
    spawned, since the window searches only when the user asks. The same method
    is where `localHistory.pruneStore()` fires — the once-per-open retention
    sweep, which takes **no root** because it sweeps every project area in the
    store (a project reclaimed only when it is reopened is a project never
    reclaimed), and which is deliberately fire-and-forget and deliberately holds
    **no** generation token: it deletes only revisions that are already past
    retention, so a sweep landing after a folder switch is not a stale answer that
    could land over a newer one, it is work that was owed anyway
    (`core-local-history.md`).
    `activateSearchMatch(url:range:)` opens the file through the ordinary
    `openFile(url:)` path (so an already-open tab is re-selected, not duplicated),
    resolves the tab id, and records the range with `reveal.reveal(fileID:range:)` —
    a failed open resolves to no tab, so nothing is revealed. It is **also the
    destination of Go to Definition** (⌘-click / ⌃⌘J), which names a declaration's
    file and name range instead of a search hit: the two want the same three steps,
    and sharing them is what keeps a jump inside the file already being edited on
    the same code path as one across the project. The **Problems panel is its
    third caller** (D34's sibling surfaces): a row activation hands over
    `(url, range)` and takes this exact path, so opening a diagnosed file and
    revealing its squiggle cannot drift from how every other surface opens and
    reveals.
    The same `init()` additionally builds the **symbol index**: a
    `SymbolIndexModel` over the *same* `openBuffers` snapshot closure (so Find in
    Files and go-to-definition cannot disagree about what an open tab's text is) plus
    a `SymbolIndexController` over it. Its `extractSymbols` argument is a **direct
    synchronous reference** to `SymbolExtractor.symbols(in:language:fileURL:)` — no
    `Task`, no actor hop, because the model calls it only from inside its own
    off-main serial queue (plan Decision 7; the reasoning is in
    `core-intelligence.md`). Both are plain `let`s, deliberately **not**
    `@StateObject` — the `commitDialog` precedent, with an even sharper argument
    here: the model republishes its `index` after *every chunk* of a walk, so
    subscribing this scene's `body` to it would re-create `ContentView` (and with it
    the project tree, the tab list and `CodeEditorView.updateNSView`) dozens of times
    while a project is indexed, for a value nothing in the window reads. The editor
    surfaces ask through `symbolIndex.provider`, which reads the latest snapshot on
    demand, and `ContentView` threads the *controller* (not the model) down to
    `CodeEditorView` alongside `onGoToDefinition`. `openFolder(url:)` calls
    `symbolIndexController.reset()` + `symbolIndex.prepareForFolderChange(root:)`
    **synchronously**, in the same main-actor turn as every other collaborator, and
    only then spawns the pinned `Task { await rebuild(root:request:) }` — the
    generation bump and the index clear happen before any hop, so an in-flight walk
    finds itself superseded and no symbol from the folder the user just left stays
    jumpable while the new one is read (a definition that opens a file from the
    previous project is worse than none). Unlike Find in Files a walk *is* spawned:
    the index has to exist before the user asks, since there is no window to open
    first. Because this is the sole place a folder switch is registered, the
    launch-time session restore builds the index exactly as a user-driven open does.
    **`private let editorConfig = EditorConfigModel(fileService: FileService())`
    rides the same two points** and is a plain stored reference for the identical
    reason (it publishes nothing, and observing it would put `ContentView` and
    `CodeEditorView.updateNSView` on an update path for a value this `body` never
    shows); it is threaded through `ContentView` into `CodeEditorView`, the only
    thing that asks it anything. `openFolder(url:)` calls
    `editorConfig.noteProjectRoot(url)` **synchronously**, right after
    `model.openFolder(url:)` and before any collaborator can ask a question — the
    model clears its cache on a root change, so a configuration resolved under the
    folder the user just left can never be returned for a file in this one. The call
    is unconditional: a re-open of the same root is a no-op inside the model, which
    compares the roots canonically itself. Like the index it is a **reader** — it
    opens files and writes none — so it neither raises `autosave.suspend()` /
    `localChanges.beginRevert()` nor is gated by them. Two more invalidation calls
    complete its lifecycle here, both filling holes `IgnoreSelf` leaves in the
    watcher: `notifyIndexOfProjectFileChanges()` drops the cache too (ahead of its
    root guard — unlike the index, this one needs no root to be told anything), so
    the app's own worktree rewrites are covered; and `noteEditorConfigWrites(_:)`
    drops it when a *written* url is a `.editorconfig`, called from `save(id:)`
    and from the autosave's `onSaved` — whose signature gained the urls it wrote
    for exactly this — because editing a `.editorconfig` in Pisaka itself is a
    self-write the watcher never reports and is the likeliest way anyone changes
    one. Narrow on purpose: an ordinary save is the app's most frequent write, and
    clearing on every one would put a resolution walk on the first keystroke after
    each autosave burst (`core-editorconfig.md`).
    Beside it sits `private let saveTransform = SaveTransformController()`, the one
    funnel every macOS save passes through before it writes (its full entry is in
    `core-editorconfig.md`). Owned **here** rather than by the editor because the
    saves it serves are menu commands and autosave ticks, not editor events: it has
    to survive every tab switch and every window rebuild, so it is attached from
    `CodeEditorView.makeNSView` and holds the editor weakly. Like `editorConfig` it
    neither raises `autosave.suspend()` / `localChanges.beginRevert()` nor is gated
    by them — it writes nothing itself; it only rewrites the buffer the save about
    to run is going to write. Three call sites, and only these three: `save(id:)`
    calls `prepareForSave(ids:)` **after** the writer-gate refusal and before the
    write, deliberately unconditional on the dirty flag (⌘S writes the file either
    way), which is how the close prompt's Save and the `runFile`/`testFile` pre-run
    saves inherit it without a second call site; `saveAs(id:)` calls
    `prepareForSaveAs(id:destination:)` once the panel is answered — the
    configuration that applies is the *destination's* — and only after
    `model.isDestinationOpenElsewhere(_:for:)` has cleared the one condition
    `saveAs` refuses on, so a rejected Save As leaves the buffer as the user typed
    it; and `AutosaveController`'s own triggers and both flush paths, through
    `prepareForAutosave(ids:abandoningBuffers:)`. **Where the buffer is being
    abandoned the caret is not protected**: the close prompt's Save passes
    `abandoningBuffer: true` through `save(id:)` — and on through `saveAs` into
    `prepareForSaveAs(id:destination:protectingCaret:)` when the buffer is
    untitled, the one branch where the close prompt changes method — and the quit
    and folder-switch flushes pass `abandoningBuffers: true`, so the file is
    trimmed in full. The folder switch reaches that flag on a **second** flush,
    taken only once the unsaved-buffer refusal has been passed: the first flush is
    what decides that refusal, and a refused switch — like the carrying path, which
    force-closes nothing — leaves every buffer open and being edited, so asserting
    abandonment before either question is answered would trim the line someone is
    still typing on. Two flushes cost nothing where nothing was spared, since
    `saveAllDirty()` is idempotent. There
    is no caret left to protect and no next save to defer a spared run to, which is
    the answer iOS's one save already gives for the same button. The commit
    dialog's flush keeps protecting: editing continues after it.
    **The LSP layer hangs off exactly those points and nowhere else** (phase 2a; the
    layer itself is `core-lsp.md`). `init()` builds one `LSPWorkspace` with
    `LSPProcessTransport.make(for:root:)` as its transport factory — the *only* thing
    handed over from the app side, the `GitServicing`/`GitCLIService` split one level
    down — and installs a `RoutingIntelligenceProvider` on the **controller** through
    `installProvider(_:)` rather than plumbing anything through the views: they read
    `symbolIndex.provider` already, so composition here changes no view signature and
    no view can tell which side answered. The router's fallback is literally
    `symbolIndex.provider`, the same live-reading instance, so a language no server
    serves takes exactly the path it took before this phase existed
    (`RoutingIntelligenceProviderTests` pins that by equality). `LSPToolchain.prewarm()`
    moves the `xcrun` lookup off the main thread at startup; it is an optimisation
    only. The workspace is a plain stored `let` like the window controllers, and that
    owning reference is load-bearing: `LSPSession`'s read task holds its session
    *weakly*, so a workspace nobody references would stop reading. `openFolder(url:)`
    calls `lspWorkspace.prepareForFolderChange(root:)` **synchronously** beside the
    index's, for the same reason and with the sharpest consequence of the three — a
    server is *initialized for one root*, so an answer from the previous project's
    server would name a file under a folder the user has left — and then awaits
    `shutdownAll()` in a `Task`, but **only when the root actually changed** (the
    `commitDialog` idiom), so re-opening the same folder does not throw away a
    resolved build system. That leaves one narrow window, stated rather than
    engineered around: a request landing between the synchronous call and the
    teardown sees the *new* root and may start its server, which the teardown then
    stops — one wasted launch, one tree-sitter answer, and no restart budget, since a
    superseded launch is not a failure and a deliberate shutdown leaves no dead
    session for the next request to count as a crash. `didClose(url:)` sits **inside**
    `forgetIndexedBuffer(_:)`, under that method's existing "no other tab shows this
    file" guard rather than a second copy of it, because the index and the server must
    agree about when a file stops having a buffer; it is fire-and-forget, since a
    server that cannot be told opens the document afresh on its next request. None of
    this touches the writer gate: the LSP layer is a **reader**, so it neither raises
    `autosave.suspend()`/`localChanges.beginRevert()` nor is gated by them.
    **The diagnostics channel (D29–D34) composes at the same point and nowhere
    else.** `init()` builds one `DiagnosticsModel` (a plain stored `let`, the
    workspace's own rule — this scene never observes it; the three surfaces subscribe
    themselves), sets `lspWorkspace.onDiagnostics` to forward every event into it —
    pushes *and* the teardown clears, which is what makes every server death blank
    all three surfaces synchronously — captured directly rather than through `self`
    for the registry closures' reason: this runs during `init`, and the sink must
    outlive it holding the model. Beside it, one `LSPDocumentSyncController` over the
    model and the workspace (full entry in `app-editor.md`). The folder switch
    registers with both in the same main-actor turn as every other collaborator:
    `diagnostics.prepareForFolderChange()` + `lspDocumentSync.reset()` run
    synchronously beside the index's and workspace's tokens — no push routed from an
    old project's server can land, and no pending debounce flushes new-folder text at
    an old project's still-live server. Only on a genuine *switch*, like the LSP
    teardown it sits beside: re-opening the folder already open leaves every tab in
    place, so nothing would re-sync afterwards and wiping the store there would blank
    all three surfaces with nothing to repopulate them.
    **`syncOpenBuffersForDiagnostics(of:through:)` is the set-wide trigger the sync
    controller cannot supply itself**, and it has two callers. The controller's own
    trigger surface is per-buffer and view-driven (a tab open/switch through
    `CodeEditorView`, a settled keystroke), which leaves two moments where a whole
    *set* of buffers becomes a server's business at once and no view says so. The
    first is each of the three `updateRegistry` callbacks: diagnostics are the only
    push-only surface here — everything else is request-driven and recovers on the
    next completion/hover/⌘-click — and every trigger gates on `canServe`, which was
    false for that language a moment earlier, so without the re-sync consenting to a
    server, or gopls/rust-analyzer discovery finishing after launch (the ordinary
    cold-start order), leaves the file on screen undiagnosed until the user types.
    The second is `openFolder(url:)`, which is also the launch-time session restore:
    a restored session's *background* tabs have no `CodeEditorView` behind them, so
    the tab-switch trigger never fires for them and the server is never told they
    exist — the Problems panel would cover "files visited since launch" rather than
    the open ones. That call runs **inside the same `Task` that awaits
    `shutdownAll()`**, after the teardown rather than beside it: a sync issued in the
    switch's own turn would launch a server for the new root that `shutdownAll()`
    then stops, costing the launch and stranding the `didOpen` with it. It is
    idempotent (`prepare` sends nothing for text the server already holds), so the
    displayed tab syncing itself through the editor as usual costs nothing. `static`,
    so the `init`-time closure reaches it without capturing a half-built `self`.
    Tab close rides `forgetIndexedBuffer(_:)`'s
    existing guard too: `lspDocumentSync.noteBufferClosed(url:)` cancels that tab's
    pending flush beside the index call, before the fire-and-forget `didClose` whose
    document clear (D33) the model routes into its store — and
    `diagnostics.noteDocumentClosed(url:)` beside them, because that clear is emitted
    only for a URI the workspace still *held*: every teardown wipes its document
    table first, so a crash-then-close would leave the sync record and the buffer
    revision behind, and a file no server ever served was never in that table at all.
    This call is the one that fires for every close, which is what keeps the model's
    two maps bounded by the open tabs (`core-lsp.md`); arriving twice is a no-op. Nothing on any of these
    paths raises or takes the writer gate either; the model is a reader by D10,
    stated on its type.
    **Provisioning (phase 2b) is composed at the same point and pushed into the same
    workspace** — the layer itself is `core-provisioning.md`. `init()` builds the
    install engine over the two concrete seams (`LSPDownloadService`,
    `LSPArchiveUnpacker`) and the model over it, through
    `makeProvisioning(settings:)` so the default-constructed `ContentView` gets the
    same stack and the install root
    (`~/Library/Application Support/Pisaka/LanguageServers`) is spelled once. The
    whole of D16's wiring is one closure: `onRegistryChange` awaits
    `lspWorkspace.updateRegistry(_:)`, which is what makes an install servable and a
    removal terminate its process without a restart. It captures `lspWorkspace`
    directly rather than through `self`, since it runs during `init` and must outlive
    a half-built value. At launch, under the same one-shot gate as the session
    restore, `sweepStaging()` runs **synchronously first** — what it deletes is
    whatever a crash left half-written, and it is only safe because nothing can be
    installing yet — and `refresh()` follows in an unawaited `Task`, re-deriving the
    registry from the disk (the file system is the state, so there is nothing
    persisted to restore and no ordering against the session restore to get right).
    A language whose server has not been re-registered yet answers from tree-sitter
    for the moment it takes, exactly as it does when no server exists.
    **gopls (D17) is composed beside it as a second registry contributor**, through
    `makeGopls(engine:settings:)` and over the *same* `LSPInstallEngine`: it is not
    downloaded, but it lives under the same install root, is swept by the same
    `sweepStaging()`, is deleted by the same `engine.remove` and records its consent
    in the same `SettingsStore` dictionary. **rust-analyzer (D21) is composed the
    same way, as a third contributor**, through `makeRust(engine:settings:)` and
    over that same engine — the case that shows a *downloaded* server can also be
    toolchain-gated: it is a pinned manifest component installed by the shared
    `LSPInstallEngine`, but it contributes nothing without a `cargo`, so its model
    is shaped like gopls's rather than like 2b's. D16's wiring is therefore
    **three** `@MainActor` closures — `provisioning.onRegistryChange`,
    `gopls.onDescriptionsChange` and `rust.onDescriptionsChange` — each taking its
    own contributor's new value as a parameter and reading the other two's
    published ones, and each merging base entries first so `LSPServerRegistry`'s
    first-registration-wins rule leaves a hand-registered override intact. The
    order among the three decides nothing today (they serve disjoint languages);
    it is stated as 2b → Go → Rust because that is the composition order and the
    order the Settings tab lists them in. `init` also kicks off `Task { await
    gopls.discover() }` and `Task { await rust.discover() }` unawaited, at
    `LSPToolchain.prewarm()`'s position and for its reason: the search shells out
    (up to a login shell) and the Settings row reads `pending` until it answers.
    The Rust one carries a second reason the Go one does not: the banner's `.task`
    *awaits* discovery before it can silently install an already-accepted
    rust-analyzer, so it joins this task rather than starting a second search.
    `lspGoToolchain` and `lspRustToolchain` are stored `let`s rather than living
    only inside their models, because the terminate observer below needs them.
    `closeFile(id:)` (and every branch of its confirmation) routes through
    `forgetIndexedBuffer(_:)`, which hands the tab's entry back to disk only when no
    tab still shows the file — so the Cancel branch, and a file legitimately reached
    through two tabs (once by path, once through a symlink, since `fileID(forURL:)`
    matches canonically exactly as the index keys its files), leave the buffer mark
    where it is. **Every other path that stops a URL from having a buffer behind it
    routes through it too**, and must: a buffer-sourced entry is exempt from *both*
    halves of a refresh (it is neither re-extracted nor removed), so one that is
    never handed back pins a file into the index for the rest of the session.
    Those paths are `performMove(from:to:)` — the body a rename and a drag-and-drop
    move share (below) — where the tabs are retargeted to the destination, so the
    old path would otherwise answer lookups under a name that no longer exists,
    beside a second entry under the new one; and because a *folder* move retargets
    every tab beneath it, the old URLs are collected from the whole `planRename`
    plan, before the move and for the same dangling-symlink reason the plan is
    (forgetting only the moved item's own URL would strand every file inside it),
    `deleteItem` (whose affected URLs are
    captured alongside the tab ids, before the removal, for the same
    dangling-symlink reason the ids are) and the three post-git resyncs — the revert
    loop, `resyncOpenTabs` and the merge-apply reload — wherever they force-close a
    tab whose file the operation took away. Four `Find` menu items reach the focused editor through the responder
    chain rather than through any window-scoped state, because none of them
    carries state to survive a tab switch: "Go to Definition" at **⌃⌘J** (Xcode's
    binding, and free here — ⌘J and ⌃⌘F are AppKit's "center selection" and full
    screen), "Find Usages" at **⌃⌘U** and "Rename…" at **⌃⌘R** (deliberately
    *not* ⌘U and ⌘R, which are Run Test and Run File and stay untouched), and
    "Complete", which alone among the app's menu items carries **no key
    equivalent at all**. Its ⌃Space lives on `EditorTextView.keyDown` instead: a
    menu equivalent is claimed app-wide and is offered the keystroke before the key
    window's first responder, and ⌃Space is the one shortcut this app wants that
    carries no ⌘ — as a menu binding it swallowed ⌃Space out of a focused embedded
    terminal, which needs it as NUL (readline/Emacs `set-mark`), and beeped there
    instead, and did so only once a tab was open, since a disabled item does not
    claim its equivalent. The item stays for discoverability; ⌃Space, AppKit's stock
    ⌥⎋ and F5 all reach the same request. Both items are
    gated on a tab being open rather than on a project — a symbol declared in the
    buffer itself is indexed from that buffer, so a lone open file can still jump
    within itself — and anything else focused beeps rather than acting somewhere the
    user is not typing. Find Usages takes the same gate for a related reason: with
    no folder open the textual scan still answers for the buffer the question was
    asked in, which beats an empty panel for a command the user just invoked. Rename
    takes it too, and **only** it (decision 4 in the plan, D35 in `core-lsp.md`):
    whether a rename is *possible* is a question about the language server, and it
    is answered on invocation — before any sheet appears — rather than by greying
    an item out for a reason a menu cannot explain. "Complete" carries a **second** gate that "Go to
    Definition" does not: `!settings.completionEnabled` greys it out while the
    completion toggle is off (`core-services.md`), so an explicitly-invoked
    command is never a silent no-op. Only the menu item can say so, though —
    ⌃Space is deliberately not a menu equivalent (above) and AppKit's ⌥⎋/F5 are
    not ours — so those keystrokes still fire while off and are silenced one level
    down, by the delegate answering `[]` (`app-editor.md`). That asymmetry is why
    the toggle is enforced in the controller as well as here. Go to Definition is
    untouched by the toggle throughout: it shares the provider, not the gate.
    `reindexReloadedBuffer(id:url:)` is the counterpart of `forgetIndexedBuffer` on
    the *success* side of the three post-git resyncs **and of Replace All**: a tab
    whose buffer `reloadFromDisk` — or `applyBufferText` — just replaced is still
    buffer-sourced, so the
    `notifyIndexOfProjectFileChanges()` refresh beside it deliberately declines to
    re-extract or remove it. Only the *selected* tab re-indexes itself, through its
    live `CodeEditorView`'s content-replaced path; without this call a background
    tab would keep answering Go to Definition and completion out of the previous
    revision, at the previous revision's ranges, until the user selected or closed
    it. Immediate rather than debounced (a resync is a bounded set of files, not a
    burst), and re-indexing the selected tab twice is harmless — the second
    scheduling supersedes the first under the same key. It is also the only place
    that can tell the diagnostics channel about an off-screen wholesale
    replacement (D32): a background tab has no editor view whose content-replaced
    path would say so, so the call opens with
    `diagnostics.noteBufferReplaced(url:)` — dropping the document's set and its
    sync record outright, so a push computed against the pre-replacement text
    cannot pass the acceptance gate — *before* the immediate re-sync below it,
    whose push then lands against a fresh record.
    `replaceAllInProject(template:originGeneration:)` brackets
    `ProjectSearchModel.replaceAll` with
    the *same* coordination as `applyMerge`/`revertChanges`, because a project-wide
    Replace All is the third uncoordinated disk writer and touches files the user
    cannot all see: it refuses outright while `localChanges.isReverting`
    (`revertInFlight()`), then raises `autosave.suspend()` +
    `localChanges.beginRevert()` **synchronously before the first `await`**
    (balanced by `defer`), and afterwards — only when something actually changed —
    re-queries Local Changes and bumps `treeRevision` (the batch changed file
    contents on disk and the watcher ignores the app's own writes) and calls
    `notifyIndexOfProjectFileChanges()` for the files no tab owns. The files that
    *do* have a tab were replaced in the **buffer**, never on disk, so that refresh
    cannot reach them; they are resynced individually through
    `reindexReloadedBuffer(id:url:)`, selected by diffing each tab's text against a
    snapshot taken before the batch (`ReplaceSummary` counts files, it does not name
    them; the snapshot is keyed by tab id because two tabs can show the same file).
    It does **not**
    capture the project pin itself — its own synchronous prefix already runs
    *inside* the view's `Task`, i.e. after the window the pin exists to close — so
    `originGeneration` arrives from `ProjectSearchView.confirmReplaceAll` (read
    from `currentRootGeneration` right after the alert returns) through the
    two-argument `onReplaceAll: (String, Int) async -> ReplaceSummary?` closure and
    is passed straight to `projectSearch.replaceAll(template:originGeneration:)`.
    **Find Usages and Rename are the two commands this file added last, and only
    one of them writes.** It owns the `FindUsagesModel` as a **plain `let`,
    deliberately not `@StateObject`** — the `commitDialog`/`diagnostics` rule, and
    this model is its strongest case: a textual scan republishes once per walked
    chunk, and `@StateObject` would subscribe this scene's `body` to every one of
    them, re-creating `ContentView` with its non-`Equatable` closure parameters and
    putting the project tree, the tab list and `CodeEditorView.updateNSView` on the
    walk's republish path. `UsagesPanelView` observes it itself, which is what makes
    the rows appear. It is built in
    `init()` over the same open-buffer closure the project search uses — so a dirty
    tab is scanned as the user sees it rather than as the disk holds it — and over a
    *closure* returning `symbolIndexController.provider`, because the routing
    provider is installed during that very `init` and a model holding today's answer
    would keep asking it forever. `findUsages(_:)` **shows** the panel rather than
    toggling it (this is the answer to a command the user just invoked, and a ⌃⌘U
    that hid the results because they happened to be on screen would be the opposite
    of what was asked) and **reserves** a request generation
    (`usages.prepareForQuery(for:)`) *synchronously* before the `Task` hop, because
    unstructured tasks are not guaranteed to start in creation order and two quick
    presses must settle on the later question whichever runs first. Reserved rather
    than merely *read*: two presses in one turn that read the same token would be
    ordered by whichever task started first, which is the thing the token exists to
    stop. The request's identifier is reserved with the token so that a rename
    landing in the same window can invalidate a question about the name it removed
    before that question has run (`FindUsagesModel.clearIfNaming`). `openFolder` calls
    `usages.prepareForFolderChange(root:)` in the same synchronous turn as
    `projectSearch.prepareForSearch` and the commit dialog's own registration, and
    for the same reason. `activateUsage(_:)` opens through `activateSearchMatch`'s
    steps but asks `UsageResult.revealRange(naming:in:)` against the buffer the
    click actually lands in: a row that no longer holds its identifier degrades to
    opening the file with nothing selected — never a crash on an out-of-bounds
    range, never a confident selection of a span that is now something else. A row
    **outside the opened folder that no tab already holds** does not go through
    `openFile` at all: it goes to
    the read-only viewer, exactly as a definition outside the project does (D3). A
    server answers `textDocument/references` with every reference it resolved, and
    an SDK header or a dependency checkout is an ordinary one — opening it as a tab
    would put a file the user did not open a project for into `WorkspaceModel`,
    where the autosave gate, the session snapshot and ⌘S all then apply to it, which
    is precisely what `viewDefinitionOutsideProject` exists to prevent and would
    otherwise arrive through the panel instead. That branch takes the row's range
    **as it stands**: the viewer reads the file when it opens the window and is
    structurally read-only, so nothing can type under the range the way a tab can.
    The gap that leaves is a *reused* window — `SourceViewerWindowController` keeps
    one viewer per file and re-reveals into the text it read when that window first
    opened — and it is a **stated limit** rather than a check, because the reveal
    is clamped to the shown text (no crash), the files this branch reaches are SDK
    sources and dependency checkouts that do not change while a window onto them is
    open, and closing it means the viewer handing its text back out, which is the
    one thing "structurally read-only" is easiest to keep true by not doing.
    **The already-open exclusion is not a courtesy.** The reason above is entirely
    about what `openFile` would *add* to `WorkspaceModel`, and there is nothing to
    add to a file already in it — the user opened it themselves, so the gate, the
    session and ⌘S already apply. Routing it to the viewer anyway would also be the
    *unsafe* branch: the viewer reads the file from **disk** while a row is a
    position in a **buffer**, so a dirty out-of-root tab would have the row's range
    revealed against text it was never computed for, which is the confident reveal
    of a wrong span `revealRange(naming:in:)` exists to refuse. Both ways in are
    ordinary rather than exotic — `FindUsagesModel.scanTextually` always scans the
    requesting file, naming "one opened from outside the root entirely" as a case
    it exists for, and a semantic answer maps every location against the open
    buffers.
    `renameSymbol(_:)` is the read half and refuses three things **before anything
    appears**, each with a beep and nothing more (the fallback vocabulary of this
    layer, where a language server's absence is never an error the user is made to
    read): no project root, no file behind the buffer, or a language
    `intelligence.canRename(_:)` declines — which is why the app holds the
    `RoutingIntelligenceProvider` as well as installing it, since that policy
    question is not on `CodeIntelligenceProviding` and the router forwards it
    precisely so nothing here reaches past the seam into the LSP layer. A fourth
    refusal joins them and is the one that *speaks*: `revertInFlight()` is asked
    here too, ahead of the dialog. `applyRename` asks it again and must — that
    check is what closes the window the modal and the round trip open — but asking
    only there would make the user name the symbol and wait out the server before
    being told the command was never going to run, and every other gated operation
    refuses before it costs anything. Then
    `FilePanels.promptName` prefilled with the old name and validated live by
    `RenameNameRule` (Core), then the rename request itself — which runs **outside**
    the writer bracket, because it is a read and holding autosave and the git gate
    down for a round trip that may time out would stall every other writer for a
    rename that has not been decided on yet. A server that advertises no rename, one
    that answers nothing, and one whose answer touches no file are one outcome here:
    a beep, and no bracket raised.
    `applyRename(_:for:root:)` is **the seventh gated worktree operation**,
    and the first that is not git's or Replace All's. Like every other writer it
    refuses outright while another one holds the gate (`revertInFlight()`), with
    the same "Git operation in progress" alert ⌘S gets and for the same reason.
    Before that it refuses **a project root that has moved**: `root` is the folder
    that was open when the command was invoked, the round trip in front of this is
    a read *outside* the bracket, and `openFolder(url:)` refuses only while the
    gate is up — so nothing stops an Open Folder in that window. Every other async
    model on this path orders across a folder switch with a token
    (`FindUsagesModel`'s `rootGeneration`), and this command has more to lose than
    they do: the plan would be built against the **old** root while
    `captureBeforeOperation` is handed `model.projectRoot`, the **new** one, and
    `LocalHistoryModel` drops every target outside the root it is given — so the
    writes would land in a project the user has left, with none of the "Before
    Rename" revisions the failure alert promises. That one refusal says nothing:
    the user has moved on. The plan is built *before* the bracket (`RenameEditPlan.make`, against
    the texts the servers were last sent, keyed by canonical path, and the disk
    otherwise), because every
    refusal is a question about the answer and the texts in hand: it costs nothing,
    stops nothing, and a rename that is going to be refused must never suspend
    autosave or capture a revision. The **requesting** file is answered with
    `request.text` rather than with its current buffer — the text the server was
    actually given, so a keystroke during the round trip surfaces as an honest
    "changed since the language server answered" instead of as edits mapped onto
    coordinates they were never computed for (D37, and the full reasoning on
    `RenameEditPlan`'s entry in `core-lsp.md`).
    **Both disk passes run off the main thread**, on this file's own serial
    `renameQueue` through a `PisakaApp.offMain` in the `ProjectSearchModel` shape.
    Between them they resolve symlinks three times per document and read every named
    file twice before writing it, over a set whose size the *server* chose — for a
    widely-used type that is hundreds of files, which is the ordinary case for this
    command and not the pathological one. Run on the main actor the window would
    freeze for the whole pass with nothing on screen to say why; every decision
    *around* them still happens on the main actor, which is what the re-checks below
    are for. The plan pass reads through
    `readTextIfNotBinary(url:maxBytes:)`, not `read`:
    this is the one file read in the app whose targets a *server* chooses, and an
    unbounded read of a binary file it happens to name would pull the
    whole thing into memory looking for identifiers that cannot be in it. Declining
    is a `RenameRefusal.unreadable`, so the rename refuses rather than skipping a
    file quietly — which is exactly why the cap is
    `LSPIntelligenceProvider.maximumTargetFileBytes` (16 MiB, the cap this layer
    already uses for a path a server named) and **not** the project search's 1 MiB:
    a grep cap on an all-or-nothing read would make ⌃⌘R permanently impossible for
    any symbol that also appears in a large generated source file, and report it as
    a file that "could not be read". The asymmetry settles it too — the requesting
    buffer and every text the server was sent bypass the cap entirely, so at 1 MiB
    whether a rename works would depend on which tabs happen to be open. Because the plan pass hops, `isCurrentProjectRoot` and
    `revertInFlight()` are asked **again** on the far side: a folder switch or
    another writer can land while it runs, and a plan built for a project the window
    has left must not be applied to the one it is showing. Inside the bracket
    the order is **capture, verify, write** (D37): `autosave.suspend()` +
    `localChanges.beginRevert()` raised synchronously and lowered **by hand on both
    exits rather than by `defer`** — the commit path's rule and for its reason:
    `PlatformAlert.presentMessage` is `NSAlert.runModal()`, a nested run loop, and
    `AutosaveController.flushNow()` bails while `suspendCount > 0`, so a ⌘Q while
    the stale-file or write-failure alert sits on screen would skip the termination
    flush for every dirty buffer. the body's two `await`s (the capture and the
    write pass) add no third way out, since neither is cancellable and both resume,
    so those two exits are still the only paths out and the `defer` bought
    nothing but the ordering hazard —
    `await captureBeforeOperation(.rename, buffers: openBufferTexts(), targets:
    plan.fileURLs)` as the **first `await` in the body**, the texts re-read *now*
    (the buffers may have been typed in and the disk written to while the dialog was
    up and the server was thinking), then the whole-plan verification — `apply`'s
    own first pass, which is why there is no separate `verify` call — then all
    writes or none. A stale file is the one refusal here worth an alert rather than a
    beep — the user asked for a write, the write did not happen, and the reason is
    something they can act on — and nothing was written when it is shown.
    The writes are split by who holds the file (decision 5): every file no tab holds
    is written by the engine, every open tab is rewritten through
    `SaveTransformController.applyRename`, which routes the displayed tab through the
    live text view as **one undoable step** and every other tab through
    `WorkspaceModel.replaceText` **at the cost of its undo stack** — the same two
    paths a restore takes, shared as one body because the *choice* between them is
    the decision.
    The buffer half applies each rewrite to **every tab on that file, not the first
    one `fileID(forURL:)` finds, and only to a tab still holding the text the plan
    was verified against**. Two tabs may legitimately show one file (opened once by
    path, once through a symlink) and `bufferTextsByCanonicalPath` collapses them to
    one text (viewer tabs are filtered out of it — they hold no buffer and would
    vouch for bytes nobody read): rewriting a single tab would leave the other holding the old name *and
    clean*, so nothing flags it and the next save through it writes the pre-rename
    text back over the file — the rename silently undone there, with no beep and no
    alert. The equality check is what makes that fan-out safe (two tabs whose texts
    differ were not both vouched for, and replacing the unvouched one wholesale
    would discard edits nobody asked to lose) and is also what closes the write
    pass's hop: a tab typed into while the disk half ran is skipped and **reported**
    in a "Rename incomplete" alert naming it, never overwritten from a text it no
    longer holds.

    **That sameness question is `NSString`'s, not Swift's**, on both sides of the
    layer. The plan's edits are UTF-16 offsets measured against exact bytes, and
    `String` equality is canonical equivalence: it would vouch for a tab holding a
    different spelling of the same text — U+212B and U+00C5 are `==` and are
    different bytes, at the same UTF-16 length — and the plan's offsets would then
    rewrite something nobody asked to change. So `applyRename` matches each tab
    with `isEqual(to:)`, and the verification it names as its premise,
    `RenameFilePlan.holds(in:)`, asks the same question of the text it read; the
    two layers have to agree about the rule or the premise means nothing. It is
    the codebase's one sameness rule — the same one
    `SaveTransformController.applyRestore`, the usages reveal and
    `LocalHistoryBrowserModel.plannedRestore` ask. A tab with no verified text
    matches nothing, and its file is reported unrewritten.

    That is Replace All's rule for the identical window — compute off
    main, re-read the buffer afterwards, skip and count a buffer that moved rather
    than clobber it. Afterwards comes the resync a project-wide Replace All already
    runs — `refreshLocalChanges()`, `model.bumpTreeRevision()`,
    `notifyIndexOfProjectFileChanges()` for the files with no tab, and
    `reindexReloadedBuffer(id:url:)` for every rewritten tab, which the stamp-gated
    refresh deliberately declines to re-extract — and then
    `usages.clearIfNaming(oldName)` (decision 7: the panel is cleared, not re-run,
    because every row it holds now names a spelling this rename just removed — and
    a ⌃⌘U reserved for that same name while the round trip was in flight has its
    token invalidated with it, so the queued walk cannot publish the old spelling
    afterwards). A disk
    write that *throws* is the one thing refusing cannot undo, so it is reported as
    its own alert naming the file and pointing at the "Before Rename" revisions
    rather than swallowed or dressed up as an abort — and that alert, not a second
    one, is where a skipped tab is named when a run hits **both**: its sentence
    "some files still hold the old name and the open editors do not" is true of
    every buffer the pass rewrote and false of the ones it skipped, so the skipped
    list is folded in rather than dropped. One incomplete rename is one sentence
    about one state. It
    owns the embedded terminal's `@StateObject
    TerminalSessionsModel`; the app-termination path calls
    `terminalSessions.terminateAll()` so no shell processes leak (tab-close
    terminates its own session). It also owns a `private let diffWindows =
    DiffWindowController()` for the separate diff windows and two open-diff handlers
    threaded into `ContentView` as `onOpenDiff`/`onOpenCommitDiff`:
    `openLocalChangesDiff(_:)` (title via `DiffWindowTitle.localChanges(path:)`,
    `load = localChanges.rows(for:)`) and `openCommitDiff(_:in:)` (title via
    `DiffWindowTitle.commit(path:hash:subject:)`, `load = commitLog.rows(for:in:)`),
    each building a `DiffWindowContent` and calling `diffWindows.open(title:content:)`.
    It likewise owns a `private let mergeWindows = MergeWindowController()` for the
    separate 3-pane merge windows and a `resolveConflict(_:)` handler threaded into
    `ContentView` as `onResolveConflict`: it resolves the repo root
    (`localChanges.root ?? model.projectRoot`), builds a fresh `MergeModel` (own
    `GitCLIService`, sharing the project `FileService`), kicks off
    `await mergeModel.load(file:root:)`, and calls
    `mergeWindows.open(title:model:settings:onApply:)` whose `onApply` is the guarded
    `applyMerge(_:file:root:)` (the controller closes the window only when it returns
    `true`). `applyMerge` brackets `MergeModel.apply()` with the *same* coordination
    as the revert path — because apply is a third uncoordinated disk writer (it
    `write`s the resolved file and `git add`s it off the main thread): it suspends
    autosave (`autosave.suspend()`) and raises the disk-writer gate
    (`localChanges.beginRevert()`) *synchronously before the first `await`* (balanced
    by `defer`) so neither an idle/focus-loss autosave of a dirty tab on this same
    file nor a project-tree op can race the apply and stage stale conflicted content
    over the resolution. It snapshots the open tab's buffer (`model.fileID(forURL:
    root/file.path)`, canonical match, so a tab opened via `projectRoot` resolves)
    *together with its dirty state* (`model.isDirty(for:)`)
    before the `await` and, on success, refreshes Local Changes, calls
    `notifyIndexOfProjectFileChanges()` (the resolved file is written *in process*, so
    `IgnoreSelf` drops it and the `git add` beside it produces only `.git` paths
    `TreeRefreshFilter` drops — nothing else would ever tell the index, and this
    editor is normally opened from Local Changes on a file with no tab at all) and
    resyncs the tab —
    `model.reloadFromDisk(id:)` only when the buffer held no unsaved edits to lose: it
    was *clean at the snapshot* **and** is provably unchanged since (else
    `model.reconcileSavedBaseline(id:)` + beep, preserving the edit — whether it
    pre-dated the apply or was made while it ran — rather than silently reloading over
    it), and `model.close(id:force: true)`
    when the resolved file is gone from disk (a modify/delete staged as a deletion).
    A successful Apply then closes the window itself.
    The `willTerminateNotification` observer calls `diffWindows.closeAll()`,
    `mergeWindows.closeAll()`, `projectSearchWindows.closeAll()`,
    `leetCodeBrowserWindows.closeAll()`, `localHistoryWindows.closeAll()`,
    `sourceViewers.closeAll()` and `databaseViewers.closeAll()` alongside
    `terminalSessions.terminateAll()` so no diff, merge, Find in Files, LeetCode
    browser, Local History or source-viewer window lingers past termination and no
    database connection is left open (best effort, and said to be — see
    `core-database-viewer.md`) — and `lspWorkspace.terminateNow()` beside them, for the
    terminal sessions' reason: a `sourcekit-lsp` left behind is an orphan process
    holding a build-system cache open, which the release check
    (`pgrep -fl sourcekit-lsp`) is specifically looking for. **`terminateNow()`
    rather than the graceful `shutdownAll()`**, because this is the last notification
    AppKit posts before the process exits: a `Task` wrapping the async teardown would
    compile, never be picked up, and leave exactly that orphan — the same reason the
    autosave and session writers flush *synchronously* from this observer.
    `lspGoToolchain.terminateNow()` is called beside it, and what it ends is worse
    than an orphan server: a `go install` has a compiler and a linker beneath it,
    all writing into a staging directory nothing will ever finish. It is also
    **permanent** as well as immediate — a torn-down service refuses to launch
    anything else — which closes the window between this observer firing and a `.go`
    tab open landing on `prepareForOpening`. The release check is
    `pgrep -f 'gopls|go install'` coming back empty after a quit.
    `lspRustToolchain.terminateNow()` runs beside it, and it is worth saying what
    it is *not* for: rust-analyzer is downloaded rather than built, and a download
    is `URLSession` bytes into a staging tree that the process exit ends and the
    next launch's `sweepStaging()` reclaims. What this call ends is the
    *discovery* — the login shell it may have spawned and the `cargo --version` /
    `rust-analyzer --version` probes — which is the one thing here that can
    outlive a quit, since a profile slow enough to hang is exactly why it has a
    deadline. It is permanent in the same way, so a `.rs` tab opening after the
    observer fires starts nothing; the release check is `pgrep -f rust-analyzer`
    coming back empty.
    `zoom.uninstall()` is called from that same observer, and is the cheap,
    undramatic end of the list: it removes the app's one `NSEvent` monitor so no
    event handler outlives the app. It is *there* rather than anywhere closer to
    the monitor because "installed in `.onAppear`, removed on termination" is one
    statement, and splitting it across two places is how the second half gets
    forgotten. The other half is `zoom.install()` in the root `.onAppear`,
    alongside the rest of the app-lifecycle wiring; it is idempotent by contract
    for `terminateAll()`'s reason — `.onAppear` can fire again for a reopened
    window, and a second monitor would apply every zoom step twice. The
    `ZoomController` itself is a plain stored `let` built in `init()` over the
    same `SettingsStore` every window and sheet receives (three zones with one
    arithmetic is only true if there is one place the numbers live), like the
    other controllers; nothing in the scene's `body` reads anything published on
    it — the *settings* it writes are what redraws the views — and that reference
    is what keeps the monitor's owner alive, since the monitor holds `self`
    weakly. The **View menu** gains the three items that go through it, above a
    `Divider()` and the bottom-dock toggles: Zoom In (⌘=), a second Zoom In
    carrying the ⌘+ alternate, Zoom Out (⌘−) and Reset Zoom (⌘0). Two items for
    zooming in on purpose — ⌘= is the keystroke that needs no Shift, ⌘+ is the one
    every other Mac app *displays*, and AppKit matches a key equivalent literally
    ("=" does not answer a ⇧= press, "+" does not answer a plain one), while
    SwiftUI offers no `isAlternate` to hide the duplicate. Each resolves the zone
    from the **pointer at invocation time**, exactly as a scroll or a pinch does,
    so ⌘= over the terminal grows the terminal even while the editor holds focus;
    the full rule and the monitor's own contract are in `core-zoom.md`. It
    also holds the shared
    `CommitLogModel` (real
    `GitCLIService`); `openFolder()` refreshes it (`CommitLogView.initialLimit`)
    alongside `LocalChangesModel`, since `CommitLogView` is only in the hierarchy
    when the Git Log panel is shown so a folder switch made with the panel hidden
    would otherwise not reach it. It
    captures the request token synchronously via `commitLog.prepareForRefresh(root:)`
    (which also resets the previous repo's ref-specific filter/refs on the switch)
    *before* the `Task`-wrapped `refresh(root:limit:request:)`, so two rapid folder
    opens settle on the latest even when their unstructured tasks start out of order
    — the same generation-pinning the Local Changes path uses. It also constructs the
    shared `BranchSwitcherModel` (real `GitCLIService`) hosted by
    `BranchSwitcherView` in the bottom bar, refreshing it on `openFolder` and after a
    successful switch/create. Its `switchBranch`/`createBranch`/`checkoutRemote`
    handlers wrap `BranchSwitcherModel.switchTo`/`createBranch`/`checkoutRemote` under
    the *same* gates as the
    revert/apply-merge paths: synchronously before the `await` — `autosave.suspend()`
    + `localChanges.beginRevert()` (the project-tree-ops gate), `defer`
    resume/`endRevert`, and a snapshot of every open-tab buffer; on success the tab
    resync (`reloadFromDisk` for a clean tab, `reconcileSavedBaseline`+beep for an
    edited one — a checkout rewrites the worktree), a tree refresh
    (`bumpTreeRevision`), and generation-pinned Local Changes / Log refreshes.
    **On failure the same tail runs when — and only when — the branch moved
    anyway** (`resyncIfTheBranchMovedAnyway`): a single `git checkout` fails
    atomically, but `gh pr checkout` is several commands and the ones after the
    checkout can fail (`--ff-only` against a diverged branch) or be killed at the
    deadline with the worktree already switched, and skipping the tail there would
    leave open buffers ready to be saved over another branch's files. The branch is
    re-read against the *requested* root the operation started under (the spelling
    `prepareForRefresh` keys its folder-switch clear off), skipped outright when
    the folder changed under the operation, and a move is declared only when both
    readings are known and differ — an unknown one is not evidence, and guessing
    costs a beep and a discarded undo stack per edited tab. The re-read is also the
    widget's catch-up, and publishing `current` is what re-triggers the Pull
    Requests coordinator's branch subscription, so its `runCheckout` failure path
    needs no trigger of its own (`core-github.md`). It happens *before* the alert,
    so the tree the modal is drawn over is the tree found when it is dismissed.
    Both
    the switch and checkout-remote handlers run through the shared
    `runBranchOperation(_ event: LocalHistoryEvent = .branch, _ op: () async -> String?)`
    — and all three worktree-checkout entry points (`switchBranch`,
    `checkoutRemote`, `createBranch`) **refuse outright while another writer holds
    the gate**, through `revertInFlight()`, ahead of their dirty-tree prompt so a
    refusal is one alert rather than a confirmation followed by one. The bracket
    raises the flag but does not read it, so without those guards a branch change
    started during a revert, a merge apply, a commit or the 120-second
    `gh pr checkout` would be a second `git` rewriting the same worktree — one of
    the two losing on `index.lock`, and the resync afterwards comparing its
    snapshot against a tree neither finished. `createBranch` carries its own guard
    rather than its two call sites' so the `.fetchUnavailable` retry is asked too
    (the first attempt has already lowered the gate by then, so an offline retry
    still runs).
    orchestration — generalised for the Pull Requests feature, which passes
    `.pullRequest` through `PullRequestCoordinator` and makes `gh pr checkout` the
    **eighth** gated operation riding this, the one bracket that serves more than
    one (`core-github.md`). The operation answers `nil` for success, a sentence for
    a failure worth an alert, and `""` for one already published where the reader
    is looking. Its third parameter is an **optional completion, called on both
    paths**, which the post-merge tail is the whole reason for: the bracket is
    fire-and-forget, and the tail's `pull --ff-only` — the **ninth** gated
    operation, and a second `.branch` caller ahead of it for the switch — must not
    start until the switch has finished *and been judged*. Two bracketed
    operations cannot be ordered without it, and the scene's share in that
    ordering is the parameter and the two calls to it, nothing else; `checkoutRemote(_:)` is a
    mirror of `switchBranch` (the same dirty-tree warning — the DWIM checkout part may
    be blocked just the same — synchronous `currentRefreshGeneration` pinning, then
    `runBranchOperation { await branchSwitcher.checkoutRemote(ref, originGeneration:) }`),
    threaded into `ContentView` as `onCheckoutRemote: { checkoutRemote($0) }` alongside
    `onCreateBranchFromRemote`. Also
    constructs the shared `LocalChangesModel` (with the real `GitCLIService`) and
    auto-refreshes it on `markSaved` so a save re-runs `git status` (no
    filesystem watching). `openFolder()` also refreshes `LocalChangesModel`
    directly (not only via `LocalChangesView`'s `.onChange(of: projectRoot)`,
    which never fires while that view is out of the hierarchy in "Project" mode):
    the model's mid-revert folder-switch guard keys off a folder change being
    observed, so a missed switch would let an in-flight revert
    keep mutating the *previous* repository. Because the model's `refresh`/`revert` are now `async`,
    these calls are `Task`-wrapped — but `openFolder()` first calls
    `localChanges.prepareForFolderChange(root:)` *synchronously*, in the same
    main-actor turn that handles the folder open, *before* spawning the
    `Task`-wrapped refresh: the `Task` body runs a later main-actor turn, so bumping
    the folder-switch generation only inside it would leave a window where an
    in-flight revert's continuation resumes first and still mutates the old repo.
    The synchronous pre-registration closes that window (and the subsequent
    `refresh` no-ops its own switch-handling for the same root). `openFolder()`
    also captures the generation `prepareForFolderChange` returns and passes it as
    `refresh(root:requestGeneration:)`, so a refresh task that two rapid folder
    opens left running out of order (an older folder's task executing after a
    newer's) is rejected instead of rewriting the panel back to the superseded
    repo. The post-save refresh hook (`refreshLocalChanges`) likewise captures
    `localChanges.currentRequestGeneration` *synchronously* and spawns
    `Task { await localChanges.refresh(root:requestGeneration:) }`, so a save-driven
    refresh that ends up running after a folder switch is rejected rather than
    re-deriving (and reversing) the switch inside `refreshImpl` — the same hazard the
    folder-open pinning closes. `LocalChangesView.refreshIfPossible` (the
    `onAppear`/manual-button backstop) pins its generation the same way — and its
    `onChange(of: projectRoot)` peer additionally passes the root from the handler's
    *parameter*, since pinning alone cannot reject a refresh launched for the
    *previous* root at the current generation (`app-git-views.md`).
    `revertChanges(contextFile:)` runs the synchronous `confirmRevert` dialog
    first, then does its `revert` + tab-resync loop inside a `Task { @MainActor in
    … }`. It resolves the affected files via `localChanges.filesToRevert(contextFile:)`,
    confirms via `FilePanels.confirmRevert(fileNames:)` (returning before any
    mutation on cancel), captures `localChanges.currentRequestGeneration`
    *synchronously* before the `Task` hop, awaits
    `localChanges.revert(files, originGeneration:)` (so a folder switch that
    commits before the deferred task starts makes the revert bail rather than
    mutate the newly opened repo), then for each reverted
    URL resolves the open tab via `model.fileID(forURL:)` (canonical match, so the
    revert's repo-root-relative url still finds a tab opened via `projectRoot`) and
    keeps it in sync — `model.reloadFromDisk(id:)` when the file still exists on
    disk, `model.close(id:force: true)` when it was deleted. Because the revert
    now runs `git` off the main thread, the editor stays interactive while it is
    in flight, so before the `Task` hop it snapshots every open tab's buffer text
    (`model.openFiles` → id→text) *synchronously*; the resync skips (and beeps for)
    any tab whose text changed since that snapshot (`model.text(for:)`), so an edit
    the user made to an affected file after confirming the revert is preserved
    rather than silently overwritten by `reloadFromDisk` or discarded by a
    force-close. A preserved tab also has its saved baseline reconciled
    (`model.reconcileSavedBaseline(id:)`): if the user *saved* that edit during the
    in-flight revert the tab would otherwise look clean (`savedText == text`) even
    though `git` has since changed the file on disk, so closing it would skip the
    unsaved-changes prompt and silently lose the edit — reconciling against the
    post-revert disk state makes it dirty. `PisakaApp` also owns an
    `AutosaveController` (started once from the window content's `.onAppear` with
    `model`, `saveTransform.prepareForAutosave(ids:abandoningBuffers:)` and an
    `onSaved` closure that
    calls `refreshLocalChanges()`, reusing
    its generation-pinning rather than duplicating the git status refresh);
    `saveTransform.start(model:editorConfig:onBufferReplaced:)` is bound just
    above it, its third argument `reindexReloadedBuffer(id:url:)` — the resync a
    background tab rewritten through the model needs, for the reason
    `core-editorconfig.md` states.
    `revertChanges` brackets its revert+resync `Task` with the controller:
    `autosave.suspend()` is called *synchronously* right after the confirm
    (where `originGeneration`/`preRevertText` are captured, before the `Task`
    hop), and `autosave.resume()` via `defer` inside the `Task { @MainActor in … }`
    so it always resumes — including the early-bail paths (origin-generation
    mismatch, empty `reverted`). This keeps autosave (a second, uncoordinated disk
    writer) from firing for the full duration of the in-flight git revert and its
    snapshot-based resync — which it would otherwise race (`git checkout` on the
    same file) and corrupt. The same synchronous-before-the-hop / `defer`-inside
    bracket raises and lowers `localChanges.beginRevert()`/`endRevert()` (the
    `isReverting` gate), blocking the *project-tree* file operations — the other
    uncoordinated disk writer — and, since part 2a, a database viewer's inline
    cell edit, which is the one blocked writer that is not a text file: it
    *consults* the flag through the closure the scene hands
    `DatabaseViewerTabs.start(isWriteBlocked:didWrite:)` and refuses in its own
    banner, and it never raises the gate itself (`core-database-viewer.md`). All
    of them for the same duration and the same reason. The suspend is *not* taken around the confirm dialog:
    an autosave *can* interleave there (the idle debounce is a GCD main-queue timer
    that fires inside the alert's nested run loop), but it is harmless — `preRevertText`
    is snapshotted *after* the confirm returns and `git checkout` then supersedes
    whatever it wrote — so suspending across the alert buys nothing and a cancel must
    not leave autosave suspended. `closeFile(id:)` *does* bracket its
    unsaved-changes confirmation with `autosave.suspendForModal()`/`resumeFromModal()`
    (the modal-only gate, not `suspend()`): the idle debounce fires inside
    `NSAlert.runModal()`'s nested run loop and would write the file to disk before
    the user answers, defeating a subsequent "Don't Save" (which then drops only the
    in-memory tab) — Don't Save force-closes the tab *before* `resumeFromModal()` so
    the replayed autosave can't resave the discarded buffer. The modal gate leaves
    the quit-time `flushNow` ungated, so a quit while the alert is open still saves
    every *other* dirty file.
    `PisakaApp` also orchestrates the writable project tree, wiring the four
    `ProjectTreeView` callbacks (threaded via `ContentView`) to disk + model
    reconciliation: New File (receives the accepted text from the view's inline draft → `parseRelativeEntryPath` →
    `fileService.ensureDirectory(at:)` on the parent chain, skipped entirely for a
    single component → `fileService.createFile(at:)` → `model.open(url:)` to show
    it → bump `treeRevision`), New Folder (same, `createDirectory` on the final
    component, no tab opened), Rename
    (receives the accepted text from the draft, a no-op when unchanged →
    validate → `performMove(from:to:)`, the shared body below: capture
    `model.planRename(from:to:)` *before* the move → `fileService.move(from:to:)`
    → `model.applyRenamePlan(_:)` → bump), and Delete
    (`confirmDelete` → capture `model.tabIDs(under:)` *before* the removal →
    `fileService.removeItem(at:)` → `model.closeFiles(ids:)` → bump). The tab
    reconciliation is captured before the disk mutation (not after) so a tab
    opened through a symlink to the affected item — which dangles, and so stops
    canonicalizing to the target, once the move/removal lands — is still matched.
    All four operations first bail (beep + an explanatory alert via
    `revertInFlight()`) when `localChanges.isReverting`: a revert's off-main `git`
    mutations would otherwise race these synchronous disk writes.
    **Rename and the tree's drag-and-drop move share one body**,
    `performMove(from:to:)`, and a fifth callback — `onMove(source, folder)`,
    threaded through `ContentView` like the other four — brings the drop here as
    `moveItem(at:into:)`. The two differ in nothing but how the destination was
    arrived at (a prompt and single-name validation there, `MoveDropRule` here),
    while the sequence they share is ordering-sensitive enough that a second copy
    would be a second thing to get wrong: `model.planRename(from:to:)` and the
    `retargetedURLs` capture *before* the move (a tab opened through a symlink to
    the source still canonicalizes to it only until the move renames the target
    away, and once `applyRenamePlan` retargets a tab its old url is no longer
    reachable from the model), then `fileService.move` → `applyRenamePlan` →
    `forgetIndexedBuffer` per retargeted url → `bumpTreeRevision()` →
    `notifyIndexOfProjectFileChanges()`, with any throw going to
    `reportFileOperationFailure(_:)`. `performMove` assumes the writer gate has
    already been passed; both callers raise it themselves. `moveItem(at:into:)`
    therefore holds only `revertInFlight()` — raised *first*, ahead of the
    engine's directory listings, like every other project-tree file operation —
    and then `MoveDropRule.decision(source:into:fileService:)`: `.move` runs
    `performMove`, `.refuse` writes **nothing at all** (no plan applied, no tree
    revision bumped, nothing handed back to the index) and either says nothing
    (the silent `unchangedLocation`, i.e. a drop back onto the folder the entry
    already lives in) or reports through the same `reportFileOperationFailure`
    alert as a disk error — which is what `MoveDropRefusal` being a
    `LocalizedError` buys, and why the tree needs no alert code of its own. The
    tree asked that same engine for the drag highlight, so the drop that lit a row
    up and the drop this accepts are decided by one rule; this call, behind the
    gate and through the app's own file service, is the authoritative one — and
    it is the *only* one that can report, since a refusal the highlight already
    caught never gets a drop performed at all (`core-workspace.md`, "How a
    refusal reaches the user"). What reaches this alert is therefore the narrow
    set the hover could not have known: the writer gate's own notice, a
    destination that gained the name or a source that vanished mid-drag, and a
    `fileService.move` that threw. The two *create*
    call sites accept a VS Code-style relative path of any depth
    (`centrifugo/config.json`): `parseRelativeEntryPath` does all the validation
    (whole-input and per-component trimming, so no padded name reaches disk; the
    `.`/`..`/line-break/NUL rules; and the case-insensitive reserved-name refusal),
    a `nil`
    result is reported through `reportInvalidName` — whose text now explains the
    *per-component* rule (a slash separates folders; each part must be non-empty,
    not `.` or `..`, must not contain a line break, and must not be a
    reserved name such as `.git`/`.DS_Store` in any
    casing; NUL is left out of the text as untypeable noise) — and the whole create
    runs inside one `do/catch`, so any step's
    failure goes through `reportFileOperationFailure`. A *multi-component* failure
    still bumps `treeRevision` first (`refreshTreeAfterFailedCreate(componentCount:)`):
    `ensureDirectory` has `mkdir -p` semantics and does not roll back, so folders it
    already created are real, and without the bump they would stay invisible until an
    unrelated tree operation refreshed the cached listings — the tree contradicting
    disk, and a retry silently "reusing" folders the user cannot see. A
    single-component create writes nothing on that path, so it is left alone.
    Missing intermediates are created and existing ones reused, but the *final*
    entry is never clobbered (`createFile`/`createDirectory` still throw
    `.alreadyExists`), and a file sitting on the path surfaces
    `.notADirectory(name:)`. `reportReservedName` is now *rename*-only: rename
    keeps single-name, exact-match semantics (`isValidFileName` +
    `FileService.isExcludedEntryName(_:)`) because a path there would mean a move —
    a separate feature — and the entry would otherwise land on disk yet never
    appear in the tree (silently retargeting the open tab to an unreachable path).
    Every path surfaces a failure non-fatally: `reportFileOperationFailure` beeps and
    shows an `NSAlert(error:)`, `reportInvalidName`/`reportReservedName` beep and
    explain the rejected name. `reportInvalidName` takes an `isPath` flag because the
    two call sites have different grammars — the create paths get the
    per-component path rule, while rename gets "a name must not contain a slash"
    (telling a rejected rename that slashes separate folders would describe a rule
    the entered name satisfies, leaving the real reason unstated).
    **None of the three takes a name from a dialog any more.** `newFile(in:name:)`,
    `newFolder(in:name:)` and `renameItem(at:newName:)` are handed a name the
    project tree's inline draft has *already* accepted against the same Core rule
    (`ProjectTreeDraftField` + `TreeNameFieldView`, `app-window.md`), so the
    reason line the user reads is the draft's, live, and these guards
    (`parseRelativeEntryPath`, `isValidFileName` + `isExcludedEntryName`) run
    post-*commit*, behind the writer gate, as defense-in-depth for a rule the
    draft could not have re-checked at the moment of the write (a sibling that
    appeared since) and for the paths reachable programmatically. They and
    `reportInvalidName`/`reportReservedName` are therefore **kept exactly as they
    were** rather than deleted as dead code. The only surviving `promptName`
    callers are the two branch prompts (`newBranch`/`createBranchFromRemote`),
    which pass an explicit `{ _ in nil }` — no live reason, `GitRefName.isValid`
    after OK stays the only reporter (deliberate minimal scope; see
    `FilePanels.swift` and `app-git-views.md`).
    (`deleteItem` handles a file and a directory tree uniformly via
    `removeItem`/`tabIDs(under:)`/`closeFiles(ids:)`, so it takes no item-type
    flag.)
    `PisakaApp` also owns `private let projectWatcher = ProjectWatcher()` (next to
    `diffWindows`/`mergeWindows`) and wires it at two call sites: `openFolder()`
    calls `projectWatcher.start(root: url, onChange: { model.bumpTreeRevision() })`
    right after `model.openFolder(url:)` — `start` is idempotent, so this doubles as
    the folder switch (events from the old root stop arriving) — and the
    `willTerminateNotification` observer calls `projectWatcher.stop()` alongside
    `terminalSessions.terminateAll()`/`closeAll()`, so no FSEvents stream outlives
    the app. Nothing about the watcher-driven bump is gated: `bumpTreeRevision()` is
    idempotent and the re-read it triggers is read-only, so the harmless
    `.DS_Store`-driven bump and the worktree events of an in-flight revert (a `git`
    *subprocess*, so `IgnoreSelf` does not suppress them) are inert — the gates
    (`isReverting`, autosave suspension) exist for *disk writers*, which a re-read is
    not; the `.git` noise of those same git runs is dropped by the Core filter.
    That same callback also calls `editorConfig.noteProjectFilesChanged()`, which is
    the whole reason a live edit to a `.editorconfig` takes effect on the next
    keystroke without reopening the project. It is ungated for the reason below
    (another *reader*) and invalidates **wholesale** rather than by path or on a
    debounce: clearing a dictionary costs nothing, and the re-resolution is paid for
    by the next keystroke in the front tab and by nothing else
    (`core-editorconfig.md`).
    That same callback additionally asks `symbolIndexController.noteProjectFilesChanged(
    root:)` for a **debounced symbol-index refresh** (a further 500 ms on top of the
    watcher's own 1 s coalescing, since a build or an `npm i` outlives that window).
    It is ungated for exactly the reason above, restated on `SymbolIndexModel`: the
    index is a *reader*, so a refresh landing mid-revert costs at worst one entry
    extracted from a half-rewritten file, which the next refresh corrects, while
    taking the writer gate would serialize the editor behind a background walk. The
    root is *captured* rather than read from the model, so the refresh always names
    the folder this subscription was started for. **The index needs its own
    counterpart to the explicit tree bumps below**, and gets it as
    `notifyIndexOfProjectFileChanges()`: `IgnoreSelf` hides every write *this*
    process performs, and the stamp-gated refresh is the only thing that re-extracts
    a rewritten file and the only thing that removes a vanished one. Without the
    call, a tree rename would leave the file answering Go to Definition under a path
    that no longer exists, a delete would leave its declarations jumpable, and a
    project-wide Replace All would keep serving the identifiers it just replaced —
    until some unrelated *child* process happened to touch the tree. It is called
    beside `bumpTreeRevision()` in `performMove` (so a rename and a
    drag-and-drop move both get it from one place), `deleteItem`, `saveAs(id:)`,
    `revertChanges` and `replaceAllInProject` — and in `applyMerge`, which has no
    tree bump to sit beside (the merge rewrites a file's *contents*, not the tree's
    membership) yet needs it for the same reason — and deliberately **not** in the
    others: `newFile`/`newFolder` write an empty file (or none) and `newFile` opens
    a tab for it, so the buffer re-index already covers it, while an ordinary save
    and the autosave's recreating save rewrite a file a tab still owns — and a
    buffer-sourced entry is precisely what a refresh declines to touch. The call is
    cheap enough to leave ungated and unconditional: 500 ms debounce, a walk that
    re-reads only what changed, and no writer gate.
    Because the watcher ignores self-generated events, `saveAs(id:)` bumps
    explicitly: after a successful `model.saveAs(url:for:)` it calls
    `model.bumpTreeRevision()` (next to `refreshLocalChanges()`) — Save As writes a
    *new* file, i.e. changes tree membership, and is the one in-app write that had no
    bump before. The bump is unconditional: a destination outside the open folder
    just re-reads listings that did not change, so gating on containment would add a
    path check for no benefit. `revertChanges` bumps for the same reason: a revert
    changes tree membership, and while every other revert branch runs a `git`
    subprocess (whose events the watcher does deliver), reverting an *untracked* file
    is `GitCLIService.removeUntracked`'s in-process `unlinkat` — which `IgnoreSelf`
    drops. It bumps once after the whole batch when `reverted` is non-empty, the
    redundant bump for the subprocess cases being free (idempotent, read-only). The
    third self-write that changes tree membership is an ordinary Save/autosave that
    *recreates* a file deleted out of band: `FileService.write` creates a missing
    file, so a tab whose file was removed externally (the watcher having already
    dropped it from the tree) puts it back on disk, and `IgnoreSelf` hides that from
    the watcher. Both save paths therefore probe *before* the write and bump only
    when the file was actually missing — `save(id:)` checks the tab's url
    (`FileManager.fileExists`) and bumps after a successful
    `model.save(for:)`, while `AutosaveController` collects the missing dirty titled
    paths (`missingDirtyPaths(in:)`, so a nothing-to-save re-fire costs no syscall)
    and reports `createdFile` through its `onSaved: ([URL], Bool) -> Void` callback,
    which `PisakaApp` turns into the bump next to `refreshLocalChanges()`. An ordinary
    overwrite is deliberately *not* bumped: it leaves every listing identical, and
    that frequent case is exactly the self-noise `IgnoreSelf` exists to drop. The
    quit-time `flushNow` has no `onSaved` and so no probe — there is no tree left to
    refresh on the way out.
    `PisakaApp` also owns the **launch-time session restore**: a `private let
    sessionStore = SessionStore()` and a `private let sessionController =
    SessionController()` (plain stored references like the controllers above — the
    `@main` App is created once), plus `@State private var didRestoreSession`. It exposes the `SessionCatalog` to `ContentView`'s recent-projects switcher via the private `recentProjectRows()`, reading `sessionStore.loadCatalog()` and passing `model.projectRoot` and `isExistingDirectory(atPath:)`. The
    former `openFolder()` is **split in two**: the no-argument form now does
    nothing but show the panel and call `openFolder(url:)`, which holds *all* the
    folder-change logic (the watcher start and the Local Changes / Git Log / branch
    switcher / Project Search registrations with their synchronous
    prepare-then-refresh pinning). The split exists so a *programmatic* open — the
    restore — goes through exactly the same collaborators as a user-driven one;
    calling `model.openFolder(url:)` directly would leave every one of them on a
    project the workspace has already moved past.
    **Sessions are per project, and `openFolder(url:)` owns the switch.**
    An **existence guard sits at the very top of `openFolder(url:)`**: before `isSwitch` is decided and before anything is flushed, the funnel checks `isExistingDirectory(atPath: url.path)`. If the folder is gone, it warns via `PlatformFeedback.warning()` + `PlatformAlert` ("Cannot open project folder") and returns, leaving the workspace unchanged. This protects programmatic callers (like the recents widget, which can offer a folder deleted since it was recorded); the launch restore's own pre-check keeps it on the silent path, so the alert never fires at launch.
    Whether this open *is* a switch is decided **next**, before anything else is touched
    (`!model.isCurrentProjectRoot(url)`) — necessarily before
    `model.openFolder(url:)` moves `projectRoot`, which would make every later test
    read as a re-open. Re-opening the folder already open stays a pure no-op for the
    tabs, exactly as it already is for the LSP workspace and the commit dialog; a
    real switch runs four things in this order, and the order is the whole design.
    (1) It **refuses** while a revert's off-main `git` mutations are in flight
    (`revertInFlight()`) — the same posture as ⌘S, and for the same reason: the
    switch is about to force-close every tab, and a buffer whose save is racing a
    `git checkout` must not be one of them. (2) It **flushes autosave** with
    `reportingSaves: true`, so the writes it makes get the same follow-up an
    ordinary mid-session autosave gets (Local Changes re-queried, the tree bumped
    for a recreated file). (3) Because that flush is **best-effort** —
    `saveAllDirty()` swallows a per-file write failure by design — it then
    **refuses and names the files** if `unsavedTitledFileNames()` is still
    non-empty (`reportUnsavedBeforeFolderSwitch`, a sibling of
    `reportUnsavedBeforeCommit`): force-closing a buffer whose contents never
    reached disk destroys the user's work outright, which is strictly worse than
    not switching. Untitled buffers need no flush at all — their text travels
    *inside* the outgoing snapshot. **That refusal is scoped to `hadFolder`**, the
    replacing path — the only one that force-closes anything. The carrying path
    (the asymmetric case below) leaves every tab open, so an unsaved buffer is in
    no more danger after the open than before it; refusing there would block the
    first Open Folder of a run over a loss that path cannot cause, with an alert
    whose "would close them" reason is not even true of it. (4) It persists the outgoing snapshot through
    `sessionController.flushNow()` while `projectRoot` is still the **outgoing**
    folder, which is what keys it correctly, since `SessionStore.save(_:)` is an
    upsert on the snapshot's own `folderPath`. Going through `flushNow()` rather
    than snapshotting directly also inherits its `hasObservedChange` guard, which is
    load-bearing here rather than incidental: at launch, restore calls this method
    *before* the controller is started, so an unguarded snapshot would write the
    empty live model over the no-folder workspace's stored session. Then
    `model.openFolder(url:)` moves the root and, still ahead of the collaborator
    registrations, the incoming tabs are applied: `sessionStore.session(forFolder:
    url) ?? EditorSession()`, re-stamped with `url.path` so the promotion below
    files it under the spelling the user just opened (the verbatim-latest-spelling
    rule `SessionCatalog.store(_:)` states, and the one the debounced writer would
    use anyway since it snapshots `projectRoot`; both apply methods ignore the
    field). The explicit empty session is what makes a folder's *first* open empty
    the editor rather than leave the previous project's tabs behind the new tree.
    **The one asymmetric case is an outgoing workspace with no folder** — the first
    Open Folder of a run, which `isCurrentProjectRoot` reports as a switch. Its key
    is `nil`, and launch restore can only reach the `nil` entry while it is the
    catalog's head, which opening this folder is about to take; force-closing there
    would file an unsaved Untitled buffer under a key nothing reads again. So when
    `model.projectRoot` was `nil` the incoming session is applied with
    `model.restoreSession(_:)` — *on top of* the pre-folder tabs, carrying them into
    the project — and with `replaceSession(with:)` otherwise. At launch the two are
    the same thing, there being nothing open to carry.
    Then `sessionController.noteProjectSwitch(promoting:)` files the session for the
    incoming project at the catalog's head — **the merged one in the carrying case**
    (`EditorSession.merging(_:onto:incomingRestoredAny:)` over a snapshot taken just
    before `restoreSession` appends, told by `restoreSession`'s own return value
    whether any incoming record actually became a tab — so a project whose files
    have all moved cannot file a selection pointing at a record nothing restored),
    the incoming entry itself otherwise. The distinction
    is load-bearing rather than tidy, and is the superset invariant stated below:
    promoting the unmerged entry would leave the carried tabs on screen but
    *unwritable* for the rest of the run — the seeded marker suppresses the quit-time
    flush too — so a pre-folder Untitled buffer would be gone at the next launch,
    which is the loss the carrying branch exists to prevent in the first place.
    That replaces relying on the 1 s debounce the
    swap arms, for two reasons: promotion becomes immediate, so a crash inside that
    second still records which project the user is in; and, the reason it exists,
    applying a session **silently skips records this build cannot open**, so the
    debounced write would persist that truncated restore over the recorded session
    with the user having touched nothing — the very loss `SessionController.start`'s
    `dropFirst()`s prevent at launch, reached by the same route. It seeds
    `lastWritten` with the post-swap snapshot, which `writeSession()`'s
    equal-snapshot guard turns into the suppression; a genuine user change afterwards
    writes normally. **The caller therefore owes one invariant: the promoted session
    must be a *superset* of what the live model holds after the swap.** The seeding
    suppresses not just the armed debounce but every later equal write, `flushNow()`
    on quit included, so what the promoted session omits is not merely unwritten now
    — it is unwritable until the user changes something. A superset is the whole
    intent (records restore skipped are kept rather than truncated away); a subset
    silently destroys the difference. Every existing collaborator call is untouched — a re-open of the
    current folder stays for the tabs the no-op it already is for them.
    `restoreLastSession()` runs
    **once**, from the window content's `.onAppear` (gated by `didRestoreSession`,
    since `.onAppear` can fire again for a reopened window or a second
    `WindowGroup` scene and restore is *not* idempotent — a second run would
    re-select a tab the user has since moved off), before the first interaction: read
    `sessionStore.loadLastOpened()` — the **head of the session catalog**, which
    with a keyed store *is* the pointer (there is no separate field that could name
    an entry the store does not hold); if a `folderPath` was recorded and still names a
    **directory** (`isExistingDirectory(atPath:)` — checked rather than mere
    existence, because a path replaced by a *file* since the last launch would point
    the tree, the watcher and every git model at something that cannot be listed),
    open it via `openFolder(url:)`, which — `projectRoot` being `nil` at that point,
    so the open reads as a switch — **also applies that folder's stored tabs**: the
    tab half of launch restore travels the exact path a user-driven Open Folder does
    rather than a second implementation of it, and the pre-switch prologue is
    trivially satisfied at launch (no revert in flight, no dirty buffer, and the
    not-yet-started controller's `flushNow()` is the no-op its `hasObservedChange`
    guard makes it). The other two cases — a session with **no folder** at all, and
    one whose folder has since vanished or become a file — fall back to
    `model.restoreSession(session)` directly, because there is no folder to switch
    to: the tabs do not depend on the folder's fate, and an untitled scratch buffer
    stored under the `nil` key must come back exactly as before. Everything is
    **silent** — a
    missing file, an unreadable one, a vanished folder all pass without an alert or a
    beep, since restore is not an operation the user asked to succeed. The writer
    starts *after* the session is applied (so the intermediate states restore
    produces are never persisted over what was saved) and writes nothing until the
    workspace actually changes — see `SessionController`'s `dropFirst()`, without
    which a lossy restore would be persisted over the recorded session ~1 s after
    launch with no user action. Finally, the existing
    `willTerminateNotification` observer calls `autosave.flushNow()` **then**
    `sessionController.flushNow()`, in that order and from this one place: the
    session records a dirty *titled* file only by path, so the snapshot is truthful
    only once those buffers have reached disk (otherwise the next launch reopens the
    file showing the pre-quit disk state as if it were clean). Doing it here rather
    than letting each controller register its own observer is what makes the
    ordering deterministic and visible — two independent observers would run in
    registration order, which nothing states or enforces — and it is why
    `AutosaveController.flushNow()` is internal; that controller keeps its own
    termination observer, and `flushNow()` is idempotent, so being called twice on
    one quit is harmless — **provided the two calls agree on
    `abandoningBuffers`**, which is why that observer passes `true` as well. They
    write the same bytes only if they do: a caret-protecting flush writes the
    spared run and an abandoning one writes it trimmed, so two observers
    disagreeing on the flag would make the quit's answer depend on exactly the
    registration order this paragraph says nothing enforces.
    `PisakaApp` also owns the **commit dialog**: a `private let commitDialog =
    CommitDialogModel(gitService: GitCLIService())` alongside the
    other git models — a plain stored property (the
    `diffWindows`/`sessionController` precedent: the `@main` App is created once,
    so a `let` is a stable instance), deliberately **not** `@StateObject`, for the
    reason `ContentView` documents on its own non-observing `commitDialog`:
    nothing in this scene's `body` reads a published property of it, it is only
    handed to the sheet, which observes it itself, so holding it as `@StateObject`
    made the App's body a subscriber and every keystroke in the message field
    invalidated the whole window — re-creating `ContentView` with its
    non-`Equatable` closure parameters and putting the project tree, the tab list
    and `CodeEditorView.updateNSView` right back on the typing path that comment
    claims to keep them off — a `@State private var isCommitDialogPresented`, a
    `CommandMenu("Git")` holding "Commit…" (**⌘K**, JetBrains' shortcut) disabled
    on exactly the one condition the `LocalChangesView` header button is — no
    project root — and deliberately **not** also on `changedFiles` being empty:
    that list is refreshed only on a folder open, a save and the manual Refresh
    button, so a change made in the embedded terminal or an external editor would
    leave ⌘K dead until the user found that button, while the dialog's own load
    runs a fresh `git status` (after flushing dirty buffers) and reports "No local
    changes" honestly. It is also what makes a **message-only amend** reachable — a
    clean tree is exactly when it is wanted, and `CommitGate` already permits an
    empty selection under Amend. Four handlers are threaded into
    `ContentView`. `openCommitDialog(preselectingPath:)` first **guards against re-entry**
    (`isCommitDialogPresented`): a SwiftUI sheet does not disable the main menu, so
    a second ⌘K would raise a second modal autosave suspension that no `onDismiss`
    ever balances — the sheet is already up, so none fires — leaving autosave off
    for the rest of the session, and would reload the dialog, resetting the user's
    per-line selection mid-composition. Then, in order: it **refuses** while
    `revertInFlight()` (the commit reads every
    changed file and then writes a temporary index from them, which a concurrent
    `git checkout` would make nonsense of); it **flushes dirty buffers**
    (`autosave.flushNow(reportingSaves: true)`) because the dialog shows what is on
    *disk*, so an
    unsaved buffer would otherwise be invisible to it and silently left out of the
    commit — `reportingSaves: true` because unlike the quit-time flush this one
    lands **mid-session**, so the writes it makes need the follow-up an ordinary
    autosave gets (`onSaved` → the Local Changes re-query, plus the `treeRevision`
    bump for a file this flush *recreated* after an out-of-band deletion); without
    it the panel kept describing the pre-flush disk state, plainly wrong the moment
    the user cancelled the dialog and corrected only by some unrelated later
    refresh — and, since that flush is **best-effort** (`saveAllDirty()` swallows a
    per-file write failure by design, leaving that buffer dirty), it measures what
    is still dirty and *titled* afterwards and names those files in an alert, so a
    file whose write failed is not committed with its stale disk contents
    unannounced; the dialog still opens, because one unwritable path must not
    strand a feature the other files are perfectly committable through, and the
    alert is raised **last** — after the re-entry guard is closed and the
    suspension is balanced by `onDismiss` — since it runs a nested run loop a
    second ⌘K could re-enter; and it raises the **modal** autosave gate (`suspendForModal()` rather
    than `suspend()`, deliberately, so a quit while the sheet is open still flushes
    every dirty file), whose matching `resumeFromModal()` is the sheet's
    `onDismiss` — firing on *every* closing path, which is what makes the
    suspension impossible to strand. The load is pinned to the token
    `commitDialog.prepareForFolderChange(root:)` returns, captured synchronously
    before the `Task` hop, and forwarded as
    `commitDialog.load(root:request:preselectedPath:)`. That last argument is the
    method's **one** parameter and the *only* difference between the three entry
    points: ⌘K and the header ✓ button call it with none (every file checked, the
    `nil` default), while a changed file's own "Commit…" context-menu item passes
    `file.path` so only that file starts checked (`onCommitFile: { file in
    openCommitDialog(preselectingPath: file.path) }`). Everything around it — the
    re-entry guard, `revertInFlight()`, the autosave flush and its unsaved-files
    alert, the modal suspension, the generation pinning — is shared *verbatim*,
    which is why the orchestration is **parameterized here rather than duplicated**
    at the row's call site: a second copy of this sequence is exactly how one of
    those gates goes missing on one of the paths. What a preselect means, and what
    a path absent from the fresh `git status` means, are `CommitDialogModel`'s
    decisions, not this method's. `commitFromDialog(originGeneration:)` takes its pin as a
    *parameter* rather than reading it: the whole body runs inside the view's
    `Task`, i.e. after the window the pin exists to close, so a token read here
    would be compared against itself and could never fire — `CommitDialogView`'s
    Commit button reads `model.currentRequestGeneration` synchronously in its
    action and threads it through `onCommit: (Int) async -> Void`, the
    `ProjectSearchView.confirmReplaceAll`/`onReplaceAll` shape. It also raises the
    **full writer bracket** every sibling takes — `autosave.suspend()` +
    `localChanges.beginRevert()` synchronously before the first `await`, and
    lowered again the instant `commit()` returns, **before any modal**
    (`runBranchOperation`'s rule: `PlatformAlert.presentMessage` is
    `NSAlert.runModal()`, a nested run loop, and `AutosaveController.flushNow()`
    bails while suspended, so a quit while the push-failure alert is on screen
    would skip the termination flush for every dirty buffer; nothing after the
    `await` suspends, so there is no exit path in between and a `defer` bought
    nothing) — because the modal suspension taken at open gates
    `performAutosave` alone: a commit reads the whole working tree into the
    temporary index (a file entering as `.addFromWorktree` has its bytes read by
    git at commit time, and `CommitStaleness` only re-compares *rows*, so a write
    landing in that window is silently committed) and a formatting `pre-commit`
    hook then writes it back, while ⌘S / ⌘R / ⌘U stay live over a sheet (SwiftUI
    does not disable the main menu — the fact the re-entry guard above exists for)
    and the project-tree operations, the run/test saves **and `save(id:)` itself**
    key on `localChanges.isReverting` through `revertInFlight()`. That last one is
    what actually closes ⌘S: the gate is only worth raising if every writer reads
    it, and a manual save was the one path that did not — landing mid-commit it
    writes bytes the dialog never displayed and `CommitStaleness`, which compares
    rows read *before* the write, cannot see. Gating the save also covers the close
    prompt's "Save" and, retroactively, a ⌘S during a revert / merge apply / branch
    checkout / Replace All, each of which raises the same flag. `revertInFlight()`'s
    notice is therefore worded for any git operation rather than for a revert. The dialog **stays
    open** on everything that did
    not create a commit (a gate refusal, a stale snapshot, git's failure — the
    reason, git's stderr verbatim, already published in `errorMessage`) and closes
    on everything that *did*, **including a failed push**: the commit exists, and
    leaving a dialog open whose Commit button would make a second one is the
    mistake this must not invite, so a push failure closes the sheet and says so in
    its own alert. `refreshAfterCommit()` re-queries Local Changes, the Git Log and
    the branch widget (all generation-pinned, the last through a new
    `refreshBranchSwitcher()` mirroring `refreshLog()`) and deliberately does
    **not** `bumpTreeRevision()` — a commit writes `.git`, not the working tree, so
    no listing changed; a `pre-commit` hook that rewrites files is the exception,
    and its edits surface as ordinary local changes through the Local Changes
    refresh. That hook is also why a commit is the fourth path to run
    the **open-tab resync**, through the same `openTabSnapshot()` /
    `resyncOpenTabsAfterCheckout(snapshot:repoRoot:mayRemoveFiles:)` pair as
    `revertChanges` and `switchBranch` (`applyMerge` resyncs its one resolved file
    inline rather than through the loop). All of them — the loop's two callers and
    `applyMerge`'s single-file path — ask `resyncViewerTab(_:mayRemoveFiles:)`
    before any text-shaped reasoning, because a viewer tab answers a text snapshot
    with "clean and unchanged" and would otherwise be force-closed over a file
    still on disk — and because a viewer tab whose file *was* rewritten needs its
    connection re-opened, git having renamed a new file over the one its handle
    holds (`core-database-viewer.md`) (snapshot captured synchronously before the
    `await`, `repoRoot` from `commitDialog.root` so tabs outside the repository are
    left alone): a formatting hook — prettier, `eslint --fix`, gofmt — edits the
    files on disk, and git runs it before reading the index it commits. Without the
    resync the tab kept the pre-format text with `savedText` matching it
    (`openCommitDialog` flushed autosave, so every titled tab is clean), so
    `isDirty` was false and **nothing would ever correct it** — the next keystroke
    autosaved the whole stale buffer over the file, silently reverting the hook's
    work and making it look like the user's own edit. It therefore runs on
    `.failed` **as well as** on the two committed outcomes (with
    `refreshLocalChanges()` beside it, those rewrites being ordinary local changes
    now): the commonest way a commit fails *is* a hook that reformats the tree and
    then refuses, so the tree is already rewritten when git exits non-zero, and the
    silent revert above does not become acceptable because of the exit code.
    `.blocked` and `.stale` are the two outcomes that genuinely ran nothing — no
    index step, no hook — so they are left alone. The commit path passes
    `mayRemoveFiles: false`, which suppresses the resync's "file gone → force-close
    the tab" rule: that rule is right for a checkout, which really does delete
    worktree files, but a commit never does (`.removePath` stages a deletion in the
    throw-away index and touches nothing on disk), so a missing file was already
    missing when the dialog opened — closing there would discard, with no prompt, a
    clean buffer holding the last copy of a file that is no longer on disk. Such a
    tab is left untouched rather than made dirty, since a dirty titled buffer is
    what autosave would use to recreate the very file the user deleted.
    `openFolder(url:)` also
    registers the switch with `commitDialog`
    synchronously alongside the other models, with sharper consequences than
    elsewhere: it **dismisses a sheet that is up** (`reset()` empties everything the
    sheet displays but cannot lower `isCommitDialogPresented`, so it stayed on
    screen bound to a deliberately emptied model — no files, a blank author line,
    the message being composed wiped, no spinner, and "This folder is not a git
    repository." under a disabled Commit button, with nothing saying why; ⌘⇧O is
    reachable from a sheet, since SwiftUI does not disable the main menu — the same
    fact `openCommitDialog`'s re-entry guard exists for — and dismissing also fires
    `onDismiss`, so the modal autosave suspension is released rather than
    stranded), clears the previous project's selection and message and bumps the
    token an in-flight `commit()` is pinned to, so a commit composed for the folder
    the user just left can never run against the newly opened one.
    **LeetCode** (LC-1; the layer's full entry is in `core-leetcode.md`) adds
    `makeLeetCode(settings:)` — the stack composed once from the three
    cross-platform seams, with the folder read out of `SettingsStore` *before* the
    model exists, so `isSignedIn` and the folder are right from the first frame —
    held as a **non-observed `let`** beside `commitDialog`/`symbolIndex`, since the
    surfaces that show its state (`LeetCodeCommands`, the Open Problem sheet, the
    login sheet, the Preferences tab and the description pane) each observe it
    themselves. A `CommandMenu("LeetCode")` hosts `LeetCodeCommands` (Open
    Problem… ⌘⇧P, state-dependent Sign In…/Sign Out, Choose LeetCode Folder…),
    gated on nothing — a problem is written into the user's LeetCode folder and
    opened as a tab whether or not a project is open. The two sheets are one
    `.sheet(item:)` over an enum attached **outside** `ContentView` (they are
    mutually exclusive, and the scene is where they belong if the window is to stay
    free of the parameter and the observation) — and they are genuinely alternatives
    rather than a stack: the login sheet a signed-out user raises *from* the Open
    Problem sheet is presented by that sheet over itself, precisely so this slot is
    never swapped while it is up. `openLeetCodeProblem` returns its
    sentence *to the sheet*, refuses to open a tab once its `Task` has been
    cancelled (the sheet cancels the open it is holding on disappear, so Esc means
    Esc), and keeps `PlatformAlert` for the two failures that happen with the sheet
    already gone — the tab open, and a login LeetCode rejected behind the dismissed
    web view; `openLeetCodeSolution`
    opens the file through `model.open(url:)` like any other and bumps the tree
    revision **only** when it landed inside the open project, because opening a
    problem never changes the project root — and when that open *fails* it re-asks
    the statement question for the selected tab before alerting, since the
    statement `openProblem` published is global rather than keyed to a tab and the
    selection did not change, so `ContentView`'s `.task(id:)` would not re-run
    (`core-leetcode.md` carries the full rule). Sign Out always goes through
    `LeetCodeWebSession.signOut(model:)` (never `model.signOut()` alone, which
    would clear the Keychain and leave the cookies), and the launch-time
    `refreshUserStatus()` joins the one-shot `.onAppear` block beside
    `sweepStaging()`/`lspProvisioning.refresh()` — unawaited and silent, since the
    menu already says "signed in" optimistically from the Keychain item. The scene also attaches the `MainWindowFrameAutosave` marker to its content, before the sheet modifiers, so exactly one window adopts the name; it must not move into `ContentView` because the marker must sit in the scene's own content to avoid being pulled into a presentation or duplicated.
  - `MainWindowFrameAutosave.swift` — the main window's frame persistence, done by
    hand because the standard window-frame autosave is unusable here twice over
    (both halves verified live in the preferences domain): the framework-derived
    save key embeds private-context type names that are address-mangled and
    therefore fresh on every launch, and adopting an explicit autosave name does
    not help because the scene's window redirects the save machinery itself —
    the adopted name sticks on the window while every save, even a manual
    `saveFrame(usingName:)` with the explicit name, lands under the derived
    per-launch key. So a non-drawing marker in the scene's content restores the
    frame from the marker's own defaults key (`MainWindowFrame` — a chosen
    constant whose rename would cost the saved frame once, deliberately outside
    the `NSWindow Frame` namespace that belongs to the bypassed machinery) on
    window attach and re-applies it once on the next main-runloop turn, and only
    *then* starts writing `frameDescriptor` back under that key on the window's
    move/resize/close notifications — observing from the start would let the
    scene's setup-time resize overwrite the saved frame with the default one.
    The persistence state is window-side and app-lifetime (a weak set of adopted
    windows, tokens never unregistered), so a recreated marker view neither
    re-restores over a resize the user has since made nor tears the observers
    down. The frame descriptor carries the screen geometry, so a changed display
    arrangement is constrained by the same call that applies it, and the
    content's minimum-size floor still clamps from below. The auxiliary windows
    deliberately persist nothing and center per use instead.
  - `SoftwareUpdater.swift` — the app's **entire** Sparkle 2 surface, wholly
    inside `#if os(macOS)`: a small `ObservableObject` owning one
    `SPUStandardUpdaterController`, plus `CheckForUpdatesCommand`, the one-button
    view the app menu's command group holds. Sparkle is imported here and
    nowhere else; nothing in `Sources/Pisaka/iOS/` or `PisakaCore` may name any
    of its types.

    **Why nothing lives in Core.** Sparkle here is *configuration*, not a
    decision. What feed to read and which key verifies it are `SUFeedURL` and
    `SUPublicEDKey` in `Resources/Info.plist`, read by Sparkle itself (entry in
    `core-services.md`); when to check, what to show, and how to install are
    Sparkle's own standard behaviour, deliberately left untouched — both
    delegates are `nil`, there is no custom UI, and no key answers the
    automatic-check question on the user's behalf. That leaves no pure rule to
    extract, so this file follows the app layer's convention and carries no unit
    test. **The absence is a recorded decision rather than an omission**, and the
    file's own doc comment says so: the static guarantees for the feature live
    where the facts do — `ReleaseMetadataTests` pins the two plist keys,
    `ReleaseWorkflowTests` pins the workflow that produces what the feed points
    at. If a real decision ever appears here (a version-comparison rule, a
    channel policy, an eligibility gate) it belongs in Core with tests, and this
    file goes back to being glue.

    **Inert in DEBUG, and not compiling the updater in is the whole mechanism.**
    Under `#if DEBUG` the framework is not even imported and no controller is
    constructed: `canCheckForUpdates` stays `false` forever (so the menu item is
    permanently disabled), and `checkForUpdates()` returns without doing
    anything — it stays callable so the two builds share one call site instead of
    gating the command itself. Nothing schedules a background check, nothing
    fetches the feed, and Sparkle's first-launch "check automatically?" consent
    prompt never appears. Both halves of that matter: a development build would
    otherwise raise the prompt against a feed that may carry no releases yet, and
    the *answer* is persisted per bundle identifier, so a later release build
    would silently inherit whatever a developer clicked. There is no scheme
    argument, no defaults key and no stub updater behind this.

    **That rule is enforced statically, because no build can catch it.** Removing
    the `#if !DEBUG` around `import Sparkle`, or moving the controller into the
    `#if DEBUG` branch beside the no-ops, **compiles cleanly in both
    configurations** — so the damage is silent and, through the persisted
    per-bundle-identifier consent answer, permanent. `SparkleSourceGatingTests`
    (Foundation-only, reading `Sources/Pisaka` through `#filePath`, in the
    `LSPSourceGatingTests` mould) asserts that `import Sparkle` appears in exactly
    this file and inside both `#if os(macOS)` and `#if !DEBUG`, and that no
    `SPU…` type is referenced from the DEBUG branch. Comments and string literals
    are stripped before matching — this file's own documentation discusses
    `SPUStandardUpdaterController` at length, and rewording documentation to
    appease a test would be the wrong direction — and the stripping is
    `LSPSourceGatingTests.strippingCommentsAndStringLiterals` itself rather than a
    second implementation: a line-at-a-time stripper that removed `//` *before*
    string literals truncated every line carrying a URL at the `//` inside it,
    which is a silent hole in a sweep whose only value is being exhaustive.

    **Two details of that suite are load-bearing rather than incidental.** It
    classifies each `#if` condition as "requires DEBUG" / "requires not-DEBUG" /
    "unrelated" instead of comparing condition *text*, because the obvious text
    walker (push `!DEBUG`, rewrite its `#else` to `!(!DEBUG)`, ask whether the
    stack contains `DEBUG`) goes blind to exactly the most natural restructuring
    of this file — collapsing its two `#if`s into one `#if !DEBUG` / `#else` —
    and an `SPU…` reference placed in that `#else` compiles in both
    configurations and ships an armed updater in development builds. A condition
    that mentions `DEBUG` but is not exactly `!DEBUG` counts as a DEBUG branch, so
    a compound condition is flagged rather than waved through. And the import
    check reads the *live* directive stack at the import line rather than asking
    whether `#if !DEBUG` appeared somewhere earlier, which a closed
    `#if !DEBUG` … `#endif` followed by a bare `import Sparkle` would satisfy
    while importing the framework unconditionally.

    The related gap on the *other* side is closed in CI rather than here: because
    everything above is behind `#if !DEBUG`, a Debug-only build gate would never
    compile the shipping code path at all, and a Sparkle API change would first
    surface inside the release workflow's archive step after a tag was already
    pushed. `ci.yml`'s macOS job therefore builds `-configuration Release`, and
    `release.yml` passes `-configuration Release` explicitly rather than relying
    on Xcode's implicit archive default. **Both of those flags are themselves
    pinned by `ReleaseWorkflowTests`, each scoped to the one step that runs the
    command** — a file-wide or repository-wide `contains` would let CI's copy be
    satisfied by the release workflow's, which is the drift most worth catching,
    since dropping the flag from `ci.yml` (a revert, or a "why is CI slow?"
    cleanup aimed at the timeout this raised from 30 to 45 minutes) leaves
    `swift test` entirely green while removing the only pre-tag compile of the
    shipping path.

    That trade is worth stating exactly, because it was made in the *switching*
    direction rather than by adding a job: the macOS job no longer builds Debug,
    and the iOS job cannot stand in for it — every file here is inside
    `#if os(macOS)`, so the iOS compile never reaches them. Debug is still
    compiled on every PR (by the iOS job), but *macOS-gated code under
    `#if DEBUG`* is now compiled by no CI job at all. The residual exposure is
    bounded and checked: the app layer outside `Sources/Pisaka/iOS/` contains
    exactly one `#if DEBUG`, and it is this updater's two no-op declarations. Any
    macOS Debug-conditional code with real content would need a third job.

    **That bound is asserted rather than merely stated**, by a third case in
    `SparkleSourceGatingTests`: every app source outside `Sources/Pisaka/iOS/` is
    walked with the same directive walker, and the set of files carrying a live
    DEBUG-only branch must be exactly `{SoftwareUpdater.swift}`. Without it the
    sentence above is a comment in `ci.yml` that quietly stops being true the
    first time someone adds a `#if DEBUG` block elsewhere — code that then ships
    compiled by nobody and breaks only on a developer's machine. The walker is
    reused rather than a text match for the reason it exists: a `#else` closing a
    `#if !DEBUG` is a DEBUG branch too, and this file is the proof the two shapes
    are interchangeable. The failure message points at adding the third,
    macOS-Debug job — widening the allow-list would be discarding the check.

    In a release build `SPUStandardUpdaterController(startingUpdater: true, …)`
    creates the updater and the standard user driver and starts it immediately,
    which is what arms the scheduled check and the first-launch prompt.
    `startingUpdater: true` makes a misconfigured bundle a hard failure at launch
    (Sparkle aborts when it cannot start — a malformed `SUPublicEDKey`, say),
    which is the deliberate choice: the alternative is an app that silently never
    updates. Both routes to that failure are closed before a build ships — the
    plist keys are pinned by `swift test`, and the release workflow refuses to
    publish while the placeholder key is in place. The published
    `canCheckForUpdates` republishes Sparkle's own KVO-compliant
    `SPUUpdater.canCheckForUpdates` (upstream's documented property for
    validating exactly this menu item: `false` while an update session or
    background download is in flight) through `assign(to: &$…)`, which keeps the
    subscription owned by the object — no stored cancellable, no retain cycle to
    weaken. Republishing rather than exposing the updater is what keeps Sparkle's
    types out of the rest of the app: the menu item needs one `Bool`.

    **Menu wiring.** `PisakaApp` holds one instance as a plain `let` (the
    `commitDialog`/`leetCode` precedent — the `@main` App is created once, so a
    `let` is a stable instance) and adds
    `CommandGroup(after: .appInfo) { CheckForUpdatesCommand(updater:) }` beside
    the existing `.newItem`/`.saveItem` groups: `after:` rather than `replacing:`,
    so "About Pisaka" stays and the item lands directly beneath it, which is both
    Sparkle's recommended placement and where macOS users look. The scene body
    reads nothing published on the updater — `CheckForUpdatesCommand` observes it
    with its own `@ObservedObject`, so an update session toggling
    `canCheckForUpdates` re-renders one button instead of re-creating
    `ContentView`. That is the same invalidation argument every other
    non-`@StateObject` model in `PisakaApp` states. `checkForUpdates()` runs a
    *user-initiated* check, which shows Sparkle's standard UI including its
    "you're up to date" alert — hence it is called from the menu item and never
    on a timer.
  - `ProjectWatcher.swift` — the macOS-only (`#if os(macOS)`, `import CoreServices`)
    FSEvents subscription that makes an *external* change (a generator run in the
    embedded terminal, a Finder rename, a console `git checkout`) show up in the
    project tree without reopening the folder. Thin and untested per the view-layer
    convention — it is IO only (a C stream, its queue, its lifetime), while the one
    decision it makes lives in Core as the pure `TreeRefreshFilter` — and it copies
    `AutosaveController`'s shape: an idempotent `start(root:onChange:)` (a repeated
    call tears the previous stream down first, so a folder switch simply switches the
    subscription), a `stop()` safe to call more than once, and `deinit` teardown.
    Stream flags and why: **directory-level events** (no
    `kFSEventStreamCreateFlagFileEvents`) because the re-read is per-directory
    anyway, which keeps `TreeRefreshFilter`'s `.git` rule live (git's writes arrive
    as directories inside `root/.git`) and its `.DS_Store` rule dormant (a Finder
    write arrives as the containing directory → one harmless bump);
    **`kFSEventStreamCreateFlagIgnoreSelf`** because the app's own create / rename /
    delete already bump synchronously and, more importantly, autosave writes a file
    every idle burst / tab switch / focus loss — under dir-level events each such
    write would report the containing directory, i.e. a recurring main-thread re-read
    of every expanded node for a listing that never changes; what it does *not*
    suppress is the embedded terminal's shell and every `GitCLIService` invocation
    (child processes with their own pids), so the headline `npx … new backend` case
    is unaffected, and the two in-app writes it would have covered by accident (Save
    As, and reverting an untracked file — an in-process `unlinkat`) get their explicit
    bumps in `PisakaApp`; **latency `1.0` s with ordinary
    deferred coalescing** (no `kFSEventStreamCreateFlagNoDefer`) so an `npm i`
    collapses into a handful of firings; plus `kFSEventStreamCreateFlagUseCFTypes`
    and `sinceWhen = kFSEventStreamEventIdSinceNow`. `start` **canonicalizes** the
    root (the private `canonical(_:)`) before handing it to either the stream or the
    filter — FSEvents reports realpath-spelled paths regardless of how the watched
    path was spelled, so a folder opened through a symlink or a firmlink (`/tmp` →
    `/private/tmp`) would otherwise have every delivered path fail
    `TreeRefreshFilter`'s root-containment rule and the feature would silently never
    fire; only the watcher resolves, `WorkspaceModel.projectRoot` stays as the user
    spelled it because the tree's own symlink semantics depend on that. It uses
    `realpath(3)`, *not* `URL.resolvingSymlinksInPath()` — which resolves ordinary
    symlinks but deliberately strips a `/private` prefix, mapping `/private/tmp` back
    to `/tmp`, the reverse of what is needed — nor `URLResourceValues.canonicalPath`,
    the mirror-image half-measure that resolves the firmlink while keeping the final
    component literal (so a folder opened *through* a symlink stays unresolved).
    `realpath` does both and falls back to the url as given when it fails. This is
    the deliberate *opposite* of Core's `CanonicalPath.canonical(_:)`, which keeps
    `resolvingSymlinksInPath()` and its `/private` stripping: there both sides of
    the comparison go through the same transform so consistency is all that is
    needed, while here only one side is under the app's control (FSEvents supplies
    the other, already realpath-spelled). Neither should be "fixed" into the other.
    The stream
    runs on its own
    serial `DispatchQueue` (`FSEventStreamSetDispatchQueue`), so neither the callback
    nor the filter touches the main thread — only the final `onChange()` hops back to
    the main actor. The C bridging is by the book: the context's `info` is an
    `Unmanaged.passRetained(self)` balanced in `stop()` (and immediately, via the
    shared `disarm(info:)`, on a failed `FSEventStreamCreate` *or* a failed
    `FSEventStreamStart` — both leave the watcher unarmed with `stream` still `nil`,
    so a later `stop()` cannot stop a never-started stream; the Refresh button remains
    the fallback, so a failure degrades rather than breaks), and `stop()`
    runs `FSEventStreamStop` → `Invalidate` → `Release`, then a `queue.sync {}`
    barrier before the balancing release — `Invalidate` does not wait for a callback
    already running on the stream queue, and that callback holds only an *unretained*
    reference, so the drain is what keeps the release from deallocating underneath it
    (no deadlock: the callback only ever does `DispatchQueue.main.async`).
    `root`/`onChange` are `NSLock`-guarded (written on the main thread,
    read on the stream queue — the `SecurityScopedFileService` precedent). iOS is out
    of scope: FSEvents does not exist there, so the tree still refreshes only on the
    app's own operations.
  - `AutosaveController.swift` — the thin view-layer wiring of JetBrains-style
    autosave to `WorkspaceModel.saveAllDirty()` (all the testable decision logic
    lives in Core; this is trigger→action wiring only, untested like the rest of
    the view layer). A `final class` holding the Combine cancellables and
    notification observers, with a fixed `idleDelay` constant (`2.0` s, no
    user-facing toggle or configurable delay) and
    `start(model:prepareForSave:onSaved:)` (whose `prepareForSave` takes
    `(ids, abandoningBuffers)`; plus
    `stop()`/`deinit` teardown; `start` is idempotent so a re-fired `.onAppear`
    can't stack observers). `prepareForSave` is the **on-save transform**, injected
    rather than reached for so this controller keeps holding no policy: it knows
    when a save happens and which buffers it is about to write, and nothing about
    `.editorconfig`. It is handed `dirtyTitledIDs(in:)` — the ids `saveAllDirty()`
    will actually write, dirty *and* titled — because transforming a clean
    background tab would rewrite a file nobody edited into the next commit; and it
    runs **before** `missingDirtyPaths(in:)`, because it rewrites buffers and the
    probe reads which of them exist. The transform may *add* buffers of its own —
    the trims a spared caret line deferred, which were edited and whose rewrite was
    postponed rather than declined — and that union is its bookkeeping, made in
    `SaveTransformController.prepareForAutosave`, not here. The second argument,
    `abandoningBuffers`, is the orthogonal axis: `true` on the quit flush and on
    the folder switch's second, post-refusal flush, where the buffers do not
    survive the write, so the transform stops protecting a caret that is about to
    cease to exist. Both
    `flushNow` paths transform too: the quit
    flush is a buffer's last chance to be written correctly, and the commit
    dialog's flush is what the dialog then reads off disk. `nil` (previews, tests)
    leaves every write byte-identical. Four triggers: **idle** —
    `model.$openFiles.debounce(for: .seconds(idleDelay), …)` → `performAutosave`
    (a save advances `savedText`, republishing `$openFiles` and re-arming the
    debounce, but the re-fire is a no-op because `saveAllDirty()` is idempotent,
    so the loop terminates); **tab-switch** — `model.$selectedID.dropFirst()` →
    `performAutosave` (also fires on a tab *close*, harmless via idempotence, and
    revert-driven closes happen while suspended); **focus-loss** —
    `NSApplication.willResignActiveNotification`, hopping to the main actor before
    touching the model; **termination** — `NSApplication.willTerminateNotification`
    → a synchronous `flushNow()` (NOT the debounced path, NOT an async hop), the
    gap-closer because `willResignActiveNotification` does *not* fire on a direct
    Cmd+Q of the frontmost app (macOS runs `applicationShouldTerminate` →
    `applicationWillTerminate` without deactivating), so focus-loss alone would
    lose the last idle-debounce window of edits; the notification arrives on the
    main thread as the run loop ends, so a direct synchronous `saveAllDirty()` is
    the only thing guaranteed to complete before the process exits (it *reports*
    its saves like every other write path, with `isTerminating: true` — what the
    quit path skips is the probe and, at the caller, the Local Changes refresh and
    the tree bump). Suspend gating uses *two* re-entrant counters
    (not booleans, so overlapping/nested suspensions each balance their own pair).
    `suspendCount` (`suspend()`/`resume()`) is raised only by an in-flight git
    revert and gates *both* `performAutosave` and `flushNow` — a quit landing
    mid-revert is the rare accepted corner where the revert's intentional discard
    wins. `modalSuspendCount` (`suspendForModal()`/`resumeFromModal()`) is raised
    only while a close-confirmation modal is open and gates `performAutosave`
    *only*, deliberately **not** `flushNow`: the idle debounce (a GCD main-queue
    timer) fires inside the alert's nested run loop and would pre-empt a "Don't
    Save", so the regular triggers must pause — but there is no revert racing the
    disk, so a quit while the alert is open must still flush every *other* dirty
    file; folding it into `suspendCount` would suppress that quit-time save (data
    loss). `performAutosave` bails while *either* counter is raised
    (`isRegularSuspended`); `flushNow` checks `suspendCount` alone. A trigger
    dropped while suspended is recorded (`pendingAutosave`) and replayed once *both*
    counters return to zero. `performAutosave` calls `onSaved` only when `saveAllDirty()` returned a
    non-empty list, and beeps at most once (non-modal, latched via
    `didBeepForFailure`) if a dirty titled file remained after a write failure.
    `onSaved` is
    `(_ saved: [URL], _ createdFile: Bool, _ isTerminating: Bool) -> Void`, and it
    is invoked on **every** write path — the three of them: `performAutosave`, the
    reporting branch of `flushNow` and the quit branch. Before the write
    `performAutosave`
    collects the dirty *titled* buffers whose file is missing on disk
    (`missingDirtyPaths(in:)` — only dirty titled buffers are probed, so a
    nothing-to-save re-fire costs no syscall) and reports whether any saved url was
    among them, so `PisakaApp` can bump `treeRevision` for an autosave that recreated
    an externally deleted file (which the watcher's `IgnoreSelf` hides). It also
    hands over the urls it actually wrote, for a second consequence of that same
    `IgnoreSelf`: the `.editorconfig` cache has no watcher behind it either, so
    `PisakaApp.noteEditorConfigWrites(_:)` needs to be told which files this tick
    wrote or an autosaved `.editorconfig` would go unnoticed
    (`core-editorconfig.md`). The third argument, `isTerminating`, says the report
    comes from the **quit** flush, where the caller's usual follow-up work is
    pointless — there is no Local Changes panel left to refresh and no tree left to
    bump, and `createdFile` is always `false` there because the probe that would
    answer it is skipped. It exists because a *report* on that path is **not**
    pointless: Local History's last chance to snapshot the edit a user is quitting
    on is exactly the edit a safety net is for (`core-local-history.md`), and it is
    one callback invoked on every write path with a flag saying which, rather than
    a second hook the next write path could again forget.
    `flushNow(reportingSaves:)` skips the probe **by default**, which is right for
    its original caller and wrong for its second one: on the quit path there is no
    tree left to bump and no panel left to refresh, but `openCommitDialog` flushes
    *mid-session* (the dialog reads disk, so every dirty buffer has to reach it
    first) and there it writes files exactly as `performAutosave` does — so it
    passes `reportingSaves: true` and the side effects become mandatory rather than
    pointless. Without them the Local Changes panel kept describing the pre-flush
    disk state (visibly wrong the moment the user cancels the dialog) and a buffer
    whose file had been deleted out of band was put back on disk with no
    `treeRevision` bump to reveal it. What it no longer skips on either branch is
    the **callback**: it did until Local History gave the quit path a listener, and
    a flush that wrote bytes and told nobody is how a write path silently loses its
    safety net — so every branch reports, and
    `LocalHistorySourceGatingTests.testEveryAutosaveWritePathReportsItsSaves` pins
    the count at three. `flushNow` is **internal, not
    private**: `PisakaApp` calls it directly on `willTerminateNotification`, ahead
    of `SessionController.flushNow()`, so the two flushes are ordered from one
    visible place (see there). No behavior change — the controller keeps its own
    termination observer and `saveAllDirty()` is idempotent, so being called twice
    on the same quit writes nothing the second time. That observer passes
    `abandoningBuffers: true`, matching `PisakaApp`'s call: the second flush writes
    nothing only when the first one already wrote what the quit rule asks for.
  - `SessionController.swift` — the thin view-layer wiring that writes the editor
    session (the opened folder, the tabs, the selection, the text of Untitled
    buffers) to Core's `SessionStore`, so a launch can bring the last session back
    — including after a crash or a force-quit, since it writes continuously rather
    than only on exit. **The keying is not its business**: `store.save(_:)` is an
    upsert keyed by the snapshot's own `folderPath`, promoting that project to the
    catalog's head, so per-project sessions cost this file no code at all — it
    still hands over one snapshot and the store decides where it lands. That is
    also why the folder-switch orchestration can call `flushNow()` to persist the
    *outgoing* project: taken while `projectRoot` is still the outgoing folder, the
    snapshot keys itself. macOS-gated (`#if os(macOS)`) and shaped like
    `AutosaveController`: idempotent `start(model:store:)` (guarded on `model ==
    nil`, because `.onAppear` can fire again and stacked subscriptions would write
    per change several times), Combine subscriptions merged over
    `model.$openFiles`/`$selectedID`/`$projectRoot`, a fixed `writeDelay` (1.0 s,
    not user-configurable — shorter than autosave's idle delay, since writing a
    small plist is cheap and a fresher session means less lost to a crash) on a
    main-queue `debounce`, `stop()`/`deinit` teardown, and a synchronous
    `flushNow()` for quit. Every decision — what a session records, which buffers
    are worth storing, where the selection lands — is `EditorSession.snapshot`'s,
    so this stays trigger→action wiring and is untested like the rest of the view
    layer. **The subscriptions are a trigger only**: the snapshot is always taken
    from the *live* model when the debounce fires, never from a value captured in
    the closure — a `@Published` value is delivered *before* the property is
    committed (so a captured `openFiles` is the pre-change one) and the other two
    properties are not part of that delivery at all, so a cached snapshot would be
    stale in a way the debounce makes permanent until the next change. Each leg is
    **`dropFirst()`ed** (`AutosaveController`'s rule for `$selectedID`, load-bearing
    here): a `@Published` publisher replays its *current* value to every new
    subscriber, so without it merely subscribing fires the trigger and the session
    is rewritten ~1 s after launch with **no user change at all** — harmless when
    restore was faithful and destructive when it was not, since restore is
    deliberately lossy (a folder on an unmounted volume is not opened, a deleted
    file is not reopened) and that write would persist the truncated session over
    the recorded one before the user touched anything. Nothing is lost by waiting
    for a real change: `loadLastOpened()` returning `nil` and an empty stored
    session both
    restore nothing. **`flushNow()` honors that same rule** (`hasObservedChange`,
    raised by the *raw* trigger ahead of the debounce so a change made inside the
    last write window still flushes): it bypasses the debounce, not the guarantee —
    `lastWritten` is `nil` until the first write, so an unguarded quit-time flush
    would persist a lossy restore's empty snapshot over the recorded session on the
    next Cmd+Q with the user having touched nothing, reintroducing one quit later
    exactly what the `dropFirst()`s prevent one second after launch. The
    folder-switch caller leans on the same guard for a second reason spelled out on
    `openFolder(url:)`: at launch, restore opens the recorded folder *before* this
    controller is started, and an unguarded outgoing snapshot there would write the
    empty live model over the no-folder workspace's stored session. A snapshot **equal to the one last written is not written
    again** (`lastWritten`) — `$openFiles` republishes on every keystroke, so the
    steady state of typing in a titled file would otherwise cost a full
    `PropertyListEncoder` pass plus a `UserDefaults` write on the main thread per
    idle second, proportional (per limit 2) to an Untitled buffer the user is not
    even editing. An **empty
    session is written like any other**, so closing every tab and quitting does not
    resurrect the session before last. It deliberately registers **no
    `willTerminateNotification` observer of its own**: the snapshot must be taken
    *after* autosave's termination flush (a dirty titled file's contents are not
    persisted here, so the session is truthful only once those buffers reached
    disk), and resting that on the relative registration order of two independent
    observers would make it invisible and fragile — hence
    `AutosaveController.flushNow()` being internal and `PisakaApp` calling both
    back to back from one place.
  - `SettingsView.swift` — the Preferences window (⌘,), a four-tab `TabView`:
    "General" (`GeneralSettingsView`, the form below), "Language Servers"
    (`LSPServerSettingsView`, phase 2b — full entry in `core-provisioning.md`),
    "LeetCode" (`LeetCodeSettingsView` — the account, the solutions folder and the
    default language; full entry in `core-leetcode.md`, and it carries its own
    `@ObservedObject LeetCodeModel` so the Preferences host holds it as a plain
    `let` — nothing in `SettingsView.body` reads anything published on it, and
    observing it there would re-evaluate the whole window, Acknowledgements and its
    66 KB license texts included, on every statement fetch and busy transition)
    and "Acknowledgements" (`AcknowledgementsView`). A `TabView` sizes to its widest
    tab, which is why the split is worth noting: `GeneralSettingsView` keeps its
    own `.frame(width: 340)` while the Acknowledgements tab — needing room to read
    a license — is what drives the window. `PisakaApp` constructs
    `SettingsView(settings:provisioning:gopls:rust:installEngine:leetCode:)`,
    threading the
    provisioning models and engine through to the tabs that read them rather
    than letting each build its own view of the install root. `gopls` and `rust`
    reach the Language Servers tab *only*, for two different reasons that land in
    the same place: `go install` writes one binary and no license file, and
    rust-analyzer's bare `.gz` unpacks one binary and no license file either — so
    neither leaves anything in the installed tree for Acknowledgements to read,
    and each row names the origin and the SPDX id instead.
    `GeneralSettingsView` is the former Preferences form, verbatim: a thin
    `@ObservedObject
    SettingsStore` view (a `Form` with a `Picker` for tab orientation, a `Picker`
    for theme, a `Stepper` + numeric "Editor font size: N pt" display bound to
    `settings.fontSize`, ranged/stepped through the store's constants, and a
    `Toggle` bound to `settings.completionEnabled`, "Offer completions as you
    type", and a second `Toggle` bound to
    `settings.indentLevelHighlightingEnabled`, "Highlight indentation levels" —
    bound straight through in the same way, but unlike the completion flag it has
    no second surface, so this checkbox is the only place it is set). The
    completion row is the *same flag* the bottom bar's lightbulb writes
    (`app-window.md`): both bind straight through to the store with no local
    `@State`, which is what makes it impossible for the two surfaces to disagree —
    they are two views of one stored value, not two states to keep in sync. The
    flag itself, and the decision that off is **total** (no automatic popup and no
    explicit invocation) while nothing in the intelligence stack is torn down, are
    in `core-services.md`. Hosted by
    the `Settings { SettingsView(settings:) }` scene `PisakaApp` declares alongside
    its `WindowGroup`, which gives the standard Preferences menu item and ⌘,
    shortcut for free. `PisakaApp` owns the single `@StateObject private var
    settings = SettingsStore()` and threads it into `ContentView`. All option
    types, clamping, and persistence live in Core, so this is trigger→binding
    wiring only (untested like the rest of the view layer). Settings application is
    spread across the views that read `settings`: the theme via
    `.preferredColorScheme` on the window content root (`ContentView`), the tab
    layout in `ContentView`, the shared editor font size in the
    code views (`CodeEditorView`/`DiffView`/`MergeView`), completion on/off
    as a plain (undefaulted) value on `CodeEditorView` plus the Find > "Complete"
    item's `.disabled` in `PisakaApp`, and indentation-level highlighting as a
    second such value on `CodeEditorView` (`app-editor-overlays.md`).
    The zoom feature adds a **"Terminal font size: N pt" `Stepper`** beside the
    editor's, bound to `settings.terminalFontSize` over the same rule's
    range/step, so the two font zones read as one pair of rows and share the
    store's clamping; the interface zone has no row of its own (it is a gesture
    and ⌘=/⌘−/⌘0, per `core-zoom.md`). The Preferences form is itself *scaled* by
    the interface zone — `PisakaApp` applies `.interfaceScaled(settings)` to the
    `Settings` scene rather than inside `SettingsView`, because an environment
    write never reaches the view that makes it and the settings form has to grow
    too.
  - `Platform/LicenseCatalogLoader.swift` — the non-gated shim both
    Acknowledgements screens read (documented here rather than in `app-ios.md`
    because nothing about it is platform-specific: `Resources/Licenses` is a
    folder reference, so the directory lands as `Licenses/` inside the bundle on
    both destinations — `Contents/Resources/Licenses/` on macOS, `Licenses/` at
    the `.app` root on iOS — and `Bundle` resolves it identically from either;
    both lookups were verified against a built macOS `.app`). It reads
    `Licenses/licenses.json` and hands its bytes plus a `[file name: text]`
    dictionary to Core's `LicenseCatalog`, exposing `documents` (the resolved
    notices in manifest order, `[]` on failure) and `failureDescription` (`nil`
    on success). Thin glue only — every decision about what a well-formed
    manifest is stays in Core (`core-services.md`). Three details are
    load-bearing: (a) the cache is `private static let cached = Result { try
    load() }`, a `static let` being lazily initialized exactly once,
    thread-safely, and immutable afterwards — the texts are a few hundred
    kilobytes (libgit2's GPLv2-plus-exception alone is 64 KB) and never change at
    run time, so re-reading them on every selection change would be pure waste;
    (b) it reads *every* `.txt` in the directory rather than the ones the manifest
    names, because the folder reference copies whatever is on disk and deciding
    what *should* be there is Core's job — an absent or non-UTF-8 text is
    therefore left out of the dictionary and surfaces as
    `LicenseCatalogError.missingText`, which names the id and the file, instead of
    a bare encoding error with no dependency attached; (c) the one failure Core
    cannot see (the manifest itself never made it into the bundle) is the local
    `LoaderError.missingManifest`.
  - `Platform/LicenseTextView.swift` — the read-only, selectable, scrolling pane
    that renders one verbatim license text, shared by both Acknowledgements
    screens (non-gated for the same reason as the loader: only the concrete text
    view differs — `NSTextView` in an `NSScrollView` on macOS, `UITextView` on
    iOS). **It is TextKit and not `ScrollView { Text(…) }`, and that is the
    point.** These texts are not label-sized: `libgit2.txt` is 66 KB / 1,323
    lines and `tree-sitter.txt` is 22 KB, which at caption-monospaced on a phone
    width wraps to a laid-out height in the tens of thousands of points. A
    SwiftUI `Text` is one view with one intrinsic size, so it lays the whole
    string out synchronously on the main thread when the pane appears — a visible
    hitch on the one screen this feature adds — and content that tall is in the
    range where the tail can be clipped rather than scrolled to. A silently
    truncated license is exactly the failure these screens exist to prevent, and
    the view layer is untested by convention, so nothing would catch it;
    `NSTextView`/`UITextView` generate glyphs lazily for the visible range, which
    makes both problems structurally impossible instead of merely unlikely
    (`allowsNonContiguousLayout` on macOS is what buys the second half). Three
    details are deliberate: the view is selectable but not editable (copying a
    license out is legitimate, and unlike a `LazyVStack` of chunked `Text`s a
    single text view keeps selection continuous across the whole document);
    `updateNSView`/`updateUIView` guard on the string being unchanged, since
    selecting another dependency reuses the view and re-setting the same text
    would drop the reader's selection and scroll position for nothing; and the
    iOS font is scaled through `UIFontMetrics(forTextStyle: .caption1)`, because
    `adjustsFontForContentSizeCategory` only tracks metrics-vended fonts and the
    `.system(.caption, design: .monospaced)` this replaced scaled with Dynamic
    Type. Two optional parameters — `pointSize` and `inset` — carry the interface
    zoom zone in, because a TextKit view sets a font and a `textContainerInset`
    instead of inheriting SwiftUI's: they travel **together**, since a license
    drawn at 200% inside a 12pt margin is the same island as one pinned at 11pt,
    and both default to `nil` ≡ the platform's own resting values (11/12 on
    macOS, `UIFont.smallSystemFontSize`/16 on iOS), so the two screens' resting
    appearance stays a property of the platform rather than of a parameter. Only
    the macOS caller passes either. `updateNSView` sets the inset and the font
    **in place**, before and outside the unchanged-string guard: a zoom step
    changes both without changing the text, and re-assigning the 66 KB string on
    every step would drop the selection and scroll position that guard exists to
    protect.
  - `AcknowledgementsView.swift` — the Preferences "Acknowledgements" tab: an
    `HSplitView` with the dependency list (name + SPDX, `minWidth: 180` /
    `maxWidth: 280`) beside the selected entry's identity (name, SPDX,
    version/revision, origin) and its full license text, at a fixed 640×420. The
    text pane is the shared `LicenseTextView` above (TextKit-backed, monospaced,
    selectable), rendered **whole** — never truncated or reflowed, the copyright
    lines and the permission notice being the obligation itself.
    `version` is omitted when `nil` (three entries have no upstream tag) rather
    than rendered blank; `revision` is always shown in full, the 40 hex characters
    being what makes the text verifiable; `origin` becomes a `Link` exactly when
    Core's `LicenseNotice.originURL` is non-nil (the `https://` remotes; the two
    `Vendor/<name>` paths stay plain text) — the rule lives there, not here, so
    the two platform screens cannot drift apart on it. The loader's
    `documents`/`failureDescription` are read through *computed* properties, not
    stored ones: `SettingsView`'s `TabView` builds both tab views eagerly, so a
    stored property would read the whole `Licenses/` directory off disk on the
    main thread whenever Preferences opens — General tab included — and the
    loader's one-shot cache makes the repeated lookup free. When the
    loader fails, the view shows `failureDescription` in place of the list, so "no
    dependencies" can never be the silent reading. No logic (untested like the
    rest of the view layer); the iOS peer is `AcknowledgementsView_iOS` in
    `app-ios.md`.
    **Two sources, one screen** since phase 2b: below the "Bundled" section, a
    "Language Servers" section lists whatever is *installed* under Application
    Support right now, read through `LSPInstalledLicenses` (entry in
    `core-provisioning.md`) — so it exists only while something is provisioned and
    disappears when it is removed, which is the one thing this screen must not get
    wrong: acknowledging software the app does not have would imply it ships it.
    Both lists are `LicenseDocument`s by the time they arrive, so the detail pane
    needs no idea which one a selection came from. The installed section is
    `@State` re-read on `.task(id: provisioning.rows)` rather than a computed
    property, because — unlike the bundled catalog — it *can* change while the
    window is open; a removal that deletes the selected entry falls back to the
    first bundled one instead of leaving the placeholder.
