import Foundation
import PisakaCore

/// The one place that answers "where does the LeetCode cache live on *this*
/// platform".
///
/// `LeetCodeCacheLayout` is pure path math over a base directory (no `stat`, no
/// `realpath`, nothing created) precisely so that this — the platform-specific
/// half — is four lines in the app rather than a `#if` inside Core. Both
/// destinations answer it the same way, `FileManager`'s Application Support
/// directory in the user domain, which resolves to `~/Library/Application
/// Support` on the unsandboxed Mac and to the app container's own
/// `Library/Application Support` on iOS.
///
/// **Application Support rather than Caches**, the `LSPInstallLayout` reasoning
/// restated for a cache that genuinely *is* reconstructible: the catalog is a
/// 2 MB download and the statements are the whole content of the description
/// panel while offline, so a purge would silently turn a working airplane-mode
/// reopen into a blank pane and put a multi-megabyte fetch in front of the next
/// "Open Problem…". It is still only a cache — deleting the directory loses
/// nothing but time, which is the promise the one-base layout exists to keep.
///
/// **Nothing is created here.** The returned URL is a location, not a claim that
/// anything is there; `LeetCodeCatalog` and `LeetCodeStatementCache` each
/// `ensureDirectory` through `FileServicing` before their first write, which is
/// what makes the iOS case work at all — a fresh container has no `Application
/// Support` directory until something makes one.
enum LeetCodeSupportDirectory {
    /// `…/Application Support/Pisaka/LeetCode`.
    ///
    /// `Pisaka/` then `LeetCode/`, so this integration's cache sits *beside*
    /// `LanguageServers/` under one app directory rather than at the top of
    /// Application Support — and `LeetCodeCacheLayout.directoryName` is the only
    /// component this file adds, so the "delete that directory to forget
    /// everything" instruction has exactly one spelling.
    ///
    /// The fallback is unreachable in practice (every Apple platform has an
    /// Application Support directory) and exists so this is a `URL` rather than
    /// an optional threaded through the layout, the catalog and the model — the
    /// same shape `PisakaApp.languageServerInstallRoot` already takes.
    static var cacheBase: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("Pisaka", isDirectory: true)
            .appendingPathComponent(LeetCodeCacheLayout.directoryName, isDirectory: true)
    }

    /// The layout the model is built with, ready-made.
    static var cacheLayout: LeetCodeCacheLayout {
        LeetCodeCacheLayout(base: cacheBase)
    }
}
