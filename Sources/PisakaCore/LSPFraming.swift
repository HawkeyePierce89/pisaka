import Foundation

/// LSP's base protocol framing: a `Content-Length` header block, `\r\n\r\n`, then
/// exactly that many bytes of JSON.
///
/// This is the whole bytes-in/bytes-out layer, with no LSP semantics in it: it
/// turns a payload into a framed message and an arbitrary stream of chunks back
/// into payloads. A pipe hands us whatever the kernel had ready — half a header,
/// three messages at once, one message in eleven reads — so the decoder is
/// incremental by construction and holds its own buffer.
///
/// **A framing error is terminal.** Once the header block cannot be read, there
/// is no way to know where the next message starts: resynchronising would mean
/// guessing, and a guess that lands mid-body feeds the JSON layer garbage that
/// looks like a real message. So the decoder poisons itself instead — every later
/// `append` rethrows the same error — and the session's answer is to tear the
/// process down and (per D7) restart it.
public enum LSPFraming {
    /// Refuse a `Content-Length` above this. A server that announces a gigabyte
    /// has gone wrong; without a cap we would sit and grow a buffer forever.
    public static let defaultMaximumContentLength = 64 * 1024 * 1024
    /// Refuse a header block that never terminates. Real header blocks are a few
    /// dozen bytes; this only fires on a peer that is not speaking LSP at all.
    public static let defaultMaximumHeaderLength = 8 * 1024

    private static let headerSeparator: [UInt8] = Array("\r\n\r\n".utf8)

    /// Frame one JSON payload for the wire.
    public static func encode(payload: Data) -> Data {
        var framed = Data("Content-Length: \(payload.count)\r\n\r\n".utf8)
        framed.append(payload)
        return framed
    }

    /// Frame one outgoing message.
    public static func encode(_ message: LSPOutgoingMessage) throws -> Data {
        encode(payload: try message.payload())
    }

    /// The incremental reader. A value type with a mutating `append`, so the
    /// transport owns exactly one and no lock is implied.
    public struct Decoder {
        public let maximumContentLength: Int
        public let maximumHeaderLength: Int

        private var bytes: [UInt8] = []
        /// A parsed header whose body has not fully arrived yet.
        private var pendingContentLength: Int?
        /// Set by the first malformed header; every later `append` rethrows it.
        private var failure: LSPFramingError?

        public init(
            maximumContentLength: Int = LSPFraming.defaultMaximumContentLength,
            maximumHeaderLength: Int = LSPFraming.defaultMaximumHeaderLength
        ) {
            self.maximumContentLength = maximumContentLength
            self.maximumHeaderLength = maximumHeaderLength
        }

        /// Whether a framing error has already poisoned this stream.
        public var isPoisoned: Bool { failure != nil }

        /// Feed the next chunk and take whatever messages completed — none, one,
        /// or several.
        ///
        /// On a malformed header this throws and the decoder is poisoned. Any
        /// payload decoded *earlier in the same chunk* is dropped with it: the
        /// caller's only response to a framing error is to kill the connection,
        /// so delivering a message and an unrecoverable error in one call would
        /// buy nothing and complicate every call site.
        public mutating func append(_ chunk: Data) throws -> [Data] {
            if let failure { throw failure }
            bytes.append(contentsOf: chunk)
            do {
                return try drain()
            } catch let error as LSPFramingError {
                failure = error
                bytes.removeAll()
                pendingContentLength = nil
                throw error
            }
        }

        private mutating func drain() throws -> [Data] {
            var payloads: [Data] = []
            while true {
                if let length = pendingContentLength {
                    guard bytes.count >= length else { break }
                    payloads.append(Data(bytes[0..<length]))
                    bytes.removeFirst(length)
                    pendingContentLength = nil
                    continue
                }
                guard let separator = indexOfHeaderSeparator() else {
                    guard bytes.count <= maximumHeaderLength else {
                        throw LSPFramingError.headerTooLarge(bytes.count)
                    }
                    break
                }
                let header = Array(bytes[0..<separator])
                bytes.removeFirst(separator + LSPFraming.headerSeparator.count)
                pendingContentLength = try Decoder.contentLength(
                    inHeader: header,
                    maximum: maximumContentLength
                )
            }
            return payloads
        }

        /// Offset of the `\r\n\r\n` that ends the header block, or `nil` while it
        /// has not arrived. The body is *not* scanned for it — the body is taken
        /// by length — so a payload containing `\r\n\r\n` is harmless.
        private func indexOfHeaderSeparator() -> Int? {
            let separator = LSPFraming.headerSeparator
            guard bytes.count >= separator.count else { return nil }
            for start in 0...(bytes.count - separator.count) {
                if bytes[start] == separator[0],
                   bytes[start + 1] == separator[1],
                   bytes[start + 2] == separator[2],
                   bytes[start + 3] == separator[3] {
                    return start
                }
            }
            return nil
        }

        /// Read the header block. Field names are case-insensitive and the value
        /// is whitespace-trimmed (both required by the base protocol);
        /// `Content-Type` — the one other header the spec defines — and anything
        /// else are ignored, because their absence changes nothing and their
        /// presence must not break us.
        static func contentLength(inHeader header: [UInt8], maximum: Int) throws -> Int {
            guard let text = String(bytes: header, encoding: .utf8) else {
                throw LSPFramingError.malformedHeader("<not UTF-8>")
            }
            var length: Int?
            for line in text.components(separatedBy: "\r\n") where !line.isEmpty {
                guard let colon = line.firstIndex(of: ":") else {
                    throw LSPFramingError.malformedHeader(line)
                }
                let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...]
                    .trimmingCharacters(in: .whitespaces)
                guard name == "content-length" else { continue }
                guard let parsed = Int(value), parsed >= 0 else {
                    throw LSPFramingError.invalidContentLength(value)
                }
                // Two lengths mean two different framings of the same bytes;
                // picking either one is a coin flip that desyncs the stream.
                guard length == nil else { throw LSPFramingError.duplicateContentLength }
                length = parsed
            }
            guard let length else { throw LSPFramingError.missingContentLength }
            guard length <= maximum else { throw LSPFramingError.contentLengthTooLarge(length) }
            return length
        }
    }
}

/// Why a byte stream stopped being readable as LSP.
public enum LSPFramingError: Error, Equatable, Hashable, Sendable {
    /// A header block with no `Content-Length` field.
    case missingContentLength
    /// Two `Content-Length` fields in one header block.
    case duplicateContentLength
    /// A `Content-Length` that is not a non-negative integer.
    case invalidContentLength(String)
    /// A `Content-Length` past the cap.
    case contentLengthTooLarge(Int)
    /// A header line with no `:`, or bytes that are not UTF-8.
    case malformedHeader(String)
    /// Bytes kept arriving without a `\r\n\r\n`.
    case headerTooLarge(Int)
}
