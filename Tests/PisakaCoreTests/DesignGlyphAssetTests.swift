import XCTest
@testable import PisakaCore

/// The "these glyphs are the ones the design exported" guard.
///
/// The design's glyphs ship as template vector imagesets in the app's asset
/// catalog, `Sources/Pisaka/Assets.xcassets/Glyphs/`, and are loaded by string
/// name — the catalog generates no asset symbols — so nothing in the build
/// relates a `DesignGlyph` case to an imageset. A case without its asset draws
/// nothing at run time, silently; an asset re-exported or hand-edited ships bytes
/// nobody recorded; an imageset that lost its template intent draws black in
/// dark mode; one that lost its preserved vector data blurs at every interface
/// scale above 1.0. All four are green builds.
///
/// So this suite reads the catalog through `#filePath`, with Foundation and
/// Core's own `SHA256` only, and pins:
///
///  * the set of imagesets equals `DesignGlyph.allCases`' raw values — set
///    equality, both directions;
///  * each PDF's sha256 prefix equals `pinnedPrefixes` below, which is the
///    export's `MANIFEST.txt` transcribed — and the record's glyph table in
///    `Resources/DesignGlyphs/VENDORED.md` states the same prefixes, so the
///    record cannot drift from the bytes either;
///  * each imageset's `Contents.json` names its one PDF and carries
///    `"template-rendering-intent": "template"` and
///    `"preserves-vector-representation": true`;
///  * `project.yml` keeps asset symbols off: exactly one active line reads
///    `ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOLS: NO`, and no active line sets
///    that key or `ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS`
///    to anything else. `ChromeThemeSourceGatingTests`' glyph-load rule reads
///    string-named loads only, so a generated accessor would load a glyph past
///    it unseen; this pin is what that rule relies on.
final class DesignGlyphAssetTests: XCTestCase {

    /// The export manifest's sha256 prefixes (the first sixteen hex digits) for
    /// the twenty-four shipped glyphs, keyed by asset name.
    private static let pinnedPrefixes: [String: String] = [
        "package": "9af0fd7e48d454dd",
        "git-branch": "e97db149acea601c",
        "chevron-down": "dcfc02712d3dc7c1",
        "chevron-right": "e2e0632f1546236b",
        "git-pull-request": "e041f1b4ade4197b",
        "check": "19dd2cb3bd997dd5",
        "terminal": "eaf8334dc2314447",
        "file-warning": "ee8267b3b8dfdff0",
        "git-compare": "c12e53cfccba2544",
        "list-checks": "65983fbf38e0ecf9",
        "search": "af5946f6cc73b081",
        "git-pull-request-arrow": "ce4cfcefde81e484",
        "folder": "c910b4a14dc215bd",
        "folder-open": "bcfb7e66403110fa",
        "file-code": "fceaf43b42b4e8a7",
        "file-text": "97843a4f65451c00",
        "database": "51310c236bbf44f3",
        "x": "4acf054fb35ee278",
        "user-round": "99e687bb2776220c",
        "undo-2": "8b51ee486f7d8d75",
        "refresh-cw": "310ac9510740d9ec",
        "case-sensitive": "317b3d293df0264b",
        "whole-word": "690693f0f9dd12b9",
        "regex": "c0fd98edaa9f0bd9",
    ]

    func testTheImagesetsAreExactlyTheGlyphCases() throws {
        XCTAssertEqual(try imagesetNames(), Set(DesignGlyph.allCases.map(\.assetName)), """
            the glyph folder's imagesets must be exactly DesignGlyph's cases: a case without an \
            imageset draws nothing at run time, and an imageset without a case is a glyph no \
            surface can name.
            """)
        XCTAssertEqual(Set(Self.pinnedPrefixes.keys), Set(DesignGlyph.allCases.map(\.assetName)),
                       "pinnedPrefixes must cover exactly DesignGlyph's cases")
    }

    func testEveryPDFMatchesItsManifestPrefix() throws {
        for glyph in DesignGlyph.allCases {
            let data = try Data(contentsOf: Self.glyphFolder
                .appendingPathComponent("\(glyph.assetName).imageset/\(glyph.assetName).pdf"))
            let digest = SHA256.hexadecimalDigest(of: data)
            XCTAssertEqual(String(digest.prefix(16)), Self.pinnedPrefixes[glyph.assetName], """
                \(glyph.assetName).pdf is not the byte-for-byte copy the export's manifest lists. \
                Re-copy it from the export, or follow the update procedure in \
                Resources/DesignGlyphs/VENDORED.md if the export itself moved.
                """)
        }
    }

    func testEveryImagesetIsATemplateVector() throws {
        for glyph in DesignGlyph.allCases {
            let url = Self.glyphFolder
                .appendingPathComponent("\(glyph.assetName).imageset/Contents.json")
            let object = try JSONSerialization.jsonObject(with: try Data(contentsOf: url))
            let root = try XCTUnwrap(object as? [String: Any])
            let properties = try XCTUnwrap(root["properties"] as? [String: Any],
                                           "\(glyph.assetName) has no properties block")
            XCTAssertEqual(properties["template-rendering-intent"] as? String, "template", """
                \(glyph.assetName) must be a template image, or the drawing site's tint is ignored \
                and the glyph draws in the PDF's own colour.
                """)
            XCTAssertEqual(properties["preserves-vector-representation"] as? Bool, true, """
                \(glyph.assetName) must preserve its vector data, or it is rasterised at its 1x \
                size and blurs at every interface scale above 1.0.
                """)
            let images = try XCTUnwrap(root["images"] as? [[String: Any]])
            XCTAssertEqual(images.compactMap { $0["filename"] as? String }, ["\(glyph.assetName).pdf"],
                           "\(glyph.assetName)'s imageset must name exactly its one PDF")
        }
    }

    func testTheRecordListsTheCasesWithThePinnedPrefixes() throws {
        let rows = DesignGlyphRecord.rows(in: try String(contentsOf: Self.record, encoding: .utf8))
        XCTAssertEqual(Set(rows.map(\.name)), Set(DesignGlyph.allCases.map(\.assetName)),
                       "the record's glyph table must list exactly DesignGlyph's cases")

        let byName = Dictionary(uniqueKeysWithValues: rows.map { ($0.name, $0) })
        for glyph in DesignGlyph.allCases {
            let row = try XCTUnwrap(byName[glyph.assetName])
            XCTAssertEqual(row.prefix, Self.pinnedPrefixes[glyph.assetName], """
                the record's prefix for \(glyph.assetName) disagrees with the pinned one
                """)
        }
    }

    func testTheProjectKeepsAssetSymbolsOff() throws {
        let lines = activeYAMLLines(of: try String(contentsOf: Self.projectSpec, encoding: .utf8))
        let keys = [
            "ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOLS",
            "ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS",
        ]
        let wanted = "ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOLS: NO"
        let why = """
            the catalog must generate no asset symbols: a generated accessor is a form of glyph \
            loading the chrome theme's glyph-load rule cannot see, so a glyph loaded through one \
            would bypass DesignGlyphImage unnoticed.
            """

        XCTAssertEqual(lines.filter { $0 == wanted }.count, 1, "project.yml must set `\(wanted)` exactly once; \(why)")
        // Any key spelled `: NO` is the setting this pin wants; only another
        // value is a breach.
        let others = lines.filter { line in
            keys.contains { line.hasPrefix($0) && line != "\($0): NO" }
        }
        XCTAssertEqual(others, [], "project.yml sets an asset-symbol key to something else; \(why)")
    }

    // MARK: - Reading the repository

    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // PisakaCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // <root>

    private static let glyphFolder = repositoryRoot
        .appendingPathComponent("Sources/Pisaka/Assets.xcassets/Glyphs")

    private static let projectSpec = repositoryRoot.appendingPathComponent("project.yml")

    private static let record = repositoryRoot
        .appendingPathComponent("Resources/DesignGlyphs/VENDORED.md")

    private func imagesetNames() throws -> Set<String> {
        let names = try FileManager.default.contentsOfDirectory(atPath: Self.glyphFolder.path)
            .filter { $0.hasSuffix(".imageset") }
            .map { String($0.dropLast(".imageset".count)) }
        XCTAssertFalse(names.isEmpty, "read no imagesets out of the glyph folder")
        return Set(names)
    }
}
