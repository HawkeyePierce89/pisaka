import Foundation

/// Pure incremental shift of one document's diagnostics across a single text
/// edit, so the squiggles keep pointing at the code they were reported for while
/// the user types — instead of drifting onto neighbouring tokens until the next
/// push arrives, or blinking off wholesale on every keystroke (D32).
///
/// The rule is deliberately three-way, not blanket:
///
/// - a diagnostic **entirely before** the edit is unchanged — its code is
///   untouched, byte for byte;
/// - a diagnostic **entirely after** the edit is shifted by `changeInLength` and
///   renumbered from `newLineStarts`;
/// - a diagnostic whose range **intersects** the touched span is dropped.
///
/// So the error being fixed loses its underline on the first keystroke (the edit
/// touches its span) while errors elsewhere stay anchored to their code — rather
/// than either drifting (no shift) or vanishing on every keystroke (a blanket
/// clear). D32 rejects replaying an edit queue onto a late-arriving push as
/// exact but heavy; this function is the cheap half of that bargain, correct for
/// every edit *after* the push, self-correcting for edits between the sync and
/// the push because the model refuses such pushes outright (D31/D32's revision
/// gate).
///
/// Foundation-only, and pure arithmetic over offsets and line-start tables — no
/// `NSString`, no content comparison — because the editor coordinator already
/// holds both tables at the moment of the edit (`LineStartIndex.updated(...)`
/// produces the new one from the old one), exactly as ``BlameShift`` does for
/// blame annotations. This is that function's shape applied to offset-addressed
/// spans instead of line-indexed annotations; where blame blanks a *line*, this
/// drops a *range*, which is why it takes the diagnostics themselves and not a
/// per-line array.
///
/// ## The touched span
///
/// With `loc = editedRange.location` and
/// `oldEnd = loc + editedRange.length - changeInLength` (the end of the replaced
/// region in **pre-edit** coordinates — `editedRange` is the edited span in the
/// *new* text, `NSTextStorage.editedRange`'s contract):
///
/// - "entirely before" is `diag.end <= loc`;
/// - "entirely after" is `diag.start >= oldEnd`;
/// - anything else intersects `[loc, oldEnd)` and is dropped.
///
/// Both comparisons are **half-open**, and the half-openness is load-bearing at
/// both edges: a diagnostic ending exactly at `loc` covers only characters the
/// edit did not touch, and a diagnostic starting exactly at `oldEnd` covers only
/// characters the edit did not remove. A zero-length diagnostic sitting exactly
/// at the insertion point therefore survives (`loc < oldEnd` fails for a pure
/// insertion), and one sitting exactly at a deletion's start survives too
/// (`end <= loc` holds) — an underline under the caret is stale-looking but not
/// wrong, while dropping it would blink on ordinary typing at the caret.
///
/// ## Renumbering
///
/// A shifted survivor's range moves by `changeInLength` (both bounds), and its
/// `line` is recomputed from `newLineStarts` — the table the caller passes, so a
/// survivor lands on the line the *editor* says it is on now. An untouched
/// survivor keeps its stored `line`: nothing before `loc` moved, so re-deriving
/// it could only launder a divergence, not fix one. Note the two numberings can
/// disagree in principle (a diagnostic's `line` comes from LSP's separator set
/// via `LSPPositionMap`; `newLineStarts` may be the editor's wider set) — the
/// bounded D1 divergence already documented on `Diagnostic`, invisible here
/// because no line number from either table is printed without going through
/// the ruler's own geometry.
///
/// ## Fallback
///
/// Any inconsistent input returns `[]` — the honest "unknown", never a drifted
/// set. Precisely, the checks are: a line-start array that is empty or not
/// anchored at `0` (either side); a negative `editedRange.location` or
/// `.length`; an `oldEnd` that comes out before `loc` or whose arithmetic
/// overflows (which a degenerate `NSNotFound`-sized range would); and any
/// single diagnostic whose end offset or shifted bounds overflow. One bad entry
/// poisons the whole answer on purpose: the callers re-sync on the next typing
/// pause anyway, and a partially-shifted array looks exactly like truth.
///
/// Note what is deliberately *not* checked: an edit lying wholly **past the end**
/// of the previous text, or a survivor landing past the new buffer's length.
/// Line-start tables alone carry no buffer length, so detecting either needs a
/// further parameter for cases the only caller cannot produce
/// (`NSTextStorage.editedRange` is by construction in range; a survivor was
/// clamped into the buffer when it was mapped). Such input yields a shifted set,
/// not the fallback — the reason this list is spelled out rather than summarized
/// as "out-of-range".
public enum DiagnosticShift {
    /// Shift `diagnostics` across one edit, given the line starts on both sides
    /// of it. `editedRange` is the edited span in the **new** text and
    /// `changeInLength` the signed length delta — exactly what
    /// `NSTextStorage` reports during `didProcessEditing`.
    ///
    /// `previousLineStarts` takes part in the consistency gate only: unlike
    /// blame's per-line array, a diagnostic is never indexed *by* the table. It
    /// is a parameter nonetheless because the caller holds both tables at the
    /// moment of the edit (the ruler does, for ``BlameShift``), because
    /// requiring both keeps the two shifters' call sites interchangeable, and
    /// because a broken table on either side means the caller's bookkeeping is
    /// broken — the same honesty the rest of the fallback encodes.
    public static func updated(
        _ diagnostics: [Diagnostic],
        previousLineStarts: [Int],
        newLineStarts: [Int],
        editedRange: NSRange,
        changeInLength delta: Int
    ) -> [Diagnostic] {
        guard previousLineStarts.first == 0,
              newLineStarts.first == 0,
              editedRange.location >= 0,
              editedRange.length >= 0
        else { return [] }

        let loc = editedRange.location
        // Pre-edit end of the replaced region, overflow-checked rather than
        // plain: a degenerate range (`NSNotFound`, i.e. `Int.max`) must fall to
        // the fallback, not trap.
        let (replacedEnd, endOverflowed) = loc.addingReportingOverflow(editedRange.length)
        guard !endOverflowed else { return [] }
        let (oldEnd, deltaOverflowed) = replacedEnd.subtractingReportingOverflow(delta)
        guard !deltaOverflowed, oldEnd >= loc else { return [] }

        var result: [Diagnostic] = []
        result.reserveCapacity(diagnostics.count)
        for diagnostic in diagnostics {
            let start = diagnostic.range.location
            let (end, diagEndOverflowed) = start.addingReportingOverflow(diagnostic.range.length)
            guard !diagEndOverflowed else { return [] }
            if end <= loc {
                result.append(diagnostic)
                continue
            }
            guard start < oldEnd else {
                let (newStart, startOverflowed) = start.addingReportingOverflow(delta)
                // The length never changes, but the shifted end must not
                // overflow either — a guard, not a used value.
                let (_, endShiftOverflowed) = end.addingReportingOverflow(delta)
                guard !startOverflowed, !endShiftOverflowed else { return [] }
                var shifted = diagnostic
                shifted.range = NSRange(location: newStart, length: diagnostic.range.length)
                shifted.line = lineIndex(containing: newStart, lineStarts: newLineStarts)
                result.append(shifted)
                continue
            }
            // Intersects the touched span: dropped (D32). Nothing appended.
        }
        return result
    }

    /// Index of the last entry whose start is `<= offset`. `lineStarts` is
    /// ascending and anchored at `0` (checked above) and `offset >= 0`, so index
    /// `0` always qualifies and the result is never negative.
    private static func lineIndex(containing offset: Int, lineStarts: [Int]) -> Int {
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low
    }
}
