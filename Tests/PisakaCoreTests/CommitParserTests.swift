import XCTest
@testable import PisakaCore

final class CommitParserTests: XCTestCase {
    /// Build one record in the service's wire format:
    /// `%H%x00%P%x00%an%x00%aI%x00%s%x00%D%x1e`.
    private func record(
        hash: String,
        parents: String,
        author: String,
        date: String,
        subject: String,
        refs: String
    ) -> String {
        [hash, parents, author, date, subject, refs].joined(separator: "\u{0}") + "\u{1e}"
    }

    /// Pin the wire format: the hand-built `record(...)` helper above and the real
    /// `git log` invocation in `GitCLIService` both depend on this exact string, so a
    /// silent edit (reordering/adding a field) would leave every other parser test
    /// green while the service's output stopped matching. This change-detector makes
    /// such drift a test failure.
    func testPrettyFormatContract() {
        XCTAssertEqual(Commit.prettyFormat, "%H%x00%P%x00%an%x00%aI%x00%s%x00%D%x1e")
    }

    func testEmptyOutputIsNoCommits() {
        XCTAssertEqual(Commit.parse(""), [])
        XCTAssertEqual(Commit.parse("   \n  "), [])
    }

    func testOrdinaryCommit() {
        let output = record(
            hash: "aaa111",
            parents: "bbb222",
            author: "Ada Lovelace",
            date: "2026-06-25T10:00:00+00:00",
            subject: "Fix the thing",
            refs: ""
        )
        XCTAssertEqual(
            Commit.parse(output),
            [Commit(
                hash: "aaa111",
                parents: ["bbb222"],
                author: "Ada Lovelace",
                date: "2026-06-25T10:00:00+00:00",
                subject: "Fix the thing",
                refs: []
            )]
        )
    }

    func testMergeCommitHasMultipleParents() {
        let output = record(
            hash: "merge1",
            parents: "p1 p2 p3",
            author: "Grace Hopper",
            date: "2026-06-25T11:00:00+00:00",
            subject: "Merge branches",
            refs: ""
        )
        let commits = Commit.parse(output)
        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(commits[0].parents, ["p1", "p2", "p3"])
    }

    func testRootCommitHasNoParents() {
        let output = record(
            hash: "root0",
            parents: "",
            author: "Someone",
            date: "2026-01-01T00:00:00+00:00",
            subject: "Initial commit",
            refs: ""
        )
        let commits = Commit.parse(output)
        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(commits[0].parents, [])
    }

    func testRefDecorationsStripPrefixes() {
        let output = record(
            hash: "c1",
            parents: "p1",
            author: "Dev",
            date: "2026-06-25T12:00:00+00:00",
            subject: "Release",
            refs: "HEAD -> main, origin/main, tag: v1.0"
        )
        let commits = Commit.parse(output)
        XCTAssertEqual(commits[0].refs, ["main", "origin/main", "v1.0"])
    }

    func testDetachedHeadEntryIsDropped() {
        let output = record(
            hash: "c1",
            parents: "p1",
            author: "Dev",
            date: "2026-06-25T12:00:00+00:00",
            subject: "Detached",
            refs: "HEAD, tag: v2.0"
        )
        let commits = Commit.parse(output)
        XCTAssertEqual(commits[0].refs, ["v2.0"])
    }

    func testSubjectWithSpacesAndCommasSurvives() {
        let output = record(
            hash: "c1",
            parents: "p1",
            author: "Dev",
            date: "2026-06-25T12:00:00+00:00",
            subject: "feat: add A, B and C with spaces",
            refs: ""
        )
        let commits = Commit.parse(output)
        XCTAssertEqual(commits[0].subject, "feat: add A, B and C with spaces")
    }

    func testRefWithSpacesSurvives() {
        // Refs are comma-separated, so a slash-or-space-containing branch name
        // (within one comma-delimited entry) stays intact.
        let output = record(
            hash: "c1",
            parents: "p1",
            author: "Dev",
            date: "2026-06-25T12:00:00+00:00",
            subject: "x",
            refs: "feature/my long branch"
        )
        let commits = Commit.parse(output)
        XCTAssertEqual(commits[0].refs, ["feature/my long branch"])
    }

    func testMultipleRecordsPreserveOrder() {
        let output =
            record(hash: "h1", parents: "h2", author: "A", date: "d1", subject: "s1", refs: "")
            + "\n"
            + record(hash: "h2", parents: "", author: "B", date: "d2", subject: "s2", refs: "")
        let commits = Commit.parse(output)
        XCTAssertEqual(commits.map(\.hash), ["h1", "h2"])
        XCTAssertEqual(commits[1].parents, [])
    }

    func testMalformedRecordIsSkipped() {
        // Only 3 fields — not a valid 6-field record.
        let bad = "h1\u{0}p1\u{0}author\u{1e}"
        let good = record(
            hash: "h2", parents: "", author: "B", date: "d", subject: "s", refs: ""
        )
        let commits = Commit.parse(bad + good)
        XCTAssertEqual(commits.map(\.hash), ["h2"])
    }
}
