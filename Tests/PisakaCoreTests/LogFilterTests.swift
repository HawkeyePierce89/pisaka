import XCTest
@testable import PisakaCore

final class LogFilterTests: XCTestCase {

    // MARK: - gitArguments: ref selection

    func testDefaultFilterSpansAllRefs() {
        XCTAssertEqual(LogFilter().gitArguments(), ["--all"])
    }

    func testNamedRefBecomesPositionalRevision() {
        let filter = LogFilter(refSelection: .ref("feature/foo"))
        // Protected by `--end-of-options` so a ref is never parsed as an option.
        XCTAssertEqual(filter.gitArguments(), ["--end-of-options", "feature/foo"])
    }

    func testBlankRefFallsBackToAll() {
        // A blank ref name would silently default git to HEAD; treat it as "all".
        XCTAssertEqual(LogFilter(refSelection: .ref("   ")).gitArguments(), ["--all"])
    }

    func testOptionLikeRefIsGuardedByEndOfOptions() {
        // `git check-ref-format` accepts a ref like `--max-count=0`; passed bare it
        // would override the command, so it must be emitted behind
        // `--end-of-options` (after any option filters) as a positional revision.
        let filter = LogFilter(refSelection: .ref("--max-count=0"), author: "Bob")
        XCTAssertEqual(filter.gitArguments(), [
            "--author=Bob",
            "--end-of-options", "--max-count=0"
        ])
    }

    // MARK: - gitArguments: author

    func testAuthorAppendsAuthorArgument() {
        let filter = LogFilter(author: "Alice")
        XCTAssertEqual(filter.gitArguments(), ["--all", "--author=Alice"])
    }

    func testBlankAuthorContributesNothing() {
        XCTAssertEqual(LogFilter(author: "   ").gitArguments(), ["--all"])
        XCTAssertEqual(LogFilter(author: "").gitArguments(), ["--all"])
    }

    func testAuthorWithSpacesSurvivesIntactAsSingleArgument() {
        let filter = LogFilter(author: "Ada Lovelace")
        XCTAssertEqual(filter.gitArguments(), ["--all", "--author=Ada Lovelace"])
    }

    // MARK: - gitArguments: date range

    func testSinceAndUntilFormatAsUTCISO8601() {
        let since = Date(timeIntervalSince1970: 0)
        let until = Date(timeIntervalSince1970: 1_000_000)
        let filter = LogFilter(since: since, until: until)
        XCTAssertEqual(filter.gitArguments(), [
            "--all",
            "--since=1970-01-01T00:00:00Z",
            "--until=1970-01-12T13:46:40Z"
        ])
    }

    func testOnlySinceOmitsUntil() {
        let filter = LogFilter(since: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(filter.gitArguments(), ["--all", "--since=1970-01-01T00:00:00Z"])
    }

    // MARK: - gitArguments: path

    func testPathAppendsPathspecBehindSeparator() {
        let filter = LogFilter(path: "Sources/foo.swift")
        XCTAssertEqual(filter.gitArguments(), ["--all", "--", "Sources/foo.swift"])
    }

    func testBlankPathContributesNothing() {
        XCTAssertEqual(LogFilter(path: "  ").gitArguments(), ["--all"])
    }

    // MARK: - gitArguments: combinations

    func testCombinedFilterOrdersRefOptionsThenPathspec() {
        let filter = LogFilter(
            refSelection: .ref("main"),
            author: "Bob",
            since: Date(timeIntervalSince1970: 0),
            until: Date(timeIntervalSince1970: 0),
            path: "src"
        )
        XCTAssertEqual(filter.gitArguments(), [
            "--author=Bob",
            "--since=1970-01-01T00:00:00Z",
            "--until=1970-01-01T00:00:00Z",
            "--end-of-options", "main",
            "--", "src"
        ])
    }

    func testPathspecAlwaysLastEvenWithAllRefs() {
        let filter = LogFilter(author: "Bob", path: "src")
        XCTAssertEqual(filter.gitArguments(), ["--all", "--author=Bob", "--", "src"])
    }

    // MARK: - graph contiguity

    func testRefOnlyFiltersKeepHistoryContiguous() {
        // Ref selection walks a connected ancestry; a path pathspec is parent-
        // rewritten by `--parents` — neither can strand a parent, so the graph
        // stays drawable.
        XCTAssertFalse(LogFilter().mayProduceNonContiguousHistory)
        XCTAssertFalse(LogFilter(refSelection: .ref("main")).mayProduceNonContiguousHistory)
        XCTAssertFalse(LogFilter(path: "Sources").mayProduceNonContiguousHistory)
        XCTAssertFalse(LogFilter(author: "   ").mayProduceNonContiguousHistory)
    }

    func testCommitLimitingFiltersMayBreakContiguity() {
        // author / since / until omit non-matching commits *without* rewriting
        // parents, so a shown commit can point at an excluded parent.
        XCTAssertTrue(LogFilter(author: "Alice").mayProduceNonContiguousHistory)
        XCTAssertTrue(LogFilter(since: Date(timeIntervalSince1970: 0)).mayProduceNonContiguousHistory)
        XCTAssertTrue(LogFilter(until: Date(timeIntervalSince1970: 0)).mayProduceNonContiguousHistory)
        XCTAssertTrue(
            LogFilter(refSelection: .ref("main"), author: "Bob", path: "src")
                .mayProduceNonContiguousHistory
        )
    }

    // MARK: - client-side message search

    private func commit(_ hash: String, subject: String) -> Commit {
        Commit(hash: hash, parents: [], author: "A", date: "d", subject: subject, refs: [])
    }

    func testSearchEmptyQueryReturnsEverything() {
        let commits = [commit("a", subject: "Fix bug"), commit("b", subject: "Add feature")]
        XCTAssertEqual(LogFilter.search(commits, query: "").map(\.hash), ["a", "b"])
        XCTAssertEqual(LogFilter.search(commits, query: "   ").map(\.hash), ["a", "b"])
    }

    func testSearchMatchesSubjectCaseInsensitively() {
        let commits = [
            commit("a", subject: "Fix the parser BUG"),
            commit("b", subject: "Add a feature"),
            commit("c", subject: "another bugfix")
        ]
        XCTAssertEqual(LogFilter.search(commits, query: "bug").map(\.hash), ["a", "c"])
        XCTAssertEqual(LogFilter.search(commits, query: "FEATURE").map(\.hash), ["b"])
    }

    func testSearchNoMatchReturnsEmpty() {
        let commits = [commit("a", subject: "Fix bug"), commit("b", subject: "Add feature")]
        XCTAssertEqual(LogFilter.search(commits, query: "nonexistent"), [])
    }

    func testSearchTrimsQueryWhitespace() {
        let commits = [commit("a", subject: "Fix bug"), commit("b", subject: "Add feature")]
        XCTAssertEqual(LogFilter.search(commits, query: "  feature  ").map(\.hash), ["b"])
    }

    // MARK: - Equatable

    func testFiltersDifferingByDimensionAreUnequal() {
        XCTAssertNotEqual(LogFilter(), LogFilter(refSelection: .ref("main")))
        XCTAssertNotEqual(LogFilter(), LogFilter(author: "A"))
        XCTAssertNotEqual(LogFilter(), LogFilter(since: Date(timeIntervalSince1970: 0)))
        XCTAssertNotEqual(LogFilter(), LogFilter(path: "x"))
        XCTAssertEqual(LogFilter(author: "A"), LogFilter(author: "A"))
    }

    // MARK: - resolvedRef(amongKnown:)

    func testResolvedRefAllIsNil() {
        XCTAssertNil(LogFilter().resolvedRef(amongKnown: ["refs/heads/main"]))
    }

    func testResolvedRefKnownNamedRefResolvesToItself() {
        let filter = LogFilter(refSelection: .ref("refs/heads/main"))
        XCTAssertEqual(
            filter.resolvedRef(amongKnown: ["refs/heads/main", "refs/heads/dev"]),
            "refs/heads/main"
        )
    }

    func testResolvedRefUnknownNamedRefDegradesToAll() {
        // A stale/dangling ref the current repo no longer has degrades to "all".
        let filter = LogFilter(refSelection: .ref("refs/heads/gone"))
        XCTAssertNil(filter.resolvedRef(amongKnown: ["refs/heads/main"]))
    }

    func testResolvedRefEmptyReferencesIsNil() {
        let filter = LogFilter(refSelection: .ref("refs/heads/main"))
        XCTAssertNil(filter.resolvedRef(amongKnown: []))
    }
}
