import Foundation

/// The editor's single definition of *"what is an identifier"*, shared by the
/// three questions code intelligence asks about raw text: which word did the
/// user ⌘-click (`identifier(in:at:)`), which partial word are they typing
/// (`completionPrefixRange(in:at:)`), and which words does this buffer contain
/// (`words(in:limit:)`).
///
/// Pure and Foundation-only, operating on an `NSString` and UTF-16 offsets like
/// every other editor engine (`DuplicateEngine`, `BracketMatchEngine`,
/// `AutoPairEngine`), so a range it returns can be handed straight to the text
/// view — and to `EditorRevealState` — without a coordinate conversion.
///
/// **The one boundary rule**, deliberately shared by all three entry points so
/// the word a click resolves, the prefix a keystroke completes and the words the
/// harvester offers can never disagree:
///
/// - an identifier *starts* with a Unicode letter or `_`;
/// - it *continues* with letters, digits, combining marks and `_`;
/// - a maximal run of continuation scalars whose leading scalars are not valid
///   starts is trimmed from the left, so `9foo` yields `foo` and a pure number
///   (`123`) yields nothing at all.
///
/// Classification is Unicode-based (`CharacterSet.letters` /
/// `.alphanumerics`) rather than ASCII, so `имя`, `número` or `変数` are single
/// identifiers instead of being split or dropped; scanning is surrogate-pair
/// aware, so a non-BMP scalar in a name is never cut in half.
public enum IdentifierScanner {

    /// An identifier found in the text, with the UTF-16 range it occupies.
    public struct Match: Equatable, Sendable {
        /// The identifier's text, exactly as written.
        public let text: String
        /// Its UTF-16 range within the scanned string.
        public let range: NSRange

        public init(text: String, range: NSRange) {
            self.text = text
            self.range = range
        }
    }

    // MARK: - The boundary rule

    /// Whether `scalar` may *begin* an identifier: a Unicode letter or `_`.
    ///
    /// Digits are deliberately excluded — no supported language starts a name
    /// with one — which is what lets the trim step turn `9foo` into `foo` and
    /// keep `123` out of the completion list entirely.
    public static func isIdentifierStart(_ scalar: UnicodeScalar) -> Bool {
        scalar == "_" || CharacterSet.letters.contains(scalar)
    }

    /// Whether `scalar` may *continue* an identifier: a letter, digit,
    /// combining mark or `_`.
    ///
    /// `CharacterSet.alphanumerics` covers the Letter, Mark and Number
    /// categories, so a decomposed accent (`e` + U+0301) keeps the name it
    /// belongs to in one piece instead of ending it mid-word.
    public static func isIdentifierContinuation(_ scalar: UnicodeScalar) -> Bool {
        scalar == "_" || CharacterSet.alphanumerics.contains(scalar)
    }

    // MARK: - Lookup

    /// The whole identifier the caret (or a click) at `offset` lands in.
    ///
    /// Two probes, in this order: the identifier *containing* `offset`, then the
    /// one *ending* at it. The second is what makes the keyboard path work —
    /// after typing a name the caret sits just past its last character
    /// (`Worker|`), and Xcode's ⌃⌘J resolves that word rather than nothing. A
    /// click, which lands *on* a character, is answered by the first probe.
    ///
    /// `offset` is clamped into the string, so an out-of-date caret from a
    /// stale layout pass degrades to the nearest end instead of trapping.
    /// Returns `nil` when neither probe finds a name — whitespace, punctuation,
    /// or a run of digits.
    public static func identifier(in text: NSString, at offset: Int) -> Match? {
        let clamped = scalarStart(in: text, at: min(max(offset, 0), text.length))

        if let scalar = scalar(in: text, startingAt: clamped),
           isIdentifierContinuation(scalar.value),
           let match = identifierRun(in: text, seededBy: scalar.range) {
            return match
        }
        if let scalar = scalar(in: text, endingAt: clamped),
           isIdentifierContinuation(scalar.value),
           let match = identifierRun(in: text, seededBy: scalar.range) {
            return match
        }
        return nil
    }

    /// The range of the partial word immediately to the left of `offset` — what
    /// a completion replaces.
    ///
    /// Only the left side is taken: completion replaces what has been typed and
    /// leaves the rest of the line alone, so `foo.bar|` completes `bar` (the
    /// `.` ends the run) and `$FOO|` completes `FOO`. This is exactly what
    /// `NSTextView.rangeForUserCompletion` must report, and returning the whole
    /// dotted expression there is the classic reason a popup offers nothing.
    ///
    /// A caret that is not preceded by an identifier — start of file,
    /// whitespace, punctuation, or a bare number (`123|`, which cannot start a
    /// name) — yields an **empty range at the caret**, never `nil`, so callers
    /// can hand it to AppKit unconditionally.
    public static func completionPrefixRange(in text: NSString, at offset: Int) -> NSRange {
        let clamped = scalarStart(in: text, at: min(max(offset, 0), text.length))
        let empty = NSRange(location: clamped, length: 0)

        var start = clamped
        while let scalar = scalar(in: text, endingAt: start), isIdentifierContinuation(scalar.value) {
            start = scalar.range.location
        }
        guard start < clamped else { return empty }
        let run = NSRange(location: start, length: clamped - start)
        return trimmedIdentifier(in: text, range: run)?.range ?? empty
    }

    /// Every distinct identifier in `text`, in first-occurrence order, capped at
    /// `limit`.
    ///
    /// This is the graceful-degradation half of completion: a language with no
    /// `symbols.scm` — or a file the index has not reached yet — still offers
    /// the words the buffer itself contains, which is what every editor's
    /// "dumb" completion does.
    ///
    /// De-duplicated and capped for a reason: a minified bundle or a generated
    /// data file is a single buffer with hundreds of thousands of tokens, and an
    /// uncapped harvest would allocate that set on every debounce tick. The cap
    /// counts *distinct* words and scanning stops as soon as it is reached, so
    /// the cost is bounded by the cap rather than by the file size. First
    /// occurrence wins so the order is deterministic (a `Set` would reshuffle
    /// between runs, and the ranking layer's tie-breaks would then be the only
    /// thing keeping the list stable).
    public static func words(in text: NSString, limit: Int) -> [String] {
        guard limit > 0, text.length > 0 else { return [] }

        var words: [String] = []
        var seen = Set<String>()
        var index = 0
        while index < text.length {
            guard let scalar = scalar(in: text, startingAt: index) else {
                index += 1  // a lone surrogate half: skip the unit, never a name
                continue
            }
            guard isIdentifierContinuation(scalar.value) else {
                index = NSMaxRange(scalar.range)
                continue
            }
            var end = NSMaxRange(scalar.range)
            while let next = self.scalar(in: text, startingAt: end),
                  isIdentifierContinuation(next.value) {
                end = NSMaxRange(next.range)
            }
            let run = NSRange(location: index, length: end - index)
            if let match = trimmedIdentifier(in: text, range: run), seen.insert(match.text).inserted {
                words.append(match.text)
                if words.count == limit { return words }
            }
            index = end
        }
        return words
    }

    // MARK: - Scanning primitives

    /// One Unicode scalar together with the UTF-16 range it occupies (one unit,
    /// or two for a surrogate pair).
    private struct ScalarUnit {
        let value: UnicodeScalar
        let range: NSRange
    }

    /// The scalar whose units *begin* at `index`, or `nil` out of bounds or on a
    /// lone surrogate half (never part of an identifier).
    private static func scalar(in text: NSString, startingAt index: Int) -> ScalarUnit? {
        guard index >= 0, index < text.length else { return nil }
        let unit = text.character(at: index)
        if UTF16.isLeadSurrogate(unit) {
            guard index + 1 < text.length else { return nil }
            let trail = text.character(at: index + 1)
            guard UTF16.isTrailSurrogate(trail),
                  let value = UnicodeScalar(combining: unit, trail) else { return nil }
            return ScalarUnit(value: value, range: NSRange(location: index, length: 2))
        }
        guard let value = UnicodeScalar(unit) else { return nil }
        return ScalarUnit(value: value, range: NSRange(location: index, length: 1))
    }

    /// The scalar whose units *end* at `index` (i.e. the one immediately to the
    /// left of it), or `nil` at the start of the string or on a lone surrogate.
    private static func scalar(in text: NSString, endingAt index: Int) -> ScalarUnit? {
        guard index > 0, index <= text.length else { return nil }
        let unit = text.character(at: index - 1)
        if UTF16.isTrailSurrogate(unit) {
            guard index - 2 >= 0 else { return nil }
            let lead = text.character(at: index - 2)
            guard UTF16.isLeadSurrogate(lead),
                  let value = UnicodeScalar(combining: lead, unit) else { return nil }
            return ScalarUnit(value: value, range: NSRange(location: index - 2, length: 2))
        }
        guard let value = UnicodeScalar(unit) else { return nil }
        return ScalarUnit(value: value, range: NSRange(location: index - 1, length: 1))
    }

    /// `index` moved back onto a scalar boundary when it points at the trailing
    /// half of a surrogate pair — a caret can only ever *be* there through a
    /// stale offset, and answering "no identifier" for one would be a puzzling
    /// dead spot inside a name.
    private static func scalarStart(in text: NSString, at index: Int) -> Int {
        guard index > 0, index < text.length else { return index }
        guard UTF16.isTrailSurrogate(text.character(at: index)),
              UTF16.isLeadSurrogate(text.character(at: index - 1)) else { return index }
        return index - 1
    }

    /// Grow `seed` to the maximal run of continuation scalars around it, then
    /// apply the trim rule.
    private static func identifierRun(in text: NSString, seededBy seed: NSRange) -> Match? {
        var start = seed.location
        while let scalar = scalar(in: text, endingAt: start), isIdentifierContinuation(scalar.value) {
            start = scalar.range.location
        }
        var end = NSMaxRange(seed)
        while let scalar = scalar(in: text, startingAt: end), isIdentifierContinuation(scalar.value) {
            end = NSMaxRange(scalar.range)
        }
        return trimmedIdentifier(in: text, range: NSRange(location: start, length: end - start))
    }

    /// Drop leading scalars that cannot *start* an identifier, and report the
    /// rest; `nil` when nothing is left (a run of digits).
    private static func trimmedIdentifier(in text: NSString, range: NSRange) -> Match? {
        var start = range.location
        let end = NSMaxRange(range)
        while start < end,
              let scalar = scalar(in: text, startingAt: start),
              !isIdentifierStart(scalar.value) {
            start = NSMaxRange(scalar.range)
        }
        guard start < end else { return nil }
        let trimmed = NSRange(location: start, length: end - start)
        return Match(text: text.substring(with: trimmed), range: trimmed)
    }
}

private extension UnicodeScalar {
    /// The scalar a UTF-16 surrogate pair encodes. Both halves are validated by
    /// the caller, so the arithmetic cannot produce an invalid scalar value.
    init?(combining lead: unichar, _ trail: unichar) {
        let value = 0x10000
            + (UInt32(lead) - 0xD800) * 0x400
            + (UInt32(trail) - 0xDC00)
        self.init(value)
    }
}
