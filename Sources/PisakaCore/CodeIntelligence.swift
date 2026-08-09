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
    /// The buffer edits `item` performs, for an item the provider deferred to a
    /// second round trip (`CompletionItem.resolveHandle`).
    ///
    /// Defaulted to "nothing to add" because it is meaningful for exactly one
    /// implementation: an LSP server may keep an item's `additionalTextEdits`
    /// back until the client asks for them (D4's auto-import), and every other
    /// provider hands out complete items the first time. The editor prefetches
    /// this in the background while the popup is open, so the answer is in hand
    /// before the user commits.
    ///
    /// An item the issuing provider does not recognise — a handle from a
    /// superseded list, or an item from a different provider — answers `[]`,
    /// which the caller reads as "insert the plain text and nothing else".
    func resolveEdits(for item: CompletionItem) async -> [CompletionEdit]
}

public extension CodeIntelligenceProviding {
    func resolveEdits(for item: CompletionItem) async -> [CompletionEdit] { [] }
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
    /// The buffer's *live* text, which an LSP provider must give the server
    /// before it can ask anything about `offset` (D2: document sync is
    /// request-driven, so the text travels with the question).
    ///
    /// Defaulted to `""` so no call site written before phase 2a breaks — which
    /// makes a *forgotten* call site the real hazard, since an empty buffer
    /// would clamp every position to `0:0` and answer confidently wrong. The
    /// LSP provider therefore treats "empty text, non-zero offset" as
    /// unanswerable and falls back rather than clamping (pinned by
    /// `LSPIntelligenceProviderTests`); the tree-sitter provider ignores the
    /// field entirely, since it looks names up in the index.
    public let text: String

    public init(identifier: String, fileURL: URL?, offset: Int, text: String = "") {
        self.identifier = identifier
        self.fileURL = fileURL
        self.offset = offset
        self.text = text
    }
}

/// One place the caret could jump to.
///
/// `relativePath` is precomputed rather than derived by the view: the picker
/// shows it, both platforms show the *same* string, and the project root is the
/// provider's knowledge, not the text view's.
///
/// **It stores what it displays and navigates by, not a `Symbol`** (D8). An LSP
/// `textDocument/definition` answer is a *location*: a file, a range and nothing
/// else — no declaration kind, because the server was asked "where", not "what".
/// Wrapping a `Symbol` would force one of two bad options: invent a synthetic
/// `SymbolKind` case for "the server did not say", which `SymbolQueryTests`
/// compares by set equality against the shipped queries and would fail, or lie
/// with an existing case. So `kind` is optional and the rest of the fields are
/// flat. `init(symbol:relativePath:)` is retained so every *construction* site —
/// the tree-sitter provider's included — is unchanged, and `displayLabel` is
/// byte-identical to what it produced before.
public struct DefinitionCandidate: Equatable, Sendable {
    /// The declared identifier, as the source spells it.
    public let name: String
    /// The enclosing type's name, when the answer carried one.
    public let containerName: String?
    /// What kind of declaration this is, or `nil` when the answer did not say —
    /// which is every LSP location. Ranking must therefore never *require* it.
    public let kind: SymbolKind?
    /// The declaring file.
    public let fileURL: URL
    /// UTF-16 range of the *name* within that file, so the jump lands the caret
    /// on the identifier rather than on the `func` keyword above it.
    public let range: NSRange
    /// 1-based display line of `range`, for the picker.
    public let line: Int
    /// The declaring file's path below the project root, or its file name when
    /// it lives outside (or there is no root).
    public let relativePath: String
    /// Whether the declaring file lives outside the opened folder — an SDK
    /// interface, a dependency checkout, a generated header.
    ///
    /// Carried on the candidate rather than recomputed by the view because the
    /// project root is the provider's knowledge (the same reason `relativePath`
    /// is precomputed), and because it decides *where the jump lands*: D3 opens
    /// an out-of-root target in a separate read-only window instead of a tab, so
    /// that a jump into the SDK structurally cannot write outside the root.
    ///
    /// Always `false` for a tree-sitter candidate: the index only ever walks the
    /// opened folder, so everything it can name is inside it.
    public let isOutsideProjectRoot: Bool

    public init(
        name: String,
        containerName: String? = nil,
        kind: SymbolKind? = nil,
        fileURL: URL,
        range: NSRange,
        line: Int,
        relativePath: String,
        isOutsideProjectRoot: Bool = false
    ) {
        self.name = name
        self.containerName = containerName
        self.kind = kind
        self.fileURL = fileURL
        self.range = range
        self.line = line
        self.relativePath = relativePath
        self.isOutsideProjectRoot = isOutsideProjectRoot
    }

    /// The tree-sitter path's spelling: everything a candidate shows comes from
    /// the indexed declaration.
    public init(symbol: Symbol, relativePath: String) {
        self.init(
            name: symbol.name,
            containerName: symbol.containerName,
            kind: symbol.kind,
            fileURL: symbol.fileURL,
            range: symbol.range,
            line: symbol.line,
            relativePath: relativePath
        )
    }

    /// `Container.name` when there is a container, the bare name otherwise —
    /// the same rule as `Symbol.qualifiedName`, which this used to borrow.
    public var qualifiedName: String {
        guard let containerName, !containerName.isEmpty else { return name }
        return containerName + "." + name
    }

    /// The row the macOS `NSMenu` and the iOS list show:
    /// `Container.name — src/Worker.swift:42`.
    public var displayLabel: String {
        "\(qualifiedName) — \(relativePath):\(line)"
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
    /// The language of the file being typed in, or `nil` when the editor has
    /// not resolved one (a url-less scratch buffer, a name no rule matches).
    ///
    /// Its only job is the keyword source: `nil` means *no keywords at all*
    /// rather than some default language's, because offering Swift's `guard`
    /// while typing in a file the editor could not classify is a worse answer
    /// than offering nothing. A language that has no list
    /// (`LanguageKeywords.languagesWithoutKeywords`) reaches the same outcome
    /// through the list itself.
    public let language: SyntaxLanguage?
    /// The member position the caret sits in, from
    /// `IdentifierScanner.memberContext(in:at:)`, or `nil` for ordinary
    /// identifier completion.
    ///
    /// Carried on the request rather than re-derived by the provider because
    /// the provider is given a prefix and a buffer, not a caret: the editor
    /// layer is the only place that knows where the caret is, and it already
    /// has to ask this question to decide whether to bypass its
    /// minimum-length trigger gate. Non-`nil` is also the one state in which
    /// `prefix` may legitimately be empty — see `SymbolIntelligenceProvider`.
    public let member: IdentifierScanner.MemberContext?
    /// The UTF-16 offset of the caret the request was made from — the end of
    /// `prefix`, so the typed word occupies
    /// `offset - prefix.utf16.count ..< offset`.
    ///
    /// `nil` means "the caller did not say where the caret is", which an LSP
    /// provider treats as **unanswerable** rather than guessing: a completion
    /// request is a question about a position, and there is no position here to
    /// derive from a prefix and a buffer that may contain it a hundred times.
    /// The tree-sitter provider ignores the field entirely — it matches names,
    /// not places — so a call site that predates phase 2a keeps meaning exactly
    /// what it meant, and only the LSP answer is given up.
    ///
    /// The same reasoning as `DefinitionRequest.text`, and the same hazard: both
    /// editor call sites pass it, and the guard above is what keeps a forgotten
    /// one from producing confidently wrong positions.
    public let offset: Int?

    /// `language` and `member` are defaulted: they are what phase 1.5 added,
    /// and defaulting them keeps every construction site that predates member
    /// completion — and every test that only cares about ranking — compiling
    /// and meaning exactly what it meant before.
    ///
    /// Note that this grew the *request*, not `CodeIntelligenceProviding`: the
    /// protocol still has the same two methods with the same shapes, so a
    /// phase-2 LSP provider implements the same contract and simply maps these
    /// two fields onto a completion-context parameter instead of onto an index
    /// lookup.
    public init(
        prefix: String,
        fileURL: URL?,
        text: String,
        language: SyntaxLanguage? = nil,
        member: IdentifierScanner.MemberContext? = nil,
        offset: Int? = nil
    ) {
        self.prefix = prefix
        self.fileURL = fileURL
        self.text = text
        self.language = language
        self.member = member
        self.offset = offset
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
    /// Every buffer edit committing this item performs, in buffer (UTF-16)
    /// coordinates — the primary replacement plus any auto-import (D4).
    ///
    /// Empty for a tree-sitter item, which is *only* `text` replacing the typed
    /// prefix and so is inserted by AppKit's own machinery. A non-empty list is
    /// the editor's signal to apply the item itself, through
    /// `CompletionEditPlan`, in one undo group.
    public let edits: [CompletionEdit]
    /// An opaque token identifying an item the server deferred to
    /// `completionItem/resolve`, or `nil` when the item is already complete.
    ///
    /// Opaque on purpose: the seam must not leak an `LSPCompletionItem` (Core's
    /// LSP types stay behind the provider), and the editor never interprets the
    /// number — it hands it straight back to the provider that issued it.
    public let resolveHandle: Int?

    /// `edits` and `resolveHandle` are defaulted so the tree-sitter provider and
    /// both iOS surfaces are untouched by phase 2a.
    public init(
        text: String,
        kind: SymbolKind?,
        isFromCurrentFile: Bool,
        edits: [CompletionEdit] = [],
        resolveHandle: Int? = nil
    ) {
        self.text = text
        self.kind = kind
        self.isFromCurrentFile = isFromCurrentFile
        self.edits = edits
        self.resolveHandle = resolveHandle
    }
}
