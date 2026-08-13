#if os(macOS)
import PisakaCore
import SwiftUI
import WebKit

/// The problem statement beside the editor: a right-hand pane that exists
/// exactly while the active tab is a LeetCode solution file.
///
/// **It observes the model; the window does not.** `LeetCodeModel` publishes on
/// every busy transition and every statement fetch, and `ContentView` holds it
/// as a plain `let` for the reason stated there — subscribing the window would
/// put the project tree, the tab list and `CodeEditorView.updateNSView` back on
/// that path. So the `@ObservedObject` lives *here*, in the one view that
/// actually shows the state, and the pane appears and disappears on its own
/// while the rest of the window stays still. That is also why the pane renders
/// nothing (rather than the window omitting it) when there is no statement: the
/// window cannot see the difference.
///
/// **A sibling in an `HStack`, not a third `HSplitView` column.** Two reasons,
/// both the bottom dock's: an `HSplitView` child that appears and disappears
/// re-creates the split and resets the widths of everything in it, and a
/// conditional *around* the editor would change the editor's structural
/// identity — tearing down the `NSTextView`, its undo stack and its scroll
/// position every time a LeetCode tab is selected. An `HStack` whose trailing
/// child is sometimes an `EmptyView` costs the editor nothing, and the width is
/// then this view's own `@State` behind a manual drag handle, exactly as
/// `ContentView` manages `panelHeight`.
struct LeetCodeDescriptionPane: View {
    @ObservedObject var model: LeetCodeModel
    /// Theme and font size: the document is recomposed from them, so changing
    /// either re-renders the pane live.
    @ObservedObject var settings: SettingsStore

    /// The editor, handed straight down to the judge section and **deliberately
    /// not** `@ObservedObject` — the `commitDialog`/`symbolIndex` rule
    /// `ContentView` states, arriving one level deeper: observing it here would
    /// re-render this pane (and reload nothing, but re-evaluate everything) on
    /// every keystroke in the file being solved. Nothing in this pane reads a
    /// buffer; the judge reads one synchronously when a button is pressed.
    /// Defaults to `nil` so a default-constructed pane (previews) still compiles.
    var workspace: WorkspaceModel?

    /// The active tab's file, passed in rather than read off `workspace` for the
    /// same reason it is not observed: this value is what re-runs the judge's
    /// `prepare`, so it has to come from a view that *is* watching the selection.
    var activeFileURL: URL?

    /// The appearance the window is *actually* drawn in, which is what resolves
    /// `ThemePreference.system` — `Theme.resolved(_:systemPrefersDark:)` needs an
    /// answer to that question and Core may not ask AppKit for one. `ContentView`
    /// applies `.preferredColorScheme` at the window root, so this reflects an
    /// explicit light/dark preference too (in which case `resolved` ignores it).
    @Environment(\.colorScheme) private var colorScheme

    /// The pane's width, held here so it survives every statement change and
    /// every tab switch — the `panelHeight` rule, for the same reason it is not
    /// an `HSplitView`. `@State` only; cross-launch persistence is YAGNI.
    @State private var width: CGFloat = 380
    /// The width captured at the start of a drag, so the cumulative
    /// `DragGesture` translation applies to a fixed base instead of compounding
    /// frame to frame. `nil` when not dragging.
    @State private var dragStartWidth: CGFloat?
    /// Whether the user has folded the pane away to a strip. Survives tab
    /// switches for the same reason `width` does: it is a preference about the
    /// window, not about one problem.
    @State private var isCollapsed = false
    /// Whether the pointer is over the resize handle, tracked because a pushed
    /// `NSCursor` has to be popped by the same view that pushed it — see the
    /// handle's own note.
    @State private var isHoveringHandle = false

    /// Narrower than this and the statement's example blocks stop being
    /// readable; wider and the editor is the one being squeezed.
    private static let minimumWidth: CGFloat = 260
    private static let maximumWidth: CGFloat = 900

    @ViewBuilder
    var body: some View {
        if let statement = model.statement {
            if isCollapsed {
                HStack(spacing: 0) {
                    Divider()
                    collapsedStrip
                }
            } else {
                HStack(spacing: 0) {
                    resizeHandle
                    pane(statement)
                        .frame(width: clamped(width))
                }
            }
        }
    }

    // MARK: - The pane

    private func pane(_ statement: LeetCodeStatement) -> some View {
        VStack(spacing: 0) {
            header(statement)
            Divider()
            LeetCodeStatementWebView(html: html(for: statement))
            Divider()
            // Below the statement, and inside the same pane: Run and Submit are
            // about the problem the user is reading, and the section observes
            // `model.judge` rather than `model`, so typing in its test-case box
            // invalidates it alone — not this pane, and not the web view above it.
            LeetCodeJudgeSection(
                judge: model.judge,
                workspace: workspace,
                fileURL: activeFileURL,
                folder: settings.leetCodeFolderURL
            )
        }
        .frame(maxHeight: .infinity)
    }

    private func header(_ statement: LeetCodeStatement) -> some View {
        HStack(spacing: 6) {
            Button { isCollapsed = true } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.plain)
            .help("Hide the problem description")

            Text("\(statement.number). \(statement.title)")
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            // The same destination a link inside the statement goes to, for the
            // parts of a problem this panel deliberately does not render:
            // discussion, submissions, the editorial.
            Button {
                NSWorkspace.shared.open(LeetCodeAPI.problemURL(slug: statement.slug))
            } label: {
                Image(systemName: "safari")
            }
            .buttonStyle(.plain)
            .help("Open this problem on leetcode.com")
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 24, maxHeight: 24)
    }

    /// The strip left behind when the pane is folded away — the only thing that
    /// can unfold it, so it is never possible to collapse the pane and lose the
    /// way back.
    private var collapsedStrip: some View {
        VStack(spacing: 0) {
            Button { isCollapsed = false } label: {
                Image(systemName: "sidebar.right")
            }
            .buttonStyle(.plain)
            .help("Show the problem description")
            .padding(.top, 6)
            Spacer(minLength: 0)
        }
        .frame(width: 28)
        .frame(maxHeight: .infinity)
    }

    /// Drag left to widen, right to narrow. The `panelDivider` shape in
    /// `ContentView`, turned ninety degrees.
    private var resizeHandle: some View {
        Rectangle()
            .fill(Color(NSColor.separatorColor))
            .frame(width: 5)
            .contentShape(Rectangle())
            // Paired with `onDisappear`, unlike `ContentView.panelDivider`'s
            // otherwise identical idiom: that divider goes away only when the
            // user toggles it, while this whole pane is removed the moment the
            // statement does — a tab switch under the pointer would otherwise
            // push a cursor nothing ever pops, and the resize cursor would stick
            // application-wide.
            .onHover { hovering in
                guard hovering != isHoveringHandle else { return }
                isHoveringHandle = hovering
                if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .onDisappear {
                if isHoveringHandle {
                    isHoveringHandle = false
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture()
                    .onChanged { value in
                        let base = dragStartWidth ?? width
                        if dragStartWidth == nil { dragStartWidth = base }
                        width = clamped(base - value.translation.width)
                    }
                    .onEnded { _ in dragStartWidth = nil }
            )
    }

    private func clamped(_ proposed: CGFloat) -> CGFloat {
        min(max(proposed, Self.minimumWidth), Self.maximumWidth)
    }

    /// The whole document, composed in Core.
    ///
    /// Recomputed on every body evaluation and compared by the web view before
    /// anything is loaded, which is what makes "re-render on theme/font-size
    /// change" and "do not reload while the user is reading" the same rule.
    private func html(for statement: LeetCodeStatement) -> String {
        LeetCodeStatementDocument.html(
            fragment: statement.fragment,
            title: "\(statement.number). \(statement.title)",
            theme: LeetCodeStatementDocument.Theme.resolved(
                settings.themePreference,
                systemPrefersDark: colorScheme == .dark
            ),
            fontSize: settings.fontSize
        )
    }
}

/// The `WKWebView` the composed document is rendered in.
///
/// It has no state of its own and runs no script: `allowsContentJavaScript` is
/// off, so the statement is markup and CSS and nothing else — LeetCode's
/// fragment is interpolated verbatim (the rule stated on
/// `LeetCodeStatementDocument`), and turning scripting off is what keeps
/// "verbatim" from meaning "executable". The data store is non-persistent for
/// the same reason: this view renders bytes the app already has and must not
/// become a second place a leetcode.com cookie can be kept.
///
/// **A click on a link leaves the app.** A statement links to related problems,
/// to the editorial and to the discussion — all of them full LeetCode pages that
/// would replace the statement inside a 380pt pane with no way back. So
/// `linkActivated` is handed to the default browser and cancelled here, and the
/// pane only ever shows the one document it was given.
private struct LeetCodeStatementWebView: NSViewRepresentable {
    let html: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        load(into: webView, coordinator: context.coordinator)
        return webView
    }

    /// Reloads **only when the document actually differs**.
    ///
    /// `ContentView.body` re-evaluates on every keystroke in the editor (the text
    /// binding republishes `openFiles`), and an unconditional `loadHTMLString`
    /// here would reload the statement — and reset its scroll position — once per
    /// character typed. Comparing the composed HTML is also exactly the right
    /// trigger for the changes that *should* reload: a new statement, a theme
    /// switch, a font-size step.
    func updateNSView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.loadedHTML != html else { return }
        load(into: webView, coordinator: context.coordinator)
    }

    /// The base URL matches the document's own `<base href>`: LeetCode's `<img
    /// src>`s are relative to the site root, and a `loadHTMLString` with no base
    /// resolves them against `about:blank`.
    private func load(into webView: WKWebView, coordinator: Coordinator) {
        coordinator.loadedHTML = html
        coordinator.isPerformingOwnLoad = true
        webView.loadHTMLString(html, baseURL: LeetCodeAPI.siteURL)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        /// What was last handed to `loadHTMLString`, so `updateNSView` can tell a
        /// re-evaluation from a change.
        var loadedHTML: String?

        /// Set immediately before `loadHTMLString` and consumed by the first
        /// navigation that follows it: **this view's own load, not a URL**, is what
        /// identifies the document.
        ///
        /// Recognising it by URL instead is not sound. `loadHTMLString` navigates
        /// to the base URL it was handed, but `https://leetcode.com/` is no private
        /// sentinel — it is an ordinary destination the verbatim, never-sanitized
        /// fragment can link to with a bare `href="/"` (resolved against the
        /// document's own `<base href>`) or reach with a `<meta http-equiv=
        /// "refresh">`, neither of which needs the JavaScript this view has off.
        /// Such a navigation matched the old URL test exactly and was `.allow`ed
        /// into the main frame — the precise failure the policy below exists to
        /// prevent, and an unrecoverable one: there is no back gesture, and
        /// `updateNSView` will not reload a document whose HTML has not changed.
        var isPerformingOwnLoad = false

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            // **The main frame only ever holds the document this view loaded.**
            // A sub-frame load is left alone (an embedded player in a statement
            // is LeetCode's own markup doing what it does), and so are the
            // subresource loads, which never reach this method at all.
            //
            // What the main-frame test catches is everything that is *not* a
            // click: the fragment is interpolated verbatim and never sanitized,
            // so a `<meta http-equiv="refresh">` or a `<form>` in it navigates
            // this pane to a live page — with disabled JavaScript no obstacle,
            // since neither needs it — and there is no way back: the pane has no
            // back gesture, and `updateNSView` will not reload a document whose
            // HTML has not changed.
            //
            // The document itself is recognised by *this view having just asked
            // for it* — see `isPerformingOwnLoad`, which is why the base URL is
            // not the test.
            let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
            guard isMainFrame else {
                decisionHandler(.allow)
                return
            }
            // The flag is consumed on the main frame alone: a sub-frame taking it
            // would leave the real document load to be judged as a navigation.
            if isPerformingOwnLoad {
                isPerformingOwnLoad = false
                decisionHandler(.allow)
                return
            }
            guard let url = navigationAction.request.url, !Self.isTheEmptyPage(url)
            else {
                decisionHandler(.allow)
                return
            }
            // **Only the web is handed to the OS.** The statement is LeetCode's
            // markup rendered verbatim — this layer never sanitizes it — so the
            // `href` behind a click is untrusted by construction, and
            // `NSWorkspace.open` will happily launch a `file:` URL in its default
            // handler or hand any other scheme to whichever app claims it.
            // Disabled JavaScript does not cover this: it is the delegate, not the
            // page, that performs the open.
            guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
            else {
                decisionHandler(.cancel)
                return
            }
            // **Only a click is handed to the OS.** The paragraph above names the
            // `<meta http-equiv="refresh">` and the `<form>` as the things the
            // main-frame test catches — but catching them and then opening them
            // is the same navigation, in the user's browser instead of this pane.
            // A refresh tag in a statement would launch Safari at an arbitrary URL
            // the moment the pane rendered, with no click and no confirmation, and
            // again on every theme or font-size change that reloads the document.
            // The verdict for everything that is not `.linkActivated` is the one
            // the comment already promised: cancel, and go nowhere.
            guard navigationAction.navigationType == .linkActivated else {
                decisionHandler(.cancel)
                return
            }
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        }

        /// The backstop for `isPerformingOwnLoad`: if `loadHTMLString` ever stops
        /// reaching the policy delegate, the flag would otherwise stay raised and
        /// hand the *next* navigation the document's exemption. A commit always
        /// follows a load, so clearing it here bounds the flag's life to one
        /// document either way.
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            isPerformingOwnLoad = false
        }

        /// Whether `url` is the empty page a web view starts on rather than
        /// somewhere the page is trying to go — not a destination, and nothing to
        /// hand the OS.
        static func isTheEmptyPage(_ url: URL) -> Bool {
            url.absoluteString == "about:blank"
        }
    }
}
#endif
