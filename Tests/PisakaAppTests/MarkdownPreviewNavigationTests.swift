#if os(macOS)
import PisakaCore
import WebKit
import XCTest
@testable import Pisaka

/// `MarkdownPreviewWebView`'s navigation policy, against a real `WKWebView`.
///
/// **The one thing in the pipeline that can see whether the shell actually
/// loads.** The policy recognises this object's own load by four facts at once
/// — a count raised immediately before it, the main frame, the shell's URL and
/// `navigationType == .other` — and three of those are WebKit's answers, not
/// this repository's. A wrong assumption about any of them does not fail to
/// compile and breaks nothing a Core test can reach: it cancels the page's own
/// load, and the preview is blank for the rest of the app's life.
///
/// Asserted end to end rather than by standing a probe in for the delegate: the
/// real object decides, and the evidence is that the shell's own container
/// element exists in the loaded document — which is true only if the policy
/// allowed the load, the handler answered it, and the served bytes were the
/// shell. The bundled subresources the shell also names are irrelevant here and
/// are `MarkdownPreviewSchemeHandlerTests`' subject.
@MainActor
final class MarkdownPreviewNavigationTests: XCTestCase {

    /// The page asks for its shell, and the shell is what ends up loaded.
    func testTheShellThisObjectAsksForIsAllowedAndLoads() async throws {
        let page = MarkdownPreviewWebView()
        page.reloadShell(html: MarkdownPreviewPage.html(theme: .dark, fontSize: 13))

        let found = try await waitForContainerElement(in: page.webView)
        XCTAssertTrue(
            found,
            "the shell's container element must exist in the loaded document: the policy allows this "
                + "object's own load only when the navigation is the main frame, MarkdownPreviewPage"
                + ".shellURL and .other, and a wrong reading of any of the three cancels the one load "
                + "the feature performs"
        )
    }

    /// Poll the page for the shell's container element until it appears.
    ///
    /// A condition-wait rather than a delay, and it fails loudly rather than
    /// vacuously: a load that never lands times out with a message naming what
    /// was waited for. The page is asked, so a cancelled navigation answers
    /// `false` for the whole budget rather than throwing.
    private func waitForContainerElement(in webView: WKWebView) async throws -> Bool {
        let source = "document.getElementById('\(MarkdownPreviewPage.containerElementID)') !== null"
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let answer = try? await webView.evaluateJavaScript(source) as? Bool, answer {
                return true
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("the shell did not load within ten seconds")
        return false
    }
}
#endif
