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
///  * every shipped PDF *draws* inside its box, not merely declares one: exactly
///    one `/MediaBox`, equal to `[0 0 24 24]`; any `/CropBox`, `/BleedBox`,
///    `/TrimBox` or `/ArtBox` equal to it too, and no `/Rotate` other than 0 — a
///    smaller crop box clips exactly as a smaller media box does — each written
///    inline as complete tokens, since an indirect or run-on box or rotation
///    cannot be read and so fails, and every key read as PDF's tokens read it —
///    a comment is whitespace, a string's contents name no key, a `#xx`
///    name escape is the character it spells, and whitespace is PDF's six bytes,
///    not Unicode's; exactly one content stream, since a page's
///    streams share one graphics state and the reader starts each from a fresh
///    one, located through its
///    `/Length`, `/FlateDecode`, each declared exactly once among the stream
///    dictionary's own entries — a nested dictionary's keys are not its — and
///    no `/DecodeParms`, `/F`, `/FFilter` or `/FDecodeParms` among them, since a
///    predictor or an external file makes what a renderer draws differ from
///    the inflate the check reads, with a valid zlib header and an Adler-32
///    trailer that proves the inflate, the filter name and the closing
///    `endstream` each read as a complete token; and every path coordinate — the
///    `m`/`l`/`c`/`v`/`y` points and the corners of each `re` — transformed by
///    the full current matrix (`cm` concatenated, `q`/`Q` scoping it) and lying
///    within 0…24 on both axes, with no tolerance and at least one point per
///    file. This is the check the export of 2026-10-02 would have failed: its
///    boxes were the drawn extent rounded down, and the renderer clips to the
///    box, so bounding the box or the manifest's sizes alone sees nothing. The
///    exports outline strokes into fills, so a path coordinate is the ink's own
///    outline; any operator outside the small set the exports use — a stroke
///    `S`, which would need half a line width, or any text or image operator,
///    which draws without a path coordinate — fails by name, so an export that
///    changes shape fails loudly rather than passing unexamined. To prove a
///    candidate export before vendoring it, make a throwaway local edit to
///    `geometrySource(of:)` below so it returns
///    `URL(fileURLWithPath: "<export>/icons/\(name).pdf")`, run
///    `swift test --filter DesignGlyphAssetTests/testEveryShippedPDFDrawsInsideItsTwentyFourUnitBox`,
///    and revert the edit;
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

    func testEveryShippedPDFDrawsInsideItsTwentyFourUnitBox() throws {
        for glyph in DesignGlyph.allCases {
            let findings = GlyphGeometry.read(try Data(contentsOf: Self.geometrySource(of: glyph.assetName)))
            for failure in findings.failures {
                XCTFail("""
                    \(glyph.assetName).pdf: \(failure). Every glyph must be exported as a 24×24 \
                    frame wrapping the icon, never the bare icon node; see "Updating by hand" in \
                    Resources/DesignGlyphs/VENDORED.md.
                    """)
            }
        }
    }

    // MARK: - The geometry reader, on in-memory fixtures

    func testTheGeometryReaderPassesAnInBoxDrawing() throws {
        let findings = GlyphGeometry.read(try Self.fixturePDF(content: """
            1 0 0 -1 0 24 cm
            q
            0 0 0 RG 0 0 0 rg
            /G3 gs
            0 0 24 24 re
            f
            Q
            q
            .5 .5 .5 RG .5 .5 .5 rg
            /G4 gs
            2 3 m
            22 3 l
            22 21 12 21 2 21 c
            4 4 6 6 y
            5 5 7 7 v
            h
            f
            Q
            """))
        XCTAssertEqual(findings.mediaBoxes, [[0, 0, 24, 24]])
        XCTAssertEqual(findings.streams, 1)
        XCTAssertEqual(findings.boundedPoints, 13, "four corners, then 1 + 1 + 3 + 2 + 2 points")
        XCTAssertEqual(findings.outOfBox, [])
        XCTAssertEqual(findings.unknownOperators, [])
        XCTAssertEqual(findings.failures, [])
    }

    func testTheGeometryReaderRefusesAPointPastTheBox() throws {
        let findings = GlyphGeometry.read(try Self.fixturePDF(content: "1 1 m 24.5 3 l h f"))
        XCTAssertEqual(findings.outOfBox, [GlyphGeometry.Point(x: 24.5, y: 3)])
        XCTAssertEqual(findings.failures.count, 1)
    }

    func testTheGeometryReaderAppliesATranslationOnlyInsideItsSaveRestore() throws {
        let findings = GlyphGeometry.read(try Self.fixturePDF(content: """
            q 1 0 0 1 2 0 cm 23 1 m Q
            23 1 l h f
            """))
        XCTAssertEqual(findings.boundedPoints, 2)
        XCTAssertEqual(findings.outOfBox, [GlyphGeometry.Point(x: 25, y: 1)],
                       "the point inside q … Q is translated out of the box; the one after Q is judged untranslated")
    }

    func testTheGeometryReaderRefusesAnyOtherMediaBox() throws {
        let findings = GlyphGeometry.read(try Self.fixturePDF(mediaBox: "[0 0 12 12]", content: "1 1 m 11 11 l h f"))
        XCTAssertEqual(findings.mediaBoxes, [[0, 0, 12, 12]])
        XCTAssertEqual(findings.outOfBox, [])
        XCTAssertEqual(findings.failures.count, 1)
    }

    func testTheGeometryReaderConcatenatesNestedTransformsInPDFOrder() throws {
        // The scale applies first, then the translation: (30, 1) → (15, 0.5) →
        // (25, 0.5), outside. The reverse order would land at (20, 0.5), inside.
        let findings = GlyphGeometry.read(try Self.fixturePDF(content: """
            1 0 0 1 10 0 cm 0.5 0 0 0.5 0 0 cm 30 1 m h f
            """))
        XCTAssertEqual(findings.outOfBox, [GlyphGeometry.Point(x: 25, y: 0.5)])
    }

    func testTheGeometryReaderRefusesASmallerCropBoxOrARotation() throws {
        let cropped = GlyphGeometry.read(try Self.fixturePDF(pageEntries: " /CropBox [0 0 12 12]",
                                                             content: "1 1 m 11 11 l h f"))
        XCTAssertEqual(cropped.otherBoxes, [[0, 0, 12, 12]])
        XCTAssertEqual(cropped.failures.count, 1)

        let wholeCrop = GlyphGeometry.read(try Self.fixturePDF(pageEntries: " /CropBox [0 0 24 24] /Rotate 0",
                                                               content: "1 1 m 11 11 l h f"))
        XCTAssertEqual(wholeCrop.failures, [])

        let rotated = GlyphGeometry.read(try Self.fixturePDF(pageEntries: " /Rotate 90", content: "1 1 m 11 11 l h f"))
        XCTAssertEqual(rotated.rotations, [90])
        XCTAssertEqual(rotated.failures.count, 1)
    }

    func testTheGeometryReaderRefusesAPageBoxOrRotationItCannotRead() throws {
        let cases: [(String, String)] = [
            (" /CropBox 8 0 R", "a `/CropBox` is not an inline array of four numbers, so the clip it sets cannot be read"),
            (" /TrimBox [0 0 24 24 R]",
             "a `/TrimBox` is not an inline array of four numbers, so the clip it sets cannot be read"),
            (" /Rotate 0 0 R", "a `/Rotate` is not a direct integer, so the rotation it sets cannot be read"),
            (" /Rotate 0.5", "a `/Rotate` is not a direct integer, so the rotation it sets cannot be read"),
            (" /Rotate 0+90", "a `/Rotate` is not a direct integer, so the rotation it sets cannot be read"),
            (" /Rotate 0,5", "a `/Rotate` is not a direct integer, so the rotation it sets cannot be read"),
            // A vertical tab is a regular character in PDF, not whitespace.
            (" /Rotate 0\u{0B}5", "a `/Rotate` is not a direct integer, so the rotation it sets cannot be read"),
            (" /TrimBox [0 0 24\u{0B}24]",
             "a `/TrimBox` is not an inline array of four numbers, so the clip it sets cannot be read"),
            (" /TrimBox [0 0 0x18 24]",
             "a `/TrimBox` is not an inline array of four numbers, so the clip it sets cannot be read"),
        ]
        for (entries, expected) in cases {
            let findings = GlyphGeometry.read(try Self.fixturePDF(pageEntries: entries, content: "1 1 m 11 11 l h f"))
            XCTAssertEqual(findings.malformed, [expected], entries)
            XCTAssertTrue(findings.failures.contains(expected), entries)
        }

        let indirectMedia = GlyphGeometry.read(try Self.fixturePDF(mediaBox: "8 0 R", content: "1 1 m 11 11 l h f"))
        XCTAssertEqual(indirectMedia.mediaBoxes, [])
        XCTAssertTrue(indirectMedia.malformed.contains(
            "a `/MediaBox` is not an inline array of four numbers, so the clip it sets cannot be read"))
    }

    func testTheGeometryReaderReadsKeysAsPDFTokensDo() throws {
        let rotated = GlyphGeometry.read(try Self.fixturePDF(pageEntries: " /Rot#61te 90", content: "1 1 m 11 11 l h f"))
        XCTAssertEqual(rotated.rotations, [90])
        XCTAssertTrue(rotated.failures.contains("it rotates its page by 90.0"))

        let cropped = GlyphGeometry.read(try Self.fixturePDF(pageEntries: " /CropB#6Fx [0 0 12 12]",
                                                             content: "1 1 m 11 11 l h f"))
        XCTAssertEqual(cropped.otherBoxes, [[0, 0, 12, 12]])
        XCTAssertEqual(cropped.failures.count, 1)

        // A name runs to the next delimiter, so `/Rotate.foo` and
        // `/MediaBox.foo` are other keys, not run-on declarations of these.
        let runOn = GlyphGeometry.read(try Self.fixturePDF(pageEntries: " /Rotate.foo 90 /MediaBox.foo [0 0 12 12]",
                                                           content: "1 1 m 11 11 l h f"))
        XCTAssertEqual(runOn.rotations, [])
        XCTAssertEqual(runOn.mediaBoxes, [[0, 0, 24, 24]])
        XCTAssertEqual(runOn.failures, [])

        let commented = GlyphGeometry.read(try Self.fixturePDF(pageEntries: " /Rotate 0%comment\n0 R",
                                                               content: "1 1 m 11 11 l h f"))
        XCTAssertEqual(commented.malformed,
                       ["a `/Rotate` is not a direct integer, so the rotation it sets cannot be read"])

        // A string's contents name no key, however much they look like one.
        let quoted = GlyphGeometry.read(try Self.fixturePDF(pageEntries: #" /Note (a \) (/Rotate 90) b)"#,
                                                            content: "1 1 m 11 11 l h f"))
        XCTAssertEqual(quoted.rotations, [])
        XCTAssertEqual(quoted.failures, [])

        // A string that never closes swallows every key and keyword after it,
        // the content stream's `stream` included.
        let unclosed = GlyphGeometry.read(try Self.fixturePDF(pageEntries: " /Note (unterminated /Rotate 90",
                                                              content: "1 1 m 11 11 l h f"))
        XCTAssertEqual(unclosed.streams, 0)
        XCTAssertEqual(unclosed.malformed,
                       ["a literal string never closes, so the structure after it cannot be read"])
        XCTAssertTrue(unclosed.failures.contains(
            "a literal string never closes, so the structure after it cannot be read"))
    }

    func testTheGeometryReaderFindsStreamsAndObjectsAsPDFTokensDo() throws {
        // `stream` in a string, a comment or a name opens no stream.
        let pageEntries = " /Note (stream) /stream 0 %stream\n"
        let quoted = GlyphGeometry.read(try Self.fixturePDF(pageEntries: pageEntries, content: "1 1 m 11 11 l h f"))
        XCTAssertEqual(quoted.streams, 1)
        XCTAssertEqual(quoted.failures, [])

        // `obj` in a string does not open the stream's dictionary after its `/Length`.
        let named = GlyphGeometry.read(try Self.fixturePDF(content: "1 1 m 11 11 l h f",
                                                           length: { "\($0) /Note (obj)" }))
        XCTAssertEqual(named.streams, 1)
        XCTAssertEqual(named.failures, [])

        // Keys inside a nested dictionary are that dictionary's, not the stream's.
        let nested = GlyphGeometry.read(try Self.fixturePDF(
            content: "1 1 m 11 11 l h f",
            filter: "/FlateDecode /Extra << /Filter /ASCIIHexDecode /Length 1 >> /ID <2F4C> /W [1 2]"))
        XCTAssertEqual(nested.streams, 1)
        XCTAssertEqual(nested.failures, [])

        // A name in value position is that entry's value, never a key.
        let valued = GlyphGeometry.read(try Self.fixturePDF(content: "1 1 m 11 11 l h f",
                                                            filter: "/FlateDecode /Alias /Filter /Other /Length"))
        XCTAssertEqual(valued.streams, 1)
        XCTAssertEqual(valued.failures, [])
    }

    func testTheGeometryReaderRefusesMoreThanOneContentStream() throws {
        // Read as one page, the first stream's translation carries into the
        // second and lands (23, 1) at (33, 1); read stream by stream, both look
        // inside. The check reads stream by stream, so it refuses the shape.
        let findings = GlyphGeometry.read(try Self.fixturePDF(content: "1 0 0 1 10 0 cm 1 1 m h f",
                                                              moreContent: ["23 1 m h f"]))
        XCTAssertEqual(findings.streams, 2)
        XCTAssertEqual(findings.outOfBox, [])
        XCTAssertEqual(findings.failures.count, 1)
    }

    func testTheGeometryReaderNamesEachWayAStreamIsMalformed() throws {
        let content = "1 1 m 2 2 l h f"
        let cases: [(String, Data)] = [
            ("a content stream is not `/FlateDecode`",
             try Self.fixturePDF(content: content, filter: "/ASCIIHexDecode")),
            ("a content stream is not `/FlateDecode`",
             try Self.fixturePDF(content: content, filter: "/FlateDecode.foo")),
            ("a content stream is not `/FlateDecode`",
             try Self.fixturePDF(content: content, filter: "/FlateDecode\u{0B}.foo")),
            ("a content stream is not `/FlateDecode`",
             try Self.fixturePDF(content: content, filter: "/ASCIIHexDecode /Metadata << /Filter /FlateDecode >>")),
            ("a content stream is not `/FlateDecode`",
             try Self.fixturePDF(content: content, filter: "/FlateDecode /Filter /ASCIIHexDecode")),
            ("a content stream is not `/FlateDecode`",
             try Self.fixturePDF(content: content, filter: "[/FlateDecode]")),
            ("a content stream is not `/FlateDecode`",
             try Self.fixturePDF(content: content, filterEntry: "/Alias /Filter /FlateDecode null")),
            ("a content stream carries `/DecodeParms` or an external-file key, so the bytes a renderer draws are "
                + "not the inflate alone",
             try Self.fixturePDF(content: content, filter: "/FlateDecode /DecodeParms << /Predictor 12 /Columns 4 >>")),
            ("a content stream carries `/DecodeParms` or an external-file key, so the bytes a renderer draws are "
                + "not the inflate alone",
             try Self.fixturePDF(content: content, filter: "/FlateDecode /DecodeParms null")),
            ("a content stream carries `/DecodeParms` or an external-file key, so the bytes a renderer draws are "
                + "not the inflate alone",
             try Self.fixturePDF(content: content, filter: "/FlateDecode /F (glyph.bin)")),
            ("a content stream carries `/DecodeParms` or an external-file key, so the bytes a renderer draws are "
                + "not the inflate alone",
             try Self.fixturePDF(content: content, filter: "/FlateDecode /FFilter /ASCIIHexDecode")),
            ("a content stream carries `/DecodeParms` or an external-file key, so the bytes a renderer draws are "
                + "not the inflate alone",
             try Self.fixturePDF(content: content, filter: "/FlateDecode /FDecodeParms << >>")),
            ("a content stream's dictionary is not key–value pairs, so its entries cannot be read",
             try Self.fixturePDF(content: content, filter: "/FlateDecode /Alias")),
            ("a content stream's dictionary does not close, so its entries cannot be read",
             try Self.fixturePDF(content: content, filter: "/FlateDecode /DecodeParms [")),
            ("a content stream has no direct `/Length` inside the file",
             try Self.fixturePDF(content: content, length: { "\($0) 0 R" })),
            ("a content stream has no direct `/Length` inside the file",
             try Self.fixturePDF(content: content, length: { "\($0).0" })),
            ("a content stream has no direct `/Length` inside the file",
             try Self.fixturePDF(content: content, length: { "\($0)+0" })),
            ("a content stream has no direct `/Length` inside the file",
             try Self.fixturePDF(content: content, length: { "\($0)%comment\n0 R" })),
            ("a content stream has no direct `/Length` inside the file",
             try Self.fixturePDF(content: content, length: { "8 0 R /DecodeParms << /Length \($0) >>" })),
            ("a content stream has no direct `/Length` inside the file",
             try Self.fixturePDF(content: content, length: { "\($0) /Length \($0)" })),
            ("a content stream's `/Length` does not end at `endstream`",
             try Self.fixturePDF(content: content, length: { "\($0 + 3)" })),
            ("a content stream's `/Length` does not end at `endstream`",
             try Self.fixturePDF(content: content, endstream: "endstreaming")),
            ("a content stream's `/Length` does not end at `endstream`",
             try Self.fixturePDF(content: content, endstream: "endstreamendobj")),
            ("a content stream does not open with a valid zlib header",
             try Self.fixturePDF(content: content, zlibHeader: [0x78, 0x9D])),
            ("a content stream's Adler-32 trailer disagrees with its inflated bytes",
             try Self.fixturePDF(content: content, adler32: 1)),
            ("`l` has 1 operands, not 2", try Self.fixturePDF(content: "1 1 m 2 l h f")),
            ("`cm` has 4 operands, not 6", try Self.fixturePDF(content: "1 0 0 1 cm 1 1 m h f")),
            ("`re` has 3 operands, not 4", try Self.fixturePDF(content: "1 1 m 0 0 24 re f")),
        ]
        for (expected, pdf) in cases {
            let findings = GlyphGeometry.read(pdf)
            XCTAssertEqual(findings.malformed, [expected])
            XCTAssertTrue(findings.failures.contains(expected), expected)
        }
    }

    func testTheGeometryReaderRefusesAnUnknownOperator() throws {
        let findings = GlyphGeometry.read(try Self.fixturePDF(content: "1 1 m 2 2 l S"))
        XCTAssertEqual(findings.unknownOperators, ["S"])
        XCTAssertEqual(findings.failures.count, 1)
    }

    func testTheGeometryReaderRefusesAFileWithoutAContentStreamOrWithAnUnbalancedRestore() throws {
        let streamless = GlyphGeometry.read(Data("%PDF-1.4\n1 0 obj\n<</MediaBox [0 0 24 24]>>\nendobj\n".utf8))
        XCTAssertEqual(streamless.streams, 0)
        XCTAssertFalse(streamless.failures.isEmpty)

        let unbalanced = GlyphGeometry.read(try Self.fixturePDF(content: "q 1 1 m Q Q"))
        XCTAssertEqual(unbalanced.malformed.count, 1)
        XCTAssertFalse(unbalanced.failures.isEmpty)
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

    /// Where the geometry check reads `name`'s PDF: the shipped imageset. The
    /// one line a throwaway edit points at a candidate export (doc comment above).
    private static func geometrySource(of name: String) -> URL {
        glyphFolder.appendingPathComponent("\(name).imageset/\(name).pdf")
    }

    private func imagesetNames() throws -> Set<String> {
        let names = try FileManager.default.contentsOfDirectory(atPath: Self.glyphFolder.path)
            .filter { $0.hasSuffix(".imageset") }
            .map { String($0.dropLast(".imageset".count)) }
        XCTAssertFalse(names.isEmpty, "read no imagesets out of the glyph folder")
        return Set(names)
    }

    /// A minimal PDF-shaped fixture: one object carrying the media box entry's
    /// value and `pageEntries`, both verbatim, then one stream object per element of
    /// `content` + `moreContent`, each in zlib framing — the `zlibHeader`, the
    /// raw deflate Foundation produces, a big-endian Adler-32 (`adler32` when
    /// given, the true one otherwise). `filter` and `length` replace each stream
    /// dictionary's entries when given — `filterEntry` the whole `/Filter` entry,
    /// key included — and `endstream` the keyword closing each stream.
    private static func fixturePDF(
        mediaBox: String = "[0 0 24 24]", pageEntries: String = "", content: String, moreContent: [String] = [],
        filter: String = "/FlateDecode", filterEntry: String? = nil, length: ((Int) -> String)? = nil,
        zlibHeader: [UInt8] = [0x78, 0x9C], adler32: UInt32? = nil, endstream: String = "endstream"
    ) throws -> Data {
        var pdf = Data("""
            %PDF-1.4
            1 0 obj
            <</Type /Page /MediaBox \(mediaBox)\(pageEntries)>>
            endobj

            """.utf8)
        for (index, text) in ([content] + moreContent).enumerated() {
            let body = Data(text.utf8)
            var stream = Data(zlibHeader)
            stream.append(try (body as NSData).compressed(using: .zlib) as Data)
            withUnsafeBytes(of: (adler32 ?? GlyphGeometry.adler32(body)).bigEndian) { stream.append(contentsOf: $0) }
            pdf.append(Data("""
                \(index + 2) 0 obj
                <<\(filterEntry ?? "/Filter " + filter)
                /Length \(length?(stream.count) ?? String(stream.count))>> stream

                """.utf8))
            pdf.append(stream)
            pdf.append(Data("\n\(endstream)\nendobj\n".utf8))
        }
        pdf.append(Data("%%EOF\n".utf8))
        return pdf
    }

    // MARK: - Reading a glyph's geometry

    /// Bounds what a glyph PDF draws, with Foundation only: the media boxes it
    /// declares, and every path coordinate of every content stream, transformed
    /// by the current matrix. It returns what it found rather than asserting,
    /// so the shipped files and the fixtures are judged by one `failures` list.
    private enum GlyphGeometry {

        struct Point: Equatable {
            let x: Double
            let y: Double
        }

        struct Findings {
            var mediaBoxes: [[Double]] = []
            /// The crop, bleed, trim and art boxes, which default to the media box.
            var otherBoxes: [[Double]] = []
            var rotations: [Double] = []
            var streams = 0
            var boundedPoints = 0
            var outOfBox: [Point] = []
            var unknownOperators: [String] = []
            var malformed: [String] = []

            /// Every reason the file is not a glyph drawn whole in a 24×24 box.
            var failures: [String] {
                var failures: [String] = []
                if mediaBoxes != [[0, 0, box, box]] {
                    failures.append("its media boxes are \(mediaBoxes), not exactly one [0 0 24 24]")
                }
                failures += otherBoxes.filter { $0 != [0, 0, box, box] }.map { other in
                    "it declares a page box \(other), which clips as a media box does, not [0 0 24 24]"
                }
                failures += rotations.filter { $0 != 0 }.map { "it rotates its page by \($0)" }
                if streams == 0 { failures.append("it has no content stream") }
                if streams > 1 {
                    failures.append("it has \(streams) content streams, not exactly one: a page's streams share "
                        + "one graphics state, and this check reads each stream from a fresh one")
                }
                failures += malformed
                failures += unknownOperators.map { operatorName in
                    "its content uses the operator `\(operatorName)`, which this check does not read, so what it "
                        + "draws cannot be bounded"
                }
                failures += outOfBox.map { point in
                    "the path coordinate (\(point.x), \(point.y)) lies outside the 24×24 box [0 0 24 24]"
                }
                if streams > 0 && boundedPoints == 0 {
                    failures.append("it bounds no path coordinate, so the check would pass vacuously")
                }
                return failures
            }
        }

        static let box = 24.0

        /// PDF's whitespace — NUL, tab, line feed, form feed, carriage return
        /// and space, nothing else — as a regex class. `\s` is not it: a vertical
        /// tab is Unicode whitespace but a PDF regular character.
        private static let space = #"[\x00\t\n\f\r ]"#

        /// Where a PDF token may end: whitespace, a PDF delimiter, or the end of
        /// the input. An integer read up to anything else — `0.5`, `0+90`, `0,5`
        /// — is a prefix of some other token, so it is not read at all.
        private static let tokenEnd = #"(?=[\x00\t\n\f\r ()<>\[\]{}/%]|\z)"#

        /// Whether a token is a reference's tail — ` <generation> R` — so the
        /// integer before it is an object number, not a direct value.
        private static let referenceTail = "(?!" + space + "+[0-9]+" + space + "+R" + tokenEnd + ")"

        static func read(_ pdf: Data) -> Findings {
            var findings = Findings()
            let bytes = [UInt8](pdf)
            var structure: [UInt8] = []
            var cursor = 0
            while let keyword = Self.keyword("stream", in: bytes, from: cursor) {
                structure += bytes[cursor..<keyword]
                guard let end = readStream(bytes, keyword: keyword, from: cursor, into: &findings) else {
                    cursor = bytes.count
                    break
                }
                cursor = end
            }
            structure += bytes[min(cursor, bytes.count)...]
            let text = lexical(structure[...], into: &findings)
            findings.mediaBoxes = boxes(named: "MediaBox", in: text, into: &findings)
            findings.otherBoxes = ["CropBox", "BleedBox", "TrimBox", "ArtBox"].flatMap { name in
                boxes(named: name, in: text, into: &findings)
            }
            findings.rotations = matches("/Rotate" + space + "+([-+]?[0-9]+)" + tokenEnd + referenceTail, in: text)
                .compactMap { Double($0) }
            if declarations(of: "Rotate", in: text) != findings.rotations.count {
                findings.malformed.append("a `/Rotate` is not a direct integer, so the rotation it sets cannot be read")
            }
            return findings
        }

        /// Reads the stream whose `stream` keyword is at `keyword`, interpreting
        /// it into `findings`; returns the offset past its `endstream`, or `nil`
        /// when the file is too malformed to go on.
        private static func readStream(_ bytes: [UInt8], keyword: Int, from start: Int,
                                       into findings: inout Findings) -> Int? {
            var dataStart = keyword + "stream".utf8.count
            if bytes[dataStart...].starts(with: [0x0D, 0x0A]) {
                dataStart += 2
            } else if bytes[dataStart...].starts(with: [0x0A]) {
                dataStart += 1
            } else {
                findings.malformed.append("a `stream` keyword is not followed by an end-of-line")
                return nil
            }
            let header = Self.keyword("obj", in: bytes, from: start, before: keyword, last: true) ?? start
            guard let dictionary = outerDictionary(lexical(bytes[header..<keyword], into: &findings)) else {
                findings.malformed.append("a content stream's dictionary does not close, so its entries cannot be read")
                return nil
            }
            guard let entries = entries(of: dictionary) else {
                findings.malformed.append("a content stream's dictionary is not key–value pairs, so its entries "
                    + "cannot be read")
                return nil
            }
            /// The values of every entry keyed `/<name>` — a name in value position is not a key.
            func values(_ name: String) -> [String] { entries.filter { $0.key == "/" + name }.map(\.value) }
            let lengths = values("Length")
            guard lengths.count == 1, lengths[0].utf8.allSatisfy({ (48...57).contains($0) }),
                  let length = Int(lengths[0]), dataStart + length <= bytes.count else {
                findings.malformed.append("a content stream has no direct `/Length` inside the file")
                return nil
            }
            var after = dataStart + length
            while after < bytes.count, [0x0A, 0x0D, 0x20].contains(bytes[after]) { after += 1 }
            let close = after + "endstream".utf8.count
            guard bytes[after...].starts(with: Array("endstream".utf8)),
                  close == bytes.count || !isRegular(bytes[close]) else {
                findings.malformed.append("a content stream's `/Length` does not end at `endstream`")
                return nil
            }
            findings.streams += 1
            if values("Filter") != ["/FlateDecode"] {
                findings.malformed.append("a content stream is not `/FlateDecode`")
            } else if ["DecodeParms", "F", "FFilter", "FDecodeParms"].contains(where: { !values($0).isEmpty }) {
                findings.malformed.append("a content stream carries `/DecodeParms` or an external-file key, so the "
                    + "bytes a renderer draws are not the inflate alone")
            } else if let text = inflate(Array(bytes[dataStart..<(dataStart + length)]), into: &findings) {
                interpret(text, into: &findings)
            }
            return close
        }

        /// Strips the zlib framing, inflates the raw deflate between, and
        /// proves the result against the Adler-32 trailer.
        private static func inflate(_ stream: [UInt8], into findings: inout Findings) -> String? {
            guard stream.count >= 6, stream[0] == 0x78, (Int(stream[0]) * 256 + Int(stream[1])) % 31 == 0,
                  stream[1] & 0x20 == 0 else {
                findings.malformed.append("a content stream does not open with a valid zlib header")
                return nil
            }
            let deflated = Data(stream[2..<(stream.count - 4)])
            guard let inflated = try? (deflated as NSData).decompressed(using: .zlib) as Data else {
                findings.malformed.append("a content stream does not inflate")
                return nil
            }
            let trailer = stream.suffix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            guard adler32(inflated) == trailer else {
                findings.malformed.append("a content stream's Adler-32 trailer disagrees with its inflated bytes")
                return nil
            }
            return String(decoding: inflated, as: Unicode.ASCII.self)
        }

        /// Interprets one content stream: every operator the exports use, by
        /// name; anything else is recorded as unknown.
        private static func interpret(_ text: String, into findings: inout Findings) {
            let whitespace = CharacterSet(charactersIn: " \t\n\r\u{0C}\u{00}")
            let numeric = CharacterSet(charactersIn: "0123456789.+-")
            var matrix = Matrix.identity
            var saved: [Matrix] = []
            var numbers: [Double] = []
            var names = 0
            for token in text.components(separatedBy: whitespace) where !token.isEmpty {
                if token.unicodeScalars.allSatisfy(numeric.contains), let number = Double(token) {
                    numbers.append(number)
                    continue
                }
                if token.hasPrefix("/") {
                    names += 1
                    continue
                }
                defer { numbers = []; names = 0 }
                /// Whether the operator took exactly `count` numbers; records it when not.
                func takes(_ count: Int) -> Bool {
                    guard numbers.count == count, names == 0 else {
                        findings.malformed.append("`\(token)` has \(numbers.count) operands, not \(count)")
                        return false
                    }
                    return true
                }
                func boundPoints(_ count: Int) {
                    guard takes(count * 2) else { return }
                    for index in stride(from: 0, to: numbers.count, by: 2) {
                        bound(numbers[index], numbers[index + 1], by: matrix, into: &findings)
                    }
                }
                switch token {
                case "m", "l":
                    boundPoints(1)
                case "c":
                    boundPoints(3)
                case "v", "y":
                    boundPoints(2)
                case "re":
                    guard takes(4) else { continue }
                    let (x, y, width, height) = (numbers[0], numbers[1], numbers[2], numbers[3])
                    for (cornerX, cornerY) in [(x, y), (x + width, y), (x, y + height), (x + width, y + height)] {
                        bound(cornerX, cornerY, by: matrix, into: &findings)
                    }
                case "cm":
                    if takes(6) { matrix = Matrix(numbers).concatenated(onto: matrix) }
                case "q":
                    saved.append(matrix)
                case "Q":
                    if let restored = saved.popLast() {
                        matrix = restored
                    } else {
                        findings.malformed.append("a `Q` restores a state no `q` saved")
                    }
                case "h", "f", "gs", "rg", "RG":
                    break
                default:
                    findings.unknownOperators.append(token)
                }
            }
        }

        private static func bound(_ x: Double, _ y: Double, by matrix: Matrix, into findings: inout Findings) {
            let point = matrix.apply(x, y)
            findings.boundedPoints += 1
            if !(0...box).contains(point.x) || !(0...box).contains(point.y) {
                findings.outOfBox.append(point)
            }
        }

        /// A PDF matrix `[a b c d e f]`, mapping `(x, y)` to
        /// `(a·x + c·y + e, b·x + d·y + f)`.
        private struct Matrix {
            var a, b, c, d, e, f: Double

            static let identity = Matrix([1, 0, 0, 1, 0, 0])

            init(_ values: [Double]) {
                (a, b, c, d, e, f) = (values[0], values[1], values[2], values[3], values[4], values[5])
            }

            func apply(_ x: Double, _ y: Double) -> Point {
                Point(x: a * x + c * y + e, y: b * x + d * y + f)
            }

            /// `cm`'s rule: this matrix applies first, then `current`.
            func concatenated(onto current: Matrix) -> Matrix {
                Matrix([
                    a * current.a + b * current.c,
                    a * current.b + b * current.d,
                    c * current.a + d * current.c,
                    c * current.b + d * current.d,
                    e * current.a + f * current.c + current.e,
                    e * current.b + f * current.d + current.f,
                ])
            }
        }

        static func adler32(_ data: Data) -> UInt32 {
            var low: UInt32 = 1
            var high: UInt32 = 0
            for byte in data {
                low = (low + UInt32(byte)) % 65_521
                high = (high + low) % 65_521
            }
            return high << 16 | low
        }

        /// Every `/<name>` box that is an inline array of four numbers. Any other
        /// declaration — an indirect reference, or an array holding one — is
        /// recorded as malformed, since the clip it sets cannot be read.
        private static func boxes(named name: String, in structure: String,
                                  into findings: inout Findings) -> [[Double]] {
            let inline = matches("/" + name + space + #"*\[([^\]]*)\]"#, in: structure).map { inside in
                inside.utf8.split(whereSeparator: isSpace).map { number(String(decoding: $0, as: UTF8.self)) }
            }
            let read = inline.filter { $0.count == 4 && !$0.contains(nil) }.map { $0.compactMap { $0 } }
            if declarations(of: name, in: structure) != read.count {
                findings.malformed.append("a `/\(name)` is not an inline array of four numbers, so the clip it sets "
                    + "cannot be read")
            }
            return read
        }

        /// The value of a PDF numeric token — an optional sign, then digits with
        /// at most one period — or `nil` for anything else, which `Double(_:)`
        /// would otherwise read: `0x18`, `1e1`, `inf`.
        private static func number(_ token: String) -> Double? {
            firstMatch(#"^([-+]?([0-9]+\.?[0-9]*|\.[0-9]+))$"#, in: token).flatMap(Double.init)
        }

        /// The entries of the first dictionary in `text`, at its own depth only:
        /// each nested dictionary, array and hex string is replaced by an empty
        /// one, so a key inside `/DecodeParms << … >>` or `/Metadata << … >>` is
        /// not read as the stream's own. `nil` when the dictionary is absent or
        /// does not close, or a container inside it closes the wrong way.
        private static func outerDictionary(_ text: String) -> String? {
            let bytes = Array(text.utf8)
            var stack: [UInt8] = []
            var entries: [UInt8] = []
            var index = 0
            func at(_ prefix: String) -> Bool { bytes[index...].starts(with: Array(prefix.utf8)) }
            while index < bytes.count {
                let atTop = stack.count == 1
                if at("<<") {
                    stack.append(UInt8(ascii: "<"))
                    if stack.count == 2 { entries += Array(" <<>> ".utf8) }
                    index += 2
                } else if stack.isEmpty {
                    index += 1
                } else if at(">>") {
                    guard stack.popLast() == UInt8(ascii: "<") else { return nil }
                    if stack.isEmpty { return String(decoding: entries, as: Unicode.ASCII.self) }
                    index += 2
                } else if bytes[index] == UInt8(ascii: "[") {
                    stack.append(UInt8(ascii: "["))
                    if stack.count == 2 { entries += Array(" [] ".utf8) }
                    index += 1
                } else if bytes[index] == UInt8(ascii: "]") {
                    guard stack.popLast() == UInt8(ascii: "[") else { return nil }
                    index += 1
                } else if bytes[index] == UInt8(ascii: "<") {
                    guard let close = bytes[index...].firstIndex(of: UInt8(ascii: ">")) else { return nil }
                    if atTop { entries += Array(" <> ".utf8) }
                    index = close + 1
                } else {
                    if atTop { entries.append(bytes[index]) }
                    index += 1
                }
            }
            return nil
        }

        /// The outer dictionary's entries in order, as PDF pairs them: each key a
        /// name, each value one token — an indirect reference's three tokens
        /// joined as one — so a name standing as another entry's value, as in
        /// `/Alias /Filter`, is that entry's value and never a key. `nil` when a
        /// key is not a name or the last key has no value.
        private static func entries(of dictionary: String) -> [(key: String, value: String)]? {
            // `outerDictionary` leaves each nested container as `<<>>`, `[]`,
            // `<>` or `()`; each of those is one token, as is a name, a run of
            // regular characters, and any other lone delimiter.
            let regular = #"[^\x00\t\n\f\r ()<>\[\]{}/%]"#
            let tokens = matches(#"(<<>>|\[\]|<>|\(\)|/"# + regular + "*|" + regular + #"+|[^\x00\t\n\f\r ])"#,
                                 in: dictionary)
            let isInteger = { (token: String) in token.utf8.allSatisfy { (48...57).contains($0) } }
            var pairs: [(key: String, value: String)] = []
            var index = 0
            while index < tokens.count {
                guard tokens[index].hasPrefix("/"), index + 1 < tokens.count else { return nil }
                let key = tokens[index]
                var value = tokens[index + 1]
                index += 2
                if isInteger(value), index + 1 < tokens.count, isInteger(tokens[index]), tokens[index + 1] == "R" {
                    value += " " + tokens[index] + " R"
                    index += 2
                }
                pairs.append((key, value))
            }
            return pairs
        }

        /// How many times the structure names the key `/<name>`.
        private static func declarations(of name: String, in structure: String) -> Int {
            matches(#"/(\#(name))"# + tokenEnd, in: structure).count
        }

        // MARK: Byte and text search

        /// The structure as PDF's tokens read it, so a key is matched however it
        /// is spelled: each comment becomes the one space PDF takes it for, so
        /// `/Length 123%…⏎0 R` reads as the reference it is; each literal string
        /// is emptied, since its contents name no key; and each `#xx` escape in a
        /// name that spells a regular character is decoded, so `/Rot#61te` reads
        /// as `/Rotate`. An escape spelling whitespace or a delimiter stays as
        /// written, keeping its name one token. A literal string that never
        /// closes is recorded as malformed, since everything after it would be
        /// read as its contents.
        private static func lexical(_ bytes: ArraySlice<UInt8>, into findings: inout Findings) -> String {
            var text: [UInt8] = []
            var index = bytes.startIndex
            var inName = false
            while index < bytes.endIndex {
                let byte = bytes[index]
                if byte == UInt8(ascii: "%") {
                    while index < bytes.endIndex, ![0x0A, 0x0D].contains(bytes[index]) { index += 1 }
                    text.append(0x20)
                    inName = false
                    continue
                }
                if byte == UInt8(ascii: "(") {
                    guard let end = endOfString(bytes, from: index) else {
                        let unclosed = "a literal string never closes, so the structure after it cannot be read"
                        if !findings.malformed.contains(unclosed) { findings.malformed.append(unclosed) }
                        break
                    }
                    index = end
                    text += Array("()".utf8)
                    inName = false
                    continue
                }
                if inName, byte == UInt8(ascii: "#"), index + 2 < bytes.endIndex,
                   let high = hexValue(bytes[index + 1]), let low = hexValue(bytes[index + 2]),
                   isRegular(high << 4 | low) {
                    text.append(high << 4 | low)
                    index += 3
                    continue
                }
                if byte == UInt8(ascii: "/") {
                    inName = true
                } else if !isRegular(byte) {
                    inName = false
                }
                text.append(byte)
                index += 1
            }
            return String(decoding: text, as: Unicode.ASCII.self)
        }

        /// The offset past the literal string opening at `start`, honouring its
        /// balanced parentheses and backslash escapes; `nil` when it never closes.
        private static func endOfString(_ bytes: ArraySlice<UInt8>, from start: Int) -> Int? {
            var depth = 0
            var index = start
            while index < bytes.endIndex {
                switch bytes[index] {
                case UInt8(ascii: "\\"):
                    index += 1
                case UInt8(ascii: "("):
                    depth += 1
                case UInt8(ascii: ")"):
                    depth -= 1
                    if depth == 0 { return index + 1 }
                default:
                    break
                }
                index += 1
            }
            return nil
        }

        /// Whether `byte` is PDF whitespace: NUL, tab, line feed, form feed,
        /// carriage return or space — not the vertical tab Unicode adds.
        private static func isSpace(_ byte: UInt8) -> Bool {
            Array(" \t\n\r\u{0C}\u{00}".utf8).contains(byte)
        }

        /// Whether `byte` is a PDF regular character: neither whitespace nor a delimiter.
        private static func isRegular(_ byte: UInt8) -> Bool {
            !isSpace(byte) && !Array("()<>[]{}/%".utf8).contains(byte)
        }

        private static func hexValue(_ byte: UInt8) -> UInt8? {
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
            default: nil
            }
        }

        /// The offset of the first — or, with `last`, the final — `keyword`
        /// standing as a whole PDF token in `bytes[start..<end]`: never inside a
        /// comment, a literal string or a name, nor as part of a longer token. A
        /// literal string that never closes ends the search, since everything
        /// after it is its contents; `lexical` records it.
        private static func keyword(_ keyword: String, in bytes: [UInt8], from start: Int,
                                    before end: Int? = nil, last: Bool = false) -> Int? {
            let pattern = Array(keyword.utf8)
            let slice = bytes[start..<(end ?? bytes.count)]
            var found: Int?
            var index = slice.startIndex
            while index < slice.endIndex {
                let byte = slice[index]
                if byte == UInt8(ascii: "%") {
                    while index < slice.endIndex, ![0x0A, 0x0D].contains(slice[index]) { index += 1 }
                    continue
                }
                if byte == UInt8(ascii: "(") {
                    guard let close = endOfString(slice, from: index) else { break }
                    index = close
                    continue
                }
                guard isRegular(byte) else {
                    index += 1
                    continue
                }
                var tokenEnd = index
                while tokenEnd < slice.endIndex, isRegular(slice[tokenEnd]) { tokenEnd += 1 }
                let isName = index > slice.startIndex && slice[index - 1] == UInt8(ascii: "/")
                if !isName, slice[index..<tokenEnd].elementsEqual(pattern) {
                    guard last else { return index }
                    found = index
                }
                index = tokenEnd
            }
            return found
        }

        private static func matches(_ pattern: String, in text: String) -> [String] {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
            let whole = NSRange(text.startIndex..., in: text)
            return expression.matches(in: text, range: whole).compactMap { match in
                Range(match.range(at: 1), in: text).map { String(text[$0]) }
            }
        }

        private static func firstMatch(_ pattern: String, in text: String) -> String? {
            matches(pattern, in: text).first
        }
    }
}
