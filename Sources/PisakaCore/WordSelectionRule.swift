import Foundation

/// What a double-click (word granularity) selects in the code editor: exactly
/// one identifier, by `IdentifierScanner`'s boundary rule — the same rule a
/// ⌘-click, a completion prefix and a usage scan already use.
///
/// The platform's own word granularity is a prose rule: it runs a word across
/// a `.` in `z.object`, through `::` and `->`, and splits `$store` in a
/// JavaScript file. This rule answers the editor's question instead and leaves
/// the platform's answer in place wherever there is no identifier to answer
/// with, so punctuation, whitespace and numbers keep selecting as they always
/// did.
///
/// Pure, Foundation-only, `NSString`/UTF-16 like every other editor engine, so
/// the range it returns is handed straight back to the text view.
public enum WordSelectionRule {

    /// The word-granularity selection for `proposed`.
    ///
    /// - A **click** — an empty or one-character proposal — on an identifier
    ///   character answers that identifier. Only the character the click lands
    ///   *on* counts (`IdentifierScanner.identifier(in:containing:)`), so a
    ///   click on the `.` right after `z` does not select `z`.
    /// - A **drag** snaps each end that lies inside an identifier out to that
    ///   identifier's bound; an end that does not keeps the platform's bound.
    ///   The end is judged by the last character the drag covers, not by the
    ///   offset past it.
    /// - When neither end lies in an identifier the answer is `platformRange`
    ///   unchanged — the platform's behaviour exactly.
    ///
    /// `platformRange` is what the platform's own word granularity proposed for
    /// the same gesture. Offsets out of the text are clamped by the scanner.
    public static func range(
        proposed: NSRange,
        platformRange: NSRange,
        text: NSString,
        language: SyntaxLanguage?
    ) -> NSRange {
        if proposed.length <= 1 {
            return IdentifierScanner.identifier(in: text, containing: proposed.location, language: language)?.range
                ?? platformRange
        }

        let startWord = IdentifierScanner.identifier(in: text, containing: proposed.location, language: language)
        let endWord = IdentifierScanner.identifier(
            in: text, containing: NSMaxRange(proposed) - 1, language: language
        )
        guard startWord != nil || endWord != nil else { return platformRange }

        let start = startWord?.range.location ?? platformRange.location
        let end = endWord.map { NSMaxRange($0.range) } ?? NSMaxRange(platformRange)
        return NSRange(location: start, length: max(end - start, 0))
    }
}
