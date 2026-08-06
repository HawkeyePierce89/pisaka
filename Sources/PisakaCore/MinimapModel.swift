import Foundation

/// One contiguous run of non-whitespace characters sharing a single token kind,
/// within one document line. `column`/`length` are in UTF-16 units (the unit the
/// tree-sitter query ranges arrive in), measured from the line start.
///
/// Color is intentionally *not* stored: the renderer resolves `kind` through the
/// theme at draw time so the minimap follows the system appearance, just like the
/// editor's attribute provider.
public struct MinimapTokenRun: Equatable {
    public let column: Int
    public let length: Int
    public let kind: SyntaxTokenKind

    public init(column: Int, length: Int, kind: SyntaxTokenKind) {
        self.column = column
        self.length = length
        self.kind = kind
    }
}

/// A line-indexed, color-free overview of a file for the minimap: `runs[i]` are
/// the non-whitespace colored runs on document line `i` (empty for a blank or
/// all-whitespace line). Appearance-agnostic — each run carries a
/// `SyntaxTokenKind`, never a frozen color.
public struct MinimapModel: Equatable {
    /// Per-line runs, indexed by 0-based document line number.
    public let runs: [[MinimapTokenRun]]

    public init(runs: [[MinimapTokenRun]]) {
        self.runs = runs
    }

    public static let empty = MinimapModel(runs: [])

    /// Number of document lines covered (used to scale rows to the minimap).
    public var lineCount: Int { runs.count }

    /// Build a line-indexed model from `text` and a per-UTF-16-unit `kinds` array
    /// (`kinds[i]` is the token kind of UTF-16 unit `i`). The tree-sitter parse
    /// that fills `kinds` stays in the view layer; this is the pure grouping step:
    /// split each line into runs of non-whitespace characters of a single kind.
    ///
    /// An empty text yields a single empty line (`[[]]`), matching an empty buffer
    /// that still has one (blank) line. `kinds` shorter than the text is tolerated
    /// (missing positions are treated as `.plain`) rather than trapping.
    public static func build(text: String, kinds: [SyntaxTokenKind]) -> MinimapModel {
        let ns = text as NSString
        let length = ns.length
        guard length > 0 else { return MinimapModel(runs: [[]]) }

        // Use the shared line-start indexing so the minimap counts document lines
        // with the same separator semantics as the line-number gutter and TextKit
        // (LF, CR, CRLF, NEL, U+2028, U+2029 — not LF alone). A LF-only count
        // would diverge from the editor for CR/LS/PS-delimited files, skewing the
        // minimap's wheel-scroll scale and token-row alignment.
        let lineStarts = LineStartIndex.offsets(in: ns)
        return MinimapModel(runs: lineRuns(in: ns, lineStarts: lineStarts, length: length, kinds: kinds))
    }

    /// Group each line's characters into non-whitespace runs of a single kind.
    static func lineRuns(
        in ns: NSString,
        lineStarts: [Int],
        length: Int,
        kinds: [SyntaxTokenKind]
    ) -> [[MinimapTokenRun]] {
        let lineCount = lineStarts.count
        var result = [[MinimapTokenRun]](repeating: [], count: lineCount)

        for line in 0..<lineCount {
            let start = lineStarts[line]
            let end = line + 1 < lineCount ? lineStarts[line + 1] : length

            var lineRuns: [MinimapTokenRun] = []
            var runStart = -1
            var runKind: SyntaxTokenKind = .plain

            var offset = start
            while offset < end {
                let isSpace = isWhitespace(ns.character(at: offset))
                if isSpace {
                    if runStart >= 0 {
                        lineRuns.append(MinimapTokenRun(column: runStart - start, length: offset - runStart, kind: runKind))
                        runStart = -1
                    }
                } else {
                    let kind = offset < kinds.count ? kinds[offset] : .plain
                    if runStart < 0 {
                        runStart = offset
                        runKind = kind
                    } else if kind != runKind {
                        lineRuns.append(MinimapTokenRun(column: runStart - start, length: offset - runStart, kind: runKind))
                        runStart = offset
                        runKind = kind
                    }
                }
                offset += 1
            }
            if runStart >= 0 {
                lineRuns.append(MinimapTokenRun(column: runStart - start, length: end - runStart, kind: runKind))
            }
            result[line] = lineRuns
        }
        return result
    }

    /// Whitespace for minimap purposes: ASCII space/tab/newlines/vertical
    /// tab/form feed, plus the Unicode line separators `LineStartIndex` splits on
    /// — NEL (U+0085), LINE SEPARATOR (U+2028), PARAGRAPH SEPARATOR (U+2029). Each
    /// line's span runs to the *next* line's start, so it includes that line's
    /// trailing separator; without these cases the invisible NEL/LS/PS separators
    /// would render as spurious one-character runs in files delimited by them.
    /// Surrogate units are never whitespace, so a UTF-16 check is sufficient for
    /// a minimap overview.
    static func isWhitespace(_ ch: unichar) -> Bool {
        switch ch {
        case 0x20, 0x09, 0x0A, 0x0D, 0x0B, 0x0C, 0x85, 0x2028, 0x2029:
            return true
        default:
            return false
        }
    }
}
