#if os(macOS)
import AppKit
import SwiftUI
import PisakaCore

/// Owns the separate, non-modal **source viewer** windows a Go to Definition opens
/// when the declaration lives outside the opened folder (D3).
///
/// The same shape as `DiffWindowController`: an `NSHostingController` inside an
/// `EscClosableWindow`, retained for its lifetime, released when the user closes it
/// (`windowWillClose`), and `closeAll()` from `willTerminateNotification` so no
/// viewer lingers past termination.
///
/// **Two deliberate differences from the diff windows.**
///
/// *It reads the file itself, before creating the window.* `DiffWindowContent`
/// loads asynchronously and shows "Loading…" because its rows come from `git show`;
/// here the whole content is one file read, and doing it up front is what lets an
/// unreadable target — a path the server named that has since moved, a permission
/// the app does not have, a binary or oversize file — be reported as *nothing
/// happened* (the caller beeps, exactly like a ⌘-click that resolved nothing)
/// rather than as an empty window the user has to close.
///
/// *It reuses a window per file.* Diff windows deliberately do not dedup, because
/// two diffs of the same file at different commits are different documents. A
/// source viewer shows a file, and ⌘-clicking three symbols in `Foundation` should
/// not leave three identical windows behind — so a second jump into a file already
/// open re-reveals its range through the same `EditorRevealState` token the editor
/// consumes and brings that window forward.
///
/// **Structurally read-only.** Nothing here creates a `WorkspaceModel` tab, touches
/// `AutosaveController`, or keeps a writable handle on the file: the content is a
/// `String` copied out of the file once. There is no code path from a viewer window
/// back to disk, which is the actual guarantee D3 is after — a semantic jump into
/// the SDK cannot write outside the project root because there is nothing to write
/// *with*, not because a flag is set correctly.
@MainActor
final class SourceViewerWindowController {

    /// One open viewer.
    private struct Viewer {
        let window: NSWindow
        /// Identity the content's reveal requests are addressed to. Fixed for the
        /// window's lifetime — one viewer shows one file.
        let fileID: UUID
        /// The window's own one-shot reveal state, so a repeat jump into this file
        /// re-scrolls it.
        let reveal: EditorRevealState
    }

    /// The open viewers, keyed by the shown file's symlink-resolved path so a
    /// second jump into the same file finds the window already showing it. Keyed by
    /// the *resolved* path for `CanonicalPath`'s reason: a server answers with the
    /// path it resolved (`/private/tmp/…` for a folder opened as `/tmp/…`), and two
    /// spellings of one file must not become two windows.
    private var viewers: [String: Viewer] = [:]

    /// One `NSWindowDelegate` per window, forwarding `windowWillClose` back so the
    /// window is released. Held alongside the window because `NSWindow.delegate` is
    /// `weak` (the `DiffWindowController` rule).
    private var delegates: [ObjectIdentifier: WindowDelegate] = [:]

    /// Show `fileURL` read-only and scroll to `range`, reusing the window already
    /// showing that file when there is one.
    ///
    /// Returns `false` — having done nothing at all — when the file cannot be read,
    /// which is the caller's cue to beep.
    @discardableResult
    func open(fileURL: URL, range: NSRange, settings: SettingsStore) -> Bool {
        let key = Self.key(for: fileURL)

        if let existing = viewers[key] {
            existing.reveal.reveal(fileID: existing.fileID, range: range)
            existing.window.makeKeyAndOrderFront(nil)
            return true
        }

        guard let text = Self.readText(at: fileURL) else { return false }

        let fileID = UUID()
        let reveal = EditorRevealState()
        // Record the reveal *before* the content exists: the pane consumes it on
        // its first update, which is the same update that installs the text — the
        // ordering `EditorRevealState` was designed around.
        reveal.reveal(fileID: fileID, range: range)

        let content = SourceViewerContent(
            fileID: fileID,
            fileName: fileURL.lastPathComponent,
            text: text,
            settings: settings,
            reveal: reveal
        )
        let hosting = NSHostingController(rootView: content)
        let window = EscClosableWindow(contentViewController: hosting)
        window.title = fileURL.lastPathComponent
        // Says what the window is in the one place the user is already looking.
        window.subtitle = "Read-Only"
        // The proxy icon and its Cmd-click path popup, so "which SDK is this
        // interface from?" is answerable without a Finder trip.
        window.representedURL = fileURL
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 800, height: 700))
        window.center()

        let delegate = WindowDelegate { [weak self] closed in
            self?.release(closed)
        }
        window.delegate = delegate
        delegates[ObjectIdentifier(window)] = delegate
        viewers[key] = Viewer(window: window, fileID: fileID, reveal: reveal)

        window.makeKeyAndOrderFront(nil)
        return true
    }

    /// Close every open viewer (app-termination path), mirroring
    /// `DiffWindowController.closeAll()`.
    func closeAll() {
        for viewer in viewers.values {
            viewer.window.delegate = nil
            viewer.window.close()
        }
        viewers.removeAll()
        delegates.removeAll()
    }

    /// Drop a window the user closed from the retained set.
    private func release(_ window: NSWindow) {
        viewers = viewers.filter { $0.value.window !== window }
        delegates[ObjectIdentifier(window)] = nil
    }

    /// The file's contents, or `nil` when it should not be shown.
    ///
    /// Read through the same `FileServicing` door — and under the same byte cap —
    /// that `LSPIntelligenceProvider` already used to turn the server's
    /// `(line, character)` answer into a buffer offset. Sharing the limit is the
    /// point: a file the provider refused to read produced no candidate at all, so
    /// the viewer can never be asked for something larger than that, and a file it
    /// did read is one this can show.
    private static func readText(at url: URL) -> String? {
        (try? FileService().readTextIfNotBinary(
            url: url,
            maxBytes: LSPIntelligenceProvider.maximumTargetFileBytes
        )) ?? nil
    }

    /// The dedup key: the file's symlink-resolved, standardized path.
    private static func key(for url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Forwards `windowWillClose` to the controller's release hook.
    private final class WindowDelegate: NSObject, NSWindowDelegate {
        private let onClose: (NSWindow) -> Void

        init(onClose: @escaping (NSWindow) -> Void) {
            self.onClose = onClose
        }

        func windowWillClose(_ notification: Notification) {
            guard let window = notification.object as? NSWindow else { return }
            onClose(window)
        }
    }
}

#endif
