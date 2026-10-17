#if os(macOS)
import Foundation
import SwiftTreeSitter
import PisakaCore

/// The editor's on-demand syntax tree for the buffer on screen: the whole text
/// parsed with the language's **root** grammar, off the main actor, cached
/// until the next edit.
///
/// It exists for the structural features that ask *where the caret is in the
/// tree* — the matching-tag highlight (R5) and Expand / Shrink Selection (R6),
/// which share one instance per editor — and is deliberately not Neon's tree,
/// which is incremental, visible-range driven and owned by the highlighter.
/// Injected languages are not consulted: a tag inside a Markdown fence is not
/// a tag of the Markdown file.
///
/// **Cache.** One tree, keyed by `(fileID, edit generation, language)`. The
/// coordinator calls `noteEdit()` from the text storage's edit notification,
/// which bumps the edit generation and drops the tree, so a cached tree always
/// describes the text it was parsed from — the key is an O(1) identity, for the
/// reason `BracketHighlightController.CacheKey` states.
///
/// **Ordering.** Every caller reads `editGeneration` in the same synchronous
/// step as the text it hands over, and passes it as the parse's token: a caller
/// that hops into a `Task` before asking would otherwise stamp the pre-edit text
/// with a post-edit generation and cache it as the new buffer's tree. A request
/// whose token an edit or a reset superseded — before the parse or during it —
/// returns `nil` and caches nothing, so a caller never receives a tree for a
/// buffer the editor is no longer showing. Two consumers asking about the same
/// text do not supersede each other: both answers describe the buffer.
///
/// **Parsing** follows `SymbolExtractor` / `MinimapTokenizer`: every parse
/// builds its own private `Parser`, so concurrent parses never share one.
/// `Tree` is `Sendable` and immutable, so the result is read on the main actor.
@MainActor
final class SyntaxTreeSnapshot {
    private struct CacheKey: Equatable {
        let fileID: UUID
        let editGeneration: Int
        let language: SyntaxLanguage
    }

    /// Bumped by every character edit and reset: what invalidates the cache,
    /// and the token that discards a superseded parse's result.
    private(set) var editGeneration = 0

    private var cachedKey: CacheKey?
    private var cachedTree: Tree?

    /// How many parses actually ran. `internal` for the app-layer test, which
    /// asserts a second ask of an unchanged buffer is served from the cache.
    private(set) var parseCount = 0

    /// The tree for `text`, parsed off the main actor, or the cached one when
    /// the key matches. `generation` is `editGeneration` as read together with
    /// `text`. `nil` for a language with no grammar, a parse failure, or a
    /// request superseded before or while it was in flight.
    func tree(text: String, language: SyntaxLanguage, fileID: UUID, generation token: Int) async -> Tree? {
        guard token == editGeneration else { return nil }
        let key = CacheKey(fileID: fileID, editGeneration: token, language: language)
        if key == cachedKey, let cachedTree { return cachedTree }

        parseCount += 1
        let tree = await Self.parseOffMain(text: text, language: language)
        guard token == editGeneration else { return nil }
        cachedKey = key
        cachedTree = tree
        return tree
    }

    /// The cached tree, if it still describes `fileID`'s current text in
    /// `language`; never parses.
    func cached(language: SyntaxLanguage, fileID: UUID) -> Tree? {
        let key = CacheKey(fileID: fileID, editGeneration: editGeneration, language: language)
        return key == cachedKey ? cachedTree : nil
    }

    /// A character edit landed: the cached tree no longer describes the buffer,
    /// and a parse in flight is of the pre-edit text.
    func noteEdit() {
        editGeneration &+= 1
        cachedKey = nil
        cachedTree = nil
    }

    /// A tab switch or teardown: nothing cached or in flight survives.
    func reset() {
        noteEdit()
    }

    /// The pure parse, run on the cooperative pool.
    private nonisolated static func parseOffMain(text: String, language: SyntaxLanguage) async -> Tree? {
        await Task.detached(priority: .userInitiated) {
            parse(text: text, language: language)
        }.value
    }

    /// Parse `text` with `language`'s root grammar through a private `Parser`.
    nonisolated static func parse(text: String, language: SyntaxLanguage) -> Tree? {
        guard let configuration = SyntaxLanguageConfiguration.configuration(for: language) else { return nil }
        let parser = Parser()
        do {
            try parser.setLanguage(configuration.language)
        } catch {
            return nil
        }
        return parser.parse(text)?.copy()
    }
}

/// Reads the markup elements enclosing an offset off a syntax tree, as
/// `TagMatchRule` takes them (R5). Every decision about what to highlight is
/// the rule's; this only maps grammar node types onto `TagElement`.
///
/// - **JSX** (`.javascript`, which covers `.jsx`, and `.tsx`): `jsx_element`
///   with its `open_tag`/`close_tag` fields and their `name` fields, and
///   `jsx_self_closing_element`. A nameless opening or closing element is a
///   fragment, whose names are its `<>` and `</>` ranges.
/// - **HTML**: `element`, `script_element` and `style_element`, named by the
///   `tag_name` of their `start_tag`/`end_tag`, or of a `self_closing_tag`.
///
/// A closing tag the parser had to invent (`isMissing`, or empty) counts as
/// absent, so an unclosed element reports `closeName == nil`.
enum TagElementExtraction {
    /// Whether `language` has tags this extraction reads. Every other language
    /// gets no tag highlight at all.
    static func supports(_ language: SyntaxLanguage?) -> Bool {
        switch language {
        case .javascript, .tsx, .html: true
        default: false
        }
    }

    /// The elements whose range contains `offset` (either end inclusive),
    /// innermost first, self-closing ones included.
    ///
    /// Both the node before and the node after `offset` are walked up, so a
    /// caret at either edge of a tag (`div|>`, `</header>|`) still sees the
    /// element it touches.
    static func enclosingElements(in tree: Tree, language: SyntaxLanguage, at offset: Int) -> [TagElement] {
        guard supports(language), let root = tree.rootNode, offset >= 0 else { return [] }
        var elements: [TagElement] = []
        var seen = Set<NSRange>()
        for probe in [max(0, offset - 1), offset] {
            let bytes = UInt32(probe * 2)
            var node = root.descendant(in: bytes..<(bytes + 2))
            while let current = node {
                if let element = element(from: current, language: language), !seen.contains(element.range) {
                    seen.insert(element.range)
                    elements.append(element)
                }
                node = current.parent
            }
        }
        return elements
            .filter { $0.range.location <= offset && offset <= NSMaxRange($0.range) }
            .sorted { $0.range.length < $1.range.length }
    }

    private static func element(from node: Node, language: SyntaxLanguage) -> TagElement? {
        switch language {
        case .javascript, .tsx: jsxElement(from: node)
        case .html: htmlElement(from: node)
        default: nil
        }
    }

    private static func jsxElement(from node: Node) -> TagElement? {
        switch node.nodeType {
        case "jsx_element":
            guard let open = node.child(byFieldName: "open_tag"), isPresent(open) else { return nil }
            let close = node.child(byFieldName: "close_tag").flatMap { isPresent($0) ? $0 : nil }
            return TagElement(
                range: node.range,
                openName: jsxName(of: open),
                closeName: close.map(jsxName(of:))
            )
        case "jsx_self_closing_element":
            return TagElement(range: node.range, openName: jsxName(of: node), closeName: nil)
        default:
            return nil
        }
    }

    /// The tag's `name` field, or — a fragment's `<>` / `</>` — the whole tag.
    private static func jsxName(of tag: Node) -> NSRange {
        tag.child(byFieldName: "name").map(\.range) ?? tag.range
    }

    private static func htmlElement(from node: Node) -> TagElement? {
        switch node.nodeType {
        case "element", "script_element", "style_element":
            break
        default:
            return nil
        }
        if let selfClosing = namedChild(of: node, type: "self_closing_tag"),
           let name = tagName(of: selfClosing) {
            return TagElement(range: node.range, openName: name, closeName: nil)
        }
        guard let start = namedChild(of: node, type: "start_tag"), let openName = tagName(of: start) else {
            return nil
        }
        let closeName = namedChild(of: node, type: "end_tag").flatMap(tagName(of:))
        return TagElement(range: node.range, openName: openName, closeName: closeName)
    }

    private static func tagName(of tag: Node) -> NSRange? {
        guard isPresent(tag), let name = namedChild(of: tag, type: "tag_name"), isPresent(name) else { return nil }
        return name.range
    }

    private static func namedChild(of node: Node, type: String) -> Node? {
        for index in 0..<node.namedChildCount {
            if let child = node.namedChild(at: index), child.nodeType == type { return child }
        }
        return nil
    }

    private static func isPresent(_ node: Node) -> Bool {
        !node.isMissing && node.range.length > 0
    }
}

/// Reads the chain Expand Selection climbs off a syntax tree, as
/// `SelectionExpansionRule.candidates` takes it (R6): the ranges of the
/// **named** nodes enclosing the selection, innermost first, and whether the
/// innermost of them is string content. Every decision about which rung comes
/// next is the rule's; this only walks parents.
///
/// The walk starts at the smallest node spanning the selection — for a caret,
/// the character after it, or the one before it at the very end of the text,
/// the probe `TagElementExtraction` uses — and keeps every named node whose
/// range contains the selection. Anonymous nodes (punctuation, keywords) are
/// never a rung.
///
/// **String content** is a literal or a comment: the tree has no node smaller
/// than the whole of either, so the rule's word step is always tried inside
/// one. Read by node type — a type naming `string` or `comment` — because the
/// grammars agree on that much and on nothing finer (`string_fragment`,
/// `string_content`, `template_string`, `line_comment`, …).
enum SelectionExpansionTreeWalk {
    struct Chain: Equatable {
        let ancestors: [NSRange]
        let stringContent: Bool
    }

    static func chain(in tree: Tree, selection: NSRange, textLength: Int) -> Chain {
        let empty = Chain(ancestors: [], stringContent: false)
        guard let root = tree.rootNode, selection.location != NSNotFound, selection.location >= 0,
              NSMaxRange(selection) <= textLength else { return empty }
        var start = selection.location
        var end = NSMaxRange(selection)
        if selection.length == 0 {
            if start < textLength {
                end = start + 1
            } else if start > 0 {
                start -= 1
            }
        }
        var node = root.descendant(in: UInt32(start * 2)..<UInt32(end * 2))
        var ancestors: [NSRange] = []
        var stringContent: Bool?
        while let current = node {
            let range = current.range
            if current.isNamed,
               range.location <= selection.location,
               NSMaxRange(range) >= NSMaxRange(selection) {
                if stringContent == nil {
                    stringContent = isStringContent(current.nodeType)
                }
                ancestors.append(range)
            }
            node = current.parent
        }
        return Chain(ancestors: ancestors, stringContent: stringContent ?? false)
    }

    private static func isStringContent(_ type: String?) -> Bool {
        guard let type else { return false }
        return type.contains("string") || type.contains("comment")
    }
}

/// Reads the ancestor chain `CommentStyle.context(ancestors:)` takes off a
/// syntax tree (R6): the **named** nodes enclosing a line's first
/// non-whitespace offset, innermost first, each paired with whether it starts
/// exactly at that offset. Every decision about what the chain means is the
/// rule's; this only walks parents.
///
/// Only the JSX-capable grammars are walked (`.javascript`, which covers
/// `.jsx`, and `.tsx`); `.typescript` has no JSX, so its chain is never asked
/// for. The tree is the snapshot's cached one, else a synchronous parse of the
/// buffer — Toggle Comment is one keystroke and must answer now. No tree
/// answers an empty chain, which the rule reads as code: silently `//`.
enum CommentContextTreeWalk {
    static func supports(_ language: SyntaxLanguage?) -> Bool {
        switch language {
        case .javascript, .tsx: true
        default: false
        }
    }

    /// The `context` Toggle Comment hands the engine: a line offset to its
    /// `CommentContext`. The tree is resolved on the first ask and reused —
    /// `snapshot`'s cached tree, else one synchronous parse of `text` — so a
    /// toggle the engine never asks about (no JSX language, no block) parses
    /// nothing.
    @MainActor
    static func resolver(
        snapshot: SyntaxTreeSnapshot, text: NSString, language: SyntaxLanguage?, fileID: UUID?
    ) -> (Int) -> CommentContext {
        var resolved: Tree??
        return { offset in
            if resolved == nil {
                resolved = .some(tree(snapshot: snapshot, text: text as String, language: language, fileID: fileID))
            }
            guard let tree = resolved ?? nil else { return .code }
            return CommentStyle.context(ancestors: ancestors(in: tree, at: offset, textLength: text.length))
        }
    }

    /// The tree describing `text`: `snapshot`'s cached tree, else a fresh
    /// synchronous parse; `nil` for a language this walk does not read.
    @MainActor
    static func tree(
        snapshot: SyntaxTreeSnapshot, text: String, language: SyntaxLanguage?, fileID: UUID?
    ) -> Tree? {
        guard supports(language), let language else { return nil }
        if let fileID, let cached = snapshot.cached(language: language, fileID: fileID) { return cached }
        return SyntaxTreeSnapshot.parse(text: text, language: language)
    }

    static func ancestors(in tree: Tree, at offset: Int, textLength: Int) -> [(kind: String, startsAtLineOffset: Bool)] {
        guard let root = tree.rootNode, offset >= 0, offset < textLength else { return [] }
        let bytes = UInt32(offset * 2)
        var node = root.descendant(in: bytes..<(bytes + 2))
        var chain: [(kind: String, startsAtLineOffset: Bool)] = []
        while let current = node {
            if current.isNamed, let kind = current.nodeType {
                chain.append((kind: kind, startsAtLineOffset: current.range.location == offset))
            }
            node = current.parent
        }
        return chain
    }
}

#endif
