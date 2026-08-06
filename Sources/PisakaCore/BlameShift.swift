import Foundation

/// Pure incremental shift of a git-blame annotation array across a single text
/// edit, so the gutter's annotation column keeps pointing at the lines it was
/// loaded for while the user types — instead of sliding onto neighbouring lines
/// until the next recompute.
///
/// Foundation-only, and deliberately **pure arithmetic over line-start arrays**:
/// no `NSString`, no scanning, no content comparison. The gutter already holds
/// both arrays at the moment of the edit (``LineStartIndex/updated(previous:editedRange:changeInLength:newText:)``
/// produces the new one from the old one), so passing them in costs nothing and
/// buys the structural invariant that makes the result safe to index by line:
///
/// > `result.count == newLineStarts.count`, always.
///
/// ## The touched span
///
/// With `loc = editedRange.location` and `oldEnd = loc + editedRange.length -
/// changeInLength` (the end of the replaced region in **pre-edit** coordinates):
///
/// - `first` is the index of the last `previousLineStarts <= loc` — the line the
///   edit begins in.
/// - `last` is the index of the last `previousLineStarts <= max(loc, oldEnd - 1)`
///   — the line containing the **last character actually removed**, not the
///   position just past it.
///
/// **Why `oldEnd - 1`, clamped up to `loc`.** `oldEnd` is an exclusive bound, so
/// on a whole-line deletion it lands exactly on the *next* line's start and pulls
/// an untouched line into the span. With line starts `[0, 10, 20, 30]`, deleting
/// line 1 entirely (`loc = 10`, removing 10 units, `oldEnd = 20`) would give
/// `last = 2` under an `oldEnd` rule, and old line 2's annotation — whose content
/// survived the edit intact — would be discarded with the span. With
/// `max(loc, oldEnd - 1) = 19` the span is `1…1`, contributes zero new lines, and
/// old lines 2–3 pass through the untouched-suffix branch carrying their own
/// annotations. The `max(loc, …)` clamp is what keeps a pure **insertion**
/// correct (`oldEnd == loc`, so a bare `oldEnd - 1` would reach back into the
/// *previous* line and drag it into the span): there `last == first`, one line
/// touched.
///
/// Lines before `first` and lines after `last` are kept verbatim — their content
/// is untouched, only their index shifts by the line-count delta — so neither can
/// migrate onto a foreign line.
///
/// ## Annotations survive only when the span's line count is unchanged
///
/// The span's new length is derived from the arrays rather than guessed:
/// `newSpanLength = newLineStarts.count - first - (previous.count - last - 1)`.
/// When it equals `last - first + 1` the edit was **structure-preserving** inside
/// the span (no line break added or removed there), so the span's old
/// annotations are copied over position for position: an ordinary keystroke
/// leaves the line's annotation in place, which is the deliberate,
/// ticket-sanctioned inaccuracy the post-save recompute fixes. When the count
/// differs — an Enter split, a line inserted at a line start, a multi-line paste,
/// a deletion joining two lines, a whole-line deletion (`newSpanLength == 0`,
/// contributing nothing at all) — the **whole span becomes `nil`**.
///
/// **Why not "the first touched line keeps its annotation".** That weaker rule
/// looks harmless but hands a real annotation to a line the user just created:
/// inserting at a line start, or pressing Enter at column 0, makes the *first*
/// new line a brand-new empty line that would then be attributed to the previous
/// line's commit. Tying survival to an unchanged line count makes it a structural
/// property — an annotation survives only where the line's index within the span
/// and the span's shape are both unchanged — at the cost of blanking a joined
/// line's annotation, which the next save recomputes anyway. **Blank is honest; a
/// wrong author is not.**
///
/// The one boundary the arithmetic cannot see: a deletion of *exactly* a line
/// separator (Backspace at column 0) removes the following line's start without
/// its index falling inside the span, so the joined line inherits the **second**
/// line's annotation rather than blanking. Distinguishing that from a whole-line
/// deletion needs the line's content, which this function deliberately does not
/// read; the next recompute settles it.
///
/// ## Fallback
///
/// Any inconsistent input returns `[BlameLine?](repeating: nil, count:
/// newLineStarts.count)`: an honest "unknown" at the right length, never a
/// drifted array. Precisely, the checks are `previous.count !=
/// previousLineStarts.count`; a line-start array not anchored at `0` (including
/// an empty one); a negative `editedRange.location` or `length`; an `oldEnd`
/// that comes out before `loc` (or whose arithmetic overflows, which a
/// degenerate `NSNotFound` range would); and a negative `newSpanLength`.
///
/// Note what is deliberately *not* checked: an edit lying wholly **past the end**
/// of the previous text. Line starts alone do not carry the buffer's length, so
/// detecting it would mean a further parameter for a case the only caller cannot
/// produce (`NSTextStorage.editedRange` is by construction in range). Such an
/// edit clamps to the final line and yields a shifted array rather than the blank
/// one — the reason this list is spelled out rather than summarized as
/// "out-of-range".
public enum BlameShift {
    /// Shift `previous` across one edit, given the line starts on both sides of
    /// it. `editedRange` is the edited span in the **new** text and
    /// `changeInLength` the signed length delta — exactly
    /// `NSTextStorage.editedRange` / `.changeInLength` during `didProcessEditing`.
    public static func updated(
        previous: [BlameLine?],
        previousLineStarts: [Int],
        newLineStarts: [Int],
        editedRange: NSRange,
        changeInLength delta: Int
    ) -> [BlameLine?] {
        // Built only on the guard paths that return it: this runs once per
        // keystroke, and eagerly materializing a one-`nil`-per-line array the
        // common path immediately discards would cost, on a large file, exactly
        // the whole-document work the incremental shift exists to avoid.
        func blank() -> [BlameLine?] {
            [BlameLine?](repeating: nil, count: max(0, newLineStarts.count))
        }

        guard previous.count == previousLineStarts.count,
              previousLineStarts.first == 0,
              newLineStarts.first == 0,
              editedRange.location >= 0,
              editedRange.length >= 0
        else { return blank() }

        let loc = editedRange.location
        // Pre-edit end of the replaced region. A well-formed edit can never have
        // replaced a negative-length span. The arithmetic is overflow-checked
        // rather than plain: a degenerate range (`NSNotFound`, i.e. `Int.max`)
        // would otherwise trap instead of falling back.
        let (replacedEnd, endOverflowed) = loc.addingReportingOverflow(editedRange.length)
        guard !endOverflowed else { return blank() }
        let (oldEnd, deltaOverflowed) = replacedEnd.subtractingReportingOverflow(delta)
        guard !deltaOverflowed, oldEnd >= loc else { return blank() }

        let first = lastIndex(in: previousLineStarts, notAfter: loc)
        let last = lastIndex(in: previousLineStarts, notAfter: max(loc, oldEnd - 1))
        let suffixCount = previous.count - last - 1
        let newSpanLength = newLineStarts.count - first - suffixCount
        guard newSpanLength >= 0 else { return blank() }

        if newSpanLength == last - first + 1 {
            // Structure-preserving inside the span: every line kept its index
            // there, so every annotation keeps its line — and the prefix and the
            // suffix keep theirs by definition. The result is therefore *exactly*
            // `previous`: the three pieces it would be assembled from
            // (`previous[0..<first]`, `previous[first...last]`,
            // `previous[(last + 1)...]`) are contiguous slices covering the whole
            // array, and the branch condition forces the lengths to agree —
            // `newLineStarts.count == newSpanLength + first + suffixCount ==
            // (last - first + 1) + first + (previous.count - last - 1) ==
            // previous.count` — so the `result.count == newLineStarts.count`
            // invariant holds for `previous` itself.
            //
            // Returning it is not a micro-optimization: this is the *ordinary
            // keystroke* path, running on the main actor for every character typed
            // while annotate is on, and a `BlameLine?` carries four `String`
            // references. Rebuilding it would spend one whole-document allocation
            // plus four retain/release pairs per line on reproducing the array
            // that was passed in — the very whole-document work the incremental
            // shift (and the lazily-built `blank()` above) exists to avoid. With
            // COW the caller's re-assignment then costs nothing.
            return previous
        }

        var result: [BlameLine?] = []
        result.reserveCapacity(newLineStarts.count)
        result.append(contentsOf: previous[0..<first])
        result.append(contentsOf: [BlameLine?](repeating: nil, count: newSpanLength))
        result.append(contentsOf: previous[(last + 1)...])
        return result
    }

    /// Index of the last entry `<= value`. `starts` is ascending and anchored at
    /// `0` (checked by the caller) and `value >= 0`, so index `0` always
    /// qualifies and the result is never negative.
    private static func lastIndex(in starts: [Int], notAfter value: Int) -> Int {
        var low = 0
        var high = starts.count
        while low < high {
            let mid = (low + high) / 2
            if starts[mid] <= value { low = mid + 1 } else { high = mid }
        }
        return low - 1
    }
}
