import XCTest
@testable import PisakaCore

@MainActor
final class CommitLogModelTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/repo")

    private enum StubError: Error { case boom }

    /// In-memory `GitServicing` for the Log model: returns canned commits (or a
    /// per-call sequence, to drive overlapping refreshes) or throws to simulate a
    /// non-repo / git failure. The local-changes methods are present only to
    /// satisfy the protocol and are unused here.
    private final class StubGit: GitServicing {
        var commitList: [Commit] = []
        var error: Error?
        var repoRoot: URL?

        /// Canned results for successive `commits` calls, in call order; calls past
        /// the end fall back to `commitList`. Lets two overlapping refreshes return
        /// distinct lists so a test can assert which one won.
        var resultsPerCommitsCall: [[Commit]] = []
        /// When true, each `commits` call suspends until `release(call:)` is invoked
        /// for its (0-based) call index, so a test can resolve calls out of order.
        var gateCommits = false
        private(set) var gatedCallIndices: [Int] = []
        /// How many times `commits` was called, so a test can assert that a
        /// client-side search (or a no-op filter re-apply) triggered no re-fetch.
        private(set) var commitsCallCount = 0
        /// The most recent filter `commits` was called with, for asserting that a
        /// filter change rebuilt the query.
        private(set) var lastFilter: LogFilter?
        /// The refs `references` returns.
        var refList: [String] = []
        /// When non-nil, `references` throws this *without* tripping the shared
        /// `error` flag, so a test can fail only the (best-effort) refs query while
        /// `commits` still succeeds.
        var referencesError: Error?
        private var gateContinuations: [Int: CheckedContinuation<Void, Never>] = [:]

        func repositoryRoot(for url: URL) async throws -> URL {
            if let error { throw error }
            return repoRoot ?? url
        }

        func commits(filter: LogFilter, limit: Int, root: URL) async throws -> [Commit] {
            if let error { throw error }
            lastFilter = filter
            let index = commitsCallCount
            commitsCallCount += 1
            let result = resultsPerCommitsCall.indices.contains(index)
                ? resultsPerCommitsCall[index]
                : commitList
            if gateCommits {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    gateContinuations[index] = cont
                    gatedCallIndices.append(index)
                }
            }
            return result
        }

        func release(call index: Int) {
            gateContinuations.removeValue(forKey: index)?.resume()
        }

        /// Canned changed-files for `commitChanges`, keyed by commit hash. A missing
        /// key returns `[]`.
        var changesByHash: [String: [ChangedFile]] = [:]
        /// Canned file contents for `fileContents`, keyed by "<revision>:<path>". A
        /// missing key returns `nil` (the file did not exist at that revision).
        var contentsByRevisionPath: [String: String] = [:]
        /// When non-nil, `commitChanges`/`fileContents` throw this instead of
        /// returning, so a test can exercise the model's error-swallowing.
        var detailError: Error?

        func commitChanges(hash: String, root: URL) async throws -> [ChangedFile] {
            if let detailError { throw detailError }
            return changesByHash[hash] ?? []
        }

        func fileContents(at revision: String, path: String, root: URL) async throws -> String? {
            if let detailError { throw detailError }
            return contentsByRevisionPath["\(revision):\(path)"]
        }

        func references(root: URL) async throws -> [String] {
            if let referencesError { throw referencesError }
            if let error { throw error }
            return refList
        }

        // Unused by the Log model — present only for protocol conformance.
        func changedFiles(root: URL) async throws -> [ChangedFile] { [] }
        func headContents(of path: String, root: URL) async throws -> String? { nil }
        func revert(_ file: ChangedFile, root: URL) async throws {}
    }

    private func commit(_ hash: String, subject: String = "s", parents: [String] = []) -> Commit {
        Commit(hash: hash, parents: parents, author: "A", date: "d", subject: subject, refs: [])
    }

    /// Spin the scheduler until `count` gated `commits` calls have suspended.
    private func waitForGatedCalls(_ count: Int, in git: StubGit) async {
        while git.gatedCallIndices.count < count { await Task.yield() }
    }

    // MARK: - refresh

    func testRefreshPopulatesCommits() async {
        let git = StubGit()
        git.commitList = [commit("a"), commit("b")]
        let model = CommitLogModel(gitService: git)

        await model.refresh(root: root, limit: 100)

        XCTAssertEqual(model.commits.map(\.hash), ["a", "b"])
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(model.root, root)
    }

    func testRefreshResolvesRepoRoot() async {
        let git = StubGit()
        let repo = URL(fileURLWithPath: "/repo-top")
        git.repoRoot = repo
        git.commitList = [commit("a")]
        let model = CommitLogModel(gitService: git)

        await model.refresh(root: root.appendingPathComponent("sub"), limit: 50)

        XCTAssertEqual(model.root, repo)
    }

    func testRefreshErrorSurfacesToErrorMessage() async {
        let git = StubGit()
        git.error = StubError.boom
        let model = CommitLogModel(gitService: git)

        await model.refresh(root: root, limit: 100)

        XCTAssertEqual(model.commits, [])
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.isLoading)
    }

    func testFailedRefreshClearsPriorCommitsAndSelection() async {
        let git = StubGit()
        git.commitList = [commit("a")]
        let model = CommitLogModel(gitService: git)
        await model.refresh(root: root, limit: 100)
        model.select(commit("a"))
        XCTAssertNotNil(model.selected)

        git.error = StubError.boom
        await model.refresh(root: root, limit: 100)

        XCTAssertEqual(model.commits, [])
        XCTAssertNil(model.selected)
        XCTAssertNotNil(model.errorMessage)
    }

    // MARK: - selection

    func testSelectOnlyAcceptsCurrentCommit() async {
        let git = StubGit()
        git.commitList = [commit("a")]
        let model = CommitLogModel(gitService: git)
        await model.refresh(root: root, limit: 100)

        model.select(commit("missing"))
        XCTAssertNil(model.selected)

        model.select(commit("a"))
        XCTAssertEqual(model.selected?.hash, "a")

        model.select(nil)
        XCTAssertNil(model.selected)
    }

    func testRefreshRebindsSelectionToRefreshedCommit() async {
        let git = StubGit()
        git.commitList = [commit("a", subject: "old")]
        let model = CommitLogModel(gitService: git)
        await model.refresh(root: root, limit: 100)
        model.select(commit("a"))

        // A refresh returns the same commit id with updated metadata; the
        // selection should re-bind to the fresh value.
        git.commitList = [commit("a", subject: "new")]
        await model.refresh(root: root, limit: 100)

        XCTAssertEqual(model.selected?.subject, "new")
    }

    func testRefreshClearsSelectionWhenCommitGone() async {
        let git = StubGit()
        git.commitList = [commit("a")]
        let model = CommitLogModel(gitService: git)
        await model.refresh(root: root, limit: 100)
        model.select(commit("a"))
        XCTAssertNotNil(model.selected)

        git.commitList = [commit("b")]
        await model.refresh(root: root, limit: 100)

        XCTAssertNil(model.selected)
    }

    func testReconcileSelectionHelper() {
        XCTAssertNil(CommitLogModel.reconcileSelection(selected: nil, commits: [commit("a")]))
        XCTAssertNil(CommitLogModel.reconcileSelection(selected: commit("x"), commits: [commit("a")]))
        let rebound = CommitLogModel.reconcileSelection(
            selected: commit("a", subject: "old"),
            commits: [commit("a", subject: "new")]
        )
        XCTAssertEqual(rebound?.subject, "new")
    }

    // MARK: - generation guard

    func testStaleRefreshIsDiscarded() async {
        let git = StubGit()
        git.gateCommits = true
        git.resultsPerCommitsCall = [[commit("stale")], [commit("fresh")]]
        let model = CommitLogModel(gitService: git)

        // Two overlapping refreshes: the first (call 0) returns "stale", the
        // second (call 1) "fresh". Both reach the gate, then we release the
        // *newer* one first and the *older* one second — the older result must be
        // discarded so "fresh" stays published.
        let first = Task { await model.refresh(root: root, limit: 100) }
        await waitForGatedCalls(1, in: git)
        let second = Task { await model.refresh(root: root, limit: 100) }
        await waitForGatedCalls(2, in: git)

        git.release(call: 1) // newer completes first
        await second.value
        git.release(call: 0) // older completes after — must not clobber
        await first.value

        XCTAssertEqual(model.commits.map(\.hash), ["fresh"])
    }

    func testNewerRequestSupersedesOlderOutOfOrderTask() async {
        // Tokens are captured synchronously in creation order; the *older* task is
        // then started last, mimicking unstructured tasks running out of order. It
        // must bail at entry (never querying) so the newer request wins.
        let git = StubGit()
        git.gateCommits = true
        git.resultsPerCommitsCall = [[commit("new")]]
        let model = CommitLogModel(gitService: git)

        let older = model.prepareForRefresh(root: root)
        let newer = model.prepareForRefresh(root: root)
        XCTAssertEqual(newer, older + 1)

        let newerTask = Task { await model.refresh(root: root, limit: 100, request: newer) }
        await waitForGatedCalls(1, in: git)
        let olderTask = Task { await model.refresh(root: root, limit: 100, request: older) }
        await olderTask.value
        // The older request bailed at entry, so only the newer one queried git.
        XCTAssertEqual(git.commitsCallCount, 1)

        git.release(call: 0)
        await newerTask.value
        XCTAssertEqual(model.commits.map(\.hash), ["new"])
        XCTAssertNil(model.errorMessage)
    }

    // MARK: - repository switch

    func testRepositoryChangeResetsRefFilterAndReferences() async {
        let git = StubGit()
        git.commitList = [commit("a")]
        git.refList = ["feature"]
        let model = CommitLogModel(gitService: git)
        await model.refresh(root: root, limit: 100)
        // Pick a repo-specific ref filter for the first repo.
        await model.applyFilter(LogFilter(refSelection: .ref("feature")), root: root, limit: 100)
        model.setSearchQuery("wip")
        XCTAssertEqual(model.filter, LogFilter(refSelection: .ref("feature")))
        XCTAssertEqual(model.references, ["feature"])

        // Switching to a different repository must drop the old repo's ref-specific
        // filter, search, and ref list synchronously — so the new repo is queried
        // with the default `--all` rather than a branch it does not have.
        let otherRoot = URL(fileURLWithPath: "/other-repo")
        let request = model.prepareForRefresh(root: otherRoot)
        XCTAssertEqual(model.filter, LogFilter())
        XCTAssertEqual(model.searchQuery, "")
        XCTAssertEqual(model.references, [])
        // The previous repo's commit list must also be dropped synchronously, so the
        // old history is neither shown nor selectable (querying detail against the
        // stale root) during the window until the new fetch resolves.
        XCTAssertEqual(model.commits, [])

        git.refList = ["main"]
        await model.refresh(root: otherRoot, limit: 100, request: request)
        XCTAssertEqual(model.filter, LogFilter())
        XCTAssertEqual(model.references, ["main"])
    }

    func testFailedRefreshClearsStaleReferences() async {
        // A failure after a previous success must clear the stale ref list, not
        // leave an actionable picker over a log stuck in an error state.
        let git = StubGit()
        git.commitList = [commit("a")]
        git.refList = ["main"]
        let model = CommitLogModel(gitService: git)
        await model.refresh(root: root, limit: 100)
        XCTAssertEqual(model.references, ["main"])

        git.error = StubError.boom
        await model.refresh(root: root, limit: 100)
        XCTAssertEqual(model.references, [])
        XCTAssertNotNil(model.errorMessage)
    }

    // MARK: - commit detail: changed files

    func testChangesReturnsServiceResultForCommit() async {
        let git = StubGit()
        git.commitList = [commit("a")]
        git.changesByHash["a"] = [
            ChangedFile(path: "A.swift", status: .modified),
            ChangedFile(path: "B.swift", status: .added),
        ]
        let model = CommitLogModel(gitService: git)
        await model.refresh(root: root, limit: 100)

        let files = await model.changes(for: commit("a"))
        XCTAssertEqual(files.map(\.path), ["A.swift", "B.swift"])
    }

    func testChangesEmptyBeforeRefresh() async {
        let git = StubGit()
        git.changesByHash["a"] = [ChangedFile(path: "A.swift", status: .modified)]
        let model = CommitLogModel(gitService: git)

        // No refresh yet ⇒ no root ⇒ no detail query.
        let files = await model.changes(for: commit("a"))
        XCTAssertEqual(files, [])
    }

    func testChangesSwallowsServiceError() async {
        let git = StubGit()
        git.commitList = [commit("a")]
        let model = CommitLogModel(gitService: git)
        await model.refresh(root: root, limit: 100)

        git.detailError = StubError.boom
        let files = await model.changes(for: commit("a"))
        XCTAssertEqual(files, [])
    }

    // MARK: - commit detail: diff rows

    func testRowsForModifiedFileDiffsParentVsCommit() async {
        let git = StubGit()
        let c = commit("child", parents: ["parent"])
        git.commitList = [c]
        git.contentsByRevisionPath["parent:A.swift"] = "old\n"
        git.contentsByRevisionPath["child:A.swift"] = "new\n"
        let model = CommitLogModel(gitService: git)
        await model.refresh(root: root, limit: 100)

        let rows = await model.rows(for: ChangedFile(path: "A.swift", status: .modified), in: c)
        XCTAssertEqual(rows, LineDiff.rows(old: "old\n", new: "new\n"))
    }

    func testRowsForAddedFileHasEmptyOldSide() async {
        let git = StubGit()
        let c = commit("child", parents: ["parent"])
        git.commitList = [c]
        // An added file should not be read from the parent even if present there.
        git.contentsByRevisionPath["parent:A.swift"] = "should be ignored\n"
        git.contentsByRevisionPath["child:A.swift"] = "added line\n"
        let model = CommitLogModel(gitService: git)
        await model.refresh(root: root, limit: 100)

        let rows = await model.rows(for: ChangedFile(path: "A.swift", status: .added), in: c)
        XCTAssertEqual(rows, LineDiff.rows(old: "", new: "added line\n"))
    }

    func testRowsForDeletedFileHasEmptyNewSide() async {
        let git = StubGit()
        let c = commit("child", parents: ["parent"])
        git.commitList = [c]
        git.contentsByRevisionPath["parent:A.swift"] = "gone line\n"
        // Even if the commit somehow has content, a deleted file's new side is empty.
        git.contentsByRevisionPath["child:A.swift"] = "should be ignored\n"
        let model = CommitLogModel(gitService: git)
        await model.refresh(root: root, limit: 100)

        let rows = await model.rows(for: ChangedFile(path: "A.swift", status: .deleted), in: c)
        XCTAssertEqual(rows, LineDiff.rows(old: "gone line\n", new: ""))
    }

    func testRowsForRenameReadsOldPathAtParent() async {
        let git = StubGit()
        let c = commit("child", parents: ["parent"])
        git.commitList = [c]
        git.contentsByRevisionPath["parent:old.swift"] = "content\n"
        git.contentsByRevisionPath["child:new.swift"] = "content\n"
        let model = CommitLogModel(gitService: git)
        await model.refresh(root: root, limit: 100)

        let file = ChangedFile(path: "new.swift", status: .renamed, oldPath: "old.swift")
        let rows = await model.rows(for: file, in: c)
        XCTAssertEqual(rows, LineDiff.rows(old: "content\n", new: "content\n"))
    }

    func testRowsForRootCommitHasEmptyOldSide() async {
        let git = StubGit()
        // A root commit has no parent, so every file's old side is empty.
        let c = commit("root", parents: [])
        git.commitList = [c]
        git.contentsByRevisionPath["root:A.swift"] = "initial\n"
        let model = CommitLogModel(gitService: git)
        await model.refresh(root: root, limit: 100)

        let rows = await model.rows(for: ChangedFile(path: "A.swift", status: .added), in: c)
        XCTAssertEqual(rows, LineDiff.rows(old: "", new: "initial\n"))
    }

    func testRowsEmptyBeforeRefresh() async {
        let git = StubGit()
        let c = commit("child", parents: ["parent"])
        let model = CommitLogModel(gitService: git)

        let rows = await model.rows(for: ChangedFile(path: "A.swift", status: .modified), in: c)
        XCTAssertEqual(rows, [])
    }

    func testRowsForMergeReadsFirstParent() async {
        // A merge commit diffs against its *first* parent only, so the old side
        // must come from `parents.first`, never a later parent.
        let git = StubGit()
        let c = commit("merge", parents: ["p1", "p2"])
        git.commitList = [c]
        git.contentsByRevisionPath["p1:A.swift"] = "first-parent\n"
        git.contentsByRevisionPath["p2:A.swift"] = "second-parent should be ignored\n"
        git.contentsByRevisionPath["merge:A.swift"] = "merged\n"
        let model = CommitLogModel(gitService: git)
        await model.refresh(root: root, limit: 100)

        let rows = await model.rows(for: ChangedFile(path: "A.swift", status: .modified), in: c)
        XCTAssertEqual(rows, LineDiff.rows(old: "first-parent\n", new: "merged\n"))
    }

    func testRowsSwallowsServiceError() async {
        // A `fileContents` throw on either side leaves that side empty rather than
        // propagating, so the detail pane shows an empty diff instead of crashing.
        let git = StubGit()
        let c = commit("child", parents: ["parent"])
        git.commitList = [c]
        let model = CommitLogModel(gitService: git)
        await model.refresh(root: root, limit: 100)

        git.detailError = StubError.boom
        let rows = await model.rows(for: ChangedFile(path: "A.swift", status: .modified), in: c)
        XCTAssertEqual(rows, LineDiff.rows(old: "", new: ""))
    }

    // MARK: - references

    func testRefreshLoadsReferences() async {
        let git = StubGit()
        git.commitList = [commit("a")]
        git.refList = ["main", "origin/main", "v1.0"]
        let model = CommitLogModel(gitService: git)

        await model.refresh(root: root, limit: 100)

        XCTAssertEqual(model.references, ["main", "origin/main", "v1.0"])
    }

    func testRefreshDegradesWhenReferencesFail() async {
        // A `for-each-ref` hiccup must not fail the whole refresh: commits still
        // publish, the picker degrades to an empty ref list, and no error surfaces.
        let git = StubGit()
        git.commitList = [commit("a"), commit("b")]
        git.referencesError = StubError.boom
        let model = CommitLogModel(gitService: git)

        await model.refresh(root: root, limit: 100)

        XCTAssertEqual(model.commits.map(\.hash), ["a", "b"])
        XCTAssertEqual(model.references, [])
        XCTAssertNil(model.errorMessage)
    }

    // MARK: - applyFilter

    func testApplyFilterRebuildsQueryAndRefetches() async {
        let git = StubGit()
        git.resultsPerCommitsCall = [[commit("a")], [commit("b")]]
        let model = CommitLogModel(gitService: git)
        await model.refresh(root: root, limit: 100)
        XCTAssertEqual(model.commits.map(\.hash), ["a"])

        let newFilter = LogFilter(author: "Alice")
        await model.applyFilter(newFilter, root: root, limit: 100)

        XCTAssertEqual(model.filter, newFilter)
        XCTAssertEqual(model.commits.map(\.hash), ["b"])
        XCTAssertEqual(git.lastFilter, newFilter)
        XCTAssertEqual(git.commitsCallCount, 2)
    }

    func testApplyFilterNoOpWhenUnchanged() async {
        let git = StubGit()
        git.commitList = [commit("a")]
        let model = CommitLogModel(gitService: git)
        await model.refresh(root: root, limit: 100)
        XCTAssertEqual(git.commitsCallCount, 1)

        // Re-applying the same (default) filter must not spend a redundant fetch.
        await model.applyFilter(LogFilter(), root: root, limit: 100)
        XCTAssertEqual(git.commitsCallCount, 1)
    }

    func testApplyFilterSurfacesError() async {
        let git = StubGit()
        git.commitList = [commit("a")]
        let model = CommitLogModel(gitService: git)
        await model.refresh(root: root, limit: 100)

        git.error = StubError.boom
        await model.applyFilter(LogFilter(author: "Alice"), root: root, limit: 100)

        XCTAssertEqual(model.commits, [])
        XCTAssertNotNil(model.errorMessage)
    }

    // MARK: - prepareForFilter ordering

    func testPrepareForFilterReturnsTokenForChangeAndNilForNoOp() async {
        let git = StubGit()
        git.commitList = [commit("a")]
        let model = CommitLogModel(gitService: git)
        await model.refresh(root: root, limit: 100)

        // A genuine change yields a token; re-requesting the same filter is a no-op.
        let token = model.prepareForFilter(LogFilter(author: "Alice"), root: root)
        XCTAssertNotNil(token)
        XCTAssertNil(model.prepareForFilter(LogFilter(author: "Alice"), root: root))
    }

    func testPrepareForFilterComparesLatestRequestedNotCommitted() async {
        // The bug guard: while a change to filter B is requested but not yet applied
        // (its `Task` hasn't run, so the *committed* filter is still the default),
        // reverting to the default must NOT be dropped as a no-op — it is a real,
        // newer intent that has to supersede B. Comparing against the committed
        // filter would wrongly drop it; comparing against the latest *requested*
        // filter lets it through.
        let git = StubGit()
        git.commitList = [commit("a")]
        let model = CommitLogModel(gitService: git)
        await model.refresh(root: root, limit: 100)
        XCTAssertEqual(model.filter, LogFilter())

        let reqB = model.prepareForFilter(LogFilter(author: "B"), root: root)
        XCTAssertNotNil(reqB)
        // Committed filter is still the default here (B's task hasn't applied it).
        XCTAssertEqual(model.filter, LogFilter())

        // Reverting to the (committed) default must still register and supersede B.
        let reqDefault = model.prepareForFilter(LogFilter(), root: root)
        XCTAssertEqual(reqDefault, reqB.map { $0 + 1 })
    }

    func testDirectApplyFilterSupersedesPreparedRequest() async {
        // A direct (request: nil) applyFilter is treated as the latest: it bumps the
        // generation *before* its no-op check, so a prepared-but-unstarted filter
        // request can't win out of order behind it. Sequence: load default → prepare
        // filter B → directly re-apply the default (a no-op for the committed filter,
        // but it must still supersede B) → B's task runs and must bail.
        let git = StubGit()
        git.commitList = [commit("a")]
        let model = CommitLogModel(gitService: git)
        await model.refresh(root: root, limit: 100)
        let baselineCalls = git.commitsCallCount

        let reqB = model.prepareForFilter(LogFilter(author: "B"), root: root)!

        // Directly re-apply the default: a no-op fetch-wise, but it bumps the
        // generation so B is now superseded.
        await model.applyFilter(LogFilter(), root: root, limit: 100)
        XCTAssertEqual(git.commitsCallCount, baselineCalls)
        XCTAssertEqual(model.filter, LogFilter())

        // B's task, started last, must now bail — never queried, filter stays default.
        await model.applyFilter(LogFilter(author: "B"), root: root, limit: 100, request: reqB)
        XCTAssertEqual(git.commitsCallCount, baselineCalls)
        XCTAssertEqual(model.filter, LogFilter())
    }

    func testApplyFilterBailsWhenRequestSuperseded() async {
        // The newer request (default revert) supersedes the older (B); B's task,
        // started last to mimic out-of-order scheduling, must bail at entry so B is
        // never queried and the committed filter stays the default.
        let git = StubGit()
        git.commitList = [commit("a")]
        let model = CommitLogModel(gitService: git)
        await model.refresh(root: root, limit: 100)
        let baselineCalls = git.commitsCallCount

        let reqB = model.prepareForFilter(LogFilter(author: "B"), root: root)!
        let reqDefault = model.prepareForFilter(LogFilter(), root: root)!

        // Run the superseded B request: it must bail (no fetch, filter unchanged).
        await model.applyFilter(LogFilter(author: "B"), root: root, limit: 100, request: reqB)
        XCTAssertEqual(git.commitsCallCount, baselineCalls)
        XCTAssertEqual(model.filter, LogFilter())

        // The default revert is the committed filter already, so it too needs no
        // fetch — the user's last choice (default) is what stays displayed.
        await model.applyFilter(LogFilter(), root: root, limit: 100, request: reqDefault)
        XCTAssertEqual(git.commitsCallCount, baselineCalls)
        XCTAssertEqual(model.filter, LogFilter())
    }

    func testRepositoryChangeResetsRequestedFilter() async {
        // A folder switch must reset the latest-requested filter too, so the first
        // filter request in the new repo is never mistaken for a no-op.
        let git = StubGit()
        git.commitList = [commit("a")]
        let model = CommitLogModel(gitService: git)
        await model.refresh(root: root, limit: 100)
        _ = model.prepareForFilter(LogFilter(author: "Alice"), root: root)

        let otherRoot = URL(fileURLWithPath: "/other-repo")
        model.prepareForRefresh(root: otherRoot)
        // Requesting the same author filter the *old* repo had must now register, not
        // no-op, since the switch reset the requested filter to the default.
        XCTAssertNotNil(model.prepareForFilter(LogFilter(author: "Alice"), root: otherRoot))
    }

    func testPlainRefreshReconcilesRequestedFilterForSameRoot() async {
        // A plain refresh (Refresh / Load More) for the *same* root re-fetches with the
        // committed filter, superseding any filter request that was prepared but never
        // applied. So it must reconcile the latest-*requested* filter back to the
        // committed one — otherwise a filter that was requested but dropped would be
        // wrongly treated as already-requested, and selecting it again would no-op
        // until the user picked a different filter first.
        let git = StubGit()
        git.commitList = [commit("a")]
        let model = CommitLogModel(gitService: git)
        await model.refresh(root: root, limit: 100)

        // Request filter B, but its task hasn't applied it yet (committed filter still
        // the default).
        let reqB = model.prepareForFilter(LogFilter(author: "B"), root: root)
        XCTAssertNotNil(reqB)

        // A plain refresh runs first and supersedes B's pending request.
        let refreshReq = model.prepareForRefresh(root: root)
        XCTAssertEqual(refreshReq, reqB.map { $0 + 1 })
        await model.refresh(root: root, limit: 100, request: refreshReq)
        XCTAssertEqual(model.filter, LogFilter())

        // Re-selecting B must now register (not no-op), since the plain refresh reset
        // the requested filter back to the committed default.
        XCTAssertNotNil(model.prepareForFilter(LogFilter(author: "B"), root: root))
    }

    func testLatestNoOpFilterClearsLoadingAfterSupersedingInFlightRefresh() async {
        // A no-op (committed-filter-equal) filter request that is nonetheless the
        // latest generation must not strand the view on "Loading…": it has superseded
        // the in-flight refresh that would have published, so that refresh is discarded
        // without clearing `isLoading`. The winning request must run the fetch itself.
        let git = StubGit()
        git.gateCommits = true
        git.resultsPerCommitsCall = [[commit("initial")], [commit("final")]]
        let model = CommitLogModel(gitService: git)

        // Initial default refresh is in flight (gated mid-fetch), so isLoading is true.
        let initialReq = model.prepareForRefresh(root: root)
        let initialTask = Task { await model.refresh(root: root, limit: 100, request: initialReq) }
        await waitForGatedCalls(1, in: git)
        XCTAssertTrue(model.isLoading)

        // Request filter B, then revert to the default before either task applies.
        let reqB = model.prepareForFilter(LogFilter(author: "B"), root: root)!
        let reqDefault = model.prepareForFilter(LogFilter(), root: root)!

        // B's request is superseded and bails at entry.
        await model.applyFilter(LogFilter(author: "B"), root: root, limit: 100, request: reqB)

        // Let the winning default revert's fetch complete without gating.
        git.gateCommits = false
        let defaultTask = Task {
            await model.applyFilter(LogFilter(), root: root, limit: 100, request: reqDefault)
        }
        await defaultTask.value

        // The superseded initial refresh resolves last and is discarded.
        git.release(call: 0)
        await initialTask.value

        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(model.commits.map(\.hash), ["final"])
        XCTAssertNil(model.errorMessage)
    }

    func testDirectRefreshReconcilesRequestedFilterForSameRoot() async {
        // Like the pinned-token plain refresh, a *direct* refresh (request: nil — no
        // `prepareForRefresh`) for the same root re-fetches with the committed filter
        // and supersedes any prepared-but-unapplied filter request. It must reconcile
        // the latest-*requested* filter back to the committed one, so re-selecting that
        // dropped filter registers instead of being misread as a no-op.
        let git = StubGit()
        git.commitList = [commit("a")]
        let model = CommitLogModel(gitService: git)
        await model.refresh(root: root, limit: 100)

        // Request filter B but never apply it.
        XCTAssertNotNil(model.prepareForFilter(LogFilter(author: "B"), root: root))

        // A direct refresh supersedes B's pending request and re-fetches the default.
        await model.refresh(root: root, limit: 100)
        XCTAssertEqual(model.filter, LogFilter())

        // Re-selecting B must now register (not no-op).
        XCTAssertNotNil(model.prepareForFilter(LogFilter(author: "B"), root: root))
    }

    func testLatestNoOpFilterFetchesAfterSupersedingPreparedButUnstartedRefresh() async {
        // The companion to `…AfterSupersedingInFlightRefresh`, but the superseded
        // refresh was only *prepared* — its task never started, so `isLoading` is still
        // false. A revert to the committed filter that is nonetheless the latest
        // generation must still run the fetch: a `!isLoading` guard would wrongly treat
        // it as a settled no-op and leave the log empty, since the prepared refresh it
        // superseded bails as stale and never loads.
        let git = StubGit()
        git.commitList = [commit("x")]
        let model = CommitLogModel(gitService: git)

        // A plain (initial/manual) refresh is prepared, then the filter changes to B and
        // reverts to the default — all before any task runs, so nothing set `isLoading`.
        let initialReq = model.prepareForRefresh(root: root)
        let reqB = model.prepareForFilter(LogFilter(author: "B"), root: root)!
        let reqDefault = model.prepareForFilter(LogFilter(), root: root)!
        XCTAssertFalse(model.isLoading)

        // The superseded initial refresh and B's request both bail at entry.
        await model.refresh(root: root, limit: 100, request: initialReq)
        await model.applyFilter(LogFilter(author: "B"), root: root, limit: 100, request: reqB)
        XCTAssertEqual(git.commitsCallCount, 0)

        // The latest request reverts to the committed default with nothing loaded yet.
        await model.applyFilter(LogFilter(), root: root, limit: 100, request: reqDefault)

        XCTAssertEqual(model.commits.map(\.hash), ["x"])
        XCTAssertEqual(git.commitsCallCount, 1)
        XCTAssertFalse(model.isLoading)
    }

    func testRepositoryChangeFetchesNewRepoAfterFilterRevert() async {
        // Regression: a folder switch clears `commits` but must also reset
        // `hasCompletedFetch` — it tracks whether the *current* repo's data is on
        // screen. With the old repo's flag left true, a revert-to-default filter
        // request (the latest generation) whose committed filter equals the
        // also-reset default would no-op via `applyFilter`'s guard while every
        // superseded refresh bails, stranding the new repo's log empty.
        let git = StubGit()
        git.resultsPerCommitsCall = [[commit("a")], [commit("b")]]
        let model = CommitLogModel(gitService: git)

        // Repo A fully loads (hasCompletedFetch becomes true, filter is default).
        await model.refresh(root: root, limit: 100)
        XCTAssertEqual(model.commits.map(\.hash), ["a"])

        // Switch to repo B: prepare its refresh but don't start the task yet.
        let otherRoot = URL(fileURLWithPath: "/other-repo")
        let refreshReq = model.prepareForRefresh(root: otherRoot)
        XCTAssertEqual(model.commits, [])

        // Filter changes to B then reverts to the default, all before any task runs.
        let reqFilter = model.prepareForFilter(LogFilter(author: "B"), root: otherRoot)!
        let reqDefault = model.prepareForFilter(LogFilter(), root: otherRoot)!

        // The superseded refresh and filter requests bail at entry.
        await model.refresh(root: otherRoot, limit: 100, request: refreshReq)
        await model.applyFilter(LogFilter(author: "B"), root: otherRoot, limit: 100, request: reqFilter)

        // The latest request (revert to default) must run the fetch for repo B.
        await model.applyFilter(LogFilter(), root: otherRoot, limit: 100, request: reqDefault)

        XCTAssertEqual(model.commits.map(\.hash), ["b"])
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isLoading)
    }

    func testPublishedFilterLagsRequestedAndEchoIsAcceptedWhenAppliesInterleave() async {
        // Pin for the one-phase lag the view must not rely on: when two applies
        // interleave, the published `filter` lags `currentRequestedFilter` by one
        // phase (publish happens synchronously at `applyFilter` entry before the
        // `await` on git), so an echo built from the published value is a genuinely
        // different filter and is accepted — it would spawn a fetch. Not echoing is
        // the view's obligation (user-intent bindings apply only from `Binding.set` /
        // `onSubmit`, and `seedFromFilter` assigns the draft directly); the model's
        // `prepareForFilter` guard orders requests and cannot suppress the echo.
        let git = StubGit()
        git.gateCommits = true
        let model = CommitLogModel(gitService: git)

        let filterB = LogFilter(author: "B")
        let filterC = LogFilter(author: "C")

        let reqB = model.prepareForFilter(filterB, root: root)!
        let taskB = Task { await model.applyFilter(filterB, root: root, limit: 100, request: reqB) }
        await waitForGatedCalls(1, in: git)
        XCTAssertEqual(model.filter, filterB)
        XCTAssertEqual(model.currentRequestedFilter, filterB)

        let reqC = model.prepareForFilter(filterC, root: root)!
        XCTAssertEqual(model.currentRequestedFilter, filterC)
        XCTAssertEqual(model.filter, filterB)
        XCTAssertNotEqual(model.filter, model.currentRequestedFilter)

        let echoToken = model.prepareForFilter(model.filter, root: root)
        XCTAssertNotNil(echoToken, "echo of published filter must be accepted while lag persists")

        git.gateCommits = false
        git.release(call: 0)
        await taskB.value
        // Clean up superseded requests: the echo bump made reqC stale, so drive
        // the last intent with a direct apply that supersedes the echo.
        await model.applyFilter(filterC, root: root, limit: 100)
    }

    // MARK: - client-side search

    func testSetSearchQueryFiltersVisibleCommitsWithoutRefetch() async {
        let git = StubGit()
        git.commitList = [
            commit("a", subject: "Fix parser bug"),
            commit("b", subject: "Add log filters"),
            commit("c", subject: "Another bugfix"),
        ]
        let model = CommitLogModel(gitService: git)
        await model.refresh(root: root, limit: 100)
        XCTAssertEqual(git.commitsCallCount, 1)

        model.setSearchQuery("bug")

        XCTAssertEqual(model.visibleCommits.map(\.hash), ["a", "c"])
        // The raw list and selection mechanics are untouched, and no re-fetch ran.
        XCTAssertEqual(model.commits.count, 3)
        XCTAssertEqual(git.commitsCallCount, 1)
    }

    func testVisibleCommitsEqualsCommitsWhenSearchBlank() async {
        let git = StubGit()
        git.commitList = [commit("a", subject: "x"), commit("b", subject: "y")]
        let model = CommitLogModel(gitService: git)
        await model.refresh(root: root, limit: 100)

        XCTAssertEqual(model.visibleCommits.map(\.hash), ["a", "b"])
    }
}
