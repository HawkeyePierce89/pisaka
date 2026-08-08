import Foundation

/// A semantic class of *declaration*, resolved from a tree-sitter capture name
/// in a `symbols.scm` query.
///
/// Pure, UI-free semantic type (no Neon/SwiftTreeSitter/AppKit), mirroring
/// `SyntaxTokenKind`'s role for highlighting — with one deliberate difference:
/// `SyntaxTokenKind(captureName:)` *degrades* an unknown name to `.plain`,
/// because mis-coloring one token is harmless, while this initializer is
/// **failable and strict**. A symbol carries a name, a jump target and a place
/// in the completion list, so an unrecognized capture must be *dropped* rather
/// than filed under a plausible-looking kind: a typo in a query would otherwise
/// inject garbage entries into go-to-definition and autocompletion, where they
/// are far more visible than a mis-colored word.
///
/// The set is closed on purpose: it covers exactly what the queries can actually
/// distinguish across the supported languages, and nothing speculative.
/// `SymbolQueryTests` asserts by *set equality* that the capture names the
/// shipped queries emit are exactly the ones this enum resolves, so a query that
/// gains a capture fails the suite until a case is added here.
public enum SymbolKind: String, CaseIterable, Equatable, Hashable, Sendable {
    /// A named type: class, struct, enum, protocol, interface, type alias.
    case type
    /// A free function (not attached to a type).
    case function
    /// A function attached to a type (method, initializer, accessor).
    case method
    /// A stored or computed member of a type.
    case property
    /// An immutable binding (`let`, `const`, `#define`-like).
    case constant
    /// A mutable binding (`var`, `let` in JS, an assignment target).
    case variable
    /// A Markdown heading.
    case heading
    /// A CSS selector.
    case selector
    /// A top-level YAML/JSON key.
    case key
    /// A Dockerfile build stage (`FROM … AS name`).
    case stage
    /// A name another part of the document refers back to: an HTML `id`
    /// attribute value, or a YAML anchor (`&name`, the target of a `*ref`).
    case anchor

    /// The capture-name prefix every `symbols.scm` capture carries.
    ///
    /// Queries spell captures `@definition.<kind>` so a reader of a query can
    /// tell a *kind* capture from the auxiliary `@container` capture at a
    /// glance, and so the two namespaces cannot collide as the set grows.
    public static let capturePrefix = "definition."

    /// The capture name a query must spell to produce this kind.
    public var captureName: String { SymbolKind.capturePrefix + rawValue }

    /// The auxiliary capture that names the enclosing type in the same *match*.
    /// It is not a kind, so `init?(captureName:)` deliberately rejects it.
    public static let containerCaptureName = "container"

    /// Resolve a kind from a tree-sitter capture name, or `nil` when the name is
    /// not one this enum defines.
    ///
    /// A leading `@` or `.` (as some grammars and hand-written queries spell it)
    /// is ignored, and the `definition.` prefix is optional so the bare kind name
    /// resolves too. Matching is otherwise **exact**: there is no longest-prefix
    /// degradation, because a partially-recognized capture (`definition.type.foo`)
    /// is a query bug, and the only safe reading of a query bug is "emit no
    /// symbol".
    public init?(captureName: String) {
        var name = String(captureName.drop { $0 == "@" || $0 == "." })
        if name.hasPrefix(SymbolKind.capturePrefix) {
            name.removeFirst(SymbolKind.capturePrefix.count)
        }
        guard let kind = SymbolKind(rawValue: name) else { return nil }
        self = kind
    }
}

/// One declaration found in one file: what the index stores, what
/// go-to-definition jumps to, and what autocompletion offers.
///
/// `range` is the range of the **name node**, not of the whole declaration, so a
/// jump lands the caret on the identifier itself rather than on the `func`
/// keyword or an attribute list above it — the same thing Find in Files does
/// with a match range, and the reason both can share `EditorRevealState`.
/// Offsets are UTF-16 (`NSRange`), the editor's own coordinate space, so no
/// conversion happens between the extractor and the text view.
///
/// `line` is 1-based and precomputed at extraction time: the picker shows it,
/// and recomputing it later would mean re-reading the file the symbol came from.
public struct Symbol: Equatable, Hashable, Sendable {
    /// The declared identifier, exactly as written in the source.
    public let name: String
    /// What kind of declaration this is.
    public let kind: SymbolKind
    /// UTF-16 range of the *name* node within its file's text.
    public let range: NSRange
    /// The file the declaration lives in, spelled as the traversal found it.
    public let fileURL: URL
    /// The enclosing type's name, when the query paired one with this match.
    public let containerName: String?
    /// 1-based line of the name node, for display in the definition picker.
    public let line: Int

    public init(
        name: String,
        kind: SymbolKind,
        range: NSRange,
        fileURL: URL,
        containerName: String? = nil,
        line: Int
    ) {
        self.name = name
        self.kind = kind
        self.range = range
        self.fileURL = fileURL
        self.containerName = containerName
        self.line = line
    }

    /// `Container.name` when the symbol has a container, the bare name otherwise
    /// — the label the definition picker leads each row with.
    public var qualifiedName: String {
        guard let containerName, !containerName.isEmpty else { return name }
        return containerName + "." + name
    }
}
