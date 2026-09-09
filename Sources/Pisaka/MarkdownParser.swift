#if os(macOS)
import Foundation
import Markdown
import PisakaCore

/// The Markdown preview's one bridge to `apple/swift-markdown`: text in,
/// `MarkdownDocument` out.
///
/// **This is the feature's only `import Markdown`**, which is what
/// `MarkdownPreviewSourceGatingTests` pins. Everything downstream of it — the
/// renderer, the page shell, the asset and link rules, the model's ordering —
/// works on the Core tree alone, so the whole preview is answerable in
/// `swift test` even though the parser itself cannot link there.
///
/// **It makes no decisions.** Every method below is a mapping from one AST node
/// onto the Core case that means the same thing: nothing is filtered, nothing is
/// normalised, nothing is defaulted, no level is clamped, no language is
/// guessed, no path is resolved and no text is escaped. Where a node has no Core
/// case the mapping simply has nowhere to put it, which is the drop — see below.
/// That discipline is what makes the parser untestable-by-inspection *and*
/// uninteresting: the questions worth asking are asked of the tree.
///
/// **Raw HTML maps to nothing.** `HTMLBlock` and `InlineHTML` fall through to
/// the `default` of their switch and are gone. That is not a filter this file
/// applies — `MarkdownDocument` has no raw-HTML case at all, so there is no
/// target to map onto and no branch anywhere that could later be talked into
/// emitting one. The preview therefore cannot render author-supplied markup,
/// stated here where markup could enter and again in the page's CSP where a
/// script could. Table cell spans (`colspan`/`rowspan`) are dropped for the same
/// structural reason, as are the node kinds this feature does not render at all
/// (block directives, symbol links, Doxygen commands, inline attributes).
///
/// **Two parse options, both refusals rather than choices.** `.disableSmartOpts`
/// keeps text exactly as the source spelled it — with smart punctuation on,
/// cmark would rewrite quotes and dashes, which is precisely the normalisation
/// this file is not allowed to do. Source positions are left *on* (the default),
/// because `sourceLine` is read from them. The GFM extensions this feature
/// renders — tables, strikethrough and task lists — are attached by
/// swift-markdown unconditionally and so need no option; bare-URL autolinking is
/// not among them, so `MarkdownInline.autolink` arrives only from the
/// `<https://example.com>` form, which is CommonMark's own.
struct MarkdownParser: MarkdownParsing {
    func parse(_ text: String) -> MarkdownDocument {
        let document = Document(parsing: text, options: [.disableSmartOpts])
        return MarkdownDocument(blocks: document.children.compactMap(Self.topLevelBlock(from:)))
    }

    // MARK: - Blocks

    /// A top-level node and the 1-based line it started on, or nothing when the
    /// node has no Core case.
    private static func topLevelBlock(from markup: Markup) -> MarkdownTopLevelBlock? {
        guard let block = self.block(from: markup) else { return nil }
        return MarkdownTopLevelBlock(block: block, sourceLine: markup.range?.lowerBound.line)
    }

    private static func blocks(from children: MarkupChildren) -> [MarkdownBlock] {
        children.compactMap(block(from:))
    }

    private static func block(from markup: Markup) -> MarkdownBlock? {
        switch markup {
        case let paragraph as Paragraph:
            return .paragraph(inlines(from: paragraph.children))
        case let heading as Heading:
            return .heading(level: heading.level, children: inlines(from: heading.children))
        case let codeBlock as CodeBlock:
            return .codeBlock(language: codeBlock.language, code: codeBlock.code)
        case let blockQuote as BlockQuote:
            return .blockQuote(blocks(from: blockQuote.children))
        case let list as UnorderedList:
            return .unorderedList(list.listItems.map(listItem(from:)))
        case let list as OrderedList:
            return .orderedList(start: Int(list.startIndex), items: list.listItems.map(listItem(from:)))
        case let table as Table:
            return .table(alignments: table.columnAlignments.map(alignment(from:)),
                          header: row(from: table.head.cells),
                          body: table.body.rows.map { row(from: $0.cells) })
        case is ThematicBreak:
            return .thematicBreak
        default:
            return nil
        }
    }

    private static func listItem(from item: ListItem) -> MarkdownListItem {
        MarkdownListItem(checkbox: item.checkbox.map(checkbox(from:)), blocks: blocks(from: item.children))
    }

    private static func checkbox(from checkbox: Checkbox) -> MarkdownCheckbox {
        switch checkbox {
        case .checked: return .checked
        case .unchecked: return .unchecked
        }
    }

    private static func alignment(from alignment: Table.ColumnAlignment?) -> MarkdownTableAlignment {
        switch alignment {
        case .none: return .none
        case .some(.left): return .left
        case .some(.center): return .center
        case .some(.right): return .right
        }
    }

    private static func row(from cells: LazyMapSequence<MarkupChildren, Table.Cell>) -> MarkdownTableRow {
        MarkdownTableRow(cells: cells.map { inlines(from: $0.children) })
    }

    // MARK: - Inlines

    private static func inlines(from children: MarkupChildren) -> [MarkdownInline] {
        children.compactMap(inline(from:))
    }

    private static func inline(from markup: Markup) -> MarkdownInline? {
        switch markup {
        case let text as Text:
            return .text(text.string)
        case let emphasis as Emphasis:
            return .emphasis(inlines(from: emphasis.children))
        case let strong as Strong:
            return .strong(inlines(from: strong.children))
        case let strikethrough as Strikethrough:
            return .strikethrough(inlines(from: strikethrough.children))
        case let code as InlineCode:
            return .code(code.code)
        case let link as Link:
            // `isAutolink` is swift-markdown's own answer to "is this link's
            // text its destination", which is the one thing that separates the
            // two Core cases. Asking it here rather than comparing the children
            // downstream is why the renderer never has to.
            if link.isAutolink, let destination = link.destination {
                return .autolink(destination: destination)
            }
            return .link(destination: link.destination, title: link.title, children: inlines(from: link.children))
        case let image as Image:
            return .image(source: image.source, title: image.title, children: inlines(from: image.children))
        case is LineBreak:
            return .lineBreak
        case is SoftBreak:
            return .softBreak
        default:
            return nil
        }
    }
}
#endif
