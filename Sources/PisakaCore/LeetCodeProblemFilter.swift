import Foundation

/// What the problem browser is currently showing, as one value.
///
/// The browser is a **client-side filter over the one catalog** (L23): the whole
/// problem list is already in hand — `LeetCodeCatalog` holds every row from one
/// REST request, cached on disk — so narrowing it is a pure pass over an array
/// rather than an endpoint. Nothing here touches the network, and nothing here
/// is added to `LeetCodeAPI`.
///
/// It is one value rather than three separate published fields on the model so
/// that the model has exactly one place to recompute from, and so a surface
/// cannot set a field and forget to re-run the filter.
public struct LeetCodeProblemFilter: Equatable, Sendable {
    /// What the user typed into the search field, verbatim (trimmed on use).
    public var query: String
    /// The difficulties to keep. **Empty means no filtering** — see ``apply(to:)``.
    public var difficulties: Set<LeetCodeDifficulty>
    /// The per-account statuses to keep. **Empty means no filtering**.
    public var statuses: Set<LeetCodeProblemStatus>

    public init(
        query: String = "",
        difficulties: Set<LeetCodeDifficulty> = [],
        statuses: Set<LeetCodeProblemStatus> = []
    ) {
        self.query = query
        self.difficulties = difficulties
        self.statuses = statuses
    }

    /// Whether this filter narrows nothing, so a surface can tell "no problems
    /// match your filter" from "no problems at all" — two different sentences
    /// and two different fixes.
    public var isEmpty: Bool {
        trimmedQuery.isEmpty && difficulties.isEmpty && statuses.isEmpty
    }

    /// The rows this filter leaves, in the order they arrived.
    ///
    /// One pass, no sort: **catalog order is preserved by construction**, so the
    /// browser can never drift into disagreeing with LeetCode's own ordering the
    /// way a re-sort added later would.
    ///
    /// The rules, in the order they are applied:
    ///
    /// - The query is trimmed of whitespace and newlines; empty (or
    ///   all-whitespace) matches every row.
    /// - **Whether the query is a number is asked through
    ///   ``LeetCodeProblemInput/parse(_:)``**, so L4 — "an all-digit input is a
    ///   number attempt and nothing else" — is reused rather than restated. A
    ///   `.number(n)` matches `frontendID == n` **exactly and matches nothing
    ///   else**: typing `1` answers problem 1, not the ~1000 rows whose number
    ///   begins with a 1.
    /// - Every other parse result — a slug, a URL, or nothing at all — falls
    ///   through to a substring match on the **raw trimmed query**, so a pasted
    ///   problem URL matches nothing here (the Open Problem field is that
    ///   paste's surface and already handles it).
    /// - The substring match is case-insensitive over the **title or the slug**,
    ///   through `range(of:options:)` and deliberately *not* the `localized…`
    ///   variants: the answer must not depend on the device's locale.
    /// - Difficulty and status are set membership, and an **empty set means no
    ///   filtering** — so "nothing selected" and "everything selected" behave
    ///   identically, which is what a row of toggles needs.
    ///
    /// **`isPaidOnly` is deliberately not a dimension of this type.** Premium
    /// rows are always shown (with a lock marker on the surface) and can never
    /// be hidden: hiding them would misrepresent LeetCode's numbering, leaving
    /// gaps a user would read as missing problems. Stating that as an absent
    /// field rather than as a flag defaulted to `false` is what makes it
    /// structural instead of a default someone can flip.
    public func apply(to rows: [LeetCodeProblem]) -> [LeetCodeProblem] {
        let query = trimmedQuery
        let number: Int? = {
            guard !query.isEmpty, case .number(let value)? = LeetCodeProblemInput.parse(query) else {
                return nil
            }
            return value
        }()

        return rows.filter { row in
            if !difficulties.isEmpty, !difficulties.contains(row.difficulty) { return false }
            if !statuses.isEmpty, !statuses.contains(row.status) { return false }
            guard !query.isEmpty else { return true }
            if let number { return row.frontendID == number }
            return row.title.range(of: query, options: .caseInsensitive) != nil
                || row.slug.range(of: query, options: .caseInsensitive) != nil
        }
    }

    /// The query with surrounding whitespace and newlines removed — the form
    /// both ``isEmpty`` and ``apply(to:)`` reason about, so they cannot disagree
    /// about whether a field holding two spaces is a search.
    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
