import Foundation

/// The two halves of one matched bracket pair, as UTF-16 ranges into the
/// document. Both ranges are always length 1, and `open` always precedes
/// `close` regardless of which side of the pair the caret was sitting on.
public struct BracketPair: Equatable {
    public let open: NSRange
    public let close: NSRange

    public init(open: NSRange, close: NSRange) {
        self.open = open
        self.close = close
    }
}

/// Pure, testable caret↔bracket pair matching for the editor's pair
/// highlighting — Foundation only, so it stays in `PisakaCore` and is unit-tested
/// without any AppKit/Neon dependency (the `AutoPairEngine`/`IndentEngine`
/// precedent). The view layer owns the attributes and the colors; this engine
/// only answers *which two characters* to highlight.
///
/// Like `AutoPairEngine`, it operates on an `NSString` and UTF-16 offsets, reads
/// single characters surrogate-safely (a lone surrogate half is never a bracket),
/// and counts *raw* characters: there is no string/comment awareness (no lexer),
/// the same deliberate boundary the rest of the editor draws. So a bracket inside
/// a string literal or a comment still matches — a known limitation;
/// tree-sitter-aware matching is a follow-up.
///
/// **Why the outward scan is chunked too.** It stops at the match, which for
/// well-formed code is a handful of characters away — but the common mid-typing
/// state is an *unmatched* adjacent bracket (typing `(` right before a word, which
/// `AutoPairEngine` deliberately passes through without inserting a closer), and
/// then the scan runs all the way to the buffer end (and `pair` can follow it with
/// a second full scan the other way). With `NSString.character(at:)` — an objc
/// message send *per character* — that is a full-buffer per-character walk on
/// every caret move, undebounced, i.e. exactly the jank `BracketDepthScanner`'s
/// bulk read exists to avoid. So both scans read through `getCharacters(_:range:)`
/// into a reusable `[unichar]` buffer of `chunkSize` units, comparing raw UTF-16
/// units (a lone surrogate half can never equal an ASCII bracket, so the
/// surrogate-safety of the former per-character read is preserved). Only the one
/// character adjacent to the caret is still read singly.
///
/// **Divergence from `BracketDepthScanner`.** The two engines answer different
/// questions and therefore count depth differently. This one counts *its own kind
/// only* (the `IndentEngine.dedentOnClosing` rule): "which `]` closes *this* `[`"
/// ignores unrelated `(`/`{`. `BracketDepthScanner` keeps *one shared stack across
/// all three kinds* (JetBrains rainbow semantics), because nesting depth is a
/// single number for the whole document. On well-formed code the two always agree;
/// on *crossed* input they do not. In `{[(]}` this engine pairs `[`↔`]` (correctly
/// nested once `(` is ignored), while the scanner sees `]` arrive with `(` on top
/// of the stack and reports both `[` and `]` as unmatched — so the caret at `[`
/// can show a highlighted pair whose brackets are painted red. That is deliberate
/// and accepted: the input is broken code mid-typing and neither answer is wrong
/// for its own question. Both suites pin the exact `{[(]}` outcome
/// (`testCrossedBracketsPairPerKindUnlikeDepthScanner` here,
/// `testCrossedBracketsAllUnmatchedUnlikeMatchEngine` there).
public enum BracketMatchEngine {
    /// Opening bracket → its matching closer. Quotes are deliberately absent:
    /// a quote is its own closer, so "which one closes this one" has no answer
    /// without a lexer.
    static let openerToCloser: [Character: Character] = [
        "(": ")", "[": "]", "{": "}"
    ]
    /// Closing bracket → its matching opener.
    static let closerToOpener: [Character: Character] = [
        ")": "(", "]": "[", "}": "{"
    ]

    /// The bracket pair to highlight for `selectedRange`, or `nil` when there is
    /// nothing to highlight.
    ///
    /// - A non-empty selection yields `nil`: pair highlighting is a caret
    ///   affordance, and a selection already has its own highlight. (A negative
    ///   length is degenerate and treated the same way — only a true caret,
    ///   `length == 0`, matches.)
    /// - A location outside `0...text.length` (including `NSNotFound`) yields
    ///   `nil` without trapping: it names no position in the buffer, so nothing
    ///   is adjacent to it. This is where the engine differs from
    ///   `AutoPairEngine`, which *clamps* a degenerate range because it must still
    ///   decide what a keystroke does; here there is simply nothing to show.
    /// - The character *after* the caret is considered first, then the one before
    ///   it (VS Code order), so with brackets on both sides the following one
    ///   wins. An adjacent bracket that has no match does not end the search: the
    ///   other side is still tried, so a caret between an unmatched opener and a
    ///   matched closer (`)|(`) still highlights the closer's pair.
    /// - An opener scans forward and a closer backward, counting the depth of
    ///   *its own kind* only.
    public static func pair(text: NSString, selectedRange: NSRange) -> BracketPair? {
        guard selectedRange.length == 0 else { return nil }
        let caret = selectedRange.location
        guard caret != NSNotFound, caret >= 0, caret <= text.length else { return nil }

        // The character after the caret wins over the one before it.
        if let match = matchBracket(in: text, at: caret) { return match }
        return matchBracket(in: text, at: caret - 1)
    }

    /// How many UTF-16 units are pulled out of the string per
    /// `getCharacters(_:range:)` call, matching `BracketDepthScanner.chunkSize`.
    private static let chunkSize = 4096

    /// The pair for the bracket sitting at `index`, or `nil` when `index` is out
    /// of bounds, holds no bracket, or holds an unmatched one.
    private static func matchBracket(in text: NSString, at index: Int) -> BracketPair? {
        guard let ch = character(in: text, at: index) else { return nil }
        if let closer = openerToCloser[ch], let units = unitPair(opener: ch, closer: closer) {
            guard let closeIndex = scanForward(
                text: text,
                from: index,
                opener: units.opener,
                closer: units.closer
            ) else { return nil }
            return BracketPair(
                open: NSRange(location: index, length: 1),
                close: NSRange(location: closeIndex, length: 1)
            )
        }
        if let opener = closerToOpener[ch], let units = unitPair(opener: opener, closer: ch) {
            guard let openIndex = scanBackward(
                text: text,
                from: index,
                opener: units.opener,
                closer: units.closer
            ) else { return nil }
            return BracketPair(
                open: NSRange(location: openIndex, length: 1),
                close: NSRange(location: index, length: 1)
            )
        }
        return nil
    }

    /// The two bracket characters as raw UTF-16 units, so the scans can compare
    /// against the chunk buffer. Both tables hold ASCII only, so this never fails
    /// in practice; a non-ASCII entry would simply match nothing.
    private static func unitPair(opener: Character, closer: Character) -> (opener: unichar, closer: unichar)? {
        guard let openerUnit = opener.asciiValue, let closerUnit = closer.asciiValue else { return nil }
        return (unichar(openerUnit), unichar(closerUnit))
    }

    /// Walk forward from the opener at `from`, counting nested openers of the
    /// *same kind*; the closer that arrives at depth 0 is the match.
    private static func scanForward(text: NSString, from: Int, opener: unichar, closer: unichar) -> Int? {
        let length = text.length
        var chunkStart = from + 1
        guard chunkStart < length else { return nil }

        var depth = 0
        var match: Int?
        var buffer = [unichar](repeating: 0, count: min(chunkSize, length - chunkStart))
        while chunkStart < length, match == nil {
            let count = min(buffer.count, length - chunkStart)
            buffer.withUnsafeMutableBufferPointer { raw in
                text.getCharacters(raw.baseAddress!, range: NSRange(location: chunkStart, length: count))
                for i in 0..<count {
                    let ch = raw[i]
                    if ch == opener {
                        depth += 1
                    } else if ch == closer {
                        if depth == 0 {
                            match = chunkStart + i
                            return
                        }
                        depth -= 1
                    }
                }
            }
            chunkStart += count
        }
        return match
    }

    /// Walk backward from the closer at `from`, counting nested closers of the
    /// *same kind*; the opener that arrives at depth 0 is the match.
    private static func scanBackward(text: NSString, from: Int, opener: unichar, closer: unichar) -> Int? {
        var chunkEnd = min(from, text.length)
        guard chunkEnd > 0 else { return nil }

        var depth = 0
        var match: Int?
        var buffer = [unichar](repeating: 0, count: min(chunkSize, chunkEnd))
        while chunkEnd > 0, match == nil {
            let count = min(buffer.count, chunkEnd)
            let chunkStart = chunkEnd - count
            buffer.withUnsafeMutableBufferPointer { raw in
                text.getCharacters(raw.baseAddress!, range: NSRange(location: chunkStart, length: count))
                var i = count - 1
                while i >= 0 {
                    let ch = raw[i]
                    if ch == closer {
                        depth += 1
                    } else if ch == opener {
                        if depth == 0 {
                            match = chunkStart + i
                            return
                        }
                        depth -= 1
                    }
                    i -= 1
                }
            }
            chunkEnd = chunkStart
        }
        return match
    }

    /// Surrogate-safe single-character read at `index`; `nil` out of bounds or on
    /// a lone surrogate half (a non-BMP character, which is never a bracket).
    private static func character(in text: NSString, at index: Int) -> Character? {
        guard index >= 0, index < text.length else { return nil }
        return UnicodeScalar(text.character(at: index)).map(Character.init)
    }
}
