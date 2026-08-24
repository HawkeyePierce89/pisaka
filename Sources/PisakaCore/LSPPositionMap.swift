import Foundation

/// The bridge between the editor's one coordinate — a UTF-16 offset into the
/// buffer — and LSP's `(line, character)` pair.
///
/// **This deliberately does not use `LineStartIndex`** (D1), and that is the
/// whole point of the file existing. `LineStartIndex` splits on everything
/// `NSString` calls a line separator — LF, CR, CRLF, NEL (U+0085), LS (U+2028)
/// and PS (U+2029) — because the gutter, the minimap and TextKit must agree with
/// each other. LSP's base protocol counts lines with **LF, CRLF and CR only**.
/// The number we send has to be the number the server counted, so this scanner
/// implements the server's rule, not the editor's.
///
/// The two rules disagree only in a file that delimits lines with NEL, LS or PS.
/// There the editor's line count and the server's differ, and the consequence is
/// bounded on purpose: every LSP position is converted to an absolute offset at
/// the boundary, so jumps and edits stay exact; only the two *numberings*
/// diverge, and no LSP line number is ever shown to the user — the picker's line
/// number is derived from the offset with `LineStartIndex`, so what is read
/// matches the gutter. This is a known limit, written down in
/// `docs/architecture/core-lsp.md` and asserted by
/// `LSPPositionMapTests.testUnicodeSeparatorsDivergeFromTheEditorsLineCount`
/// rather than left as an assumption.
///
/// Everything is UTF-16, matching `positionEncoding: utf-16`, `NSString.length`
/// and every other offset in this codebase. A character *inside* a surrogate pair
/// is a legal LSP position; it maps to the offset of that code unit, which is
/// exactly what an `NSString` index means.
public enum LSPPositionMap {
    /// UTF-16 offset of the first character of every LSP line in `content`.
    ///
    /// Always non-empty: an empty document is one line starting at 0. A document
    /// ending in a separator gets a final entry at `content.length` — the empty
    /// last line, which is a real position a server can point at.
    public static func lineStarts(in content: NSString) -> [Int] {
        var starts = [0]
        let length = content.length
        var index = 0
        while index < length {
            let unit = content.character(at: index)
            if unit == 0x000A {  // LF
                starts.append(index + 1)
                index += 1
            } else if unit == 0x000D {  // CR, or CRLF as one separator
                if index + 1 < length, content.character(at: index + 1) == 0x000A {
                    starts.append(index + 2)
                    index += 2
                } else {
                    starts.append(index + 1)
                    index += 1
                }
            } else {
                index += 1
            }
        }
        return starts
    }

    /// The LSP position of a buffer offset.
    ///
    /// An offset outside the buffer is clamped rather than rejected: it can only
    /// come from a caret the editor already moved, and answering about the
    /// nearest real position is better than not asking the server at all.
    public static func position(forOffset offset: Int, in content: NSString) -> LSPPosition {
        position(forOffset: offset, lineStarts: lineStarts(in: content), length: content.length)
    }

    /// The same, against line starts computed once — how a caller that maps
    /// several positions in one buffer avoids rescanning it each time.
    public static func position(forOffset offset: Int, lineStarts: [Int], length: Int) -> LSPPosition {
        guard !lineStarts.isEmpty else { return LSPPosition(line: 0, character: 0) }
        let clamped = min(max(offset, 0), length)
        let line = lineIndex(containing: clamped, lineStarts: lineStarts)
        return LSPPosition(line: line, character: clamped - lineStarts[line])
    }

    /// The buffer offset of an LSP position.
    ///
    /// Clamped in both dimensions, because this is where a *server's* numbers
    /// enter the editor and they are not to be trusted with an `NSString` index:
    /// a line past the end resolves to the end of the buffer, and a character
    /// past the end of its line resolves to that line's end — before the
    /// separator, so a jump never lands on the invisible half of a CRLF.
    public static func offset(for position: LSPPosition, in content: NSString) -> Int {
        offset(for: position, in: content, lineStarts: lineStarts(in: content))
    }

    /// The same, against line starts computed once.
    ///
    /// `content` is still needed even though `lineStarts` is given: clamping a
    /// character to the end of its line means knowing whether the separator that
    /// follows is one unit or two, and a list of starts cannot tell CRLF from LF.
    public static func offset(for position: LSPPosition, in content: NSString, lineStarts: [Int]) -> Int {
        guard !lineStarts.isEmpty, position.line >= 0 else { return 0 }
        guard position.line < lineStarts.count else { return content.length }
        let start = lineStarts[position.line]
        guard position.character > 0 else { return start }
        let end = lineContentEnd(ofLine: position.line, in: content, lineStarts: lineStarts)
        // The clamp is applied to `character` itself rather than to the sum, and
        // that is not a rewrite for taste: `character` is a number a *server* sent,
        // an `Int` decoded straight off the wire, and `start + character` with an
        // `Int.max` in it traps on overflow before any `min` could see it — a hard
        // crash of the editor on one malformed response, on a path where every
        // other failure degrades silently to tree-sitter. `end >= start` always
        // (`lineContentEnd`'s own postcondition), so the difference is non-negative.
        return start + min(position.character, end - start)
    }

    /// Convert a whole LSP range to a buffer range in one pass over `content`.
    ///
    /// The range is normalised: a server that sends `end` before `start` — which
    /// happens, and which `NSRange` cannot represent — yields an empty range at
    /// `start` rather than a negative length that traps at the call site.
    public static func range(for range: LSPRange, in content: NSString) -> NSRange {
        self.range(for: range, in: content, lineStarts: lineStarts(in: content))
    }

    /// The same conversion against a table the caller already built.
    ///
    /// The overload above scans the whole buffer once per call, which is the right
    /// shape for a one-off but the wrong one for a completion list: every item the
    /// server sends carries a `textEdit`, so mapping a 30-item list in a large file
    /// would re-scan it 30 times on every debounced keystroke. Callers that map
    /// more than one range against the same `content` build the table once and hand
    /// it here.
    public static func range(
        for range: LSPRange,
        in content: NSString,
        lineStarts: [Int]
    ) -> NSRange {
        let start = offset(for: range.start, in: content, lineStarts: lineStarts)
        let end = offset(for: range.end, in: content, lineStarts: lineStarts)
        return NSRange(location: start, length: max(0, end - start))
    }

    /// The end of a line's *content*: the offset of its separator, or the end of
    /// the buffer for the last line.
    private static func lineContentEnd(
        ofLine line: Int,
        in content: NSString,
        lineStarts: [Int]
    ) -> Int {
        guard line + 1 < lineStarts.count else { return content.length }
        let start = lineStarts[line]
        let nextStart = lineStarts[line + 1]
        // Step back over the separator the next line starts after. A CRLF is one
        // separator of two code units, and stopping between its halves would put
        // a clamped position inside a character pair the editor treats as one.
        if nextStart - 2 >= start,
           content.character(at: nextStart - 2) == 0x000D,
           content.character(at: nextStart - 1) == 0x000A {
            return nextStart - 2
        }
        return max(start, nextStart - 1)
    }

    /// Binary search for the line whose start is the greatest one `<= offset`.
    ///
    /// Internal — not `private` — because the diagnostics layer reuses it in
    /// exactly this shape (`Diagnostic.make`, `DiagnosticShift.updated`,
    /// `DiagnosticStore.worstSeverityPerLine`): one table, one rule for turning
    /// an offset back into a line, never four copies that can drift. An empty
    /// table (which `lineStarts(in:)` never produces) reads as one line at 0.
    static func lineIndex(containing offset: Int, lineStarts: [Int]) -> Int {
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= offset {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return low
    }
}
