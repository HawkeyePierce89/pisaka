import XCTest
@testable import PisakaCore

/// The diagnostic value type: the severity table, the wire→buffer mapping
/// (`Diagnostic.make`) and the panel's ordering key.
///
/// Every number that comes out of `make` goes straight into TextKit or the
/// ruler, so the mapping cases here are the ones that could trap there: an
/// out-of-buffer position, a surrogate pair mis-counted as one code unit, a
/// range spanning lines. The wire types themselves are pinned against raw JSON,
/// in `LSPProtocolTypesTests`' lenient-decode style.
final class DiagnosticTests: XCTestCase {
    private let url = URL(fileURLWithPath: "/tmp/pkg/Sources/App/main.swift")

    private func make(
        _ json: String,
        in text: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Diagnostic? {
        let params = try JSONDecoder().decode(
            LSPPublishDiagnosticsParams.self,
            from: Data(json.utf8)
        )
        guard let wire = params.diagnostics.first else {
            XCTFail("the push carried no diagnostics", file: file, line: line)
            return nil
        }
        let content = text as NSString
        return Diagnostic.make(
            from: wire,
            in: content,
            lineStarts: LSPPositionMap.lineStarts(in: content),
            url: url
        )
    }

    // MARK: - Severity table

    func testTheSeverityTableMapsBothWays() {
        XCTAssertEqual(DiagnosticSeverity(lspValue: 1), .error)
        XCTAssertEqual(DiagnosticSeverity(lspValue: 2), .warning)
        XCTAssertEqual(DiagnosticSeverity(lspValue: 3), .information)
        XCTAssertEqual(DiagnosticSeverity(lspValue: 4), .hint)

        XCTAssertEqual(DiagnosticSeverity.error.rawValue, 1)
        XCTAssertEqual(DiagnosticSeverity.warning.rawValue, 2)
        XCTAssertEqual(DiagnosticSeverity.information.rawValue, 3)
        XCTAssertEqual(DiagnosticSeverity.hint.rawValue, 4)
    }

    /// An absent severity is the server declining to say — and an editor that
    /// must not hide a failure reads silence as error, not as trivia.
    func testAnAbsentSeverityIsAnError() {
        XCTAssertEqual(DiagnosticSeverity(lspValue: nil), .error)
    }

    /// Same for a number this spec version does not name (0 is explicitly not a
    /// severity; 5+ is a server from the future).
    func testAnUnknownSeverityIsAnError() {
        XCTAssertEqual(DiagnosticSeverity(lspValue: 0), .error)
        XCTAssertEqual(DiagnosticSeverity(lspValue: 5), .error)
        XCTAssertEqual(DiagnosticSeverity(lspValue: -1), .error)
        XCTAssertEqual(DiagnosticSeverity(lspValue: 99), .error)
    }

    /// `.error` is the *greatest* element, so `max` answers what the gutter shows.
    func testSeverityOrdersBySeriousnessNotByWireValue() {
        XCTAssertLessThan(DiagnosticSeverity.hint, .information)
        XCTAssertLessThan(DiagnosticSeverity.information, .warning)
        XCTAssertLessThan(DiagnosticSeverity.warning, .error)
        let all: [DiagnosticSeverity] = [.warning, .hint, .error, .information]
        XCTAssertEqual(all.max(), .error)
        let partial: [DiagnosticSeverity] = [.warning, .hint]
        XCTAssertEqual(partial.max(), .warning)
    }

    // MARK: - Wire shape (decode leniently)

    func testAFullPushDecodesWithEveryOptionalMember() throws {
        let params = try JSONDecoder().decode(
            LSPPublishDiagnosticsParams.self,
            from: Data("""
            {"uri":"file:///tmp/pkg/Sources/App/main.swift","version":7,\
            "diagnostics":[{"range":{"start":{"line":0,"character":0},\
            "end":{"line":0,"character":3}},"severity":2,"code":"no_member",\
            "codeDescription":{"href":"file:///x"},"source":"sourcekit-lsp",\
            "message":"value of type X has no member"}]}
            """.utf8)
        )
        XCTAssertEqual(params.uri, "file:///tmp/pkg/Sources/App/main.swift")
        XCTAssertEqual(params.version, 7)
        XCTAssertEqual(params.diagnostics.count, 1)
        let entry = try XCTUnwrap(params.diagnostics.first)
        XCTAssertEqual(entry.severity, .warning)
        XCTAssertEqual(entry.code, .string("no_member"))
        XCTAssertEqual(entry.source, "sourcekit-lsp")
        XCTAssertEqual(entry.message, "value of type X has no member")
    }

    func testAnIntegerCodeDecodesToo() throws {
        let params = try JSONDecoder().decode(
            LSPPublishDiagnosticsParams.self,
            from: Data("""
            {"uri":"file:///a","diagnostics":[{"range":{"start":{"line":0,\
            "character":0},"end":{"line":0,"character":1}},"code":42,\
            "message":"m"}]}
            """.utf8)
        )
        XCTAssertEqual(params.diagnostics.first?.code, .int(42))
    }

    /// The spec lets a server omit `version`; most do. Absence must read as
    /// "accept regardless of version" (D31), never as a decode failure.
    func testAPushWithoutAVersionDecodesWithNilVersion() throws {
        let params = try JSONDecoder().decode(
            LSPPublishDiagnosticsParams.self,
            from: Data("""
            {"uri":"file:///a","diagnostics":[]}
            """.utf8)
        )
        XCTAssertNil(params.version)
        XCTAssertTrue(params.diagnostics.isEmpty)
    }

    func testNullAndMissingDiagnosticsBothReadAsNone() throws {
        for spelling in [#"{"uri":"file:///a","diagnostics":null}"#, #"{"uri":"file:///a"}"#] {
            let params = try JSONDecoder().decode(
                LSPPublishDiagnosticsParams.self,
                from: Data(spelling.utf8)
            )
            XCTAssertTrue(params.diagnostics.isEmpty, spelling)
        }
    }

    func testAnUnknownSeverityNumberSurvivesTheWireAndBecomesAnErrorOneLayerUp() throws {
        let params = try JSONDecoder().decode(
            LSPPublishDiagnosticsParams.self,
            from: Data("""
            {"uri":"file:///a","diagnostics":[{"range":{"start":{"line":0,\
            "character":0},"end":{"line":0,"character":1}},"severity":17,\
            "message":"from the future"}]}
            """.utf8)
        )
        let wire = try XCTUnwrap(params.diagnostics.first)
        XCTAssertEqual(wire.severity?.rawValue, 17, "the open set must round-trip the wire value")
        let mapped = Diagnostic.make(
            from: wire,
            in: "let x = 1" as NSString,
            lineStarts: [0],
            url: url
        )
        XCTAssertEqual(mapped?.severity, .error)
    }

    /// One malformed entry is dropped; its siblings survive — the same
    /// per-element rule `LSPHoverResponse` states.
    func testAMalformedEntryIsDroppedWithoutTakingThePushDown() throws {
        let params = try JSONDecoder().decode(
            LSPPublishDiagnosticsParams.self,
            from: Data("""
            {"uri":"file:///a","diagnostics":[\
            {"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}}},\
            {"range":{"start":{"line":1,"character":0},"end":{"line":1,"character":2}},\
            "message":"kept"}]}
            """.utf8)
        )
        XCTAssertEqual(params.diagnostics.map(\.message), ["kept"])
    }

    /// A top level without `uri` is not "an empty push" — it is an unreadable
    /// one, and those stay different facts.
    func testAPushWithoutURIIsADecodeFailure() {
        XCTAssertThrowsError(
            try JSONDecoder().decode(LSPPublishDiagnosticsParams.self, from: Data(#"{"diagnostics":[]}"#.utf8))
        )
    }

    /// The remaining "unreadable → nil, never a failed push" spellings, so a
    /// CodingKeys change cannot quietly turn any of them into a thrown error.
    func testLenientDecodeSpellings() throws {
        // A null severity decodes as an absent one (the mapping then says .error).
        let nullSeverity = try JSONDecoder().decode(
            LSPPublishDiagnosticsParams.self,
            from: Data("""
            {"uri":"file:///a","diagnostics":[{"range":{"start":{"line":0,"character":0},\
            "end":{"line":0,"character":1}},"severity":null,"message":"m"}]}
            """.utf8)
        )
        XCTAssertNil(nullSeverity.diagnostics.first?.severity)

        // A non-integer version is *unreadable*, not "absent-with-a-lie": it
        // decodes to nil (D31 then accepts against revision alone), never
        // fails the push and never fabricates an integer.
        let stringVersion = try JSONDecoder().decode(
            LSPPublishDiagnosticsParams.self,
            from: Data(#"{"uri":"file:///a","version":"7","diagnostics":[]}"#.utf8)
        )
        XCTAssertNil(stringVersion.version)

        // A non-object element inside the array is dropped by the lenient
        // per-element rule, not fatal to the push.
        let strayElement = try JSONDecoder().decode(
            LSPPublishDiagnosticsParams.self,
            from: Data("""
            {"uri":"file:///a","diagnostics":[42,{"range":{"start":{"line":0,"character":0},\
            "end":{"line":0,"character":1}},"message":"kept"}]}
            """.utf8)
        )
        XCTAssertEqual(strayElement.diagnostics.map(\.message), ["kept"])
    }

    /// The absent-severity `.error` fallback pinned end-to-end through the full
    /// JSON → wire → mapping path (not only via `init(lspValue:)`).
    func testAnAbsentSeverityThroughTheWholeMappingIsAnError() throws {
        let params = try JSONDecoder().decode(
            LSPPublishDiagnosticsParams.self,
            from: Data("""
            {"uri":"file:///a","diagnostics":[{"range":{"start":{"line":0,"character":0},\
            "end":{"line":0,"character":1}},"message":"m"}]}
            """.utf8)
        )
        let mapped = Diagnostic.make(
            from: try XCTUnwrap(params.diagnostics.first),
            in: "let x = 1" as NSString,
            lineStarts: [0],
            url: url
        )
        XCTAssertEqual(mapped?.severity, .error)
    }

    // MARK: - Mapping onto the buffer

    func testAZeroLengthDiagnosticStaysZeroLengthAtItsOffset() throws {
        //        0123456789
        let diagnostic = try make(
            """
            {"uri":"unused","diagnostics":[{"range":{"start":{"line":1,"character":2},\
            "end":{"line":1,"character":2}},"severity":1,"message":"m"}]}
            """,
            in: "aaa\nbbb"
        )
        let mapped = try XCTUnwrap(diagnostic)
        XCTAssertEqual(mapped.range, NSRange(location: 6, length: 0))
        XCTAssertEqual(mapped.line, 1)
        XCTAssertEqual(mapped.severity, .error)
    }

    func testAMultiLineRangeSpansFromItsStartLine() throws {
        //  aaa\nbbb\nccc → starts [0, 4, 8], length 11.
        let diagnostic = try make(
            """
            {"uri":"unused","diagnostics":[{"range":{"start":{"line":0,"character":1},\
            "end":{"line":2,"character":1}},"message":"m"}]}
            """,
            in: "aaa\nbbb\nccc"
        )
        let mapped = try XCTUnwrap(diagnostic)
        XCTAssertEqual(mapped.range, NSRange(location: 1, length: 8))
        XCTAssertEqual(mapped.line, 0)
    }

    /// Positions beyond the buffer clamp rather than reject: the underline lands
    /// at the end of the buffer instead of vanishing or trapping.
    func testARangePastTheEndOfTheBufferClampsToIt() throws {
        let diagnostic = try make(
            """
            {"uri":"unused","diagnostics":[{"range":{"start":{"line":9,"character":40},\
            "end":{"line":9,"character":50}},"message":"m"}]}
            """,
            in: "abc"
        )
        let mapped = try XCTUnwrap(diagnostic)
        XCTAssertEqual(mapped.range, NSRange(location: 3, length: 0))
        XCTAssertEqual(mapped.line, 0)
    }

    /// A character past its own line's content end stops *before* the separator,
    /// so the squiggle never paints the invisible half of a CRLF.
    func testACharacterPastItsLineEndClampsToThatLinesContentEnd() throws {
        let diagnostic = try make(
            """
            {"uri":"unused","diagnostics":[{"range":{"start":{"line":0,"character":30},\
            "end":{"line":0,"character":31}},"message":"m"}]}
            """,
            in: "ab\r\ncd"
        )
        let mapped = try XCTUnwrap(diagnostic)
        XCTAssertEqual(mapped.range, NSRange(location: 2, length: 0))
    }

    /// UTF-16 counting, not character counting: the emoji is two code units and
    /// everything after it shifts by two.
    func testNonASCIITextIsCountedInUTF16CodeUnits() throws {
        //  var 🎉 = 1\n — the emoji sits at units 4–5.
        let diagnostic = try make(
            """
            {"uri":"unused","diagnostics":[{"range":{"start":{"line":0,"character":4},\
            "end":{"line":0,"character":6}},"message":"m"}]}
            """,
            in: "var 🎉 = 1\n"
        )
        let mapped = try XCTUnwrap(diagnostic)
        XCTAssertEqual(mapped.range, NSRange(location: 4, length: 2))
        XCTAssertEqual(mapped.line, 0)
    }

    func testSourceAndMessageTravelThroughUnchanged() throws {
        let diagnostic = try make(
            """
            {"uri":"unused","diagnostics":[{"range":{"start":{"line":0,"character":0},\
            "end":{"line":0,"character":1}},"severity":3,"source":"pyright",\
            "message":"m"}]}
            """,
            in: "abc"
        )
        let mapped = try XCTUnwrap(diagnostic)
        XCTAssertEqual(mapped.source, "pyright")
        XCTAssertEqual(mapped.message, "m")
        XCTAssertEqual(mapped.fileURL, url)
    }

    // MARK: - Ordering key

    private func key(
        _ path: String,
        _ start: Int,
        _ severity: DiagnosticSeverity
    ) -> Diagnostic.OrderingKey {
        Diagnostic.OrderingKey(path: path, startOffset: start, severity: severity)
    }

    /// Grouped by file, then by position, then most severe first — and no two
    /// distinct diagnostics ever compare equal, which is what makes the order
    /// stable regardless of the sort's own stability.
    func testTheOrderingKeySortsPanelRowsInReadingOrder() {
        let unsorted = [
            key("/b.swift", 10, .warning),
            key("/a.swift", 40, .hint),
            key("/a.swift", 10, .warning),
            key("/a.swift", 10, .error),
            key("/a.swift", 5, .error),
        ]
        let sorted = unsorted.sorted()
        XCTAssertEqual(sorted, [
            key("/a.swift", 5, .error),
            key("/a.swift", 10, .error),
            key("/a.swift", 10, .warning),
            key("/a.swift", 40, .hint),
            key("/b.swift", 10, .warning),
        ])
    }

    /// The order is total: irreflexive, antisymmetric (exactly one of `a < b`,
    /// `b < a` holds for distinct elements) and transitive — over a sample
    /// including equal-path/equal-offset pairs that differ only in severity.
    func testTheOrderingKeyIsATotalOrder() {
        let sample = [
            key("/a.swift", 0, .error),
            key("/a.swift", 0, .hint),
            key("/a.swift", 7, .warning),
            key("/b.swift", 0, .information),
        ]
        XCTAssertFalse(key("/a.swift", 0, .error) < key("/a.swift", 0, .error), "< must be irreflexive")
        for a in sample {
            for b in sample {
                if a == b {
                    XCTAssertFalse(a < b, "< must be irreflexive")
                    continue
                }
                XCTAssertTrue(a < b || b < a, "\(a) and \(b) must compare")
                XCTAssertFalse(a < b && b < a, "\(a) and \(b) must not both be less")
            }
        }
        for a in sample {
            for b in sample {
                for c in sample where a < b && b < c {
                    XCTAssertTrue(a < c, "\(a) < \(b) < \(c) implies \(a) < \(c)")
                }
            }
        }
    }

    /// The key derives from the diagnostic itself — path standardized, start
    /// offset from the buffer range.
    func testTheOrderingKeyDerivesFromTheDiagnostic() {
        let diagnostic = Diagnostic(
            range: NSRange(location: 12, length: 3),
            line: 2,
            severity: .warning,
            message: "m",
            source: nil,
            fileURL: URL(fileURLWithPath: "/tmp/pkg/Src/A.swift")
        )
        XCTAssertEqual(
            diagnostic.orderingKey,
            key("/tmp/pkg/Src/A.swift", 12, .warning)
        )
    }

    // MARK: - Hover content (D34)

    private func diagnosed(
        at location: Int,
        _ severity: DiagnosticSeverity,
        _ message: String
    ) -> Diagnostic {
        Diagnostic(
            range: NSRange(location: location, length: 3),
            line: 0,
            severity: severity,
            message: message,
            source: nil,
            fileURL: url
        )
    }

    func testOneDiagnosticAloneIsALabelledProseSegment() throws {
        let content = try XCTUnwrap(
            Diagnostic.hoverContent(for: [diagnosed(at: 4, .warning, "unused x")], merging: nil)
        )
        XCTAssertEqual(content.segments, [.prose("warning: unused x")])
        XCTAssertFalse(content.isTruncated)
    }

    /// Two sharing one range sort most-severe-first, per the ordering key — the
    /// error a pointer rests on leads its hint.
    func testTwoOnOneRangeOrderMostSevereFirst() throws {
        let content = try XCTUnwrap(Diagnostic.hoverContent(
            for: [
                diagnosed(at: 4, .hint, "h"),
                diagnosed(at: 4, .error, "e"),
            ],
            merging: nil
        ))
        XCTAssertEqual(content.segments, [.prose("error: e"), .prose("hint: h")])
    }

    /// The messages ride above the type answer, in front of it.
    func testADiagnosticSitsAboveTheTypeAnswer() throws {
        let typeAnswer = try XCTUnwrap(HoverContent(segments: [.code("func f()"), .prose("doc")]))
        let content = try XCTUnwrap(
            Diagnostic.hoverContent(for: [diagnosed(at: 0, .error, "bad")], merging: typeAnswer)
        )
        XCTAssertEqual(content.segments, [.prose("error: bad"), .code("func f()"), .prose("doc")])
        XCTAssertFalse(content.isTruncated)
    }

    /// A message past the line cap comes out clipped and marked — D26's cap
    /// applied once, by the checking initializer, not re-applied here or left
    /// to the renderer's line-count pass.
    func testAMessageLongerThanTheCapIsClippedAndMarked() throws {
        let long = String(repeating: "a", count: HoverContent.maximumLineLength + 100)
        let content = try XCTUnwrap(
            Diagnostic.hoverContent(for: [diagnosed(at: 0, .error, long)], merging: nil)
        )
        XCTAssertEqual(content.segments.count, 1)
        XCTAssertEqual(content.segments.first?.text.count, HoverContent.maximumLineLength)
        XCTAssertTrue(content.isTruncated)
    }

    /// Nothing diagnosed: the type answer passes through whole — segments and
    /// its own truncation mark included.
    func testAnEmptySetFallsThroughToTheTypeAnswerUnchanged() throws {
        let typeAnswer = try XCTUnwrap(
            HoverContent(segments: [.prose("Int"), .prose("doc")], isTruncated: true)
        )
        let content = Diagnostic.hoverContent(for: [], merging: typeAnswer)
        XCTAssertEqual(content, typeAnswer)
    }

    /// No diagnostics and no type answer is no popover (D25), never an empty
    /// one.
    func testNothingAtAllBuildsNoContent() {
        XCTAssertNil(Diagnostic.hoverContent(for: [], merging: nil))
    }
}
