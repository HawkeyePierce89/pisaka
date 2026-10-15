import Foundation

/// Whether the next keystroke's completion is answered by narrowing the list
/// the editor already holds, by asking the provider again, or by neither.
///
/// A language server that answered a prefix with `isIncomplete == false` has
/// said that its list holds everything a longer spelling of the same word can
/// match, so typing on inside that word needs no second round trip — the
/// provider re-ranks the list it kept (`CodeIntelligenceProviding.narrow`). A
/// backspace that stays inside the answered word is the same situation read the
/// other way: the list was answered for a longer word, and the shorter one is a
/// prefix of it, so the server's own matching was looser than or equal to what
/// is now typed.
///
/// Everything that makes the situation *new* asks again: a different word
/// (its start moved), an explicit invocation, a trigger character, a newline, a
/// caret that jumped rather than typed. Those are exactly the cases in which a
/// server may answer differently from the same items, so narrowing them would
/// be answering a question nobody asked it.
public enum CompletionNarrowingRule {
    public enum Decision: Equatable, Sendable {
        /// Re-rank the retained list for the new word; no request.
        case narrow
        /// Make an ordinary (debounced) request, as before narrowing existed.
        case request
        /// Forget the retained list.
        ///
        /// **Only that.** It carries no instruction about what the popup does
        /// next: the caller forgets the list and then follows whatever path it
        /// already takes for an empty typed word, unchanged — dismissing,
        /// requesting or anything else that path does today.
        case dropRetained
    }

    /// - Parameters:
    ///   - retained: The list the editor holds, or `nil`.
    ///   - wordStart: The UTF-16 offset where the typed word now starts.
    ///   - typed: The typed word now standing left of the caret.
    ///   - explicit: The user asked for completion (a shortcut), rather than typing.
    ///   - typedTriggerCharacter: The keystroke was a trigger character (a `.`).
    ///   - insertedNewline: The edit inserted a line break.
    ///   - caretJumped: The caret moved other than by the typing itself.
    public static func decide(
        retained: RetainedCompletionList?,
        wordStart: Int,
        typed: String,
        explicit: Bool,
        typedTriggerCharacter: Bool,
        insertedNewline: Bool,
        caretJumped: Bool
    ) -> Decision {
        guard !typed.isEmpty else { return .dropRetained }
        guard let retained else { return .request }
        guard !explicit, !typedTriggerCharacter, !insertedNewline, !caretJumped else {
            return .request
        }
        guard wordStart == retained.wordStart else { return .request }
        // Compared in UTF-16 units, the coordinates every offset here is in, so a
        // composed and a decomposed spelling never read as the same word.
        let now = Array(typed.utf16)
        let answered = Array(retained.typed.utf16)
        let extends = now.starts(with: answered)
        let shortens = answered.starts(with: now)
        return extends || shortens ? .narrow : .request
    }
}
