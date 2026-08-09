import XCTest
@testable import PisakaCore

/// JSON-RPC envelopes: what a message *is*, before anything knows what any LSP
/// method means. The interesting cases are all about faithfulness — a `null`
/// result that is not an absent result, an id we no longer recognise that must
/// still decode, an opaque `data` blob that must survive being carried back to
/// the server unchanged.
final class LSPMessageTests: XCTestCase {
    private func decode(_ json: String) throws -> LSPIncomingMessage {
        try LSPIncomingMessage.decode(Data(json.utf8))
    }

    private func encoded(_ message: LSPOutgoingMessage) throws -> String {
        String(decoding: try message.payload(), as: UTF8.self)
    }

    // MARK: - JSONValue

    func testJSONValueRoundTripsEveryShape() throws {
        let json = """
        {"n":null,"t":true,"i":-3,"d":1.5,"s":"x","a":[1,"two",[]],"o":{"k":{}}}
        """
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        XCTAssertEqual(value["n"], .null)
        XCTAssertEqual(value["t"], .bool(true))
        XCTAssertEqual(value["i"], .int(-3))
        XCTAssertEqual(value["d"], .double(1.5))
        XCTAssertEqual(value["s"], .string("x"))
        XCTAssertEqual(value["a"]?[1], .string("two"))
        XCTAssertEqual(value["o"], .object(["k": .object([:])]))

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let reEncoded = try encoder.encode(value)
        XCTAssertEqual(
            try JSONDecoder().decode(JSONValue.self, from: reEncoded),
            value
        )
    }

    /// `true` must not decode as the number 1: a server that reads
    /// `"dynamicRegistration": 1` sees a different capability than we advertised.
    func testBooleansDoNotCollapseIntoNumbers() throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data("[true,1]".utf8))
        XCTAssertEqual(value, .array([.bool(true), .int(1)]))
    }

    /// Integers stay integers through a round trip — a request id re-encoded as
    /// `1.0` fails to correlate on a strict server.
    func testIntegersDoNotBecomeDoublesThroughAReEncode() throws {
        let value = JSONValue.object(["id": .int(7)])
        let data = try JSONEncoder().encode(value)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"id":7}"#)
    }

    func testIntValueAcceptsAWholeDoubleButNotAFractionalOne() {
        XCTAssertEqual(JSONValue.double(3.0).intValue, 3)
        XCTAssertNil(JSONValue.double(3.5).intValue)
        XCTAssertNil(JSONValue.string("3").intValue)
    }

    func testTypedValuesProjectIntoJSONAndBack() throws {
        struct Position: Codable, Equatable {
            let line: Int
            let character: Int
        }
        let value = try JSONValue(encoding: Position(line: 4, character: 11))
        XCTAssertEqual(value, .object(["line": .int(4), "character": .int(11)]))
        XCTAssertEqual(try value.decoded(as: Position.self), Position(line: 4, character: 11))
    }

    func testLiteralsBuildTheSameValuesAsTheCases() {
        let literal: JSONValue = ["a": 1, "b": ["x", true, nil]]
        XCTAssertEqual(
            literal,
            .object(["a": .int(1), "b": .array([.string("x"), .bool(true), .null])])
        )
    }

    // MARK: - Request ids

    func testRequestIDDecodesBothNumbersAndStrings() throws {
        XCTAssertEqual(
            try JSONDecoder().decode([LSPRequestID].self, from: Data(#"[3,"abc"]"#.utf8)),
            [.number(3), .string("abc")]
        )
    }

    func testRequestIDReEncodesInTheFormItArrived() throws {
        let ids: [LSPRequestID] = [.number(3), .string("3")]
        let data = try JSONEncoder().encode(ids)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"[3,"3"]"#)
    }

    // MARK: - Outgoing envelopes

    func testOutgoingRequestCarriesTheProtocolVersion() throws {
        let message = LSPOutgoingMessage.request(
            LSPRequestMessage(id: .number(1), method: "shutdown")
        )
        XCTAssertEqual(try encoded(message), #"{"id":1,"jsonrpc":"2.0","method":"shutdown"}"#)
    }

    func testOutgoingNotificationHasNoID() throws {
        let message = LSPOutgoingMessage.notification(
            LSPNotificationMessage(method: "exit")
        )
        XCTAssertEqual(try encoded(message), #"{"jsonrpc":"2.0","method":"exit"}"#)
    }

    /// Our reply to a server-initiated request. `workspace/configuration` is
    /// answered with an array of nulls, so a `null` inside `result` has to
    /// survive encoding.
    func testOutgoingResponseEncodesNullsFaithfully() throws {
        let message = LSPOutgoingMessage.response(
            LSPResponseMessage(id: .number(9), result: .array([.null]))
        )
        XCTAssertEqual(try encoded(message), #"{"id":9,"jsonrpc":"2.0","result":[null]}"#)
    }

    func testOutgoingErrorResponseEncodesCodeAndMessage() throws {
        let message = LSPOutgoingMessage.response(
            LSPResponseMessage(
                id: .string("cfg"),
                error: LSPResponseError(code: .methodNotFound, message: "unsupported")
            )
        )
        XCTAssertEqual(
            try encoded(message),
            #"{"error":{"code":-32601,"message":"unsupported"},"id":"cfg","jsonrpc":"2.0"}"#
        )
    }

    /// A response to a message so broken its id could not be read is still a
    /// valid response — with an explicit `null` id, not a missing one.
    func testOutgoingResponseWritesAnExplicitNullID() throws {
        let message = LSPOutgoingMessage.response(
            LSPResponseMessage(id: nil, error: LSPResponseError(code: .parseError, message: "x"))
        )
        XCTAssertTrue(try encoded(message).contains(#""id":null"#))
    }

    // MARK: - Incoming discrimination

    func testAMessageWithMethodAndIDIsAServerRequest() throws {
        let message = try decode(
            #"{"jsonrpc":"2.0","id":4,"method":"workspace/configuration","params":{"items":[]}}"#
        )
        guard case .serverRequest(let request) = message else {
            return XCTFail("expected a server request, got \(message)")
        }
        XCTAssertEqual(request.id, .number(4))
        XCTAssertEqual(request.method, "workspace/configuration")
        XCTAssertEqual(request.params?["items"], .array([]))
    }

    func testAMessageWithMethodAndNoIDIsANotification() throws {
        let message = try decode(
            #"{"jsonrpc":"2.0","method":"window/logMessage","params":{"type":3,"message":"hi"}}"#
        )
        guard case .notification(let notification) = message else {
            return XCTFail("expected a notification, got \(message)")
        }
        XCTAssertEqual(notification.method, "window/logMessage")
        XCTAssertEqual(notification.params?["message"], .string("hi"))
    }

    /// A `null` id with a method is a notification, not a request with an
    /// unreadable id: answering it would put a reply on the wire nobody asked for.
    func testAMethodWithANullIDIsANotification() throws {
        let message = try decode(#"{"jsonrpc":"2.0","id":null,"method":"$/progress"}"#)
        guard case .notification(let notification) = message else {
            return XCTFail("expected a notification, got \(message)")
        }
        XCTAssertEqual(notification.method, "$/progress")
        XCTAssertNil(notification.params)
    }

    func testAMessageWithNeitherMethodNorIDIsRejected() {
        XCTAssertThrowsError(try decode(#"{"jsonrpc":"2.0","result":1}"#))
    }

    // MARK: - Incoming responses

    func testResponseWithAResultDecodes() throws {
        let message = try decode(#"{"jsonrpc":"2.0","id":2,"result":{"capabilities":{}}}"#)
        guard case .response(let response) = message else {
            return XCTFail("expected a response, got \(message)")
        }
        XCTAssertEqual(response.id, .number(2))
        XCTAssertEqual(response.result, .object(["capabilities": .object([:])]))
        XCTAssertNil(response.error)
    }

    /// `"result": null` is the answer to `shutdown` and to a definition request
    /// that found nothing — it must not read as "no result member", which is what
    /// a decode failure or a plain `decodeIfPresent` would make of it.
    func testANullResultIsPresentAndDistinctFromAnAbsentOne() throws {
        guard case .response(let withNull) = try decode(#"{"id":1,"result":null}"#),
              case .response(let without) = try decode(#"{"id":1,"error":{"code":1,"message":"e"}}"#)
        else { return XCTFail("expected responses") }
        XCTAssertEqual(withNull.result, .null)
        XCTAssertNotNil(withNull.result)
        XCTAssertNil(without.result)
    }

    func testANullResultReEncodesAsNull() throws {
        guard case .response(let response) = try decode(#"{"id":1,"result":null}"#) else {
            return XCTFail("expected a response")
        }
        let re = try encoded(.response(response))
        XCTAssertEqual(re, #"{"id":1,"jsonrpc":"2.0","result":null}"#)
    }

    func testErrorResponseDecodesCodeMessageAndData() throws {
        let json = """
        {"jsonrpc":"2.0","id":5,"error":{"code":-32602,"message":"bad params","data":{"why":"x"}}}
        """
        guard case .response(let response) = try decode(json) else {
            return XCTFail("expected a response")
        }
        XCTAssertEqual(response.error?.code, .invalidParams)
        XCTAssertEqual(response.error?.message, "bad params")
        XCTAssertEqual(response.error?.data, .object(["why": .string("x")]))
    }

    /// An unknown code round-trips rather than failing to decode: the wire is not
    /// a closed set, and a code we have never seen is still an error we must
    /// report to the awaiting caller.
    func testAnUnknownErrorCodeSurvives() throws {
        guard case .response(let response) =
                try decode(#"{"id":5,"error":{"code":-12345,"message":"?"}}"#)
        else { return XCTFail("expected a response") }
        XCTAssertEqual(response.error?.code, LSPErrorCode(rawValue: -12345))
    }

    /// Responses may come back in any order and may name an id we already gave
    /// up on (a timed-out request). Both decode faithfully; correlating them —
    /// and dropping the stranger — is the session's job, not the envelope's.
    func testOutOfOrderAndUnknownIDResponsesDecodeFaithfully() throws {
        let ids = try [
            #"{"id":7,"result":1}"#,
            #"{"id":3,"result":2}"#,
            #"{"id":"never-sent","result":3}"#,
        ].map { json -> LSPRequestID? in
            guard case .response(let response) = try decode(json) else { return nil }
            return response.id
        }
        XCTAssertEqual(ids, [.number(7), .number(3), .string("never-sent")])
    }

    /// Completion items carry an opaque `data` blob that `completionItem/resolve`
    /// must receive back byte-for-byte in meaning; carrying it as `JSONValue` is
    /// what makes that possible without knowing sourcekit-lsp's schema.
    func testOpaqueDataSurvivesADecodeReEncodeRoundTrip() throws {
        let json = #"{"id":1,"result":{"data":{"key":[1,{"nested":null}],"v":2.5}}}"#
        guard case .response(let response) = try decode(json) else {
            return XCTFail("expected a response")
        }
        let re = try encoded(.response(response))
        guard case .response(let again) = try decode(re) else {
            return XCTFail("expected a response")
        }
        XCTAssertEqual(again.result, response.result)
    }

    func testAResponseMissingJSONRPCStillDecodes() throws {
        guard case .response(let response) = try decode(#"{"id":1,"result":true}"#) else {
            return XCTFail("expected a response")
        }
        XCTAssertEqual(response.jsonrpc, "2.0")
    }
}
