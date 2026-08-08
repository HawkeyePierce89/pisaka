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
    @StateObject private var settings = SettingsStore()
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
                credentialStore: credentialStore,
                symbolIndex: symbolIndex,
                symbolIndexController: symbolIndexController
            )
        }
    }
}
#endif
