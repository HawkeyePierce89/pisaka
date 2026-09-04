import XCTest
@testable import PisakaCore

/// The one schema file, driven from what `gh` actually printed.
///
/// Two halves, and the second is the one that earns its keep:
///
/// - **Round-trips** parse the recorded fixtures in `Fixtures/github/`
///   (provenance and the verbatim/authored split in that directory's README), so
///   every shape assertion here is pinned against `gh version 2.99.0`'s real
///   output for this repository rather than against a remembered schema.
/// - **Refusals** drive every closed table off its edge and assert the *key path*
///   the error names. With a parser this strict the key path is the entire
///   diagnosis — it names the line of `GitHubAPI` to edit — and a parser that
///   quietly rounded an unknown conclusion to "passed" would sail through every
///   round-trip above while putting a green checkmark on a pull request nobody
///   has looked at.
///
/// Nothing here runs `gh`: the test target cannot link `Process`, which is the
/// point of the `GitHubCLITransport` seam.
final class GitHubAPITests: XCTestCase {

    // MARK: - Fixtures

    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // PisakaCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // <root>

    private static let fixtures = repositoryRoot
        .appendingPathComponent("Tests/PisakaCoreTests/Fixtures/github")

    private func fixture(_ name: String) throws -> String {
        let data = try Data(contentsOf: Self.fixtures.appendingPathComponent(name))
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    /// Run `body` and assert it threw `expected`, key path and all.
    private func assertSchemaError(
        _ expected: GitHubSchemaError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () throws -> Void
    ) {
        do {
            try body()
            XCTFail("expected \(expected), returned normally", file: file, line: line)
        } catch let error as GitHubSchemaError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("expected \(expected), threw \(error)", file: file, line: line)
        }
    }

    private func date(_ text: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return try XCTUnwrap(formatter.date(from: text))
    }

    // MARK: - `pr list`, round-trip

    func testListParsesTheRecordedRowAndItsFourCheckRuns() throws {
        let rows = try GitHubAPI.pullRequests(fromListJSON: try fixture("pr-list-merged.json"))

        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.number, 54)
        XCTAssertEqual(row.id, 54, "identity is the number")
        XCTAssertEqual(row.title, "GitHub pull requests part 1: gh CLI panel, create, checkout, indicator (macOS)")
        XCTAssertEqual(row.authorLogin, "HawkeyePierce89")
        XCTAssertEqual(row.headRefName, "github-pull-requests-part-1-gh-cli-macos")
        XCTAssertEqual(row.baseRefName, "master")
        XCTAssertFalse(row.isDraft)
        XCTAssertEqual(row.url, "https://github.com/HawkeyePierce89/pisaka/pull/54")
        XCTAssertEqual(row.state, "MERGED")
        XCTAssertEqual(row.summary, .success, "four completed successes")
    }

    /// The three fields a merge is decided from, read off the recorded row.
    ///
    /// `UNKNOWN`/`UNKNOWN` is not a gap in the capture: it is what GitHub answers
    /// for a pull request that has **already been merged**, and it is carried as a
    /// value rather than smoothed away — a closed row has no mergeability left to
    /// report, and the plan reading it will refuse rather than offer a button.
    func testTheRecordedRowCarriesTheThreeMergeFields() throws {
        let rows = try GitHubAPI.pullRequests(fromListJSON: try fixture("pr-list-merged.json"))
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.headRefOid, "999005649c31b9c493e8cefac074297a7d304b49")
        XCTAssertEqual(row.mergeable, .unknown)
        XCTAssertEqual(row.mergeStateStatus, .unknown)
    }

    /// `""` is the ordinary answer for a repository that requires no review, and
    /// it is a *value*, not an absence — the one place in the file where an empty
    /// string does not throw.
    func testEmptyReviewDecisionIsNoneRatherThanARefusal() throws {
        let rows = try GitHubAPI.pullRequests(fromListJSON: try fixture("pr-list-merged.json"))
        XCTAssertEqual(rows.first?.reviewDecision, GitHubReviewDecision.none)
    }

    func testAuthoredRowCarriesTheDraftFlagAndTheReviewDecision() throws {
        let rows = try GitHubAPI.pullRequests(fromListJSON: try fixture("pr-list-mixed-typename.json"))
        let row = try XCTUnwrap(rows.first)
        XCTAssertTrue(row.isDraft)
        XCTAssertEqual(row.reviewDecision, .approved)
    }

    /// A rollup carrying both `__typename`s is decided over both tables at once —
    /// and the unfinished `StatusContext` outranks the passed `CheckRun`.
    func testMixedTypenameRollupIsDecidedOverBothTables() throws {
        let rows = try GitHubAPI.pullRequests(fromListJSON: try fixture("pr-list-mixed-typename.json"))
        XCTAssertEqual(rows.first?.summary, .pending)
    }

    /// The ordinary answer to the `--head` lookup for a branch with no pull
    /// request, and to `--state open` in a repository with nothing open.
    func testEmptyArrayIsAnAnswerRatherThanAFailure() throws {
        XCTAssertEqual(try GitHubAPI.pullRequests(fromListJSON: try fixture("pr-list-empty.json")).count, 0)
    }

    /// GraphQL answers `null` for a commit with no rollup at all, which states the
    /// same fact `[]` does — and lands on `noChecks`, never on `success`.
    func testNullRollupIsNoChecks() throws {
        let rows = try GitHubAPI.pullRequests(fromListJSON: Self.listJSON(rollup: "null"))
        XCTAssertEqual(rows.first?.summary, .noChecks)
    }

    func testEmptyRollupIsNoChecks() throws {
        let rows = try GitHubAPI.pullRequests(fromListJSON: Self.listJSON(rollup: "[]"))
        XCTAssertEqual(rows.first?.summary, .noChecks)
    }

    // MARK: - `pr view`, round-trip

    /// The wait's one read, parsed by the *same* decoder the list uses.
    ///
    /// `pr-view.json` and `pr-list-merged.json` hold the same pull request, read
    /// two different ways, so this is the assertion that a row addressed by number
    /// and a row taken out of a list are the same value under the same tables —
    /// which is what "one schema, one set of tables" has to mean to be worth
    /// stating.
    func testTheViewParserReadsTheSameRowTheListParserDoes() throws {
        let listed = try XCTUnwrap(
            try GitHubAPI.pullRequests(fromListJSON: try fixture("pr-list-merged.json")).first
        )
        let viewed = try GitHubAPI.pullRequest(fromViewJSON: try fixture("pr-view.json"))
        XCTAssertEqual(viewed, listed)
    }

    func testTheViewParserReadsTheRecordedSingleObject() throws {
        let row = try GitHubAPI.pullRequest(fromViewJSON: try fixture("pr-view.json"))
        XCTAssertEqual(row.number, 54)
        XCTAssertEqual(row.headRefOid, "999005649c31b9c493e8cefac074297a7d304b49")
        XCTAssertEqual(row.summary, .success)
        XCTAssertEqual(row.state, "MERGED")
    }

    /// The key path names `pr view`, not `pr list[0]`: the string in the error is
    /// the command somebody has to re-run to see the shape for themselves.
    func testTheViewParserReportsAgainstItsOwnCommandRoot() {
        assertSchemaError(.missingKey(keyPath: "pr view.author")) {
            _ = try GitHubAPI.pullRequest(fromViewJSON: #"{"number":1,"title":"t"}"#)
        }
        assertSchemaError(.malformed(keyPath: "pr view")) {
            _ = try GitHubAPI.pullRequest(fromViewJSON: "no pull requests found for branch\n")
        }
    }

    /// An array is `pr list`'s shape, not this one's: `pr view <n>` answers with
    /// one object or fails, and a parser that unwrapped an array here would be a
    /// second reading of the same command.
    func testTheViewParserRefusesAnArray() {
        assertSchemaError(.malformed(keyPath: "pr view")) {
            _ = try GitHubAPI.pullRequest(fromViewJSON: "[]")
        }
    }

    // MARK: - `pr list`, refusals

    func testUnknownReviewDecisionNamesItsKeyPath() {
        assertSchemaError(.unknownValue(keyPath: "pr list[0].reviewDecision", value: "DISMISSED")) {
            _ = try GitHubAPI.pullRequests(fromListJSON: Self.listJSON(reviewDecision: #""DISMISSED""#))
        }
    }

    func testUnknownCheckRunStatusNamesItsKeyPath() {
        let rollup = #"[{"__typename":"CheckRun","status":"NAPPING","conclusion":""}]"#
        assertSchemaError(.unknownValue(keyPath: "pr list[0].statusCheckRollup[0].status", value: "NAPPING")) {
            _ = try GitHubAPI.pullRequests(fromListJSON: Self.listJSON(rollup: rollup))
        }
    }

    /// The violation fixture. Its whole job is to prove an unknown conclusion is
    /// loud rather than rounded to a checkmark.
    func testUnknownCheckRunConclusionNamesItsKeyPath() throws {
        let json = try fixture("pr-list-unknown-conclusion.json")
        assertSchemaError(.unknownValue(keyPath: "pr list[0].statusCheckRollup[0].conclusion", value: "TELEPORTED")) {
            _ = try GitHubAPI.pullRequests(fromListJSON: json)
        }
    }

    func testUnknownStatusContextStateNamesItsKeyPath() {
        let rollup = #"[{"__typename":"StatusContext","state":"SHRUGGING"}]"#
        assertSchemaError(.unknownValue(keyPath: "pr list[0].statusCheckRollup[0].state", value: "SHRUGGING")) {
            _ = try GitHubAPI.pullRequests(fromListJSON: Self.listJSON(rollup: rollup))
        }
    }

    /// A third `__typename` is a schema change, not a row to skip: skipping it
    /// would drop a check out of the summary and report the pull request greener
    /// than it is.
    func testUnknownTypenameNamesItsKeyPath() {
        let rollup = #"[{"__typename":"Prophecy","state":"SUCCESS"}]"#
        assertSchemaError(.unknownValue(keyPath: "pr list[0].statusCheckRollup[0].__typename", value: "Prophecy")) {
            _ = try GitHubAPI.pullRequests(fromListJSON: Self.listJSON(rollup: rollup))
        }
    }

    /// An unknown mergeability is loud rather than read as "probably fine": the
    /// optimistic reading is the one that offers a Merge button for a state nobody
    /// has looked at.
    func testUnknownMergeabilityNamesItsKeyPath() throws {
        let json = try fixture("pr-list-unknown-mergeable.json")
        assertSchemaError(.unknownValue(keyPath: "pr list[0].mergeable", value: "PERHAPS")) {
            _ = try GitHubAPI.pullRequests(fromListJSON: json)
        }
    }

    /// The fixture's value is `DRAFT` on purpose — a value GitHub's own enum still
    /// carries but no longer emits, deprecated in favour of `isDraft` rather than
    /// removed. The table has seven cases rather than eight because a draft
    /// answers `BLOCKED` and says it is a draft in `isDraft`, which is where the
    /// draft refusal is decided from.
    func testUnknownMergeStateStatusNamesItsKeyPath() throws {
        let json = try fixture("pr-list-unknown-merge-state.json")
        assertSchemaError(.unknownValue(keyPath: "pr list[0].mergeStateStatus", value: "DRAFT")) {
            _ = try GitHubAPI.pullRequests(fromListJSON: json)
        }
    }

    /// Every value of both tables, so the closed set is asserted rather than
    /// merely exercised on the two the fixtures happen to carry.
    func testBothMergeTablesReadEveryValueTheyName() throws {
        for value in GitHubMergeability.allCases {
            let json = Self.listJSON(mergeable: "\"\(value.rawValue)\"")
            XCTAssertEqual(try GitHubAPI.pullRequests(fromListJSON: json).first?.mergeable, value)
        }
        for value in GitHubMergeStateStatus.allCases {
            let json = Self.listJSON(mergeStateStatus: "\"\(value.rawValue)\"")
            XCTAssertEqual(try GitHubAPI.pullRequests(fromListJSON: json).first?.mergeStateStatus, value)
        }
    }

    func testAMissingHeadOidIsReportedByItsPath() {
        let json = #"""
        [{"number":1,"title":"t","author":{"login":"o"},"headRefName":"h","baseRefName":"b","isDraft":false,
        "reviewDecision":"","url":"u","state":"OPEN","statusCheckRollup":[],"mergeable":"MERGEABLE",
        "mergeStateStatus":"CLEAN"}]
        """#
        assertSchemaError(.missingKey(keyPath: "pr list[0].headRefOid")) {
            _ = try GitHubAPI.pullRequests(fromListJSON: json)
        }
    }

    func testAMissingKeyIsReportedByItsPath() {
        let json = #"[{"number":1,"title":"t"}]"#
        assertSchemaError(.missingKey(keyPath: "pr list[0].author")) {
            _ = try GitHubAPI.pullRequests(fromListJSON: json)
        }
    }

    /// The nested key path is the *whole* path, not the leaf: `author.login` is
    /// what somebody re-runs `gh` with `--jq` to see.
    func testANestedMissingKeyCarriesTheWholePath() {
        let json = #"[{"number":1,"title":"t","author":{"name":"nobody"}}]"#
        assertSchemaError(.missingKey(keyPath: "pr list[0].author.login")) {
            _ = try GitHubAPI.pullRequests(fromListJSON: json)
        }
    }

    func testAValueOfTheWrongKindIsMalformed() {
        assertSchemaError(.malformed(keyPath: "pr list[0].number")) {
            _ = try GitHubAPI.pullRequests(fromListJSON: Self.listJSON(number: #""53""#))
        }
    }

    /// Output that is not JSON at all — `gh` printing prose because a flag was
    /// rejected — is reported against the command's own root.
    func testNonJSONOutputIsMalformedAgainstTheCommandRoot() {
        assertSchemaError(.malformed(keyPath: "pr list")) {
            _ = try GitHubAPI.pullRequests(fromListJSON: "unknown flag: --json\n")
        }
    }

    func testAnObjectWhereTheListBelongsIsMalformed() {
        assertSchemaError(.malformed(keyPath: "pr list")) {
            _ = try GitHubAPI.pullRequests(fromListJSON: #"{"number":1}"#)
        }
    }

    func testARollupThatIsNotAnArrayIsMalformed() {
        assertSchemaError(.malformed(keyPath: "pr list[0].statusCheckRollup")) {
            _ = try GitHubAPI.pullRequests(fromListJSON: Self.listJSON(rollup: #""none""#))
        }
    }

    // MARK: - `pr checks`

    func testChecksParseTheRecordedNineFieldRows() throws {
        let rows = try GitHubAPI.checkRows(fromChecksJSON: try fixture("pr-checks.json"))

        XCTAssertEqual(rows.map(\.name), ["build-macos", "build-ios", "lint", "test"])
        XCTAssertEqual(rows.map(\.bucket), [.pass, .pass, .pass, .pass])
        XCTAssertEqual(Set(rows.map(\.workflow)), ["CI"])
        XCTAssertEqual(Set(rows.map(\.state)), ["SUCCESS"])
        XCTAssertEqual(Set(rows.map(\.description)), [""], "this integration publishes no description")

        let first = try XCTUnwrap(rows.first)
        XCTAssertEqual(
            first.link,
            "https://github.com/HawkeyePierce89/pisaka/actions/runs/33672316821/job/100389653079"
        )
        XCTAssertEqual(first.startedAt, try date("2026-09-02T19:19:39Z"))
        XCTAssertEqual(first.completedAt, try date("2026-09-02T19:24:51Z"))
    }

    /// Go's zero `time.Time`, which `gh` marshals verbatim for a job that has not
    /// finished. A sentinel, not a date in the year 1.
    func testTheZeroTimestampSentinelReadsAsNoTimestamp() throws {
        let json = """
        [{"bucket":"pending","completedAt":"0001-01-01T00:00:00Z","description":"","event":"pull_request",\
        "link":"","name":"test","startedAt":"2026-09-02T19:16:36Z","state":"IN_PROGRESS","workflow":"CI"}]
        """
        let rows = try GitHubAPI.checkRows(fromChecksJSON: json)
        XCTAssertNil(rows.first?.completedAt)
        XCTAssertEqual(rows.first?.startedAt, try date("2026-09-02T19:16:36Z"))
        XCTAssertEqual(rows.first?.bucket, .pending)
    }

    func testAnEmptyTimestampReadsAsNoTimestamp() throws {
        let json = """
        [{"bucket":"pending","completedAt":"","description":"","event":"pull_request",\
        "link":"","name":"test","startedAt":"","state":"QUEUED","workflow":"CI"}]
        """
        let rows = try GitHubAPI.checkRows(fromChecksJSON: json)
        XCTAssertNil(rows.first?.startedAt)
        XCTAssertNil(rows.first?.completedAt)
    }

    /// The second formatter, which is otherwise free to be deleted as dead: every
    /// other fixture and inline row here carries whole seconds.
    func testAFractionalSecondsTimestampParses() throws {
        let json = """
        [{"bucket":"pass","completedAt":"2026-09-02T19:19:39.123Z","description":"","event":"pull_request",\
        "link":"","name":"test","startedAt":"2026-09-02T19:16:36.007Z","state":"SUCCESS","workflow":"CI"}]
        """
        let rows = try GitHubAPI.checkRows(fromChecksJSON: json)
        let started = try XCTUnwrap(rows.first?.startedAt)
        let completed = try XCTUnwrap(rows.first?.completedAt)
        // Asserted against the whole-second instants either side, so the test
        // reads the fraction rather than merely surviving it.
        XCTAssertEqual(started.timeIntervalSince(try date("2026-09-02T19:16:36Z")), 0.007, accuracy: 0.001)
        XCTAssertEqual(completed.timeIntervalSince(try date("2026-09-02T19:19:39Z")), 0.123, accuracy: 0.001)
    }

    func testAnUnreadableTimestampIsMalformed() {
        let json = """
        [{"bucket":"pass","completedAt":"yesterday","description":"","event":"pull_request",\
        "link":"","name":"test","startedAt":"","state":"SUCCESS","workflow":"CI"}]
        """
        assertSchemaError(.malformed(keyPath: "pr checks[0].completedAt")) {
            _ = try GitHubAPI.checkRows(fromChecksJSON: json)
        }
    }

    func testUnknownBucketNamesItsKeyPath() {
        let json = """
        [{"bucket":"shrug","completedAt":"","description":"","event":"pull_request",\
        "link":"","name":"test","startedAt":"","state":"SUCCESS","workflow":"CI"}]
        """
        assertSchemaError(.unknownValue(keyPath: "pr checks[0].bucket", value: "shrug")) {
            _ = try GitHubAPI.checkRows(fromChecksJSON: json)
        }
    }

    /// A pull request with no checks answers `[]` from this command too, and that
    /// is not a failure — it is what an expanded row with nothing to show reads.
    func testChecksAcceptAnEmptyArray() throws {
        XCTAssertEqual(try GitHubAPI.checkRows(fromChecksJSON: "[]").count, 0)
    }

    // MARK: - `repo view`

    func testRepositoryViewParsesTheRecordedAnswer() throws {
        let repository = try GitHubAPI.repository(fromViewJSON: try fixture("repo-view.json"))
        XCTAssertEqual(repository.nameWithOwner, "HawkeyePierce89/pisaka")
        XCTAssertEqual(repository.defaultBranch, "master")
    }

    /// The merge policy half: which methods the sheet may offer, which one it
    /// starts on, and whether GitHub deletes the head branch by itself.
    func testRepositoryViewParsesTheRecordedMergePolicy() throws {
        let repository = try GitHubAPI.repository(fromViewJSON: try fixture("repo-view.json"))
        XCTAssertTrue(repository.mergeCommitAllowed)
        XCTAssertTrue(repository.squashMergeAllowed)
        XCTAssertTrue(repository.rebaseMergeAllowed)
        XCTAssertEqual(repository.viewerDefaultMergeMethod, .squash)
        XCTAssertFalse(repository.deleteBranchOnMerge)
    }

    func testEveryMergeMethodIsReadFromTheViewersDefault() throws {
        for method in GitHubMergeMethod.allCases {
            let json = Self.repositoryJSON(viewerDefaultMergeMethod: "\"\(method.rawValue)\"")
            XCTAssertEqual(try GitHubAPI.repository(fromViewJSON: json).viewerDefaultMergeMethod, method)
        }
    }

    func testAnUnknownDefaultMergeMethodNamesItsKeyPath() {
        assertSchemaError(.unknownValue(keyPath: "repo view.viewerDefaultMergeMethod", value: "CHERRY_PICK")) {
            _ = try GitHubAPI.repository(fromViewJSON: Self.repositoryJSON(
                viewerDefaultMergeMethod: #""CHERRY_PICK""#
            ))
        }
    }

    /// A missing policy flag is refused rather than read as `false`: "this
    /// repository disallows squashing" and "the field was not asked for" are
    /// different facts, and the second one silently empties the sheet's picker.
    func testAMissingMergePolicyFlagIsReportedByItsPath() {
        let json = #"{"defaultBranchRef":{"name":"main"},"nameWithOwner":"o/r"}"#
        assertSchemaError(.missingKey(keyPath: "repo view.mergeCommitAllowed")) {
            _ = try GitHubAPI.repository(fromViewJSON: json)
        }
    }

    /// A repository with no commits has no default branch ref. The create sheet's
    /// whole base default comes from this answer, so an empty base is refused
    /// rather than passed to `pr create` as if it were a branch.
    func testANullDefaultBranchRefIsRefusedByItsPath() {
        let json = #"{"defaultBranchRef":null,"nameWithOwner":"octocat/empty"}"#
        assertSchemaError(.missingKey(keyPath: "repo view.defaultBranchRef")) {
            _ = try GitHubAPI.repository(fromViewJSON: json)
        }
    }

    func testAMissingNameWithOwnerIsReportedByItsPath() {
        let json = #"{"defaultBranchRef":{"name":"main"}}"#
        assertSchemaError(.missingKey(keyPath: "repo view.nameWithOwner")) {
            _ = try GitHubAPI.repository(fromViewJSON: json)
        }
    }

    func testNonJSONRepositoryOutputIsMalformedAgainstTheCommandRoot() {
        assertSchemaError(.malformed(keyPath: "repo view")) {
            _ = try GitHubAPI.repository(fromViewJSON: "not a repository\n")
        }
    }

    // MARK: - `pr create`

    func testTheCreatedNumberIsReadOutOfThePrintedURL() {
        let output = "https://github.com/HawkeyePierce89/pisaka/pull/54\n"
        XCTAssertEqual(GitHubAPI.pullRequestNumber(fromCreateOutput: output), 54)
    }

    /// `gh pr create` prefaces the URL with prose naming the two branches; the URL
    /// is the last thing it prints.
    func testTheNumberIsFoundPastThePrecedingProse() {
        let output = """
        Warning: 1 uncommitted change

        Creating pull request for feature/x into master in HawkeyePierce89/pisaka

        https://github.com/HawkeyePierce89/pisaka/pull/107
        """
        XCTAssertEqual(GitHubAPI.pullRequestNumber(fromCreateOutput: output), 107)
    }

    /// The rule the doc comment states: the **last** `/pull/<n>` wins.
    ///
    /// `gh pr create` prints an existing pull request's URL before the new one
    /// when it has something to say about a fork or an already-open request, so
    /// first-wins would pre-select somebody else's row.
    func testTheLastPullURLWinsWhenTheOutputNamesTwo() {
        let output = """
        Warning: a pull request for branch "feature" into branch "master" already exists:
        https://github.com/HawkeyePierce89/pisaka/pull/12

        https://github.com/HawkeyePierce89/pisaka/pull/107
        """
        XCTAssertEqual(GitHubAPI.pullRequestNumber(fromCreateOutput: output), 107)
    }

    /// Two on one line, which is the case a line-by-line scan can get wrong on
    /// its own.
    func testTheLastPullURLWinsWithinASingleLine() {
        let output = "see https://github.com/o/r/pull/12 — opened https://github.com/o/r/pull/13\n"
        XCTAssertEqual(GitHubAPI.pullRequestNumber(fromCreateOutput: output), 13)
    }

    func testAnUnreadableCreateAnswerIsNilRatherThanAFailure() {
        XCTAssertNil(GitHubAPI.pullRequestNumber(fromCreateOutput: "https://github.com/o/r/pull/\n"))
        XCTAssertNil(GitHubAPI.pullRequestNumber(fromCreateOutput: ""))
        XCTAssertNil(GitHubAPI.pullRequestNumber(fromCreateOutput: "https://github.com/o/r/issues/9\n"))
    }

    // MARK: - The sentences

    func testEverySchemaErrorNamesItsKeyPathInItsSentence() {
        let errors: [GitHubSchemaError] = [
            .missingKey(keyPath: "pr list[0].author.login"),
            .malformed(keyPath: "pr checks[2].completedAt"),
            .unknownValue(keyPath: "pr list[0].reviewDecision", value: "DISMISSED"),
        ]
        for error in errors {
            let sentence = error.errorDescription ?? ""
            XCTAssertTrue(sentence.contains(error.keyPath), "“\(sentence)” does not name \(error.keyPath)")
        }
        XCTAssertEqual(
            GitHubSchemaError.unknownValue(keyPath: "pr checks[0].bucket", value: "shrug").errorDescription,
            "The GitHub CLI answered “pr checks[0].bucket” with “shrug”, which Pisaka does not know."
        )
    }

    // MARK: - Composing a list row

    /// One `pr list` row with every required key present, so a test can bend
    /// exactly one of them.
    private static func listJSON(
        number: String = "1",
        reviewDecision: String = "\"\"",
        rollup: String = "[]",
        mergeable: String = #""MERGEABLE""#,
        mergeStateStatus: String = #""CLEAN""#
    ) -> String {
        """
        [{"number":\(number),"title":"t","author":{"login":"octocat"},"headRefName":"h","baseRefName":"b",\
        "isDraft":false,"reviewDecision":\(reviewDecision),"url":"https://example.com/pull/1","state":"OPEN",\
        "statusCheckRollup":\(rollup),"headRefOid":"abc123","mergeable":\(mergeable),\
        "mergeStateStatus":\(mergeStateStatus)}]
        """
    }

    /// One `repo view` answer with every required key present, so a test can bend
    /// exactly one of them.
    private static func repositoryJSON(viewerDefaultMergeMethod: String = #""SQUASH""#) -> String {
        """
        {"defaultBranchRef":{"name":"main"},"nameWithOwner":"octocat/example","mergeCommitAllowed":true,\
        "squashMergeAllowed":true,"rebaseMergeAllowed":false,\
        "viewerDefaultMergeMethod":\(viewerDefaultMergeMethod),"deleteBranchOnMerge":true}
        """
    }
}
