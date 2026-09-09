import Foundation

/// What clicking a link in the preview does.
///
/// Four answers and no fifth, so the navigation delegate is a `switch` with no
/// `default` that could quietly become a permission. In particular there is no
/// "let the web view handle it": every navigation the page attempts either
/// leaves the app (``external``), leaves the page (``openInEditor``), moves
/// within the page (``anchor``), or does not happen (``refused``). The preview
/// never navigates *itself* anywhere — the document it shows is installed once
/// and updated in place — so a navigation is always a link, and a link is always
/// one of these four.
public enum MarkdownLinkDecision: Equatable, Sendable {

    /// A `http`, `https` or `mailto` target: handed to the system, which is the
    /// only thing that may reach the network on this feature's behalf.
    case external(URL)

    /// A project file: opened as a tab, exactly as the project tree would open
    /// it. The URL is the file's, already resolved and already checked against
    /// the project root by ``MarkdownPreviewAsset/projectFileURL(forPreviewURL:context:)``.
    case openInEditor(URL)

    /// A fragment on the page itself, carried without its `#`.
    case anchor(String)

    /// Everything else, including every scheme that can execute or inline
    /// something (`javascript:`, `data:`), a `file:` URL the page had no
    /// business composing, and an app-scheme URL naming a path the inverse
    /// mapping rejects.
    case refused
}

/// The rule the preview's navigation delegate dispatches on.
///
/// It is asked about the **navigation URL** — what the web view resolved the
/// clicked `href` to — which for a project target is the app-scheme URL
/// ``MarkdownRenderer`` put into the page. That is the whole round trip: the
/// renderer turned a source spelling into a URL through
/// ``MarkdownPreviewAsset/assetURL(forTarget:context:)``, and this rule turns
/// that URL back into the same file through the inverse. Neither half parses a
/// path itself, and the inverse re-checks containment rather than trusting the
/// forward direction to have done it, because the URL arriving here need not be
/// one the forward direction produced.
///
/// A target the renderer could **not** resolve was emitted with the source's own
/// spelling, so it arrives here as whatever the page's base URL made of it: an
/// `http` URL stays one and opens externally, and a relative path resolves
/// against the shell's URL into an app-scheme URL naming a file that is either
/// inside the root (in which case opening it is right, and the forward
/// direction's refusal was about the *document's* directory, not about reach) or
/// outside it, in which case the inverse refuses it here.
public enum MarkdownLinkRule {

    /// The schemes that leave the app. Lowercased on comparison, since a URL may
    /// spell its scheme in any case and `URL.scheme` does not normalize it.
    private static let externalSchemes: Set<String> = ["http", "https", "mailto"]

    /// What `url` should do.
    public static func decision(for url: URL, context: MarkdownDocumentContext) -> MarkdownLinkDecision {
        guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty else { return .refused }

        if externalSchemes.contains(scheme) { return .external(url) }
        guard scheme == MarkdownPreviewPage.scheme, url.host == MarkdownPreviewPage.host else {
            return .refused
        }

        // An anchor is a fragment on *this document*, which is the shell — the
        // one URL the page was ever loaded from. A fragment on any other path is
        // not an anchor but a navigation to another resource that happens to
        // carry one, and is judged as that resource.
        if url.path == MarkdownPreviewPage.shellPath {
            guard let fragment = url.fragment, !fragment.isEmpty else { return .refused }
            return .anchor(fragment)
        }

        guard let fileURL = MarkdownPreviewAsset.projectFileURL(forPreviewURL: url, context: context) else {
            return .refused
        }
        return .openInEditor(fileURL)
    }
}
