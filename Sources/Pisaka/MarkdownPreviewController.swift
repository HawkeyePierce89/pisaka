#if os(macOS)
import Foundation
import PisakaCore

/// Who owns the Markdown preview's page, and what the window tells it.
///
/// **Glue with no logic of its own.** Every question this feature answers is
/// answered somewhere else: the parse is `MarkdownParser`'s, the markup is
/// `MarkdownRenderer`'s, the page is `MarkdownPreviewPage`'s, and — the reason
/// this file is four forwarding methods rather than a controller — *when* any
/// of it happens is `MarkdownPreviewModel`'s. There is no generation token
/// here, no debounce, no dirty flag and no branch on what to reload, because
/// the model's methods are total for the facts they are handed: re-forwarding
/// the document already shown is a text change, re-forwarding the text already
/// parsed sends nothing, and an unchanged appearance reloads nothing. So the
/// window may forward the same facts as often as it likes.
///
/// That is also why this file has no tests of its own: there is nothing here to
/// assert that `MarkdownPreviewModelTests` does not already assert on the model,
/// and the shape of the file — one `import Markdown` away, one `import WebKit`
/// away, naming neither writer gate — is pinned by
/// `MarkdownPreviewSourceGatingTests`.
///
/// **One page per window, retargeted.** The web view is built once and pointed
/// at whichever Markdown tab is active, the way the Local History window is
/// retargeted rather than opened per file: a `WKWebView` per tab would be a
/// process per tab, and switching tabs would re-load a document instead of
/// replacing a body. `ContentView` holds this as a `@StateObject`, so the
/// lifetime is the window's.
///
/// **Nothing is built until the pane is shown.** The page and the model are
/// `lazy`, so a window whose Markdown preference is off — the default — pays for
/// this feature exactly one object with two unevaluated properties. The first
/// touch of either comes from `MarkdownPreviewPane`, which exists only while the
/// pane is on screen.
///
/// **A reader.** It never raises `autosave.suspend()` / `beginRevert()` and is
/// never gated by them: it reads a buffer the editor already holds and writes
/// nothing anywhere.
@MainActor
final class MarkdownPreviewController: ObservableObject {

    /// How text becomes a tree. Injected so this type names no concrete parser
    /// in its stored state; the app always passes the real one.
    private let parser: any MarkdownParsing

    /// The page, as an `NSView` the pane shows and as the model's sink.
    lazy var page = MarkdownPreviewWebView()

    /// The ordering. Built over the page above, which is why it is `lazy` too —
    /// touching it is what builds the web view.
    private lazy var model = MarkdownPreviewModel(parser: parser, sink: page)

    init(parser: any MarkdownParsing = MarkdownParser()) {
        self.parser = parser
    }

    /// What opening a link into the project means. Forwarded to the page, which
    /// is where the navigation delegate lives; this type neither classifies a
    /// link nor knows what a tab is.
    var openInEditor: ((URL) -> Void)? {
        get { page.openInEditor }
        set { page.openInEditor = newValue }
    }

    /// The tab being previewed and the project it sits in, or `nil` when there
    /// is nothing to preview.
    ///
    /// The one translation this file performs, and it is not a decision: the
    /// model has a document or it has none, and "none" is spelled `clear()`.
    /// Which tabs are previewable — a `.text` tab whose language is Markdown,
    /// with the preference on — is the routing in `ContentView`, and this is
    /// simply told the outcome.
    ///
    /// The context is set on the page *and* handed to the model, so the file a
    /// fetch is checked against and the file the body is rendered for are one
    /// value.
    func preview(_ file: OpenFile?, projectRoot: URL?) {
        guard let file else {
            page.documentContext = .none
            model.clear()
            return
        }
        let context = MarkdownDocumentContext(documentURL: file.url, projectRoot: projectRoot)
        page.documentContext = context
        model.retarget(to: context, text: file.text)
    }

    /// The window's resolved theme and the code font size.
    ///
    /// Forwarded on every appearance the pane computes; the model compares and
    /// reloads the shell only when one of the two actually moved.
    func updateAppearance(theme: MarkdownPreviewTheme, fontSize: Double) {
        model.updateAppearance(theme: theme, fontSize: fontSize)
    }
}
#endif
