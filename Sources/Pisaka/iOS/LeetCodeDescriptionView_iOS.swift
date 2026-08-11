#if os(iOS)
import PisakaCore
import SwiftUI
import UIKit
import WebKit

/// The problem statement on iOS — the peer of the macOS `LeetCodeDescriptionPane`,
/// in the two shapes iOS needs.
///
/// **Adaptive the way `MergeRoute_iOS` is adaptive**, and for the same reason: on
/// a regular width there is room to show the statement *and* the code at once, so
/// it is a pane beside the editor; on a compact width there is not, so it is a
/// screen the user toggles. The two share `LeetCodeDescriptionContent_iOS` — the
/// header and the web view — so the only difference between them is the container
/// they sit in.
///
/// **Each piece observes the model; the root does not.** `LeetCodeModel` publishes
/// on every busy transition and every statement fetch, and `RootView_iOS` holds it
/// as a plain `let` for the reason stated there — the macOS rule, restated on a
/// root that already re-renders on every keystroke and does not need a second
/// reason to. So the `@ObservedObject` lives in the pane, in the toggle and in the
/// screen, each of which renders *nothing at all* when there is no statement.
/// That is what makes the pane and its toolbar button appear and disappear
/// without the project tree and the editor being rebuilt for it.

// MARK: - The regular-width pane

/// The statement beside the editor on a regular width. Renders nothing — no
/// divider, no width — when the active tab is not a LeetCode solution file, and
/// nothing at all on a compact width, where `LeetCodeDescriptionScreen_iOS` is the
/// surface instead.
///
/// Its width is `@State` here rather than a split-view column, for the macOS
/// pane's reason: a container child that appears and disappears would resize
/// everything beside it, and a conditional *wrapping* the editor would change the
/// editor's structural identity — tearing down the `UITextView`, its undo stack
/// and its scroll position every time a LeetCode tab is selected. An `HStack`
/// whose trailing child is sometimes an `EmptyView` costs the editor nothing.
struct LeetCodeDescriptionPane_iOS: View {
    @ObservedObject var model: LeetCodeModel
    /// Theme and font size: the document is recomposed from them, so changing
    /// either re-renders the pane live.
    @ObservedObject var settings: SettingsStore
    /// Compact width has no room for two columns; the screen is used there.
    let isCompact: Bool

    /// The pane's width, held here so it survives every statement change and every
    /// tab switch. `@State` only; cross-launch persistence is YAGNI.
    @State private var width: CGFloat = 360
    /// The width captured at the start of a drag, so the cumulative translation
    /// applies to a fixed base instead of compounding frame to frame.
    @State private var dragStartWidth: CGFloat?
    /// Whether the user folded the pane away to a strip. Survives tab switches for
    /// the same reason `width` does: it is a preference about the layout, not
    /// about one problem.
    @State private var isCollapsed = false

    private static let minimumWidth: CGFloat = 260
    private static let maximumWidth: CGFloat = 900

    @ViewBuilder
    var body: some View {
        if !isCompact, let statement = model.statement {
            if isCollapsed {
                HStack(spacing: 0) {
                    Divider()
                    collapsedStrip
                }
            } else {
                HStack(spacing: 0) {
                    resizeHandle
                    LeetCodeDescriptionContent_iOS(
                        statement: statement,
                        settings: settings,
                        onCollapse: { isCollapsed = true }
                    )
                    .frame(width: clamped(width))
                }
            }
        }
    }

    /// The strip left behind when the pane is folded away — the only thing that
    /// can unfold it, so it is never possible to collapse the pane and lose the
    /// way back.
    private var collapsedStrip: some View {
        VStack(spacing: 0) {
            Button {
                isCollapsed = false
            } label: {
                Image(systemName: "sidebar.right")
            }
            .padding(.top, 8)
            .accessibilityLabel("Show the problem description")
            Spacer(minLength: 0)
        }
        .frame(width: 34)
        .frame(maxHeight: .infinity)
    }

    /// Drag left to widen, right to narrow.
    private var resizeHandle: some View {
        Rectangle()
            .fill(Color(uiColor: .separator))
            .frame(width: 6)
            .contentShape(Rectangle())
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
}

// MARK: - The compact-width screen

/// The statement as a screen of its own, for compact widths. Presented by
/// `RootView_iOS` as a sheet and dismissed by its own Done button; renders a
/// placeholder rather than nothing when the statement has gone (a tab switch
/// behind the sheet), because a sheet that empties itself reads as a bug.
struct LeetCodeDescriptionScreen_iOS: View {
    @ObservedObject var model: LeetCodeModel
    @ObservedObject var settings: SettingsStore
    var onDone: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                if let statement = model.statement {
                    LeetCodeDescriptionContent_iOS(
                        statement: statement,
                        settings: settings,
                        onCollapse: nil
                    )
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 36))
                            .foregroundStyle(.secondary)
                        Text("No problem description")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(model.statement.map { "\($0.number). \($0.title)" } ?? "Description")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                }
            }
        }
    }
}

/// The toolbar button that raises the screen above, on compact width only.
/// Renders nothing when the active tab is not a LeetCode solution file — which is
/// what keeps the editor's toolbar unchanged for every other file, without the
/// root having to observe the model to know.
struct LeetCodeDescriptionToggle_iOS: View {
    @ObservedObject var model: LeetCodeModel
    var onShow: () -> Void

    @ViewBuilder
    var body: some View {
        if model.statement != nil {
            Button(action: onShow) {
                Image(systemName: "doc.text")
            }
            .accessibilityLabel("Show the problem description")
        }
    }
}

// MARK: - Shared content

/// The header plus the rendered document — everything both shapes have in common.
/// `onCollapse` is the pane's fold-away button and is `nil` on the screen, which
/// has a Done button instead.
private struct LeetCodeDescriptionContent_iOS: View {
    let statement: LeetCodeStatement
    @ObservedObject var settings: SettingsStore
    let onCollapse: (() -> Void)?

    /// The appearance the view is *actually* drawn in, which is what resolves
    /// `ThemePreference.system` — `Theme.resolved(_:systemPrefersDark:)` needs an
    /// answer to that question and Core may not ask UIKit for one. `RootView_iOS`
    /// applies `.preferredColorScheme` at its root, so this reflects an explicit
    /// light/dark preference too (in which case `resolved` ignores it).
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            LeetCodeStatementWebView_iOS(html: html)
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 8) {
            if let onCollapse {
                Button(action: onCollapse) {
                    Image(systemName: "chevron.right")
                }
                .accessibilityLabel("Hide the problem description")

                Text("\(statement.number). \(statement.title)")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 4)

            // The same destination a link inside the statement goes to, for the
            // parts of a problem this surface deliberately does not render:
            // discussion, submissions, the editorial.
            Button {
                UIApplication.shared.open(LeetCodeAPI.problemURL(slug: statement.slug))
            } label: {
                Image(systemName: "safari")
            }
            .accessibilityLabel("Open this problem on leetcode.com")
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
    }

    /// The whole document, composed in Core.
    ///
    /// Recomputed on every body evaluation and compared by the web view before
    /// anything is loaded, which is what makes "re-render on theme/font-size
    /// change" and "do not reload while the user is reading" the same rule.
    private var html: String {
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

/// The `WKWebView` the composed document is rendered in — the iOS peer of the
/// macOS `LeetCodeStatementWebView`, with the same three rules.
///
/// It has no state of its own and runs no script: `allowsContentJavaScript` is
/// off, so the statement is markup and CSS and nothing else — LeetCode's fragment
/// is interpolated verbatim (the rule stated on `LeetCodeStatementDocument`), and
/// turning scripting off is what keeps "verbatim" from meaning "executable". The
/// data store is non-persistent for the same reason: this view renders bytes the
/// app already has and must not become a second place a leetcode.com cookie can
/// be kept, beside the login web view's deliberately persistent one.
///
/// **A tap on a link leaves the app.** A statement links to related problems, to
/// the editorial and to the discussion — all full LeetCode pages that would
/// replace the statement with no way back. So `linkActivated` is handed to Safari
/// and cancelled here.
private struct LeetCodeStatementWebView_iOS: UIViewRepresentable {
    let html: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
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
    /// The root's `body` re-evaluates on every keystroke in the editor (the text
    /// binding republishes `openFiles`), and an unconditional `loadHTMLString`
    /// here would reload the statement — and reset its scroll position — once per
    /// character typed. Comparing the composed HTML is also exactly the right
    /// trigger for the changes that *should* reload: a new statement, a theme
    /// switch, a font-size step.
    func updateUIView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.loadedHTML != html else { return }
        load(into: webView, coordinator: context.coordinator)
    }

    /// The base URL matches the document's own `<base href>`: LeetCode's `<img
    /// src>`s are relative to the site root, and a `loadHTMLString` with no base
    /// resolves them against `about:blank`.
    private func load(into webView: WKWebView, coordinator: Coordinator) {
        coordinator.loadedHTML = html
        webView.loadHTMLString(html, baseURL: LeetCodeAPI.siteURL)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        /// What was last handed to `loadHTMLString`, so `updateUIView` can tell a
        /// re-evaluation from a change.
        var loadedHTML: String?

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            // **The main frame only ever holds the document this view loaded** —
            // the macOS pane's rule, for the reason stated there: the fragment is
            // interpolated verbatim, so a `<meta http-equiv="refresh">` or a
            // `<form>` in it would navigate this pane to a live page with no way
            // back. Sub-frame loads are left alone, and subresource loads never
            // reach this method at all. The document itself is recognised by its
            // URL: `loadHTMLString` navigates to the base URL it was handed, which
            // is `LeetCodeAPI.siteURL` and nothing else.
            let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
            guard isMainFrame, let url = navigationAction.request.url,
                  !Self.isTheDocumentItself(url)
            else {
                decisionHandler(.allow)
                return
            }
            // **Only the web is handed to the OS.** The statement is LeetCode's
            // markup rendered verbatim — this layer never sanitizes it — so the
            // `href` behind a tap is untrusted by construction, and
            // `UIApplication.open` will hand any scheme to whichever app claims
            // it. Disabled JavaScript does not cover this: it is the delegate, not
            // the page, that performs the open.
            guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
            else {
                decisionHandler(.cancel)
                return
            }
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
        }

        /// Whether `url` is the document this view loaded rather than somewhere
        /// the page is trying to go. `about:blank` counts: it is the empty page a
        /// web view starts on, not a destination.
        static func isTheDocumentItself(_ url: URL) -> Bool {
            url.absoluteString == LeetCodeAPI.siteURL.absoluteString
                || url.absoluteString == "about:blank"
        }
    }
}
#endif
