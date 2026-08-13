import Foundation

/// The typed vocabulary of a judge run: what was asked for, what came back, and
/// how far along it is.
///
/// Everything here is a Foundation-only value type with no behaviour beyond
/// naming itself. The *wire* half — which URL, which payload keys, which numeric
/// `status_code` means which verdict — stays in `LeetCodeAPI`, the one schema
/// file, exactly as it does for the catalog and the statement. These types are
/// what that file parses *into*, so the flow model and the two views can speak
/// about a verdict without ever having seen a JSON key.

// MARK: - Which judge

/// Run against the visible examples, or submit against LeetCode's full suite.
///
/// It travels with every judge call rather than being inferred, because it
/// decides three separate things — which URL is posted to, whether the payload
/// carries `data_input`, and which of the two entirely different finished shapes
/// the check response is parsed into. LeetCode answers both from the *same*
/// `submissions/detail/<id>/check/` endpoint with overlapping-but-different key
/// sets, so a check parsed under the wrong kind reads plausible and is wrong.
public enum LeetCodeJudgeKind: String, CaseIterable, Sendable {
    /// `interpret_solution` — the example test cases, editable by the user.
    case run
    /// `submit` — LeetCode's own full test suite, and the thing that marks a
    /// problem solved on the account.
    case submit
}

// MARK: - What the judge has to know about a problem

/// The two facts a judge call needs about a problem, beside the code itself.
///
/// It exists because **neither of the two things this app already keeps about a
/// problem holds them**: a solution file's name carries the frontend number and
/// the slug, and the statement disk cache carries the HTML fragment and nothing
/// else. The judge payloads are addressed by LeetCode's *internal* id, and Run
/// prefills its box from the examples, so a judge surface that had only a file
/// name in hand would have to re-fetch the detail every single time it appeared.
///
/// Modelled as its own value rather than by keeping whole
/// `LeetCodeProblemDetail`s around: the detail carries the statement and every
/// language's starter code, which is the large half of that response and exactly
/// the half the judge never reads. The statement is cached on disk already; this
/// is the small remainder, memoised in memory for the run (see
/// `LeetCodeModel.judgeContext(forSlug:)`), and the disk cache format is
/// deliberately untouched by it.
public struct LeetCodeJudgeContext: Equatable, Sendable {
    /// The problem, as every LeetCode URL spells it.
    public let slug: String
    /// LeetCode's internal `questionId` — what `question_id` in the run and
    /// submit payloads must be, and never the number in the file name. See
    /// ``LeetCodeProblemDetail/questionID``.
    public let questionID: String
    /// The statement's own examples, one per element, in LeetCode's order —
    /// what Run's editable input box is prefilled from.
    public let exampleTestCases: [String]

    public init(slug: String, questionID: String, exampleTestCases: [String]) {
        self.slug = slug
        self.questionID = questionID
        self.exampleTestCases = exampleTestCases
    }

    /// The projection of a detail response onto what the judge uses.
    public init(detail: LeetCodeProblemDetail) {
        self.init(
            slug: detail.slug,
            questionID: detail.questionID,
            exampleTestCases: detail.exampleTestCases
        )
    }
}

// MARK: - The verdict

/// LeetCode's numeric `status_code`, as the nine outcomes it actually spells.
///
/// The raw values *are* the wire codes: they are what the check response carries
/// and the only machine-readable statement of the outcome LeetCode makes
/// (`status_msg` is a display string that has been re-worded before). Modelling
/// them as the raw value keeps the mapping one line rather than a switch that
/// can drift from the table it mirrors.
///
/// **There is deliberately no `unknown` case and no `default`.** An unrecognised
/// code is `LeetCodeError.apiChanged(detail: "status_code = 7")`, for this
/// area's usual reason: a tenth outcome silently rendered as "Unknown Error"
/// would be indistinguishable from LeetCode's *own* code 21, and the user would
/// be told the wrong thing about their submission forever.
public enum LeetCodeVerdict: Int, CaseIterable, Sendable {
    case accepted = 10
    case wrongAnswer = 11
    case memoryLimitExceeded = 12
    case outputLimitExceeded = 13
    case timeLimitExceeded = 14
    case runtimeError = 15
    /// The judge itself broke — not the submitted code.
    case internalError = 16
    case compileError = 20
    /// LeetCode's own catch-all, which is *not* the same thing as a code this
    /// app does not know: this one it sent on purpose.
    case unknownError = 21

    /// What the result header reads, spelled the way LeetCode spells it so a
    /// user comparing against the site sees the same words.
    public var displayName: String {
        switch self {
        case .accepted: return "Accepted"
        case .wrongAnswer: return "Wrong Answer"
        case .memoryLimitExceeded: return "Memory Limit Exceeded"
        case .outputLimitExceeded: return "Output Limit Exceeded"
        case .timeLimitExceeded: return "Time Limit Exceeded"
        case .runtimeError: return "Runtime Error"
        case .internalError: return "Internal Error"
        case .compileError: return "Compile Error"
        case .unknownError: return "Unknown Error"
        }
    }

    /// Whether this is the one outcome that means the suite passed.
    ///
    /// On a **submit** that is the whole answer. On a **run** it is not: code 10
    /// there means "your code executed on the examples", and whether the output
    /// matched is `LeetCodeRunResult.matchedExpected` — which is why that
    /// property exists and why this one is not consulted for a run's headline.
    public var isAccepted: Bool { self == .accepted }
}

// MARK: - How far along

/// The `state` a check response reports, which is what the poll loop reads.
///
/// `failure` is a small, deliberate extension beyond the three states the happy
/// path walks through: LeetCode does answer `FAILURE` when its own judge gives
/// up on a submission. Mapping that to a stated "the judge did not finish" beats
/// reporting a state LeetCode documents by sending it as a schema change — the
/// user can retry, and nobody is sent hunting a parser bug. Anything *else* is
/// still `apiChanged`.
public enum LeetCodeJudgeState: String, CaseIterable, Sendable {
    case pending = "PENDING"
    case started = "STARTED"
    case success = "SUCCESS"
    case failure = "FAILURE"
}

// MARK: - Finished shapes

/// What a finished **run** answered.
///
/// Optionals are absences, never substituted zeros: LeetCode omits the runtime
/// on a compile error and omits the answers when nothing executed, and a `0 ms`
/// invented to fill the gap would read as a measurement.
public struct LeetCodeRunResult: Equatable, Sendable {
    /// The numeric outcome. On a run this says whether the code *ran*; see
    /// ``matchedExpected`` for whether it was right.
    public let verdict: LeetCodeVerdict
    /// LeetCode's `correct_answer` — whether every example's output matched the
    /// expected one. `nil` when nothing executed (a compile error), which is a
    /// different statement from `false`.
    public let matchedExpected: Bool?
    /// The inputs the judge says it ran, one per case, when it echoed them back.
    /// Empty when it did not — the flow model already knows what it submitted.
    public let inputs: [String]
    /// The submitted code's output, one entry per example.
    public let answers: [String]
    /// LeetCode's own reference output for the same examples.
    public let expectedAnswers: [String]
    /// Whatever the code printed, one entry per example.
    public let stdOutputs: [String]
    /// The runtime as LeetCode displays it (`"12 ms"`), not a number: it is a
    /// display string on the wire and nothing here computes with it.
    public let runtime: String?
    /// The memory figure as displayed (`"14.4 MB"`).
    public let memory: String?
    /// The compile or runtime error, in the fullest form LeetCode sent. Shown
    /// verbatim and in full — a truncated compiler diagnostic is the reason a
    /// user goes back to the browser.
    public let errorText: String?

    public init(
        verdict: LeetCodeVerdict,
        matchedExpected: Bool? = nil,
        inputs: [String] = [],
        answers: [String] = [],
        expectedAnswers: [String] = [],
        stdOutputs: [String] = [],
        runtime: String? = nil,
        memory: String? = nil,
        errorText: String? = nil
    ) {
        self.verdict = verdict
        self.matchedExpected = matchedExpected
        self.inputs = inputs
        self.answers = answers
        self.expectedAnswers = expectedAnswers
        self.stdOutputs = stdOutputs
        self.runtime = runtime
        self.memory = memory
        self.errorText = errorText
    }
}

/// What a finished **submit** answered.
///
/// The percentiles are optional because LeetCode simply omits them on anything
/// that is not Accepted — there is no percentile for a submission that failed —
/// and `totalCorrect`/`totalTestcases` are optional because a compile error
/// never reached a test case at all.
public struct LeetCodeSubmitResult: Equatable, Sendable {
    public let verdict: LeetCodeVerdict
    /// `"12 ms"`, as displayed.
    public let runtime: String?
    /// "Faster than N% of submissions", when LeetCode said so.
    public let runtimePercentile: Double?
    /// `"14.4 MB"`, as displayed.
    public let memory: String?
    public let memoryPercentile: Double?
    /// How many of LeetCode's cases passed, and out of how many.
    public let totalCorrect: Int?
    public let totalTestcases: Int?
    /// The input of the first case that failed — the single most useful thing on
    /// a Wrong Answer, and absent on an Accepted one.
    public let lastTestcaseInput: String?
    /// What the submitted code produced for that case.
    public let codeOutput: String?
    /// What LeetCode expected for it.
    public let expectedOutput: String?
    /// Whatever the code printed while failing it.
    public let stdOutput: String?
    /// The compile or runtime error, in the fullest form LeetCode sent.
    public let errorText: String?

    public init(
        verdict: LeetCodeVerdict,
        runtime: String? = nil,
        runtimePercentile: Double? = nil,
        memory: String? = nil,
        memoryPercentile: Double? = nil,
        totalCorrect: Int? = nil,
        totalTestcases: Int? = nil,
        lastTestcaseInput: String? = nil,
        codeOutput: String? = nil,
        expectedOutput: String? = nil,
        stdOutput: String? = nil,
        errorText: String? = nil
    ) {
        self.verdict = verdict
        self.runtime = runtime
        self.runtimePercentile = runtimePercentile
        self.memory = memory
        self.memoryPercentile = memoryPercentile
        self.totalCorrect = totalCorrect
        self.totalTestcases = totalTestcases
        self.lastTestcaseInput = lastTestcaseInput
        self.codeOutput = codeOutput
        self.expectedOutput = expectedOutput
        self.stdOutput = stdOutput
        self.errorText = errorText
    }
}

/// One answer from `submissions/detail/<id>/check/`.
///
/// The poll loop's whole control flow is a switch over this: the first two cases
/// mean "ask again", the last three are terminal. Modelling "not finished yet"
/// as a *case* rather than as a nil result is what makes it impossible to
/// publish a half-built verdict — there is no result to publish until the check
/// says there is.
public enum LeetCodeJudgeCheck: Equatable, Sendable {
    /// Queued; the judge has not picked it up.
    case pending
    /// Running.
    case started
    case finishedRun(LeetCodeRunResult)
    case finishedSubmit(LeetCodeSubmitResult)
    /// LeetCode's own judge gave up (`state: "FAILURE"`). Terminal, and not a
    /// verdict on the submitted code.
    case judgeFailed

    /// Whether the poll loop is done asking.
    public var isTerminal: Bool {
        switch self {
        case .pending, .started: return false
        case .finishedRun, .finishedSubmit, .judgeFailed: return true
        }
    }
}
