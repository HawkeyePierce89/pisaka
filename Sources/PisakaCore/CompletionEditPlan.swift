import Foundation

/// One buffer edit a completion item performs when it is committed.
///
/// Buffer coordinates, UTF-16, absolute — *not* LSP positions. The conversion
/// happens once, in the LSP provider, so nothing downstream of the seam has to
/// know what a line is: by the time an edit reaches the editor it is an
/// `NSRange` the text view can act on directly.
public struct CompletionEdit: Equatable, Hashable, Sendable {
    /// What an edit is *for*, which is the only thing that decides where the
    /// caret ends up.
    ///
    /// D4's rule — "the caret lands after the inserted symbol, never at the
    /// import" — cannot be recovered from the ranges alone: an import inserted
    /// at offset 0 and a symbol completed at offset 0 of an empty file are
    /// indistinguishable geometrically. So the provider labels the one edit that
    /// is the completion itself, and everything else is an accompaniment.
    public enum Role: Equatable, Hashable, Sendable {
        /// The replacement of the typed word by the completed text. Exactly one
        /// per plan.
        case primary
        /// An `additionalTextEdits` entry — an `import` line, a qualifier.
        case additional
    }

    /// The UTF-16 buffer range this edit replaces; zero-length for an insertion.
    public let range: NSRange
    /// The text that replaces `range`. Always plain text: no snippet support is
    /// advertised (D5), so nothing here needs `${1:…}` stripping.
    public let newText: String
    /// Whether this is the completion itself or something it drags along.
    public let role: Role

    public init(range: NSRange, newText: String, role: Role) {
        self.range = range
        self.newText = newText
        self.role = role
    }

    /// How much the buffer's length changes when this edit is applied.
    var delta: Int { (newText as NSString).length - range.length }

    /// This edit re-expressed against a buffer in which the typed word has
    /// already been replaced by `length` UTF-16 units of other text.
    ///
    /// The edits a provider hands back are in the coordinates of the buffer the
    /// *request* was made against, and by the time one is committed the editor
    /// itself may have written over the typed word twice: AppKit inserts a
    /// **preview** of the highlighted row as the user arrows through the popup
    /// (`insertCompletion(…, isFinal: false)`), and an item whose auto-import
    /// arrives late (D4's stated race) is applied on top of an insertion that
    /// has already happened. Both replace exactly the typed word and nothing
    /// else, so both are one number — the length now standing where `typedWord`
    /// stood — and every offset past that word moves by the difference.
    ///
    /// Only three shapes are possible, because a plan's edits never overlap and
    /// the primary one covers the typed word entirely: an edit wholly before it
    /// (an `import` line) is untouched, an edit wholly after it slides, and the
    /// primary edit — the only one that can span the boundary — grows or shrinks
    /// by the same amount. An edit that starts inside the typed word cannot
    /// occur in a plan that validates; it is shifted as "before" here and
    /// `CompletionEditPlan.make` then refuses it for overlapping the primary.
    ///
    /// **The primary edit is recognised by its role, not by its geometry**, and
    /// that is what makes an *empty* typed word work. A member list opened by a
    /// bare `.` replaces nothing (`typedWord.length == 0`), so the word's start,
    /// its end and the caret are all the same number — and the primary edit, a
    /// zero-length insertion sitting on it, is geometrically indistinguishable
    /// from an edit "wholly after the word". Read as the latter it would slide
    /// past the preview it is supposed to replace, `make` would reject the plan
    /// for `primaryEditMissesTypedWord`, and the item's `import` would be
    /// silently dropped on exactly the completion kind that has no prefix.
    public func shifted(afterReplacingTypedWord typedWord: NSRange, withLength length: Int) -> CompletionEdit {
        let delta = length - typedWord.length
        guard delta != 0 else { return self }
        let boundary = NSMaxRange(typedWord)
        if role == .primary, range.location <= typedWord.location, NSMaxRange(range) >= boundary {
            return CompletionEdit(
                range: NSRange(location: range.location, length: range.length + delta),
                newText: newText,
                role: role
            )
        }
        if range.location >= boundary {
            return CompletionEdit(
                range: NSRange(location: range.location + delta, length: range.length),
                newText: newText,
                role: role
            )
        }
        if NSMaxRange(range) >= boundary {
            return CompletionEdit(
                range: NSRange(location: range.location, length: range.length + delta),
                newText: newText,
                role: role
            )
        }
        return self
    }
}

/// The ordered application of a completion item's edits, and where the caret
/// ends up afterwards.
///
/// Pure and Foundation-only, so the whole auto-import rule is unit-tested
/// without an `NSTextView`: the editor's job shrinks to "raise the programmatic
/// edit flag, open one undo group, apply `edits` in order, set the selection to
/// `caretOffset`".
///
/// **Edits are ordered strictly last-to-first**, the same rule `TextSearch`'s
/// Replace All follows and for the same reason: each edit then lies entirely
/// before every edit already applied, so no pending offset is ever invalidated
/// by a length change and the caller needs no offset arithmetic of its own.
/// `caretOffset` is the one number that *is* computed against the final buffer,
/// because the caret is placed once, at the end.
public struct CompletionEditPlan: Equatable, Sendable {
    /// Every edit, ordered last-to-first by location. Apply them in this order.
    public let edits: [CompletionEdit]
    /// The UTF-16 offset the caret takes after all of `edits` are applied: just
    /// past the primary edit's inserted text, shifted by whatever the edits
    /// before it added or removed.
    public let caretOffset: Int

    /// Why a plan could not be made. Every case means the same thing to the
    /// caller — *do not apply anything* — but they are distinct so a test can
    /// say which rule fired, and so a future log line can be specific.
    ///
    /// Rejection is a safe outcome, not an error worth surfacing: the editor
    /// falls back to AppKit's own insertion of the item's plain text, which
    /// loses the auto-import and nothing else.
    public enum Rejection: Error, Equatable, Sendable {
        /// No edit is labelled `.primary` — there is nothing to complete, and
        /// therefore nowhere to put the caret.
        case noPrimaryEdit
        /// More than one edit claims to be the completion itself.
        case multiplePrimaryEdits
        /// An edit's range lies outside the buffer (negative, or past the end).
        case outOfRange
        /// Two edits cover the same characters, or begin at the same offset —
        /// in either case which one "wins" is undefined, and guessing would
        /// corrupt the buffer rather than merely mis-order it.
        case overlappingEdits
        /// The buffer no longer reads the way the request that produced these
        /// edits saw it: the typed word is gone, moved, or is now different
        /// text. The offsets are stale, so applying them would edit whatever
        /// happens to sit at those numbers now.
        case bufferChanged
        /// The completion would not replace the word the user typed, leaving
        /// the prefix behind as duplicated text.
        case primaryEditMissesTypedWord
    }

    /// Build the plan for `edits` against `text`, where `typedWord` is the
    /// partial word the completion replaces and `typed` is what that range
    /// contained when the request was made.
    ///
    /// `typed` is the staleness gate, and it is checked against the *buffer*
    /// rather than trusted: a completion list is computed behind a debounce and
    /// committed by a keystroke some time later, so between the two the user may
    /// have typed, deleted, or undone. Comparing the range's current contents to
    /// what the request saw catches every one of those for the price of one
    /// substring — the same per-item staleness re-check `ProjectSearchModel`
    /// does before it replaces.
    ///
    /// The primary edit must *cover* `typedWord`. A server is free to answer
    /// with a range wider than the client's prefix (it decides what the
    /// completion replaces, and for a member access that can reach back past the
    /// dot), but one that reaches less far would leave the typed characters in
    /// the buffer with the completion appended to them — `fooFooBar` — which is
    /// worse than not auto-importing.
    public static func make(
        edits: [CompletionEdit],
        in text: NSString,
        replacing typedWord: NSRange,
        typed: String
    ) -> Result<CompletionEditPlan, Rejection> {
        let length = text.length

        guard typedWord.location >= 0, typedWord.length >= 0, NSMaxRange(typedWord) <= length else {
            return .failure(.bufferChanged)
        }
        guard text.substring(with: typedWord) == typed else { return .failure(.bufferChanged) }

        let primaries = edits.filter { $0.role == .primary }
        guard !primaries.isEmpty else { return .failure(.noPrimaryEdit) }
        guard primaries.count == 1, let primary = primaries.first else {
            return .failure(.multiplePrimaryEdits)
        }

        for edit in edits {
            guard edit.range.location >= 0,
                  edit.range.length >= 0,
                  NSMaxRange(edit.range) <= length
            else { return .failure(.outOfRange) }
        }

        guard primary.range.location <= typedWord.location,
              NSMaxRange(primary.range) >= NSMaxRange(typedWord)
        else { return .failure(.primaryEditMissesTypedWord) }

        let ascending = edits.sorted {
            $0.range.location != $1.range.location
                ? $0.range.location < $1.range.location
                : $0.range.length < $1.range.length
        }
        var previousLocation: Int?
        var previousEnd: Int?
        for edit in ascending {
            // Two edits beginning at the same offset are refused even when
            // neither covers a character: their order is undefined (a zero-length
            // insertion at the start of a replaced range could land either side
            // of it), and the spec gives a server no way to say which it meant.
            if edit.range.location == previousLocation { return .failure(.overlappingEdits) }
            if let previousEnd, edit.range.location < previousEnd { return .failure(.overlappingEdits) }
            previousLocation = edit.range.location
            previousEnd = NSMaxRange(edit.range)
        }

        // Non-overlapping means every other edit lies wholly before or wholly
        // after the primary one; only the ones before it move the caret.
        let shift = edits
            .filter { $0.role != .primary && NSMaxRange($0.range) <= primary.range.location }
            .reduce(0) { $0 + $1.delta }
        let caret = primary.range.location + (primary.newText as NSString).length + shift

        return .success(
            CompletionEditPlan(
                edits: ascending.reversed(),
                caretOffset: caret
            )
        )
    }
}
