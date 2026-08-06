#if os(iOS)
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import PisakaCore

/// A SwiftUI wrapper over `UIDocumentPickerViewController` for opening a folder or
/// a file on iOS — the iOS peer of the macOS `FilePanels` open panels. The picker
/// returns a security-scoped url; the caller maps it into the workspace via
/// `FileAccessController` (which persists the bookmark and starts scoped access).
///
/// `mode` selects what can be chosen (a folder, or any file); `onPick` receives
/// the chosen url (a single selection — `allowsMultipleSelection` is off), and the
/// view is dismissed by the binding the presenter drives.
struct DocumentPicker: UIViewControllerRepresentable {
    enum Mode {
        /// Choose a directory (the project root).
        case folder
        /// Choose a single file to open as a tab.
        case file
    }

    let mode: Mode
    let onPick: (URL) -> Void
    var onCancel: () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let contentTypes: [UTType]
        switch mode {
        case .folder:
            contentTypes = [.folder]
        case .file:
            // Permit any file — a code editor opens many types; the language is
            // resolved from the extension downstream.
            contentTypes = [.item]
        }
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: contentTypes,
            asCopy: false
        )
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {
        // Static configuration; nothing to update across SwiftUI passes.
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onPick: (URL) -> Void
        private let onCancel: () -> Void

        init(onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { onCancel(); return }
            onPick(url)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel()
        }
    }
}

/// Ties document-picker results (and restored bookmarks) to the shared
/// `WorkspaceModel`: it registers the security-scoped url with the
/// `SecurityScopedFileService` so subsequent `FileService` I/O is bracketed,
/// persists/refreshes the folder bookmark via `BookmarkStore`, and finally calls
/// `WorkspaceModel.openFolder`/`open(url:)`.
///
/// View-layer wiring only — all the testable ordering/path logic lives in
/// `PisakaCore.ScopedFileAccess`/`BookmarkStore`. The app (Task 6) constructs the
/// `WorkspaceModel` with the `SecurityScopedFileService` so the model's reads and
/// autosave writes flow through the scoped service.
@MainActor
final class FileAccessController: ObservableObject {
    private let model: WorkspaceModel
    private let scopedService: SecurityScopedFileService
    private let bookmarks: BookmarkStore
    /// The currently-registered project-root scope, released when a different folder
    /// opens so stale ancestor grants don't accumulate in the service's registry (an
    /// old, now-unreachable root could otherwise still cover a later target) — but
    /// *only* when no open tab still lives under it. `WorkspaceModel.openFolder`
    /// deliberately leaves open tabs untouched on a folder switch, so a file opened
    /// from the previous project tree (which has no standalone scope of its own — it
    /// relied on the root's grant) would otherwise lose all disk access after the
    /// switch and fail to save/reload on device. Scopes for standalone opened files
    /// are likewise left registered — their tabs may outlive a folder switch.
    private var registeredRoot: URL?

    init(model: WorkspaceModel, scopedService: SecurityScopedFileService, bookmarks: BookmarkStore) {
        self.model = model
        self.scopedService = scopedService
        self.bookmarks = bookmarks
    }

    /// Open `url` (from the folder picker or a resolved bookmark) as the project
    /// root: release the previous root's scope, register the new one, persist a fresh
    /// bookmark, and set the model's `projectRoot`.
    func openFolder(at url: URL) {
        let standardized = url.standardizedFileURL
        if let previous = registeredRoot, previous != standardized,
           !hasOpenTab(under: previous) {
            scopedService.unregister(previous)
        }
        scopedService.register(url)
        registeredRoot = standardized
        if let data = SecurityScopedBookmarks.makeBookmark(for: url) {
            bookmarks.rememberFolder(bookmark: data, path: standardized.path)
        }
        model.openFolder(url: url)
    }

    /// Open `url` (from the file picker) as a tab: register its scope so the
    /// initial read — and later autosave writes — are bracketed, then open it.
    func openFile(at url: URL) {
        scopedService.register(url)
        do {
            try model.open(url: url)
        } catch {
            PlatformFeedback.warning()
        }
    }

    /// Reopen the most-recently-opened folder on launch by resolving its persisted
    /// bookmark. A bookmark that no longer resolves is forgotten; a stale-but-usable
    /// one is refreshed. No-op when there are no recents.
    func restoreLastFolder() {
        guard let recent = bookmarks.folders().first else { return }
        var isStale = false
        guard let url = SecurityScopedBookmarks.resolve(recent.bookmark, isStale: &isStale) else {
            bookmarks.forgetFolder(path: recent.path)
            return
        }
        openFolder(at: url)
        // `openFolder` already re-bookmarks (refreshing a stale blob), so no extra
        // handling is needed for `isStale` here.
        _ = isStale
    }

    /// Whether any still-open tab's file lives at or under `root` — so `root`'s
    /// security scope must stay registered after a folder switch (the tab can still
    /// be saved/reloaded). Uses the same trailing-slash-normalized ancestor check the
    /// scoped service uses to find a covering scope.
    private func hasOpenTab(under root: URL) -> Bool {
        let rootPath = root.path
        return model.openFiles.contains { file in
            guard let fileURL = file.url else { return false }
            return ScopedFileAccess.path(fileURL.standardizedFileURL.path, isWithin: rootPath)
        }
    }
}
#endif
