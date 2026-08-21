import Foundation

/// What the editor should do when a single character is typed, as decided by the
/// pure `AutoPairEngine`. The view layer turns each case into a programmatic edit.
///
/// - `wrap`: a non-empty selection is present and the typed character opens a pair
///   (bracket or quote); surround the selection with `open` … `close`.
/// - `insertPair`: insert the typed opener plus its `close`, leaving the caret
///   between them.
/// - `typeOver`: the typed closer/quote already sits immediately after the caret;
///   step over it instead of inserting a duplicate.
/// - `passthrough`: let the keystroke insert normally (no auto-pair behavior).
public enum AutoPairAction: Equatable {
    case wrap(open: String, close: String)
    case insertPair(close: String)
    case typeOver
    case passthrough
}

/// Pure, testable auto-close decision logic for the editor — Foundation only, so
/// it stays in `PisakaCore` and is unit-tested without any AppKit/Neon dependency.
///
/// Like `IndentEngine`/`LineStartIndex`, it operates on an `NSString` and UTF-16
/// offsets and splits document lines with the same Unicode separator semantics.
/// Bracket/quote matching counts *raw* characters — there is no string/comment
/// awareness (no lexer) — matching the deliberately simple, language-agnostic
/// scope of the rest of the editor; the quote heuristics below are what stand in
/// for that missing context.
public enum AutoPairEngine {
    /// Opening bracket → its matching closer.
    static let openerToCloser: [Character: String] = [
        "(": ")", "[": "]", "{": "}"
    ]
    /// Closing bracket → its matching opener.
    static let closerToOpener: [Character: Character] = [
        ")": "(", "]": "[", "}": "{"
    ]
    /// Quote characters that close themselves.
    static let quotes: Set<Character> = ["\"", "'", "`"]

    /// Decide what to do when `typed` is about to be inserted, replacing
    /// `selectedRange` (a bare caret when its length is 0).
    ///
    /// - Non-single-character `typed` → `.passthrough` (paste, IME, etc.).
    /// - Opener: a non-empty selection wraps; otherwise insert the pair when the
    ///   following position *can close* (so an opener before a word does not
    ///   strand a closer), else passthrough.
    /// - Closer: with a non-empty selection, passthrough (the typed closer
    ///   replaces the selection normally); otherwise step over an identical closer
    ///   sitting immediately after the caret, else passthrough.
    /// - Quote: a non-empty selection wraps; otherwise step over an identical
    ///   quote immediately after the caret, else insert the pair when the quote
    ///   *can close* (and is not completing a word, e.g. `don'`), else passthrough.
    public static func action(text: NSString, selectedRange: NSRange, typed: String) -> AutoPairAction {
        guard typed.count == 1, let ch = typed.first else { return .passthrough }

        // Clamp the location first, then add the (already non-negative) length to
        // the clamped start so a degenerate range (e.g. `NSNotFound`/`Int.max`
        // location, or `Int.min` length) can never overflow before clamping.
        let start = max(0, min(selectedRange.location, text.length))
        let length = max(0, selectedRange.length)
        let end = start + min(length, text.length - start)
        let hasSelection = end > start

        if let closer = openerToCloser[ch] {
            if hasSelection { return .wrap(open: String(ch), close: closer) }
            return canClose(text: text, at: end) ? .insertPair(close: closer) : .passthrough
        }

        if closerToOpener[ch] != nil {
            // A non-empty selection must replace, not step over: `.typeOver` only
            // moves the caret, so it would drop the keystroke and leave the
            // selection intact. Mirror the opener/quote branches' `hasSelection`
            // guard and let the normal replace-selection proceed.
            if hasSelection { return .passthrough }
            return character(in: text, at: end) == ch ? .typeOver : .passthrough
        }

        if quotes.contains(ch) {
            if hasSelection { return .wrap(open: String(ch), close: String(ch)) }
            if character(in: text, at: end) == ch { return .typeOver }
            return canCloseQuote(text: text, caret: start, at: end) ? .insertPair(close: String(ch)) : .passthrough
        }

        return .passthrough
    }

    /// Whether Backspace at `location` (an empty selection) sits between an
    /// auto-inserted empty pair — `(|)`, `"|"`, … — so both characters should be
    /// removed together. False when the neighbors are not a matching pair, the
    /// caret is at a buffer boundary, or there is content between them.
    public static func shouldDeletePair(text: NSString, location: Int) -> Bool {
        // Guard the bounds before any arithmetic so a degenerate `location`
        // (e.g. `Int.min`) can't underflow on `location - 1`.
        guard location >= 1, location < text.length else { return false }
        let before = location - 1
        let after = location
        guard let b = character(in: text, at: before), let a = character(in: text, at: after) else { return false }
        if let closer = openerToCloser[b] { return String(a) == closer }
        if quotes.contains(b) { return a == b }
        return false
    }

    /// The position `at` is a valid place to drop a closer: end-of-buffer, a line
    /// separator, whitespace, or an existing closing bracket. Anything else (a
    /// letter, digit, opener, quote) means real content follows, so auto-closing
    /// would strand the inserted closer.
    private static func canClose(text: NSString, at index: Int) -> Bool {
        if index >= text.length { return true }
        let ch = text.character(at: index)
        if isLineSeparator(ch) { return true }
        if let scalar = UnicodeScalar(ch) {
            // Any Unicode whitespace (space, tab, NBSP, other Zs) is not real
            // content, so an opener before it can still auto-close.
            if CharacterSet.whitespaces.contains(scalar) { return true }
            if closerToOpener[Character(scalar)] != nil { return true }
        }
        return false
    }

    /// `canClose`, plus the character immediately before the caret must not be
    /// alphanumeric — so an apostrophe completing a word (`don'`) passes through
    /// rather than auto-closing into `don''`.
    private static func canCloseQuote(text: NSString, caret: Int, at index: Int) -> Bool {
        guard canClose(text: text, at: index) else { return false }
        if let scalar = scalarBefore(text, caret: caret),
           CharacterSet.alphanumerics.contains(scalar) {
            return false
        }
        return true
    }

    /// The Unicode scalar ending immediately before `caret` (an exclusive UTF-16
    /// index), combining a surrogate pair so an astral letter/digit is read as the
    /// single scalar it is — not a lone (non-alphanumeric) surrogate half, which
    /// would otherwise let a quote auto-close after an astral word character.
    /// `nil` at the buffer start or on an unpaired surrogate.
    private static func scalarBefore(_ text: NSString, caret: Int) -> UnicodeScalar? {
        let last = caret - 1
        guard last >= 0, last < text.length else { return nil }
        let unit = text.character(at: last)
        if (0xDC00...0xDFFF).contains(unit) {
            // Low surrogate: combine with the preceding high surrogate.
            guard last - 1 >= 0 else { return nil }
            let high = text.character(at: last - 1)
            guard (0xD800...0xDBFF).contains(high) else { return nil }
            let value = 0x10000 + ((UInt32(high) - 0xD800) << 10) + (UInt32(unit) - 0xDC00)
            return UnicodeScalar(value)
        }
        return UnicodeScalar(unit)
    }

    /// Surrogate-safe single-character read at `index`; `nil` at end-of-buffer or
    /// on a lone surrogate half (a non-BMP character, which is never a bracket or
    /// quote here).
    private static func character(in text: NSString, at index: Int) -> Character? {
        guard index >= 0, index < text.length else { return nil }
        return UnicodeScalar(text.character(at: index)).map(Character.init)
    }

    /// Whether `ch` is a line separator, deferring to `LineStartIndex` so this
    /// engine, `IndentEngine` and the gutter can never disagree about where a line
    /// ends: LF, CR, NEL, U+2028, U+2029.
    private static func isLineSeparator(_ ch: unichar) -> Bool {
        LineStartIndex.isLineSeparator(ch)
    }
}
