import Foundation

/// The completion matcher: *"does this candidate answer what the user typed,
/// and how well"* — one subsequence walk shared by every candidate source
/// (indexed symbols, language keywords, harvested buffer words) so a fuzzy hit
/// means the same thing wherever it comes from.
///
/// Pure and Foundation-only, operating on `Character`s (grapheme clusters)
/// rather than on UTF-16 units: this type never reports a range back to the
/// text view, it only compares two names and produces a sort key, so working in
/// characters is what keeps a decomposed accent or an emoji in an identifier
/// from being cut in half by the walk.
///
/// **The one boundary rule of this file** — what counts as the start of a
/// "word" inside a name — is deliberately kept here in a single place, because
/// two very different things depend on it agreeing with itself:
/// `SymbolIndex`'s lookup bucket is keyed by the boundary initials, and the
/// ranking prefers a match whose characters land on boundaries. A name's word
/// starts are:
///
/// - index 0, always (including a leading `_`, so `_private` is reachable by
///   typing the underscore as well as by typing `p`);
/// - a camelCase hump: any uppercase character not preceded by an uppercase
///   one (`arrayBuffer` → `B`), plus the *last* uppercase of an uppercase run
///   that is followed by a lowercase one (`URLSession` → `S`, not `R`/`L`);
/// - the character after a `_` or `-` separator (`snake_case` → `c`);
/// - either side of a digit/letter transition (`base64Encoder` → `6`, `E`).
///
/// **A fuzzy match must *start* on a word boundary.** `buf` matches
/// `ArrayBuffer` (the hump), `rray` does not. That is not a performance
/// accident of the index's bucket — it is stated here, in the matcher, so that
/// a buffer word and a keyword (neither of which is looked up through a bucket)
/// obey exactly the same rule as a symbol. It is also what keeps the candidate
/// set intelligible: without it, a three-letter query matches an appreciable
/// fraction of every project's identifiers and the popup stops being a ranking
/// problem and becomes a lottery. The boundary it starts on must additionally be
/// one of the name's first `maximumInitials` — see that constant for why the
/// matcher, not just the index, is where the cap has to be stated.
public enum FuzzyMatch {

    /// How many bucket keys one name may contribute — **and therefore how many
    /// of its word boundaries a fuzzy match may be anchored on.**
    ///
    /// A generated or minified file can hold identifiers with dozens of humps,
    /// and every initial is an entry appended to a project-wide bucket. Eight
    /// covers every hand-written name (`NSAttributedStringKey` has four) while
    /// bounding what one pathological identifier can do to the index's memory.
    /// The kept eight are the *first* eight in name order, so the cap is
    /// deterministic rather than dictionary-ordered.
    ///
    /// The cap is enforced in `quality(of:matching:)` as well as in
    /// `wordBoundaryInitials(of:)`, and that symmetry is load-bearing rather than
    /// tidy: `SymbolIndex` reads exactly one bucket per query, so a matcher that
    /// accepted a match anchored on a ninth boundary would claim candidates the
    /// index can never hand back — the same query would then find such a name as
    /// a keyword or a harvested buffer word and silently *not* as the identical
    /// indexed symbol, which looks exactly like "not indexed yet".
    public static let maximumInitials = 8

    // MARK: - Quality

    /// How well a candidate answers a query — the completion ranking's first
    /// key, ordered best-first (a *smaller* value is a better match).
    ///
    /// The keys, in comparison order:
    ///
    /// 1. `tier` — 0 a case-sensitive prefix, 1 a case-insensitive prefix,
    ///    2 a fuzzy (subsequence) match. The user's capitalization is a signal,
    ///    and a literal prefix is always a better answer than a scattered one.
    /// 2. `offBoundary` — how many matched characters did *not* land on a word
    ///    boundary. `aBu` → `ArrayBuffer` (two humps hit) reads as intentional;
    ///    the same three characters scattered through the middle of a name do
    ///    not.
    /// 3. `span` — last matched index minus first: a tighter match over a
    ///    looser one.
    /// 4. `start` — where the match begins: earlier over later.
    ///
    /// **For a prefix match (`tier` 0 or 1) the three fuzzy sub-keys are
    /// pinned to zero**, not computed. That is what keeps the pre-existing
    /// ranking intact bit-for-bit: with a literal prefix the whole key collapses
    /// to the two-valued case rank the provider ranked on before fuzzy matching
    /// existed, so every candidate that would have tied then still ties now and
    /// the later tie-breaks decide, exactly as before.
    public struct Quality: Comparable, Hashable, Sendable {
        /// A prefix match with the typed capitalization.
        public static let caseSensitivePrefixTier = 0
        /// A prefix match ignoring capitalization.
        public static let caseInsensitivePrefixTier = 1
        /// A subsequence match that is not a prefix.
        public static let fuzzyTier = 2

        public let tier: Int
        public let offBoundary: Int
        public let span: Int
        public let start: Int

        public init(tier: Int, offBoundary: Int, span: Int, start: Int) {
            self.tier = tier
            self.offBoundary = offBoundary
            self.span = span
            self.start = start
        }

        /// Whether the candidate literally starts with the query — the state in
        /// which the fuzzy sub-keys carry no information.
        public var isPrefixMatch: Bool { tier < Self.fuzzyTier }

        public static func < (lhs: Quality, rhs: Quality) -> Bool {
            if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
            if lhs.offBoundary != rhs.offBoundary { return lhs.offBoundary < rhs.offBoundary }
            if lhs.span != rhs.span { return lhs.span < rhs.span }
            return lhs.start < rhs.start
        }

        /// The pinned key of a prefix match — see the type's note on why the
        /// fuzzy sub-keys are constant here.
        fileprivate static func prefix(tier: Int) -> Quality {
            Quality(tier: tier, offBoundary: 0, span: 0, start: 0)
        }
    }

    // MARK: - Matching

    /// How well `candidate` answers `query`, or `nil` when it does not.
    ///
    /// `nil` means one of exactly three things, and nothing else: the query is
    /// empty (nothing typed, nothing to rank), the query is not a
    /// case-insensitive subsequence of the candidate, or the query's first
    /// character does not name one of the candidate's word-boundary initials
    /// (the rule stated on the type, bounded by `maximumInitials` — so a
    /// character occurring only *off* a boundary, or only on a boundary past the
    /// cap, is not a match).
    ///
    /// The walk is greedy and left-to-right, and deliberately deterministic
    /// rather than optimal: for each query character it takes the next
    /// *boundary* occurrence if there is one and the next occurrence otherwise,
    /// and if that pass runs out of candidate it retries taking the leftmost
    /// occurrence throughout. Two passes rather than a search because the
    /// candidate set is scanned once per keystroke: the pair answers "is this a
    /// subsequence at all" exactly, and only the *quality* of a pathological
    /// name (`abC_bx` matched against `abc`, where the boundary-preferring pass
    /// is the one that has to back off) is decided by which pass succeeded.
    public static func quality(of candidate: String, matching query: String) -> Quality? {
        guard !query.isEmpty, !candidate.isEmpty else { return nil }

        // The prefix tiers first: they are the common case, they short-circuit
        // the character-array work below, and their key is a constant.
        if candidate.hasPrefix(query) { return .prefix(tier: Quality.caseSensitivePrefixTier) }
        // `lowercased()` allocates a whole String per side, so it is reached only
        // once the first characters agree — a necessary condition for the prefix
        // (the first character of a lowercased string is the lowercased first
        // character), and one that rejects nearly every candidate for two
        // character lowercasings instead of two string allocations.
        if let queried = query.first, let leading = candidate.first,
           lowercased(leading) == lowercased(queried),
           candidate.lowercased().hasPrefix(query.lowercased()) {
            return .prefix(tier: Quality.caseInsensitivePrefixTier)
        }

        // **The allocation gate.** Everything below builds four arrays per
        // candidate, and this function is asked about every harvested buffer
        // word (up to `defaultBufferWordLimit`), every keyword and — in member
        // position — every member the index holds, on every completion tick.
        // Answering "no" is by far the common case, so it must not cost an
        // allocation: this walk is the *necessary* half of what `positions`
        // decides (that one additionally demands the first character land on a
        // boundary, so it can only reject more), done over the two strings in
        // place. Without it a rejection costs the same as a match — measurably
        // ~100× the literal-prefix test this matcher replaced, paid on the
        // ordinary per-keystroke path rather than only after a dot.
        guard isSubsequence(query, of: candidate) else { return nil }

        let characters = Array(candidate)
        let lowered = characters.map(lowercased)
        let target = query.map(lowercased)
        let boundaries = boundaryFlags(of: characters)

        // The bucket agreement, enforced here rather than left to the index — see
        // `maximumInitials`. A name contributes at most that many keys, so a match
        // anchored on a later boundary is one `SymbolIndex` could never return,
        // and stating the restriction in the matcher is what keeps a symbol, a
        // keyword and a buffer word answering the same query alike.
        guard let queried = target.first,
              boundaryInitials(of: lowered, boundaries: boundaries).contains(queried)
        else { return nil }

        guard let positions = positions(of: target, in: lowered, boundaries: boundaries, preferringBoundaries: true)
                ?? positions(of: target, in: lowered, boundaries: boundaries, preferringBoundaries: false),
              let first = positions.first, let last = positions.last
        else { return nil }

        return Quality(
            tier: Quality.fuzzyTier,
            offBoundary: positions.reduce(0) { $0 + (boundaries[$1] ? 0 : 1) },
            span: last - first,
            start: first
        )
    }

    /// Whether `candidate` answers `query` at all — `quality(of:matching:)`
    /// without the key, for the filtering call sites that do not rank.
    public static func matches(_ candidate: String, query: String) -> Bool {
        quality(of: candidate, matching: query) != nil
    }

    /// The deduplicated, lowercased characters that begin a word in `name`, in
    /// name order, capped at `maximumInitials`.
    ///
    /// These are exactly the characters a query may *start* with and still
    /// reach this name, which is why `SymbolIndex` files a symbol under all of
    /// them: a completion request then looks in the one bucket its first typed
    /// character names and finds every candidate the matcher could accept,
    /// without a project-wide scan.
    public static func wordBoundaryInitials(of name: String) -> [Character] {
        let characters = Array(name)
        return boundaryInitials(
            of: characters.map(lowercased),
            boundaries: boundaryFlags(of: characters)
        )
    }

    // MARK: - Primitives

    /// The capped, deduplicated boundary initials of an already-lowercased name —
    /// the one implementation `wordBoundaryInitials(of:)` (which files a symbol)
    /// and `quality(of:matching:)` (which decides whether a query may reach it)
    /// both go through, so the two cannot drift apart at the cap.
    private static func boundaryInitials(of lowered: [Character], boundaries: [Bool]) -> [Character] {
        var initials: [Character] = []
        for index in lowered.indices where boundaries[index] {
            let initial = lowered[index]
            // A linear scan rather than a `Set`: the list is capped at
            // `maximumInitials`, so the membership test is over at most eight
            // characters, and this runs once per symbol on every re-index as
            // well as once per surviving candidate on every completion tick —
            // where allocating a hash set to hold eight characters is the cost
            // that shows up, not the comparisons it saves.
            guard !initials.contains(initial) else { continue }
            initials.append(initial)
            if initials.count == maximumInitials { break }
        }
        return initials
    }

    /// Whether `query` is a case-insensitive subsequence of `candidate` — the
    /// allocation-free necessary condition `quality(of:matching:)` gates its
    /// array work behind.
    ///
    /// Lowercasing is per-character, exactly as the arrays below do it, so this
    /// walk and `positions(of:in:boundaries:preferringBoundaries:)` cannot
    /// disagree about which characters are equal.
    private static func isSubsequence(_ query: String, of candidate: String) -> Bool {
        var remaining = query.makeIterator()
        guard var needle = remaining.next().map(lowercased) else { return true }
        for character in candidate where lowercased(character) == needle {
            guard let next = remaining.next() else { return true }
            needle = lowercased(next)
        }
        return false
    }

    /// One index per query character, or `nil` when the walk cannot place them
    /// all. The first character is restricted to boundary positions in *both*
    /// passes — that restriction is the rule, not a heuristic of one pass.
    private static func positions(
        of query: [Character],
        in candidate: [Character],
        boundaries: [Bool],
        preferringBoundaries: Bool
    ) -> [Int]? {
        var positions: [Int] = []
        positions.reserveCapacity(query.count)

        var searchFrom = 0
        for (offset, character) in query.enumerated() {
            let boundaryOnly = offset == 0
            var leftmost: Int?
            var onBoundary: Int?
            var index = searchFrom
            while index < candidate.count {
                if candidate[index] == character {
                    if boundaries[index] { onBoundary = index; break }
                    if leftmost == nil { leftmost = index }
                    if !preferringBoundaries && !boundaryOnly { break }
                }
                index += 1
            }
            guard let chosen = onBoundary ?? (boundaryOnly ? nil : leftmost) else { return nil }
            positions.append(chosen)
            searchFrom = chosen + 1
        }
        return positions
    }

    /// Which characters of `characters` begin a word — the rule stated on the
    /// type, in one pass.
    private static func boundaryFlags(of characters: [Character]) -> [Bool] {
        guard !characters.isEmpty else { return [] }

        var flags = [Bool](repeating: false, count: characters.count)
        flags[0] = true
        guard characters.count > 1 else { return flags }

        for index in 1..<characters.count {
            let current = characters[index]
            let previous = characters[index - 1]

            // A separator is not itself a word start; the character after it is
            // (so `foo__bar` marks `b`, not the second `_`).
            if isSeparator(current) { continue }
            if isSeparator(previous) { flags[index] = true; continue }

            if current.isUppercase {
                if !previous.isUppercase {
                    flags[index] = true  // `arrayBuffer`, `utf8Data`
                    continue
                }
                // The tail of an uppercase run that turns into a word:
                // `URLSession` → `S`, while `URL` alone marks nothing after `U`.
                if index + 1 < characters.count, characters[index + 1].isLowercase {
                    flags[index] = true
                    continue
                }
                continue
            }

            if (previous.isNumber && current.isLetter) || (previous.isLetter && current.isNumber) {
                flags[index] = true  // `base64`, `utf8data`
            }
        }
        return flags
    }

    private static func isSeparator(_ character: Character) -> Bool {
        character == "_" || character == "-"
    }

    /// One character lowercased, staying one character.
    ///
    /// `String.lowercased()` can widen a character (`İ` → `i` + U+0307), and
    /// widening it here would desynchronize the lowercased array from the
    /// boundary flags computed over the original. Taking the first character of
    /// the lowercased form keeps the two arrays index-for-index aligned, and
    /// agrees with how `SymbolIndex` derived its bucket key before this file
    /// existed. The already-lowercase fast path is what most source code hits.
    private static func lowercased(_ character: Character) -> Character {
        if character.isLowercase { return character }
        return character.lowercased().first ?? character
    }
}
