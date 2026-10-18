import Foundation

/// Pure incremental shift of a git-blame annotation array across a single text
/// edit, so the gutter's annotation column keeps pointing at the lines it was
/// loaded for while the user types. The arithmetic — the touched span, the
/// `oldEnd - 1` clamp, "blank is honest; a wrong author is not" and the
/// fallbacks — lives in ``LineShift``, generic over the payload; this is its
/// blame-typed delegate, kept so the ruler and `BlameShiftTests` are untouched.
public enum BlameShift {
    /// Shift `previous` across one edit — ``LineShift/updated(previous:previousLineStarts:newLineStarts:editedRange:changeInLength:)``
    /// at `BlameLine`.
    public static func updated(
        previous: [BlameLine?],
        previousLineStarts: [Int],
        newLineStarts: [Int],
        editedRange: NSRange,
        changeInLength delta: Int
    ) -> [BlameLine?] {
        LineShift.updated(
            previous: previous,
            previousLineStarts: previousLineStarts,
            newLineStarts: newLineStarts,
            editedRange: editedRange,
            changeInLength: delta
        )
    }
}
