import XCTest
@testable import PisakaCore

/// The "these icons are the ones the pinned commit carries" guard.
///
/// The vendored file-icon set ships as full-colour vector imagesets in the app's
/// asset catalog, `Sources/Pisaka/Assets.xcassets/FileIcons/`, and is loaded by
/// string name — the catalog generates no asset symbols (`DesignGlyphAssetTests`
/// pins that) — so nothing in the build relates a `FileTypeIcon` case to an
/// imageset. A case without its asset draws nothing at run time, silently; an
/// icon re-fetched from another commit or hand-edited ships bytes nobody
/// recorded; an imageset that turned template draws as a flat tint; one that
/// lost its preserved vector data blurs at every interface scale above 1.0; a
/// folder that stopped providing a namespace makes the set's `database` collide
/// with the design glyph of that name. All five are green builds.
///
/// So this suite reads the catalog and its record through `#filePath`, with
/// Foundation and Core's own `SHA256` only, and pins:
///
///  * **three-way set equality**, both directions: the imagesets on disk,
///    `FileTypeIcon.allCases`' raw values, and the rows of the icon table in
///    `Resources/FileIcons/VENDORED.md` (read through `FileIconRecord`, the
///    reader `LicenseCoverageTests` shares) — and `pinnedFiles` below covers
///    exactly the cases too;
///  * **the bytes**: each SVG's sha256 prefix (the first sixteen hex digits) and
///    byte count equal `pinnedFiles`, the table measured off the pinned commit,
///    and the record's row states the same two values, so the record cannot
///    drift from the bytes either;
///  * **the light-variant column**: the record's rows marked `yes` are exactly
///    `pinnedLightVariants` — the icons upstream also ships a `_light` variant
///    of, none of which is taken;
///  * **the Contents files**: each imageset's `Contents.json` names exactly its
///    own SVG, `idiom: universal`, and carries
///    `"template-rendering-intent": "original"` and
///    `"preserves-vector-representation": true`; the folder's own carries
///    `"provides-namespace": true`, and the folder's name equals
///    `FileTypeIcon.catalogNamespace`, which `catalogName` is built from;
///  * **the SVG content**: every file opens, after whitespace alone, with an
///    `<svg` tag that declares a `viewBox`, and no file contains `<style`, `<script`,
///    `<text`, `<image`, `<foreignObject` or `href` (matched case-insensitively)
///    — features the system's SVG renderer drops silently, so an update cannot
///    ship an icon that draws nothing or draws half of itself. This rule's
///    subject *is* literal text, so it reads each file's **raw bytes**: there is
///    no comment or literal syntax in an SVG to strip, and stripping XML
///    attribute values would delete the very `href` it looks for.
///    `testTheContentCheckFlagsEveryDroppedFeature` proves the check refuses
///    each spelling on an in-memory fixture;
///  * **the record's header**: its `## file-icons` section states tag `v5.40.0`
///    and commit `045291ff033062a25441dd297fd51546326866f2`, the one commit
///    every pinned value above was measured off.
final class FileTypeIconAssetTests: XCTestCase {

    /// Each shipped SVG's sha256 prefix and byte count, keyed by imageset name —
    /// measured off commit `045291ff033062a25441dd297fd51546326866f2` (tag
    /// `v5.40.0`) of the vendored file-icon set.
    private static let pinnedFiles: [String: (prefix: String, bytes: Int)] = [
        "swift": ("2cf5377f88aa8cb4", 502),
        "javascript": ("00eb9422f4519015", 291),
        "typescript": ("1822f88268b452ce", 267),
        "react_ts": ("f5caa02786d9ce96", 1104),
        "json": ("649ad4f4d01cec78", 540),
        "markdown": ("42f95867350ed1f3", 161),
        "python": ("798fcd59653af34e", 773),
        "go": ("eb3b74fcad124042", 745),
        "rust": ("a58c24641e82c1ba", 526),
        "html": ("23e04ad5f1ae9cd1", 232),
        "css": ("afe20f8da21f1f2d", 674),
        "yaml": ("666b724d61cfa091", 199),
        "docker": ("3d032b712bbedea1", 1501),
        "tune": ("786079eb0fe64343", 268),
        "git": ("b0caee7c9cb4e602", 729),
        "database": ("e0679294defea907", 332),
        "editorconfig": ("199762cbea98d785", 8091),
        "console": ("c5f33efa92ce94d2", 223),
        "makefile": ("a6d8260757abc492", 943),
        "react": ("6a7fb2e8b5e168c0", 1104),
        "test-ts": ("7ec0f2314d2937a9", 615),
        "test-js": ("ce9c34d8ab5b7560", 615),
        "test-jsx": ("4fc0daa5e61deaef", 615),
        "typescript-def": ("3dd13d3bc29103ea", 274),
        "nodejs": ("365af5c7b70d11c2", 375),
        "npm": ("6bd740d3e31675d1", 132),
        "yarn": ("a9ded67f57faa176", 918),
        "pnpm": ("a3d8e5760f080d0f", 222),
        "tsconfig": ("a7bd2a966578a9ec", 411),
        "readme": ("ed41dbf841368745", 215),
        "changelog": ("30377c6875c27b98", 314),
        "contributing": ("32e5eb75555da8e5", 303),
        "license": ("4b0a147a39eade32", 225),
        "codeowners": ("a1f09959acd8a60e", 262),
        "prettier": ("b81b3661b6ec0aac", 346),
        "eslint": ("aeb3a553e20f087a", 665),
        "vitest": ("c845017d0b57201a", 318),
        "jest": ("a43bd245edf20ab6", 519),
        "robots": ("7540bc749364bd0d", 402),
        "lock": ("f28fe89b018236f9", 246),
        "c": ("4adba54251e85851", 245),
        "h": ("73fa9417071d70dc", 185),
        "cpp": ("336346afba3afb62", 325),
        "hpp": ("a030bcbf24e67aed", 232),
        "java": ("755c5b6f3fe0fb1e", 208),
        "kotlin": ("94583b191f9a7898", 517),
        "ruby": ("a7f0628476482b9f", 491),
        "php": ("5163a63d5a8d8192", 880),
        "lua": ("d69816f1ae2002f2", 576),
        "toml": ("eaeb55ba45f14a50", 180),
        "xml": ("51bfeb938c24772c", 290),
        "svg": ("120ceffcaa97658a", 1285),
        "table": ("1714898c0d538648", 268),
        "image": ("838e1953a3a2ebf5", 346),
        "font": ("092850724e8e29ff", 165),
        "pdf": ("c14c66a3914b894d", 976),
        "zip": ("dad79a45f756542d", 230),
        "sass": ("e613bd47d598c54c", 1281),
        "document": ("64f5da56de591d5f", 234),
    ]

    /// The shipped icons upstream also ships a `<name>_light.svg` variant of.
    /// Neither variant is taken: each kind draws as one image in both
    /// appearances (the record says why).
    private static let pinnedLightVariants: Set<String> = ["pnpm", "toml"]

    private static let pinnedTag = "v5.40.0"
    private static let pinnedCommit = "045291ff033062a25441dd297fd51546326866f2"

    /// The features the system's SVG renderer drops silently, lowercased.
    private static let droppedFeatures = ["<style", "<script", "<text", "<image", "<foreignobject", "href"]

    private static var caseNames: Set<String> { Set(FileTypeIcon.allCases.map(\.rawValue)) }

    // MARK: - Set equality

    func testTheImagesetsAreExactlyTheIconCases() throws {
        XCTAssertEqual(try imagesetNames(), Self.caseNames, """
            the file-icon folder's imagesets must be exactly FileTypeIcon's cases: a case without \
            an imageset draws nothing at run time, and an imageset without a case is an icon no \
            file can reach.
            """)
        XCTAssertEqual(Set(Self.pinnedFiles.keys), Self.caseNames,
                       "pinnedFiles must cover exactly FileTypeIcon's cases")
    }

    func testTheRecordListsExactlyTheIconCases() throws {
        let rows = try recordRows()
        XCTAssertEqual(Set(rows.map(\.name)), Self.caseNames,
                       "the record's icon table must list exactly FileTypeIcon's cases")
        XCTAssertEqual(rows.count, Set(rows.map(\.name)).count, "the record's icon table lists an icon twice")
    }

    // MARK: - Bytes

    func testEverySVGMatchesItsPinnedPrefixAndByteCount() throws {
        for icon in FileTypeIcon.allCases {
            let data = try Data(contentsOf: Self.svg(of: icon.rawValue))
            let pinned = try XCTUnwrap(Self.pinnedFiles[icon.rawValue], "\(icon.rawValue) has no pinned row")
            XCTAssertEqual(String(SHA256.hexadecimalDigest(of: data).prefix(16)), pinned.prefix, """
                \(icon.rawValue).svg is not the byte-for-byte copy the pinned commit carries. Re-copy \
                it from that commit, or follow "Updating by hand" in Resources/FileIcons/VENDORED.md \
                if the pin itself moved.
                """)
            XCTAssertEqual(data.count, pinned.bytes, "\(icon.rawValue).svg is \(data.count) bytes, not \(pinned.bytes)")
        }
    }

    func testTheRecordStatesThePinnedPrefixesAndByteCounts() throws {
        for row in try recordRows() {
            let pinned = try XCTUnwrap(Self.pinnedFiles[row.name], "the record lists \(row.name), which is not pinned")
            XCTAssertEqual(row.prefix, pinned.prefix, "the record's prefix for \(row.name) disagrees with the pinned one")
            XCTAssertEqual(row.bytes, pinned.bytes, "the record's byte count for \(row.name) disagrees with the pinned one")
        }
    }

    func testTheRecordsLightVariantColumnIsThePinnedSet() throws {
        let marked = Set(try recordRows().filter(\.lightVariant).map(\.name))
        XCTAssertEqual(marked, Self.pinnedLightVariants, """
            the record's light-variant column must mark exactly the icons upstream ships a `_light` \
            variant of; re-check it against the pinned commit's icons/ folder.
            """)
    }

    // MARK: - Contents files

    func testEveryImagesetIsAnOriginalVector() throws {
        for icon in FileTypeIcon.allCases {
            let url = Self.iconFolder.appendingPathComponent("\(icon.rawValue).imageset/Contents.json")
            let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: try Data(contentsOf: url))
                as? [String: Any])
            let properties = try XCTUnwrap(root["properties"] as? [String: Any],
                                           "\(icon.rawValue) has no properties block")
            XCTAssertEqual(properties["template-rendering-intent"] as? String, "original", """
                \(icon.rawValue) must render with its original intent, or it is drawn as a flat \
                tint and every kind looks the same.
                """)
            XCTAssertEqual(properties["preserves-vector-representation"] as? Bool, true, """
                \(icon.rawValue) must preserve its vector data, or it is rasterised at its 1x size \
                and blurs at every interface scale above 1.0.
                """)
            let images = try XCTUnwrap(root["images"] as? [[String: Any]])
            XCTAssertEqual(images.compactMap { $0["filename"] as? String }, ["\(icon.rawValue).svg"],
                           "\(icon.rawValue)'s imageset must name exactly its one SVG")
            XCTAssertEqual(images.compactMap { $0["idiom"] as? String }, ["universal"],
                           "\(icon.rawValue)'s one image must be universal")
        }
    }

    func testTheFolderProvidesTheCatalogNamespace() throws {
        XCTAssertEqual(Self.iconFolder.lastPathComponent, FileTypeIcon.catalogNamespace, """
            the folder's name is the namespace every catalogName is looked up under
            """)
        let url = Self.iconFolder.appendingPathComponent("Contents.json")
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: try Data(contentsOf: url))
            as? [String: Any])
        let properties = try XCTUnwrap(root["properties"] as? [String: Any], "the folder has no properties block")
        XCTAssertEqual(properties["provides-namespace"] as? Bool, true, """
            the file-icon folder must provide a namespace: without it `FileIcons/<name>` resolves \
            to nothing, and the set's `database` collides with the design glyph of the same name.
            """)
    }

    // MARK: - SVG content

    func testEverySVGIsAViewBoxedRootWithNoDroppedFeature() throws {
        for icon in FileTypeIcon.allCases {
            let failures = Self.contentFailures(of: try Data(contentsOf: Self.svg(of: icon.rawValue)))
            for failure in failures {
                XCTFail("\(icon.rawValue).svg: \(failure)")
            }
        }
    }

    func testTheContentCheckFlagsEveryDroppedFeature() {
        let clean = #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path d="M0 0h24v24H0z"/></svg>"#
        XCTAssertEqual(Self.contentFailures(of: Data(clean.utf8)), [], "the clean fixture must pass")

        let spellings = [
            "<style>path{}</style>", "<script>1</script>", "<text>a</text>", "<textPath/>",
            #"<image width="1"/>"#, "<foreignObject/>", "<FOREIGNOBJECT/>",
            ##"<use href="#a"/>"##, ##"<use xlink:href="#a"/>"##,
        ]
        for spelling in spellings {
            let svg = clean.replacingOccurrences(of: "</svg>", with: spelling + "</svg>")
            XCTAssertEqual(Self.contentFailures(of: Data(svg.utf8)).count, 1, "the check must refuse \(spelling)")
        }

        let notRoot = "<g/>" + clean
        XCTAssertFalse(Self.contentFailures(of: Data(notRoot.utf8)).isEmpty, "a file opening with another element")
        let noViewBox = clean.replacingOccurrences(of: #" viewBox="0 0 24 24""#, with: "")
        XCTAssertFalse(Self.contentFailures(of: Data(noViewBox.utf8)).isEmpty, "an <svg> without a viewBox")
        let viewBoxOutsideTheTag = noViewBox.replacingOccurrences(of: "<path", with: #"<path viewBox="0 0 1 1""#)
        XCTAssertFalse(Self.contentFailures(of: Data(viewBoxOutsideTheTag.utf8)).isEmpty,
                       "a viewBox on another element is not the root's")
    }

    // MARK: - Record header

    /// The record states the pin twice: `Tag`/`Commit`, which this suite
    /// measured the bytes off, and `Version`/`Revision`, which
    /// `LicenseCoverageTests` holds against the notice. Both pairs are pinned
    /// here, so the acknowledgement cannot name a revision the bytes did not
    /// come from.
    func testTheRecordStatesThePinnedTagAndCommit() throws {
        let section = try XCTUnwrap(MarkdownPreviewVendoredDoc.sections(
            in: try String(contentsOf: Self.record, encoding: .utf8))["file-icons"],
            "the record has no `## file-icons` section")
        XCTAssertEqual(section.value("Tag"), Self.pinnedTag)
        XCTAssertEqual(section.value("Commit"), Self.pinnedCommit)
        XCTAssertEqual(section.value("Version"), Self.pinnedTag)
        XCTAssertEqual(section.value("Revision"), Self.pinnedCommit)
    }

    // MARK: - Reading the repository

    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // PisakaCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // <root>

    private static let iconFolder = repositoryRoot
        .appendingPathComponent("Sources/Pisaka/Assets.xcassets/FileIcons")

    private static let record = repositoryRoot.appendingPathComponent("Resources/FileIcons/VENDORED.md")

    private static func svg(of name: String) -> URL {
        iconFolder.appendingPathComponent("\(name).imageset/\(name).svg")
    }

    private func imagesetNames() throws -> Set<String> {
        let names = try FileManager.default.contentsOfDirectory(atPath: Self.iconFolder.path)
            .filter { $0.hasSuffix(".imageset") }
            .map { String($0.dropLast(".imageset".count)) }
        XCTAssertFalse(names.isEmpty, "read no imagesets out of the file-icon folder")
        return Set(names)
    }

    private func recordRows() throws -> [FileIconRecord.Row] {
        let rows = FileIconRecord.rows(in: try String(contentsOf: Self.record, encoding: .utf8))
        XCTAssertFalse(rows.isEmpty, "read no rows out of the record's icon table")
        return rows
    }

    /// Every reason `data` is not an SVG the system renderer draws whole: it
    /// must open, after whitespace alone, with an `<svg` tag declaring a `viewBox`, and
    /// the raw bytes must spell none of `droppedFeatures`, case-insensitively.
    private static func contentFailures(of data: Data) -> [String] {
        let text = String(decoding: data, as: UTF8.self)
        var failures: [String] = []
        let body = text.drop { $0.isWhitespace }
        if body.hasPrefix("<svg"), let close = body.firstIndex(of: ">") {
            if !body[..<close].contains("viewBox=") {
                failures.append("its root <svg> tag declares no viewBox")
            }
        } else {
            failures.append("it does not open with an <svg tag")
        }
        let lowered = text.lowercased()
        failures += droppedFeatures.filter(lowered.contains).map { feature in
            "it contains `\(feature)`, which the system's SVG renderer drops silently"
        }
        return failures
    }
}
