import XCTest
@testable import PisakaCore

/// The app-scheme ↔ project-file mapping, both directions, and the handler's
/// dispatch.
///
/// The interesting half is containment, and containment is a question about the
/// **file system**, not about strings: a symlink inside the project pointing out
/// of it, and a file reached through a symlinked ancestor, are exactly the two
/// cases a lexical prefix check gets wrong in opposite directions. So the cases
/// that matter run against real temporary trees with real symlinks; the ones
/// that are genuinely about spelling (schemes, prefixes, the empty path) use
/// fixed paths, where no disk is needed to know the answer.
final class MarkdownPreviewAssetTests: XCTestCase {

    // MARK: - Temp-directory helper

    /// A fresh temporary directory, removed when the test ends.
    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    /// A project at `/p/root` with a document two levels down, so `..` has
    /// somewhere to climb to and somewhere to climb *past*.
    private let context = MarkdownDocumentContext(
        documentURL: URL(fileURLWithPath: "/p/root/docs/guide.md"),
        projectRoot: URL(fileURLWithPath: "/p/root")
    )

    private func previewURL(_ string: String) throws -> URL {
        try XCTUnwrap(URL(string: string))
    }

    // MARK: - Forward: what resolves

    func testRelativeTargetInsideTheRootBecomesAnAppSchemeURL() {
        XCTAssertEqual(
            MarkdownPreviewAsset.assetURL(forTarget: "img/diagram.png", context: context)?.absoluteString,
            "pisaka-preview://preview/file/docs/img/diagram.png"
        )
    }

    func testTargetClimbingToTheRootResolves() {
        XCTAssertEqual(
            MarkdownPreviewAsset.assetURL(forTarget: "../README.md", context: context)?.absoluteString,
            "pisaka-preview://preview/file/README.md"
        )
    }

    func testAbsoluteTargetInsideTheRootResolves() {
        XCTAssertEqual(
            MarkdownPreviewAsset.assetURL(forTarget: "/p/root/img.png", context: context)?.absoluteString,
            "pisaka-preview://preview/file/img.png"
        )
    }

    func testAPathWithASpaceIsPercentEncodedOnce() throws {
        let url = try XCTUnwrap(MarkdownPreviewAsset.assetURL(forTarget: "my file.png", context: context))
        XCTAssertEqual(url.absoluteString, "pisaka-preview://preview/file/docs/my%20file.png")
        // And decodes back to the one space it started with, rather than to
        // `%2520` a second encoding would have produced.
        XCTAssertEqual(url.path, "/file/docs/my file.png")
    }

    func testAPercentEncodedTargetNamesTheSameFileAsItsDecodedSpelling() {
        XCTAssertEqual(
            MarkdownPreviewAsset.assetURL(forTarget: "my%20file.png", context: context),
            MarkdownPreviewAsset.assetURL(forTarget: "my file.png", context: context)
        )
    }

    // MARK: - Forward: what does not

    func testEscapingTheRootResolvesToNothing() {
        XCTAssertNil(MarkdownPreviewAsset.assetURL(forTarget: "../../secret.png", context: context))
    }

    func testAbsoluteTargetOutsideTheRootResolvesToNothing() {
        XCTAssertNil(MarkdownPreviewAsset.assetURL(forTarget: "/etc/passwd", context: context))
        XCTAssertNil(MarkdownPreviewAsset.assetURL(forTarget: "file:///etc/passwd", context: context))
    }

    func testNetworkAndActiveSchemesResolveToNothing() {
        for target in [
            "https://example.com/i.png",
            "http://example.com/i.png",
            "mailto:someone@example.com",
            "data:image/png;base64,AAAA",
            "javascript:alert(1)",
            "pisaka-preview://preview/file/img.png",
        ] {
            XCTAssertNil(
                MarkdownPreviewAsset.assetURL(forTarget: target, context: context),
                "\(target) must not resolve to a project file"
            )
        }
    }

    func testAFragmentIsNotAFile() {
        XCTAssertNil(MarkdownPreviewAsset.assetURL(forTarget: "#section", context: context))
    }

    /// A cross-file link carrying an anchor — the ordinary shape of a link
    /// between two documents in a tree — names the *file*.
    ///
    /// The failure this pins is a silent one: the whole string treated as a path
    /// produces a URL for a file called `other.md#usage`, which resolves, which
    /// the inverse direction hands back, and which the app then fails to open —
    /// a working link that beeps.
    func testAFragmentOnAPathNamesTheFileAndNotTheFragment() {
        for target in ["other.md#usage", "./other.md#usage"] {
            XCTAssertEqual(
                MarkdownPreviewAsset.assetURL(forTarget: target, context: context)?.absoluteString,
                "pisaka-preview://preview/file/docs/other.md",
                "\(target) names docs/other.md"
            )
        }
        XCTAssertEqual(
            MarkdownPreviewAsset.assetURL(forTarget: "../README.md#install", context: context)?
                .absoluteString,
            "pisaka-preview://preview/file/README.md"
        )
    }

    /// And the fragment is dropped *before* decoding, so the one spelling that
    /// means a literal `#` in a file name still reaches that file.
    func testAPercentEncodedHashStaysPartOfTheName() {
        XCTAssertEqual(
            MarkdownPreviewAsset.assetURL(forTarget: "od%23d.png", context: context)?.absoluteString,
            "pisaka-preview://preview/file/docs/od%23d.png"
        )
    }

    /// The fragment cannot be used to leave the tree either: it is dropped, so
    /// what is checked for containment is the path in front of it.
    func testAFragmentCannotSmuggleAPathOutOfTheRoot() {
        XCTAssertNil(MarkdownPreviewAsset.assetURL(forTarget: "../../secret.md#x", context: context))
    }

    /// A query is read out the same way, and for the same reason: the cache-buster
    /// a document copied from a web page names the file in front of it.
    ///
    /// The failure this pins is the fragment's own, one component along — the
    /// whole string as a path produces a URL for a file called `logo.png?v=2`,
    /// which resolves and which the handler then cannot read, so the image is
    /// broken with no sign of why.
    func testAQueryIsNotPartOfTheFileName() {
        XCTAssertEqual(
            MarkdownPreviewAsset.assetURL(forTarget: "img/logo.png?v=2", context: context)?.absoluteString,
            "pisaka-preview://preview/file/docs/img/logo.png"
        )
        XCTAssertEqual(
            MarkdownPreviewAsset.assetURL(forTarget: "../README.md?raw=1#install", context: context)?
                .absoluteString,
            "pisaka-preview://preview/file/README.md"
        )
    }

    /// And it is dropped *before* decoding, so the one spelling that means a
    /// literal `?` in a file name still reaches that file.
    func testAPercentEncodedQuestionMarkStaysPartOfTheName() {
        XCTAssertEqual(
            MarkdownPreviewAsset.assetURL(forTarget: "why%3F.png", context: context)?.absoluteString,
            "pisaka-preview://preview/file/docs/why%3F.png"
        )
    }

    /// A query cannot smuggle a path out of the tree, and cannot stand in for
    /// one either: with nothing in front of it there is no file being named.
    func testAQueryCannotSmuggleOrStandInForAPath() {
        XCTAssertNil(MarkdownPreviewAsset.assetURL(forTarget: "../../secret.md?x=1", context: context))
        XCTAssertNil(MarkdownPreviewAsset.assetURL(forTarget: "?v=2", context: context))
    }

    /// A scheme is case-insensitive, and `URL.scheme` hands back the document's
    /// own spelling — so `file:` must be recognised however it was written, the
    /// same reading `MarkdownLinkRule` already makes.
    ///
    /// The failure is a false refusal: a perfectly valid in-project target
    /// emitted unresolved and then refused by the navigation rule.
    func testTheFileSchemeIsMatchedCaseInsensitively() {
        for target in ["FILE:///p/root/img/logo.png", "File:///p/root/img/logo.png"] {
            XCTAssertEqual(
                MarkdownPreviewAsset.assetURL(forTarget: target, context: context)?.absoluteString,
                "pisaka-preview://preview/file/img/logo.png",
                "\(target) names img/logo.png"
            )
        }
    }

    /// Widening the reading does not widen what resolves: every other scheme is
    /// still nothing, in any case it is spelled.
    func testOtherSchemesResolveToNothingInAnyCase() {
        for target in ["HTTPS://example.com/i.png", "JavaScript:alert(1)", "DATA:image/png;base64,AAAA"] {
            XCTAssertNil(
                MarkdownPreviewAsset.assetURL(forTarget: target, context: context),
                "\(target) must not resolve to a project file"
            )
        }
    }

    /// A destination carrying a scheme is refused **because it carries one**,
    /// not because Foundation could parse it: the scheme is read lexically, so
    /// a target `URL(string:)` answers `nil` for still settles the question.
    ///
    /// The failure this pins is not a refusal but a wrong resolution. A
    /// scheme-less answer falls through to the relative-path branch, where the
    /// whole destination is resolved against the document's directory and lands
    /// *inside* the project root — so it resolves, the navigation rule answers
    /// `openInEditor`, and clicking an external link opens a missing file
    /// instead of the browser. macOS 13, the deployment target, refuses every
    /// non-ASCII character here, which makes an ordinary link the common case.
    func testAnUnparseableSchemeIsStillASchemeAndResolvesToNothing() {
        for target in [
            "https://ru.wikipedia.org/wiki/Привет",
            "https://exa mple.com/i.png",
            "http://[bad",
            "javascript:alert('привет')",
        ] {
            XCTAssertNil(
                MarkdownPreviewAsset.assetURL(forTarget: target, context: context),
                "\(target) carries a scheme and must not resolve to a project file"
            )
        }
    }

    /// And the lexical reading refuses nothing the parsed one accepted: a colon
    /// reached after a path separator is part of a name, not a scheme, and a
    /// leading character that cannot start one leaves the target scheme-less.
    func testAColonInsideAPathIsNotAScheme() {
        XCTAssertEqual(
            MarkdownPreviewAsset.assetURL(forTarget: "img/logo:v2.png", context: context)?.absoluteString,
            "pisaka-preview://preview/file/docs/img/logo:v2.png"
        )
        XCTAssertEqual(
            MarkdownPreviewAsset.assetURL(forTarget: "./2:1.png", context: context)?.absoluteString,
            "pisaka-preview://preview/file/docs/2:1.png"
        )
    }

    func testADocumentWithNoURLResolvesNothing() {
        let noDocument = MarkdownDocumentContext(
            documentURL: nil,
            projectRoot: URL(fileURLWithPath: "/p/root")
        )
        XCTAssertNil(MarkdownPreviewAsset.assetURL(forTarget: "img.png", context: noDocument))
        XCTAssertNil(MarkdownPreviewAsset.assetURL(forTarget: "/p/root/img.png", context: noDocument))
    }

    func testNoProjectRootResolvesNothing() {
        let noRoot = MarkdownDocumentContext(
            documentURL: URL(fileURLWithPath: "/p/root/docs/guide.md"),
            projectRoot: nil
        )
        XCTAssertNil(MarkdownPreviewAsset.assetURL(forTarget: "img.png", context: noRoot))
    }

    // MARK: - Forward: the file system's answers

    func testASymlinkPointingOutOfTheRootResolvesToNothing() throws {
        let dir = try makeTempDirectory()
        let root = dir.appendingPathComponent("root")
        let outside = dir.appendingPathComponent("outside")
        try write("secret", to: outside.appendingPathComponent("secret.png"))
        try write("# Guide", to: root.appendingPathComponent("guide.md"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("escape"),
            withDestinationURL: outside
        )

        let context = MarkdownDocumentContext(
            documentURL: root.appendingPathComponent("guide.md"),
            projectRoot: root
        )
        XCTAssertNil(MarkdownPreviewAsset.assetURL(forTarget: "escape/secret.png", context: context))
    }

    func testAFileReachedThroughASymlinkedAncestorResolvesToWhereItActuallyIs() throws {
        let dir = try makeTempDirectory()
        let root = dir.appendingPathComponent("root")
        try write("png", to: root.appendingPathComponent("real/img.png"))
        try write("# Guide", to: root.appendingPathComponent("real/guide.md"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link"),
            withDestinationURL: root.appendingPathComponent("real")
        )

        // The document is opened *through* the symlink; the asset beside it is
        // inside the root either way, and is named by its canonical position.
        let context = MarkdownDocumentContext(
            documentURL: root.appendingPathComponent("link/guide.md"),
            projectRoot: root
        )
        XCTAssertEqual(
            MarkdownPreviewAsset.assetURL(forTarget: "img.png", context: context)?.path,
            "/file/real/img.png"
        )
    }

    // MARK: - The inverse

    func testTheInverseAnswersTheFileTheForwardDirectionNamed() throws {
        let url = try previewURL("pisaka-preview://preview/file/docs/img/diagram.png")
        XCTAssertEqual(
            MarkdownPreviewAsset.projectFileURL(forPreviewURL: url, context: context)?.path,
            "/p/root/docs/img/diagram.png"
        )
    }

    func testTheInverseDecodesAPercentEncodedPathOnce() throws {
        let url = try previewURL("pisaka-preview://preview/file/docs/my%20file.png")
        XCTAssertEqual(
            MarkdownPreviewAsset.projectFileURL(forPreviewURL: url, context: context)?.path,
            "/p/root/docs/my file.png"
        )
    }

    func testTheInverseRefusesAForeignSchemeOrHost() throws {
        for string in [
            "https://preview/file/img.png",
            "file:///p/root/img.png",
            "pisaka-preview://elsewhere/file/img.png",
        ] {
            let url = try previewURL(string)
            XCTAssertNil(
                MarkdownPreviewAsset.projectFileURL(forPreviewURL: url, context: context),
                "\(string) must not name a project file"
            )
        }
    }

    func testTheInverseRefusesAnythingOutsideTheFilePrefix() throws {
        for string in [
            "pisaka-preview://preview/index.html",
            "pisaka-preview://preview/assets/preview.css",
            "pisaka-preview://preview/file/",
            "pisaka-preview://preview/",
        ] {
            let url = try previewURL(string)
            XCTAssertNil(
                MarkdownPreviewAsset.projectFileURL(forPreviewURL: url, context: context),
                "\(string) must not name a project file"
            )
        }
    }

    func testTheInverseRefusesAForgedPathClimbingOutOfTheRoot() throws {
        let url = try previewURL("pisaka-preview://preview/file/../../etc/passwd")
        XCTAssertNil(MarkdownPreviewAsset.projectFileURL(forPreviewURL: url, context: context))
    }

    func testTheInverseRefusesASymlinkPointingOutOfTheRoot() throws {
        let dir = try makeTempDirectory()
        let root = dir.appendingPathComponent("root")
        let outside = dir.appendingPathComponent("outside")
        try write("secret", to: outside.appendingPathComponent("secret.png"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("escape"),
            withDestinationURL: outside
        )

        let context = MarkdownDocumentContext(documentURL: nil, projectRoot: root)
        let url = try previewURL("pisaka-preview://preview/file/escape/secret.png")
        XCTAssertNil(MarkdownPreviewAsset.projectFileURL(forPreviewURL: url, context: context))
    }

    func testTheInverseRefusesEverythingWithNoProjectRoot() throws {
        let url = try previewURL("pisaka-preview://preview/file/docs/img.png")
        XCTAssertNil(MarkdownPreviewAsset.projectFileURL(forPreviewURL: url, context: .none))
    }

    func testTheInverseSpellsTheRootTheCallerGave() throws {
        // A `/private`-spelled root must come back `/private`-spelled: the app
        // opens tabs under the spelling it holds, and only the containment check
        // is canonical.
        let dir = try makeTempDirectory()
        let root = URL(fileURLWithPath: "/private" + dir.path).appendingPathComponent("root")
        try write("png", to: root.appendingPathComponent("img.png"))

        let context = MarkdownDocumentContext(documentURL: nil, projectRoot: root)
        let url = try previewURL("pisaka-preview://preview/file/img.png")
        XCTAssertEqual(
            MarkdownPreviewAsset.projectFileURL(forPreviewURL: url, context: context)?.path,
            root.appendingPathComponent("img.png").path
        )
    }

    // MARK: - The round trip

    func testTheTwoDirectionsAgree() throws {
        let dir = try makeTempDirectory()
        let root = dir.appendingPathComponent("root")
        try write("png", to: root.appendingPathComponent("docs/img/diagram.png"))
        try write("# Guide", to: root.appendingPathComponent("docs/guide.md"))

        let context = MarkdownDocumentContext(
            documentURL: root.appendingPathComponent("docs/guide.md"),
            projectRoot: root
        )
        let forward = try XCTUnwrap(
            MarkdownPreviewAsset.assetURL(forTarget: "img/diagram.png", context: context)
        )
        let back = try XCTUnwrap(
            MarkdownPreviewAsset.projectFileURL(forPreviewURL: forward, context: context)
        )
        XCTAssertEqual(
            CanonicalPath.canonical(back),
            CanonicalPath.canonical(root.appendingPathComponent("docs/img/diagram.png"))
        )
    }

    // MARK: - The handler's dispatch

    func testTheShellIsClassifiedAsTheShell() {
        XCTAssertEqual(
            MarkdownPreviewAsset.classify(MarkdownPreviewPage.shellURL, context: context),
            .shell
        )
    }

    func testAFragmentOnTheShellIsStillTheShell() throws {
        let url = try previewURL("pisaka-preview://preview/index.html#section")
        XCTAssertEqual(MarkdownPreviewAsset.classify(url, context: context), .shell)
    }

    func testEveryBundledFileIsClassifiedByName() throws {
        for name in MarkdownPreviewPage.bundledFileNames {
            let url = try previewURL(
                "pisaka-preview://preview" + MarkdownPreviewPage.bundledPath(forFileName: name)
            )
            XCTAssertEqual(MarkdownPreviewAsset.classify(url, context: context), .bundled(name: name))
        }
    }

    func testAnUnknownBundledNameIsRefused() throws {
        for string in [
            "pisaka-preview://preview/assets/secret.js",
            "pisaka-preview://preview/assets/",
            "pisaka-preview://preview/assets/../index.html",
        ] {
            let url = try previewURL(string)
            XCTAssertEqual(
                MarkdownPreviewAsset.classify(url, context: context),
                .refused,
                "\(string) must be refused"
            )
        }
    }

    func testAProjectFileIsClassifiedAsItsFileURL() throws {
        let url = try previewURL("pisaka-preview://preview/file/docs/img.png")
        XCTAssertEqual(
            MarkdownPreviewAsset.classify(url, context: context),
            .asset(fileURL: URL(fileURLWithPath: "/p/root/docs/img.png"))
        )
    }

    func testAForgedOrForeignURLIsRefused() throws {
        for string in [
            "pisaka-preview://preview/file/../../etc/passwd",
            "pisaka-preview://elsewhere/file/img.png",
            "https://preview/file/img.png",
            "pisaka-preview://preview/anything",
        ] {
            let url = try previewURL(string)
            XCTAssertEqual(
                MarkdownPreviewAsset.classify(url, context: context),
                .refused,
                "\(string) must be refused"
            )
        }
    }

    func testAProjectFileIsRefusedWithNoProjectRoot() throws {
        let url = try previewURL("pisaka-preview://preview/file/docs/img.png")
        XCTAssertEqual(MarkdownPreviewAsset.classify(url, context: .none), .refused)
        // The shell and the bundled files are still served: they are the app's
        // own bytes and have nothing to do with a project.
        XCTAssertEqual(MarkdownPreviewAsset.classify(MarkdownPreviewPage.shellURL, context: .none), .shell)
    }
}
