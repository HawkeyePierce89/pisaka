import Foundation

/// The Markdown preview's document tree: what the parser produces and what the
/// renderer turns into HTML, with nothing platform-shaped in between.
///
/// The pipeline is deliberately cut in two here. `MarkdownParser` (the app's one
/// `import Markdown`) walks swift-markdown's AST and maps it onto these types
/// making no decisions of its own; `MarkdownRenderer` turns these types into an
/// HTML body. Neither half knows the other, and this file — the only thing they
/// share — parses nothing, composes no HTML and names no platform type, so every
/// question about *what the preview shows* is answerable in `swift test` against
/// a tree built by hand.
///
/// **There is no raw-HTML case at all.** A Markdown document may contain HTML
/// blocks and inline HTML spans; this tree has nowhere to put them, so the
/// parser drops them by having no target rather than by filtering. That is what
/// makes the drop *structural*: it cannot be forgotten in one branch of a
/// mapping, re-enabled by a later case, or bypassed by a renderer that decided
/// to interpolate something it was handed. The preview therefore cannot render
/// author-supplied markup, which is the same guarantee the page's CSP makes from
/// the other side — one property, stated twice, once where markup could enter
/// and once where a script could.
///
/// The set of cases is closed and covers exactly what this feature renders:
/// CommonMark plus the three GFM extensions the preview draws (tables, task
/// items, strikethrough). Nothing speculative is here, because an unrendered
/// case is a case no test can distinguish from a dropped one.

// MARK: - Inline content

/// A run of inline content: the leaves of a paragraph, a heading, a table cell
/// or a list item's first paragraph.
///
/// `indirect` because emphasis, strong, strikethrough and links nest.
public indirect enum MarkdownInline: Equatable, Sendable {
    /// Literal text, **unescaped** — exactly the characters the source spelled.
    /// Escaping for HTML is the renderer's job and happens once, there; a tree
    /// that carried pre-escaped text could not be asserted against a source
    /// string and would double-escape the moment a second consumer appeared.
    case text(String)
    case emphasis([MarkdownInline])
    case strong([MarkdownInline])
    /// GFM `~~struck~~`.
    case strikethrough([MarkdownInline])
    /// Inline `` `code` `` — a string, never children: its content is literal by
    /// definition, so there is nothing inside it to mark up.
    case code(String)
    /// A link. `destination` is the target **as the source spelled it** — the
    /// asset rule (`MarkdownPreviewAsset`) decides what a relative one resolves
    /// to, and it needs the original spelling to do that. `nil` is a link the
    /// source left without a destination.
    case link(destination: String?, title: String?, children: [MarkdownInline])
    /// An image. `children` is the alt text as inline content, because that is
    /// what Markdown allows there; the renderer flattens it, since HTML's `alt`
    /// is a plain attribute value.
    case image(source: String?, title: String?, children: [MarkdownInline])
    /// `<https://example.com>` and GFM's bare-URL autolinks: a link whose text
    /// *is* its destination. Kept as its own case rather than a `link` with a
    /// matching text child so the renderer never has to compare the two to find
    /// out which it is holding.
    case autolink(destination: String)
    /// A hard line break (two trailing spaces, or a backslash) — `<br>`.
    case lineBreak
    /// A newline inside a paragraph that is *not* a hard break. It is a case
    /// rather than a dropped node because dropping it would run the two lines'
    /// words together; the renderer emits it as the whitespace it is.
    case softBreak
}

// MARK: - Block content

/// How a GFM table column is aligned, from the delimiter row's colons.
///
/// `.none` is a column the source did not align (`---`), which is not the same
/// as `.left`: the renderer emits no alignment for it and lets the stylesheet
/// decide.
public enum MarkdownTableAlignment: Equatable, Sendable {
    case none
    case left
    case center
    case right
}

/// One table row: its cells, in column order, each a run of inline content.
///
/// A row may be shorter or longer than the header — GFM permits both — so
/// nothing here pads or truncates. The renderer answers to the alignment list.
public struct MarkdownTableRow: Equatable, Sendable {
    public let cells: [[MarkdownInline]]

    public init(cells: [[MarkdownInline]]) {
        self.cells = cells
    }
}

/// The state of a GFM task-list checkbox, when the item has one.
public enum MarkdownCheckbox: Equatable, Sendable {
    case unchecked
    case checked
}

/// One item of either list kind: its own blocks, plus the checkbox a GFM task
/// item carries.
///
/// `checkbox` is optional because an ordinary list item has none at all —
/// distinct from an unchecked one, which draws an empty box.
public struct MarkdownListItem: Equatable, Sendable {
    public let checkbox: MarkdownCheckbox?
    public let blocks: [MarkdownBlock]

    public init(checkbox: MarkdownCheckbox? = nil, blocks: [MarkdownBlock]) {
        self.checkbox = checkbox
        self.blocks = blocks
    }
}

/// A block of document content.
///
/// The same type describes a top-level block and a nested one — a blockquote's
/// paragraphs, a list item's own list — because the shapes are identical. What
/// differs is the source line, which only a *top-level* block carries, and which
/// is why `MarkdownTopLevelBlock` exists rather than an optional field here.
///
/// `indirect` because blockquotes and list items hold blocks.
public indirect enum MarkdownBlock: Equatable, Sendable {
    case paragraph([MarkdownInline])
    /// An ATX or Setext heading. `level` is 1…6 as the source spelled it;
    /// nothing here clamps it, because nothing here parses.
    case heading(level: Int, children: [MarkdownInline])
    /// A fenced or indented code block. `language` is the fence's info string
    /// when there was one, and `nil` for an indented block or a bare fence —
    /// which is the whole difference the renderer needs, since a block with no
    /// language is emitted without a highlight class and never guessed at.
    case codeBlock(language: String?, code: String)
    case blockQuote([MarkdownBlock])
    /// A bullet list. `isTight` is CommonMark's own distinction, decided by
    /// ``MarkdownListTightness``: a tight list draws its items as bare lines, a
    /// loose one puts paragraph spacing between them.
    case unorderedList(isTight: Bool, items: [MarkdownListItem])
    /// An ordered list. `start` is the first item's number, so `3.` renders as
    /// `<ol start="3">` rather than silently restarting at one; `isTight` is the
    /// same distinction the bullet list carries.
    case orderedList(start: Int, isTight: Bool, items: [MarkdownListItem])
    /// A GFM table. `alignments` is per column, in column order; `header` is the
    /// one header row and `body` the rest.
    case table(alignments: [MarkdownTableAlignment], header: MarkdownTableRow, body: [MarkdownTableRow])
    case thematicBreak
}

/// A top-level block together with the source line it started on.
///
/// The line is what `data-line` is rendered from, and it is what scroll sync
/// looks up: the page finds the last top-level element whose line is at or above
/// the editor's top visible line. Nested blocks carry none — not "carry `nil`",
/// but have nowhere to put one — because scroll sync only ever asks about
/// top-level positions and a nested line would be a second, unread number that
/// could disagree with the first.
///
/// `sourceLine` is 1-based, matching the editor's own line numbering, and is
/// optional because a parser may hand back a node with no source range.
public struct MarkdownTopLevelBlock: Equatable, Sendable {
    public let block: MarkdownBlock
    public let sourceLine: Int?

    public init(block: MarkdownBlock, sourceLine: Int? = nil) {
        self.block = block
        self.sourceLine = sourceLine
    }
}

/// A parsed Markdown document: its top-level blocks, in source order.
///
/// A value type with no behaviour on purpose. Everything that *decides*
/// something — what a relative path resolves to, what the page looks like, what
/// a click does — lives in the rules beside it, so this stays the one thing the
/// parser and the renderer both agree on.
public struct MarkdownDocument: Equatable, Sendable {
    public let blocks: [MarkdownTopLevelBlock]

    public init(blocks: [MarkdownTopLevelBlock]) {
        self.blocks = blocks
    }

    /// The empty document — what an empty file parses to, and what the preview
    /// shows before a first parse has landed.
    public static let empty = MarkdownDocument(blocks: [])
}

// MARK: - The parser seam

/// The one thing Core asks of a Markdown parser: text in, tree out.
///
/// The parser itself cannot live here — it is `apple/swift-markdown`, an
/// external dependency the `PisakaCore` library deliberately does not link — so
/// the preview's model reaches it through this protocol and never names it. The
/// app's `MarkdownParser` is its only production conformer; the tests' scripted
/// one is the other, which is what lets the model's whole ordering be asserted
/// in `swift test` with no parser present at all.
///
/// `Sendable` and *not* `@MainActor`: parsing a large document is the one part
/// of an update that is worth doing off the main actor, so the model hops with
/// it. The method is synchronous because parsing is — the hop is the caller's
/// decision, not the seam's.
public protocol MarkdownParsing: Sendable {
    /// The document `text` describes. A parser answers a tree for every input —
    /// an unparseable one is not a thing Markdown has, so there is no failure
    /// case and no `throws`.
    func parse(_ text: String) -> MarkdownDocument
}
