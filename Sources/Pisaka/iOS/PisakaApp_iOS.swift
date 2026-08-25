#if os(iOS)
import SwiftUI
import PisakaCore

/// The iOS / iPadOS entry point. Owns the shared Core models and the iOS file-
/// access wiring, then hands them to the adaptive `RootView_iOS`. The macOS app
/// (`PisakaApp` in `PisakaApp.swift`) is gated to `#if os(macOS)`, so exactly one
/// `@main` is active per platform.
///
/// File I/O on iOS goes through a `SecurityScopedFileService` decorator (so reads
/// and autosave writes are bracketed by the opened folder/file's security-scoped
/// access grant); the `WorkspaceModel` is constructed over it. `FileAccessController`
/// ties document-picker results and restored bookmarks to the model.
@main
struct PisakaApp_iOS: App {
    @StateObject private var model: WorkspaceModel
    /// Built in `init` rather than inline, for the reason the macOS `PisakaApp`
    /// records: the LeetCode model is composed from it (the folder it remembers),
    /// so a value has to exist before the `StateObject` wrapper is made.
    @StateObject private var settings: SettingsStore
    @StateObject private var fileAccess: FileAccessController
    @StateObject private var localChanges: LocalChangesModel
    @StateObject private var commitLog: CommitLogModel
    @StateObject private var branchSwitcher: BranchSwitcherModel

    /// The shared scoped file service (registered with the opened folder), passed to
    /// the root so a merge apply writes the resolved file through the same security
    /// scope as the workspace's reads/writes.
    private let scopedService: SecurityScopedFileService

    /// The shared Keychain-backed PAT store — supplied to the branch-switcher's
    /// libgit2 service (so an HTTPS fetch of a private repo can authenticate) and to
    /// the root (so Settings can manage the tokens).
    private let credentialStore: KeychainCredentialStore

    /// The project-wide symbol index behind go-to-definition and completion, and the
    /// controller that schedules its incremental work — the iOS peers of the macOS
    /// `PisakaApp` properties, constructed the same way from the same synchronous
    /// `SymbolExtractor` function.
    ///
    /// Plain stored properties rather than `@StateObject` for the reason the macOS
    /// app records: the model republishes its index after *every chunk* of a walk,
    /// and subscribing this scene's `body` to that would rebuild the whole root view
    /// dozens of times while a project is indexed, for a value no view reads.
    ///
    /// iOS has **no file-system watcher**, so nothing here refreshes on a genuinely
    /// *external* change (Files.app, another app's share extension) — stated rather
    /// than worked around. The index moves forward on folder open, tab open, buffer
    /// edits, and the working-tree rewrites the app performs itself, which it knows
    /// about and reports through `RootView_iOS.notifyIndexOfProjectFileChanges`.
    private let symbolIndex: SymbolIndexModel
    private let symbolIndexController: SymbolIndexController

    /// What `.editorconfig` says about the file being edited — the cache behind
    /// Enter's indentation unit and the Tab key, and the iOS peer of the macOS
    /// `PisakaApp.editorConfig`.
    ///
    /// A plain stored property for the reason the two above record: it publishes
    /// nothing, so observing it would put this scene's `body` — and with it the
    /// whole root view — on an update path for a value no view shows. It is
    /// threaded straight through `RootView_iOS` to the editor, which is the only
    /// thing that asks it anything.
    ///
    /// **A reader**, like the index: it opens files and writes none, so it neither
    /// raises the disk-writer gate nor is gated by it. And like the index it has
    /// no file-system watcher to lean on, so its cache is dropped from the
    /// boundaries this platform *does* know about — the root switch, the worktree
    /// rewrites the app performs itself, and the one save iOS has, which is the
    /// likeliest way a `.editorconfig` changes at all (`RootView_iOS`). An
    /// out-of-band edit to a `.editorconfig` (Files.app, a share extension) stays a
    /// stated limit, exactly as it is for the index.
    private let editorConfig: EditorConfigModel

    /// Who is signed in to LeetCode, the open-problem operation, and the statement
    /// for the active tab.
    ///
    /// A plain `let` for the same reason as the two above and as its macOS
    /// counterpart: the model republishes on every busy transition and every
    /// statement fetch, and this scene's `body` reads nothing on it. The surfaces
    /// that show its state observe it themselves.
    private let leetCode: LeetCodeModel

    init() {
        // The scoped service decorates a real `FileService`; the workspace model
        // reads/writes through it so every file op is bracketed by the covering
        // security scope.
        let scopedService = SecurityScopedFileService()
        self.scopedService = scopedService
        // Assigned via a local (like `scopedService`) so the `StateObject`
        // autoclosures below capture the value, not the still-initializing `self`.
        let credentialStore = KeychainCredentialStore()
        self.credentialStore = credentialStore
        let model = WorkspaceModel(fileService: scopedService)
        let bookmarks = BookmarkStore()
        let settings = SettingsStore()
        _settings = StateObject(wrappedValue: settings)
        // The LeetCode stack, composed once — the iOS peer of
        // `PisakaApp.makeLeetCode`, and deliberately *this* composition rather
        // than a second one: the transport, the Keychain store and the cache
        // layout are all cross-platform files under `Platform/`, so the only
        // thing this platform changes is the file service. It is the **scoped**
        // one, because a LeetCode folder the user picked outside the container is
        // security-scoped exactly like a picked project root, and the solution
        // write is the first thing that touches it. The cache lives in the
        // container, where the decorator simply finds no covering scope and falls
        // through.
        //
        // The folder is read out of the store here rather than at each open, so
        // the model is pointed at it before the first `openProblem` captures it;
        // `LeetCodeFolder_iOS` re-resolves it at launch (a bookmark has to be
        // resolved and registered, which a `SettingsStore` cannot do) and writes
        // both halves whenever the user changes it.
        //
        // Building one talks to nothing: `URLSession` opens no connection until a
        // request is made, and the Keychain is read exactly once, in
        // `LeetCodeModel.init`, to decide whether to show "signed in" before the
        // launch-time confirmation lands.
        self.leetCode = LeetCodeModel(
            transport: LeetCodeURLSessionTransport(),
            credentialStore: LeetCodeKeychainStore(),
            fileService: scopedService,
            cacheLayout: LeetCodeSupportDirectory.cacheLayout,
            solutionsFolder: settings.leetCodeFolderURL
        )
        _model = StateObject(wrappedValue: model)
        _fileAccess = StateObject(
            wrappedValue: FileAccessController(
                model: model,
                scopedService: scopedService,
                bookmarks: bookmarks
            )
        )
        // Local Changes is backed by the libgit2 service (the iOS peer of
        // `GitCLIService`) and shares the same scoped `FileService` so its
        // working-copy reads/writes are likewise bracketed by the security scope.
        // The libgit2 service also takes the scoped service as its scope provider so
        // its direct repository/working-tree access runs under the same grant.
        _localChanges = StateObject(
            wrappedValue: LocalChangesModel(
                gitService: LibGit2Service(scopeProvider: scopedService),
                fileService: scopedService
            )
        )
        // The Git Log view is backed by its own libgit2 service (read-only history
        // queries), the iOS peer of the macOS app's shared `CommitLogModel`.
        _commitLog = StateObject(
            wrappedValue: CommitLogModel(gitService: LibGit2Service(scopeProvider: scopedService))
        )
        // The branch-switcher widget is backed by its own libgit2 service (branch
        // list / current branch / checkout / create / fetch), the iOS peer of the
        // macOS app's shared `BranchSwitcherModel`. It also gets the Keychain PAT
        // store so a fetch (create-from-remote) can authenticate a private HTTPS repo.
        _branchSwitcher = StateObject(
            wrappedValue: BranchSwitcherModel(
                gitService: LibGit2Service(
                    scopeProvider: scopedService,
                    credentialStore: credentialStore
                )
            )
        )
        // The index reads through the *scoped* service like everything else, so its
        // traversal runs under the opened folder's security-scope grant; an open
        // tab's text — dirty or not — wins over the file on disk, which is the same
        // snapshot closure shape the macOS app hands both of its project models.
        // The extractor is a direct synchronous function reference: the model calls
        // it only from inside its own off-main serial queue.
        let symbolIndex = SymbolIndexModel(
            fileService: scopedService,
            openBuffers: { [weak model] in
                guard let model else { return [:] }
                var buffers: [URL: String] = [:]
                buffers.reserveCapacity(model.openFiles.count)
                for file in model.openFiles {
                    if let url = file.url { buffers[url] = file.text }
                }
                return buffers
            },
            extractSymbols: SymbolExtractor.symbols(in:language:fileURL:)
        )
        self.symbolIndex = symbolIndex
        self.symbolIndexController = SymbolIndexController(model: symbolIndex)
        // Over the *scoped* service like every other reader here, so its
        // `.editorconfig` reads run under the opened folder's security-scope grant.
        // No root yet: both folder paths — a picker open and the launch-time
        // bookmark restore — publish `projectRoot`, which is where it is recorded.
        self.editorConfig = EditorConfigModel(fileService: scopedService)
    }

    var body: some Scene {
        WindowGroup {
            RootView_iOS(
                model: model,
                settings: settings,
                fileAccess: fileAccess,
                localChanges: localChanges,
                commitLog: commitLog,
                branchSwitcher: branchSwitcher,
                fileService: scopedService,
                scopeProvider: scopedService,
                scopedService: scopedService,
                credentialStore: credentialStore,
                leetCode: leetCode,
                symbolIndex: symbolIndex,
                symbolIndexController: symbolIndexController,
                editorConfig: editorConfig
            )
        }
    }
}
#endif
