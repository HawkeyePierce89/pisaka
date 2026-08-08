import XCTest
@testable import PisakaCore

/// The bytes-in/bytes-out layer of the LSP client: `Content-Length` framing over
/// a stream that arrives in whatever pieces the kernel felt like handing over.
/// Everything here is about *chunk boundaries* and *bad headers* — the two ways a
/// framing layer breaks — because a desynchronised stream feeds the JSON layer
/// garbage that still looks like a message.
final class LSPFramingTests: XCTestCase {
    // MARK: - Helpers

    private func framed(_ body: String) -> Data {
        LSPFraming.encode(payload: Data(body.utf8))
    }

    private func text(_ payloads: [Data]) -> [String] {
        payloads.map { String(decoding: $0, as: UTF8.self) }
    }

    // MARK: - Encoding

    func testEncodeWritesContentLengthInBytesNotCharacters() {
        // "é" is two UTF-8 bytes: a length counted in characters would frame one
        // byte short and desync every following message.
        let framed = LSPFraming.encode(payload: Data(#"{"a":"é"}"#.utf8))
        XCTAssertEqual(
            String(decoding: framed, as: UTF8.self),
            "Content-Length: 10\r\n\r\n" + #"{"a":"é"}"#
        )
    }

    func testEncodeAndDecodeRoundTripOneMessage() throws {
        var decoder = LSPFraming.Decoder()
        let payloads = try decoder.append(framed(#"{"jsonrpc":"2.0"}"#))
        XCTAssertEqual(text(payloads), [#"{"jsonrpc":"2.0"}"#])
    }

    func testEncodeOutgoingMessageFramesItsPayload() throws {
        let message = LSPOutgoingMessage.notification(
            LSPNotificationMessage(method: "initialized", params: .object([:]))
        )
        let data = try LSPFraming.encode(message)
        let string = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(string.hasPrefix("Content-Length: "))
        let body = string.components(separatedBy: "\r\n\r\n").last ?? ""
        XCTAssertEqual(body, #"{"jsonrpc":"2.0","method":"initialized","params":{}}"#)
    }

    // MARK: - Chunk boundaries

    func testSplitMidHeaderYieldsNothingUntilTheHeaderCompletes() throws {
        var decoder = LSPFraming.Decoder()
        let all = framed("{}")
        XCTAssertEqual(try decoder.append(all.prefix(8)).count, 0)
        XCTAssertEqual(try decoder.append(all.dropFirst(8).prefix(4)).count, 0)
        XCTAssertEqual(text(try decoder.append(all.dropFirst(12))), ["{}"])
    }

    func testSplitMidBodyYieldsNothingUntilTheBodyCompletes() throws {
        var decoder = LSPFraming.Decoder()
        let all = framed(#"{"id":1}"#)
        let headerEnd = all.count - 8
        XCTAssertEqual(try decoder.append(all.prefix(headerEnd + 3)).count, 0)
        XCTAssertEqual(text(try decoder.append(all.dropFirst(headerEnd + 3))), [#"{"id":1}"#])
    }

    func testSeveralMessagesInOneReadAreAllYieldedInOrder() throws {
        var decoder = LSPFraming.Decoder()
        var chunk = framed("1")
        chunk.append(framed("22"))
        chunk.append(framed("333"))
        XCTAssertEqual(text(try decoder.append(chunk)), ["1", "22", "333"])
    }

    func testOneMessageAcrossManySingleByteReads() throws {
        var decoder = LSPFraming.Decoder()
        let all = framed(#"{"result":null}"#)
        var yielded: [Data] = []
        for byte in all {
            yielded += try decoder.append(Data([byte]))
        }
        XCTAssertEqual(text(yielded), [#"{"result":null}"#])
    }

    func testTrailingPartialMessageIsHeldForTheNextRead() throws {
        var decoder = LSPFraming.Decoder()
        var chunk = framed("first")
        chunk.append(framed("second").prefix(20))
        XCTAssertEqual(text(try decoder.append(chunk)), ["first"])
        XCTAssertEqual(
            text(try decoder.append(framed("second").dropFirst(20))),
            ["second"]
        )
    }

    /// The body is taken *by length*, never by scanning, so a payload that
    /// happens to contain a header separator is not a frame boundary.
    func testBodyContainingTheHeaderSeparatorIsNotSplit() throws {
        var decoder = LSPFraming.Decoder()
        let body = "{\"text\":\"a\r\n\r\nb\"}"
        var chunk = framed(body)
        chunk.append(framed("after"))
        XCTAssertEqual(text(try decoder.append(chunk)), [body, "after"])
    }

    func testEmptyChunkYieldsNothingAndKeepsState() throws {
        var decoder = LSPFraming.Decoder()
        _ = try decoder.append(framed("x").prefix(6))
        XCTAssertEqual(try decoder.append(Data()).count, 0)
        XCTAssertEqual(text(try decoder.append(framed("x").dropFirst(6))), ["x"])
    }

    func testZeroLengthBodyIsACompleteMessage() throws {
        var decoder = LSPFraming.Decoder()
        var chunk = Data("Content-Length: 0\r\n\r\n".utf8)
        chunk.append(framed("next"))
        XCTAssertEqual(text(try decoder.append(chunk)), ["", "next"])
    }

    // MARK: - Header tolerance

    func testHeaderNameCaseAndWhitespaceVariationAreAccepted() throws {
        var decoder = LSPFraming.Decoder()
        var chunk = Data("content-length:2\r\n\r\n{}".utf8)
        chunk.append(Data("CONTENT-LENGTH:   2  \r\n\r\n[]".utf8))
        chunk.append(Data("Content-Length \t: 2\r\n\r\n''".utf8))
        XCTAssertEqual(text(try decoder.append(chunk)), ["{}", "[]", "''"])
    }

    func testContentTypeAndUnknownHeadersAreIgnored() throws {
        var decoder = LSPFraming.Decoder()
        let header = "Content-Type: application/vscode-jsonrpc; charset=utf-8\r\n"
            + "X-Whatever: 1\r\n"
            + "Content-Length: 2\r\n\r\n{}"
        let chunk = Data(header.utf8)
        XCTAssertEqual(text(try decoder.append(chunk)), ["{}"])
    }

    // MARK: - Malformed headers poison the stream

    func testMissingContentLengthIsRejected() {
        var decoder = LSPFraming.Decoder()
        XCTAssertThrowsError(try decoder.append(Data("Content-Type: x\r\n\r\n{}".utf8))) {
            XCTAssertEqual($0 as? LSPFramingError, .missingContentLength)
        }
    }

    func testDuplicateContentLengthIsRejected() {
        var decoder = LSPFraming.Decoder()
        let chunk = Data("Content-Length: 2\r\nContent-Length: 3\r\n\r\n{}".utf8)
        XCTAssertThrowsError(try decoder.append(chunk)) {
            XCTAssertEqual($0 as? LSPFramingError, .duplicateContentLength)
        }
    }

    func testNonNumericContentLengthIsRejected() {
        var decoder = LSPFraming.Decoder()
        XCTAssertThrowsError(try decoder.append(Data("Content-Length: two\r\n\r\n{}".utf8))) {
            XCTAssertEqual($0 as? LSPFramingError, .invalidContentLength("two"))
        }
    }

    func testNegativeContentLengthIsRejected() {
        var decoder = LSPFraming.Decoder()
        XCTAssertThrowsError(try decoder.append(Data("Content-Length: -1\r\n\r\n{}".utf8))) {
            XCTAssertEqual($0 as? LSPFramingError, .invalidContentLength("-1"))
        }
    }

    func testHeaderLineWithoutAColonIsRejected() {
        var decoder = LSPFraming.Decoder()
        let chunk = Data("Content-Length: 2\r\nnonsense\r\n\r\n{}".utf8)
        XCTAssertThrowsError(try decoder.append(chunk)) {
            XCTAssertEqual($0 as? LSPFramingError, .malformedHeader("nonsense"))
        }
    }

    /// An absurd announced length must be refused *before* the buffer grows to
    /// meet it.
    func testAbsurdContentLengthIsRejectedByTheCap() {
        var decoder = LSPFraming.Decoder(maximumContentLength: 1024)
        XCTAssertThrowsError(try decoder.append(Data("Content-Length: 99999\r\n\r\n".utf8))) {
            XCTAssertEqual($0 as? LSPFramingError, .contentLengthTooLarge(99999))
        }
    }

    func testALengthAtTheCapIsAccepted() throws {
        var decoder = LSPFraming.Decoder(maximumContentLength: 2)
        XCTAssertEqual(text(try decoder.append(Data("Content-Length: 2\r\n\r\n{}".utf8))), ["{}"])
    }

    func testHeaderThatNeverTerminatesIsRejectedByTheCap() {
        var decoder = LSPFraming.Decoder(maximumHeaderLength: 32)
        XCTAssertThrowsError(try decoder.append(Data(String(repeating: "x", count: 33).utf8))) {
            XCTAssertEqual($0 as? LSPFramingError, .headerTooLarge(33))
        }
    }

    /// Resynchronising after a bad header would mean guessing where the next
    /// message starts, so the decoder refuses to try: it stays failed and keeps
    /// reporting the *first* error, whatever arrives later.
    func testAMalformedHeaderPoisonsTheStreamForGood() throws {
        var decoder = LSPFraming.Decoder()
        XCTAssertThrowsError(try decoder.append(Data("Content-Length: two\r\n\r\n{}".utf8)))
        XCTAssertTrue(decoder.isPoisoned)
        XCTAssertThrowsError(try decoder.append(framed("perfectly fine"))) {
            XCTAssertEqual($0 as? LSPFramingError, .invalidContentLength("two"))
        }
        XCTAssertThrowsError(try decoder.append(Data())) {
            XCTAssertEqual($0 as? LSPFramingError, .invalidContentLength("two"))
        }
    }
}
