#if os(macOS)
import Foundation
import PisakaCore

/// The one place that answers "where does Local History keep its snapshots on
/// *this* platform".
///
/// `LocalHistoryLayout` is pure path math over a base directory (no `stat`, no
/// `realpath`, nothing created) precisely so that this — the platform-specific
/// half — is a handful of lines in the app rather than a `#if` inside Core; the
/// `LeetCodeSupportDirectory` shape, restated for the third such root.
///
/// **Application Support rather than Caches**, and here the reasoning is not the
/// one `LSPInstallLayout` gives (a re-download) or the one
/// `LeetCodeSupportDirectory` gives (an offline pane): these bytes are the *only*
/// copy of a text nobody else kept. A purge would silently empty the safety net
/// exactly when it is asked for, and nothing could put a single revision back.
///
/// Only on macOS, because Local History is a macOS feature end to end: there is
/// no iOS window to browse it in and no iOS caller of the capture model, so
/// building the base on that destination would create a directory nothing ever
/// writes to.
///
/// **Nothing is created here.** The returned URL is a location, not a claim that
/// anything is there; `LocalHistoryStore` calls `ensureDirectory` through
/// `FileServicing` before its first write, which is what makes a first run work
/// at all.
enum LocalHistorySupportDirectory {
    /// `…/Application Support/Pisaka/LocalHistory`.
    ///
    /// `Pisaka/` then `LocalHistory/`, so the snapshots sit *beside*
    /// `LanguageServers/` and `LeetCode/` under one app directory rather than at
    /// the top of Application Support — and `LocalHistoryLayout.directoryName` is
    /// the only component this file adds, so the "delete that directory to forget
    /// every revision" instruction has exactly one spelling.
    ///
    /// The fallback is unreachable in practice (every Mac has an Application
    /// Support directory) and exists so this is a `URL` rather than an optional
    /// threaded through the layout, the store and both models — the same shape
    /// `PisakaApp.languageServerInstallRoot` and `LeetCodeSupportDirectory` take.
    static var storeBase: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("Pisaka", isDirectory: true)
            .appendingPathComponent(LocalHistoryLayout.directoryName, isDirectory: true)
    }
}

#endif
