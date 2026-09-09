#if os(macOS)
import Foundation
import WebKit
import XCTest
import PisakaCore
@testable import Pisaka

/// `MarkdownPreviewSchemeHandler` over a real temporary project tree.
///
/// **The three answered kinds and the refusals, in the app layer, because that
/// is where they can be answered at all**: the shell is state this object holds,
/// a bundled file is bytes in `Bundle.main` (the host app — which is what makes
/// this an app-bundle test rather than a Core one, and what makes it a real
/// check of the `Resources/MarkdownPreview` folder reference), and a project
/// file is bytes on disk. Which URL is which is Core's answer and is asserted
/// exhaustively in `MarkdownPreviewAssetTests`; what is asserted here is that
/// each of Core's four cases produces the right *response*.
///
/// The last case is the one worth stating: a refusal is a 404 and nothing else.
/// The adapter half is exercised through a stub `WKURLSchemeTask` for exactly
/// that reason — the property is not "the handler returns nil", it is "the page
/// is told 404 and no error is ever raised", and only the task can see the
/// difference.
final class MarkdownPreviewSchemeHandlerTests: XCTestCase {

    // MARK: - The tree

    private var root: URL!
    private var documentURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("markdown-preview-handler-\(UUID().uuidString)")
        documentURL = root.appendingPathComponent("docs/readme.md")
        try FileManager.default.createDirectory(
            at: documentURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("# hi\n".utf8).write(to: documentURL)
        try Data([0x89, 0x50, 0x4e, 0x47]).write(to: root.appendingPathComponent("docs/diagram.png"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    @MainActor
    private func makeHandler() -> MarkdownPreviewSchemeHandler {
        let handler = MarkdownPreviewSchemeHandler()
        handler.context = MarkdownDocumentContext(documentURL: documentURL, projectRoot: root)
        handler.shellHTML = MarkdownPreviewPage.html(theme: .light, fontSize: 13)
        return handler
    }

    /// A preview URL by its page-relative path. Spelled from Core's own
    /// constants, so a test cannot go on passing against a scheme the product no
    /// longer uses.
    private func previewURL(path: String) -> URL {
        URL(string: "\(MarkdownPreviewPage.scheme)://\(MarkdownPreviewPage.host)\(path)")!
    }

    // MARK: - The three answered kinds

    @MainActor
    func testTheShellIsAnsweredAsTheInstalledDocument() throws {
        let handler = makeHandler()
        let answer = try XCTUnwrap(handler.answer(for: MarkdownPreviewPage.shellURL))
        XCTAssertEqual(answer.mimeType, "text/html")
        XCTAssertEqual(answer.textEncodingName, "utf-8")
        XCTAssertEqual(String(decoding: answer.data, as: UTF8.self), handler.shellHTML)
    }

    /// Before a shell has been installed there is nothing to serve, and that is a
    /// 404 rather than a blank page.
    @MainActor
    func testTheShellIsRefusedBeforeOneIsInstalled() {
        let handler = makeHandler()
        handler.shellHTML = nil
        XCTAssertNil(handler.answer(for: MarkdownPreviewPage.shellURL))
    }

    /// Every one of the four names the shell asks for reaches the app bundle —
    /// which is the folder reference itself under test, a file that does not
    /// reach it being a page that renders unstyled with no build error.
    @MainActor
    func testEveryBundledFileIsAnsweredFromTheAppBundle() throws {
        let handler = makeHandler()
        for name in MarkdownPreviewPage.bundledFileNames {
            let url = previewURL(path: MarkdownPreviewPage.bundledPath(forFileName: name))
            let answer = try XCTUnwrap(handler.answer(for: url), "\(name) is missing from the app bundle")
            XCTAssertFalse(answer.data.isEmpty, name)
            XCTAssertEqual(answer.textEncodingName, "utf-8", name)
        }
    }

    @MainActor
    func testTheBundledScriptsAndStylesheetCarryTheirOwnTypes() throws {
        let handler = makeHandler()
        let css = try XCTUnwrap(handler.answer(
            for: previewURL(path: MarkdownPreviewPage.bundledPath(
                forFileName: MarkdownPreviewPage.stylesheetFileName
            ))
        ))
        XCTAssertEqual(css.mimeType, "text/css")
        let js = try XCTUnwrap(handler.answer(
            for: previewURL(path: MarkdownPreviewPage.bundledPath(
                forFileName: MarkdownPreviewPage.previewScriptFileName
            ))
        ))
        XCTAssertTrue(js.mimeType.hasSuffix("javascript"), js.mimeType)
    }

    /// The bundled bytes are read once each and kept, and the memory is keyed by
    /// the name asked for.
    ///
    /// The saving itself is invisible from here — what a cache can get *wrong*
    /// is not: one keyed by nothing, or by the wrong thing, answers the first
    /// file's bytes for every later name, so `mermaid.min.js` would arrive as
    /// the stylesheet. Two interleaved passes: every name keeps its own answer,
    /// and no two names share one.
    @MainActor
    func testEachBundledFileKeepsItsOwnBytesAcrossRepeatedFetches() throws {
        let handler = makeHandler()
        let urls = MarkdownPreviewPage.bundledFileNames.map {
            previewURL(path: MarkdownPreviewPage.bundledPath(forFileName: $0))
        }
        var first: [String: Data] = [:]
        for (name, url) in zip(MarkdownPreviewPage.bundledFileNames, urls) {
            first[name] = try XCTUnwrap(handler.answer(for: url)).data
        }
        for (name, url) in zip(MarkdownPreviewPage.bundledFileNames, urls) {
            XCTAssertEqual(try XCTUnwrap(handler.answer(for: url)).data, first[name], name)
        }
        XCTAssertEqual(Set(first.values).count, first.count, "two bundled names answered the same bytes")
    }

    /// The round trip: the URL the renderer would have put into the page for a
    /// relative image is the URL the handler serves that file's bytes for.
    @MainActor
    func testAProjectFileIsAnsweredThroughTheURLTheRendererWouldEmit() throws {
        let handler = makeHandler()
        let url = try XCTUnwrap(MarkdownPreviewAsset.assetURL(
            forTarget: "diagram.png",
            context: handler.context
        ))
        let answer = try XCTUnwrap(handler.answer(for: url))
        XCTAssertEqual(answer.data, Data([0x89, 0x50, 0x4e, 0x47]))
        XCTAssertEqual(answer.mimeType, "image/png")
        XCTAssertNil(answer.textEncodingName)
    }

    /// A file inside the root that has since been deleted is the same 404 as one
    /// that was never reachable.
    @MainActor
    func testAProjectFileThatNoLongerExistsIsRefused() throws {
        let handler = makeHandler()
        let url = try XCTUnwrap(MarkdownPreviewAsset.assetURL(
            forTarget: "diagram.png",
            context: handler.context
        ))
        try FileManager.default.removeItem(at: root.appendingPathComponent("docs/diagram.png"))
        XCTAssertNil(handler.answer(for: url))
    }

    // MARK: - The refusals

    @MainActor
    func testAnEscapeOutOfTheProjectIsRefused() {
        let handler = makeHandler()
        let url = previewURL(path: MarkdownPreviewPage.filePathPrefix + "../../etc/passwd")
        XCTAssertNil(handler.answer(for: url))
    }

    @MainActor
    func testAForgedPreviewURLIsRefused() {
        let handler = makeHandler()
        // Another host, a path under neither prefix, and a bundled name that is
        // not one of the four — three spellings of the same refusal.
        XCTAssertNil(handler.answer(for: URL(string: "\(MarkdownPreviewPage.scheme)://evil/index.html")!))
        XCTAssertNil(handler.answer(for: previewURL(path: "/secret/index.html")))
        XCTAssertNil(handler.answer(
            for: previewURL(path: MarkdownPreviewPage.bundledPath(forFileName: "../../Info.plist"))
        ))
    }

    /// With no folder open there is no root to check against, so no project file
    /// is reachable at all — while the shell and the bundled files still are.
    @MainActor
    func testWithNoProjectRootOnlyTheShellAndTheBundledFilesAreServed() throws {
        let handler = makeHandler()
        let url = try XCTUnwrap(MarkdownPreviewAsset.assetURL(
            forTarget: "diagram.png",
            context: handler.context
        ))
        handler.context = MarkdownDocumentContext(documentURL: documentURL, projectRoot: nil)
        XCTAssertNil(handler.answer(for: url))
        XCTAssertNotNil(handler.answer(for: MarkdownPreviewPage.shellURL))
        XCTAssertNotNil(handler.answer(
            for: previewURL(path: MarkdownPreviewPage.bundledPath(
                forFileName: MarkdownPreviewPage.stylesheetFileName
            ))
        ))
    }

    // MARK: - The task adapter

    @MainActor
    func testAnAnsweredRequestFinishesWithItsBytesAndNoFailure() throws {
        let handler = makeHandler()
        let task = StubSchemeTask(url: MarkdownPreviewPage.shellURL)
        handler.webView(WKWebView(), start: task)

        XCTAssertEqual(task.receivedData, Data(try XCTUnwrap(handler.shellHTML).utf8))
        XCTAssertEqual(task.response?.mimeType, "text/html")
        XCTAssertTrue(task.isFinished)
        XCTAssertNil(task.failure)
    }

    /// The property the whole refusal path exists for: a 404, finished, with no
    /// error raised — for an escape and for a forged URL alike.
    @MainActor
    func testARefusedRequestIsAPlainNotFoundAndNeverAFailure() throws {
        let handler = makeHandler()
        let refused = [
            previewURL(path: MarkdownPreviewPage.filePathPrefix + "../../etc/passwd"),
            URL(string: "\(MarkdownPreviewPage.scheme)://evil/index.html")!,
        ]
        for url in refused {
            let task = StubSchemeTask(url: url)
            handler.webView(WKWebView(), start: task)

            XCTAssertEqual((task.response as? HTTPURLResponse)?.statusCode, 404, url.absoluteString)
            XCTAssertTrue(task.receivedData.isEmpty, url.absoluteString)
            XCTAssertTrue(task.isFinished, url.absoluteString)
            XCTAssertNil(task.failure, url.absoluteString)
        }
    }
}

/// A `WKURLSchemeTask` that records what it was told instead of rendering it.
///
/// WebKit never sees this object, so nothing here has to behave the way its own
/// task does — it only has to answer `request` and remember the four calls the
/// adapter can make.
private final class StubSchemeTask: NSObject, WKURLSchemeTask {
    let request: URLRequest

    private(set) var response: URLResponse?
    private(set) var receivedData = Data()
    private(set) var isFinished = false
    private(set) var failure: Error?

    init(url: URL) {
        request = URLRequest(url: url)
    }

    func didReceive(_ response: URLResponse) { self.response = response }

    func didReceive(_ data: Data) { receivedData.append(data) }

    func didFinish() { isFinished = true }

    func didFailWithError(_ error: any Error) { failure = error }
}
#endif
