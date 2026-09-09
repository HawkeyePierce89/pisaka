import Foundation

/// The Markdown preview's document tree turned into an HTML **body** — the
/// fragment that goes inside the shell's one container element.
///
/// A pure function of the tree and the document's context, which is what makes
/// the whole of *what the preview shows* assertable in `swift test`: no web
/// view, no parser and no file system are involved in getting from a
/// `MarkdownDocument` to the markup, and the app layer composes no HTML at all.
///
/// Three properties hold by construction rather than by care:
///
/// * **Nothing author-supplied reaches the page as markup.** Every string that
///   comes out of the document — text, code, a link's title, an image's alt —
///   goes through ``escaped(_:)`` exactly once, and the tree it renders has no
///   raw-HTML case to interpolate (`MarkdownDocument`). The page's CSP states
///   the same property from the other side.
/// * **Only top-level blocks carry `data-line`.** The line lives on
///   `MarkdownTopLevelBlock` and nowhere else, so a nested block cannot acquire
///   one: the renderer is handed the attribute from outside and passes none down.
/// * **A file target is either an app-scheme URL or the source's own
///   spelling.** The one decision about reach belongs to
///   `MarkdownPreviewAsset`; this file asks it and emits its answer. What it
///   emits for an approved target is exactly what the navigation rule will later
///   be handed, which is what makes the round trip testable end to end.
///
/// The renderer *does* make three presentational decisions the tree
/// deliberately leaves open, each because HTML has no way to express the
/// alternative: a heading level is clamped to 1…6, a fence's info string is
/// reduced to its first word, and that word is lowercased. All three are stated
/// where they happen.
public enum MarkdownRenderer {

    /// The document as an HTML body fragment.
    ///
    /// Blocks are joined with newlines — for a readable devtools inspection and
    /// for tests that read like the markup, never for layout: every block is a
    /// block-level element and the whitespace between them collapses.
    public static func body(for document: MarkdownDocument, context: MarkdownDocumentContext) -> String {
        // The one allocator of the render, created here and threaded down: it is
        // *this document's* heading ids, so it begins the same way on every call
        // and a second render of the same tree produces the same markup.
        //
        // It begins holding the shell's own container id, which is the one `id`
        // the page carries that this file did not write: `getElementById` answers
        // the first element in document order, so a `## Content` heading taking
        // that id would send its link to the top of the container instead of to
        // itself. Reserved here rather than inside the allocator because the page
        // is this file's dependency, not the slug rule's.
        var slugs = MarkdownHeadingSlug.Allocator(reserving: [MarkdownPreviewPage.containerElementID])
        return document.blocks
            .map { render($0.block, attributes: lineAttribute($0.sourceLine), context: context, slugs: &slugs) }
            .joined(separator: "\n")
    }

    /// The `data-line` attribute a top-level block carries, or nothing.
    ///
    /// Nothing, rather than `data-line="0"` or an empty attribute: scroll sync
    /// looks for elements *carrying* the attribute, and a block whose parser gave
    /// no source range has no honest line to offer.
    private static func lineAttribute(_ sourceLine: Int?) -> String {
        guard let sourceLine else { return "" }
        return " data-line=\"\(sourceLine)\""
    }

    // MARK: - Blocks

    private static func render(
        _ block: MarkdownBlock,
        attributes: String,
        context: MarkdownDocumentContext,
        slugs: inout MarkdownHeadingSlug.Allocator
    ) -> String {
        switch block {
        case .paragraph(let children):
            return "<p\(attributes)>\(render(children, context: context))</p>"

        case .heading(let level, let children):
            // Clamped because HTML has six heading elements and the tree carries
            // whatever the source spelled. A `<h9>` is an unknown inline element
            // — the text would render as a paragraph in the body font with no
            // hint that it was a heading — so the deepest heading HTML has is a
            // truer answer than a working `<h7>` that does not exist.
            let clamped = min(max(level, 1), 6)
            // The heading's *text* is what the anchor is named after, which is
            // the same flattening an image's `alt` gets: markup inside a heading
            // is how it is drawn, never part of what a link to it spells. The
            // attribute goes through `attribute(_:_:)` like every other one — a
            // slug carries nothing that needs escaping, and bypassing the one
            // escape to say so would make that a fact about the slug rule rather
            // than about this file. A heading the rule leaves unnamed carries no
            // `id` at all.
            let anchor = attribute("id", slugs.allocate(forText: plainText(children)))
            return "<h\(clamped)\(anchor)\(attributes)>\(render(children, context: context))</h\(clamped)>"

        case .codeBlock(let language, let code):
            return renderCodeBlock(language: language, code: code, attributes: attributes)

        case .blockQuote(let blocks):
            let content = renderNested(blocks, context: context, slugs: &slugs)
            return "<blockquote\(attributes)>\(content)</blockquote>"

        case .unorderedList(let isTight, let items):
            let content = renderItems(items, context: context, slugs: &slugs)
            return "<ul\(looseClass(isTight: isTight))\(attributes)>\(content)</ul>"

        case .orderedList(let start, let isTight, let items):
            // `start` is emitted always, including for `1`. One shape rather than
            // two: a conditional attribute is a branch whose "1" case is
            // untestable from the markup, and `<ol start="1">` is what the
            // default already means.
            let open = "<ol start=\"\(start)\"\(looseClass(isTight: isTight))\(attributes)>"
            return "\(open)\(renderItems(items, context: context, slugs: &slugs))</ol>"

        case .table(let alignments, let header, let body):
            return renderTable(alignments: alignments, header: header, body: body, attributes: attributes, context: context)

        case .thematicBreak:
            return "<hr\(attributes)>"
        }
    }

    /// Nested blocks — a blockquote's content, a list item's own blocks.
    ///
    /// The attribute is empty at every nesting level, which is the *only* way
    /// this function is called: `data-line` reaches a block from its top-level
    /// wrapper and there is no path by which a nested one receives one.
    ///
    /// The slug allocator, by contrast, travels *all* the way down: a heading
    /// inside a blockquote or a list item is a heading, and gets its `id` on the
    /// same terms and in the same document order as a top-level one.
    private static func renderNested(
        _ blocks: [MarkdownBlock],
        context: MarkdownDocumentContext,
        slugs: inout MarkdownHeadingSlug.Allocator
    ) -> String {
        blocks
            .map { render($0, attributes: "", context: context, slugs: &slugs) }
            .joined(separator: "\n")
    }

    /// A fenced or indented code block.
    ///
    /// Three shapes, and no fourth: a `mermaid` fence is a diagram source the
    /// page's own script renders, a fence with any other language is a
    /// highlight.js target, and a fence with none — like every indented block —
    /// is plain preformatted text. **Nothing is auto-detected.** Language
    /// guessing on an unlabelled fence is wrong often enough to matter, and it is
    /// wrong *colourfully*: a shell transcript highlighted as Ruby reads as a
    /// syntax error in the document rather than as a guess by the viewer.
    private static func renderCodeBlock(language: String?, code: String, attributes: String) -> String {
        guard let name = highlightName(for: language) else {
            return "<pre\(attributes)><code>\(escaped(code))</code></pre>"
        }
        if name == mermaidLanguage {
            // The diagram source sits directly in the `<pre>`, which is what
            // mermaid's own renderer reads and replaces. Escaped like any other
            // text: it is read as text by the script, never as markup by the
            // parser.
            return "<pre class=\"mermaid\"\(attributes)>\(escaped(code))</pre>"
        }
        return "<pre\(attributes)><code class=\"language-\(escaped(name))\">\(escaped(code))</code></pre>"
    }

    /// The fence info string reduced to the language name a class may carry, or
    /// `nil` for a fence that named none.
    ///
    /// Two reductions, both forced by what the name is *for*:
    ///
    /// * **The first word only.** CommonMark's info string is free text after the
    ///   language (` ```swift title=Example.swift ` is legal), and the whole of
    ///   it in `class="language-…"` would add classes the stylesheet never
    ///   declared and a highlight.js lookup that cannot match.
    /// * **Lowercased.** Every highlight.js language name and alias is
    ///   lowercase, so ` ```Swift ` highlights only if the name is folded — and
    ///   folding it here, once, is what makes the `mermaid` comparison below
    ///   case-insensitive for free.
    private static func highlightName(for language: String?) -> String? {
        guard let language else { return nil }
        guard let first = language.split(whereSeparator: { $0.isWhitespace }).first else { return nil }
        return String(first).lowercased()
    }

    /// The one language name that is not a highlight target but a diagram.
    private static let mermaidLanguage = "mermaid"

    /// The class a **loose** list carries, and the empty string a tight one does.
    ///
    /// Marked in that direction on purpose. Tight is the ordinary list and the
    /// stylesheet's ordinary case — an item's content is drawn as a bare line —
    /// so it is the loose list, the one the source asked for spacing in, that
    /// needs something to select on. The element carries the class rather than
    /// each item, because looseness is a fact about the list: CommonMark draws
    /// *every* item of a loose list loose, including the ones with no blank line
    /// beside them.
    private static func looseClass(isTight: Bool) -> String {
        isTight ? "" : " class=\"loose\""
    }

    /// Either list kind's items.
    ///
    /// A GFM task item gets a disabled checkbox ahead of its content: disabled
    /// because the preview is read-only — a live checkbox would be a control
    /// that either does nothing when clicked or writes to the worktree, and this
    /// feature writes nothing. Where the box sits relative to the item's first
    /// paragraph is the stylesheet's business, not the renderer's; the class is
    /// emitted so the stylesheet has something to select.
    private static func renderItems(
        _ items: [MarkdownListItem],
        context: MarkdownDocumentContext,
        slugs: inout MarkdownHeadingSlug.Allocator
    ) -> String {
        items.map { item in
            let content = renderNested(item.blocks, context: context, slugs: &slugs)
            switch item.checkbox {
            case nil:
                return "<li>\(content)</li>"
            case .unchecked:
                return "<li class=\"task-list-item\"><input type=\"checkbox\" disabled>\(content)</li>"
            case .checked:
                return "<li class=\"task-list-item\"><input type=\"checkbox\" disabled checked>\(content)</li>"
            }
        }
        .joined(separator: "\n")
    }

    /// A GFM table.
    ///
    /// Alignment travels as `style="text-align: …"` rather than as the `align`
    /// attribute, which HTML5 removed; `.none` emits nothing at all and lets the
    /// stylesheet decide, which is the difference between a column the source
    /// aligned left and one it did not align.
    ///
    /// Nothing pads or truncates a row. GFM allows a row shorter or longer than
    /// the header and says what it means (missing cells are empty, extra ones are
    /// dropped by the *parser*); a renderer that invented cells would be
    /// disagreeing with a tree that already decided.
    ///
    /// This is the one nested path the slug allocator does **not** travel, and
    /// not by omission: a cell is `[MarkdownInline]`, which has no heading case
    /// at all, so there is nothing here to name. Threading it anyway would be a
    /// parameter no line reads, claiming a possibility the tree does not have.
    private static func renderTable(
        alignments: [MarkdownTableAlignment],
        header: MarkdownTableRow,
        body: [MarkdownTableRow],
        attributes: String,
        context: MarkdownDocumentContext
    ) -> String {
        let head = renderRow(header, cell: "th", alignments: alignments, context: context)
        let rows = body.map { renderRow($0, cell: "td", alignments: alignments, context: context) }
        return "<table\(attributes)><thead>\(head)</thead><tbody>\(rows.joined(separator: "\n"))</tbody></table>"
    }

    private static func renderRow(
        _ row: MarkdownTableRow,
        cell: String,
        alignments: [MarkdownTableAlignment],
        context: MarkdownDocumentContext
    ) -> String {
        let cells = row.cells.enumerated().map { index, inlines -> String in
            let alignment = index < alignments.count ? alignments[index] : .none
            return "<\(cell)\(alignmentAttribute(alignment))>\(render(inlines, context: context))</\(cell)>"
        }
        return "<tr>\(cells.joined())</tr>"
    }

    private static func alignmentAttribute(_ alignment: MarkdownTableAlignment) -> String {
        switch alignment {
        case .none: return ""
        case .left: return " style=\"text-align: left\""
        case .center: return " style=\"text-align: center\""
        case .right: return " style=\"text-align: right\""
        }
    }

    // MARK: - Inline content

    private static func render(_ inlines: [MarkdownInline], context: MarkdownDocumentContext) -> String {
        inlines.map { render($0, context: context) }.joined()
    }

    private static func render(_ inline: MarkdownInline, context: MarkdownDocumentContext) -> String {
        switch inline {
        case .text(let text):
            return escaped(text)

        case .emphasis(let children):
            return "<em>\(render(children, context: context))</em>"

        case .strong(let children):
            return "<strong>\(render(children, context: context))</strong>"

        case .strikethrough(let children):
            return "<del>\(render(children, context: context))</del>"

        case .code(let code):
            return "<code>\(escaped(code))</code>"

        case .link(let destination, let title, let children):
            let attributes = attribute("href", target(destination, context: context)) + attribute("title", title)
            return "<a\(attributes)>\(render(children, context: context))</a>"

        case .image(let source, let title, let children):
            let attributes = attribute("src", target(source, context: context))
                + attribute("alt", plainText(children))
                + attribute("title", title)
            return "<img\(attributes)>"

        case .autolink(let destination):
            // The destination is both the target and the text, which is what an
            // autolink *is*. It still goes through the target rule: a URL always
            // has a scheme, so the rule answers nothing and the spelling is
            // emitted — but asking is what keeps this case from being the one
            // place a destination reaches the page unexamined.
            let attributes = attribute("href", target(destination, context: context))
            return "<a\(attributes)>\(escaped(destination))</a>"

        case .lineBreak:
            return "<br>"

        case .softBreak:
            // The whitespace it is. Dropping it would run the two lines' last
            // and first words together; `<br>` would turn a soft wrap into a
            // hard one the source did not ask for.
            return "\n"
        }
    }

    /// What a `src`/`href` is emitted as: the app-scheme URL when the asset rule
    /// approves the target, and otherwise the *unresolved* form of the target.
    ///
    /// The unresolved form is deliberate and is the whole of the fallback: an
    /// out-of-project image renders as a broken image showing its alt text, and
    /// an out-of-project link is a target the navigation rule refuses. Both are
    /// visible; a dropped attribute would be silent.
    ///
    /// It is ``MarkdownPreviewAsset/unresolvedTarget(_:)`` rather than the raw
    /// spelling because the raw spelling is not always a refusal: a scheme-less
    /// one is re-resolved by the page against the shell's URL and can land back
    /// in the served namespace as another project file. That rule is asked here
    /// for the same reason the forward one is — this is the one place a
    /// destination becomes an attribute, and neither answer is composed here.
    private static func target(_ destination: String?, context: MarkdownDocumentContext) -> String? {
        guard let destination else { return nil }
        if let url = MarkdownPreviewAsset.assetURL(forTarget: destination, context: context) {
            return url.absoluteString
        }
        return MarkdownPreviewAsset.unresolvedTarget(destination)
    }

    /// One attribute, escaped, or nothing when the value is absent.
    ///
    /// Absent rather than empty: `<a>` with no `href` is not a link and the
    /// navigation delegate never hears about it, which is the right answer for a
    /// link the source left without a destination. `href=""` would instead
    /// reload the shell.
    private static func attribute(_ name: String, _ value: String?) -> String {
        guard let value else { return "" }
        return " \(name)=\"\(escaped(value))\""
    }

    /// Inline content flattened to text — what an `alt` attribute can carry.
    ///
    /// Markdown allows full inline content as an image's description; HTML's
    /// `alt` is a plain attribute value, so the markup is dropped and the words
    /// are kept. Escaping happens at the attribute, once, like every other value.
    private static func plainText(_ inlines: [MarkdownInline]) -> String {
        inlines.map { inline in
            switch inline {
            case .text(let text): return text
            case .code(let code): return code
            case .autolink(let destination): return destination
            case .emphasis(let children), .strong(let children), .strikethrough(let children):
                return plainText(children)
            case .link(_, _, let children), .image(_, _, let children):
                return plainText(children)
            case .lineBreak, .softBreak: return " "
            }
        }.joined()
    }

    // MARK: - Escaping

    /// The one escape, applied once to every author-supplied string, in text
    /// position and in an attribute value alike.
    ///
    /// One function rather than a text escape and an attribute escape: the two
    /// differ only in whether quotes are folded, and folding them in text costs
    /// nothing while *not* folding them in an attribute is an injected attribute.
    /// A single total function cannot be the wrong one for the position it is
    /// called in.
    ///
    /// `&` is replaced first, or it would re-escape the ampersands the later
    /// replacements introduce.
    static func escaped(_ text: String) -> String {
        var escaped = text.replacingOccurrences(of: "&", with: "&amp;")
        escaped = escaped.replacingOccurrences(of: "<", with: "&lt;")
        escaped = escaped.replacingOccurrences(of: ">", with: "&gt;")
        escaped = escaped.replacingOccurrences(of: "\"", with: "&quot;")
        return escaped.replacingOccurrences(of: "'", with: "&#39;")
    }
}
