#if os(macOS)
import SwiftUI
import PisakaCore

/// Promotes the process to a regular GUI app when launched as a bare SwiftPM
/// executable (`swift run`). Without this it runs as an accessory process: no
/// Dock icon and the menu bar stays owned by the launching terminal.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct PisakaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model: WorkspaceModel
    /// Observable state for the project-wide Find in Files window (⌘⇧F).
    ///
    /// Built in `init()` rather than inline because its two open-buffer closures
    /// need the *same* `WorkspaceModel` instance the rest of the app observes:
    /// Core deliberately keeps no reference to the workspace, so a file with an
    /// open tab is searched — and replaced — through these closures instead of on
    /// disk, which is what lets Replace All keep a dirty tab's unsaved edits.
    @StateObject private var projectSearch: ProjectSearchModel
    /// Observable state for the Find Usages bottom dock panel (⌃⌘U).
    ///
    /// Built in `init()` for `projectSearch`'s reason and one more: it needs the
    /// same open-buffer closure — so a dirty tab is scanned as the user sees it,
    /// not as the disk holds it — *and* the installed intelligence provider, so
    /// the question reaches a language server when one serves the language and
    /// falls to the whole-word scan only when nothing does.
    ///
    /// A plain stored property, deliberately **not** `@StateObject` — the
    /// `commitDialog`/`diagnostics` rule, and this model is the strongest case
    /// for it in the app: a textual scan republishes once per walked chunk, and
    /// `@StateObject` subscribes this scene's `body` to every one of them, which
    /// re-creates `ContentView` with its non-`Equatable` closure parameters and
    /// puts the project tree, the tab list and `CodeEditorView.updateNSView` on
    /// the walk's republish path. `UsagesPanelView` observes it itself, which is
    /// what makes the rows appear; nothing in this scene's `body` reads a
    /// published property of it. `ContentView` states the same rule where it
    /// holds this model non-observed.
    private let usages: FindUsagesModel
    @StateObject private var localChanges = LocalChangesModel(gitService: GitCLIService())
    @StateObject private var commitLog = CommitLogModel(gitService: GitCLIService())
    /// Observable state for the branch-switcher bottom-bar widget. Constructed
    /// alongside `localChanges`/`commitLog`; refreshed on `openFolder` and after a
    /// successful switch/create (the model's `switchTo`/`createBranch` refresh
    /// themselves on success).
    @StateObject private var branchSwitcher = BranchSwitcherModel(gitService: GitCLIService())
    /// State for the commit dialog (⌘K / the Local Changes header button).
    /// Constructed alongside the other git models; loaded synchronously pinned,
    /// then presented as a sheet on the main window.
    ///
    /// A plain stored property, deliberately **not** `@StateObject` — the
    /// `diffWindows`/`sessionController` precedent (the `@main` App is created
    /// once, so a `let` is a stable instance) applied for the reason
    /// `ContentView` documents on its own non-observing `commitDialog`: nothing
    /// in this scene's `body` reads a published property of it, it is only handed
    /// to the sheet, which observes it itself. Holding it as `@StateObject` made
    /// the App's body a subscriber, so every keystroke in the message field —
    /// which writes `@Published message` — invalidated the whole window and
    /// re-created `ContentView` with its non-`Equatable` closure parameters,
    /// putting the project tree, the tab list and `CodeEditorView.updateNSView`
    /// back on the typing path, which is exactly what that comment claims to
    /// avoid.
    private let commitDialog = CommitDialogModel(gitService: GitCLIService())
    /// Owns the embedded terminal's live sessions. Created once for the app's
    /// lifetime; shared with the window content and terminated on app quit.
    @StateObject private var terminalSessions = TerminalSessionsModel()
    /// Owns one database-viewer model — and therefore one SQLite connection — per
    /// open viewer tab. Created in `init()` over the very workspace this app
    /// publishes, because it follows that workspace's `openFiles` in order to
    /// close a tab's connection when the tab goes away; injected into the window's
    /// environment below, where `DatabaseViewerHost` reads it. The per-tab
    /// lifetime lives in `DatabaseViewerTabs.swift` rather than here on purpose —
    /// this file is at its measured lint ceiling.
    @StateObject private var databaseViewers: DatabaseViewerTabs
    /// Persisted user preferences (tab orientation, theme, shared editor font
    /// size). Created once for the app's lifetime; hosted by the `Settings` scene
    /// below (the standard ⌘, Preferences window) and threaded into `ContentView`
    /// so downstream views can read each setting.
    ///
    /// Built in `init()` rather than inline because the provisioning model persists
    /// its per-server consent through this very store (D15), and "asked once" is
    /// only true if the banner, the Settings surface and the model are all reading
    /// the same instance.
    @StateObject private var settings: SettingsStore
    /// The editor find/replace bar's state (⌘F). Owned here rather than by the
    /// editor because the bar is *window*-scoped: its pattern, template and
    /// toggles survive a tab switch, while `CodeEditorView`'s coordinator is
    /// rebuilt with the view. The Find menu below drives this state; the editor's
    /// `EditorSearchController` registers itself as its executor on attach.
    @StateObject private var search = EditorSearchState()

    /// Pending "select this range" request for the editor, produced when a Find in
    /// Files result is activated. Window-scoped for the same reason as `search`:
    /// activating a match may *open* the file, so the request is recorded before
    /// the `CodeEditorView` that will honour it exists.
    @StateObject private var reveal = EditorRevealState()

    /// The project-wide symbol index behind go-to-definition and completion.
    ///
    /// A plain stored property, deliberately **not** `@StateObject` — the
    /// `commitDialog` precedent, and here the argument is even sharper: the model
    /// republishes its `index` after *every chunk* of the walk, so subscribing this
    /// scene's `body` to it would re-create `ContentView` (and with it the project
    /// tree, the tab list and `CodeEditorView.updateNSView`) dozens of times while
    /// a project is being indexed, for a value nothing in the window reads. The
    /// editor surfaces ask their questions through `symbolIndex.provider`, which
    /// reads the latest snapshot on demand. The `@main` App is created once, so a
    /// `let` is a stable instance for the app's lifetime.
    private let symbolIndex: SymbolIndexModel

    /// Schedules the index's incremental work: the debounced buffer re-index while
    /// typing, the immediate one on a tab switch, and the debounced project refresh
    /// the FSEvents callback asks for. A plain stored reference like the window
    /// controllers above.
    private let symbolIndexController: SymbolIndexController

    /// What `.editorconfig` says about the file being edited — the cache behind
    /// Enter's indentation unit and the Tab key. A plain stored reference like
    /// `symbolIndexController`, and for its exact reason: it publishes nothing, so
    /// observing it would put `ContentView` (and with it the project tree, the tab
    /// list and `CodeEditorView.updateNSView`) on an update path for a value this
    /// scene's `body` never shows. Threaded straight through to `CodeEditorView`,
    /// which is the only thing that asks it anything.
    ///
    /// **A reader**, like the symbol index: it opens files and writes none, so it
    /// neither raises `autosave.suspend()` / `localChanges.beginRevert()` nor is
    /// gated by them. The two invalidation calls below are its whole lifecycle.
    private let editorConfig: EditorConfigModel

    /// The one funnel every save on this platform passes through before it
    /// writes: it asks `SaveTransform` what `.editorconfig` says saving each
    /// buffer changes and applies the answer, so the bytes on disk, the open
    /// buffer and the saved baseline agree.
    ///
    /// Owned here rather than by the editor because the saves it serves are menu
    /// commands and autosave ticks, not editor events, and it must survive every
    /// tab switch and window rebuild. It is attached to whichever editor is built
    /// (`CodeEditorView.makeNSView`) and holds it weakly.
    ///
    /// **Called from exactly three places**, all of them a save: `save(id:)`
    /// (⌘S, the close prompt's Save and the run/test pre-run saves, which all
    /// funnel through it), `saveAs(id:)` once the destination is known, and the
    /// closure handed to `AutosaveController`. Opening, closing, switching tabs,
    /// editing an `.editorconfig` and every worktree writer (Replace All, the git
    /// operations) deliberately do not go anywhere near it.
    ///
    /// It writes nothing itself — it rewrites *buffers*, and the caller's own
    /// write follows — so like `editorConfig` it neither raises
    /// `autosave.suspend()` / `localChanges.beginRevert()` nor is gated by them;
    /// its callers are already on whichever side of that gate they belong.
    private let saveTransform = SaveTransformController()

    /// Which language servers are running, for which project, holding which
    /// documents open (phase 2a). A plain stored reference like the window
    /// controllers: the `@main` App is created once, and this owning reference is
    /// what keeps a session's read task alive — `LSPSession` holds `self` weakly, so
    /// a workspace nobody references would stop reading (the retention contract
    /// stated on the session).
    ///
    /// Three lifecycle points hang off it, all beside the ones that already exist:
    /// `prepareForFolderChange` + `shutdownAll()` in `openFolder(url:)`,
    /// `didClose(url:)` in `forgetIndexedBuffer(_:)`, and `terminateNow()` in the
    /// `willTerminateNotification` observer. Nothing else: **it is a reader** (D10),
    /// so it neither raises `autosave.suspend()` / `localChanges.beginRevert()` nor
    /// is gated by them — the rule already written for the symbol index, and for the
    /// same reason.
    private let lspWorkspace: LSPWorkspace

    /// The composed intelligence provider — a language server's answer where there
    /// is one, the symbol index everywhere else — held here as well as installed on
    /// `symbolIndexController`.
    ///
    /// The *same instance* the controller hands out, so nothing about which side
    /// answers differs between the editor's questions and this one. It is held
    /// because the rename command asks one question the seam deliberately does not
    /// carry: `canRename(_:)` is a policy answer about whether a *dialog* should
    /// appear at all (decision 4), which no `CodeIntelligenceProviding` has,
    /// and the router forwards it precisely so the app never reaches past it into
    /// the LSP layer.
    private let intelligence: RoutingIntelligenceProvider

    /// Every language server's published diagnostics, with the sync/revision
    /// bookkeeping that decides which pushes may land (D31/D32): what the
    /// editor's overlays, the gutter and the Problems panel read. A plain
    /// stored reference like every model above — this scene's `body` reads
    /// nothing published on it, so observing it would only put `ContentView`
    /// back on the republish path for value nothing in this scene shows; the
    /// surfaces that show diagnostics observe it themselves.
    private let diagnostics: DiagnosticsModel

    /// Schedules the push channel's sync (D30): every open buffer of a served
    /// language is flushed to its server behind a 400 ms debounce, and
    /// immediately on a tab open/switch, so the server re-diagnoses without
    /// being asked. A plain stored reference like `symbolIndexController`, for
    /// the same reason: it publishes nothing and must outlive individual
    /// editor views.
    ///
    /// **A reader**, exactly like everything else in the LSP layer: it raises
    /// no `autosave.suspend()`/`localChanges.beginRevert()` and is gated by
    /// none — a flush landing mid-revert sends one extra whole-file
    /// notification whose late pushes the acceptance gate drops.
    private let lspDocumentSync: LSPDocumentSyncController

    /// Downloads, verifies and installs the language servers this app can provision
    /// itself (phase 2b). A plain stored reference like `lspWorkspace`, and for the
    /// same reason: the `@main` App is created once, and the engine's in-flight
    /// table is what makes two accepts one download.
    ///
    /// Given the *concrete* seams here and nowhere else — `LSPDownloadService` and
    /// `LSPArchiveUnpacker` are the app's whole contribution to provisioning (D14),
    /// exactly as `LSPProcessTransport` is its whole contribution to running a
    /// server. Everything else — what may be downloaded, what makes it acceptable,
    /// what happens when it is not — is Core's and is unit-tested.
    private let lspInstallEngine: LSPInstallEngine

    /// Which downloadable servers exist, what state each is in, and what the
    /// registry should therefore look like right now — the one thing the consent
    /// banner and the Settings surface both read.
    ///
    /// A plain stored reference rather than a `@StateObject`, the `symbolIndex`
    /// precedent: this scene's `body` reads nothing published on it, and
    /// subscribing the App to a model that republishes its rows on every install
    /// transition would put `ContentView` — and with it the project tree, the tab
    /// list and `CodeEditorView.updateNSView` — back on that path for a value
    /// nothing in this scene shows. The surfaces that *do* show it observe it
    /// themselves.
    private let lspProvisioning: LSPProvisioningModel

    /// Where `go` and `gopls` are on this Mac, and what `go install` means here —
    /// the app's whole contribution to gopls (D18/D20), exactly as
    /// `LSPDownloadService`/`LSPArchiveUnpacker` are its whole contribution to the
    /// downloadable servers.
    ///
    /// Held here rather than only inside the model because it owns the live
    /// children: the terminate observer calls its `terminateNow()` beside
    /// `lspWorkspace`'s, so a quit during a first-launch build leaves no `go`.
    private let lspGoToolchain: LSPGoToolchainService

    /// The second registry contributor (D17): whether Go has a language server,
    /// how it got one, and what the Settings row may do about it. A plain stored
    /// reference for `lspProvisioning`'s reason — nothing in this scene's `body`
    /// reads it, and the two surfaces that show it observe it themselves.
    private let lspGopls: LSPGoplsProvisioningModel

    /// Where `cargo` and any rust-analyzer are on this Mac — the app's whole
    /// contribution to Rust (D23), and a *smaller* contribution than Go's: there
    /// is no install seam, because rust-analyzer publishes prebuilt binaries and
    /// the install is the download/unpack pair `lspInstallEngine` already has.
    ///
    /// Held here rather than only inside the model for `lspGoToolchain`'s reason:
    /// it owns live children — a login shell asked for its `$PATH`, a
    /// `cargo --version` probe — and the terminate observer calls its
    /// `terminateNow()` beside the other two.
    private let lspRustToolchain: LSPRustToolchainService

    /// The third registry contributor (D21): whether Rust has a language server,
    /// whether this Mac can drive one at all, and what the Settings row may do
    /// about it. A plain stored reference for `lspProvisioning`'s reason.
    private let lspRust: LSPRustProvisioningModel

    /// Who is signed in to LeetCode, what opening a problem does, and the
    /// statement for the active tab.
    ///
    /// A plain stored reference rather than a `@StateObject`, the
    /// `commitDialog`/`symbolIndex` precedent: this scene's `body` reads nothing
    /// published on it, and subscribing the App to a model that publishes on
    /// every busy transition and every statement fetch would put `ContentView` —
    /// and with it the project tree, the tab list and
    /// `CodeEditorView.updateNSView` — back on that path. The surfaces that *do*
    /// show its state observe it themselves: `LeetCodeCommands` (the menu),
    /// `LeetCodeOpenProblemSheet`, `LeetCodeLoginView` and the Preferences tab.
    /// The `@main` App is created once, so a `let` is a stable instance.
    ///
    /// Composed with the same shape as the LSP stack: the app supplies the two
    /// concrete seams (`LeetCodeURLSessionTransport`, `LeetCodeKeychainStore`)
    /// and the cache base, and every decision above them is Core's and is
    /// unit-tested without a network or a Keychain.
    private let leetCode: LeetCodeModel

    /// Local History's capture side: the object every write path in this app hands
    /// its bytes to, so a buffer that was on screen five minutes ago is still
    /// recoverable after a save, a revert, a checkout or a Replace All.
    ///
    /// A plain stored reference for the `commitDialog`/`leetCode` reason: it
    /// publishes nothing this scene's `body` reads, so observing it would put
    /// `ContentView` back on an update path for a value nothing here shows. The
    /// `@main` App is created once, so a `let` is a stable instance — and it has to
    /// be, because the model owns the serial write chain that keeps two captures of
    /// one file from each dedup'ing against the state before the other.
    ///
    /// **A reader of the user's files and a writer only of its own store**, like
    /// the symbol index and the `.editorconfig` cache: it never raises
    /// `autosave.suspend()` / `localChanges.beginRevert()` and is never gated by
    /// them. What it takes from the seven gated operations is *timing* alone — each
    /// awaits `captureBeforeOperation` as the first `await` inside its bracket, so
    /// every byte stored is pre-operation by construction.
    ///
    /// Composed the way the LSP and LeetCode stacks are: the app supplies the
    /// concrete `FileService` and the base directory, and every decision above them
    /// (identity, policy, retention, ordering) is Core's and is unit-tested against
    /// a `StubFileTree`.
    private let localHistory: LocalHistoryModel

    /// The Sparkle updater behind the "Check for Updates…" item in the app menu.
    ///
    /// A plain stored reference for the `commitDialog`/`leetCode` reason: the
    /// `@main` App is created once, so a `let` is a stable instance, and this
    /// scene's `body` reads nothing published on it — the one published value
    /// (`canCheckForUpdates`) is observed by `CheckForUpdatesCommand` itself, so
    /// an update session toggling it re-renders one menu item rather than
    /// re-creating `ContentView`.
    ///
    /// Constructing it *is* starting the updater on a release build (see
    /// `SoftwareUpdater`); in DEBUG it holds no Sparkle object at all, so a
    /// development build neither checks nor prompts.
    private let softwareUpdater = SoftwareUpdater()

    /// Where every zoom gesture and every zoom menu item lands: it resolves which
    /// of the three zones the pointer is over and steps that zone's scale in the
    /// one `SettingsStore` this app owns.
    ///
    /// A plain stored reference like the controllers above — the `@main` App is
    /// created once, and this reference is what keeps the event monitor's owner
    /// alive (the monitor holds `self` weakly). Nothing in this scene's `body`
    /// reads anything published on it; the *settings* it writes are what redraws
    /// the views.
    ///
    /// Built in `init()` because it needs the same store every window and sheet
    /// receives: three zones with one arithmetic is only true if there is one
    /// place the numbers live.
    private let zoom: ZoomController

    /// Wire the workspace, the project-search model and the symbol index together.
    ///
    /// `ProjectSearchModel`'s buffer closures are `let`s taken at construction, and
    /// they must close over the very `WorkspaceModel` this app publishes — which a
    /// property initializer cannot reach. Creating the workspace here and wrapping
    /// it in `StateObject` is the whole reason this `init` exists; every other
    /// stored property keeps its inline default. `SymbolIndexModel` joins for the
    /// same reason, over the *same* buffer snapshot closure, so the two features
    /// agree about what an open tab's text is.
    init() {
        // `viewerTabsEnabled: true` is the **one site in the app** that turns the
        // second tab kind on, and `DatabaseViewerSourceGatingTests` pins that it
        // is this one: the routing lives in Core's `open(url:)`, and iOS opens
        // files through that same method with no viewer surface behind it, so an
        // iOS viewer tab would render a database as an empty text file. With the
        // switch off a `.sqlite` takes the ordinary read path and fails honestly.
        let workspace = WorkspaceModel(viewerTabsEnabled: true)
        _model = StateObject(wrappedValue: workspace)
        // Over the same instance, because the owner closes a viewer tab's
        // connection by watching that workspace's tab set rather than by being
        // told from four different close paths.
        _databaseViewers = StateObject(wrappedValue: DatabaseViewerTabs(workspace: workspace))
        // An open tab's text — dirty or not — is what the user sees, so it is what
        // gets searched and indexed; a file with no tab goes down the on-disk
        // branch. Handing over the whole snapshot (rather than answering one URL at
        // a time) is what keeps the project walk off the main thread: each model
        // re-keys these by canonical path *off-main* and matches every candidate
        // with a dictionary hit, instead of making this closure re-resolve every
        // tab's symlinks per file. A url-less "Untitled" buffer names no file, so
        // it is left out. Weak, so neither model resurrects a torn-down workspace.
        let openBuffers: () -> [URL: String] = { [weak workspace] in
            guard let workspace else { return [:] }
            var buffers: [URL: String] = [:]
            buffers.reserveCapacity(workspace.openFiles.count)
            // A viewer tab is skipped: it stands for a database, whose bytes are
            // not text and whose `text` is empty by construction. Contributing an
            // empty buffer for a real path would make the symbol index and Find in
            // Files answer for that file out of the buffer branch — reporting the
            // database as an empty file, and outranking the on-disk branch that
            // would at least have declined it as binary.
            for file in workspace.openFiles where file.kind == .text {
                if let url = file.url { buffers[url] = file.text }
            }
            return buffers
        }
        // The extractor is handed over as a **direct synchronous function
        // reference** — no `Task`, no actor hop. `SymbolIndexModel` calls it only
        // from inside its own off-main serial queue, which is the whole point of
        // that seam being synchronous (see the model's note on it).
        let symbolIndex = SymbolIndexModel(
            fileService: FileService(),
            openBuffers: openBuffers,
            extractSymbols: SymbolExtractor.symbols(in:language:fileURL:)
        )
        self.symbolIndex = symbolIndex
        let symbolIndexController = SymbolIndexController(model: symbolIndex)
        self.symbolIndexController = symbolIndexController

        // Over the same stateless `FileService` every other disk reader here uses.
        // No root yet: the launch-time session restore and every user-driven open
        // both go through `openFolder(url:)`, which is where the root is recorded.
        self.editorConfig = EditorConfigModel(fileService: FileService())

        // The LSP layer, composed once and then left alone. `LSPProcessTransport`
        // is the *only* thing handed over from the app side: the workspace decides
        // whether to launch a server, this decides what launching one means here —
        // the `GitServicing`/`GitCLIService` split, one level down.
        let lspWorkspace = LSPWorkspace(
            transportFactory: LSPProcessTransport.make(for:root:)
        )
        self.lspWorkspace = lspWorkspace
        // What the editor surfaces actually ask: a language server first, and this
        // very index — the same instance, reading the same live snapshot — whenever
        // that does not answer in time. The fallback is `symbolIndex.provider`
        // itself rather than a second provider over the same index, so a request no
        // server serves takes exactly the path it took before this phase existed
        // (`RoutingIntelligenceProviderTests` pins that by equality).
        //
        // Installed on the controller rather than plumbed through the views: they
        // read `symbolIndex.provider` already, so composition here changes no view
        // signature and no view can tell which side answered.
        let intelligence = RoutingIntelligenceProvider(
            lsp: LSPIntelligenceProvider(workspace: lspWorkspace),
            fallback: symbolIndex.provider
        )
        self.intelligence = intelligence
        symbolIndexController.installProvider(intelligence)
        // The diagnostics channel (D29–D32), composed beside the routing above:
        // the workspace's push sink feeds the model — clears included, so every
        // teardown path blanks the three surfaces synchronously — and the sync
        // controller is what makes pushes come at all. Captured directly rather
        // than through `self` for the registry closures' reason below: this runs
        // during `init`, and the sink must outlive it holding the model.
        let diagnostics = DiagnosticsModel()
        self.diagnostics = diagnostics
        lspWorkspace.onDiagnostics = { [diagnostics] event in
            diagnostics.receive(event)
        }
        let lspDocumentSync = LSPDocumentSyncController(
            model: diagnostics,
            workspace: lspWorkspace
        )
        self.lspDocumentSync = lspDocumentSync
        // Resolve `sourcekit-lsp` off the main thread now, so the first ⌘-click in a
        // cold project does not pay for an `xcrun` inside the launch turn. Purely an
        // optimisation — the lookup is cached either way (see `LSPToolchain`).
        LSPToolchain.prewarm()

        // Provisioning (phase 2b), composed exactly once. The two concrete seams
        // appear here and nowhere else: everything above them — the pinned
        // manifest, the digest, the staging/rename sequence, the consent rules — is
        // Core's and is unit-tested without a network or a `tar`.
        let settings = SettingsStore()
        _settings = StateObject(wrappedValue: settings)
        // The zoom controller over that very store. Constructing it installs
        // nothing — the event monitor goes up in `.onAppear` and comes down in the
        // termination observer, beside the other app-lifecycle wiring.
        self.zoom = ZoomController(settings: settings)
        let (installEngine, provisioning) = PisakaApp.makeProvisioning(settings: settings)
        self.lspInstallEngine = installEngine

        // gopls (D17), composed beside the pair above and over the *same* install
        // engine: it is not downloaded, but it lives under the same install root,
        // is removed by the same `engine.remove`, and records its consent in the
        // same `SettingsStore` dictionary. What it does not share is anything about
        // bytes — no manifest entry, no pinned digest, nothing to unpack.
        let (goToolchain, gopls) = PisakaApp.makeGopls(engine: installEngine, settings: settings)
        self.lspGoToolchain = goToolchain
        self.lspGopls = gopls

        // rust-analyzer (D21), composed beside the other two and over the *same*
        // install engine — one install root, one `sweepStaging()`. Rust is the
        // hybrid of the two arrangements above: it is downloaded from a pinned
        // manifest component like the 2b servers, and gated on a toolchain and
        // preferred behind a discovered copy like gopls. Sharing the engine is
        // what makes the first half free; the second half is entirely the Core
        // model's, which is why the app adds one discovery seam and nothing else.
        let (rustToolchain, rust) = PisakaApp.makeRust(engine: installEngine, settings: settings)
        self.lspRustToolchain = rustToolchain
        self.lspRust = rust

        // The LeetCode stack, composed once. The folder comes out of the store
        // *here* rather than being read at each open, so the model is already
        // pointed at it before the first `openProblem` captures it; the chooser
        // writes both halves whenever the user changes it.
        //
        // Building one talks to nothing: `URLSession` opens no connection until a
        // request is made, and the Keychain is read exactly once, in
        // `LeetCodeModel.init`, to decide whether to show "signed in" before the
        // launch-time confirmation lands.
        self.leetCode = PisakaApp.makeLeetCode(settings: settings)

        // Local History, composed once. Building one touches no disk at all: the
        // layout is pure path math and the store `ensureDirectory`s only in front
        // of its first write, so a run in which nothing is ever saved creates
        // nothing under Application Support.
        self.localHistory = LocalHistoryModel(base: LocalHistorySupportDirectory.storeBase, fileService: FileService())
        // The window's reader, over the *same* store value the capture side
        // writes through — not a second one built from the same base. Building it
        // touches no disk either: it lists a file's revisions when a window is
        // first pointed at one, and never before.
        self.localHistoryBrowser = LocalHistoryBrowserModel(store: self.localHistory.store)

        // The whole of D16's wiring, now with **three** registry contributors:
        // whenever any set of installed servers changes, the workspace is handed one
        // merged registry and shuts down whatever the change un-registered. Awaited
        // by all three models on purpose — a removal publishes the registry *before*
        // deleting the files, so the process is gone before its executable is (see
        // `LSPProvisioningModel.onRegistryChange` and its two counterparts).
        //
        // Each callback takes its own contributor's new value as a parameter and
        // reads the other two's published ones, which is what makes the merge see the
        // change that is being pushed rather than the state before it. Base entries
        // first (`provisioning.registry` already opens with them), so a
        // hand-registered override still wins — `LSPServerRegistry`'s
        // first-registration-wins rule. The three contributors serve disjoint
        // languages, so the order among *them* decides nothing today; it is stated
        // rather than left to the reader because the rule that would decide it if
        // they ever overlapped is the registry's, not this site's.
        //
        // `lspWorkspace` and the models are captured directly rather than through
        // `self`: this runs during `init`, and the closures must outlive it holding
        // those objects, not a half-built `PisakaApp` value.
        //
        // Each callback ends by re-syncing the open buffers (D30). Diagnostics
        // are the one push-only channel here: every other LSP surface is
        // request-driven and recovers on the next completion/hover/⌘-click,
        // while the sync controller's whole trigger surface is tab open/switch
        // and a settled keystroke — all of which gate on `canServe`, which was
        // *false* for the language a moment ago. Without this, consenting to a
        // server (or gopls/rust-analyzer discovery finishing after launch, which
        // is the ordinary cold-start order) leaves the file on screen with no
        // squiggles, no gutter markers and no Problems rows until the user types
        // a character — precisely the "diagnosed before they finish reading it"
        // moment the channel exists for.
        let resyncDiagnostics: @MainActor () -> Void = { [weak workspace, lspDocumentSync] in
            guard let workspace else { return }
            PisakaApp.syncOpenBuffersForDiagnostics(of: workspace, through: lspDocumentSync)
        }
        provisioning.onRegistryChange = { @MainActor [lspWorkspace, gopls, rust] registry in
            await lspWorkspace.updateRegistry(
                LSPServerRegistry(registry.descriptions + gopls.descriptions + rust.descriptions)
            )
            resyncDiagnostics()
        }
        gopls.onDescriptionsChange = { @MainActor [lspWorkspace, provisioning, rust] descriptions in
            await lspWorkspace.updateRegistry(
                LSPServerRegistry(
                    provisioning.registry.descriptions + descriptions + rust.descriptions
                )
            )
            resyncDiagnostics()
        }
        rust.onDescriptionsChange = { @MainActor [lspWorkspace, provisioning, gopls] descriptions in
            await lspWorkspace.updateRegistry(
                LSPServerRegistry(
                    provisioning.registry.descriptions + gopls.descriptions + descriptions
                )
            )
            resyncDiagnostics()
        }
        self.lspProvisioning = provisioning

        // Find the Go toolchain now, off the main thread — `LSPToolchain.prewarm()`'s
        // position and its reasoning, one step further: the row that reports this is
        // `pending` until it answers, and the silent half of D15 (a gopls the user
        // already accepted, built when a `.go` file is opened) can only run once the
        // answer is in. Unawaited, so a machine with no `go` spends its login-shell
        // search entirely off the launch path.
        Task { await gopls.discover() }
        // And the Rust one, for the same reasons and with one more: this search
        // ends at a login shell on a Mac with no Rust at all, which is most of
        // them, so it must never be on the path that draws the first window. The
        // model coalesces onto this one task, so the banner's `.task` — which
        // awaits discovery before it can install a rust-analyzer the user already
        // accepted — joins it rather than starting a second search.
        Task { await rust.discover() }

        _projectSearch = StateObject(
            wrappedValue: ProjectSearchModel(
                fileService: FileService(),
                openBuffers: openBuffers,
                // …and what gets replaced: the edit lands in the buffer, leaving
                // the tab dirty and the save the user's call, rather than being
                // written to disk behind the editor's back.
                // `replaceText`, not `updateText`: this is an *external* buffer
                // replacement, and it lands in every matching open tab — including
                // ones that are not on screen. The token it bumps is what lets the
                // editor drop that file's stale undo stack when the tab is next
                // displayed (see `WorkspaceModel.textReplacementRevisions`).
                applyBufferText: { [weak workspace] url, text in
                    guard let workspace, let id = workspace.fileID(forURL: url) else { return false }
                    return workspace.replaceText(text, for: id)
                }
            )
        )

        // The usages panel's model, over the same two seams. The provider is read
        // through a closure rather than captured as a value for the reason the
        // model states: the routing provider is *installed* on the controller
        // during this very `init`, and a later phase may install another, so a
        // model holding today's answer would keep asking it forever.
        usages = FindUsagesModel(
            fileService: FileService(),
            provider: { [weak symbolIndexController] in symbolIndexController?.provider },
            openBuffers: openBuffers,
            // The textual walk gets the live buffers above; the *semantic* half
            // gets what the servers were actually told, which is a different map
            // (`FindUsagesModel.serverTexts`, and `renameSymbol`'s reason one file
            // over): the document-sync debounce means a tab typed in a moment ago
            // is a buffer no server has seen, and mapping its answers onto that
            // buffer is how a row ends up with a plausible line number and the
            // wrong offsets. `lspWorkspace` is `@MainActor`, as is the model that
            // calls this, so the snapshot is taken in the asking turn.
            serverTexts: { [weak lspWorkspace] in lspWorkspace?.lastSentTexts() ?? [:] }
        )
    }

    /// The provisioning pair — the engine and the model over it — composed the
    /// one way this app composes them.
    ///
    /// A factory rather than two inline expressions in `init` because the
    /// default-constructed `ContentView` (previews/tests, the `GitCLIService()`
    /// defaults' reason) needs the same stack and must not spell the install root
    /// a second time: two spellings of one directory is how a preview ends up
    /// reading somewhere the real app never writes. The `settings` default is for
    /// that caller alone; `init` passes the store the whole app shares, because
    /// consent is persisted through it.
    ///
    /// Building one opens no connection — `URLSession` does nothing until a
    /// request is made — but it is not free: `LSPProvisioningModel.init` derives
    /// its rows, which lists the install root's component directories. That is one
    /// pass over a directory that normally does not exist, and it is why the
    /// default argument exists at all rather than a lazily-built stack.
    static func makeProvisioning(
        settings: SettingsStore = SettingsStore()
    ) -> (engine: LSPInstallEngine, model: LSPProvisioningModel) {
        let engine = LSPInstallEngine(
            layout: LSPInstallLayout(base: PisakaApp.languageServerInstallRoot),
            fileService: FileService(),
            downloader: LSPDownloadService(),
            unpacker: LSPArchiveUnpacker(),
            architecture: PisakaApp.hostArchitecture
        )
        return (engine, LSPProvisioningModel(engine: engine, settings: settings))
    }

    /// The gopls pair — the machine-knowledge seams and the model over them —
    /// composed the one way this app composes them.
    ///
    /// A factory for `makeProvisioning`'s reason, and it takes the *same* engine
    /// the downloadable servers use rather than building a second one: the install
    /// root is one directory, `sweepStaging()` sweeps all of it, and two layouts
    /// over one path is how a Remove ends up looking somewhere nothing was ever
    /// written. The defaults exist for the default-constructed `ContentView`
    /// (previews/tests) alone.
    ///
    /// Building one searches for nothing: `LSPGoToolchainService` resolves lazily
    /// on first `discover()`, and the model derives its row from a `pending`
    /// report until that answers.
    static func makeGopls(
        engine: LSPInstallEngine = PisakaApp.makeProvisioning().engine,
        settings: SettingsStore = SettingsStore()
    ) -> (service: LSPGoToolchainService, model: LSPGoplsProvisioningModel) {
        let service = LSPGoToolchainService()
        return (
            service,
            LSPGoplsProvisioningModel(
                discovery: service,
                installer: service,
                engine: engine,
                fileService: FileService(),
                settings: settings
            )
        )
    }

    /// The Rust pair — the one machine-knowledge seam and the model over it —
    /// composed the one way this app composes them.
    ///
    /// A factory for `makeProvisioning`'s reason, over the *same* engine for
    /// `makeGopls`'s: the install root is one directory and `sweepStaging()`
    /// sweeps all of it. Rust hands the engine *more* than gopls does — its
    /// server is a pinned manifest component, so the download, the digest check,
    /// the unpack and the removal are all the engine's — which is why there is one
    /// seam here and not two.
    ///
    /// Building one searches for nothing: `LSPRustToolchainService` resolves
    /// lazily on first `discover()`, and the model derives its row from a
    /// `pending` report until that answers.
    static func makeRust(
        engine: LSPInstallEngine = PisakaApp.makeProvisioning().engine,
        settings: SettingsStore = SettingsStore()
    ) -> (service: LSPRustToolchainService, model: LSPRustProvisioningModel) {
        let service = LSPRustToolchainService()
        return (
            service,
            LSPRustProvisioningModel(discovery: service, engine: engine, settings: settings)
        )
    }

    /// The LeetCode stack: the two concrete seams, the cache base, and the
    /// folder the store remembers.
    ///
    /// A factory for `makeProvisioning`'s reason — `ContentView` needs a default
    /// value for the model it hands to the description pane, so the composition
    /// cannot live only inside `init`. The folder is read from the store *here*
    /// rather than at each open, so the model is already pointed at it before the
    /// first `openProblem` captures it; `LeetCodeFolderChooser` writes both halves
    /// whenever the user changes it.
    ///
    /// Building one talks to nothing: `URLSession` opens no connection until a
    /// request is made, and the Keychain is read exactly once, in
    /// `LeetCodeModel.init`, to decide whether to show "signed in" before the
    /// launch-time confirmation lands.
    static func makeLeetCode(settings: SettingsStore = SettingsStore()) -> LeetCodeModel {
        LeetCodeModel(
            transport: LeetCodeURLSessionTransport(),
            credentialStore: LeetCodeKeychainStore(),
            fileService: FileService(),
            cacheLayout: LeetCodeSupportDirectory.cacheLayout,
            solutionsFolder: settings.leetCodeFolderURL
        )
    }

    /// Where provisioned language servers live: `~/Library/Application
    /// Support/Pisaka/LanguageServers` (D12).
    ///
    /// Application Support rather than Caches, because these are not
    /// reconstructible on demand: a purged cache would silently un-provision every
    /// language the user accepted, and the next `.ts` file would download 56 MB
    /// again without asking. Under the app's own directory, so
    /// `LSPInstallLayout.directoryName` is the only path component this layer adds
    /// and deleting that one directory de-provisions completely — which is what
    /// `README.md` tells people to do.
    ///
    /// The fallback spelling is unreachable in practice (a Mac always has an
    /// Application Support directory) and exists so this is a `URL` rather than an
    /// optional threaded through the engine, the layout and the model.
    private static var languageServerInstallRoot: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("Pisaka", isDirectory: true)
            .appendingPathComponent(LSPInstallLayout.directoryName, isDirectory: true)
    }

    /// The slice this app is *running as*, not what the machine is.
    ///
    /// A Rosetta-translated build reports `x64` and provisions the x64 Node, which
    /// is the right answer: the server process it spawns inherits the translation,
    /// so an arm64 Node under a translated parent is the arrangement that would not
    /// work. Stated as a known limit rather than worked around — see
    /// `LSPHostArchitecture`.
    private static var hostArchitecture: LSPHostArchitecture {
        #if arch(arm64)
        return .arm64
        #else
        return .x64
        #endif
    }

    /// Which bottom dock panel is shown (`nil` = none), VS Code-style. Owned here
    /// so the always-visible bottom bar (in `ContentView`) and the View-menu
    /// commands share one source of truth; toggled via `togglePanel(_:)`.
    @State private var bottomPanel: BottomPanel?

    /// Whether the commit dialog sheet is up. Raised by `openCommitDialog()` after
    /// the load has been kicked off, lowered by a successful commit, Cancel or Esc.
    @State private var isCommitDialogPresented = false

    /// Which of the two LeetCode sheets is up, or `nil` for neither.
    ///
    /// One `.sheet(item:)` over an enum rather than two `.sheet(isPresented:)`
    /// modifiers on the same view: the two are mutually exclusive by nature (the
    /// sign-in sheet exists because an open needs a session), and one binding
    /// makes that structural instead of a rule two `@State` flags would have to
    /// keep between them.
    @State private var leetCodeSheet: LeetCodeSheet?

    /// The LeetCode sheets this window can raise.
    private enum LeetCodeSheet: Int, Identifiable {
        case signIn
        case openProblem

        var id: Int { rawValue }
    }

    /// Owns the separate, non-modal diff windows opened on double-click (a Local
    /// Changes row, or a commit's file in Git Log). A plain stored reference — the
    /// `@main` App is created once, so this single instance lives for the app's
    /// lifetime; `closeAll()` is invoked on `willTerminateNotification` so no diff
    /// windows linger past termination.
    private let diffWindows = DiffWindowController()

    /// Owns the separate, non-modal 3-pane merge windows opened to resolve a
    /// conflicted file. A plain stored reference — the `@main` App is created once,
    /// so this single instance lives for the app's lifetime; `closeAll()` is
    /// invoked on `willTerminateNotification` so no merge windows linger past
    /// termination (mirroring `diffWindows`).
    private let mergeWindows = MergeWindowController()

    /// Owns the single, non-modal Find in Files window (⌘⇧F). A plain stored
    /// reference like `diffWindows`/`mergeWindows`, and `closeAll()` is invoked
    /// from the same `willTerminateNotification` observer.
    private let projectSearchWindows = ProjectSearchWindowController()

    /// Owns the single, non-modal LeetCode problem browser window (⌘⇧B). A plain
    /// stored reference like `projectSearchWindows`, and `closeAll()` is invoked
    /// from the same `willTerminateNotification` observer.
    private let leetCodeBrowserWindows = LeetCodeBrowserWindowController()

    /// Owns the single, non-modal Local History window (⌘⇧H). A plain stored
    /// reference like `projectSearchWindows`/`leetCodeBrowserWindows`, and
    /// `closeAll()` is invoked from the same `willTerminateNotification` observer.
    private let localHistoryWindows = LocalHistoryWindowController()

    /// The Local History window's own state: which file it is showing, that
    /// file's revisions, the selection and the diff.
    ///
    /// A **companion** to `localHistory` rather than part of it, the way
    /// `LeetCodeBrowserModel` is a companion to `LeetCodeModel`: it is handed the
    /// very same `LocalHistoryStore` value — one store, one layout, one policy,
    /// however many readers — and it captures nothing, prunes nothing and writes
    /// nothing. Held here for the app's lifetime because the window is a single
    /// retargeted one, so its rows and selection have to outlive a close.
    ///
    /// A plain stored `let` for the `localHistory`/`commitDialog` reason: it
    /// publishes plenty, but nothing this scene's `body` reads — the only view
    /// that observes it is `LocalHistoryView`, inside its own window.
    private let localHistoryBrowser: LocalHistoryBrowserModel

    /// Owns the separate, non-modal read-only source viewer windows a Go to
    /// Definition opens when the declaration lives *outside* the opened folder — an
    /// SDK interface, a dependency checkout (D3). A plain stored reference and a
    /// `closeAll()` from the same `willTerminateNotification` observer, mirroring
    /// `diffWindows`/`mergeWindows`.
    ///
    /// Only the LSP provider ever produces such a candidate, so on a project with
    /// no language server this stays empty for the app's whole life.
    private let sourceViewers = SourceViewerWindowController()

    /// Watches the opened project folder with FSEvents so an *external* change (a
    /// generator run in the embedded terminal, a Finder rename, a console `git
    /// checkout`) shows up in the project tree on its own. A plain stored reference
    /// — the `@main` App is created once, so this single instance lives for the
    /// app's lifetime; `start(root:onChange:)` is called from `openFolder(url:)` —
    /// the form that holds every folder-change side effect, so the launch-time
    /// session restore starts the watcher exactly as a user-driven open does (it is
    /// idempotent, so a folder switch simply switches the subscription) and `stop()`
    /// on `willTerminateNotification`, mirroring `diffWindows`/`mergeWindows`.
    ///
    /// Nothing about the watcher-driven bump is gated: `bumpTreeRevision()` is
    /// idempotent and the re-read it triggers is read-only, so an extra bump costs a
    /// `contentsOfDirectory` per expanded node and nothing else. In particular the
    /// harmless `.DS_Store`-driven bump (dir-level events report the containing
    /// directory, so `TreeRefreshFilter`'s `.DS_Store` rule never sees it) and the
    /// worktree events of an in-flight revert (a `git` *subprocess*, so
    /// `kFSEventStreamCreateFlagIgnoreSelf` does not suppress them) are inert — a
    /// re-read observes whatever is on disk at that moment and never writes. The
    /// `.git` noise of those same git operations is dropped by the Core filter. So
    /// no `isReverting`-style gate belongs here; the gates exist for *disk writers*,
    /// which this is not.
    private let projectWatcher = ProjectWatcher()

    /// JetBrains-style autosave wiring (idle / focus-loss / tab-switch / quit).
    /// A plain stored reference — the `@main` App is created once, so this single
    /// instance lives for the app's lifetime; it is started from the window
    /// content's `.onAppear` below.
    private let autosave = AutosaveController()

    /// Where the last session (the opened folder, the tabs, the selection, the text
    /// of Untitled buffers) is read from on launch and written back to. A plain
    /// stored reference like the controllers above — the `@main` App is created
    /// once, so this single instance lives for the app's lifetime.
    private let sessionStore = SessionStore()

    /// Writes the session continuously (debounced) so a launch can bring the last
    /// one back even after a crash or a force-quit. Started from the window
    /// content's `.onAppear` below, *after* the restored session has been applied,
    /// so a half-built state cannot overwrite what was saved.
    private let sessionController = SessionController()

    /// Whether the launch-time session restore has already run. `.onAppear` can
    /// fire again (a reopened window, a second `WindowGroup` scene) and restore is
    /// **not** idempotent — a second run would re-select a tab the user has since
    /// moved off, so it is gated here rather than inside the model.
    @State private var didRestoreSession = false

    /// Disk access for the project-tree file operations (create / rename /
    /// delete). A separate, stateless `FileService` instance — the same concrete
    /// type the model uses by default — so the orchestration here goes through the
    /// same `FileServicing` surface the Core logic is tested against.
    private let fileService = FileService()

    var body: some Scene {
        WindowGroup {
            ContentView(
                model: model,
                localChanges: localChanges,
                commitLog: commitLog,
                branchSwitcher: branchSwitcher,
                commitDialog: commitDialog,
                terminalSessions: terminalSessions,
                settings: settings,
                search: search,
                reveal: reveal,
                symbolIndex: symbolIndexController,
                editorConfig: editorConfig,
                saveTransform: saveTransform,
                lspSync: lspDocumentSync,
                diagnostics: diagnostics,
                provisioning: lspProvisioning,
                gopls: lspGopls,
                rust: lspRust,
                leetCode: leetCode,
                onGoToDefinition: { url, range in activateSearchMatch(url: url, range: range) },
                onViewDefinitionOutsideProject: { url, range in
                    viewDefinitionOutsideProject(url: url, range: range)
                },
                bottomPanel: $bottomPanel,
                onTogglePanel: { togglePanel($0) },
                onActivateProblem: { url, range in activateSearchMatch(url: url, range: range) },
                usages: usages,
                onActivateUsage: { activateUsage($0) },
                onFindUsages: { findUsages($0) },
                onRenameSymbol: { renameSymbol($0) },
                onClose: { closeFile(id: $0) },
                onOpenFile: { openFile(url: $0) },
                onOpenFolder: { openFolder() },
                recentProjects: { recentProjectRows() },
                onOpenRecentProject: { openFolder(url: $0) },
                onRevert: { revertChanges(contextFile: $0) },
                onOpenDiff: { openLocalChangesDiff($0) },
                onOpenCommitDiff: { openCommitDiff($0, in: $1) },
                onResolveConflict: { resolveConflict($0) },
                onSwitchBranch: { switchBranch($0) },
                onCreateBranchFromRemote: { createBranchFromRemote($0) },
                onCheckoutRemote: { checkoutRemote($0) },
                onNewBranch: { newBranch() },
                mayBeginFileOperation: { !revertInFlight() },
                onNewFile: { dir, name in newFile(in: dir, name: name) },
                onNewFolder: { dir, name in newFolder(in: dir, name: name) },
                onRename: { url, name in renameItem(at: url, newName: name) },
                onMove: { moveItem(at: $0, into: $1) },
                onDelete: { deleteItem(at: $0) },
                onRun: { runFile(url: $0) },
                onRunTest: { testFile(url: $0) },
                onShowLocalHistory: { showLocalHistory(for: $0) },
                isCommitDialogPresented: $isCommitDialogPresented,
                onOpenCommitDialog: { openCommitDialog() },
                onCommitFile: { file in openCommitDialog(preselectingPath: file.path) },
                onCommit: { origin in await commitFromDialog(originGeneration: origin) },
                onCommitDialogDismissed: { autosave.resumeFromModal() }
            )
            // The one thing the window's environment carries for the database
            // viewer: the per-tab model owner, read by `DatabaseViewerHost` inside
            // `ContentView.editorZone`. Injected here rather than passed as a
            // parameter so `ContentView` gains no property for a surface it only
            // routes to.
            .environmentObject(databaseViewers)
            // The explicit frame autosave name for the main window.
            // This is the only place the main window's frame identity is established
            // (the auxiliary windows deliberately have none). The attachment must
            // not be moved inside `ContentView`: the marker must sit in the scene's
            // own content so exactly one window ever adopts the name.
            .background(MainWindowFrameAutosave())
            // The LeetCode sheets, attached *outside* `ContentView` rather than
            // inside it: the window content already presents the commit dialog
            // from its own body, and these are raised by menu commands this
            // scene owns. Keeping them here means `ContentView` gains no
            // parameter for them and no reason to observe `leetCode` — which is
            // the whole point of the model being a non-observed `let` above.
            .sheet(item: $leetCodeSheet) { sheet in
                // The interface scale, injected on the sheet's *content*.
                //
                // It cannot be inherited here, and that is the whole reason this
                // is not a mistake to "clean up": `ContentView` applies
                // `.interfaceScaled(settings)` inside its own body, so the write
                // lives below this modifier rather than above it — an environment
                // value a child's body publishes cannot reach a presentation the
                // parent attached around that child. The commit dialog looks like
                // a counter-example and is not: `ContentView` presents it from
                // the same body, *before* the injection, so the injection is its
                // ancestor. These two sheets are attached out here (see below),
                // so they had rendered at 100% over a window at 200%.
                Group {
                    switch sheet {
                    case .signIn:
                        LeetCodeLoginView(
                            model: leetCode,
                            onDismiss: { leetCodeSheet = nil },
                            // The sheet is already gone when the confirmation lands
                            // and this window renders `lastError` nowhere, so an
                            // alert is the only thing between a rejected session and
                            // a Sign In that appears to do nothing at all.
                            onFailure: {
                                PlatformAlert.presentMessage(
                                    title: "Could Not Sign In to LeetCode",
                                    message: $0.errorDescription ?? "LeetCode rejected the session."
                                )
                            }
                        )
                    case .openProblem:
                        // No sign-in hook: the open sheet presents the login web view
                        // over *itself*, so the problem the user typed is still there
                        // when they come back. Swapping this slot from `.openProblem`
                        // to `.signIn` instead took the open sheet down and never
                        // brought it back.
                        LeetCodeOpenProblemSheet(
                            model: leetCode,
                            settings: settings,
                            onOpen: { input, language in
                                await openLeetCodeProblem(input: input, language: language)
                            },
                            onCancel: { leetCodeSheet = nil }
                        )
                    }
                }
                .interfaceScaled(settings)
            }
            .onAppear {
                // Start once. `onSaved` reuses `refreshLocalChanges()` so an
                // autosave re-runs `git status` through the same generation-pinning
                // as a manual save, rather than duplicating that logic. Its
                // `createdFile` flag additionally bumps the tree when an autosave
                // *recreated* a file that had been deleted out of band — the watcher
                // ignores our own writes, so nothing else would put it back in the
                // listing (the same reason `saveAs` bumps explicitly).
                // `prepareForSave` is the on-save transform, handed over as a
                // closure so the controller keeps holding no policy: it decides
                // *when* a save happens and which buffers it writes, and this
                // decides what `.editorconfig` makes of them.
                // `onBufferReplaced` is the off-screen half: a background tab the
                // transform rewrote through the model fired no change
                // notification, so it is resynced through the same funnel every
                // other off-screen rewrite uses.
                //
                // `isTerminating` splits the callback in two. Everything that
                // exists to keep *this session's UI* honest — the Local Changes
                // re-query, the tree bump, the `.editorconfig` cache drop — runs
                // only when the session continues; on the way out there is no panel,
                // no tree and no next question. The Local History capture runs on
                // both, because the last save before a quit is precisely the edit a
                // safety net is for — synchronously there, since the process exits
                // when this observer returns and a `Task` hop is not guaranteed to
                // run at all.
                saveTransform.start(model: model, editorConfig: editorConfig, onBufferReplaced: { id, url in
                    reindexReloadedBuffer(id: id, url: url)
                })
                autosave.start(
                    model: model,
                    prepareForSave: saveTransform.prepareForAutosave(ids:abandoningBuffers:),
                    onSaved: { saved, createdFile, isTerminating in
                        let texts = savedBufferTexts(for: saved)
                        let root = model.projectRoot
                        guard !isTerminating else {
                            localHistory.captureSavesSynchronously(urls: saved, root: root, texts: texts)
                            return
                        }
                        localHistory.captureSaves(urls: saved, root: root, texts: texts)
                        refreshLocalChanges()
                        if createdFile { model.bumpTreeRevision() }
                        // An autosaved `.editorconfig` is a self-write the watcher
                        // never reports, so this is the only thing that can drop
                        // the cache for it.
                        noteEditorConfigWrites(saved)
                    }
                )

                // Start watching for zoom gestures. Idempotent by contract, for
                // the same reason `terminateAll()` below is: `.onAppear` can fire
                // again for a reopened window, and a second monitor would apply
                // every step twice.
                zoom.install()

                // Bring the last session back, once, before the first interaction —
                // and start the writer only afterwards, so the intermediate states
                // this produces are never persisted over what was saved.
                if !didRestoreSession {
                    didRestoreSession = true
                    restoreLastSession()

                    // Provisioning's launch pair, under the same one-shot gate.
                    //
                    // `sweepStaging()` first and synchronously: what it deletes is
                    // whatever a crash, a force-quit or a power loss left half
                    // written under `.staging`, and it is only safe *because* it
                    // runs before anything can be installed (D13). Nothing else in
                    // the app ever removes those trees, so skipping it would leave
                    // a failed 53 MB download on disk for the life of the
                    // installation.
                    //
                    // `refresh()` then re-derives everything from the disk and
                    // publishes the resulting registry, which is what makes a
                    // relaunch pick up what a previous run installed: the file
                    // system is the state (D12), so there is nothing persisted to
                    // restore and no ordering against the session restore to get
                    // right. Asynchronous and unawaited — a language whose server
                    // has not been registered yet answers from tree-sitter for the
                    // moment it takes, exactly as it does when no server exists.
                    lspInstallEngine.sweepStaging()
                    Task { await lspProvisioning.refresh() }

                    // Ask LeetCode who the stored session belongs to, once.
                    // Non-throwing and silent by contract: the menu already says
                    // "signed in" optimistically from the Keychain item, and an
                    // unreachable LeetCode at launch is not a sign-out. All this
                    // fills in is the account name — and, when the session has
                    // actually expired, the correction.
                    Task { await leetCode.refreshUserStatus() }
                }

                // Terminate every shell on app quit so no PTY-backed processes
                // leak. `willTerminateNotification` arrives on the main thread as
                // the run loop ends; `terminateAll()` is idempotent, so a re-fired
                // `.onAppear` registering a second observer is harmless.
                //
                // `queue: nil` — the block then runs **synchronously on the posting
                // thread**, which is the only *documented* delivery guarantee
                // `NotificationCenter` gives. Everything below has to complete
                // before the process exits: this notification is the last thing
                // AppKit posts before it tears the app down, so there is no further
                // run-loop turn in which a block merely *enqueued* onto a queue
                // would be picked up. (In practice a `queue: .main` observer is
                // also delivered synchronously here, because the notification is
                // posted on the main thread and `NotificationCenter` short-circuits
                // when the target queue is the current one — but that is an
                // implementation detail, and the quit-time `flushNow()` pair at the
                // bottom is exactly the kind of one-shot, data-losing-if-skipped
                // work that must not rest on one. `AutosaveController` registers its
                // own termination observer the same way, for the same reason.)
                NotificationCenter.default.addObserver(
                    forName: NSApplication.willTerminateNotification,
                    object: nil,
                    queue: nil
                ) { _ in
                    terminalSessions.terminateAll()
                    // Close any open separate diff windows so none linger past
                    // termination, mirroring the terminal-session teardown. AppKit
                    // posts this notification on the main thread and `queue: nil`
                    // runs the block right there, so the `@MainActor` `closeAll()`
                    // runs on the right actor.
                    MainActor.assumeIsolated {
                        diffWindows.closeAll()
                        mergeWindows.closeAll()
                        projectSearchWindows.closeAll()
                        leetCodeBrowserWindows.closeAll()
                        localHistoryWindows.closeAll()
                        sourceViewers.closeAll()
                        // And every database connection an open viewer tab still
                        // holds. Best effort at this point by construction (the
                        // seam's `close()` is `async`), which is why part 1 keeps
                        // those connections read-only: there is nothing unflushed
                        // to lose if the hop does not run before the process goes.
                        databaseViewers.closeAll()
                        // And every language server, for the terminal sessions'
                        // reason: a `sourcekit-lsp` left behind is an orphan process
                        // holding a build-system cache open, which the release check
                        // (`pgrep -fl sourcekit-lsp`) is specifically looking for.
                        // `terminateNow()` rather than the graceful `shutdownAll()`
                        // — this is the last notification AppKit posts, so a `Task`
                        // wrapping the `async` teardown would never be picked up;
                        // see the method's own note.
                        lspWorkspace.terminateNow()
                        // And whatever the Go seams have running — a `go install`
                        // in flight, or a login shell still printing its `PATH`.
                        // A build left behind is worse than an orphan server: it
                        // has a compiler and a linker of its own beneath it, and
                        // it is writing into a staging directory nothing will
                        // finish. Permanent as well as immediate, so a `.go` tab
                        // open arriving after this observer cannot start another
                        // one (see `LSPGoToolchainService.terminateNow()`).
                        lspGoToolchain.terminateNow()
                        // And whatever the Rust seam has running — a login shell
                        // still printing its `PATH`, or a `cargo --version`
                        // probe. Neither is expensive, but the login shell is
                        // exactly the child that can outlive a quit: a profile
                        // slow enough to need the deadline is a profile still
                        // running when the app goes away. Permanent as well as
                        // immediate, for the Go seam's reason — a `.rs` tab
                        // opening after this observer starts nothing at all.
                        //
                        // The rust-analyzer *download* is not this call's
                        // business and needs none: it is `URLSession` bytes into
                        // a staging tree, which the process exit ends and the
                        // next launch's `sweepStaging()` reclaims (D13).
                        lspRustToolchain.terminateNow()
                        // And the zoom monitor, so no event handler outlives the
                        // app. Cheap and undramatic next to the teardown above —
                        // it is here because "installed in `.onAppear`, removed on
                        // termination" is one statement, and splitting it across
                        // two places is how the second half gets forgotten.
                        zoom.uninstall()
                    }
                    // Tear the FSEvents subscription down too, so no stream
                    // outlives the app. `stop()` is idempotent (and a no-op when
                    // no folder was ever opened), so a re-fired `.onAppear`
                    // registering a second observer stays harmless.
                    projectWatcher.stop()

                    // Flush both writers from here, in this order and from this one
                    // place. Autosave first: the session records a dirty *titled*
                    // file only by path, never its contents, so the snapshot is
                    // truthful only once those buffers have reached disk —
                    // otherwise the next launch reopens the file showing the
                    // pre-quit disk state as if it were clean. Doing it here rather
                    // than letting each controller register its own observer is
                    // what makes the ordering deterministic and visible: two
                    // independent observers would run in registration order, which
                    // nothing states or enforces. `AutosaveController` still has its
                    // own termination observer; `flushNow()` is idempotent
                    // (`saveAllDirty()` writes nothing on a second run), so being
                    // called twice on the same quit is harmless — provided the two
                    // calls *agree*, which is why that observer passes
                    // `abandoningBuffers: true` as well. A quit that trimmed the
                    // spared line only when the observers happened to run in one
                    // order would be exactly the order-dependence this comment
                    // claims to have removed.
                    autosave.flushNow(abandoningBuffers: true)
                    sessionController.flushNow()
                }
            }
        }
        .commands {
            // Sparkle's own recommended placement: directly under "About Pisaka"
            // in the app menu, which is where macOS users look for it. `after:`
            // rather than `replacing:` — the About item stays.
            CommandGroup(after: .appInfo) {
                CheckForUpdatesCommand(updater: softwareUpdater)
            }

            CommandGroup(replacing: .newItem) {
                Button("New File") { model.newFile() }
                    .keyboardShortcut("n", modifiers: .command)

                Button("Open…") { openFile() }
                    .keyboardShortcut("o", modifiers: .command)

                Button("Open Folder…") { openFolder() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }

            CommandGroup(replacing: .saveItem) {
                Button("Save") { saveSelected() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(model.selectedID == nil)

                Button("Close") { closeSelected() }
                    .keyboardShortcut("w", modifiers: .command)
                    .disabled(model.selectedID == nil)

                Divider()

                // Local History for the selected tab. Disabled without a
                // *titled* one, which is stricter than every other item in this
                // group on purpose: an untitled buffer belongs to no path, and
                // this feature's first skip rule is "no url" — an enabled item
                // that opened an empty window would say the file has no history
                // when what is true is that it has no file.
                Button("Local History…") {
                    if let url = localHistoryTargetURL { showLocalHistory(for: url) }
                }
                .keyboardShortcut("h", modifiers: [.command, .shift])
                .disabled(localHistoryTargetURL == nil)
            }

            CommandGroup(after: .pasteboard) {
                Button("Toggle Comment") { toggleCommentAtCaret() }
                    .keyboardShortcut("/", modifiers: .command)
                    .disabled(model.selectedID == nil)
            }

            CommandMenu("View") {
                // The three zoom items. Each resolves the zone from the pointer
                // **at invocation time**, exactly as a scroll or a pinch does — a
                // key equivalent fires wherever the pointer happens to be, so ⌘=
                // over the terminal grows the terminal even while the editor holds
                // the focus. With the pointer over no window of ours, Core falls
                // back to the key window's focused surface and then to the
                // interface (`ZoomZone.resolve`).
                //
                // Two items for zooming in, on purpose: ⌘= is the keystroke that
                // needs no Shift, ⌘+ is the one every other Mac app *displays*,
                // and AppKit matches a key equivalent literally — "=" does not
                // answer a ⇧= press, and "+" does not answer a plain one. SwiftUI
                // offers no `isAlternate`, so the alternate is a second item
                // rather than a hidden one.
                Button("Zoom In") { zoom.stepZoomUnderPointer(by: 1) }
                    .keyboardShortcut("=", modifiers: .command)

                Button("Zoom In") { zoom.stepZoomUnderPointer(by: 1) }
                    .keyboardShortcut("+", modifiers: .command)

                Button("Zoom Out") { zoom.stepZoomUnderPointer(by: -1) }
                    .keyboardShortcut("-", modifiers: .command)

                // Only the zone under the pointer — the other two keep whatever
                // the user set them to, which is what makes the three independent
                // in both directions.
                Button("Reset Zoom") { zoom.resetZoomUnderPointer() }
                    .keyboardShortcut("0", modifiers: .command)

                Divider()

                // Toggle the Git Log bottom dock panel. Showing it makes
                // `CommitLogView` appear in the panel, whose `.onAppear` triggers a
                // refresh. Same handler as the bottom bar's Git button.
                Button(bottomPanel == .log ? "Hide Git Log" : "Show Git Log") {
                    togglePanel(.log)
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])

                // Toggle the bottom terminal panel. Showing it with no sessions yet
                // creates the first one in the current project folder (or home when
                // none is open — resolved by `TerminalLaunch`). Same handler as the
                // bottom bar's Terminal button.
                Button(bottomPanel == .terminal ? "Hide Terminal" : "Show Terminal") {
                    togglePanel(.terminal)
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])

                // Toggle the Local Changes bottom dock panel. Showing it makes
                // `LocalChangesView` appear in the panel, whose `.onAppear`
                // triggers a refresh. Same handler as the bottom bar's Changes
                // button.
                //
                // ⌘⇧C, *not* ⌘⇧G: the latter is the macOS standard for "Find
                // Previous" and is claimed by the Find menu below.
                Button(bottomPanel == .changes ? "Hide Local Changes" : "Show Local Changes") {
                    togglePanel(.changes)
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])

                // Toggle the Problems bottom dock panel (the language servers'
                // published diagnostics). Same handler as the bottom bar's
                // Problems button; the panel itself renders whatever the servers
                // currently report, so it needs no on-appear fetch.
                Button(bottomPanel == .problems ? "Hide Problems" : "Show Problems") {
                    togglePanel(.problems)
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])

                // Toggle the Usages bottom dock panel. Same handler as the
                // bottom bar's Usages button; the panel renders whatever the
                // last ⌃⌘U asked, so showing it fetches nothing — a panel that
                // re-ran the previous query on every open would spend a project
                // walk on a question nobody re-asked.
                Button(bottomPanel == .usages ? "Hide Usages" : "Show Usages") {
                    togglePanel(.usages)
                }
                .keyboardShortcut("u", modifiers: [.command, .shift])
            }

            CommandMenu("Find") {
                // ⌘F opens the bar above the editor, or — when it is already open
                // — re-focuses the query field and selects its contents, so a
                // repeated press starts a new search without reaching for the
                // mouse.
                Button("Find…") { search.open() }
                    .keyboardShortcut("f", modifiers: .command)
                    .disabled(model.selectedID == nil)

                // ⌘⌥F opens the same bar with the replace row expanded.
                Button("Replace…") { search.openReplace() }
                    .keyboardShortcut("f", modifiers: [.command, .option])
                    .disabled(model.selectedID == nil)

                // The two navigation commands work whether or not the bar has
                // focus; with the bar closed they are inert (the state forwards to
                // an editor whose controller has nothing applied).
                Button("Find Next") { search.findNext() }
                    .keyboardShortcut("g", modifiers: .command)
                    .disabled(model.selectedID == nil)

                Button("Find Previous") { search.findPrevious() }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    .disabled(model.selectedID == nil)

                Divider()

                // ⌘⇧F opens the project-wide search in its own window (or focuses
                // the one already open). Needs a folder: the search *is* a walk of
                // the opened project.
                Button("Find in Files…") { openProjectSearch() }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                    .disabled(model.projectRoot == nil)

                Divider()

                // ⌃⌘J — Xcode's Jump to Definition binding, and free here (⌘J and
                // ⌃⌘F are not, being AppKit's "center selection" and full screen).
                // The keyboard peer of ⌘-clicking an identifier: both end up in the
                // editor coordinator's one `goToDefinition(in:at:)`. Gated on a tab
                // being open rather than on a project: a symbol declared in the
                // buffer itself is indexed from that buffer, so a lone open file
                // can still jump within itself.
                Button("Go to Definition") { goToDefinitionAtCaret() }
                    .keyboardShortcut("j", modifiers: [.control, .command])
                    .disabled(model.selectedID == nil)

                // ⌃⌘U — free here, and deliberately not ⌘U, which is Run Test.
                // Gated on a tab being open rather than on a project, exactly as
                // Go to Definition is: with no folder open the textual scan
                // still answers for the buffer the question was asked in, which
                // is a better answer to a command the user just invoked than an
                // empty panel.
                Button("Find Usages") { findUsagesAtCaret() }
                    .keyboardShortcut("u", modifiers: [.control, .command])
                    .disabled(model.selectedID == nil)

                // ⌃⌘R — free here, and deliberately not ⌘R, which is Run File.
                // Enabled whenever a tab is open (decision 4): whether a rename
                // is *possible* is a question about the language server, and it
                // is answered on invocation — before any sheet appears — rather
                // than by greying the item out for reasons the menu cannot
                // explain.
                Button("Rename…") { renameAtCaret() }
                    .keyboardShortcut("r", modifiers: [.control, .command])
                    .disabled(model.selectedID == nil)

                // The explicit "complete this word now" command, in addition to
                // AppKit's stock ⌥⎋ and F5, which reach the same delegate.
                //
                // Carries *no* key equivalent, unlike every other item here, and
                // that is the point: its ⌃Space lives on `EditorTextView.keyDown`
                // instead (see the override, which explains why). A menu equivalent
                // is claimed app-wide and beats the first responder to the
                // keystroke, and ⌃Space is the one shortcut this app wants that
                // carries no ⌘ — so binding it here swallowed ⌃Space out of the
                // focused embedded terminal, which needs it as NUL. The item stays
                // for discoverability and still works while the editor is focused,
                // via the same responder hop as ⌃⌘J.
                //
                // Additionally gated on `settings.completionEnabled`: while the
                // toggle is off the delegate answers `[]`, so leaving the item
                // live would make an explicitly-invoked command a silent no-op.
                // Greying it out says *why* nothing happens.
                Button("Complete") { completeAtCaret() }
                    .disabled(model.selectedID == nil || !settings.completionEnabled)
            }

            CommandMenu("Git") {
                // ⌘K, JetBrains' commit shortcut. Gated on the project alone —
                // the same condition as the Local Changes header button — and
                // deliberately *not* additionally on `changedFiles` being
                // non-empty. That list is refreshed only on a folder open, a save
                // and the manual Refresh button, so a change made in the embedded
                // terminal or an external editor would leave ⌘K dead until the
                // user found that button; the dialog's own load runs a fresh `git
                // status` (after flushing dirty buffers) and reports "No local
                // changes" honestly. It is also what makes a **message-only
                // amend** reachable: a clean tree is exactly when it is wanted,
                // and `CommitGate` already permits an empty selection under
                // Amend.
                Button("Commit…") { openCommitDialog() }
                    .keyboardShortcut("k", modifiers: .command)
                    .disabled(model.projectRoot == nil)
            }

            CommandMenu("Run") {
                // Run the active tab's file in a dedicated embedded-terminal
                // session. Enabled only when a tab with a url of a runnable type is
                // selected (the same `RunCommand.canRun` gate as the project-tree
                // "Run" context-menu item). Same handler as that context-menu item.
                Button("Run File") {
                    if let url = model.selectedFile?.url { runFile(url: url) }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!canRunSelectedFile)

                // Run the active tab's file as a test in a dedicated
                // embedded-terminal session. Enabled only when a tab with a url of
                // a recognized test-file naming convention is selected (the same
                // `TestCommand.isTestFile` gate as the project-tree "Run Test"
                // context-menu item). Same handler as that context-menu item.
                Button("Run Test") {
                    if let url = model.selectedFile?.url { testFile(url: url) }
                }
                .keyboardShortcut("u", modifiers: .command)
                .disabled(!canTestSelectedFile)
            }

            CommandMenu("LeetCode") {
                // The items live in their own view so *it* observes the model
                // and this scene's body does not — see the note on `leetCode`.
                // Nothing here is gated on a project being open: a LeetCode
                // problem is written into the user's LeetCode folder and opened
                // as an ordinary tab, which needs no project root (opening that
                // folder as a project stays their separate choice).
                LeetCodeCommands(
                    model: leetCode,
                    onOpenProblem: { leetCodeSheet = .openProblem },
                    onBrowseProblems: { openLeetCodeBrowser() },
                    onSignIn: { leetCodeSheet = .signIn },
                    onSignOut: { signOutOfLeetCode() },
                    onChooseFolder: {
                        LeetCodeFolderChooser.choose(settings: settings, model: leetCode)
                    }
                )
            }
        }

        // The standard Preferences scene: macOS gives it the ⌘, menu item and a
        // dedicated window automatically. Hosts the thin `SettingsView` bound to
        // the shared `settings` store.
        Settings {
            SettingsView(
                settings: settings,
                provisioning: lspProvisioning,
                gopls: lspGopls,
                rust: lspRust,
                installEngine: lspInstallEngine,
                leetCode: leetCode
            )
            // The interface scale, injected *here* rather than inside
            // `SettingsView`: applied by the scene it reaches the settings form
            // itself, not only the views below it (an environment write never
            // reaches the view that makes it).
            .interfaceScaled(settings)
        }
    }

    // MARK: - LeetCode

    /// Open the problem the sheet described, and put the resulting file in a tab.
    ///
    /// Answers `nil` when there is nothing left to say — the file opened, or a
    /// newer request superseded this one — and otherwise the sentence the sheet
    /// shows under its field. Failures reach the user *there* rather than
    /// through `PlatformAlert` while the sheet is up: an alert stacked on the
    /// modal that raised it would make a mistyped number look like a crash.
    /// `PlatformAlert` is kept for the one failure that happens with the sheet
    /// already gone — the tab open itself.
    ///
    /// Everything decidable happens one layer down: `LeetCodeModel` resolves the
    /// input, refuses a Premium problem before writing anything, and **never
    /// overwrites** an existing file. This function's whole contribution is the
    /// folder (asked for on first use) and the tab.
    ///
    /// `onOpened` fires on the one outcome that put a tab up, which is *not* the
    /// same question as "was there anything to say": `nil` is also the answer to a
    /// withdrawn open and to a superseded one, and a caller that reads it as
    /// success acts on an open that never happened. The browser's window-raise is
    /// the caller that noticed — it reordered the windows under a click that had
    /// opened nothing.
    private func openLeetCodeProblem(
        input: LeetCodeProblemInput,
        language: LeetCodeLanguage,
        onOpened: () -> Void = {}
    ) async -> String? {
        // Cancelling the folder panel is an answer, not a failure: the user was
        // asked where solutions go and declined to say, so the sheet stays up
        // with its sentence and nothing is fetched.
        guard LeetCodeFolderChooser.established(settings: settings, model: leetCode) != nil else {
            return LeetCodeError.folderUnavailable.errorDescription
        }
        do {
            let outcome = try await leetCode.openProblem(input: input, language: language)
            // Cancelled means the user closed the sheet while this was in flight
            // (see `LeetCodeOpenProblemSheet.openTask`). The file may already have
            // been created — it is a file in a folder they set aside, and the
            // never-overwrite rule means reopening the problem returns to it — but
            // putting a tab in front of somebody who pressed Esc is the sheet
            // answering a question they withdrew.
            if Task.isCancelled { return nil }
            switch outcome {
            case .created(let solution), .resumed(let solution):
                leetCodeSheet = nil
                openLeetCodeSolution(solution, wasCreated: outcome.wasCreated)
                onOpened()
                return nil
            case .noSuchProblem:
                return "LeetCode has no problem matching that."
            case .superseded:
                // A newer open is already running and owns the sheet's state.
                return nil
            }
        } catch let error as LeetCodeError {
            return error.errorDescription
        } catch {
            return error.localizedDescription
        }
    }

    /// Show the LeetCode problem browser window (⌘⇧B), or focus the one already
    /// open.
    ///
    /// The browser model comes off `leetCode` — the *one* catalog the rest of this
    /// area already reads (L23) — and the open handler is
    /// `openLeetCodeProblem(input:language:)` itself, so a row and a typed number
    /// reach LC-1's flow through the same function. **There is no second open
    /// path**; the only thing added on this route is raising the editor window
    /// afterwards, because this window stays up.
    private func openLeetCodeBrowser() {
        let content = LeetCodeBrowserView(
            browser: leetCode.browser,
            settings: settings,
            model: leetCode,
            onOpen: { input, language in
                await openLeetCodeProblem(
                    input: input,
                    language: language,
                    onOpened: { raiseEditorWindowBehindBrowser() }
                )
            }
        )
        leetCodeBrowserWindows.show(content: content)
    }

    /// Bring the editor window forward, but **below** the browser window — the tab
    /// the user just opened is what they asked for, and the list they opened it
    /// from is what they are still working through.
    ///
    /// The rule for which window that is, written down where it is used: this app
    /// has exactly one `WindowGroup` window and every auxiliary window it makes is
    /// an `EscClosableWindow` (diff, merge, Find in Files, the source viewers and
    /// the browser itself), so **the frontmost visible, main-capable window that is
    /// neither one of ours nor the Preferences window** is the editor. A no-op when
    /// there is none — the window can be closed while the app runs.
    ///
    /// Two things the obvious spelling gets wrong, both stated because this is
    /// identification by exclusion and exclusion rots quietly. `NSApp.windows` is
    /// in *unspecified* order, so "the first match" is only meaningful over
    /// `orderedWindows`, which is documented front-to-back. And the exclusion is
    /// not complete: `Settings` is a window SwiftUI makes rather than this app, so
    /// it is no `EscClosableWindow` and it is main-capable — with Preferences open,
    /// the plain rule sends *it* behind the browser and leaves the editor where it
    /// was. It is excluded by the identifier SwiftUI gives that scene; should a
    /// future SwiftUI stop setting it, the cost is this one cosmetic re-order, so
    /// the miss stays silent by design.
    private func raiseEditorWindowBehindBrowser() {
        guard let browserNumber = leetCodeBrowserWindows.windowNumber else { return }
        guard let editor = NSApp.orderedWindows.first(where: { window in
            window.isVisible
                && window.canBecomeMain
                && !(window is EscClosableWindow)
                && window.identifier?.rawValue != Self.settingsWindowIdentifier
        }) else { return }
        editor.order(.below, relativeTo: browserNumber)
    }

    /// The identifier SwiftUI gives its `Settings` scene window — see
    /// `raiseEditorWindowBehindBrowser()`, its one reader.
    private static let settingsWindowIdentifier = "com_apple_SwiftUI_Settings_window"

    /// Open a solution file as an ordinary editor tab.
    ///
    /// **Opening a problem never changes the project root** — the file is a tab
    /// like any other, and browsing the LeetCode folder as a project stays the
    /// user's separate action. Which is also why the tree bump is conditional:
    /// the tree only shows the opened project, so a file written outside it has
    /// nothing to appear in.
    ///
    /// No `notifyIndexOfProjectFileChanges()` beside that bump, for the reason
    /// `newFile(in:)` already states: the file is opened as a tab in this same
    /// turn, and a buffer-sourced entry is exactly what the index's disk refresh
    /// declines to touch.
    ///
    /// **A failed open has to put the statement panel back**, which is why the
    /// catch path re-asks the question rather than only alerting: `openProblem`
    /// published the statement it already had in hand, the panel is global rather
    /// than keyed to a tab, and with no tab opened the selection did not change —
    /// so `ContentView`'s `.task(id:)` will not re-run and a statement for a
    /// problem the user has no tab for would sit beside whatever unrelated tab is
    /// open. Asking for the *selected* tab is the whole restore: it clears the
    /// panel when that tab is not a solution file and republishes that tab's own
    /// statement when it is — out of the cache, so no second request.
    private func openLeetCodeSolution(_ solution: LeetCodeSolution, wasCreated: Bool) {
        do {
            try model.open(url: solution.url)
        } catch {
            PlatformFeedback.warning()
            Task {
                await leetCode.statement(
                    forFileAt: model.selectedFile?.url,
                    in: settings.leetCodeFolderURL
                )
            }
            PlatformAlert.presentMessage(
                title: "Can't open the solution file",
                message: "The file for problem \(solution.problem.frontendID) was written to \(solution.url.path) but could not be opened."
            )
            return
        }
        guard wasCreated, let root = model.projectRoot, isInsideProject(solution.url, root: root)
        else { return }
        model.bumpTreeRevision()
    }

    /// Whether `url` sits inside the opened project — the tree-bump condition.
    ///
    /// Both sides go through the same symlink-resolving transform before the
    /// containment test, so a project reached through a symlinked path still
    /// matches. (`CanonicalPath` itself is Core-internal; this is the same
    /// transform it applies, which is what keeps the two answers in step.)
    private func isInsideProject(_ url: URL, root: URL) -> Bool {
        ScopedFileAccess.path(
            url.standardizedFileURL.resolvingSymlinksInPath().path,
            isWithin: root.standardizedFileURL.resolvingSymlinksInPath().path
        )
    }

    /// Sign out of LeetCode: the credential store *and* the login web view's
    /// cookies, in that one call.
    ///
    /// Never `leetCode.signOut()` on its own — that clears the Keychain and
    /// leaves the cookies, which signs the user straight back in the next time
    /// the login sheet opens (the rule stated on `LeetCodeWebSession.signOut`).
    private func signOutOfLeetCode() {
        Task { await LeetCodeWebSession.signOut(model: leetCode) }
    }

    /// Toggle a bottom dock panel, shared by the bottom-bar buttons (via
    /// `ContentView.onTogglePanel`) and the View-menu commands so both behave
    /// identically. Selecting the terminal with no sessions yet creates the first
    /// one rooted at the current project folder (or home when none is open —
    /// resolved by `TerminalLaunch`) so the user gets a live shell immediately;
    /// the pure `BottomPanel.toggled` collapses the panel when it is re-selected.
    private func togglePanel(_ panel: BottomPanel) {
        let next = BottomPanel.toggled(bottomPanel, selecting: panel)
        // Create the first session only when the terminal will actually be shown,
        // so a re-select that collapses the panel never spawns a hidden shell.
        if next == .terminal && terminalSessions.sessions.isEmpty {
            terminalSessions.newSession(projectRoot: model.projectRoot)
        }
        bottomPanel = next
    }

    /// Whether the active tab is a saved file of a runnable type — drives the ⌘R
    /// "Run File" menu item's enablement. `false` when there is no selection, the
    /// selected tab has no url (an unsaved "Untitled" buffer), or its extension has
    /// no known runner.
    private var canRunSelectedFile: Bool {
        guard let url = model.selectedFile?.url else { return false }
        return RunCommand.canRun(fileName: url.lastPathComponent)
    }

    /// Whether the active tab is a saved file whose name matches its language's
    /// test-file convention — drives the ⌘U "Run Test" menu item's enablement.
    /// `false` when there is no selection or the selected tab has no url (an
    /// unsaved "Untitled" buffer).
    private var canTestSelectedFile: Bool {
        guard let url = model.selectedFile?.url else { return false }
        return TestCommand.isTestFile(fileName: url.lastPathComponent)
    }

    /// Run the file at `url` in a dedicated embedded-terminal session. Resolves the
    /// shell command via `RunCommand` (beeping + explaining for an unrunnable
    /// type), saves the file first if an open tab for it has unsaved edits (so the
    /// run sees the current contents), shows the terminal panel, and hands off to
    /// `TerminalSessionsModel.runFile(...)`. Shared by the ⌘R menu command and the
    /// project-tree "Run" context-menu item.
    private func runFile(url: URL) {
        guard let command = RunCommand.command(
            forFileName: url.lastPathComponent,
            absolutePath: url.path
        ) else {
            PlatformFeedback.warning()
            presentCantRun()
            return
        }
        // Save the dirty buffer for this file first, so the run reflects the edits
        // the user sees rather than the stale on-disk contents. Saving is an
        // uncoordinated disk write, so refuse (with the same "revert in progress"
        // notice as the project-tree file ops) while a revert's off-main `git`
        // mutations are in flight — a concurrent write races `git checkout` on the
        // same file — and abort the run if the save itself fails rather than
        // running stale on-disk contents that no longer match the editor.
        if let id = model.fileID(forURL: url), model.isDirty(for: id) {
            guard !revertInFlight() else { return }
            guard save(id: id) else { return }
        }
        let wd = RunCommand.workingDirectory(projectRoot: model.projectRoot, fileURL: url)
        // Make the terminal panel visible so the run's output is seen immediately.
        bottomPanel = .terminal
        terminalSessions.runFile(
            url: url,
            command: command,
            workingDirectory: wd,
            title: "Run: \(url.lastPathComponent)"
        )
    }

    /// Surface an attempt to run a file whose type has no known runner, the same
    /// non-fatal informational way as other failures.
    private func presentCantRun() {
        PlatformAlert.presentMessage(
            title: "Can't run this file",
            message: "Can't run files of this type."
        )
    }

    /// The manifests whose *contents* `TestCommand` inspects to pick a runner —
    /// only `package.json` (the JS/TS vitest/jest/mocha substring check). Read
    /// verbatim through `fileService` and handed to `ProjectTestEvidence` so the
    /// resolver stays pure. Every other runner is chosen by an entry's *presence*
    /// in the root listing, not its contents.
    private static let testManifestNames = ["package.json"]

    /// Assemble the project's `ProjectTestEvidence` from the opened `projectRoot`:
    /// the names of its root entries (the listing, which includes dotfiles such as
    /// mocha's `.mocharc*` variants) plus the raw contents of any manifest in
    /// `testManifestNames` that exists.
    /// Empty evidence when no folder is open (every single-runner language still
    /// resolves; JS/TS then reports `.runnerUndetected`). Directory-read /
    /// file-read failures are swallowed — absent evidence, not a fatal error.
    private func projectTestEvidence() -> ProjectTestEvidence {
        guard let root = model.projectRoot else {
            return ProjectTestEvidence(rootEntryNames: [], manifests: [:])
        }
        let entries = (try? fileService.contentsOfDirectory(at: root)) ?? []
        let names = Set(entries.map(\.name))
        var manifests: [String: String] = [:]
        for name in Self.testManifestNames where names.contains(name) {
            if let contents = try? fileService.read(url: root.appendingPathComponent(name)) {
                manifests[name] = contents
            }
        }
        return ProjectTestEvidence(rootEntryNames: names, manifests: manifests)
    }

    /// Test the file at `url` in a dedicated embedded-terminal session, mirroring
    /// `runFile(url:)`. Resolves the per-file test command via `TestCommand` from
    /// the assembled `ProjectTestEvidence` (beeping + explaining when no runner is
    /// detected — JS/TS with no vitest/jest/mocha signal), saves the file first if
    /// an open tab for it has unsaved edits (gated behind `revertInFlight()` and
    /// aborting on a save failure, exactly as `runFile`), shows the terminal panel,
    /// and hands off to `TerminalSessionsModel.testFile(...)`. Shared by the ⌘U
    /// menu command and the project-tree "Run Test" context-menu item.
    private func testFile(url: URL) {
        let result = TestCommand.command(
            forFileName: url.lastPathComponent,
            absolutePath: url.path,
            evidence: projectTestEvidence()
        )
        guard case let .command(command) = result else {
            PlatformFeedback.warning()
            PlatformAlert.presentMessage(
                title: "Can't run tests",
                message: "Couldn't detect a test runner for this project."
            )
            return
        }
        // Save the dirty buffer first so the test sees the edits the user sees,
        // gated the same way as `runFile` — refuse while a revert's off-main `git`
        // mutations are in flight, and abort on a save failure rather than testing
        // stale on-disk contents.
        if let id = model.fileID(forURL: url), model.isDirty(for: id) {
            guard !revertInFlight() else { return }
            guard save(id: id) else { return }
        }
        let wd = TestCommand.workingDirectory(projectRoot: model.projectRoot, fileURL: url)
        // Make the terminal panel visible so the test's output is seen immediately.
        bottomPanel = .terminal
        terminalSessions.testFile(
            url: url,
            command: command,
            workingDirectory: wd,
            title: "Test: \(url.lastPathComponent)"
        )
    }

    private func openFile() {
        guard let url = FilePanels.showOpenPanel() else { return }
        openFile(url: url)
    }

    /// Open a specific file in a tab, beeping on failure. Shared by the Open…
    /// command and the project tree's file rows.
    private func openFile(url: URL) {
        do {
            try model.open(url: url)
        } catch {
            PlatformFeedback.warning()
        }
    }

    /// Ask for a folder and open it. The panel is the *only* thing this form adds:
    /// everything a folder change entails lives in `openFolder(url:)` below, so a
    /// programmatic open (the launch-time session restore) registers the switch with
    /// exactly the same collaborators as a user-driven one.
    private func openFolder() {
        guard let url = FilePanels.showOpenFolderPanel() else { return }
        openFolder(url: url)
    }

    /// Open `url` as the project folder and register the switch everywhere it has
    /// to be registered — the tab set plus the FSEvents watcher, Local Changes, the
    /// Git Log, the branch switcher and Project Search, each with the synchronous
    /// prepare-then-refresh pinning documented below.
    ///
    /// **Sessions are per project.** Whether this is a *switch* is decided first,
    /// before anything is touched: re-opening the folder already open stays a pure
    /// no-op for the tabs (as it already is for the LSP workspace and the commit
    /// dialog), while a real switch snapshots the outgoing project's tabs under that
    /// folder's key and applies the incoming folder's stored session — empty on its
    /// first open. A switch runs four things in this order, and the order is the
    /// whole design:
    ///
    /// 1. It **refuses** while a revert's off-main `git` mutations are in flight
    ///    (`revertInFlight()`) — the same posture as ⌘S, and for the same reason:
    ///    the switch is about to force-close every tab, and a buffer whose save is
    ///    racing a `git checkout` must not be one of them.
    /// 2. It **flushes autosave** (`reportingSaves: true`, so the writes it makes
    ///    get the same follow-up an ordinary mid-session autosave gets: Local
    ///    Changes re-queried, the tree bumped for a recreated file) — **protecting
    ///    carets**, because whether these buffers survive is not yet decided: step
    ///    3's refusal is read off this very flush, and both a refusal and the
    ///    carrying path leave every tab open and being edited. Once step 3 has been
    ///    passed on the replacing path it flushes a *second* time with
    ///    `abandoningBuffers: true`, which is where a spared trim is finally
    ///    settled; that pass writes nothing at all unless one was spared, since
    ///    `saveAllDirty()` is idempotent.
    /// 3. Because that flush is **best-effort** — `saveAllDirty()` swallows a
    ///    per-file write failure by design — it then **refuses and names the files**
    ///    if any dirty *titled* buffer is still unsaved. Force-closing a buffer whose
    ///    contents never reached disk would destroy the user's work outright, which
    ///    is a strictly worse outcome than not switching. Untitled buffers need no
    ///    flush at all: their text travels *inside* the outgoing snapshot. This
    ///    refusal is scoped to `hadFolder` — the *replacing* path, the only one that
    ///    force-closes anything. The carrying path below (see the asymmetric case)
    ///    leaves every tab open, so an unsaved buffer is in no more danger after the
    ///    open than before it, and refusing there would block the first Open Folder
    ///    of a run for a loss that path cannot cause.
    /// 4. It persists the outgoing snapshot through `sessionController.flushNow()`,
    ///    while `projectRoot` is still the **outgoing** folder — that is what keys it
    ///    correctly, since `SessionStore.save(_:)` is an upsert on the snapshot's own
    ///    `folderPath`. Going through `flushNow()` rather than snapshotting directly
    ///    also inherits its `hasObservedChange` guard, which is load-bearing here:
    ///    at launch, restore calls this method *before* the controller is started, so
    ///    an unguarded snapshot would write the empty live model over the no-folder
    ///    workspace's stored session.
    ///
    /// After the swap, `sessionController.noteProjectSwitch(promoting:)` files the
    /// incoming project at the catalog's head and suppresses the debounced write the
    /// swap would otherwise arm — see there for why persisting a restore that
    /// skipped records would be a loss.
    ///
    /// **The one asymmetric case is the outgoing workspace that has no folder** —
    /// the first Open Folder of a run. It is a switch for the tree, but its key is
    /// `nil`, and launch restore can only reach the `nil` entry while it is the
    /// catalog's head, which opening this folder is about to take. Force-closing
    /// there would file an unsaved Untitled buffer under a key nothing reads again,
    /// so the pre-folder tabs travel *into* the project instead: the incoming
    /// session is applied on top of them rather than replacing them, and the
    /// session *promoted* for the project is the two merged
    /// (`EditorSession.merging(_:onto:incomingRestoredAny:)`, told what
    /// `restoreSession` actually did) — promoting the unmerged incoming one would
    /// leave those tabs on screen but unwritable, see `noteProjectSwitch`'s superset
    /// invariant. Nothing being force-closed is also why step 3's refusal does not
    /// apply here. At launch this is all the same thing, since there is nothing open
    /// to carry.
    ///
    /// The existence guard at the top protects against the recents list offering a
    /// folder deleted since it was recorded. Every present and future programmatic
    /// caller inherits this refusal rather than re-implementing it.
    /// `restoreLastSession()` is untouched — its own pre-check keeps launch restore
    /// on the silent path, so the new alert can never fire at launch.
    private func openFolder(url: URL) {
        guard isExistingDirectory(atPath: url.path) else {
            reportMissingFolderBeforeSwitch(url)
            return
        }

        // Both decided *before* `model.openFolder(url:)` moves `projectRoot`, which
        // would make every later test read as a re-open.
        let isSwitch = !model.isCurrentProjectRoot(url)
        let hadFolder = model.projectRoot != nil
        if isSwitch {
            guard !revertInFlight() else { return }
            // This first flush **protects carets**, on every path: whether the
            // buffers survive is not yet known here. The carrying path below keeps
            // every tab open, and the refusal a few lines down — which is decided
            // by what this very flush leaves unsaved — leaves them open *and being
            // edited*. `flushNow`'s flag means "the buffers do not survive this
            // flush", and asserting that before either question is answered would
            // trim the line someone is still typing on.
            autosave.flushNow(reportingSaves: true, abandoningBuffers: false)
            // Only the *replacing* path can lose that text, and so only it refuses:
            // the carrying path below force-closes nothing, so the buffer stays
            // open, dirty, exactly as it is now — refusing there would block the
            // first Open Folder of a run over a risk that path does not take, with
            // an alert whose "would close them" reason is not even true of it.
            if hadFolder {
                let unsaved = unsavedTitledFileNames()
                if !unsaved.isEmpty {
                    reportUnsavedBeforeFolderSwitch(unsaved)
                    return
                }
                // Past the refusal the switch is going ahead and these tabs are
                // about to be force-closed, so now the flag is true: no caret is
                // left to protect and no next save to defer a spared trim to.
                // Flushing twice is what `flushNow` already documents as harmless —
                // `saveAllDirty()` is idempotent, so this second pass writes only
                // the buffers whose spared runs it has just settled, and nothing at
                // all in the ordinary case where none were spared.
                autosave.flushNow(reportingSaves: true, abandoningBuffers: true)
            }
            sessionController.flushNow()
        }

        model.openFolder(url: url)

        // Point the `.editorconfig` cache at the new root in this same synchronous
        // turn, before anything can ask it a question: the model clears itself on a
        // root change, so a configuration resolved under the folder the user just
        // left can never be returned for a file in this one. Unconditional — a
        // re-open of the same root is a no-op inside the model, which compares the
        // roots itself.
        editorConfig.noteProjectRoot(url)

        // Apply the incoming project's tabs, before the collaborators below are
        // pointed at the new root: a first open of this folder has no stored session
        // and gets an explicitly empty one, which empties the editor rather than
        // leaving the previous project's tabs behind the new tree. The empty session
        // still carries this folder as its `folderPath`, so promoting it below files
        // it under the right key rather than under the no-folder workspace's.
        //
        // `folderPath` is re-stamped with the spelling the user just opened — the
        // verbatim-latest-spelling rule `SessionCatalog.store(_:)` states, and the
        // one the debounced writer would use anyway, since it snapshots
        // `projectRoot`. `restoreSession`/`replaceSession` ignore the field.
        if isSwitch {
            var incoming = sessionStore.session(forFolder: url) ?? EditorSession()
            incoming.folderPath = url.path
            let promoted: EditorSession
            if hadFolder {
                model.replaceSession(with: incoming)
                promoted = incoming
            } else {
                // The carried tabs have to reach the *store*, not just the model.
                // `noteProjectSwitch` seeds the "already written" marker with the
                // post-swap live snapshot, which suppresses every later equal write
                // — the quit-time flush included — so a promoted session missing
                // these tabs would make them unwritable for the rest of the run:
                // on screen, absent from the stored session, gone at the next
                // launch. `EditorSession.merging` states the order and selection
                // (it must be a *superset* of the live model); the snapshot is
                // taken before `restoreSession` appends the incoming tabs, and
                // `projectRoot` has already moved, so it is stamped with the right
                // folder either way.
                let carried = EditorSession.snapshot(
                    openFiles: model.openFiles,
                    selectedID: model.selectedID,
                    projectRoot: url
                )
                // Whether the incoming records became tabs is `restoreSession`'s
                // answer to give, not something `incoming.tabs` can be read for: a
                // project whose every file has moved restores nothing and leaves
                // the selection on a carried tab, and the promoted session has to
                // say that rather than point at a record no tab exists for.
                let restoredAny = model.restoreSession(incoming)
                promoted = EditorSession.merging(
                    incoming,
                    onto: carried,
                    incomingRestoredAny: restoredAny
                )
            }
            sessionController.noteProjectSwitch(promoting: promoted)
        }
        // Watch the newly opened folder so external changes (a generator run in the
        // embedded terminal, a Finder rename, a console `git checkout`) reach the
        // tree without reopening it. `start` is idempotent — it tears the previous
        // stream down first — so this doubles as the folder switch: events from the
        // old root stop arriving. The callback runs on the main actor and does the
        // one thing the tree needs, the same bump the app's own file operations use.
        //
        // The same callback drives the symbol index's refresh, debounced a further
        // 500 ms on top of the watcher's own 1 s coalescing. Nothing about that is
        // gated either, and for the reason spelled out on `projectWatcher` and on
        // `SymbolIndexModel`: the index is a *reader*, so a refresh landing in the
        // middle of a revert costs at worst one stale entry that the next refresh
        // corrects. `url` is captured rather than read from the model so the
        // refresh always names the root this subscription was started for.
        // The same callback drops the `.editorconfig` cache, which is the whole
        // reason a live edit to one takes effect without reopening the project. It
        // is a reader too, so it is ungated for the same reason, and its
        // invalidation is wholesale rather than debounced: clearing a dictionary
        // costs nothing, and the re-resolution is paid for by the next question
        // anyone asks of it — the next keystroke in the front tab, and the next
        // save, which asks once per buffer it is about to write
        // (`SaveTransformController.prepare`). Both are outward walks of a handful
        // of directories on the main thread; what keeps that cheap is that the
        // walk stops at the project root and that the answer is cached again on
        // the way out, not that the cache is rarely dropped.
        projectWatcher.start(root: url, onChange: {
            model.bumpTreeRevision()
            symbolIndexController.noteProjectFilesChanged(root: url)
            editorConfig.noteProjectFilesChanged()
        })
        // Record the folder switch *synchronously*, in this same main-actor turn,
        // before launching the async refresh. The model's revert guard keys off a
        // folder change being observed (via `rootRequestGeneration`) — but bumping
        // it only inside the `Task`-wrapped `refresh` below would run a later
        // main-actor turn, leaving a window where an in-flight revert's continuation
        // can resume first and keep mutating the *previous* repository. The
        // synchronous call closes that window; the subsequent `refresh` then no-ops
        // its own switch-handling (same `lastRequestedRoot`), so there is no
        // double-clear.
        let requestGeneration = localChanges.prepareForFolderChange(root: url)
        // Drive the Local Changes refresh from here rather than relying on
        // `LocalChangesView`'s `.onChange(of: projectRoot)`: that view is only in
        // the hierarchy in "Changes" mode, so in "Project" mode a folder switch
        // would never reach the model. Refreshing here makes the switch reliable;
        // the view's own refresh stays as a (same-root, idempotent) backstop when
        // toggling back to Changes.
        //
        // Pass the request generation captured synchronously above: two rapid
        // folder opens spawn two refresh tasks, and unstructured tasks are not
        // guaranteed to start in creation order — so an earlier folder's task can
        // run last. The generation lets the model reject the superseded refresh
        // instead of leaving the Changes panel on a different repo than the
        // workspace.
        Task { await localChanges.refresh(root: url, requestGeneration: requestGeneration) }

        // Refresh the Log view too, for the same reason: `CommitLogView` is only in
        // the hierarchy in Log mode, so a folder switch made while in editor mode
        // would otherwise not reach the model until the user toggled into Log.
        // Capture the request token synchronously (which also resets the previous
        // repo's ref-specific filter/refs on this folder switch) before the `Task`
        // hop, so two rapid folder opens settle on the latest even if their
        // unstructured tasks start out of order — mirroring the Local Changes path.
        let logRequest = commitLog.prepareForRefresh(root: url)
        Task { await commitLog.refresh(root: url, limit: CommitLogView.initialLimit, request: logRequest) }

        // Refresh the branch-switcher widget for the newly opened folder. Capture
        // the request token synchronously (which also clears the previous repo's
        // branch list on this folder switch) before the `Task` hop, so two rapid
        // folder opens settle on the latest even if their unstructured tasks start
        // out of order — mirroring the Local Changes / Log paths above.
        let branchRequest = branchSwitcher.prepareForRefresh(root: url)
        Task { await branchSwitcher.refresh(root: url, request: branchRequest) }

        // Register the folder switch with the project search *synchronously*, in
        // this same main-actor turn — the `prepareForFolderChange` rule. It bumps
        // the request generation and drops the previous project's results, so an
        // in-flight traversal (or a Replace All suspended on its off-main I/O)
        // finds itself superseded the instant it resumes instead of publishing —
        // or rewriting — files under a folder the user has left. No refresh is
        // spawned: the Find in Files window runs a search only when the user asks
        // for one.
        projectSearch.prepareForSearch(root: url)

        // And with the usages panel, in this same turn and for the same reason:
        // it drops the previous project's rows — which are file positions in
        // files this window no longer shows — and bumps both of its tokens, so a
        // walk suspended on its off-main I/O abandons instead of filling the new
        // project's panel with the old one's matches. No query is spawned: the
        // panel answers a question the user asks, never one it asks itself.
        usages.prepareForFolderChange(root: url)

        // Register the switch with the commit dialog *synchronously* too, for the
        // same reason and with sharper consequences: it clears the previous
        // project's file selection and message, and it bumps the token an
        // in-flight `commit()` is pinned to — so a commit composed for the folder
        // the user just left can never run against the newly opened one. No load
        // is spawned; the dialog reads the repository when it is opened.
        //
        // A sheet that is *up* is dismissed as part of that switch. `reset()` empties
        // everything it displays but cannot lower `isCommitDialogPresented`, so the
        // sheet stayed on screen bound to a deliberately emptied model — an empty
        // file list, a blank author line, the message the user was composing wiped,
        // no spinner and "This folder is not a git repository." under a disabled
        // Commit button, with nothing saying why. (⌘⇧O is reachable from a sheet:
        // SwiftUI does not disable the main menu, which is why `openCommitDialog`
        // needs its own re-entry guard.) Dismissing also fires `onDismiss`, so the
        // modal autosave suspension is released rather than stranded.
        let generationBefore = commitDialog.currentRequestGeneration
        if commitDialog.prepareForFolderChange(root: url) != generationBefore {
            isCommitDialogPresented = false
        }

        // Register the switch with the symbol index *synchronously* too, and only
        // then spawn the walk. `prepareForFolderChange` bumps the request
        // generation and clears the index in this turn, so an in-flight walk finds
        // itself superseded when it resumes and no symbol from the folder the user
        // just left stays jumpable while the new one is being read — a definition
        // that opens a file from the previous project is worse than none. The
        // controller's two debounces are dropped for the same reason: whatever they
        // would publish is already superseded, so the work is simply not done.
        //
        // Unlike Find in Files, a walk *is* spawned: the index has to exist before
        // the user asks for a definition, since there is no window to open first.
        // This is the sole place a folder switch is registered, so the launch-time
        // session restore builds the index exactly as a user-driven open does.
        symbolIndexController.reset()
        let symbolRequest = symbolIndex.prepareForFolderChange(root: url)
        Task { await symbolIndex.rebuild(root: url, request: symbolRequest) }

        // Apply Local History's retention to the whole store, once per open —
        // which the launch-time session restore reaches through this same
        // function, so a relaunch prunes exactly as a user-driven open does.
        //
        // Capture already prunes the one file it just wrote; this is the only
        // thing that reclaims the history of files nobody has touched since their
        // revisions aged out, and without it a project abandoned for a month would
        // keep every snapshot forever. It sweeps *every* project area rather than
        // this one, which is why it takes no root: a project reclaimed only when
        // it is reopened is a project never reclaimed. Fire-and-forget on the
        // model's own chain and off the main actor, so nothing *here* waits on
        // it, and a folder switch in the gap costs at most one sweep that had to
        // happen anyway.
        //
        // It does sit on the same chain as the captures, which is deliberate and
        // has one stated cost: a gated operation started while the sweep is still
        // running waits for it, because `captureBeforeOperation` is awaited and
        // the chain is serial (see there). Retention deletes names retention has
        // already condemned, but it deletes them *between* another capture's
        // list-decide-write, so a lane of its own would trade a bounded wait for
        // a dedup that reads a directory another unit is mutating.
        //
        // No generation token, deliberately — unlike every collaborator above,
        // this publishes nothing and reads nothing anyone displays, so there is no
        // superseded state it could write over.
        localHistory.pruneStore()

        // Register the switch with the LSP workspace in this same turn, for the same
        // reason and with the sharpest consequence of the three: a language server is
        // *initialized for one root*, so an answer from the previous project's server
        // would name a file under a folder the user has left. The synchronous call
        // bumps the token a launch still in its handshake is pinned to, so that
        // server is terminated when it finishes rather than stored.
        //
        // Only when the root actually changed (the `commitDialog` idiom above):
        // re-opening the same folder must not tear down a server that has already
        // paid for resolving its build system. The teardown itself has to be
        // awaited — a graceful `didClose`/`shutdown`/`exit` cannot happen
        // synchronously — and needs no generation of its own, because
        // `shutdownAll()` is unconditional.
        //
        // Which leaves exactly one narrow window, worth stating rather than
        // engineering around: a request arriving between this turn and the teardown
        // sees the *new* root and may start its server, which `shutdownAll()` then
        // stops. It costs one wasted launch and one tree-sitter answer, and — the
        // part that matters — no restart budget, since a superseded launch is not a
        // failure and a server shut down deliberately leaves no dead session for the
        // next request to count as a crash.
        let lspGenerationBefore = lspWorkspace.currentRequestGeneration
        if lspWorkspace.prepareForFolderChange(root: url) != lspGenerationBefore {
            Task { @MainActor [lspDocumentSync, lspWorkspace, model] in
                await lspWorkspace.shutdownAll()
                // Diagnose the tabs this open just installed — *every* one of
                // them, not only the one the editor happens to display (D30).
                // A restored session's background tabs have no `CodeEditorView`
                // behind them, so the tab-switch trigger that is the sync's
                // whole steady-state supply never fires for them and the server
                // is never told they exist: the Problems panel would cover
                // "files visited since launch" rather than the open ones.
                //
                // After the teardown rather than beside it, deliberately: a
                // sync issued in the same turn as the switch would launch a
                // server for the new root that `shutdownAll()` then stops,
                // costing the launch and stranding the didOpen with it. The
                // displayed tab's own sync is unaffected — it rides the
                // editor's update and this call is idempotent (`prepare` sends
                // nothing for text the server already holds).
                PisakaApp.syncOpenBuffersForDiagnostics(of: model, through: lspDocumentSync)
            }
        }

        // Register the switch with the diagnostics channel in this same turn,
        // for the same reason one step removed: the model's cleared sync
        // bookkeeping means no push routed from an old project's server can
        // land, and the pending debounced flushes are dropped rather than
        // flushing new-folder text at an old project's still-live server. The
        // next tab open/switch or settled keystroke re-syncs against whatever
        // serves the new root.
        //
        // Only on a *switch*, like the LSP teardown just above: re-opening the
        // folder already open leaves every tab in place, so no re-sync would
        // follow — wiping the store there would blank all three surfaces with
        // nothing to repopulate them until the next keystroke or tab switch.
        if isSwitch {
            diagnostics.prepareForFolderChange()
            lspDocumentSync.reset()
        }
    }

    private func recentProjectRows() -> [RecentProject] {
        RecentProject.rows(
            catalog: sessionStore.loadCatalog(),
            currentRoot: model.projectRoot,
            folderExists: { isExistingDirectory(atPath: $0.path) }
        )
    }

    // MARK: - Commit dialog

    /// Open the commit dialog for the current project (⌘K / the Local Changes
    /// header button / a changed file's "Commit…" context-menu item).
    ///
    /// `preselectingPath` is the JetBrains "Commit File" case: with a repo-relative
    /// path only *that* file is left checked in the freshly loaded list, and it is
    /// the **only** difference between the row item and ⌘K/the ✓ button. Everything
    /// around it — the re-entry guard, `revertInFlight()`, the autosave flush and
    /// its unsaved-files report, the modal suspension, the generation pinning — is
    /// shared verbatim, which is why the orchestration is parameterized here rather
    /// than duplicated at the row's call site. `nil` (every existing call site)
    /// keeps today's behaviour, every file checked. A path absent from the fresh
    /// `git status` leaves nothing selected — the honest outcome, which `CommitGate`
    /// reports as `.nothingSelected`.
    ///
    /// Three things happen before the sheet is raised, in this order. It **refuses**
    /// while a revert's off-main `git` mutations are in flight (`revertInFlight()`):
    /// the commit reads every changed file and then writes a temporary index from
    /// them, which a concurrent `git checkout` would make nonsense of. It **flushes
    /// dirty buffers** — the dialog shows what is on *disk*, so an unsaved editor
    /// buffer would otherwise be invisible to it and silently left out of the
    /// commit — and, because that flush is best-effort, names whatever it could not
    /// write rather than letting the commit record those files' stale disk contents
    /// unannounced. And it raises the **modal** autosave gate, so no idle/focus-loss
    /// autosave writes a file out from under the dialog's snapshot while it is up;
    /// `suspendForModal` rather than `suspend` deliberately, so a quit while the
    /// sheet is open still flushes every dirty file. The matching
    /// `resumeFromModal()` is the sheet's `onDismiss`, which fires on *every*
    /// closing path.
    private func openCommitDialog(preselectingPath: String? = nil) {
        // A SwiftUI sheet does not disable the main menu, so ⌘K fires again while
        // the dialog is up. Without this the second call would raise a *second*
        // modal autosave suspension that no `onDismiss` ever balances (the sheet is
        // already presented, so none is fired), leaving autosave off for the rest
        // of the session — and would reload the dialog, resetting the user's
        // per-line selection to "everything checked" mid-composition.
        guard !isCommitDialogPresented else { return }
        guard let root = model.projectRoot else { return }
        guard !revertInFlight() else { return }
        // `reportingSaves: true` — unlike the quit-time flush this one lands
        // mid-session, so the writes it makes need the same follow-up an ordinary
        // autosave gets: Local Changes re-queried (otherwise the panel keeps
        // describing the pre-flush disk state, plainly wrong as soon as the user
        // cancels the dialog) and the tree bumped for a file this flush *recreated*
        // after an out-of-band deletion.
        autosave.flushNow(reportingSaves: true)
        // The flush is **best-effort**: `WorkspaceModel.saveAllDirty()` swallows a
        // per-file write failure by design (autosave fires unattended and must not
        // abort the batch or raise a modal on one bad write), leaving that buffer
        // dirty. The dialog reads *disk*, so such a file is shown — and committed —
        // with its last successfully saved contents rather than what the editor
        // displays, which is exactly the silent divergence the flush exists to
        // prevent. So the remainder is measured here and named to the user. The
        // dialog still opens: the other files are perfectly committable and one
        // unwritable path must not strand the whole feature (a file whose write
        // fails cannot be saved on a retry either).
        let unsaved = unsavedTitledFileNames()
        autosave.suspendForModal()
        // Pin the load to the token captured synchronously here, before the `Task`
        // hop (the `prepareForFolderChange` rule): a folder switch that lands in
        // the gap then rejects this load rather than filling the dialog with the
        // previous project's files.
        let request = commitDialog.prepareForFolderChange(root: root)
        isCommitDialogPresented = true
        Task { await commitDialog.load(root: root, request: request, preselectedPath: preselectingPath) }
        // Reported last, once the re-entry guard is closed and the suspension is
        // balanced by the sheet's `onDismiss`: the alert runs a nested run loop, in
        // which a second ⌘K would otherwise re-enter this method and raise a
        // suspension nothing releases.
        if !unsaved.isEmpty { reportUnsavedBeforeCommit(unsaved) }
    }

    /// The display names of dirty *titled* buffers — the ones a flush was supposed
    /// to put on disk. An "Untitled" buffer names no file, so it is not part of the
    /// question: autosave never writes it and the commit dialog never sees it.
    private func unsavedTitledFileNames() -> [String] {
        model.openFiles
            .filter { $0.url != nil && model.isDirty(for: $0.id) }
            .map(\.displayName)
    }

    /// Say that the pre-dialog flush left files unsaved, so the commit will record
    /// what is on disk rather than what is on screen for them.
    private func reportUnsavedBeforeCommit(_ names: [String]) {
        PlatformFeedback.warning()
        PlatformAlert.presentMessage(
            title: "Unsaved changes are not included",
            message: "These files could not be saved, so the commit uses the contents "
                + "already on disk rather than what the editor shows:\n\n"
                + names.joined(separator: "\n")
        )
    }

    /// Say that the folder switch was **refused** because the pre-switch flush left
    /// files unsaved — the sibling of `reportUnsavedBeforeCommit`, with the opposite
    /// resolution. The commit dialog opens anyway (it merely records stale disk
    /// contents for those files); a switch cannot proceed, because its next act is
    /// to force-close exactly those buffers, and text that never reached disk would
    /// be gone for good.
    ///
    /// Reached only from the *replacing* path (`hadFolder`), which is what makes the
    /// message's reason true: the first Open Folder of a run carries its tabs into
    /// the project instead of closing them, so it has nothing to refuse.
    private func reportUnsavedBeforeFolderSwitch(_ names: [String]) {
        PlatformFeedback.warning()
        PlatformAlert.presentMessage(
            title: "Cannot switch project folders",
            message: "These files could not be saved, and switching folders would "
                + "close them and lose those edits:\n\n"
                + names.joined(separator: "\n")
        )
    }

    private func reportMissingFolderBeforeSwitch(_ url: URL) {
        PlatformFeedback.warning()
        PlatformAlert.presentMessage(
            title: "Cannot open project folder",
            message: "The folder “\(url.lastPathComponent)” no longer exists at its recorded location."
        )
    }

    /// Run the commit the dialog describes and deal with each outcome.
    ///
    /// The dialog stays open on everything that did **not** create a commit — a
    /// gate refusal, a stale snapshot, git's own failure — with the reason (git's
    /// stderr verbatim, for a failure) already published in `model.errorMessage`,
    /// so the user can fix it and retry in place. Every outcome that *did* create
    /// one closes the sheet, including a failed push: the commit exists, and
    /// leaving a dialog open whose Commit button would make a *second* one is the
    /// one mistake this must not invite. A push failure is reported in its own
    /// alert saying exactly that.
    ///
    /// `originGeneration` is captured by the *view*, synchronously in the button's
    /// action before its `Task` hop, and threaded in here — the
    /// `ProjectSearchView.confirmReplaceAll` precedent and the same reason: this
    /// whole body already runs inside that task, i.e. after the window the pin
    /// exists to close, so reading the token here would compare it against itself
    /// and could never fire.
    private func commitFromDialog(originGeneration: Int) async {
        // A commit can rewrite the working tree: a `pre-commit` hook that formats
        // (prettier, eslint --fix, gofmt) edits the files on disk, and git runs it
        // before reading the index it commits. This is the one worktree-mutating
        // path in the app, so it takes the same snapshot every sibling does
        // (`applyMerge`, `revertChanges`, `switchBranch`) — synchronously, before the
        // `await` hop. Without the resync that follows, the tab kept the pre-format
        // text with `savedText` matching it (`openCommitDialog` flushed autosave, so
        // every titled tab is clean), which means `isDirty` is false and *nothing*
        // would ever correct it: the next keystroke autosaves the whole stale buffer
        // over the file and the hook's work is silently reverted, looking like the
        // user's own edit.
        let snapshot = openTabSnapshot()
        let repoRoot = commitDialog.root
        // The same writer bracket every sibling takes, raised **synchronously**
        // before the first `await` and released by `defer`. A commit reads the
        // whole working tree into the temporary index (a file entering it as
        // `.addFromWorktree` has its bytes read by git at commit time, so a write
        // landing in that window is silently committed, and `CommitStaleness` only
        // re-compares *rows*), and a formatting `pre-commit` hook then writes the
        // tree back. The modal suspension taken at open is not enough: it gates
        // `performAutosave` alone, leaving ⌘S / ⌘R / ⌘U live — SwiftUI does not
        // disable the main menu for a sheet, which is the same fact
        // `openCommitDialog`'s re-entry guard exists for — and it gates neither the
        // project-tree operations nor `runFile`/`testFile`, both of which key on
        // `localChanges.isReverting`.
        autosave.suspend()
        localChanges.beginRevert()
        // Pre-empting a formatting `pre-commit` hook, which is the one way a
        // commit rewrites the working tree — the same fact the snapshot above
        // exists for, and the reason the resync below is not enough on its own:
        // the resync can put the hook's text into the tab, but the *pre-hook* text
        // is then gone from everywhere. Inputs collected in the synchronous
        // stretch, and this is the first `await` in the body, ahead of the commit's
        // own — so what it stores is pre-operation by construction.
        await captureBeforeOperation(
            .commit,
            buffers: openBufferTexts(),
            targets: changedFileURLs(localChanges.changedFiles, root: repoRoot)
        )
        let outcome = await commitDialog.commit(originGeneration: originGeneration)
        // Git op done: lower the disk-writer gates *before* any modal, the
        // `runBranchOperation` rule and for its reason. `PlatformAlert
        // .presentMessage` is `NSAlert.runModal()`, a nested run loop, and
        // `AutosaveController.flushNow()` bails while `suspendCount > 0` — so a
        // quit while the push-failure alert sits on screen would skip the
        // termination flush for every dirty buffer. Nothing below awaits, so
        // there is no path out of this function between the two statements and
        // the former `defer` bought nothing.
        localChanges.endRevert()
        autosave.resume()
        switch outcome {
        case .committed:
            isCommitDialogPresented = false
            resyncOpenTabsAfterCheckout(snapshot: snapshot, repoRoot: repoRoot, mayRemoveFiles: false)
            refreshAfterCommit()
        case let .committedPushFailed(reason):
            isCommitDialogPresented = false
            resyncOpenTabsAfterCheckout(snapshot: snapshot, repoRoot: repoRoot, mayRemoveFiles: false)
            refreshAfterCommit()
            PlatformFeedback.warning()
            PlatformAlert.presentMessage(
                title: "Commit created, push failed",
                message: "The commit was created locally. The push failed:\n\n\(reason)"
            )
        case .abandoned:
            // The project changed under the dialog; nothing ran and its contents
            // describe a repository that is no longer open.
            isCommitDialogPresented = false
        case .failed:
            // Stay open: git's stderr is on screen and the user can act on it.
            //
            // But resync anyway — a `pre-commit` hook that formats the tree and
            // *then* refuses ("I reformatted these, please review") is the single
            // commonest way a commit fails, and it has already rewritten the files
            // on disk by the time git exits non-zero. Every open tab is clean
            // (`openCommitDialog` flushed autosave), so `isDirty` is false and
            // nothing else would ever correct it: the first autosave after the
            // sheet closes writes the pre-hook buffer back over the file and
            // silently reverts the hook's work, looking like the user's own edit.
            // That is the same failure the success branch's resync exists to
            // prevent — it does not become acceptable because git exited non-zero.
            // Local Changes is refreshed for the same reason: those rewrites are
            // ordinary local changes now.
            resyncOpenTabsAfterCheckout(snapshot: snapshot, repoRoot: repoRoot, mayRemoveFiles: false)
            refreshLocalChanges()
            PlatformFeedback.warning()
        case .blocked, .stale:
            // Nothing ran — no index step, no hook, so the working tree is exactly
            // as it was. Stay open: the reason is on screen and the user can act
            // on it.
            PlatformFeedback.warning()
        }
    }

    /// Re-query everything a new commit changes: Local Changes (the committed
    /// files leave the list), the Git Log (the new commit heads it) and the branch
    /// widget (its dirty flag, and the branch an unborn HEAD's first commit just
    /// created).
    ///
    /// Deliberately **no** `bumpTreeRevision()`: a commit writes `.git`, not the
    /// working tree, so no listing changed and re-reading every expanded node
    /// would be pure waste. (A `pre-commit` hook that rewrites files is the
    /// exception, and its edits show up as ordinary local changes — which the
    /// Local Changes refresh below does surface.)
    private func refreshAfterCommit() {
        refreshLocalChanges()
        refreshLog()
        refreshBranchSwitcher()
    }

    /// Generation-pinned branch-widget refresh, mirroring `refreshLog()`.
    private func refreshBranchSwitcher() {
        guard let root = model.projectRoot else { return }
        let request = branchSwitcher.prepareForRefresh(root: root)
        Task { await branchSwitcher.refresh(root: root, request: request) }
    }

    // MARK: - Session restore

    /// Apply the last persisted session and start writing new ones. Called exactly
    /// once, from the window content's `.onAppear`, before the first interaction.
    ///
    /// What is restored is the **head of the session catalog** — the project opened
    /// last, `loadLastOpened()`. The store is keyed per project now, so the head *is*
    /// the pointer: there is no separate "last session" field that could name an
    /// entry the store does not hold.
    ///
    /// A recorded folder that still exists is opened through `openFolder(url:)` — the
    /// one path that starts the FSEvents watcher and registers the change with Local
    /// Changes / the Git Log / the branch switcher / Project Search — rather than
    /// through `model.openFolder(url:)` directly, which would leave every one of
    /// those on a project the workspace has already moved to. Since `projectRoot` is
    /// still `nil` here, that open reads as a *switch*, so it also applies the
    /// folder's stored tabs: the tab half of launch restore travels the exact same
    /// path a user-driven Open Folder does, rather than a second implementation of
    /// it. The pre-switch prologue is trivially satisfied at launch (no revert is in
    /// flight, no buffer is dirty, and the not-yet-started controller's `flushNow()`
    /// is the no-op its `hasObservedChange` guard makes it).
    ///
    /// The other two cases — a session with **no folder** at all, and one whose
    /// folder has since been deleted or replaced by a file — get
    /// `model.restoreSession(_:)` directly, because there is no folder to switch to:
    /// the tabs do not depend on the folder's fate, and an untitled scratch buffer
    /// stored under the no-folder key must come back exactly as it did before.
    ///
    /// Everything here is **silent**: a missing file, an unreadable one, a vanished
    /// folder all pass without an alert or a beep. Restore is not an operation the
    /// user asked to succeed, and a launch that starts by explaining what it could
    /// not bring back is worse than one that quietly brings back the rest.
    ///
    /// The writer starts *after* the session is applied, and writes nothing until
    /// the workspace actually changes: restore is deliberately lossy (a vanished
    /// folder is not opened, an unreadable file is not reopened), so a write
    /// triggered by the launch itself would persist that truncated session over the
    /// recorded one before the user has touched anything — see `SessionController`.
    private func restoreLastSession() {
        if let session = sessionStore.loadLastOpened() {
            if let folderPath = session.folderPath, isExistingDirectory(atPath: folderPath) {
                openFolder(url: URL(fileURLWithPath: folderPath))
            } else {
                model.restoreSession(session)
            }
        }
        sessionController.start(model: model, store: sessionStore)
    }

    /// Whether `path` still names a directory. `isDirectory` is checked rather than
    /// mere existence: the recorded path may have been replaced by a *file* since
    /// the last launch, and opening that as a project root would leave the tree, the
    /// watcher and every git model pointed at something that cannot be listed.
    private func isExistingDirectory(atPath path: String) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    // MARK: - Local History

    /// Open the Local History window on `url`, or retarget the one already open.
    ///
    /// Both entry points come here — **File ▸ Local History…** (⌘⇧H, on the
    /// selected tab) and a project-tree file row's "Local History" item — because
    /// there is one window and one browser model behind it, so a second open path
    /// would be a second way to leave the two disagreeing about which file is
    /// being shown.
    ///
    /// The listing is started *before* the window is shown, which costs nothing
    /// (it is one directory read on a background queue) and means a window that
    /// was already open never shows the previous file's revisions for a frame.
    /// A file outside the project root — or no root at all — leaves the model
    /// empty and the window says so: the store is keyed by a path under the root,
    /// so there is nothing to list, and that is a fact about the file rather than
    /// a failure to report.
    private func showLocalHistory(for url: URL) {
        localHistoryBrowser.open(file: url, root: model.projectRoot)
        let currentText = { [self] in currentTextForLocalHistory(of: url) }
        let content = LocalHistoryView(
            browser: localHistoryBrowser, settings: settings, currentText: currentText,
            onRestore: { [self] plan in restoreFromLocalHistory(plan) }
        )
        // Coming back to this window is the moment its "current" side may have
        // moved: the buffer lives in another window, and the Restore button's
        // enablement is computed from it. See
        // `LocalHistoryBrowserModel.refreshSelection(currentText:)`.
        localHistoryWindows.show(title: "Local History — \(url.lastPathComponent)", content: content) {
            localHistoryBrowser.refreshSelection(currentText: currentText())
        }
    }

    /// What the file `url` names holds *right now* — the "new" side of the
    /// window's diff and the text a restore displaces.
    ///
    /// **The buffer wins when a tab holds the file**, and that is the whole point
    /// of asking at call time rather than reading disk once: a dirty tab holds
    /// text that exists nowhere else, and diffing a revision against the stale
    /// disk copy would show the user changes they already made. With no tab on
    /// it, the disk copy is what the file is.
    ///
    /// **The two halves are answered differently, because they cost differently.**
    /// The buffer half stays synchronous and travels as a value: it is
    /// `WorkspaceModel` state, this method is already on the main actor, and
    /// reading it is a dictionary lookup — deferring that would buy nothing and
    /// cost a hop. The disk half is a file read, which has no business on the main
    /// thread at all, so it travels as a closure the browser model resolves off it,
    /// inside the hop that call already makes for the revision's content and the
    /// diff. Same call, same ceiling, same fallback; one fewer main-thread read —
    /// and a deselection, which takes no hop, now costs no read whatsoever.
    ///
    /// The disk read goes through `readTextIfNotBinary` under the same 1 MiB
    /// ceiling the capture side uses, so the window cannot be made to load a
    /// gigabyte of binary into a diff; an unreadable, oversized or binary file
    /// answers the empty string, which diffs as "everything in this revision was
    /// added" rather than as an error — the feature has no error state.
    private func currentTextForLocalHistory(of url: URL) -> LocalHistoryCurrentText {
        if let id = model.fileID(forURL: url), let text = model.text(for: id) { return .text(text) }
        let fileService = self.fileService
        return .deferred {
            let disk = try? fileService.readTextIfNotBinary(
                url: url,
                maxBytes: ProjectSearchModel.defaultMaxFileBytes
            )
            return disk ?? ""
        }
    }

    /// Carry out the restore `LocalHistoryBrowserModel` planned: open a tab if
    /// none holds the file, snapshot what the buffer holds now, then replace it.
    ///
    /// **Three steps, in this order, and the order is the design.**
    ///
    /// 1. The tab. A restore is a *buffer* edit — Local History never writes the
    ///    worktree — so a file with no tab open has nothing to edit; `model.open`
    ///    re-selects an existing tab rather than duplicating it, so this is also
    ///    the right call when one is already there. A file that cannot be read
    ///    beeps and stops: there is nothing to restore *into*.
    /// 2. The capture, under `.restore`, of the text the replacement is about to
    ///    displace — so a restore is itself reversible from history as well as by
    ///    one ⌘Z. It is read back off the buffer **after** the open, not taken
    ///    from the plan: the plan's `captureText` is what the *window* was
    ///    showing, which for a file with no tab is a `readTextIfNotBinary` read
    ///    under a 1 MiB ceiling and therefore the empty string for a file that
    ///    has since grown past it — while `model.open` has no ceiling and loads
    ///    the whole thing. Storing the plan's answer would file an empty
    ///    `Before Restore` revision for a buffer holding a megabyte of text, which
    ///    is the one place in this feature a capture could *lose* what it exists
    ///    to keep. `applyRestore` displaces `model.text(for:)`, so that is the
    ///    text this snapshots.
    /// 3. The replacement, through `SaveTransformController` — the one place in
    ///    this app that rewrites a buffer through the live text view, so the
    ///    restore is a single undoable step with a single change notification and
    ///    every reader sees an ordinary edit.
    ///
    /// The tab is left **dirty**: the ordinary save funnel puts the restored text
    /// on disk when the user saves or the autosave fires, which is what keeps this
    /// feature a reader that takes no writer gate.
    ///
    /// **Step 0 is the project check, and it is what makes the window's survival
    /// of a folder switch safe.** The window is deliberately long-lived — it is
    /// retargeted, not recreated, and `LocalHistoryView` says outright that it
    /// outlives a folder switch, which costs nothing while everything it does is
    /// read-only: the diff asks `currentText` at the moment it needs it. Restore
    /// is the one thing in it that is *not* read-only, and a plan made under the
    /// previous root names a file that is no longer in the project. Carrying it
    /// out would put that file into `WorkspaceModel` through `model.open` — the
    /// exact hazard `viewDefinitionOutsideProject` exists to avoid, since the
    /// autosave, the session snapshot and ⌘S all then apply to a file outside the
    /// opened folder — and would file the `.restore` capture under `plan.root`
    /// while every later save of that buffer keys to nothing, so the restore
    /// would be the one edit in the file with no history behind it. So it beeps
    /// and stops, like the two refusals below. `isCurrentProjectRoot` is the
    /// model's own canonical comparison, which is the rule for "same folder?"
    /// everywhere else in this file.
    ///
    /// **The two refusals are asked before the open, for a file with a tab and for
    /// a file without one.** They judge the text a restore would displace, and
    /// `model.open` is not free of consequence: it selects the tab — and, for a
    /// file no tab holds, adds one. Asking only afterwards turns a click that does
    /// nothing into a click that pulls the editor onto another file and beeps,
    /// which is the armed-button-whose-click-does-nothing the published plan
    /// exists to remove, wearing a side effect. Both answers are in hand before
    /// the open: `localHistoryTextToDisplace(_:)` reads the buffer when a tab
    /// holds the file and the same unbounded `read` the open itself makes when
    /// none does. The refusal is nonetheless re-asked *after* the open, because
    /// the open is what the capture and the replacement actually act on and the
    /// file can move between the two reads; the pre-open ask is there to keep the
    /// refusal from costing a tab, not to decide it.
    private func restoreFromLocalHistory(_ plan: LocalHistoryRestore) {
        guard model.isCurrentProjectRoot(plan.root) else {
            PlatformFeedback.warning()
            return
        }
        if let known = localHistoryTextToDisplace(plan.fileURL),
           localHistoryRestoreRefused(displacing: known, plan) {
            PlatformFeedback.warning()
            return
        }
        guard let file = try? model.open(url: plan.fileURL) else {
            PlatformFeedback.warning()
            return
        }
        let displaced = model.text(for: file.id) ?? plan.captureText
        guard !localHistoryRestoreRefused(displacing: displaced, plan) else {
            PlatformFeedback.warning()
            return
        }
        localHistory.captureBuffers(
            event: LocalHistoryRestore.event,
            urls: [plan.fileURL],
            root: plan.root,
            texts: [plan.fileURL: displaced]
        )
        saveTransform.applyRestore(plan.text, to: file.id)
    }

    /// The text a restore of `url` would displace, answered **without opening
    /// anything** — or `nil` when nothing can answer it, which is a file the open
    /// is about to fail on anyway.
    ///
    /// The buffer wins when a tab holds the file, for the reason
    /// `currentTextForLocalHistory` spells: a dirty tab holds text that exists
    /// nowhere else. With no tab on it, this is the *same* `read` the open makes
    /// a moment later — unbounded on purpose, and deliberately not the window's
    /// `readTextIfNotBinary` under `ProjectSearchModel.defaultMaxFileBytes`. That
    /// ceiling is `LocalHistoryPolicy.maxContentBytes` to the byte, so a capped
    /// read answers the empty string for exactly the file the policy is about to
    /// refuse as `tooLarge`, and the preflight would wave through the one case it
    /// most needs to catch: a file that had history when it was small, has since
    /// grown past the ceiling, and would otherwise be loaded whole into a new tab
    /// only to be refused.
    ///
    /// This does mean the successful restore of a file no tab holds reads it
    /// twice. That is bounded by the ceiling the policy enforces — anything above
    /// it is refused here and never opened at all, so the duplicated read is at
    /// most 1 MiB — and it is paid once per explicit Restore click.
    private func localHistoryTextToDisplace(_ url: URL) -> String? {
        if let id = model.fileID(forURL: url) { return model.text(for: id) }
        return try? fileService.read(url: url)
    }

    /// Whether the planned restore must not happen against `displaced` — the text
    /// it would replace. Both refusals answer the same way, beep and stop, so they
    /// are one question asked in one place.
    ///
    /// **The plan's sameness question, re-asked against the text actually in
    /// hand.** `LocalHistoryBrowserModel.restorePlan` answers it against the text
    /// the window resolved when the selection landed, refreshed when the window
    /// becomes key — and a buffer can move without either happening: an
    /// FSEvents-driven `reloadFromDisk`, a `resyncOpenTabs` after an operation or
    /// a rename all rewrite it while this window stays key. Left alone, a plan
    /// gone stale that way re-creates the armed button whose click does nothing,
    /// and adds a side effect to it: `applyRestore` bails at its own `NSString`
    /// guard, but the capture before it has already filed a `.restore` revision of
    /// bytes nothing displaced — `LocalHistoryStore.capture` dedups against the
    /// *newest* revision only, so a mid-list revision's bytes are stored again.
    /// The comparison is `NSString`'s for the reason spelled on `restorePlan`:
    /// this feature identifies a revision by SHA-256 over UTF-8 bytes, and Swift's
    /// `==` would call two spellings of one word equal and refuse the one restore
    /// that does change bytes.
    ///
    /// **A restore that cannot be captured does not happen.** The capture is what
    /// makes a restore reversible, and the policy can refuse it — a file that had
    /// history when it was small and has since grown past `maxContentBytes` is
    /// captured by nothing, while `model.open` has no ceiling and loads the whole
    /// of it. Going ahead there would replace megabytes the store is about to
    /// decline to hold, leaving one ⌘Z as the only copy — the feature destroying
    /// exactly what it exists to keep. It is also the case the window renders
    /// least honestly: the same ceiling makes `currentTextForLocalHistory` answer
    /// the empty string, so the diff showed the revision as wholly added.
    /// `latestHash: nil` asks the one question that matters here — *may* these
    /// bytes be stored — rather than whether they would be deduplicated, which is
    /// a skip that loses nothing.
    private func localHistoryRestoreRefused(displacing displaced: String, _ plan: LocalHistoryRestore) -> Bool {
        if (displaced as NSString).isEqual(to: plan.text) { return true }
        return localHistory.store.policy.capture(of: displaced, relativePath: plan.relativePath, latestHash: nil).hash == nil
    }

    /// The selected tab's url, or `nil` — what **File ▸ Local History…** acts on,
    /// and what disables it.
    ///
    /// An untitled buffer has no path, so it has no history and can have none:
    /// every skip rule in this feature starts with "no url".
    private var localHistoryTargetURL: URL? {
        model.openFiles.first { $0.id == model.selectedID }?.url
    }

    // MARK: - Find in Files

    /// Show the project-wide search window (⌘⇧F), or focus the one already open.
    ///
    /// The root is passed as a *closure* rather than a value: the window outlives a
    /// folder switch, so reading `model.projectRoot` at search time is what keeps a
    /// stale root from walking the previous project.
    private func openProjectSearch() {
        let content = ProjectSearchView(
            model: projectSearch,
            settings: settings,
            root: { model.projectRoot },
            onActivate: { url, range in activateSearchMatch(url: url, range: range) },
            onReplaceAll: { template, origin in
                await replaceAllInProject(template: template, originGeneration: origin)
            }
        )
        projectSearchWindows.show(content: content)
    }

    /// Open the file a search result names and select the match inside it.
    ///
    /// The open goes through the ordinary `openFile(url:)` path (so an already-open
    /// tab is re-selected rather than duplicated), and the range is handed to the
    /// editor through `reveal` — the tab's `CodeEditorView` may not exist yet, and
    /// the update that creates it is the one that installs the file's contents.
    /// A file that failed to open beeps in `openFile` and resolves to no tab, so
    /// nothing is revealed.
    ///
    /// Also the destination of **Go to Definition** (⌘-click / ⌃⌘J), which names a
    /// declaration's file and name range instead of a search hit: the two want the
    /// exact same three steps, and sharing them is what keeps a jump into the file
    /// already being edited on the same code path as a jump across the project.
    private func activateSearchMatch(url: URL, range: NSRange) {
        openFile(url: url)
        guard let id = model.fileID(forURL: url) else { return }
        reveal.reveal(fileID: id, range: range)
    }

    // MARK: - Go to definition

    /// Show a declaration that lives **outside** the opened folder in a separate,
    /// read-only source viewer window (D3) — the other half of
    /// `activateSearchMatch(url:range:)`, which handles every target inside it.
    ///
    /// A jump into an SDK `.swiftinterface` or a dependency checkout deliberately
    /// does *not* go through `openFile(url:)`: that would put a file the user
    /// cannot meaningfully edit into `WorkspaceModel`, where the autosave gate, the
    /// session snapshot and ⌘S all apply to it. The viewer has no model behind it,
    /// so a semantic jump outside the project cannot become a write outside the
    /// project.
    ///
    /// An unreadable target (the path moved, permission denied, binary or oversize)
    /// beeps and opens nothing — exactly what a ⌘-click that resolved nothing does,
    /// because from the user's side it is the same event: the jump did not happen.
    private func viewDefinitionOutsideProject(url: URL, range: NSRange) {
        guard sourceViewers.open(fileURL: url, range: range, settings: settings) else {
            PlatformFeedback.warning()
            return
        }
    }

    /// The Find menu's "Go to Definition" (⌃⌘J): ask the focused editor to jump
    /// from wherever its caret is.
    ///
    /// Routed through the first responder rather than through a window-scoped
    /// state object (the `EditorSearchState` shape): this command carries no state
    /// at all — no query, no toggles, nothing to survive a tab switch — so a
    /// published object for it would be an empty mailbox between the menu and the
    /// one view that can answer. The responder chain already names that view.
    /// Anything else focused (the project tree, the terminal, a text field) has no
    /// definition to go to and beeps.
    private func goToDefinitionAtCaret() {
        guard let editor = NSApp.keyWindow?.firstResponder as? EditorTextView else {
            PlatformFeedback.warning()
            return
        }
        editor.goToDefinitionAtCaret()
    }

    // MARK: - Find usages / rename

    /// The Find menu's "Find Usages" (⌃⌘U): ask the focused editor about the
    /// identifier under its caret.
    ///
    /// Routed through the first responder for `goToDefinitionAtCaret()`'s reason
    /// — the command carries no state, and the responder chain already names the
    /// one view that can answer. Anything else focused has no caret in code and
    /// beeps.
    private func findUsagesAtCaret() {
        guard let editor = NSApp.keyWindow?.firstResponder as? EditorTextView else {
            PlatformFeedback.warning()
            return
        }
        editor.findUsagesAtCaret()
    }

    /// The Find menu's "Rename…" (⌃⌘R): ask the focused editor about the
    /// identifier under its caret. Routed and refused exactly as
    /// `findUsagesAtCaret()` is.
    private func renameAtCaret() {
        guard let editor = NSApp.keyWindow?.firstResponder as? EditorTextView else {
            PlatformFeedback.warning()
            return
        }
        editor.renameAtCaret()
    }

    /// Run a usages query and show the panel holding its answer.
    ///
    /// The panel is *shown* rather than toggled: this is the answer to a command
    /// the user just invoked, and a ⌃⌘U that hid the results because they
    /// happened to be on screen would be the opposite of what was asked.
    ///
    /// The request generation is **reserved** synchronously, before the `Task`
    /// hop, and handed back to the model — the generation-token rule, applied
    /// here because unstructured tasks are not guaranteed to start in creation
    /// order, so two quick ⌃⌘U presses must settle on the later question
    /// whichever task runs first. Reserved rather than merely read: two presses
    /// that read the same token would be ordered by whichever task started first,
    /// which is the thing this is here to stop. The identifier is reserved along
    /// with the token so a rename landing in the same window can invalidate a
    /// question about the name it removed before that question has run
    /// (`FindUsagesModel.clearIfNaming`).
    private func findUsages(_ request: UsagesRequest) {
        bottomPanel = .usages
        let root = model.projectRoot
        let generation = usages.prepareForQuery(for: request.identifier)
        Task { await usages.find(request, root: root, request: generation) }
    }

    /// Open the file a usages row names and reveal the occurrence — when it is
    /// still there.
    ///
    /// The open goes through `activateSearchMatch`'s three steps, but the range
    /// is not the row's own: a row is a position in a text that was read once,
    /// and the buffer the click lands in may have been typed in, rewritten or
    /// renamed since. `UsageResult.revealRange(naming:in:)` is asked against the
    /// text as it *now* is, and a row that no longer holds its identifier
    /// degrades to opening the file with nothing selected — never a crash on an
    /// out-of-bounds range, never a confident selection of a span that is now
    /// something else.
    ///
    /// A row **outside the opened folder that no tab already holds** goes to the
    /// read-only viewer instead,
    /// for `viewDefinitionOutsideProject`'s reason and D3's: a language server
    /// answers `textDocument/references` with every reference it resolved, and an
    /// SDK header or a dependency checkout is a perfectly ordinary one. Opening it
    /// through `openFile` would put a file the user did not open a project for
    /// into `WorkspaceModel`, where the autosave gate, the session snapshot and ⌘S
    /// all then apply to it — the very thing a semantic *jump* outside the project
    /// is prevented from doing, arriving through the panel instead. The viewer
    /// takes the row's range as it stands: it reads the file when it opens the
    /// window and is structurally read-only, so nothing can type under the range
    /// the way an editor tab can. The one gap that leaves is a *reused* window —
    /// `SourceViewerWindowController` keeps one viewer per file and re-reveals
    /// into text it read when that window first opened, so a file changed on disk
    /// since can be scrolled to the wrong span. It is a stated limit rather than
    /// a check because the reveal is clamped to the shown text (no crash), the
    /// files this branch reaches are SDK sources and dependency checkouts that do
    /// not change while a window onto them is open, and closing it means the
    /// viewer handing its text back out — the one thing "structurally read-only"
    /// is easiest to keep true by not doing.
    ///
    /// **A file a tab already holds never takes that branch, wherever it lives.**
    /// The reason above is entirely about what `openFile` would *add* to
    /// `WorkspaceModel`, and there is nothing to add to a file already in it: the
    /// user opened it themselves, the autosave gate and ⌘S already apply, and
    /// showing a second, read-only window onto a file whose editable tab is on
    /// screen is the wrong answer to a click. It is also the *unsafe* one — the
    /// viewer reads the file from disk while a row is a position in a buffer, so
    /// a dirty out-of-root tab would have the row's range revealed against text
    /// it was never computed for, which is exactly the confident reveal of a
    /// wrong span `revealRange(naming:in:)` exists to refuse. Both paths out of
    /// this are ordinary: Find Usages always scans the requesting file, even one
    /// opened from outside the root entirely (`FindUsagesModel.scanTextually`),
    /// and a semantic answer maps every location against the open buffers.
    private func activateUsage(_ row: UsageResult) {
        if let root = model.projectRoot,
           !isInsideProject(row.fileURL, root: root),
           model.fileID(forURL: row.fileURL) == nil {
            viewDefinitionOutsideProject(url: row.fileURL, range: row.range)
            return
        }
        openFile(url: row.fileURL)
        guard let id = model.fileID(forURL: row.fileURL),
              let text = model.openFiles.first(where: { $0.id == id })?.text
        else { return }
        guard let range = row.revealRange(naming: usages.identifier, in: text as NSString) else {
            return
        }
        reveal.reveal(fileID: id, range: range)
    }

    /// Rename the symbol the editor resolved: ask, then write.
    ///
    /// Three refusals happen before anything is shown, and every one of them is a
    /// beep and nothing more — the fallback vocabulary of this layer, where a
    /// language server's absence is never an error the user is made to read
    /// (decision 4). No project root, no file behind the buffer, or a language
    /// `canRename` declines: the dialog does not appear at all, because a name
    /// prompt whose OK cannot do anything is worse than no prompt. A fourth,
    /// `revertInFlight()`, joins them and is the one that speaks: a raised writer
    /// gate is the same alert every other gated operation gives.
    ///
    /// `canRename` is a policy question — it starts no server and probes none — so
    /// asking it before the sheet costs one actor hop, not a launch.
    private func renameSymbol(_ request: UsagesRequest) {
        guard let root = model.projectRoot,
              let fileURL = request.fileURL,
              let language = SyntaxLanguage(forFileName: fileURL.lastPathComponent)
        else {
            PlatformFeedback.warning()
            return
        }
        Task {
            guard await intelligence.canRename(language) else {
                PlatformFeedback.warning()
                return
            }
            // The writer gate, asked *before* the dialog rather than only after
            // the round trip. `applyRename` asks it again and must — that check
            // closes the window the modal and the server open — but asking only
            // there makes the user name the symbol and wait out the server before
            // being told the command was never going to run. Every other gated
            // operation refuses before it costs anything, and this one costs the
            // most.
            guard !revertInFlight() else { return }
            guard let newName = promptForNewName(replacing: request.identifier) else { return }
            // **Read before the request goes out, never after it comes back.**
            // This map is the baseline every *other* file's plan is built
            // against, so it has to be the text the server computed its answer
            // from. A server processes notifications in order, so everything
            // sent by now is text it will have seen by the time it reads the
            // rename request. Reading it *after* the round trip instead admits
            // the one text that is definitionally not that: a background tab
            // typed in while the request was in flight, pushed by
            // `LSPDocumentSyncController`'s 400 ms debounce after the server had
            // already answered. Planning against that text would map the
            // server's `(line, character)` coordinates onto bytes it never saw
            // and then record those same bytes as `expectedText`, so
            // `RenameFilePlan.holds` would pass by construction and the rename
            // would silently rewrite the wrong spans.
            //
            // Snapshotting early can only err the safe way round: if a push
            // lands between here and the server reading the request, this map is
            // *older* than the server's baseline, `holds` fails against the live
            // buffer, and the command refuses instead of writing.
            var serverTexts: [String: String] = [:]
            for (url, text) in lspWorkspace.lastSentTexts() { serverTexts[Self.canonicalKey(url)] = text }
            // The request is a *read*, so it runs outside the writer bracket: it
            // can take as long as the server takes, and holding autosave and the
            // git gate down for a round trip that may time out would stall every
            // other writer for a rename that has not been decided on yet.
            let answer = await intelligence.renameEdits(
                for: RenameRequest(
                    identifier: request.identifier,
                    fileURL: request.fileURL,
                    offset: request.offset,
                    text: request.text,
                    newName: newName
                )
            )
            // A server that advertises no rename, one that answered nothing, and
            // one whose answer touches no file are the same outcome here: there is
            // nothing to write, and the bracket must not be raised for it.
            guard let answer, !answer.edit.isEmpty else {
                PlatformFeedback.warning()
                return
            }
            await applyRename(answer, for: request, root: root, serverTexts: serverTexts)
        }
    }

    /// The name dialog: prefilled with the old name, validated on every keystroke
    /// by the Core rule that owns what a new name may be (`RenameNameRule`).
    ///
    /// Both reasons are inline in the dialog rather than an alert after OK,
    /// because both are knowable while the user types.
    private func promptForNewName(replacing oldName: String) -> String? {
        FilePanels.promptName(
            title: "Rename “\(oldName)”",
            defaultValue: oldName,
            validator: { RenameNameRule.rejection(of: $0, replacing: oldName) }
        )
    }

    /// Apply a server's rename — **the seventh gated worktree operation**.
    ///
    /// The plan is built *before* the bracket: every refusal
    /// (`RenameRefusal`) is a question about the answer in hand and the texts in
    /// hand, so it costs nothing and stops nothing, and a rename that is going to
    /// be refused must never suspend autosave or capture a revision.
    ///
    /// Inside the bracket the order is capture, verify, write — and it is that way
    /// round on purpose (decision 6). The capture is the **first `await` inside the
    /// bracket**, which is what makes every "Before Rename" revision pre-operation
    /// by construction; verification then happens against the texts as they are at
    /// that moment, and an abort leaves behind one harmless extra snapshot that
    /// retention prunes. The reverse order — verify, then capture — would leave a
    /// window between the two in which the thing verified could change.
    ///
    /// The writes are `RenameEditPlan.apply`'s: files no tab holds go to disk,
    /// files a tab holds come back as buffer plans and are applied through
    /// `SaveTransformController` — the displayed tab as one undoable step, every
    /// other tab through `WorkspaceModel.replaceText` at the cost of its undo stack
    /// (decision 5).
    ///
    /// **Every file is planned against the text the *server* was given, and no
    /// file against a live buffer.** The dialog is modal, but the round trip that
    /// follows it is not: the editor is live for however long the server takes,
    /// and a keystroke in that window moves every offset after it. Planning
    /// against the current buffer would map the server's `(line, character)`
    /// coordinates onto text they were never computed for and then record
    /// whatever bytes happen to sit there as `expectedText` — a verification that
    /// passes by construction, and a rename that silently replaces the wrong
    /// spans. Planning against what the server was told instead makes the
    /// mismatch visible: `apply` re-reads the live buffer, `holds` fails, and the
    /// command says the file changed and writes nothing.
    ///
    /// The requesting file's copy of that text is `request.text` — definitionally
    /// what `LSPIntelligenceProvider` prepared the document with. Every *other*
    /// file is one nobody prepared, and its copy is `serverTexts` — the caller's
    /// `LSPWorkspace.lastSentTexts()` snapshot, **taken before the request went
    /// out and handed down here** rather than read on arrival, because only the
    /// earlier read is the text the server answered against: a background tab
    /// typed in during the round trip is pushed by `LSPDocumentSyncController`'s
    /// 400 ms debounce *after* the answer was computed, and a map read here would
    /// carry it. `LSPWorkspace.stillHolds` cannot see that either — it compares
    /// the *prepared* document's version and nothing else — so the two halves are
    /// closed together, or the one left open is the one with no undo behind it
    /// (decision 5).
    ///
    /// A file the map does not name is a file **no server holds open**, so the
    /// server answered about the bytes on disk: the fallback is `FileService`,
    /// never `WorkspaceModel`. A dirty tab over such a file therefore ends in the
    /// stale refusal below rather than in a write — which is the honest answer,
    /// because the edits were computed for text that tab has already replaced.
    ///
    /// **It refuses outright once the project root has moved.** `root` is the
    /// folder that was open when the command was invoked; the round trip in front
    /// of this is a *read* outside the bracket, and `openFolder(url:)` refuses only
    /// while the gate is up, so nothing stops an Open Folder in that window. Every
    /// other async model on this branch orders across that switch with a token —
    /// `FindUsagesModel` grew `rootGeneration` for it — and this command has more
    /// to lose than they do: the plan is built against the *old* root while
    /// `captureBeforeOperation` is handed the *new* one, and `LocalHistoryModel`
    /// drops every target outside the root it is given. The writes would still
    /// land, in a project the user has left, with none of the "Before Rename"
    /// revisions the failure alert promises. So the switch ends the command, and
    /// says nothing: the user has moved on.
    ///
    /// It refuses outright while another writer holds the gate too, through
    /// `revertInFlight()` — the same alert every other gated operation gives,
    /// because a rename arriving mid-`git checkout` is refused for the same reason
    /// ⌘S is and deserves the same explanation.
    private func applyRename(
        _ answer: RenameAnswer, for request: UsagesRequest, root: URL, serverTexts: [String: String]
    ) async {
        guard model.isCurrentProjectRoot(root) else { return }
        guard !revertInFlight() else { return }
        let oldName = request.identifier
        let fileService = FileService()
        let requestKey = request.fileURL.map(Self.canonicalKey)
        let requestText = request.text
        let maxBytes = LSPIntelligenceProvider.maximumTargetFileBytes
        let edit = answer.edit
        // **Off the main thread**, the `ProjectSearchModel.replaceAll` shape and
        // for its reason: building the plan resolves symlinks three times and
        // reads one file per document the server named, and a server naming a
        // widely-used type names hundreds — which is the ordinary case for the
        // command this is, not the pathological one. Run here it would freeze the
        // window for the whole read pass with nothing on screen to say why.
        // Nothing is written in this pass and no gate is up yet, so the hop costs
        // only the two re-checks below.
        //
        // `readTextIfNotBinary` rather than `read`: this is the one file read in
        // the app that a *server* chooses the targets of, and an unbounded `read`
        // of a binary file it happens to name would load the whole thing into
        // memory to look for identifiers that cannot be there.
        //
        // The cap is `LSPIntelligenceProvider.maximumTargetFileBytes` — the one
        // this layer already uses for a file whose path a *server* named — and
        // deliberately not the project search's 1 MiB. Declining here is a
        // `RenameRefusal.unreadable`, i.e. the *whole* rename refuses rather than
        // silently skipping a file, so the grep cap would make ⌃⌘R permanently
        // impossible for any symbol that also appears in a large generated source
        // file — and report it as a file that "could not be read", which is not
        // what happened. The asymmetry is the other half of the argument: the
        // requesting buffer and every text the server was sent bypass the cap
        // entirely, so at 1 MiB whether a rename works would depend on which tabs
        // happen to be open. Binary content is still declined by content, which is
        // what this read is actually protecting against.
        let made = await Self.offMain {
            RenameEditPlan.make(
                from: edit,
                root: root,
                texts: { url in
                    let key = Self.canonicalKey(url)
                    if key == requestKey { return requestText }
                    if let sent = serverTexts[key] { return sent }
                    return (try? fileService.readTextIfNotBinary(url: url, maxBytes: maxBytes))
                        ?? nil
                }
            )
        }
        // Re-asked after the hop, not merely repeated: the folder can be switched
        // and another writer can raise the gate while the read pass runs, and a
        // plan built for a project the window has left must not be applied to the
        // one it is showing now.
        guard model.isCurrentProjectRoot(root) else { return }
        guard !revertInFlight() else { return }
        let plan: RenameEditPlan
        switch made {
        case .success(let made):
            guard !made.isEmpty else {
                PlatformFeedback.warning()
                return
            }
            plan = made
        case .failure(let refusal):
            PlatformFeedback.warning()
            PlatformAlert.presentMessage(title: "Rename not applied", message: refusal.reason)
            return
        }

        autosave.suspend()
        localChanges.beginRevert()
        // No `defer`: the two exits below lower the gates by hand, the commit
        // path's rule and for its reason — `PlatformAlert.presentMessage` is
        // `NSAlert.runModal()`, a nested run loop, and `AutosaveController
        // .flushNow()` bails while `suspendCount > 0`, so a ⌘Q while a rename
        // alert sits on screen would skip the termination flush for every dirty
        // buffer. The two `await`s below (the capture and the write pass) add no
        // third way out — neither is cancellable and both resume — so the two
        // exits are still the only paths out and a `defer` would buy nothing but
        // the ordering hazard.
        // Pre-empting a write the user cannot see all of: a rename changes files
        // no tab holds, and unlike a git operation nothing can put them back. The
        // targets are the plan's own files, which is also the whole set the write
        // below touches — though not necessarily the whole set *captured*:
        // `LocalHistoryPolicy.maxPreOperationFiles` caps the disk half and binary
        // and oversize files are skipped, so this is a safety net and not a
        // guarantee, which is why the incomplete-write alert below does not
        // promise one. First `await` in the body, ahead of every write.
        await captureBeforeOperation(
            .rename,
            buffers: openBufferTexts(),
            targets: plan.fileURLs
        )
        // Re-read *now*: the buffers may have been typed in and the disk written
        // to while the dialog was up and the server was thinking.
        let current = bufferTextsByCanonicalPath()
        // Off the main thread again, for the read pass's reason one step further
        // on: this is where every remaining file is re-read, vouched for and
        // written. The verification stays all-or-nothing inside the hop — nothing
        // is written until every file's text has been checked against the plan —
        // and the buffer snapshot it verifies against is the one taken just above,
        // on the main actor, so what the hop decides about a tab is decided about
        // a text that existed. A tab typed into *during* the hop is caught below
        // rather than clobbered, the same rule Replace All applies to the same
        // window.
        let outcome = await Self.offMain {
            plan.apply(
                bufferText: { url in current[Self.canonicalKey(url)] },
                fileService: fileService
            )
        }
        let application: RenameApplication
        switch outcome {
        case .applied(let applied):
            application = applied
        case .stale(let url):
            // Nothing was written — the verification is what makes that true, and
            // it is the one refusal worth an alert rather than a beep: the user
            // asked for a write, the write did not happen, and the reason is
            // something they can act on. Gates down *before* the modal.
            localChanges.endRevert()
            autosave.resume()
            PlatformFeedback.warning()
            PlatformAlert.presentMessage(
                title: "Rename not applied",
                message: "\(url.lastPathComponent) changed since the language server answered, "
                    + "so nothing was renamed. Try again."
            )
            return
        }

        // The buffer half, and the resync every worktree rewrite runs.
        //
        // **Every tab on the file, not the first one `fileID(forURL:)` finds.**
        // Two tabs may legitimately show one file — opened once by path, once
        // through a symlink — and `bufferTextsByCanonicalPath` collapses them to
        // the single text the plan was verified against. Rewriting only one of
        // them leaves the other holding the old name *and clean*, so nothing
        // flags it and the next save through it writes the pre-rename text back
        // over the file: the rename silently undone in that file, with no beep
        // and no alert. The plan's edits are one file's, so applying them to
        // every tab on that file is the same write, not a repeated one.
        //
        // **And only to a tab still holding the verified text.** That is both the
        // check that makes the collapse safe (two tabs whose texts differ were
        // not both vouched for, and replacing the unvouched one wholesale would
        // discard edits nobody asked to lose) and the one that closes the write
        // pass's hop: a tab typed into while the disk half ran is skipped and
        // reported, never overwritten from a text it no longer holds — Replace
        // All's rule for the identical window.
        //
        // **The sameness question is `NSString`'s, not Swift's.** The plan was
        // verified against exact bytes and its edits are UTF-16 offsets measured
        // against them, while Swift's `String` equality is *canonical
        // equivalence*: it answers `true` for a decomposed and a precomposed
        // spelling of the same characters, which have different `NSString`
        // lengths. Vouching for a tab holding a differently-encoded spelling
        // would apply offsets measured against one string to another — misplaced
        // edits, or an out-of-range exception — which is the same hazard the
        // restore path (`SaveTransformController`) and the usages reveal already
        // name. A key with no verified text still matches nothing and the file is
        // reported unrewritten, exactly as before.
        var rewrittenTabs: [(id: UUID, url: URL)] = []
        var unrewritten: [URL] = []
        for rewrite in application.bufferRewrites {
            let key = Self.canonicalKey(rewrite.fileURL)
            let verified = current[key] as NSString?
            var matched = false
            for file in model.openFiles {
                guard file.url.map(Self.canonicalKey) == key,
                      verified?.isEqual(to: file.text) == true else { continue }
                saveTransform.applyRename(rewrite.plan, to: file.id)
                rewrittenTabs.append((file.id, rewrite.fileURL))
                matched = true
            }
            if !matched { unrewritten.append(rewrite.fileURL) }
        }
        refreshLocalChanges()
        model.bumpTreeRevision()
        // The files with no tab changed on disk and their symbols are stale until
        // a stamp-gated refresh re-extracts them…
        notifyIndexOfProjectFileChanges()
        // …and a file that *does* have a tab was replaced in the buffer, which is
        // exactly what that refresh declines to re-extract. Same resync a
        // project-wide Replace All runs, for its reason.
        for tab in rewrittenTabs {
            reindexReloadedBuffer(id: tab.id, url: tab.url)
        }
        // Decision 7: the panel is cleared rather than re-run when it is showing
        // the name that no longer exists. Re-running would spend a walk or a round
        // trip on a question nobody asked, and every row it holds now names a
        // string this rename just removed.
        usages.clearIfNaming(oldName)
        // Every write and every resync is done: gates down before the one modal
        // this path can still present, for the reason stated above the bracket.
        localChanges.endRevert()
        autosave.resume()
        if !unrewritten.isEmpty, application.writeFailure == nil {
            // A tab moved under the write pass, so its file is the one thing the
            // plan vouched for and did not change. Said rather than swallowed for
            // the write-failure alert's reason: the user asked for a rename, part
            // of it did not happen, and which part is something they can act on.
            PlatformFeedback.warning()
            PlatformAlert.presentMessage(
                title: "Rename incomplete",
                message: "\(unrewritten.map(\.lastPathComponent).joined(separator: ", ")) "
                    + "changed while the rename was being written, so "
                    + (unrewritten.count == 1 ? "it still holds" : "they still hold")
                    + " the old name. Every other file was renamed."
            )
        }
        if let failed = application.writeFailure {
            // Deliberately *not* "the other files were renamed": `apply` stops at
            // the first write that throws, so the files it had not reached yet
            // still hold the old name, while every open buffer above has been
            // rewritten regardless. And the pre-operation capture is neither
            // complete nor guaranteed — `LocalHistoryModel` reads at most
            // `LocalHistoryPolicy.maxPreOperationFiles` from disk and skips
            // binary and oversize files silently — so the alert points at Local
            // History without promising what is in it. Naming a state the user
            // can check beats naming one that sounds tidier and may be false.
            //
            // "the open editors do not" is true of every buffer this pass
            // rewrote and false of the ones it skipped, so a run that both failed
            // a write *and* had a tab move under it says which tabs those are
            // rather than asserting a consistency they do not have. The skipped
            // list is reported here instead of in its own alert above for that
            // reason: one incomplete rename is one sentence about one state.
            let skipped = unrewritten.isEmpty
                ? ""
                : " \(unrewritten.map(\.lastPathComponent).joined(separator: ", ")) "
                    + "changed while the rename was being written, so "
                    + (unrewritten.count == 1 ? "that editor" : "those editors")
                    + " still hold\(unrewritten.count == 1 ? "s" : "") the old name too."
            PlatformAlert.presentMessage(
                title: "Rename incomplete",
                message: "\(failed.lastPathComponent) could not be written, so the rename stopped "
                    + "there: some files still hold the old name and the open editors do not."
                    + skipped
                    + " Local History may hold a “Before Rename” revision of the files "
                    + "that changed."
            )
        }
    }

    /// Every open buffer's text, keyed by its file's canonical path.
    ///
    /// Keyed canonically rather than by URL because the two sides of this question
    /// spell paths differently on purpose: a tab is opened as the user spelled it
    /// and a language server answers with whatever its own resolution produced
    /// (`/private/var` against `/var` being the standing example). A URL-keyed
    /// lookup would miss the buffer and quietly write the server's edits into the
    /// disk copy beneath an open, possibly dirty, tab.
    ///
    /// The key is spelled by `canonicalKey(_:)` — the same symlink-resolving
    /// transform `CanonicalPath` applies inside Core, restated here for
    /// `isInsideProject`'s reason (that type is Core-internal) and matching it
    /// exactly, which is what keeps this lookup and the plan's own path
    /// comparisons answering the same question.
    private nonisolated static func canonicalKey(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// The one queue the rename's disk passes run on.
    ///
    /// A queue of its own rather than the cooperative pool: both passes are
    /// *blocking* file I/O over a set the server chose the size of, and handing
    /// that to a `Task.detached` would park a pool thread per pass. Serial because
    /// the two passes of one rename are ordered anyway and two renames cannot
    /// overlap — the writer gate sees to the second one.
    private nonisolated static let renameQueue = DispatchQueue(
        label: "com.pisaka.rename", qos: .userInitiated
    )

    /// Run `work` on `renameQueue` and resume with its result — the
    /// `ProjectSearchModel.offMain` shape, so the rename's reads and writes never
    /// land on the main thread while everything that decides *around* them stays
    /// on the main actor.
    private nonisolated static func offMain<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            renameQueue.async { continuation.resume(returning: work()) }
        }
    }

    private func bufferTextsByCanonicalPath() -> [String: String] {
        var texts: [String: String] = [:]
        // Viewer tabs are left out: this map is what the rename pass *vouches
        // for*, and an entry here says "this file's bytes are these bytes". A
        // database's are not, and its tab's `text` is empty — so an entry would
        // offer the rename plan an empty baseline for a real path, which
        // `expectedText` would then verify against and rewrite.
        for file in model.openFiles where file.kind == .text {
            guard let url = file.url else { continue }
            texts[Self.canonicalKey(url)] = file.text
        }
        return texts
    }

    /// The Edit menu's "Toggle Comment": ask the focused editor to toggle comments
    /// for its selection or line.
    ///
    /// Routed through the first responder for the same reason as
    /// `goToDefinitionAtCaret()` — the command carries no state. This app-wide
    /// key equivalent (Cmd+/) takes the shortcut from the terminal and the project
    /// tree, so with either focused it beeps rather than editing.
    private func toggleCommentAtCaret() {
        guard let editor = NSApp.keyWindow?.firstResponder as? EditorTextView,
              editor.isEditable,
              !editor.hasMarkedText()
        else {
            PlatformFeedback.warning()
            return
        }
        editor.toggleCommentAtSelection()
    }

    // MARK: - Completion

    /// The Find menu's "Complete": ask the focused editor to offer completions for
    /// the word at its caret. (⌃Space reaches the same request without passing
    /// through here — `EditorTextView.keyDown` handles it, so the keystroke is not
    /// taken from the embedded terminal.)
    ///
    /// Routed through the first responder for the same reason as
    /// `goToDefinitionAtCaret()` — the command carries no state, and the responder
    /// chain already names the one view that can answer. Anything else focused has
    /// no partial word to complete, and beeps rather than opening a popup
    /// somewhere the user is not typing.
    private func completeAtCaret() {
        guard let editor = NSApp.keyWindow?.firstResponder as? EditorTextView else {
            PlatformFeedback.warning()
            return
        }
        editor.complete(nil)
    }

    /// Run a project-wide Replace All under the same disk-writer coordination as
    /// `applyMerge`/`revertChanges`, returning the summary — or `nil` when the
    /// batch was refused (a revert is in flight and `revertInFlight()` has already
    /// explained itself).
    ///
    /// Replace All writes files the user cannot all see, so it is the third
    /// uncoordinated disk writer: autosave is suspended and the tree/revert gate
    /// raised *synchronously before the first `await`* (balanced by `defer`), so
    /// neither an idle autosave of a dirty tab nor a project-tree operation can
    /// interleave with the batch's read-modify-write of the same file. Afterwards
    /// Local Changes is re-queried and the tree bumped — the batch changed file
    /// contents on disk, and the watcher deliberately ignores our own writes.
    ///
    /// `originGeneration` is the project token the *view* captured synchronously,
    /// before its own `Task` hop — not something this method could pin, since its
    /// synchronous prefix already runs inside that task, i.e. after the window the
    /// pin exists to close.
    private func replaceAllInProject(
        template: String,
        originGeneration: Int
    ) async -> ReplaceSummary? {
        guard !revertInFlight() else { return nil }
        autosave.suspend()
        localChanges.beginRevert()
        defer {
            autosave.resume()
            localChanges.endRevert()
        }
        // The buffers as they stand *before* the batch, so the resync below can
        // name exactly the tabs it rewrote — `ReplaceSummary` counts files, it does
        // not list them. Keyed by tab id, not URL: two tabs can legitimately show
        // the same file (opened once by path, once through a symlink).
        // Viewer tabs are left out: they hold no text the batch could have
        // rewritten, and an entry here would say this map vouches for a database's
        // bytes. The resync loop below skips them for the same reason and must,
        // since a missing entry reads as "changed".
        let textsBeforeBatch = Dictionary(
            uniqueKeysWithValues: model.openFiles
                .filter { $0.kind == .text }
                .map { ($0.id, $0.text) }
        )
        // Pre-empting the batch's own read-modify-write of every matched file —
        // the one worktree writer here that is not git, and the one whose result
        // no `git checkout` can undo. The targets are the results already in hand
        // (`ProjectSearchModel.results`), so this adds no second traversal. First
        // `await` in the body, ahead of the batch's own.
        await captureBeforeOperation(
            .replace,
            buffers: openBufferTexts(),
            targets: projectSearch.results.map(\.fileURL)
        )
        let summary = await projectSearch.replaceAll(
            template: template,
            originGeneration: originGeneration
        )
        guard summary.filesChanged > 0 else { return summary }
        refreshLocalChanges()
        model.bumpTreeRevision()
        // The batch rewrote files the user mostly has no tab for, so their symbols
        // are stale until a stamp-gated refresh re-extracts them.
        notifyIndexOfProjectFileChanges()
        // …but a file that *does* have a tab was replaced **in the buffer**
        // (`applyBufferText`), never on disk, and a buffer-sourced entry is exactly
        // what that refresh declines to re-extract. Only the selected tab repairs
        // itself, through its live `CodeEditorView`'s content-replaced path; every
        // other rewritten tab would keep answering Go to Definition and completion
        // with the pre-replacement identifiers, at the pre-replacement ranges,
        // until it was selected or closed. Same resync the worktree rewrites do
        // (revert / checkout / merge apply) — see `reindexReloadedBuffer`.
        for file in model.openFiles where file.kind == .text {
            guard let url = file.url, textsBeforeBatch[file.id] != file.text else { continue }
            reindexReloadedBuffer(id: file.id, url: url)
        }
        return summary
    }

    @discardableResult
    private func saveSelected() -> Bool {
        guard let id = model.selectedID else { return false }
        return save(id: id)
    }

    /// Save the file identified by `id`, prompting for a location when it has
    /// none. Returns `true` only when the file ends up saved (not dirty).
    @discardableResult
    private func save(id: UUID, abandoningBuffer: Bool = false) -> Bool {
        // A viewer tab holds nothing to save, so ⌘S over one is a no-op that
        // *reports success*: nothing to save is not a failure, and returning
        // `false` would beep at the close prompt and fail the run/test pre-run
        // save. Deliberately ahead of everything below — the writer gate (a save
        // that writes nothing cannot race git), `saveTransform.prepareForSave`
        // (there is no buffer to transform and no caret to protect) and the
        // recreate probe (which would put an empty file back where a deleted
        // database was). `WorkspaceModel.save(for:)` answers `.saved` for one too;
        // this returns before reaching it so the surrounding side effects — the
        // Local History capture, the `.editorconfig` note, the tree bump — never
        // run for a tab whose bytes this app never wrote.
        guard model.openFiles.first(where: { $0.id == id })?.kind != .viewer else { return true }
        // A save is a disk write, so it is refused while one of the app's git
        // operations is mutating or reading the working tree (`revertInFlight()` —
        // raised by revert, merge apply, a branch checkout, Replace All and the
        // commit). ⌘S is reachable throughout every one of them: none blocks the
        // main menu, and a modal *sheet* does not either, which is exactly why the
        // commit path raises the gate at all. Landing mid-operation it races `git
        // checkout` on the same file, or writes bytes into the working tree while
        // git is reading it into the commit's temporary index — content the dialog
        // never displayed and `CommitStaleness` (which compares rows read before
        // the write) cannot see. `runFile`/`testFile` already refuse ahead of their
        // own save for this reason; checking here covers ⌘S and the close prompt's
        // "Save" too, and their earlier guard simply returns first.
        guard !revertInFlight() else { return false }
        // Ask `.editorconfig` what saving this buffer changes and apply it *here*,
        // after the writer-gate refusal above and before the write below — so the
        // close prompt's Save and the `runFile`/`testFile` pre-run saves, which all
        // funnel through this method, inherit the transform without a second call
        // site, and a save that the gate refuses rewrites nothing at all.
        // Deliberately unconditional on the dirty flag: ⌘S writes this file either
        // way, so the transform applies either way (autosave, which writes only
        // dirty buffers, passes only those — see its wiring).
        saveTransform.prepareForSave(ids: [id], protectingCaret: !abandoningBuffer)
        // `FileService.write` creates a missing file, so saving a tab whose file was
        // deleted out of band (Finder, a console `rm`, a branch checkout) puts it
        // back on disk — the tree already dropped it via the watcher, and the watcher
        // will not report our *own* write (`kFSEventStreamCreateFlagIgnoreSelf`), so
        // the listing would keep contradicting disk until a manual Refresh. Probe
        // before the write and bump only for such a creating save; an ordinary
        // overwrite changes no listing and is deliberately left unbumped (that
        // frequent case is precisely what `IgnoreSelf` keeps quiet).
        let recreatesFile = model.openFiles.first { $0.id == id }?.url
            .map { !FileManager.default.fileExists(atPath: $0.path) } ?? false
        do {
            if try model.save(for: id) == .needsSaveAs {
                // The untitled case, and it carries `abandoningBuffer` with it:
                // the close prompt's Save reaches `saveAs` whenever the buffer has
                // no path yet, and the transform decision is the same one this
                // method just made — there is no caret to protect on a buffer whose
                // tab closes as soon as the write returns.
                return saveAs(id: id, abandoningBuffer: abandoningBuffer)
            }
            if recreatesFile { model.bumpTreeRevision() }
            // Local History's first save site (⌘S, the close prompt's Save, the
            // run/test pre-run saves — everything funnels through here). *After*
            // the write, deliberately: the bytes worth keeping are the ones that
            // reached disk, and a write that threw leaves the `catch` below with
            // nothing to store.
            if let file = model.openFiles.first(where: { $0.id == id }), let url = file.url {
                localHistory.captureSaves(urls: [url], root: model.projectRoot, texts: [url: file.text])
            }
            noteEditorConfigWrites([model.openFiles.first { $0.id == id }?.url].compactMap { $0 })
            refreshLocalChanges()
            return true
        } catch {
            PlatformFeedback.warning()
            return false
        }
    }

    /// Prompt for a destination and save the file there. Returns `true` on a
    /// successful write, `false` if the user cancelled or the write failed.
    @discardableResult
    private func saveAs(id: UUID, abandoningBuffer: Bool = false) -> Bool {
        let suggested = model.openFiles.first { $0.id == id }?.displayName ?? "Untitled"
        guard let url = FilePanels.showSavePanel(suggestedName: suggested) else { return false }
        // Only now is there a path to resolve a configuration against, and it is
        // the *destination's*: an untitled buffer belongs to no folder until this
        // panel is answered, so the transform runs after it and never before —
        // but also never before the one condition `saveAs` refuses on. A rewrite
        // is only a save's to make, so a destination another tab already owns is
        // rejected here, before the buffer is touched, instead of letting the
        // throw below leave a silently reformatted buffer that was never written.
        guard !model.isDestinationOpenElsewhere(url, for: id) else {
            PlatformFeedback.warning()
            return false
        }
        saveTransform.prepareForSaveAs(id: id, destination: url, protectingCaret: !abandoningBuffer)
        do {
            try model.saveAs(url: url, for: id)
            // Save As writes a *new* file, which changes tree membership when the
            // destination is inside the open folder — and the watcher deliberately
            // ignores self-generated events (`kFSEventStreamCreateFlagIgnoreSelf`),
            // so it will not cover this write. Bump explicitly, like every other
            // in-app disk mutation (create / rename / delete). Unconditional: a
            // destination outside the open folder just re-reads listings that did
            // not change, so gating on containment would add a path check for no
            // benefit.
            model.bumpTreeRevision()
            // Local History's second save site. Only now is there a url to key the
            // buffer under — an untitled buffer belongs to no file and is skipped
            // everywhere else in this feature — so this is where a Save As first
            // enters history, under the destination it just took.
            if let text = model.text(for: id) {
                localHistory.captureSaves(urls: [url], root: model.projectRoot, texts: [url: text])
            }
            // The buffer was untitled until now, so nothing has ever indexed it
            // under this path; the refresh picks the written file up from disk.
            notifyIndexOfProjectFileChanges()
            refreshLocalChanges()
            return true
        } catch {
            PlatformFeedback.warning()
            return false
        }
    }

    /// Re-query the repository for changed files after a successful save, so the
    /// Local Changes panel reflects the edit without filesystem watching. No-op
    /// when no project folder is open.
    private func refreshLocalChanges() {
        guard let root = model.projectRoot else { return }
        // Pin the request generation captured *synchronously* now, before the
        // `Task` hop. A save-driven refresh of the current folder should reflect
        // the save — but unstructured tasks are not guaranteed to start in creation
        // order, so if the opened folder switches before this task runs, the
        // captured generation no longer matches and the model rejects this stale
        // refresh. Without the pin it would instead enter `refreshImpl`, see its
        // old root differ from the new `lastRequestedRoot`, be misread as a folder
        // switch *back* to the old repo, and reject the new folder's legitimate
        // refresh — stranding the Changes panel on the previous repository.
        let requestGeneration = localChanges.currentRequestGeneration
        Task { await localChanges.refresh(root: root, requestGeneration: requestGeneration) }
    }

    /// Revert (discard) the local changes for `contextFile` — or, when it is part
    /// of the checked multi-selection, every checked file. Confirms first (the
    /// action is destructive and irreversible), reverts via the model, then keeps
    /// any open tab for a reverted file in sync with disk: reloaded if the file
    /// still exists, closed if it was deleted — except a buffer the user edited
    /// while the async revert was in flight, which is preserved (not silently
    /// overwritten or closed).
    private func revertChanges(contextFile: ChangedFile) {
        let files = localChanges.filesToRevert(contextFile: contextFile)
        guard !files.isEmpty else { return }
        let names = files.map { ($0.path as NSString).lastPathComponent }
        // Run the synchronous confirmation dialog before awaiting the async
        // revert, so the modal sheet is presented inline (not after a hop).
        guard FilePanels.confirmRevert(fileNames: names) else { return }

        // Pin the project the revert was confirmed against, synchronously, before
        // the `Task` hop. The task body runs a later main-actor turn, during which
        // a folder switch could replace the repository — the model reads its
        // root/generation only when `revert` starts, so without this pin a revert
        // of repo A's files could execute against a newly opened repo B.
        let originGeneration = localChanges.currentRequestGeneration
        // Suspend autosave *synchronously*, before the `Task` hop — autosave is a
        // second, uncoordinated disk writer (idle/focus-loss/tab-switch), and one
        // firing mid-revert could write a buffer back to disk that the revert is
        // concurrently discarding (racing `git checkout`) and corrupt the
        // snapshot-based resync below. The matching `resume()` is a `defer` inside
        // the Task so it always balances, including the early-bail paths. Not done
        // around the confirm dialog: an autosave *can* interleave there (the idle
        // debounce, a GCD main-queue timer, fires inside the alert's nested run
        // loop), but it is harmless — `preRevertText` is snapshotted *after* the
        // confirm returns, and `git checkout` then supersedes whatever it wrote — so
        // suspending across the alert buys nothing and a cancel must not leave it
        // suspended.
        autosave.suspend()
        // Raise the revert gate *synchronously*, before the `Task` hop, for the
        // same reason autosave is suspended above: the project tree stays
        // interactive while the revert runs `git` off the main thread, and a
        // tree file operation (create / rename / delete) is a second,
        // uncoordinated disk writer that could race the git mutation — deleting a
        // file `git checkout` is concurrently restoring, or recreating one the
        // revert is about to remove. The four tree operations refuse while this is
        // raised; the matching `endRevert()` is a `defer` inside the Task so it
        // always balances (including the early-bail paths). Set before the hop so
        // no tree op can slip into the gap before the task body runs.
        localChanges.beginRevert()
        // Snapshot every open tab's buffer text *synchronously*, before the async
        // revert hops off the main actor. The revert runs `git` off the main
        // thread, so the editor stays interactive while it is in flight: if the
        // user edits an affected file after confirming, that edit lives only in
        // memory and must not be silently overwritten (or the tab closed) by the
        // post-revert resync below. We reload/close a tab only when its buffer is
        // unchanged since this snapshot; a buffer the user touched is preserved.
        let preRevertText = Dictionary(
            uniqueKeysWithValues: model.openFiles.map { ($0.id, $0.text) }
        )
        // The two Local History inputs, collected in the same synchronous stretch
        // as `preRevertText` above and for the same reason — the revert hops off
        // the main actor and the editor stays live behind it.
        let revertBuffers = openBufferTexts()
        let revertTargets = changedFileURLs(files, root: localChanges.root ?? model.projectRoot)
        Task { @MainActor in
            // Resume autosave and lower the revert gate when the whole revert +
            // resync finishes, on every path (origin-generation mismatch, empty
            // `reverted`, or a full run).
            defer {
                autosave.resume()
                localChanges.endRevert()
            }
            // Pre-empting the discard itself. This is the operation whose whole
            // purpose is to destroy text, so it is the one a safety net most owes
            // an escape hatch: after this, the reverted content exists only in the
            // store. First `await` in the body, ahead of the revert's own.
            await captureBeforeOperation(.revert, buffers: revertBuffers, targets: revertTargets)
            let reverted = await localChanges.revert(files, originGeneration: originGeneration)
            // A revert changes tree membership (an added/untracked file is deleted, a
            // deleted one restored), so refresh the tree. The watcher does not cover
            // this: reverting an *untracked* file is `GitCLIService.removeUntracked`'s
            // `unlinkat` — an in-process write, which
            // `kFSEventStreamCreateFlagIgnoreSelf` drops — unlike every other revert
            // branch, which runs a `git` subprocess. Idempotent and read-only, so the
            // redundant bump for the subprocess cases costs nothing.
            if !reverted.isEmpty {
                model.bumpTreeRevision()
                // Same asymmetry as the bump above: the untracked-file branch is an
                // in-process `unlinkat` the watcher never reports, so without this
                // the deleted file's symbols would outlive it. Redundant for the
                // subprocess branches, which the watcher does cover, and harmless
                // there — the refresh re-reads only what changed.
                notifyIndexOfProjectFileChanges()
            }
            for url in reverted {
                guard let id = model.fileID(forURL: url) else { continue }
                // The same viewer rule the checkout resync applies, asked here too
                // because a database can be tracked and therefore reverted. Without
                // it the branch below reads a viewer tab as "unchanged" (its text
                // is empty on both sides), asks `reloadFromDisk`, gets the no-op
                // `false` a viewer tab always answers, and force-closes a tab whose
                // file is sitting right there.
                if resyncViewerTab(id, mayRemoveFiles: true) { continue }
                // Reload/close this tab only when its buffer is provably unchanged
                // since we confirmed the revert: a snapshot exists *and* the text
                // still matches it. Anything else is preserved (and we beep)
                // rather than silently reloaded over or closed. Two cases qualify:
                //  - the buffer changed since the snapshot — the user edited it
                //    while the revert ran off the main thread (editor stayed live);
                //  - the tab has *no* snapshot at all — it was opened (or closed and
                //    reopened, earning a fresh id) for this file *during* the
                //    in-flight revert, so its contents post-date the snapshot and
                //    may hold edits we never recorded. Treat it as changed.
                guard let before = preRevertText[id], before == model.text(for: id) else {
                    // Preserve the edited buffer rather than reload over it — but
                    // reconcile its saved baseline with the post-revert disk state.
                    // If the user *saved* the edit during the in-flight revert,
                    // `savedText == text` (the tab looks clean) yet `git` has since
                    // overwritten (or deleted) the file on disk; without this the
                    // now-stale "clean" tab would close without confirmation and
                    // silently lose the preserved edit. Reconciling makes it dirty.
                    model.reconcileSavedBaseline(id: id)
                    PlatformFeedback.warning()
                    continue
                }
                if FileManager.default.fileExists(atPath: url.path) {
                    if !model.reloadFromDisk(id: id) {
                        // The reverted file exists but could not be re-read (unreadable
                        // or removed in the race between the check and the read). The
                        // tab now shows stale pre-revert contents that a later save
                        // would write back over the revert, so close it rather than
                        // leave that trap open.
                        model.close(id: id, force: true)
                        forgetIndexedBuffer(url)
                        PlatformFeedback.warning()
                    } else {
                        reindexReloadedBuffer(id: id, url: url)
                    }
                } else {
                    model.close(id: id, force: true)
                    // The revert deleted the file. Hand its index entry back to disk
                    // so the next refresh can drop it: a buffer-sourced entry is
                    // exempt from that removal and would stay jumpable forever.
                    forgetIndexedBuffer(url)
                }
            }
        }
    }

    // MARK: - Branch switching

    /// Check out a local branch. Warns first when the working tree is dirty (git
    /// may refuse to overwrite local changes), then runs the checkout under the same
    /// gates as the revert/apply-merge paths and resyncs open tabs to the new
    /// branch's working tree. A blocked checkout surfaces git's message.
    private func switchBranch(_ branch: BranchRef) {
        guard confirmBranchSwitchIfDirty() else { return }
        // Pin the refresh generation synchronously, in this main-actor turn, before
        // `runBranchOperation`'s `Task` hop — so a folder switch that lands in the gap
        // makes `switchTo` bail rather than check out against the newly opened repo
        // (the `revert(_:originGeneration:)` precedent).
        let origin = branchSwitcher.currentRefreshGeneration
        runBranchOperation { await self.branchSwitcher.switchTo(branch, originGeneration: origin) }
    }

    /// Checkout a remote branch (git DWIM): switch to the same-named local if it
    /// already exists, else create it from the remote ref (no fetch). Mirrors
    /// `switchBranch` — the same dirty-tree warning (the checkout part may be blocked
    /// just the same), synchronous generation pinning, and gated orchestration.
    private func checkoutRemote(_ ref: BranchRef) {
        guard confirmBranchSwitchIfDirty() else { return }
        let origin = branchSwitcher.currentRefreshGeneration
        runBranchOperation { await self.branchSwitcher.checkoutRemote(ref, originGeneration: origin) }
    }

    /// If the working tree is dirty, warn (a checkout may be blocked) and ask for
    /// confirmation; returns `true` to proceed (a clean tree proceeds silently).
    /// Shared by `switchBranch` and `checkoutRemote` — both run the same DWIM/plain
    /// checkout that git may refuse against uncommitted changes.
    private func confirmBranchSwitchIfDirty() -> Bool {
        guard branchSwitcher.isWorkingTreeDirty else { return true }
        PlatformFeedback.warning()
        let alert = NSAlert()
        alert.messageText = "Working tree has uncommitted changes"
        alert.informativeText =
            "Switching branches may be blocked if it would overwrite local "
            + "changes. Continue?"
        alert.addButton(withTitle: "Switch")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Create-and-switch a new branch from a remote branch: prompt for the name
    /// (pre-filled with the remote's short name, minus the `<remote>/` prefix), then
    /// create from that remote ref (which fetches first).
    private func createBranchFromRemote(_ ref: BranchRef) {
        guard branchSwitcher.root != nil else { return }
        let suggested = BranchSwitcherModel.defaultBranchName(forRemote: ref)
        // No live reason line here — the post-OK `GitRefName.isValid` guard in
        // `createBranch` stays the only reporter (deliberate minimal scope).
        guard let rawName = FilePanels.promptName(
            title: "New Branch",
            defaultValue: suggested,
            validator: { _ in nil }
        ) else {
            return
        }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        createBranch(name: name, from: .ref(ref))
    }

    /// Create-and-switch a new branch from `HEAD` ("New Branch…"): prompt for the
    /// name, then create.
    private func newBranch() {
        guard branchSwitcher.root != nil else { return }
        // No live reason line here — the post-OK `GitRefName.isValid` guard in
        // `createBranch` stays the only reporter (deliberate minimal scope).
        guard let rawName = FilePanels.promptName(
            title: "New Branch",
            validator: { _ in nil }
        ) else { return }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        createBranch(name: name, from: .head)
    }

    /// Create-and-switch a new branch `name` at `startPoint` under the shared gates.
    /// On `.fetchUnavailable` (a remote start whose fetch failed — offline, or on
    /// iOS a missing PAT) it offers "create from the local copy" (retry with
    /// `fetchRemote: false`) or cancel; an invalid name / hard failure is reported.
    private func createBranch(
        name: String,
        from startPoint: BranchSwitcherModel.StartPoint,
        fetchRemote: Bool = true
    ) {
        autosave.suspend()
        localChanges.beginRevert()
        let snapshot = openTabSnapshot()
        // Capture — synchronously, before the `Task` hop — the refresh generation (so
        // a folder switch in the gap makes the create bail rather than run against the
        // new repo) and the repository the create runs against (so the resync touches
        // only tabs under it). Same rationale as `runBranchOperation`.
        let origin = branchSwitcher.currentRefreshGeneration
        let repoRoot = branchSwitcher.root
        // Local History's inputs, in the same synchronous stretch as `snapshot`.
        let branchBuffers = openBufferTexts()
        let branchTargets = changedFileURLs(localChanges.changedFiles, root: repoRoot)
        Task { @MainActor in
            // Pre-empting the checkout a create-and-switch performs: a branch
            // change rewrites every file that differs between the two branches,
            // and an uncommitted edit that the checkout carries over — or refuses
            // over — is exactly what the user is least able to reconstruct. First
            // `await` in the body, ahead of the create's own. Its own call site,
            // not `runBranchOperation`'s: two separate functions, two separate
            // brackets, one shared `.branch` label.
            await captureBeforeOperation(.branch, buffers: branchBuffers, targets: branchTargets)
            let outcome = await branchSwitcher.createBranch(
                name: name,
                from: startPoint,
                fetchRemote: fetchRemote,
                originGeneration: origin
            )
            // The worktree-mutating git op is done; lower the disk-writer gates before
            // presenting any modal (the fetch-unavailable prompt, an error), so a quit
            // during that modal still flushes other dirty files. Holding `suspend()`
            // across a modal blocks `flushNow` — the reason `closeFile` uses the
            // modal-only `suspendForModal` gate. The remaining synchronous tail runs no
            // run loop, so no autosave/tree op can interleave before it completes.
            autosave.resume()
            localChanges.endRevert()
            switch outcome {
            case .created:
                finishBranchOperation(snapshot: snapshot, repoRoot: repoRoot)
            case .invalidName:
                reportInvalidBranchName(name)
            case .failed:
                if let message = branchSwitcher.errorMessage { presentBranchError(message) }
            case .fetchUnavailable(let error):
                handleFetchUnavailable(error, name: name, startPoint: startPoint)
            }
        }
    }

    /// Offer to create a branch from the local copy of a remote ref after its fetch
    /// failed, or cancel. On "Create from Local" it retries the create without a
    /// fetch (`fetchRemote: false`).
    private func handleFetchUnavailable(
        _ error: GitError,
        name: String,
        startPoint: BranchSwitcherModel.StartPoint
    ) {
        PlatformFeedback.warning()
        let alert = NSAlert()
        alert.messageText = "Couldn't fetch from the remote"
        alert.informativeText =
            error.localizedDescription
            + "\n\nCreate the branch from the local copy of the remote ref instead?"
        alert.addButton(withTitle: "Create from Local")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        createBranch(name: name, from: startPoint, fetchRemote: false)
    }

    /// Run a gated branch checkout: suspend the other disk writers, snapshot open
    /// tabs, run `op` off the main actor, and on success resync tabs + refresh the
    /// tree/Changes/Log. On failure surface git's message. Mirrors the
    /// revert/apply-merge coordination.
    private func runBranchOperation(_ op: @escaping () async -> Bool) {
        autosave.suspend()
        localChanges.beginRevert()
        let snapshot = openTabSnapshot()
        // Capture the repository the checkout runs against so the resync touches only
        // tabs under it — `WorkspaceModel` keeps tabs across folder switches, so a tab
        // pointing at an unrelated repo/folder must not be reloaded or closed by this
        // repo's branch change.
        let repoRoot = branchSwitcher.root
        // Local History's inputs, in the same synchronous stretch as `snapshot`.
        let branchBuffers = openBufferTexts()
        let branchTargets = changedFileURLs(localChanges.changedFiles, root: repoRoot)
        Task { @MainActor in
            // Pre-empting the checkout `op` is about to run — the shared body
            // behind branch *switch* and *checkout-remote*, both of which rewrite
            // the working tree wholesale. First `await` in the body, ahead of the
            // operation's own.
            await captureBeforeOperation(.branch, buffers: branchBuffers, targets: branchTargets)
            let ok = await op()
            // Git op done: lower the disk-writer gates before any modal so a quit during
            // an error alert still flushes other dirty files (see `createBranch`).
            autosave.resume()
            localChanges.endRevert()
            guard ok else {
                if let message = branchSwitcher.errorMessage { presentBranchError(message) }
                return
            }
            finishBranchOperation(snapshot: snapshot, repoRoot: repoRoot)
        }
    }

    /// The post-success tail shared by switch and create: resync open tabs to the
    /// new working tree, bump `treeRevision`, and refresh Changes and Log.
    private func finishBranchOperation(
        snapshot: [UUID: (text: String, wasDirty: Bool)],
        repoRoot: URL?
    ) {
        resyncOpenTabsAfterCheckout(snapshot: snapshot, repoRoot: repoRoot)
        model.bumpTreeRevision()
        refreshLocalChanges()
        refreshLog()
    }

    /// A snapshot of every open tab's buffer text and dirty state, captured
    /// synchronously before a branch mutation hops off the main actor — so the
    /// post-checkout resync can tell a tab it may safely reload (clean and
    /// unchanged) from one the user has edits in.
    ///
    /// Viewer tabs are left out. This map is the resync's evidence that a tab is
    /// safe to reload over, and a database's bytes are not something the app has
    /// read; `resyncOpenTabsAfterCheckout` decides a viewer tab on its file's
    /// existence alone, without consulting this.
    private func openTabSnapshot() -> [UUID: (text: String, wasDirty: Bool)] {
        Dictionary(
            uniqueKeysWithValues: model.openFiles
                .filter { $0.kind == .text }
                .map { ($0.id, ($0.text, model.isDirty(for: $0.id))) }
        )
    }

    /// Every open **titled** tab's buffer text, keyed by url — the "always added"
    /// half of every pre-operation Local History capture, collected synchronously
    /// in the same stretch as `openTabSnapshot()` and for the same reason.
    ///
    /// Buffers rather than disk copies because a buffer is what the user would
    /// lose: a dirty tab holds text that exists nowhere else, and a clean one
    /// holds exactly what disk holds, so reading it back would only cost a syscall
    /// and a race with the next keystroke. `LocalHistoryModel` also uses this set
    /// to *exclude* those files from the disk-read pass, so one operation never
    /// leaves two same-labelled snapshots of one file.
    ///
    /// Two tabs may legitimately show one file (opened once by path, once through
    /// a symlink); the last one wins, which is the same arbitrary-but-harmless
    /// choice the dedup would make one step later.
    ///
    /// Viewer tabs are left out, for the third time and the same reason: an entry
    /// here would file a Local History revision holding the empty string under a
    /// database's path — a snapshot that claims to be the file and is not, which
    /// is worse than no snapshot at all. It also keeps the buffer half honest
    /// about the exclusion it hands `LocalHistoryModel`, which reads *disk* for
    /// everything this map does not name and declines a database there by
    /// content.
    private func openBufferTexts() -> [URL: String] {
        var texts: [URL: String] = [:]
        for file in model.openFiles where file.kind == .text {
            guard let url = file.url else { continue }
            texts[url] = file.text
        }
        return texts
    }

    /// The buffer text of each url in `urls`, for the three save sites' capture.
    ///
    /// A save reports *urls*, and the text that belongs in history is the one the
    /// app just wrote — post-`SaveTransform`, since that funnel runs before every
    /// write on every path — so it is read out of the buffer here rather than back
    /// off disk, where the next keystroke could already have overtaken it.
    private func savedBufferTexts(for urls: [URL]) -> [URL: String] {
        let wanted = Set(urls)
        return openBufferTexts().filter { wanted.contains($0.key) }
    }

    /// The one spelling of a pre-operation capture, so the seven bracket sites each
    /// read as a single line naming what they are pre-empting rather than as four
    /// repetitions of the same two boilerplate arguments.
    ///
    /// It adds no decision of its own: the root is always the project's, because
    /// that is the only thing the store keys by, and a target outside it is
    /// dropped by `LocalHistoryModel`, not here. Being `async` is the whole point
    /// — every caller `await`s it as the first `await` inside its bracket, which
    /// is what makes what it stores pre-operation by construction.
    private func captureBeforeOperation(
        _ event: LocalHistoryEvent,
        buffers: [URL: String],
        targets: [URL]
    ) async {
        await localHistory.captureBeforeOperation(
            event: event,
            root: model.projectRoot,
            bufferTexts: buffers,
            diskTargets: targets
        )
    }

    /// The worktree urls of `files`, resolved against the repository `root` — the
    /// disk-read half of a pre-operation capture, and no new git call: these are
    /// the rows Local Changes already holds.
    ///
    /// A url that is not under the *project* root is dropped by
    /// `LocalHistoryModel` rather than here, so this stays one path join.
    private func changedFileURLs(_ files: [ChangedFile], root: URL?) -> [URL] {
        guard let root else { return [] }
        return files.map { root.appendingPathComponent($0.path) }
    }

    /// The whole post-operation resync rule for a **viewer** tab, in one place
    /// all three resync sites ask before they reach their text-shaped reasoning.
    ///
    /// Returns `true` when `id` is a viewer tab and has therefore been settled
    /// here — the caller must go no further with it. Takes the id rather than the
    /// `OpenFile` the two loops already hold, because the third site has only an
    /// id, and one signature all three can ask is worth a lookup over a tab list.
    ///
    /// A viewer tab has exactly two outcomes, and neither is any of the three a
    /// text tab has. Its file is **gone** and the caller `mayRemoveFiles`: it
    /// force-closes, exactly like a text tab on a deleted file, and
    /// `DatabaseViewerTabs` releases its connection off the same `openFiles`
    /// change (which is why nothing is closed by hand here — one subscription
    /// covers every way a tab can leave). No `forgetIndexedBuffer` goes with it:
    /// `openBuffers` never offered the tab, so there is no buffer-sourced entry to
    /// hand back to disk. Its file is **still there**: the *tab* is left alone —
    /// no `reloadFromDisk` (a viewer tab's no-op `false` would read as a failed
    /// read and close the tab), no `reconcileSavedBaseline` (there is no
    /// baseline; it can never be dirty), and no beep, because nothing was
    /// preserved and nothing was lost — while its **connection is re-opened**.
    /// That last part is not optional: git replaces a file by renaming a new one
    /// over it, so the tab's `sqlite3 *` is left pointing at the unlinked old
    /// inode and every later read answers the pre-operation database with nothing
    /// on screen saying so. `DatabaseViewerTabs.reload(id:)` is the viewer's half
    /// of the `reloadFromDisk` beside it.
    private func resyncViewerTab(_ id: UUID, mayRemoveFiles: Bool) -> Bool {
        guard let file = model.openFiles.first(where: { $0.id == id }), file.kind == .viewer else { return false }
        guard let url = file.url else { return true }
        if FileManager.default.fileExists(atPath: url.path) {
            databaseViewers.reload(id: id, url: url)
        } else if mayRemoveFiles {
            model.close(id: id, force: true)
        }
        return true
    }

    /// After a successful checkout/create the working tree may have changed under
    /// any open tab *within the repository whose branch changed*. Reload each such tab
    /// that holds no unsaved edits to lose (clean at the snapshot and provably
    /// unchanged since); preserve — reconcile its saved baseline so a since-saved edit
    /// still prompts on close, and beep — a tab the user had edits in; close a tab
    /// whose file no longer exists on the new branch. Tabs outside `repoRoot` are left
    /// untouched: `WorkspaceModel` keeps tabs across folder switches, so a branch
    /// change must not reload/close an unrelated tab whose disk state changed out of
    /// band.
    ///
    /// `mayRemoveFiles` is what makes that closing rule honest for callers other
    /// than a checkout. A checkout really does delete worktree files, so "the file
    /// is gone" means "this operation removed it" and force-closing the tab is
    /// right. A **commit** never touches the working tree that way — its
    /// `.removePath` entries stage a deletion in the throw-away index and nothing
    /// more — so a missing file was already missing when the dialog opened (a
    /// `.deleted` row, an `rm` from the embedded terminal). Closing there would
    /// discard, with no prompt, a clean buffer holding the last copy of a file that
    /// is no longer on disk. Such a tab is left exactly as it is: not reloaded, not
    /// closed, and deliberately not made dirty either, since a dirty titled buffer
    /// is what autosave would use to recreate the very file the user deleted.
    private func resyncOpenTabsAfterCheckout(
        snapshot: [UUID: (text: String, wasDirty: Bool)],
        repoRoot: URL?,
        mayRemoveFiles: Bool = true
    ) {
        let rootPath = repoRoot?.resolvingSymlinksInPath().path
        var didPreserve = false
        for file in model.openFiles {
            guard let url = file.url else { continue }
            if let rootPath,
               !ScopedFileAccess.path(url.resolvingSymlinksInPath().path, isWithin: rootPath) {
                continue
            }
            let id = file.id
            if resyncViewerTab(id, mayRemoveFiles: mayRemoveFiles) { continue }
            guard let snap = snapshot[id], !snap.wasDirty, snap.text == model.text(for: id) else {
                model.reconcileSavedBaseline(id: id)
                didPreserve = true
                continue
            }
            if FileManager.default.fileExists(atPath: url.path) {
                if !model.reloadFromDisk(id: id) {
                    model.close(id: id, force: true)
                    forgetIndexedBuffer(url)
                    didPreserve = true
                } else {
                    reindexReloadedBuffer(id: id, url: url)
                }
            } else if mayRemoveFiles {
                model.close(id: id, force: true)
                // Same rule as the revert resync: a closed tab's entry must stop
                // being buffer-sourced, or the refresh can neither re-extract nor
                // remove the file the branch switch took away.
                forgetIndexedBuffer(url)
            }
        }
        if didPreserve { PlatformFeedback.warning() }
    }

    /// Re-query the Log after a branch change so it reflects the new branch's
    /// history. Mirrors `refreshLocalChanges`'s generation-pinned refresh.
    private func refreshLog() {
        guard let root = model.projectRoot else { return }
        let logRequest = commitLog.prepareForRefresh(root: root)
        Task { await commitLog.refresh(root: root, limit: CommitLogView.initialLimit, request: logRequest) }
    }

    /// Surface a failed branch operation (a blocked checkout, a failed create)
    /// non-fatally, the same informational way as other failures.
    private func presentBranchError(_ message: String) {
        PlatformFeedback.warning()
        let alert = NSAlert()
        alert.messageText = "Branch operation failed"
        alert.informativeText = message
        alert.runModal()
    }

    /// Surface a rejected branch name the same non-fatal way as a rejected file name.
    private func reportInvalidBranchName(_ name: String) {
        PlatformFeedback.warning()
        let alert = NSAlert()
        alert.messageText = "Invalid branch name"
        alert.informativeText = "\"\(name)\" is not a valid git branch name."
        alert.runModal()
    }

    // MARK: - Separate diff windows

    /// Open a Local Changes file's working-copy-vs-`HEAD` diff in a separate,
    /// non-modal window. The window's `load` closure binds the model and file so
    /// `DiffWindowContent` stays model-agnostic; the title pairs the path with
    /// "Local Changes" so several diff windows stay distinguishable.
    private func openLocalChangesDiff(_ file: ChangedFile) {
        let content = DiffWindowContent(
            fileID: file.id,
            fileName: (file.path as NSString).lastPathComponent,
            load: { await localChanges.rows(for: file) },
            settings: settings
        )
        diffWindows.open(title: DiffWindowTitle.localChanges(path: file.path), content: content)
    }

    /// Open a commit's file diff (commit-vs-first-parent) in a separate, non-modal
    /// window, mirroring `openLocalChangesDiff`. The title pairs the path with the
    /// commit's short hash and subject.
    private func openCommitDiff(_ file: ChangedFile, in commit: Commit) {
        let content = DiffWindowContent(
            fileID: "\(commit.hash):\(file.path)",
            fileName: (file.path as NSString).lastPathComponent,
            load: { await commitLog.rows(for: file, in: commit) },
            settings: settings
        )
        let title = DiffWindowTitle.commit(
            path: file.path,
            hash: commit.hash,
            subject: commit.subject
        )
        diffWindows.open(title: title, content: content)
    }

    /// Open the 3-pane merge editor for a conflicted file in a separate, non-modal
    /// window. A fresh `MergeModel` (its own `GitCLIService`, sharing the project's
    /// `FileService`) loads the file's `:1`/`:2`/`:3` index stages off-main and
    /// builds the merge document; the window's "Apply" runs `MergeModel.apply()`
    /// (write resolved text + `git add`), then on success refreshes Local Changes —
    /// reusing the existing generation-pinned `refreshLocalChanges()` — and the
    /// merge window closes itself. The repo root is the one `LocalChangesModel`
    /// resolved (repo-root-relative paths), falling back to the opened folder.
    private func resolveConflict(_ file: ChangedFile) {
        guard let root = localChanges.root ?? model.projectRoot else {
            PlatformFeedback.warning()
            return
        }
        let mergeModel = MergeModel(gitService: GitCLIService(), fileService: fileService)
        Task { @MainActor in await mergeModel.load(file: file, root: root) }
        mergeWindows.open(
            title: "Resolve \(file.path)",
            model: mergeModel,
            settings: settings,
            onApply: { await applyMerge(mergeModel, file: file, root: root) }
        )
    }

    /// Perform a guarded merge apply: write the resolved text + `git add` (via
    /// `MergeModel.apply()`), then refresh Local Changes and resync any open tab on
    /// the resolved file. Returns whether the apply succeeded (the window closes on
    /// `true`).
    ///
    /// Coordinated against the two other uncoordinated disk writers exactly like the
    /// revert path: autosave is suspended and the disk-writer gate raised
    /// *synchronously* before the first `await` (so neither an idle/focus-loss
    /// autosave of a dirty tab on this same file nor a project-tree op can race the
    /// apply's `write` + `git add` and stage stale conflicted content over the
    /// resolution), balanced by `defer`. The open tab is snapshotted before the async
    /// apply and only reloaded over when it was clean at the snapshot and is
    /// provably unchanged since — otherwise the user's edit (whether made before or
    /// during the apply) is preserved (and beeped) rather than silently discarded by
    /// `reloadFromDisk`.
    private func applyMerge(_ mergeModel: MergeModel, file: ChangedFile, root: URL) async -> Bool {
        let resolvedURL = root.appendingPathComponent(file.path)
        // Snapshot the open tab's buffer (canonical match resolves a tab opened via
        // `projectRoot` against the repo-root-relative path) before any `await`,
        // recording whether it was already dirty: a tab carrying unsaved edits at
        // apply time must not be silently reloaded over even if it doesn't change
        // during the apply.
        let preApply: (id: UUID, text: String, wasDirty: Bool)? =
            model.fileID(forURL: resolvedURL).flatMap { id in
                model.text(for: id).map { (id, $0, model.isDirty(for: id)) }
            }
        // Suspend the other disk writers synchronously, before the `await` hop.
        autosave.suspend()
        localChanges.beginRevert()
        defer {
            autosave.resume()
            localChanges.endRevert()
        }
        // Pre-empting the resolved write: `MergeModel.apply()` replaces the
        // conflicted file with the resolution, so the conflict markers — and any
        // hand-editing done inside them — are gone from disk and from the tab the
        // moment it succeeds. One target, the file being resolved. First `await`
        // in the body, ahead of the apply's own.
        await captureBeforeOperation(.merge, buffers: openBufferTexts(), targets: [resolvedURL])
        let applied = await mergeModel.apply()
        guard applied else { return false }
        refreshLocalChanges()
        // `MergeModel.apply()` writes the resolved file through `fileService` — an
        // in-process write `kFSEventStreamCreateFlagIgnoreSelf` drops — and the
        // `git add` beside it touches only `.git`, which `TreeRefreshFilter` drops
        // too. So no watcher callback follows, and the merge editor is normally
        // opened from Local Changes on a file with no tab: without this the
        // pre-merge symbols would answer lookups for the rest of the session. The
        // iOS peer in `RootView_iOS` makes the same call for the same reason.
        notifyIndexOfProjectFileChanges()
        guard let id = model.fileID(forURL: resolvedURL) else { return true }
        // The third resync, and it asks the viewer rule first for the reason the
        // other two do: `preApply` is a text snapshot, and a viewer tab answers it
        // with `("", false)` — "clean and provably unchanged" — so without this the
        // guard below would pass, `reloadFromDisk` would return its by-construction
        // `false`, and a database tab whose file is sitting right there on disk
        // would be force-closed with a beep.
        if resyncViewerTab(id, mayRemoveFiles: true) { return true }
        // Reload the tab to match the applied resolution only when its buffer holds
        // no unsaved edits to lose: it was clean at the snapshot *and* is provably
        // unchanged since. Anything else — the tab was already dirty before apply,
        // the user edited it while apply ran, or it was opened during the apply with
        // no snapshot — is preserved (reconcile its saved baseline so a since-saved
        // edit still prompts on close) rather than silently reloaded over.
        guard let before = preApply, before.id == id, !before.wasDirty,
              before.text == model.text(for: id) else {
            model.reconcileSavedBaseline(id: id)
            PlatformFeedback.warning()
            return true
        }
        // The resolved file may have been staged as a deletion (modify/delete resolved
        // to the deleted side), so it can be gone from disk: close the now-stale tab
        // rather than reload it.
        if FileManager.default.fileExists(atPath: resolvedURL.path) {
            if !model.reloadFromDisk(id: id) {
                model.close(id: id, force: true)
                forgetIndexedBuffer(resolvedURL)
                PlatformFeedback.warning()
            } else {
                reindexReloadedBuffer(id: id, url: resolvedURL)
            }
        } else {
            model.close(id: id, force: true)
            // Resolved to the deleted side: same rule as the other resync paths.
            forgetIndexedBuffer(resolvedURL)
        }
        return true
    }

    // MARK: - Project tree file operations

    /// Create a new file inside `directory` at the *relative path* `rawName` (VS
    /// Code-style — `centrifugo/config.json`, not just a single name): create any
    /// missing intermediate folders, create the file on disk, open it in a tab,
    /// then bump `treeRevision` so the tree re-reads the directory.
    ///
    /// **There is no prompt and no OK button.** The name arrives already typed
    /// and already accepted: the tree draws an inline draft field
    /// (`ProjectTreeDraftField.swift`) that validates *live* through
    /// `validateRelativeEntryPath(_:)`, shows the resulting
    /// `EntryPathIssue.message` under the field, and refuses to commit an invalid
    /// or blank input at all — Enter beeps and the draft stays open. So an
    /// invalid path normally never reaches this method. The
    /// `parseRelativeEntryPath(_:)` guard below is *post-commit*
    /// defense-in-depth behind that live validation, over the same one Core rule
    /// the field asked (`FileName`), for the paths the field does not stand in
    /// front of; a `nil` result is reported through `reportInvalidName`, which
    /// explains the per-component rule. Existing intermediate folders are reused
    /// (`ensureDirectory`, `mkdir -p` semantics), but the *final* entry is never
    /// clobbered — an existing one fails with `.alreadyExists`. Any disk failure
    /// (collision, a file sitting on the path, missing/unwritable parent, write
    /// error) is surfaced non-fatally — and because `ensureDirectory` does not
    /// roll back, a multi-component failure still bumps `treeRevision` so
    /// intermediates it already created are visible instead of leaving the tree
    /// contradicting disk.
    private func newFile(in directory: URL, name rawName: String) {
        guard !revertInFlight() else { return }
        guard let components = parseRelativeEntryPath(rawName) else {
            reportInvalidName(rawName)
            return
        }
        let url = components.reduce(directory) { $0.appendingPathComponent($1) }
        do {
            if components.count > 1 {
                try fileService.ensureDirectory(at: url.deletingLastPathComponent())
            }
            try fileService.createFile(at: url)
            openFile(url: url)
            model.bumpTreeRevision()
        } catch {
            refreshTreeAfterFailedCreate(componentCount: components.count)
            reportFileOperationFailure(error)
        }
    }

    /// Create a new folder inside `directory`, mirroring `newFile(in:name:)` —
    /// `rawName` is likewise a relative path of any depth, missing intermediates
    /// are created and existing ones reused, and the final component is never
    /// clobbered. No tab is opened for a directory. A failure refreshes the tree
    /// for the same no-rollback reason as `newFile(in:name:)`. The inline draft
    /// likewise validated live through `validateRelativeEntryPath(_:)` and
    /// refused to commit anything invalid, so the parse below is the same
    /// post-commit defense-in-depth over the same Core rule.
    private func newFolder(in directory: URL, name rawName: String) {
        guard !revertInFlight() else { return }
        guard let components = parseRelativeEntryPath(rawName) else {
            reportInvalidName(rawName)
            return
        }
        let url = components.reduce(directory) { $0.appendingPathComponent($1) }
        do {
            if components.count > 1 {
                try fileService.ensureDirectory(at: url.deletingLastPathComponent())
            }
            try fileService.createDirectory(at: url)
            model.bumpTreeRevision()
        } catch {
            refreshTreeAfterFailedCreate(componentCount: components.count)
            reportFileOperationFailure(error)
        }
    }

    /// Refresh the tree after a *failed* multi-component create.
    ///
    /// `ensureDirectory` has `mkdir -p` semantics: a chain it partly built before
    /// a later step failed is left on disk. Without a `treeRevision` bump those
    /// real folders stay invisible until some unrelated tree operation refreshes
    /// the cached listings, so the tree would contradict disk (and a retry would
    /// silently "reuse" folders the user cannot see). A single-component create
    /// writes nothing on the failure path, so it needs no refresh; the bump is
    /// only a re-read token, so it is harmless when nothing changed.
    private func refreshTreeAfterFailedCreate(componentCount: Int) {
        guard componentCount > 1 else { return }
        model.bumpTreeRevision()
    }

    /// Rename the file or folder at `url` to `rawName`: move on disk, retarget
    /// any affected open tabs via `renamePath(from:to:)`, then bump
    /// `treeRevision`. A no-op when the accepted name is unchanged.
    ///
    /// **There is no prompt and no OK button**, as with the two creates: the row
    /// swaps its label for an inline draft field pre-filled with the current name
    /// (its stem preselected, `initialRenameSelection(in:isDirectory:)`) which
    /// validates *live* through `validateSingleEntryName(_:)` — the single-name
    /// grammar, where a `/` is rejected as "a name, not a path", with the
    /// *exact-match* reserved semantics the guards below use, so the two can
    /// never disagree — and refuses to commit while the input is invalid,
    /// beeping instead. The `isValidFileName` + `isExcludedEntryName` guards
    /// below are therefore post-commit defense-in-depth behind that live
    /// validation, over the same one Core rule the field asked.
    ///
    /// Everything past the accepted name is `performMove(from:to:)` — the body a
    /// rename shares with a drag-and-drop move, which is where the
    /// ordering-sensitive plan/move/apply sequence and its reasoning live.
    private func renameItem(at url: URL, newName rawName: String) {
        guard !revertInFlight() else { return }
        let currentName = url.lastPathComponent
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name != currentName else { return }
        guard isValidFileName(name) else { reportInvalidName(rawName, isPath: false); return }
        guard !FileService.isExcludedEntryName(name) else { reportReservedName(name); return }
        let destination = url.deletingLastPathComponent().appendingPathComponent(name)
        performMove(from: url, to: destination)
    }

    /// Move the entry at `source` to `destination` on disk and carry everything
    /// that names it along: the open tabs, the symbol index and the tree.
    ///
    /// The one body both project-tree moves share — the rename
    /// (`renameItem(at:newName:)`, a move within one folder) and the
    /// drag-and-drop move (`moveItem(at:into:)`, a move across folders). Each
    /// caller owns only its own admission rules (the inline draft's live
    /// validation and that method's re-run guards there, `MoveDropRule` here);
    /// the *ordering* below is delicate enough that a second copy of it would be
    /// a second thing to get wrong, and the two differ in nothing but how
    /// `destination` was arrived at.
    ///
    /// Callers must have passed the writer gate (`revertInFlight()`) before
    /// calling: this writes to the working tree.
    private func performMove(from source: URL, to destination: URL) {
        // Capture the tab-retarget plan *before* the move, while a tab opened
        // through a symlink to `source` still canonicalizes to it — once the move
        // renames the target away that symlink dangles and would no longer match.
        // Apply the plan only after the move succeeds.
        let plan = model.planRename(from: source, to: destination)
        // The paths the index still has those tabs' buffers filed under, captured
        // alongside the plan and before the move for the same reason: once
        // `applyRenamePlan` retargets a tab, its old url is no longer reachable from
        // the model. A *folder* move retargets every tab beneath it, so this is a
        // list rather than just `source` — which alone would strand each of those
        // files.
        let retargetedURLs = plan.compactMap { retarget in
            model.openFiles.first { $0.id == retarget.id }?.url
        }
        do {
            try fileService.move(from: source, to: destination)
            model.applyRenamePlan(plan)
            // The tabs now name their destinations, so nothing holds a buffer for the
            // old paths any more. Without this each entry stays marked buffer-sourced
            // — which exempts it from both the refresh's re-extraction and its
            // removal — and the file would keep answering lookups under a name that
            // no longer exists, beside a second entry under the new one.
            retargetedURLs.forEach(forgetIndexedBuffer)
            model.bumpTreeRevision()
            // The index still holds the entry filed under the old path; only the
            // refresh's removal pass drops it, and only this call reaches it.
            notifyIndexOfProjectFileChanges()
        } catch {
            reportFileOperationFailure(error)
        }
    }

    /// Move the entry at `url` into `folder` — the project tree's drag-and-drop
    /// drop, landing here from `ProjectTreeView`'s drop delegate.
    ///
    /// Every question of *whether* the move may happen and *where* it lands is
    /// `MoveDropRule`'s, not this function's: the tree asked the same engine for
    /// the drag highlight, so a drop that lit up a row and a drop this accepts
    /// are decided by one rule. What is left here is the writer gate — raised
    /// first, before the engine's directory listings, for the same reason every
    /// other project-tree file operation raises it — and the two ways a decision
    /// can end.
    ///
    /// A refusal writes *nothing*: no plan is applied, no tree revision bumped,
    /// nothing handed back to the index. A silent one (`unchangedLocation` — the
    /// drop landed back on the folder the entry is already in) reports nothing
    /// either; every other refusal goes through the same failure alert as a disk
    /// error, which is what `MoveDropRefusal` being a `LocalizedError` buys.
    private func moveItem(at url: URL, into folder: URL) {
        guard !revertInFlight() else { return }
        switch MoveDropRule.decision(source: url, into: folder, fileService: fileService) {
        case let .move(destination):
            performMove(from: url, to: destination)
        case let .refuse(refusal):
            guard !refusal.isSilent else { return }
            reportFileOperationFailure(refusal)
        }
    }

    /// Delete the file or folder at `url`: confirm first (destructive), remove it
    /// from disk, close any affected open tabs via `closeFiles(under:)`, then bump
    /// `treeRevision`. The disk and tab-reconciliation paths handle a file and a
    /// directory tree uniformly.
    private func deleteItem(at url: URL) {
        guard !revertInFlight() else { return }
        guard FilePanels.confirmDelete(fileNames: [url.lastPathComponent]) else { return }
        // Capture the affected tab ids *before* the removal, while a tab opened
        // through a symlink to `url` (or into it) still canonicalizes to it — once
        // the item is gone that symlink dangles and would no longer match. Close
        // them only after the removal succeeds.
        let affectedIDs = model.tabIDs(under: url)
        // Captured alongside the ids and for the same reason: once the item is gone
        // the tabs are closed and their URLs are no longer reachable from the model.
        let affectedURLs = affectedIDs.compactMap { id in
            model.openFiles.first { $0.id == id }?.url
        }
        do {
            try fileService.removeItem(at: url)
            model.closeFiles(ids: affectedIDs)
            // Hand every closed tab's entry back to disk. A buffer-sourced entry is
            // exempt from the refresh's removal pass, so without this a deleted
            // file's symbols would stay jumpable for the rest of the session.
            affectedURLs.forEach(forgetIndexedBuffer)
            model.bumpTreeRevision()
            // Handing the entries back to disk is only half of it: what actually
            // drops the deleted files' symbols is the refresh's removal pass.
            notifyIndexOfProjectFileChanges()
        } catch {
            reportFileOperationFailure(error)
        }
    }

    /// Whether one of the app's git operations is currently touching the working
    /// tree. A project-tree file operation (create / rename / delete), a save, a
    /// run/test and a Replace All are each a second, uncoordinated disk writer that
    /// would race the off-main `git` work, so they refuse — beeping and explaining —
    /// rather than corrupting the working tree. Returns `true` (and reports) when an
    /// operation must be blocked, `false` when it may proceed.
    ///
    /// The flag it reads (`LocalChangesModel.isReverting`) is named for its first
    /// caller but is raised by every such operation — a revert, a merge apply, a
    /// branch checkout, a project-wide Replace All and a commit — so the notice is
    /// worded for all of them rather than claiming a revert is running.
    private func revertInFlight() -> Bool {
        guard localChanges.isReverting else { return false }
        PlatformFeedback.warning()
        let alert = NSAlert()
        alert.messageText = "Git operation in progress"
        alert.informativeText =
            "A git operation is writing to the working tree. Wait for it to finish "
            + "before saving, running, or changing files in the project."
        alert.runModal()
        return true
    }

    /// Surface a failed disk operation non-fatally: beep and show the error text
    /// in an informational alert. Never crashes the view; the caller does not bump
    /// `treeRevision` on this path.
    private func reportFileOperationFailure(_ error: Error) {
        PlatformFeedback.warning()
        let alert = NSAlert(error: error)
        alert.runModal()
    }

    /// Surface a rejected name the same non-fatal way as a disk failure.
    ///
    /// Both call sites are now post-*commit* reporters — the inline draft has
    /// already accepted the name against the same Core rule — and the two have
    /// different grammars, so the text does too. The create paths
    /// (`newFile(in:name:)`/`newFolder(in:name:)`, `isPath: true`) treat a slash
    /// as a path separator, so the message explains the *per-component* rule.
    /// Rename (`isPath: false`) still takes a single name and rejects any slash
    /// outright — a path there would be a move, a separate feature — so it must
    /// not be told that slashes separate folders.
    private func reportInvalidName(_ name: String, isPath: Bool = true) {
        PlatformFeedback.warning()
        let alert = NSAlert()
        alert.messageText = "Invalid name"
        alert.informativeText = isPath
            ? "\"\(name)\" is not a valid path. A slash separates folders, and each "
                + "part of the path must be non-empty, must not be \".\" or \"..\", "
                + "must not contain a line break, and must not be a reserved name "
                + "such as \".git\" or \".DS_Store\" (in any casing)."
            : "\"\(name)\" is not a valid name. A name must be non-empty, must not "
                + "be \".\" or \"..\", must not contain a line break, and must not "
                + "contain a slash — renaming takes a single name, not a path."
        alert.runModal()
    }

    /// Surface a name the project tree never shows (`FileService`'s excluded
    /// service entries), rejected the same non-fatal way as an invalid name: the
    /// entry would exist on disk but stay invisible in the tree, so the rename is
    /// refused instead. Rename-only — a reserved component in a *create* path is
    /// reported by `reportInvalidName`, which explains the per-component rule
    /// (and refuses reserved names in any casing).
    private func reportReservedName(_ name: String) {
        PlatformFeedback.warning()
        let alert = NSAlert()
        alert.messageText = "Reserved name"
        alert.informativeText =
            "\"\(name)\" is reserved and is never shown in the project tree, "
            + "so an entry can't be renamed to it from here."
        alert.runModal()
    }

    private func closeSelected() {
        guard let id = model.selectedID else { return }
        closeFile(id: id)
    }

    /// Close the file identified by `id`, confirming first when it has unsaved
    /// changes. Used by both the tab close button and the Cmd+W menu command.
    private func closeFile(id: UUID) {
        // Hand the tab's index entry back to disk once the close is settled,
        // whichever way it went. `forgetIndexedBuffer` checks that no tab still
        // shows the file, so the Cancel branch — and a second tab on the same file
        // — leave the buffer mark exactly where it is.
        let closingURL = model.openFiles.first { $0.id == id }?.url
        defer { forgetIndexedBuffer(closingURL) }
        guard model.close(id: id) == .needsConfirmation else { return }
        let name = model.openFiles.first { $0.id == id }?.displayName ?? "Untitled"
        // Suspend the regular autosave triggers across the close confirmation.
        // `NSAlert.runModal()` spins a nested event loop, during which the idle
        // debounce — a GCD main-queue timer, serviced in AppKit's modal run-loop
        // mode — can fire and autosave the dirty file before the user answers. That
        // would defeat a subsequent "Don't Save": the discard would only drop the
        // in-memory tab while the edit had already been written to disk. Suspend
        // before the prompt and resume only after the close is fully handled (Don't
        // Save force-closes the tab *before* resume, so the replayed autosave can't
        // resave the discarded buffer). Use the *modal* gate, not `suspend()`: a quit
        // landing while this alert is open must still flush every *other* dirty file
        // (there is no revert racing the disk here), so the termination flush stays
        // ungated by this suspension.
        autosave.suspendForModal()
        defer { autosave.resumeFromModal() }
        switch FilePanels.confirmClose(fileName: name) {
        case .save:
            // The tab closes the moment this write succeeds, so there is no caret
            // left to protect and no next save to trim a spared line on: this write
            // is the file's last word. iOS's one save already answers the same way
            // for the same button.
            if save(id: id, abandoningBuffer: true) {
                model.close(id: id)
            }
        case .dontSave:
            model.close(id: id, force: true)
        case .cancel:
            break
        }
    }

    /// Flush every open buffer of a served language to its language server, so
    /// the push-only diagnostics channel has something to answer for all of
    /// them (D30) — not only for the tab an editor view happens to display.
    ///
    /// The steady-state triggers are per-buffer and view-driven (a tab
    /// open/switch through `CodeEditorView`, a settled keystroke), which leaves
    /// two moments where a whole *set* of buffers becomes the server's business
    /// at once and no view says so: a session restored into several tabs, and a
    /// registry change that makes a language servable that was not a moment ago.
    /// Both call this. Idempotent — `LSPWorkspace.prepare` sends nothing for
    /// text the server already holds — and silent for an unserved language,
    /// which the controller drops before it costs a task.
    ///
    /// Static so the `init`-time closure can reach it without capturing a
    /// half-built `self`, and so both callers run one implementation.
    @MainActor
    private static func syncOpenBuffersForDiagnostics(
        of workspace: WorkspaceModel,
        through sync: LSPDocumentSyncController
    ) {
        for file in workspace.openFiles where file.kind == .text {
            guard let url = file.url else { continue }
            sync.noteBufferOpened(
                url: url,
                text: file.text,
                language: SyntaxLanguage(forFileName: url.lastPathComponent)
            )
        }
    }

    /// Tell the symbol index that `url` no longer has an editor buffer behind it,
    /// so it re-extracts the file from disk instead of keeping the text the closed
    /// tab held.
    ///
    /// A no-op while *any* tab still shows the file: a cancelled close leaves the
    /// tab open, and the same file can legitimately be reached through two tabs
    /// (opened once by path and once through a symlink — `fileID(forURL:)` matches
    /// canonically, exactly as the index keys its files).
    ///
    /// The language server is told the same thing at the same moment (D2's
    /// `didClose`), under this one guard rather than a second copy of it: the two
    /// consumers of a buffer must agree about when a file stops having one, and a
    /// `didClose` for a file another tab still shows would leave the server
    /// answering about a document it has dropped. Fire-and-forget, because nothing
    /// waits on it and a server that cannot be told is one whose next request opens
    /// the document afresh anyway.
    private func forgetIndexedBuffer(_ url: URL?) {
        guard let url, model.fileID(forURL: url) == nil else { return }
        symbolIndexController.noteBufferClosed(url: url)
        // The sync controller rides the same guard: a closed tab's pending
        // debounced flush is cancelled, so nothing pushes a buffer no editor
        // holds. The server-side goodbye is the `didClose` below, which also
        // emits the document clear (D33) the model routes into its store.
        lspDocumentSync.noteBufferClosed(url: url)
        // ...and the model is told here rather than only through that clear,
        // because the workspace emits it solely for a URI it still holds: every
        // teardown path wipes its document table first, so a crash-then-close
        // leaves the sync record and the buffer revision behind, and a file no
        // server ever served has no document table entry to begin with. This
        // call is the one that fires for *every* close, which is what keeps the
        // model's maps bounded by the open tabs; the workspace's clear remains
        // for the closes it does see, and arriving twice is a no-op.
        diagnostics.noteDocumentClosed(url: url)
        Task { await lspWorkspace.didClose(url: url) }
    }

    /// Re-index a still-open tab whose buffer an in-app rewrite just replaced —
    /// with the file's new on-disk contents through `reloadFromDisk` (revert,
    /// branch checkout, merge apply), or with replaced text written straight into
    /// the buffer (project-wide Replace All).
    ///
    /// The `notifyIndexOfProjectFileChanges()` refresh these same operations
    /// schedule cannot cover this: the file is still buffer-sourced, and the walk
    /// deliberately declines to re-extract — or remove — a file an editor owns.
    /// Only the *selected* tab re-indexes itself, through its live
    /// `CodeEditorView`'s content-replaced path; a background tab has no editor
    /// view behind it at all, so without this it would keep answering Go to
    /// Definition and completion with the *previous* revision's declarations, at
    /// the previous revision's ranges, until the user happened to select or close
    /// it.
    ///
    /// Immediate rather than debounced, for the same reason a tab switch is: a
    /// resync touches a bounded set of files, not a burst of keystrokes. The
    /// selected tab is re-indexed twice (here and from its own editor) and that is
    /// harmless — the second scheduling supersedes the first under the same key.
    private func reindexReloadedBuffer(id: UUID, url: URL) {
        guard let text = model.text(for: id) else { return }
        // The replacement is wholesale for the diagnostics channel too (D32):
        // the document's set is dropped outright and its sync record with it,
        // so a push computed against the pre-replacement text can no longer
        // pass the acceptance gate. A background tab has no editor view whose
        // content-replaced path would say this — this funnel is the only place
        // that sees every rewritten tab (Replace All's buffer writes and the
        // worktree resyncs alike). Clearing *before* the immediate re-sync
        // below lets its push land against the fresh record.
        diagnostics.noteBufferReplaced(url: url)
        let language = SyntaxLanguage(forFileName: url.lastPathComponent)
        symbolIndexController.noteBufferOpened(url: url, text: text, language: language)
        // The push channel rides the same immediate trigger: the server must be
        // told the replacement before it can re-diagnose the file (D30), and a
        // resync touches a bounded set of files, not a burst.
        lspDocumentSync.noteBufferOpened(url: url, text: text, language: language)
    }

    /// Tell the symbol index that the project's files changed on disk — the
    /// index's counterpart to `model.bumpTreeRevision()`, and called beside it.
    ///
    /// The watcher covers everything a *child* process writes (every
    /// `GitCLIService` run, the embedded terminal), but
    /// `kFSEventStreamCreateFlagIgnoreSelf` drops the app's own writes, so the
    /// mutations this process performs itself have to say so — for the index for
    /// exactly the reason `ProjectWatcher` already spells out for the tree. Without
    /// it the stamp-gated refresh, which is the only thing that re-extracts a
    /// rewritten file and the only thing that *removes* a vanished one, would never
    /// run for a rename, a delete or a Replace All: a renamed file would go on
    /// answering Go to Definition under a path that no longer exists, and a
    /// project-wide replace would keep serving the identifiers it just replaced,
    /// until some unrelated child process happened to touch the tree.
    ///
    /// Cheap enough to call unconditionally: it is debounced 500 ms, the walk that
    /// follows re-reads only files whose stamp changed, and it takes no writer gate
    /// (the index is a reader — see `SymbolIndexModel`).
    ///
    /// Not every `bumpTreeRevision()` needs one, which is why this is a separate
    /// call rather than folded into that one: `newFile`/`newFolder` write an empty
    /// file (or none at all) and `newFile` opens a tab for it, so the buffer
    /// re-index already covers everything there is to index; an ordinary save and
    /// the autosave's recreating save rewrite a file a tab still owns, and a
    /// buffer-sourced entry is exactly what a refresh declines to touch.
    private func notifyIndexOfProjectFileChanges() {
        // The `.editorconfig` cache rides along, for the same reason and with the
        // same coverage hole to fill: `kFSEventStreamCreateFlagIgnoreSelf` drops
        // every event this process causes, so the watcher callback that is
        // otherwise this cache's whole lifecycle never sees the app's *own*
        // worktree rewrites — a revert's in-process `unlinkat`, a merge apply, a
        // project-wide Replace All, a rename or a delete of a `.editorconfig`.
        // Not a branch switch: `git` runs as a *subprocess* there, so `IgnoreSelf`
        // does not drop its events and the watcher callback is what covers it —
        // which is why `finishBranchOperation` calls nothing here. (The iOS peer
        // does have to cover it: libgit2 runs in-process.)
        // Dropped wholesale and unconditionally, ahead of the root guard: clearing
        // a dictionary costs nothing and, unlike the index, it needs no root to be
        // told anything. The iOS peer says the same thing in `RootView_iOS`.
        editorConfig.noteProjectFilesChanged()
        guard let root = model.projectRoot else { return }
        symbolIndexController.noteProjectFilesChanged(root: root)
    }

    /// Drop the `.editorconfig` cache when a write just landed on one.
    ///
    /// The watcher cannot cover this: an ordinary save is a *self*-generated event
    /// and `IgnoreSelf` drops it, so editing a `.editorconfig` in Pisaka itself —
    /// the likeliest way anyone changes one — would otherwise keep serving the
    /// pre-edit properties for the rest of the session. Narrow on purpose: an
    /// ordinary save of an ordinary file is the most frequent write the app makes,
    /// and throwing the cache away on each one would put a resolution walk on the
    /// next keystroke after every autosave burst.
    /// The name test folds case (`EditorConfigResolver.isFileName(_:)`) because
    /// the resolver reads the file through a case-insensitive filesystem: an
    /// exact comparison would serve a `.EditorConfig` from cache long after it
    /// was edited here.
    private func noteEditorConfigWrites(_ urls: [URL]) {
        guard urls.contains(where: { EditorConfigResolver.isFileName($0.lastPathComponent) }) else { return }
        editorConfig.noteProjectFilesChanged()
    }
}

#endif
