import Foundation

/// A problem's difficulty.
///
/// One enum for two wire spellings: GraphQL says `"Easy"/"Medium"/"Hard"` and the
/// legacy REST catalog says `level: 1/2/3`. Both mappings live in `LeetCodeAPI`
/// (the one schema file), and both treat an unrecognised value as `apiChanged`
/// rather than defaulting — "everything is Easy" is exactly the kind of silent
/// wrongness an unofficial API produces when it changes.
public enum LeetCodeDifficulty: String, Equatable, Sendable, CaseIterable {
    case easy
    case medium
    case hard
}

/// How far this account has got with a problem.
///
/// Only meaningful signed in; the REST catalog reports it as `status: "ac"`,
/// `"notac"` or `null`. Carried now because it costs nothing (it arrives in the
/// catalog response either way) and the problem list surfaces it later.
public enum LeetCodeProblemStatus: String, Equatable, Sendable, CaseIterable {
    /// Never submitted.
    case notStarted
    /// Submitted, never accepted.
    case attempted
    /// Accepted at least once.
    case solved
}

/// One problem as the catalog knows it — everything needed to name a file and
/// show a row, and nothing that requires a second request.
///
/// The identifier that matters is `frontendID`: the number a user types and the
/// number on the site ("1" is Two Sum). LeetCode also has an internal
/// `question_id` which drifts from it for newer problems; this layer never uses
/// it, so it is deliberately not modelled.
///
/// Not `Codable`: the cached catalog on disk has its own versioned DTO
/// (`LeetCodeCatalog`), so this model can be renamed or extended without
/// invalidating every user's cache, and the on-disk shape is changed only on
/// purpose.
public struct LeetCodeProblem: Equatable, Sendable {
    /// The user-visible problem number (`questionFrontendId` / REST's
    /// `stat.frontend_question_id`).
    public let frontendID: Int
    /// The URL slug (`two-sum`), the key every detail request is made by.
    public let slug: String
    /// The display title (`Two Sum`).
    public let title: String
    public let difficulty: LeetCodeDifficulty
    /// Whether the problem is LeetCode Premium. Opening one is refused with
    /// `LeetCodeError.paidOnly` rather than writing a file seeded from a
    /// statement the account cannot read.
    public let isPaidOnly: Bool
    /// This account's progress; `.notStarted` when signed out or unreported.
    public let status: LeetCodeProblemStatus

    public init(
        frontendID: Int,
        slug: String,
        title: String,
        difficulty: LeetCodeDifficulty,
        isPaidOnly: Bool,
        status: LeetCodeProblemStatus = .notStarted
    ) {
        self.frontendID = frontendID
        self.slug = slug
        self.title = title
        self.difficulty = difficulty
        self.isPaidOnly = isPaidOnly
        self.status = status
    }
}

/// A problem plus everything the detail request adds: the statement, the starter
/// code for every language LeetCode offers it in, and the example test cases.
///
/// Composes `LeetCodeProblem` rather than restating its fields so the catalog and
/// the detail can never disagree about what a problem *is*; the handful of
/// members the open-problem flow reaches for are forwarded below.
public struct LeetCodeProblemDetail: Equatable, Sendable {
    /// The catalog-level facts.
    public let problem: LeetCodeProblem
    /// The statement as LeetCode's own HTML **fragment** — not a document. It is
    /// wrapped in the app's themed document by `LeetCodeStatementDocument` before
    /// any web view sees it, and cached verbatim so an offline reopen still shows
    /// the statement.
    public let content: String
    /// Starter code keyed by LeetCode's language slug (`swift`, `python3`,
    /// `golang`). A language absent here is one LeetCode does not offer for this
    /// problem, which the picker has to respect.
    public let codeSnippets: [String: String]
    /// The example inputs from the statement, one per element, in LeetCode's own
    /// order — the default input for LC-2's Run.
    public let exampleTestCases: [String]

    public init(
        problem: LeetCodeProblem,
        content: String,
        codeSnippets: [String: String],
        exampleTestCases: [String] = []
    ) {
        self.problem = problem
        self.content = content
        self.codeSnippets = codeSnippets
        self.exampleTestCases = exampleTestCases
    }

    public var frontendID: Int { problem.frontendID }
    public var slug: String { problem.slug }
    public var title: String { problem.title }
    public var difficulty: LeetCodeDifficulty { problem.difficulty }
    public var isPaidOnly: Bool { problem.isPaidOnly }

    /// The starter code for `langSlug`, or `nil` when LeetCode does not offer this
    /// problem in that language.
    public func snippet(forLanguageSlug langSlug: String) -> String? {
        codeSnippets[langSlug]
    }
}
