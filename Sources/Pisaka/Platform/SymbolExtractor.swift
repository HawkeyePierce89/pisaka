#if os(macOS) || os(iOS)
import Foundation
import SwiftTreeSitter
import PisakaCore

/// Turns a file's text into the `[Symbol]` array `SymbolIndexModel` stores — the
/// one piece of the symbol index that cannot live in `PisakaCore`, because it is
/// the only piece that needs tree-sitter.
///
/// Lives in the non-gated `Platform/` layer: both destinations index, and nothing
/// here is platform-specific.
///
/// **Not an actor, and not `@MainActor`.** It is a caseless enum with one
/// `nonisolated static` function, the `MinimapTokenizer.computeModel` shape this
/// repository already relies on for off-main tree-sitter work. `SymbolIndexModel`
/// calls it exclusively from inside its own private serial queue (the seam is
/// deliberately synchronous — see that type's note), so the queue *is* the
/// serialization and an actor here would only add a second hop and a second
/// ordering authority. The thread-safety contract that makes that sound is the
/// same one `computeModel` states: **every call builds its own `Parser` and its
/// own query cursor** — tree-sitter parsers and cursors are not safe to share —
/// while the compiled `Query` and the `Language` come from the lock-guarded
/// caches (`SymbolQueryCatalog`, `SyntaxLanguageConfiguration`) and are only
/// *read*.
///
/// **Matches, not captures.** The queries pair an optional `@container` capture
/// with the kind capture inside a single pattern, and only a *match* carries that
/// pairing — a flat capture stream would lose which type a method belongs to. So
/// this walks `QueryCursor`'s match sequence rather than `highlights()`.
///
/// **Predicates are resolved**, unlike in the minimap's highlight pass. Exactly
/// one query needs it: an HTML `id` attribute is structurally identical to every
/// other attribute, so without evaluating `(#eq? @_attribute "id")` every
/// `class=` and `href=` value in the document would be indexed as an anchor.
/// `SymbolQueryTests` pins that HTML is the only query with a predicate, so a
/// second one arriving is reviewed rather than silently relying on this.
///
/// **Returning `[]` is the documented degradation**, covering all of: a language
/// with no query, a query that failed to compile, a grammar that failed to load,
/// and a parse that produced no tree. The index then holds an empty entry for the
/// file, which reads as "declares nothing" — quiet by nature, which is why
/// `SymbolQueryCatalog` asserts in DEBUG builds.
enum SymbolExtractor {
    /// Every declaration `language`'s symbols query finds in `text`.
    ///
    /// `fileURL` is carried into each `Symbol` unchanged — as the traversal (or
    /// the open tab) spelled it, never canonicalized here; `SymbolIndex` owns that
    /// normalization.
    ///
    /// `@Sendable` because this is handed to `SymbolIndexModel.extractSymbols` as a
    /// bare function reference, and that parameter is `@Sendable` — without the
    /// annotation the conversion is an unchecked one the compiler warns about.
    /// Sound for the reason the type's note gives: parser and cursor are built per
    /// call, and the only shared state touched is the lock-guarded grammar/query
    /// caches, read-only.
    @Sendable nonisolated static func symbols(
        in text: String,
        language: SyntaxLanguage,
        fileURL: URL
    ) -> [Symbol] {
        guard
            let configuration = SyntaxLanguageConfiguration.configuration(for: language),
            let query = SymbolQueryCatalog.query(for: language)
        else {
            return []
        }

        let content = text as NSString
        guard content.length > 0 else { return [] }

        let parser = Parser()
        do {
            try parser.setLanguage(configuration.language)
        } catch {
            return []
        }
        guard let tree = parser.parse(text), let root = tree.rootNode else { return [] }

        let context = Predicate.Context(string: text)
        // Line starts are an O(length) scan, so they are computed once and only
        // when the file actually declares something — most files in a project
        // (assets, configs, vendored bundles) yield no match at all.
        var lineStarts: [Int]?

        var symbols: [Symbol] = []
        for match in query.execute(node: root, in: tree) {
            // `allowed(in:)` is `allSatisfy` over the pattern's predicates, so a
            // pattern without any (every query but HTML) costs nothing here.
            guard match.allowed(in: context) else { continue }

            let container = match.captures
                .first { $0.name == SymbolKind.containerCaptureName }
                .flatMap { name(in: content, range: $0.range)?.text }

            for capture in match.captures {
                guard
                    let captureName = capture.name,
                    // An unknown capture is *dropped*, not defaulted — the whole
                    // reason `SymbolKind(captureName:)` is failable. This is also
                    // what filters the auxiliary `@_attribute` and `@container`
                    // captures out of the symbol stream.
                    let kind = SymbolKind(captureName: captureName),
                    let name = name(in: content, range: capture.range)
                else {
                    continue
                }

                let starts = lineStarts ?? LineStartIndex.offsets(in: content)
                lineStarts = starts

                symbols.append(
                    Symbol(
                        name: name.text,
                        kind: kind,
                        range: name.range,
                        fileURL: fileURL,
                        containerName: container,
                        line: line(of: name.range.location, in: starts)
                    )
                )
            }
        }

        return symbols
    }

    /// The captured node's text and the range it actually occupies, with
    /// surrounding whitespace trimmed off both — or `nil` when nothing is left.
    ///
    /// Trimming exists for the nodes that are not bare identifiers: a Markdown
    /// heading's `inline`/`paragraph` node can carry the space after the `#` and
    /// the newline that ends it. The *range* is narrowed alongside the text rather
    /// than only the text, so go-to-definition still lands the caret on the first
    /// character of the name and not on the whitespace before it.
    private static func name(in content: NSString, range: NSRange) -> (text: String, range: NSRange)? {
        guard range.location >= 0, NSMaxRange(range) <= content.length else { return nil }

        var start = range.location
        var end = NSMaxRange(range)
        while start < end, isWhitespace(content.character(at: start)) { start += 1 }
        while end > start, isWhitespace(content.character(at: end - 1)) { end -= 1 }
        guard end > start else { return nil }

        let trimmed = NSRange(location: start, length: end - start)
        return (content.substring(with: trimmed), trimmed)
    }

    /// Whether `character` is whitespace for the trimming above. A deliberately
    /// small set (space, tab and the line separators `LineStartIndex` splits on):
    /// a name node's stray characters are always these, and testing a full
    /// `CharacterSet` per code unit would cost far more than the trim saves.
    private static func isWhitespace(_ character: unichar) -> Bool {
        switch character {
        case 0x20, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0x2028, 0x2029:
            return true
        default:
            return false
        }
    }

    /// The 1-based display line containing `offset`, by binary search over the
    /// ascending line starts — so a file with a thousand symbols costs
    /// `n log n` lookups rather than `n` rescans.
    private static func line(of offset: Int, in lineStarts: [Int]) -> Int {
        var low = 0
        var high = lineStarts.count
        while low < high {
            let mid = (low + high) / 2
            if lineStarts[mid] <= offset { low = mid + 1 } else { high = mid }
        }
        // `lineStarts` always begins at 0, so `low` is at least 1 for any
        // non-negative offset — which is exactly the 1-based line number.
        return max(1, low)
    }
}

#endif
