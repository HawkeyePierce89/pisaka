import XCTest
@testable import PisakaCore

/// `textDocument/documentHighlight` on the wire: the capability in both of its
/// spellings, the request's shape, and the result's three decoding rules.
///
/// The rules are the ones `LSPDocumentHighlightResponse` states. `null` is an
/// empty answer, not a failure. One unreadable element is dropped while its
/// siblings survive. A top level that is neither `null` nor an array throws.
/// An unreadable or unknown `kind` decodes rather than refusing its range.
final class DocumentHighlightDecodeTests: XCTestCase {
    // MARK: - Helpers

    private func capabilities(_ body: String) throws -> LSPServerCapabilities {
        try JSONDecoder().decode(LSPServerCapabilities.self, from: Data(body.utf8))
    }

    private func decodeResponse(_ body: String) throws -> LSPDocumentHighlightResponse {
        // Wrapped in an array so a bare `null`, which `JSONDecoder` refuses as a
        // top-level fragment, reaches the single-value container.
        try JSONDecoder().decode(
            [LSPDocumentHighlightResponse].self,
            from: Data("[\(body)]".utf8)
        )[0]
    }

    // MARK: - The capability

    func testTheBooleanSpellingIsReadBothWays() throws {
        XCTAssertTrue(try capabilities(#"{"documentHighlightProvider":true}"#).supportsDocumentHighlight)
        XCTAssertFalse(try capabilities(#"{"documentHighlightProvider":false}"#).supportsDocumentHighlight)
    }

    /// `DocumentHighlightOptions` is the second spelling. An options object,
    /// even an empty one, is support.
    func testTheOptionsSpellingIsSupport() throws {
        XCTAssertTrue(try capabilities(#"{"documentHighlightProvider":{}}"#).supportsDocumentHighlight)
        XCTAssertTrue(
            try capabilities(#"{"documentHighlightProvider":{"workDoneProgress":true}}"#)
                .supportsDocumentHighlight
        )
    }

    func testAnAbsentOrNullProviderIsNoSupport() throws {
        XCTAssertFalse(try capabilities("{}").supportsDocumentHighlight)
        XCTAssertFalse(try capabilities(#"{"documentHighlightProvider":null}"#).supportsDocumentHighlight)
    }

    // MARK: - The request

    func testTheMethodNameIsSpelledOnce() {
        XCTAssertEqual(LSPMethod.documentHighlight, "textDocument/documentHighlight")
    }

    func testTheParamsAreAPositionRequest() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let params = LSPDocumentHighlightParams(
            uri: "file:///tmp/Project/main.swift",
            position: LSPPosition(line: 2, character: 7)
        )
        XCTAssertEqual(
            String(decoding: try encoder.encode(params), as: UTF8.self),
            #"{"position":{"character":7,"line":2},"textDocument":{"uri":"file:///tmp/Project/main.swift"}}"#
        )
    }

    // MARK: - The result

    func testEveryKindDecodesIncludingAbsentAndUnknown() throws {
        let response = try decodeResponse("""
            [{"range":{"start":{"line":0,"character":1},"end":{"line":0,"character":4}},"kind":1},
             {"range":{"start":{"line":1,"character":1},"end":{"line":1,"character":4}},"kind":2},
             {"range":{"start":{"line":2,"character":1},"end":{"line":2,"character":4}},"kind":3},
             {"range":{"start":{"line":3,"character":1},"end":{"line":3,"character":4}}},
             {"range":{"start":{"line":4,"character":1},"end":{"line":4,"character":4}},"kind":9},
             {"range":{"start":{"line":5,"character":1},"end":{"line":5,"character":4}},"kind":"write"}]
            """)
        XCTAssertEqual(
            response.highlights.map(\.kind),
            [.text, .read, .write, nil, LSPDocumentHighlightKind(rawValue: 9), nil]
        )
        XCTAssertEqual(response.highlights.map(\.range.start.line), [0, 1, 2, 3, 4, 5])
    }

    func testNullIsAnEmptyAnswerRatherThanAFailure() throws {
        XCTAssertTrue(try decodeResponse("null").isEmpty)
        XCTAssertTrue(try decodeResponse("[]").isEmpty)
    }

    func testOneUnreadableElementIsDroppedAndItsSiblingsSurvive() throws {
        let response = try decodeResponse("""
            [{"range":{"start":{"line":0,"character":1},"end":{"line":0,"character":4}}},
             {"kind":2},
             "nonsense"]
            """)
        XCTAssertEqual(response.highlights.count, 1)
    }

    func testATopLevelThatIsNeitherNullNorAnArrayThrows() {
        XCTAssertThrowsError(try decodeResponse(#"{"range":{}}"#))
        XCTAssertThrowsError(try decodeResponse("3"))
    }
}
