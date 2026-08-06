import Foundation

/// What to look for: the pattern plus the three JetBrains/VS Code-style toggles
/// (`Aa` case sensitivity, `ab` whole word, `.*` regular expression).
///
/// A value type so the view layer can compare the query it last ran against the
/// current one and skip a redundant re-scan.
public struct SearchQuery: Equatable {
    /// The literal text, or the regular expression when `isRegex`.
    public var pattern: String
    /// Interpret `pattern` as an `NSRegularExpression` instead of literal text.
    public var isRegex: Bool
    /// Match case exactly (otherwise the search is case-insensitive).
    public var caseSensitive: Bool
    /// Keep only matches whose own boundaries are non-word characters.
    public var wholeWord: Bool

    public init(
        pattern: String,
        isRegex: Bool = false,
        caseSensitive: Bool = false,
        wholeWord: Bool = false
    ) {
        self.pattern = pattern
        self.isRegex = isRegex
        self.caseSensitive = caseSensitive
        self.wholeWord = wholeWord
    }
}

/// One found occurrence: its UTF-16 range in the searched text plus the 1-based
/// number of the line it starts on (what the find bar's counter and the Find in
/// Files result rows display).
public struct SearchMatch: Equatable {
    /// UTF-16 range in the searched buffer. May be zero-length for a regex that
    /// can match the empty string (`a*`).
    public var range: NSRange
    /// 1-based line number of `range.location`, counted with the same Unicode
    /// separators as the gutter and the minimap (`LineStartIndex`).
    public var lineNumber: Int

    public init(range: NSRange, lineNumber: Int) {
        self.range = range
        self.lineNumber = lineNumber
    }
}

/// Why a search could not run. Carries its own human-readable text (the
/// `GitError`/`FileServiceError` precedent) so the find bar can show the reason
/// inline — an invalid regex is an ordinary mid-typing state, not an alert.
public enum TextSearchError: Error, Equatable {
    /// The pattern is empty or whitespace-only — an empty field is "no query",
    /// not a search for spaces.
    case emptyPattern
    /// `NSRegularExpression` refused the pattern; `reason` is its own
    /// `localizedDescription`.
    case invalidRegex(reason: String)
}

extension TextSearchError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptyPattern:
            return "Enter something to search for."
        case .invalidRegex(let reason):
            let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Invalid regular expression." : trimmed
        }
    }
}

/// One replacement in a plan: the UTF-16 `range` to overwrite and the resolved
/// `replacement` text (group references already substituted for a regex query).
///
/// A struct rather than a tuple so a whole plan is `Equatable` and can be
/// asserted as one value in tests.
public struct ReplaceEdit: Equatable {
    /// UTF-16 range in the buffer the plan was built against. May be zero-length
    /// (a pure insertion, for a regex that matches the empty string).
    public var range: NSRange
    /// The text to write over `range` — already resolved, so applying a plan
    /// needs no further knowledge of the query.
    public var replacement: String

    public init(range: NSRange, replacement: String) {
        self.range = range
        self.replacement = replacement
    }
}

/// Pure, testable text search over an `NSString` in UTF-16 offsets — the engine
/// behind both the editor's find bar and the project-wide "Find in Files"
/// traversal (Foundation only, no AppKit/UIKit: the `DuplicateEngine`/
/// `AutoPairEngine` split, where the view layer owns selection, scrolling and
/// colors while every decision lives here).
///
/// Two search paths produce ranges — a literal `range(of:options:range:)` walk
/// and `NSRegularExpression` — and *one* `wholeWord` post-filter runs over
/// whatever either produced. That is deliberate: the filter judges the found
/// match's **own** boundaries, so it composes with a regex (a `\w+` match is
/// already whole-word, an `oo` match inside `foo` is not) instead of needing a
/// second, regex-specific rule that could drift from the literal one.
public enum TextSearchEngine {

    /// Every occurrence of `query` in `text`, in document order.
    ///
    /// The literal path advances by `max(1, found.length)` so a zero-length or
    /// overlapping candidate can never stall the walk; the regex path takes
    /// `NSRegularExpression`'s own enumeration, which already terminates on a
    /// pattern that matches the empty string. Locations strictly increase in
    /// both.
    ///
    /// Throws `.emptyPattern` for an empty/whitespace-only pattern and
    /// `.invalidRegex` when `isRegex` and `NSRegularExpression` refuses it.
    public static func matches(in text: NSString, query: SearchQuery) throws -> [SearchMatch] {
        guard !query.pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TextSearchError.emptyPattern
        }

        var ranges = query.isRegex
            ? try regexRanges(in: text, query: query)
            : literalRanges(in: text, query: query)

        if query.wholeWord {
            ranges = ranges.filter { isWholeWord($0, in: text) }
        }
        guard !ranges.isEmpty else { return [] }

        // One line-start index per call plus a binary search per match, rather
        // than a scan per match (O(n + m log n), not O(n·m)).
        let lineStarts = LineStartIndex.offsets(in: text)
        return ranges.map {
            SearchMatch(range: $0, lineNumber: lineNumber(forOffset: $0.location, in: lineStarts))
        }
    }

    /// A compiled `NSRegularExpression` for `query`, or `.invalidRegex` carrying
    /// the reason. Shared with the replacement path so both judge a pattern the
    /// same way.
    ///
    /// `.anchorsMatchLines` is always on: the product decision is that `^`/`$` in
    /// a *search* are line boundaries, as they are in VS Code and JetBrains, so
    /// `^import` finds every import line rather than only one at the very top of
    /// the file. Because the option lives in this one factory it applies
    /// identically to `matches(in:query:)` and to the anchored re-match inside
    /// `replacement(...)`, which is what keeps the two from disagreeing about
    /// which ranges an anchored pattern produces.
    ///
    /// What deliberately does **not** change: `.dotMatchesLineSeparators` stays
    /// off, so `.` still stops at a line break.
    ///
    /// **Known divergence.** ICU anchors after a *superset* of the separators
    /// `LineStartIndex` splits on: it adds VT (U+000B) and FF (U+000C), which
    /// `NSString.enumerateSubstrings(.byLines)` does not treat as line breaks
    /// (CR, CRLF, NEL, LS and PS all agree). So in a file carrying a form feed —
    /// a page separator in Emacs-managed C/Lisp sources — `^` can match at a
    /// position the gutter, the minimap and `SearchMatch.lineNumber` all place
    /// *inside* a line, and two such matches report the same line number. The
    /// ranges stay exact, so a replacement still rewrites precisely what matched;
    /// only the anchor↔line-number correspondence is off. There is no ICU option
    /// to exclude VT/FF alone, so this is recorded rather than fixed, and pinned
    /// by `testRegexAnchorsFollowICUTerminatorsIncludingFormFeed`.
    static func regularExpression(for query: SearchQuery) throws -> NSRegularExpression {
        var options: NSRegularExpression.Options = [.anchorsMatchLines]
        if !query.caseSensitive { options.insert(.caseInsensitive) }
        do {
            return try NSRegularExpression(pattern: query.pattern, options: options)
        } catch {
            throw TextSearchError.invalidRegex(reason: (error as NSError).localizedDescription)
        }
    }

    // MARK: - Replacement

    /// The text that should replace `match`, with a regex query's group
    /// references (`$0`, `$1`, …) already substituted.
    ///
    /// A literal query inserts `template` **verbatim** — `$1` there is an ordinary
    /// dollar sign, not a back-reference — so replacing text with a literal `$1`
    /// works without escaping.
    ///
    /// For a regex query the `NSTextCheckingResult` is rebuilt by re-running the
    /// pattern *anchored* inside `match.range`, then handed to
    /// `replacementString(for:in:offset:template:)`. This never throws: an invalid
    /// pattern, an out-of-bounds range, or a range the pattern no longer re-matches
    /// exactly (a stale match) falls back to the raw `template` — the conservative
    /// outcome, since the user sees the unsubstituted text rather than a silently
    /// wrong substitution.
    ///
    /// The re-run carries `.withTransparentBounds` and `.withoutAnchoringBounds`
    /// so it reproduces the *original* full-buffer run's semantics exactly rather
    /// than the semantics of a region that happens to end at the match. Both are
    /// load-bearing. Without transparent bounds a lookaround cannot see past the
    /// match — `(h)ello(?= world)` re-run inside `{0, 5}` finds nothing, so every
    /// such replacement fell back to the raw template and wrote the literal `$1`
    /// into the buffer (and, through Find in Files, into files on disk). Without
    /// `.withoutAnchoringBounds` the opposite error appears: `^`/`$` would bind to
    /// the *re-run range's* own edges instead of the buffer's line boundaries (the
    /// `.anchorsMatchLines` semantics `regularExpression(for:)` compiles in), so a
    /// mid-line range would re-anchor and substitute rather than fall back — an
    /// anchored pattern re-matching a range the original run never produced.
    ///
    /// `matches(in:query:)` runs the regex over the whole buffer with no matching
    /// options, so those two flags are exactly what makes the re-run agree with
    /// it; the `result.range == range` check stays the backstop for a genuinely
    /// stale range.
    public static func replacement(
        for match: SearchMatch,
        in text: NSString,
        query: SearchQuery,
        template: String
    ) -> String {
        let regex = query.isRegex ? try? regularExpression(for: query) : nil
        return replacement(forRange: match.range, in: text as String, length: text.length, regex: regex, template: template)
    }

    /// Shared by the single-match and plan paths so both resolve a template the
    /// same way; the plan compiles the regex and bridges the string once.
    ///
    /// `.withTransparentBounds` lets a lookaround read past `range`, and
    /// `.withoutAnchoringBounds` keeps `^`/`$` on the buffer's *line* boundaries
    /// rather than on `range`'s edges — see `replacement(for:in:query:template:)`
    /// for why each is load-bearing.
    private static func replacement(
        forRange range: NSRange,
        in string: String,
        length: Int,
        regex: NSRegularExpression?,
        template: String
    ) -> String {
        guard let regex else { return template }
        guard range.location >= 0, range.length >= 0, NSMaxRange(range) <= length else { return template }
        let options: NSRegularExpression.MatchingOptions = [
            .anchored, .withTransparentBounds, .withoutAnchoringBounds,
        ]
        guard let result = regex.firstMatch(in: string, options: options, range: range),
              result.range == range
        else { return template }
        return regex.replacementString(for: result, in: string, offset: 0, template: template)
    }

    /// Every replacement for `matches`, ordered **strictly last-to-first** by
    /// location, so a caller can apply them one after another to a single mutable
    /// buffer: each edit lies entirely before the ones already applied, so no
    /// pending offset is ever invalidated by a length change.
    ///
    /// Overlapping input ranges are dropped, the earlier-in-document one winning
    /// (two edits over the same characters cannot both be applied, and the
    /// document-order match is the one the user sees first). Ranges outside the
    /// buffer are dropped too, so a stale match list can never trap. The regex is
    /// compiled once for the whole plan.
    public static func replacePlan(
        matches: [SearchMatch],
        in text: NSString,
        query: SearchQuery,
        template: String
    ) -> [ReplaceEdit] {
        guard !matches.isEmpty else { return [] }
        let length = text.length
        let ascending = matches.map(\.range).sorted {
            $0.location != $1.location ? $0.location < $1.location : $0.length < $1.length
        }

        var kept: [NSRange] = []
        var nextFree = 0
        for range in ascending {
            guard range.location >= 0, range.length >= 0, NSMaxRange(range) <= length else { continue }
            guard range.location >= nextFree else { continue }
            // Two zero-length matches at one location would otherwise both pass
            // the `>= nextFree` test and insert the template twice.
            guard kept.last != range else { continue }
            kept.append(range)
            nextFree = NSMaxRange(range)
        }
        guard !kept.isEmpty else { return [] }

        let regex = query.isRegex ? try? regularExpression(for: query) : nil
        let string = text as String
        return kept.reversed().map { range in
            ReplaceEdit(
                range: range,
                replacement: replacement(forRange: range, in: string, length: length, regex: regex, template: template)
            )
        }
    }

    // MARK: - Navigation

    /// The index of the match to move to from a caret at `location`, wrapping
    /// around the ends (a find bar always finds *something* while matches exist).
    ///
    /// `forward` takes the first match starting at or after `location`, wrapping to
    /// the first match; backward takes the last match starting strictly before it,
    /// wrapping to the last match. `nil` only when `matches` is empty. `matches` is
    /// assumed ascending by location — what `matches(in:query:)` returns.
    ///
    /// Deciding on the match's *start* is what lets the caller pass the selection's
    /// end for "next" and its start for "previous" and step off the current match
    /// in both directions — with one qualification that keeps that promise true for
    /// a **zero-length** match (`a*`, `^`, `\b`). There the selection's end *equals*
    /// its start, so a plain at-or-after test resolves to the match the caret is
    /// already on and Find Next never advances: pressing it repeatedly stays pinned
    /// to match 1 of *n* while the bar reports the others exist. So a zero-length
    /// match starting exactly *at* `location` is not a candidate going forward,
    /// while one of non-zero length still is — a caret placed at the very start of a
    /// match must still find it rather than skip to the following one. Nothing is
    /// unreachable: the sole zero-length match at the caret wraps back to itself
    /// through `?? 0`.
    public static func index(nearestTo location: Int, in matches: [SearchMatch], forward: Bool) -> Int? {
        guard !matches.isEmpty else { return nil }
        if forward {
            let next = matches.firstIndex {
                $0.range.location > location
                    || ($0.range.location == location && $0.range.length > 0)
            }
            return next ?? 0
        }
        return matches.lastIndex { $0.range.location < location } ?? (matches.count - 1)
    }

    /// The index of the match a caret at `location` is *on*, for the "which match
    /// am I looking at" question — the counter's `n` and the match Replace applies
    /// to. `nil` only when `matches` is empty.
    ///
    /// This is deliberately **not** `index(nearestTo:forward:)`, and the two must
    /// not be conflated: that one answers "where does Find Next go", so it refuses
    /// a **zero-length** match starting exactly at `location` in order to step off
    /// the match the caret already sits on. Asked "which match is current" it
    /// therefore names the *following* one — so for `^`, `\b` or `a*` the counter
    /// reads one ahead of the caret and Replace edits a match the user is not
    /// looking at (with `^`, the first line could never be replaced at all, and
    /// selecting a match would immediately advance the cursor past it).
    ///
    /// So a match starting exactly at the caret wins outright, whatever its
    /// length; only when the caret sits on no match's start does it fall back to
    /// the forward rule (the caret is mid-match or between matches, and the one at
    /// or after it is the one to name). Locations are strictly increasing, so at
    /// most one match can start at the caret.
    public static func currentIndex(forCaretAt location: Int, in matches: [SearchMatch]) -> Int? {
        guard !matches.isEmpty else { return nil }
        if let exact = matches.firstIndex(where: { $0.range.location == location }) { return exact }
        return index(nearestTo: location, in: matches, forward: true)
    }

    // MARK: - Range production

    private static func literalRanges(in text: NSString, query: SearchQuery) -> [NSRange] {
        // `.literal` keeps the comparison a strict UTF-16 one, so a found range's
        // length always matches the pattern's and the offsets stay predictable.
        var options: NSString.CompareOptions = [.literal]
        if !query.caseSensitive { options.insert(.caseInsensitive) }

        var ranges: [NSRange] = []
        var start = 0
        while start < text.length {
            let searchRange = NSRange(location: start, length: text.length - start)
            let found = text.range(of: query.pattern, options: options, range: searchRange)
            guard found.location != NSNotFound else { break }
            ranges.append(found)
            start = found.location + max(1, found.length)
        }
        return ranges
    }

    private static func regexRanges(in text: NSString, query: SearchQuery) throws -> [NSRange] {
        let regex = try regularExpression(for: query)
        let full = NSRange(location: 0, length: text.length)
        return regex.matches(in: text as String, options: [], range: full).map(\.range)
    }

    // MARK: - Whole word

    /// Whether both edges of `range` sit against a non-word neighbor. A buffer
    /// boundary counts as non-word, and "word" is `CharacterSet.alphanumerics`
    /// plus `_` (the identifier rule editors use).
    private static func isWholeWord(_ range: NSRange, in text: NSString) -> Bool {
        !isWordScalar(scalarBefore(text, offset: range.location))
            && !isWordScalar(scalarAt(text, offset: NSMaxRange(range)))
    }

    private static func isWordScalar(_ scalar: UnicodeScalar?) -> Bool {
        guard let scalar else { return false }
        return scalar == "_" || CharacterSet.alphanumerics.contains(scalar)
    }

    /// The scalar ending immediately before `offset`, combining a surrogate pair
    /// so an astral letter reads as the single letter it is rather than as a lone
    /// (non-alphanumeric) surrogate half — which would wave through a match that
    /// is not on a word boundary. `nil` at the buffer start or on an unpaired
    /// surrogate. (`AutoPairEngine.scalarBefore`'s rule.)
    private static func scalarBefore(_ text: NSString, offset: Int) -> UnicodeScalar? {
        let last = offset - 1
        guard last >= 0, last < text.length else { return nil }
        let unit = text.character(at: last)
        if (0xDC00...0xDFFF).contains(unit) {
            guard last - 1 >= 0 else { return nil }
            let high = text.character(at: last - 1)
            guard (0xD800...0xDBFF).contains(high) else { return nil }
            return UnicodeScalar(combine(high: high, low: unit))
        }
        return UnicodeScalar(unit)
    }

    /// The scalar starting at `offset`, combining a surrogate pair for the same
    /// reason as `scalarBefore`. `nil` at end-of-buffer or on an unpaired
    /// surrogate.
    private static func scalarAt(_ text: NSString, offset: Int) -> UnicodeScalar? {
        guard offset >= 0, offset < text.length else { return nil }
        let unit = text.character(at: offset)
        if (0xD800...0xDBFF).contains(unit) {
            guard offset + 1 < text.length else { return nil }
            let low = text.character(at: offset + 1)
            guard (0xDC00...0xDFFF).contains(low) else { return nil }
            return UnicodeScalar(combine(high: unit, low: low))
        }
        return UnicodeScalar(unit)
    }

    private static func combine(high: unichar, low: unichar) -> UInt32 {
        0x10000 + ((UInt32(high) - 0xD800) << 10) + (UInt32(low) - 0xDC00)
    }

    // MARK: - Line numbers

    /// 1-based line number of `offset` given ascending `lineStarts`: the last
    /// start that is `<= offset`, so a match sitting exactly on a line start
    /// belongs to *that* line.
    static func lineNumber(forOffset offset: Int, in lineStarts: [Int]) -> Int {
        guard !lineStarts.isEmpty else { return 1 }
        var low = 0
        var high = lineStarts.count - 1
        var best = 0
        while low <= high {
            let mid = (low + high) / 2
            if lineStarts[mid] <= offset {
                best = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return best + 1
    }
}
