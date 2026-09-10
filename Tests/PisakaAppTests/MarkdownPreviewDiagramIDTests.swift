#if os(macOS)
import PisakaCore
import WebKit
import XCTest
@testable import Pisaka

/// A heading survives the diagram beside it, against a real `WKWebView` running
/// the bundled mermaid.
///
/// **The one place in the pipeline where the two id families meet.** mermaid is
/// handed an id per render and removes whatever element already carries it
/// before it measures its own, so the id it is given and the ids
/// `MarkdownRenderer` writes onto headings must be drawn from disjoint
/// alphabets. Core pins both halves of that — no slug carries an ASCII capital
/// (`MarkdownHeadingSlugTests`), the prefix does and the script spells it
/// (`MarkdownPreviewAssetPinTests`) — but neither can *execute* the bundle, and
/// the sentence being protected is a statement about what mermaid does, not
/// about two spellings. So it is asserted here the only way it can be seen:
/// render a document whose heading slugs to what the old scheme handed mermaid
/// verbatim, let the diagram render, and ask the page whether the heading is
/// still in it.
@MainActor
final class MarkdownPreviewDiagramIDTests: XCTestCase {

    /// `# Pisaka diagram 1` slugs to `pisaka-diagram-1` — the id the page used
    /// to hand its first diagram — and must outlive that diagram's render.
    func testAHeadingWhoseSlugNamesADiagramSurvivesItsRender() async throws {
        let markdown = """
            # Pisaka diagram 1

            ```mermaid
            graph TD; A-->B;
            ```
            """
        let document = MarkdownParser().parse(markdown)
        let body = MarkdownRenderer.body(for: document, context: .none)
        let headingID = try XCTUnwrap(MarkdownHeadingSlug.slug(forText: "Pisaka diagram 1"))
        XCTAssertTrue(body.contains("id=\"\(headingID)\""), "the heading must carry the id under test")
        XCTAssertTrue(body.contains("<pre class=\"mermaid\""), "the fence must render as a diagram block")

        let page = MarkdownPreviewWebView()
        page.reloadShell(html: MarkdownPreviewPage.html(theme: .light, fontSize: 13))
        try await waitFor("the shell to load", in: page.webView, "document.getElementById('content') !== null")
        try await waitFor("the bundled mermaid to load", in: page.webView, "!!window.mermaid")

        page.evaluate(MarkdownPreviewPage.bodyUpdateSource(body: body))
        // Every ending of a render — drawn, failed, or an answer of a shape the
        // page does not know — clears this class, and all three happen *after*
        // mermaid has removed whatever carried the id it was handed. Waiting on
        // it therefore stages the collision whether or not this environment can
        // actually draw the diagram.
        try await waitFor(
            "the diagram render to settle",
            in: page.webView,
            "document.querySelectorAll('pre.mermaid.mermaid-pending').length === 0"
                + " && document.querySelectorAll('pre.mermaid').length === 1"
        )

        // The *element*, not merely the id: mermaid gives its own svg the id it
        // was handed, so a document whose heading was deleted still answers
        // `getElementById` — with the diagram. Asking what carries the id is
        // what tells "the anchor works" from "the anchor now points at a
        // picture that replaced the heading it named".
        let carrier = try await page.webView.evaluateJavaScript(
            "(document.getElementById('\(headingID)') || {}).outerHTML || ''"
        ) as? String
        XCTAssertTrue(carrier?.hasPrefix("<h1 ") ?? false, """
            “\(headingID)” is carried by \(carrier?.prefix(80) ?? "nothing") rather than by the \
            heading that named it: the id handed to mermaid named the heading, and mermaid removed \
            it before drawing its own element under the same id. The two families are kept apart \
            by MarkdownPreviewPage.diagramElementIDPrefix carrying a capital no slug can spell.
            """)
        XCTAssertTrue(carrier?.contains("Pisaka diagram 1") ?? false, "the heading must keep its text")
    }

    /// Poll the page for `condition`, failing loudly rather than vacuously.
    private func waitFor(_ what: String, in webView: WKWebView, _ condition: String) async throws {
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if let answer = try? await webView.evaluateJavaScript(condition) as? Bool, answer {
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("timed out waiting for \(what)")
    }
}
#endif
