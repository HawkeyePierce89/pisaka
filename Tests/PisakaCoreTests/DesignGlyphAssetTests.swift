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
///  * every row of that glyph table states a size of exactly 24: each PDF is a
///    24-unit box at the icon set's native coordinates, and the drawn size is
///    always the drawing site's, so a row naming any other size describes an
///    export that clips (the record says why);
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
    /// the twenty-four shipped glyphs, keyed by asset name — the export of
    /// 2026-10-05, every glyph in a 24×24 box.
    private static let pinnedPrefixes: [String: String] = [
        "package": "4e19fc2e5b0fbd39",
        "git-branch": "1738e285c5e53723",
        "chevron-down": "8b7df9eda0367c90",
        "chevron-right": "02cd1542fb22ad90",
        "git-pull-request": "37a0975caf14903b",
        "check": "496d1749c8eaf0e0",
        "terminal": "992c48725d6efb5d",
        "file-warning": "18a5d9157e3c9fa2",
        "git-compare": "2dbb6bb38742483c",
        "list-checks": "3456e4aed7e36adb",
        "search": "fca0d98489622650",
        "git-pull-request-arrow": "d9250c717269a4c4",
        "folder": "8751dad31dc2126f",
        "folder-open": "b732124cc847a62f",
        "file-code": "4f1e3ceacbac6a29",
        "file-text": "d759e0792fcfd2ba",
        "database": "94e48ce90170f619",
        "x": "9ffad35485eeffa0",
        "user-round": "5eac37ea03006449",
        "undo-2": "3086adea25b52419",
        "refresh-cw": "b1dba6c8271f47ff",
        "case-sensitive": "7e7229ec9d8a3b64",
        "whole-word": "c8f3633e9f9b8492",
        "regex": "0f392dda96cecce3",
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

    func testTheRecordListsTheCasesWithThePinnedPrefixesAtTheTwentyFourUnitBox() throws {
        let rows = DesignGlyphRecord.rows(in: try String(contentsOf: Self.record, encoding: .utf8))
        XCTAssertEqual(Set(rows.map(\.name)), Set(DesignGlyph.allCases.map(\.assetName)),
                       "the record's glyph table must list exactly DesignGlyph's cases")

        let byName = Dictionary(uniqueKeysWithValues: rows.map { ($0.name, $0) })
        for glyph in DesignGlyph.allCases {
            let row = try XCTUnwrap(byName[glyph.assetName])
            XCTAssertEqual(row.prefix, Self.pinnedPrefixes[glyph.assetName], """
                the record's prefix for \(glyph.assetName) disagrees with the pinned one
                """)
            XCTAssertEqual(row.size, 24, """
                the record's size for \(glyph.assetName) is \(row.size), not the 24-unit box every \
                glyph is exported at; see "Why every box is 24" in Resources/DesignGlyphs/VENDORED.md
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
