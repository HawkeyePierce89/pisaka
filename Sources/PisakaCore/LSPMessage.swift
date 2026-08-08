import Foundation

/// JSON-RPC 2.0 envelopes — the *only* thing this file knows about LSP.
///
/// Phase 2a puts a Language Server Protocol client behind
/// `CodeIntelligenceProviding`, and the whole protocol stack lives in Core so it
/// is Foundation-only and unit-tested; the process and its pipes live macOS-gated
/// in the app (the `GitCLIService` split). This file is the bottom of that stack
/// together with `LSPFraming`: values that say *what a message is*, with no
/// opinion at all about what any particular method means. LSP's own bodies
/// (`initialize`, `textDocument/definition`, …) are typed one layer up.
///
/// Everything here is a value type: a message is data, so it can be built on any
/// actor, compared in a test, and handed across a `Sendable` boundary without a
/// lock.

// MARK: - Any-JSON value

/// A decoded JSON value of unknown shape.
///
/// LSP is a moving target: a server may answer `textDocument/definition` with a
/// `Location`, an array of them, or an array of `LocationLink`s, and it attaches
/// opaque `data` to completion items that must be echoed back verbatim on
/// `completionItem/resolve`. Both need a value that survives a decode/re-encode
/// round trip without knowing its schema, which is what this is: parse once at
/// the envelope boundary, re-interpret with `decoded(as:)` where the schema *is*
/// known, and carry the rest untouched.
///
/// `int` and `double` are separate cases on purpose. JSON has one number type,
/// but LSP request ids and character offsets are integers, and re-encoding
/// `1` as `1.0` makes a response fail to correlate on a strict server.
public enum JSONValue: Equatable, Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: Codable {
    public init(from decoder: Swift.Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            // Before `Int`: `true` must not become `1`.
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Value is not valid JSON"
            )
        }
    }

    public func encode(to encoder: Swift.Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

extension JSONValue {
    /// Project an `Encodable` (a typed LSP params struct) into an any-JSON value.
    ///
    /// Encoded inside a one-element array rather than on its own because a
    /// top-level JSON *fragment* (a bare string or number) is not encodable by
    /// every Foundation version this ships against; an array always is, and the
    /// wrapper costs two bytes that never leave this function.
    public init<T: Encodable>(encoding value: T) throws {
        let data = try JSONEncoder().encode([value])
        let values = try JSONDecoder().decode([JSONValue].self, from: data)
        guard let first = values.first else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "Encoded value vanished")
            )
        }
        self = first
    }

    /// Re-interpret this value as a typed one — how a decoded `result` becomes an
    /// LSP response body.
    public func decoded<T: Decodable>(as type: T.Type) throws -> T {
        let data = try JSONEncoder().encode([self])
        let values = try JSONDecoder().decode([T].self, from: data)
        guard let first = values.first else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "Decoded value vanished")
            )
        }
        return first
    }

    public var isNull: Bool { self == .null }
    public var boolValue: Bool? { if case .bool(let value) = self { return value }; return nil }
    public var stringValue: String? { if case .string(let value) = self { return value }; return nil }
    public var arrayValue: [JSONValue]? { if case .array(let value) = self { return value }; return nil }
    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    /// An integer, accepting a whole `double` too: a server is free to write
    /// `3.0` where the spec says `uinteger`.
    public var intValue: Int? {
        switch self {
        case .int(let value): return value
        case .double(let value) where value == value.rounded() && value.magnitude < 9.0e15:
            return Int(value)
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .int(let value): return Double(value)
        case .double(let value): return value
        default: return nil
        }
    }

    public subscript(key: String) -> JSONValue? { objectValue?[key] }

    public subscript(index: Int) -> JSONValue? {
        guard let array = arrayValue, array.indices.contains(index) else { return nil }
        return array[index]
    }
}

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral,
                     ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
                     ExpressibleByStringLiteral, ExpressibleByArrayLiteral,
                     ExpressibleByDictionaryLiteral {
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

// MARK: - Request ids

/// A JSON-RPC request id: an integer or a string.
///
/// This client only ever *sends* integers (`LSPSession` counts up), but a server
/// may send either in a server-initiated request, and the reply must echo the id
/// back in the form it arrived — so the type has to carry both.
public enum LSPRequestID: Equatable, Hashable, Sendable {
    case number(Int)
    case string(String)
}

extension LSPRequestID: Codable {
    public init(from decoder: Swift.Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Request id is neither a number nor a string"
            )
        }
    }

    public func encode(to encoder: Swift.Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        }
    }
}

extension LSPRequestID: CustomStringConvertible {
    public var description: String {
        switch self {
        case .number(let value): return String(value)
        case .string(let value): return value
        }
    }
}

// MARK: - Errors

/// A JSON-RPC / LSP error code.
///
/// A struct rather than an enum because the wire is not a closed set: a server
/// may answer with a code no version of the spec lists, and an unknown code must
/// round-trip rather than fail to decode.
public struct LSPErrorCode: RawRepresentable, Equatable, Hashable, Sendable, Codable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    // JSON-RPC
    public static let parseError = LSPErrorCode(rawValue: -32700)
    public static let invalidRequest = LSPErrorCode(rawValue: -32600)
    public static let methodNotFound = LSPErrorCode(rawValue: -32601)
    public static let invalidParams = LSPErrorCode(rawValue: -32602)
    public static let internalError = LSPErrorCode(rawValue: -32603)

    // LSP
    public static let serverNotInitialized = LSPErrorCode(rawValue: -32002)
    public static let unknownErrorCode = LSPErrorCode(rawValue: -32001)
    public static let requestFailed = LSPErrorCode(rawValue: -32803)
    public static let serverCancelled = LSPErrorCode(rawValue: -32802)
    public static let contentModified = LSPErrorCode(rawValue: -32801)
    public static let requestCancelled = LSPErrorCode(rawValue: -32800)
}

/// The `error` member of a response. Conforms to `Error` so the session can
/// throw a server's refusal straight to the awaiting caller.
public struct LSPResponseError: Error, Equatable, Hashable, Sendable, Codable {
    public let code: LSPErrorCode
    public let message: String
    public let data: JSONValue?

    public init(code: LSPErrorCode, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    private enum CodingKeys: String, CodingKey { case code, message, data }

    public init(from decoder: Swift.Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decode(LSPErrorCode.self, forKey: .code)
        // Tolerated absent: a server that omits `message` is malformed, but
        // dropping the whole response over it would turn a bad error into a
        // decode failure the caller cannot read at all.
        message = try container.decodeIfPresent(String.self, forKey: .message) ?? ""
        data = try container.decodeOptionalJSON(forKey: .data)
    }

    public func encode(to encoder: Swift.Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(code, forKey: .code)
        try container.encode(message, forKey: .message)
        try container.encodeOptionalJSON(data, forKey: .data)
    }
}

// MARK: - Envelopes

public enum LSPMessage {
    public static let jsonrpcVersion = "2.0"

    /// The encoder every outgoing message goes through.
    ///
    /// `sortedKeys` so a produced payload is byte-stable (tests assert on bytes,
    /// and a stable payload makes a recorded transcript diffable);
    /// `withoutEscapingSlashes` so a `file:///…` URI stays readable in a log.
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

/// A request — a message that expects exactly one response with the same id.
/// Sent by us (`textDocument/definition`) and received from the server
/// (`workspace/configuration`), which is why one type serves both directions.
public struct LSPRequestMessage: Equatable, Hashable, Sendable, Codable {
    public let jsonrpc: String
    public let id: LSPRequestID
    public let method: String
    public let params: JSONValue?

    public init(id: LSPRequestID, method: String, params: JSONValue? = nil) {
        self.jsonrpc = LSPMessage.jsonrpcVersion
        self.id = id
        self.method = method
        self.params = params
    }

    private enum CodingKeys: String, CodingKey { case jsonrpc, id, method, params }

    public init(from decoder: Swift.Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        jsonrpc = try container.decodeIfPresent(String.self, forKey: .jsonrpc)
            ?? LSPMessage.jsonrpcVersion
        id = try container.decode(LSPRequestID.self, forKey: .id)
        method = try container.decode(String.self, forKey: .method)
        params = try container.decodeOptionalJSON(forKey: .params)
    }

    public func encode(to encoder: Swift.Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(jsonrpc, forKey: .jsonrpc)
        try container.encode(id, forKey: .id)
        try container.encode(method, forKey: .method)
        try container.encodeOptionalJSON(params, forKey: .params)
    }
}

/// A notification — fire and forget, no id, no reply. `textDocument/didChange`
/// going out, `window/logMessage` coming in.
public struct LSPNotificationMessage: Equatable, Hashable, Sendable, Codable {
    public let jsonrpc: String
    public let method: String
    public let params: JSONValue?

    public init(method: String, params: JSONValue? = nil) {
        self.jsonrpc = LSPMessage.jsonrpcVersion
        self.method = method
        self.params = params
    }

    private enum CodingKeys: String, CodingKey { case jsonrpc, method, params }

    public init(from decoder: Swift.Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        jsonrpc = try container.decodeIfPresent(String.self, forKey: .jsonrpc)
            ?? LSPMessage.jsonrpcVersion
        method = try container.decode(String.self, forKey: .method)
        params = try container.decodeOptionalJSON(forKey: .params)
    }

    public func encode(to encoder: Swift.Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(jsonrpc, forKey: .jsonrpc)
        try container.encode(method, forKey: .method)
        try container.encodeOptionalJSON(params, forKey: .params)
    }
}

/// A response — the answer to a request, ours or the server's.
///
/// `id` is optional because JSON-RPC says a message that could not even be
/// parsed is answered with `"id": null`; `result` and `error` are both optional
/// and both preserved *as written*, so a legitimate `"result": null` (the answer
/// to `shutdown`, and to a definition request that found nothing) is
/// distinguishable from a response that carried no `result` member at all.
public struct LSPResponseMessage: Equatable, Hashable, Sendable, Codable {
    public let jsonrpc: String
    public let id: LSPRequestID?
    public let result: JSONValue?
    public let error: LSPResponseError?

    public init(id: LSPRequestID?, result: JSONValue? = nil, error: LSPResponseError? = nil) {
        self.jsonrpc = LSPMessage.jsonrpcVersion
        self.id = id
        self.result = result
        self.error = error
    }

    private enum CodingKeys: String, CodingKey { case jsonrpc, id, result, error }

    public init(from decoder: Swift.Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        jsonrpc = try container.decodeIfPresent(String.self, forKey: .jsonrpc)
            ?? LSPMessage.jsonrpcVersion
        if container.contains(.id), try !container.decodeNil(forKey: .id) {
            id = try container.decode(LSPRequestID.self, forKey: .id)
        } else {
            id = nil
        }
        result = try container.decodeOptionalJSON(forKey: .result)
        if container.contains(.error), try !container.decodeNil(forKey: .error) {
            error = try container.decode(LSPResponseError.self, forKey: .error)
        } else {
            error = nil
        }
    }

    public func encode(to encoder: Swift.Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(jsonrpc, forKey: .jsonrpc)
        // `id` is written even when nil — a response without an id member is not
        // a valid JSON-RPC response.
        if let id {
            try container.encode(id, forKey: .id)
        } else {
            try container.encodeNil(forKey: .id)
        }
        try container.encodeOptionalJSON(result, forKey: .result)
        if let error {
            try container.encode(error, forKey: .error)
        }
    }
}

/// Anything we can put on the wire.
public enum LSPOutgoingMessage: Equatable, Hashable, Sendable, Encodable {
    case request(LSPRequestMessage)
    case notification(LSPNotificationMessage)
    case response(LSPResponseMessage)

    public func encode(to encoder: Swift.Encoder) throws {
        switch self {
        case .request(let message): try message.encode(to: encoder)
        case .notification(let message): try message.encode(to: encoder)
        case .response(let message): try message.encode(to: encoder)
        }
    }

    /// The JSON body, ready for `LSPFraming.encode(payload:)`.
    public func payload() throws -> Data {
        try LSPMessage.encoder().encode(self)
    }
}

/// Anything the peer can hand us, resolved to exactly one case.
///
/// The discrimination is the spec's: `method` present with an id is a
/// server-initiated *request* (it wants an answer); `method` without one is a
/// *notification* (it does not); no `method` at all is a *response* to something
/// we sent — including one whose id we no longer recognise, which decodes
/// faithfully here and is dropped a layer up rather than being a parse failure.
public enum LSPIncomingMessage: Equatable, Hashable, Sendable, Decodable {
    case response(LSPResponseMessage)
    case notification(LSPNotificationMessage)
    case serverRequest(LSPRequestMessage)

    private enum ProbeKeys: String, CodingKey { case id, method }

    public init(from decoder: Swift.Decoder) throws {
        let probe = try decoder.container(keyedBy: ProbeKeys.self)
        let hasMethod = probe.contains(.method)
        var hasID = false
        if probe.contains(.id) {
            hasID = try !probe.decodeNil(forKey: .id)
        }
        switch (hasMethod, hasID) {
        case (true, true):
            self = .serverRequest(try LSPRequestMessage(from: decoder))
        case (true, false):
            self = .notification(try LSPNotificationMessage(from: decoder))
        case (false, _):
            guard probe.contains(.id) else {
                throw DecodingError.dataCorrupted(
                    .init(
                        codingPath: decoder.codingPath,
                        debugDescription: "Message has neither `method` nor `id`"
                    )
                )
            }
            self = .response(try LSPResponseMessage(from: decoder))
        }
    }

    /// Decode one framed payload.
    public static func decode(_ payload: Data) throws -> LSPIncomingMessage {
        try JSONDecoder().decode(LSPIncomingMessage.self, from: payload)
    }
}

// MARK: - `null` versus absent

/// A JSON `null` and an absent member mean different things in LSP responses, and
/// `decodeIfPresent`/`encodeIfPresent` collapse them into one. These two helpers
/// keep the distinction: a present `null` decodes to `.null` and re-encodes as
/// `null`; an absent member decodes to `nil` and is not written at all.
private extension KeyedDecodingContainer {
    func decodeOptionalJSON(forKey key: Key) throws -> JSONValue? {
        guard contains(key) else { return nil }
        if try decodeNil(forKey: key) { return .null }
        return try decode(JSONValue.self, forKey: key)
    }
}

private extension KeyedEncodingContainer {
    mutating func encodeOptionalJSON(_ value: JSONValue?, forKey key: Key) throws {
        guard let value else { return }
        if value == .null {
            try encodeNil(forKey: key)
        } else {
            try encode(value, forKey: key)
        }
    }
}
