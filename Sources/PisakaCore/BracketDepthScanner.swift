import Foundation

/// One bracket found by `BracketDepthScanner`, as a UTF-16 offset into the
/// document plus the two facts the view needs to color it.
///
/// `depth` is *semantic*, not a palette index: the scanner reports the honest
/// nesting level (7 stays 7) and the view resolves a color with `depth % N` over
/// its own cycling palette — the same "semantics in Core, color in the view"
/// split as `FileIconColor`/`SyntaxTokenKind`. A `depth` reported alongside
/// `isUnmatched` is not meaningful and must not be looked up: a stray/wrong-kind
/// closer carries `depth: 0` (it never sat on the stack), while an opener the
/// document never closes keeps the depth it was pushed at, because it is patched
/// in place. `isUnmatched` wins in both cases and the view paints it red.
public struct BracketToken: Equatable {
    /// UTF-16 offset of the bracket character (always one unit long).
    public let location: Int
    /// Nesting level, 0 at the outermost. Ignored when `isUnmatched`.
    public let depth: Int
    /// A closer with no (or a wrong-kind) opener on the stack, or an opener still
    /// on the stack when the document ends.
    public let isUnmatched: Bool

    public init(location: Int, depth: Int, isUnmatched: Bool) {
        self.location = location
        self.depth = depth
        self.isUnmatched = isUnmatched
    }
}

/// Pure, testable nesting-depth scanning for the editor's rainbow brackets —
/// Foundation only, so it stays in `PisakaCore` and is unit-tested without any
/// AppKit/Neon dependency (the `AutoPairEngine`/`BracketMatchEngine` precedent).
/// The view layer owns the attributes and the palette; this engine only answers
/// *which characters are brackets and how deep each one sits*.
///
/// Like the rest of the editor's engines it counts *raw* characters: there is no
/// string/comment awareness (no lexer), the same deliberate boundary
/// `IndentEngine`/`AutoPairEngine`/`BracketMatchEngine` draw. So a bracket inside
/// a string literal or a comment is scanned like any other — a known limitation;
/// tree-sitter-aware scanning is a follow-up.
///
/// **Why the chunked bulk read.** The caller runs this on the main actor after a
/// debounce, so the scan must stay a plain memory walk. `NSString.character(at:)`
/// is an objc message send *per character*, which turns a nominally cheap O(n)
/// pass over a megabyte-sized file into visible typing jank. Instead the text is
/// read through `getCharacters(_:range:)` into a reusable `[unichar]` buffer of
/// `chunkSize` units: the whole scan costs `ceil(n / chunkSize)` message sends,
/// and the allocation stays bounded no matter how large the file is (a megabyte
/// buffer never gets a second megabyte-sized copy). Chunking is invisible in the
/// result — the depth stack and the token array carry across chunks and each
/// token's `location` is `chunkStart + indexInChunk`. Its sibling
/// `BracketMatchEngine` scans outward from the caret and stops at the match, but
/// an *unmatched* adjacent bracket sends it to the buffer end just the same, so it
/// reads in chunks of the same size for the same reason.
///
/// **Divergence from `BracketMatchEngine`.** The two engines answer different
/// questions and therefore count depth differently. This one keeps *one shared
/// stack across all three kinds* (JetBrains rainbow semantics), because nesting
/// depth is a single number for the whole document: `{[()]}` reads 0,1,2.
/// `BracketMatchEngine` counts *its own kind only* (the
/// `IndentEngine.dedentOnClosing` rule), since "which `]` closes *this* `[`"
/// ignores unrelated `(`/`{`. On well-formed code the two always agree; on
/// *crossed* input they do not. In `{[(]}` this scanner sees `]` arrive with `(`
/// on top of the stack and reports every bracket unmatched, while the matcher
/// pairs `[`↔`]` — so a bracket painted red here can still show a highlighted
/// pair. That is deliberate and accepted: the input is broken code mid-typing and
/// neither answer is wrong for its own question. Both suites pin the exact
/// `{[(]}` outcome (`testCrossedBracketsAllUnmatchedUnlikeMatchEngine` here,
/// `testCrossedBracketsPairPerKindUnlikeDepthScanner` there).
public enum BracketDepthScanner {
    /// How many UTF-16 units are pulled out of the string per
    /// `getCharacters(_:range:)` call. Internal (not private) so the tests can
    /// build input that straddles a chunk seam and prove the chunking never
    /// shows up in the result.
    internal static let chunkSize = 4096

    private static let openParen = unichar(UInt8(ascii: "("))
    private static let closeParen = unichar(UInt8(ascii: ")"))
    private static let openBracket = unichar(UInt8(ascii: "["))
    private static let closeBracket = unichar(UInt8(ascii: "]"))
    private static let openBrace = unichar(UInt8(ascii: "{"))
    private static let closeBrace = unichar(UInt8(ascii: "}"))

    /// Every bracket in `text`, in ascending `location` order.
    ///
    /// One O(n) pass with a single stack shared by all three kinds:
    /// - an opener is pushed and reported with the depth *before* the increment
    ///   (so the outermost is 0);
    /// - a closer matching the top of the stack pops it and takes its opener's
    ///   depth, so a pair always shares one color;
    /// - a closer of the wrong kind, or one arriving on an empty stack, is
    ///   reported `isUnmatched` and **leaves the stack untouched** — a stray `]`
    ///   inside `(…)` must not orphan the `(`;
    /// - openers still on the stack when the text ends are patched to
    ///   `isUnmatched` in place, so the array stays sorted by `location`.
    public static func scan(text: NSString) -> [BracketToken] {
        let length = text.length
        guard length > 0 else { return [] }

        var tokens: [BracketToken] = []
        /// The open brackets seen so far: their token index (for the end-of-text
        /// patch) and the closer each one expects.
        var stack: [(tokenIndex: Int, closer: unichar)] = []

        var buffer = [unichar](repeating: 0, count: min(chunkSize, length))
        var chunkStart = 0
        while chunkStart < length {
            let count = min(chunkSize, length - chunkStart)
            buffer.withUnsafeMutableBufferPointer { raw in
                text.getCharacters(raw.baseAddress!, range: NSRange(location: chunkStart, length: count))
                for i in 0..<count {
                    let ch = raw[i]
                    let location = chunkStart + i
                    if let closer = expectedCloser(for: ch) {
                        stack.append((tokenIndex: tokens.count, closer: closer))
                        tokens.append(BracketToken(location: location, depth: stack.count - 1, isUnmatched: false))
                    } else if isCloser(ch) {
                        if let top = stack.last, top.closer == ch {
                            stack.removeLast()
                            tokens.append(BracketToken(
                                location: location,
                                depth: tokens[top.tokenIndex].depth,
                                isUnmatched: false
                            ))
                        } else {
                            // A wrong-kind or orphaned closer: reported, but the
                            // stack is left alone so the real opener can still
                            // find its own closer later.
                            tokens.append(BracketToken(location: location, depth: 0, isUnmatched: true))
                        }
                    }
                }
            }
            chunkStart += count
        }

        // Openers that never closed.
        for entry in stack {
            let token = tokens[entry.tokenIndex]
            tokens[entry.tokenIndex] = BracketToken(location: token.location, depth: token.depth, isUnmatched: true)
        }
        return tokens
    }

    /// The closer `ch` expects when it is an opener, else `nil`.
    private static func expectedCloser(for ch: unichar) -> unichar? {
        switch ch {
        case openParen: return closeParen
        case openBracket: return closeBracket
        case openBrace: return closeBrace
        default: return nil
        }
    }

    private static func isCloser(_ ch: unichar) -> Bool {
        ch == closeParen || ch == closeBracket || ch == closeBrace
    }
}
