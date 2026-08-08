import Foundation

/// The editor's single definition of *"what is an identifier"*, shared by the
/// four questions code intelligence asks about raw text: which word did the
/// user ⌘-click (`identifier(in:at:)`), which partial word are they typing
/// (`completionPrefixRange(in:at:)`), which words does this buffer contain
/// (`words(in:limit:)`), and is the caret sitting after a member-access dot
/// (`memberContext(in:at:)`).
///
/// Pure and Foundation-only, operating on an `NSString` and UTF-16 offsets like
/// every other editor engine (`DuplicateEngine`, `BracketMatchEngine`,
/// `AutoPairEngine`), so a range it returns can be handed straight to the text
/// view — and to `EditorRevealState` — without a coordinate conversion.
///
/// **The one boundary rule**, deliberately shared by every entry point so the
/// word a click resolves, the prefix a keystroke completes, the words the
/// harvester offers and the receiver a dot hangs off can never disagree:
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

    /// The caret sitting in a *member position* — just after a `.` that hangs
    /// off something a member could belong to.
    public struct MemberContext: Equatable, Sendable {
        /// The identifier immediately left of the dot (`worker` in `worker.na|`),
        /// or `nil` when the dot follows a closing bracket (`f().|`,
        /// `items[0].|`) — an expression whose spelling says nothing about the
        /// type, so the ranking has no receiver to prefer.
        public let receiver: String?
        /// The UTF-16 range a completion replaces: the member prefix already
        /// typed after the dot, **possibly empty** when the dot was just typed.
        /// Always equal to `completionPrefixRange(in:at:)` at the same offset,
        /// so the two paths can never insert at different places.
        public let prefixRange: NSRange

        public init(receiver: String?, prefixRange: NSRange) {
            self.receiver = receiver
            self.prefixRange = prefixRange
        }
    }

    // MARK: - The boundary rule

    /// Whether `scalar` may *begin* an identifier: a Unicode letter or `_`.
    ///
    /// Digits are deliberately excluded — no supported language starts a name
    /// with one — which is what lets the trim step turn `9foo` into `foo` and
    /// keep `123` out of the completion list entirely.
    public static func isIdentifierStart(_ scalar: UnicodeScalar) -> Bool {
        if scalar.isASCII { return isASCIILetterOrUnderscore(scalar) }
        return letters.contains(scalar)
    }

    /// Whether `scalar` may *continue* an identifier: a letter, digit,
    /// combining mark or `_`.
    ///
    /// `CharacterSet.alphanumerics` covers the Letter, Mark and Number
    /// categories, so a decomposed accent (`e` + U+0301) keeps the name it
    /// belongs to in one piece instead of ending it mid-word.
    public static func isIdentifierContinuation(_ scalar: UnicodeScalar) -> Bool {
        if scalar.isASCII { return isASCIILetterOrUnderscore(scalar) || (scalar >= "0" && scalar <= "9") }
        return alphanumerics.contains(scalar)
    }

    /// The ASCII half of both rules, which is what source code is made of.
    ///
    /// `CharacterSet.letters`/`.alphanumerics` are computed properties: each
    /// access *builds* a bridged set, and `words(in:limit:)` asks the question
    /// once per scalar of the whole buffer on every completion tick. Answering
    /// the ASCII range with two range compares — and holding the Unicode sets in
    /// `static let`s for everything else — keeps the classification identical
    /// (`CharacterSet.letters` is exactly `A-Za-z` within ASCII, and
    /// `.alphanumerics` adds exactly `0-9`) while taking the allocation out of
    /// the loop. Same reasoning as `BracketDepthScanner`'s bulk read: these
    /// scanners run over a whole file behind a debounce, so a per-scalar
    /// allocation is the cost that matters.
    private static func isASCIILetterOrUnderscore(_ scalar: UnicodeScalar) -> Bool {
        (scalar >= "a" && scalar <= "z") || (scalar >= "A" && scalar <= "Z") || scalar == "_"
    }

    private static let letters = CharacterSet.letters
    private static let alphanumerics = CharacterSet.alphanumerics

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

    /// Whether the caret at `offset` sits in a member position — after a `.`
    /// that hangs off an identifier or a closing bracket — and, if so, what the
    /// completion should replace and which receiver it hangs off.
    ///
    /// This extends the file's one boundary rule rather than inventing a second
    /// one: the member prefix is the same maximal run of continuation scalars
    /// `completionPrefixRange(in:at:)` takes (and `prefixRange` is literally that
    /// call's answer, so the two can never disagree about the insertion point),
    /// and the receiver is the same `identifierRun` a ⌘-click would resolve.
    ///
    /// The dot must hang off something a member could belong to. Accepted:
    /// an identifier (`worker.|`) and the closing brackets `)`, `]`, `}`
    /// (`f().|`, `items[0].|`, `{ … }.|`), whose expression yields *some* value
    /// even though its spelling names no type — hence `receiver == nil` there.
    /// Rejected, all yielding `nil`: a dot after whitespace (`foo .|`), after
    /// `(` or `,`, after another dot (`..|`), at the start of the file, and
    /// after a bare number — `1.|` and `1.5|` are float literals, caught by the
    /// trim rule (a run of digits is not an identifier), so typing a decimal
    /// point never opens a member list. The same trim rule rejects a member
    /// prefix that does not *begin* where the dot ends (`pair.0|`,
    /// `ubuntu20.04|`, `ubuntu20.04lts|`) — see the guard below.
    ///
    /// **String and comment context is deliberately not detected.** A dot inside
    /// a string literal or a comment *does* report a member position, exactly as
    /// identifier completion already offers candidates while typing inside one:
    /// knowing better needs the syntax tree, which this Foundation-only scanner
    /// does not have, and the provider's own rules (a bare dot offers members
    /// only, never buffer words) are what keep the resulting popup quiet.
    ///
    /// `offset` is clamped and moved onto a scalar boundary like the rest of the
    /// file, so a stale caret degrades instead of trapping.
    public static func memberContext(in text: NSString, at offset: Int) -> MemberContext? {
        let clamped = scalarStart(in: text, at: min(max(offset, 0), text.length))

        // The member prefix: the run of continuation scalars left of the caret.
        var start = clamped
        while let scalar = scalar(in: text, endingAt: start), isIdentifierContinuation(scalar.value) {
            start = scalar.range.location
        }

        // The dot must be immediately before it — no whitespace is tolerated,
        // so `foo .|` is not a member position.
        guard let dot = scalar(in: text, endingAt: start), dot.value == "." else { return nil }
        guard let preceding = scalar(in: text, endingAt: dot.range.location) else { return nil }

        let prefixRange = completionPrefixRange(in: text, at: clamped)
        // **The member prefix must begin right after the dot.** `prefixRange` is
        // the trimmed identifier inside the run, so the two agree exactly when
        // the run either is empty (the legitimate bare-dot case, an empty range
        // at the caret) or starts with something that can begin a name. Anywhere
        // they disagree, the text after the dot opens with digits — and reporting
        // a member position there would be wrong at whichever offset the trim
        // landed on: `pair.0|` and `ubuntu20.04|` trim to *nothing*, leaving the
        // empty range the provider reads as "the dot was just typed" and answers
        // with every member in the project while the editors insert at it,
        // turning `pair.0` into `pair.0doWork`; `ubuntu20.04lts|` trims to `lts`,
        // three characters into a run that is not a member access at all, and
        // completing it rewrites the version to `ubuntu20.04doWork`. Swift tuple
        // access (`pair.0`, `point.1`) hits the first shape on every keystroke,
        // version-shaped text both.
        guard prefixRange.location == start else { return nil }
        if preceding.value == ")" || preceding.value == "]" || preceding.value == "}" {
            return MemberContext(receiver: nil, prefixRange: prefixRange)
        }
        guard isIdentifierContinuation(preceding.value),
              let receiver = identifierRun(in: text, seededBy: preceding.range) else { return nil }
        return MemberContext(receiver: receiver.text, prefixRange: prefixRange)
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
