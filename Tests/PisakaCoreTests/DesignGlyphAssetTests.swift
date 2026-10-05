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
///    one `/MediaBox`, equal to `[0 0 24 24]`; every content stream located
///    through its `/Length`, `/FlateDecode`, with a valid zlib header and an
///    Adler-32 trailer that proves the inflate; and every path coordinate — the
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
        let findings = GlyphGeometry.read(try Self.fixturePDF(mediaBox: "0 0 12 12", content: "1 1 m 11 11 l h f"))
        XCTAssertEqual(findings.mediaBoxes, [[0, 0, 12, 12]])
        XCTAssertEqual(findings.outOfBox, [])
        XCTAssertEqual(findings.failures.count, 1)
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

    /// A minimal PDF-shaped fixture: one object carrying the media box, one
    /// `/FlateDecode` stream holding `content` in zlib framing — the `0x78 0x9C`
    /// header, the raw deflate Foundation produces, a big-endian Adler-32.
    private static func fixturePDF(mediaBox: String = "0 0 24 24", content: String) throws -> Data {
        let body = Data(content.utf8)
        var stream = Data([0x78, 0x9C])
        stream.append(try (body as NSData).compressed(using: .zlib) as Data)
        withUnsafeBytes(of: GlyphGeometry.adler32(body).bigEndian) { stream.append(contentsOf: $0) }

        var pdf = Data("""
            %PDF-1.4
            1 0 obj
            <</Type /Page /MediaBox [\(mediaBox)]>>
            endobj
            2 0 obj
            <</Filter /FlateDecode
            /Length \(stream.count)>> stream

            """.utf8)
        pdf.append(stream)
        pdf.append(Data("\nendstream\nendobj\n%%EOF\n".utf8))
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
                if streams == 0 { failures.append("it has no content stream") }
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

        static func read(_ pdf: Data) -> Findings {
            var findings = Findings()
            let bytes = [UInt8](pdf)
            var structure: [UInt8] = []
            var cursor = 0
            while let keyword = find("stream", in: bytes, from: cursor) {
                structure += bytes[cursor..<keyword]
                guard let end = readStream(bytes, keyword: keyword, from: cursor, into: &findings) else {
                    cursor = bytes.count
                    break
                }
                cursor = end
            }
            structure += bytes[min(cursor, bytes.count)...]
            findings.mediaBoxes = mediaBoxes(in: String(decoding: structure, as: Unicode.ASCII.self))
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
            let header = find("obj", in: bytes, from: start, before: keyword, last: true) ?? start
            let dictionary = String(decoding: bytes[header..<keyword], as: Unicode.ASCII.self)
            guard let length = firstMatch(#"/Length\s+(\d+)\b(?!\s+\d+\s+R)"#, in: dictionary).flatMap(Int.init),
                  dataStart + length <= bytes.count else {
                findings.malformed.append("a content stream has no direct `/Length` inside the file")
                return nil
            }
            var after = dataStart + length
            while after < bytes.count, [0x0A, 0x0D, 0x20].contains(bytes[after]) { after += 1 }
            guard bytes[after...].starts(with: Array("endstream".utf8)) else {
                findings.malformed.append("a content stream's `/Length` does not end at `endstream`")
                return nil
            }
            findings.streams += 1
            if firstMatch(#"/Filter\s*/(FlateDecode)\b"#, in: dictionary) == nil {
                findings.malformed.append("a content stream is not `/FlateDecode`")
            } else if let text = inflate(Array(bytes[dataStart..<(dataStart + length)]), into: &findings) {
                interpret(text, into: &findings)
            }
            return after + "endstream".utf8.count
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

        /// How many points each path operator bounds; `re` and the state
        /// operators are handled by name.
        private static let pointOperators: [String: Int] = ["m": 1, "l": 1, "c": 3, "v": 2, "y": 2]
        private static let inertOperators: Set<String> = ["h", "f", "gs", "rg", "RG"]

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
                if let count = pointOperators[token] {
                    guard numbers.count == count * 2, names == 0 else {
                        findings.malformed.append("`\(token)` has \(numbers.count) operands, not \(count * 2)")
                        continue
                    }
                    for index in stride(from: 0, to: numbers.count, by: 2) {
                        bound(numbers[index], numbers[index + 1], by: matrix, into: &findings)
                    }
                } else if inertOperators.contains(token) {
                    continue
                } else if !operate(token, numbers, matrix: &matrix, saved: &saved, into: &findings) {
                    findings.unknownOperators.append(token)
                }
            }
        }

        /// The operators that change the matrix or draw a rectangle; `false`
        /// for any operator the check does not read.
        private static func operate(_ token: String, _ numbers: [Double], matrix: inout Matrix,
                                    saved: inout [Matrix], into findings: inout Findings) -> Bool {
            switch token {
            case "q":
                saved.append(matrix)
            case "Q":
                guard let restored = saved.popLast() else {
                    findings.malformed.append("a `Q` restores a state no `q` saved")
                    return true
                }
                matrix = restored
            case "cm":
                guard numbers.count == 6 else {
                    findings.malformed.append("`cm` has \(numbers.count) operands, not 6")
                    return true
                }
                matrix = Matrix(numbers).concatenated(onto: matrix)
            case "re":
                guard numbers.count == 4 else {
                    findings.malformed.append("`re` has \(numbers.count) operands, not 4")
                    return true
                }
                let (x, y, width, height) = (numbers[0], numbers[1], numbers[2], numbers[3])
                for (cornerX, cornerY) in [(x, y), (x + width, y), (x, y + height), (x + width, y + height)] {
                    bound(cornerX, cornerY, by: matrix, into: &findings)
                }
            default:
                return false
            }
            return true
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

        private static func mediaBoxes(in structure: String) -> [[Double]] {
            matches(#"/MediaBox\s*\[([^\]]*)\]"#, in: structure).map { inside in
                inside.split(whereSeparator: \.isWhitespace).compactMap { Double($0) }
            }
        }

        // MARK: Byte and text search

        private static func find(_ needle: String, in bytes: [UInt8], from start: Int,
                                 before end: Int? = nil, last: Bool = false) -> Int? {
            let pattern = Array(needle.utf8)
            let limit = (end ?? bytes.count) - pattern.count
            guard start <= limit else { return nil }
            let offsets = last ? Array(stride(from: limit, through: start, by: -1)) : Array(start...limit)
            return offsets.first { bytes[$0..<($0 + pattern.count)].elementsEqual(pattern) }
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
