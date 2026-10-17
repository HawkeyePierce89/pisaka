import Foundation

/// One editing command's whole answer: the replacements to make and the
/// selection to leave behind.
///
/// `edits` are sorted by ascending location and never overlap, all against the
/// **original** text's UTF-16 offsets. That is what lets the view apply them
/// **back-to-front** inside a single `shouldChangeText` / `beginEditing` …
/// `endEditing` / `didChangeText` bracket: applying the last one first leaves
/// every earlier range's offsets untouched, and the whole command is one undo
/// step and one change notification. `selections` are expressed in the
/// **resulting** text, ready to hand to `setSelectedRanges`.
///
/// The ordering is **enforced, not trusted**: the initializer refuses an
/// unsorted or overlapping list, so a plan that exists is a plan the applier can
/// apply. Two insertions at the same offset are *not* an overlap — applied
/// back-to-front, they land in list order — and neither is an edit starting
/// exactly where the previous one ends.
///
/// `IndentReplacement` is reused verbatim, as `TabInsertionPlan` and
/// `SaveTransform` already do: a (range, replacement) pair is a (range,
/// replacement) pair whichever engine produced it.
public struct RangeEditPlan: Equatable {
    /// Which side of a replacement an offset sitting at its boundary lands on.
    public enum Bias: Equatable {
        /// Before the replacement: an offset at an edit's start stays in front
        /// of whatever is inserted there.
        case before
        /// After the replacement: an offset at an edit's start moves past what
        /// is inserted there.
        case after
    }

    public let edits: [IndentReplacement]
    public let selections: [NSRange]

    /// `nil` when `edits` are unsorted, overlapping, or carry a negative
    /// location or length.
    public init?(edits: [IndentReplacement], selections: [NSRange]) {
        var previousEnd = 0
        for edit in edits {
            guard edit.range.location >= 0, edit.range.length >= 0 else { return nil }
            guard edit.range.location >= previousEnd else { return nil }
            previousEnd = NSMaxRange(edit.range)
        }
        self.edits = edits
        self.selections = selections
    }

    /// Nothing to do and nothing to select.
    public static let empty = RangeEditPlan(uncheckedEdits: [], selections: [])

    public var isEmpty: Bool { edits.isEmpty }

    /// Where `offset`, an offset into the original text, sits in the resulting
    /// text.
    ///
    /// - Before an edit, it shifts by the net length change of every earlier
    ///   edit.
    /// - Strictly inside a replaced range, it moves to the replacement's start
    ///   (`.before`) or end (`.after`) — the text it pointed into is gone.
    /// - Exactly at an edit's start — always the case for an insertion at that
    ///   offset — `bias` decides: `.before` stays in front of the replacement,
    ///   `.after` moves past it. Several insertions at one offset are passed as
    ///   one: `.before` precedes all of them, `.after` follows all of them.
    /// - At or past a non-empty edit's end, it shifts by that edit's full
    ///   change.
    public func mapped(offset: Int, bias: Bias = .after) -> Int {
        var shift = 0
        for edit in edits {
            let start = edit.range.location
            let end = NSMaxRange(edit.range)
            let inserted = (edit.replacement as NSString).length
            if offset < start { break }
            if offset == start, bias == .before { break }
            if offset < end {
                // Strictly inside the replaced range (or at its start, biased
                // after): the original text there no longer exists.
                return start + shift + (bias == .after ? inserted : 0)
            }
            shift += inserted - edit.range.length
        }
        return offset + shift
    }

    private init(uncheckedEdits: [IndentReplacement], selections: [NSRange]) {
        self.edits = uncheckedEdits
        self.selections = selections
    }
}
