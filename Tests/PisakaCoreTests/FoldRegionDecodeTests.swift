import XCTest
@testable import PisakaCore

/// `textDocument/foldingRange` on the wire: what is sent, what is accepted, and
/// what is refused.
///
/// The fold question is the cheapest one in the LSP layer to lose — a server
/// that says nothing leaves the pure scanner answering — which is exactly why
/// its decoder needs pinning rather than trusting. Every failure here is silent
/// at runtime: a `kind` string nobody recognised, one miscounted block among
/// four hundred good ones, or a `null` read as an error would each end with the
/// file folding somewhere slightly different, and nothing would ever say so.
///
/// The three rules asserted below are the ones stated on the types themselves:
/// **an unknown `kind` is absent, not a refusal**; **one bad element is dropped
/// while its siblings survive**; and **a top level that is neither `null` nor an
/// array still throws**, because "this file folds nowhere" and "we could not
/// read the answer" must stay different facts.
final class FoldRegionDecodeTests: XCTestCase {
    // MARK: - Helpers

    private func decodeRange(_ body: String) throws -> LSPFoldingRange {
        try JSONDecoder().decode(LSPFoldingRange.self, from: Data(body.utf8))
    }

    private func decodeResponse(_ body: String) throws -> LSPFoldingRangeResponse {
        // Wrapped in an array so a bare `null` — which `JSONDecoder` refuses as
        // a top-level fragment — reaches the single-value container the response
        // actually reads it through at runtime.
        try JSONDecoder().decode(
            [LSPFoldingRangeResponse].self,
            from: Data("[\(body)]".utf8)
        )[0]
    }

    // MARK: - The params

    /// The one request in the layer that names no position: folding is a
    /// property of the whole document, so there is nothing to point at, and a
    /// `position` sent anyway would be a member the server has to ignore.
    func testFoldingRangeParamsCarryOnlyTheDocument() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let encoded = try encoder.encode(LSPFoldingRangeParams(uri: "file:///tmp/Project/main.swift"))
        XCTAssertEqual(
            String(decoding: encoded, as: UTF8.self),
            #"{"textDocument":{"uri":"file:///tmp/Project/main.swift"}}"#
        )
    }

    func testTheMethodNameIsSpelledOnce() {
        XCTAssertEqual(LSPMethod.foldingRange, "textDocument/foldingRange")
    }

    // MARK: - One range

    func testTheFullShapeDecodesEveryMember() throws {
        let range = try decodeRange(
            #"{"startLine":4,"startCharacter":18,"endLine":9,"endCharacter":1,"kind":"region"}"#
        )
        XCTAssertEqual(range.startLine, 4)
        XCTAssertEqual(range.startCharacter, 18)
        XCTAssertEqual(range.endLine, 9)
        XCTAssertEqual(range.endCharacter, 1)
        XCTAssertEqual(range.kind, .region)
    }

    /// The two characters are optional on the wire *and* their absence means
    /// something: no `startCharacter` is "from the end of `startLine`", no
    /// `endCharacter` is "to the end of `endLine`". So `nil` has to survive the
    /// decode as `nil` rather than as a zero, which would hide the whole header
    /// line behind the placeholder.
    func testTheTwoCharactersMayBeAbsentAndStayAbsent() throws {
        let range = try decodeRange(#"{"startLine":4,"endLine":9}"#)
        XCTAssertEqual(range.startLine, 4)
        XCTAssertEqual(range.endLine, 9)
        XCTAssertNil(range.startCharacter)
        XCTAssertNil(range.endCharacter)
        XCTAssertNil(range.kind)
    }

    func testAnExplicitNullCharacterIsTheSameAsAnAbsentOne() throws {
        let range = try decodeRange(
            #"{"startLine":4,"startCharacter":null,"endLine":9,"endCharacter":null}"#
        )
        XCTAssertNil(range.startCharacter)
        XCTAssertNil(range.endCharacter)
    }

    /// A character that is not a number at all — a server bug, or a spec this
    /// client has not read yet. It is read as absence rather than failing the
    /// element, on the same lenient path `LSPDiagnostic`'s optionals take.
    func testAnUnreadableCharacterDegradesToAbsence() throws {
        let range = try decodeRange(
            #"{"startLine":4,"startCharacter":"eighteen","endLine":9}"#
        )
        XCTAssertEqual(range.startLine, 4)
        XCTAssertNil(range.startCharacter)
    }

    func testEveryKindTheClosedTableNamesDecodes() throws {
        for kind in FoldRegionKind.allCases {
            let range = try decodeRange(
                #"{"startLine":0,"endLine":3,"kind":"\#(kind.rawValue)"}"#
            )
            XCTAssertEqual(range.kind, kind)
        }
    }

    /// `FoldingRangeKind` is an *open* set in the specification — a server may
    /// invent a word — so a kind outside the closed table is read as **absent
    /// rather than as a refusal**. Dropping the region instead would cost the
    /// file a perfectly good fold over a label nothing in this editor reads.
    func testAKindTheTableDoesNotKnowIsAbsentRatherThanARefusal() throws {
        let range = try decodeRange(#"{"startLine":4,"endLine":9,"kind":"licence-header"}"#)
        XCTAssertEqual(range.startLine, 4)
        XCTAssertEqual(range.endLine, 9)
        XCTAssertNil(range.kind)
    }

    func testAKindOfTheWrongTypeIsAlsoJustAbsent() throws {
        let range = try decodeRange(#"{"startLine":4,"endLine":9,"kind":7}"#)
        XCTAssertNil(range.kind)
    }

    /// The two line numbers are the only members that are not optional, because
    /// a range that does not say where it starts and ends is not a range.
    func testARangeMissingALineNumberFailsToDecode() {
        XCTAssertThrowsError(try decodeRange(#"{"startLine":4}"#))
        XCTAssertThrowsError(try decodeRange(#"{"endLine":9}"#))
    }

    // MARK: - The answer

    func testAnOrdinaryAnswerKeepsEveryRangeInWireOrder() throws {
        let response = try decodeResponse(
            """
            [{"startLine":0,"endLine":2,"kind":"imports"},\
            {"startLine":4,"startCharacter":18,"endLine":9,"endCharacter":1},\
            {"startLine":11,"endLine":14,"kind":"comment"}]
            """
        )
        XCTAssertEqual(response.ranges.map(\.startLine), [0, 4, 11])
        XCTAssertEqual(response.ranges.map(\.kind), [.imports, nil, .comment])
        XCTAssertFalse(response.isEmpty)
    }

    /// A server with nothing to say and a server that says so explicitly are the
    /// same fact — the rule every response in the file states.
    func testNullAndAnEmptyArrayAreTheSameEmptyAnswer() throws {
        XCTAssertTrue(try decodeResponse("null").isEmpty)
        XCTAssertTrue(try decodeResponse("[]").isEmpty)
    }

    /// The session folds an absent `result` member into `null` before the typed
    /// decode ever runs, so the two spellings arrive here as one.
    func testAMissingResultMemberIsTheSameEmptyAnswer() throws {
        let envelope = """
            {"jsonrpc":"2.0","id":2}
            """
        let message = try LSPIncomingMessage.decode(Data(envelope.utf8))
        guard case .response(let response) = message else {
            return XCTFail("not a response")
        }
        XCTAssertNil(response.result)
        // What `LSPSession.decode` does with that nil: read it as `null`.
        let folded = try (response.result ?? .null).decoded(as: LSPFoldingRangeResponse.self)
        XCTAssertTrue(folded.isEmpty)
    }

    /// One miscounted block must not cost the file the other four hundred —
    /// `publishDiagnostics`' per-element rule, applied here.
    func testOneUnreadableElementIsDroppedWhileItsSiblingsSurvive() throws {
        let response = try decodeResponse(
            """
            [{"startLine":0,"endLine":2},\
            {"startLine":"four","endLine":9},\
            "not an object at all",\
            {"startLine":11,"endLine":14}]
            """
        )
        XCTAssertEqual(response.ranges.map(\.startLine), [0, 11])
    }

    /// "This file folds nowhere" and "we could not read the answer" are
    /// different facts: only the second one is a failure, and the routing layer
    /// reads them differently.
    func testATopLevelThatIsNeitherNullNorAnArrayThrows() {
        XCTAssertThrowsError(try decodeResponse(#"{"ranges":[]}"#))
        XCTAssertThrowsError(try decodeResponse("true"))
        XCTAssertThrowsError(try decodeResponse(#""[]""#))
    }

    // MARK: - The capability, both halves

    /// `foldingRangeProvider` is `boolean | FoldingRangeOptions |
    /// FoldingRangeRegistrationOptions` — three spellings of one question, read
    /// through the collapse every provider in the file shares.
    func testTheServerCapabilityIsReadThroughTheSameCollapse() throws {
        let boolean = try JSONDecoder().decode(
            LSPServerCapabilities.self,
            from: Data(#"{"foldingRangeProvider":true}"#.utf8)
        )
        XCTAssertTrue(boolean.supportsFoldingRange)

        let empty = try JSONDecoder().decode(
            LSPServerCapabilities.self,
            from: Data(#"{"foldingRangeProvider":{}}"#.utf8)
        )
        XCTAssertTrue(empty.supportsFoldingRange)

        let options = try JSONDecoder().decode(
            LSPServerCapabilities.self,
            from: Data(#"{"foldingRangeProvider":{"workDoneProgress":true}}"#.utf8)
        )
        XCTAssertTrue(options.supportsFoldingRange)
    }

    func testEveryWayOfSayingNoToFoldingRanges() throws {
        let stated = try JSONDecoder().decode(
            LSPServerCapabilities.self,
            from: Data(#"{"foldingRangeProvider":false}"#.utf8)
        )
        XCTAssertFalse(stated.supportsFoldingRange)

        let explicitNull = try JSONDecoder().decode(
            LSPServerCapabilities.self,
            from: Data(#"{"foldingRangeProvider":null}"#.utf8)
        )
        XCTAssertFalse(explicitNull.supportsFoldingRange)

        let absent = try JSONDecoder().decode(
            LSPServerCapabilities.self,
            from: Data(#"{"definitionProvider":true}"#.utf8)
        )
        XCTAssertFalse(absent.supportsFoldingRange)

        XCTAssertFalse(LSPServerCapabilities().supportsFoldingRange)
    }

    /// The client half is a *promise*, so it is asserted key by key rather than
    /// by "the tree contains the word folding". `lineFoldingOnly: false` is the
    /// load-bearing one: this editor hides a UTF-16 range, and a server told
    /// otherwise would round every block out to whole lines. `collapsedText:
    /// false` is its mirror — the placeholder is always `…`, so a
    /// server-supplied one would be received and thrown away.
    func testTheClientCapabilityAsksForCharacterPreciseRangesAndNoCollapsedText() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let tree = try JSONSerialization.jsonObject(
            with: try encoder.encode(LSPClientCapabilities())
        ) as? [String: Any]
        let textDocument = tree?["textDocument"] as? [String: Any]
        let folding = try XCTUnwrap(textDocument?["foldingRange"] as? [String: Any])

        XCTAssertEqual(folding["dynamicRegistration"] as? Bool, false)
        XCTAssertEqual(folding["lineFoldingOnly"] as? Bool, false)

        let kinds = try XCTUnwrap(folding["foldingRangeKind"] as? [String: Any])
        XCTAssertEqual(kinds["valueSet"] as? [String], ["comment", "imports", "region"])

        let nested = try XCTUnwrap(folding["foldingRange"] as? [String: Any])
        XCTAssertEqual(nested["collapsedText"] as? Bool, false)

        // The advertised set *is* the closed table, rather than a second list
        // beside it that can drift.
        XCTAssertEqual(kinds["valueSet"] as? [String], FoldRegionKind.allCases.map(\.rawValue))
    }
}
