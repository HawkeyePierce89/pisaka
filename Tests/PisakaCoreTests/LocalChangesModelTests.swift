import XCTest
@testable import PisakaCore

@MainActor
final class LocalChangesModelTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/repo")

    // MARK: - Stubs

    private enum StubError: Error { case boom }

    /// A revert failure that reports which paths it had already changed — mirrors
    /// the real `InterruptedRevert` so the model's `PartialRevertError` handling
    /// is exercised without `Process`.
    private struct StubPartialRevert: PartialRevertError {
        let changedPaths: [String]
    }

    /// In-memory `GitServicing`: returns canned changed files and HEAD contents,
    /// or throws `error` (set per-test) to simulate a non-repo / git failure.
    private final class StubGit: GitServicing {
        var files: [ChangedFile] = []
        var headByPath: [String: String] = [:]
        var error: Error?
        /// The repo root to report; defaults to echoing the queried folder.
        var repoRoot: URL?
        /// Files passed to `revert`, in call order.
        var revertedFiles: [ChangedFile] = []
        /// When set, `revert` throws this instead of recording the file.
        var revertError: Error?
        /// When set, `revert` throws for the file at this path only (others
        /// succeed) — used to exercise a mid-batch failure.
        var revertFailPath: String?
        /// The error thrown for `revertFailPath` (defaults to `StubError.boom`).
        /// Set to a `PartialRevertError` to exercise a mid-batch partial failure.
        var revertFailError: Error?
        /// Fired after each successful `revert`, letting a test mutate `files`
        /// mid-batch to simulate an out-of-band change during the loop.
        var onRevert: (() -> Void)?

        // MARK: gating (out-of-order refresh tests)

        /// Canned results for successive `changedFiles` calls, in call order;
        /// calls past the end fall back to `files`. Lets two overlapping refreshes
        /// return distinct lists so a test can assert which one won.
        var resultsPerChangedFilesCall: [[ChangedFile]] = []
        /// When true, each `changedFiles` call suspends until `release(call:)` is
        /// invoked for its (0-based) call index, so a test can resolve in-flight
        /// calls out of order.
        var gateChangedFiles = false
        /// The call indices that have suspended at the gate so far, in order — a
        /// test waits on this to know an overlapping refresh has reached the gate.
        private(set) var gatedCallIndices: [Int] = []
        private var changedFilesCallCount = 0
        private var gateContinuations: [Int: CheckedContinuation<Void, Never>] = [:]

        func repositoryRoot(for url: URL) async throws -> URL {
            if let error { throw error }
            return repoRoot ?? url
        }

        func changedFiles(root: URL) async throws -> [ChangedFile] {
            if let error { throw error }
            let index = changedFilesCallCount
            changedFilesCallCount += 1
            let result = resultsPerChangedFilesCall.indices.contains(index)
                ? resultsPerChangedFilesCall[index]
                : files
            if gateChangedFiles {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    gateContinuations[index] = cont
                    gatedCallIndices.append(index)
                }
                // Re-check after the gate so a test can fail an already-suspended
                // call (e.g. to drive a stale refresh down the catch path).
                if let error { throw error }
            }
            return result
        }

        /// Release the gated `changedFiles` call at `index`, letting it return.
        func release(call index: Int) {
            gateContinuations.removeValue(forKey: index)?.resume()
        }

        func commits(filter: LogFilter, limit: Int, root: URL) async throws -> [Commit] {
            if let error { throw error }
            return []
        }

        func headContents(of path: String, root: URL) async throws -> String? {
            if let error { throw error }
            return headByPath[path]
        }

        func revert(_ file: ChangedFile, root: URL) async throws {
            if let revertError { throw revertError }
            if let revertFailPath, file.path == revertFailPath { throw revertFailError ?? StubError.boom }
            revertedFiles.append(file)
            // Simulate the on-disk effect so the model's pre-revert re-query and
            // the post-revert refresh both see the file gone, as real git would.
            files.removeAll { $0.id == file.id }
            onRevert?()
        }
    }

    /// In-memory `FileServicing`: working-copy text keyed by absolute path.
    private final class StubFiles: FileServicing {
        var contentsByPath: [String: String] = [:]
        /// Symlink targets keyed by absolute path (the git-blob target string).
        var symlinkTargetsByPath: [String: String] = [:]

        func read(url: URL) throws -> String {
            if let text = contentsByPath[url.path] { return text }
            throw CocoaError(.fileReadNoSuchFile)
        }
        func write(_ text: String, to url: URL) throws {}
        func contentsOfDirectory(at url: URL) throws -> [DirectoryEntry] { [] }
        func symbolicLinkDestination(at url: URL) -> String? {
            symlinkTargetsByPath[url.path]
        }
        func isExecutableFile(at url: URL) -> Bool { false }
    }

    private func makeModel(git: StubGit, files: StubFiles = StubFiles()) -> LocalChangesModel {
        LocalChangesModel(gitService: git, fileService: files)
    }

    /// Spin the cooperative scheduler until `count` gated `changedFiles` calls
    /// have suspended at the stub's gate (so an overlapping refresh is known to
    /// have reached its git I/O before the next one starts).
    private func waitForGatedCalls(_ count: Int, in git: StubGit) async {
        while git.gatedCallIndices.count < count { await Task.yield() }
    }

    // MARK: - refresh

    func testRefreshPopulatesChangedFiles() async {
        let git = StubGit()
        git.files = [ChangedFile(path: "a.swift", status: .modified)]
        let model = makeModel(git: git)

        await model.refresh(root: root)

        XCTAssertEqual(model.changedFiles, git.files)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.root, root)
    }

    func testRefreshErrorClearsStateAndSurfacesMessage() async {
        let git = StubGit()
        let file = ChangedFile(path: "a.swift", status: .modified)
        git.files = [file]
        let model = makeModel(git: git)

        await model.refresh(root: root)
        model.select(file)
        XCTAssertEqual(model.changedFiles.count, 1)

        // A subsequent failing refresh (e.g. folder is not a repo) clears state
        // and surfaces a message instead of crashing.
        git.error = StubError.boom
        await model.refresh(root: root)

        XCTAssertTrue(model.changedFiles.isEmpty)
        XCTAssertNil(model.selected)
        XCTAssertNotNil(model.errorMessage)
    }

    func testStaleRefreshDoesNotClobberNewerResult() async {
        // Two overlapping refreshes whose git I/O resolves out of order: the
        // newer one completes first and commits its result, then the older
        // (superseded) one resolves and must NOT overwrite it.
        let git = StubGit()
        let older = ChangedFile(path: "older.swift", status: .modified)
        let newer = ChangedFile(path: "newer.swift", status: .modified)
        git.resultsPerChangedFilesCall = [[older], [newer]]
        git.gateChangedFiles = true
        let model = makeModel(git: git)

        // Start the older refresh (generation 1 / call 0) and wait until it has
        // reached the gate, so it has claimed its generation before the next.
        let first = Task { await model.refresh(root: root) }
        await waitForGatedCalls(1, in: git)

        // Start the newer refresh (generation 2 / call 1) and wait until it too
        // is gated.
        let second = Task { await model.refresh(root: root) }
        await waitForGatedCalls(2, in: git)

        // Resolve the newer refresh first: it is the latest, so it commits.
        git.release(call: 1)
        await second.value
        XCTAssertEqual(model.changedFiles, [newer])

        // Resolve the older (now stale) refresh: its result is discarded.
        git.release(call: 0)
        await first.value
        XCTAssertEqual(model.changedFiles, [newer])
    }

    func testStaleRefreshFailureDoesNotClobberNewerResult() async {
        // A superseded refresh that *fails* must not clear a newer refresh's
        // successfully published state via the catch path.
        let git = StubGit()
        let newer = ChangedFile(path: "newer.swift", status: .modified)
        git.resultsPerChangedFilesCall = [[], [newer]]
        git.gateChangedFiles = true
        let model = makeModel(git: git)

        // Older refresh (generation 1 / call 0) reaches the gate first.
        let first = Task { await model.refresh(root: root) }
        await waitForGatedCalls(1, in: git)

        // Newer refresh (generation 2 / call 1) reaches the gate and commits first.
        let second = Task { await model.refresh(root: root) }
        await waitForGatedCalls(2, in: git)
        git.release(call: 1)
        await second.value
        XCTAssertEqual(model.changedFiles, [newer])
        XCTAssertNil(model.errorMessage)

        // The older refresh now errors out, but being stale it must leave the
        // newer state intact (no clear, no errorMessage).
        git.error = StubError.boom
        git.release(call: 0)
        await first.value
        XCTAssertEqual(model.changedFiles, [newer])
        XCTAssertNil(model.errorMessage)
    }

    func testRefreshClearsStaleFilesUpFrontWhenOpenedFolderChanges() async {
        // Switching the opened folder must invalidate the previous project's
        // files immediately — before the new project's status resolves — so they
        // are not selectable/revertable during the await against the new repo.
        let git = StubGit()
        let a = ChangedFile(path: "a.swift", status: .modified)
        let b = ChangedFile(path: "b.swift", status: .added)
        let repoA = URL(fileURLWithPath: "/repoA")
        let repoB = URL(fileURLWithPath: "/repoB")
        git.repoRoot = repoA
        // call 0: initial refresh(A); call 1 (gated): refresh(B).
        git.resultsPerChangedFilesCall = [[a], [b]]
        let model = makeModel(git: git)
        await model.refresh(root: repoA)
        model.select(a)
        model.toggleChecked(a)
        XCTAssertEqual(model.changedFiles, [a])

        // Gate the next refresh so we can observe state mid-flight, then switch
        // the opened folder.
        git.gateChangedFiles = true
        git.repoRoot = repoB
        let task = Task { await model.refresh(root: repoB) }
        await waitForGatedCalls(1, in: git)

        // The new project's status has not resolved yet, but the stale repo-A
        // files, selection, and checks are already cleared.
        XCTAssertTrue(model.changedFiles.isEmpty)
        XCTAssertNil(model.selected)
        XCTAssertTrue(model.revertSelection.isEmpty)

        git.release(call: 1)
        await task.value
        XCTAssertEqual(model.changedFiles, [b])
        XCTAssertEqual(model.root, repoB)
    }

    func testInFlightRefreshDiscardedAfterFolderSwitchClearedState() async {
        // A refresh of repo A, suspended on its git I/O, must not republish A's
        // files after the opened folder switched to B. A folder switch bumps the
        // *request* generation (not the refresh generation), and
        // `prepareForFolderChange`/`refreshImpl` clear the previous project's files
        // up front — so a stale in-flight A refresh resolving afterward would make
        // them reappear (and stay actionable) throughout B's query. The commit-time
        // root-generation guard discards it.
        let git = StubGit()
        let a = ChangedFile(path: "a.swift", status: .modified)
        let b = ChangedFile(path: "b.swift", status: .added)
        let repoA = URL(fileURLWithPath: "/repoA")
        let repoB = URL(fileURLWithPath: "/repoB")
        git.repoRoot = repoA
        // call 0: initial refresh(A) committed; call 1: in-flight refresh(A)
        // (gated); call 2: refresh(B).
        git.resultsPerChangedFilesCall = [[a], [a], [b]]
        let model = makeModel(git: git)
        await model.refresh(root: repoA)
        XCTAssertEqual(model.changedFiles, [a])

        // A second refresh of A (e.g. a save-driven refresh) goes in flight and
        // suspends at its git I/O.
        git.gateChangedFiles = true
        let staleRefresh = Task { await model.refresh(root: repoA) }
        await waitForGatedCalls(1, in: git)

        // The opened folder switches to B synchronously (as the app does); the
        // previous project's files are cleared up front.
        git.repoRoot = repoB
        model.prepareForFolderChange(root: repoB)
        XCTAssertTrue(model.changedFiles.isEmpty)

        // The in-flight A refresh resolves now. Being stale (the folder switched
        // since it began), it must NOT republish A's files.
        git.release(call: 1)
        await staleRefresh.value
        XCTAssertTrue(model.changedFiles.isEmpty)

        // B's refresh then commits, uncontested.
        git.gateChangedFiles = false
        await model.refresh(root: repoB)
        XCTAssertEqual(model.root, repoB)
        XCTAssertEqual(model.changedFiles, [b])
    }

    // MARK: - selection

    func testSelectSetsSelectedFile() async {
        let git = StubGit()
        let file = ChangedFile(path: "a.swift", status: .modified)
        git.files = [file]
        let model = makeModel(git: git)
        await model.refresh(root: root)

        model.select(file)

        XCTAssertEqual(model.selected, file)
    }

    func testSelectIgnoresFileNotInChangedList() async {
        let git = StubGit()
        git.files = [ChangedFile(path: "a.swift", status: .modified)]
        let model = makeModel(git: git)
        await model.refresh(root: root)

        model.select(ChangedFile(path: "ghost.swift", status: .modified))

        XCTAssertNil(model.selected)
    }

    func testSelectNilClearsSelection() async {
        let git = StubGit()
        let file = ChangedFile(path: "a.swift", status: .modified)
        git.files = [file]
        let model = makeModel(git: git)
        await model.refresh(root: root)
        model.select(file)

        model.select(nil)

        XCTAssertNil(model.selected)
    }

    func testRefreshClearsSelectionWhenFileNoLongerChanged() async {
        let git = StubGit()
        let file = ChangedFile(path: "a.swift", status: .modified)
        git.files = [file]
        let model = makeModel(git: git)
        await model.refresh(root: root)
        model.select(file)

        git.files = [ChangedFile(path: "b.swift", status: .added)]
        await model.refresh(root: root)

        XCTAssertNil(model.selected)
    }

    func testRefreshResolvesRepositoryRootFromOpenedSubfolder() async {
        // Opening a subdirectory of a repo: the model stores the resolved repo
        // top level (not the opened folder), so working-copy paths line up with
        // the repo-root-relative git paths.
        let git = StubGit()
        git.repoRoot = URL(fileURLWithPath: "/repo")
        let file = ChangedFile(path: "Sources/a.swift", status: .modified)
        git.files = [file]
        git.headByPath["Sources/a.swift"] = "old\n"
        let files = StubFiles()
        files.contentsByPath["/repo/Sources/a.swift"] = "new\n"
        let model = makeModel(git: git, files: files)

        await model.refresh(root: URL(fileURLWithPath: "/repo/Sources"))

        XCTAssertEqual(model.root, URL(fileURLWithPath: "/repo"))
        let rows = await model.rows(for: file)
        XCTAssertEqual(rows, LineDiff.rows(old: "old\n", new: "new\n"))
    }

    func testRefreshRebindsSelectionToRefreshedStatus() async {
        // A selected file whose status changes between refreshes (deleted →
        // modified) must pick up the new status, or its diff would stay wrong
        // (a deleted file forces an empty working side).
        let git = StubGit()
        let deleted = ChangedFile(path: "a.swift", status: .deleted)
        git.files = [deleted]
        git.headByPath["a.swift"] = "old\n"
        let files = StubFiles()
        files.contentsByPath["/repo/a.swift"] = "restored\n"
        let model = makeModel(git: git, files: files)
        await model.refresh(root: root)
        model.select(deleted)

        // The file reappears as modified (it was restored and edited).
        let modified = ChangedFile(path: "a.swift", status: .modified)
        git.files = [modified]
        await model.refresh(root: root)

        XCTAssertEqual(model.selected?.status, .modified)
        // The working side is now read (not forced empty by the stale .deleted).
        let rows = await model.selectedRows()
        XCTAssertEqual(rows, LineDiff.rows(old: "old\n", new: "restored\n"))
    }

    func testRefreshKeepsSelectionWhenFileStillChanged() async {
        let git = StubGit()
        let file = ChangedFile(path: "a.swift", status: .modified)
        git.files = [file]
        let model = makeModel(git: git)
        await model.refresh(root: root)
        model.select(file)

        // A new refresh that still reports the file keeps the selection.
        git.files = [file, ChangedFile(path: "b.swift", status: .added)]
        await model.refresh(root: root)

        XCTAssertEqual(model.selected, file)
    }

    // MARK: - rows (diff)

    func testRowsForModifiedFileDiffsHeadAgainstWorking() async {
        let git = StubGit()
        let file = ChangedFile(path: "a.swift", status: .modified)
        git.files = [file]
        git.headByPath["a.swift"] = "line1\nline2\n"
        let files = StubFiles()
        files.contentsByPath["/repo/a.swift"] = "line1\nline2 changed\n"
        let model = makeModel(git: git, files: files)
        await model.refresh(root: root)

        let rows = await model.rows(for: file)
        XCTAssertEqual(
            rows,
            LineDiff.rows(old: "line1\nline2\n", new: "line1\nline2 changed\n")
        )
    }

    func testRowsForAddedFileHasEmptyHeadSide() async {
        let git = StubGit()
        let file = ChangedFile(path: "new.swift", status: .added)
        git.files = [file]
        // Even if HEAD content somehow exists, an added file's old side is empty.
        git.headByPath["new.swift"] = "should be ignored"
        let files = StubFiles()
        files.contentsByPath["/repo/new.swift"] = "a\nb\n"
        let model = makeModel(git: git, files: files)
        await model.refresh(root: root)

        let rows = await model.rows(for: file)
        XCTAssertEqual(rows, LineDiff.rows(old: "", new: "a\nb\n"))
        XCTAssertTrue(rows.allSatisfy { $0.left == nil })
    }

    func testRowsForUntrackedFileHasEmptyHeadSide() async {
        let git = StubGit()
        let file = ChangedFile(path: "scratch.txt", status: .untracked)
        git.files = [file]
        let files = StubFiles()
        files.contentsByPath["/repo/scratch.txt"] = "hello\n"
        let model = makeModel(git: git, files: files)
        await model.refresh(root: root)

        let rows = await model.rows(for: file)
        XCTAssertEqual(rows, LineDiff.rows(old: "", new: "hello\n"))
    }

    func testRowsForDeletedFileHasEmptyWorkingSide() async {
        let git = StubGit()
        let file = ChangedFile(path: "gone.swift", status: .deleted)
        git.files = [file]
        git.headByPath["gone.swift"] = "x\ny\n"
        let model = makeModel(git: git)
        await model.refresh(root: root)

        let rows = await model.rows(for: file)
        XCTAssertEqual(rows, LineDiff.rows(old: "x\ny\n", new: ""))
        XCTAssertTrue(rows.allSatisfy { $0.right == nil })
    }

    func testRowsForRenamedFileReadsHeadFromOldPath() async {
        let git = StubGit()
        let file = ChangedFile(path: "new/name.swift", status: .renamed, oldPath: "old/name.swift")
        git.files = [file]
        git.headByPath["old/name.swift"] = "content\n"
        let files = StubFiles()
        files.contentsByPath["/repo/new/name.swift"] = "content edited\n"
        let model = makeModel(git: git, files: files)
        await model.refresh(root: root)

        let rows = await model.rows(for: file)
        XCTAssertEqual(
            rows,
            LineDiff.rows(old: "content\n", new: "content edited\n")
        )
    }

    func testRowsForModifiedFileWithUnreadableHeadFallsBackToEmpty() async {
        // A modified file whose HEAD read fails should not crash; the old side
        // falls back to empty rather than throwing.
        let git = StubGit()
        let file = ChangedFile(path: "a.swift", status: .modified)
        git.files = [file]
        // No headByPath entry → headContents returns nil → empty old side.
        let files = StubFiles()
        files.contentsByPath["/repo/a.swift"] = "now\n"
        let model = makeModel(git: git, files: files)
        await model.refresh(root: root)

        let rows = await model.rows(for: file)
        XCTAssertEqual(rows, LineDiff.rows(old: "", new: "now\n"))
    }

    func testRowsForChangedSymlinkUsesTargetStringNotDereferencedContents() async {
        // Git stores a symlink's target string as its blob. The working side must
        // diff against that target, not the contents of the file it points to.
        let git = StubGit()
        let file = ChangedFile(path: "link", status: .modified)
        git.files = [file]
        git.headByPath["link"] = "/old/target\n"
        let files = StubFiles()
        files.symlinkTargetsByPath["/repo/link"] = "/new/target"
        // A dereferenced read would return this — it must be ignored.
        files.contentsByPath["/repo/link"] = "contents of the target file\n"
        let model = makeModel(git: git, files: files)
        await model.refresh(root: root)

        let rows = await model.rows(for: file)
        XCTAssertEqual(
            rows,
            LineDiff.rows(old: "/old/target\n", new: "/new/target")
        )
    }

    func testRowsWithoutRootIsEmpty() async {
        let git = StubGit()
        let model = makeModel(git: git)
        let rows = await model.rows(for: ChangedFile(path: "a.swift", status: .modified))
        XCTAssertEqual(rows, [])
    }

    func testSelectedRowsUsesSelectedFile() async {
        let git = StubGit()
        let file = ChangedFile(path: "a.swift", status: .modified)
        git.files = [file]
        git.headByPath["a.swift"] = "old\n"
        let files = StubFiles()
        files.contentsByPath["/repo/a.swift"] = "new\n"
        let model = makeModel(git: git, files: files)
        await model.refresh(root: root)
        model.select(file)

        let selectedRows = await model.selectedRows()
        let rows = await model.rows(for: file)
        XCTAssertEqual(selectedRows, rows)
        XCTAssertEqual(selectedRows, LineDiff.rows(old: "old\n", new: "new\n"))
    }

    func testSelectedRowsEmptyWhenNothingSelected() async {
        let git = StubGit()
        git.files = [ChangedFile(path: "a.swift", status: .modified)]
        let model = makeModel(git: git)
        await model.refresh(root: root)

        let rows = await model.selectedRows()
        XCTAssertEqual(rows, [])
    }

    // MARK: - revert

    func testToggleCheckedAddsThenRemovesId() async {
        let git = StubGit()
        let file = ChangedFile(path: "a.swift", status: .modified)
        git.files = [file]
        let model = makeModel(git: git)
        await model.refresh(root: root)

        model.toggleChecked(file)
        XCTAssertTrue(model.revertSelection.contains(file.id))

        model.toggleChecked(file)
        XCTAssertFalse(model.revertSelection.contains(file.id))
    }

    func testRefreshPrunesCheckOfFileNoLongerChanged() async {
        // A checked file that disappears from the changed list (committed away)
        // is dropped from the checkbox set, so if the *same path* later reappears
        // it starts unchecked rather than silently rejoining a destructive batch.
        let git = StubGit()
        let a = ChangedFile(path: "a.swift", status: .modified)
        let b = ChangedFile(path: "b.swift", status: .modified)
        git.files = [a, b]
        let model = makeModel(git: git)
        await model.refresh(root: root)
        model.toggleChecked(a)
        model.toggleChecked(b)

        // `a` is no longer changed on the next refresh.
        git.files = [b]
        await model.refresh(root: root)
        XCTAssertEqual(model.revertSelection, [b.id])

        // `a` reappears (modified again) — it must not be pre-checked.
        git.files = [a, b]
        await model.refresh(root: root)
        XCTAssertEqual(model.revertSelection, [b.id])
    }

    func testRefreshClearsChecksWhenRepositoryRootChanges() async {
        // Checking a path in one repo must not pre-check a same-relative-path file
        // in a different opened repository (path-equal ids there are unrelated).
        let git = StubGit()
        let a = ChangedFile(path: "src/a.swift", status: .modified)
        git.repoRoot = URL(fileURLWithPath: "/repo1")
        git.files = [a]
        let model = makeModel(git: git)
        await model.refresh(root: URL(fileURLWithPath: "/repo1"))
        model.toggleChecked(a)
        XCTAssertEqual(model.revertSelection, [a.id])

        // Open a different repository that also has a changed `src/a.swift`.
        git.repoRoot = URL(fileURLWithPath: "/repo2")
        await model.refresh(root: URL(fileURLWithPath: "/repo2"))
        XCTAssertTrue(model.revertSelection.isEmpty)
    }

    func testFailedRefreshClearsChecksSoTheyDoNotLeakAcrossRepositories() async {
        // A failed refresh must not preserve the checkbox set: it stores the
        // unresolved passed-in root, so a later successful refresh whose resolved
        // root equals it (a different repo opened at its top level) would intersect
        // rather than clear, carrying path-equal checks into an unrelated repo.
        let git = StubGit()
        let a = ChangedFile(path: "src/a.swift", status: .modified)
        git.repoRoot = URL(fileURLWithPath: "/repo1")
        git.files = [a]
        let model = makeModel(git: git)
        await model.refresh(root: URL(fileURLWithPath: "/repo1"))
        model.toggleChecked(a)
        XCTAssertEqual(model.revertSelection, [a.id])

        // Open `/repo2` at its top level, but its first refresh fails (e.g. git
        // transiently unavailable). The failure stores `root = /repo2`.
        git.error = StubError.boom
        await model.refresh(root: URL(fileURLWithPath: "/repo2"))
        XCTAssertTrue(model.revertSelection.isEmpty)

        // The next refresh of `/repo2` succeeds and also has a changed `src/a.swift`.
        // Because the failure already cleared the checks, the same-relative-path
        // file in the unrelated repo is not silently pre-checked.
        git.error = nil
        git.repoRoot = URL(fileURLWithPath: "/repo2")
        await model.refresh(root: URL(fileURLWithPath: "/repo2"))
        XCTAssertTrue(model.revertSelection.isEmpty)
    }

    func testFilesToRevertReturnsCheckedSetWhenContextFileChecked() async {
        let git = StubGit()
        let a = ChangedFile(path: "a.swift", status: .modified)
        let b = ChangedFile(path: "b.swift", status: .added)
        let c = ChangedFile(path: "c.swift", status: .deleted)
        git.files = [a, b, c]
        let model = makeModel(git: git)
        await model.refresh(root: root)

        model.toggleChecked(a)
        model.toggleChecked(c)

        // Context file is checked → all checked files (current changed files).
        XCTAssertEqual(model.filesToRevert(contextFile: a), [a, c])
    }

    func testFilesToRevertReturnsJustContextFileWhenUnchecked() async {
        let git = StubGit()
        let a = ChangedFile(path: "a.swift", status: .modified)
        let b = ChangedFile(path: "b.swift", status: .added)
        git.files = [a, b]
        let model = makeModel(git: git)
        await model.refresh(root: root)

        // b is checked, but the action is triggered from a (unchecked).
        model.toggleChecked(b)

        XCTAssertEqual(model.filesToRevert(contextFile: a), [a])
    }

    // MARK: - revert gate (isReverting)

    func testRevertGateRaisesAndClearsWithReentrantBalance() {
        let model = makeModel(git: StubGit())
        XCTAssertFalse(model.isReverting)

        // Two overlapping reverts each raise the gate; it stays raised until both
        // balance their end (a boolean would clear on the first end).
        model.beginRevert()
        XCTAssertTrue(model.isReverting)
        model.beginRevert()
        XCTAssertTrue(model.isReverting)

        model.endRevert()
        XCTAssertTrue(model.isReverting)
        model.endRevert()
        XCTAssertFalse(model.isReverting)
    }

    func testRevertGateEndIsClampedAtZero() {
        let model = makeModel(git: StubGit())
        // An unbalanced extra end must not drive the counter negative and wedge a
        // later begin into needing two ends to clear.
        model.endRevert()
        XCTAssertFalse(model.isReverting)
        model.beginRevert()
        XCTAssertTrue(model.isReverting)
        model.endRevert()
        XCTAssertFalse(model.isReverting)
    }

    func testRevertCallsGitPerFileRefreshesClearsSelectionAndReturnsURLs() async {
        let git = StubGit()
        let a = ChangedFile(path: "a.swift", status: .modified)
        let b = ChangedFile(path: "src/b.swift", status: .added)
        git.files = [a, b]
        let model = makeModel(git: git)
        await model.refresh(root: root)
        model.toggleChecked(a)
        model.toggleChecked(b)

        // The stub drops each reverted file, so after the batch git reports no
        // remaining changes (matching the real on-disk effect).
        let urls = await model.revert([a, b])

        XCTAssertEqual(git.revertedFiles, [a, b])
        XCTAssertEqual(urls, [
            root.appendingPathComponent("a.swift"),
            root.appendingPathComponent("src/b.swift"),
        ])
        XCTAssertTrue(model.changedFiles.isEmpty)
        XCTAssertTrue(model.revertSelection.isEmpty)
        XCTAssertNil(model.errorMessage)
    }

    func testRevertSuccessPreservesAFileCheckedDuringTheTrailingRefresh() async {
        // The success path must not wipe the whole checked set: the main actor
        // processes UI events during the revert's awaits, so the user can check
        // another changed file in that window. Only the files this batch reverted
        // should be dropped from the checked set — a fresh check on an unrelated
        // file survives.
        let git = StubGit()
        let a = ChangedFile(path: "a.swift", status: .modified)
        let x = ChangedFile(path: "x.swift", status: .modified)
        git.files = [a, x]
        let model = makeModel(git: git)
        await model.refresh(root: root)
        model.toggleChecked(a)

        // Simulate the user checking `x` during the revert (after `a` is reverted,
        // before the trailing refresh reconciles/clears the checked set).
        git.onRevert = { [weak model] in
            model?.toggleChecked(x)
        }

        let urls = await model.revert([a])

        XCTAssertEqual(git.revertedFiles, [a])
        XCTAssertEqual(urls, [root.appendingPathComponent("a.swift")])
        // `a` was reverted and dropped; `x`'s fresh check is preserved (a bare
        // `revertSelection = []` would have erased it).
        XCTAssertEqual(model.revertSelection, [x.id])
    }

    func testRevertUntrackedFileRoutesThroughGitService() async {
        let git = StubGit()
        let scratch = ChangedFile(path: "scratch.txt", status: .untracked)
        git.files = [scratch]
        let model = makeModel(git: git)
        await model.refresh(root: root)

        let urls = await model.revert([scratch])

        XCTAssertEqual(git.revertedFiles, [scratch])
        XCTAssertEqual(urls, [root.appendingPathComponent("scratch.txt")])
        XCTAssertTrue(model.changedFiles.isEmpty)
    }

    func testRevertErrorSetsMessageAndDoesNotCrash() async {
        let git = StubGit()
        let a = ChangedFile(path: "a.swift", status: .modified)
        git.files = [a]
        let model = makeModel(git: git)
        await model.refresh(root: root)
        git.revertError = StubError.boom

        let urls = await model.revert([a])

        XCTAssertTrue(urls.isEmpty)
        XCTAssertNotNil(model.errorMessage)
        // The file is still listed (the failed revert left it in place).
        XCTAssertEqual(model.changedFiles, [a])
    }

    func testRevertStopsAtFirstFailureDroppingRevertedFromCheckedSet() async {
        // A batch where the second file fails: the first is reverted, the failure
        // sets a message and stops. The already-reverted file is dropped from the
        // checked set so a retry does not re-attempt it (which would fail
        // immediately on the now-gone file and mask the one that actually failed);
        // the failing and not-yet-attempted files stay checked for the retry, and
        // the failure message is preserved across the refresh.
        let git = StubGit()
        let a = ChangedFile(path: "a.swift", status: .modified)
        let b = ChangedFile(path: "b.swift", status: .modified)
        let c = ChangedFile(path: "c.swift", status: .modified)
        git.files = [a, b, c]
        let model = makeModel(git: git)
        await model.refresh(root: root)
        model.toggleChecked(a)
        model.toggleChecked(b)
        model.toggleChecked(c)
        git.revertFailPath = "b.swift"

        let urls = await model.revert([a, b, c])

        // Only the prefix before the failure was reverted and returned.
        XCTAssertEqual(git.revertedFiles, [a])
        XCTAssertEqual(urls, [root.appendingPathComponent("a.swift")])
        XCTAssertNotNil(model.errorMessage)
        // The reverted file is dropped from the checked set; the failing and
        // untouched files stay checked for a retry.
        XCTAssertEqual(model.revertSelection, [b.id, c.id])
    }

    func testRevertRenamedFileReturnsBothNewAndRestoredOldPath() async {
        // A rename revert deletes the new path and restores the old one, so both
        // URLs must come back for the app to resync tabs at either path.
        let git = StubGit()
        let renamed = ChangedFile(path: "new/name.swift", status: .renamed, oldPath: "old/name.swift")
        git.files = [renamed]
        let model = makeModel(git: git)
        await model.refresh(root: root)

        let urls = await model.revert([renamed])

        XCTAssertEqual(urls, [
            root.appendingPathComponent("new/name.swift"),
            root.appendingPathComponent("old/name.swift"),
        ])
    }

    func testRevertPlainFailureReportsNoChangedPaths() async {
        // A failure that does not conform to `PartialRevertError` changed nothing
        // on disk (single-command reverts are atomic; a rename that fails on its
        // first step never restored the old path). The model must report no URLs
        // so the app does not reload/close a tab the revert never touched — which
        // would discard unsaved edits there.
        let git = StubGit()
        let renamed = ChangedFile(path: "new/name.swift", status: .renamed, oldPath: "old/name.swift")
        git.files = [renamed]
        let model = makeModel(git: git)
        await model.refresh(root: root)
        git.revertFailPath = "new/name.swift"

        let urls = await model.revert([renamed])

        XCTAssertTrue(urls.isEmpty)
        XCTAssertNotNil(model.errorMessage)
    }

    func testRevertPartialFailureReportsOnlyServiceReportedPaths() async {
        // A rename revert that fails *after* restoring the old path reports that
        // one path via `PartialRevertError`. The model resyncs exactly the paths
        // the service says it changed — here the restored old path, but not the
        // new path (whose on-disk contents the revert never reached).
        let git = StubGit()
        let renamed = ChangedFile(path: "new/name.swift", status: .renamed, oldPath: "old/name.swift")
        git.files = [renamed]
        let model = makeModel(git: git)
        await model.refresh(root: root)
        git.revertError = StubPartialRevert(changedPaths: ["old/name.swift"])

        let urls = await model.revert([renamed])

        XCTAssertEqual(urls, [root.appendingPathComponent("old/name.swift")])
        XCTAssertNotNil(model.errorMessage)
    }

    func testRevertAccumulatesSuccessfulPrefixURLsWithPartialFailurePaths() async {
        // A multi-file batch where an earlier file reverts cleanly (contributing
        // its own URL) and a later file fails *after* changing one path on disk
        // (reported via `PartialRevertError`). The returned URLs must combine both:
        // the successfully reverted prefix file *and* the partially-changed path of
        // the failing file, so the app resyncs every tab the revert actually
        // touched — not just one or the other.
        let git = StubGit()
        let a = ChangedFile(path: "a.swift", status: .modified)
        let renamed = ChangedFile(path: "new/name.swift", status: .renamed, oldPath: "old/name.swift")
        git.files = [a, renamed]
        let model = makeModel(git: git)
        await model.refresh(root: root)
        model.toggleChecked(a)
        model.toggleChecked(renamed)
        git.revertFailPath = "new/name.swift"
        git.revertFailError = StubPartialRevert(changedPaths: ["old/name.swift"])

        let urls = await model.revert([a, renamed])

        // The clean prefix file's URL, then the failing file's partially-changed
        // path — accumulated across the success and the partial-failure branches.
        XCTAssertEqual(urls, [
            root.appendingPathComponent("a.swift"),
            root.appendingPathComponent("old/name.swift"),
        ])
        XCTAssertNotNil(model.errorMessage)
        // The cleanly reverted file is dropped from the checked set; the failing
        // file stays checked for a retry.
        XCTAssertEqual(model.revertSelection, [renamed.id])
    }

    func testFilesToRevertExcludesCheckedFileNoLongerChanged() async {
        // When a checked file leaves `changedFiles`, `refresh` prunes its id from
        // the checkbox set (so it cannot reappear pre-checked) and `filesToRevert`
        // resolves only against the current list.
        let git = StubGit()
        let a = ChangedFile(path: "a.swift", status: .modified)
        let b = ChangedFile(path: "b.swift", status: .modified)
        git.files = [a, b]
        let model = makeModel(git: git)
        await model.refresh(root: root)
        model.toggleChecked(a)
        model.toggleChecked(b)

        // b disappears from the changed list; the refresh drops its check.
        git.files = [a]
        await model.refresh(root: root)
        XCTAssertFalse(model.revertSelection.contains(b.id))

        // Reverting from a (checked) resolves to only the still-changed files.
        XCTAssertEqual(model.filesToRevert(contextFile: a), [a])
    }

    func testRevertWithoutRootIsNoOp() async {
        let git = StubGit()
        let model = makeModel(git: git)
        let urls = await model.revert([ChangedFile(path: "a.swift", status: .modified)])
        XCTAssertTrue(urls.isEmpty)
        XCTAssertTrue(git.revertedFiles.isEmpty)
    }

    func testRevertAbortsWhenFileStatusChangedSinceRefresh() async {
        // The snapshot shows an untracked file, but by revert time it has become
        // tracked and modified (committed + edited out of band). Deleting it as
        // "untracked" would discard the new content, so the model re-queries
        // before mutating, sees the status changed, and aborts without calling
        // the destructive revert.
        let git = StubGit()
        let stale = ChangedFile(path: "foo.txt", status: .untracked)
        git.files = [stale]
        let model = makeModel(git: git)
        await model.refresh(root: root)

        // Out of band: foo.txt is now tracked and modified.
        git.files = [ChangedFile(path: "foo.txt", status: .modified)]
        let urls = await model.revert([stale])

        XCTAssertTrue(urls.isEmpty)
        XCTAssertTrue(git.revertedFiles.isEmpty)
        XCTAssertNotNil(model.errorMessage)
    }

    func testRevertAbortsWhenFileVanishedSinceRefresh() async {
        // The file is gone from a fresh query (e.g. reverted/committed out of
        // band). The model must not attempt to revert a path that is no longer
        // changed.
        let git = StubGit()
        let stale = ChangedFile(path: "foo.txt", status: .modified)
        git.files = [stale]
        let model = makeModel(git: git)
        await model.refresh(root: root)

        git.files = []
        let urls = await model.revert([stale])

        XCTAssertTrue(urls.isEmpty)
        XCTAssertTrue(git.revertedFiles.isEmpty)
        XCTAssertNotNil(model.errorMessage)
    }

    func testRevertAbortsWhenStatusReQueryFails() async {
        // The pre-revert re-query fails (e.g. git became unavailable). With no
        // trustworthy current state, the model surfaces the error and mutates
        // nothing.
        let git = StubGit()
        let a = ChangedFile(path: "a.swift", status: .modified)
        git.files = [a]
        let model = makeModel(git: git)
        await model.refresh(root: root)

        git.error = StubError.boom
        let urls = await model.revert([a])

        XCTAssertTrue(urls.isEmpty)
        XCTAssertTrue(git.revertedFiles.isEmpty)
        XCTAssertNotNil(model.errorMessage)
    }

    func testRevertRevertsValidPrefixThenAbortsOnStaleFile() async {
        // A batch where the second file has gone stale: the first is reverted and
        // returned, the stale one aborts the batch. The reverted file is dropped
        // from the checked set while the stale one stays checked, so a retry runs
        // against the refreshed state.
        let git = StubGit()
        let a = ChangedFile(path: "a.swift", status: .modified)
        let b = ChangedFile(path: "b.txt", status: .untracked)
        git.files = [a, b]
        let model = makeModel(git: git)
        await model.refresh(root: root)
        model.toggleChecked(a)
        model.toggleChecked(b)

        // b becomes tracked + modified out of band before the revert runs.
        git.files = [a, ChangedFile(path: "b.txt", status: .modified)]
        let urls = await model.revert([a, b])

        XCTAssertEqual(git.revertedFiles, [a])
        XCTAssertEqual(urls, [root.appendingPathComponent("a.swift")])
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.revertSelection, [b.id])
    }

    func testRevertReQueriesPerFileCatchingLaterFileChangedDuringBatch() async {
        // The re-query runs before *each* file, not once before the loop: a later
        // file can change out of band *while the earlier files are being reverted*.
        // Here `b` (untracked) becomes tracked + modified the moment `a` is
        // reverted — a single up-front snapshot would still see `b` as untracked
        // and delete it (discarding the new content); the per-file re-query sees
        // the flip and aborts before touching `b`.
        let git = StubGit()
        let a = ChangedFile(path: "a.swift", status: .modified)
        let b = ChangedFile(path: "b.txt", status: .untracked)
        git.files = [a, b]
        let model = makeModel(git: git)
        await model.refresh(root: root)
        model.toggleChecked(a)
        model.toggleChecked(b)

        // Reverting `a` flips `b` to tracked + modified (out of band, mid-batch).
        git.onRevert = { [weak git] in
            guard let git, git.files.contains(where: { $0.id == b.id }) else { return }
            git.files = git.files.map { $0.id == b.id ? ChangedFile(path: "b.txt", status: .modified) : $0 }
        }

        let urls = await model.revert([a, b])

        // Only `a` was reverted; the batch aborted on `b`'s changed status rather
        // than deleting the now-tracked file.
        XCTAssertEqual(git.revertedFiles, [a])
        XCTAssertEqual(urls, [root.appendingPathComponent("a.swift")])
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.revertSelection, [b.id])
    }

    func testRevertDoesNotClobberNewerRepositoryWhenRootSwitchesMidRevert() async {
        // The opened project switches mid-revert (a folder change commits a new
        // root while the revert is suspended on its pre-mutation re-query). The
        // revert must detect the switch, stop before mutating, and leave the new
        // repository's freshly published state intact — rather than reverting a
        // file in the old repo or re-publishing the old repo via its trailing
        // refresh.
        let git = StubGit()
        let a = ChangedFile(path: "a.swift", status: .modified)
        let b = ChangedFile(path: "b.swift", status: .added)
        let repoA = URL(fileURLWithPath: "/repoA")
        let repoB = URL(fileURLWithPath: "/repoB")
        git.repoRoot = repoA
        // call 0: initial refresh(A); call 1: revert's re-query (A); call 2: refresh(B).
        git.resultsPerChangedFilesCall = [[a], [a], [b]]
        let model = makeModel(git: git)
        await model.refresh(root: repoA)
        XCTAssertEqual(model.root, repoA)

        git.gateChangedFiles = true

        // Start the revert; it suspends at its pre-mutation re-query (call 1).
        let revertTask = Task { await model.revert([a]) }
        await waitForGatedCalls(1, in: git)

        // The user opens repo B mid-revert; its refresh resolves and commits first.
        git.repoRoot = repoB
        let refreshTask = Task { await model.refresh(root: repoB) }
        await waitForGatedCalls(2, in: git)
        git.release(call: 2)
        await refreshTask.value
        XCTAssertEqual(model.root, repoB)
        XCTAssertEqual(model.changedFiles, [b])

        // Now let the revert's re-query resolve: it must see the root switch and
        // bail without reverting anything or clobbering repo B's published state.
        git.release(call: 1)
        let reverted = await revertTask.value

        XCTAssertTrue(git.revertedFiles.isEmpty)
        XCTAssertTrue(reverted.isEmpty)
        XCTAssertEqual(model.root, repoB)
        XCTAssertEqual(model.changedFiles, [b])
        XCTAssertNil(model.errorMessage)
    }

    func testRevertDetectsRootSwitchWhileNewRefreshStillInFlight() async {
        // The harder ordering the `self.root`-based guard missed: the revert's
        // re-query resolves *before* the new project's refresh commits. `refresh(B)`
        // records the switch and clears state synchronously at entry, but leaves
        // `self.root == A` until its own git I/O resolves. A guard keyed off
        // `self.root` would therefore still see A and let the revert mutate the
        // *old* repo and re-publish it over B. The request-generation guard, bumped
        // synchronously at refresh entry, must catch the switch in this window too.
        let git = StubGit()
        let a = ChangedFile(path: "a.swift", status: .modified)
        let b = ChangedFile(path: "b.swift", status: .added)
        let repoA = URL(fileURLWithPath: "/repoA")
        let repoB = URL(fileURLWithPath: "/repoB")
        git.repoRoot = repoA
        // call 0: initial refresh(A); call 1: revert's re-query (A); call 2: refresh(B).
        git.resultsPerChangedFilesCall = [[a], [a], [b]]
        let model = makeModel(git: git)
        await model.refresh(root: repoA)
        XCTAssertEqual(model.root, repoA)

        git.gateChangedFiles = true

        // Start the revert; it suspends at its pre-mutation re-query (call 1).
        let revertTask = Task { await model.revert([a]) }
        await waitForGatedCalls(1, in: git)

        // The user opens repo B; its refresh reaches the gate (call 2) but stays
        // suspended — so it has bumped the request generation and cleared state,
        // but `self.root` is still repoA (not yet committed).
        git.repoRoot = repoB
        let refreshTask = Task { await model.refresh(root: repoB) }
        await waitForGatedCalls(2, in: git)
        XCTAssertEqual(model.root, repoA)

        // Release the revert's re-query *first*, while refresh(B) is still in flight
        // (self.root == repoA). The revert must still detect the switch via the
        // request generation and bail without mutating the old repo.
        git.release(call: 1)
        let reverted = await revertTask.value
        XCTAssertTrue(git.revertedFiles.isEmpty)
        XCTAssertTrue(reverted.isEmpty)

        // Now let refresh(B) commit; it owns the published state, uncontested.
        git.release(call: 2)
        await refreshTask.value
        XCTAssertEqual(model.root, repoB)
        XCTAssertEqual(model.changedFiles, [b])
        XCTAssertNil(model.errorMessage)
    }

    func testRevertBailsWhenStartedDuringInFlightFolderSwitch() async {
        // A revert that *starts* after `refresh(B)` bumped the request generation
        // but before it committed `self.root = B`: `self.root` is still repoA while
        // the request generation already advanced. Capturing the new generation
        // next to the stale root would make every `projectStillCurrent` check pass,
        // letting the revert mutate repoA. The revert must instead detect (via the
        // published-root generation lagging the request generation) that a switch
        // is pending and bail without touching the old repository.
        let git = StubGit()
        let a = ChangedFile(path: "a.swift", status: .modified)
        let b = ChangedFile(path: "b.swift", status: .added)
        let repoA = URL(fileURLWithPath: "/repoA")
        let repoB = URL(fileURLWithPath: "/repoB")
        git.repoRoot = repoA
        // call 0: initial refresh(A); call 1: refresh(B).
        git.resultsPerChangedFilesCall = [[a], [b]]
        let model = makeModel(git: git)
        await model.refresh(root: repoA)
        XCTAssertEqual(model.root, repoA)

        git.gateChangedFiles = true
        git.repoRoot = repoB
        // refresh(B) bumps the request generation and clears state synchronously,
        // then suspends at its changedFiles gate — `self.root` is still repoA.
        let refreshTask = Task { await model.refresh(root: repoB) }
        await waitForGatedCalls(1, in: git)
        XCTAssertEqual(model.root, repoA)

        // A revert that starts in this window must bail synchronously, without
        // re-querying or mutating the old repository.
        let reverted = await model.revert([a])
        XCTAssertTrue(reverted.isEmpty)
        XCTAssertTrue(git.revertedFiles.isEmpty)

        // refresh(B) then completes and owns the published state, uncontested.
        git.release(call: 1)
        await refreshTask.value
        XCTAssertEqual(model.root, repoB)
        XCTAssertEqual(model.changedFiles, [b])
        XCTAssertNil(model.errorMessage)
    }

    func testStaleRevertErrorDoesNotClobberNewerRefreshSuccess() async {
        // Same-project overlap: an older revert fails (down its abort path, which
        // awaits an internal refresh before writing `errorMessage`), but while it
        // is suspended on that internal refresh a *newer* manual refresh resolves
        // and publishes a clean result (no error). The older revert must then drop
        // its stale message rather than restore it over the newer success — the
        // `operationGeneration` guard, not just the folder guard.
        let git = StubGit()
        let untracked = ChangedFile(path: "a.txt", status: .untracked)
        let modified = ChangedFile(path: "a.txt", status: .modified)
        let fresh = ChangedFile(path: "fresh.swift", status: .modified)
        // call 0: initial refresh; call 1: revert's pre-mutation re-query (flips a
        // to modified → abort); call 2: revert's trailing refresh (gated); call 3:
        // the newer refresh (gated).
        git.resultsPerChangedFilesCall = [[untracked], [modified], [modified], [fresh]]
        let model = makeModel(git: git)
        await model.refresh(root: root)

        git.gateChangedFiles = true

        // Start the revert; it suspends at its pre-mutation re-query (call 1).
        let revertTask = Task { await model.revert([untracked]) }
        await waitForGatedCalls(1, in: git)
        // Release the re-query: it returns `modified`, so `guardRevert` aborts and
        // the revert enters its trailing refresh (call 2), where it gates.
        git.release(call: 1)
        await waitForGatedCalls(2, in: git)

        // The user triggers a newer refresh (call 3) — it resolves and commits its
        // clean result first.
        let refreshTask = Task { await model.refresh(root: root) }
        await waitForGatedCalls(3, in: git)
        git.release(call: 3)
        await refreshTask.value
        XCTAssertEqual(model.changedFiles, [fresh])
        XCTAssertNil(model.errorMessage)

        // Now release the older revert's stale trailing refresh. It is superseded,
        // so it must neither re-publish its list nor restore its error message.
        git.release(call: 2)
        let reverted = await revertTask.value

        XCTAssertTrue(reverted.isEmpty)
        XCTAssertTrue(git.revertedFiles.isEmpty)
        XCTAssertEqual(model.changedFiles, [fresh])
        XCTAssertNil(model.errorMessage)
    }

    func testPrepareForFolderChangeBumpsGuardSoSuspendedRevertBails() async {
        // The app records a folder switch synchronously (before the `Task`-wrapped
        // refresh) via `prepareForFolderChange`. A revert already suspended on its
        // off-main git I/O must observe that switch the moment it resumes — exactly
        // as it would for a switch recorded at `refresh` entry — and bail without
        // mutating the previous repository or re-publishing it.
        let git = StubGit()
        let a = ChangedFile(path: "a.swift", status: .modified)
        let b = ChangedFile(path: "b.swift", status: .added)
        let repoA = URL(fileURLWithPath: "/repoA")
        let repoB = URL(fileURLWithPath: "/repoB")
        git.repoRoot = repoA
        // call 0: initial refresh(A); call 1: revert's re-query (A); call 2: refresh(B).
        git.resultsPerChangedFilesCall = [[a], [a], [b]]
        let model = makeModel(git: git)
        await model.refresh(root: repoA)
        XCTAssertEqual(model.root, repoA)

        git.gateChangedFiles = true

        // Start the revert; it suspends at its pre-mutation re-query (call 1).
        let revertTask = Task { await model.revert([a]) }
        await waitForGatedCalls(1, in: git)

        // The app handles a folder-open: it records the switch *synchronously*
        // (mirroring `PisakaApp.openFolder`) and only then launches the async
        // refresh. The synchronous record alone must already invalidate the
        // in-flight revert.
        git.repoRoot = repoB
        model.prepareForFolderChange(root: repoB)
        XCTAssertTrue(model.changedFiles.isEmpty)
        let refreshTask = Task { await model.refresh(root: repoB) }

        // Release the revert's re-query: even though the refresh's own git I/O has
        // not resolved yet, the synchronous `prepareForFolderChange` already bumped
        // the request generation, so the revert detects the switch and bails.
        git.release(call: 1)
        let reverted = await revertTask.value
        XCTAssertTrue(reverted.isEmpty)
        XCTAssertTrue(git.revertedFiles.isEmpty)

        // refresh(B) commits, uncontested, and is not double-cleared.
        await waitForGatedCalls(2, in: git)
        git.release(call: 2)
        await refreshTask.value
        XCTAssertEqual(model.root, repoB)
        XCTAssertEqual(model.changedFiles, [b])
        XCTAssertNil(model.errorMessage)
    }

    func testSupersededFolderRefreshTaskIsRejected() async {
        // Two folders opened in rapid succession (B then C), each pre-registered
        // synchronously via `prepareForFolderChange` before its `Task`-wrapped
        // refresh. Unstructured tasks are not guaranteed to start in creation
        // order, so B's older refresh task can execute *after* C's. Passing the
        // request generation captured at pre-registration lets the model reject
        // the obsolete B refresh, so it does not rewrite the panel back to repo B
        // while the workspace shows repo C.
        let git = StubGit()
        let cFiles = [ChangedFile(path: "c.swift", status: .modified)]
        let bFiles = [ChangedFile(path: "b.swift", status: .added)]
        let repoB = URL(fileURLWithPath: "/repoB")
        let repoC = URL(fileURLWithPath: "/repoC")
        let model = makeModel(git: git)

        // Both synchronous pre-registrations run first (rapid double folder-open).
        let genB = model.prepareForFolderChange(root: repoB)
        let genC = model.prepareForFolderChange(root: repoC)
        XCTAssertNotEqual(genB, genC)

        // The newer folder (C) refresh runs and commits.
        git.repoRoot = repoC
        git.files = cFiles
        await model.refresh(root: repoC, requestGeneration: genC)
        XCTAssertEqual(model.root, repoC)
        XCTAssertEqual(model.changedFiles, cFiles)

        // The older folder (B) refresh — created first but executing last — must
        // be rejected as obsolete instead of rewriting the panel to repo B.
        git.repoRoot = repoB
        git.files = bFiles
        await model.refresh(root: repoB, requestGeneration: genB)
        XCTAssertEqual(model.root, repoC)
        XCTAssertEqual(model.changedFiles, cFiles)
    }

    func testRevertQueuedAgainstReplacedRepositoryIsRejected() async {
        // A revert is confirmed against repository A, but the folder is switched
        // to B (and B's refresh fully commits) before the queued revert task
        // starts running. Without pinning the originating project, the revert
        // would read its root/generation from B at entry — and a path-equal file
        // with a matching status would pass `guardRevert` and be destructively
        // reverted in B. Capturing the origin generation synchronously (as the app
        // does before the `Task` hop) lets the revert detect the switch and bail.
        let git = StubGit()
        let a = ChangedFile(path: "a.swift", status: .modified)
        let repoA = URL(fileURLWithPath: "/repoA")
        let repoB = URL(fileURLWithPath: "/repoB")
        git.repoRoot = repoA
        git.files = [a]
        let model = makeModel(git: git)
        await model.refresh(root: repoA)
        XCTAssertEqual(model.root, repoA)

        // The app captures the displayed project's generation synchronously, before
        // spawning the revert task.
        let origin = model.currentRequestGeneration

        // Folder B fully replaces A — and B happens to have a path-equal, same-status
        // file that would otherwise pass the per-file revert guard.
        git.repoRoot = repoB
        git.files = [ChangedFile(path: "a.swift", status: .modified)]
        model.prepareForFolderChange(root: repoB)
        await model.refresh(root: repoB)
        XCTAssertEqual(model.root, repoB)

        // The revert queued against A must be rejected, not mutate repo B.
        let reverted = await model.revert([a], originGeneration: origin)
        XCTAssertTrue(reverted.isEmpty)
        XCTAssertTrue(git.revertedFiles.isEmpty)
        XCTAssertEqual(model.root, repoB)
    }

    func testRevertInSubfolderRepoKeepsSelectionViaTrailingRefresh() async {
        // Opening a subfolder: the resolved repo root (/repo) differs from the
        // requested folder (/repo/sub). The revert's trailing refresh must run
        // against the *requested* folder, not the resolved root — otherwise it
        // looks like a folder switch to `refresh`, spuriously clearing the
        // selection (and bumping the request generation).
        let git = StubGit()
        let sub = URL(fileURLWithPath: "/repo/sub")
        git.repoRoot = URL(fileURLWithPath: "/repo")
        let a = ChangedFile(path: "a.swift", status: .modified)
        let b = ChangedFile(path: "b.swift", status: .modified)
        git.files = [a, b]
        let model = makeModel(git: git)
        await model.refresh(root: sub)
        model.select(b)

        // Revert a (b stays changed); the trailing refresh keeps b selected.
        _ = await model.revert([a])

        XCTAssertEqual(git.revertedFiles, [a])
        XCTAssertEqual(model.root, URL(fileURLWithPath: "/repo"))
        XCTAssertEqual(model.changedFiles, [b])
        XCTAssertEqual(model.selected, b)
        XCTAssertNil(model.errorMessage)
    }

    // MARK: - pure helpers: reconcile

    func testReconcileClearsCheckSetWhenRootChanges() async {
        // Switching repositories: path-equal ids in two repos are unrelated, so
        // the checkbox set is cleared regardless of overlap in the new list.
        let a = ChangedFile(path: "src/a.swift", status: .modified)
        let result = LocalChangesModel.reconcile(
            previousRoot: URL(fileURLWithPath: "/repo1"),
            newRoot: URL(fileURLWithPath: "/repo2"),
            files: [a],
            selected: nil,
            revertSelection: [a.id]
        )

        XCTAssertTrue(result.revertSelection.isEmpty)
    }

    func testReconcileIntersectsCheckSetWhenRootUnchanged() async {
        // Same root: the checkbox set is intersected with the current ids,
        // dropping any file no longer changed and keeping the rest.
        let a = ChangedFile(path: "a.swift", status: .modified)
        let b = ChangedFile(path: "b.swift", status: .modified)
        let result = LocalChangesModel.reconcile(
            previousRoot: root,
            newRoot: root,
            files: [b],
            selected: nil,
            revertSelection: [a.id, b.id]
        )

        XCTAssertEqual(result.revertSelection, [b.id])
    }

    func testReconcileIntersectsWhenPreviousRootWasNil() async {
        // First successful refresh (no previous root): nil != newRoot, so the
        // checkbox set is cleared. (It is empty at that point anyway.)
        let result = LocalChangesModel.reconcile(
            previousRoot: nil,
            newRoot: root,
            files: [ChangedFile(path: "a.swift", status: .modified)],
            selected: nil,
            revertSelection: []
        )

        XCTAssertTrue(result.revertSelection.isEmpty)
    }

    func testReconcileRebindsSelectionToRefreshedFile() async {
        // The selection is re-bound to its refreshed `ChangedFile`, picking up a
        // new status (deleted → modified) at the same id.
        let deleted = ChangedFile(path: "a.swift", status: .deleted)
        let modified = ChangedFile(path: "a.swift", status: .modified)
        let result = LocalChangesModel.reconcile(
            previousRoot: root,
            newRoot: root,
            files: [modified],
            selected: deleted,
            revertSelection: []
        )

        XCTAssertEqual(result.selected, modified)
    }

    func testReconcileClearsSelectionWhenFileGone() async {
        let selected = ChangedFile(path: "a.swift", status: .modified)
        let result = LocalChangesModel.reconcile(
            previousRoot: root,
            newRoot: root,
            files: [ChangedFile(path: "b.swift", status: .added)],
            selected: selected,
            revertSelection: []
        )

        XCTAssertNil(result.selected)
    }

    func testReconcileNilSelectionStaysNil() async {
        let result = LocalChangesModel.reconcile(
            previousRoot: root,
            newRoot: root,
            files: [ChangedFile(path: "a.swift", status: .modified)],
            selected: nil,
            revertSelection: []
        )

        XCTAssertNil(result.selected)
    }

    // MARK: - pure helpers: guardRevert

    func testGuardRevertProceedsWhenStatusAndOldPathMatch() async {
        let file = ChangedFile(path: "new.swift", status: .renamed, oldPath: "old.swift")
        XCTAssertEqual(LocalChangesModel.guardRevert(file: file, current: file), .proceed)
    }

    func testGuardRevertAbortsWhenFileVanished() async {
        let file = ChangedFile(path: "a.swift", status: .modified)
        guard case .abort = LocalChangesModel.guardRevert(file: file, current: nil) else {
            return XCTFail("expected abort for a vanished file")
        }
    }

    func testGuardRevertAbortsWhenStatusChanged() async {
        let file = ChangedFile(path: "foo.txt", status: .untracked)
        let current = ChangedFile(path: "foo.txt", status: .modified)
        guard case .abort = LocalChangesModel.guardRevert(file: file, current: current) else {
            return XCTFail("expected abort when status flipped")
        }
    }

    func testGuardRevertAbortsWhenOldPathChanged() async {
        let file = ChangedFile(path: "new.swift", status: .renamed, oldPath: "old.swift")
        let current = ChangedFile(path: "new.swift", status: .renamed, oldPath: "other.swift")
        guard case .abort = LocalChangesModel.guardRevert(file: file, current: current) else {
            return XCTFail("expected abort when oldPath differs")
        }
    }

    func testGuardRevertAbortReasonNamesThePath() async {
        let file = ChangedFile(path: "weird path.txt", status: .modified)
        guard case .abort(let reason) = LocalChangesModel.guardRevert(file: file, current: nil) else {
            return XCTFail("expected abort")
        }
        XCTAssertTrue(reason.contains("weird path.txt"))
        XCTAssertTrue(reason.contains("changed since the list was last refreshed"))
    }

    // MARK: - pure helpers: revertedURLs

    func testRevertedURLsForPlainFileIsSingleURL() async {
        let file = ChangedFile(path: "src/a.swift", status: .modified)
        XCTAssertEqual(
            LocalChangesModel.revertedURLs(for: file, root: root),
            [root.appendingPathComponent("src/a.swift")]
        )
    }

    func testRevertedURLsForRenameReturnsBothPaths() async {
        let file = ChangedFile(path: "new/name.swift", status: .renamed, oldPath: "old/name.swift")
        XCTAssertEqual(
            LocalChangesModel.revertedURLs(for: file, root: root),
            [
                root.appendingPathComponent("new/name.swift"),
                root.appendingPathComponent("old/name.swift"),
            ]
        )
    }

    func testRevertedURLsForRenameWithoutOldPathIsSingleURL() async {
        // Defensive: a `.renamed` with no `oldPath` (shouldn't happen) still
        // yields just the new path rather than crashing.
        let file = ChangedFile(path: "new.swift", status: .renamed)
        XCTAssertEqual(
            LocalChangesModel.revertedURLs(for: file, root: root),
            [root.appendingPathComponent("new.swift")]
        )
    }

    // MARK: - grouping

    func testTreeGroupsChangedFilesViaChangeTree() async {
        let git = StubGit()
        let file = ChangedFile(path: "src/a.swift", status: .modified)
        git.files = [file]
        let model = makeModel(git: git)
        await model.refresh(root: root)

        XCTAssertEqual(model.tree, ChangeTree.build(from: [file], root: root))
    }

    func testTreeIsEmptyWithoutRoot() async {
        let git = StubGit()
        let model = makeModel(git: git)
        XCTAssertEqual(model.tree, [])
    }

    func testGroupingModeDefaultsToFlat() async {
        let model = makeModel(git: StubGit())
        XCTAssertEqual(model.groupingMode, .flat)
    }
}
