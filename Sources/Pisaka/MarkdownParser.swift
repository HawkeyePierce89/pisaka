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
/// **One fact is read rather than mapped**: whether a list is tight or loose,
/// which cmark decided while parsing and swift-markdown's tree keeps no flag
/// for. This file gathers the source lines the rule is stated in terms of and
/// hands them to ``MarkdownListTightness``; the rule itself stays in Core, so
/// the decision is still not made here — see `isTight(_:blankLines:)` below.
/// That reading is also the only reason the *text* is looked at at all, and it
/// is Core that looks: `parse(_:)` asks ``MarkdownListTightness/blankLines(in:)``
/// which lines are blank. The rule wants them twice over — a code block's range
/// alone cannot say whether it ended at a closing fence or past a blank line,
/// and a gap between two blocks is only a separation when a line inside it is
/// actually blank.
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
/// not among them, so a URL written as bare text stays text. What *does* become
/// `MarkdownInline.autolink` is any untitled link whose one text child is its
/// own destination — `<https://example.com>` and
/// `[https://example.com](https://example.com)` alike — because that is the
/// question `link.isAutolink` answers, and the two spell the same thing.
struct MarkdownParser: MarkdownParsing {
    func parse(_ text: String) -> MarkdownDocument {
        let document = Document(parsing: text, options: [.disableSmartOpts])
        // The one thing read from the source rather than from the tree, and read
        // by Core: which lines are blank. Only the tightness reading below wants
        // it, and only for a code block, whose range alone cannot say where its
        // content stopped — see `contentSpan(of:blankLines:)`.
        let blankLines = MarkdownListTightness.blankLines(in: text)
        return MarkdownDocument(blocks: document.children.compactMap {
            Self.topLevelBlock(from: $0, blankLines: blankLines)
        })
    }

    // MARK: - Blocks

    /// A top-level node and the 1-based line it started on, or nothing when the
    /// node has no Core case.
    private static func topLevelBlock(from markup: Markup, blankLines: Set<Int>) -> MarkdownTopLevelBlock? {
        guard let block = self.block(from: markup, blankLines: blankLines) else { return nil }
        return MarkdownTopLevelBlock(block: block, sourceLine: markup.range?.lowerBound.line)
    }

    private static func blocks(from children: MarkupChildren, blankLines: Set<Int>) -> [MarkdownBlock] {
        children.compactMap { block(from: $0, blankLines: blankLines) }
    }

    private static func block(from markup: Markup, blankLines: Set<Int>) -> MarkdownBlock? {
        switch markup {
        case let paragraph as Paragraph:
            return .paragraph(inlines(from: paragraph.children))
        case let heading as Heading:
            return .heading(level: heading.level, children: inlines(from: heading.children))
        case let codeBlock as CodeBlock:
            return .codeBlock(language: codeBlock.language, code: codeBlock.code)
        case let blockQuote as BlockQuote:
            return .blockQuote(blocks(from: blockQuote.children, blankLines: blankLines))
        case let list as UnorderedList:
            return .unorderedList(isTight: isTight(list, blankLines: blankLines),
                                  items: list.listItems.map { listItem(from: $0, blankLines: blankLines) })
        case let list as OrderedList:
            return .orderedList(start: Int(list.startIndex),
                                isTight: isTight(list, blankLines: blankLines),
                                items: list.listItems.map { listItem(from: $0, blankLines: blankLines) })
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

    /// Whether `list` is tight, read off its items' source lines by
    /// ``MarkdownListTightness``.
    ///
    /// The one place this file consults a range for something other than a
    /// `data-line`, and still not a decision of its own: cmark answered this
    /// question while parsing and swift-markdown's tree kept neither the answer
    /// nor a way back to the node holding it, so the fact has to be re-read from
    /// what the tree *does* carry. What is read is stated in
    /// ``MarkdownListTightness/isTight(itemSpans:blankLines:)``; the rule applied
    /// to it lives there, in Core, where `swift test` can see it. The source's
    /// blank lines travel with the spans because the rule asks which lines are
    /// blank rather than how far apart two blocks sit — a link reference
    /// definition leaves no node behind, so the gap it opens is not one.
    private static func isTight(_ list: some ListItemContainer, blankLines: Set<Int>) -> Bool {
        MarkdownListTightness.isTight(itemSpans: list.listItems.map { spans(of: $0, blankLines: blankLines) },
                                      blankLines: blankLines)
    }

    /// One item's direct block children as line spans, in source order.
    ///
    /// **An item always occupies the line its marker was written on**, whatever
    /// it holds: the marker line carries content by definition, so it can never
    /// be the blank line the rule is looking for. The first span therefore
    /// starts no later than the item's own `lowerBound`, and an item with no
    /// children at all reports that line alone. Both halves say the same thing —
    /// without them an item whose first block begins lower than its marker (`-`
    /// on its own line, its content indented under it on the next) would let its
    /// neighbours be compared across a line that is not blank, and a tight list
    /// would read as loose.
    private static func spans(of item: ListItem, blankLines: Set<Int>) -> [ClosedRange<Int>] {
        var spans = item.children.compactMap { contentSpan(of: $0, blankLines: blankLines) }
        guard let line = item.range?.lowerBound.line else { return spans }
        guard let first = spans.first else { return [line...line] }
        spans[0] = Swift.min(line, first.lowerBound)...first.upperBound
        return spans
    }

    /// The lines a block's **content** occupies.
    ///
    /// A **list**'s or **list item**'s own range is not that: cmark closes both
    /// *after* the blank line that ended them, so their `upperBound` swallows
    /// the very blank line the rule is looking for and every list would read as
    /// tight. Their children's ranges do not, so they answer with the union of
    /// theirs — widened to their own `lowerBound`, the marker line being content
    /// for the reason `spans(of:)` states — and everything else — a paragraph, a
    /// table, a thematic break — answers with its own, which for those is
    /// exactly its content. A container with nothing measurable in it (an empty
    /// item, a list of them) reports the line it was written on, the same
    /// degenerate answer and for the same reason.
    ///
    /// A **block quote** is the exception, and answers with its own range: cmark
    /// extends a quote only on a line the quote itself matched, so the range
    /// covers every `>` line — including a trailing one, blank *inside* the
    /// quote and part of the quote from the outside — and stops short of the
    /// truly blank line that ended it, which the enclosing item's range absorbs
    /// instead. Its children cannot say that: they end at the last line carrying
    /// content, and the `>` lines past it would read as a gap in the list
    /// holding the quote, where cmark reads no blank line at all (a blank line
    /// whose deepest container is a block quote never loosens anything).
    ///
    /// A heading is neither, and is the third case: a Setext heading's underline
    /// belongs to it and to no child of it, so its children end a line early —
    /// while its own range runs on past the underline to wherever cmark closed
    /// it, exactly as a container's does. One line past the last child, capped by
    /// the range, is the answer to both; an ATX heading has no underline and the
    /// two agree, so the cap is what decides it.
    ///
    /// A **code block** is the fourth case, and the one whose range cannot be
    /// read either way round: an *indented* block's swallows the blank line that
    /// ended it (cmark strips trailing blanks from the content and closes the
    /// node past them) while a fenced block's legitimately runs to its closing
    /// fence, and nothing on `CodeBlock` tells the two apart. The range, the code
    /// and the source's blank lines together do —
    /// ``MarkdownListTightness/codeBlockContentSpan(range:code:blankLines:)``,
    /// where that rule lives.
    private static func contentSpan(of markup: Markup, blankLines: Set<Int>) -> ClosedRange<Int>? {
        switch markup {
        case let heading as Heading:
            guard let range = heading.range else { return nil }
            let first = range.lowerBound.line
            let children = heading.children.compactMap { contentSpan(of: $0, blankLines: blankLines) }
            guard let last = children.map(\.upperBound).max() else {
                return first...first
            }
            return first...Swift.min(range.upperBound.line, last + 1)
        case let codeBlock as CodeBlock:
            guard let range = codeBlock.range else { return nil }
            return MarkdownListTightness.codeBlockContentSpan(
                range: range.lowerBound.line...range.upperBound.line,
                code: codeBlock.code,
                blankLines: blankLines
            )
        case is BlockQuote:
            guard let range = markup.range else { return nil }
            return range.lowerBound.line...range.upperBound.line
        case is UnorderedList, is OrderedList, is ListItem:
            let spans = markup.children.compactMap { contentSpan(of: $0, blankLines: blankLines) }
            let line = markup.range?.lowerBound.line
            guard let first = spans.first else { return line.map { $0...$0 } }
            let union = spans.dropFirst().reduce(first) {
                Swift.min($0.lowerBound, $1.lowerBound)...Swift.max($0.upperBound, $1.upperBound)
            }
            guard let line else { return union }
            return Swift.min(line, union.lowerBound)...union.upperBound
        default:
            guard let range = markup.range else { return nil }
            return range.lowerBound.line...range.upperBound.line
        }
    }

    private static func listItem(from item: ListItem, blankLines: Set<Int>) -> MarkdownListItem {
        MarkdownListItem(checkbox: item.checkbox.map(checkbox(from:)),
                         blocks: blocks(from: item.children, blankLines: blankLines))
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
            // text its destination", which is most of what separates the two
            // Core cases. Asking it here rather than comparing the children
            // downstream is why the renderer never has to.
            //
            // The title is the rest of it, and swift-markdown does not consider
            // it: `[https://x](https://x "Docs")` answers `true` there, being a
            // link whose one text child equals its destination. An autolink
            // cannot carry a title in any Markdown dialect — the syntax has
            // nowhere to write one — so a title is proof this was written as an
            // ordinary link, and ``MarkdownInline/autolink(destination:)`` has
            // no field to keep it in. Kept as a `.link`, which does.
            if link.isAutolink, link.title == nil, let destination = link.destination {
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
