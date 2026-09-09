import Foundation

/// The Markdown preview's page: its custom scheme, the URLs that scheme
/// addresses, and the document served over it.
///
/// **The page is served, never string-loaded.** The shell HTML is answered by
/// the app's scheme handler and the web view reaches it with an ordinary
/// request, so the document, the four bundled files and every project image
/// share one app-scheme origin. A string-loaded document has a null origin, and
/// a null origin cannot be granted access to anything — every asset would have
/// to be inlined, which for a 4.5 MB script bundle is not a page but a copy of
/// one per keystroke.
///
/// **The vocabulary is spelled once, here.** The scheme name, the host, the
/// shell's URL and the two path prefixes are constants of this file and nothing
/// in the app layer may spell any of them: the handler receives a URL and hands
/// it to Core's classifier, the renderer receives a target and hands it to
/// Core's asset rule, and neither builds or parses a preview URL itself. A
/// second spelling would be a second answer to *which origin is this*, and the
/// two halves of the round trip — the URL the renderer puts into the page and
/// the file the handler serves for it — would be free to disagree.
public enum MarkdownPreviewPage {

    /// The custom URL scheme the whole preview lives under.
    ///
    /// Registered on the web view's configuration, so `WKWebView` routes every
    /// request spelling it to the app's handler and nothing else can be reached:
    /// the page's own CSP names this scheme and no network origin at all.
    ///
    /// It must not be a scheme WebKit already knows (`http`, `file`, `about`, …)
    /// — registering one of those traps — and it carries the app's name so a
    /// URL in a crash log or a devtools panel says where it came from.
    public static let scheme = "pisaka-preview"

    /// The one host every preview URL uses.
    ///
    /// Fixed rather than derived from the document, so a document's *path* never
    /// becomes part of the origin: two Markdown tabs are one origin, and
    /// retargeting the web view from one to the other is not a cross-origin
    /// navigation.
    public static let host = "preview"

    /// The shell document's path.
    public static let shellPath = "/index.html"

    /// The path prefix the four bundled files answer under
    /// (`…/assets/preview.css`).
    ///
    /// Distinct from the project-file prefix because the two are served from
    /// different places — the app bundle and the worktree — and because a
    /// project file must never be reachable under a name the shell's own
    /// `<script>` tags spell.
    public static let bundledPathPrefix = "/assets/"

    /// The path prefix a project file answers under, carrying that file's
    /// **project-relative** path (`…/file/docs/diagram.png`).
    ///
    /// Relative, not absolute: the page never learns where the project sits on
    /// disk, and the inverse mapping cannot be handed a path it did not have to
    /// re-check against the root it was given.
    public static let filePathPrefix = "/file/"

    /// The URL the web view loads, and the only document the handler ever serves
    /// as HTML.
    public static let shellURL = URL(string: "\(scheme)://\(host)\(shellPath)")!
}
