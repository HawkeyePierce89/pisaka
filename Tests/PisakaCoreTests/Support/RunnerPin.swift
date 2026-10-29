import Foundation

/// The runner image CI and the release workflow run on, read out of the
/// workflows themselves.
///
/// **The workflows are the one authority.** Every job in
/// `.github/workflows/ci.yml` and `.github/workflows/release.yml` states a
/// `runs-on:` directly under its header, and the set of those values must have
/// exactly one member, equal to `label` — changing that constant is the
/// deliberate act, and changing only the YAML fails `swift test`. A partial move
/// (some jobs on the new image, one left behind) is two members; a job with no
/// `runs-on:` or with two is reported rather than collapsed.
///
/// **The label must be an explicit versioned image** (`^macos-[0-9]+$`). A
/// moving alias such as `macos-latest` would agree with itself in every job
/// while GitHub moved the OS under it without a commit — and SwiftUI ships with
/// the OS, so that move changes what the app-layer gates draw. The same pattern
/// refuses the `-intel` / `-large` variants, a matrix expression and list
/// syntax.
///
/// Nothing else states the label on its own authority; every other spelling of
/// it is a reader checked against this value:
///
/// - `ReleaseWorkflowTests.testTheReleaseJobIsGatedOnTheTestJob`'s `test:` job
///   in `release.yml`, whose `runs-on:` values must be exactly the pinned one.
/// - `LintConfigurationTests.testCIDeclaresALintJobIndependentOfTheBuildGraph`'s
///   lint job, whose `runs-on:` values must be exactly the pinned one.
/// - `docs/RELEASING.md`'s anchored ``Pinned runner: `X` `` phrase, which must
///   occur exactly once (`ReleaseWorkflowTests.testReleasingDocNamesTheRunnerPin`).
///
/// The two workflow readers compare values through `labelValue(of:)`, never a
/// spelled line, so a quoted label or a trailing comment the rule accepts cannot
/// fail them.
///
/// Two prose sites also spell the image and are deliberately **not** readers:
/// they record what one move reached and what its first release must show, not
/// which image is pinned, so no rule holds them equal to this value and a move
/// owes each a hand revisit — the rest of `docs/RELEASING.md`'s runner
/// paragraph (the OS the move reached and the older ones it left ungated) and
/// its owed-verification entry for the first release on the image.
///
/// `ReleaseWorkflowTests.testEveryWorkflowJobRunsOnThePinnedRunner` holds the
/// workflows themselves to it: the set of jobs by set equality, one `runs-on:`
/// each, no stray line, the set of values equal to `[label]`, and
/// `pinnedLabel()` succeeding; `testRunnerPinRefusesWhatItExistsToRefuse` holds
/// the reading and the refusal to inline workflows the real ones never show.
///
/// The workflows are read through `#filePath` with Foundation only, through the
/// shared `workflowJobs(in:)` / `workflowJobKeyLines(_:in:)` reading — so a
/// commented-out `runs-on:` cannot count, and a job's own keys are told from
/// nested ones by the indentation that states them.
enum RunnerPin {
    /// The pinned runner image. Moving every job to another image starts here.
    static let label = "macos-26"

    /// The two workflows whose jobs run on it, by file name under
    /// `.github/workflows/`.
    static let workflows = ["ci.yml", "release.yml"]

    /// One job: where it sits and every `runs-on:` written directly under its
    /// header (exactly one, when the workflow is well-formed — kept as a list so
    /// a job with none or two is reportable rather than silently collapsed).
    struct Job: CustomStringConvertible {
        let workflow: String
        let job: String
        let labels: [String]

        var description: String {
            "\(workflow) job `\(job)`: runs-on \(labels.isEmpty ? "absent" : labels.joined(separator: ", "))"
        }
    }

    /// Why `pinnedLabel()` found no single, versioned, pinned value, naming every
    /// job.
    struct Disagreement: Error, CustomStringConvertible {
        let jobs: [Job]

        var description: String {
            """
            Every job in \(RunnerPin.workflows.joined(separator: " and ")) must run on one runner, \
            `\(RunnerPin.label)` (RunnerPin.label), and carry exactly one `runs-on:`. The label must \
            be an explicit versioned image (`macos-<N>`), never `macos-latest` or an -intel / -large \
            variant, so GitHub cannot change the OS under the pin without a commit. Found: \
            \(jobs.isEmpty ? "no job at all" : jobs.map(\.description).joined(separator: "; ")). \
            Set every one to the same label.
            """
        }
    }

    /// Every job across both workflows, in file order.
    static func jobs() throws -> [Job] {
        try workflows.flatMap { try jobs(in: text(of: $0), workflow: $0) }
    }

    /// Every active `runs-on:` line across both workflows, wherever it sits —
    /// the count that must equal the number of jobs, so a stray one outside any
    /// job's header level is visible.
    static func runsOnLineCount() throws -> Int {
        try workflows.reduce(0) { count, workflow in
            count + activeYAMLLines(of: try text(of: workflow)).filter { $0.hasPrefix("runs-on:") }.count
        }
    }

    /// The single pinned label, or a `Disagreement` naming every job when a job
    /// carries none or two, the jobs carry more than one value, the one value is
    /// not an explicit versioned image, or it is not `label`.
    static func pinnedLabel() throws -> String {
        try pinnedLabel(of: jobs())
    }

    /// `pinnedLabel()`'s decision over a given set of jobs.
    static func pinnedLabel(of all: [Job]) throws -> String {
        let values = Set(all.flatMap(\.labels))
        guard !all.isEmpty, all.allSatisfy({ $0.labels.count == 1 }), values.count == 1, let only = values.first,
              only.range(of: #"^macos-[0-9]+$"#, options: .regularExpression) != nil, only == label else {
            throw Disagreement(jobs: all)
        }
        return only
    }

    // MARK: - Parsing

    /// Every job of one workflow, through the shared `workflowJobs(in:)` /
    /// `workflowJobKeyLines(_:in:)` reading.
    static func jobs(in text: String, workflow: String) -> [Job] {
        workflowJobs(in: text).map { job in
            Job(workflow: workflow, job: job, labels: workflowJobKeyLines(job, in: text).compactMap(labelValue(of:)))
        }
    }

    /// `macos-26` out of `runs-on: macos-26` (either quote, or none, with any
    /// trailing comment dropped); `nil` for any other line.
    static func labelValue(of trimmedLine: String) -> String? {
        guard trimmedLine.hasPrefix("runs-on:") else { return nil }
        var value = trimmedLine.dropFirst("runs-on:".count)
        if let comment = value.range(of: " #") { value = value[..<comment.lowerBound] }
        return value.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
    }

    // MARK: - Reading the repository

    private static func text(of workflow: String) throws -> String {
        try String(contentsOf: XcodePin.repositoryRoot.appendingPathComponent(".github/workflows/\(workflow)"),
                   encoding: .utf8)
    }
}
