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
        XCTAssertEqual(row.number, 53)
        XCTAssertEqual(row.id, 53, "identity is the number")
        XCTAssertEqual(row.title, "Database viewer part 2b: SQL console (macOS)")
        XCTAssertEqual(row.authorLogin, "HawkeyePierce89")
        XCTAssertEqual(row.headRefName, "database-viewer-part-2b-sql-console")
        XCTAssertEqual(row.baseRefName, "master")
        XCTAssertFalse(row.isDraft)
        XCTAssertEqual(row.url, "https://github.com/HawkeyePierce89/pisaka/pull/53")
        XCTAssertEqual(row.state, "MERGED")
        XCTAssertEqual(row.summary, .success, "four completed successes")
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
        rollup: String = "[]"
    ) -> String {
        """
        [{"number":\(number),"title":"t","author":{"login":"octocat"},"headRefName":"h","baseRefName":"b",\
        "isDraft":false,"reviewDecision":\(reviewDecision),"url":"https://example.com/pull/1","state":"OPEN",\
        "statusCheckRollup":\(rollup)}]
        """
    }
}
