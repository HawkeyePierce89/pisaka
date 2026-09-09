import XCTest
@testable import PisakaCore

/// The "these two files are the ones we said they are" guard.
///
/// `Resources/MarkdownPreview/` holds the preview page's four files, and two of
/// them are third-party bundles copied verbatim out of a published distribution.
/// Nothing in this repository compiles them, links them or parses them: they are
/// copied into the app as a folder reference and handed to a web view. So every
/// ordinary gate is blind to them. A file re-downloaded from an unpinned URL, a
/// half-finished `curl`, a local "quick fix" applied to a minified bundle, or a
/// version bump that updated `VENDORED.md` and not the file (or the file and not
/// the document) all produce a green `swift test`, a green build, and an app
/// shipping bytes nobody recorded.
///
/// This suite is the `LSPProvisioningManifestTests` answer applied to bytes that
/// are already here rather than bytes that arrive later: read each file through
/// `#filePath`, assert its **byte count** and its **SHA-256** — computed with
/// Core's own `SHA256`, so `swift test` needs no dependency — and then close the
/// loop three ways, because a digest alone only proves the file did not change,
/// not that it is what the repository *claims*:
///
///  * the pinned digest must match the file (the file has not drifted);
///  * `VENDORED.md` must state the same version, byte count and digest (the
///    document has not drifted from the file);
///  * the file must contain its own version string (the *version* is not just an
///    assertion — the bundle says it about itself, so a bump that swapped the
///    bytes without moving the version line fails here).
///
/// Plus the one property that is specific to mermaid and is the reason its
/// version is pinned where it is: the bundle must be a *single* file. mermaid's
/// chunked distribution loads its diagram definitions through a run-time
/// `import()`, which the page's CSP refuses and the scheme handler does not
/// serve — the diagrams would silently never appear, on a page with no error to
/// show. That property is checked here rather than trusted to the update
/// procedure, because it is the one a version bump changes without warning.
final class MarkdownPreviewAssetPinTests: XCTestCase {

    /// One third-party bundle, as this repository records it.
    private struct AssetPin {
        /// The `licenses.json` id, which is also the `## ` heading its section of
        /// `VENDORED.md` carries — one name for all three records.
        let id: String
        let fileName: String
        let version: String
        let byteCount: Int
        let sha256: String
        /// The version as the bundle spells it *in its own bytes*.
        let versionMarker: String
    }

    /// The pins. Bumping a bundle means editing this table, `VENDORED.md` and
    /// `licenses.json` together — which is the point: three records that must
    /// agree are three chances to notice a file that is not what was intended,
    /// where one record is no chance at all.
    private static let pins: [AssetPin] = [
        AssetPin(
            id: "highlight.js",
            fileName: MarkdownPreviewPage.highlightScriptFileName,
            version: "11.11.1",
            byteCount: 127_496,
            sha256: "c4a399dd6f488bc97a3546e3476747b3e714c99c57b9473154c6fb8d259b9381",
            versionMarker: "Highlight.js v11.11.1"
        ),
        AssetPin(
            id: "mermaid",
            fileName: MarkdownPreviewPage.diagramScriptFileName,
            version: "11.15.0",
            byteCount: 3_312_967,
            sha256: "70137e77bb273bb2ef972b86e8b0400cca8be53cb25bfc45911a186dc98665de",
            versionMarker: "version:\"11.15.0\""
        ),
    ]

    /// The two files written in this repository, which carry no pin because they
    /// are read as source and reviewed as source.
    private static let firstPartyFileNames: Set<String> = [
        MarkdownPreviewPage.stylesheetFileName,
        MarkdownPreviewPage.previewScriptFileName,
    ]

    /// The document that records the two pins in prose.
    private static let vendoredDocFileName = "VENDORED.md"

    // MARK: - The bytes

    func testEveryPinnedAssetHasItsRecordedSizeAndDigest() throws {
        for pin in Self.pins {
            let data = try data(forAsset: pin.fileName)

            XCTAssertEqual(data.count, pin.byteCount, """
                Resources/MarkdownPreview/\(pin.fileName) is \(data.count) bytes; this suite pins \
                \(pin.byteCount). Either the file was replaced without updating the pin, or a \
                download was truncated. Nothing else in the pipeline reads this file.
                """)
            XCTAssertEqual(SHA256.hexadecimalDigest(of: data), pin.sha256, """
                Resources/MarkdownPreview/\(pin.fileName) does not hash to its pinned SHA-256. The \
                shipped bundle is not the one this repository recorded — re-download it from the \
                distribution VENDORED.md names, verify it against upstream's published digest, and \
                update the pin here and there together.
                """)
        }
    }

    /// The digest above proves the file has not moved; this proves it is the
    /// *release* it is filed under. A bundle states its own version, so the two
    /// can be compared — which is what catches the bump that replaced the bytes
    /// and left every version record saying the old number.
    func testEveryPinnedAssetStatesItsOwnVersion() throws {
        for pin in Self.pins {
            let source = try text(forAsset: pin.fileName)
            XCTAssertTrue(source.contains(pin.versionMarker), """
                Resources/MarkdownPreview/\(pin.fileName) does not contain “\(pin.versionMarker)” — \
                the bundle does not say it is \(pin.version), so either the pinned version is wrong \
                or upstream changed how it embeds it (in which case update `versionMarker` after \
                confirming the new spelling by hand).
                """)
        }
    }

    // MARK: - The document

    func testVendoredDocRecordsExactlyThePinnedAssets() throws {
        let sections = MarkdownPreviewVendoredDoc.sections(in: try vendoredDoc())
        let documented = Set(sections.values.compactMap { $0.value("File") })

        XCTAssertEqual(documented, Set(Self.pins.map(\.fileName)), """
            Resources/MarkdownPreview/VENDORED.md documents \(documented.sorted()) but this suite \
            pins \(Self.pins.map(\.fileName).sorted()). A third-party file added to that directory \
            without a section of its own — or a section left behind after one was dropped — means \
            the document has stopped being the record of what ships.
            """)
    }

    func testVendoredDocStatesTheSameVersionSizeAndDigestAsThePins() throws {
        let sections = MarkdownPreviewVendoredDoc.sections(in: try vendoredDoc())

        for pin in Self.pins {
            let section = try XCTUnwrap(sections[pin.id], """
                Resources/MarkdownPreview/VENDORED.md has no `## \(pin.id)` section — the pin table \
                in this suite has nothing to be checked against.
                """)

            XCTAssertEqual(section.value("Version"), pin.version,
                           "VENDORED.md records \(pin.id) at a different version than the pin")
            XCTAssertEqual(section.value("Bytes"), String(pin.byteCount),
                           "VENDORED.md records a different byte count for \(pin.fileName)")
            XCTAssertEqual(section.value("SHA-256"), pin.sha256,
                           "VENDORED.md records a different SHA-256 for \(pin.fileName)")
            XCTAssertEqual(section.value("File"), pin.fileName,
                           "VENDORED.md's `## \(pin.id)` section names another file")
        }
    }

    // MARK: - The directory

    /// The directory is a folder reference: whatever is in it ships. So its
    /// listing must be exactly the four files the page asks for plus the
    /// document that records the two pinned ones — an extra file would be
    /// copied into the app with nothing naming it, and a missing one is a `404`
    /// the page answers by rendering unstyled, unhighlighted, or without
    /// diagrams, with no build error anywhere.
    func testTheDirectoryHoldsExactlyTheFilesThePageAsksForAndTheirRecord() throws {
        let listing = try FileManager.default
            .contentsOfDirectory(atPath: Self.assetDirectory.path)
            .filter { $0 != ".DS_Store" }

        let expected = Set(MarkdownPreviewPage.bundledFileNames).union([Self.vendoredDocFileName])
        XCTAssertEqual(Set(listing), expected, """
            Resources/MarkdownPreview must hold exactly \(expected.sorted()). The directory is a \
            folder reference, so anything in it ships; and every name the shell's tags spell must \
            be there, or the page loads with that file missing and says nothing about it.
            """)

        // The set above is derived from `bundledFileNames`, which is what the
        // shell links and what the handler serves. This is the other half:
        // the four names are the two pinned bundles plus the two files written
        // here, and no name may belong to neither — a bundle with no pin is
        // exactly the unrecorded third-party file this suite exists to prevent.
        XCTAssertEqual(Set(MarkdownPreviewPage.bundledFileNames),
                       Set(Self.pins.map(\.fileName)).union(Self.firstPartyFileNames), """
                       Every file the page asks for must be either a pinned third-party bundle or \
                       one of the two files written in this repository. A new one is one or the \
                       other, and saying which is what decides whether it needs a pin and a licence.
                       """)
    }

    // MARK: - The single-file property

    /// mermaid's pin exists to hold this property, so assert the property rather
    /// than trusting the version.
    ///
    /// A chunked build is not a broken build — it loads, it defines its global,
    /// and it fails only when a diagram is actually rendered, by requesting a
    /// URL the CSP refuses. There is no error the page could show for that, so
    /// the check has to be here.
    func testTheDiagramBundleIsASingleSelfContainedFile() throws {
        let source = try text(forAsset: MarkdownPreviewPage.diagramScriptFileName)

        XCTAssertFalse(source.contains("import("), """
            Resources/MarkdownPreview/\(MarkdownPreviewPage.diagramScriptFileName) spells a dynamic \
            `import(`, so it expects to load chunks at run time. The page's CSP names no origin the \
            chunks could come from and the scheme handler serves only the four fixed names, so every \
            diagram would silently fail to render. Pin the newest version that still ships one file.
            """)
        XCTAssertTrue(source.contains("globalThis[\"mermaid\"]"), """
            Resources/MarkdownPreview/\(MarkdownPreviewPage.diagramScriptFileName) no longer ends by \
            assigning the `mermaid` global, so `preview.js` would find nothing to render diagrams \
            with. The bundled build must be the one that defines a global, not a module.
            """)
    }

    /// The same property, stated for the highlighter: it must define the global
    /// `preview.js` reaches for. Cheap, and it is the one thing a wrong file
    /// (the ES module build, say — same name, same project, same digest
    /// discipline) would fail while passing everything above once repinned.
    func testTheHighlighterDefinesItsGlobal() throws {
        let source = try text(forAsset: MarkdownPreviewPage.highlightScriptFileName)
        XCTAssertTrue(source.contains("var hljs="), """
            Resources/MarkdownPreview/\(MarkdownPreviewPage.highlightScriptFileName) does not define \
            the `hljs` global `preview.js` calls through — this looks like the module build rather \
            than the browser one.
            """)
    }

    // MARK: - Reading the repository

    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // PisakaCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // <root>

    private static let assetDirectory = repositoryRoot.appendingPathComponent("Resources/MarkdownPreview")

    private func data(forAsset name: String) throws -> Data {
        try Data(contentsOf: Self.assetDirectory.appendingPathComponent(name))
    }

    /// The bundles are minified UTF-8 JavaScript; read as text so a marker can be
    /// searched for.
    private func text(forAsset name: String) throws -> String {
        try String(contentsOf: Self.assetDirectory.appendingPathComponent(name), encoding: .utf8)
    }

    private func vendoredDoc() throws -> String {
        try text(forAsset: Self.vendoredDocFileName)
    }
}
