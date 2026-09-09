#if os(macOS)
import Foundation
import PisakaCore
import UniformTypeIdentifiers

/// Everything the Markdown preview's page is allowed to fetch, and the bytes
/// each of those fetches answers with.
///
/// It serves exactly three kinds of thing — the shell document, the four
/// bundled files, and project files inside the opened root — and everything
/// else is a 404. **It decides none of that**: an incoming URL goes straight to
/// `MarkdownPreviewAsset.classify(_:context:)`, and this file switches over the
/// four cases Core answers with. It splits no path, compares no scheme, spells
/// neither the scheme nor the host nor either path prefix, and never asks
/// whether a file is inside the project — all of those questions are settled in
/// the same Core file that composed the URL in the first place, which is what
/// makes the round trip a function rather than two implementations agreeing by
/// habit.
///
/// **A refusal is a 404, not an error.** Nothing here throws, fails the task or
/// writes a log line: a page asking for something it may not have gets the
/// answer a web server gives, and a missing image renders as a missing image.
/// Failing the task instead would put a WebKit error in the console for every
/// broken link in every document, and a log line would be a channel from a
/// document's contents into the app's diagnostics.
///
/// **Its two pieces of state are retargetable**, because there is one handler
/// and one web view per window while there are many Markdown tabs: the shell is
/// re-installed when the theme or the code font size changes (the page is then
/// re-loaded from the same URL), and the document context is re-pointed on every
/// selection change, so the containment check the classifier makes is always
/// against the tab being shown now.
///
/// It deliberately does **not** import WebKit. The `WKURLSchemeHandler`
/// conformance is one adapter in `MarkdownPreviewWebView.swift` — the feature's
/// one WebKit file — over ``answer(for:)``, which is a plain function of a URL
/// and this object's state and is therefore assertable in the app-layer bundle
/// without a web view, a window or a task object.
@MainActor
final class MarkdownPreviewSchemeHandler: NSObject {

    /// The shell document served for the shell URL, or `nil` before one has been
    /// installed.
    ///
    /// `nil` answers a 404 rather than an empty page on purpose: the only way to
    /// reach the shell URL before the glue has composed a document is a
    /// navigation the app did not ask for, and an empty `text/html` would leave
    /// a blank page that looks like a rendering failure.
    var shellHTML: String?

    /// Which document is being previewed, and where its project begins — the
    /// context every containment question is asked against.
    var context: MarkdownDocumentContext = .none

    /// The bundle subdirectory the four page files are copied into, verbatim, by
    /// the `Resources/MarkdownPreview` folder reference.
    ///
    /// The *names* inside it are Core's (`MarkdownPreviewPage.bundledFileNames`,
    /// which the classifier checks membership in before this file is ever
    /// reached); only where the copy lands is the app's business, and it is
    /// spelled here alone.
    static let bundledDirectory = "MarkdownPreview"

    /// One answered request: the bytes, and how the page should read them.
    struct Answer: Equatable {
        let data: Data
        let mimeType: String
        let textEncodingName: String?
    }

    /// The answer for `url`, or `nil` for the 404.
    ///
    /// A read that fails is `nil` too, and the two are one outcome deliberately:
    /// a file deleted between the render and the fetch is not distinguishable
    /// from one that was never reachable, and the page has nothing useful to do
    /// with the difference.
    func answer(for url: URL) -> Answer? {
        switch MarkdownPreviewAsset.classify(url, context: context) {
        case .shell:
            guard let html = shellHTML else { return nil }
            return Answer(data: Data(html.utf8), mimeType: "text/html", textEncodingName: "utf-8")

        case .bundled(let name):
            guard
                let fileURL = Bundle.main.url(
                    forResource: name,
                    withExtension: nil,
                    subdirectory: Self.bundledDirectory
                ),
                let data = try? Data(contentsOf: fileURL)
            else { return nil }
            // The two scripts and the stylesheet are UTF-8 by authorship, and
            // the page has no `<meta charset>` to fall back on for a
            // subresource.
            return Answer(data: data, mimeType: Self.mimeType(for: name), textEncodingName: "utf-8")

        case .asset(let fileURL):
            guard let data = try? Data(contentsOf: fileURL) else { return nil }
            // No encoding is claimed for a project file: these are images, and
            // naming an encoding for bytes that have none is a statement this
            // layer is in no position to make.
            return Answer(
                data: data,
                mimeType: Self.mimeType(for: fileURL.lastPathComponent),
                textEncodingName: nil
            )

        case .refused:
            return nil
        }
    }

    /// The MIME type for a file name, from the system's own type table.
    ///
    /// Read from the extension rather than from a table written here, so a
    /// project image of any format the system knows is served as itself. The
    /// fallback is the one every web server uses for bytes it cannot name, and
    /// it renders as a broken image — which is the right outcome for a file the
    /// system has no type for.
    private static func mimeType(for fileName: String) -> String {
        let ext = (fileName as NSString).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext), let mime = type.preferredMIMEType
        else { return "application/octet-stream" }
        return mime
    }
}
#endif
