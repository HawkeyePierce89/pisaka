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
    /// about spelling rather than about reach. So does a target carrying a
    /// **fragment** (`other.md#section`), which resolves to the file alone — the
    /// `#` opens a fragment in any reading of a URL, and refusing the link, or
    /// naming a file whose name ends in `#section`, would both be answers to a
    /// question the document did not ask.
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

        // A scheme-less target is still a URL, so a `#` in it opens a fragment
        // and does not belong to the file: `./other.md#usage` — the ordinary
        // shape of a cross-file link in a documentation tree — names `other.md`
        // and a place inside it. The fragment is dropped rather than carried,
        // there being nothing to carry it to (the renderer emits no `id`, a
        // stated limit), and the file is what the link is for. The `file:`
        // branch above already answers this way, `URL` reading the fragment out
        // for it; this is that same reading, by hand, for a target `URL(string:)`
        // must not be asked to parse.
        //
        // Split *before* decoding, so a literal `#` in a name — which a document
        // has to spell `%23` for any renderer at all — survives as part of it.
        let withoutFragment = String(target.prefix { $0 != "#" })

        // A Markdown destination may be percent-encoded (`a%20b.png`) and may
        // equally contain a literal `%` that decodes to nothing. Decoding is
        // therefore attempted and the raw spelling kept when it fails, which is
        // the only reading under which both files are reachable.
        let path = withoutFragment.removingPercentEncoding ?? withoutFragment
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

// MARK: - The inverse direction

extension MarkdownPreviewAsset {

    /// The project file an app-scheme URL names, or `nil` when the preview may
    /// not reach it.
    ///
    /// The exact inverse of ``assetURL(forTarget:context:)``, and deliberately
    /// **not** a lookup of what that function last produced: the page is a
    /// document, and a document can navigate to a URL its Markdown source never
    /// contained — one a script composed, one a stale body still holds, one a
    /// crafted `href` in a file someone was asked to open. So this direction
    /// re-derives the file from the URL and re-asks the containment question
    /// from scratch, against the root it is handed now.
    ///
    /// `nil` — again one outcome for every refusal — covers a URL of another
    /// scheme or another host, a path outside the project-file prefix (the shell
    /// and the bundled files are *not* project files, whatever their bytes are),
    /// an empty relative path, a `../` escape, a symlink leading out of the tree,
    /// and every URL at all when no folder is open.
    ///
    /// The answer is spelled from the **root the caller gave**, not from its
    /// canonical form, because that is the spelling the rest of the app opens
    /// tabs under; only the containment *check* is canonical.
    public static func projectFileURL(
        forPreviewURL url: URL,
        context: MarkdownDocumentContext
    ) -> URL? {
        guard let root = context.projectRoot else { return nil }
        guard url.scheme == MarkdownPreviewPage.scheme, url.host == MarkdownPreviewPage.host else {
            return nil
        }
        // `URL.path` is the percent-*decoded* path, which is the one reading that
        // round-trips `previewURL(forRelativeComponents:)`: that function let
        // Foundation encode the components once, so Foundation decodes them once
        // here and a file whose name contains a space or a `%` survives both
        // ways.
        guard url.path.hasPrefix(MarkdownPreviewPage.filePathPrefix) else { return nil }
        let relative = String(url.path.dropFirst(MarkdownPreviewPage.filePathPrefix.count))
        guard !relative.isEmpty else { return nil }

        // Appended, not resolved against the root as a base: a base URL that
        // does not end in a slash names a *file*, and resolving against it would
        // drop the root's own last component (`/p/root` + `docs/x` = `/p/docs/x`)
        // — a path that is outside the root and would simply be refused, which
        // is the kind of wrong answer that looks correct from the outside.
        //
        // `standardized`, not `standardizedFileURL`: the former removes `.` and
        // `..` lexically and nothing else, while the latter also resolves the
        // path against the file system — which would hand back a
        // `/private`-stripped spelling of a root the caller spelled with it.
        // Containment is still checked canonically below; only the *answer*
        // keeps the caller's spelling.
        let candidate = root.appendingPathComponent(relative).standardized
        guard relativeComponents(of: candidate, under: root) != nil else { return nil }
        return candidate
    }
}

// MARK: - The handler's dispatch

/// What an incoming preview-scheme request is for.
///
/// A closed answer so the app's scheme handler *dispatches* and decides nothing:
/// it neither splits a path, nor compares a scheme, nor asks whether a file is
/// inside the project — all four of those questions are settled here, in the
/// same file that composed the URL in the first place. Anything not one of the
/// three served kinds is ``refused``, which the handler answers as a plain 404:
/// not an error, not a log line, and never a partial answer.
public enum MarkdownPreviewRequest: Equatable, Sendable {

    /// The shell document itself — the one thing served as HTML.
    case shell

    /// One of the bundled files, by its exact name. Only a name
    /// ``MarkdownPreviewPage/bundledFileNames`` lists is ever answered, so the
    /// handler cannot be asked for an arbitrary path inside the app bundle.
    case bundled(name: String)

    /// A project file, already resolved and already checked against the root by
    /// ``MarkdownPreviewAsset/projectFileURL(forPreviewURL:context:)``.
    case asset(fileURL: URL)

    /// Everything else.
    case refused
}

extension MarkdownPreviewAsset {

    /// What the scheme handler should answer for `url`.
    public static func classify(_ url: URL, context: MarkdownDocumentContext) -> MarkdownPreviewRequest {
        guard url.scheme == MarkdownPreviewPage.scheme, url.host == MarkdownPreviewPage.host else {
            return .refused
        }
        let path = url.path
        if path == MarkdownPreviewPage.shellPath { return .shell }
        if path.hasPrefix(MarkdownPreviewPage.bundledPathPrefix) {
            let name = String(path.dropFirst(MarkdownPreviewPage.bundledPathPrefix.count))
            // Membership, not existence: the set is fixed at build time, so a
            // name outside it is refused without touching the bundle, and a
            // nested path (`…/assets/../../secret`) is refused for being no
            // member rather than for looking like an escape.
            guard MarkdownPreviewPage.bundledFileNames.contains(name) else { return .refused }
            return .bundled(name: name)
        }
        guard let fileURL = projectFileURL(forPreviewURL: url, context: context) else { return .refused }
        return .asset(fileURL: fileURL)
    }
}
