import Foundation

/// The seam between the editor surfaces and whatever knows about code.
///
/// Phase 1 answers from a tree-sitter symbol index
/// (`SymbolIntelligenceProvider`); a later phase can answer from a language
/// server on macOS. Everything the UI needs is in this file — the two questions,
/// their requests and their results — so the platform layers depend on *this*
/// and never on the index, and swapping the implementation is a construction
/// change rather than a UI rewrite.
///
/// **Async by design, even though phase 1 is synchronous.** An LSP provider must
/// await a socket, so the protocol has to be async from the start: retrofitting
/// it later would touch every call site in both platform layers — exactly the
/// churn this seam exists to prevent. The cost today is one suspension point on
/// a value the provider already has, which is also what lets the macOS
/// completion controller compute candidates *before* AppKit's synchronous
/// delegate asks for them (see `CompletionItem`).
///
/// Foundation-only value types throughout: no `NSTextView`, no `UITextView`, no
/// tree-sitter — so every ranking rule stays unit-testable in Core.
public protocol CodeIntelligenceProviding: AnyObject {
    /// Declarations matching the identifier in `request`, best first.
    func definitions(for request: DefinitionRequest) async -> [DefinitionCandidate]
    /// Completion candidates for the prefix in `request`, best first, already
    /// capped by the provider.
    func completions(for request: CompletionRequest) async -> [CompletionItem]
}

// MARK: - Go to definition

/// "Where is this name declared?" — what a ⌘-click, a ⌃⌘J or an iOS edit-menu
/// action asks.
public struct DefinitionRequest: Equatable, Sendable {
    /// The identifier under the caret/click, already resolved by
    /// `IdentifierScanner` so the provider never re-parses text.
    public let identifier: String
    /// The file the question was asked from, or `nil` for a url-less buffer.
    /// Used to rank a declaration in the current file first — the same file is
    /// overwhelmingly the likely target for a local helper.
    public let fileURL: URL?
    /// The UTF-16 offset of the identifier's **first character** in that file —
    /// the resolved word's start, not the raw caret position it was resolved from
    /// (a ⌘-click lands mid-word, and ⌃⌘J fires with the caret just past the last
    /// character), so the same click always yields the same offset.
    ///
    /// Unused by phase 1's name-based lookup and carried anyway: it is the one
    /// piece of context an LSP `textDocument/definition` request cannot be built
    /// without, and adding it later would change every call site.
    public let offset: Int

    public init(identifier: String, fileURL: URL?, offset: Int) {
        self.identifier = identifier
        self.fileURL = fileURL
        self.offset = offset
    }
}

/// One place the caret could jump to.
///
/// `relativePath` is precomputed rather than derived by the view: the picker
/// shows it, both platforms show the *same* string, and the project root is the
/// provider's knowledge, not the text view's.
public struct DefinitionCandidate: Equatable, Sendable {
    /// The declaration itself — `range` is the name node, so the jump lands on
    /// the identifier (see `Symbol`).
    public let symbol: Symbol
    /// The declaring file's path below the project root, or its file name when
    /// it lives outside (or there is no root).
    public let relativePath: String

    public init(symbol: Symbol, relativePath: String) {
        self.symbol = symbol
        self.relativePath = relativePath
    }

    /// The row the macOS `NSMenu` and the iOS list show:
    /// `Container.name — src/Worker.swift:42`.
    public var displayLabel: String {
        "\(symbol.qualifiedName) — \(relativePath):\(symbol.line)"
    }
}

// MARK: - Completion

/// "What could this partial word become?" — what the debounced completion
/// controllers ask on both platforms.
public struct CompletionRequest: Equatable, Sendable {
    /// The partial word to the left of the caret, from
    /// `IdentifierScanner.completionPrefixRange(in:at:)`.
    public let prefix: String
    /// The file being typed in, or `nil` for a url-less buffer; ranks its own
    /// symbols first.
    public let fileURL: URL?
    /// The buffer's *live* text, which the provider harvests words from.
    ///
    /// Passed in rather than read from a model on purpose: the buffer being
    /// typed in is always ahead of the index (the re-index debounce has not
    /// fired yet), and a name the user typed thirty seconds ago must still be
    /// completable. This is also what makes a language with no `symbols.scm`
    /// degrade to word completion instead of to nothing.
    public let text: String

    public init(prefix: String, fileURL: URL?, text: String) {
        self.prefix = prefix
        self.fileURL = fileURL
        self.text = text
    }
}

/// One offer in the completion list.
///
/// Deliberately just a string plus two ranking facts: AppKit's stock completion
/// popup shows strings only (Decision 2), and the iOS accessory strip shows
/// buttons. `kind` and `isFromCurrentFile` exist so the *provider's* ranking is
/// testable and so a later, richer popup has the data it needs without changing
/// the seam.
public struct CompletionItem: Equatable, Hashable, Sendable {
    /// The text inserted in place of the typed prefix.
    public let text: String
    /// The declaration kind, or `nil` for a bare word harvested from the buffer
    /// — the flag that ranks known symbols above guesses.
    public let kind: SymbolKind?
    /// Whether this came from the file being edited.
    public let isFromCurrentFile: Bool

    public init(text: String, kind: SymbolKind?, isFromCurrentFile: Bool) {
        self.text = text
        self.kind = kind
        self.isFromCurrentFile = isFromCurrentFile
    }
}
