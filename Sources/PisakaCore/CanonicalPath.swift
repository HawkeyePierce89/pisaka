import Foundation

/// The single source of truth for the two path questions the app keeps asking:
/// *"do these two urls name the same file?"* and *"does this file live inside
/// this directory?"*.
///
/// `WorkspaceModel` matches open tabs against a url in several places —
/// `open(url:)`, `fileID(forURL:)`, `entryMatch(fileURL:operation:)` (rename and
/// delete reconciliation) — and the breadcrumb `DisplayPath` asks the same
/// questions about a tab and the opened project root. Those answers must agree:
/// a file the model considers "already open" but the breadcrumb considers
/// outside the root (or vice versa) is a silent inconsistency. So the primitives
/// live here once and every caller delegates, rather than each keeping a private
/// copy that can drift.
///
/// Foundation-only and purely lexical apart from `canonical(_:)`'s symlink
/// resolution, so it stays testable in Core.
enum CanonicalPath {

    /// Canonical form of a url for identity comparison: resolves symlinks and
    /// standardizes the path so `/tmp` vs `/private/tmp`, trailing slashes, and
    /// `.`/`..` components all compare equal.
    ///
    /// Note on `resolvingSymlinksInPath()`: it resolves ordinary symlinks but
    /// deliberately *strips* a `/private` prefix, mapping `/private/tmp` back to
    /// `/tmp` — so it is **not** a true `realpath(3)`. That is harmless here
    /// because both sides of every comparison go through this same transform, so
    /// a firmlinked path is spelled the same way on both sides and still
    /// matches; what this function guarantees is *consistency*, not true
    /// canonicality.
    ///
    /// Do **not** "fix" this to `realpath(3)`. `ProjectWatcher.canonical(_:)`
    /// does use `realpath` and is right to: *its* comparison is one-sided —
    /// FSEvents supplies an already-realpath-spelled path that cannot be
    /// re-transformed, so a `/private`-stripped root would never match it.
    /// Switching *this* helper would instead desynchronize it from the urls
    /// `WorkspaceModel.fileID(forURL:)`/`open(url:)`/`entryMatch(fileURL:
    /// operation:)` have been matching all along — exactly the drift this shared
    /// helper exists to prevent.
    static func canonical(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// If `components` live strictly under `ancestorComponents`, the trailing
    /// components (the part below the ancestor); otherwise `nil`.
    ///
    /// Compares whole path *components*, so `/p/rootx` is not under `/p/root`
    /// the way a raw string prefix check would have it. "Strictly" under: equal
    /// paths yield `nil`, since the ancestor is not inside itself. Used to
    /// detect and rewrite tabs nested inside a renamed/deleted folder, and to
    /// build the breadcrumb suffix below the project root.
    static func relativeComponents(
        of components: [String],
        under ancestorComponents: [String]
    ) -> [String]? {
        guard components.count > ancestorComponents.count else { return nil }
        guard Array(components.prefix(ancestorComponents.count)) == ancestorComponents else {
            return nil
        }
        return Array(components.dropFirst(ancestorComponents.count))
    }
}
