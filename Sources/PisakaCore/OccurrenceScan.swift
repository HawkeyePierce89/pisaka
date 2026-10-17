import Foundation

/// The textual half of occurrence highlighting: every place one buffer spells a
/// name (R2) or a selected string (R3), against a **charged work budget**.
///
/// It runs on the main actor at a caret settle, against whatever the editor
/// holds — including a minified bundle's single multi-megabyte line — so unlike
/// `TextualUsageScanner`, which a user asked for and waits on, this scan must be
/// able to give up. `nil` is that answer: *the budget ran out*, and the caller
/// paints nothing rather than a partial list that would claim the rest of the
/// file holds no occurrence.
///
/// **The boundary rule is not restated here.** A candidate is a whole word
/// exactly when `IdentifierScanner.identifier(in:at:language:)` resolves that
/// range to that text — `TextualUsageScanner`'s question, asked the same way —
/// so the highlight, ⌘-click, completion and Find Usages agree about what a word
/// is. Unlike that scanner this one builds no line index and no previews: the
/// highlight wants ranges and nothing else.
///
/// **Bookkeeping is double-entry** (`EditorConfigGlob.MatchWork`'s pattern and
/// reasoning): each site `record`s what a step costs and `spend`s what it is
/// charged, as two separate calls, so a test can tell a budget that stopped the
/// scan from one that was merely never charged. A step records what it walked —
/// the literal search's units, plus for an identifier the run the whole-word
/// check walked — and is charged the literal walk plus the span from where it
/// began to where the scan resumes, which bounds the check's walk only while the
/// scan skips past each run.
///
/// **Linear by construction**, which is what makes the charges honest: after a
/// whole-word check the scan resumes past the *whole identifier run* the check
/// resolved, not merely past the hit, because no later hit inside the same run
/// can be a whole word (it resolves to the same run). Without that skip, a
/// needle repeated inside one long run (`_1` in `_1_1_1…`) would re-walk the run
/// once per hit.
///
/// Pure, Foundation-only, `NSString`/UTF-16 like every other editor engine.
public enum OccurrenceScan {

    /// The production ceiling, in UTF-16 units of work — two mebi-units, so an
    /// ordinary file is scanned whole a few times over and a pathological one
    /// stops after a bounded walk.
    public static let maximumWorkUnits = 2_097_152

    /// Every whole-word, case-sensitive occurrence of `identifier` in `text`, in
    /// ascending order; `nil` when the budget ran out first.
    ///
    /// `[]` — not `nil` — for a query that is not one identifier by the
    /// language's rule: it cannot occur as a word, so there is nothing to scan
    /// for. Matching is `.literal`, exact UTF-16 units, so every range names a
    /// span the length of the query.
    public static func identifierMatches(
        of identifier: String,
        in text: NSString,
        language: SyntaxLanguage? = nil,
        budget: Int = maximumWorkUnits
    ) -> [NSRange]? {
        var work = Work(budget: budget)
        return identifierMatches(of: identifier, in: text, language: language, work: &work)
    }

    /// Every literal, case-sensitive, non-overlapping occurrence of `needle` in
    /// `text`, in ascending order; `nil` when the budget ran out first.
    ///
    /// `limit` stops the scan once that many matches are found — the selection
    /// match's cap asks for one past its own bound, which is all it needs to
    /// refuse — and is not a budget answer: a limited scan answers the matches
    /// it found.
    public static func exactMatches(
        of needle: String,
        in text: NSString,
        budget: Int = maximumWorkUnits,
        limit: Int = .max
    ) -> [NSRange]? {
        var work = Work(budget: budget)
        return exactMatches(of: needle, in: text, limit: limit, work: &work)
    }

    // MARK: - Work bookkeeping

    /// The ceiling and the work actually done under it, booked separately; see
    /// `EditorConfigGlob.MatchWork` for why the pair is two numbers and two
    /// calls, never one.
    struct Work {
        /// What is left of the ceiling.
        private(set) var budget: Int
        /// UTF-16 units of work the scan really did, whatever it was charged.
        private(set) var performed = 0

        init(budget: Int) {
            self.budget = budget
        }

        /// Records `units` of work the scan just did. Always paired with the
        /// `spend(_:)` that pays for it.
        mutating func record(_ units: Int) {
            performed += units
        }

        /// Charges `cost` units of the ceiling for the work just recorded.
        mutating func spend(_ cost: Int) {
            budget -= cost
        }

        var isExhausted: Bool { budget <= 0 }
    }

    /// The test seam: the identifier scan against a `Work` the caller owns, so a
    /// test reads both what was left of the ceiling and what was performed.
    static func identifierMatches(
        of identifier: String,
        in text: NSString,
        language: SyntaxLanguage?,
        work: inout Work
    ) -> [NSRange]? {
        guard IdentifierScanner.isIdentifier(identifier, language: language) else { return [] }
        let needle = identifier as NSString
        var ranges: [NSRange] = []
        var searchStart = 0
        while searchStart <= text.length - needle.length {
            guard let found = nextLiteral(needle, in: text, from: searchStart, work: &work) else { return nil }
            guard found.location != NSNotFound else { break }

            // The check walks the run containing the hit, back to its start and
            // on to its end: that run is the work recorded. The charge is the
            // span from `searchStart` to where the scan resumes, which bounds the
            // walk only because the run starts at or after `searchStart` (the
            // scan always resumes at a run's end) — so a scan that stopped
            // skipping the run would record far more than it was charged.
            let word = IdentifierScanner.identifier(in: text, at: found.location, language: language)
            let resume = max(NSMaxRange(found), word.map { NSMaxRange($0.range) } ?? 0)
            work.record(word?.range.length ?? needle.length)
            work.spend(resume - searchStart)
            if let word, word.range == found, word.text == identifier {
                ranges.append(found)
            }
            if work.isExhausted { return nil }
            searchStart = resume
        }
        return ranges
    }

    /// The test seam for the literal scan; see `identifierMatches(of:in:language:work:)`.
    static func exactMatches(
        of needle: String,
        in text: NSString,
        limit: Int,
        work: inout Work
    ) -> [NSRange]? {
        let needle = needle as NSString
        guard needle.length > 0 else { return [] }
        var ranges: [NSRange] = []
        var searchStart = 0
        while ranges.count < limit, searchStart <= text.length - needle.length {
            guard let found = nextLiteral(needle, in: text, from: searchStart, work: &work) else { return nil }
            guard found.location != NSNotFound else { break }
            ranges.append(found)
            searchStart = NSMaxRange(found)
        }
        return ranges
    }

    /// The next literal occurrence of `needle` at or after `start`, searching no
    /// further than the budget can pay for.
    ///
    /// Answers a range (`NSNotFound` location ⇒ none in the rest of the text) or
    /// `nil` when the window the budget allowed ended before the text did and
    /// held no occurrence — exhaustion. The units walked are recorded and spent
    /// here, once per search.
    private static func nextLiteral(
        _ needle: NSString,
        in text: NSString,
        from start: Int,
        work: inout Work
    ) -> NSRange? {
        guard !work.isExhausted else { return nil }
        let remaining = text.length - start
        // The window must hold a whole needle, or a budget smaller than the
        // needle could never find one and never report exhaustion either.
        let window = min(remaining, max(work.budget, needle.length))
        let found = text.range(
            of: needle as String,
            options: .literal,
            range: NSRange(location: start, length: window)
        )
        if found.location != NSNotFound {
            work.record(NSMaxRange(found) - start)
            work.spend(NSMaxRange(found) - start)
            return found
        }
        work.record(window)
        work.spend(window)
        return window < remaining ? nil : found
    }
}
