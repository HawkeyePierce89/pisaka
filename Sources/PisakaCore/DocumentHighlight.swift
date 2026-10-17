import Foundation

// MARK: - Occurrence highlighting (R2)

/// "Where else does this buffer use the name the caret is on?" — what the
/// occurrence highlight asks after a caret settle.
///
/// The **usages** question narrowed to one buffer: the same identifier, already
/// resolved by `IdentifierScanner`, and the same position, which is all a server
/// reads. A server is asked `textDocument/documentHighlight` about the position.
/// The textual fallback (`OccurrenceScan.identifierMatches`) searches for the
/// identifier in `text` under the language's boundary rule. Both answers are about
/// this one document and walk nothing else, which is why the second answer belongs
/// to a provider here, as folding's does, rather than to a model, as usages' does.
public struct DocumentHighlightRequest: Equatable, Sendable {
    /// The identifier under the caret, already resolved by `IdentifierScanner`.
    /// The fallback's search word. A server never reads it.
    public let identifier: String
    /// The file the caret is in, or `nil` for a url-less buffer. No server can
    /// answer for a url-less buffer, but the scan can.
    public let fileURL: URL?
    /// The UTF-16 offset of the identifier's **first character**, so the same word
    /// always asks the same question wherever in it the caret stood.
    public let offset: Int
    /// The buffer's *live* text (D2: sync is request-driven, so the text travels
    /// with the question). It is also the text the fallback scans, so both answers
    /// share one coordinate space.
    public let text: String
    /// The buffer's language as the editor resolved it. `nil` means "no
    /// language", which only the scan answers, under the default boundary rule.
    public let language: SyntaxLanguage?

    public init(
        identifier: String,
        fileURL: URL?,
        offset: Int,
        text: String,
        language: SyntaxLanguage?
    ) {
        self.identifier = identifier
        self.fileURL = fileURL
        self.offset = offset
        self.text = text
        self.language = language
    }
}

/// One whole answer to a `DocumentHighlightRequest`, and the source that gave it.
///
/// **Never a mixture** (D45). One source answers, whole, and says which one it
/// was. The two answers disagree by design: a server knows which `count` is which
/// and a whole-word scan does not. A merged list would paint the scan's wrong
/// guesses with the server's authority.
public struct DocumentHighlightAnswer: Equatable, Sendable {
    /// Which of the two sources answered.
    public enum Provenance: Equatable, Hashable, Sendable {
        /// The language server's `textDocument/documentHighlight`.
        case server
        /// `OccurrenceScan.identifierMatches` over the request's text.
        case textual
    }

    /// Whether an occurrence reads the symbol or writes it. LSP's `Text`, `Read`
    /// and an absent kind all read as `.read`. Only a server can name a write.
    public enum Kind: Equatable, Hashable, Sendable {
        case read
        case write
    }

    /// One painted range, in the request text's UTF-16 coordinates.
    public struct Highlight: Equatable, Hashable, Sendable {
        public let range: NSRange
        public let kind: Kind

        public init(range: NSRange, kind: Kind) {
            self.range = range
            self.kind = kind
        }
    }

    public let provenance: Provenance
    /// Ascending by location. Empty is a real answer only when the server gave
    /// it (see `RoutingIntelligenceProvider.documentHighlights(for:)`).
    public let highlights: [Highlight]

    public init(provenance: Provenance, highlights: [Highlight]) {
        self.provenance = provenance
        self.highlights = highlights
    }
}
