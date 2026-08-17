import Foundation

/// Pure, testable line-start indexing shared by the line-number gutter and the
/// minimap overview, so both count document lines with the *same* separator
/// semantics.
///
/// Lines are split on the standard Unicode separators that `NSString` line
/// enumeration recognizes — LF, CR, the CRLF pair (one separator), NEL,
/// U+2028 (line) and U+2029 (paragraph) — rather than LF alone. This keeps the
/// minimap's line count, the gutter's line count, and TextKit's own layout in
/// agreement even for CR/LS/PS-delimited files (otherwise the minimap and the
/// editor disagree on how many lines exist, which skews the wheel-scroll scale
/// and the token-row alignment).
///
/// UI-free (Foundation only) so it stays in `PisakaCore` and is unit-tested,
/// including an `offsets`-vs-`updated` fuzz equivalence (the incremental path
/// must always reproduce a full rebuild).
public enum LineStartIndex {
    /// UTF-16 start offset of every displayed line in `content`.
    ///
    /// Matches `NSString` `.byLines` enumeration: one entry per line, plus a
    /// trailing entry at `content.length` when the text ends in a separator (the
    /// final empty line). Empty text yields `[0]` (a single blank line). The
    /// count therefore equals the displayed line count.
    public static func offsets(in content: NSString) -> [Int] {
        var offsets: [Int] = []
        content.enumerateSubstrings(
            in: NSRange(location: 0, length: content.length),
            options: [.byLines, .substringNotRequired]
        ) { _, _, enclosingRange, _ in
            offsets.append(enclosingRange.location)
        }
        if offsets.isEmpty {
            // Empty document: a single line starting at 0.
            offsets = [0]
        } else if endsWithLineSeparator(content) {
            offsets.append(content.length)
        }
        return offsets
    }

    /// Whether `content` ends with a line separator (and so has a trailing empty
    /// line). Uses `lineRange`, which recognizes the same separators as
    /// `offsets(in:)`: the last line range starts at `length` exactly when the
    /// preceding character was a separator.
    public static func endsWithLineSeparator(_ content: NSString) -> Bool {
        guard content.length > 0 else { return false }
        let lastLine = content.lineRange(for: NSRange(location: content.length, length: 0))
        return lastLine.location == content.length
    }

    /// Whether `ch` is one of the editor-wide line separators this type splits
    /// lines on: LF, CR (the CRLF pair is two of them), NEL, U+2028 (line) and
    /// U+2029 (paragraph).
    ///
    /// The *exact* set, unlike the deliberately over-inclusive `couldStartLine`
    /// below: callers use this to decide what a character **is**, not whether a
    /// fast path may be taken, so a false positive is a wrong answer rather than a
    /// forfeited shortcut. Public because the same question is asked outside the
    /// line index — `IndentEngine` and `AutoPairEngine` in Core, and the hover
    /// controller's "is the pointer over a character at all" test, which must
    /// agree with TextKit's own layout about where a line ends.
    public static func isLineSeparator(_ ch: unichar) -> Bool {
        switch ch {
        case 0x0A, 0x0D, 0x85, 0x2028, 0x2029:
            return true
        default:
            return false
        }
    }

    /// Incrementally update a cached `offsets` array after a single edit, instead
    /// of rescanning the whole document.
    ///
    /// `editedRange` is the edited span in the *new* string and `changeInLength`
    /// the signed length delta (exactly `NSTextStorage.editedRange` /
    /// `.changeInLength` during `didProcessEditing`). The result always equals
    /// `offsets(in: newText)`: lines before the edit are untouched and lines after
    /// it shift by the delta. A structure-preserving edit (no line break added or
    /// removed — the common keystroke) shifts the suffix without scanning any line
    /// at all; only an edit that adds or removes a line break rescans the affected
    /// line span. So typing into even a multi-megabyte single-line (minified) file
    /// stays cheap, while the per-edit cost is otherwise the inherent flat-array
    /// suffix shift, not a whole-buffer scan.
    ///
    /// Any unexpected input falls back to a full `offsets(in:)` rebuild, which is
    /// always correct, so the cache can never drift out of sync.
    public static func updated(
        previous: [Int],
        editedRange: NSRange,
        changeInLength delta: Int,
        newText content: NSString
    ) -> [Int] {
        let length = content.length
        let loc = editedRange.location
        let newEnd = loc + editedRange.length
        // Fall back to a full rebuild on anything we can't reason about cheaply.
        guard let first = previous.first, first == 0,
              loc >= 0, loc <= length, newEnd >= loc, newEnd <= length else {
            return offsets(in: content)
        }

        // Fast path: the edit changes no line structure, so every cached line
        // start merely shifts. This is the common keystroke (typing a non-break
        // character) and is the only path that stays cheap for a huge single-line
        // (minified) file: it never scans the line, only shifts a flat-array
        // suffix. It applies when (a) the inserted text holds no line break, (b)
        // the deletion removed no line start, and (c) no CRLF pair forms or
        // dissolves at the left boundary. Otherwise we fall through to the
        // line-rescanning path below. Anything missed here is still handled
        // correctly there, so the fast path can only ever be skipped, never wrong.
        if let shifted = shiftOnlyUpdate(
            previous: previous,
            loc: loc,
            newEnd: newEnd,
            delta: delta,
            content: content
        ) {
            return shifted
        }

        // Start of the line containing the edit: the largest cached offset <= loc.
        // Nothing before it changed (the edit begins at `loc`), so earlier line
        // starts stay valid.
        var low = 0
        var high = previous.count
        while low < high {
            let mid = (low + high) / 2
            if previous[mid] <= loc { low = mid + 1 } else { high = mid }
        }
        var anchorIndex = low - 1
        guard anchorIndex >= 0 else { return offsets(in: content) }
        // A cached line start *exactly* at `loc` can be invalidated even though
        // every character before `loc` is unchanged: CRLF is the one Unicode
        // line break that spans two units, so a `CR` just before `loc` can pair
        // with an `LF` the edit brings to `loc` (e.g. deleting the character that
        // sat between them), dissolving the line start at `loc`. Back up one line
        // so that boundary falls *inside* the rescanned span rather than being
        // assumed stable. Position 0 is always a line start, so it never needs it.
        if previous[anchorIndex] == loc, anchorIndex > 0 {
            anchorIndex -= 1
        }
        let anchor = previous[anchorIndex]

        // First line boundary at or after the edited region (new coordinates).
        // `lineRange` never splits a CRLF pair, so this lands on a real separator
        // boundary — the edited span is always a whole number of lines.
        let editLine = content.lineRange(for: NSRange(location: min(newEnd, length), length: 0))
        let scanEnd = NSMaxRange(editLine)
        // Old coordinate of that boundary: the first unchanged line start after
        // the edit. Everything from here on merely shifts by `delta`.
        let oldTailStart = scanEnd - delta
        guard scanEnd >= anchor, scanEnd <= length, oldTailStart >= anchor else {
            return offsets(in: content)
        }

        // Rescan only the affected span [anchor, scanEnd] — the line(s) the edit
        // touched, not the whole buffer. Usually edit-sized, but a structural edit
        // into a very long line is O(that line's length): inserting a break into a
        // multi-megabyte single-line file makes the span run from offset 0 to the
        // end of the document. Only structural edits reach here at all; the common
        // keystroke takes the shift-only fast path above.
        let span = content.substring(with: NSRange(location: anchor, length: scanEnd - anchor)) as NSString
        let rescanned = offsets(in: span).map { $0 + anchor } // first == anchor (kept below)

        var result = Array(previous[0...anchorIndex])
        // The rescanned span's first entry duplicates `anchor`; drop it. Its last
        // entry is `scanEnd`, the boundary shared with the shifted tail.
        result.append(contentsOf: rescanned.dropFirst())
        // Unchanged tail: every old line start strictly past the boundary, shifted.
        for j in (anchorIndex + 1)..<previous.count where previous[j] > oldTailStart {
            result.append(previous[j] + delta)
        }
        return result
    }

    /// Try to satisfy an edit by shifting the cached suffix without rescanning any
    /// line — returns the updated offsets when the edit provably adds and removes
    /// no line start, or `nil` to signal the caller should fall back to the
    /// line-rescanning path. Cost is O(log n) for the boundary checks plus the
    /// inherent O(suffix) flat-array shift; in particular it never scans the
    /// edited line, so typing into a multi-megabyte single-line file stays cheap.
    private static func shiftOnlyUpdate(
        previous: [Int],
        loc: Int,
        newEnd: Int,
        delta: Int,
        content: NSString
    ) -> [Int]? {
        // (a) The inserted span [loc, newEnd) must contain no character that could
        // start a new line. `couldStartLine` is deliberately *over*-inclusive
        // (VT/FF included) so any uncertainty falls back to the proven path.
        var i = loc
        while i < newEnd {
            if couldStartLine(content.character(at: i)) { return nil }
            i += 1
        }

        // (c) A bare CR just before the edit can pair with whatever now follows it
        // (forming/dissolving a CRLF), which is a structural change — fall back.
        if loc > 0, content.character(at: loc - 1) == 0x0D { return nil }

        // First cached line start strictly after `loc`; everything from here shifts.
        var low = 0
        var high = previous.count
        while low < high {
            let mid = (low + high) / 2
            if previous[mid] <= loc { low = mid + 1 } else { high = mid }
        }
        let splitIndex = low

        // (b) No cached line start may sit inside the deleted span (loc, oldEnd];
        // such a line start was carried by a now-deleted separator. The first line
        // start past `loc` is `previous[splitIndex]`; if it lands in that span the
        // deletion removed a line, so fall back.
        let oldEnd = newEnd - delta
        if splitIndex < previous.count, previous[splitIndex] <= oldEnd { return nil }

        // Structure is preserved: keep starts at or before the edit, shift the rest.
        var result = Array(previous[0..<splitIndex])
        for j in splitIndex..<previous.count {
            result.append(previous[j] + delta)
        }
        return result
    }

    /// Whether `ch` could begin a new line under `NSString` `.byLines`
    /// enumeration. Over-inclusive on purpose (covers LF, VT, FF, CR, NEL, LS,
    /// PS): a false positive only forfeits the shift-only fast path for a rare
    /// character, while a false negative would let the fast path diverge from a
    /// full rebuild — so we err toward falling back.
    private static func couldStartLine(_ ch: unichar) -> Bool {
        switch ch {
        case 0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0x2028, 0x2029:
            return true
        default:
            return false
        }
    }
}
