import Foundation

/// The breadcrumb segments shown above the editor for the open file — the path
/// relative to the opened project root (`backend › src › dialogs.service.ts`),
/// or an abbreviated absolute path when the file lives outside it.
///
/// Pure and Foundation-only: `home` is passed in by the view layer rather than
/// read from `FileManager` here, the `TerminalLaunch.workingDirectory(
/// projectRoot:home:)` precedent, so the whole decision stays testable in Core.
/// The segments are *names* only — the leading `/` is never a segment, so
/// joining them with a separator can't produce `/ › Volumes › …`; the view
/// chooses the separator.
public enum DisplayPath {

    /// Breadcrumb segments for `fileURL`, in order from the outermost to the
    /// file itself.
    ///
    /// - A url-less buffer yields `["Untitled"]`, matching
    ///   `OpenFile.displayName` so the bar and the tab agree (the literal is
    ///   duplicated rather than shared; a test pins the two together).
    /// - A file strictly under `projectRoot` yields the suffix below the root —
    ///   without the root's own name, ending in the file name.
    /// - Anything else yields the absolute path: `["~"] + suffix` when the file
    ///   is strictly under `home`, otherwise the plain path components.
    ///
    /// "Inside this root" is decided by `CanonicalPath` — the same primitives
    /// `WorkspaceModel.open(url:)`/`fileID(forURL:)` match tabs with — through
    /// two probes: lexical (`standardizedFileURL`, symlinks *un*resolved) first,
    /// then canonical on both sides. See `relativeComponents(of:under:)` for why
    /// that order, and why this deliberately does *not* copy
    /// `entryMatch(fileURL:operation:)`'s `entryURL` shape (parent canonicalized,
    /// final component kept literal) or its third, ancestor-walking probe: those
    /// exist because a rename/delete acts on a *named entry*, whereas a project
    /// root is a directory to descend into — canonicalizing it whole is what lets
    /// a root opened through a symlink still match a canonically spelled file.
    /// Sharing the primitives with the model is what keeps the breadcrumb from
    /// disagreeing with which tab `fileID(forURL:)`/`open(url:)` consider the
    /// same file.
    public static func components(fileURL: URL?, projectRoot: URL?, home: URL) -> [String] {
        guard let fileURL else { return ["Untitled"] }

        if let projectRoot, let suffix = relativeComponents(of: fileURL, under: projectRoot) {
            return suffix
        }
        if let suffix = relativeComponents(of: fileURL, under: home) {
            return ["~"] + suffix
        }
        return absoluteComponents(of: fileURL)
    }

    /// The components of `url` strictly below `ancestor`, or `nil` when it does
    /// not live inside it. Lexical probe first, canonical fallback.
    ///
    /// Both probes answer the same containment question — a file is inside the
    /// ancestor when *either* matches — so the order decides only which spelling
    /// is shown when both do: the lexical one, i.e. the path as the user opened
    /// it, so the bar agrees with the project tree and the tab. That matters for
    /// a symlink inside the root pointing *back* inside it (pnpm's
    /// `node_modules/foo -> .pnpm/foo@1.0.0/node_modules/foo`), where a
    /// canonical-first order would show the referent's expansion under a name the
    /// user never opened. A symlink inside the root pointing *outside* it is the
    /// same rule: only the lexical probe matches, so it stays shown where it was
    /// opened rather than as an absolute path to its referent.
    ///
    /// The canonical probe then catches what the lexical one cannot see: the two
    /// sides spelled differently (a root opened through a symlink against a
    /// canonically spelled file, and the reverse), or paths differing only by a
    /// `/private` firmlink prefix.
    private static func relativeComponents(of url: URL, under ancestor: URL) -> [String]? {
        if let suffix = CanonicalPath.relativeComponents(
            of: url.standardizedFileURL.pathComponents,
            under: ancestor.standardizedFileURL.pathComponents
        ) {
            return suffix
        }
        return CanonicalPath.relativeComponents(
            of: CanonicalPath.canonical(url).pathComponents,
            under: CanonicalPath.canonical(ancestor).pathComponents
        )
    }

    /// The standardized path of `url` as name segments, dropping the leading
    /// `/` component `URL.pathComponents` reports for an absolute path.
    private static func absoluteComponents(of url: URL) -> [String] {
        Array(url.standardizedFileURL.pathComponents.drop { $0 == "/" })
    }
}
