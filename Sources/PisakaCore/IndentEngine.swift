import Foundation

/// The text to insert for a newline plus where to place the cursor afterward.
///
/// `text` is the literal string to splice in at the cursor (a leading `"\n"`
/// followed by the computed indentation, and in the between-brackets case a
/// second `"\n"` and the closer's indentation). `cursorOffset` is the UTF-16
/// distance from the insertion point to where the caret should land — equal to
/// `text`'s UTF-16 length for the simple case, but on the *middle* line for the
/// between-brackets split so the caret sits on the freshly indented blank line.
///
/// `consumeAfter` is a count of UTF-16 units *after* the replaced selection that
/// the caller should also delete (by extending the replacement range). It is used
/// by the opener case to swallow trailing whitespace sitting between the opener
/// and the rest of the line: that whitespace is junk, not indentation to inherit,
/// so it must not stack on top of the freshly added indent unit. `0` for every
/// case that leaves the following text untouched.
public struct NewlineEdit: Equatable {
    public let text: String
    public let cursorOffset: Int
    public let consumeAfter: Int

    public init(text: String, cursorOffset: Int, consumeAfter: Int = 0) {
        self.text = text
        self.cursorOffset = cursorOffset
        self.consumeAfter = consumeAfter
    }
}

/// A leading-whitespace rewrite for the dedent-on-closing-bracket case: replace
/// `range` (the current line's leading whitespace, in UTF-16 units of the whole
/// document) with `replacement` (the matching opener line's indentation).
public struct IndentReplacement: Equatable {
    public let range: NSRange
    public let replacement: String

    public init(range: NSRange, replacement: String) {
        self.range = range
        self.replacement = replacement
    }
}

/// Pure, testable indent computation for the editor — Foundation only, so it
/// stays in `PisakaCore` and is unit-tested without any AppKit/Neon dependency.
///
/// Like `LineStartIndex`/`LineDiff`/`MinimapModel`, it operates on an `NSString`
/// and UTF-16 offsets and splits document lines with the same Unicode separator
/// semantics (via `LineStartIndex`). Bracket matching counts *raw* characters —
/// there is no string/comment awareness — matching the plan's deliberately
/// simple, language-agnostic scope.
public enum IndentEngine {
    /// The set of opening brackets that trigger an extra indent unit / split.
    static let openers: Set<Character> = ["{", "(", "["]
    /// Closing → matching opening bracket.
    static let closingToOpening: [Character: Character] = [
        "}": "{", ")": "(", "]": "["
    ]

    /// Detect the file's indentation unit: a single tab when the file indents
    /// with tabs, otherwise the smallest run of leading spaces observed across
    /// all lines — **counting only runs of two or more**. Falls back to four
    /// spaces for an empty file, one with no indented line, and one whose only
    /// leading-space runs are single spaces, so a fresh/flat file still indents
    /// sensibly.
    public static func inferIndentUnit(text: NSString) -> String {
        let fallback = "    "
        guard text.length > 0 else { return fallback }

        var sawTabIndent = false
        var smallestSpaceIndent: Int?

        let starts = LineStartIndex.offsets(in: text)
        for start in starts {
            // Measure this line's leading whitespace run.
            var i = start
            var spaces = 0
            var sawTab = false
            loop: while i < text.length {
                let ch = text.character(at: i)
                switch ch {
                case 0x09: // tab
                    sawTab = true
                    i += 1
                case 0x20: // space
                    spaces += 1
                    i += 1
                default:
                    break loop
                }
            }
            // Skip a whitespace-only line: its run reaches end-of-line or a line
            // separator with no content after it, so that whitespace is *trailing*
            // whitespace, not indentation. Counting it would skew the inferred unit
            // (e.g. a stray "  \n" in an otherwise 4-space file inferring a 2-space
            // unit). The separator set matches `LineStartIndex` (LF, CR, NEL, LS,
            // PS) so a line is judged whitespace-only on the same boundaries the
            // editor splits lines on.
            if i >= text.length || isLineSeparator(text.character(at: i)) { continue }
            if sawTab { sawTabIndent = true }
            // Skip a run of exactly one space for the same reason a whitespace-only
            // line is skipped: it is not indentation, and counting it destroys the
            // answer. No language is indented one space per level, but the
            // continuation line of a C-family block comment (` * text`) starts with
            // exactly one — so an ordinary four-space file carrying a single
            // `/** … */` would otherwise infer a one-space unit, which makes Enter
            // append one space after `{` and makes the indentation-level painting
            // cycle its whole palette inside a single level. A genuinely one-space
            // file therefore falls back to four, which is what a file with no
            // indentation at all already answers.
            if spaces > 1 {
                if let current = smallestSpaceIndent {
                    smallestSpaceIndent = min(current, spaces)
                } else {
                    smallestSpaceIndent = spaces
                }
            }
        }

        if sawTabIndent { return "\t" }
        if let spaces = smallestSpaceIndent { return String(repeating: " ", count: spaces) }
        return fallback
    }

    /// Compute the text to splice in when Enter is pressed at `location`.
    ///
    /// The base indentation is the current line's leading whitespace (inherited
    /// verbatim — tabs and spaces alike). One `unit` is appended when the current
    /// line, ignoring trailing whitespace, ends with an opening bracket
    /// (`{`/`(`/`[`). When `location` sits directly between an opener and its
    /// matching closer (`{|}`), the edit splits across two lines: a freshly
    /// indented middle line for the caret and the closer pushed down to the base
    /// indentation. Otherwise the previous line's indentation is simply inherited.
    ///
    /// `selectionLength` is the UTF-16 length of the selection the newline
    /// replaces (0 for a bare caret). The between-brackets split looks at the
    /// character immediately *after* the selection — the one that survives the
    /// replacement — so selecting the closer in `{}` and pressing Enter does not
    /// spuriously split (the selected closer is consumed by the replacement, so
    /// there is no adjacent closer to push down). Surviving whitespace is likewise
    /// measured from the *end* of the selection (`selEnd`): characters inside the
    /// selection are deleted by the replacement and must not be counted as
    /// surviving (doing so would push the caret past the end of the result).
    ///
    /// `terminator` is the line terminator to splice — LF by default, so a caller
    /// that states nothing (and every project without an `end_of_line`) keeps
    /// splicing exactly what it spliced before. `end_of_line` is consumed in full:
    /// what `SaveTransform` normalizes already-written terminators to is what a
    /// newly typed one is, so the two never disagree. The terminator's *real*
    /// UTF-16 length is measured everywhere it is counted (CRLF is two units), so
    /// the caret lands in the same logical place under every flavor.
    public static func newlineIndentation(
        text: NSString,
        location: Int,
        unit: String,
        selectionLength: Int = 0,
        terminator: String = "\n"
    ) -> NewlineEdit {
        let loc = max(0, min(location, text.length))
        let selEnd = max(loc, min(loc + max(0, selectionLength), text.length))
        let terminatorLength = (terminator as NSString).length

        // Start of the line containing `loc`.
        var lineStart = 0
        for s in LineStartIndex.offsets(in: text) {
            if s <= loc { lineStart = s } else { break }
        }

        // Base = the current line's leading whitespace up to the caret, inherited
        // verbatim. The scan stops at `loc` (not `text.length`): when the caret
        // sits inside the leading whitespace ("  |  foo"), the whitespace after it
        // survives the insertion, so scanning the full run would double-count it
        // and over-indent the new line.
        var base = ""
        var i = lineStart
        while i < loc {
            let ch = text.character(at: i)
            if ch == 0x20 || ch == 0x09 {
                base.unicodeScalars.append(UnicodeScalar(ch)!)
                i += 1
            } else {
                break
            }
        }

        // The characters immediately bracketing the caret, for the split case.
        // A non-BMP character occupies two UTF-16 units, each a surrogate half for
        // which `UnicodeScalar(_:)` is nil; a surrogate is never a bracket, so map
        // it to `nil` and fall through rather than force-unwrapping (which traps).
        let charBefore: Character? = loc > 0
            ? UnicodeScalar(text.character(at: loc - 1)).map(Character.init) : nil
        let charAfter: Character? = selEnd < text.length
            ? UnicodeScalar(text.character(at: selEnd)).map(Character.init) : nil

        // Between-brackets split: opener immediately before, its matching closer
        // immediately after.
        if let before = charBefore, let after = charAfter,
           openers.contains(before), closingToOpening[after] == before {
            let middle = base + unit
            let txt = terminator + middle + terminator + base
            return NewlineEdit(text: txt, cursorOffset: terminatorLength + (middle as NSString).length)
        }

        // Last non-whitespace character before the caret on the current line.
        var lastNonWS: Character?
        var j = loc - 1
        while j >= lineStart {
            let ch = text.character(at: j)
            if ch == 0x20 || ch == 0x09 {
                j -= 1
                continue
            }
            // A surrogate half (non-BMP char) is never an opener; map to nil and
            // fall through rather than force-unwrapping a nil `UnicodeScalar`.
            lastNonWS = UnicodeScalar(ch).map(Character.init)
            break
        }

        // Whitespace immediately *after* the selection — the run that the
        // replacement would otherwise leave at the start of the new line. Measured
        // from `selEnd` (not `loc`) so characters inside the selection, which the
        // replacement deletes, are never counted.
        var survivingWhitespace = 0
        var s = selEnd
        while s < text.length {
            let ch = text.character(at: s)
            if ch == 0x20 || ch == 0x09 { survivingWhitespace += 1; s += 1 } else { break }
        }

        if let last = lastNonWS, openers.contains(last) {
            let indent = base + unit
            let txt = terminator + indent
            // The surviving whitespace here is trailing junk between the opener and
            // the rest of the line, not indentation to inherit, so consuming it
            // keeps the new line at exactly `base + unit` instead of stacking the
            // two (and wedging the caret in the middle of the doubled run).
            return NewlineEdit(
                text: txt,
                cursorOffset: (txt as NSString).length,
                consumeAfter: survivingWhitespace
            )
        }

        // When the caret sits within the current line's leading whitespace
        // ("  |  foo"), the whitespace *after* the caret survives the insertion
        // and becomes part of the new line's indentation. Advance the caret over
        // it so it lands at the end of that indentation (ready to type content)
        // rather than wedged between the inherited and surviving whitespace —
        // matching every other case, where the caret lands at the indent's end.
        // `i == loc` means the base scan consumed the whole prefix, i.e. it was
        // all whitespace; otherwise the caret is past some content and the
        // following whitespace is not leading indentation. Here the surviving
        // whitespace is *kept* (it is the inherited indent), so the caret advances
        // over it rather than the edit consuming it.
        let survivingIndent = (i == loc) ? survivingWhitespace : 0

        let txt = terminator + base
        return NewlineEdit(text: txt, cursorOffset: (txt as NSString).length + survivingIndent)
    }

    /// Compute the dedent when a closing bracket is typed on a whitespace-only
    /// line.
    ///
    /// `location` is the caret position where `closing` is about to be inserted
    /// (the bracket itself is *not* yet in `text`). Returns a rewrite of the
    /// current line's leading whitespace to match the line that opened the bracket,
    /// or `nil` when the prefix up to `location` is not whitespace-only, `closing`
    /// is not a known closer, or no matching opener can be found by scanning
    /// backward. Bracket matching counts *raw* characters of the same kind (no
    /// string/comment awareness), tracking nesting depth so an inner pair of the
    /// same kind is skipped over.
    public static func dedentOnClosing(text: NSString, location: Int, closing: Character) -> IndentReplacement? {
        guard let opening = closingToOpening[closing] else { return nil }
        let loc = max(0, min(location, text.length))

        // Start of the line containing `loc`.
        var lineStart = 0
        for s in LineStartIndex.offsets(in: text) {
            if s <= loc { lineStart = s } else { break }
        }

        // The line prefix up to the caret must be whitespace-only.
        var k = lineStart
        while k < loc {
            let ch = text.character(at: k)
            if ch != 0x20 && ch != 0x09 { return nil }
            k += 1
        }

        // Scan backward for the matching opener, tracking same-kind nesting depth.
        var depth = 0
        var openerIndex: Int?
        var j = loc - 1
        while j >= 0 {
            let scalar = UnicodeScalar(text.character(at: j))
            let ch = scalar.map { Character($0) }
            if ch == closing {
                depth += 1
            } else if ch == opening {
                if depth == 0 {
                    openerIndex = j
                    break
                }
                depth -= 1
            }
            j -= 1
        }

        guard let opener = openerIndex else { return nil }

        // Start of the opener's line.
        var openerLineStart = 0
        for s in LineStartIndex.offsets(in: text) {
            if s <= opener { openerLineStart = s } else { break }
        }

        // The opener line's leading whitespace, inherited verbatim.
        var indent = ""
        var i = openerLineStart
        while i < text.length {
            let ch = text.character(at: i)
            if ch == 0x20 || ch == 0x09 {
                indent.unicodeScalars.append(UnicodeScalar(ch)!)
                i += 1
            } else {
                break
            }
        }

        return IndentReplacement(range: NSRange(location: lineStart, length: loc - lineStart), replacement: indent)
    }

    /// Whether `ch` is a line separator, deferring to `LineStartIndex` (whose set
    /// is `NSString` line enumeration's) so nothing in the editor splits lines
    /// differently: LF, CR, NEL, U+2028 (line) and U+2029 (paragraph).
    private static func isLineSeparator(_ ch: unichar) -> Bool {
        LineStartIndex.isLineSeparator(ch)
    }
}
