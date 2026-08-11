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
        let workspace = WorkspaceModel()
        _model = StateObject(wrappedValue: workspace)
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
            for file in workspace.openFiles {
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
        symbolIndexController.installProvider(
            RoutingIntelligenceProvider(
                lsp: LSPIntelligenceProvider(workspace: lspWorkspace),
                fallback: symbolIndex.provider
            )
        )
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
        provisioning.onRegistryChange = { @MainActor [lspWorkspace, gopls, rust] registry in
            await lspWorkspace.updateRegistry(
                LSPServerRegistry(registry.descriptions + gopls.descriptions + rust.descriptions)
            )
        }
        gopls.onDescriptionsChange = { @MainActor [lspWorkspace, provisioning, rust] descriptions in
            await lspWorkspace.updateRegistry(
                LSPServerRegistry(
                    provisioning.registry.descriptions + descriptions + rust.descriptions
                )
            )
        }
        rust.onDescriptionsChange = { @MainActor [lspWorkspace, provisioning, gopls] descriptions in
            await lspWorkspace.updateRegistry(
                LSPServerRegistry(
                    provisioning.registry.descriptions + gopls.descriptions + descriptions
                )
            )
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
    @State private var bottomPanel: BottomPanel? = nil

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
                onClose: { closeFile(id: $0) },
                onOpenFile: { openFile(url: $0) },
                onOpenFolder: { openFolder() },
                onRevert: { revertChanges(contextFile: $0) },
                onOpenDiff: { openLocalChangesDiff($0) },
                onOpenCommitDiff: { openCommitDiff($0, in: $1) },
                onResolveConflict: { resolveConflict($0) },
                onSwitchBranch: { switchBranch($0) },
                onCreateBranchFromRemote: { createBranchFromRemote($0) },
                onCheckoutRemote: { checkoutRemote($0) },
                onNewBranch: { newBranch() },
                onNewFile: { newFile(in: $0) },
                onNewFolder: { newFolder(in: $0) },
                onRename: { renameItem(at: $0) },
                onDelete: { deleteItem(at: $0) },
                onRun: { runFile(url: $0) },
                onRunTest: { testFile(url: $0) },
                isCommitDialogPresented: $isCommitDialogPresented,
                onOpenCommitDialog: { openCommitDialog() },
                onCommitFile: { file in openCommitDialog(preselectingPath: file.path) },
                onCommit: { origin in await commitFromDialog(originGeneration: origin) },
                onCommitDialogDismissed: { autosave.resumeFromModal() }
            )
            // The LeetCode sheets, attached *outside* `ContentView` rather than
            // inside it: the window content already presents the commit dialog
            // from its own body, and these are raised by menu commands this
            // scene owns. Keeping them here means `ContentView` gains no
            // parameter for them and no reason to observe `leetCode` — which is
            // the whole point of the model being a non-observed `let` above.
            .sheet(item: $leetCodeSheet) { sheet in
                switch sheet {
                case .signIn:
                    LeetCodeLoginView(model: leetCode, onDismiss: { leetCodeSheet = nil })
                case .openProblem:
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
            .onAppear {
                // Start once. `onSaved` reuses `refreshLocalChanges()` so an
                // autosave re-runs `git status` through the same generation-pinning
                // as a manual save, rather than duplicating that logic. Its
                // `createdFile` flag additionally bumps the tree when an autosave
                // *recreated* a file that had been deleted out of band — the watcher
                // ignores our own writes, so nothing else would put it back in the
                // listing (the same reason `saveAs` bumps explicitly).
                autosave.start(model: model, onSaved: { createdFile in
                    refreshLocalChanges()
                    if createdFile { model.bumpTreeRevision() }
                })

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
                        sourceViewers.closeAll()
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
                    // called twice on the same quit is harmless.
                    autosave.flushNow()
                    sessionController.flushNow()
                }
            }
        }
        .commands {
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
            }

            CommandMenu("View") {
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
                Button("Complete") { completeAtCaret() }
                    .disabled(model.selectedID == nil)
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
    private func openLeetCodeProblem(
        input: LeetCodeProblemInput,
        language: LeetCodeLanguage
    ) async -> String? {
        // Cancelling the folder panel is an answer, not a failure: the user was
        // asked where solutions go and declined to say, so the sheet stays up
        // with its sentence and nothing is fetched.
        guard LeetCodeFolderChooser.established(settings: settings, model: leetCode) != nil else {
            return LeetCodeError.folderUnavailable.errorDescription
        }
        do {
            let outcome = try await leetCode.openProblem(input: input, language: language)
            switch outcome {
            case .created(let solution), .resumed(let solution):
                leetCodeSheet = nil
                openLeetCodeSolution(solution, wasCreated: outcome.wasCreated)
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
    private func openLeetCodeSolution(_ solution: LeetCodeSolution, wasCreated: Bool) {
        do {
            try model.open(url: solution.url)
        } catch {
            PlatformFeedback.warning()
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
    /// to be registered — the FSEvents watcher plus Local Changes, the Git Log, the
    /// branch switcher and Project Search, each with the synchronous
    /// prepare-then-refresh pinning documented below.
    private func openFolder(url: URL) {
        model.openFolder(url: url)
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
        projectWatcher.start(root: url, onChange: {
            model.bumpTreeRevision()
            symbolIndexController.noteProjectFilesChanged(root: url)
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
            Task { await lspWorkspace.shutdownAll() }
        }
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
    /// The folder is opened through `openFolder(url:)` — the one path that starts
    /// the FSEvents watcher and registers the change with Local Changes / the Git
    /// Log / the branch switcher / Project Search — rather than through
    /// `model.openFolder(url:)` directly, which would leave every one of those on a
    /// project the workspace has already moved to. A recorded folder that has since
    /// been deleted (or replaced by a file) is simply not opened; the tabs are
    /// restored either way, since a tab does not depend on the folder's fate.
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
        if let session = sessionStore.load() {
            if let folderPath = session.folderPath, isExistingDirectory(atPath: folderPath) {
                openFolder(url: URL(fileURLWithPath: folderPath))
            }
            model.restoreSession(session)
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
        editor.completeAtCaret()
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
        let textsBeforeBatch = Dictionary(
            uniqueKeysWithValues: model.openFiles.map { ($0.id, $0.text) }
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
        for file in model.openFiles {
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
    private func save(id: UUID) -> Bool {
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
                return saveAs(id: id)
            }
            if recreatesFile { model.bumpTreeRevision() }
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
    private func saveAs(id: UUID) -> Bool {
        let suggested = model.openFiles.first { $0.id == id }?.displayName ?? "Untitled"
        guard let url = FilePanels.showSavePanel(suggestedName: suggested) else { return false }
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
        Task { @MainActor in
            // Resume autosave and lower the revert gate when the whole revert +
            // resync finishes, on every path (origin-generation mismatch, empty
            // `reverted`, or a full run).
            defer {
                autosave.resume()
                localChanges.endRevert()
            }
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
        Task { @MainActor in
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
        Task { @MainActor in
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
    private func openTabSnapshot() -> [UUID: (text: String, wasDirty: Bool)] {
        Dictionary(
            uniqueKeysWithValues: model.openFiles.map {
                ($0.id, ($0.text, model.isDirty(for: $0.id)))
            }
        )
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

    /// Create a new file inside `directory`: prompt for a *relative path* (VS
    /// Code-style — `centrifugo/config.json`, not just a single name), validate
    /// it, create any missing intermediate folders, create the file on disk, open
    /// it in a tab, then bump `treeRevision` so the tree re-reads the directory.
    ///
    /// The dialog validates *live* through `validateRelativeEntryPath(_:)`, whose
    /// `EntryPathIssue.message` is shown under the field and keeps OK disabled
    /// while the input is invalid — so an invalid path normally cannot be
    /// confirmed at all. The post-OK `parseRelativeEntryPath(_:)` guard below is
    /// kept anyway as defense-in-depth (both share one Core rule, and a
    /// programmatic path could reach here without the dialog); a `nil` result is
    /// reported through `reportInvalidName`, which explains the per-component
    /// rule. Existing intermediate folders are reused (`ensureDirectory`,
    /// `mkdir -p` semantics), but the *final* entry is never clobbered — an
    /// existing one fails with `.alreadyExists`. Any disk failure (collision, a
    /// file sitting on the path, missing/unwritable parent, write error) is
    /// surfaced non-fatally — and because `ensureDirectory` does not roll back,
    /// a multi-component failure still bumps `treeRevision` so intermediates it
    /// already created are visible instead of leaving the tree contradicting disk.
    private func newFile(in directory: URL) {
        guard !revertInFlight() else { return }
        guard let rawName = FilePanels.promptName(
            title: "New File",
            validator: { validateRelativeEntryPath($0)?.message }
        ) else { return }
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

    /// Create a new folder inside `directory`, mirroring `newFile(in:)` — the
    /// prompt likewise accepts a relative path of any depth, missing
    /// intermediates are created and existing ones reused, and the final
    /// component is never clobbered. No tab is opened for a directory. A failure
    /// refreshes the tree for the same no-rollback reason as `newFile(in:)`. The
    /// dialog likewise validates live through `validateRelativeEntryPath(_:)`,
    /// with the post-OK parse kept as defense-in-depth.
    private func newFolder(in directory: URL) {
        guard !revertInFlight() else { return }
        guard let rawName = FilePanels.promptName(
            title: "New Folder",
            validator: { validateRelativeEntryPath($0)?.message }
        ) else { return }
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

    /// Rename the file or folder at `url`: prompt pre-filled with the current
    /// name, validate, move on disk, retarget any affected open tabs via
    /// `renamePath(from:to:)`, then bump `treeRevision`. A no-op when the entered
    /// name is unchanged.
    ///
    /// The dialog validates *live* through `validateSingleEntryName(_:)` (the
    /// single-name grammar — a `/` is rejected as "a name, not a path" — with the
    /// *exact-match* reserved semantics the post-OK guard uses, so the two can
    /// never disagree), keeping OK disabled while the input is invalid. The
    /// `isValidFileName` + `isExcludedEntryName` guards below are kept as
    /// defense-in-depth over the same Core rule.
    private func renameItem(at url: URL) {
        guard !revertInFlight() else { return }
        let currentName = url.lastPathComponent
        guard let rawName = FilePanels.promptName(
            title: "Rename",
            defaultValue: currentName,
            validator: { validateSingleEntryName($0)?.message }
        ) else {
            return
        }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name != currentName else { return }
        guard isValidFileName(name) else { reportInvalidName(rawName, isPath: false); return }
        guard !FileService.isExcludedEntryName(name) else { reportReservedName(name); return }
        let destination = url.deletingLastPathComponent().appendingPathComponent(name)
        // Capture the tab-retarget plan *before* the move, while a tab opened
        // through a symlink to `url` still canonicalizes to it — once the move
        // renames the target away that symlink dangles and would no longer match.
        // Apply the plan only after the move succeeds.
        let plan = model.planRename(from: url, to: destination)
        // The paths the index still has those tabs' buffers filed under, captured
        // alongside the plan and before the move for the same reason: once
        // `applyRenamePlan` retargets a tab, its old url is no longer reachable from
        // the model. A *folder* rename retargets every tab beneath it, so this is a
        // list rather than just `url` — which alone would strand each of those files.
        let retargetedURLs = plan.compactMap { retarget in
            model.openFiles.first { $0.id == retarget.id }?.url
        }
        do {
            try fileService.move(from: url, to: destination)
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
    /// The two call sites have different grammars, so the text does too. The
    /// create dialogs (`isPath: true`) treat a slash as a path separator, so the
    /// message explains the *per-component* rule. Rename (`isPath: false`) still
    /// takes a single name and rejects any slash outright — a path there would be
    /// a move, a separate feature — so it must not be told that slashes separate
    /// folders.
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
            if save(id: id) {
                model.close(id: id)
            }
        case .dontSave:
            model.close(id: id, force: true)
        case .cancel:
            break
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
        symbolIndexController.noteBufferOpened(
            url: url,
            text: text,
            language: SyntaxLanguage(forFileName: url.lastPathComponent)
        )
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
        guard let root = model.projectRoot else { return }
        symbolIndexController.noteProjectFilesChanged(root: root)
    }
}

#endif
