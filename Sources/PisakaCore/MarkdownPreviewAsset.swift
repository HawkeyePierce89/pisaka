import Foundation

/// Which document the preview is showing, and where the project it belongs to
/// begins.
///
/// Two optionals rather than two values, because both are genuinely absent
/// sometimes: a Markdown buffer can be rendered before it has ever been saved,
/// and the app can be running with no folder open. Absence is not a degenerate
/// case to be papered over — it is what makes every relative target
/// unresolvable, which is the honest answer (a relative path has nothing to be
/// relative *to*), so the rules below return nothing rather than guessing at a
/// base.
public struct MarkdownDocumentContext: Equatable, Sendable {

    /// The Markdown file being previewed. `nil` for a buffer with no file yet.
    public let documentURL: URL?

    /// The opened project's root. `nil` when no folder is open.
    public let projectRoot: URL?

    public init(documentURL: URL?, projectRoot: URL?) {
        self.documentURL = documentURL
        self.projectRoot = projectRoot
    }

    /// The context of a document with neither — what the preview holds before
    /// it has been pointed at anything.
    public static let none = MarkdownDocumentContext(documentURL: nil, projectRoot: nil)
}

/// The mapping between a Markdown document's own spelling of a target and the
/// app-scheme URL the preview page may reach it through.
///
/// The forward direction is what the renderer emits into the page: a relative
/// `src`/`href` becomes an app-scheme URL **only** when it resolves, after
/// symlinks, to a file inside the opened project root. Everything else is
/// emitted exactly as the source spelled it, which renders as a broken image
/// showing its alt text and, for a link, as a target the navigation rule
/// refuses. There is deliberately no third outcome: nothing is silently
/// rewritten into something else, and nothing is dropped, because a dropped
/// image is indistinguishable from a document that never had one.
///
/// The root check is the whole security property of the feature's file access.
/// It is made **canonically** — `CanonicalPath.canonical(_:)`, so symlinks are
/// resolved on both sides and compared component by component — because a
/// lexical check answers yes for `root/link/../../../etc/passwd` and for a
/// symlink inside the tree pointing anywhere at all. It is made *here*, once,
/// in the direction that composes the URL, and made again in the inverse
/// direction that consumes one, since a page can spell a URL its document never
/// contained.
public enum MarkdownPreviewAsset {

    /// The app-scheme URL for `target` as a document spelled it, or `nil` when
    /// the preview may not reach it.
    ///
    /// `nil` — the unresolved answer — covers, deliberately as one outcome:
    ///
    /// * a target with any scheme other than `file` (`http`, `https`,
    ///   `mailto`, `data`, `javascript`, and the app's own scheme, which a
    ///   document has no business spelling);
    /// * a fragment-only target (`#section`), which addresses this page and is
    ///   not a file at all;
    /// * a `../` escape, or a symlink pointing out of the tree;
    /// * an absolute path — `file:` or a leading `/` — landing outside the root;
    /// * every target in a document with no URL or in a window with no project
    ///   root, there being no base to resolve against.
    ///
    /// An **absolute** target inside the root does resolve: it is a file in the
    /// project the same way a relative one is, and refusing it would be a rule
    /// about spelling rather than about reach.
    public static func assetURL(forTarget target: String, context: MarkdownDocumentContext) -> URL? {
        guard let documentURL = context.documentURL, let root = context.projectRoot else { return nil }
        guard let fileURL = fileURL(forTarget: target, documentURL: documentURL) else { return nil }
        guard let relative = relativeComponents(of: fileURL, under: root) else { return nil }
        return previewURL(forRelativeComponents: relative)
    }

    /// The file `target` names, resolved against the document's own directory —
    /// before any question of whether the preview may reach it.
    ///
    /// Split out because the containment check is the interesting half and reads
    /// better without the parsing in front of it.
    private static func fileURL(forTarget target: String, documentURL: URL) -> URL? {
        guard !target.isEmpty, !target.hasPrefix("#") else { return nil }

        // A parsed scheme is the one thing that settles the question outright.
        // `URL(string:)` is only consulted for the scheme: it is the component
        // Foundation reads the same way WebKit does, and reading the *path* back
        // out of it would re-encode a target that was never encoded to begin
        // with.
        if let scheme = URL(string: target)?.scheme, !scheme.isEmpty {
            guard scheme == "file", let absolute = URL(string: target) else { return nil }
            return absolute.standardizedFileURL
        }

        // A Markdown destination may be percent-encoded (`a%20b.png`) and may
        // equally contain a literal `%` that decodes to nothing. Decoding is
        // therefore attempted and the raw spelling kept when it fails, which is
        // the only reading under which both files are reachable.
        let path = target.removingPercentEncoding ?? target
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        let base = documentURL.standardizedFileURL.deletingLastPathComponent()
        return URL(fileURLWithPath: path, relativeTo: base).standardizedFileURL
    }

    /// `fileURL`'s path components below `root`, canonically — or `nil` when it
    /// does not live under it.
    ///
    /// The components come from the *canonical* pair, so a file reached through
    /// a symlinked ancestor is named by where it actually is. Joining those
    /// components back onto the root the caller spelled reaches the same file,
    /// since that is what the symlink means; naming it canonically is what keeps
    /// the round trip a function rather than a coincidence.
    private static func relativeComponents(of fileURL: URL, under root: URL) -> [String]? {
        CanonicalPath.relativeComponents(
            of: CanonicalPath.canonical(fileURL).pathComponents,
            under: CanonicalPath.canonical(root).pathComponents
        )
    }

    /// The app-scheme URL a project-relative path answers under.
    ///
    /// Composed through `URLComponents` so the path is percent-encoded once, by
    /// Foundation, rather than by a hand-written escape that has to agree with
    /// WebKit's decoder.
    private static func previewURL(forRelativeComponents components: [String]) -> URL? {
        var url = URLComponents()
        url.scheme = MarkdownPreviewPage.scheme
        url.host = MarkdownPreviewPage.host
        url.path = MarkdownPreviewPage.filePathPrefix + components.joined(separator: "/")
        return url.url
    }
}
