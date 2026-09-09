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
    ///
    /// The one wire this file makes rather than forwards, and it is still not a
    /// decision of its own: a page that died is a fact the web view alone can
    /// observe and a recovery only the model can perform, so the two are joined
    /// here, where both are owned, and what happens next is entirely
    /// ``MarkdownPreviewModel/pageIsGone()``'s. Joined in the `lazy` that builds
    /// the model rather than in `init`, because that is the moment the pair
    /// first exists — so it cannot exist unjoined. The model is captured weakly:
    /// it holds the page as its sink, and the closure travels the other way.
    private lazy var model: MarkdownPreviewModel = {
        let model = MarkdownPreviewModel(parser: parser, sink: page)
        page.pageIsGone = { [weak model] in model?.pageIsGone() }
        return model
    }()

    init(parser: any MarkdownParsing = MarkdownParser()) {
        self.parser = parser
    }

    /// How many `MarkdownPreviewPane`s are on screen for this window's page.
    ///
    /// Ordinarily one or zero, and the count exists for the moment it is briefly
    /// two. `ContentView` instantiates `editorZone` at **two** positions — the
    /// `.vertical` and `.horizontal` branches of the tab-orientation switch — so
    /// changing that preference is a structural replacement: one pane is removed
    /// and another inserted in the same update. SwiftUI does not guarantee which
    /// of `onAppear` and `onDisappear` runs first there, and with the inserted
    /// pane going first the sequence was *appear, forward, disappear, clear* —
    /// a blank pane the user could not get back, because every method the model
    /// offers is deliberately a no-op for a fact that did not move (the same
    /// "the memory they compare against is false" shape `pageIsGone()` was
    /// written for). A keystroke would have fixed it; a file being read rather
    /// than edited would stay blank indefinitely.
    private var livePanes = 0

    /// A pane came on screen. Balanced by ``paneDisappeared()``.
    func paneAppeared() {
        livePanes += 1
    }

    /// A pane went off screen; the document is dropped only when the last one
    /// does. Ordering-independent by construction: whichever of the two calls
    /// arrives first, the count is only zero when no pane is left.
    func paneDisappeared() {
        livePanes -= 1
        guard livePanes <= 0 else { return }
        livePanes = 0
        preview(nil, projectRoot: nil)
    }

    /// What opening a link into the project means. Forwarded to the page, which
    /// is where the navigation delegate lives; this type neither classifies a
    /// link nor knows what a tab is.
    var openInEditor: ((URL) -> Void)? {
        get { page.openInEditor }
        set { page.openInEditor = newValue }
    }

    /// The buffer the scroll mapping is read against, and its line starts once
    /// something has asked for them.
    ///
    /// Not a second copy of the document and not a decision: it is the very text
    /// ``preview(_:projectRoot:)`` was just handed, kept so a scroll needs only
    /// an offset. The line starts are computed on the first scroll after a
    /// keystroke rather than on the keystroke itself — a burst of typing with
    /// nobody scrolling then costs none of them — and dropped whenever the text
    /// moves, which is the only place they can go stale.
    private var scrollText: NSString = ""
    private var scrollLineStarts: [Int]?

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
            scrollText = ""
            scrollLineStarts = nil
            model.clear()
            return
        }
        let context = MarkdownDocumentContext(documentURL: file.url, projectRoot: projectRoot)
        page.documentContext = context
        scrollText = file.text as NSString
        scrollLineStarts = nil
        model.retarget(to: context, text: file.text)
    }

    /// The editor scrolled, with the character offset now at the top of it.
    ///
    /// The one mapping this file performs, and — like the `nil`/document
    /// translation above — not a decision: which line an offset is in is
    /// ``MarkdownScrollRule``'s answer, and *when* that line reaches the page is
    /// the model's, which coalesces a gesture's worth of them into one call per
    /// turn of the main run loop. Nothing here holds a dirty flag or a timer.
    func noteScrolled(topOffset: Int) {
        let lineStarts = scrollLineStarts ?? LineStartIndex.offsets(in: scrollText)
        scrollLineStarts = lineStarts
        model.noteScrolled(toLine: MarkdownScrollRule.line(forTopOffset: topOffset, lineStarts: lineStarts))
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
