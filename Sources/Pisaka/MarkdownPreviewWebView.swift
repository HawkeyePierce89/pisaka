#if os(macOS)
import AppKit
import Foundation
import PisakaCore
import SwiftUI
import WebKit

/// The preview's page, as an object the model can drive.
///
/// **This is the feature's one WebKit file**, which
/// `MarkdownPreviewSourceGatingTests` pins: the scheme handler beside it is a
/// plain function of a URL, the renderer and the page live in Core, and nothing
/// else in the preview knows that a web view is what shows it. The
/// `WKURLSchemeHandler` conformance is here for that reason and not because the
/// handler is short — the adapter is what needs WebKit, the answering does not.
///
/// It is the production conformer of ``MarkdownPreviewPageSink``, and the seam's
/// two verbs are the *only* things it does on its own behalf: evaluate a source
/// Core composed, or install a shell Core composed and load it. It holds no
/// token, no debounce and no memory of what the page is showing — that is all
/// ``MarkdownPreviewModel``'s, which is why none of it needs a web view to be
/// tested.
///
/// **One origin, one load site.** The shell is *served*, never string-loaded:
/// ``reloadShell(html:)`` hands the document to the handler and then fetches
/// ``MarkdownPreviewPage/shellURL`` — the one `load(URLRequest` in the feature —
/// so the document, the four bundled files and every project image share one
/// app-scheme origin. Everything after that arrives as JavaScript into the
/// document already loaded, so typing does not reload the page and the scroll
/// position survives a keystroke.
///
/// **Every navigation is cancelled.** The preview never navigates itself: it
/// loads the shell once per theme or font change and is otherwise updated in
/// place, so a navigation is always a link and is always one of
/// ``MarkdownLinkDecision``'s four answers. Three of them carry a side effect —
/// the system opens it, the app opens a tab, the page scrolls — and all four end
/// in `.cancel`, because none of them is "let the web view go there".
/// The preview's web view, as a type the caret commands can recognise.
///
/// The subclass exists for its conformance alone — it overrides nothing and adds
/// nothing. Focus landing inside the preview is still focus on the file the
/// editor beside it is holding, so ⌘/ and its five siblings look past it to that
/// editor; ``EditorCommandTarget`` documents why that permission is granted to
/// this one region and to nothing else.
final class MarkdownPreviewWKWebView: WKWebView, EditorCommandFocusPassthrough {}

@MainActor
final class MarkdownPreviewWebView: NSObject, MarkdownPreviewPageSink {

    /// The view SwiftUI shows. Owned here rather than made in `makeNSView`, so
    /// retargeting the pane from one Markdown tab to the next reuses the one
    /// page instead of building a second.
    let webView: WKWebView

    /// The one handler this page fetches through. Its state is retargeted, never
    /// replaced.
    private let handler: MarkdownPreviewSchemeHandler

    /// What to do with a link into the project — the app's own open-a-tab path,
    /// injected so this file neither knows nor decides what opening means.
    var openInEditor: ((URL) -> Void)?

    /// What to do when the page dies under this object — injected for the same
    /// reason as the closure above: the fact is observable only here, and what
    /// to put back is known only to the model.
    var pageIsGone: (() -> Void)?

    /// How many loads this object has asked for and not yet been asked to
    /// decide a policy for.
    ///
    /// The shell's URL is *not* a usable test for "this is our load": a document
    /// can link to it — an `href="/index.html"`, a bare `href="#"` — and such a
    /// navigation would then be allowed into the main frame and would reload the
    /// page under the user. Recognising the load by *having just asked for it*
    /// is the precedent `LeetCodeStatementWebView` set, for that same reason.
    ///
    /// A **count** rather than a flag, because two reloads can be asked for
    /// before the first one's decision arrives — two theme changes in a row do
    /// exactly that, as does one arriving while a recovery from a dead page is
    /// still in flight. (A code-zoom step is no longer one of them: it sets two
    /// properties on the loaded document and asks for no shell.) A flag the first decision
    /// consumed would leave the second navigation to be judged as a *link*, and
    /// the shell's own fragment-less URL is `.refused` there, so the page's own
    /// load would be cancelled and the preview would never appear. Every
    /// `load(_:)` is answered by exactly one policy decision, so the count
    /// returns to zero.
    ///
    /// **The count is a discriminator, never the whole test.** It says only
    /// that a load was asked for and not yet decided — it cannot say that the
    /// navigation now being judged *is* that load. A count that leaks (a page
    /// whose process dies while a load is still provisional decides no policy
    /// for it) would otherwise hand the exemption to whatever navigates next,
    /// and that exemption is unconditional `.allow` into the main frame: one
    /// click on an `http` link in a rendered document and the pane is a live
    /// remote page, outside the shell's CSP, with no back gesture and nothing
    /// that reloads the shell. The three conditions beside the count in
    /// ``webView(_:decidePolicyFor:decisionHandler:)`` bound what a leak can
    /// authorise to the page's own shell.
    private var ownLoadsAwaitingDecision = 0

    /// Sources handed over while the shell is still loading, and whether that is
    /// the state this object is in.
    ///
    /// **Capability, not a decision.** The model composes the body immediately
    /// after asking for a reload — that ordering is Core's and is asserted there
    /// — but `evaluateJavaScript` reaches whatever document is loaded *now*, so
    /// a source sent in that window would run in the outgoing page and be lost
    /// with it. Holding them here is what makes the seam's contract ("run this
    /// in the page") true; nothing is reordered, coalesced or dropped, so the
    /// page sees exactly the sequence the model sent.
    private var pendingSources: [String] = []
    private var isAwaitingShell = false

    /// The load whose ending releases ``pendingSources`` — held by identity, and
    /// the same reasoning as the count above read from the other side.
    ///
    /// A second reload supersedes the first, and WebKit ends the superseded one
    /// with `didFailProvisionalNavigation`. Flushing on *that* ending would
    /// evaluate the queued body in the outgoing document, where it is lost, and
    /// the arriving shell would then be left empty with nothing able to re-send
    /// it — the model has already recorded that body as the one the page is
    /// showing, so nothing short of another keystroke would publish it again.
    private var awaitedShellNavigation: WKNavigation?

    /// The handler is made here rather than injected: it is this page's own
    /// half — one handler per web view, retargeted with it — and nothing else in
    /// the app has a use for one.
    override init() {
        let handler = MarkdownPreviewSchemeHandler()
        self.handler = handler

        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(handler, forURLScheme: MarkdownPreviewPage.scheme)
        // Nothing this page holds may outlive the window: the document is
        // composed from a file already open in the editor, and a persistent
        // store would keep a copy of it in caches and local storage that no
        // part of this app would ever clean up.
        configuration.websiteDataStore = .nonPersistent()
        webView = MarkdownPreviewWKWebView(frame: .zero, configuration: configuration)
        // There is nothing to go back to — the page is loaded once and updated
        // in place — so a swipe would only ever leave the preview blank.
        webView.allowsBackForwardNavigationGestures = false
        // The one *other* way a document can be fetched, and the reason it is
        // spelled here rather than left at its default: a link preview loads
        // the URL it is showing in a web view of WebKit's own, which neither
        // `navigationDelegate` below nor the shell's `default-src 'none'` can
        // reach. Every navigation this feature sees ends in `.cancel` — an
        // `http(s)` link is handed to the system browser and nothing else is
        // followed at all — so leaving this on would be the single path by
        // which the preview fetched something from the network, and the
        // feature's stated property is that there is none.
        webView.allowsLinkPreview = false

        super.init()
        webView.navigationDelegate = self
    }

    /// Which document the page is showing, as the handler and the link rule both
    /// ask it.
    ///
    /// A stored property of the handler rather than of this object, so there is
    /// one answer: the file a fetch is checked against and the file a click is
    /// checked against cannot differ.
    var documentContext: MarkdownDocumentContext {
        get { handler.context }
        set { handler.context = newValue }
    }

    // MARK: - MarkdownPreviewPageSink

    func evaluate(_ source: String) {
        guard !isAwaitingShell else {
            pendingSources.append(source)
            return
        }
        webView.evaluateJavaScript(source, completionHandler: nil)
    }

    func reloadShell(html: String) {
        handler.shellHTML = html
        ownLoadsAwaitingDecision += 1
        isAwaitingShell = true
        awaitedShellNavigation = webView.load(URLRequest(url: MarkdownPreviewPage.shellURL))
    }

    /// A navigation ended: deliver whatever arrived while the shell was loading,
    /// in the order it arrived — but only when the load that ended is the one
    /// being waited for.
    ///
    /// Called on all three endings, because a shell that failed to load leaves a
    /// page that will never take the queue and holding it forever would silence
    /// the preview until the next theme change. A load superseded by a newer
    /// reload ends here too and is ignored: the newer one's ending is what
    /// settles the queue.
    private func shellLoadEnded(_ navigation: WKNavigation?) {
        guard isAwaitingShell else { return }
        // An unidentifiable ending — either side `nil` — is treated as the
        // awaited one: a queue nobody ever drains is the worse failure of the
        // two, and it is the behaviour every ending had before.
        if let awaitedShellNavigation, let navigation, navigation !== awaitedShellNavigation { return }
        awaitedShellNavigation = nil
        isAwaitingShell = false
        let sources = pendingSources
        pendingSources.removeAll()
        for source in sources {
            webView.evaluateJavaScript(source, completionHandler: nil)
        }
    }
}

// MARK: - Navigation

extension MarkdownPreviewWebView: WKNavigationDelegate {

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        // **The one allowed navigation: a document this object just asked for.**
        //
        // Recognised by *having just asked for it* — see the count — and by the
        // three facts that are true of every such load and of nothing a document
        // can author: it is the main frame, it is the shell's own URL, and it is
        // `.other`, which is what `load(_:)` produces. The count is what
        // separates this from a document linking to the shell's path, which is
        // `.linkActivated` and fails the last test on its own; the three are
        // what keep a leaked count from authorising a destination of the page's
        // choosing rather than of this object's.
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        if ownLoadsAwaitingDecision > 0,
            isMainFrame,
            navigationAction.navigationType == .other,
            navigationAction.request.url == MarkdownPreviewPage.shellURL {
            ownLoadsAwaitingDecision -= 1
            decisionHandler(.allow)
            return
        }
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }

        // **Only a click carries a side effect.** Three of the rule's four
        // answers act on the world outside the page — the system opens a URL,
        // the app opens a tab, the page scrolls — and a navigation that nobody
        // clicked is not a request for any of them. The precedent is
        // `LeetCodeDescriptionView`'s delegate, which refuses the same way and
        // for the same reason: a `<meta http-equiv="refresh">` would otherwise
        // launch a browser at an arbitrary URL the moment the pane rendered,
        // with no click and no confirmation. That this page's tree has no
        // raw-HTML case to author one with is a second property, not a reason to
        // rest the first on it.
        guard navigationAction.navigationType == .linkActivated else {
            decisionHandler(.cancel)
            return
        }

        // A `switch` with no `default`: the rule's four answers are the whole
        // vocabulary, and this method chooses none of them.
        switch MarkdownLinkRule.decision(for: url, context: documentContext) {
        case .external(let target):
            NSWorkspace.shared.open(target)
        case .openInEditor(let fileURL):
            openInEditor?(fileURL)
        case .anchor(let fragment):
            evaluate(MarkdownPreviewPage.scrollToAnchorSource(anchor: fragment))
        case .refused:
            break
        }
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        shellLoadEnded(navigation)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        shellLoadEnded(navigation)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: any Error
    ) {
        shellLoadEnded(navigation)
    }

    /// The page's web content process died and took the document with it.
    ///
    /// WebKit leaves a blank view and reloads nothing on its own, and nothing
    /// this object holds can put the document back: the shell is a string the
    /// model composed and the body one only the model remembers. So the state
    /// that describes a page which no longer exists is dropped — the dead
    /// process decides no policy and ends no navigation, so every one of these
    /// would otherwise be held forever — and the model is told, from where both
    /// halves of the document can be installed again.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        ownLoadsAwaitingDecision = 0
        isAwaitingShell = false
        awaitedShellNavigation = nil
        pendingSources.removeAll()
        pageIsGone?()
    }
}

// MARK: - The scheme handler's WebKit half

/// The adapter between WebKit's task and ``MarkdownPreviewSchemeHandler/answer(for:)``.
///
/// Every branch ends in `didFinish()`: an answer is a response plus its bytes, a
/// refusal is a 404 with no bytes, and neither is a failure. `didFailWithError`
/// appears once, for a request WebKit started without a URL — which it does not
/// do, and which there is otherwise nothing at all to answer.
extension MarkdownPreviewSchemeHandler: WKURLSchemeHandler {

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }

        guard let answer = answer(for: url) else {
            let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)
            // Non-optional in practice: the initializer only fails on a status
            // code it cannot represent, and 404 is not one.
            if let response {
                urlSchemeTask.didReceive(response)
            }
            urlSchemeTask.didFinish()
            return
        }

        urlSchemeTask.didReceive(
            URLResponse(
                url: url,
                mimeType: answer.mimeType,
                expectedContentLength: answer.data.count,
                textEncodingName: answer.textEncodingName
            )
        )
        urlSchemeTask.didReceive(answer.data)
        urlSchemeTask.didFinish()
    }

    /// Nothing to stop: every answer is produced synchronously inside
    /// ``webView(_:start:)`` and the task is finished before it returns.
    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}

// MARK: - The SwiftUI half

/// The pane's view: the one web view, shown.
///
/// Separate from the object above because the object is a *reference* the model
/// holds across a retarget, while a `View` is a value SwiftUI rebuilds whenever
/// anything it reads changes. `updateNSView` is therefore empty by design —
/// every change reaches the page through the seam, never through a re-evaluated
/// body.
struct MarkdownPreviewWebViewRepresentable: NSViewRepresentable {
    let page: MarkdownPreviewWebView

    func makeNSView(context: Context) -> WKWebView { page.webView }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#endif
